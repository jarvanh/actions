#!/bin/bash
# ===== OpenList 同步工具 — 任务编排函数 =====
# 提供 sync_task 用户接口函数，
# 支持:
#   --auto-split  — 源端 > 50GB 时按一级子目录自动拆分
#   --1d-skip     — 1 天内已成功同步则跳过（--2d-skip / --3d-skip 自定义天数）
#   其余参数（如 --exclude）原样传给 rclone
#
# 依赖: sync.sh, split.sh, marker.sh, preview.sh, progress.sh
# 依赖环境变量:
#   RCLONE_SYNC_TASK_FLAGS — sync_task 特有 rclone 参数（在 flags.sh 中定义）

# ===== 同步任务清单（单点定义，增减任务只需在此添加/删除一行）=====
# 格式: "id|源端|目标端|任务名|附加参数"
#   id:       调试模式（run_task_by_id）的选择器，无需单独调试的任务填 "-"
#   附加参数: --auto-split / --1d-skip / --exclude 等，原样透传给 sync_task
# 所有任务统一 sync_task（rclone sync，删除目标端多余文件）:
#   - --delete-before 等由 RCLONE_SYNC_TASK_FLAGS 自动追加
#   - 已修复文件（original/alternative）由 sync.sh 的 filter-from 排除，
#     排除 = 不传输 + 不删除，sync 模式下不会被误删
SYNC_TASK_REGISTRY=(
  "-|onedrive:backup|openlist:aliyundriveCrypt/backup|backup|--auto-split --1d-skip --exclude /notion/** --exclude notion/** --exclude /self-hosted_latest.tar.gz --exclude self-hosted_latest.tar.gz --exclude /github_repos_latest.tar.gz --exclude github_repos_latest.tar.gz"
  "backup|onedrive:backup|openlist:wopan176Crypt/backup|backup|--auto-split --1d-skip"
  # "-|onedrive:backup|gd:backup|backup|--1d-skip"

  "task0|onedrive:0|openlist:wopan176Crypt/0|task0|--auto-split --1d-skip"
  "-|onedrive:0|openlist:baidupanCrypt/0|task0|--auto-split --1d-skip"
  "-|onedrive:0/j-1024j-视频-pornhub-favorites|openlist:wopan175/0/j-1024j-视频-pornhub-favorites|task0|--auto-split --1d-skip"
  # "-|onedrive:0|gd:0|task0|--1d-skip"

  "task1|onedrive:1|openlist:wopan176Crypt/1|task1|--auto-split --1d-skip"
  "-|onedrive:1|openlist:baidupanCrypt/1|task1|--auto-split --1d-skip"
  "-|onedrive:1|openlist:wopan175/1|task1|--auto-split --1d-skip"
  # "-|onedrive:1|gd:1|task1|--1d-skip"

  "task2|onedrive:2|openlist:wopan176Crypt/2|task2|--auto-split --1d-skip"
  "-|onedrive:2|openlist:wopan175/2|task2|--auto-split --1d-skip"
  # "-|onedrive:2|gd:2|task2|--1d-skip"

  "task3|onedrive:3|openlist:wopan176Crypt/3|task3|--auto-split --1d-skip"
  "-|onedrive:3|openlist:wopan175/3|task3|--auto-split --1d-skip"
  # "-|onedrive:3|gd:3|task3|--1d-skip"

  "task4|onedrive:4|openlist:wopan176Crypt/4|task4|--auto-split --1d-skip"
  "-|onedrive:4|openlist:wopan175/4|task4|--auto-split --1d-skip"

  "task5|onedrive:5|openlist:wopan176Crypt/5|task5|--auto-split --1d-skip"
  "-|onedrive:5|openlist:wopan175/5|task5|--auto-split --1d-skip"
)

# 执行清单中的一条任务（供 run_all_tasks / run_task_by_id 复用）
_run_registry_entry() {
  local _e="$1"
  local _id _src _dst _name _flags
  local -a _flag_arr
  IFS='|' read -r _id _src _dst _name _flags <<< "$_e"
  read -ra _flag_arr <<< "$_flags"
  sync_task "$_src" "$_dst" "$_name" "${_flag_arr[@]}"
}

# 顺序执行清单中的全部任务
run_all_tasks() {
  local _e
  for _e in "${SYNC_TASK_REGISTRY[@]}"; do
    _run_registry_entry "$_e"
  done
}

# 按 id 执行清单中的单条任务（调试模式专用）
run_task_by_id() {
  local _want="$1" _e _id
  for _e in "${SYNC_TASK_REGISTRY[@]}"; do
    _id="${_e%%|*}"
    [ "$_id" = "$_want" ] || continue
    _run_registry_entry "$_e"
    return $?
  done
  echo "未知任务: ${_want}（可选: backup/task0-task5）"
  return 1
}

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

# 目标端路径过长时截断为 "remote:挂载/一级目录/..."（保留头部上下文）
# 用于进度通知的任务显示名（如 openlist:wopan175/0/xxx → openlist:wopan175/0/...）
_short_dest_head() {
  local p="${1:-}" max_len=40
  [ ${#p} -le "$max_len" ] && { echo "$p"; return; }
  case "$p" in
    *:*)
      local remote="${p%%:*}" rest="${p#*:}"
      local first="${rest%%/*}" rest2="${rest#*/}"
      case "$rest2" in
        */*) echo "${remote}:${first}/${rest2%%/*}/..." ;;
        *)   echo "$p" ;;
      esac
      ;;
    *)
      echo "...${p: -$((max_len - 3))}"
      ;;
  esac
}

# 预览/仅注册模式：注册任务到进度系统（不实际同步）
#   TASK_PREVIEW_ONLY=1  — 注册 + 发送预览通知
#   TASK_REGISTER_ONLY=1 — 仅注册（skip_preview=true 时使用，保证进度消息
#                          "总任务"从一开始就是全量，而非随 task_begin 逐个增长）
_preview_register() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"
  shift 3
  local extra_args=("$@")

  # 仅注册模式跳过预览通知，只算源端大小并注册
  if [ "${TASK_REGISTER_ONLY:-0}" != "1" ]; then
    # task_name 变化时刷新上一个预览组
    if [ "$_PREVIEW_CUR_TASK" != "$task_name" ]; then
      if [ -n "$_PREVIEW_CUR_TASK" ]; then
        flush_task_preview
      fi
      start_task_preview "$task_name"
      _PREVIEW_CUR_TASK="$task_name"
    fi
    add_preview_pair "$source_path" "$dest_path" "${extra_args[@]}"
  fi

  # 注册到进度系统（pending 状态）
  # 显示名: 目标端过长时截断；附源端大小提示（add_preview_pair 刚算过，缓存命中）
  local _task_id _src_bytes _size_hint
  _task_id=$(_derive_task_id "$task_name" "$dest_path")
  _src_bytes=$(_get_source_size_with_excludes "$source_path" "${extra_args[@]}" | awk '{print $1}')
  _size_hint=""
  [[ "$_src_bytes" =~ ^[0-9]+$ ]] && [ "$_src_bytes" -gt 0 ] && _size_hint=$(format_bytes "$_src_bytes")
  progress_register_task "$_task_id" "${source_path} → $(_short_dest_head "$dest_path")" "$_size_hint"
}

# 渲染子目录阶段树（供 PROGRESS_PHASE_INFO，多行）
# 依赖调用方（_sync_task_impl）作用域内的变量（bash 动态作用域可见）:
#   subdirs（排序后的子目录列表）/ subdir_size_map / subdir_status_map /
#   total_subdirs_count / source_size_bytes
# 输出格式（状态由 emoji 表达，不重复文字说明，紧凑单行）:
#   ▸ 源端 28 GiB
#   ├─ ✅ a · 4 GiB
#   └─ 🔄 b · 17 GiB
_render_subdir_phase_tree() {
  local _tree="▸ 源端 $(format_bytes "$source_size_bytes")"
  local _name _mark _conn _i=0
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    _i=$((_i + 1))
    case "${subdir_status_map[$_name]:-pending}" in
      synced)  _mark="✅" ;;
      skipped) _mark="⏭️" ;;
      partial) _mark="⚠️" ;;
      failed)  _mark="❌" ;;
      syncing) _mark="🔄" ;;
      *)       _mark="⏳" ;;
    esac
    _conn="├─"; [ "$_i" -eq "$total_subdirs_count" ] && _conn="└─"
    _tree+=$'\n'"${_conn} ${_mark} $(escape_html "$_name") · $(format_bytes "${subdir_size_map[$_name]:-0}")"
  done <<< "$subdirs"
  echo "$_tree"
}

# 任务收尾：成功且启用 skip 时写跳过标记；顶级调用失败时切割大文件；恢复进度变量
# 依赖调用方（_sync_task_impl）作用域内的变量（bash 动态作用域可见）:
#   source_path / dest_path / task_name / extra_args / current_depth / _old_phase / _old_stats
_sync_task_finalize() {
  local _rc="$1"
  if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  elif [ "$current_depth" -eq 0 ]; then
    split_on_sync_failure "$source_path" "$task_name"
  fi
  PROGRESS_PHASE_INFO="$_old_phase"
  PROGRESS_STATS="$_old_stats"
  return "$_rc"
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
    SYNC_PARTIAL=0
    # 初始化修复文件累计器（sync_with_logging 每次执行后会累加到此变量）
    # auto-split 子目录的修复也会累计到这里，最终由 save_sync_marker 写入 marker
    GLOBAL_FIXED_FILES_JSON="[]"
    # 方法假成功黑名单累计器（B: 失败记忆）与本轮已修复文件表
    GLOBAL_FIX_BLACKLIST_JSON="{}"
    FIXED_THIS_RUN=()
  fi

  local max_depth=10
  local subdir

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
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
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  # 50GB 阈值（带默认值，防止跨 step 环境变量丢失时为空）
  local threshold="${SYNC_SPLIT_THRESHOLD_BYTES:-50000000000}"

  # 检查源端大小
  local source_size_bytes=0
  local size_json
  size_json=$(_rclone_size_json "$source_path")
  if [ -n "$size_json" ]; then
    source_size_bytes=$(_size_json_field "$size_json" bytes)
  fi
  # 确保 source_size_bytes 是有效整数，否则置 0
  [[ "$source_size_bytes" =~ ^[0-9]+$ ]] || source_size_bytes=0

  if [ "$source_size_bytes" -le "$threshold" ]; then
    echo "源端大小 $(format_bytes_iec "$source_size_bytes") 未超过 50GB 阈值，直接同步"
    progress_update "直接同步中（源端 $(format_bytes "$source_size_bytes")）"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  # 超过 50GB，需要拆分
  if [ "$current_depth" -ge "$max_depth" ]; then
    echo "已达最大拆分深度 ${max_depth}，按文件批次拆分 (depth=${current_depth}, size=$(format_bytes_iec "$source_size_bytes"))"
    progress_update "文件批次拆分（已达最大深度 ${current_depth}）"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  echo "源端大小 $(format_bytes_iec "$source_size_bytes") 超过 50GB 阈值，按子目录拆分同步 (depth=${current_depth})"

  # 列出一级子目录
  local subdirs
  subdirs=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||')
  if [ -z "$subdirs" ]; then
    echo "无子目录，按文件批次拆分同步"
    progress_update "无子目录，按文件批次拆分"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
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
      _sync_task_finalize "$_rc"
      return "$_rc"
    fi
  fi

  # 按子目录大小从小到大排序
  echo "按子目录大小排序..."
  PROGRESS_PHASE_INFO="▸ 📂 子目录拆分（depth=${current_depth}，源端 $(format_bytes "$source_size_bytes")，正在统计大小...）"
  progress_update "正在按子目录大小排序..."
  local sorted_subdirs=""
  declare -A subdir_size_map=()
  declare -A subdir_status_map=()
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    local subdir_bytes=0
    local subdir_json
    subdir_json=$(_rclone_size_json "${source_path}/${subdir}")
    [ -n "$subdir_json" ] && subdir_bytes=$(_size_json_field "$subdir_json" bytes)
    subdir_size_map["$subdir"]=$subdir_bytes
    echo "  ${subdir}: $(format_bytes "$subdir_bytes")"
    sorted_subdirs+="${subdir_bytes} ${subdir}"$'\n'
  done <<< "$subdirs"
  subdirs=$(echo "$sorted_subdirs" | sort -n | cut -d' ' -f2-)

  # 预统计子目录总数（用于进度展示）
  local total_subdirs_count
  total_subdirs_count=$(echo "$subdirs" | grep -c . 2>/dev/null || echo 0)

  # 按子目录逐个同步（静默模式：无文件变更时跳过通知）
  SYNC_SKIP_QUIET=1
  local total_subtasks=0
  local synced_subtasks=0
  local failed_subtasks=0
  local partial_subtasks=0
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
    subdir_status_map["$subdir"]="syncing"
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    local _completed_before=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    # detail 留空: 任务行只显示名称，进度由阶段树（🔄 标记）+ 统计行表达；
    # 必须用 force: 上一个子目录的完成刷新刚更新过节流时间戳，普通 update
    # 会被 2s 节流吞掉，导致整个子目录同步期间消息停留在旧树（当前子目录
    # 一直显示 ⏳ 待同步而非 🔄 同步中）
    progress_update_force "" "▸ 📊 子目录：${_completed_before}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⏳$((total_subdirs_count - _completed_before)) ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
    SYNC_AUTO_SPLIT_DEPTH=$((current_depth + 1))
    # PROGRESS_SUPPRESS=1: 子任务内部的 progress_update 不覆盖父任务的
    # 阶段树（当前子目录已由上方标记为 🔄 同步中）
    PROGRESS_SUPPRESS=1
    # < /dev/null: 子任务全链路（sync/fix/marker）不读 stdin；不隔离的话
    # 链路里任何误读 stdin 的命令（jq/rclone rcat 等）会把本循环的子目录
    # 列表吃掉，剩余子任务被静默跳过（run 31954162437 实锤: 只同步了
    # archive 就跳去最终完整同步，照片/j-1024j 两个子任务丢失）
    _sync_task_impl "${source_path}/${subdir}" "${dest_path}/${subdir}" "${safe_subtask}" "${extra_args[@]}" < /dev/null || true
    PROGRESS_SUPPRESS=0
    SYNC_AUTO_SPLIT_DEPTH=$current_depth
    if [ "$SYNC_SKIPPED" = "1" ]; then
      skipped_subtasks=$((skipped_subtasks + 1))
      subdir_status_map["$subdir"]="skipped"
      skipped_list+="• <code>$(escape_html "$subdir")</code> · <i>$(format_bytes "${subdir_size_map[$subdir]:-0}")</i>"$'\n'
    elif [ "$SYNC_FAILED" = "0" ]; then
      synced_subtasks=$((synced_subtasks + 1))
      subdir_status_map["$subdir"]="synced"
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      synced_list+="• <code>$(escape_html "$subdir")</code> · <i>$(format_bytes "${subdir_size_map[$subdir]:-0}")</i>"$'\n'
    else
      failed_subtasks=$((failed_subtasks + 1))
      if [ "${SYNC_PARTIAL:-0}" = "1" ]; then
        # 有文件成功但有文件失败/缺失（sync_with_logging 导出的部分失败标志）
        partial_subtasks=$((partial_subtasks + 1))
        subdir_status_map["$subdir"]="partial"
      else
        subdir_status_map["$subdir"]="failed"
      fi
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      failed_list+="• <code>$(escape_html "$subdir")</code> · <i>$(format_bytes "${subdir_size_map[$subdir]:-0}")</i>$([ "${subdir_status_map[$subdir]}" = partial ] && echo ' · <b>部分失败</b>')"$'\n'
    fi
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    local _completed_after=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    progress_update_force "" "▸ 📊 子目录：${_completed_after}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⏳$((total_subdirs_count - _completed_after)) ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
  done <<< "$subdirs"
  SYNC_SKIP_QUIET=0

  # 设置拆分信息供最终通知使用（HTML 片段，由 sync.sh 通知按分节插入）
  AUTO_SPLIT_INFO="<b>🔀 子任务拆分统计</b>"$'\n'
  AUTO_SPLIT_INFO+="总子目录：<b>${total_subtasks}</b> · 传输总量：<b>$(format_bytes "$total_transferred")</b>"$'\n'
  local _counts="✅ <b>${synced_subtasks}</b> · ❌ <b>${failed_subtasks}</b>"
  [ "$partial_subtasks" -gt 0 ] && _counts+=" · ⚠️ <b>${partial_subtasks}</b>"
  _counts+=" · ⏭️ <b>${skipped_subtasks}</b>"
  AUTO_SPLIT_INFO+="${_counts}"
  if [ -n "$synced_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"<b>✅ 已同步的子目录</b>"$'\n'"${synced_list%$'\n'}"
  fi
  if [ -n "$failed_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"<b>❌ 未同步的子目录</b>"$'\n'"${failed_list%$'\n'}"
  fi
  if [ -n "$skipped_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"<b>⏭️ 已跳过的子目录（无文件变动）</b>"$'\n'"${skipped_list%$'\n'}"
  fi

  # 最终完整同步（仅在顶层执行，正常通知）
  if [ "$current_depth" -eq 0 ]; then
    echo "=== 最终完整同步: ${task_name} ==="
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    progress_update_force "最终完整同步中" "▸ 📊 子目录：${total_subtasks}/${total_subtasks} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    AUTO_SPLIT_INFO=""
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    else
      split_on_sync_failure "$source_path" "$task_name"
    fi
  else
    # 递归子任务收尾：把聚合状态传回父级（父循环依据 SYNC_FAILED/SYNC_SKIPPED
    # 对本子目录分类）。失败子目录数 > 0 时必须保持 SYNC_FAILED=1，否则父级
    # 会把本任务误判为"已同步"，深层失败被静默吞掉
    SYNC_SKIPPED=0
    if [ "$failed_subtasks" -gt 0 ]; then SYNC_FAILED=1; else SYNC_FAILED=0; fi
    if [ "$partial_subtasks" -gt 0 ]; then SYNC_PARTIAL=1; else SYNC_PARTIAL=0; fi
    SYNC_TRANSFERRED_BYTES=$total_transferred
    if [ "$failed_subtasks" -eq 0 ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
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
  extra_args=("${RCLONE_SYNC_TASK_FLAGS[@]}" "${extra_args[@]}")

  # 根据 skip 天数设置 SYNC_SKIP_SECONDS
  if [ "$_skip_days" -gt 0 ]; then
    SYNC_SKIP_SECONDS=$((_skip_days * 24 * 60 * 60))
  fi

  local current_depth=${SYNC_AUTO_SPLIT_DEPTH:-0}

  # 预览/仅注册模式：只注册，不实际同步
  if [ "$current_depth" -eq 0 ] && { [ -n "$TASK_PREVIEW_ONLY" ] || [ "${TASK_REGISTER_ONLY:-0}" = "1" ]; }; then
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

  # 无论本轮成败，持久化修复状态（fixed_files + fix_blacklist）
  # 部分失败轮（SYNC_FAILED=1）不写跳过 marker，但修复成果必须记录：
  # 否则下一轮会重复下载/打包/上传已持久化的替代文件，跨轮方法黑名单也会丢失。
  # 任务被跳过时（SYNC_SKIPPED=1）本轮无修复活动，不写。
  if [ "$SYNC_SKIPPED" != "1" ]; then
    save_fix_state_marker "$source_path" "$dest_path" "$task_name" || true
  fi

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
    check_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
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
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分（depth=${SYNC_AUTO_SPLIT_DEPTH:-0}，正在列出文件...）"
  progress_update "正在列出文件..."
  # 注意：GitHub Actions 默认 set -e -o pipefail，rclone lsjson 失败时管道会非零退出，
  # 此处只需文件列表（失败时 total_files=0 触发下方 lsf 备选），用 || true 避免 step 直接退出。
  rclone lsjson --recursive --files-only --no-modtime --no-mimetype "$source_path" 2>&1 | jq -c '.[]' > "$file_list_file" 2>/dev/null || true

  local total_files
  total_files=$(wc -l < "$file_list_file" | tr -d ' ')
  echo "总文件数: ${total_files}"
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分（${total_files} 文件，正在拆分批次...）"
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
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：${total_batches} 批 / ${total_files} 文件（每批 ≤ $(format_bytes "$threshold")）"
  progress_update_force "拆分为 ${total_batches} 个批次" "▸ 📊 批次：0/${total_batches}"

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
      PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：${total_batches} 批 / ${total_files} 文件（当前批次 ${batch_idx}：${batch_file_count} 文件）"
      progress_update "批次 ${batch_idx}/${total_batches}：${batch_file_count} 个文件" "▸ 📊 批次：${batch_idx}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"

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
        # grep -c 无匹配时已输出 0（退出码 1），用 || true 防止追加第二行 0
        err_count=$(grep -c 'ERROR.*object not found' "${task_name}_batch_${i}.log" 2>/dev/null || true)
        echo "批次 $((i+1)) 部分成功 (exit=4, ${err_count} 个文件 object not found)"
        grep 'ERROR.*object not found' "${task_name}_batch_${i}.log" 2>/dev/null | head -50 | while IFS= read -r line; do
          echo "  ${line}"
        done
      else
        failed_batches=$((failed_batches + 1))
        failed_batch_list+="• 批次 $((i+1))/${total_batches} · <i>${batch_file_count} 文件</i> · exit=${rc}"$'\n'
        echo "批次 $((i+1)) 失败 (exit=${rc})"
      fi
      progress_update_force "批次 ${batch_idx}/${total_batches} 完成" "▸ 📊 批次：${batch_idx}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"
    fi
  done

  # 清理批次文件
  rm -rf "$batch_dir"

  echo "=== 批次传输完成 (成功 ${synced_batches}/${total_batches}, 失败 ${failed_batches})，执行最终同步检查 ==="
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：${total_batches} 批 / ${total_files} 文件（✅${synced_batches} ❌${failed_batches}）"
  progress_update_force "批次传输完成，最终同步检查中" "▸ 📊 批次：${total_batches}/${total_batches} | ✅${synced_batches} ❌${failed_batches}"

  # 设置批次统计信息，供最终通知展示（与子目录拆分的 AUTO_SPLIT_INFO 对齐）
  AUTO_SPLIT_INFO="<b>🔀 文件批次拆分统计</b>"$'\n'
  AUTO_SPLIT_INFO+="总批次：<b>${total_batches}</b> · 文件数：<b>${batch_total_files}</b>"$'\n'
  AUTO_SPLIT_INFO+="✅ <b>${synced_batches}</b> · ❌ <b>${failed_batches}</b>"
  if [ -n "$failed_batch_list" ]; then
    AUTO_SPLIT_INFO+=$'\n\n'"<b>❌ 失败的批次</b>"$'\n'"${failed_batch_list%$'\n'}"
  fi

  # 最终用 sync_with_logging 做完整同步检查（处理缺失文件修复、通知等）
  # 文件批次阶段已完成实质传输，最终 sync 即使无新增 Copied 记录也必须发通知；
  # 此处可能被子目录递归调用（SYNC_SKIP_QUIET=1），需临时关闭静默模式，避免通知被吞。
  # 跳过标记（save_sync_marker）不在本函数保存——调用方 _sync_task_impl 随后的
  # _sync_task_finalize 会按统一条件保存，这里保存会重复执行远端统计。
  local _saved_skip_quiet="${SYNC_SKIP_QUIET:-0}"
  SYNC_SKIP_QUIET=0
  sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  AUTO_SPLIT_INFO=""
  SYNC_SKIP_QUIET="$_saved_skip_quiet"
}
