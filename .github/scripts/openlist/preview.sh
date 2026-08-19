#!/bin/bash
# ===== OpenList 同步工具 — 任务预览系统 =====
# 在实际同步前，发送预览通知展示:
#   - 每个同步对的源端大小、预估待同步量（按源端分组的树形列表）
#   - 合计预估待同步量
#
# 依赖: utils.sh (format_bytes, _extract_exclude_summary, escape_html, tree_*)
# 依赖: telegram.sh (send_telegram_message, tg_add_title/tg_add_section/tg_append)

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

  # 同步对数据缓冲（TSV），flush_task_preview 时按源端分组渲染为
  # 📁 组头 + ├─/└─ 树形条目（与进度通知的任务列表同风格）
  # 空字段写 "-" 占位: tab 是 IFS 空白类字符，read 会吞掉空列导致字段错位
  # （同 progress.sh 的任务队列 TSV 约定）
  local _excl_ph="${exclude_summary:--}"
  local _fnote_ph="${fixed_note:--}"
  PREVIEW_PAIRS_TSV+="${source_path}"$'\t'"${_excl_ph}"$'\t'"${src_bytes}"$'\t'"${src_count}"$'\t'"${dest_path}"$'\t'"${sync_bytes}"$'\t'"${sync_count}"$'\t'"${_fnote_ph}"$'\n'
}

# 同步对详情渲染: 仅按源端分组（同源端多目标一组的树形列表）
#   📁 <code>src</code> · <i>源端 X / N 文件</i>        ← 组内各条目源端大小一致时上提组头
#     ├─ <code>dst</code> · <i>源端 X / N 文件</i> · <b>+Y / +K 文件</b>
#     │   排除：<code>pat</code>                          ← 有排除规则的条目子行
#     └─ <code>dst</code> · <i>无变动</i>
#   组内源端大小不一（如部分目标带排除规则）时组头不带大小、各条目单独标注，
#   避免同一源端因排除规则不同而分裂成多组; 组间空一行分隔。
# 输入: PREVIEW_PAIRS_TSV（每行 src/excl/sbytes/scount/dst/ybytes/ycount/fnote）
_preview_render_pairs_detail() {
  # 第一遍: 按源端聚合条目数，并判断组内源端大小是否一致（能否上提组头）
  declare -A _g_total=() _g_size=()
  local -a _g_order=()
  while IFS=$'\t' read -r _src _excl _sbytes _scount _dst _ybytes _ycount _fnote; do
    [ -z "$_src" ] && continue
    if [ -z "${_g_total[$_src]+x}" ]; then
      _g_total[$_src]=0
      _g_order+=("$_src")
      _g_size[$_src]="${_sbytes}|${_scount}"
    elif [ "${_g_size[$_src]}" != "${_sbytes}|${_scount}" ]; then
      _g_size[$_src]=""   # 大小不一 → 不上提
    fi
    _g_total[$_src]=$(( ${_g_total[$_src]} + 1 ))
  done <<< "$PREVIEW_PAIRS_TSV"
  # 第二遍: 渲染条目（含子行），按组缓冲
  declare -A _g_seen=() _g_block=()
  while IFS=$'\t' read -r _src _excl _sbytes _scount _dst _ybytes _ycount _fnote; do
    [ -z "$_src" ] && continue
    # 还原 "-" 占位为空
    [ "$_excl" = "-" ] && _excl=""
    [ "$_fnote" = "-" ] && _fnote=""
    _g_seen[$_src]=$(( ${_g_seen[$_src]:-0} + 1 ))
    local _last=0
    [ "${_g_seen[$_src]}" -eq "${_g_total[$_src]}" ] && _last=1
    # 目标端 openlist: 前缀冗余（与进度通知一致），统一裁剪
    local _entry="<code>$(escape_html "${_dst#openlist:}")</code>"
    # 源端大小未上提组头时在条目行标注
    [ -z "${_g_size[$_src]}" ] && _entry+=" · <i>源端 $(format_bytes "$_sbytes") / ${_scount} 文件</i>"
    if [ "$_ybytes" -gt 0 ] || [ "$_ycount" -gt 0 ]; then
      _entry+=" · <b>+$(format_bytes "$_ybytes") / +${_ycount} 文件</b>"
    else
      _entry+=" · <i>无变动</i>"
    fi
    _g_block[$_src]+="$(tree_conn "$_last")${_entry}"$'\n'
    local _sub
    _sub=$(tree_sub "$_last")
    [ -n "$_excl" ] && _g_block[$_src]+="${_sub}排除：<code>$(escape_html "$_excl")</code>"$'\n'
    [ -n "$_fnote" ] && _g_block[$_src]+="${_sub}${_fnote# · }"$'\n'
  done <<< "$PREVIEW_PAIRS_TSV"
  # 组装: 组头 + 树形条目块，组间空一行（首组前不加——tg_add_section 已带段前空行）
  local _out="" _src _gi=0
  for _src in "${_g_order[@]}"; do
    [ "$_gi" -gt 0 ] && _out+=$'\n'
    _out+="📁 <code>$(escape_html "$_src")</code>"
    if [ -n "${_g_size[$_src]}" ]; then
      _out+=" · <i>源端 $(format_bytes "${_g_size[$_src]%%|*}") / ${_g_size[$_src]##*|} 文件</i>"
    fi
    _out+=$'\n'"${_g_block[$_src]%$'\n'}"$'\n'
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
  tg_append msg $'\n\n'"📦 合计预估待同步：<b>$(format_bytes "$PREVIEW_TOTAL_SYNC_BYTES")</b> / <b>${PREVIEW_TOTAL_SYNC_COUNT}</b> 文件"

  send_telegram_message "$msg"
  echo "  已发送 ${PREVIEW_TASK_NAME} 预览通知"
}
