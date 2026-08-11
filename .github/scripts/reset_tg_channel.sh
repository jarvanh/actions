#!/bin/bash
# 重置 Telegram 频道共享脚本（清空所有消息并删除 uploaded_videos.json）
#
# 流程：
#   1. 调用 clean_tg_channel.py 删除频道内所有消息
#   2. 删除远端 uploaded_videos.json，使下次运行重新处理全部视频
#   3. 发送 Telegram 通知
#
# 用法: reset_tg_channel.sh <channel_id> <workflow_label>
#   channel_id     - Telegram 频道 ID（如 -100xxxxxxxxxx）
#   workflow_label - 通知中显示的工作流名称（如 ph-dl、91-tg）
#
# 环境变量:
#   SOURCE_REMOTE          - rclone 远程路径（用于删除 uploaded_videos.json）
#   TG_API_ID, TG_API_HASH, TG_SESSION_STRING  - Telethon 鉴权信息
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID       - 通知发送凭据
#   GITHUB_WORKSPACE, GITHUB_REPOSITORY, GITHUB_RUN_ID  - Actions 上下文

set +e

CHANNEL_ID="$1"
WORKFLOW_LABEL="$2"

if [ -z "$CHANNEL_ID" ] || [ -z "$WORKFLOW_LABEL" ]; then
  echo "用法: $0 <channel_id> <workflow_label>"
  exit 1
fi

# 安装 telethon（已安装则快速跳过）
pip3 install telethon

# 1. 删除 Telegram 频道所有消息
python3 "${GITHUB_WORKSPACE}/.github/scripts/clean_tg_channel.py" "$CHANNEL_ID"

# 2. 删除 uploaded_videos.json，下次运行会重新处理所有视频
rclone delete "$SOURCE_REMOTE/uploaded_videos.json" 2>/dev/null || true
echo "已删除 uploaded_videos.json"

# 3. 发送通知（使用共享通知脚本，自动处理 429 限流）
source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"
MSG="🧹 ${WORKFLOW_LABEL} 频道清理完成"$'\n\n'"📁 已清空 Telegram 频道所有视频"$'\n'"📄 已删除 uploaded_videos.json（下次运行重新处理全部视频）"$'\n'"🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
send_tg "$MSG"
