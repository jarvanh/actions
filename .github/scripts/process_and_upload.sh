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
rclone lsf "$SOURCE_REMOTE/" --files-only --sort-by modtime 2>/dev/null | grep -iE '\.(mp4|mkv|avi|mov|flv|wmv|webm|m4v|ts)$' > "$TMP_DIR/all_videos.txt" || true
TOTAL_VIDEOS=$(wc -l < "$TMP_DIR/all_videos.txt")

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

# 顺序处理每个视频（不并行）
while IFS= read -r file; do
  [ -z "$file" ] && continue

  WORK_DIR="$TMP_DIR/work"
  LOCAL_FILE="$WORK_DIR/$file"
  OUTPUT_FILE="$WORK_DIR/output.mp4"

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  # 从 OneDrive 下载到本地（不修改原文件）
  if ! rclone copy "$SOURCE_REMOTE/$file" "$WORK_DIR/" 2>/dev/null || [ ! -f "$LOCAL_FILE" ]; then
    echo "FAILED: rclone copy failed: $file"
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}（rclone copy failed）"$'\n'
    rm -rf "$WORK_DIR"
    continue
  fi

  # 检测编码
  vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || vcodec=""
  acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || acodec=""
  pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || pix_fmt=""
  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || width=0
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || height=0

  if [ -z "$vcodec" ]; then
    echo "FAILED: cannot read codec: $file"
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}（cannot read codec）"$'\n'
    rm -rf "$WORK_DIR"
    continue
  fi

  echo "OK: $file (${width}x${height}, vcodec=$vcodec, acodec=$acodec, pix_fmt=$pix_fmt)"

  # Telegram 流式播放要求：H.264 + AAC + yuv420p + 偶数维度 + faststart
  NEED_REENCODE=0
  REASON=""
  if [ "$vcodec" != "h264" ]; then
    NEED_REENCODE=1; REASON="vcodec=$vcodec"
  elif [ "$acodec" != "aac" ]; then
    NEED_REENCODE=1; REASON="acodec=$acodec"
  elif [ "$pix_fmt" != "yuv420p" ]; then
    NEED_REENCODE=1; REASON="pix_fmt=$pix_fmt"
  elif [ $((width % 2)) -ne 0 ] || [ $((height % 2)) -ne 0 ]; then
    NEED_REENCODE=1; REASON="odd dims ${width}x${height}"
  fi

  # 检测旋转元数据和非标准 SAR：
  # stream copy 会原样保留 rotation 和 SAR，Telegram 播放器可能不尊重这些元数据。
  # 重编码时 ffmpeg 会自动应用旋转（autorotate）并通过 setsar=1 归一化像素比例。
  if [ "$NEED_REENCODE" -eq 0 ]; then
    side_data=$(ffprobe -v error -select_streams v:0 -show_entries stream=side_data -of csv=p=0 "$LOCAL_FILE" 2>/dev/null)
    if echo "$side_data" | grep -qi 'rotation'; then
      NEED_REENCODE=1; REASON="has rotation"
    else
      sar=$(ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of csv=p=0 "$LOCAL_FILE" 2>/dev/null)
      if [ -n "$sar" ] && [ "$sar" != "1:1" ] && [ "$sar" != "0:1" ]; then
        NEED_REENCODE=1; REASON="sar=$sar"
      fi
    fi
  fi

  if [ "$NEED_REENCODE" -eq 1 ]; then
    # 重编码为 Telegram 兼容格式（yuv420p + 偶数维度 + faststart）
    echo "Convert: $file ($REASON → h264/yuv420p/aac)"
    if ffmpeg -y -i "$LOCAL_FILE" -map 0:v:0 -map 0:a? -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1" -c:a aac -movflags +faststart "$OUTPUT_FILE" 2>/dev/null && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
      : # 成功
    else
      rm -f "$OUTPUT_FILE"
      echo "FAILED: transcode failed ($REASON): $file"
      FAILED=$((FAILED + 1))
      FAILED_LIST+="- ${file}（transcode failed: ${REASON}）"$'\n'
      rm -rf "$WORK_DIR"
      continue
    fi
  else
    # 已是兼容格式，仅添加 faststart
    echo "Faststart: $file"
    if ffmpeg -y -i "$LOCAL_FILE" -c copy -movflags +faststart "$OUTPUT_FILE" 2>/dev/null && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
      : # 成功
    else
      # faststart 失败 → 重编码兜底
      rm -f "$OUTPUT_FILE"
      echo "WARN: faststart failed, re-encoding: $file"
      if ffmpeg -y -i "$LOCAL_FILE" -map 0:v:0 -map 0:a? -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1" -c:a aac -movflags +faststart "$OUTPUT_FILE" 2>/dev/null && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
        : # 成功
      else
        rm -f "$OUTPUT_FILE"
        echo "FAILED: faststart + transcode both failed: $file"
        FAILED=$((FAILED + 1))
        FAILED_LIST+="- ${file}（faststart + transcode failed）"$'\n'
        rm -rf "$WORK_DIR"
        continue
      fi
    fi
  fi

  # 上传到 Telegram 频道
  FILESIZE_HUMAN=$(du -h "$LOCAL_FILE" | cut -f1)
  if python3 "${GITHUB_WORKSPACE}/.github/scripts/upload_video.py" "$LOCAL_FILE" "$CHANNEL_ID" "${CAPTION_PREFIX}: $file ($FILESIZE_HUMAN)"; then
    echo "$file" >> "$TMP_DIR/uploaded_videos.txt"
    SENT=$((SENT + 1))
    SENT_LIST+="- ${file}"$'\n'
    echo "SENT: $file"
  else
    echo "FAILED: telegram upload failed: $file"
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}（telegram upload failed）"$'\n'
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
