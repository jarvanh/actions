#!/bin/bash
# 自续触发接力 —— 全库统一实现（emby / openlist 既有语义，2026-09-15 抽出供保活型 workflow 复用）
#
# 目的：一轮结束时**立刻**派下一轮，中间不留空档；cron 只当"接力失败时的兜底网"。
#
# 三条判据（顺序固定，任一命中即跳过，且必须把原因写进日志——"跳过"是健康接力链的常态，
# 不是异常，不能静默）：
#   ① 开关关闭（SR_ENABLED=false）
#   ② 人工取消（status=cancelled 且 elapsed < SR_CANCEL_MIN，默认 21000s）：
#      6h 上限触发的取消 elapsed ≈ 21600s，远小于它说明是人手动停的，不该替他续上
#   ③ 队列里已有 queued/waiting/pending 的运行：说明下一轮已经排上了（cron 兜底留下的
#      pending，或上一次派发），再派一轮就是叠罗汉
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
#
# 返回码：0 = 已派发或按判据跳过（都属正常）；1 = 派发失败（调用方通常 `|| true`，
#         失败时由 cron 兜底，不必让整轮失败）

self_retrigger() {
  local wf="${1:-}"
  local repo="${SR_REPO:-${GITHUB_REPOSITORY:-}}"
  local status="${SR_STATUS:-success}"
  local enabled="${SR_ENABLED:-true}"
  local cancel_min="${SR_CANCEL_MIN:-21000}"
  local on_failure="${SR_ON_FAILURE:-1}"
  local label="${SR_LABEL:-${wf%.yml}}"
  local limit="${SR_LIMIT:-30}"
  local elapsed="${SR_ELAPSED:-}" pending="" reason="" kv=""
  local -a args=()

  [ -n "$wf" ] || { echo "self_retrigger: 未指定 workflow 文件名，跳过"; return 0; }
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

  if [ "$status" = "cancelled" ] && [ "$elapsed" -lt "$cancel_min" ]; then
    reason="人工取消（仅运行 $((elapsed / 60)) 分钟）"
  fi
  if [ -z "$reason" ] && [ "$status" = "failure" ] && [ "$on_failure" != "1" ]; then
    reason="本轮失败且未开启失败接力"
  fi
  if [ -z "$reason" ]; then
    pending=$(gh run list -R "$repo" --workflow="$wf" --limit "$limit" --json status 2>/dev/null \
      | jq '[.[] | select(.status == "queued" or .status == "waiting" or .status == "pending")] | length' 2>/dev/null || echo 0)
    case "$pending" in ''|*[!0-9]*) pending=0;; esac
    [ "$pending" -eq 0 ] || reason="队列里已有 ${pending} 个排队运行"
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
