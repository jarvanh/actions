#!/usr/bin/env bash
# openclaw 工作流「Run qingyan-proxy」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL /
#     QINGYAN_REFRESH_TOKEN / QINGYAN_GATEWAY_KEY / QINGYAN_PORT /
#     QINGYAN_APP_REMOTE / QINGYAN_DATA_DIR / QINGYAN_STATE_DIR / QINGYAN_ENV_FILE /
#     GITHUB_WORKSPACE
#   落盘契约：/tmp/upstream-rc-qingyan（P5b 等齐门标记）、/opt/logs/upstream-qingyan.log
# P5b 双层子壳结构是刻意设计，勿动结构。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）；体内自带 set -uo pipefail。

(
  set +e
  (
    set -uo pipefail
    # 通知真源在 step 顶层 source 一次（勿挪进函数体，理由见 workbuddy 步骤同名注释 / 规范 4.4）
    source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

    DEPLOY="${GITHUB_WORKSPACE}/.github/scripts/services/qingyan_deploy.sh"
    SERVICES="${GITHUB_WORKSPACE}/.github/scripts/services/services.sh"
    QUOTA="${GITHUB_WORKSPACE}/.github/scripts/services/qingyan_quota.sh"
    GL_OK=0
    GL_REASON=""
    GL_ENSURE_FAILED=0

    # 凭据缺失直接跳过本步骤（不部署无凭据服务）：拿不到账号积分，
    # 且限流严重，起了也是假象。判空不判内容——内容有效性交给后面的自检。
    if [ -z "${QINGYAN_REFRESH_TOKEN:-}" ]; then
      echo "::warning::[qingyan] 未配置 Secret GLM_REFRESH_TOKEN，跳过部署"
      GL_REASON="未配置 Secret GLM_REFRESH_TOKEN"
      _m=""
      tg_add_title _m "⏭️ qingyan-proxy 已跳过"
      tg_add_kv _m "结论" "未部署"
      tg_add_kv _m "原因" "$GL_REASON"
      tg_add_kv _m "如何配置" "仓库 Settings → Secrets → 新增 GLM_REFRESH_TOKEN（取法见脚本 login 指引）"
      tg_add_footer _m
      send_tg "$_m" || echo "::warning::TG 通知发送失败（不影响任务）"
      exit 0
    fi

    # 1. 准备运行目录（校验 Dropbox 真源在位 + 写 env.sh）
    if bash "$DEPLOY" prepare; then
      # 2. 托管：systemd --user + Restart=always（窗口期崩溃秒级自愈，见 services.sh 文件头）
      # 2026-10-31 修复：ensure 失败不再静默（旧 `|| true` 掩盖过「单元根本
      # 没写盘」的假就绪，见当日两轮「60 秒内未监听 8320」告警）。输出原样
      # 落运行日志，失败打 warning 并标记，让下方 60s 探测给出准确原因。
      if ! _ens_out="$(bash "$SERVICES" ensure qingyan 2>&1)"; then
        printf '%s\n' "$_ens_out"
        echo "::warning::[qingyan] systemd 托管失败（ensure 退出码非零，见上方输出）"
        GL_ENSURE_FAILED=1
      fi
      GL_UP=0
      for _ in $(seq 1 60); do
        if bash "$DEPLOY" status >/dev/null 2>&1; then GL_UP=1; break; fi
        sleep 1
      done
      if [ "$GL_UP" != "1" ]; then
        if [ "$GL_ENSURE_FAILED" = "1" ]; then
          GL_REASON="systemd 托管失败（ensure 退出码非零，见运行日志）"
        else
          GL_REASON="服务未在 60 秒内监听 ${QINGYAN_PORT}（见日志尾部）"
        fi
      else
        # 3. 端到端自检：两个模型各发一条，都返回助手内容才算就绪
        # 2026-10-22 限时（下线优化）：实测该自检曾在 glm-5.3 通过后静默 203s
        # 才等到 glm-5.3-flash（上游慢/重试），把启动链整段拖住。自检只是
        # 「就绪度播报」，不参与服务可用性判定 → 90s 封顶，超时按未通过记录。
        if timeout 90 bash "$DEPLOY" selftest; then
          GL_OK=1
          GL_REASON="GLM-5.3 与 GLM-5.3-Flash 自检均通过"
        else
          GL_REASON="服务已监听但自检未通过（见日志尾部）"
        fi
      fi
    else
      GL_REASON="运行目录准备失败（见日志尾部）"
    fi

    # 积分采集（供「💳 积分」分节）：放在自检之后——上游结算有几秒延迟，
    # 紧贴调用前后读会读到「没变」。采集失败只让通知少一节，不改变就绪结论。
    GL_SCORE=""
    GL_SCORE_RULE=""
    GL_ROUND_DELTA=""
    GL_DAY_TOTAL=""
    GL_SOONEST=""
    GL_SOONEST_AMT=""
    GL_SOON_EXPIRE=""
    if [ "$GL_OK" = "1" ]; then
      # 快照由 QUOTA delta 直接写进 QINGYAN_STATE_DIR（= Dropbox 数据目录，
      # 直写真源）。缺失即首轮，delta 会自动按 0 起算。
      if GLQ="$(bash "$QUOTA" fetch)"; then
        GL_SCORE="$(printf '%s' "$GLQ" | cut -f1)"
        GL_SCORE_RULE="$(printf '%s' "$GLQ" | cut -f2)"
        GL_SOONEST="$(printf '%s' "$GLQ" | cut -f3)"
        GL_SOONEST_AMT="$(printf '%s' "$GLQ" | cut -f4)"
        GL_SOON_EXPIRE="$(printf '%s' "$GLQ" | cut -f5)"
        # 第 2/3 参（2026-10-09 加）：把 fetch 拿到的「最近到期 / 24h 将过期」
        # 一并交给 delta 落进快照 —— 此前快照只存 date/score/day_total，
        # quota-board 想显示「即将过期」根本没有数据源。
        # 快照直写 QINGYAN_STATE_DIR（Dropbox 真源），无需回推。
        if GLD="$(bash "$QUOTA" delta "$GL_SCORE" "$GL_SOONEST" "$GL_SOON_EXPIRE")"; then
          GL_ROUND_DELTA="$(printf '%s' "$GLD" | cut -f1)"
          GL_DAY_TOTAL="$(printf '%s' "$GLD" | cut -f2)"
        fi
      else
        echo "::warning::[qingyan] 积分采集失败，通知将省略积分分节"
      fi
    fi

    if [ "$GL_OK" != "1" ]; then
      _m=""
      tg_add_title _m "❌ qingyan-proxy 启动失败"
      tg_add_kv _m "结论" "未就绪"
      tg_add_path _m "端口" "$QINGYAN_PORT"
      tg_add_kv _m "原因" "$GL_REASON"
      tg_add_path _m "运行目录" "/dropbox/self-hosted/qingyan-proxy/app"
      tg_add_path _m "日志" "/dropbox/self-hosted/qingyan-proxy/logs/qingyan.log"
      tg_add_footer _m
      send_tg "$_m" alert || echo "::warning::TG 通知发送失败（不影响任务）"
    else
      _m=""
      # 2026-10-11 标题对齐全库网关就绪约定：🟢（对齐 workbuddy/zcode2api/trae/Runner，见 docs/telegram-notify.md）
      tg_add_title _m "🟢 qingyan-proxy 已就绪"
      tg_add_kv _m "结论" "$GL_REASON"
      tg_add_path _m "运行目录" "/dropbox/self-hosted/qingyan-proxy/app"
      tg_add_path _m "日志" "/dropbox/self-hosted/qingyan-proxy/logs/qingyan.log"
      tg_add_path _m "代码" "dropbox:self-hosted/qingyan-proxy/app"
      tg_add_path _m "接口" "http://127.0.0.1:${QINGYAN_PORT}/v1"
      # 标签「API Key」+ tg_add_path：对齐 zcode2api 就绪通知同款 —— 值走
      # <code> 等宽，客户端点一下即可整块复制。监听已改 0.0.0.0，key 是唯一
      # 安全边界，通知里给主人一份便于配置客户端（与 8319 的处理一致）。
      tg_add_path _m "API Key" "${QINGYAN_GATEWAY_KEY:-未取到}"
      tg_add_path _m "模型" "glm-5.3 · glm-5.3-flash"
      tg_add_kv _m "计费" "默认通道不扣积分；-agent 后缀走 AgentMore 才扣"
      # 信息层面对齐 wb_notify（主人 2026-10-11 要求）：运行目录 + 日志 + 代码来源。
      # 与下方失败分支同口径；代码真源在 Dropbox（qingyan_deploy.sh 每轮 pull）。

      # 💳 积分分节（版式对齐 zcode2api 的「💳 账号池」：条目行 = 主值 + 状态，
      # 子行 = 明细）。只在采集成功时出现——接口失败时什么都不说，
      # 不把「没取到」谎报成「余额 0」。
      if [ -n "${GL_SCORE:-}" ]; then
        tg_add_section _m "💳 积分 · 1"
        # 单条目结构：条目行手拼 tree_conn、子行手拼 tree_sub。
        # 不能用 tree_lines —— 它把每行都当兄弟条目，子行会被渲染成 ├─/└─
        # 与条目平级（规范 · 二层列表要求子行与条目正文同列）。
        _gl_rows=""
        _gl_rows+="$(tree_conn 1)$(tg_entry "$(printf '%s' "$GL_SCORE")" "今日已消耗 $(printf '%s' "$GL_DAY_TOTAL")")"$'\n'
        [ -n "${GL_ROUND_DELTA:-}" ] && _gl_rows+="$(tree_sub 1)$(escape_html "本轮消耗 ${GL_ROUND_DELTA}（自检产生）")"$'\n'
        # 到期：最近一批 + 7 天内将过期的总额。「-」表示没有带有效期的入账，
        # 此时整行省略——不把「没取到」渲染成「00-00 到期」。
        if [ -n "${GL_SOONEST:-}" ] && [ "$GL_SOONEST" != "-" ]; then
          if [ -n "${GL_SOON_EXPIRE:-}" ] && [ "$GL_SOON_EXPIRE" != "0" ]; then
            _gl_rows+="$(tree_sub 1)$(escape_html "最近到期 ${GL_SOONEST}（该批 ${GL_SOONEST_AMT}）· 7 天内将过期 ${GL_SOON_EXPIRE}")"$'\n'
          else
            _gl_rows+="$(tree_sub 1)$(escape_html "最近到期 ${GL_SOONEST}（该批 ${GL_SOONEST_AMT}）")"$'\n'
          fi
        fi
        [ -n "${GL_SCORE_RULE:-}" ] && _gl_rows+="$(tree_sub 1)$(escape_html "${GL_SCORE_RULE}")"$'\n'
        tg_add_block _m "${_gl_rows%$'\n'}"
      fi
      # 用量 + 流水（信息层面对齐 wb/zcode 通知，主人 2026-10-11 要求）：
      # 调 board.py CLI 与看板共用渲染代码；qingyan 走访问日志+快照特例，
      # 无数据时输出空串静默跳过（与 wb/zcode 同口径）。
      _qy_ul_block="$(python3 /dropbox/self-hosted/quota-board/board.py usage-ledger qingyan 12 2>/dev/null || true)"
      [ -n "$_qy_ul_block" ] && tg_append _m "$_qy_ul_block"
      tg_add_footer _m
      send_tg "$_m" alert || echo "::warning::TG 通知发送失败（不影响任务）"
    fi
  )
  _up_rc=$?
  printf '%s' "$_up_rc" > /tmp/upstream-rc-qingyan
) > /opt/logs/upstream-qingyan.log 2>&1 &
echo "🚀 [P5b] qingyan-proxy 已转后台部署（等齐门在 AI 网关步骤）"
