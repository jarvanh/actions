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
#   PROGRESS_ROWS_FILE.N     — 拆分深度 N 的阶段行（原始行，连接符由渲染器加）
#   PROGRESS_STATS_FILE.N    — 拆分深度 N 的统计信息（HTML 片段）
#   PROGRESS_NOTE_FILE.N     — 拆分深度 N 的细粒度状态（深层 detail，见下）
#   PROGRESS_FIXED_FILE      — 本轮经替代方式（修复管线）同步的文件数累计
#   （多层槽位: auto-split 递归时每层写入自己的深度槽位，渲染时逐层缩进
#   合并展示；行内容含 HTML 已由生产方 escape，此处透传）
#   PROGRESS_FINALIZED_FILE  — 最终完成标记
#
# 每层的三种行在消息里的层级关系（缩进每层下沉 5 格 = 连接符 2 + "├─ " 3，
# 保证下一层表头正好对齐本层树行文本列、视觉上挂在本层 🔄 活动行之下）:
#   📁 <b>onedrive:0</b> · <i>280.790 GiB</i>      任务条目（按源端分组）
#     └─ wopan176Crypt/0                            目标端
#        ▸ 📊 子目录：2/3 完成 | ✅1 ⏭️1 ⏳1         本层统计行（树型块的表头）
#          ├─ ⏭️ archive · <i>477.281 MiB</i>       本层阶段树（🔄 行已置尾）
#          └─ 🔄 j-1024j-视频-pornhub-favorites
#             ▸ 📦 文件批次拆分：15 批 / 1367 文件   下一层标签行（表头，无连接符）
#             ▸ 📊 批次：1/15 | ✅0 ❌0              下一层统计行
#               └─ 批次 1 巩固: 重启容器校验落盘真值   下一层细粒度状态（detail）
# 阶段行两种形态由渲染器按内容判定（生产方无需区分）:
#   标签型 全部行以 "▸" 开头 → 说明"本层在做什么"，与统计行同列、排在统计行之前
#   树型   其余（子目录等状态条目）→ 统计行是它的表头，排在其后并缩进 2 格
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
_progress_slot_note() { printf '/tmp/progress_note.%d' "$1"; }
PROGRESS_FINALIZED_FILE="/tmp/progress_finalized.txt"
# 本轮经替代方式（修复管线）同步的文件数（收尾标题区分"带修复的完成"）
PROGRESS_FIXED_FILE="/tmp/progress_fixed_count.txt"
# 节流时间戳文件（避免频繁刷新 Telegram 消息）
PROGRESS_LAST_UPDATE_FILE="/tmp/progress_last_update.txt"
# 批次历史记录文件（最近 N 个已完成批次的快照，供进度消息回显既往批次结果）
# 格式: "<批次号>|<展示文本>"，同批次号覆盖旧条目；展示文本由 task_engine 生成
PROGRESS_BATCH_HISTORY_FILE="/tmp/progress_batch_history.txt"
PROGRESS_BATCH_HISTORY_MAX=6
# 批次实时刷新线程（分钟级）: 间隔与 pid 文件
PROGRESS_RT_INTERVAL="${PROGRESS_RT_INTERVAL:-60}"
PROGRESS_RT_PID_FILE="/tmp/progress_rt_pid.txt"

# 追加一条批次历史（同批次号覆盖，只保留最近 PROGRESS_BATCH_HISTORY_MAX 条）
# 用法: _progress_batch_history_add <批次号> <展示文本>
_progress_batch_history_add() {
  local bnum="$1" entry="$2"
  [[ "$bnum" =~ ^[0-9]+$ ]] || return 0
  [ -n "$entry" ] || return 0
  local tmp
  tmp=$(mktemp)
  [ -f "$PROGRESS_BATCH_HISTORY_FILE" ] && grep -v "^${bnum}|" "$PROGRESS_BATCH_HISTORY_FILE" > "$tmp" || true
  echo "${bnum}|${entry}" >> "$tmp"
  tail -n "$PROGRESS_BATCH_HISTORY_MAX" "$tmp" > "$PROGRESS_BATCH_HISTORY_FILE"
  rm -f "$tmp"
}

# 清空批次历史（新任务/新文件批次阶段开始时调用）
_progress_batch_history_clear() {
  rm -f "$PROGRESS_BATCH_HISTORY_FILE" 2>/dev/null || true
}

# 渲染批次历史为树行（无连接符，由调用方 tree_lines 加）；按批次号升序展示
_progress_batch_history_render() {
  [ -f "$PROGRESS_BATCH_HISTORY_FILE" ] || return 0
  local _sorted _out="" _l
  _sorted=$(sort -t'|' -k1,1n "$PROGRESS_BATCH_HISTORY_FILE" 2>/dev/null)
  while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    _out+="${_l#*|}"$'\n'
  done <<< "$_sorted"
  printf '%s' "$_out"
}

# ===== 批次传输实时刷新线程（分钟级进度）=====
# 背景: 批次内 rclone copy 阻塞主线程数分钟～数十分钟，期间无 progress_update
# 调用，进度消息冻结在批次开始时刻。本线程按固定间隔（默认 60s）tail 批次
# 日志，提取 rclone --progress 的 Transferred 行，刷新为“传输中”实时状态。
# 生命周期: _start_batch_progress_thread 在每批 copy 前启动；
#           _stop_batch_progress_thread 在 copy 后（含失败/中止路径）停止。
# 安全性: 线程是独立子进程，只读写 /tmp 状态文件与 Telegram API；
#         主线程在 copy 期间阻塞，无并发写冲突；kill 停止。
_start_batch_progress_thread() {
  _stop_batch_progress_thread
  local log_file="$1"
  [ -n "$log_file" ] || return 0
  touch "$log_file" 2>/dev/null || return 0
  (
    while :; do
      sleep "$PROGRESS_RT_INTERVAL"
      [ -f "$log_file" ] || continue
      # rclone --progress 用 \r 刷新单行统计，先归一为行再取最后一个带 ETA 的 Transferred 行
      # 注意: 此处是子壳非函数上下文，不能用 local
      _xfer=$(tr '\r' '\n' < "$log_file" | grep -a 'Transferred:' | grep -a 'ETA' | tail -1 | sed -E 's/^.*Transferred:[[:space:]]*//')
      [ -z "$_xfer" ] && continue
      progress_update "传输中: ${_xfer}" "▸ 📊 批次：${batch_idx:-?}/${total_batches:-?} | ✅${synced_batches:-0} ❌${failed_batches:-0} · 📄 ${batch_total_files:-?}/${total_files:-?} 文件 · ⏱ ${_xfer}"
    done
  ) &
  echo $! > "$PROGRESS_RT_PID_FILE"
}

_stop_batch_progress_thread() {
  if [ -f "$PROGRESS_RT_PID_FILE" ]; then
    local _pid
    _pid=$(head -1 "$PROGRESS_RT_PID_FILE" 2>/dev/null)
    if [ -n "$_pid" ]; then
      kill "$_pid" 2>/dev/null || true
      pkill -P "$_pid" 2>/dev/null || true
      wait "$_pid" 2>/dev/null || true
    fi
    rm -f "$PROGRESS_RT_PID_FILE"
  fi
}

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

# 累计本轮经替代方式（修复管线）同步的文件数
# 用法: progress_add_fixed_files <n>
# 上报方是 sync_notify.sh（每个同步轮次报一次 fix_list 条数，auto-split
# 子任务各自上报）；落文件而非全局变量: 任务执行与 progress_finalize
# 分属不同 Actions step（各自独立 shell），内存变量传不过去。
progress_add_fixed_files() {
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  [ "$n" -eq 0 ] && return 0
  local cur
  cur=$(_progress_get_fixed_files)
  echo $((cur + n)) > "$PROGRESS_FIXED_FILE"
}

# 读取本轮经替代方式同步的文件数（无记录/内容非法一律 0）
_progress_get_fixed_files() {
  local cur=0
  [ -f "$PROGRESS_FIXED_FILE" ] && cur=$(head -1 "$PROGRESS_FIXED_FILE" 2>/dev/null || echo 0)
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
  echo "$cur"
}

# 清空 base_depth 及更深层级的阶段槽位
# 用法: progress_scope_init <base_depth>
# auto-split 递归进入子任务时调用: 同名深度的槽位可能被上一个兄弟子树
# 留下过期内容（尤其"直接同步中"这类不写树的路径会残留旧树），进入时清空。
progress_scope_init() {
  local _d="${1:-0}"
  local d
  for ((d = _d; d < PROGRESS_MAX_DEPTH; d++)); do
    rm -f "$(_progress_slot_rows "$d")" "$(_progress_slot_stats "$d")" "$(_progress_slot_note "$d")"
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
    # 收尾标题只有 4 种终态，按严重度从高到低判定:
    #   1 ⛔ 中断          — 仍有 pending/running（撞 job 上限被取消、step 提前
    #     失败），或一个任务都没注册。它必须排在 failed 之前: 中断时伴生的失败
    #     只是"没跑完"的副产物，"13 待处理 + 1 失败"被报成"同步完成（有失败）"
    #     会让人误以为整轮跑完了。
    #   2 ⚠️ 有文件无法同步 — 全部任务都跑完，但个别文件连修复管线也没搞定
    #     （已记入 marker 修复清单/黑名单，下轮继续）。修复成功的同时仍有
    #     顽固失败时，失败优先。
    #   3 ✅ 带修复的完成  — 全部跑完、无遗留失败，但部分文件是经替代方式
    #     （改名/短哈希/分卷）落盘的，提醒可还原。
    #   4 ✅ 完全完成
    local fixed_total
    fixed_total=$(_progress_get_fixed_files)
    if [ "$total" -eq 0 ]; then
      # 一个任务都没注册就到了收尾（注册前被取消/失败），绝非"全部完成"
      title="⛔ 同步中断（未注册任何任务）"
    elif [ $((pending + running)) -gt 0 ]; then
      title="⛔ 同步中断（${pending} 个待处理、${running} 个进行中未执行完）"
      [ "$failed" -gt 0 ] && title="⛔ 同步中断（${pending} 个待处理、${running} 个进行中未执行完、${failed} 个失败）"
    elif [ "$failed" -gt 0 ]; then
      title="⚠️ 同步完成（${failed} 个任务有文件无法同步）"
    elif [ "$fixed_total" -gt 0 ]; then
      title="✅ 同步全部完成（${fixed_total} 个文件经修复同步）"
    else
      title="✅ 同步全部完成"
    fi
  else
    title="🔄 同步进度"
  fi
  tg_add_title msg "$title"
  tg_append msg "📊 总任务：<b>${total}</b> | 待处理：${pending} | 进行中：${running} | 完成：${completed} | 跳过：${skipped} | 失败：${failed}"$'\n'

  # 进行中任务块: 任务条目（分组渲染）+ 多层级阶段行/统计信息/细粒度状态
  #   各拆分深度槽位逐层下沉合并：深度 0 的块挂在任务条目下，
  #   auto-split 子层再下沉一层、视觉上挂在本层活动行（🔄 已置尾）下；
  # finalized（中断/收尾）时仍渲染任务条目: 标题已报 "N 个进行中未执行完"，
  # 条目却不列出的话，被打断的任务（如 wopan176Crypt/0）在消息里完全失踪;
  # 阶段/统计不展示（progress_finalize 已清空各槽位，属过期信息）
  if [ "$running" -gt 0 ]; then
    local _running_title="📍 进行中 · ${running}"
    [ "$finalized" -eq 1 ] && _running_title="⏸️ 进行中（未执行完）· ${running}"
    tg_add_section msg "$_running_title"
    tg_add_block msg "$(_progress_render_task_list "$running_lines")"

    if [ "$finalized" -ne 1 ]; then
      local _d _ind _ind_rows _rf _sf _nf _is_label _raw _tree _line
      for ((_d = 0; _d < PROGRESS_MAX_DEPTH; _d++)); do
        _rf="$(_progress_slot_rows "$_d")"
        _sf="$(_progress_slot_stats "$_d")"
        _nf="$(_progress_slot_note "$_d")"
        [ -f "$_rf" ] || [ -f "$_sf" ] || [ -f "$_nf" ] || continue
        # 本层表头缩进（每层下沉 5 格）+ 树行/细粒度状态再下沉 2 格
        _ind=$(printf '%*s' "$((5 * _d + 5))" '')
        _ind_rows=$(printf '%*s' "$((5 * _d + 7))" '')

        # 阶段行形态判定（决定它与统计行的先后、是否加树形连接符）:
        #   标签型（全部行以 "▸" 开头）= 本层在做什么，作表头排在统计行之前
        #   树型（子目录等状态条目）= 统计行是它的表头，排在其后并缩进 2 格
        _is_label=1
        [ -f "$_rf" ] && while IFS= read -r _line; do
          [ -z "$_line" ] && continue
          case "$_line" in
            '▸'*) ;;
            *) _is_label=0 ;;
          esac
        done < "$_rf"

        if [ "$_is_label" -eq 1 ]; then
          [ -f "$_rf" ] && while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            msg+="${_ind}${_line}"$'\n'
          done < "$_rf"
          [ -f "$_sf" ] && msg+="${_ind}$(cat "$_sf")"$'\n'
          # 批次历史回显: 最近 N 个已完成批次的快照（当前批次状态由 rows/stats 表达，不在此重复）
          # 多行块需逐行加缩进前缀，否则仅首行对齐
          local _bh
          _bh=$(_progress_batch_history_render)
          if [ -n "$_bh" ]; then
            msg+="$(tree_lines "$_bh" | sed 's/^  //' | sed "s/^/${_ind_rows}/")"$'\n'
          fi
        else
          [ -f "$_sf" ] && msg+="${_ind}$(cat "$_sf")"$'\n'
          _raw="$(_progress_active_last < "$_rf")"
          # tree_lines 每行自带 2 空格树干前缀（tree_conn），剥掉后
          # 由本层缩进统一控制，保证树与统计行同列对齐
          _tree="$(tree_lines "$_raw" | sed 's/^  //')"
          while IFS= read -r _line; do
            [ -z "$_line" ] && continue
            msg+="${_ind_rows}${_line}"$'\n'
          done <<< "$_tree"
        fi
        # 细粒度状态（深层 detail）挂在最末，对齐树行文本列
        [ -f "$_nf" ] && msg+="${_ind_rows}└─ $(cat "$_nf")"$'\n'
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
  : > "$PROGRESS_FIXED_FILE"
  _progress_purge_all_slots
  _progress_batch_history_clear
  _stop_batch_progress_thread
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
  # 清空上一任务遗留的阶段槽位与批次历史（run 33048121562: task0 的批次统计
  # "15 批 ❌15" 被残留显示到下一个任务的 📍 进行中 区块下）
  _progress_purge_all_slots
  _progress_batch_history_clear
  _stop_batch_progress_thread
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
  elif [ -n "$detail" ]; then
    # 深层（auto-split 子任务/文件批次）的 detail 无处安放: 任务行只接受深度
    # 0 的更新（见上），此处落到本层 note 槽，渲染时挂在本层统计行之下 ——
    # 否则批次阶段只有 "📊 批次 n/m" 一行，正在做什么（列出文件/传输/巩固
    # /重试/修复）全程不可见
    echo "$detail" > "$(_progress_slot_note "$_d")"
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
  _stop_batch_progress_thread
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
