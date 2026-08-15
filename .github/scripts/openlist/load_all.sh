#!/bin/bash
# ===== OpenList 同步工具 — 函数库统一加载入口 =====
# 在 workflow 中通过 source 加载所有函数:
#   source "$GITHUB_WORKSPACE/.github/scripts/openlist/load_all.sh"
#
# 加载顺序遵循依赖关系: 基础工具 → 通知 → 业务逻辑 → 任务编排

# 获取脚本所在目录（支持 source 和 bash 两种调用方式）
_OPENLIST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 按依赖顺序加载所有函数库
source "$_OPENLIST_SCRIPT_DIR/utils.sh"         # 通用工具函数（escape_html, format_bytes 等）
source "$_OPENLIST_SCRIPT_DIR/telegram.sh"       # Telegram 消息发送/编辑/删除
source "$_OPENLIST_SCRIPT_DIR/progress.sh"       # 全局进度通知系统
source "$_OPENLIST_SCRIPT_DIR/split.sh"          # 大文件分割（视频 ffmpeg + 非视频 7z）
source "$_OPENLIST_SCRIPT_DIR/fix.sh"            # 缺失文件修复（try_fix_failed_file）
source "$_OPENLIST_SCRIPT_DIR/sync.sh"           # 核心同步引擎（sync_with_logging）
source "$_OPENLIST_SCRIPT_DIR/marker.sh"         # 同步标记系统（跳过/警告/保存）
source "$_OPENLIST_SCRIPT_DIR/preview.sh"        # 任务预览（大小估算 + 流量图）
source "$_OPENLIST_SCRIPT_DIR/gd_sync.sh"        # Google Drive 专用同步
source "$_OPENLIST_SCRIPT_DIR/tasks.sh"          # 任务编排（sync_task/copy_task/gd_task）
# 注意: rclone 参数数组 (RCLONE_*_FLAGS) 已移至 workflow 文件中定义，便于集中修改

# 清理局部变量
unset _OPENLIST_SCRIPT_DIR
