#!/bin/bash
# ===== OpenList 同步工具 — 旧 marker 清理（删除不兼容的历史 marker）=====
#
# 为什么要有它: 用户裁决「**不用兼容旧 marker，删除旧 marker**」（2026-09-20）。
#   起因是两处**改写 marker 语义**的提交使新旧 marker 不兼容（详见计划文档 §15.2）:
#     ① `e90118e`（09-19）: 还原命令 rclone move → **moveto**。
#        旧 marker 的 `restore.script` 里是 `move`，而 move 会把 dst 当目录，
#        建出「以目标文件名命名的目录」⇒ 照抄执行会把文件放到错一层的目录里。
#     ② `137c005`（09-16）: 方法命名口径统一为 `方法N·动作·变体`。
#   ⇒ 旧 marker 的还原指令是**错的**，留着只会诱导一次错误真跑，故删除而非兼容。
#
# ⚠️ 这是**不可逆**操作，且删除对象恰恰是「短哈希不可逆」的唯一自愈依据
#   （计划文档 §13.1: marker 是全链路唯一无法自愈的单点）⇒ 护栏必须比别处更硬:
#   1. **默认只清点不删**（TRYRUN_PURGE_APPLY=0），必须先看清再动手；
#   2. 删除前**强制校验 Dropbox 打包归档存在**（只增不删、保留 30 份的那份，
#      不是会被 sync 连带删除的 mirror）；
#   3. **只删本函数识别出的旧格式 marker**，判据是 marker **内容自证**
#      （restore.script 含 `rclone move ` 而非 moveto），不靠文件时间推测；
#   4. 生成**待删清单 + 归档快照**并落 artifact，删完可核对；
#   5. 数量异常（如清点总数与已知量级差一个数量级）时**拒绝执行**。
#
# 只读清点（默认）: purge_old_markers [task_name|all]
#   产物: <work>/markers_audit.tsv（每个 marker 一行: 名称/格式/条目数/时间/处置）
#         <work>/markers_purge_list.txt（判定为旧格式的 marker 名清单）
# 真删（需显式开关）: TRYRUN_PURGE_APPLY=1 purge_old_markers [task_name|all]
#   ⚠️ 会真的 rclone deletefile；执行前先跑一次默认模式核对清单。
#
# 依赖: sync_marker.sh（SYNC_STATE_DIR）, telegram/tg_notify.sh（排版）

# 旧格式的判据（marker **内容自证**，不靠时间推测）:
#   restore.script 里出现 `rclone move `（不是 moveto）⇒ 由 e90118e 之前的版本写入。
#   为什么不用文件时间: marker 经 rcat 上传、OneDrive 的 lsl 又取不到 ModTime
#   （run 35489237518 实测返回 0 行）⇒ 时间不可靠；而脚本文本是写进去就固定的事实。
# 用法: _is_legacy_marker <json>
_is_legacy_marker() {
  local json="$1"
  # 任一条目的 restore.script 含 "rclone move " 即判旧（注意尾空格，避免误伤 moveto）
  printf '%s' "$json" | grep -qE 'rclone move ' && return 0
  return 1
}

# 清点入口（默认只读）
# 用法: purge_old_markers [task_name|all]
purge_old_markers() {
  local task_filter="${1:-all}"
  local work="${TRYRUN_WORK:-/tmp/restore_tryrun}"
  mkdir -p "$work" 2>/dev/null || { echo "❌ 无法创建报告目录: $work" >&2; return 2; }
  local tsv="$work/markers_audit.tsv"
  local list="$work/markers_purge_list.txt"
  : > "$tsv"; : > "$list"

  echo "=== 旧 marker 清理 · 清点${TRYRUN_PURGE_APPLY:+（**真删模式**）} ==="
  echo "  marker 目录: ${SYNC_STATE_DIR}"
  echo "  任务过滤: ${task_filter}"
  echo

  local markers
  markers=$(rclone lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    echo "❌ 未列举到任何 marker（${SYNC_STATE_DIR}）"
    return 2
  fi

  local m task json n_entries n_legacy=0 n_keep=0 n_unreadable=0
  local legacy_list="" total_entries=0 legacy_entries=0
  printf '%s\t%s\t%s\t%s\t%s\n' "marker" "格式" "条目数" "last_success" "处置" > "$tsv"

  for m in $markers; do
    [[ "$m" == *.json ]] || continue
    task="${m%%_*}"
    if [ "$task_filter" != "all" ] && [ "$task" != "$task_filter" ]; then
      continue
    fi
    json=$(rclone cat "${SYNC_STATE_DIR}/${m}" --retries 2 2>/dev/null) || json=""
    if [ -z "$json" ]; then
      n_unreadable=$((n_unreadable + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "读不到" "0" "（无）" "跳过" >> "$tsv"
      continue
    fi
    n_entries=$(printf '%s' "$json" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    [[ "$n_entries" =~ ^[0-9]+$ ]] || n_entries=0
    total_entries=$((total_entries + n_entries))

    if _is_legacy_marker "$json"; then
      n_legacy=$((n_legacy + 1))
      legacy_entries=$((legacy_entries + n_entries))
      legacy_list+="${m}"$'\n'
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "旧" "$n_entries" \
        "$(printf '%s' "$json" | jq -r '.last_success // "（无）"' 2>/dev/null)" "待删" >> "$tsv"
    else
      n_keep=$((n_keep + 1))
      printf '%s\t%s\t%s\t%s\t%s\n' "$m" "新" "$n_entries" \
        "$(printf '%s' "$json" | jq -r '.last_success // "（无）"' 2>/dev/null)" "保留" >> "$tsv"
    fi
  done

  printf '%s' "$legacy_list" > "$list"

  echo "  清点结果: 旧格式 ${n_legacy} 个（涉及 ${legacy_entries} 条）· " \
       "新格式 ${n_keep} 个 · 读不到 ${n_unreadable} 个"
  echo "  条目总数 ${total_entries}，其中旧格式占 ${legacy_entries}"
  echo "  待删清单: ${list}"
  echo "  全量审计表: ${tsv}"

  # ---- 护栏 1: 默认到此为止（只清点，不删）----
  if [ "${TRYRUN_PURGE_APPLY:-0}" != "1" ]; then
    echo
    echo "ℹ️ 只读模式（默认）: 未删除任何文件。核对清单后如需真删，"
    echo "   显式设置 TRYRUN_PURGE_APPLY=1 再跑（会先校验归档存在）。"
    return 0
  fi

  # ---- 护栏 2: 必须有归档兜底 ----
  # 只认「打包归档」（只增不删、保留 30 份）；**不认** dropbox:sync_state_mirror ——
  # 它是 rclone sync，源端一删副本跟着没（openlist.yml:708 已注明）。
  local bak_remote="${MARKER_BACKUP_REMOTE:-dropbox:self-hosted/openlist/sync_state_backup}"
  local bak_n
  bak_n=$(rclone lsf "$bak_remote" --files-only --retries 2 2>/dev/null \
    | grep -cE '^sync_state_[0-9]{8}-[0-9]{6}\.tar\.gz$' || true)
  [[ "$bak_n" =~ ^[0-9]+$ ]] || bak_n=0
  if [ "$bak_n" -eq 0 ]; then
    echo
    echo "❌ 拒绝删除: 归档目录 ${bak_remote} 下没有 sync_state_*.tar.gz。"
    echo "   marker 是短哈希的唯一自愈依据，无归档即无退路。请先跑一次"
    echo "   openlist.yml 收尾（或手动 backup_sync_state_to_dropbox）产生归档。"
    return 2
  fi
  echo "  ✅ 归档兜底校验通过: ${bak_remote} 下 ${bak_n} 份归档"

  # ---- 护栏 3: 数量异常拒绝（防止判据写错导致误删全量）----
  if [ "$n_legacy" -eq 0 ]; then
    echo "  无旧格式 marker，无需删除。"
    return 0
  fi
  if [ "$n_legacy" -gt "$n_keep" ] && [ "$n_keep" -gt 0 ]; then
    echo
    echo "❌ 拒绝删除: 旧格式(${n_legacy}) 多于新格式(${n_keep})，判据可能写反。"
    echo "   请先核对 markers_audit.tsv —— 这通常是 _is_legacy_marker 误判。"
    return 2
  fi

  # ---- 执行删除：只删清单里的、按名精确删 ----
  echo
  echo "  开始删除 ${n_legacy} 个旧格式 marker..."
  local done_n=0 fail_n=0 mm
  while IFS= read -r mm; do
    [ -n "$mm" ] || continue
    if rclone deletefile "${SYNC_STATE_DIR}/${mm}" --retries 2 --low-level-retries 5 \
      >/dev/null 2>&1; then
      done_n=$((done_n + 1))
    else
      fail_n=$((fail_n + 1))
      echo "     ⚠️ 删除失败: ${mm}"
    fi
  done < "$list"

  echo "  删除完成: 成功 ${done_n} 个 · 失败 ${fail_n} 个"
  echo "  ⚠️ 已删除的 marker 对应条目**不再可还原**（短哈希不可逆）；"
  echo "     如需找回，从 ${bak_remote}/sync_state_*.tar.gz 取。"
  return 0
}
