#!/bin/bash
# ===== OpenList 同步工具 — rclone 参数单点定义 =====
# 所有 rclone 参数集中在此修改，由 load_all.sh 在 L1 层最先加载
# （L0 是通知真源 telegram/tg_notify.sh，比本文件更早），
# workflow 各 step source /tmp/load_all.sh 后自动获得。

# sync_task 共用的默认 rclone 参数
RCLONE_DEFAULT_FLAGS=(
  --progress
  --stats 15s
  --stats-one-line
  --ignore-errors
  --verbose
  --size-only
  --timeout 5m
  --contimeout 30s
  --retries 1
  --low-level-retries 3
)

# sync_task 特有参数（保留为空数组: 调用方展开 "${RCLONE_SYNC_TASK_FLAGS[@]}"，
# 删除数组本身会让未设置 nounset 之外的形态报错，故保留空壳而不是删掉定义）
#
# 不再使用任何 --delete-*（含 --delete-before / --delete-during / --delete-after）:
#   实测（run #12616, 2026-09-11）目标端删除与修复管线互相伤害:
#     - 上一轮以替代形态修复成功的文件，下一轮的 initial sync 把它们当
#       "源端没有的多余文件"删除（该轮 50 个 Deleted + 短哈希目录
#       f21d720a 被整个 Removing directory），随后 truth-check 又把同一批
#       文件判为缺失重新修复 —— 修一轮、删一轮，跨轮净进度为零。
#     - exclude 是文件级的（original + alternative 各一条），目录里只要混有
#       未记录文件就会被逐个删空，目录随之消失，受保护条目照样丢。
#     - 备份语义下目标端是"只增不减"的灾备副本，"源端删了目标端也要删"
#       从来不是需求；误删的代价远大于残留。
#   去掉删除后 sync 退化为 copy 语义（仍用 rclone sync 命令是为了保留
#   --size-only 等既有参数与调用形态），目标端多余文件永久保留。
# 另注: 更不可加 --delete-excluded —— filter 排除项是已修复文件的唯一保护，
#   它会连排除项一起删掉。删除语义已整体移除后该风险不复存在。
RCLONE_SYNC_TASK_FLAGS=()

# 一次性操作（修复/还原/切割等散点调用）的统一重试参数
# --timeout 各场景不同（2m/5m/10m/15m），由调用方追加在最后
RCLONE_RETRY_FLAGS=(
  --retries 1
  --low-level-retries 3
  --contimeout 30s
)
