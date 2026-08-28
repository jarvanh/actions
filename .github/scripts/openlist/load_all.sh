#!/bin/bash
# ===== OpenList 同步工具 — 函数库统一加载入口 =====
# 在 workflow 中通过 source 加载所有函数:
#   source "$GITHUB_WORKSPACE/.github/scripts/openlist/load_all.sh"
#
# 命名约定: <领域>_<职责>.sh
#   rclone_*    — rclone 适配层（参数、查询）
#   openlist_*  — OpenList 适配层（管理面 API、驱动与健康）
#   sync_*      — 同步流程（引擎、标记、通知、进度）
#   file_*      — 单文件级操作（分割、修复、修复管线、还原）
#   task_*      — 任务级编排（预览、引擎）
#   utils / telegram / load_all — 基础层，无领域归属
#
# 加载按分层自下而上（L1 → L6），括号内为主要依赖。
# 注: bash 函数在调用时才解析，故顺序不影响正确性；保持分层是为了可读性。

# 获取脚本所在目录（支持 source 和 bash 两种调用方式）
_OPENLIST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- L1 基础层（无内部依赖）---
source "$_OPENLIST_SCRIPT_DIR/rclone_flags.sh"  # rclone 参数单点定义（RCLONE_*_FLAGS）
source "$_OPENLIST_SCRIPT_DIR/utils.sh"         # 通用工具（escape_html, format_bytes 等）
source "$_OPENLIST_SCRIPT_DIR/telegram.sh"      # Telegram 消息发送/编辑/删除

# --- L2 外部服务适配 ---
source "$_OPENLIST_SCRIPT_DIR/rclone_query.sh"  # rclone 查询与过滤解析（size/check/exclude）[utils]
source "$_OPENLIST_SCRIPT_DIR/openlist_api.sh"  # OpenList 服务访问（管理面登录、就绪等待）

# --- L3 领域能力 ---
source "$_OPENLIST_SCRIPT_DIR/file_fix.sh"      # 单文件修复 4 种方法实现（try_fix_failed_file）
source "$_OPENLIST_SCRIPT_DIR/file_split.sh"    # 大文件分割（视频 ffmpeg + 非视频 7z 分卷）
source "$_OPENLIST_SCRIPT_DIR/sync_marker.sh"   # 同步标记系统（跳过/警告/保存）
source "$_OPENLIST_SCRIPT_DIR/sync_progress.sh" # 全局进度通知系统

# --- L4 服务与管线编排 ---
source "$_OPENLIST_SCRIPT_DIR/openlist_driver.sh"   # 驱动维护/健康预检/缓存与 truth-check [openlist_api, file_fix]
source "$_OPENLIST_SCRIPT_DIR/file_fix_pipeline.sh" # 修复管线编排（方法轮换 + 增量持久化）
source "$_OPENLIST_SCRIPT_DIR/sync_notify.sh"       # 同步结果通知构建（tg_* 排版段落）

# --- L5 同步引擎 ---
source "$_OPENLIST_SCRIPT_DIR/sync_engine.sh"   # 核心同步引擎（编排 + 423/8005 重试）

# --- L6 任务层与运维 ---
source "$_OPENLIST_SCRIPT_DIR/file_restore.sh"  # 修复文件一键还原（restore_fixed_files）
source "$_OPENLIST_SCRIPT_DIR/task_preview.sh"  # 任务预览（大小估算 + 流量图）
source "$_OPENLIST_SCRIPT_DIR/task_engine.sh"   # 任务编排（sync_task / run_all_tasks）

# 清理局部变量
unset _OPENLIST_SCRIPT_DIR
