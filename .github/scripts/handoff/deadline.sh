#!/usr/bin/env bash
# 死线公式的唯一实现（2026-11-11 抽出来，治「两处各抄一遍」的漂移）
#
# 死线 = job 起点 + (360 硬上限 − 26 收尾预算 − 8 安全余量) = +326 分钟
# 账：326 + 收尾 timeout 30 + 通知/接力 2 = 358 < 360（GitHub 单 job 硬上限）
#
# 数据冻结时刻（2026-11-11 主人语义校正）：
#   「最终归档」原本想表达的是「还有多久当前轮次冻结、之后写入会丢失」。
#   真正的丢数据点是收尾里「2.5 停 OpenClaw 网关」那一刻（快照在停机后打，
#   此后写入不进最终包）。实测：keep-alive 收到收尾请求 12:00:59 →
#   12:01:06 停网关，间隔 7s；正常轮前面还要停 rsstt，最坏 ~70s。
#   取 10s 作为「最早可能冻结」的下界（宁早勿晚：宁可让主人早停 1 分钟，
#   也不要在冻结后还以为能写）。消费者看到的是安全边界。
FREEZE_DELAY_SECONDS="${FREEZE_DELAY_SECONDS:-10}"

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

printf 'DEADLINE_MINUTES=%s\nHARD_LIMIT_MINUTES=%s\nFINAL_ARCHIVE_BUDGET_MINUTES=%s\nSAFETY_MARGIN_MINUTES=%s\nFREEZE_DELAY_SECONDS=%s\n' \
  "$DEADLINE_MINUTES" "$HARD_LIMIT_MINUTES" "$FINAL_ARCHIVE_BUDGET_MINUTES" "$SAFETY_MARGIN_MINUTES" "$FREEZE_DELAY_SECONDS" \
  | tee /tmp/openclaw-deadline.env 2>/dev/null || true
