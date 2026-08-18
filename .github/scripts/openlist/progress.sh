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
#   PROGRESS_PHASE_FILE      — 当前阶段信息（HTML 片段）
#   PROGRESS_STATS_FILE      — 当前统计信息（HTML 片段）
#   PROGRESS_FINALIZED_FILE  — 最终完成标记
#
# 依赖: telegram.sh (send/edit/delete), utils.sh (escape_html)

# 状态文件路径定义
PROGRESS_MSG_ID_FILE="/tmp/progress_msg_id.txt"
PROGRESS_TASKS_FILE="/tmp/progress_tasks.tsv"
PROGRESS_CURRENT_FILE="/tmp/progress_current.txt"
PROGRESS_START_FILE="/tmp/progress_start.txt"
PROGRESS_PHASE_FILE="/tmp/progress_phase.txt"
PROGRESS_STATS_FILE="/tmp/progress_stats.txt"
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

# 从任务队列中按 task_id 查找
# 输出: 匹配的 TSV 行（task_id, display_name, status, detail）
_progress_get_task_row() {
  local task_id="$1"
  [ -f "$PROGRESS_TASKS_FILE" ] || return
  grep -P "^\Q${task_id}\E\t" "$PROGRESS_TASKS_FILE" 2>/dev/null | head -1
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

# 获取当前阶段信息（HTML 片段）
_progress_get_phase() {
  [ -f "$PROGRESS_PHASE_FILE" ] && cat "$PROGRESS_PHASE_FILE" 2>/dev/null || echo ""
}

# 获取当前统计信息（HTML 片段）
_progress_get_stats() {
  [ -f "$PROGRESS_STATS_FILE" ] && cat "$PROGRESS_STATS_FILE" 2>/dev/null || echo ""
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

  # 统计各状态任务数
  # 列表项统一语法: "• 名称 — <i>备注</i>"（进行中为动态详情，其余为源端大小）
  local total=0 pending=0 running=0 completed=0 skipped=0 failed=0
  local pending_list="" running_list="" completed_list="" skipped_list="" failed_list=""

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
          pending_list+="• $(escape_html "$tname")"
          [ -n "$tsize" ] && pending_list+=" — <i>${tsize}</i>"
          pending_list+=$'\n'
          ;;
        running)
          running=$((running + 1))
          running_list+="• $(escape_html "$tname")"
          [ -n "$tdetail" ] && running_list+=" — <i>$(escape_html "$tdetail")</i>"
          running_list+=$'\n'
          ;;
        completed)
          completed=$((completed + 1))
          completed_list+="• $(escape_html "$tname")"
          [ -n "$tsize" ] && completed_list+=" — <i>${tsize}</i>"
          completed_list+=$'\n'
          ;;
        skipped)
          skipped=$((skipped + 1))
          skipped_list+="• $(escape_html "$tname")"
          [ -n "$tsize" ] && skipped_list+=" — <i>${tsize}</i>"
          skipped_list+=$'\n'
          ;;
        failed)
          failed=$((failed + 1))
          failed_list+="• $(escape_html "$tname")"
          [ -n "$tsize" ] && failed_list+=" — <i>${tsize}</i>"
          failed_list+=$'\n'
          ;;
      esac
    done < "$PROGRESS_TASKS_FILE"
  fi

  local msg=""
  if [ "$finalized" -eq 1 ]; then
    if [ "$failed" -gt 0 ]; then
      msg+="⚠️ <b>同步完成（有失败）</b>"$'\n'
    else
      msg+="✅ <b>同步全部完成</b>"$'\n'
    fi
  else
    msg+="🔄 <b>同步进度</b>"$'\n'
  fi
  msg+="━━━━━━━━━━━━━━━━━━"$'\n'
  msg+="📊 总任务：<b>${total}</b> | 待处理：${pending} | 进行中：${running} | 完成：${completed} | 跳过：${skipped} | 失败：${failed}"$'\n'

  # 进行中任务块: 任务行 + 缩进两格的阶段/统计信息
  #   阶段首行（▸ 摘要）→ 统计行（▸ 📊 ...）→ 阶段剩余行（├─/└─ 树形子项）
  if [ "$finalized" -ne 1 ] && [ "$running" -gt 0 ]; then
    msg+=$'\n'"📍 <b>进行中</b>"$'\n'"${running_list}"

    local phase phase_first="" phase_rest=""
    phase=$(_progress_get_phase)
    if [ -n "$phase" ]; then
      phase_first="$(printf '%s\n' "$phase" | head -1)"
      phase_rest="$(printf '%s\n' "$phase" | tail -n +2)"
      msg+="  ${phase_first}"$'\n'
    fi

    local stats
    stats=$(_progress_get_stats)
    [ -n "$stats" ] && msg+="  ${stats}"$'\n'

    if [ -n "$phase_rest" ]; then
      local pline
      while IFS= read -r pline; do
        [ -z "$pline" ] && continue
        msg+="  ${pline}"$'\n'
      done <<< "$phase_rest"
    fi
  fi

  if [ "$pending" -gt 0 ]; then
    msg+=$'\n'"⏳ <b>待处理 · ${pending}</b>"$'\n'"${pending_list}"
  fi

  if [ "$completed" -gt 0 ]; then
    msg+=$'\n'"✅ <b>已完成 · ${completed}</b>"$'\n'"${completed_list}"
  fi

  if [ "$skipped" -gt 0 ]; then
    msg+=$'\n'"⏭️ <b>已跳过 · ${skipped}</b>"$'\n'"${skipped_list}"
  fi

  if [ "$failed" -gt 0 ]; then
    msg+=$'\n'"❌ <b>失败 · ${failed}</b>"$'\n'"${failed_list}"
  fi

  msg+=$'\n'"⏱️ 已用：<b>${time_str}</b>"
  echo "$msg"
}

# 刷新进度消息（删除旧消息并重新发送，确保在聊天底部）
_progress_refresh() {
  local msg
  msg=$(_progress_render)
  local new_id
  new_id=$(_tg_ensure_bottom_message "$msg")
  [ -n "$new_id" ] && echo "$new_id" > "$PROGRESS_MSG_ID_FILE"
}

# 初始化进度通知系统（在第一个任务开始前调用一次）
# 任务通过 task_begin 或预览阶段的 _preview_register 自动注册
progress_init() {
  # 清理旧状态
  : > "$PROGRESS_TASKS_FILE"
  : > "$PROGRESS_MSG_ID_FILE"
  : > "$PROGRESS_CURRENT_FILE"
  : > "$PROGRESS_PHASE_FILE"
  : > "$PROGRESS_STATS_FILE"
  rm -f "$PROGRESS_FINALIZED_FILE" 2>/dev/null || true
  date +%s > "$PROGRESS_START_FILE"

  _progress_refresh
}

# 标记任务开始（自动注册未注册的任务）
# 用法: task_begin <task_id> [fallback_display_name]
#   第二参数仅在任务未注册时用作显示名（如 debug 模式无预览阶段）；
#   已注册任务（预览阶段）开始运行时不设置 detail，显示名/大小提示保持注册时的值
task_begin() {
  local task_id="$1"
  local fallback_name="${2:-}"
  # 自动注册未注册的任务
  if ! grep -qP "^\Q${task_id}\E\t" "$PROGRESS_TASKS_FILE" 2>/dev/null; then
    progress_register_task "$task_id" "${fallback_name:-$task_id}"
  fi
  echo "$task_id" > "$PROGRESS_CURRENT_FILE"
  _progress_set_task_status "$task_id" "running" ""
  _progress_refresh
}

# 更新当前任务的详细信息和阶段/统计（带 2 秒节流）
# 用法: task_update <detail> [phase_html] [stats_html]
# PROGRESS_SUPPRESS=1 时静默返回: 子任务执行期间不覆盖父任务的
# phase/stats/detail（父任务树中的当前子目录由父循环标记 🔄）
task_update() {
  [ "${PROGRESS_SUPPRESS:-0}" = "1" ] && return 0
  local detail="$1"
  local phase="${2:-}"
  local stats="${3:-}"
  local current
  current=$(_progress_get_current_task)
  [ -z "$current" ] && return

  _progress_set_task_status "$current" "running" "$detail"
  [ -n "$phase" ] && echo "$phase" > "$PROGRESS_PHASE_FILE"
  [ -n "$stats" ] && echo "$stats" > "$PROGRESS_STATS_FILE"

  # 简单节流：2 秒内不重复刷新
  local now last=0
  now=$(date +%s)
  [ -f "$PROGRESS_LAST_UPDATE_FILE" ] && last=$(cat "$PROGRESS_LAST_UPDATE_FILE" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt 2 ]; then
    return 0
  fi
  echo "$now" > "$PROGRESS_LAST_UPDATE_FILE"
  _progress_refresh
}

# 强制更新（忽略节流）
# 用法: task_update_force <detail> [phase_html] [stats_html]
task_update_force() {
  [ "${PROGRESS_SUPPRESS:-0}" = "1" ] && return 0
  local detail="$1"
  local phase="${2:-}"
  local stats="${3:-}"
  local current
  current=$(_progress_get_current_task)
  [ -z "$current" ] && return

  _progress_set_task_status "$current" "running" "$detail"
  [ -n "$phase" ] && echo "$phase" > "$PROGRESS_PHASE_FILE"
  [ -n "$stats" ] && echo "$stats" > "$PROGRESS_STATS_FILE"
  date +%s > "$PROGRESS_LAST_UPDATE_FILE"
  _progress_refresh
}

# 设置阶段信息（子目录/批次信息）
# 用法: progress_set_phase <phase_html>
progress_set_phase() {
  echo "$1" > "$PROGRESS_PHASE_FILE"
  _progress_refresh
}

# 设置统计信息
# 用法: progress_set_stats <stats_html>
progress_set_stats() {
  echo "$1" > "$PROGRESS_STATS_FILE"
  _progress_refresh
}

# 手动刷新进度消息（无节流）
# 用法: 任务队列注册完成后调用，让"总任务"在首个任务开始前就是全量
progress_reload() {
  _progress_refresh
}

# 标记任务完成
# 用法: task_done <status: completed|skipped|failed> [detail]
task_done() {
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
  : > "$PROGRESS_PHASE_FILE"
  : > "$PROGRESS_STATS_FILE"
  _progress_refresh
}

# ===== 兼容层 =====
# 旧代码直接修改 PROGRESS_PHASE_INFO 和 PROGRESS_STATS 全局变量，
# 兼容层自动读取这些变量并通过新 API 更新。
# 这些函数保留为 no-op，避免旧调用报错。
progress_start() { :; }
progress_set_detail() { :; }
progress_update() {
  local detail="$1"
  local stats="${2:-}"
  # 如果调用方传了 stats 参数，使用它；否则用全局变量
  [ -z "$stats" ] && [ -n "${PROGRESS_STATS:-}" ] && stats="$PROGRESS_STATS"
  local phase="${PROGRESS_PHASE_INFO:-}"
  task_update "$detail" "$phase" "$stats"
}
progress_update_force() {
  local detail="$1"
  local stats="${2:-}"
  [ -z "$stats" ] && [ -n "${PROGRESS_STATS:-}" ] && stats="$PROGRESS_STATS"
  local phase="${PROGRESS_PHASE_INFO:-}"
  task_update_force "$detail" "$phase" "$stats"
}
progress_finish() { :; }
_progress_add_completed() { :; }
_progress_add_skipped() { :; }
_progress_remove_completed() { :; }
_progress_remove_skipped() { :; }
