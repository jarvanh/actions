#!/bin/bash
# ===== OpenList 同步工具 — 全局进度通知系统 =====
# 基于"单条消息 + 任务队列"模式，跨 step 持久化状态到 /tmp 文件。
# 每个 GitHub Actions step 是独立 shell，通过文件传递状态。
#
# 状态文件（跨 step 持久化）:
#   PROGRESS_MSG_ID_FILE     — 当前进度消息的 message_id
#   PROGRESS_TASKS_FILE      — 任务队列（TSV: task_id, display_name, status, detail, size_hint）
#   PROGRESS_CURRENT_FILE    — 当前正在执行的任务 ID
#   PROGRESS_START_FILE      — 进度开始时间戳
#   PROGRESS_ROWS_FILE.N     — 拆分深度 N 的阶段树行（原始行，连接符由渲染器加）
#   PROGRESS_STATS_FILE.N    — 拆分深度 N 的统计信息（HTML 片段）
#   （多层槽位: auto-split 递归时每层写入自己的深度槽位，渲染时逐层缩进
#   合并展示；行内容含 HTML 已由生产方 escape，此处透传）
#   PROGRESS_FINALIZED_FILE  — 最终完成标记
#
# 依赖: telegram.sh (send/edit/delete), utils.sh (escape_html)

# 状态文件路径定义
PROGRESS_MSG_ID_FILE="/tmp/progress_msg_id.txt"
PROGRESS_TASKS_FILE="/tmp/progress_tasks.tsv"
PROGRESS_CURRENT_FILE="/tmp/progress_current.txt"
PROGRESS_START_FILE="/tmp/progress_start.txt"
# 阶段树/统计按拆分深度分槽存储（auto-split 递归可达 10 层，留余量取 16）
PROGRESS_MAX_DEPTH=16
_progress_slot_rows() { printf '/tmp/progress_rows.%d' "$1"; }
_progress_slot_stats() { printf '/tmp/progress_stats.%d' "$1"; }
PROGRESS_FINALIZED_FILE="/tmp/progress_finalized.txt"
# 节流时间戳文件（避免频繁刷新 Telegram 消息）
PROGRESS_LAST_UPDATE_FILE="/tmp/progress_last_update.txt"

# 注册任务到队列（初始化时调用）
# 用法: progress_register_task <task_id> <display_name> [size_hint]
#   size_hint — 源端大小（如 "3.100 GiB"），非运行态任务展示为 "• 名称 — 大小"
# TSV 格式: task_id \t display_name \t status(pending/running/completed/skipped/failed) \t detail \t size_hint
progress_register_task() {
  local task_id="$1"
  local display_name="$2"
  local size_hint="${3:-}"
  [ -z "$task_id" ] && return
  # 空字段写 "-" 占位: tab 是 IFS 空白类字符，read 会吞掉空列导致字段错位
  [ -z "$size_hint" ] && size_hint="-"
  echo -e "${task_id}\t${display_name}\tpending\t-\t${size_hint}" >> "$PROGRESS_TASKS_FILE"
}

# 更新任务状态
# 用法: _progress_set_task_status <task_id> <status> [detail]
_progress_set_task_status() {
  local task_id="$1"
  local status="$2"
  local detail="${3:-}"
  [ -z "$task_id" ] || [ -z "$status" ] && return
  [ -f "$PROGRESS_TASKS_FILE" ] || return
  # 空字段写 "-" 占位（同 progress_register_task 注释）
  [ -z "$detail" ] && detail="-"
  local tmp
  tmp=$(mktemp)
  while IFS=$'\t' read -r tid tname tstatus tdetail tsize; do
    [ -z "$tsize" ] && tsize="-"
    if [ "$tid" = "$task_id" ]; then
      echo -e "${tid}\t${tname}\t${status}\t${detail}\t${tsize}" >> "$tmp"
    else
      echo -e "${tid}\t${tname}\t${tstatus}\t${tdetail}\t${tsize}" >> "$tmp"
    fi
  done < "$PROGRESS_TASKS_FILE"
  mv "$tmp" "$PROGRESS_TASKS_FILE"
}

# 加载进度开始时间（无则返回当前时间）
_progress_get_start_time() {
  if [ -f "$PROGRESS_START_FILE" ]; then
    cat "$PROGRESS_START_FILE" 2>/dev/null
  else
    date +%s
  fi
}

# 获取当前正在执行的任务 ID
_progress_get_current_task() {
  [ -f "$PROGRESS_CURRENT_FILE" ] && head -1 "$PROGRESS_CURRENT_FILE" 2>/dev/null || echo ""
}

# 清空 base_depth 及更深层级的阶段槽位
# 用法: progress_scope_init <base_depth>
# auto-split 递归进入子任务时调用: 同名深度的槽位可能被上一个兄弟子树
# 留下过期内容（尤其"直接同步中"这类不写树的路径会残留旧树），进入时清空。
progress_scope_init() {
  local _d="${1:-0}"
  local d
  for ((d = _d; d < PROGRESS_MAX_DEPTH; d++)); do
    rm -f "$(_progress_slot_rows "$d")" "$(_progress_slot_stats "$d")"
  done
}

_progress_purge_all_slots() {
  progress_scope_init 0
}

# 阶段树行重排: 🔄 同步行挪到末尾（其余保持原序）
# 多层级渲染时深层块紧跟在本层末尾，把当前同步行置尾才能让深层在视觉上挂其下
_progress_active_last() {
  local _others="" _active="" _l
  while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    case "$_l" in
      🔄*) _active+="${_l}"$'\n' ;;
      *)   _others+="${_l}"$'\n' ;;
    esac
  done
  printf '%s%s' "$_others" "$_active"
}

# 任务列表分组渲染（进度通知专用）
# 任务显示名为 "src → dst"，按源端分组展示，树形层级:
#   📁 <b>src</b> · <i>源端大小</i>
#     ├─ dst · <i>详情</i>
#     └─ dst
#   组间空一行分隔（首组前不加空行——tg_add_section 已带段前空行），
#   条目经 tree_lines 加 ├─/└─ 连接符（utils.sh）; 目标端 openlist: 前缀
#   冗余（所有目标均为 openlist 远端），统一裁剪缩短行宽。
# 无 " → " 结构的显示名（调试任务等）退化为普通 "• 名称" 条目。
# 输入: 每行 "display_name\tsize\tdetail"（size/detail 可空）
_progress_render_task_list() {
  local lines="$1"
  declare -A _grp=() _grp_size=()
  local -a _order=()
  local _plain=""
  while IFS=$'\t' read -r _tname _tsize _tdetail; do
    [ -z "$_tname" ] && continue
    local _src="$_tname" _dst=""
    if [[ "$_tname" == *" → "* ]]; then
      _src="${_tname% → *}"
      _dst="${_tname#* → }"
      _dst="${_dst#openlist:}"
    fi
    if [ -z "$_dst" ]; then
      _plain+="• $(escape_html "$_src")"
      [ -n "$_tsize" ] && _plain+=" · <i>$_tsize</i>"
      _plain+=$'\n'
      continue
    fi
    if [ -z "${_grp[$_src]+x}" ]; then
      _grp[$_src]=""
      _order+=("$_src")
      [ -n "$_tsize" ] && _grp_size[$_src]="$_tsize"
    fi
    local _entry
    _entry="$(escape_html "$_dst")"
    [ -n "$_tdetail" ] && _entry+=" · <i>$(escape_html "$_tdetail")</i>"
    _grp[$_src]+="${_entry}"$'\n'
  done <<< "$lines"
  local _out="" _src _gi=0
  for _src in "${_order[@]}"; do
    # 组间空一行
    [ "$_gi" -gt 0 ] && _out+=$'\n'
    _out+="📁 <b>$(escape_html "$_src")</b>"
    [ -n "${_grp_size[$_src]:-}" ] && _out+=" · <i>${_grp_size[$_src]}</i>"
    _out+=$'\n'"$(tree_lines "${_grp[$_src]}")"$'\n'
    _gi=$((_gi + 1))
  done
  # 普通条目（无 → 结构）与分组之间空一行
  [ -n "$_out" ] && [ -n "$_plain" ] && _out+=$'\n'
  printf '%s' "${_out}${_plain}"
}

# 渲染进度消息为 HTML
# 包含: 标题、总任务统计、阶段信息、统计信息、各状态任务列表、已用时间
_progress_render() {
  local finalized=0
  [ -f "$PROGRESS_FINALIZED_FILE" ] && finalized=1

  local start_time elapsed time_str
  start_time=$(_progress_get_start_time)
  elapsed=$(( $(date +%s) - start_time ))
  local hrs=$((elapsed / 3600))
  local mins=$(((elapsed % 3600) / 60))
  local secs=$((elapsed % 60))
  if [ "$hrs" -gt 0 ]; then
    time_str="${hrs}h ${mins}m"
  elif [ "$mins" -gt 0 ]; then
    time_str="${mins}m ${secs}s"
  else
    time_str="${secs}s"
  fi

  # 统计各状态任务数；条目按 "名\t大小\t详情" 暂存，
  # 渲染时经 _progress_render_task_list 按源端分组（大小为源端大小，
  # 详情仅 running/failed 任务携带）
  local total=0 pending=0 running=0 completed=0 skipped=0 failed=0
  local pending_lines="" running_lines="" completed_lines="" skipped_lines="" failed_lines=""

  if [ -f "$PROGRESS_TASKS_FILE" ]; then
    while IFS=$'\t' read -r tid tname tstatus tdetail tsize; do
      [ -z "$tid" ] && continue
      total=$((total + 1))
      # 还原 "-" 占位为空
      [ "$tdetail" = "-" ] && tdetail=""
      [ "$tsize" = "-" ] && tsize=""
      case "$tstatus" in
        pending)
          pending=$((pending + 1))
          pending_lines+="${tname}"$'\t'"${tsize}"$'\t'$'\n'
          ;;
        running)
          running=$((running + 1))
          running_lines+="${tname}"$'\t'"${tsize}"$'\t'"${tdetail}"$'\n'
          ;;
        completed)
          completed=$((completed + 1))
          completed_lines+="${tname}"$'\t'"${tsize}"$'\t'$'\n'
          ;;
        skipped)
          skipped=$((skipped + 1))
          skipped_lines+="${tname}"$'\t'"${tsize}"$'\t'$'\n'
          ;;
        failed)
          failed=$((failed + 1))
          failed_lines+="${tname}"$'\t'"${tsize}"$'\t'"${tdetail}"$'\n'
          ;;
      esac
    done < "$PROGRESS_TASKS_FILE"
  fi

  local msg=""
  local title
  if [ "$finalized" -eq 1 ]; then
    # 中断检测: 任务被取消/step 提前失败时，Finalize(always() 执行) 会把消息
    # 标记为最终态；若仍有 pending/running 任务却只看 failed 数，会把
    # "7 个任务全待处理" 误报成 "✅ 同步全部完成"
    if [ "$failed" -gt 0 ]; then
      title="⚠️ 同步完成（有失败）"
    elif [ $((pending + running)) -gt 0 ]; then
      title="⛔ 同步中断（${pending} 个待处理、${running} 个进行中未执行完）"
    elif [ "$total" -eq 0 ]; then
      # 一个任务都没注册就到了收尾（注册前被取消/失败），绝非"全部完成"
      title="⛔ 同步中断（未注册任何任务）"
    else
      title="✅ 同步全部完成"
    fi
  else
    title="🔄 同步进度"
  fi
  tg_add_title msg "$title"
  tg_append msg "📊 总任务：<b>${total}</b> | 待处理：${pending} | 进行中：${running} | 完成：${completed} | 跳过：${skipped} | 失败：${failed}"$'\n'

  # 进行中任务块: 任务条目（分组渲染）+ 多层级阶段树/统计信息
  #   各拆分深度槽位逐层缩进两格合并：深度 0 的树挂在任务条目下，
  #   auto-split 子层的树再缩进一层、视觉上挂在本层活动行（🔄 已置尾）下；
  # finalized（中断/收尾）时仍渲染任务条目: 标题已报 "N 个进行中未执行完"，
  # 条目却不列出的话，被打断的任务（如 wopan176Crypt/0）在消息里完全失踪;
  # 阶段/统计不展示（progress_finalize 已清空各槽位，属过期信息）
  if [ "$running" -gt 0 ]; then
    local _running_title="📍 进行中 · ${running}"
    [ "$finalized" -eq 1 ] && _running_title="⏸️ 进行中（未执行完）· ${running}"
    tg_add_section msg "$_running_title"
    tg_add_block msg "$(_progress_render_task_list "$running_lines")"

    if [ "$finalized" -ne 1 ]; then
      local _d _pad _rf _sf _raw _tree _line
      for ((_d = 0; _d < PROGRESS_MAX_DEPTH; _d++)); do
        _rf="$(_progress_slot_rows "$_d")"
        _sf="$(_progress_slot_stats "$_d")"
        [ -f "$_rf" ] || [ -f "$_sf" ] || continue
        _pad=""
        local _k
        for ((_k = 0; _k <= _d; _k++)); do _pad+="  "; done
        if [ -f "$_rf" ]; then
          _raw="$(_progress_active_last < "$_rf")"
          # tree_lines 每行自带 2 空格树干前缀（tree_conn），剥掉后
          # 由本层 pad 统一缩进，保证树与统计行同列对齐
          _tree="$(tree_lines "$_raw" | sed 's/^  //')"
          if [ -n "$_tree" ]; then
            while IFS= read -r _line; do
              [ -z "$_line" ] && continue
              msg+="${_pad}${_line}"$'\n'
            done <<< "$_tree"
          fi
        fi
        [ -f "$_sf" ] && msg+="${_pad}$(cat "$_sf")"$'\n'
      done
    fi
  fi

  if [ "$pending" -gt 0 ]; then
    tg_add_section msg "⏳ 待处理 · ${pending}"
    tg_add_block msg "$(_progress_render_task_list "$pending_lines")"
  fi

  if [ "$completed" -gt 0 ]; then
    tg_add_section msg "✅ 已完成 · ${completed}"
    tg_add_block msg "$(_progress_render_task_list "$completed_lines")"
  fi

  if [ "$skipped" -gt 0 ]; then
    tg_add_section msg "⏭️ 已跳过 · ${skipped}"
    tg_add_block msg "$(_progress_render_task_list "$skipped_lines")"
  fi

  if [ "$failed" -gt 0 ]; then
    tg_add_section msg "❌ 失败 · ${failed}"
    tg_add_block msg "$(_progress_render_task_list "$failed_lines")"
  fi

  tg_append msg $'\n'"⏱️ 已用：<b>${time_str}</b>"
  echo "$msg"
}

# 刷新进度消息（删除旧消息并重新发送，确保在聊天底部）
_progress_refresh() {
  local msg
  msg=$(_progress_render)
  local new_id
  new_id=$(_tg_ensure_bottom_message "$msg")
  # Telegram 失败（new_id 空）时返回 1 会沿 progress_update/progress_task_begin 等
  # 裸调用链在 set -e 下终止整个 step —— 通知失败不传播
  [ -n "$new_id" ] && echo "$new_id" > "$PROGRESS_MSG_ID_FILE"
  return 0
}

# 初始化进度通知系统（在第一个任务开始前调用一次）
# 任务通过 progress_task_begin 或预览阶段的 _preview_register 自动注册
progress_init() {
  # 清理旧状态
  : > "$PROGRESS_TASKS_FILE"
  : > "$PROGRESS_MSG_ID_FILE"
  : > "$PROGRESS_CURRENT_FILE"
  _progress_purge_all_slots
  rm -f "$PROGRESS_FINALIZED_FILE" 2>/dev/null || true
  date +%s > "$PROGRESS_START_FILE"

  # 不在此处发送消息: 此刻任务队列为空，只会发出 "总任务：0 | 已用：0s" 的
  # 空占位消息；若运行在任务注册前被取消（concurrency 抢占/早期失败），
  # 该消息会冻结为最终状态且每轮 runner 全新、删不掉上一轮的。首条消息
  # 由注册完成后的 progress_reload（正常/跳预览流程）或 progress_task_begin（调试
  # 流程）发出，此时任务列表已是全量。
}

# 标记任务开始（自动注册未注册的任务）
# 用法: progress_task_begin <task_id> [fallback_display_name]
#   第二参数仅在任务未注册时用作显示名（如 debug 模式无预览阶段）；
#   已注册任务（预览阶段）开始运行时不设置 detail，显示名/大小提示保持注册时的值
progress_task_begin() {
  local task_id="$1"
  local fallback_name="${2:-}"
  # 自动注册未注册的任务
  if ! grep -qP "^\Q${task_id}\E\t" "$PROGRESS_TASKS_FILE" 2>/dev/null; then
    progress_register_task "$task_id" "${fallback_name:-$task_id}"
  fi
  echo "$task_id" > "$PROGRESS_CURRENT_FILE"
  # 清空上一任务遗留的阶段槽位（run 33048121562: task0 的批次统计
  # "15 批 ❌15" 被残留显示到下一个任务的 📍 进行中 区块下）
  _progress_purge_all_slots
  _progress_set_task_status "$task_id" "running" ""
  _progress_refresh
}

# 更新器共享实现：按 SYNC_AUTO_SPLIT_DEPTH 把内容路由到对应深度槽位
# 用法: _progress_task_apply <detail> [rows_raw] [stats_html] <bypass_throttle>
#   rows_raw — 本层阶段树的原始行（多行，无连接符），空则不动本层树
#   深度路由规则（替代旧的 PROGRESS_SUPPRESS 单槽互斥模型）:
#   - 任务行 detail 只接受深度 0（注册任务本层）的更新——深层子任务的
#     过程信息不上提到任务行，由各层自己的阶段树/统计行表达;
#   - rows/stats 写入 SYNC_AUTO_SPLIT_DEPTH 对应槽位，父子天然隔离,
#     渲染时逐层合并展示（Tasks.sh 递归前后已维护好深度变量）;
#   - 兼容兜底: 外部仍设 PROGRESS_SUPPRESS=1 时静默丢弃（旧行为）。
#   节流: 2 秒内不重复刷新消息；bypass=1（force）且深度 0 才豁免——
#   深层文件批次的高频 force 若不加限流会造成 Telegram 消息风暴。
_progress_task_apply() {
  local detail="${1:-}"
  local rows="${2:-}"
  local stats="${3:-}"
  local bypass_throttle="${4:-0}"
  local current
  current=$(_progress_get_current_task)
  [ -z "$current" ] && return

  local _d="${SYNC_AUTO_SPLIT_DEPTH:-0}"
  [[ "$_d" =~ ^[0-9]+$ ]] || _d=0

  if [ "$_d" -eq 0 ]; then
    _progress_set_task_status "$current" "running" "$detail"
  fi
  [ -n "$rows" ] && printf '%s\n' "$rows" > "$(_progress_slot_rows "$_d")"
  [ -n "$stats" ] && echo "$stats" > "$(_progress_slot_stats "$_d")"

  local now last=0
  now=$(date +%s)
  [ -f "$PROGRESS_LAST_UPDATE_FILE" ] && last=$(cat "$PROGRESS_LAST_UPDATE_FILE" 2>/dev/null || echo 0)
  if [ "$bypass_throttle" = "1" ] && [ "$_d" -eq 0 ]; then
    echo "$now" > "$PROGRESS_LAST_UPDATE_FILE"
    _progress_refresh
    return 0
  fi
  [ $((now - last)) -lt 2 ] && return 0
  echo "$now" > "$PROGRESS_LAST_UPDATE_FILE"
  _progress_refresh
}

# 更新当前任务的详细信息和阶段/统计（带 2 秒节流）
# 用法: progress_task_update <detail> [rows_raw] [stats_html]
progress_task_update() {
  [ "${PROGRESS_SUPPRESS:-0}" = "1" ] && return 0
  _progress_task_apply "${1:-}" "${2:-}" "${3:-}" 0
}

# 强制更新（顶层忽略节流，深层仍限流防消息风暴）
# 用法: progress_task_update_force <detail> [rows_raw] [stats_html]
progress_task_update_force() {
  [ "${PROGRESS_SUPPRESS:-0}" = "1" ] && return 0
  _progress_task_apply "${1:-}" "${2:-}" "${3:-}" 1
}

# 手动刷新进度消息（无节流）
# 用法: progress_reload — 任务队列注册完成后调用，让"总任务"在首个任务开始前就是全量
progress_reload() {
  _progress_refresh
}

# 标记任务完成
# 用法: progress_task_done <status: completed|skipped|failed> [detail]
progress_task_done() {
  local status="$1"
  local detail="${2:-}"
  local current
  current=$(_progress_get_current_task)
  [ -z "$current" ] && return

  case "$status" in
    completed|skipped|failed) ;;
    *) status="completed" ;;
  esac

  _progress_set_task_status "$current" "$status" "$detail"
  : > "$PROGRESS_CURRENT_FILE"
  _progress_refresh
}

# 最终完成所有任务（在最后调用）
progress_finalize() {
  echo "1" > "$PROGRESS_FINALIZED_FILE"
  : > "$PROGRESS_CURRENT_FILE"
  _progress_purge_all_slots
  _progress_refresh
}

# ===== 阶段信息入口（task_engine.sh 高频使用）=====
# 调用方把阶段树写入 PROGRESS_PHASE_INFO、统计写入 PROGRESS_STATS 全局变量，
# 本入口将其转发给 progress_task_update/progress_task_update_force 并把变量转换为树行/统计参数。
progress_update() {
  local detail="$1"
  local stats="${2:-}"
  # 如果调用方传了 stats 参数，使用它；否则用全局变量
  [ -z "$stats" ] && [ -n "${PROGRESS_STATS:-}" ] && stats="$PROGRESS_STATS"
  local phase="${PROGRESS_PHASE_INFO:-}"
  progress_task_update "$detail" "$phase" "$stats"
}
progress_update_force() {
  local detail="$1"
  local stats="${2:-}"
  [ -z "$stats" ] && [ -n "${PROGRESS_STATS:-}" ] && stats="$PROGRESS_STATS"
  local phase="${PROGRESS_PHASE_INFO:-}"
  progress_task_update_force "$detail" "$phase" "$stats"
}
