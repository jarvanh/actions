#!/usr/bin/env bash
# openclaw 工作流「Run trae2api container」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL /
#     GITHUB_WORKSPACE
#   落盘契约：/tmp/upstream-rc-trae2api（P5b 等齐门标记）、/opt/logs/upstream-trae2api.log
# P5b 双层子壳结构是刻意设计（孤儿化孙进程存活到网关步骤等齐），勿动结构。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）；体内自带 set -euo pipefail。

(
  set +e
  (
    set -euo pipefail
    # 通知真源在 step 顶层 source 一次（勿挪进函数体，理由见 workbuddy 步骤同名注释 / 规范 4.4）
    source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

    TRAE_DATA=/dropbox/self-hosted/trae2api
    TRAE_SRC=/tmp/local_trae2api-src
    TRAE_PORT="7864"
    CHECKIN_JSONL=/tmp/trae2api-checkin.jsonl
    CHECKIN_ERR=/tmp/trae2api-checkin.err
    PACKS_JSON=/tmp/trae2api-packs.json
    mkdir -p "$TRAE_DATA/auths" "$TRAE_DATA/data" ~/.openclaw/logs

    # 凭据清单（只列文件名，绝不回显内容——真实凭据；与 wb_notify 同口径）
    TRAE_CREDS="$(cd "$TRAE_DATA/auths" 2>/dev/null && ls -1 trae*.json 2>/dev/null || true)"

    # trae2api 通知的版式真源：与 wb_notify（workbuddy 段）完全同构
    # （docs/telegram-notify.md 2.5；三个调用点共用本函数，改版式只改这里）。
    # 用法: trae_notify <标题> <结论> <版本> <更新说明> <原因> <原始输出> [<接口/鉴权>]
    # 第 7 参 = 服务就绪态，取 "1" 才补「接口 / 鉴权」两行：失败时服务已不在，
    # 展示一个指向已停进程的地址会误导读者（与 wb_notify 同口径）。
    # 取值口径（同 wb_notify）：结论/更新/原因 → 人写的自然语言 → 裸文本 kv；
    # 版本/路径/端口 → 机器值 → <code>；原始输出 → <pre>，恒为正文最后一块。
    # 空值整行跳过、空分节整段跳过。凭据段只列 trae-*.json 文件名，绝不回显内容。
    # 账号池逐账号「一条目 + 多子行」：数据源是函数外的 CHECKIN_JSONL / PACKS_JSON
    # （uid/昵称/状态/积分进条目行，该账号最早过期的前 3 个包各占一个子行）。
    trae_notify() {
      TRAE_NOTIFY_OK=0
      if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        local _msg=""
        tg_add_title _msg "$1"
        tg_add_kv _msg "结论" "$2"
        # 数据目录（机器值 → <code>）移到头部，与 wb_notify 同口径
        # （主人 2026-10-06 要求）：它是「这条通知说的是哪份数据」的定位信息，
        # 与 版本/接口/API Key 同类；压在正文末尾夹在用量段与原始输出之间，
        # 既不像结论也不像明细，读者要找它得翻到底。
        tg_add_path _msg "数据目录" "$TRAE_DATA"
        [ -n "$3" ] && tg_add_path _msg "版本" "$3"
        [ -n "$4" ] && tg_add_kv _msg "更新" "$4"
        if [ "${7:-0}" = "1" ]; then
          tg_add_path _msg "接口" "http://127.0.0.1:${TRAE_PORT}/v1"
          # 明文 API Key（主人 23:33 要求，与 workbuddy 段同款展示）：
          # 从 Dropbox 数据目录 .env 读取，即面板/CLI 实际使用的那把
          local _trae_key="$(grep -m1 '^TW2A_API_KEY=' "${TRAE_DATA}/.env" 2>/dev/null | cut -d= -f2- || true)"
          # 标签「API Key」+ tg_add_path：值按规范走 <code> 等宽，
          # 客户端点一下即可整块复制（tg_add_kv 是纯文本，只能手选）
          tg_add_path _msg "API Key" "${_trae_key:-未取到}"
        fi
        [ -n "$5" ] && tg_add_kv _msg "原因" "$5"
        # 凭据段（🔑 凭据 · N）已按主人要求移除（2026-10-05），与 wb_notify 同口径。
        # TRAE_CREDS 变量保留（采集处仍在产出，供将来其它用途），仅不再渲染。
        # 账号池：与 wb_notify 同构的「条目 + 子行」形态。子行必须用 tree_sub
        # 前缀手拼 —— tree_lines 把每行都当兄弟条目，子行经它会渲染成 ├─/└─，
        # 与条目平级（规范 4.2 二层列表：子行与条目正文同列）。
        # 错峰签到（主人 09-25 定）：checkin 先零请求落盘全部账号的排程行
        # （skipped=scheduled/cooldown/already，带 planned_at），真实签到完成后
        # 追加结果行 —— 同一 uid 会有两行，按 uid 取末行：有结果显示结果，
        # 没轮到的显示「安排 HH:MM」；计数也按去重后的账号数。
        if [ -s "${CHECKIN_JSONL:-}" ]; then
          local _total _rows _i _line _uid _nick _cr _err _skipr _st _exp3 _eline _last _planned
          # 按 uid 取末行（保持首次出现顺序）：JSONL 逐行 uid 序列去重拼接
          _uids="$(jq -r '.uid' "$CHECKIN_JSONL" 2>/dev/null | awk '!seen[$0]++' || true)"
          _total="$(printf '%s\n' "$_uids" | grep -c . || true)"
          tg_add_section _msg "💳 账号池 · ${_total}"
          _rows=""
          _i=0
          while IFS= read -r _uid; do
            [ -z "$_uid" ] && continue
            _i=$((_i + 1))
            _last=0
            [ "$_i" -eq "$_total" ] && _last=1
            _line="$(jq -c --arg uid "$_uid" 'select(.uid == $uid)' "$CHECKIN_JSONL" 2>/dev/null | tail -n 1 || true)"
            _nick=$(jq -r '(.nickname // "-")' <<<"$_line" 2>/dev/null || echo "-")
            _cr=$(jq -r '.credits' <<<"$_line" 2>/dev/null || echo "-")
            _err=$(jq -r '(.err // "")' <<<"$_line" 2>/dev/null || true)
            _skipr=$(jq -r '(.skip_reason // "")' <<<"$_line" 2>/dev/null || true)
            _planned=$(jq -r '(.planned_at // "")' <<<"$_line" 2>/dev/null || true)
            if [ -n "$_err" ]; then
              _st="⚠️ $_err"
            elif [ "$(jq -r '.claimed' <<<"$_line" 2>/dev/null || true)" = "true" ]; then
              _st="签到 ✓ 本轮领取"
            elif [ "$(jq -r '.checked_in' <<<"$_line" 2>/dev/null || true)" = "true" ]; then
              _st="今日已签"
            elif [ -n "$_skipr" ] && [ -n "$_planned" ]; then
              # 排程/冷却中的账号：显示安排的签到时间（主人 09-25 定）
              _st="$_skipr · 安排 ${_planned}"
            elif [ -n "$_skipr" ]; then
              _st="$_skipr"
            else
              _st="今日已签"
            fi
            # 条目行只留「uid · 昵称」，签到状态与积分下移成子行
            # （主人 2026-10-06 要求：少用 · 分割、多换行）。此前四段全挤在
            # 条目行，读起来是一坨；与看板 trae 段同版式（board.py 该段
            # 注释里的样板即「今日已签 · 积分 3517」独占一行）。
            _rows+="$(tree_conn "$_last")$(tg_entry "$_uid" "$_nick")"$'\n'
            _rows+="$(tree_sub "$_last")$(escape_html "${_st} · 积分 ${_cr}")"$'\n'
            # 子行：该账号未用完的包里最早过期的前 3 个（逐包一行，完整时间戳）
            _exp3=$(jq -r --arg uid "$_uid" '[.[] | select(.uid == $uid and .remain > 0 and .expire_at > 0)] | sort_by(.expire_at) | .[:3][] | "剩 \(.remain) 分 · \(.expire_fmt) 过期"' "${PACKS_JSON:-}" 2>/dev/null || true)
            if [ -n "$_exp3" ]; then
              while IFS= read -r _eline; do
                [ -z "$_eline" ] && continue
                _rows+="$(tree_sub "$_last")$(escape_html "$_eline")"$'\n'
              done <<< "$_exp3"
            fi
          done <<< "$_uids"
          tg_add_block _msg "${_rows%$'\n'}"
          # 块尾补一个空行：tg_add_block 不补尾空行，下一个 kv（数据目录）会紧贴
          # 末条子行渲染，版式与 wb_notify（块与 kv 区之间空一行）一致。
          tg_append _msg $'\n'
        fi
        # 签到健康段（主人 09-30 定：原先独立的「签到简报」并入已就绪通知，
        # 不再单独发一条）。只列**需要关注**的账号（连败>0 / 换代过 / 仍在退避），
        # 全健康时整段跳过 —— 健康是常态，异常才值得占版面，否则每轮重复渲染
        # 四行「连败 0」纯属噪音。
        # 数据源：checkin-state.json（连败/上次成功）+ state.json（自愈换代/退避）。
        # 换代 gen>0 是 9074 自愈动过手的证据（不是故障），故单列且不加 ⚠️。
        # 2026-10-04 主人：裸写「自愈换代 gen 1」外人读不懂 → 条目改白话
        # 「签到设备换代 +1」（主人终版措辞），标题改「N 个账号有备注」
        # （N 是账号数不是失败数，此前被误读为「1 个失败」）。
        local _ck_state _st_state _hrows _hu _hfc _hlcd _hgen _hrc _hnick _hinfo
        _ck_state="${TRAE_DATA}/data/checkin-state.json"
        _st_state="${TRAE_DATA}/data/state.json"
        _hrows=""
        _hn=0
        if [ -s "$_ck_state" ]; then
          while IFS= read -r _hu; do
            [ -z "$_hu" ] && continue
            _hfc=$(jq -r --arg u "$_hu" '.[$u].fail_count // 0' "$_ck_state" 2>/dev/null || echo 0)
            _hlcd=$(jq -r --arg u "$_hu" '.[$u].last_claim_date // "-"' "$_ck_state" 2>/dev/null || echo "-")
            _hgen=$(jq -r --arg u "$_hu" '.accounts[$u].checkin_device_gen // 0' "$_st_state" 2>/dev/null || echo 0)
            _hrc=$(jq -r --arg u "$_hu" '.accounts[$u].checkin_retry_count // 0' "$_st_state" 2>/dev/null || echo 0)
            # 全健康 → 跳过（不占版面）
            [ "${_hfc:-0}" -gt 0 ] || [ "${_hgen:-0}" -gt 0 ] || [ "${_hrc:-0}" -gt 0 ] || continue
            _hnick=$(jq -r --arg uid "$_hu" '[.[] | select(.uid == $uid) | .nickname] | last // ""' "${CHECKIN_JSONL:-/dev/null}" 2>/dev/null || true)
            [ -n "$_hnick" ] || _hnick="$_hu"
            _hinfo="上次成功 ${_hlcd}"
            [ "${_hfc:-0}" -gt 0 ] && _hinfo="${_hinfo} · ⚠️ 连续失败 ${_hfc} 次"
            [ "${_hgen:-0}" -gt 0 ] && _hinfo="${_hinfo} · 签到设备换代 +1"
            [ "${_hrc:-0}" -gt 0 ] && _hinfo="${_hinfo} · ⏳ 退避重试中（已退 ${_hrc} 次）"
            # 主体是「昵称 · 健康备注」= 自然语言（规范 · 取值行口径），走
            # tg_add_entry_text 裸文本；tg_add_entry 会把整串当机器值套 <code>
            tg_add_entry_text _hrows "${_hnick} · ${_hinfo}"
            _hn=$((_hn + 1))
          done <<< "$(jq -r 'keys[]' "$_ck_state" 2>/dev/null)"
        fi
        if [ "$_hn" -gt 0 ]; then
          tg_add_section _msg "🩺 签到健康 · ${_hn} 个账号有备注"
          tg_add_block _msg "$(tree_lines "${_hrows%$'\n'}")"
          tg_append _msg $'\n'
        fi
        # 模型倍率段：数据源是 7.5 生成的 RATES_TXT（/v1/models 的
        # consumption_rate，倍率升序（价格低的排上面）、每模型一行）；服务未就绪/
        # 取数失败时为空，
        # 整段跳过（与凭据段同口径）。section 计数与「🔑 凭据 · N」同构。
        if [ -n "${RATES_TXT:-}" ]; then
          tg_add_section _msg "📊 模型倍率 · 模型数量${RATES_N:-0}"
          tg_add_pre _msg "$RATES_TXT"
          # tg_add_pre 内部 <pre> 包裹 + 转义；段尾补空行对齐账号池段
          tg_append _msg $'\n'
        fi
        # 用量 + 流水（与 wb_notify 同口径，2026-10-05 补）：只渲染 trae 自己的，
        # 调 board.py CLI 与看板共用渲染代码与数据源。trae 当日无 usage 文件时
        # CLI 输出空串，静默跳过（不留空行）。
        _trae_ul_block="$(python3 /dropbox/self-hosted/quota-board/board.py usage-ledger trae 12 2>/dev/null || true)"
        [ -n "$_trae_ul_block" ] && tg_append _msg "$_trae_ul_block"
        if [ -n "$6" ]; then
          tg_add_section _msg "🧾 原始输出"
          tg_add_pre _msg "$(tg_tail_safe "$6" 1200)"
        fi
        tg_add_footer _msg
        if send_tg "$_msg" alert; then
          TRAE_NOTIFY_OK=1
        else
          echo "::warning::TG 通知发送失败（不影响任务）"
        fi
      else
        echo "⚠️ Telegram secrets missing, skip trae2api notification."
      fi
    }

    echo "1. Resolving latest Release (jarvanh/trae2api)..."
    # 部署取 fork 的 Release 静态二进制，不在 runner 上跑 go build。
    # Release tag 形如 v2026.09.23-<短 commit>，镜像 tag 直接复用它（一一对应、
    # 同日多构建不撞车）；「更新」说明在第 8 步与 Dropbox 记录的上轮 tag 对比后判定。
    # 重试（2026-10-02 事故修复）：单次 gh api 瞬时返回空就 exit 1 → 服务
    # 停摆一整轮（run 36963030965 实测：step 2 秒即失败，非网络超时；
    # 之后无容器/无镜像/端口未监听，停摆约 5 小时才被发现）。
    # 瞬时抖动不该等价于一整轮不可用，故重试 3 次、间隔 5 秒，
    # 全失败才判定真故障。stderr 保留用于排查，不再静默吞掉。
    TRAE_REL=""
    TRAE_REL_ERR=""
    for _try in 1 2 3; do
      # ⚠️ 不能写 VAR="$(cmd)"：set -euo pipefail 下命令替换失败会直接终止脚本，
      # 重试循环形同虚设。必须让失败落在 &&/|| 列表里被吃掉，再回读文件取结果。
      gh api repos/jarvanh/trae2api/releases/latest --jq '.tag_name' \
        >/tmp/trae-rel.out 2>/tmp/trae-rel.err && _gh_rc=0 || _gh_rc=$?
      TRAE_REL="$(cat /tmp/trae-rel.out 2>/dev/null || true)"
      TRAE_REL_ERR="$(cat /tmp/trae-rel.err 2>/dev/null || true)"
      [ "$_gh_rc" -ne 0 ] && [ -z "$TRAE_REL_ERR" ] && TRAE_REL_ERR="gh api exit=$_gh_rc"
      if [ -n "$TRAE_REL" ]; then
        [ "$_try" -gt 1 ] && echo "   （第 ${_try} 次尝试成功）"
        break
      fi
      echo "   ⚠️ 第 ${_try}/3 次解析 Release 失败，5 秒后重试" >&2
      [ "$_try" -lt 3 ] && sleep 5
    done
    rm -f /tmp/trae-rel.out /tmp/trae-rel.err
    if [ -z "$TRAE_REL" ]; then
      echo "❌ 无法解析 jarvanh/trae2api 最新 Release（已重试 3 次）" >&2
      trae_notify "❌ trae2api 部署失败" "无法解析最新 Release" "" "" \
        "gh api releases/latest 连续 3 次返回空（网络抖动或仓库不可达）" "${TRAE_REL_ERR}" 0
      exit 1
    fi
    TRAE_VER="$TRAE_REL"
    echo "   Release: $TRAE_REL"

    # 二进制 sha256 从 Release 的 SHA256SUMS 实时提取，与版本强绑定；
    # 取不到就拒绝构建（Dockerfile 内还有一道 sha256sum -c 兜底校验）。
    # 同上：SHA256SUMS 是同一轮网络请求的下游，抖动会连带失败，
    # 同样重试 3 次；全失败才拒绝构建（安全底线不动：取不到仍不构建）。
    TRAE_SHA256=""
    TRAE_SHA_ERR=""
    for _try in 1 2 3; do
      # 同上：curl 失败不能直接进命令替换赋值，否则 set -e 当场终止。
      curl -fsSL "https://github.com/jarvanh/trae2api/releases/download/${TRAE_REL}/SHA256SUMS" \
        >/tmp/trae-sums.out 2>/tmp/trae-sums.err && _curl_rc=0 || _curl_rc=$?
      TRAE_SHA256="$(awk '$2 == "./trae2api-linux-amd64" {print $1}' /tmp/trae-sums.out 2>/dev/null || true)"
      TRAE_SHA_ERR="$(cat /tmp/trae-sums.err 2>/dev/null || true)"
      [ "$_curl_rc" -ne 0 ] && [ -z "$TRAE_SHA_ERR" ] && TRAE_SHA_ERR="curl exit=$_curl_rc"
      if [ -n "$TRAE_SHA256" ]; then
        [ "$_try" -gt 1 ] && echo "   （第 ${_try} 次尝试成功）"
        break
      fi
      echo "   ⚠️ 第 ${_try}/3 次获取 SHA256SUMS 失败，5 秒后重试" >&2
      [ "$_try" -lt 3 ] && sleep 5
    done
    rm -f /tmp/trae-sums.out /tmp/trae-sums.err
    if [ -z "$TRAE_SHA256" ]; then
      echo "❌ 未能提取 sha256，拒绝构建（已重试 3 次）" >&2
      trae_notify "❌ trae2api 部署失败" "SHA256SUMS 未取到校验值" "$TRAE_VER" "" \
        "Release 资产缺失或连续 3 次下载失败" "${TRAE_SHA_ERR}" 0
      exit 1
    fi
    echo "   sha256  : $TRAE_SHA256"

    echo "2. Bootstrap data files (idempotent, Dropbox 为准)..."
    if [ ! -f "$TRAE_DATA/.env" ]; then
      printf 'TW2A_API_KEY=%s\n' "$(openssl rand -hex 24)" > "$TRAE_DATA/.env"
    fi
    if [ ! -f "$TRAE_DATA/config.json" ]; then
      curl -fsSL "https://raw.githubusercontent.com/jarvanh/trae2api/${TRAE_REL}/config.example.json" \
        -o "$TRAE_DATA/config.json"
    fi

    echo "3. Fetch Dockerfile + compose from fork Release..."
    # 构建定义从 fork 对应 Release tag 的 raw 拉取（不再克隆源码、不再内联 heredoc）：
    # fork 的 Dockerfile 是「alpine + 下载 Release 二进制 + sha256 校验」单阶段构建，
    # compose 透传版本/Release/sha256 三个 build arg。本机无需源码、无需 Go 工具链。
    rm -rf "$TRAE_SRC"
    mkdir -p "$TRAE_SRC"
    curl -fsSL "https://raw.githubusercontent.com/jarvanh/trae2api/${TRAE_REL}/Dockerfile" \
      -o "$TRAE_SRC/Dockerfile"
    curl -fsSL "https://raw.githubusercontent.com/jarvanh/trae2api/${TRAE_REL}/docker-compose.yml" \
      -o "$TRAE_SRC/docker-compose.yml"

    echo "3.5 防御校验：compose 必须固化 Dropbox 挂载..."
    # 挂载在 jarvanh/trae2api eccfc2e 固化为 /dropbox/self-hosted/trae2api/... 绝对路径，
    # 不再由本 workflow 内联生成（此前两套 compose 并存，部署半途中断时会残留旧版）。
    # 取回来的 compose 若被回退成相对路径版，显式失败而不是让容器静默崩。
    if ! grep -q '/dropbox/self-hosted/trae2api' "$TRAE_SRC/docker-compose.yml"; then
      echo "::error::仓库 compose 未固化 Dropbox 挂载（可能被回退），拒绝部署" >&2
      exit 1
    fi

    echo "4. Remove stale container & build & start..."
    # 幂等接管：清理同名旧容器（可能来自手工部署或旧 project），再由本 compose 接管
    docker rm -f trae2api >/dev/null 2>&1 || true
    TRAE2API_IMAGE_VERSION="$TRAE_REL" \
    TRAE2API_RELEASE_TAG="$TRAE_REL" \
    TRAE2API_SHA256="$TRAE_SHA256" \
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    docker compose --env-file "$TRAE_DATA/.env" \
      -f "$TRAE_SRC/docker-compose.yml" \
      --project-directory "$TRAE_SRC" up -d --build

    echo "5. Health check..."
    _code=""
    for i in $(seq 1 60); do
      _code=$(curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:7864/healthz || true)
      if [ "$_code" = "200" ]; then
        echo "✅ [trae2api] 7864 已就绪 (HTTP 200)"
        break
      fi
      echo "⏳ [trae2api] 等待中... ${i}/60"
      sleep 2
    done
    if [ "${_code:-}" != "200" ]; then
      echo "❌ trae2api 未在 120 秒内就绪" >&2
      # 失败也通知（对齐 workbuddy：成功/失败都有声）。接口行不展示（第 7 参 0）：
      # 服务已不在，展示一个指向已停进程的地址会误导读者（wb_notify 同口径）。
      trae_notify "❌ trae2api 启动失败" \
        "未就绪 · 120 秒健康检查超时" \
        "$TRAE_VER" "" "构建或启动失败（详见运行日志）" \
        "$(docker logs --tail 60 trae2api 2>&1 || true)" 0
      exit 1
    fi

    echo "6. Converge tunnel..."
    # 公网隧道已撤（2026-09-29 主人要求）：trae2api 管理后台改走 Tailscale
    # ts.net 内网，不再暴露公网。tunnels.conf 里 trae2api 一行已删除，
    # ensure 对清单外名字是静默空操作；这里保留注释说明，避免后人误加回公网。

    echo "7. Bulk check-in all accounts (cooldown-aware)..."
    # 签到/积分工具随 fork 维护（jarvanh/trae2api cmd/checkin、cmd/credit）。
    # 冷却策略（工具内实现，状态落 Dropbox）：失败 30m 起步指数递增
    # （30m→60m→120m 封顶），当日已签直接跳过 —— 避免上游 9074
    # 「参与用户太多」限流下每 5 分钟空转重试。
    # CHECKIN_JSONL / CHECKIN_ERR / PACKS_JSON 已在 step 顶部定义（trae_notify 数据源）。
    # 工具二进制同样取自本轮 Release（fork 的 release.yml 一并构建），
    # 不再 go build —— 本机无源码、也无需 Go 工具链。
    curl -fsSL "https://github.com/jarvanh/trae2api/releases/download/${TRAE_REL}/trae2api-checkin-linux-amd64" \
      -o /tmp/trae2api-checkin && chmod +x /tmp/trae2api-checkin
    curl -fsSL "https://github.com/jarvanh/trae2api/releases/download/${TRAE_REL}/trae2api-credit-linux-amd64" \
      -o /tmp/trae2api-credit && chmod +x /tmp/trae2api-credit
    # 启动式错峰签到（主人 09-25 定）：停用 cron 连打，每次 VM 启动只跑一轮。
    #   - /tmp 标记随 VM 重启清空 → 天然「每次启动一次」
    #   - 后台进程存活（pid 探活）→ 上一 run 拉起的错峰仍在 30-60 分钟账号间隔中，跳过
    #   - 首个真实账号立即发起；already/cooldown 分支零请求秒回；
    #     后续真实请求随机间隔 30-60 分钟（工具内 -stagger-min/-stagger-max）
    #   - 不提供 -force：风控期禁止绕过冷却强打
    CK_RUNNING=0
    _ckp="$(cat /tmp/trae2api-checkin.pid 2>/dev/null || true)"
    if [ -n "$_ckp" ] && kill -0 "$_ckp" 2>/dev/null; then
      CK_RUNNING=1
    fi
    if [ "$CK_RUNNING" = 1 ]; then
      echo "   后台错峰签到进行中（pid $_ckp），跳过重复拉起"
    elif [ -f /tmp/trae2api-checkin.round ]; then
      echo "   本次 VM 启动已完成一轮错峰签到（标记存在），跳过"
    elif ! /tmp/trae2api-checkin -h 2>&1 | grep -q 'stagger-min'; then
      echo "   ⚠️ 签到工具不支持错峰参数（Release 未更新），本轮跳过签到"
    else
      : > "$CHECKIN_JSONL"; : > "$CHECKIN_ERR"
      nohup /tmp/trae2api-checkin -dir "$TRAE_DATA/auths" -state "$TRAE_DATA/data/state.json" \
        -stagger-min 30 -stagger-max 60 \
        > "$CHECKIN_JSONL" 2>>"$CHECKIN_ERR" &
      echo $! > /tmp/trae2api-checkin.pid
      touch /tmp/trae2api-checkin.round
      echo "   已后台拉起错峰签到（pid $(cat /tmp/trae2api-checkin.pid)），真实请求随机间隔 30-60 分钟"
    fi
    # 等首批落盘：跳过类分支秒回；首个真实账号数秒～数十秒
    for _i in 1 2 3 4 5 6 7 8 9; do
      sleep 10
      [ -s "$CHECKIN_JSONL" ] && break || true
    done
    /tmp/trae2api-credit -dir "$TRAE_DATA/auths" -packs -json > "$PACKS_JSON" 2>/dev/null || true
    cat "$CHECKIN_JSONL" 2>/dev/null || true
    _ckp="$(cat /tmp/trae2api-checkin.pid 2>/dev/null || true)"
    if [ -n "$_ckp" ] && kill -0 "$_ckp" 2>/dev/null; then
      echo "   （错峰签到后台进行中，剩余账号按 30-60 分钟间隔陆续落盘）"
    fi

    echo "7.5 Fetch model consumption rates (from live /v1/models)..."
    # 数据源：本机 trae2api /v1/models 的 consumption_rate 字段（jarvanh/trae2api
    # 91cb7a5 起提供，与 TRAE 客户端显示的倍率一致）。鉴权用 Dropbox .env 的
    # TW2A_API_KEY。取数失败/服务未就绪时 RATES_TXT 为空，通知里整段跳过。
    RATES_TXT=""
    RATES_N=""
    _tw2a_key="$(grep -m1 '^TW2A_API_KEY=' "$TRAE_DATA/.env" 2>/dev/null | cut -d= -f2-)"
    if [ -n "$_tw2a_key" ] && curl -sf -m 10 \
        -H "Authorization: Bearer ${_tw2a_key}" \
        "http://127.0.0.1:${TRAE_PORT}/v1/models" -o /tmp/trae2api-models.json 2>/dev/null \
        && jq -e '.data | length > 0' /tmp/trae2api-models.json >/dev/null 2>&1; then
      # 过滤内部功能模型（subagent/summary 等），只留用户可用的对话模型。
      # 仅统计 consumption_rate > 0 的条目：上游 client.go:270 定义
      # 「Rate 0 = 未知」，且 handler.go 只在 Rate > 0 时才输出该字段 ——
      # 故 rate 缺失 ≠ 免费，不能渲染成「免费」或 0.00x（那是编造）。
      # 已排除 custom_model_* 占位（14）与内部功能模型（4）；
      # 倍率未知的也列出并标「未知」（主人 07:12 定）。
      # 标题「模型数量N」= 列出的模型数（有倍率 + 未知），不是接口返回总数。
      RATES_N="$(jq -r '[.data[]
          | select(.id != "file_search_agent" and .id != "explore_sub_agent_v2"
              and .id != "browser_use_subagent" and .id != "summary")
          | select((.id | startswith("custom_model")) | not)] | length' /tmp/trae2api-models.json)"
      # 倍率升序（价格低的排上面）、等宽表格（模型左对齐 + 倍率两位小数右对齐），
      # 通知里走 <pre> 渲染。版式与 workbuddy 段统一：
      #   行首两空格缩进 + 模型 %-26s 左对齐 + 倍率 %6.2fx 右对齐
      #   不列 model/rate 表头（workbuddy 以「国内站/国际站」分组，同样无表头）
      # 倍率未知（rate 缺失/0）也列出，排在最末并标「未知」——不冒充免费或 0.00x。
      # 排序键：有倍率用其值，未知用 9999 保证沉底。
      RATES_TXT="$(jq -r '.data[]
          | select(.id != "file_search_agent" and .id != "explore_sub_agent_v2"
              and .id != "browser_use_subagent" and .id != "summary")
          | select((.id | startswith("custom_model")) | not)
          | if (.consumption_rate // 0) > 0
            then "\(.consumption_rate)\t\(.id)"
            else "9999\t\(.id)" end' /tmp/trae2api-models.json \
            | sort -k1,1 -n \
          | awk -F'\t' '{if ($1 == "9999") printf "  %-26s %6s\n", $2, "未知"; else printf "  %-26s %6.2fx\n", $2, $1}')"
    fi

    echo "8. Telegram notification (workbuddy-format)..."
    # 版式与调用形态对齐 wb_notify（workbuddy 段）：状态 emoji 标题 + 结论/版本/
    # 更新/接口/鉴权 + 凭据 + 账号池 + 数据目录 + 原始输出（版式真源在 trae_notify）。
    # 「更新」判定：TRAE_VER（本轮克隆 hash）与 Dropbox 数据目录记录的上轮 hash
    # 对比（语义对齐 wb_notify 的 WB_VER/WB_UPDATE）。记录写在服务健康通过之后 ——
    # 未就绪的轮次不落账，下轮仍报「更新」。
    TRAE_VER_FILE="$TRAE_DATA/data/.built-commit"
    TRAE_LOCAL_VER="$(head -n 1 "$TRAE_VER_FILE" 2>/dev/null || true)"
    if [ -n "$TRAE_LOCAL_VER" ] && [ "$TRAE_LOCAL_VER" = "$TRAE_VER" ]; then
      TRAE_UPDATE="已在最新版 ${TRAE_VER} · 镜像复用缓存"
    elif [ -n "$TRAE_LOCAL_VER" ]; then
      TRAE_UPDATE="从 ${TRAE_LOCAL_VER} 更新到 ${TRAE_VER}"
    else
      TRAE_UPDATE="首次构建 ${TRAE_VER}"
    fi
    # 标题/结论随签到结果走：无输出 = 签到工具自身异常（⚠️ 中间态，对齐 workbuddy
    # 的「已启动 · 无可用账号」调用点），服务本身仍就绪 → 接口行照常展示（第 7 参 1）。
    _title="🟢 trae2api 已就绪"
    _conclusion="已就绪 · 签到工具无输出（详见原始输出）"
    # 必须先初始化：本 step 顶部是 set -euo pipefail（带 -u），而下面的 else 分支
    # 不赋值 _raw_out，trae_notify 第 6 参展开它会 unbound variable 直接退出整 step。
    _raw_out=""
    if [ -s "$CHECKIN_JSONL" ]; then
      # 两行制（排程行+结果行）：按 uid 取末行再分类，避免重复计数；
      # 排程/冷却中的账号计入「待签」，结论里也能看到本轮还剩几个没轮到
      _total=$(jq -sr 'group_by(.uid) | length' "$CHECKIN_JSONL" 2>/dev/null || echo 0)
      _ok=$(jq -sr 'group_by(.uid) | map(last) | [.[] | select((.err // "") == "" and ((.claimed // false) == true or (.checked_in // false) == true or (.skipped // "") == "already"))] | length' "$CHECKIN_JSONL" 2>/dev/null || echo 0)
      _wait=$(jq -sr 'group_by(.uid) | map(last) | [.[] | select((.err // "") == "" and (.claimed // false) != true and (.checked_in // false) != true and ((.skipped // "") == "scheduled" or (.skipped // "") == "cooldown"))] | length' "$CHECKIN_JSONL" 2>/dev/null || echo 0)
      _fail=$(jq -sr 'group_by(.uid) | map(last) | [.[] | select((.err // "") != "")] | length' "$CHECKIN_JSONL" 2>/dev/null || echo 0)
      # 计数只列非零项（telegram-notify 规范 2.5 / 5.4）：
      # 「待签 0 · 失败 0」这类零计数与 🟢 已就绪的标题自相矛盾，且把常态噪音
      # 顶到结论行最显眼的位置。共 N 是分母、始终保留（读者需要知道池子多大）。
      _parts="已就绪"
      [ "${_ok:-0}" -gt 0 ] && _parts="${_parts} · 已签 ${_ok}"
      [ "${_wait:-0}" -gt 0 ] && _parts="${_parts} · 待签 ${_wait}"
      [ "${_fail:-0}" -gt 0 ] && _parts="${_parts} · 失败 ${_fail}"
      _conclusion="${_parts}（共 ${_total}）"
      # 错峰后台进行中 → 结论追加标记（剩余账号尚未落盘）
      _ckp="$(cat /tmp/trae2api-checkin.pid 2>/dev/null || true)"
      if [ -n "$_ckp" ] && kill -0 "$_ckp" 2>/dev/null; then
        _conclusion="${_conclusion} · 错峰进行中"
      fi
      # 原始输出：全签轮次的 stderr 尾行是「checkin done: 0/N ok」，分子 0 是
      # 「本轮真实领取次数」（已签账号幂等跳过不计入），不是失败数 —— 与结论的
      # 「已签 N」正面冲突，读者会以为签到全挂了。
      # 处理：无失败时滤掉该行。结论行已写明已签数，这是重复信息，没必要换句
      # 术语再解释一遍；滤完为空则「原始输出」整段跳过（规范 · 空清单整段跳过）。
      # 有失败时原样保留 —— 失败细节必须可见，不能被这层过滤盖掉。
      _raw_out="$(cat "$CHECKIN_ERR" 2>/dev/null || true)"
      if [ "${_fail:-0}" -eq 0 ]; then
        _raw_out="$(printf '%s' "$_raw_out" | grep -vE 'checkin done:[[:space:]]*0/' || true)"
      fi
    else
      _title="⚠️ trae2api 已就绪 · 签到无输出"
    fi
    trae_notify "$_title" \
      "$_conclusion" \
      "$TRAE_VER" "$TRAE_UPDATE" "" \
      "${_raw_out}" 1
    # 只有通知真正发出才落版本标记：发送失败时下轮仍会报「从 X 更新到 Y」，
    # 不会把更新说明永久吞掉（与 workbuddy/zcode 同口径）。
    if [ "${TRAE_NOTIFY_OK:-0}" = "1" ] && [ -n "$TRAE_VER" ]; then
      printf '%s\n' "$TRAE_VER" > "$TRAE_VER_FILE"
    fi
  )
  _up_rc=$?
  printf '%s' "$_up_rc" > /tmp/upstream-rc-trae2api
) > /opt/logs/upstream-trae2api.log 2>&1 &
echo "🚀 [P5b] trae2api 已转后台部署（等齐门在 AI 网关步骤）"
