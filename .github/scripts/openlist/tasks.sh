#!/bin/bash
# ===== OpenList 同步工具 — 任务编排函数 =====
# 提供 sync_task / copy_task / gd_task 三个用户接口函数，
# 支持:
#   --auto-split  — 源端 > 50GB 时按一级子目录自动拆分
#   --1d-skip     — 1 天内已成功同步则跳过（--2d-skip / --3d-skip 自定义天数）
#   其余参数（如 --exclude）原样传给 rclone
#
# 依赖: sync.sh, split.sh, marker.sh, preview.sh, gd_sync.sh, progress.sh
# 依赖环境变量:
#   RCLONE_SYNC_TASK_FLAGS — sync_task 特有 rclone 参数（在 workflow 文件中定义）
#   RCLONE_COPY_TASK_FLAGS — copy_task 特有 rclone 参数（在 workflow 文件中定义）

# 从 task_name 和 dest_path 派生唯一 task_id（用于进度跟踪）
# 例: _derive_task_id "task0" "openlist:wopan176Crypt/0" → "task0_wopan176Crypt"
_derive_task_id() {
  local task_name="$1"
  local dest_path="$2"
  local dest_clean="${dest_path#*:}"
  local first_component="${dest_clean%%/*}"
  [ -z "$first_component" ] && first_component="${dest_clean}"
  [ -z "$first_component" ] && first_component="dest"
  echo "${task_name}_${first_component}"
}

# 预览模式：注册任务到进度系统并添加预览对（不实际同步）
_preview_register() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"
  shift 3
  local extra_args=("$@")

  # task_name 变化时刷新上一个预览组
  if [ "$_PREVIEW_CUR_TASK" != "$task_name" ]; then
    if [ -n "$_PREVIEW_CUR_TASK" ]; then
      flush_task_preview
    fi
    start_task_preview "$task_name"
    _PREVIEW_CUR_TASK="$task_name"
  fi
  add_preview_pair "$source_path" "$dest_path" "${extra_args[@]}"

  # 同时注册到进度系统（pending 状态）
  local _task_id
  _task_id=$(_derive_task_id "$task_name" "$dest_path")
  progress_register_task "$_task_id" "${source_path} → ${dest_path}"
}

# 自动拆分同步实现：源端 > 50GB 时按一级子目录拆分，最后再完整同步一次
# 用法: _sync_task_impl <source_path> <dest_path> <task_name> [rclone_extra_args...]
_sync_task_impl() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  local current_depth=${SYNC_AUTO_SPLIT_DEPTH:-0}

  # 只在顶级调用（非递归）时重置状态标志，避免递归子任务覆盖父任务状态
  if [ "$current_depth" -eq 0 ]; then
    SYNC_SKIPPED=0
    SYNC_FAILED=0
  fi

  local max_depth=10
  local subdir

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "$task_name"
    case "$MARKER_ACTION" in
      skip)
        send_sync_skipped "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
      warning)
        send_sync_warning "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
    esac
  fi

  # 初始化 phase/stats（递归子任务在同一 shell 中继承/修改，返回后由调用方恢复）
  local _old_phase="${PROGRESS_PHASE_INFO:-}"
  local _old_stats="${PROGRESS_STATS:-}"
  PROGRESS_PHASE_INFO=""
  PROGRESS_STATS=""

  # 未开启 --auto-split 时跳过大小检查和子目录拆分，直接同步
  if [ "${_TASK_AUTO_SPLIT:-0}" = "0" ]; then
    progress_update "直接同步中"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    elif [ "$current_depth" -eq 0 ]; then
      split_on_sync_failure "$source_path" "$task_name"
    fi
    PROGRESS_PHASE_INFO="$_old_phase"
    PROGRESS_STATS="$_old_stats"
    return $_rc
  fi

  # 50GB 阈值（带默认值，防止跨 step 环境变量丢失时为空）
  local threshold="${SYNC_SPLIT_THRESHOLD_BYTES:-50000000000}"

  # 检查源端大小
  local source_size_bytes=0
  local size_json
  size_json=$(rclone size "$source_path" --json 2>/dev/null || true)
  if [ -n "$size_json" ]; then
    source_size_bytes=$(echo "$size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  fi
  # 确保 source_size_bytes 是有效整数，否则置 0
  [[ "$source_size_bytes" =~ ^[0-9]+$ ]] || source_size_bytes=0

  if [ "$source_size_bytes" -le "$threshold" ]; then
    echo "源端大小 $(numfmt --to=iec-i --suffix=B "$source_size_bytes" 2>/dev/null || echo "${source_size_bytes}B") 未超过 50GB 阈值，直接同步"
    progress_update "直接同步中（源端 $(format_bytes "$source_size_bytes")）"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    elif [ "$current_depth" -eq 0 ]; then
      split_on_sync_failure "$source_path" "$task_name"
    fi
    PROGRESS_PHASE_INFO="$_old_phase"
    PROGRESS_STATS="$_old_stats"
    return $_rc
  fi

  # 超过 50GB，需要拆分
  if [ "$current_depth" -ge "$max_depth" ]; then
    echo "已达最大拆分深度 ${max_depth}，按文件批次拆分 (depth=${current_depth}, size=$(numfmt --to=iec-i --suffix=B "$source_size_bytes" 2>/dev/null || echo "${source_size_bytes}B"))"
    progress_update "文件批次拆分（已达最大深度 ${current_depth}）"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    elif [ "$current_depth" -eq 0 ]; then
      split_on_sync_failure "$source_path" "$task_name"
    fi
    PROGRESS_PHASE_INFO="$_old_phase"
    PROGRESS_STATS="$_old_stats"
    return $_rc
  fi

  echo "源端大小 $(numfmt --to=iec-i --suffix=B "$source_size_bytes" 2>/dev/null || echo "${source_size_bytes}B") 超过 50GB 阈值，按子目录拆分同步 (depth=${current_depth})"

  # 列出一级子目录
  local subdirs
  subdirs=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||')
  if [ -z "$subdirs" ]; then
    echo "无子目录，按文件批次拆分同步"
    progress_update "无子目录，按文件批次拆分"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    elif [ "$current_depth" -eq 0 ]; then
      split_on_sync_failure "$source_path" "$task_name"
    fi
    PROGRESS_PHASE_INFO="$_old_phase"
    PROGRESS_STATS="$_old_stats"
    return $_rc
  fi

  # 从 extra_args 中提取排除的目录名（模式如 notion/** 或 /notion/**）
  local exclude_dir_list=""
  local i=0
  while [ $i -lt ${#extra_args[@]} ]; do
    if [ "${extra_args[$i]}" = "--exclude" ] && [ $((i+1)) -lt ${#extra_args[@]} ]; then
      local pattern="${extra_args[$((i+1))]}"
      if [[ "$pattern" == */** ]]; then
        local dirname="${pattern#/}"
        dirname="${dirname%/**}"
        if [ -n "$dirname" ]; then
          exclude_dir_list="${exclude_dir_list}${dirname}"$'\n'
        fi
      fi
      i=$((i+2))
    else
      i=$((i+1))
    fi
  done

  # 过滤掉匹配排除规则的子目录
  if [ -n "$exclude_dir_list" ]; then
    local filtered_subdirs=""
    while IFS= read -r subdir; do
      [ -z "$subdir" ] && continue
      if echo "$exclude_dir_list" | grep -qxF "$subdir"; then
        echo "跳过排除的子目录: ${subdir}"
        continue
      fi
      if [ -z "$filtered_subdirs" ]; then
        filtered_subdirs="$subdir"
      else
        filtered_subdirs="${filtered_subdirs}"$'\n'"${subdir}"
      fi
    done <<< "$subdirs"
    subdirs="$filtered_subdirs"
    if [ -z "$subdirs" ]; then
      echo "所有子目录均被排除，直接执行完整同步"
      progress_update "所有子目录被排除，直接完整同步"
      sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
      local _rc=$?
      if [ "$current_depth" -eq 0 ]; then
        if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
          save_sync_marker "$source_path" "$dest_path" "$task_name"
        else
          split_on_sync_failure "$source_path" "$task_name"
        fi
      fi
      PROGRESS_PHASE_INFO="$_old_phase"
      PROGRESS_STATS="$_old_stats"
      return $_rc
    fi
  fi

  # 按子目录大小从小到大排序
  echo "按子目录大小排序..."
  PROGRESS_PHASE_INFO="📂 <b>子目录拆分</b>（depth=${current_depth}，源端 $(format_bytes "$source_size_bytes")，正在统计大小...）"
  progress_update "正在按子目录大小排序..."
  local sorted_subdirs=""
  declare -A subdir_size_map=()
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    local subdir_bytes=0
    local subdir_json
    subdir_json=$(rclone size "${source_path}/${subdir}" --json 2>/dev/null || true)
    [ -n "$subdir_json" ] && subdir_bytes=$(echo "$subdir_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
    subdir_size_map["$subdir"]=$subdir_bytes
    echo "  ${subdir}: $(format_bytes "$subdir_bytes")"
    sorted_subdirs+="${subdir_bytes} ${subdir}"$'\n'
  done <<< "$subdirs"
  subdirs=$(echo "$sorted_subdirs" | sort -n | cut -d' ' -f2-)

  # 预统计子目录总数（用于进度展示）
  local total_subdirs_count
  total_subdirs_count=$(echo "$subdirs" | grep -c . 2>/dev/null || echo 0)

  # 构建子目录大小信息（HTML 片段，供进度通知展示）
  local subdir_phase_info=""
  subdir_phase_info="📂 <b>子目录大小</b>（共 ${total_subdirs_count} 个，源端 $(format_bytes "$source_size_bytes")）"
  while IFS= read -r _info_subdir; do
    [ -z "$_info_subdir" ] && continue
    subdir_phase_info+=$'\n'"• $(escape_html "$_info_subdir"): $(format_bytes "${subdir_size_map[$_info_subdir]:-0}")"
  done <<< "$subdirs"

  # 按子目录逐个同步（静默模式：无文件变更时跳过通知）
  SYNC_SKIP_QUIET=1
  local total_subtasks=0
  local synced_subtasks=0
  local failed_subtasks=0
  local skipped_subtasks=0
  local total_transferred=0
  local synced_list=""
  local failed_list=""
  local skipped_list=""
  local subtask_idx=0
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    total_subtasks=$((total_subtasks + 1))
    subtask_idx=$((subtask_idx + 1))
    local safe_subtask="${task_name}_${subdir//\//_}"
    echo "=== 子目录同步: ${safe_subtask} ==="
    PROGRESS_PHASE_INFO="$subdir_phase_info"
    local _completed_before=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    local _in_progress=$((subtask_idx - _completed_before))
    progress_update "子目录 ${subtask_idx}/${total_subdirs_count}: ${subdir}" "📊 子目录: ${_completed_before}/${total_subdirs_count} 完成$([ "$_in_progress" -gt 0 ] && echo " (${_in_progress} 进行中)") | ✅${synced_subtasks} ⏭️${skipped_subtasks} ❌${failed_subtasks}"
    SYNC_AUTO_SPLIT_DEPTH=$((current_depth + 1))
    _sync_task_impl "${source_path}/${subdir}" "${dest_path}/${subdir}" "${safe_subtask}" "${extra_args[@]}" || true
    SYNC_AUTO_SPLIT_DEPTH=$current_depth
    if [ "$SYNC_SKIPPED" = "1" ]; then
      skipped_subtasks=$((skipped_subtasks + 1))
      skipped_list+="• ${subdir} ($(format_bytes "${subdir_size_map[$subdir]:-0}"))"$'\n'
    elif [ "$SYNC_FAILED" = "0" ]; then
      synced_subtasks=$((synced_subtasks + 1))
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      synced_list+="• ${subdir} ($(format_bytes "${subdir_size_map[$subdir]:-0}"))"$'\n'
    else
      failed_subtasks=$((failed_subtasks + 1))
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      failed_list+="• ${subdir} ($(format_bytes "${subdir_size_map[$subdir]:-0}"))"$'\n'
    fi
    PROGRESS_PHASE_INFO="$subdir_phase_info"
    local _completed_after=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    progress_update_force "子目录 ${subtask_idx}/${total_subdirs_count} 完成: ${subdir}" "📊 子目录: ${_completed_after}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ❌${failed_subtasks}"
  done <<< "$subdirs"
  SYNC_SKIP_QUIET=0

  # 设置拆分信息供最终通知使用
  AUTO_SPLIT_INFO="🔀 子任务拆分统计"$'\n'
  AUTO_SPLIT_INFO+="• 总子目录数：${total_subtasks}"$'\n'
  AUTO_SPLIT_INFO+="• 已同步：${synced_subtasks}，未同步：${failed_subtasks}，已跳过：${skipped_subtasks}"$'\n'
  AUTO_SPLIT_INFO+="• 子任务传输总量：$(format_bytes "$total_transferred")"
  if [ -n "$synced_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"✅ 已同步的子目录："$'\n'"${synced_list%"$'\n'"}"
  fi
  if [ -n "$failed_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"❌ 未同步的子目录："$'\n'"${failed_list%"$'\n'"}"
  fi
  if [ -n "$skipped_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"⏭️ 已跳过的子目录（无文件变动）："$'\n'"${skipped_list%"$'\n'"}"
  fi

  # 最终完整同步（仅在顶层执行，正常通知）
  if [ "$current_depth" -eq 0 ]; then
    echo "=== 最终完整同步: ${task_name} ==="
    PROGRESS_PHASE_INFO="$subdir_phase_info"
    progress_update_force "最终完整同步中" "📊 子目录: ${total_subtasks}/${total_subtasks} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ❌${failed_subtasks}"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    AUTO_SPLIT_INFO=""
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    else
      split_on_sync_failure "$source_path" "$task_name"
    fi
  else
    SYNC_SKIPPED=0
    SYNC_FAILED=0
    SYNC_TRANSFERRED_BYTES=$total_transferred
    if [ "$SYNC_FAILED" = "0" ] && [ "$failed_subtasks" -eq 0 ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name"
    fi
  fi
  PROGRESS_PHASE_INFO="$_old_phase"
  PROGRESS_STATS="$_old_stats"
}

# sync_task: rclone sync 模式（删除目标端多余文件）
# 可选参数:
#   --auto-split   开启 50GB 子目录自动拆分
#   --1d-skip      开启 1 天跳过（--2d-skip / --3d-skip 可自定义天数）
#   其余参数（如 --exclude）原样传给 rclone
# sync_task 特有参数（--delete-before 等）由 RCLONE_SYNC_TASK_FLAGS 自动追加
sync_task() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3

  # 解析任务级开关，剩余参数作为 extra_args 传给 rclone
  local _auto_split=0
  local _skip_days=0
  local extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto-split) _auto_split=1; shift ;;
      --*d-skip)
        _skip_days="${1#--}"
        _skip_days="${_skip_days%d-skip}"
        [[ "$_skip_days" =~ ^[0-9]+$ ]] || _skip_days=0
        shift ;;
      *) extra_args+=("$1"); shift ;;
    esac
  done

  # 追加 sync_task 特有 rclone 参数（如 --delete-before）
  # copy_task 调用时 _SYNC_MODE=copy，跳过 sync 特有参数（copy 不删除）
  if [ "${_SYNC_MODE:-sync}" != "copy" ]; then
    extra_args=("${RCLONE_SYNC_TASK_FLAGS[@]}" "${extra_args[@]}")
  fi

  # 根据 skip 天数设置 SYNC_SKIP_SECONDS
  if [ "$_skip_days" -gt 0 ]; then
    SYNC_SKIP_SECONDS=$((_skip_days * 24 * 60 * 60))
  fi

  local current_depth=${SYNC_AUTO_SPLIT_DEPTH:-0}

  # 预览模式：只注册，不实际同步
  if [ "$current_depth" -eq 0 ] && [ -n "$TASK_PREVIEW_ONLY" ]; then
    _preview_register "$task_name" "$source_path" "$dest_path" "${extra_args[@]}"
    return 0
  fi

  # 顶级调用时自动 task_begin/task_done
  if [ "$current_depth" -eq 0 ]; then
    local _task_id
    _task_id=$(_derive_task_id "$task_name" "$dest_path")
    task_begin "$_task_id" "${source_path} → ${dest_path}"
  fi

  _TASK_AUTO_SPLIT=$_auto_split _TASK_SKIP_DAYS=$_skip_days _sync_task_impl "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  local _rc=$?

  if [ "$current_depth" -eq 0 ]; then
    if [ "$SYNC_SKIPPED" = "1" ]; then
      task_done "skipped"
    elif [ "$SYNC_FAILED" = "1" ]; then
      task_done "failed"
    else
      task_done "completed"
    fi
  fi
  return $_rc
}

# copy_task: 使用 rclone copy 模式（不删除目标端多余文件）
# 特有参数（--no-traverse 等）由 RCLONE_COPY_TASK_FLAGS 自动追加
copy_task() {
  _SYNC_MODE="copy" sync_task "$@" "${RCLONE_COPY_TASK_FLAGS[@]}"
}

# gd_task: Google Drive 专用同步（处理配额超限、API 限流等 GD 特有错误）
# 可选参数: --1d-skip (或 --2d-skip / --3d-skip 自定义天数)
# 其余 rclone 参数（如 --exclude）直接追加在后面
gd_task() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3

  # 解析任务级开关
  local _skip_days=0
  local extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --*d-skip)
        _skip_days="${1#--}"
        _skip_days="${_skip_days%d-skip}"
        [[ "$_skip_days" =~ ^[0-9]+$ ]] || _skip_days=0
        shift ;;
      *) extra_args+=("$1"); shift ;;
    esac
  done

  # 根据 skip 天数设置 SYNC_SKIP_SECONDS
  if [ "$_skip_days" -gt 0 ]; then
    SYNC_SKIP_SECONDS=$((_skip_days * 24 * 60 * 60))
  fi

  # 预览模式：只注册，不实际同步
  if [ -n "$TASK_PREVIEW_ONLY" ]; then
    _preview_register "$task_name" "$source_path" "$dest_path" "${extra_args[@]}"
    return 0
  fi

  # 自动 task_begin/task_done
  local _task_id
  _task_id=$(_derive_task_id "$task_name" "$dest_path")
  task_begin "$_task_id" "${source_path} → ${dest_path}"

  _TASK_SKIP_DAYS=$_skip_days _gd_sync "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  local _rc=$?

  if [ "$SYNC_SKIPPED" = "1" ]; then
    task_done "skipped"
  elif [ "$SYNC_FAILED" = "1" ]; then
    task_done "failed"
  else
    task_done "completed"
  fi
  return $_rc
}

# 按文件批次拆分同步（用于无子目录的大文件夹）
# 按 ~50GB 拆分为多个批次，每批用 rclone copy --files-from 同步
# 用法: sync_by_file_batches <source_path> <dest_path> <task_name> [rclone_extra_args...]
sync_by_file_batches() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "$task_name"
    case "$MARKER_ACTION" in
      skip)
        echo "跳过 ${task_name} 文件批次同步: $((SYNC_SKIP_SECONDS / 3600))小时内已成功同步"
        send_sync_skipped "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
      warning)
        send_sync_warning "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
    esac
  fi

  local threshold="${SYNC_SPLIT_THRESHOLD_BYTES:-50000000000}"  # 50GB
  local batch_dir="/tmp/file_batches_${task_name}"
  mkdir -p "$batch_dir"

  echo "=== 按文件批次拆分: ${task_name} ==="

  # 递归列出所有文件（使用 lsjson，比 lsf --json 更可靠）
  local file_list_file="${batch_dir}/all_files.jsonl"
  echo "正在列出文件..."
  # 进入文件批次阶段：清空父级子目录阶段的 stats，避免在批次阶段
  # 仍显示 "📊 子目录: x/y 完成" 这类与当前阶段无关的旧数据。
  PROGRESS_STATS=""
  PROGRESS_PHASE_INFO="📦 <b>文件批次拆分</b>（depth=${SYNC_AUTO_SPLIT_DEPTH:-0}，正在列出文件...）"
  progress_update "正在列出文件..."
  # 注意：GitHub Actions 默认 set -e -o pipefail，rclone lsjson 失败时管道会非零退出，
  # 此处只需文件列表（失败时 total_files=0 触发下方 lsf 备选），用 || true 避免 step 直接退出。
  rclone lsjson --recursive --files-only --no-modtime --no-mimetype "$source_path" 2>&1 | jq -c '.[]' > "$file_list_file" 2>/dev/null || true

  local total_files
  total_files=$(wc -l < "$file_list_file" | tr -d ' ')
  echo "总文件数: ${total_files}"
  PROGRESS_PHASE_INFO="📦 <b>文件批次拆分</b>（${total_files} 文件，正在拆分批次...）"
  progress_update "总文件数: ${total_files}，正在拆分批次..."

  if [ "$total_files" -eq 0 ]; then
    echo "⚠️ 无文件列出，尝试 rclone lsf 备选方案..."
    # 备选：用 rclone lsf -l 获取文件列表和大小
    rclone lsf -l --files-only --recursive "$source_path" 2>&1 | \
      awk '{
        size=$1
        name=""
        # 文件名是第5个字段之后的所有内容（文件名可能含空格）
        for(i=5;i<=NF;i++) name = (i==5 ? $i : name " " $i)
        if (name != "") printf "{\"size\":%s,\"path\":\"%s\"}\n", size, name
      }' > "$file_list_file" 2>/dev/null || true
    total_files=$(wc -l < "$file_list_file" | tr -d ' ')
    echo "备选方案文件数: ${total_files}"
  fi

  if [ "$total_files" -eq 0 ]; then
    echo "无文件可同步"
    SYNC_SKIPPED=1
    SYNC_FAILED=0
    SYNC_TRANSFERRED_BYTES=0
    rm -rf "$batch_dir"
    return 0
  fi

  # 按大小拆分为 ~50GB 的批次
  local batch_num=0
  local batch_size=0
  local batch_file="${batch_dir}/batch_${batch_num}.txt"
  > "$batch_file"

  while IFS= read -r line; do
    local size fpath
    # lsjson 用 .size 和 .path (小写)，lsf --json 用 .Size 和 .Path (大写)
    size=$(echo "$line" | jq -r '(.size // .Size // 0)' 2>/dev/null || echo 0)
    fpath=$(echo "$line" | jq -r '(.path // .Path // empty)' 2>/dev/null)
    [ -z "$fpath" ] && continue
    # 确保 size 是有效整数，否则置 0（避免 $(( )) 语法错误和 [: : integer expression expected）
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    # 当前批次加此文件超阈值则开新批次
    if [ "$batch_size" -gt 0 ] && [ $((batch_size + size)) -gt "$threshold" ]; then
      batch_num=$((batch_num + 1))
      batch_file="${batch_dir}/batch_${batch_num}.txt"
      > "$batch_file"
      batch_size=0
    fi

    echo "$fpath" >> "$batch_file"
    batch_size=$((batch_size + size))
  done < "$file_list_file"

  local total_batches=$((batch_num + 1))
  echo "拆分为 ${total_batches} 个批次"
  PROGRESS_PHASE_INFO="📦 <b>文件批次拆分</b>：${total_batches} 批 / ${total_files} 文件（每批 ≤ $(format_bytes "$threshold")）"
  progress_update_force "拆分为 ${total_batches} 个批次" "📊 批次: 0/${total_batches}"

  # 逐批同步（rclone copy + --files-from）
  local synced_batches=0
  local failed_batches=0
  local failed_batch_list=""
  local batch_total_files=0
  local batch_idx=0

  for i in $(seq 0 $batch_num); do
    local bf="${batch_dir}/batch_${i}.txt"
    if [ -s "$bf" ]; then
      batch_idx=$((batch_idx + 1))
      local batch_file_count
      batch_file_count=$(wc -l < "$bf" | tr -d ' ')
      batch_total_files=$((batch_total_files + batch_file_count))
      echo "=== 批次 $((i+1))/${total_batches}: ${batch_file_count} 个文件 ==="
      PROGRESS_PHASE_INFO="📦 <b>文件批次拆分</b>：${total_batches} 批 / ${total_files} 文件（当前批次 ${batch_idx}: ${batch_file_count} 文件）"
      progress_update "批次 ${batch_idx}/${total_batches}: ${batch_file_count} 个文件" "📊 批次: ${batch_idx}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"

      # set -e 下 rclone 非零退出（如 exit 4 部分失败）会直接终止 step，
      # 导致后续 sync_with_logging 通知无法发出。此处需捕获退出码，临时关闭 set -e。
      set +e
      rclone copy "$source_path" "$dest_path" \
        --files-from "$bf" \
        --size-only \
        --no-traverse \
        --retries 1 \
        --low-level-retries 3 \
        --timeout 5m \
        --contimeout 30s \
        --ignore-errors \
        --progress \
        --stats 15s \
        --stats-one-line \
        --verbose \
        "${extra_args[@]}" \
        2>&1 | tee "${task_name}_batch_${i}.log"
      local rc=${PIPESTATUS[0]}
      set -e

      if [ "$rc" -eq 0 ]; then
        synced_batches=$((synced_batches + 1))
      elif [ "$rc" -eq 4 ]; then
        # exit code 4 = 部分文件失败，大部分成功
        synced_batches=$((synced_batches + 1))
        local err_count
        err_count=$(grep -c 'ERROR.*object not found' "${task_name}_batch_${i}.log" 2>/dev/null || echo 0)
        echo "批次 $((i+1)) 部分成功 (exit=4, ${err_count} 个文件 object not found)"
        grep 'ERROR.*object not found' "${task_name}_batch_${i}.log" 2>/dev/null | head -50 | while IFS= read -r line; do
          echo "  ${line}"
        done
      else
        failed_batches=$((failed_batches + 1))
        failed_batch_list+="• 批次 $((i+1))/${total_batches} (exit=${rc}, ${batch_file_count} 文件)"$'\n'
        echo "批次 $((i+1)) 失败 (exit=${rc})"
      fi
      progress_update_force "批次 ${batch_idx}/${total_batches} 完成" "📊 批次: ${batch_idx}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"
    fi
  done

  # 清理批次文件
  rm -rf "$batch_dir"

  echo "=== 批次传输完成 (成功 ${synced_batches}/${total_batches}, 失败 ${failed_batches})，执行最终同步检查 ==="
  PROGRESS_PHASE_INFO="📦 <b>文件批次拆分</b>：${total_batches} 批 / ${total_files} 文件（✅${synced_batches} ❌${failed_batches}）"
  progress_update_force "批次传输完成，最终同步检查中" "📊 批次: ${total_batches}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"

  # 设置批次统计信息，供最终通知展示（与子目录拆分的 AUTO_SPLIT_INFO 对齐）
  AUTO_SPLIT_INFO="🔀 文件批次拆分统计"$'\n'
  AUTO_SPLIT_INFO+="• 总批次数：${total_batches}（共 ${batch_total_files} 文件）"$'\n'
  AUTO_SPLIT_INFO+="• 成功：${synced_batches}，失败：${failed_batches}"
  if [ -n "$failed_batch_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"❌ 失败的批次："$'\n'"${failed_batch_list%"$'\n'"}"
  fi

  # 最终用 sync_with_logging 做完整同步检查（处理 405/409、通知等）
  # 文件批次阶段已完成实质传输，最终 sync 即使无新增 Copied 记录也必须发通知；
  # 此处可能被子目录递归调用（SYNC_SKIP_QUIET=1），需临时关闭静默模式，避免通知被吞。
  local _saved_skip_quiet="${SYNC_SKIP_QUIET:-0}"
  SYNC_SKIP_QUIET=0
  sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  AUTO_SPLIT_INFO=""
  SYNC_SKIP_QUIET="$_saved_skip_quiet"

  # 文件批次同步成功后保存标记
  if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    save_sync_marker "$source_path" "$dest_path" "$task_name"
  fi
}
