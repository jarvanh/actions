#!/bin/bash
# ===== OpenList 同步工具 — rclone 参数单点定义 =====
# 所有 rclone 参数集中在此修改，由 load_all.sh 最先加载，
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

# sync_task 特有参数（rclone sync 模式，删除目标端多余文件，自动追加）
# 禁止加 --delete-excluded: rclone 语义下 filter 排除的文件"不传输也不删除"，
#   这是已修复文件（original/alternative）在 sync 模式下唯一的删除保护；
#   --delete-excluded 会连排除项一起删掉，直接毁掉修复成果。
#   代价: --exclude 匹配的历史文件（如 notion/）会在目标端残留，可接受。
RCLONE_SYNC_TASK_FLAGS=(
  --delete-before
)

# 一次性操作（修复/还原/切割等散点调用）的统一重试参数
# --timeout 各场景不同（2m/5m/10m/15m），由调用方追加在最后
RCLONE_RETRY_FLAGS=(
  --retries 1
  --low-level-retries 3
  --contimeout 30s
)
