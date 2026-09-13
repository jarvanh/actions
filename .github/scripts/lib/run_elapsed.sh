#!/bin/bash
# 本轮已运行秒数 —— 全库统一实现（emby / openlist 等长跑 workflow 共用）
#
# ⚠️ 为什么不能再用 ${{ github.run_started_at }}：
#   GitHub 平台已于 2026-09-05 移除该表达式上下文（API 字段仍在），workflow 里
#   `${{ github.run_started_at }}` 会展开成**空串**。此时
#       ELAPSED=$(( $(date +%s) - $(date -d "${{ github.run_started_at }}" +%s) ))
#   会退化成 `date -d ""`，GNU date 把它当"今天零点"→ ELAPSED 变成"北京时间今天
#   已经过了多久"，而不是本轮跑了多久。实测：run 34720938292 报"运行 664 分钟"
#   （真实 317）、run 34678683486 报"1178"（真实 300）。
#   后果不止是显示错——它同时是两个判断的输入：
#     ① "人工取消不接力"（ELAPSED < 21000）
#     ② 全量备份预算（LEFT = JOB_BUDGET - ELAPSED - ETA）
#   于是 ① 变成"现在是不是 05:50 之前"，② 只要收尾落在 05:00 之后必为负、
#   全量打包永远跳过。**别再照这些数调预算。**
#
# 降级链（与 docs/telegram-notify.md 的收尾区口径一致）：
#   ① TG_RUN_STARTED_AT（非空且能被 date 解析时才用）
#   ② /proc/1 的启动时刻 —— hosted runner 的 PID 1 随 job 启动，误差秒级。
#      job 硬上限 6h 正是按 job 计时的，所以拿它算预算比 run_started_at 更贴切。
# 两者都拿不到时返回 0（调用方需自行决定 0 的含义，别拿 0 当"刚启动"）。
#
# 用法：
#   source "$GITHUB_WORKSPACE/.github/scripts/lib/run_elapsed.sh"
#   ELAPSED=$(run_elapsed_seconds)

run_elapsed_seconds() {
  local started=0 now e
  if [ -n "${TG_RUN_STARTED_AT:-}" ]; then
    started=$(date -d "$TG_RUN_STARTED_AT" +%s 2>/dev/null || echo 0)
    case "$started" in ''|*[!0-9]*) started=0;; esac
  fi
  if [ "$started" -le 0 ] && [ -r /proc/1 ]; then
    started=$(stat -c %Y /proc/1 2>/dev/null || echo 0)
    case "$started" in ''|*[!0-9]*) started=0;; esac
  fi
  [ "$started" -gt 0 ] || { echo 0; return 0; }
  now=$(date +%s)
  e=$(( now - started ))
  [ "$e" -ge 0 ] || e=0
  echo "$e"
}
