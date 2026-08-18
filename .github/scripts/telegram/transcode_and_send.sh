#!/bin/bash
# 共享脚本：预处理（按需转码 + faststart）单个视频文件并上传到 Telegram
# Telegram 流式播放要求：H.264 + AAC + yuv420p + 偶数维度 + faststart
# 用法: transcode_and_send.sh <local_file> <channel_id> <modtime>
# 环境变量: GITHUB_WORKSPACE
# 返回: 0=成功（已上传）, 1=失败, 10=源文件损坏（无法读取编码信息，如 moov atom 缺失）

set +e

LOCAL_FILE="$1"
CHANNEL_ID="$2"
MODTIME="$3"

FILENAME="$(basename "$LOCAL_FILE")"
WORK_DIR="$(dirname "$LOCAL_FILE")"
OUTPUT_FILE="$WORK_DIR/output.mp4"
# ffmpeg stderr 写入日志文件（成功时静默，失败时打印尾部，避免错误细节丢失）
FFMPEG_LOG="$WORK_DIR/ffmpeg.err"

# 打印 ffmpeg 日志尾部（失败排查用）
print_ffmpeg_tail() {
  echo "--- ffmpeg 错误输出(尾部) ---"
  tail -n 30 "$FFMPEG_LOG" 2>/dev/null || echo "(无错误输出)"
  echo "------------------------------"
}

# 检测编码
vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || vcodec=""
acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || acodec=""
pix_fmt=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || pix_fmt=""
width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || width=0
height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$LOCAL_FILE" 2>/dev/null) || height=0

if [ -z "$vcodec" ]; then
  echo "FAILED: cannot read codec: $FILENAME"
  echo "--- ffprobe 错误输出 ---"
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$LOCAL_FILE" 2>&1 | tail -n 20
  echo "------------------------"
  # 退出码 10 = 源文件损坏/无法解析（如 moov atom 缺失），供 sync_to_tg.sh 识别并持久标记跳过
  exit 10
fi

echo "OK: $FILENAME (${width}x${height}, vcodec=$vcodec, acodec=$acodec, pix_fmt=$pix_fmt)"

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

# 检测旋转元数据和非标准 SAR
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

TRANSCODE_START=$SECONDS
if [ "$NEED_REENCODE" -eq 1 ]; then
  # 重编码为 Telegram 兼容格式
  echo "[transcode] 需要转码: $FILENAME ($REASON → h264/yuv420p/aac)"
  if ffmpeg -y -i "$LOCAL_FILE" -map 0:v:0 -map 0:a? -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1" -c:a aac -movflags +faststart "$OUTPUT_FILE" 2> "$FFMPEG_LOG" && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
    TRANSCODE_ELAPSED=$((SECONDS - TRANSCODE_START))
    echo "[transcode] 转码成功: $FILENAME (耗时 ${TRANSCODE_ELAPSED}s)"
  else
    rm -f "$OUTPUT_FILE"
    TRANSCODE_ELAPSED=$((SECONDS - TRANSCODE_START))
    echo "FAILED: transcode failed ($REASON) after ${TRANSCODE_ELAPSED}s: $FILENAME"
    print_ffmpeg_tail
    exit 1
  fi
else
  # 已是兼容格式，仅添加 faststart
  echo "[transcode] 无需转码，仅添加 faststart: $FILENAME"
  if ffmpeg -y -i "$LOCAL_FILE" -c copy -movflags +faststart "$OUTPUT_FILE" 2> "$FFMPEG_LOG" && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
    TRANSCODE_ELAPSED=$((SECONDS - TRANSCODE_START))
    echo "[transcode] faststart 成功: $FILENAME (耗时 ${TRANSCODE_ELAPSED}s)"
  else
    # faststart 失败 → 重编码兜底
    rm -f "$OUTPUT_FILE"
    echo "WARN: faststart failed, re-encoding: $FILENAME"
    tail -n 10 "$FFMPEG_LOG" 2>/dev/null
    if ffmpeg -y -i "$LOCAL_FILE" -map 0:v:0 -map 0:a? -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1" -c:a aac -movflags +faststart "$OUTPUT_FILE" 2> "$FFMPEG_LOG" && mv "$OUTPUT_FILE" "$LOCAL_FILE"; then
      TRANSCODE_ELAPSED=$((SECONDS - TRANSCODE_START))
      echo "[transcode] faststart 失败后重编码成功: $FILENAME (总耗时 ${TRANSCODE_ELAPSED}s)"
    else
      rm -f "$OUTPUT_FILE"
      TRANSCODE_ELAPSED=$((SECONDS - TRANSCODE_START))
      echo "FAILED: faststart + transcode both failed after ${TRANSCODE_ELAPSED}s: $FILENAME"
      print_ffmpeg_tail
      exit 1
    fi
  fi
fi

# 上传到 Telegram
FILESIZE_HUMAN=$(du -h "$LOCAL_FILE" | cut -f1)
FILESIZE_BYTES=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || stat -f%z "$LOCAL_FILE" 2>/dev/null || echo "unknown")
# Caption 分三行：文件名、大小、修改时间
CAPTION="${FILENAME}"$'\n'"${FILESIZE_HUMAN}"$'\n'"${MODTIME}"
echo "[upload] 开始上传 Telegram: $FILENAME (大小 ${FILESIZE_HUMAN} / ${FILESIZE_BYTES} bytes, 修改时间 $MODTIME)"
UPLOAD_START=$SECONDS
# tg_send_video.py 的进度/属性输出属于噪音，重定向到日志文件；仅失败时打印尾部便于排查
UPLOAD_LOG="$WORK_DIR/upload.log"
if python3 "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_send_video.py" "$LOCAL_FILE" "$CHANNEL_ID" "$CAPTION" > "$UPLOAD_LOG" 2>&1; then
  UPLOAD_ELAPSED=$((SECONDS - UPLOAD_START))
  echo "SENT: $FILENAME (上传耗时 ${UPLOAD_ELAPSED}s)"
  exit 0
else
  UPLOAD_ELAPSED=$((SECONDS - UPLOAD_START))
  echo "FAILED: telegram upload failed after ${UPLOAD_ELAPSED}s: $FILENAME"
  echo "--- tg_send_video.py 输出(尾部) ---"
  tail -n 20 "$UPLOAD_LOG" 2>/dev/null || echo "(无输出)"
  echo "-----------------------------------"
  exit 1
fi
