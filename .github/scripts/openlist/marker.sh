#!/bin/bash
# ===== OpenList 同步工具 — 同步标记系统 =====
# 通过在 OneDrive 上保存 JSON 标记文件来跟踪每个 task 的同步状态。
# 功能:
#   - 跳过短期内已成功同步的 task（默认 24 小时）
#   - 检测源端大小异常减小（可能数据丢失），发送警告并跳过
#
# 标记存储路径: onedrive:/logs/sync_state/<task_name>_<dest_hash>.json
# JSON 字段: last_success, source_path, dest_path, source_bytes, source_count, top_dirs
#
# 依赖: utils.sh (escape_html, format_bytes), telegram.sh (send_telegram_message)
# 依赖环境变量: FORCE_SYNC — 为 "true" 时跳过所有标记检查

# 标记存储目录
SYNC_STATE_DIR="onedrive:/logs/sync_state"
# 默认跳过时间窗口（24 小时，可被 SYNC_SKIP_SECONDS 覆盖）
SYNC_SKIP_SECONDS=$((24 * 60 * 60))

# 生成标记文件路径（每个 task+dest 组合唯一）
# 用法: get_marker_path <task_name> <dest_path>
get_marker_path() {
  local task_name="$1"
  local dest_path="$2"
  local dest_hash
  dest_hash=$(echo -n "${task_name}_${dest_path}" | md5sum | cut -c1-8)
  echo "${SYNC_STATE_DIR}/${task_name}_${dest_hash}.json"
}

# 保存同步标记（同步成功后调用）
# 记录: 时间戳、源端路径、目标路径、源端大小/文件数、顶层目录列表、已修复文件列表
# 已修复文件列表 (fixed_files): 通过 405/409 修复机制以非原名上传的文件
#   预览时从差异中扣减这部分，避免显示"虚假缺失"
# 用法: save_sync_marker <source_path> <dest_path> <task_name>
save_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 获取源端大小和文件数
  local size_json source_bytes source_count
  size_json=$(rclone size "$source_path" --json 2>/dev/null || true)
  source_bytes=$(echo "$size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  source_count=$(echo "$size_json" | jq -r '.count // 0' 2>/dev/null || echo 0)

  # 获取顶层目录列表（用于检测目录变化）
  local top_dirs
  top_dirs=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||' | sort)

  # 读取本任务（含 auto-split 子目录）累计的修复文件列表
  # sync_with_logging 每次执行后会把 fix_list 累计到 GLOBAL_FIXED_FILES_JSON
  local fixed_files_json="${GLOBAL_FIXED_FILES_JSON:-[]}"
  local fixed_count fixed_bytes
  fixed_count=$(echo "$fixed_files_json" | jq 'length' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$fixed_files_json" | jq '[.[].size_bytes] | add // 0' 2>/dev/null || echo 0)

  # 构建 JSON 标记
  local marker_json
  marker_json=$(jq -n \
    --arg last_success "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_path "$source_path" \
    --arg dest_path "$dest_path" \
    --argjson source_bytes "$source_bytes" \
    --argjson source_count "$source_count" \
    --arg top_dirs "$top_dirs" \
    --argjson fixed_files "$fixed_files_json" \
    --argjson fixed_count "$fixed_count" \
    --argjson fixed_bytes "$fixed_bytes" \
    '{last_success: $last_success, source_path: $source_path, dest_path: $dest_path, source_bytes: $source_bytes, source_count: $source_count, top_dirs: $top_dirs, fixed_files: $fixed_files, fixed_count: $fixed_count, fixed_bytes: $fixed_bytes}')

  # 上传标记到 OneDrive
  rclone mkdir "$SYNC_STATE_DIR" >/dev/null 2>&1 || true
  echo "$marker_json" | rclone rcat "$marker_path" 2>/dev/null
  echo "已保存同步标记: $marker_path (源端 $(format_bytes "$source_bytes"), $source_count 文件, $fixed_count 个修复文件)"
}

# 检查同步标记（同步前调用）
# 设置全局变量:
#   MARKER_ACTION        — "skip" | "warning" | "proceed"
#   MARKER_JSON          — 标记 JSON 原文
#   MARKER_CURRENT_BYTES — 当前源端字节数
#   MARKER_CURRENT_COUNT — 当前源端文件数
#   MARKER_CURRENT_DIRS  — 当前源端顶层目录列表
#   MARKER_LAST_SUCCESS  — 上次成功时间（ISO 8601）
#   MARKER_SINCE_HOURS   — 距上次同步的小时数
#   MARKER_FIXED_COUNT   — 已修复文件数（以非原名存在于目标端）
#   MARKER_FIXED_BYTES   — 已修复文件总字节数
#   MARKER_FIXED_FILES   — 已修复文件列表 JSON
# 用法: check_sync_marker <source_path> <dest_path> <task_name>
check_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  MARKER_ACTION="proceed"
  MARKER_JSON=""
  MARKER_CURRENT_BYTES=0
  MARKER_CURRENT_COUNT=0
  MARKER_CURRENT_DIRS=""
  MARKER_LAST_SUCCESS=""
  MARKER_SINCE_HOURS=0
  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"

  # 强制同步跳过所有检查
  if [ "$FORCE_SYNC" = "true" ]; then
    echo "强制同步模式，跳过标记检查"
    return 0
  fi

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 下载标记
  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  if [ -z "$marker_json" ]; then
    echo "无同步标记，继续同步"
    return 0
  fi

  MARKER_JSON="$marker_json"

  # 解析已修复文件信息（用于预览扣减和跳过通知）
  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

  # 解析上次成功时间
  local last_success
  last_success=$(echo "$marker_json" | jq -r '.last_success // ""')

  if [ -z "$last_success" ]; then
    echo "标记无时间戳，继续同步"
    return 0
  fi

  # 检查是否在跳过时间窗口内
  local now_epoch last_epoch diff
  now_epoch=$(date +%s)
  last_epoch=$(date -d "$last_success" +%s 2>/dev/null || echo 0)

  if [ "$last_epoch" -gt 0 ]; then
    diff=$((now_epoch - last_epoch))
    if [ "$diff" -lt "$SYNC_SKIP_SECONDS" ]; then
      echo "$((SYNC_SKIP_SECONDS / 3600))小时内已成功同步（距今 $((diff / 3600)) 小时），跳过"
      MARKER_ACTION="skip"
      MARKER_LAST_SUCCESS="$last_success"
      MARKER_SINCE_HOURS=$((diff / 3600))
      return 0
    fi
  fi

  # 检查源端大小是否减小（可能数据丢失）
  local marker_bytes
  marker_bytes=$(echo "$marker_json" | jq -r '.source_bytes // 0')

  local current_size_json
  current_size_json=$(rclone size "$source_path" --json 2>/dev/null || true)
  MARKER_CURRENT_BYTES=$(echo "$current_size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  MARKER_CURRENT_COUNT=$(echo "$current_size_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  MARKER_CURRENT_DIRS=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||' | sort)

  if [ "$MARKER_CURRENT_BYTES" -lt "$marker_bytes" ]; then
    echo "⚠️ 源端大小减小: $(format_bytes "$marker_bytes") → $(format_bytes "$MARKER_CURRENT_BYTES")"
    MARKER_ACTION="warning"
    return 0
  fi

  echo "标记检查通过，继续同步"
  MARKER_ACTION="proceed"
  return 0
}

# 仅加载 marker 的 fixed_files 信息（不做跳过判断，供预览使用）
# 设置全局变量: MARKER_FIXED_COUNT, MARKER_FIXED_BYTES, MARKER_FIXED_FILES
# 用法: _load_marker_fixed_files <source_path> <dest_path> <task_name>
_load_marker_fixed_files() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  [ -z "$marker_json" ] && return 0

  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")
}

# 发送源端大小减小的警告通知（同时跳过本次同步）
# 依赖全局变量: MARKER_JSON, MARKER_CURRENT_BYTES, MARKER_CURRENT_COUNT, MARKER_CURRENT_DIRS
# 用法: send_sync_warning <task_name> <source_path> <dest_path>
send_sync_warning() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count marker_dirs
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0')
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0')
  marker_dirs=$(echo "$MARKER_JSON" | jq -r '.top_dirs // ""')

  local diff_bytes=$((marker_bytes - MARKER_CURRENT_BYTES))
  local diff_count=$((marker_count - MARKER_CURRENT_COUNT))
  local pct=0
  if [ "$marker_bytes" -gt 0 ]; then
    pct=$((diff_bytes * 100 / marker_bytes))
  fi

  # 找出缺失和新增的目录
  local missing_dirs="" new_dirs=""
  if [ -n "$marker_dirs" ] && [ -n "$MARKER_CURRENT_DIRS" ]; then
    missing_dirs=$(comm -23 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
    new_dirs=$(comm -13 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
  fi

  # HTML 转义动态内容
  local e_task e_source e_dest
  e_task=$(escape_html "$task_name")
  e_source=$(escape_html "$source_path")
  e_dest=$(escape_html "$dest_path")

  local msg=""
  msg+="🚨🚨🚨 <b>源端大小异常减小</b> 🚨🚨🚨"$'\n'
  msg+="━━━━━━━━━━━━━━━━━━"$'\n'
  msg+="任务：<b>${e_task}</b>"$'\n'
  msg+="源端：<code>${e_source}</code>"$'\n'
  msg+="目标：<code>${e_dest}</code>"$'\n'
  msg+=$'\n'"📊 <b>大小对比</b>"$'\n'
  msg+="• 上次记录：<b>$(format_bytes "$marker_bytes")</b> (${marker_count} 文件)"$'\n'
  msg+="• 当前大小：<b>$(format_bytes "$MARKER_CURRENT_BYTES")</b> (${MARKER_CURRENT_COUNT} 文件)"$'\n'
  msg+="• 减少：<b>$(format_bytes "$diff_bytes")</b> (-${pct}%)"$'\n'
  if [ "$diff_count" -ne 0 ]; then
    msg+="• 文件减少：<b>${diff_count}</b> 个"$'\n'
  fi

  if [ -n "$missing_dirs" ]; then
    msg+=$'\n'"📁 <b>缺失的目录（可能被删除）</b>"$'\n'
    while IFS= read -r d; do
      [ -n "$d" ] && msg+="• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$missing_dirs"
  fi

  if [ -n "$new_dirs" ]; then
    msg+=$'\n'"📁 <b>新增的目录</b>"$'\n'
    while IFS= read -r d; do
      [ -n "$d" ] && msg+="• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$new_dirs"
  fi

  msg+=$'\n'"⏸️ <b>已跳过此同步，继续执行其他任务</b>"$'\n'
  msg+="如确认无误，请手动触发 force_sync=true"

  send_telegram_message "$msg" "HTML"
}

# 发送"近期已成功同步，本次跳过"的通知
# 依赖全局变量: MARKER_LAST_SUCCESS, MARKER_SINCE_HOURS, MARKER_JSON
# 用法: send_sync_skipped <task_name> <source_path> <dest_path>
send_sync_skipped() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0' 2>/dev/null || echo 0)
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0' 2>/dev/null || echo 0)

  # 已修复文件信息（通过 405/409 修复机制以非原名上传的文件）
  local fixed_count fixed_bytes
  fixed_count=$(echo "$MARKER_JSON" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$MARKER_JSON" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)

  # HTML 转义动态内容
  local e_task e_source e_dest e_last
  e_task=$(escape_html "$task_name")
  e_source=$(escape_html "$source_path")
  e_dest=$(escape_html "$dest_path")
  e_last=$(escape_html "$MARKER_LAST_SUCCESS")

  local msg=""
  msg+="⏭️ <b>同步任务跳过（1 天内已成功）</b>"$'\n'
  msg+="━━━━━━━━━━━━━━━━━━"$'\n'
  msg+="任务：<b>${e_task}</b>"$'\n'
  msg+="源端：<code>${e_source}</code>"$'\n'
  msg+="目标：<code>${e_dest}</code>"$'\n'
  msg+=$'\n'"🕒 <b>上次同步</b>"$'\n'
  msg+="• 时间：<code>${e_last}</code>"$'\n'
  msg+="• 距今：<b>${MARKER_SINCE_HOURS}</b> 小时"$'\n'
  msg+="• 记录大小：$(format_bytes "$marker_bytes") (${marker_count} 文件)"$'\n'
  if [ "${fixed_count:-0}" -gt 0 ]; then
    msg+="• 已修复文件：<b>${fixed_count}</b> 个 ($(format_bytes "$fixed_bytes"))，以非原名存在于目标端"$'\n'
    # 修复方式汇总（按 restore.kind 分组统计）
    local method_summary
    method_summary=$(echo "$MARKER_JSON" | jq -r '
      (.fixed_files // []) | group_by(.restore.kind // "unknown")
        | map({kind: .[0].restore.kind // "unknown",
               summary: .[0].restore.summary // "",
               count: length,
               bytes: ([.[].size_bytes] | add // 0)})
        | sort_by(-.bytes)
        | map("    · " + .kind + " (" + (.count|tostring) + " 个/"
            + (.bytes | tostring | if tonumber>0 then tonumber|tostring else "0" end) + "B) "
            + .summary)
        | join("\n")
    ' 2>/dev/null || echo "")
    [ -n "$method_summary" ] && msg+=$'\n'"🔧 <b>修复方式构成</b>"$'\n'"${method_summary}"$'\n'
    msg+="🔗 完整还原脚本保存在 OneDrive marker: <code>$(get_marker_path "$task_name" "$dest_path")</code> 的 fixed_files[].restore.script 字段"$'\n'
  fi
  msg+=$'\n'"⏸️ <b>本次跳过同步，继续执行其他任务</b>"$'\n'
  msg+="如需强制同步，请手动触发 force_sync=true"

  send_telegram_message "$msg" "HTML"
}
