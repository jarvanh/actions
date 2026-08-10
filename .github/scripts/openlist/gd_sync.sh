#!/bin/bash
# ===== OpenList 同步工具 — Google Drive 同步函数 =====
# Google Drive 专用同步逻辑，处理 GD 特有的错误:
#   - storageQuotaExceeded（存储配额超限）
#   - object not found（源文件不存在）
#   - rateLimitExceeded / userRateLimitExceeded / dailyLimitExceeded（API 限流）
#   - forbidden / unauthorized / permission denied（权限问题）
#
# 依赖: utils.sh, telegram.sh, marker.sh (check_sync_marker, save_sync_marker)
# 依赖环境变量:
#   TELEGRAM_BOT_TOKEN — 用于发送日志文件
#   TELEGRAM_CHAT_ID   — 用于发送日志文件

# Google Drive 同步实现
# 用法: _gd_sync <source_path> <dest_path> <task_name> [rclone_extra_args...]
# 设置全局变量: SYNC_SKIPPED, SYNC_FAILED, SYNC_TRANSFERRED_BYTES
_gd_sync() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  # 初始化全局状态变量
  SYNC_SKIPPED=0
  SYNC_FAILED=0
  SYNC_TRANSFERRED_BYTES=0

  # 保存/恢复 phase/stats
  local _old_phase="${PROGRESS_PHASE_INFO:-}"
  local _old_stats="${PROGRESS_STATS:-}"
  PROGRESS_PHASE_INFO=""
  PROGRESS_STATS=""

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "${task_name}_gd"

    case "$MARKER_ACTION" in
      skip)
        echo "跳过 ${task_name} GD: $((SYNC_SKIP_SECONDS / 3600))小时内已成功同步"
        send_sync_skipped "${task_name} GD" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        PROGRESS_PHASE_INFO="$_old_phase"
        PROGRESS_STATS="$_old_stats"
        return 0
        ;;
      warning)
        send_sync_warning "${task_name} GD" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        PROGRESS_PHASE_INFO="$_old_phase"
        PROGRESS_STATS="$_old_stats"
        return 0
        ;;
    esac
  fi

  echo "执行 ${task_name} GD 同步"
  progress_update "Google Drive 同步中..."

  local TIMESTAMP
  local LOG_FILENAME
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  LOG_FILENAME="${task_name}_gd_sync_${TIMESTAMP}.log"
  LAST_GD_ATTEMPT_LOG="${LOG_FILENAME}.last"

  # 执行一次 GD 同步
  run_gd_sync_once() {
    local attempt_label="$1"
    shift
    local attempt_args=("$@")

    echo "=== ${task_name} ${attempt_label} ===" | tee -a "$LOG_FILENAME"
    echo "GD sync args: ${attempt_args[*]}" | tee -a "$LOG_FILENAME"
    : > "$LAST_GD_ATTEMPT_LOG"

    set +e
    rclone sync "$source_path" "$dest_path" \
      "${attempt_args[@]}" \
      --progress \
      --stats 15s \
      --stats-one-line \
      --ignore-errors \
      --verbose \
      --retries 1 \
      2>&1 | tee "$LAST_GD_ATTEMPT_LOG"
    local status=${PIPESTATUS[0]}
    set -e

    cat "$LAST_GD_ATTEMPT_LOG" >> "$LOG_FILENAME"
    return "$status"
  }

  : > "$LOG_FILENAME"
  local SYNC_STATUS=0
  run_gd_sync_once "initial sync" "${extra_args[@]}" || SYNC_STATUS=$?

  # 获取源端和目标端大小及文件数量
  local gd_src_size="未知"
  local gd_dst_size="未知"
  local gd_src_count="未知"
  local gd_dst_count="未知"
  local gd_count_info=""
  local gd_diff_files_list=""
  local gd_src_stats gd_dst_stats

  gd_src_stats=$(_get_path_stats "$source_path" "${extra_args[@]}")
  gd_src_count=$(echo "$gd_src_stats" | awk '{print $2}')
  gd_src_size=$(echo "$gd_src_stats" | awk '{print $3 ($4? " "$4 : "")}')
  [ "$gd_src_count" = "0" ] && gd_src_count="未知"

  gd_dst_stats=$(_get_path_stats "$dest_path" "${extra_args[@]}")
  gd_dst_count=$(echo "$gd_dst_stats" | awk '{print $2}')
  gd_dst_size=$(echo "$gd_dst_stats" | awk '{print $3 ($4? " "$4 : "")}')
  [ "$gd_dst_count" = "0" ] && gd_dst_count="未知"

  if [[ "$gd_src_count" =~ ^[0-9]+$ ]] && [[ "$gd_dst_count" =~ ^[0-9]+$ ]]; then
    local gd_diff=$((gd_src_count - gd_dst_count))
    if [ "$gd_diff" -ne 0 ]; then
      gd_count_info="文件数差异：${gd_diff} (源端 ${gd_src_count} / 目标 ${gd_dst_count})"
      gd_diff_files_list=$(_build_diff_files_list "$source_path" "$dest_path" "${extra_args[@]}")
    else
      gd_count_info="文件数：${gd_src_count} (一致)"
    fi
  else
    gd_count_info="文件数：源端 ${gd_src_count} / 目标 ${gd_dst_count}"
  fi

  # 提取 --exclude 规则，方便在通知中说明
  local gd_exclude_list=""
  gd_exclude_list=$(_build_exclude_bullets "${extra_args[@]}")

  # ===== 根据同步结果发送通知 =====

  if grep -Eqi 'storageQuotaExceeded|storage quota has been exceeded' "$LAST_GD_ATTEMPT_LOG"; then
    # Google Drive 存储配额超限，跳过同步，发送通知，不阻止后续 task
    SYNC_SKIPPED=1
    SYNC_FAILED=0
    local quota_msg
    printf -v quota_msg '%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s' \
      "⚠️ ${task_name} Google Drive 存储配额超限" \
      '━━━━━━━━━━━━━━' \
      "源端大小：${gd_src_size}" \
      "目标大小：${gd_dst_size}" \
      "状态：配额超限，跳过本次同步" \
      "$gd_count_info" \
      '📁 任务信息' \
      "• 任务：${task_name}" \
      "• 源端：${source_path}" \
      "• 目标：${dest_path}" \
      '🚫 排除规则' \
      "$gd_exclude_list"

    send_telegram_message "$quota_msg"

  elif grep -Eqi 'ERROR : .+: Failed to copy.*object not found' "$LAST_GD_ATTEMPT_LOG" 2>/dev/null; then
    # object not found（源文件不存在），使用结构化通知
    SYNC_FAILED=1
    local gd_fail_summary=""
    local gd_fail_idx=0
    while IFS= read -r failed_line; do
      [ -z "$failed_line" ] && continue
      gd_fail_idx=$((gd_fail_idx + 1))
      [ -n "$gd_fail_summary" ] && gd_fail_summary+=$'\n'
      gd_fail_summary+="[${gd_fail_idx}] 源文件：${source_path}/${failed_line}"$'\n'
      gd_fail_summary+="    目标文件：${dest_path}/${failed_line}"$'\n'
      gd_fail_summary+="    失败原因：源文件不存在 (object not found)"$'\n'
    done < <(
      grep -E 'ERROR : .+: Failed to copy.*object not found' "$LAST_GD_ATTEMPT_LOG" 2>/dev/null | \
        sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
    )
    [ -z "$gd_fail_summary" ] && gd_fail_summary="无"

    local onf_msg=""
    onf_msg+="⚠️ ${task_name} Google Drive 同步部分文件失败"$'\n'
    onf_msg+='━━━━━━━━━━━━━━'$'\n'
    onf_msg+="源端大小：${gd_src_size}"$'\n'
    onf_msg+="目标大小：${gd_dst_size}"$'\n'
    onf_msg+="状态：源文件不存在 (object not found)，部分文件无法同步"$'\n'
    onf_msg+="${gd_count_info}"$'\n'
    onf_msg+=$'\n''📁 任务信息'$'\n'
    onf_msg+="• 任务：${task_name}"$'\n'
    onf_msg+="• 源端：${source_path}"$'\n'
    onf_msg+="• 目标：${dest_path}"$'\n'
    onf_msg+=$'\n''🚫 排除规则'$'\n'
    onf_msg+="${gd_exclude_list}"$'\n'
    onf_msg+=$'\n''❌ 无法同步文件：'$'\n'
    onf_msg+="${gd_fail_summary}"
    if [ -n "$gd_diff_files_list" ]; then
      onf_msg+=$'\n\n'"📋 差异文件列表："$'\n'
      onf_msg+="$gd_diff_files_list"
    fi
    send_telegram_message "$onf_msg"
    # 同时发送完整日志文件
    local gd_log_size
    gd_log_size=$(stat -c%s "$LOG_FILENAME" 2>/dev/null || echo 0)
    if [ "$gd_log_size" -gt 0 ] && [ "$gd_log_size" -lt 50000000 ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"$LOG_FILENAME" \
        -F caption="📁 ${task_name} GD 错误日志" || true
    fi

  elif [ "$SYNC_STATUS" -ne 0 ] || grep -Eqi 'forbidden|rateLimitExceeded|userRateLimitExceeded|dailyLimitExceeded|ERROR|Failed|timeout|unauthorized|permission denied|connection refused|upload chunks may be taking too long' "$LAST_GD_ATTEMPT_LOG"; then
    # GD API 错误或通用同步错误
    SYNC_FAILED=1
    local gd_is_partial_failure=0
    if [[ "$gd_src_count" =~ ^[0-9]+$ ]] && [[ "$gd_dst_count" =~ ^[0-9]+$ ]] && \
       [ "$gd_dst_count" -gt 0 ] && [ "$gd_dst_count" -lt "$gd_src_count" ]; then
      gd_is_partial_failure=1
    fi
    local gd_critical_logs="无明显错误关键字"
    if [ -f "$LOG_FILENAME" ]; then
      gd_critical_logs=$(grep -Ei "error|failed|too large|timeout|permission denied|connection refused" "$LOG_FILENAME" | tail -n 5 || echo "无明显错误关键字")
    fi
    local gd_err_msg=""
    if [ "$gd_is_partial_failure" -eq 1 ]; then
      gd_err_msg+="⚠️ ${task_name} Google Drive 部分文件同步失败"$'\n'
    else
      gd_err_msg+="⚠️ ${task_name} Google Drive 同步失败"$'\n'
    fi
    gd_err_msg+='━━━━━━━━━━━━━━'$'\n'
    gd_err_msg+="源端大小：${gd_src_size}"$'\n'
    gd_err_msg+="目标大小：${gd_dst_size}"$'\n'
    if [ "$gd_is_partial_failure" -eq 1 ]; then
      gd_err_msg+="状态：部分文件同步失败 (exit=${SYNC_STATUS})"$'\n'
    else
      gd_err_msg+="状态：Google Drive 同步失败 (exit=${SYNC_STATUS})"$'\n'
    fi
    gd_err_msg+="${gd_count_info}"$'\n'
    gd_err_msg+=$'\n''📁 任务信息'$'\n'
    gd_err_msg+="• 任务：${task_name}"$'\n'
    gd_err_msg+="• 源端：${source_path}"$'\n'
    gd_err_msg+="• 目标：${dest_path}"$'\n'
    gd_err_msg+=$'\n''🚫 排除规则'$'\n'
    gd_err_msg+="${gd_exclude_list}"$'\n'
    gd_err_msg+=$'\n''🧾 错误详情'$'\n'
    gd_err_msg+="• 关键日志："$'\n'
    while IFS= read -r line; do
      [ -n "$line" ] && gd_err_msg+="  ${line}"$'\n'
    done <<< "$gd_critical_logs"
    if [ -n "$gd_diff_files_list" ]; then
      gd_err_msg+=$'\n'"📋 差异文件列表："$'\n'
      gd_err_msg+="$gd_diff_files_list"
    fi
    send_telegram_message "$gd_err_msg"
    # 发送完整日志文件
    local gd_err_log_size
    gd_err_log_size=$(stat -c%s "$LOG_FILENAME" 2>/dev/null || echo 0)
    if [ "$gd_err_log_size" -gt 0 ] && [ "$gd_err_log_size" -lt 50000000 ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"$LOG_FILENAME" \
        -F caption="📁 ${task_name} GD 错误日志" || true
    fi

  else
    # 同步返回成功，检查是否有文件缺失（部分失败）
    local gd_is_partial_success=0
    if [[ "$gd_src_count" =~ ^[0-9]+$ ]] && [[ "$gd_dst_count" =~ ^[0-9]+$ ]] && \
       [ "$gd_dst_count" -gt 0 ] && [ "$gd_dst_count" -lt "$gd_src_count" ]; then
      gd_is_partial_success=1
      SYNC_FAILED=1
    fi

    if [ "$gd_is_partial_success" -eq 1 ]; then
      # 同步"成功"但目标文件数少于源端，视为部分失败，不保存同步标记
      local ok_message=""
      ok_message+="⚠️ ${task_name} Google Drive 部分文件同步失败"$'\n'
      ok_message+='━━━━━━━━━━━━━━'$'\n'
      ok_message+="源端大小：${gd_src_size}"$'\n'
      ok_message+="目标大小：${gd_dst_size}"$'\n'
      ok_message+="状态：部分文件同步失败 (exit=0，文件数不一致)"$'\n'
      ok_message+="${gd_count_info}"$'\n'
      ok_message+=$'\n''📁 任务信息'$'\n'
      ok_message+="• 任务：${task_name}"$'\n'
      ok_message+="• 源端：${source_path}"$'\n'
      ok_message+="• 目标：${dest_path}"$'\n'
      ok_message+=$'\n''🚫 排除规则'$'\n'
      ok_message+="${gd_exclude_list}"$'\n'
      if [ -n "$gd_diff_files_list" ]; then
        ok_message+=$'\n''📋 差异文件列表：'$'\n'
        ok_message+="$gd_diff_files_list"
      fi
    else
      # 同步成功，保存标记
      if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
        save_sync_marker "$source_path" "$dest_path" "${task_name}_gd"
      fi

      if [ -n "$gd_diff_files_list" ]; then
        printf -v ok_message '%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n\n%s\n%s' \
          "✅ ${task_name} Google Drive sync 完成" \
          '━━━━━━━━━━━━━━' \
          "源端大小：${gd_src_size}" \
          "目标大小：${gd_dst_size}" \
          "状态：已保存同步标记，未来 1 天内会跳过" \
          "$gd_count_info" \
          '📁 任务信息' \
          "• 任务：${task_name}" \
          "• 源端：${source_path}" \
          "• 目标：${dest_path}" \
          '🚫 排除规则' \
          "$gd_exclude_list" \
          '📋 差异文件列表' \
          "$gd_diff_files_list"
      else
        printf -v ok_message '%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s' \
          "✅ ${task_name} Google Drive sync 完成" \
          '━━━━━━━━━━━━━━' \
          "源端大小：${gd_src_size}" \
          "目标大小：${gd_dst_size}" \
          "状态：已保存同步标记，未来 1 天内会跳过" \
          "$gd_count_info" \
          '📁 任务信息' \
          "• 任务：${task_name}" \
          "• 源端：${source_path}" \
          "• 目标：${dest_path}" \
          '🚫 排除规则' \
          "$gd_exclude_list"
      fi
    fi

    send_telegram_message "$ok_message"
  fi

  rm -f "$LOG_FILENAME" "${LOG_FILENAME}.last" 2>/dev/null || true
  PROGRESS_PHASE_INFO="$_old_phase"
  PROGRESS_STATS="$_old_stats"
  return 0
}
