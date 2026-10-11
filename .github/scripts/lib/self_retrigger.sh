#!/bin/bash
# 自续触发接力 —— 全库统一实现（emby / openlist 既有语义，2026-09-15 抽出供保活型 workflow 复用）
#
# 目的：一轮结束时**立刻**派下一轮，中间不留空档；cron 只当"接力失败时的兜底网"。
#
# 三条判据（顺序固定，任一命中即跳过，且必须把原因写进日志——"跳过"是健康接力链的常态，
# 不是异常，不能静默）：
#   ① 开关关闭（SR_ENABLED=false）
#   ② 人工取消（status=cancelled 且 0 < elapsed < SR_CANCEL_MIN，默认 21000s）：
#      6h 上限触发的取消 elapsed ≈ 21600s，远小于它说明是人手动停的，不该替他续上。
#      ⚠️ elapsed 取不到（==0，Windows runner 无 /proc/1 时的历史形态）**不判人工取消**，
#      否则每轮取消都会被当成人工取消、链永久断掉；此时放行派发（fail-open）。
#   ③ 队列里已有 queued/waiting/pending 的运行：说明下一轮已经排上了（cron 兜底留下的
#      pending，或上一次派发），再派一轮就是叠罗汉
#   ④ 连续失败熔断（SR_CB_THRESHOLD，默认 3，2026-10-11 增补）：本轮失败且此前已有
#      (阈值-1) 轮连续 failure 时停止接力并发 tier=alert 告警——失败接力没有上限会退化
#      成 2 分钟一轮的失败工厂（vaultwarden db.sqlite3 丢失当日实测：全程无人知晓）。
#      成功一轮即自动清零；熔断期间链路由每小时 cron 兜底，根因修完后下一轮自然恢复。
#      计数 API 失败一律放行（fail-open，与②③同一取向：保活优先，宁可多派一轮）；
#      SR_CB_THRESHOLD=0 可关闭。
#
# ⚠️ 判据 ③ 是这套设计能成立的关键：保活型 workflow 的 cron 会在队列里留下 pending，
#   上一轮结束的瞬间它就接管——零空档其实来自这里；接力只在队列**空出来**时（cron 被
#   GitHub 限流、或兜底周期还没到）才真正派发。两个机制互为对方的兜底，谁也不许把谁挤掉。
#
# 用法（各 workflow 的收尾步骤，`if: always()`；job 需 `permissions: actions: write`）：
#   source "$GITHUB_WORKSPACE/.github/scripts/lib/self_retrigger.sh"
#   self_retrigger <workflow 文件名>
#
# 环境变量（都有默认值，按需覆盖）：
#   SR_STATUS      本轮 job 状态，传 "${{ job.status }}"（默认 success）
#   SR_ELAPSED     本轮已运行秒数（默认自动调 run_elapsed_seconds）
#   SR_REPO        仓库（默认 $GITHUB_REPOSITORY）
#   SR_ENABLED     是否允许接力（默认 true，对应 workflow 的 self_retrigger 开关）
#   SR_CANCEL_MIN  人工取消判定阈值秒数（默认 21000）
#   SR_ON_FAILURE  失败轮是否接力（默认 1；纯周期任务可设 0）
#   SR_INPUTS      透传给下一轮的输入，形如 "run_minutes=8&mode=302"
#   SR_LABEL       日志里的名字（默认取 workflow 文件名去掉 .yml）
#   SR_LIMIT       查排队时取多少条（默认 30）
#   SR_CB_THRESHOLD 连续失败熔断阈值（默认 3；0=关闭），见判据④
#
# 返回码：0 = 已派发或按判据跳过（都属正常）；1 = 派发失败（调用方通常 `|| true`，
#         失败时由 cron 兜底，不必让整轮失败）

# 熔断告警（tier=alert）：停止接力若无人知晓，服务就静默躺平到 cron 兜底（最长 1h）。
# 独立成函数便于测试桩替换；tg_notify.sh 缺失/凭据缺失时留痕跳过，不影响接力判定。
self_retrigger_breaker_alert() {
  local label="$1" streak="$2" threshold="$3"
  local notify="${BASH_SOURCE[0]%/*}/../telegram/tg_notify.sh"
  [ -f "$notify" ] || { echo "（tg_notify.sh 缺失，熔断告警未发送）"; return 0; }
  source "$notify" 2>/dev/null || return 0
  local msg=""
  tg_add_title msg "🧯 保活接力已熔断"
  tg_add_kv msg "任务" "${label}"
  tg_add_kv msg "现象" "连续 ${streak} 轮 failure（阈值 ${threshold}），停止自动接力"
  tg_add_note msg "链路由 cron 兜底；根因修复后手动 dispatch 即恢复"
  tg_add_footer msg
  send_tg "$msg" alert || true
}

self_retrigger() {
  local wf="${1:-}"
  local repo="${SR_REPO:-${GITHUB_REPOSITORY:-}}"
  local status="${SR_STATUS:-success}"
  local enabled="${SR_ENABLED:-true}"
  local cancel_min="${SR_CANCEL_MIN:-21000}"
  local on_failure="${SR_ON_FAILURE:-1}"
  local cb_threshold="${SR_CB_THRESHOLD:-3}"
  local label="${SR_LABEL:-${wf%.yml}}"
  local limit="${SR_LIMIT:-30}"
  local elapsed="${SR_ELAPSED:-}" pending="" reason="" kv=""
  local -a args=()

  [ -n "$wf" ] || { echo "self_retrigger: 未指定 workflow 文件名，跳过"; return 0; }
  case "$cb_threshold" in ''|*[!0-9]*) cb_threshold=3;; esac
  if [ "$enabled" != "true" ]; then
    echo "⏭️ 未接力（${label}）：开关关闭"
    return 0
  fi

  # elapsed：优先用调用方算好的；没给就就地算（同目录的 run_elapsed.sh）
  if [ -z "$elapsed" ]; then
    local libdir="${BASH_SOURCE[0]%/*}"
    [ -f "$libdir/run_elapsed.sh" ] && . "$libdir/run_elapsed.sh"
    if command -v run_elapsed_seconds >/dev/null 2>&1; then
      elapsed=$(run_elapsed_seconds)
    else
      elapsed=0
    fi
  fi
  case "$elapsed" in ''|*[!0-9]*) elapsed=0;; esac

  # ⚠️ elapsed==0 表示"取不到"（不是"刚启动"）：Windows runner 无 /proc/1 时恒为 0
  #    （run_elapsed.sh 第 ③ 档），此时若照旧判 `0 < cancel_min` 会把每轮取消都当成
  #    人工取消 → 链永久断掉，只剩 cron 兜底。判据②只在拿得到真实 elapsed 时才生效，
  #    否则放行派发（fail-open，与「排队判据取不到时放行」同一取向：保活型服务可用性
  #    优先，宁可多派一轮让单例并发把它变 pending，也不让服务断档）。
  if [ "$elapsed" -gt 0 ] && [ "$status" = "cancelled" ] && [ "$elapsed" -lt "$cancel_min" ]; then
    reason="人工取消（仅运行 $((elapsed / 60)) 分钟）"
  fi
  if [ "$elapsed" -le 0 ] && [ "$status" = "cancelled" ]; then
    echo "::warning::本轮已运行秒数取不到（elapsed=0），跳过人工取消判定，按接力处理"
  fi
  if [ -z "$reason" ] && [ "$status" = "failure" ] && [ "$on_failure" != "1" ]; then
    reason="本轮失败且未开启失败接力"
  fi
  if [ -z "$reason" ]; then
    # ⚠️ 用 gh 自带的 --jq（Go 实现的 jq），不要管道给外部 jq：
    #    Windows runner 没有 jq 二进制，管道版本会静默退化成"排队数=0"，
    #    这条判据就白设了（叠罗汉只剩单例并发兜着）。
    pending=$(gh run list -R "$repo" --workflow="$wf" --limit "$limit" --json status \
      --jq '[.[] | select(.status == "queued" or .status == "waiting" or .status == "pending")] | length' 2>/dev/null || echo 0)
    case "$pending" in ''|*[!0-9]*) pending=0;; esac
    [ "$pending" -eq 0 ] || reason="队列里已有 ${pending} 个排队运行"
  fi

  # 判据④：连续失败熔断。只在"本轮失败且前面没有其他跳过原因"时才多打一次 API；
  # 成功路径零开销。从最近已完成轮次往回数连续 failure（遇非 failure 即停，本轮的
  # 失败由 status 计入），够阈值就停止接力并发 tier=alert。gh 计数失败 → streak=1
  # → 不达阈值放行（fail-open）。
  if [ -z "$reason" ] && [ "$status" = "failure" ]; then
    local streak=1 prev c
    prev=$(gh run list -R "$repo" --workflow="$wf" --limit "$((cb_threshold + 30))" \
      --json conclusion,status \
      --jq '[.[] | select(.status == "completed") | .conclusion] | .[]' 2>/dev/null || true)
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      [ "$c" = "failure" ] || break
      streak=$((streak + 1))
    done <<< "$prev"
    if [ "$cb_threshold" -gt 0 ] && [ "$streak" -ge "$cb_threshold" ]; then
      reason="连续失败熔断：最近 ${streak} 轮全部 failure（阈值 ${cb_threshold}）"
      self_retrigger_breaker_alert "$label" "$streak" "$cb_threshold"
    fi
  fi

  if [ -n "$reason" ]; then
    echo "⏭️ 未接力（${label}）：${reason}（本轮 ${status}，运行 $((elapsed / 60)) 分钟）"
    return 0
  fi

  # SR_INPUTS 用 & 分隔多个 k=v，转成多个 -f
  if [ -n "${SR_INPUTS:-}" ]; then
    local IFS='&'
    for kv in $SR_INPUTS; do
      [ -n "$kv" ] && args+=(-f "$kv")
    done
    unset IFS
  fi

  if gh workflow run "$wf" -R "$repo" ${args[@]+"${args[@]}"}; then
    echo "✅ 已触发下一轮接力（${label}，本轮 ${status}，运行 $((elapsed / 60)) 分钟）"
    return 0
  fi
  echo "::warning::接力派发失败（${label}）——等 cron 兜底或人工介入"
  return 1
}
