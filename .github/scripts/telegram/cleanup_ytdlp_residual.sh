#!/bin/bash
# 清理 yt-dlp 下载过程中产生的残留文件
# 残留文件类型：
#   *.mp4-Frag*、*.part-Frag*   - 未完成的分片下载
#   *.ytdl                       - yt-dlp 临时元数据文件
#   *.m3u8                       - HLS 播放列表残留
#
# 用法: cleanup_ytdlp_residual.sh [target_dir]
#   target_dir  - 待清理的目录路径，默认 ~/onedrive/0/j-1024j-视频-pornhub-favorites
#
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE,
#           GITHUB_REPOSITORY, GITHUB_RUN_ID（用于发送 Telegram 通知）

set +e

TARGET_DIR="${1:-$HOME/onedrive/0/j-1024j-视频-pornhub-favorites}"

if [ ! -d "$TARGET_DIR" ]; then
  echo "目录不存在，跳过清理: $TARGET_DIR"
  exit 0
fi

cd "$TARGET_DIR" || exit 0

# 递归查找 yt-dlp 残留文件（包含子目录）
mapfile -t FRAG_FILES < <(find . -type f \( -name '*.mp4-Frag*' -o -name '*.part-Frag*' -o -name '*.ytdl' -o -name '*.m3u8' \) -print)
FRAG_COUNT=${#FRAG_FILES[@]}

if [ "$FRAG_COUNT" -eq 0 ]; then
  echo "未发现 yt-dlp 残留文件"
  exit 0
fi

# 收集文件名与大小，用于通知
FILE_DETAILS=""
for f in "${FRAG_FILES[@]}"; do
  fname=$(basename "$f")
  fsize=$(du -h "$f" | cut -f1)
  FILE_DETAILS+="🗑 ${fname} (${fsize})
"
done

# 删除残留文件
find . -type f \( -name '*.mp4-Frag*' -o -name '*.part-Frag*' -o -name '*.ytdl' -o -name '*.m3u8' \) -delete
echo "已清理 ${FRAG_COUNT} 个 yt-dlp 残留文件"

# 发送 Telegram 通知（按 4000 字符分片，避免超过 4096 限制）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

DIR_LABEL=$(basename "$TARGET_DIR")
HEADER="🧹 ph-dl 清理 yt-dlp 残留文件"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n'"📁 目录: ${DIR_LABEL}"$'\n'$'\n'"🗑️ 清理数量: ${FRAG_COUNT}"
send_tg "$HEADER"
send_tg_chunked "📋 文件列表"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n\n'"${FILE_DETAILS}"
send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
