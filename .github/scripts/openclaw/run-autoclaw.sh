#!/usr/bin/env bash
# openclaw 工作流「Run autoclaw-proxy」步骤本体（2026-10-30 搬移自 yml + P5b 化）。
# 外置背景：workflow 500KB 上限减重（同 run-zcode2api.sh 模式）。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL / AUTOCLAW_GATEWAY_KEY / AUTOCLAW_REPO / AUTOCLAW_SNAPSHOT_REMOTE / AUTOCLAW_STATS_REMOTE / AUTOCLAW_PORT
#   文件依赖：$HOME/ts.env（Tailscale 步骤落盘；serve/tailscale 入口用）
#   落盘契约：/tmp/upstream-rc-autoclaw（P5b 等齐门标记，2026-10-30 起 autoclaw
#     计入上游 —— 主人拍板：autoclaw 也是模型渠道，须先于 OmniRoute 启动）、
#     /opt/logs/upstream-autoclaw.log
# P5b 双层子壳结构是刻意设计，勿动结构。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）；体内自带 set -uo pipefail。

(
  set +e
  (
          set -uo pipefail
          source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

          RUN_DIR="/tmp/local_autoclaw-proxy"
          AC_OK=0
          AC_REASON=""
          AC_ACCOUNTS=""
          AC_MODEL=""
          AC_SCORE=""

          # 0. 拉代码（GitHub，clone 到干净目录）+ 票仓快照（快照缺失 = 未导入凭据，直接跳过）
          rm -rf "$RUN_DIR"
          if ! git clone --quiet --depth 1 "$AUTOCLAW_REPO" "$RUN_DIR" || [ ! -f "$RUN_DIR/app/proxy.py" ]; then
            echo "::warning::[autoclaw] 代码克隆失败（$AUTOCLAW_REPO）"
            AC_REASON="代码克隆失败"
          elif ! rclone copyto "$AUTOCLAW_SNAPSHOT_REMOTE" "$RUN_DIR/snapshot.json" 2>/dev/null || [ ! -s "$RUN_DIR/snapshot.json" ]; then
            echo "::warning::[autoclaw] 无凭据快照（先在本机跑 autoclaw_auth.py bootstrap）"
            AC_REASON="未配置凭据快照"
          else
            AC_COMMIT="$(git -C "$RUN_DIR" rev-parse --short HEAD)"
            echo "代码: $AUTOCLAW_REPO @ $AC_COMMIT"
            # 累计统计拉回续计：Dropbox 有则覆盖本地（/tmp 重建后为空），无则从零起计
            rclone copyto "$AUTOCLAW_STATS_REMOTE" "$RUN_DIR/app/lifetime_stats.json" 2>/dev/null \
              && echo "lifetime_stats: 已从 Dropbox 拉回续计" \
              || echo "lifetime_stats: 无云端存档，从零起计"
            SNAP_ACCOUNTS="$(python3 -c "import json;print(len(json.load(open('$RUN_DIR/snapshot.json')).get('accounts',[])))" 2>/dev/null || echo 0)"
            if [ "${SNAP_ACCOUNTS:-0}" -eq 0 ]; then
              echo "::warning::[autoclaw] 快照为空（0 账号）"
              AC_REASON="快照无账号"
            else
              echo "快照账号数: $SNAP_ACCOUNTS"

              # 1. 无头刷新：剩余>6h 自动跳过；失败再 -f 强刷一次（406/网络抖动兜底）
              #    新票回写 snapshot 后立即回推 Dropbox（票持久化，见上方凭据模型）
              #
              #    ⚠️ AUTOCLAW_AUTH_EMIT_REFRESH=1（2026-10-12）：同时产出
              #    accounts.json.refresh（0600，含 refresh_token/device_id），
              #    这是 proxy 内 M3「现刷新票」的唯一原料。缺它时 M3 恒空转——
              #    一旦上游启用 access token「铸造时间」分钟级校验（switch 在
              #    2.0.2 网关实测过），静态票会 401 且**没有第二个号可换**时
              #    整个池子全 401（今天 07:02–07:53 就是这么熔断的）。
              if AUTOCLAW_AUTH_EMIT_REFRESH=1 python3 "$RUN_DIR/app/autoclaw_auth.py" refresh \
                   --snapshot "$RUN_DIR/snapshot.json" \
                   --accounts-out "$RUN_DIR/accounts.json"; then
                echo "refresh: 直刷通过"
              else
                echo "refresh: 直刷失败，尝试 -f 强刷"
                AUTOCLAW_AUTH_EMIT_REFRESH=1 python3 "$RUN_DIR/app/autoclaw_auth.py" refresh -f \
                  --snapshot "$RUN_DIR/snapshot.json" \
                  --accounts-out "$RUN_DIR/accounts.json" || true
              fi
              rclone copyto "$RUN_DIR/snapshot.json" "$AUTOCLAW_SNAPSHOT_REMOTE" \
                || echo "::warning::[autoclaw] 快照回推失败（票仍是可复用长票时无害；一旦上游轮换即丢票，需重新 bootstrap）"

              # 1.5 每日签到（daily_signin，+200 积分/账号/天；2026-10-11 新增）：
              #     复用 refresh 出的热票打 task 网关；幂等三重保障——本地状态当日
              #     跳过、上游 already_completed 不重复加分、-f 只在状态丢失时兜底。
              #     签到失败不影响反代启动（结果只进通知）。
              AC_CHECKIN=""
              # 脚本在 stdout 末尾打 "--- summary ---" 单行摘要（多账号明细同行），
              # awk 取分隔行之后的内容作为通知摘要；签到 rc=1（有账号失败）不阻断反代。
              CHECKIN_OUT="$(python3 "$RUN_DIR/app/autoclaw_auth.py" checkin \
                   --snapshot "$RUN_DIR/snapshot.json" \
                   --results-out "$RUN_DIR/checkin-results.json" 2>&1 || true)"
              AC_CHECKIN="$(printf '%s\n' "$CHECKIN_OUT" | awk 'f{print} /^--- summary ---$/{f=1}' | tail -n 1)"
              echo "签到: ${AC_CHECKIN:-（无摘要输出）}"

              # 1.6 积分收割（claim 全家桶：签到+灵感中心+新人任务+活动奖励；2026-10-12 新增）：
              #     签到之外的可领积分（灵感中心每日 200 为主）也要自动收干净。
              #     调度收敛到每日两个窗口：CST 9 点后首轮 + 21 点后首轮 —— 同时覆盖
              #     「UTC 零点重置（=08:00 CST）」与「CN 零点重置」两种上游口径。
              #     GitHub cron 常迟到/偶发跳轮，所以按「小时开窗 + 标记去重」而非
              #     精确分钟匹配；标记文件在 STATE_DIR（/tmp 之外），跨轮持久，
              #     VM 销毁后自动重新开窗。窗口内脚本硬崩（无 summary 行）不落标记，
              #     下轮自动重试；claim 幂等（上游 already/560118 不重复加分）。
              AC_CLAIM=""
              AC_CLAIM_TODAY="$(TZ=Asia/Shanghai date +%F)"
              AC_CLAIM_HOUR="$(TZ=Asia/Shanghai date +%H)"
              AC_CLAIM_MARK="$HOME/.config/autoclaw-auth/claim-marker.json"
              if [ "$AC_CLAIM_HOUR" -ge 9 ] 2>/dev/null || [ "$AC_CLAIM_HOUR" -le 3 ] 2>/dev/null; then
                AC_CLAIM_SLOT="am"
              fi
              if [ "$AC_CLAIM_HOUR" -ge 21 ] 2>/dev/null; then
                AC_CLAIM_SLOT="pm"
              fi
              if [ -n "${AC_CLAIM_SLOT:-}" ]; then
                # 单行 python -c（run: | 块内多行内嵌会破坏 YAML 块标量缩进）
                AC_CLAIM_DONE="$(python3 -c "import json,os;print(json.load(open('$AC_CLAIM_MARK')).get('$AC_CLAIM_SLOT','') if os.path.exists('$AC_CLAIM_MARK') else '')" 2>/dev/null)"
                if [ "$AC_CLAIM_DONE" != "$AC_CLAIM_TODAY" ]; then
                  CLAIM_OUT="$(python3 "$RUN_DIR/app/autoclaw_auth.py" claim \
                       --snapshot "$RUN_DIR/snapshot.json" 2>&1 || true)"
                  AC_CLAIM="$(printf '%s\n' "$CLAIM_OUT" | awk 'f{print} /^--- summary ---$/{f=1}' | tail -n 1)"
                  if [ -n "$AC_CLAIM" ]; then
                    python3 -c "import json,os,time;os.makedirs(os.path.dirname('$AC_CLAIM_MARK'),exist_ok=True);m=(json.load(open('$AC_CLAIM_MARK')) if os.path.exists('$AC_CLAIM_MARK') else {});m['$AC_CLAIM_SLOT']='$AC_CLAIM_TODAY';m['updated_at']=int(time.time());json.dump(m,open('$AC_CLAIM_MARK','w'))"
                  else
                    AC_CLAIM="已到收割窗口但未取到摘要（脚本报错？详见本轮 action 日志）"
                  fi
                  echo "claim: $AC_CLAIM"
                fi
              fi

              # 2. 托管起反代（2026-10-12 起 systemd --user，取代原 nohup 裸跑）
              #    旧方案：nohup 起的进程 PPID=1，~/.config/systemd/user 下无单元，
              #    本机重启/被收编即断连且无自愈（窗口期崩溃要等下一轮 run）。
              #    新方案与其他四网关同口径：services.sh ensure → 写单元(幂等)+restart，
              #    Restart=always 把崩溃自愈收敛到秒级。
              #
              #    与 qingyan 的差异：autoclaw 代码在 /tmp（每轮 clone 自 GitHub，真源不在
              #    本机），故 write_unit 用 AUTOCLAW_RUN_DIR 定位，且每轮 ensure 的 restart
              #    语义与原 nohup 的「每轮 pkill + 重启」完全一致。
              #
              #    绑定地址/鉴权 fail-closed 已移入单元：无 AUTOCLAW_GATEWAY_KEY 时
              #    write_unit 直接拒绝生成单元（比原来的「运行期降级回环」更严，不起假服务）。
              mkdir -p "$HOME/.openclaw-autoclaw"
              [ -f "$HOME/.openclaw-autoclaw/openclaw.json" ] \
                || cp "$RUN_DIR/app/openclaw.json" "$HOME/.openclaw-autoclaw/openclaw.json"
              AC_SERVICES="${GITHUB_WORKSPACE}/.github/scripts/services/services.sh"
              if [ -f "$AC_SERVICES" ]; then
                AUTOCLAW_RUN_DIR="$RUN_DIR" bash "$AC_SERVICES" ensure autoclaw || \
                  echo "::warning::[autoclaw] systemd 托管失败（见 services 日志），自检将判定未就绪"
              else
                echo "::error::[autoclaw] services.sh 缺失，无法托管"
              fi
              # 就绪等待：systemd active ≠ 端口已监听（绑定失败会 active 后秒退），故仍以端口为准。
              for _ in $(seq 1 30); do
                code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AUTOCLAW_PORT}/v1/models" 2>/dev/null || true)"
                [ -n "$code" ] && [ "$code" != "000" ] && break
                sleep 2
              done

              # 3. 端到端自检：真发消息（healthz 通≠上游通，zcode2api 同款原则）。
              #    失败分诊：quota=上游限流（服务本体健康）· auth=票无效 · unavailable=其他
              AC_PROBE="$(curl -sS --max-time 120 -X POST "http://127.0.0.1:${AUTOCLAW_PORT}/v1/chat/completions" \
                -H "Authorization: Bearer ${AUTOCLAW_GATEWAY_KEY}" \
                -H 'content-type: application/json' \
                -d '{"model":"zai_glm-5.3-flash","messages":[{"role":"user","content":"只回复两个字：正常"}],"max_tokens":256}' 2>&1 || true)"
              if printf '%s' "$AC_PROBE" | jq -e '(.choices // [] | length) > 0' >/dev/null 2>&1; then
                AC_OK=1
                AC_REASON="端到端自检通过"
                AC_MODEL="zai_auto · zai_glm-5.3-flash · zaicoding_glm-5.3"
                # ⚠️ 2026-10-12 修正：积分/钱包字段**只在 /v1/health**，/healthz 的
                # 响应体顶层根本没有 wallet/subscription 键（实测对比两端口字段：
                # healthz=[ok,uptime,upstream,token,models,...]，v1/health=[...,wallet,
                # subscription,...]）。此前这里打 /healthz 取 .wallet，jq 恒落空 →
                # AC_SCORE 永远为空 → 通知的账号池子行没有积分包信息（主人反馈）。
                AC_HEALTH="$(curl -s --max-time 5 -H "Authorization: Bearer ${AUTOCLAW_GATEWAY_KEY}" \
                  "http://127.0.0.1:${AUTOCLAW_PORT}/v1/health" 2>/dev/null || true)"
                AC_ACCOUNTS="$(printf '%s' "$AC_HEALTH" | jq -r '.accounts.count // "?"' 2>/dev/null || echo '?')"
                # 积分包：总余额 + 即将到期（有账号级明细时一并带上，与 qingyan 的
                # 「💳 积分」同口径：真有才显示，取不到就整段省略不谎报 0）。
                AC_SCORE="$(printf '%s' "$AC_HEALTH" | jq -r '.wallet | select(.available) \
                  | "总余额 \(.total_balance) · 即将到期 \(.expiring.points // 0)"' 2>/dev/null || true)"
                # 钱包取不到时**必须留痕**（主人 2026-10-12 反馈「没有积分包过期时间」）：
                # 可用性判定落在 .wallet.available，上游返回 410000「用户未登录」时
                # 该值为 false —— 此时若不展示原因，通知里这一行就是凭空消失，
                # 读者无法区分「没配这个字段」和「上游没给数据」。
                if [ -z "${AC_SCORE:-}" ]; then
                  AC_SCORE="$(printf '%s' "$AC_HEALTH" | jq -r '.wallet | select(.available == false) \
                    | "积分包未取到 · \(.error // "原因未知")"' 2>/dev/null || true)"
                fi
                # 票有效期：credential.expired 为 true 时不显示剩余秒数（负值无意义）
                AC_TOKEN_EXP="$(printf '%s' "$AC_HEALTH" | jq -r '.credential \
                  | select(.present) | if .expired then "票已过期" \
                    else "票有效 · 剩余 \((.expires_in_seconds // 0) / 3600 | floor) 小时" end' 2>/dev/null || true)"
              elif printf '%s' "$AC_PROBE" | grep -qE '401|authentication'; then
                AC_REASON="自检失败：账号凭据无效（401）—— 票已过期且 refresh 失败，需本机重新 bootstrap"
              elif printf '%s' "$AC_PROBE" | grep -qE '406|upstream_throttled|繁忙'; then
                AC_REASON="自检失败：上游限流/限载（406/503）—— 服务本体健康，下轮重试"
              else
                AC_REASON="自检失败：$(printf '%s' "$AC_PROBE" | head -c 120)"
              fi
            fi
          fi

          # 4. tailscale serve（复用「HTTP 明文 + WireGuard 隧道」既有口径；serve 态
          #    随内存 state 逐轮清零，幂等重建）
          # ⚠️ 2026-10-19 修死链：面板路由原来整段挂在 $AC_OK 上，而 AC_OK 是
          # **端到端自检**结论 —— 上游限流/限载（406/503）会让自检失败，但服务本身
          # 健康、端口在听。此时 8083 不建，看板 admin_entries 第 4 项就成了死链
          # （实测 HTTP 000，主人 2026-10-19 反馈）。故面板与 API 入口拆开：
          # 面板/API serve 只看**端口是否在听**，与自检结论解耦。
          if [ -n "${TS_FQDN:-}" ] && curl -s --max-time 3 -o /dev/null "http://127.0.0.1:${AUTOCLAW_PORT}/v1/models" 2>/dev/null; then
            sudo tailscale serve --bg --http=8321 "http://127.0.0.1:${AUTOCLAW_PORT}" 2>/dev/null \
              && echo "autoclaw 反代: http://${TS_FQDN}:8321/v1"
            # 内置状态面板（/dashboard | / | /ui 均同一页）：2026-10-13 补。
            # 端口 8083 —— 延续后台端口段（trae 8080 / zcode 8081 / wb 8082），
            # 看板 admin_entries 第 4 项指的就是这个地址，两者必须一致。
            # 该面板免鉴权（实测无 key 即 200），收敛靠 tailscale 内网；
            # 主人 2026-10-13 明确「不要密码」，故不加 key 参数。
            sudo tailscale serve --bg --http=8083 "http://127.0.0.1:${AUTOCLAW_PORT}" 2>/dev/null \
              && echo "autoclaw 控制台: http://${TS_FQDN}:8083/"
          elif [ -z "${TS_FQDN:-}" ]; then
            echo "⚠️ autoclaw serve 跳过：TS_FQDN 为空"
          else
            echo "⚠️ autoclaw 端口 ${AUTOCLAW_PORT} 未监听，跳过 serve（面板将不可达）"
          fi

          # 5. TG 通知（版式对齐 qingyan/zcode2api：失败走 alert 档）
          _m=""
          if [ "$AC_OK" != "1" ]; then
            tg_add_title _m "❌ autoclaw-proxy 启动失败"
            tg_add_kv _m "结论" "未就绪"
            tg_add_kv _m "原因" "$AC_REASON"
            tg_add_kv _m "处理" "本机 clone jarvanh/autoclaw-proxy 后跑 python3 app/autoclaw_auth.py bootstrap（桌面端加 --inspect=9229）"
            tg_add_footer _m
            send_tg "$_m" alert || echo "::warning::TG 通知发送失败（不影响任务）"
          else
            # 2026-10-11 标题对齐全库网关就绪约定：🟢（对齐 workbuddy/zcode2api/trae/Runner，见 docs/telegram-notify.md）；原 ✅ 是照抄 qingyan 骨架带进来的游离用法
            tg_add_title _m "🟢 autoclaw-proxy 已就绪"
            tg_add_kv _m "结论" "$AC_REASON"
            tg_add_path _m "数据目录" "/tmp/local_autoclaw-proxy"
            tg_add_path _m "代码" "$AUTOCLAW_REPO @ $AC_COMMIT"
            tg_add_path _m "接口" "http://127.0.0.1:${AUTOCLAW_PORT}/v1"
            tg_add_path _m "API Key" "${AUTOCLAW_GATEWAY_KEY:-未取到}"
            # 信息层面对齐 wb_notify（主人 2026-10-11 要求）：数据目录 + 代码来源。
            # 数据目录是「这条通知说的是哪台机/哪份数据」的定位信息（主人 10-06 定的
            # 头部定位口径）；代码真源已迁 GitHub（2026-10-12，Dropbox 只存数据）。
            if [ -n "$AC_ACCOUNTS" ] && [ "$AC_ACCOUNTS" != "?" ]; then
              tg_add_section _m "💳 账号池 · ${AC_ACCOUNTS}"
              _ac_rows="$(tree_conn 1)$(tg_entry "账号数 ${AC_ACCOUNTS}" "负载均衡 · 401/406 冷却回退 · 快过期积分优先")"$'\n'
              # 积分包信息（主人 2026-10-12 要求：对齐 workbuddy 的「积分有效期」口径）
              [ -n "${AC_SCORE:-}" ] && _ac_rows+="$(tree_sub 1)$(escape_html "$AC_SCORE")"$'\n'
              [ -n "${AC_TOKEN_EXP:-}" ] && _ac_rows+="$(tree_sub 1)$(escape_html "$AC_TOKEN_EXP")"$'\n'
              tg_add_block _m "${_ac_rows%$'\n'}"
            fi
            # 每日签到结果（独立分节；含 +积分 明细）
            if [ -n "${AC_CHECKIN:-}" ]; then
              tg_add_section _m "📅 每日签到 · 1"
              tg_add_block _m "$(tree_lines "结果：<code>$(escape_html "$AC_CHECKIN")</code>")"
            else
              # 签到段缺席必须留痕（主人 2026-10-12 反馈「没有签到信息」）：
              # 此前 checkin 因传入不支持的 --accounts-out 参数直接 argparse exit 2，
              # 摘要恒为空 → 整段静默消失，看通知的人无从判断是「没跑」还是「跑了没输出」。
              tg_add_section _m "📅 每日签到 · 1"
              tg_add_block _m "$(tree_lines "结果：<code>未取到签到摘要（本轮未执行或脚本报错）</code>")"
            fi
            # 积分收割（claim 全家桶）：只在收割窗口轮展示（每日两轮，见 1.6 注释）；
            # 非窗口轮不渲染此节，避免每 5 分钟通知重复「全部已领」的噪音。
            if [ -n "${AC_CLAIM:-}" ]; then
              tg_add_section _m "🌾 积分收割 · 1"
              tg_add_block _m "$(tree_lines "结果：<code>$(escape_html "$AC_CLAIM")</code>")"
            fi
            # 用量 + 流水（信息层面对齐 wb/zcode 通知，主人 2026-10-11 要求）：
            # 调 board.py CLI 与看板共用渲染代码；autoclaw 走 lifetime 累计特例，
            # 无数据时输出空串静默跳过（与 wb/zcode 同口径）。
            _ac_ul_block="$(python3 /dropbox/self-hosted/quota-board/board.py usage-ledger autoclaw 12 2>/dev/null || true)"
            [ -n "$_ac_ul_block" ] && tg_append _m "$_ac_ul_block"
            tg_add_footer _m
            send_tg "$_m" alert || echo "::warning::TG 通知发送失败（不影响任务）"
          fi
          exit 0
  )
  _up_rc=$?
  printf '%s' "$_up_rc" > /tmp/upstream-rc-autoclaw
) > /opt/logs/upstream-autoclaw.log 2>&1 &
echo "🚀 [P5b] autoclaw-proxy 已转后台部署（等齐门在 AI 网关步骤）"
