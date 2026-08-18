#!/bin/bash
# ===== OpenList 同步工具 — 大文件分割函数 =====
# 处理超过 OpenList/阿里云盘 4GB 限制的大文件：
#   - 视频文件：使用 ffmpeg 按关键帧分割（无损，-c copy）
#   - 非视频文件：使用 7z 分卷存储模式（可恢复）
#
# 依赖: utils.sh (log_split, check_log_has_content), telegram.sh (send_telegram_message)

# 发送视频分割通知到 Telegram
# 用法: send_video_split_notification <file_path> <file_size> <parts_count> <result> <log_file> [validation_summary]
send_video_split_notification() {
  local file_path="$1"
  local file_size="$2"
  local parts_count="$3"
  local result="$4"
  local log_file="$5"
  local validation_summary="${6:-}"

  local file_size_human
  file_size_human=$(format_bytes_iec "$file_size")

  local message
  if [ "$result" = "success" ]; then
    printf -v message '%s\n%s\n%s\n%s\n%s\n%s' '✅ OpenList 视频分割通知' '━━━━━━━━━━' '状态：分割成功' "文件：$file_path" "原始大小：$file_size_human" "分割数量：$parts_count 个部分"
  else
    printf -v message '%s\n%s\n%s\n%s\n%s\n%s' '❌ OpenList 视频分割通知' '━━━━━━━━━━' '状态：分割失败' "文件：$file_path" "文件大小：$file_size_human" "失败原因：$result"
  fi

  if [ -n "$validation_summary" ]; then
    message+=$'\n\n安全检查：\n'
    message+="$validation_summary"
  fi

  if [ -f "$log_file" ]; then
    local log_status
    log_status=$(check_log_has_content "$log_file")
    if [ "$log_status" = "has_content" ]; then
      local current_file_name
      current_file_name=$(basename -- "$file_path")
      local current_log
      current_log=$(awk -v marker="开始分割视频文件: ${current_file_name}" '
        index($0, marker) { capture=1; buf=$0 "\n"; next }
        capture { buf = buf $0 "\n" }
        END { printf "%s", buf }
      ' "$log_file" 2>/dev/null || true)
      local log_summary
      if [ -n "$current_log" ]; then
        log_summary=$(printf '%s' "$current_log" | tail -c 1200 2>/dev/null || echo "无法读取当前文件日志")
      else
        log_summary=$(tail -c 1200 "$log_file" 2>/dev/null || echo "无法读取日志")
      fi
      message+=$'\n\n日志摘要（当前文件）：\n'
      message+="$log_summary"
    fi
  fi

  send_telegram_message "$message"
}

# 发送非视频 7z 分卷通知到 Telegram
# 用法: send_binary_split_notification <file_path> <file_size> <parts_count> <result> <log_file>
send_binary_split_notification() {
  local file_path="$1"
  local file_size="$2"
  local parts_count="$3"
  local result="$4"
  local log_file="$5"
  local file_size_human
  file_size_human=$(format_bytes_iec "$file_size")
  local message
  if [ "$result" = "success" ]; then
    printf -v message '%s\n%s\n%s\n%s\n%s\n%s\n%s' \
      '✅ OpenList 非视频 7z 分卷通知' \
      '━━━━━━━━━━' \
      '状态：分卷成功' \
      "文件：$file_path" \
      "原始大小：$file_size_human" \
      "分卷数量：$parts_count 个 .7z.00x" \
      '恢复：下载全部分卷后，双击 .7z.001 或运行 7z x 文件名.7z.001'
  else
    printf -v message '%s\n%s\n%s\n%s\n%s\n%s' \
      '❌ OpenList 非视频 7z 分卷通知' \
      '━━━━━━━━━━' \
      '状态：分卷失败' \
      "文件：$file_path" \
      "文件大小：$file_size_human" \
      "失败原因：$result"
  fi
  if [ -f "$log_file" ]; then
    local log_summary
    log_summary=$(tail -c 1200 "$log_file" 2>/dev/null || echo "无法读取日志")
    message+=$'\n\n日志摘要：\n'
    message+="$log_summary"
  fi
  send_telegram_message "$message"
}

# 上传分割日志到 OneDrive（保留最近 10 份，自动清理旧日志）
# 用法: upload_split_log <log_file>
upload_split_log() {
  local log_file="$1"

  if [ -f "$log_file" ] && [ -s "$log_file" ]; then
    local log_status
    log_status=$(check_log_has_content "$log_file")
    if [ "$log_status" = "has_content" ]; then
      local REMOTE_LOG_DIR="onedrive:/logs/video_split"
      log_split "$log_file" "上传分割日志到 OneDrive: $REMOTE_LOG_DIR"
      rclone copyto "$log_file" "$REMOTE_LOG_DIR/$(basename "$log_file")" 2>/dev/null || echo "上传分割日志失败，继续执行"

      # 保留最近 10 份日志，删除更旧的
      rclone lsf "$REMOTE_LOG_DIR/" 2>/dev/null | \
        grep "^video_split_.*\.log$" | \
        sort | head -n -10 | while read -r old_file; do
          echo "删除旧分割日志: $old_file"
          rclone delete "$REMOTE_LOG_DIR/$old_file" 2>/dev/null || true
        done
    else
      log_split "$log_file" "跳过上传空日志文件"
      echo "跳过上传空分割日志: $log_file"
    fi
  else
    echo "分割日志为空或不存在，不上传"
  fi
}

# ===== 视频/非视频切割共用的分片校验、上传、删除助手 =====

# 统计并校验分片大小（结果写入全局 SPLIT_PART_COUNT / SPLIT_OVERSIZED_PARTS）
# 用法: _validate_split_parts <max_part_size> <log_file> <log_label> <part_glob...>
_validate_split_parts() {
  local max_part_size="$1" log_file="$2" log_label="$3"
  shift 3
  SPLIT_PART_COUNT=0
  SPLIT_OVERSIZED_PARTS=""
  local part part_size part_name
  for part in "$@"; do
    [ -f "$part" ] || continue
    SPLIT_PART_COUNT=$((SPLIT_PART_COUNT + 1))
    part_size=$(stat -c%s "$part" 2>/dev/null || stat -f%z "$part" 2>/dev/null || echo 0)
    part_name=$(basename -- "$part")
    log_split "$log_file" "${log_label}: $part_name ($(format_bytes_iec "$part_size"))"
    if [ "$part_size" -gt "$max_part_size" ]; then
      SPLIT_OVERSIZED_PARTS+="${part_name} "
    fi
  done
}

# 上传本地文件到远端目录（输出成功上传数；任一失败即中断并返回 1）
# 用法: _upload_split_parts <remote_dir> <log_file> <log_label> <file_glob...>
_upload_split_parts() {
  local remote_dir="$1" log_file="$2" log_label="$3"
  shift 3
  local count=0 part part_name upload_exit_code
  for part in "$@"; do
    [ -f "$part" ] || continue
    part_name=$(basename -- "$part")
    rclone copyto "$part" "${remote_dir}/${part_name}" --retries 3 --low-level-retries 3 2>&1 | \
      while IFS= read -r line; do
        log_split "$log_file" "rclone upload ${log_label} ${part_name}: $line"
      done
    upload_exit_code=${PIPESTATUS[0]}
    if [ "$upload_exit_code" -ne 0 ]; then
      log_split "$log_file" "上传失败: ${remote_dir}/${part_name} exit=$upload_exit_code"
      echo "$count"
      return 1
    fi
    count=$((count + 1))
  done
  echo "$count"
  return 0
}

# 删除远端原始大文件（日志记录），返回 rclone 退出码
# 用法: _delete_original_file <remote_full_path> <log_file> <log_label>
_delete_original_file() {
  local remote_full="$1" log_file="$2" log_label="$3"
  rclone deletefile "$remote_full" 2>&1 | \
    while IFS= read -r line; do
      log_split "$log_file" "rclone delete ${log_label}: $line"
    done
  return "${PIPESTATUS[0]}"
}

# 视频文件分割函数（使用 ffmpeg -c copy 无损按关键帧分割）
# 用法: split_large_video <remote_path> <remote_source> <local_file_path> <file_name> <video_split_log>
# 流程: 获取时长 → 计算分片数 → ffmpeg 分割 → 验证分片大小 → 上传 → 删除原始文件
# 安全检查: 时长获取、ffmpeg 退出码、分片数量、分片大小、上传结果、删除条件
split_large_video() {
  local remote_path="$1"
  local remote_source="$2"
  local local_file_path="$3"
  local file_name="$4"
  local video_split_log="$5"

  log_split "$video_split_log" "开始分割视频文件: $file_name"
  local base_name extension part_suffix
  if [[ "$file_name" == *.* ]]; then
    base_name="${file_name%.*}"
    extension="${file_name##*.}"
    part_suffix=".${extension}"
  else
    base_name="$file_name"
    extension=""
    part_suffix=""
  fi
  local file_size
  file_size=$(stat -c%s "$local_file_path" 2>/dev/null || echo 0)
  # OpenList/阿里云盘大文件阈值按 4,000,000,000 bytes 处理。
  # 分片目标略低于 4G，尽量贴近上限，同时给封装开销和关键帧边界留余量。
  local max_part_size="${OPENLIST_MAX_PART_SIZE:-4000000000}"
  local target_part_size="${OPENLIST_TARGET_PART_SIZE:-3980000000}"
  local check_duration="⏳ 未执行"
  local check_ffmpeg="⏳ 未执行"
  local check_parts_generated="⏳ 未执行"
  local check_parts_size="⏳ 未执行"
  local check_upload="⏳ 未执行"
  local check_delete="⏳ 未执行"
  local split_validation_summary=""

  # 构建安全检查摘要（用于通知消息）
  build_split_validation_summary() {
    printf -v split_validation_summary '%s\n%s\n%s\n%s\n%s\n%s' \
      "1. 获取/估算视频时长：${check_duration}" \
      "2. ffmpeg 成功退出：${check_ffmpeg}" \
      "3. 至少生成 1 个分片：${check_parts_generated}" \
      "4. 每个分片 ≤ ${max_part_size} bytes：${check_parts_size}" \
      "5. 所有分片上传成功：${check_upload}" \
      "6. 满足以上条件后删除原始文件：${check_delete}"
  }

  # 发送带安全检查摘要的分割通知
  send_split_notification_with_checks() {
    local notify_parts_count="$1"
    local notify_result="$2"
    build_split_validation_summary
    send_video_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "$notify_parts_count" "$notify_result" "$video_split_log" "$split_validation_summary"
  }

  log_split "$video_split_log" "文件大小: $(format_bytes_iec "$file_size")"
  log_split "$video_split_log" "获取视频时长..."

  # 尝试获取视频时长（优先 format duration，降级到 stream duration，再降级到 bit_rate 估算）
  local duration
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$local_file_path" 2>/dev/null | head -n 1 || true)
  if ! echo "$duration" | grep -Eq '^[0-9]+([.][0-9]+)?$' || [ "$(echo "$duration > 0" | bc 2>/dev/null || echo 0)" -ne 1 ]; then
    duration=$(ffprobe -v error -select_streams v:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 "$local_file_path" 2>/dev/null | head -n 1 || true)
  fi
  if ! echo "$duration" | grep -Eq '^[0-9]+([.][0-9]+)?$' || [ "$(echo "$duration > 0" | bc 2>/dev/null || echo 0)" -ne 1 ]; then
    local bit_rate
    bit_rate=$(ffprobe -v error -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$local_file_path" 2>/dev/null | head -n 1 || true)
    if echo "$bit_rate" | grep -Eq '^[0-9]+$' && [ "$bit_rate" -gt 0 ]; then
      duration=$(echo "scale=2; ($file_size * 8) / $bit_rate" | bc 2>/dev/null || echo 0)
      log_split "$video_split_log" "format duration 不可用，按 bit_rate 估算时长: ${duration}s"
    fi
  fi

  # 无法获取时长时改用固定时间分段兜底
  local duration_fallback_mode=0
  if ! echo "$duration" | grep -Eq '^[0-9]+([.][0-9]+)?$' || [ "$(echo "$duration > 0" | bc 2>/dev/null || echo 0)" -ne 1 ]; then
    duration_fallback_mode=1
    duration=0
    check_duration="⚠️ 未获取有效时长，改用固定时间分段兜底"
    log_split "$video_split_log" "无法获取有效视频时长，改用固定时间分段兜底: $file_name"
  else
    check_duration="✅ 通过（duration=${duration}s）"
  fi

  local n=$(( (file_size + target_part_size - 1) / target_part_size ))
  if [ "$n" -lt 2 ]; then n=2; fi
  local max_split_attempts="${OPENLIST_MAX_SPLIT_ATTEMPTS:-4}"
  local safe_base_name
  safe_base_name=$(printf '%s' "$base_name" | tr '/\\' '__')
  local split_dir=""
  local generated_count=0
  local oversized_parts=""
  local part part_size part_name
  local split_success=0
  local attempt=1

  # 多次尝试分割：分片超限时增加分片数后重试
  while [ "$attempt" -le "$max_split_attempts" ]; do
    local segment_count=$((n + attempt - 1))
    local segment_time
    if [ "$duration_fallback_mode" -eq 1 ]; then
      # ffprobe 无法给出 duration 时，仍尝试按固定时间切。
      # 若分片超 4G，后续 attempt 会继续缩短 segment_time 后重切。
      segment_time=$((3600 / attempt))
      if [ "$segment_time" -lt 300 ]; then segment_time=300; fi
    else
      segment_time=$(echo "scale=2; $duration / $segment_count" | bc 2>/dev/null || echo 0)
    fi
    if ! echo "$segment_time" | grep -Eq '^[0-9]+([.][0-9]+)?$' || [ "$(echo "$segment_time > 0" | bc 2>/dev/null || echo 0)" -ne 1 ]; then
      log_split "$video_split_log" "计算分段时长失败: duration=$duration segment_count=$segment_count fallback=$duration_fallback_mode"
      check_ffmpeg="❌ 未执行（分段时长计算失败）"
      check_parts_generated="❌ 未执行（分段时长计算失败）"
      check_parts_size="❌ 未执行（分段时长计算失败）"
      break
    fi

    rm -rf "$split_dir" 2>/dev/null || true
    split_dir="split_${safe_base_name}_$(date +%s)_$$_${attempt}"
    mkdir -p "$split_dir"
    log_split "$video_split_log" "尝试分割: attempt=$attempt segment_count=$segment_count target_part_size=${target_part_size} max_part_size=${max_part_size} segment_time=${segment_time}s"

    ffmpeg -hide_banner -y -i "$local_file_path" -c copy -map 0 -segment_time "$segment_time" -f segment -reset_timestamps 1 -segment_start_number 1 "$split_dir/${base_name} - part%d${part_suffix}" 2>&1 | \
      while IFS= read -r line; do
        log_split "$video_split_log" "ffmpeg: $line"
      done
    local ffmpeg_exit_code=${PIPESTATUS[0]}

    if [ "$ffmpeg_exit_code" -ne 0 ]; then
      log_split "$video_split_log" "ffmpeg 分割命令失败，退出码: $ffmpeg_exit_code"
      check_ffmpeg="❌ 未通过（exit=$ffmpeg_exit_code，已尝试 ${attempt}/${max_split_attempts}）"
      check_parts_generated="❌ 未执行（ffmpeg 失败）"
      check_parts_size="❌ 未执行（ffmpeg 失败）"
      rm -rf "$split_dir" 2>/dev/null || true
      split_dir=""
      if [ "$attempt" -lt "$max_split_attempts" ]; then
        attempt=$((attempt + 1))
        log_split "$video_split_log" "ffmpeg 失败，准备重试下一轮: attempt=$attempt/$max_split_attempts"
        continue
      fi
      break
    fi

    _validate_split_parts "$max_part_size" "$video_split_log" "生成分片" "$split_dir/${base_name} - part"*"${part_suffix}"
    generated_count=$SPLIT_PART_COUNT
    oversized_parts="$SPLIT_OVERSIZED_PARTS"

    if [ "$generated_count" -eq 0 ]; then
      log_split "$video_split_log" "ffmpeg 未生成任何分片"
      check_ffmpeg="✅ 通过"
      check_parts_generated="❌ 未通过（0 个分片）"
      check_parts_size="❌ 未执行（无分片）"
      rm -rf "$split_dir" 2>/dev/null || true
      split_dir=""
      break
    fi

    if [ -z "$oversized_parts" ]; then
      if [ "$duration_fallback_mode" -eq 1 ]; then
        check_duration="⚠️ 未获取有效时长；固定时间分段兜底成功"
      fi
      check_ffmpeg="✅ 通过"
      check_parts_generated="✅ 通过（${generated_count} 个分片）"
      check_parts_size="✅ 通过（全部 ≤ ${max_part_size} bytes）"
      split_success=1
      break
    fi

    check_ffmpeg="✅ 通过"
    check_parts_generated="✅ 通过（${generated_count} 个分片）"
    check_parts_size="❌ 未通过（超限：${oversized_parts}）"
    log_split "$video_split_log" "存在超过阈值的分片，将增加分片数后重试: $oversized_parts"
    attempt=$((attempt + 1))
  done

  # 分割失败：清理并通知
  if [ "$split_success" -ne 1 ]; then
    log_split "$video_split_log" "未能生成全部小于阈值的分片，跳过上传和删除原始文件"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    check_delete="⛔ 未删除（前置检查未通过）"
    send_split_notification_with_checks "$generated_count" "分片仍超过阈值或生成失败，已保留原始文件"
    return 1
  fi

  # 上传所有分片
  local part_count=0
  local upload_failed=0
  part_count=$(_upload_split_parts "${remote_source}:${remote_path}" "$video_split_log" "part" "$split_dir/${base_name} - part"*"${part_suffix}") || upload_failed=1

  # 上传失败：保留原始文件
  if [ "$upload_failed" -ne 0 ] || [ "$part_count" -ne "$generated_count" ]; then
    log_split "$video_split_log" "分片上传未全部成功，已上传 $part_count/$generated_count；保留原始大文件"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    check_upload="❌ 未通过（已上传 $part_count/$generated_count）"
    check_delete="⛔ 未删除（分片上传未全部成功）"
    send_split_notification_with_checks "$part_count" "分片上传失败，已保留原始文件"
    return 1
  fi

  check_upload="✅ 通过（${part_count}/${generated_count}）"

  # 所有分片上传成功后删除原始大文件
  if ! _delete_original_file "${remote_source}:${remote_path}/${file_name}" "$video_split_log" "original"; then
    log_split "$video_split_log" "删除原始大文件失败: ${remote_source}:${remote_path}/${file_name}"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    check_delete="❌ 未通过（删除命令失败）"
    send_split_notification_with_checks "$part_count" "删除原始文件失败"
    return 1
  fi

  log_split "$video_split_log" "已删除原始大文件: ${remote_source}:${remote_path}/${file_name}"
  rm -f "$local_file_path" 2>/dev/null || true
  rm -rf "$split_dir" 2>/dev/null || true
  echo "$(date +%Y-%m-%d_%H:%M:%S) - ${remote_source}:${remote_path}/${file_name} - 分割成 $part_count 个部分" >> "$PROCESSED_FILES_LOG"
  check_delete="✅ 已删除（全部前置条件已满足）"
  send_split_notification_with_checks "$part_count" "success"
  return 0
}

# 非视频大文件使用 7z 分卷存储模式分割
# 恢复方式：下载全部 .7z.00x 后，双击 .7z.001 或执行 7z x 文件名.7z.001
# 用法: split_large_binary_file <remote_path> <remote_source> <local_file_path> <file_name> <video_split_log>
# 附加产物: .sha256（校验文件）, .restore.txt（恢复说明）
split_large_binary_file() {
  local remote_path="$1"
  local remote_source="$2"
  local local_file_path="$3"
  local file_name="$4"
  local video_split_log="$5"

  local file_size
  file_size=$(stat -c%s "$local_file_path" 2>/dev/null || echo 0)
  local max_part_size="${OPENLIST_MAX_PART_SIZE:-4000000000}"
  local volume_size="${OPENLIST_7Z_VOLUME_SIZE:-3810m}"
  local split_dir="binary_split_$(printf '%s' "$file_name" | tr '/\\' '__')_$(date +%s)_$$"
  mkdir -p "$split_dir"

  log_split "$video_split_log" "开始非视频 7z 分卷: $file_name"
  log_split "$video_split_log" "文件大小: $(format_bytes_iec "$file_size") volume_size=${volume_size} max_part_size=${max_part_size}"

  local abs_split_dir
  abs_split_dir="$(cd "$split_dir" && pwd)"
  local local_dir
  local_dir="$(dirname -- "$local_file_path")"
  local local_base
  local_base="$(basename -- "$local_file_path")"

  # 7z 分卷压缩（-t7z -mx=0 存储模式，不压缩只分卷）
  (cd "$local_dir" && 7z a -t7z -mx=0 -v"$volume_size" "$abs_split_dir/${file_name}.7z" "$local_base") 2>&1 | \
    while IFS= read -r line; do
      log_split "$video_split_log" "7z: $line"
    done
  local seven_zip_exit_code=${PIPESTATUS[0]}
  if [ "$seven_zip_exit_code" -ne 0 ]; then
    log_split "$video_split_log" "7z 分卷失败，退出码: $seven_zip_exit_code"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "0" "7z 分卷失败，已保留原始文件" "$video_split_log"
    return 1
  fi

  # 验证分卷大小
  local generated_count=0
  local oversized_parts=""
  local part part_size part_name
  _validate_split_parts "$max_part_size" "$video_split_log" "生成 7z 分卷" "$split_dir/${file_name}.7z."*
  generated_count=$SPLIT_PART_COUNT
  oversized_parts="$SPLIT_OVERSIZED_PARTS"

  if [ "$generated_count" -eq 0 ]; then
    log_split "$video_split_log" "7z 未生成任何分卷，跳过删除原始文件"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "0" "未生成 7z 分卷，已保留原始文件" "$video_split_log"
    return 1
  fi

  if [ -n "$oversized_parts" ]; then
    log_split "$video_split_log" "存在超过阈值的 7z 分卷，跳过上传和删除原始文件: $oversized_parts"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "$generated_count" "7z 分卷仍超过阈值，已保留原始文件" "$video_split_log"
    return 1
  fi

  # 生成 SHA256 校验文件和恢复说明
  (cd "$local_dir" && sha256sum "$local_base") > "$split_dir/${file_name}.sha256" 2>/dev/null || true
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    '恢复方式：' \
    "1. 下载全部 ${file_name}.7z.00x 分卷到同一目录。" \
    "2. 双击 ${file_name}.7z.001，或运行：" \
    "   7z x '${file_name}.7z.001'" \
    "3. 解压后会得到原文件：${file_name}" \
    '4. 如需校验，运行：' \
    "   sha256sum -c '${file_name}.sha256'" \
    > "$split_dir/${file_name}.restore.txt"

  # 上传分卷 + 辅助文件
  local upload_count=0
  local upload_failed=0
  upload_count=$(_upload_split_parts "${remote_source}:${remote_path}" "$video_split_log" "binary part" "$split_dir/${file_name}.7z."* "$split_dir/${file_name}.sha256" "$split_dir/${file_name}.restore.txt") || upload_failed=1

  local expected_upload_count=$((generated_count + 2))
  if [ "$upload_failed" -ne 0 ] || [ "$upload_count" -ne "$expected_upload_count" ]; then
    log_split "$video_split_log" "非视频分卷上传未全部成功，已上传 $upload_count/$expected_upload_count；保留原始大文件"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "$generated_count" "分卷上传失败，已保留原始文件" "$video_split_log"
    return 1
  fi

  # 删除原始大文件
  if ! _delete_original_file "${remote_source}:${remote_path}/${file_name}" "$video_split_log" "original binary"; then
    log_split "$video_split_log" "删除原始非视频大文件失败: ${remote_source}:${remote_path}/${file_name}"
    rm -f "$local_file_path" 2>/dev/null || true
    rm -rf "$split_dir" 2>/dev/null || true
    send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "$generated_count" "删除原始文件失败" "$video_split_log"
    return 1
  fi

  log_split "$video_split_log" "已删除原始非视频大文件: ${remote_source}:${remote_path}/${file_name}"
  rm -f "$local_file_path" 2>/dev/null || true
  rm -rf "$split_dir" 2>/dev/null || true
  send_binary_split_notification "${remote_source}:${remote_path}/${file_name}" "$file_size" "$generated_count" "success" "$video_split_log"
  return 0
}

# 对指定源目录中的超阈值大文件进行切割
# 根据文件扩展名自动选择视频（ffmpeg）或非视频（7z）分割方式
# 用法: preprocess_large_files <source_path> <task_name>
preprocess_large_files() {
  local source_path="$1"
  local task_name="$2"
  local large_file_threshold="${LARGE_FILE_THRESHOLD_BYTES:-4000000000}"

  local remote_source="${source_path%%:*}"
  local remote_path="${source_path#*:}"
  remote_path="${remote_path#/}"
  remote_path="${remote_path%/}"

  if [ -z "$remote_source" ] || [ -z "$remote_path" ] || [ "$remote_source" = "$source_path" ]; then
    echo "无法解析源路径，跳过大文件预处理: $source_path"
    return 0
  fi

  echo "=== OpenList 前置大文件预处理: $source_path ($task_name) ==="

  local video_split_log="video_split_pre_${task_name}_$(date +%Y%m%d_%H%M%S).log"
  echo "=== OpenList 前置大文件分割日志 - 开始于 $(date) ===" > "$video_split_log"
  local processed_count=0
  local success_count=0
  local failed_count=0
  local processed_files=""
  local deleted_files=""
  local failed_files=""

  while IFS=$'\t' read -r file_size relative_path; do
    [ -n "$relative_path" ] || continue

    # 根据扩展名判断分割方式
    local split_kind="binary"
    case "$relative_path" in
      *.mp4|*.mkv|*.mov|*.avi|*.flv|*.webm|*.m4v|*.wmv|*.mpg|*.mpeg|*.3gp|*.mp3|*.wav|*.aac|*.flac|*.m4a)
        split_kind="media"
        ;;
    esac

    local full_path="${remote_path}/${relative_path}"
    local file_name
    file_name="$(basename -- "$relative_path")"
    local file_dir
    file_dir="$(dirname -- "$full_path")"
    if [ "$file_dir" = "." ]; then
      file_dir="$remote_path"
    fi

    processed_count=$((processed_count + 1))
    local temp_dir="temp_video_pre_split_$(date +%s)_${processed_count}"
    mkdir -p "$temp_dir"

    log_split "$video_split_log" "下载待分割大文件: ${remote_source}:${full_path}"
    rclone copyto "${remote_source}:${full_path}" "$temp_dir/$file_name" --progress --stats 15s --stats-one-line 2>&1 | \
      while IFS= read -r line; do log_split "$video_split_log" "rclone copy: $line"; done
    local copy_exit_code=${PIPESTATUS[0]}

    local split_success=1
    if [ "$copy_exit_code" -eq 0 ] && [ -f "$temp_dir/$file_name" ]; then
      if [ "$split_kind" = "media" ]; then
        split_large_video "$file_dir" "$remote_source" "$temp_dir/$file_name" "$file_name" "$video_split_log" || split_success=0
      else
        split_large_binary_file "$file_dir" "$remote_source" "$temp_dir/$file_name" "$file_name" "$video_split_log" || split_success=0
      fi
    else
      split_success=0
    fi

    if [ "$split_success" -eq 1 ]; then
      success_count=$((success_count + 1))
      processed_files+="• ${remote_source}:${full_path} ($(format_bytes_iec "$file_size"), ${split_kind})"$'\n'
      deleted_files+="• ${remote_source}:${full_path}"$'\n'
      echo "$(date +%Y-%m-%d_%H:%M:%S) - ${remote_source}:${full_path} - OpenList 前置分割成功(${split_kind})，已删除原始大文件" >> "$PROCESSED_FILES_LOG"
    else
      failed_count=$((failed_count + 1))
      failed_files+="• ${remote_source}:${full_path}"$'\n'
      log_split "$video_split_log" "OpenList 前置分割失败: ${remote_source}:${full_path}"
    fi

    rm -rf "$temp_dir" 2>/dev/null || true
  done < <(
    rclone lsjson "$source_path" --recursive --files-only 2>/dev/null | \
      jq -r --argjson threshold "$large_file_threshold" \
        '.[] | select((.Size // 0) > $threshold) | [(.Size | tostring), .Path] | @tsv'
  )

  upload_split_log "$video_split_log"

  # 发送处理总结通知
  if [ "$processed_count" -gt 0 ]; then
    local summary_message
    printf -v summary_message '%s\n%s\n%s\n%s\n%s\n%s' \
      '📊 OpenList 前置大文件处理总结' \
      '━━━━━━━━━━' \
      "任务：$task_name" \
      "尝试处理：$processed_count" \
      "处理成功：$success_count" \
      "处理失败：$failed_count"
    if [ -n "$processed_files" ]; then
      summary_message+=$'\n\n✂️ 已切割文件：\n'
      summary_message+="$processed_files"
    fi
    if [ -n "$deleted_files" ]; then
      summary_message+=$'\n🗑️ 已删除 OneDrive 原始大文件：\n'
      summary_message+="$deleted_files"
    fi
    if [ -n "$failed_files" ]; then
      summary_message+=$'\n⚠️ 处理失败文件：\n'
      summary_message+="$failed_files"
    fi
    send_telegram_message "$summary_message"
  fi

  rm -f "$video_split_log" 2>/dev/null || true
  return 0
}

# 同步失败后的补救措施: 对源目录中的超阈值大文件执行切割
# 受 OPENLIST_SPLIT_ON_SYNC_FAILURE 环境变量开关控制（默认关闭）
# 注意: 任务结束时无论成败都会走到这里检查一次开关，
#       关闭时的"跳过"提示只是开关状态通知，不代表同步失败
# 用法: split_on_sync_failure <source_path> <task_name>
split_on_sync_failure() {
  local source_path="$1"
  local task_name="$2"
  local switch_value="${OPENLIST_SPLIT_ON_SYNC_FAILURE:-false}"
  case "$switch_value" in
    true|TRUE|1|yes|YES|on|ON) ;;
    *)
      echo "大文件切割开关关闭 (split_on_sync_failure=false)，跳过切割处理: task=${task_name} source=${source_path}（仅开关状态通知，不代表同步失败）"
      return 0
      ;;
  esac

  echo "大文件切割开关已开启 (split_on_sync_failure=true)，开始检查超阈值大文件: task=${task_name} source=${source_path}"
  preprocess_large_files "$source_path" "$task_name"
}
