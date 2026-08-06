#!/bin/bash
# 共享脚本：转码并上传视频到 Telegram 频道
# 用法: process_and_upload.sh <SOURCE_REMOTE> <CHANNEL_ID> <CAPTION_PREFIX>
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE, GITHUB_REPOSITORY, GITHUB_RUN_ID

set +e

SOURCE_REMOTE="$1"
CHANNEL_ID="$2"
CAPTION_PREFIX="$3"

TMP_DIR="/tmp/tg-upload"
mkdir -p "$TMP_DIR"

# 读取 uploaded_videos.txt（记录已上传的文件名），rclone cat 绕过 mount
rclone cat "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null > "$TMP_DIR/uploaded_videos.txt" || touch "$TMP_DIR/uploaded_videos.txt"

# 列出源目录所有视频文件（按修改时间从旧到新排序）
# --format "tp" 输出 TIME;PATH（分隔符为 ;），sort 按时间排序，cut 提取文件名
rclone lsf "$SOURCE_REMOTE/" --files-only --format "tp" 2>/dev/null | sort | cut -d';' -f2- | grep -iE '\.(mp4|mkv|avi|mov|flv|wmv|webm|m4v|ts)$' > "$TMP_DIR/all_videos.txt" || true
TOTAL_VIDEOS=$(wc -l < "$TMP_DIR/all_videos.txt")
if [ "$TOTAL_VIDEOS" -eq 0 ]; then
  echo "WARN: 0 videos found, trying rclone lsf without --format..."
  rclone lsf "$SOURCE_REMOTE/" --files-only 2>&1 | head -20
fi

# 过滤掉已上传的视频
grep -Fxvf "$TMP_DIR/uploaded_videos.txt" "$TMP_DIR/all_videos.txt" > "$TMP_DIR/pending.txt" 2>/dev/null || true
PENDING_COUNT=$(wc -l < "$TMP_DIR/pending.txt" 2>/dev/null || echo 0)

echo "源目录视频总数: $TOTAL_VIDEOS, 待上传: $PENDING_COUNT"

if [ "$PENDING_COUNT" -eq 0 ] || [ ! -s "$TMP_DIR/pending.txt" ]; then
  echo "没有新视频需要上传"
  MSG="📺 ${CAPTION_PREFIX}"$'\n'"📊 源目录: ${TOTAL_VIDEOS} 个视频"$'\n'"✅ 已上传: ${TOTAL_VIDEOS}"$'\n'"⏳ 待上传: 0"$'\n\n'"没有新视频需要上传"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="${MSG}"
  rm -rf "$TMP_DIR"
  exit 0
fi

SENT=0
FAILED=0
SENT_LIST=""
FAILED_LIST=""

# 顺序处理每个视频（不并行，避免 OneDrive 限速和 Telegram API 并发限制）
# 使用 IFS= 和 -r 选项保证读取时保留行首尾空格、不解析转义字符，正确处理含特殊字符的文件名
while IFS= read -r file; do
  # 跳过空行（pending.txt 末尾可能存在空行）
  [ -z "$file" ] && continue

  # 当前视频的工作目录与本地文件路径
  # 每次处理都使用全新的 work 目录，避免上次残留文件干扰
  WORK_DIR="$TMP_DIR/work"
  LOCAL_FILE="$WORK_DIR/$file"

  # 清理并重建工作目录
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  # ===== 第一步：从 OneDrive 下载视频到本地 =====
  # 使用 rclone copy 下载单个文件（不修改远端原文件）
  # 错误输出重定向到独立日志文件，避免 rclone 正常进度信息刷屏，
  # 但在失败时仍可通过日志查看真实错误原因（如文件不存在、限速、网络错误等）
  echo "⬇️  正在下载: $file"
  RCLONE_ERR="$TMP_DIR/rclone_err.log"
  # 双重校验：rclone 命令返回值 + 本地文件是否实际生成
  if ! rclone copy "$SOURCE_REMOTE/$file" "$WORK_DIR/" 2>"$RCLONE_ERR" || [ ! -f "$LOCAL_FILE" ]; then
    echo "❌ FAILED: rclone copy failed: $file"
    echo "--- rclone 错误输出（最近 20 行）---"
    tail -n 20 "$RCLONE_ERR"
    echo "-----------------------------------"
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}（rclone copy failed）"$'\n'
    rm -rf "$WORK_DIR"
    continue
  fi
  echo "✅ 下载完成: $file"

  # 预处理（转码/faststart）并上传到 Telegram
  if bash "${GITHUB_WORKSPACE}/.github/scripts/process_one_file.sh" "$LOCAL_FILE" "$CHANNEL_ID" "$CAPTION_PREFIX"; then
    echo "$file" >> "$TMP_DIR/uploaded_videos.txt"
    SENT=$((SENT + 1))
    SENT_LIST+="- ${file}"$'\n'
  else
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}"$'\n'
  fi

  rm -rf "$WORK_DIR"
done < "$TMP_DIR/pending.txt"

# 上传更新后的 uploaded_videos.txt 到 OneDrive
rclone copyto "$TMP_DIR/uploaded_videos.txt" "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null

# 汇总通知
echo "上传完成: 成功 $SENT, 失败 $FAILED"

MSG="📺 ${CAPTION_PREFIX} 上传完成"$'\n\n'"📊 总计: ${PENDING_COUNT}"$'\n'"✅ 成功: ${SENT}"$'\n'"❌ 失败: ${FAILED}"
if [ -n "$SENT_LIST" ]; then
  MSG+=$'\n\n'"✅ 已上传:"$'\n'"${SENT_LIST}"
fi
if [ -n "$FAILED_LIST" ]; then
  MSG+=$'\n\n'"❌ 失败:"$'\n'"${FAILED_LIST}"
fi
MSG+=$'\n\n'"🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode text="${MSG}"

rm -rf "$TMP_DIR"
