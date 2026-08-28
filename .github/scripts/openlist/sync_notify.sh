#!/bin/bash
# ===== OpenList 同步工具 — 同步结果通知构建 =====
#
# 职责边界:
#   - 构建同步结果的 Telegram 通知（成功/失败/跳过/无变化 4 个分支共用排版）
#   - 共享段落构建器: 头部(任务/路径/大小/状态)、自动拆分、排除规则、差异列表
#
# 拆分缘由: sync_engine.sh 曾同时承担同步编排、修复管线、通知排版三类职责
#   （2000+ 行），通知部分与同步逻辑无耦合，独立后按职责即可定位。
#
# 依赖: utils.sh (escape_html, tree_conn/tree_sub/tree_lines,
#         get_transferred_bytes_from_log),
#       rclone_query.sh (_build_diff_files_list, _build_exclude_patterns,
#         _get_path_stats),
#       telegram.sh (tg_*), file_fix.sh (_fix_method_short),
#       openlist_driver.sh (_refresh_openlist_cache)
# 被依赖: sync_engine.sh (sync_with_logging)
# ===== 通知消息公共段落构建 =====
# 4 个通知分支共享的头部/任务信息/排除规则/差异列表段落。
# 统一走 telegram.sh 的 tg_* 排版助手（HTML）；
# 读取调用方（_send_sync_result_notification）作用域:
#   source_size_human / dest_size_human / count_info / task_name /
#   source_path / dest_path / exclude_list / AUTO_SPLIT_INFO / diff_files_list

# 头部: 标题 + 分隔线 + 任务/路径 + 大小 + 可选状态行 + 文件数信息
# 用法: _notify_add_header <var> <标题（含 emoji）> [状态行文本]
_notify_add_header() {
  tg_add_title "$1" "$2"
  tg_add_kv "$1" "任务" "$task_name"
  tg_add_path "$1" "源端" "$source_path"
  tg_add_path "$1" "目标" "$dest_path"
  tg_add_kv "$1" "源端大小" "$source_size_human"
  tg_add_kv "$1" "目标大小" "$dest_size_human"
  if [ -n "${3:-}" ]; then
    tg_add_kv "$1" "状态" "$3"
  fi
  tg_append "$1" "文件数：${count_info}"$'\n'
}

# AUTO_SPLIT_INFO 段（仅非空时插入；内容为 task_engine.sh 构建的 HTML 分节片段）
_notify_add_autosplit() {
  [ -n "$AUTO_SPLIT_INFO" ] && tg_append "$1" $'\n'"${AUTO_SPLIT_INFO}"$'\n'
  return 0
}

# 排除规则段（仅非空时插入；模式 code 等宽展示）
# 用法: _notify_add_excludes <var>
_notify_add_excludes() {
  [ -z "$exclude_list" ] && return 0
  tg_add_section "$1" "🚫 排除规则"
  local _pattern
  while IFS= read -r _pattern; do
    [ -z "$_pattern" ] && continue
    tg_append "$1" "• <code>$(escape_html "$_pattern")</code>"$'\n'
  done <<< "$exclude_list"
  return 0
}

# 差异文件列表段（仅非空时插入）
# 用法: _notify_add_diff_list <var>
_notify_add_diff_list() {
  [ -z "$diff_files_list" ] && return 0
  tg_add_section "$1" "📋 差异文件列表"
  tg_add_block "$1" "$(escape_html "$diff_files_list")"
  return 0
}

# 发送同步结果通知（从 sync_with_logging 拆分出来）
# 构建包含源/目标大小、差异文件列表、排除规则、修复结果的通知消息
# 设置全局变量: SYNC_FAILED, SYNC_SKIPPED, SYNC_TRANSFERRED_BYTES
_send_sync_result_notification() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  local sync_status="$4"
  local log_filename="$5"
  local last_attempt_log="$6"
  local fail_list="$7"
  local fix_list="$8"
  local fix_log="$9"
  local has_object_not_found="${10}"
  shift 10
  local extra_args=("$@")

  SYNC_FAILED=0
  # 部分失败标志: 本次同步有文件成功但有文件失败/缺失（导出给调用方，
  # 子目录进度树据此区分 ⚠️ 部分失败 / ❌ 完全失败）
  SYNC_PARTIAL=0

  # 获取源端和目标端大小及文件数量（各只调一次 --json）
  local source_size_human="未知"
  local dest_size_human="未知"
  local source_count="未知"
  local dest_count="未知"
  local count_info=""
  local src_stats dst_stats

  src_stats=$(_get_path_stats "$source_path" "${extra_args[@]}")
  source_count=$(echo "$src_stats" | awk '{print $2}')
  source_size_human=$(echo "$src_stats" | awk '{print $3 ($4? " "$4 : "")}')
  local source_count_raw="$source_count"
  [ "$source_count" = "0" ] && source_count="未知"

  # 同步后刷新 OpenList 缓存，确保 _get_path_stats 拿到真实文件数
  # 避免 stale 缓存里残留"幽灵文件"导致 dest_count 虚高，误报同步成功
  if [[ "$dest_path" == openlist:* ]]; then
    echo "同步后刷新 OpenList 缓存以获取真实文件数..." | tee -a "$log_filename"
    _refresh_openlist_cache "$dest_path"
  fi

  dst_stats=$(_get_path_stats "$dest_path" "${extra_args[@]}")
  dest_count=$(echo "$dst_stats" | awk '{print $2}')
  dest_size_human=$(echo "$dst_stats" | awk '{print $3 ($4? " "$4 : "")}')
  local dest_count_raw="$dest_count"
  [ "$dest_count" = "0" ] && dest_count="未知"

  # 始终显示文件数信息
  local diff_files_list=""
  if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]]; then
    local count_diff=$((source_count_raw - dest_count_raw))
    if [ "$count_diff" -ne 0 ]; then
      count_info="<b>差异 ${count_diff}</b>（源端 ${source_count} / 目标 ${dest_count}）"
      diff_files_list=$(_build_diff_files_list "$source_path" "$dest_path" "${extra_args[@]}")
    else
      count_info="${source_count}（一致）"
    fi
  else
    count_info="源端 ${source_count} / 目标 ${dest_count}"
  fi

  # 提取 --exclude 规则，方便在通知中说明
  local exclude_list=""
  exclude_list=$(_build_exclude_patterns "${extra_args[@]}")

  # 构建 fix_summary（已修复文件树形列表: 一文件一行，原名 → 实际名 · 大小 · 方式；
  # HTML 格式，路径 code 等宽，动态内容经 escape_html 转义，条目经 tree_lines 加 ├─/└─）
  local fix_summary=""
  local fix_total=0
  if [ -s "$fix_list" ]; then
    fix_total=$(grep -c . "$fix_list" 2>/dev/null || true)
    local _fix_entries=""
    while IFS='|' read -r f_original f_alternative f_method f_restore f_size f_bytes f_mid; do
      [ -z "$f_original" ] && continue
      local f_method_tag _entry
      f_method_tag=$(_fix_method_short "$f_mid")
      _entry="<code>$(escape_html "$f_original")</code>"
      # 改名修复（含目录变动）: 原名 → 实际名 双方完整路径
      [ "$f_original" != "$f_alternative" ] && _entry+=" → <code>$(escape_html "$f_alternative")</code>"
      _entry+=" · <i>$(escape_html "$f_size")</i> · <i>$(escape_html "$f_method_tag")</i>"
      _fix_entries+="${_entry}"$'\n'
    done < "$fix_list"
    fix_summary="$(tree_lines "$_fix_entries")"$'\n'
  fi
  [ -z "$fix_summary" ] && fix_summary="无"$'\n'

  # 上报本轮经替代方式同步的文件数（进度面板收尾标题据此区分"带修复的完成"）
  # auto-split 子任务各报一次，面板侧累加
  [ "$fix_total" -gt 0 ] && progress_add_fixed_files "$fix_total"

  # 构建 fail_summary（无法修复的文件树形列表: 条目行 + tree_sub 缩进的"修复过程"子行；
  # 风格与 fix_summary 一致）
  local fail_summary=""
  local fail_total=0
  if [ -s "$fail_list" ]; then
    fail_total=$(grep -c . "$fail_list" 2>/dev/null || true)
    local -a _fail_entries=() _fail_sections=()
    while IFS='|' read -r fpath fsize fmsg; do
      [ -z "$fpath" ] && continue
      _fail_entries+=("<code>$(escape_html "$fpath")</code> · <i>$(escape_html "$fsize")</i> · <i>$(escape_html "$fmsg")</i>")
      # 从 fix_log 中按文件名分隔提取该文件对应的修复过程
      local fix_section="" _fix_log_text
      if [ -f "$fix_log" ]; then
        fix_section=$(awk -v rel="$fpath" '
          index($0, "=== 尝试修复失败文件: " rel " ===") > 0 { capture=1; next }
          /=== 尝试修复失败文件: / && capture { capture=0 }
          capture { sub(/^\[[^]]*\] /, ""); print }
        ' "$fix_log" 2>/dev/null)
      fi
      if [ -n "$fix_section" ]; then
        _fix_log_text="修复过程："
        while IFS= read -r log_line; do
          [ -z "$log_line" ] && continue
          _fix_log_text+=$'\n'"  $(escape_html "$log_line")"
        done <<< "$fix_section"
      elif echo "$fmsg" | grep -qi 'object not found'; then
        _fix_log_text="修复过程：源文件不存在，无需修复"
      else
        _fix_log_text="修复过程：无记录"
      fi
      _fail_sections+=("$_fix_log_text")
    done < "$fail_list"
    local _i _n=${#_fail_entries[@]} _last
    for (( _i=0; _i<_n; _i++ )); do
      _last=0
      [ $((_i + 1)) -eq "$_n" ] && _last=1
      fail_summary+="$(tree_conn "$_last")${_fail_entries[$_i]}"$'\n'
      local _sub
      while IFS= read -r _sub; do
        [ -z "$_sub" ] && continue
        fail_summary+="$(tree_sub "$_last")${_sub}"$'\n'
      done <<< "${_fail_sections[$_i]}"
    done
  fi
  [ -z "$fail_summary" ] && fail_summary="无"$'\n'

  # 解析本次同步传输的字节数
  SYNC_TRANSFERRED_BYTES=$(get_transferred_bytes_from_log "$log_filename")
  SYNC_SKIPPED=0

  # 子目录拆分模式下，如果没有文件变更且无错误，跳过通知
  if [ "$SYNC_SKIP_QUIET" = "1" ] && [ ! -s "$fail_list" ] && [ ! -s "$fix_list" ]; then
    if ! grep -Eqi 'Copied|Deleted|Renamed|Moved' "$log_filename" 2>/dev/null; then
      SYNC_SKIPPED=1
      echo "无文件变更，跳过通知 (SYNC_SKIP_QUIET=1, task=${task_name})"
      rm -f "$log_filename" 2>/dev/null || true
      return 0
    fi
  fi

  # ===== 构建并发送通知消息 =====

  if [ -s "$fail_list" ]; then
    # 有无法同步的文件，标记失败以便上层触发大文件切割
    # fail_list 只列出失败文件（其余已正常同步），恒为部分失败
    SYNC_FAILED=1
    SYNC_PARTIAL=1
    # 根据错误类型构建状态消息
    local fail_status_msg="部分文件无法同步"
    if [ "$has_object_not_found" -eq 1 ]; then
      fail_status_msg="源文件不存在（object not found），部分文件无法同步"
    fi
    local partial_msg=""
    _notify_add_header partial_msg "⚠️ ${task_name} 部分文件同步失败" "$fail_status_msg"
    _notify_add_excludes partial_msg
    _notify_add_autosplit partial_msg
    tg_add_section partial_msg "✅ 已通过其他方式同步（${fix_total} 个文件）"
    tg_append partial_msg "${fix_summary}"
    tg_add_section partial_msg "❌ 无法同步文件（${fail_total} 个）"
    tg_append partial_msg "${fail_summary}"
    _notify_add_diff_list partial_msg

    send_telegram_message "$partial_msg"

  elif [ -s "$fix_list" ]; then
    # 所有缺失文件都已通过其他方式同步
    local partial_msg=""
    _notify_add_header partial_msg "⚠️ ${task_name} 部分文件已通过其他方式同步" "${fix_total} 个缺失文件已全部通过替代方式同步"
    _notify_add_excludes partial_msg
    _notify_add_autosplit partial_msg
    tg_add_section partial_msg "✅ 已通过其他方式同步（${fix_total} 个文件）"
    tg_append partial_msg "${fix_summary}"
    _notify_add_diff_list partial_msg

    send_telegram_message "$partial_msg"

  elif [ "$sync_status" -ne 0 ] || grep -Eqi '(^|[^[:alpha:]])(ERROR|Failed|timeout|forbidden|unauthorized|permission denied|connection refused)([^[:alpha:]]|$)' "$last_attempt_log"; then
    # 同步返回非零或日志包含错误关键字
    SYNC_FAILED=1
    # 检测是否为部分失败：目标已有部分文件但少于源端
    local is_partial_failure=0
    if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]] && \
     [ "$dest_count_raw" -gt 0 ] && [ "$dest_count_raw" -lt "$source_count_raw" ]; then
      is_partial_failure=1
    fi
    SYNC_PARTIAL=$is_partial_failure
    # 提取关键错误日志
    local critical_logs="无明显错误关键字"
    if [ -f "$log_filename" ]; then
      critical_logs=$(grep -Ei "error|failed|too large|timeout|permission denied|connection refused" "$log_filename" | tail -n 5 || echo "无明显错误关键字")
    fi
    local err_title err_status
    if [ "$is_partial_failure" -eq 1 ]; then
      err_title="⚠️ ${task_name} 部分文件同步失败"
      err_status="部分文件同步失败（exit=${sync_status}）"
    else
      err_title="⚠️ ${task_name} 同步失败"
      err_status="同步失败（exit=${sync_status}）"
    fi
    local err_msg=""
    _notify_add_header err_msg "$err_title" "$err_status"
    _notify_add_excludes err_msg
    _notify_add_autosplit err_msg
    tg_add_section err_msg "🧾 错误详情 · 关键日志"
    if [ -n "$critical_logs" ] && [ "$critical_logs" != "无明显错误关键字" ]; then
      # 日志为原始输出（可能含 <>& 字符），逐行转义后 <pre> 等宽展示
      local err_log_lines=""
      while IFS= read -r line; do
        [ -n "$line" ] && err_log_lines+="${line}"$'\n'
      done <<< "$critical_logs"
      tg_add_block err_msg "<pre>$(escape_html "${err_log_lines%$'\n'}")</pre>"
    else
      tg_add_block err_msg "• 无明显错误关键字"
    fi
    _notify_add_diff_list err_msg
    send_telegram_message "$err_msg"
    # 发送完整日志文件
    local err_log_size
    err_log_size=$(stat -c%s "$log_filename" 2>/dev/null || echo 0)
    if [ "$err_log_size" -gt 0 ] && [ "$err_log_size" -lt "${OPENLIST_ERR_LOG_MAX_BYTES:-50000000}" ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"$log_filename" \
        -F parse_mode="HTML" \
        -F caption="📁 <b>$(escape_html "$task_name")</b> 错误日志" || true
    fi
  else
    # 同步返回成功，检查是否有文件缺失（部分失败）
    local is_partial_success=0
    if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]] && \
       [ "$dest_count_raw" -lt "$source_count_raw" ]; then
      is_partial_success=1
      SYNC_FAILED=1
      SYNC_PARTIAL=1
    fi
    local ok_message=""
    if [ "$is_partial_success" -eq 1 ]; then
      # 同步"成功"但目标文件数少于源端，视为部分失败
      _notify_add_header ok_message "⚠️ ${task_name} 部分文件同步失败" "部分文件同步失败（exit=0，文件数不一致）"
    else
      _notify_add_header ok_message "✅ ${task_name} 同步完成"
    fi
    _notify_add_excludes ok_message
    _notify_add_autosplit ok_message
    _notify_add_diff_list ok_message

    send_telegram_message "$ok_message"
  fi
}
