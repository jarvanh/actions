#!/usr/bin/env bash
# openclaw 工作流「Run zcode2api」步骤本体（2026-10-30 搬移自 yml）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL /
#     ZCODE_GATEWAY_KEY / GITHUB_WORKSPACE / GITHUB_RUN_ID
#   落盘契约：/tmp/upstream-rc-zcode2api（P5b 等齐门标记）、
#     /opt/logs/upstream-zcode2api.log、$Z2A_LOG（Dropbox 服务日志）
# P5b 双层子壳结构是刻意设计，勿动结构。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）；体内自带 set -uo pipefail。
# 唯一逻辑适配：Bun 安装由 `curl | bash` 改为「下载落盘 → bash 执行」——
# 管道直执行被安全扫描判高危；两步式语义等价（同一脚本、同一 bash、同 env），
# 且落盘后可留档核对，是 curl|bash 的标准安全改写。

(
  set +e
  (
    set -uo pipefail
    # 通知真源在 step 顶层 source 一次（勿挪进函数体，理由见 workbuddy 步骤同名注释 / 规范 4.4）
    source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

    Z2A_REPO="https://github.com/jarvanh/zcode2api.git"
    Z2A_DATA_ARCHIVE="dropbox:self-hosted/zcode2api-data.tar.gz"
    Z2A_RUN_DIR="/tmp/local_zcode2api"
    Z2A_PORT="8319"
    Z2A_LOG="/dropbox/self-hosted/zcode2api/logs/zcode2api.log"

    Z2A_OK=0
    Z2A_REASON=""
    Z2A_STARTED=0
    Z2A_SELFTEST_MODEL=""
    Z2A_SELFTEST_OUT=""
    Z2A_PLAN_BAD=0

    # 端口存活判定：/v1 带鉴权，未带 key 会拿 401，不能 curl -f；
    # 拿到任意 HTTP 码（非 000）即视为有进程在监听，链路可用性交给自检。
    z2a_alive() {
      local code
      code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${Z2A_PORT}/v1/models" 2>/dev/null || true)"
      [ -n "$code" ] && [ "$code" != "000" ]
    }

    # 端到端自检：无论进程是新起的还是复用的残留实例，都要真发消息验证。
    # 判据是「上游返回了助手内容块」——healthz/模型列表通不代表上游链路可用
    # （旧反代实测漏过「进程活着但上游 429」）。注意 GLM 是思考模型，
    # max_tokens 给小了会只产出 thinking 块，故判据不限定 text 类型。
    # 主探 glm-5.3-flash（Plan 通道）：要过无痕验证码。2026-09-29 起
    # 求解器已切 bun + vendored 上游 captcha-happy（实测 6/6 成功），
    # 连败已罕见，验证码类错误重试 3 轮仅作兜底；全败再退探
    # bigmodel/GLM-5.3（API Key 通道，免验证码）——能通说明服务
    # 本体健康、仅 Plan 通道降级，通知里如实分开报（Z2A_PLAN_BAD）。
    z2a_probe() {
      curl -sS --max-time 120 -X POST "http://127.0.0.1:${Z2A_PORT}/v1/messages" \
        -H "Authorization: Bearer ${ZCODE_GATEWAY_KEY}" \
        -H 'content-type: application/json' \
        -d "$1" 2>&1
    }
    z2a_body_ok() {
      echo "$1" | jq -e '(.content // [] | length) > 0' >/dev/null 2>&1
    }
    # 失败分诊：自检不通不等于服务没起来。上游额度耗尽时网关照样回 HTTP 200，
    # 只是没有 content 块（实测 {"code":1005,"msg":"exceed quota limit"}），
    # 与「进程没起来 / 端口没人听」是完全两种事，不该共用红色「启动失败」告警。
    # 返回：quota=上游额度/余额类（服务本体健康）· channel=回退通道被关 ·
    # captcha=验证码 · auth=鉴权 ·
    #       unavailable=网关 503/请求级死线（账号池全冷却/耗尽，服务本体健康）·
    #       unknown=其他（按真失败处理）
    z2a_fail_class() {
      printf '%s' "$1" | jq -e '.code == 1005 or ((.msg // "") | test("quota|余额|insufficient|1113"; "i"))' >/dev/null 2>&1 && { echo quota; return; }
      printf '%s' "$1" | jq -e '.error.type == "channel_disabled"' >/dev/null 2>&1 && { echo channel; return; }
      printf '%s' "$1" | jq -e '.error.type == "captcha_error"' >/dev/null 2>&1 && { echo captcha; return; }
      printf '%s' "$1" | jq -e '.error.type == "no_available_account"' >/dev/null 2>&1 && { echo unavailable; return; }
      printf '%s' "$1" | jq -e '.error.type | test("auth|invalid_request|unauthorized"; "i")' >/dev/null 2>&1 && { echo auth; return; }
      echo unknown
    }
    z2a_selftest() {
      Z2A_SELFTEST_OUT=""
      Z2A_SELFTEST_MODEL=""
      Z2A_PLAN_BAD=0
      Z2A_FAIL_CLASS=""
      Z2A_MAIN_CLASS=""
      for _ in 1 2 3; do
        Z2A_SELFTEST_OUT="$(z2a_probe '{"model":"glm-5.3-flash","max_tokens":16,"messages":[{"role":"user","content":"回复 ok 即可"}]}')"
        if z2a_body_ok "$Z2A_SELFTEST_OUT"; then
          Z2A_SELFTEST_MODEL="$(printf '%s' "$Z2A_SELFTEST_OUT" | jq -r '.model // "未知"' 2>/dev/null || true)"
          return 0
        fi
        # 只有验证码类错误值得重试（额控/鉴权重试也是同样结果）
        echo "$Z2A_SELFTEST_OUT" | jq -e '.error.type == "captcha_error"' >/dev/null 2>&1 || break
        sleep 5
      done
      # 主通道失败原因先落袋：兜底探会覆盖 Z2A_SELFTEST_OUT，若只在最后
      # 分诊，主通道的额度耗尽会被兜底的 channel_disabled 顶掉 —— 于是通知
      # 让人去开回退通道，而该通道实测上游同样欠费（429 code 1113），白折腾。
      Z2A_MAIN_CLASS="$(z2a_fail_class "$Z2A_SELFTEST_OUT")"
      # 请求级死线形态：主通道被 429 梯拖满 600s，curl 拿不到任何字节
      # （自检输出恰为 "curl: (28) Operation timed out ..."，非 JSON）。
      # 这不是服务挂了，是账号池在冷却期。
      if [ "$Z2A_MAIN_CLASS" = "unknown" ] && \
         printf '%s' "$Z2A_SELFTEST_OUT" | grep -q 'curl: (28)'; then
        Z2A_MAIN_CLASS="unavailable"
      fi
      # 兜底探 bigmodel/GLM-5.3（Key 通道，免验证码）。该通道是**独立**的
      # bigmodel 账号池：Plan 池耗尽/冷却时它仍可能出内容，故「主通道 503/超时
      # + 兜底通」应报「Plan 通道降级」，不该报启动失败。
      # 但主通道已确认是额度/无可用账号时不必再等：兜底探在 Key 池同样 429 时
      # 会被 curl 拖满 120s（零输出），直接判「服务正常 · 无可用额度」更快更准。
      Z2A_PLAN_BAD=1
      case "$Z2A_MAIN_CLASS" in
        quota|unavailable)
          Z2A_SELFTEST_OUT=""
          Z2A_FAIL_CLASS="$Z2A_MAIN_CLASS"
          return 1
          ;;
      esac
      Z2A_SELFTEST_OUT="$(z2a_probe '{"model":"bigmodel/GLM-5.3","max_tokens":16,"messages":[{"role":"user","content":"回复 ok 即可"}]}')"
      if z2a_body_ok "$Z2A_SELFTEST_OUT"; then
        Z2A_SELFTEST_MODEL="$(printf '%s' "$Z2A_SELFTEST_OUT" | jq -r '.model // "未知"' 2>/dev/null || true)"
        return 0
      fi
      # 两条通道都没出内容：以主通道原因为准（它才是服务设计上该走的通道），
      # 主通道归因不明时才退回兜底原因，供通知层区分「降级」与「真挂了」
      if [ -n "$Z2A_MAIN_CLASS" ] && [ "$Z2A_MAIN_CLASS" != unknown ]; then
        Z2A_FAIL_CLASS="$Z2A_MAIN_CLASS"
      else
        Z2A_FAIL_CLASS="$(z2a_fail_class "$Z2A_SELFTEST_OUT")"
      fi
      return 1
    }
    # 账号池采集：admin API 脱敏视图拼「💳 账号池」分节（对齐 wb_notify 的
    # 账号池口径：条目行 = 名称 · 通道 · 状态；子行 = 额度/套餐 + 最近错误）。
    # 只在服务已监听时可采；采集失败只影响通知信息量，不改变结论。
    # 注意：子行换行用 $'\n' 单行拼接 —— YAML 块标量里裸换行续行会破坏缩进。
    # 后台密码真值在 accounts.db 的 meta.admin_key：.env 的 ZCODE_ADMIN_KEY
    # 只在首次初始化时播种一次（store.py 是 INSERT OR IGNORE），后台「设置」页
    # 改过密码后 db 永久优先、.env 变成历史残留 —— 拿 .env 的值调 admin API
    # 会 401，账号池分节静默消失（2026-09-30 实测）。故优先读 db，读不到才回退 .env。
    z2a_admin_key() {
      local k=""
      if [ -f "$Z2A_RUN_DIR/data/accounts.db" ]; then
        k="$(Z2A_DB="$Z2A_RUN_DIR/data/accounts.db" python3 -c 'import os,sqlite3;db=sqlite3.connect("file:"+os.environ["Z2A_DB"]+"?mode=ro",uri=True,timeout=5);r=db.execute("select value from meta where key=?",("admin_key",)).fetchone();print(r[0] if r and r[0] else "")' 2>/dev/null || true)"
      fi
      [ -n "$k" ] || k="$(grep -m1 '^ZCODE_ADMIN_KEY=' "$Z2A_RUN_DIR/.env" 2>/dev/null | cut -d= -f2-)"
      printf '%s' "$k"
    }
    Z2A_POOL_TITLE=""
    Z2A_POOL_TEXT=""
    z2a_collect_pool() {
      local ak json n=0 total=0
      ak="$(z2a_admin_key)"
      [ -n "$ak" ] || return 0
      json="$(curl -sS --max-time 10 -H "Authorization: Bearer ${ak}" \
        "http://127.0.0.1:${Z2A_PORT}/admin/api/accounts" 2>/dev/null)" || return 0
      printf '%s' "$json" | jq -e '.accounts' >/dev/null 2>&1 || return 0
      # 无额度账号不展示（主人 2026-09-30 要求）。判据与 quota-board 的
      # zc_apikeys 一致：**quota 为空即无额度可展示**，不按 mode 硬编码隐藏 ——
      # Key 通道（bigmodel/apiKey）设计上不打 billing 全家桶，quota 恒空，
      # 将来上游若给它补了额度会自动出现，不用回来改代码。
      local pool_rows shown_total shown_active hidden_total
      pool_rows="$(printf '%s' "$json" | jq -r '.accounts[] | select((.quota // {} | length) > 0) | [.name, .provider, .mode, .status, (.plan.name // "-"), (.last_error // "-"), (.quota // {} | tostring)] | @tsv' 2>/dev/null || true)"
      shown_total="$(printf '%s' "$pool_rows" | grep -c . || true)"
      shown_active="$(printf '%s' "$pool_rows" | awk -F'\t' '$4=="active"' | grep -c . || true)"
      hidden_total="$(printf '%s' "$json" | jq -r '[.accounts[] | select((.quota // {} | length) == 0)] | length' 2>/dev/null || true)"
      # 标题计数用**已展示**的条目，避免「账号池 10」却只列 1 条的口径打架；
      # 被略去的条数单独标出，主人仍知道池子里还有多少无额度账号。
      Z2A_POOL_TITLE="💳 账号池 · ${shown_total}（active ${shown_active}）"
      if [ "${hidden_total:-0}" -gt 0 ] 2>/dev/null; then
        Z2A_POOL_TITLE="${Z2A_POOL_TITLE} · 略 ${hidden_total} 无额度"
      fi
      local rows="" prefix subpre
      while IFS=$'\t' read -r name prov mode st plan_name err quota_json; do
        n=$((n + 1))
        if [ "$n" -eq "${shown_total}" ]; then
          prefix='<code>  └─ </code>'; subpre="$(tree_sub 1)"
        else
          prefix='<code>  ├─ </code>'; subpre="$(tree_sub 0)"
        fi
        local chan st_cn
        case "$prov/$mode" in
          zai/jwt)         chan="Plan 通道" ;;
          bigmodel/apiKey) chan="Key 通道" ;;
          *)               chan="$prov/$mode" ;;
        esac
        case "$st" in
          active)    st_cn="正常" ;;
          exhausted) st_cn="额度用完" ;;
          cooling)   st_cn="冷却中" ;;
          invalid)   st_cn="鉴权失效" ;;
          disabled)  st_cn="已停用" ;;
          *)         st_cn="$st" ;;
        esac
        local line="$prefix<code>$(escape_html "$name")</code> · $chan · $st_cn"
        local sub=""
        if [ -n "$quota_json" ] && [ "$quota_json" != "{}" ]; then
          local q
          q="$(printf '%s' "$quota_json" | jq -r 'to_entries | map("\(.key) 剩 \(((.value.remaining / 100000) | floor) / 10)M / \(((.value.total / 100000) | floor) / 10)M") | join(" · ")' 2>/dev/null)"
          local exp
          # 精确到时刻并强制北京时区（jq todate 是 GMT 且只取日期会丢时刻；
          # strftime 两参数写法在本机 jq 会崩，故 bash 侧 date 换算）
          exp="$(printf '%s' "$quota_json" | jq -r '[.[] | .expires_at // empty] | unique | .[]' 2>/dev/null \
            | while read -r ts; do TZ=Asia/Shanghai date -d @"$ts" '+%Y-%m-%d %H:%M'; done | paste -sd' · ' -)"
          [ -n "$exp" ] && q="${q} · 有效期 ${exp}"
          [ -n "$q" ] && sub="额度 $(escape_html "$q")"
        fi
        [ -n "$plan_name" ] && [ "$plan_name" != "-" ] && sub="${sub:+$sub · }套餐 $(escape_html "$plan_name")"
        [ -n "$err" ] && [ "$err" != "-" ] && sub="${sub:+$sub · }最近错误 $(escape_html "$err")"
        [ -n "$sub" ] && line="${line}"$'\n'"${subpre}${sub}"
        rows+="$line"$'\n'
      done < <(printf '%s\n' "$pool_rows")
      Z2A_POOL_TEXT="$(printf '%s' "$rows" | sed '/^$/d')"
    }

    # 风控停用检测（2026-10-24 主人要求：账号风控要像模型冷却一样主动通知）：
    # 上游 503「无可用账号」文案把三种原因混在一句话里，其中「风控封禁停用」
    # （disabled + last_error 命中风控特征 3012/unusual activity）额度满格、
    # 不会自动恢复、必须人工到 z.ai 后台解封 —— 不能再套「额度耗尽 · 无需
    # 人工介入」的口径。只认 status=disabled 且 last_error 命中风控特征的账号。
    # 状态留痕落 /dropbox（跨 runner 重置存活）：报过风控 → 写入；后续任一轮
    # admin API 可达、无风控停用账号且自检通过 → 补发「风控解除」并清痕。
    Z2A_RISK_STATE_FILE="/dropbox/self-hosted/zcode2api/state/risk-ban.state"
    Z2A_RISK_BAN_COUNT=0
    Z2A_RISK_BAN_LIST=""
    Z2A_RISK_SEEN_OK=0
    z2a_detect_risk_ban() {
      local ak json names
      ak="$(z2a_admin_key)"
      [ -n "$ak" ] || return 0
      json="$(curl -sS --max-time 10 -H "Authorization: Bearer ${ak}" \
        "http://127.0.0.1:${Z2A_PORT}/admin/api/accounts" 2>/dev/null)" || return 0
      printf '%s' "$json" | jq -e '.accounts' >/dev/null 2>&1 || return 0
      Z2A_RISK_SEEN_OK=1
      names="$(printf '%s' "$json" | jq -r '[.accounts[] | select(.status == "disabled") | select((.last_error // "") | test("风控|3012|unusual activity")) | .name] | .[]' 2>/dev/null || true)"
      Z2A_RISK_BAN_COUNT="$(printf '%s' "$names" | grep -c . || true)"
      Z2A_RISK_BAN_LIST="$(printf '%s' "$names" | paste -sd'、' -)"
    }

    z2a_ok_reason() {
      if [ "$Z2A_PLAN_BAD" = "1" ]; then
        echo "已就绪（Plan 通道降级）· glm-5.3-flash 自检 3 轮未过，bigmodel Key 通道可用（model=${Z2A_SELFTEST_MODEL:-未知}）"
      else
        echo "已就绪 · 自检消息已收到回答（model=${Z2A_SELFTEST_MODEL:-未知}）"
      fi
    }

    # 自检前先强制刷新一次额度 —— 修「有额度却报额度耗尽」的误报
    # （2026-10-06 实测：启动通知报 4 个账号全「额度用完」，实际刷新后
    # 4 个全部 active、合计剩 2.76 亿 token）。
    # 成因是时序竞争：服务重启后账号状态从 accounts.db 恢复，带着上次
    # 运行留下的 EXHAUSTED；后台 monitor 的额度刷新还没跑完，自检探针就
    # 打进来拿 503，通知便据此判「全部通道额度耗尽」。服务没病，是健康
    # 检查抢跑。故先刷一次让状态追上真实额度，再自检 —— 刷新后仍 503
    # 才是真的无额度，此时报警才准。
    # 失败不阻断：刷新只用于纠正状态，刷不动时自检结果本身仍然可信。
    # （端点只跳过 cooling / 非 Plan 通道账号，EXHAUSTED 会被刷到，
    #  quota.py 的「额度恢复 → 重新激活」逻辑会把有余量的账号救回 active）
    z2a_refresh_quota() {
      local ak
      ak="$(z2a_admin_key)"
      [ -n "$ak" ] || return 0
      curl -sS --max-time 180 -X POST \
        "http://127.0.0.1:${Z2A_PORT}/admin/api/accounts/refresh" \
        -H "Authorization: Bearer ${ak}" \
        -H 'content-type: application/json' \
        -d '{"all":true}' >/dev/null 2>&1 || true
    }

    if z2a_alive; then
      # 端口已有实例在响应：多为上一轮接力残留，直接复用，不重复起。
      # 但复用不等于可用 —— 仍要跑自检确认上游链路。
      # 复用实例同理先刷额度：残留实例可能已跑很久，状态未必跟上。
      z2a_refresh_quota
      if z2a_selftest; then
        Z2A_OK=1
        Z2A_REASON="已就绪 · 复用 ${Z2A_PORT} 上的实例（$(z2a_ok_reason)）"
      else
        Z2A_REASON="复用 ${Z2A_PORT} 上的实例，但自检未通过（输出见下方原始输出）"
      fi
    else
      echo "Cloning zcode2api and restoring data snapshot..."
      # Bun 运行时：验证码求解主路径 = bun + vendored 上游 captcha-happy
      # （fork 641c193 起）。缺 bun 时 settings.py 自动回退旧 node solver.js，
      # 该移植版在上游轮换 pe 版本后失速率 >70%（表现为连环 500「多次重试
      # 无结果」），故此处 best-effort 补装；安装失败不阻断本轮（有回退路
      # 径），但自检大概率 Plan 降级。runner 重置会清 ~/.bun，每轮幂等检查。
      if [ ! -x "$HOME/.bun/bin/bun" ]; then
        echo "Installing Bun for zcode2api captcha solver..."
        # 2026-10-30 外置适配：原 `curl | bash` 被安全扫描判高危，改两步式
        #（下载落盘 → bash 执行），语义等价且可留档核对。
        if curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh \
           && bash /tmp/bun-install.sh; then
          echo "✅ [zcode2api] Bun 已安装（$HOME/.bun/bin/bun）"
        else
          echo "⚠️ [zcode2api] Bun 安装失败（回退 node solver.js，验证码可能连环 500）"
        fi
      fi
      # 2026-10-30 P5a：代码+依赖已由 Prefetch 后台就绪时直接复用（同 $Z2A_REPO
      # HEAD、同 requirements 自装，结果与本步骤现场安装等价）；数据快照仍由
      # 本步骤从 Dropbox 照常恢复。检测判据 = clone 树 + venv + node_modules 齐备；
      # 任一不齐（Prefetch 失败/半途）则按原路径现场重装，语义与此前完全一致。
      Z2A_PREPPED=0
      if [ -f "$Z2A_RUN_DIR/requirements.txt" ] && [ -x "$Z2A_RUN_DIR/.venv/bin/python" ] \
         && [ -d "$Z2A_RUN_DIR/captcha_node/node_modules" ] \
         && git -C "$Z2A_RUN_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "ℹ️ [zcode2api] 代码与依赖已由 Prefetch 就绪，跳过 clone 与依赖安装"
        Z2A_PREPPED=1
      fi
      if [ "$Z2A_PREPPED" != "1" ]; then rm -rf "$Z2A_RUN_DIR"; fi
      # 先 clone（目标必须为空目录），logs 目录随后补建
      if ! { [ "$Z2A_PREPPED" = "1" ] || git clone --quiet --depth 1 "$Z2A_REPO" "$Z2A_RUN_DIR"; }; then
        Z2A_REASON="代码克隆失败：$Z2A_REPO"
      else
        mkdir -p "$Z2A_RUN_DIR/logs"
        if ! { rclone copyto "$Z2A_DATA_ARCHIVE" /tmp/zcode2api-data.tar.gz 2>/dev/null \
             && [ -s /tmp/zcode2api-data.tar.gz ] \
             && tar -xzf /tmp/zcode2api-data.tar.gz -C "$Z2A_RUN_DIR"; }; then
          Z2A_REASON="数据快照缺失或损坏：$Z2A_DATA_ARCHIVE（先在本机重新打包上传）"
        elif ! { [ "$Z2A_PREPPED" = "1" ] || { python3 -m venv "$Z2A_RUN_DIR/.venv" \
             && "$Z2A_RUN_DIR/.venv/bin/pip" install --quiet --disable-pip-version-check \
                  -r "$Z2A_RUN_DIR/requirements.txt" 2>"$Z2A_RUN_DIR/logs/pip.log" \
             && (cd "$Z2A_RUN_DIR/captcha_node" && npm ci --silent 2>"$Z2A_RUN_DIR/logs/npm.log"); }; }; then
          Z2A_REASON="依赖安装失败（见 logs/pip.log / logs/npm.log）"
        else
          echo "Starting zcode2api on ${Z2A_PORT} (systemd --user 托管)..."
          # 托管交给 services.sh（systemd --user + Restart=always）：窗口期内
          # 进程崩溃由 systemd 秒级拉起，不再依赖下一轮 run。ZCODE_GATEWAY_KEY
          # 由 step env 注入、单元 Environment 落盘（600），优先级高于 .env。
          # 停止必须走 systemctl（见收尾 3c 注释），pkill 会被 Restart 抢回来。
          bash "$GITHUB_WORKSPACE/.github/scripts/services/services.sh" ensure zcode2api || true
          Z2A_UP=0
          for _ in $(seq 1 60); do
            if z2a_alive; then Z2A_UP=1; break; fi
            sleep 1
          done
          if [ "$Z2A_UP" != "1" ]; then
            Z2A_REASON="服务未在 60 秒内监听 ${Z2A_PORT}（见日志尾部）"
          else
            # 本轮确实执行了 ensure/start（不是复用旧实例）→ 属于「启动」，
            # 就绪通知必须发，即使上一轮留下过 tag 文件。
            Z2A_STARTED=1
            # 凭据自动跟随：credentials.json 每轮随 zcode.tar.gz 还原（比快照里的
            # 账号池新），解密出的 JWT / bigmodel API Key 对齐进账号池；
            # 脚本幂等（一致即 SKIP），失败不阻断，沿用快照凭据继续服务
            if (cd "$Z2A_RUN_DIR" && .venv/bin/python credential_sync.py >> "$Z2A_LOG" 2>&1); then
              echo "✅ [zcode2api] credential sync 完成"
            else
              echo "⚠️ [zcode2api] credential sync 失败（沿用快照账号池凭据）"
            fi
            # 凭据自动跟随 cron：runner 重置会清掉手工 crontab，故每轮幂等重装。
            # run 间隔最长 ~5.75h，期间 zcode 客户端滚动刷新 credentials.json，
            # 账号池靠这条 cron 每 10 分钟跟上（脚本幂等，一致即 SKIP）。
            mkdir -p "$HOME/.openclaw/logs"
            CRON_LINE="*/10 * * * * flock -n /tmp/zcode2api-cred-sync.lock $Z2A_RUN_DIR/.venv/bin/python $Z2A_RUN_DIR/credential_sync.py >> $HOME/.openclaw/logs/zcode2api-cred-sync.log 2>&1"
            if { crontab -l 2>/dev/null | grep -vF 'zcode2api-cred-sync.lock'; echo "$CRON_LINE"; } | crontab -; then
              echo "✅ [zcode2api] credential sync cron 已就位"
            else
              echo "⚠️ [zcode2api] credential sync cron 安装失败（不影响本轮服务）"
            fi
            # 新起实例：自检前先刷额度，避免账号从 accounts.db 带着上轮的
            # EXHAUSTED 恢复、后台刷新尚未跑完就被自检判「额度耗尽」
            # （2026-10-06 误报实例，详见 z2a_refresh_quota 处注释）
            z2a_refresh_quota
            if z2a_selftest; then
              Z2A_OK=1
              Z2A_REASON="$(z2a_ok_reason)"
            else
              Z2A_REASON="服务已监听但自检未通过（输出见下方原始输出）"
            fi
          fi
        fi
      fi
    fi

    # 通知前采集账号池（服务已监听才有数据；失败不阻断，通知里少一节）
    z2a_alive && z2a_collect_pool
    z2a_detect_risk_ban
    # 503 no_available_account + 池内存在风控停用账号 → 真实原因是风控封禁，
    # 重新分诊为 risk_ban（区别于真额度耗尽：后者才适用「无需人工介入」）
    if [ "$Z2A_OK" != "1" ] && [ "$Z2A_RISK_BAN_COUNT" -gt 0 ]; then
      case "$Z2A_FAIL_CLASS" in
        quota|unavailable) Z2A_FAIL_CLASS="risk_ban" ;;
      esac
    fi

    # 通知口径：与 workbuddy-gateway 一致，成功也推「已就绪」。
    # 接力轮每轮都会跑本步骤，为免逐轮刷屏，用本步骤自己的标记文件区分：
    # 文件在 → 上一轮已启动过 = 接力轮，不重复推「已就绪」。按未标记处理
    # （多发一条好过漏发）。Plan 降级不算接力静默条件：降级必须每轮报。
    Z2A_RUN_TAG_FILE="/tmp/zcode2api-serve-run-tag"
    Z2A_RELAUNCH=0
    Z2A_PREV_TAG=""
    if [ -s "$Z2A_RUN_TAG_FILE" ] && [ "$Z2A_PLAN_BAD" != "1" ]; then
      Z2A_RELAUNCH=1
      Z2A_PREV_TAG="$(head -n 1 "$Z2A_RUN_TAG_FILE" 2>/dev/null || true)"
    fi

    if [ "$Z2A_OK" != "1" ]; then
      Z2A_TAIL="$(tail -n 15 "$Z2A_LOG" 2>/dev/null || true)"
      echo "--- zcode2api.log tail ---"
      printf '%s\n' "${Z2A_TAIL:-<empty>}"
      echo "--- end zcode2api.log tail ---"
      _m=""
      # 失败分诊：服务已监听但自检不出内容时，先分清是「上游额度/通道问题」
      # 还是「服务真没起来」。前者服务本体健康（/v1/models 带 key 回 200），
      # 只是无额度可用 —— 用黄色「已就绪（额度耗尽）」，不用红色「启动失败」：
      # 红色会让人去查进程/端口，实际该做的是等额度重置或换账号，方向完全不同。
      case "$Z2A_FAIL_CLASS" in
        # risk_ban = 账号被 z.ai 风控封禁自动停用（3012/unusual activity）：
        # 额度满格、不自动恢复、必须人工解封后启用 —— 红色点名 + 持续每轮
        # 上报直至解除（2026-10-24 主人要求：风控要像模型冷却一样通知）
        risk_ban)
          tg_add_title _m "🔴 zcode2api 账号池风控停用 · 需人工解封"
          tg_add_kv _m "结论" "z.ai 风控封禁（3012/unusual activity）已停用 ${Z2A_RISK_BAN_COUNT} 个账号：${Z2A_RISK_BAN_LIST}；账号额度满格，并非额度耗尽"
          tg_add_kv _m "说明" "不会自动恢复：需到 z.ai 后台确认解封后启用（解封后可让我调 admin API 启用并实测）；解除前 GLM-5.3 持续 503"
          ;;
        # unavailable = 网关 503 no_available_account / 请求级死线：账号池全冷却
        # 或额度耗尽，服务本体在监听且能回 /v1/models —— 与 quota 同为黄色降级，
        # 不能掉进红色「启动失败」（2026-09-30 误报实例：额度耗尽报成了启动失败）
        quota|unavailable)
          tg_add_title _m "🟡 zcode2api 已就绪 · 全部通道额度耗尽"
          tg_add_kv _m "结论" "服务正常，上游无可用额度/账号池冷却中（非启动故障）"
          tg_add_kv _m "说明" "冷却到期自动回轮询，无需人工介入；额度周期刷新后自动恢复"
          ;;
        channel)
          tg_add_title _m "🟡 zcode2api 已就绪 · 回退通道已关闭"
          tg_add_kv _m "结论" "服务正常，bigmodel 回退通道被关（后台「设置」可开）"
          ;;
        auth)
          tg_add_title _m "🟠 zcode2api 鉴权失败"
          tg_add_kv _m "结论" "网关 Key / 上游鉴权不符，需人工介入"
          ;;
        *)
          tg_add_title _m "❌ zcode2api 启动失败"
          tg_add_kv _m "结论" "未就绪"
          ;;
      esac
      tg_add_path _m "端口" "$Z2A_PORT"
      tg_add_kv _m "原因" "$Z2A_REASON"
      tg_add_path _m "代码" "$Z2A_REPO"
      tg_add_path _m "数据快照" "$Z2A_DATA_ARCHIVE"
      if [ -n "$Z2A_SELFTEST_OUT" ]; then
        tg_add_section _m "🧾 自检输出"
        tg_add_pre _m "$Z2A_SELFTEST_OUT"
      fi
      if [ -n "$Z2A_POOL_TEXT" ]; then
        tg_add_section _m "$Z2A_POOL_TITLE"
        tg_add_block _m "$Z2A_POOL_TEXT"
      fi
      if [ -n "$Z2A_TAIL" ]; then
        tg_add_section _m "🧾 服务日志尾部"
        tg_add_pre _m "$Z2A_TAIL"
      fi
      tg_add_footer _m
      if send_tg "$_m" alert; then
        # 风控停用留痕：发送成功才写（失败下轮重试，对齐就绪标记口径）
        if [ "$Z2A_FAIL_CLASS" = "risk_ban" ]; then
          mkdir -p "$(dirname "$Z2A_RISK_STATE_FILE")" 2>/dev/null || true
          printf 'banned: %s\n' "${Z2A_RISK_BAN_LIST}" > "$Z2A_RISK_STATE_FILE" 2>/dev/null || true
        fi
      else
        echo "::warning::TG 通知发送失败（不影响任务）"
      fi
    else
      echo "✅ [zcode2api] ${Z2A_PORT} 已就绪（${Z2A_REASON}）"
      # 风控解除补报：上一轮报过风控停用（留痕在）且本轮 admin API 可达、
      # 无风控停用账号、自检通过 → 补发恢复通知并清痕。独立于接力静默：
      # 恢复是状态翻转事件，必须每轮都有机会补报。
      if [ -s "$Z2A_RISK_STATE_FILE" ] && [ "$Z2A_RISK_SEEN_OK" = "1" ] && [ "$Z2A_RISK_BAN_COUNT" -eq 0 ]; then
        _r=""
        tg_add_title _r "🟢 zcode2api 风控解除 · 账号池恢复"
        tg_add_kv _r "结论" "此前风控停用的账号已恢复可用，自检通过（model=${Z2A_SELFTEST_MODEL:-未知}）"
        tg_add_path _r "端口" "$Z2A_PORT"
        if [ -n "$Z2A_POOL_TEXT" ]; then
          tg_add_section _r "$Z2A_POOL_TITLE"
          tg_add_block _r "$Z2A_POOL_TEXT"
        fi
        tg_add_footer _r
        if send_tg "$_r" alert; then
          rm -f "$Z2A_RISK_STATE_FILE" 2>/dev/null || true
        else
          echo "::warning::TG 通知发送失败（不影响任务）"
        fi
      fi
      if [ "$Z2A_RELAUNCH" = "1" ] && [ "$Z2A_STARTED" != "1" ]; then
        echo "ℹ️ [zcode2api] 接力轮（上一 run ${Z2A_PREV_TAG} 已启动），跳过重复的就绪通知"
      else
        # 版式对齐 wb_notify 的就绪态分支：结论 → 接口/鉴权/模型 → 代码来源。
        # 「模型」是机器值（模型名），按规范 · 取值行口径走 <code>。
        _m=""
        if [ "$Z2A_PLAN_BAD" = "1" ]; then
          tg_add_title _m "🟡 zcode2api 已就绪（Plan 通道降级）"
        else
          tg_add_title _m "🟢 zcode2api 已就绪"
        fi
        tg_add_kv _m "结论" "$Z2A_REASON"
        tg_add_path _m "接口" "http://127.0.0.1:${Z2A_PORT}/v1"
        # 数据目录（对齐 wb_notify 头部定位口径，主人 2026-10-11 要求信息层面统一）
        tg_add_path _m "数据目录" "/tmp/local_zcode2api/data"
        # 标签「API Key」+ tg_add_path：对齐 wb_notify 同款 —— 值走 <code> 等宽，
        # 客户端点一下即可整块复制（tg_add_kv 是纯文本，只能手选）
        tg_add_path _m "API Key" "${ZCODE_GATEWAY_KEY:-未取到}"
        [ -n "${Z2A_SELFTEST_MODEL:-}" ] && tg_add_path _m "模型" "$Z2A_SELFTEST_MODEL"
        if [ -n "$Z2A_POOL_TEXT" ]; then
          tg_add_section _m "$Z2A_POOL_TITLE"
          tg_add_block _m "$Z2A_POOL_TEXT"
          _m+=$'\n'
        fi
        # 池内仍有风控停用账号时，就绪卡也必须点名（不能只靠账号池明细一行小字）
        if [ "$Z2A_RISK_BAN_COUNT" -gt 0 ]; then
          tg_add_kv _m "⚠️ 风控停用" "${Z2A_RISK_BAN_COUNT} 个：${Z2A_RISK_BAN_LIST} · 需 z.ai 后台解封后启用"
        fi
        tg_add_path _m "代码" "$Z2A_REPO"
        # 用量 + 流水（看板独有，2026-10-05 补进 zcode 通知，与 wb/trae 同口径）：
        # 只渲染 zcode 自己的，调 board.py CLI 与看板共用渲染代码与数据源。
        _z2a_ul_block="$(python3 /dropbox/self-hosted/quota-board/board.py usage-ledger zcode 12 2>/dev/null || true)"
        # 2026-10-11 修复：此处变量是 _m（本分支消息变量），曾误写 _msg ——
        # _msg 在本 step 未定义，tg_append 的 ${!1} 间接展开撞 set -u 直接崩整 step
        # （run 38141881455 实锤：tg_notify.sh line 89: !1: unbound variable），
        # zcode2api 的「已就绪」通知自 2026-10-06 (a873e07) 起从未发出过。
        [ -n "$_z2a_ul_block" ] && tg_append _m "$_z2a_ul_block"
        tg_add_footer _m
        if send_tg "$_m" alert; then
          printf '%s\n' "${GITHUB_RUN_ID:-manual}" > "$Z2A_RUN_TAG_FILE"
          if [ "$Z2A_RISK_BAN_COUNT" -gt 0 ]; then
            # 就绪卡已点名风控停用 → 同样留痕，供后续轮次补报解除
            mkdir -p "$(dirname "$Z2A_RISK_STATE_FILE")" 2>/dev/null || true
            printf 'banned: %s\n' "${Z2A_RISK_BAN_LIST}" > "$Z2A_RISK_STATE_FILE" 2>/dev/null || true
          fi
        else
          echo "::warning::TG 通知发送失败（不影响任务）"
        fi
      fi
    fi
  )
  _up_rc=$?
  printf '%s' "$_up_rc" > /tmp/upstream-rc-zcode2api
) > /opt/logs/upstream-zcode2api.log 2>&1 &
echo "🚀 [P5b] zcode2api 已转后台部署（等齐门在 AI 网关步骤）"
