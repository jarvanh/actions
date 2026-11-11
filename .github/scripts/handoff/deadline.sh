#!/usr/bin/env bash
# 死线公式的唯一实现（2026-11-11 抽出来，治「两处各抄一遍」的漂移）
#
# 死线 = job 起点 + (360 硬上限 − 26 收尾预算 − 8 安全余量) = +326 分钟
# 账：326 + 收尾 timeout 30 + 通知/接力 2 = 358 < 360（GitHub 单 job 硬上限）
#
# 用法：
#   deadline.sh            # 打印 KEY=VALUE（可 eval），并写 /tmp/openclaw-deadline.env
# 消费者：
#   · rclone-install（job 起点落盘同刻调用）→ 看板从开机起就能读到正确死线
#   · Keep alive（真正用死线的地方）→ 读同一份，不再自己抄公式
#   · board.py → 读 /tmp/openclaw-deadline.env 的 DEADLINE_MINUTES
#
# 为什么抽出来：2026-11-11 实测看板显示「最终归档」比实际晚 6 分钟 ——
# board.py 曾硬编码 332，改成读文件后，又因为文件只在 Keep alive 步骤才写，
# job 起点到那一步的 ~10 分钟内仍回退 332。现在起点与死线同刻落盘。
set -uo pipefail

HARD_LIMIT_MINUTES="${HARD_LIMIT_MINUTES:-360}"
FINAL_ARCHIVE_BUDGET_MINUTES="${FINAL_ARCHIVE_BUDGET_MINUTES:-26}"
SAFETY_MARGIN_MINUTES="${SAFETY_MARGIN_MINUTES:-8}"
DEADLINE_MINUTES=$(( HARD_LIMIT_MINUTES - FINAL_ARCHIVE_BUDGET_MINUTES - SAFETY_MARGIN_MINUTES ))

printf 'DEADLINE_MINUTES=%s\nHARD_LIMIT_MINUTES=%s\nFINAL_ARCHIVE_BUDGET_MINUTES=%s\nSAFETY_MARGIN_MINUTES=%s\n' \
  "$DEADLINE_MINUTES" "$HARD_LIMIT_MINUTES" "$FINAL_ARCHIVE_BUDGET_MINUTES" "$SAFETY_MARGIN_MINUTES" \
  | tee /tmp/openclaw-deadline.env 2>/dev/null || true
