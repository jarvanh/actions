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

# 发送 Telegram 通知（统一 HTML 排版；明细超长自动分片）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

DIR_LABEL=$(basename "$TARGET_DIR")
msg=""
tg_add_title msg "🧹 ph-dl 清理 yt-dlp 残留文件"
tg_add_path msg "目录" "$DIR_LABEL"
tg_add_kv msg "清理数量" "${FRAG_COUNT} 个"
tg_add_section msg "📋 文件列表"
tg_add_block msg "$FILE_DETAILS"
tg_add_footer msg
send_tg_chunked "$msg"
