#!/bin/bash
# yt-dlp 下载后处理脚本（Pornhub 收藏专用）
#
# 由 yt-dlp --exec 调用，对刚下载完成的视频执行：
#   1. 清理文件名中的控制字符
#   2. 校验文件完整性（moov atom 存在）
#   3. 文件完好 → 转码/faststart 后上传到 Telegram，再上传到 OneDrive
#   4. 文件损坏 → 删除文件并从 archive.txt 移除 ID（下次重新下载）
#
# 用法: process_ph_download.sh <filepath> <webpage_url>
# 环境变量:
#   SOURCE_REMOTE          - rclone 远程路径（用于上传到 OneDrive）
#   TELEGRAM_CHANNEL_ID    - Telegram 频道 ID（用于上传到频道）
#   GITHUB_WORKSPACE       - Actions 工作目录（用于定位其他脚本）
#   HOME                   - 主目录（用于定位 OneDrive 挂载点）

set +e

FILEPATH="$1"
URL="$2"
FILENAME=$(basename "$FILEPATH")
FILESIZE_HUMAN=$(du -h "$FILEPATH" | cut -f1)
TARGET_DIR="$HOME/onedrive/0/j-1024j-视频-pornhub-favorites"
REMOTE_BASE="$SOURCE_REMOTE"
ARCHIVE_FILE="$TARGET_DIR/archive.txt"
CORRUPTED_LOG="/tmp/ph-dl-downloads/corrupted.txt"

# 如果 FILENAME 包含控制字符或清理后为空，用 URL/ID 生成安全文件名
CLEANED_FILENAME=$(python3 "${GITHUB_WORKSPACE}/.github/scripts/telegram/clean_ytdlp_filename.py" "$FILENAME" "$URL" 2>/dev/null)
[ -z "$CLEANED_FILENAME" ] && CLEANED_FILENAME="$FILENAME"
if [ "$CLEANED_FILENAME" != "$FILENAME" ]; then
  echo "NOTE: cleaned filename '$FILENAME' -> '$CLEANED_FILENAME'"
  CLEANED_FILEPATH="$(dirname "$FILEPATH")/$CLEANED_FILENAME"
  mv "$FILEPATH" "$CLEANED_FILEPATH" 2>/dev/null || true
  FILEPATH="$CLEANED_FILEPATH"
  FILENAME="$CLEANED_FILENAME"
fi

# 验证文件完整性（moov atom 存在）
if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$FILEPATH" 2>/dev/null | grep -q .; then
  echo "Corrupted (no moov atom): $FILENAME"
  rm -f "$FILEPATH"
  # 从 archive.txt 移除视频 ID（格式: id|filename|url），以便下次重新下载
  id="${FILENAME%.*}"
  id="${id##*-}"
  if [ -n "$id" ] && [ -f "$ARCHIVE_FILE" ]; then
    grep -v "^${id}|" "$ARCHIVE_FILE" > "${ARCHIVE_FILE}.tmp" 2>/dev/null && mv "${ARCHIVE_FILE}.tmp" "$ARCHIVE_FILE"
  fi
  echo "$FILENAME" >> "$CORRUPTED_LOG"
  exit 0
fi

# 文件完好，预处理（转码/faststart）并上传到 Telegram
# 直接输出原始 URL，Telegram 自动识别为可点击链接（无需 parse_mode）
echo "- ${FILENAME} (${FILESIZE_HUMAN}) ${URL}" >> new_downloads_list.txt
# 上传成功后，通过独立 Python 脚本原子追加到 uploaded_videos.json（保持 JSON v1 结构，避免 shell >> 破坏格式）
FILESIZE_BYTES=$(stat -c%s "$FILEPATH" 2>/dev/null || stat -f%z "$FILEPATH" 2>/dev/null || echo "")
# 本地文件 mtime 作为 source_modified_at（yt-dlp 下载时间，最接近原始视频修改时间）
SOFTWARE_MODIFIED_AT=$(stat -c%Y "$FILEPATH" 2>/dev/null || stat -f%m "$FILEPATH" 2>/dev/null || echo "")
# 本地文件 birth time 作为 source_created_at（Linux 不支持时 fallback 到 ctime）
SOFTWARE_CREATED_AT=$(stat -c%W "$FILEPATH" 2>/dev/null || echo "0")
if [ "$SOFTWARE_CREATED_AT" = "0" ]; then
  SOFTWARE_CREATED_AT=$(stat -c%Z "$FILEPATH" 2>/dev/null || echo "0")
fi
# 转换为 ISO 8601 UTC
if [ -n "$SOFTWARE_MODIFIED_AT" ] && [ "$SOFTWARE_MODIFIED_AT" != "0" ]; then
  SOURCE_MODIFIED_ISO=$(python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp($SOFTWARE_MODIFIED_AT, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || echo "")
else
  SOURCE_MODIFIED_ISO=""
fi
if [ -n "$SOFTWARE_CREATED_AT" ] && [ "$SOFTWARE_CREATED_AT" != "0" ]; then
  SOURCE_CREATED_ISO=$(python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp($SOFTWARE_CREATED_AT, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null || echo "")
else
  SOURCE_CREATED_ISO=""
fi
if bash ${GITHUB_WORKSPACE}/.github/scripts/telegram/transcode_and_send.sh "${FILEPATH}" "${TELEGRAM_CHANNEL_ID}" "ph"; then
  python3 "${GITHUB_WORKSPACE}/.github/scripts/telegram/add_uploaded_video.py" \
    "${TARGET_DIR}/uploaded_videos.json" \
    "${FILENAME}" \
    ${FILESIZE_BYTES:-0} \
    "${SOURCE_MODIFIED_ISO}" \
    "${SOURCE_CREATED_ISO}"
fi

# 上传到 OneDrive（覆盖已有文件），完成后删除临时文件
if rclone copyto "${FILEPATH}" "${REMOTE_BASE}/${FILENAME}" 2>/dev/null; then
  rm -f "$FILEPATH"
  # 写入 archive.txt（格式: id|filename|url）
  id="${FILENAME%.*}"
  id="${id##*-}"
  echo "${id}|${FILENAME}|${URL}" >> "$ARCHIVE_FILE"
else
  echo "WARN: rclone copyto failed, keeping temp file: $FILENAME"
fi
