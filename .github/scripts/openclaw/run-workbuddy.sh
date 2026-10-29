#!/usr/bin/env bash
# openclaw 工作流「Run workbuddy-gateway」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限，schedule 停摆 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL /
#     WB_GH_TOKEN / AI_GATEWAY_API_KEY（job 级）/ GITHUB_WORKSPACE / GITHUB_RUN_ID
#   落盘契约：/tmp/upstream-rc-workbuddy（P5b 等齐门标记，AI 网关步骤轮询上限 480s）、
#     /opt/logs/upstream-workbuddy.log、/tmp/run-workbuddy-meta.env
# P5b 双层子壳结构是刻意设计（外层子壳收 rc，内层子壳跑本体）：步骤 shell 退出后
# 孤儿化的孙进程才能活到网关步骤等齐，动结构前先读 7ccd896 的 P5b 说明。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）。

(
  set +e
  (
    set -uo pipefail

    # 通知真源在 step 顶层 source 一次。**不要挪进 wb_notify 函数体**：
    # 该函数在 $( ) / 管道里跑（子 shell），子 shell 内 source 不影响父 shell 的
    # 函数表，会把调用点对 send_tg 的本地覆写还原掉；而且子 shell 里 `local`
    # 管不住父 shell 的变量（规范 4.4）。
    source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

    # workbuddy-gateway（jarvanh/workbuddy-gateway）：纯 Go 单二进制的本地 AI 代理网关。
    # 运行目录整体落本地盘，Dropbox 只做持久化存放 —— 与 OpenClaw/CliRelay 同口径。
    # 两处刻意分离的原因：
    #   1. 二进制不能放挂载点：rclone 按 --file-perms 合成权限（默认 0644），chmod +x 是空操作，
    #      从挂载点执行一律 "Permission denied"。
    #   2. 工作目录也不能直接用挂载点：serve 会在 cwd 下高频读写 logs/ 与 workbuddy-status.json，
    #      在 --vfs-cache-mode full 的 FUSE 挂载点上会卡住/被 runner 清理，表现为
    #      「进程已退出且 serve.log 为空」。
    # 2026-10-07 起无 WB_RUN_DIR：数据（凭据/config/usage/status/logs）直写 WB_DIR（Dropbox），
    # 二进制在本地盘；原「起前拉数据、停后回推」机制已随数据直写迁移退役。
    WB_DIR="/dropbox/self-hosted/workbuddy-gateway"
    WB_BIN_DIR="/tmp/local_workbuddy"
    WB_BIN="$WB_BIN_DIR/workbuddy-gateway"
    WB_RELEASE_BASE="https://github.com/jarvanh/workbuddy-gateway/releases/latest/download"
    WB_VER_FILE="$WB_DIR/.installed-version"
    WB_META="/tmp/run-workbuddy-meta.env"
    WB_LOG="$WB_DIR/logs/serve.log"
    : > "$WB_META"

    # workbuddy 通知的版式真源（docs/telegram-notify.md 2.5 workbuddy 段）。
    # 三个调用点（step 内就绪/失败、收尾停止）在同一作业但不同 shell，函数无法跨 step
    # 共享，故版式在两处各存一份；改版式必须同时改两处，否则停止通知会掉队。
    #
    # 用法: wb_notify <标题> <结论> <版本> <更新说明> <原因> <原始输出> [<接口/鉴权 kv>]
    # 第 7 参 = 网关就绪态，取 "1" 才补「接口 / 鉴权」两行：失败或收尾停止时服务已不在，
    # 展示一个指向已停进程的地址会误导读者。
    #
    # 取值口径（逐条见规范）：
    #   结论/更新/原因 → 人写的自然语言 → 裸文本 kv；版本/路径/端口 → 机器值 → <code>；
    #   原始输出 → <pre>，恒为正文最后一块（其后只跟收尾区）。空值整行跳过、空分节整段跳过。
    #   鉴权写实际形态：serve 以 -addr 0.0.0.0 监听（对 Tailscale/局域网开放），
    #   故显式传 -api-key 做客户端 Bearer 校验，取 AI_GATEWAY_API_KEY（workbuddy 专属，
    #   与 zcode2api 的 ZCODE_GATEWAY_API_KEY 已分家，见 zcode2api 步骤 env 注释）。
    #   （此前注释写「仅回环监听，无需密钥」，与 -addr 0.0.0.0 的实际启动参数不符，已订正）
    #   绝不编造密钥值，也不在通知里回显 key 本身。凭据段只列 workbuddy*.json 的文件名，绝不回显内容（真实 Token）。
    #   账号池取自 workbuddy-status.json（键名由上游 Go 结构体固定，见采集处注释）；
    #   免费模型列**具体模型名**（取自上游模型目录接口，见采集处注释），
    #   全量展示不折叠 —— 只给「免费模型 N」读者不知道是哪个，等于没说。
    wb_notify() {
      # 发送成功才置 1；调用方据此决定是否写「本轮已启动」标记，
      # 避免发送失败后下一轮被标记挡住、通知永久丢失。
      WB_NOTIFY_OK=0
      if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        local _msg=""
        tg_add_title _msg "$1"
        tg_add_kv _msg "结论" "$2"
        # 数据目录（机器值 → <code>）移到头部（主人 2026-10-06 要求）：
        # 它是「这条通知说的是哪台机/哪份数据」的定位信息，与 版本/接口/API Key
        # 同类；压在正文末尾时夹在「用量/流水」与「原始输出」之间，既不像结论
        # 也不像明细，读者要找它得翻到底。
        tg_add_path _msg "数据目录" "$WB_DIR"
        [ -n "$3" ] && tg_add_path _msg "版本" "$3"
        [ -n "$4" ] && tg_add_kv _msg "更新" "$4"
        if [ "${7:-0}" = "1" ]; then
          tg_add_path _msg "接口" "http://127.0.0.1:${WB_PORT}/v1"
          # 明文 API Key（主人 23:33 要求）：本机网关访问口令，取值即启动 serve
          # 时传入的 job 级 AI_GATEWAY_API_KEY，与客户端实际使用的一致
          # 标签「API Key」+ tg_add_path：值按规范走 <code> 等宽，
          # 客户端点一下即可整块复制（tg_add_kv 是纯文本，只能手选）
          tg_add_path _msg "API Key" "${AI_GATEWAY_API_KEY:-未取到}"
        fi
        [ -n "$5" ] && tg_add_kv _msg "原因" "$5"
        # 凭据段（🔑 凭据 · N）已按主人要求移除（2026-10-05）：凭据文件名去掉
        # 前后缀后与下方账号池条目名逐字相同，同一份名单渲染两遍纯占版面。
        # ⚠️ WB_CREDS 变量本身**保留** —— 上方签到汇总仍用它算「跳过」数
        # （_n_creds - _n_rows），删掉会让跳过数恒为 0。
        # 账号池：逐账号「一条目 + 多子行」。数据源是函数外的 WB_POOL —— 采集处
        # （启动步骤）已用 jq 解析 workbuddy-status.json 成 9 列 TSV：
        #     名录可信标记 \t 凭据文件名 \t 站点 \t 状态 \t 账号冷却 \t 额度 \t 免费模型名 \t 模型冷却 \t Token 过期
        # 采集处保证**每列都不为空**（空值填哨兵「-」），否则 read 的空白折叠会让
        # 中段空列后面的值整体左移（实测会把冷却数当模型名渲染）。故这里先把「-」
        # 还原成空串，再按原来的「非空才并入」逻辑处理，读者看不到哨兵。
        # 凭据名/站点/状态进条目行，第 5/6/8/9 列（账号冷却 / 额度 / 模型冷却 / Token 过期）
        # 并成第一个子行，第 7 列（免费模型名，可能很长）另起一个独立子行
        # 「免费模型 N · <code>名</code> · <code>名</code>」—— 与额度等短字段混在一行会被撑爆。
        # 子行必须用 tree_sub 前缀手拼 —— tree_lines 把每行都当兄弟条目，
        # 子行经它会渲染成 ├─/└─，与条目平级（规范 4.2 二层列表：子行与条目正文同列）。
        if [ -n "${WB_POOL:-}" ]; then
          local _readyflag _cf _st _state _acdl _quota _fm _cdl _tok _n_acc _rows _i _sub _x _last
          local _names _n_names _m _mline
          _n_acc="$(printf '%s\n' "$WB_POOL" | grep -c . || true)"
          tg_add_section _msg "💳 账号池 · ${_n_acc}"
          _rows=""
          _i=0
          while IFS="$(printf '\t')" read -r _readyflag _cf _st _state _acdl _quota _fm _cdl _tok; do
            [ -z "$_cf" ] && continue
            # 哨兵「-」还原成空串（采集处保证列非空，故此处不可能因还原再产生空列错位）
            # 不要用 `eval "[ ... ] && x="`：本 step 跑在 Actions 默认的 `bash -e` 下
            # （`set -uo pipefail` 不会关掉 -e），A && B 里 A 为假时整条返回 1，
            # 循环体末条命令返回 1 会直接终止整个 step —— 只要有任何一列是哨兵「-」
            # 就会 exit 1。改成 if 语句：无论分支走哪边，返回值恒为 0。
            # ⚠️ _state 也必须在列：active 已映射为空串（常态不显示「· 可用」），
            # 采集处的 or_dash 会把空串补成哨兵「-」，不还原就渲染成「· -」。
            for _x in _state _acdl _quota _fm _cdl _tok; do
              if [ "${!_x}" = "-" ]; then printf -v "$_x" '%s' ""; fi
            done
            _i=$((_i + 1))
            _last=0
            [ "$_i" -eq "$_n_acc" ] && _last=1
            _rows+="$(tree_conn "$_last")$(tg_entry "$_cf" "$_st" "$_state")"$'\n'
            # 第一个子行：账号冷却 / 额度 / 模型冷却 / Token 过期，逐项非空才并入。
            # 账号冷却只在 state=cooldown 时有值（采集处已按状态过滤）；
            # 过期时间在 jq 侧已带「过期 」前缀（裸时间戳读者不知道是什么）。
            _sub=""
            for _x in "$_acdl" "$_quota" "$_cdl" "$_tok"; do
              [ -z "$_x" ] && continue
              _sub="${_sub:+${_sub} · }${_x}"
            done
            [ -n "$_sub" ] && _rows+="$(tree_sub "$_last")$(escape_html "$_sub")"$'\n'
            # 第二个子行：免费模型清单。全量展示、不折叠（规范 · 折叠规则：读者要逐条
            # 核对哪些模型免费，折叠等于把最需要看的部分藏起来）。模型名是机器值 → <code>，
            # 逐个转义。名单来自上游模型目录接口 → 格式是「名 · 名 · …」。
            # 「免费模型 0」只在名录确实取到（_readyflag=1）时才显示 ——
            # 接口失败时什么都不说，不把「没取到」谎报成「没有免费模型」。
            _n_names=0
            _mline=""
            if [ -n "$_fm" ]; then
              _names="$(printf '%s' "$_fm" | tr -s ' ' | sed 's/ *· */\n/g')"
              _n_names="$(printf '%s\n' "$_names" | grep -c . || true)"
              while IFS= read -r _m; do
                [ -z "$_m" ] && continue
                _mline+="${_mline:+ · }<code>$(escape_html "$_m")</code>"
              done <<< "$_names"
            fi
            if [ "$_n_names" -gt 0 ]; then
              _rows+="$(tree_sub "$_last")$(escape_html "免费模型 ${_n_names}") · ${_mline}"$'\n'
            elif [ "${_readyflag:-0}" = "1" ]; then
              _rows+="$(tree_sub "$_last")$(escape_html "免费模型 0")"$'\n'
            fi
          done <<< "$WB_POOL"
          tg_add_block _msg "${_rows%$'\n'}"
          # 块尾补一个空行：tg_add_block 不补尾空行，下一个 kv（数据目录）会紧贴
          # 末条子行渲染，版式与规范示例（块与 kv 区之间空一行）不一致。
          tg_append _msg $'\n'
        fi
        # 签到段（2026-09-26 补）：workbuddy-gateway 的每日签到是 serve 内置后台协程
        # （backgroundDailyCheckin），**没有 CLI 子命令**（--help 里确实没列出），
        # 也不写进 workbuddy-status.json —— 唯一可观测出口就是 serve.log 的 [Checkin] 行。
        # 此前本通知完全没有这一段：主人看到的是「5 个账号全绿」的账号池，却无从知道
        # 今天签到跑没跑、哪个号失败了。本段即补这个缺口。
        # 数据源 WB_CHECKIN 是上一步合并好的 TSV（5 列）：凭据文件名 \t 站点 \t
        # 签到结果 \t 签到积分 \t 旅行奖励（后两列可为空，空则不展示）。
        # 逐账号一条目：签到信息一行装得下；积分跟在结果后（本次/累计/连签），
        # 旅行奖励有领取动作时独占一条子行（无领取不占行）。
        # 全量不折叠：账号量级只有个位数，读者要逐号核对，折叠等于把要看的藏起来。
        if [ -n "${WB_CHECKIN:-}" ]; then
          local _ckn _ckrows _cki _ckf _cks _ckr _cklast _ckcredit _cktravel _ckline
          _ckn="$(printf '%s\n' "$WB_CHECKIN" | grep -c . || true)"
          tg_add_section _msg "🗓 每日签到 · ${_ckn}"
          _ckrows=""
          _cki=0
          while IFS="$(printf '\t')" read -r _ckf _cks _ckr _ckcredit _cktravel; do
            [ -z "$_ckf" ] && continue
            _cki=$((_cki + 1))
            if [ "$_cki" -eq "$_ckn" ]; then _cklast=1; else _cklast=0; fi
            _ckline="$(tg_entry "$_ckf" "$_cks" "$_ckr")"
            if [ -n "$_ckcredit" ]; then
              _ckline="${_ckline} · $(escape_html "$_ckcredit")"
            fi
            _ckrows+="$(tree_conn "$_cklast")${_ckline}"$'\n'
            if [ -n "$_cktravel" ]; then
              _ckrows+="$(tree_sub "$_cklast")$(escape_html "$_cktravel")"$'\n'
            fi
          done <<< "$WB_CHECKIN"
          tg_add_block _msg "${_ckrows%$'\n'}"
          tg_append _msg $'\n'
          # 汇总行（总数/成功/今日已签/失败/跳过）：**被跳过**的账号不会有「开始每日签到」
          # 行、也就不会出现在上面的条目里 —— 只有这行能暴露「有号根本没轮到」，
          # 光看逐账号条目会把「跳过」误读成「没问题」。
          if [ -n "${WB_CHECKIN_SUMMARY:-}" ]; then
            tg_add_kv _msg "本轮汇总" "$WB_CHECKIN_SUMMARY"
          fi
          # 下次签到时刻：服务自己算的定时点（东八区，日志原文带 UTC+8 后缀）。
          if [ -n "${WB_CHECKIN_NEXT:-}" ]; then
            tg_add_kv _msg "下次签到" "$WB_CHECKIN_NEXT"
          fi
        fi
        # 模型倍率段：数据源是上方生成的 WB_RATES_TXT（wb-models-cache.json 的
        # catalogs + 免费实测，按站点分组、站点内倍率升序（价格低者在上）每模型一行、
        # **全量不截断**）。
        # 取数失败/缓存缺失时为空，整段跳过（与凭据段同口径），绝不编造倍率。
        # 长度：send_tg 现在会自动分片（超过 3900 UTF-16 码元走 send_tg_chunked）；
        # 倍率全量实测 2200+ B，与凭据 + 账号池（三行明细）叠加后实测 3912 B。
        # 仍保留独立第二条：主消息保持完整版式，倍率段自成一篇（标题 + 收尾区），
        # 既不砍数据，也避免主消息在客户端被折叠得太长。
        WB_RATES_BLOCK=""
        if [ -n "${WB_RATES_TXT:-}" ]; then
          WB_RATES_BLOCK="$(tg_add_title WB_RATES_BLOCK "📊 workbuddy-gateway 模型倍率 · 模型数量${WB_RATES_N:-0}${WB_RATES_FREE_TAG:-}"; tg_add_pre WB_RATES_BLOCK "$WB_RATES_TXT"; tg_add_footer WB_RATES_BLOCK; printf '%s' "$WB_RATES_BLOCK")"
        fi
        # 用量 + 流水（看板独有，2026-10-05 补进通知）：只渲染本网关自己，
        # 避免 wb 通知里出现 zcode 数据（语义串台）。调 board.py 的 CLI 子命令 ——
        # 与看板**共用同一份渲染代码与本地实时 usage**，不另写一套、不走 Dropbox 旧副本
        # （那版仅收尾回推，实测落后 4 小时丢 93% 行）。文件缺失时 CLI 输出空串，静默跳过。
        _wb_ul_block="$(python3 /dropbox/self-hosted/quota-board/board.py usage-ledger workbuddy 12 2>/dev/null || true)"
        [ -n "$_wb_ul_block" ] && tg_append _msg "$_wb_ul_block"
        if [ -n "$6" ]; then
          tg_add_section _msg "🧾 原始输出"
          tg_add_pre _msg "$(tg_tail_safe "$6" 1200)"
        fi
        tg_add_footer _msg
        if send_tg "$_msg" alert; then
          WB_NOTIFY_OK=1
        else
          echo "::warning::TG 通知发送失败（不影响任务）"
        fi
        # 倍率段独立第二条（常驻：只要取到倍率就发）：数据全量保留，不与主条挤在
        # 同一条里超限丢弃。它自带标题 + 收尾区，是可独立成篇的一条完整通知。
        # 两条之间 sleep 1s：连续 sendMessage 撞 429 会让后一条直接丢失。
        if [ -n "${WB_RATES_BLOCK:-}" ]; then
          sleep 1
          send_tg "$WB_RATES_BLOCK" alert || echo "::warning::模型倍率段独立通知发送失败（不影响任务）"
        fi
      else
        echo "⚠️ Telegram secrets missing, skip workbuddy-gateway notification."
      fi
    }

    mkdir -p "$WB_DIR" "$WB_DIR/logs" "$WB_BIN_DIR"

    # 拉取已移除（2026-10-06）：workbuddy 的 WorkingDirectory 已直指 Dropbox
    # （/dropbox/self-hosted/workbuddy-gateway），凭据/config/usage/status 全部由网关
    # 自己直写，不再需要把数据搬进 /tmp/local_workbuddy/data 这个无人读取的运行目录。
    # 原逻辑每轮在此白跑一次 rclone copy。
    echo "0. workbuddy 数据直写 Dropbox（cwd=$WB_DIR），无需拉取"

    # ---------- 1. 检查更新：比对 GitHub Releases 的 latest 版本号与本地记录 ----------
    # 查版本失败按"保持现状"处理，不因查版本失败而少启一个服务。
    # 走两条路，任一成功即可（此前只有 ①，runner 共享出口 IP 撞上匿名配额就整轮降级）：
    #   ① GitHub API（带 token 认证，配额 5000/h 而非匿名 60/h）；
    #   ② releases/latest 的 302 重定向取 tag（**不消耗 API 配额**，纯网页跳转）。
    # ② 是兜底：即便 token 缺失或 API 抖动，仍能拿到版本号，不必把失败暴露给读者。
    echo "1. Checking workbuddy-gateway release..."
    WB_REMOTE_VER=""
    _release_json="$(curl -fsSL --max-time 20 \
      -H 'Accept: application/vnd.github+json' \
      ${WB_GH_TOKEN:+-H "Authorization: Bearer ${WB_GH_TOKEN}"} \
      https://api.github.com/repos/jarvanh/workbuddy-gateway/releases/latest 2>/dev/null || true)"
    if [ -n "$_release_json" ]; then
      WB_REMOTE_VER="$(printf '%s' "$_release_json" \
        | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
        | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    fi
    if [ -z "$WB_REMOTE_VER" ]; then
      echo "ℹ️ GitHub API 未取到版本（限流或不可达），改用 releases/latest 重定向兜底..."
      _eff_url="$(curl -sL -o /dev/null -w '%{url_effective}' --max-time 20 \
        https://github.com/jarvanh/workbuddy-gateway/releases/latest 2>/dev/null || true)"
      WB_REMOTE_VER="$(printf '%s' "$_eff_url" \
        | sed -n 's#.*/releases/tag/##p' | head -n 1 || true)"
      [ -n "$WB_REMOTE_VER" ] && echo "✅ 重定向兜底取到版本：${WB_REMOTE_VER}"
    fi
    WB_LOCAL_VER="$(head -n 1 "$WB_VER_FILE" 2>/dev/null || true)"

    # WB_STATE = 部署结论（是否发生了更新），WB_REASON = 只在异常/降级时给的原因，
    # WB_UPDATE = 更新说明（「已在最新版」这类正常结论不写进「原因」，避免
    # 「原因：已在最新版」这种把正常状态说成故障的写法）。
    WB_STATE=""
    WB_REASON=""
    WB_UPDATE=""
    if [ -n "$WB_REMOTE_VER" ] && [ "$WB_REMOTE_VER" = "$WB_LOCAL_VER" ] && [ -x "$WB_BIN" ]; then
      WB_STATE="已就绪"
      WB_UPDATE="已在最新版 ${WB_LOCAL_VER} · 跳过下载"
      echo "✅ 本地已是最新版（${WB_LOCAL_VER}），跳过下载"
    else
      if [ -n "$WB_REMOTE_VER" ]; then
        echo "⬇️ 发现新版本 ${WB_REMOTE_VER}（本地 ${WB_LOCAL_VER:-未安装}），开始下载..."
      else
        echo "⚠️ 无法读取 release 版本（GitHub API 不可达或限流），按当前可用版本部署"
      fi
      # 下载到本地盘的临时文件再原子替换：中途失败不会留下半个二进制
      WB_TMP_BIN="$WB_BIN_DIR/.workbuddy-gateway.new"
      if curl -fsSL --max-time 300 -o "$WB_TMP_BIN" "$WB_RELEASE_BASE/workbuddy-gateway-linux-amd64"; then
        chmod 755 "$WB_TMP_BIN"
        if [ -s "$WB_TMP_BIN" ]; then
          mv -f "$WB_TMP_BIN" "$WB_BIN"
          # mv 保留源文件模式；上面的 chmod 755 只作用于 .new 临时文件。
          # 这里对最终路径再补一次，防「临时文件权限被外部改回」等异常路径。
          chmod +x "$WB_BIN" 2>/dev/null || true
          if [ -n "$WB_REMOTE_VER" ]; then
            printf '%s\n' "$WB_REMOTE_VER" > "$WB_VER_FILE"
            if [ -n "$WB_LOCAL_VER" ]; then
              WB_STATE="已更新"
              WB_UPDATE="从 ${WB_LOCAL_VER} 更新到 ${WB_REMOTE_VER}"
            else
              WB_STATE="已安装"
              WB_UPDATE="首次安装 ${WB_REMOTE_VER}"
            fi
          else
            WB_STATE="已就绪"
            WB_REASON="版本号查询失败（GitHub API 不可达或限流），以现有二进制运行"
          fi
        else
          WB_STATE="下载失败"
          WB_REASON="下载产物为空"
        fi
      else
        rm -f "$WB_TMP_BIN" 2>/dev/null || true
        WB_STATE="下载失败"
        WB_REASON="GitHub Releases 下载失败"
      fi
      rm -f "$WB_TMP_BIN" 2>/dev/null || true
    fi

    WB_VER="$(head -n 1 "$WB_VER_FILE" 2>/dev/null || true)"
    echo "WB_STATE=${WB_STATE:-未知}" >> "$WB_META"
    echo "WB_VERSION=${WB_VER}" >> "$WB_META"
    printf 'WB_UPDATE=%s\n' "$WB_UPDATE" >> "$WB_META"
    printf 'WB_REASON=%s\n' "$WB_REASON" >> "$WB_META"

    # ---------- 1b. 二进制真源 = GitHub Releases（2026-09-29 v2，真源唯一化） ----------
    # 升级流程唯一正确的顺序：
    #   ① 发版：push v* tag → workbuddy-gateway 的 release.yml 自动构建并发布正式产物；
    #   ② 本步骤从 GitHub Releases 拉「正式产物」上线（绝不本地编译直上，本机曾因此
    #      出现 v1.14.11 这种官方没有的非正式版本号，无法追溯）。
    #   ③ 无需任何「回推」：setup-env.sh 的自愈（v7 起）同样直拉 GitHub
    #      releases/latest，二进制单一真源；Dropbox 只存数据，不存二进制。
    # 历史：自愈源曾是 Dropbox -current，「上线新版 → 忘记回推 → 重启回退」
    # （2026-09-29 18:25 事故）先以回推方案修补（dd04030），后按主人拍板改为
    # 自愈同源直拉 GitHub，回推整体移除 —— 真源唯一化才是根治。
    # ---------- 2. 启动 serve ----------
    # 注意：workbuddy-gateway 上游 -port 默认值是 8317。2026-10-11 起 OpenClaw 主
    # AI 网关为 OmniRoute（20128），8317 已不再被占用；workbuddy 自 2026-09 起按
    # 8318 运行，为避免客户端配置漂移保持不变，故这里仍显式传 -port 8318 覆盖。
    # 通知里的「接口」写实际绑定端口。
    WB_PORT="8318"
    WB_API="http://127.0.0.1:${WB_PORT}"
    echo "2. Starting workbuddy-gateway serve on ${WB_PORT} (systemd --user 托管)..."
    echo "   preflight: binary=$WB_BIN"
    ls -l "$WB_BIN" 2>&1 || true
    # 权限位自愈（2026-09-26 事故加固）：二进制存在但丢了 +x 时，systemd 会以
    # 203/EXEC 反复重启（当晚 23:05-23:15 崩溃循环 8 分钟，根因是手工 mv 了一个
    # 0644 的临时产物进来）。下载分支的 chmod 管不到「非下载路径」写入的二进制，
    # 故启动前统一补一次 +x：仅在「存在且不可执行」时动手，幂等、无副作用。
    if [ -f "$WB_BIN" ] && [ ! -x "$WB_BIN" ]; then
      chmod +x "$WB_BIN" 2>/dev/null || true
      echo "🔧 二进制缺可执行位，已补回：$WB_BIN"
    fi
    if [ ! -x "$WB_BIN" ]; then
      echo "❌ 二进制不可执行：$WB_BIN（下载失败或权限位丢失）"
    fi
    # serve 的工作目录是 Dropbox（WB_DIR，2026-10-06 起数据直写：凭据/状态/缓存/logs 都落这里），
    # 二进制在本地盘 WB_BIN_DIR；unit 真源 services.sh（WorkingDirectory=WB_DIR）。
    # 托管交给 services.sh（systemd --user + Restart=always）：窗口期内进程崩溃
    # 由 systemd 秒级拉起，不再依赖下一轮 run。ensure 语义 = 写单元 + 每轮重启，
    # 与本步骤原先的 pkill + nohup 等价；停止必须走 systemctl（见收尾 3b 注释）。
    # ⚠️ 2026-10-07 事故修复：此处曾残留旧门闸 cd "$WB_RUN_DIR"（/tmp/local_workbuddy/data）。
    #    数据直写迁移（2026-10-06）后该目录不再创建，runner 重启清空 /tmp 后 cd 必败 →
    #    ensure 被跳过 → systemd 单元缺失、服务起不来（告警「无法进入运行目录」）。
    #    ensure 无前置条件，直接执行。
    bash "$GITHUB_WORKSPACE/.github/scripts/services/services.sh" ensure workbuddy || true

    # 健康检查：GET /health 返回任意 HTTP 响应码即视为已监听。
    # 就绪后再校验进程是否还在：进程若已崩，端口可能短暂由 TIME_WAIT/旧进程占用，
    # 只看 HTTP 会把「刚起来就退出」判成成功（凭据缺失时网关会打警告并退出）。
    WB_READY=0
    WB_API_DEAD=0
    for i in $(seq 1 60); do
      _code="$(curl -s --connect-timeout 2 -o /dev/null -w '%{http_code}' "${WB_API}/health" || true)"
      if [ -n "$_code" ] && [ "$_code" -ge 100 ] && [ "$_code" -lt 600 ]; then
        WB_READY=1
        echo "✅ [workbuddy-gateway] ${WB_PORT} 已就绪 (HTTP ${_code})"
        break
      fi
      # 进程已不在（二进制缺失 / 启动即退出）→ 早退，不再空等满 120 秒
      if ! pgrep -f "$WB_BIN serve" >/dev/null 2>&1; then
        WB_API_DEAD=1
        echo "❌ [workbuddy-gateway] serve 进程已退出，停止等待"
        break
      fi
      echo "⏳ [workbuddy-gateway] 等待中... ${i}/60"
      sleep 2
    done

    WB_ACCOUNTS=""
    WB_STATUS_RAW="$(grep -a '账号池' "$WB_LOG" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$WB_STATUS_RAW" ]; then
      WB_ACCOUNTS="$(printf '%s' "$WB_STATUS_RAW" | sed 's/.*账号池[:：][[:space:]]*//' || true)"
    fi
    echo "WB_READY=${WB_READY}" >> "$WB_META"
    printf 'WB_ACCOUNTS=%s\n' "$WB_ACCOUNTS" >> "$WB_META"

    # 凭据清单：只取文件名（真实 token 绝不回显）。serve 自动发现 cwd 下
    # workbuddy*.json 组池，这份清单就是它实际加载的凭据集合。
    WB_CREDS="$(cd "$WB_DIR" 2>/dev/null && ls -1 workbuddy*.json 2>/dev/null \
      | grep -v '^workbuddy-status\.json$' || true)"

    # 逐账号明细走 serve 写出的状态快照 workbuddy-status.json（JSON，jq 直接取）。
    # 此前用 `status` 子命令的文本输出，理由是「有 README 文档」——那个判断是错的：
    #   1. 文本输出是对齐排版的给人看的表格，字段名后跟多个空格、`过期时间` 独立成行，
    #      解析要靠 trim + 逐行匹配，脆且易漏（本轮已踩过）；
    #   2. 快照的键名其实**是稳定的**——它由上游 Go 结构体 accountSnapshot 的
    #      json tag 固定（path/edition/state/tokenExpiresAt/quotaRemaining/
    #      isPaidUser/quotaKnown/freeModels/modelCooldowns…），比文本表格更可靠。
    # 故改用 jq 取快照。字段语义照 accountSnapshot 与 monitor 表格：
    #   state: active|cooldown|paid_exhausted|expired|disabled → 可用/冷却/付费耗尽/已过期/失效
    #   quotaKnown 为 false 时额度三项无意义（monitor 显示 "-"），此处显示「未获取」
    #   quotaRemaining 按上游 formatQuota（两位小数、去尾零）
    WB_STATUS_JSON="$WB_DIR/workbuddy-status.json"

    # 免费模型名单：三路并集（见下方 siteKnownFree 说明），目录接口只是其中一路。
    # 目录接口：GET {Base}/v2/enterprises/personal/models
    #   国内站 Base=https://copilot.tencent.com，国际站 Base=https://www.workbuddy.ai
    #   站点由凭据文件的 edition 决定（cn/缺失 → 国内，intl → 国际），必须逐账号分别请求。
    # 免费判据照上游 siteKnownFree —— 它是**三路并集**，缺一路就会漏报：
    #   ① 实测 verdict=free（wb-models-cache.json 的 probes）
    #   ② 运行时 modelStates[model].costClass == free（快照里，探针观测落库）
    #   ③ 目录接口明确 0.00x（credits 解析出倍率、生效倍率 0、促销未过期）
    # 此前只实现了 ③：实测免费但**不在目录里**的模型就永远不显示
    # （deepseek-v4.1-flash 即此形态 —— 被探针标 free，却不在
    #  /v2/enterprises/personal/models 返回的 18 个模型里）。
    # ②① 都取自 serve 写出的快照/缓存，无需额外请求，故直接补进名录。
    # 生效倍率 = credits（baseMultiplier），命中**有效**促销再乘 factor（factor == 0 即 promoFree）。
    #   解析不出或倍率 > 0 → 不算免费（别把未知当免费）。
    # 这条接口只读：不产生真实 chat 请求、不消耗额度、不改变账号状态
    #   （与已废弃的 /admin/probe 相反 —— 它逐账号×逐模型串行发真实请求，
    #    44 模型 × 4 账号实测 634 秒，超过 serve 的 WriteTimeout=300 秒而被截断）。
    # 结果只用于展示，不写回快照（快照由 serve 独占重写，外部写会被覆盖）。
    # 失败不阻塞：拿不到名单就退回快照的免费模型计数（降级，绝不编造名字）。
    # 凭据直读凭据文件取 accessToken（serve 的加载源就是同一批文件），不落盘、不回显。
    # 逐账号记录「目录接口是否取到」：静默失败与「确实没有免费模型」必须区分，
    # 否则接口一挂就会把每个账号都渲染成「免费模型 0」，把故障谎报成结论。
    # 用「已成功拉取过目录的账号数 == 凭据数」判定名录是否完整可信。
    WB_FREEMAP="$(mktemp)"
    WB_FREE_OK_ACC=0
    WB_FREE_TOTAL_ACC=0
    if [ "$WB_READY" = "1" ]; then
      while IFS= read -r _cf; do
        [ -z "$_cf" ] && continue
        WB_FREE_TOTAL_ACC=$((WB_FREE_TOTAL_ACC + 1))
        _fp="$WB_DIR/$_cf"
        [ -r "$_fp" ] || continue
        _tok="$(jq -r '.auth.accessToken // ""' "$_fp" 2>/dev/null || true)"
        [ -z "$_tok" ] && continue
        _uid="$(jq -r '.account.uid // ""' "$_fp" 2>/dev/null || true)"
        _eid="$(jq -r '.account.enterpriseId // ""' "$_fp" 2>/dev/null || true)"
        _dom="$(jq -r '.auth.domain // ""' "$_fp" 2>/dev/null || true)"
        _ed="$(jq -r '.edition // "cn"' "$_fp" 2>/dev/null || true)"
        case "$(printf '%s' "$_ed" | tr 'A-Z' 'a-z')" in
          intl|international|global|workbuddy.ai) _base="https://www.workbuddy.ai" ;;
          *) _base="https://copilot.tencent.com" ;;
        esac
        _hdr=(-H "Authorization: Bearer ${_tok}"
              -H 'X-Client-ID: codebuddy-cli'
              -H 'X-Client-Version: 2.143.1'
              -H 'X-Product: SaaS')
        [ -n "$_uid" ] && _hdr+=(-H "X-User-Id: ${_uid}")
        [ -n "$_eid" ] && _hdr+=(-H "X-Enterprise-Id: ${_eid}")
        [ -n "$_dom" ] && _hdr+=(-H "X-Domain: ${_dom}")
        _cat="$(curl -s --connect-timeout 5 --max-time 30 "${_hdr[@]}" \
          "${_base}/v2/enterprises/personal/models" 2>/dev/null || true)"
        if ! printf '%s' "$_cat" | jq -e '.data.models' >/dev/null 2>&1; then
          echo "⚠️ ${_cf}: 模型目录接口无有效响应（本账号免费名单留空）"
          continue
        fi
        WB_FREE_OK_ACC=$((WB_FREE_OK_ACC + 1))
        # 免费判据（照上游 parseLiveCatalog + siteKnownFree 逐条对齐）：
        #   credits 解析出 base 倍率；命中「已启用且在有效期内」的促销则乘 factor；
        #   最终倍率为 0 才计入免费名单。促销过期/未生效都不算免费。
        # 字段名照**实测**响应逐条核过，别照文档/直觉写：
        #   响应带信封 → 目录在 .data.models / .data.modelPromotions（顶层取不到）；
        #   credits 形如 "x0.79 credits" / "x0.00"，前缀是 x 不是后缀；
        #   促销的模型列表是 modelIds（小写 d），倍率在 discount.factor（不在顶层）。
        printf '%s' "$_cat" | jq -r --arg fn "$_cf" '
          (.data.modelPromotions // []) as $promos
          | (.data.models // [])[]
          | (.id // "") as $_raw
          | ($_raw | ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $_id
          | select($_id != "")
          | ( .credits
              | if . == null then null
                elif type == "number" then .
                elif type == "string" then
                  ( gsub("[Cc]redits?"; "") | gsub("[[:blank:]]"; "") | sub("^[xX]"; "")
                    | try tonumber catch null )
                else null end ) as $_base
          | ( $promos
              | map(select(((.modelIds // []) | map(ascii_downcase) | index($_id)) != null)) ) as $_mine
          | ( $_mine
              | map(select(.enabled == true))
              | map(select(
                  ((.schedule.validFrom // "") == "" or .schedule.validFrom <= (now | todate))
                  and ((.schedule.validUntil // "") == "" or .schedule.validUntil >= (now | todate))))
              | sort_by(.discount.factor // 1) | .[0] ) as $_active
          # 生效倍率照上游 parseLiveCatalog 逐条对齐：
          #   命中**生效**促销 → 乘 factor；factor == 0 即免费（此时 credits 解析不出也算免费，
          #   上游此时直接取 factor 作倍率，故不能因 base 为 null 就判未知）；
          #   有促销但**未生效/已过期/已停用** → 上游一律记 PromoExpired，而 siteKnownFree
          #   要求 !PromoExpired，故都不算免费（上游常把促销价固化在 credits 里，
          #   过期后 credits 不可信）。注意判据要拿**全部**促销比，不能只看 enabled 的。
          #   无促销 → 用 credits 原价，解析不出即未知。
          | ( if $_active != null then
                (($_active.discount.factor // 1) as $_f
                 | if $_f == 0 then 0
                   elif $_base == null then null
                   else ($_base * $_f) end)
              elif ($_mine | length) > 0 then null
              else $_base
              end ) as $_mult
          | select($_mult != null and $_mult == 0)
          | "\($fn)\t\($_id)"
        ' 2>/dev/null >> "$WB_FREEMAP" || true
      done <<< "$WB_CREDS"

      # 补齐 siteKnownFree 的另外两路（② 运行时实测、① 探针 verdict）。
      # 这两路都取自 serve 自己写出的文件，不需要额外请求、不消耗额度：
      #   ② modelStates[model].costClass == free —— 逐账号的实测观测；
      #   ① wb-models-cache.json 的 probes[site|model].verdict == free —— 逐站点的实测结论，
      #      站点级，需按账号 edition 展开到该站点的每个账号（上游 siteKnownFree 正是按站点判）。
      # 为什么必须补：目录接口只返回**当前在售**的模型，实测免费但已下架/未在列的模型
      # （deepseek-v4.1-flash）在目录里根本取不到，只走 ③ 就会漏报（本轮实测少报一半）。
      WB_CACHE="$WB_DIR/wb-models-cache.json"
      # 缓存缺失时 jq --slurpfile 会报错（且引用未定义的 $cache 会直接编译失败），
      # 故缺失就用一个临时空对象顶上：只走 ②（modelStates 在快照里，仍覆盖实测免费），
      # 探针那一路自然为空，而不是整段不产出。
      WB_CACHE_SRC="$WB_CACHE"
      if [ ! -r "$WB_CACHE_SRC" ]; then
        WB_CACHE_SRC="$(mktemp)"
        printf '{}' > "$WB_CACHE_SRC"
      fi
      if [ -r "$WB_STATUS_JSON" ]; then
        jq -r --slurpfile cache "$WB_CACHE_SRC" '
          ((($cache[0].probes) // {}) | to_entries
            | map(select(.value.verdict == "free"))
            | map({ key: (.key | split("|") | .[0]), value: (.key | split("|") | .[1]) })
            | group_by(.key)
            | map({ key: .[0].key, value: [.[].value] })
            | from_entries) as $probesBySite
          | .accounts[]?
          | (.path | split("/") | last) as $fn
          | (.edition // "cn") as $site
          | [ (.modelStates // {}) | to_entries[] | select(.value.costClass == "free") | .key ]
            + ($probesBySite[$site] // [])
          | unique[]
          | "\($fn)\t\(.)"
        ' "$WB_STATUS_JSON" 2>/dev/null >> "$WB_FREEMAP" || true
      fi
      # 三路可能命中同一模型（如 hy3 同时被目录与实测判定），按 (账号, 模型) 去重，
      # 否则渲染层会输出「hy3 · hy3」。
      sort -u -o "$WB_FREEMAP" "$WB_FREEMAP" 2>/dev/null || true
    fi
    # 名录完整可信 ⇔ 每个凭据都成功取到目录（含「成功但 0 个免费」的账号）
    WB_FREE_READY=0
    if [ "$WB_READY" = "1" ] && [ "$WB_FREE_TOTAL_ACC" -gt 0 ] \
       && [ "$WB_FREE_OK_ACC" -eq "$WB_FREE_TOTAL_ACC" ]; then
      WB_FREE_READY=1
    fi
    WB_POOL=""
    if [ "$WB_READY" = "1" ]; then
      if [ -r "$WB_STATUS_JSON" ]; then
        # serve 每 3 秒重写该文件，读到半截会解析失败 —— 失败就本轮留空，
        # 不发半条（下一轮接力会自动补上），也绝不因此判定服务未就绪。
        # 8 列 TSV：名录可信标记 凭据文件名 站点 状态 额度 免费模型名(· 分隔) 模型冷却 Token 过期
        # 第 1 列刻意放**最前**且恒非空：`read` 会把连续制表符折叠成一个
        # （制表符属 IFS 空白），中间列一旦为空，后面的列就整体左移、
        # 错位嫁接到前一个变量上。第 1 列就把错位挡在门外。
        # 但「首列非空」**不足以**保护中间列：第 6 列（免费模型名）与第 7 列（模型冷却）
        # 都可能为空且相邻，一旦如此，后面的值会整体左移、把「模型冷却」当成模型名渲染
        # （已实测复现：输出「免费模型 1 · <code>2</code>」，2 是冷却数不是模型）。
        # 故**所有列一律不留空**：空值统一填哨兵「-」，渲染层再把哨兵还原成「跳过」。
        WB_POOL="$(TZ=Asia/Shanghai jq -r --argjson ready "${WB_FREE_READY:-0}" '
          def fq: if . > -0.005 and . < 0.005 then "0"
                  else (. * 100 | round / 100 | tostring) end;
          # 账号状态中文化：active 是**常态**，映射成空串（渲染层不显示）——
          # 主人 2026-10-06 要求去掉条目行的「· 可用」（6 个号每个都挂一遍纯占版面，
          # 且与看板 board.py 同口径：只露异常）。冷却/付费耗尽/已过期/失效仍要露出。
          def state_cn:
            if   . == "active"         then ""
            elif . == "cooldown"       then "冷却"
            elif . == "paid_exhausted" then "付费耗尽"
            elif . == "expired"        then "已过期"
            elif . == "disabled"       then "失效"
            else . end;
          def or_dash: if . == null or . == "" then "-" else . end;
          ( $wbraw | split("\n")
            | map(split("\t"))
            | map(select(length >= 2))
            | map({ key: .[0], value: .[1] })
            | group_by(.key)
            | map({ key: .[0].key, value: (map(.value) | join(" · ")) })
            | from_entries ) as $free
          | .accounts
          | to_entries
          | sort_by([
              # 账号池排序（2026-10-26 主人定，与看板小程序 sortAccounts 同规则）：
              # 站点（国内站在前）→ D 账号 → 数字账号升序 → 其他保持原序。
              # 文件名形如 workbuddy-131.json / workbuddy-D.json。
              (if .value.edition == "intl" then 1 else 0 end),
              ( (.value.path | split("/") | last
                 | ltrimstr("workbuddy-") | rtrimstr(".json")) as $n
                | if ($n | test("^[Dd]($|[^A-Za-z])")) then [0, 0]
                  elif ($n | test("[0-9]{3,}")) then [1, (($n | capture("(?<x>[0-9]{3,})").x) | tonumber)]
                  else [2, 0] end ),
              .key
            ])
          | .[].value
          | (.path | split("/") | last) as $_fn
          # 模型级冷却的「最早恢复」时刻：遍历 modelStates 取所有 cooldownUntil 的
          # 最小值（= 至少有一个模型先可用）。换算成东八区 HH:MM（jq 前固定 TZ=Asia/Shanghai
          # + strflocaltime；此前 strftime 恒按 UTC 渲染，通知时间比北京早 8 小时）。
          # 冷却普遍是分钟级，跨天时只给 HH:MM 也够用，故不标日期（标了会把子行撑爆）。
          # 正在冷却的**具体模型名**（主人 2026-10-06 要求：别只报数量）：
          # 从 modelStates 的 key 取，只保留 cooldownUntil > now 的（已过期的冷却不算，
          # 否则会写出一条早已恢复的冷却，与「可用」自相矛盾）。
          | ( [ (.modelStates // {}) | to_entries[]
                | select((.value | type) == "object")
                | select((.value.cooldownUntil // 0) > now) ] ) as $_cdmpairs
          | ( [ $_cdmpairs[] | .key ] | sort ) as $_cdms
          # 最早恢复时刻：只从**仍在冷却**的条目里取最小值（此前取所有 >0 的，
          # 含已过期项 → 会渲染出过去的恢复时刻）。
          | ( [ $_cdmpairs[] | .value.cooldownUntil ] | min ) as $_mc
          | [
              ($ready | tostring),
              ($_fn | or_dash),
              (if .edition == "intl" then "国际站" else "国内站" end),
              (.state | state_cn | or_dash),
              # 账号级冷却时刻：只在 state=cooldown 时展示。cooldownUntil 是
              # omitempty，其他状态下即便残留也不展示 —— 免得与「可用」自相矛盾。
              (if .state == "cooldown" and ((.cooldownUntil // 0) > 0)
                 then ("冷却 " + (.cooldownUntil | strflocaltime("%Y-%m-%d %H:%M")))
               else "" end | or_dash),
              # 额度行只留额度（主人 2026-10-06 要求去掉「· 免费/付费」后缀：
              # 该属性由下方「免费模型 N · 模型名」子行表达，两处重复纯占版面）
              (if .quotaKnown then ("额度剩 " + (.quotaRemaining | fq))
               else "额度未获取" end),
              ($free[$_fn] // "" | or_dash),
              # 模型冷却：**具体模型名** + 最早恢复时刻（缺一不写半截）
              (if ($_cdms | length) > 0
                 then ("模型冷却 " + ($_cdms | join(" · "))
                       + (if ($_mc // 0) > 0
                            then (" · 最早 " + ($_mc | strflocaltime("%H:%M")) + " 恢复")
                          else "" end))
               else "" end | or_dash),
              (if (.tokenExpiresAt // 0) > 0 then ("过期 " + (.tokenExpiresAt | strflocaltime("%Y-%m-%d %H:%M"))) else "" end | or_dash)
            ]
          | @tsv
        ' --rawfile wbraw "$WB_FREEMAP" "$WB_STATUS_JSON" 2>/dev/null || true)"
        if [ -z "$WB_POOL" ]; then
          echo "⚠️ workbuddy-status.json 解析失败（多为读到 serve 正在重写的半截文件），本轮账号池明细留空"
        fi
      else
        echo "⚠️ 未找到 $WB_STATUS_JSON（账号池明细本轮留空）"
      fi
    fi

    # 倍率段数据源（三路合并、实测优先）：不做任何模型名过滤，全部列出。
    #   目录价  ：wb-models-cache.json 的 catalogs.<站点>[].multiplier（已含促销）
    #   站点汇总：status 顶层 models 数组的 cnMultiplier/intlMultiplier（每模型×每站点）
    #   免费实测：运行时 modelStates.costClass==free（逐账号按站点归集）
    #             + 探针 probes[site|model].verdict==free（站点级）
    # 只看目录会漏模型（实测缺口）：glm-5.3-flash 在 cn 目录 multiplier=null、
    # hy4-preview-f 在 cn 目录根本没有 —— 靠站点汇总表补齐；
    # deepseek-v4.1-flash 目录标 0.03 但 intl 账号实测免费 —— 实测优先于目录价。
    #
    # 不按 fromLive 分组（主人 08:06 要求取消）：所有模型混在一组、按倍率升序，
    # 只保留站点分组（国内站 / 国际站）。fromLive 不再参与取数、排序与渲染。
    WB_RATES_CAT="$(mktemp)"; WB_RATES_MODELS="$(mktemp)"; WB_RATES_FREE="$(mktemp)"
    if [ -n "${WB_CACHE:-}" ] && [ -r "$WB_CACHE" ]; then
      # 4 列：站点 / 倍率 / 归一键 / 显示名
      jq -r '
        (.catalogs // {}) | to_entries[] as $e | $e.value[]?
        | select((.multiplier // null) != null)
        | ((.id // "") | ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $_id
        | select($_id != "")
        | "\($e.key)\t\(.multiplier)\t\($_id)\t\(.id // $_id)"' "$WB_CACHE" 2>/dev/null > "$WB_RATES_CAT" || true
    fi
    if [ -n "${WB_STATUS_JSON:-}" ] && [ -r "$WB_STATUS_JSON" ]; then
      # 全字段防御：edition/modelStates/key 遇非字符串会报
      # explode input must be a string（实测复现）→ 整段静默丢失；
      # serve 每 3s 重写本文件，读到半截时结构异常 —— tostring + type 守卫
      # 对任何脏数据免疫；真读到坏文件时本轮免费路降级为空（下轮自然恢复）。
      # 3 列：站点 / FREE / 模型
      jq -r '
        (.accounts // [])
        | (if type == "array" then .[] else empty end) | objects
        | ((.edition // "cn") | tostring | ascii_downcase) as $ed
        | (if ($ed | test("intl|global|workbuddy")) then "intl" else "cn" end) as $site
        | (.modelStates // {})
        | (if type == "object" then to_entries else empty end)
        | map(select((.value | type) == "object"))
        | .[]
        | select(.value.costClass == "free")
        | (.key | tostring | ascii_downcase) as $m
        | select($m != "")
        | "\($site)\tFREE\t\($m)"' "$WB_STATUS_JSON" 2>/dev/null >> "$WB_RATES_FREE" || true
    fi
    if [ -n "${WB_CACHE:-}" ] && [ -r "$WB_CACHE" ]; then
      # 探针（站点级）：3 列
      jq -r '
        (.probes // {}) | to_entries[]
        | select(.value.verdict == "free")
        | (.key | split("|")) as $p
        | (($p[0] // "") | ascii_downcase) as $site
        | (($p[1] // "") | ascii_downcase) as $m
        | select($m != "")
        | "\($site)\tFREE\t\($m)"' "$WB_CACHE" 2>/dev/null >> "$WB_RATES_FREE" || true
    fi
    # 第三路：status 顶层 models 数组 —— serve 汇总的「每模型 × 每站点」倍率表。
    # 它覆盖目录里缺失/无倍率的条目，是国内站数据齐全的关键：
    #   glm-5.3-flash 在 cn 目录里有但 multiplier=null（被上面 != null 守卫过滤）
    #     → 这里 cnMultiplier=0.06x 补上
    #   hy4-preview-f 在 cn 目录里根本没有（0 次）
    #     → 这里 cnFree=是 / cnMultiplier=0.00x 补上
    # 来源即客户端/监视视图所用的同一张表，非我自造。
    # 4 列：站点 / 倍率或FREE / 归一键 / 显示名（与目录价同构，便于合并）
    if [ -n "${WB_STATUS_JSON:-}" ] && [ -r "$WB_STATUS_JSON" ]; then
      jq -r '
        (.models // [])
        | (if type == "array" then .[] else empty end)
        | objects
        | (.id | tostring | ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")) as $m
        | select($m != "")
        | [ { site: "cn",   raw: (.cnMultiplier // "-"),   free: (.cnFree // "-") },
            { site: "intl", raw: (.intlMultiplier // "-"), free: (.intlFree // "-") } ]
        | .[]
        | (.raw | tostring | gsub("[[:space:]]"; "") | gsub("[xX]$"; "")) as $rm
        | if (.free | tostring) == "是" then
            "\(.site)\tFREE\t\($m)\t\($m)"
          elif ($rm | test("^[0-9]+([.][0-9]+)?$")) then
            "\(.site)\t\($rm)\t\($m)\t\($m)"
          else
            empty
          end' "$WB_STATUS_JSON" 2>/dev/null > "$WB_RATES_MODELS" || true
    fi
    # 合并去重：键=站点|模型（归一小写）。取值口径 = 取最小（FREE 视为 0.00）：
    # 三路都可能给出同一键的倍率，谁更低以谁为准 —— 显示值即实际最低消耗。
    # 倍率降到 0（含实测免费）一律渲染为「免费」。
    # 输出 3 列：站点 / 排序键 / 已渲染行
    # 排序（主人 08:53 定）：站点内按倍率**升序**，价格低的排上面；
    # 免费（0.00）排各站点最前。
    WB_RATES_TXT="$(cat "$WB_RATES_CAT" "$WB_RATES_MODELS" "$WB_RATES_FREE" 2>/dev/null \
      | awk -F'\t' '
          NF >= 3 {
            k = $1 "|" $3
            # 取值口径（主人 08:45 定）：FREE 视为 0.00，与数值一起按「取最小」比较。
            # 理由：显示的就是实际最低消耗；促销/汇总表给出更低值时应以更低值为准，
            # 不再让先到（目录价）静默压掉后到的更低值。
            v = ($2 == "FREE" ? 0 : $2)
            if (!(k in mname) || v + 0 < best[k] + 0) {
              site[k] = $1; mname[k] = $3; disp[k] = ($4 != "" ? $4 : $3)
              best[k] = v + 0
            }
          }
          END {
            for (k in mname) {
              d = (k in disp) ? disp[k] : mname[k]
              if (best[k] + 0 == 0) printf "%s\t0\t  %-26s %6s\n", site[k], d, "免费"
              else printf "%s\t%s\t  %-26s %6.2fx\n", site[k], best[k], d, best[k]
            }
          }' 2>/dev/null \
      | sort -t$'\t' -k1,1 -k2,2g \
      | awk -F'\t' 'BEGIN{s=""} {
          if ($1 != s) { s=$1; printf "%s\n", ($1=="intl" ? "国际站" : "国内站") }
          printf "%s\n", $3
        }' 2>/dev/null || true)"
    rm -f "$WB_RATES_CAT" "$WB_RATES_MODELS" "$WB_RATES_FREE"
    WB_RATES_N="$(printf '%s\n' "${WB_RATES_TXT:-}" | grep -cE '^  ' || true)"
    WB_RATES_FREE_N="$(printf '%s\n' "${WB_RATES_TXT:-}" | grep -c '免费' || true)"
    WB_RATES_FREE_TAG=""
    if [ "${WB_RATES_FREE_N:-0}" -gt 0 ]; then
      WB_RATES_FREE_TAG="（含免费 ${WB_RATES_FREE_N}）"
    fi

    # ---------- 每日签到采集（2026-09-26 补）----------
    # 签到是 serve 内置后台协程 backgroundDailyCheckin 干的：**没有 CLI 子命令**
    # （--help 里确实不列）、也**不写进 workbuddy-status.json**（实测该快照无签名字段，
    # 账号键只有 path/edition/state/quota*/modelStates/freeModels/modelCooldowns 等）。
    # 唯一可观测出口就是 serve.log 的 [Checkin] 行 —— 故只能从日志解析。
    # 解析必须**对齐轮次**：只取最后一轮「开始每日签到，账号总数=N」之后的行，
    # 否则会把历史上每一轮的账号都并进来、顺序与计数全乱（首版试跑即踩：
    # 错把逐账号的「账号 X 开始每日签到」当轮次起点，结果只剩最后一个号）。
    # 日志文案由上游 Go 源码固定，实测变体（2026-09-26 从二进制 + 日志双向核对）：
    #   账号 %s 开始每日签到，站点=%s，接口=%s
    #   账号 %s 每日签到成功
    #   账号 %s 今天已经签到，本次按幂等成功处理
    #   账号 %s 每日签到失败，HTTP=%d，原因=%v
    #   本轮签到完成，总数=%d，成功=%d，今日已签=%d，失败=%d，跳过=%d
    #   下一次定时签到时间=%s
    # ⚠️ 国内站与国际站是**两条分支、两套文案**（2026-10-04 补）：
    #   gate 源码 checkinAccount 按 isCN 分流 —— 国内站打 daily-checkin 接口，
    #   国际站改跑网页 ACP 会话（2026-09-26 那版只有国内站分支，故只认得国内站文案）。
    #   国际站文案（v1.19.0 实测）：
    #   账号 %s 开始国际站每日活跃（ACP 会话），模型=%s
    #   账号 %s 国际站每日活跃完成：%d 段输出 / %d 次更新，耗时 %dms
    #   账号 %s 国际站每日活跃失败：%s；不改变账号调度状态
    # 首版只认「开始每日签到」当账号出现判据 → 5 个国际站号全被漏掉，只显示国内站 1 行，
    # 差额又被汇总层反推成「跳过 5」（网关自统计其实是 跳过=0），观感像国际站全挂。
    # 失败原因里有中文与括号，且可能很长（撑爆条目行）—— 条目里只给「⚠️ 失败」定性，
    # 完整原因可看下方「原始输出」段，不在此拼接。
    # 此处先出 3 列 TSV：凭据文件名 \t 站点 \t 签到结果（下方与活动状态接口
    # 合并成 5 列，加签到积分与旅行奖励）。列恒非空（结果缺省填「未取到结果」），
    # 避免 read 的空白折叠导致列错位（与 WB_POOL 同一坑，见其注释）。
    WB_CHECKIN=""
    WB_CHECKIN_SUMMARY=""
    WB_CHECKIN_NEXT=""
    if [ -r "$WB_LOG" ]; then
      # 下次签到时刻：serve 在**上一轮结束时**写入，时间上早于下一轮起点行，
      # 故全局取最后一次，不能被轮次窗口切掉（首版试跑被切掉 → 取空）。
      WB_CHECKIN_NEXT="$(grep -a "下一次定时签到时间=" "$WB_LOG" 2>/dev/null \
        | tail -n 1 | sed 's/.*下一次定时签到时间=//' || true)"
      # 轮次锚点（2026-10-05 修）：取**最近一轮已有完成行的轮次**的起点行，
      # 而不是无脑取最后一个起点行。原因：通知段在签到协程进行中也会被触发，
      # 进行中的轮次大量账号还没写完成行 —— 首版只认最后起点行时，进行中轮次
      # 被当成完整结果：完成行没写的账号全落「未取到结果」/缺行，再被汇总层
      # 反推成「跳过 N」（实测：镜像轮恰逢 22:50 签到轮进行中，国际站 5 个号
      # 被截成 2 行：已签 1 + 未开启 1 + 跳过 4）。取最近**已完成**轮 = 永远
      # 展示完整一轮；进行中的轮次等它写完完成行后自然接管。
      _ck_start="$(grep -an "开始每日签到，账号总数=\|本轮签到完成" "$WB_LOG" 2>/dev/null \
        | awk -F: '
            /本轮签到完成/ { if (laststart != "") done_start = laststart; next }
            { laststart = $1 }
            END { if (done_start != "") print done_start; else if (laststart != "") print laststart }' \
        || true)"
      if [ -n "$_ck_start" ]; then
        WB_CHECKIN="$(tail -n +"$_ck_start" "$WB_LOG" 2>/dev/null \
          | grep -a '\[Checkin\]' \
          | awk '
            {
              line=$0
              if (line ~ /账号 .* 开始每日签到/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 开始每日签到.*/,"",f)
                s=line; sub(/.*站点=/,"",s); sub(/，接口=.*/,"",s)
                if (f != "" && !(f in seen)) { seen[f]=1; order[++n]=f; site[f]=s }
              } else if (line ~ /账号 .* 开始国际站每日活跃/) {
                # 国际站分支（2026-10-04 补）：该行不带「站点=」字段，站点是已知的
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 开始国际站每日活跃.*/,"",f)
                if (f != "" && !(f in seen)) { seen[f]=1; order[++n]=f; site[f]="国际站" }
              } else if (line ~ / 国际站每日活跃完成/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 国际站每日活跃完成.*/,"",f)
                if (f!="") res[f]="今日活跃 ✓"
              } else if (line ~ / 国际站每日活跃失败/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 国际站每日活跃失败.*/,"",f)
                if (f!="") res[f]="⚠️ 活跃失败"
              } else if (line ~ / 每日签到成功/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 每日签到成功.*/,"",f)
                if (f!="") res[f]="签到 ✓"
              } else if (line ~ /今天已经签到/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 今天已经签到.*/,"",f)
                if (f!="") res[f]="今日已签"
              } else if (line ~ / 每日签到失败/) {
                f=line; sub(/.*\[Checkin\] 账号 /,"",f); sub(/ 每日签到失败.*/,"",f)
                if (f!="") res[f]="⚠️ 失败"
              }
            }
            END {
              for (i=1;i<=n;i++) {
                f=order[i]
                printf "%s\t%s\t%s\n", f, site[f], (res[f]=="" ? "未取到结果" : res[f])
              }
            }' 2>/dev/null || true)"
        WB_CHECKIN_SUMMARY="$(tail -n +"$_ck_start" "$WB_LOG" 2>/dev/null \
          | grep -a '本轮签到完成' | tail -n 1 \
          | sed 's/.*\[Checkin\] //; s/^本轮签到完成，//' || true)"
      fi
    fi

    # ---------- 签到积分采集（2026-09-26 补，主人要求通知里显示积分）----------
    # 网关把签到接口的响应体整个丢掉（上游 checkinAccount 只接 status/err），
    # 日志里只有「成功/已签」没有积分数值；「已签」幂等响应（code=10001）也不带积分。
    # 积分真源是独立的活动状态接口（只读、幂等、无副作用，2026-09-26 全账号实测）：
    #   POST {Origin}/v2/billing/meter/checkin-activity-status
    #   data: active / today_checked_in / today_credit(本次) / total_credits(累计)
    #         / streak_days(连签) / daily_credit(每日可得)
    # 实测口径：国内站 active=true（Buddy 加油站，+100/天）；国际站 active=false
    # （活动未开启）—— 而网关把 code=10001 一律按「今日已签」幂等成功处理，
    # 国际站其实没签上（状态接口 today_checked_in=false 佐证）。故结果列以状态
    # 接口为准修正；查询失败/无数据的账号保留网关日志结果，绝不编造积分。
    WB_CKSTAT_OK=0
    WB_CKSTAT_TOTAL=0
    declare -A _CK_ACT _CK_CHK _CK_TODAY _CK_TOTAL _CK_STREAK _CK_DAILY _CK_TRAVEL
    if [ "${WB_READY:-}" = "1" ] && [ -n "${WB_CREDS:-}" ]; then
      WB_CKTMP="$(mktemp)"
      while IFS= read -r _cf; do
        if [ -z "$_cf" ]; then continue; fi
        WB_CKSTAT_TOTAL=$((WB_CKSTAT_TOTAL + 1))
        _fp="$WB_DIR/$_cf"
        _tok=""
        if [ -r "$_fp" ]; then
          _tok="$(jq -r '.auth.accessToken // ""' "$_fp" 2>/dev/null || true)"
        fi
        if [ -z "$_tok" ]; then continue; fi
        _uid="$(jq -r '.account.uid // ""' "$_fp" 2>/dev/null || true)"
        _eid="$(jq -r '.account.enterpriseId // ""' "$_fp" 2>/dev/null || true)"
        _dom="$(jq -r '.auth.domain // ""' "$_fp" 2>/dev/null || true)"
        _ed="$(jq -r '.edition // "cn"' "$_fp" 2>/dev/null || true)"
        case "$(printf '%s' "$_ed" | tr 'A-Z' 'a-z')" in
          intl|international|global|workbuddy.ai) _base="https://www.workbuddy.ai" ;;
          *) _base="https://www.codebuddy.cn" ;;
        esac
        _hdr=(--connect-timeout 5 --max-time 20 -X POST
          -H "Authorization: Bearer ${_tok}"
          -H 'X-Client-ID: codebuddy-cli'
          -H 'X-Client-Version: 2.143.1'
          -H 'X-Product: SaaS'
          -H 'X-Client-Platform: web'
          -H 'Content-Type: application/json' -d '{}')
        if [ -n "$_uid" ]; then _hdr+=(-H "X-User-Id: ${_uid}"); fi
        if [ -n "$_eid" ]; then _hdr+=(-H "X-Enterprise-Id: ${_eid}" -H "X-Tenant-Id: ${_eid}"); fi
        if [ -n "$_dom" ]; then _hdr+=(-H "X-Domain: ${_dom}"); fi
        if curl -o "$WB_CKTMP" "${_hdr[@]}" \
          "${_base}/v2/billing/meter/checkin-activity-status" 2>/dev/null; then
          _row="$(jq -r 'if .code == 0 and (.data | type == "object") then
              [ (.data.active // false), (.data.today_checked_in // false),
                (.data.today_credit // 0), (.data.total_credits // 0),
                (.data.streak_days // 0), (.data.daily_credit // 0) ]
              | map(tostring) | @tsv
            else empty end' "$WB_CKTMP" 2>/dev/null || true)"
          if [ -n "$_row" ]; then
            IFS="$(printf '\t')" read -r _act _chk _tdy _tot _stk _dly <<< "$_row"
            if [ "$_act" = "true" ] || [ "$_act" = "false" ]; then
              WB_CKSTAT_OK=$((WB_CKSTAT_OK + 1))
              _CK_ACT["$_cf"]="$_act"
              _CK_CHK["$_cf"]="$_chk"
              _CK_TODAY["$_cf"]="$_tdy"
              _CK_TOTAL["$_cf"]="$_tot"
              _CK_STREAK["$_cf"]="$_stk"
              _CK_DAILY["$_cf"]="$_dly"
            fi
          fi
        fi
      done <<< "$WB_CREDS"
      rm -f "$WB_CKTMP"
    fi

    # Buddy 旅行奖励（仅国内站有旅行，领取成功才落一行 credit=）。
    # 窗口 = 今天（东八区）全天日志，而不是最后一轮签到窗口：旅行奖励一天最多
    # 领一次，常发生在更早的轮次（实测：启动轮 06:28 领取 credit=10.00，
    # 09:00 定时轮只报「今日派遣已达上限」）—— 按轮次窗口会漏掉当天的实际领取。
    # 日志时间戳已实测为东八区（09:00 定时轮落笔 09:00:00），与 TZ 过滤直接对齐。
    if [ -r "$WB_LOG" ]; then
      _today="$(TZ=Asia/Shanghai date +%Y/%m/%d)"
      while IFS= read -r _tl; do
        if [ -z "$_tl" ]; then continue; fi
        case "$_tl" in
          *"旅行奖励领取成功（credit="*)
            _tf="$(printf '%s' "$_tl" | sed 's/.*\[Travel\] 账号 //; s/ Buddy 已到达.*//' || true)"
            _tc="$(printf '%s' "$_tl" | sed 's/.*credit=//; s/）.*//' || true)"
            if [ -n "$_tf" ] && [ -n "$_tc" ]; then
              _CK_TRAVEL["$_tf"]="Buddy 旅行 +${_tc}"
            fi
            ;;
        esac
      done <<< "$(grep -a "^${_today} " "$WB_LOG" 2>/dev/null | grep -a '\[Travel\]' || true)"
    fi


    # 合并：状态接口修正结果列 + 拼积分/旅行列（3 列 → 5 列，渲染层只管展示）。
    # 结果优先级：网关日志判「失败」时保留原样（HTTP/原因在原始输出里，更具体）；
    # 其余以状态接口为准 —— active=false 修成「活动未开启」（网关把 code=10001
    # 一律幂等成功，国际站活动没开也被记成「今日已签」，这里纠正）。
    # ---------- 国际站「每日活跃」奖励（2026-10-06 补）----------
    # 国际站没有签到活动，活跃奖励的**真值只在 quota-board 的账本里**：
    # 每笔 `wb|<账号>` 的正向 delta，按金额众数还原每日额度（实测 30.0/天，
    # 10-01~10-06 每天一笔）。签到活动状态接口对国际站恒 active=false，
    # 查不到这笔钱 —— 首版据此把国际站写成「活动未开启 · 无积分」，与账本里
    # 实打实的 +30/天 直接矛盾。
    # 故调 board.py 的 CLI 复用**同一份**聚合代码，不在 shell 里另写一套
    # （两边各写一套必然对不齐，与 usage-ledger 走同一条路）。
    declare -A _CK_ADAILY _CK_ATOTAL _CK_ADAYS _CK_ATODAY
    if [ "${WB_READY:-}" = "1" ]; then
      while IFS="$(printf '\t')" read -r _af _adaily _adays _atotal _atoday; do
        [ -z "$_af" ] && continue
        _CK_ADAILY["$_af"]="$_adaily"
        _CK_ATOTAL["$_af"]="$_atotal"
        _CK_ADAYS["$_af"]="$_adays"
        _CK_ATODAY["$_af"]="$_atoday"
      done <<< "$(python3 /dropbox/self-hosted/quota-board/board.py active-credits 2>/dev/null || true)"
    fi

    if [ -n "${WB_CHECKIN:-}" ]; then
      WB_CHECKIN_MERGED=""
      while IFS="$(printf '\t')" read -r _mf _ms _mr; do
        if [ -z "$_mf" ]; then continue; fi
        _mres="$_mr"
        _mcred=""
        if [ -n "${_CK_ACT[$_mf]:-}" ]; then
          if printf '%s' "$_mr" | grep -q '失败'; then
            _mres="$_mr"
          elif [ "$_mr" = "未取到结果" ]; then
            # 采集层没拿到结果（结果列缺省值）：说明采集中断/缺行，不是「没签到」。
            # 不能被下面 active=false 分支降级成「活动未开启」—— 那是把
            # 「我们不知道」伪装成确定结论，且积分列全 0（实测 2026-10-05：
            # workbuddy-18 被降级后还带出了「可得 +0」假积分）。
            # 保留缺省原样如实展示（下轮日志写全自然恢复），汇总层只计「未采集」。
            _mres="$_mr"
          elif printf '%s' "$_mr" | grep -q '今日活跃 ✓'; then
            # 国际站（2026-10-04 补）：ACP 会话跑完即签到成功。积分活动 active=false
            # 只表示「这个站没有积分可领」，**不代表签到没做** —— 不能被下面的
            # 分支降级成「活动未开启」（首版会显示成活动未开启，观感像没签到）。
            # 2026-10-06 改名：原文案「活跃 ✓」脱离上下文看不出是签到，改「今日活跃 ✓」。
            _mres="$_mr"
            # 活跃奖励：真值在账本（见上方采集段）。只有**今日确实到账**
            # 才写「本次 +N」，否则只给累计 —— 避免把历史额度当成今天领的。
            _ak="$(printf '%s' "$_mf" | sed 's/^workbuddy-//; s/\.json$//')"
            if [ "${_CK_ATODAY[$_ak]:-}" = "1" ]; then
              _mcred="本次 +${_CK_ADAILY[$_ak]} · 累计 ${_CK_ATOTAL[$_ak]} · 活跃 ${_CK_ADAYS[$_ak]} 天"
            elif [ -n "${_CK_ATOTAL[$_ak]:-}" ]; then
              _mcred="累计 ${_CK_ATOTAL[$_ak]} · 活跃 ${_CK_ADAYS[$_ak]} 天"
            fi
          elif [ "${_CK_ACT[$_mf]}" = "false" ]; then
            _mres="活动未开启"
          elif [ "${_CK_CHK[$_mf]}" = "true" ]; then
            case "$_mr" in *"签到 ✓"*) : ;; *) _mres="今日已签" ;; esac
            _mcred="本次 +${_CK_TODAY[$_mf]} · 累计 ${_CK_TOTAL[$_mf]} · 连签 ${_CK_STREAK[$_mf]} 天"
          else
            _mres="未签"
            _mcred="可得 +${_CK_DAILY[$_mf]}"
          fi
        fi
        _mtrav="${_CK_TRAVEL[$_mf]:-}"
        WB_CHECKIN_MERGED+="${WB_CHECKIN_MERGED:+$'\n'}${_mf}"$'\t'"${_ms}"$'\t'"${_mres}"$'\t'"${_mcred}"$'\t'"${_mtrav}"
      done <<< "$WB_CHECKIN"
      WB_CHECKIN="$WB_CHECKIN_MERGED"

      # 汇总：状态接口全覆盖时按展示行重算（与逐账号口径一致，含积分合计）；
      # 有查询失败/无数据时退回网关日志口径的 WB_CHECKIN_SUMMARY，不硬凑。
      if [ "$WB_CKSTAT_OK" -eq "$WB_CKSTAT_TOTAL" ] && [ "$WB_CKSTAT_TOTAL" -gt 0 ]; then
        _n_signed=0
        _n_closed=0
        _n_open=0
        _n_fail=0
        _n_unk=0
        _sum_today=0
        while IFS="$(printf '\t')" read -r _sf _ss _sr _sc _st; do
          if [ -z "$_sf" ]; then continue; fi
          case "$_sr" in
            # 「今日活跃 ✓」= 国际站 ACP 会话成功（2026-10-04 补），与国内站签到同等计入已签
            *"签到 ✓"*|*"今日已签"*|*"今日活跃 ✓"*) _n_signed=$((_n_signed + 1)) ;;
            *"活动未开启"*) _n_closed=$((_n_closed + 1)) ;;
            *"未签"*) _n_open=$((_n_open + 1)) ;;
            *"失败"*) _n_fail=$((_n_fail + 1)) ;;
            *"未取到结果"*) _n_unk=$((_n_unk + 1)) ;;
          esac
        done <<< "$WB_CHECKIN"
        # 国际站活跃奖励（账本口径）：与国内站签到积分同等计入今日合计。
        # 只加「今日确实到账」的号，且只认整数，避免小数把 $(( )) 打挂。
        for _kf in "${!_CK_ATODAY[@]}"; do
          if [ "${_CK_ATODAY[$_kf]}" = "1" ]; then
            case "${_CK_ADAILY[$_kf]}" in
              ''|*[!0-9]*) : ;;
              *) _sum_today=$((_sum_today + ${_CK_ADAILY[$_kf]})) ;;
            esac
          fi
        done
        for _kf in "${!_CK_ACT[@]}"; do
          if [ "${_CK_ACT[$_kf]}" = "true" ] && [ "${_CK_CHK[$_kf]}" = "true" ]; then
            case "${_CK_TODAY[$_kf]}" in
              ''|*[!0-9]*) : ;;
              *) _sum_today=$((_sum_today + ${_CK_TODAY[$_kf]})) ;;
            esac
          fi
        done
        _n_rows="$(printf '%s\n' "$WB_CHECKIN" | grep -c . || true)"
        _n_creds="$(printf '%s\n' "$WB_CREDS" | grep -c . || true)"
        _n_skip=$((_n_creds - _n_rows))
        if [ "$_n_skip" -lt 0 ]; then _n_skip=0; fi
        _cksum="已签 ${_n_signed}"
        if [ "$_n_closed" -gt 0 ]; then _cksum="${_cksum} · 未开启 ${_n_closed}"; fi
        if [ "$_n_open" -gt 0 ]; then _cksum="${_cksum} · 未签 ${_n_open}"; fi
        if [ "$_n_fail" -gt 0 ]; then _cksum="${_cksum} · 失败 ${_n_fail}"; fi
        if [ "$_n_unk" -gt 0 ]; then _cksum="${_cksum} · 未采集 ${_n_unk}"; fi
        if [ "$_n_skip" -gt 0 ]; then _cksum="${_cksum} · 跳过 ${_n_skip}"; fi
        if [ "$_sum_today" -gt 0 ]; then _cksum="${_cksum} · 今日合计 +${_sum_today}"; fi
        WB_CHECKIN_SUMMARY="$_cksum"
      fi
    fi

    # 接力轮次的判据：本文件由「Trigger next OpenClaw run」在上一轮收尾时以
    # workflow_dispatch 接力启动（长跑保活标准形态），但接力轮同样会跑一遍本步骤，
    # 于是同一份 service 同一份账号池会**每个 run 各推一条**已就绪通知。
    # 用本步骤自己的结果文件区分（本步骤无 id、幂等引用 steps.run_workbuddy 不安全，
    # 且其结果在本步骤内不可读）：文件在 → 上一轮启动过 = 接力轮，不再发就绪通知。
    # 按标记文件失败处理（多发一条好过漏发；下次重装后自然收敛）。
    WB_RUN_TAG_FILE="/tmp/workbuddy-serve-run-tag"
    WB_RELAUNCH=0
    WB_PREV_TAG=""
    if [ -s "$WB_RUN_TAG_FILE" ]; then
      WB_RELAUNCH=1
      WB_PREV_TAG="$(head -n 1 "$WB_RUN_TAG_FILE" 2>/dev/null || true)"
    fi
    if [ "$WB_READY" = "1" ]; then
      if [ -n "$WB_ACCOUNTS" ]; then
        # 2026-10-24 主人定：就绪通知每次启动都发。services.sh ensure
        # 每轮 restart 一次，故这里不再按「接力轮」静默。
        wb_notify "🟢 workbuddy-gateway 已就绪" "$WB_ACCOUNTS" "$WB_VER" "$WB_UPDATE" "$WB_REASON" "" 1
        [ "$WB_NOTIFY_OK" = "1" ] && printf '%s\n' "${GITHUB_RUN_ID:-manual}" > "$WB_RUN_TAG_FILE"
      else
        # 网关自己起来了、但账号池为空：多半是数据目录里还没有 workbuddy*.json
        # （二维码登录只能人工做），如实标注为可用性问题，不假装就绪。
        wb_notify "⚠️ workbuddy-gateway 已启动 · 无可用账号" \
          "账号池为空 · 需人工扫码登录" "$WB_VER" "$WB_UPDATE" "$WB_REASON" "" 1
        [ "$WB_NOTIFY_OK" = "1" ] && printf '%s\n' "${GITHUB_RUN_ID:-manual}" > "$WB_RUN_TAG_FILE"
      fi
    else
      WB_TAIL="$(tg_tail_file_safe "$WB_LOG" 1200)"
      # 把日志尾部同时打到 stdout：<pre> 只进 Telegram，CI 日志里看不到，
      # 排查时不得不再跑一轮才能拿到真实报错。
      echo "--- serve.log tail (1200B) ---"
      printf '%s\n' "${WB_TAIL:-<empty>}"
      echo "--- end serve.log tail ---"
      if [ "$WB_API_DEAD" = "1" ]; then
        # 从日志尾部区分三种"起来就退"，避免一律写成"凭据/参数错误"误导排查：
        # Permission denied → 二进制不可执行（放错到非 exec 的文件系统）；
        # 未检测到有效凭据 → 账号池为空；其余归为启动即退。
        case "$WB_TAIL" in
          *"Permission denied"*)
            _wb_fail_reason="二进制不可执行（Permission denied）：须落在本地盘，rclone 挂载点无法执行文件" ;;
          *"未检测到有效凭据"*|*"login"*)
            _wb_fail_reason="未检测到有效凭据：需人工执行 login 扫码后把凭据放入数据目录" ;;
          *)
            _wb_fail_reason="serve 进程启动后立即退出（多为参数错误或上游不可达）" ;;
        esac
        echo "❌ workbuddy-gateway serve 进程启动后立即退出" >&2
      else
        _wb_fail_reason="serve 未在 120 秒内监听 ${WB_PORT}"
        echo "❌ workbuddy-gateway 未能在 120 秒内监听 ${WB_PORT}" >&2
      fi
      # WB_REASON 可能为空，拼串前先规整，避免出现「原因： serve …」的前导空格
      _wb_fail_reason="${WB_REASON:+${WB_REASON} · }${_wb_fail_reason}"
      wb_notify "❌ workbuddy-gateway 启动失败" "未监听 ${WB_PORT} · 退出码 1" "$WB_VER" \
        "$WB_UPDATE" "$_wb_fail_reason" "$WB_TAIL" 0
    fi
  )
  _up_rc=$?
  printf '%s' "$_up_rc" > /tmp/upstream-rc-workbuddy
) > /opt/logs/upstream-workbuddy.log 2>&1 &
echo "🚀 [P5b] workbuddy-gateway 已转后台部署（等齐门在 AI 网关步骤）"
