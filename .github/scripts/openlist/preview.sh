#!/bin/bash
# ===== OpenList 同步工具 — 任务预览系统 =====
# 在实际同步前，发送预览通知展示:
#   - 每个同步对的源端/目标端大小和文件数
#   - 预估待同步的数据量
#   - 文件同步流量图（ASCII 树形图）
#
# 依赖: utils.sh (format_bytes, _shorten_path, _extract_exclude_summary, escape_html)
# 依赖: telegram.sh (send_telegram_message, tg_add_title/tg_add_section/tg_add_block 等)

# 获取远端大小和文件数
# 用法: _get_remote_size_count <remote_path> [--exclude pat] ...
# 与源端 _get_source_size_with_excludes 保持同样的过滤口径，避免因 exclude 规则
# 仅作用于源端而导致目标端统计包含历史残留文件，使预览文件数/大小永远对不上。
# 返回: "bytes count" 或 "0 0"
_get_remote_size_count() {
  local remote_path="$1"
  shift
  local -a extra_args=("$@")
  local err_file="/tmp/_rclone_size_err_$$"
  local size_json
  if [ ${#extra_args[@]} -gt 0 ]; then
    size_json=$(rclone size "$remote_path" --json "${extra_args[@]}" 2>"$err_file" || true)
  else
    size_json=$(rclone size "$remote_path" --json 2>"$err_file" || true)
  fi
  if [ -z "$size_json" ]; then
    echo "⚠️ _get_remote_size_count: rclone size 失败 (${remote_path})" >&2
    if [ -s "$err_file" ]; then
      echo "   $(head -3 "$err_file" | tr '\n' ' ')" >&2
    fi
    rm -f "$err_file"
    echo "0 0"
    return
  fi
  rm -f "$err_file"
  local bytes count
  bytes=$(_size_json_field "$size_json" bytes)
  count=$(_size_json_field "$size_json" count)
  echo "${bytes} ${count}"
}

# 源端大小缓存（按 source_path + excludes 组合做 key，避免重复调用 rclone size）
declare -A PREVIEW_SRC_CACHE

# 获取源端大小（带 --exclude 参数，带缓存）
# 用法: _get_source_size_with_excludes <source_path> [--exclude pat] ...
# 返回: "bytes count"
_get_source_size_with_excludes() {
  local source_path="$1"
  shift
  local extra_args=("$@")
  local cache_key="${source_path} ${extra_args[*]}"

  if [ -n "${PREVIEW_SRC_CACHE[$cache_key]:-}" ]; then
    echo "${PREVIEW_SRC_CACHE[$cache_key]}"
    return
  fi

  local result="0 0"
  local size_json
  size_json=$(_rclone_size_json "$source_path" "${extra_args[@]}")
  if [ -n "$size_json" ]; then
    result="$(_size_json_field "$size_json" bytes) $(_size_json_field "$size_json" count)"
  fi
  PREVIEW_SRC_CACHE[$cache_key]="$result"
  echo "$result"
}

# 开始一个主任务的预览
# 用法: start_task_preview <task_name>
start_task_preview() {
  local task_name="$1"
  PREVIEW_TASK_NAME="$task_name"
  PREVIEW_PAIR_COUNT=0
  PREVIEW_TOTAL_SYNC_BYTES=0
  PREVIEW_TOTAL_SYNC_COUNT=0
  PREVIEW_PAIRS_TSV=""
  PREVIEW_FLOW=""
  PREVIEW_CUR_GROUP=""
  echo "=== 预览任务: ${task_name} ==="
}

# 添加一个同步对到预览
# 用法: add_preview_pair <source_path> <dest_path> [--exclude pat] ...
add_preview_pair() {
  local source_path="$1"
  local dest_path="$2"
  shift 2
  local extra_args=("$@")

  PREVIEW_PAIR_COUNT=$((PREVIEW_PAIR_COUNT + 1))
  echo "  同步对 ${PREVIEW_PAIR_COUNT}: ${source_path} → ${dest_path}"

  # 获取源端大小（带 exclude，带缓存）
  local src_data src_bytes src_count
  src_data=$(_get_source_size_with_excludes "$source_path" "${extra_args[@]}")
  src_bytes=$(echo "$src_data" | awk '{print $1}')
  src_count=$(echo "$src_data" | awk '{print $2}')

  # 获取目标大小（与源端使用相同的 --exclude 口径，避免目标端历史残留文件
  # 被计入统计而使文件数/大小与源端对不上）
  local dst_data dst_bytes dst_count
  dst_data=$(_get_remote_size_count "$dest_path" "${extra_args[@]}")
  dst_bytes=$(echo "$dst_data" | awk '{print $1}')
  dst_count=$(echo "$dst_data" | awk '{print $2}')

  # 计算预估待同步（原始差值）
  local sync_bytes sync_count
  if [ "$src_bytes" -gt "$dst_bytes" ]; then
    sync_bytes=$((src_bytes - dst_bytes))
  else
    sync_bytes=0
  fi
  if [ "$src_count" -gt "$dst_count" ]; then
    sync_count=$((src_count - dst_count))
  else
    sync_count=0
  fi

  # 扣减已通过修复方式同步的文件（这些文件在目标端以不同路径/文件名存在）
  # 避免修复文件导致预览显示"虚假缺失"
  _load_marker_fixed_files "$source_path" "$dest_path" "${PREVIEW_TASK_NAME:-}"
  local raw_sync_bytes="$sync_bytes" raw_sync_count="$sync_count"
  local fixed_note=""
  if [ "${MARKER_FIXED_COUNT:-0}" -gt 0 ]; then
    local adjusted_count=$((sync_count - MARKER_FIXED_COUNT))
    [ "$adjusted_count" -lt 0 ] && adjusted_count=0
    local adjusted_bytes=$((sync_bytes - MARKER_FIXED_BYTES))
    [ "$adjusted_bytes" -lt 0 ] && adjusted_bytes=0
    fixed_note=" · <i>已扣减 ${MARKER_FIXED_COUNT} 个修复文件 / $(format_bytes "$MARKER_FIXED_BYTES")</i>"
    sync_count=$adjusted_count
    sync_bytes=$adjusted_bytes
  fi

  PREVIEW_TOTAL_SYNC_BYTES=$((PREVIEW_TOTAL_SYNC_BYTES + sync_bytes))
  PREVIEW_TOTAL_SYNC_COUNT=$((PREVIEW_TOTAL_SYNC_COUNT + sync_count))

  # exclude 摘要
  local exclude_summary
  exclude_summary=$(_extract_exclude_summary "${extra_args[@]}")

  # 同步对数据缓冲（TSV），flush_task_preview 时按源端（+exclude）分组
  # 渲染为 📁 组头 + ├─/└─ 树形条目（与进度通知的任务列表同风格）
  # 空字段写 "-" 占位: tab 是 IFS 空白类字符，read 会吞掉空列导致字段错位
  # （同 progress.sh 的任务队列 TSV 约定）
  local _excl_ph="${exclude_summary:--}"
  local _fnote_ph="${fixed_note:--}"
  PREVIEW_PAIRS_TSV+="${source_path}"$'\t'"${_excl_ph}"$'\t'"${src_bytes}"$'\t'"${src_count}"$'\t'"${dest_path}"$'\t'"${dst_bytes}"$'\t'"${dst_count}"$'\t'"${sync_bytes}"$'\t'"${sync_count}"$'\t'"${_fnote_ph}"$'\n'

  # 流量图分组（按 source + excludes 组合分组，相同分组的 dest 共享一个源端节点）
  local group_key="${source_path}|${exclude_summary}"
  if [ "$group_key" != "$PREVIEW_CUR_GROUP" ]; then
    # 新分组前空一行
    if [ -n "$PREVIEW_CUR_GROUP" ]; then
      PREVIEW_FLOW+=$'\n'
    fi
    PREVIEW_CUR_GROUP="$group_key"
    if [ -n "$exclude_summary" ]; then
      PREVIEW_FLOW+="  $(escape_html "$source_path")（排除 $(escape_html "$exclude_summary")）"$'\n'
    else
      PREVIEW_FLOW+="  $(escape_html "$source_path")"$'\n'
    fi
    PREVIEW_FLOW+="  $(format_bytes "$src_bytes") / ${src_count} 文件"$'\n'
    PREVIEW_FLOW+="       │"$'\n'
  fi

  local short_dest
  short_dest=$(_shorten_path "$dest_path" 48)
  PREVIEW_FLOW+="   ├──► $(escape_html "$short_dest")"$'\n'
  PREVIEW_FLOW+="         [+$(format_bytes "$sync_bytes") / +${sync_count} 文件]"$'\n'
}

# 同步对详情渲染: 按源端（+exclude）分组，与进度通知任务列表同风格
#   📁 <code>src</code>（排除 <code>pat</code>） · <i>源端 X / N 文件</i>
#     ├─ <code>dst</code> · <i>目标 Y / M 文件</i> · <b>+Z / +K 文件</b>
#   组间空一行分隔（首组前不加空行——tg_add_section 已带段前空行）
# 输入: PREVIEW_PAIRS_TSV（每行 src/excl/sbytes/scount/dst/dbytes/dcount/ybytes/ycount/fnote）
_preview_render_pairs_detail() {
  declare -A _g_entries=() _g_header=()
  local -a _g_order=()
  while IFS=$'\t' read -r _src _excl _sbytes _scount _dst _dbytes _dcount _ybytes _ycount _fnote; do
    [ -z "$_src" ] && continue
    # 还原 "-" 占位为空
    [ "$_excl" = "-" ] && _excl=""
    [ "$_fnote" = "-" ] && _fnote=""
    local _key="${_src}|${_excl}"
    if [ -z "${_g_entries[$_key]+x}" ]; then
      _g_entries[$_key]=""
      _g_order+=("$_key")
      local _hdr="📁 <code>$(escape_html "$_src")</code>"
      [ -n "$_excl" ] && _hdr+="（排除 <code>$(escape_html "$_excl")</code>）"
      _hdr+=" · <i>源端 $(format_bytes "$_sbytes") / ${_scount} 文件</i>"
      _g_header[$_key]="$_hdr"
    fi
    # 目标端 openlist: 前缀冗余（与进度通知一致），统一裁剪
    local _dst_clean="${_dst#openlist:}"
    _g_entries[$_key]+="<code>$(escape_html "$_dst_clean")</code> · <i>目标 $(format_bytes "$_dbytes") / ${_dcount} 文件</i> · <b>+$(format_bytes "$_ybytes") / +${_ycount} 文件</b>${_fnote}"$'\n'
  done <<< "$PREVIEW_PAIRS_TSV"
  local _out="" _key _gi=0
  for _key in "${_g_order[@]}"; do
    [ "$_gi" -gt 0 ] && _out+=$'\n'
    _out+="${_g_header[$_key]}"$'\n'"$(tree_lines "${_g_entries[$_key]}")"$'\n'
    _gi=$((_gi + 1))
  done
  printf '%s' "$_out"
}

# 发送任务预览通知到 Telegram
# 用法: flush_task_preview
flush_task_preview() {
  local msg=""
  tg_add_title msg "📋 任务预览 · ${PREVIEW_TASK_NAME}"
  tg_add_section msg "📊 同步对（${PREVIEW_PAIR_COUNT} 对）"
  tg_append msg "$(_preview_render_pairs_detail)"
  tg_add_section msg "🔀 文件同步流量图"
  # 流量图用 <pre> 等宽渲染，保证 │/├──► 树形对齐（内容构建时已逐行转义）
  tg_add_block msg "<pre>${PREVIEW_FLOW%$'\n'}</pre>"
  tg_append msg $'\n'"📦 合计预估待同步：<b>$(format_bytes "$PREVIEW_TOTAL_SYNC_BYTES")</b> / <b>${PREVIEW_TOTAL_SYNC_COUNT}</b> 文件"

  send_telegram_message "$msg"
  echo "  已发送 ${PREVIEW_TASK_NAME} 预览通知"
}
