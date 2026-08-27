#!/bin/bash
# ===== OpenList 同步工具 — 修复文件一键还原 =====
# 把 marker fixed_files 中以替代路径/文件名存在的文件还原为「原路径 + 原文件名」。
# 触发: workflow_dispatch input run_mode="⚠️ 还原 · 修复文件还原为原路径"
#       （restore_task 指定任务名或 all）
#
# 还原策略按修复方式自动分类（方法编号对应 fix.sh 现行 4 种方法）:
#   - 改名类（短哈希文件名、base64URL 编码目录变体）: rclone move 服务端移动
#     回原路径（不经过本地，不重新上传）
#   - 分卷 zip（方法3/4）: 下载全部 .zip.00N 分卷 → cat 合并 → 解压 →
#       上传到原路径 → 验证后删除替代文件
#   - 原路径原名（alt == original，方法1）: 仅验证存在，跳过
#
# 每还原成功一个: 从 marker 的 fixed_files / fix_blacklist 移除该条目并即时写回，
# 中断后重跑不会重复处理。全部完成后发送 Telegram 汇总。
#
# 注意: 还原 = 把文件放回目标端原路径。若后端对该路径仍无法持久化（假成功），
# 下一轮同步会重新检测缺失并再次修复，数据不会丢。
#
# 依赖: utils.sh, telegram.sh, marker.sh (SYNC_STATE_DIR), rclone, 7z

# 目标端文件存在性检查
# 用法: _dst_file_exists <full_remote_path>
_dst_file_exists() {
  local full="$1"
  rclone lsf "$(dirname "$full")" --files-only --retries 1 --low-level-retries 2 \
    --timeout 2m 2>/dev/null | grep -qxF "$(basename "$full")"
}

# 按修复方法名分类还原方式（move=改名类 / split=分卷打包类）
_restore_classify_kind() {
  case "$1" in
    *分卷*) echo "split" ;;
    *) echo "move" ;;
  esac
}

# 下载分卷形态并解码为本地原始文件（两个还原入口共用管线）
# 用法: _restore_build_payload <alt> <alt_base> <tmp>
#   alt: 替代文件相对路径（以首卷定位全部分卷）; alt_base: 替代文件所在远端根
# 输出: "OK:<local_payload_path>" 或 "FAIL:<原因>"（返回码随之 0/1）
# 仅处理 kind=split；kind=move 在入口函数已单独走服务端移动，不会到这
_restore_build_payload() {
  local alt="$1" alt_base="$2" tmp="$3"
  local rflags=("${RCLONE_RETRY_FLAGS[@]}" --timeout 15m)

  # 分卷: 列举 → 下载 → 合并
  local pkg="$tmp/pkg"
  local alt_dir prefix parts_regex p
  alt_dir="$(dirname "$alt")"
  prefix="$(basename "$alt")"          # <name>.zip.001
  prefix="${prefix%.*}"                # <name>.zip
  parts_regex="^$(printf '%s' "$prefix" | sed 's/[.]/\\./g')\.[0-9]{3}$"
  local parts
  parts=$(rclone lsf "${alt_base}/${alt_dir}" --files-only --retries 1 2>/dev/null | grep -E "$parts_regex" | sort)
  if [ -z "$parts" ]; then
    echo "FAIL: 未找到分卷（前缀 ${prefix}）"
    return 1
  fi
  mkdir -p "$tmp/parts"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    rclone copyto "${alt_base}/${alt_dir}/${p}" "$tmp/parts/$p" "${rflags[@]}" >/dev/null 2>&1 || { echo "FAIL: 下载分卷 ${p} 失败"; return 1; }
  done <<< "$parts"
  cat "$tmp"/parts/* > "$pkg" 2>/dev/null || { echo "FAIL: 合并分卷失败"; return 1; }

  # 解压
  if ! 7z x -y "$pkg" -o"$tmp/out" >/dev/null 2>&1; then
    echo "FAIL: 解压失败"
    return 1
  fi
  local inner
  inner=$(find "$tmp/out" -type f 2>/dev/null | head -1)
  if [ -z "$inner" ]; then
    echo "FAIL: 解压后未找到文件"
    return 1
  fi
  echo "OK:$inner"
}

# 还原成功后清理目标端分卷（删除该前缀的全部卷）
# 用法: _restore_cleanup_alternative <alt_base> <alt>
_restore_cleanup_alternative() {
  local alt_base="$1" alt="$2"
  local rflags=("${RCLONE_RETRY_FLAGS[@]}" --timeout 15m)
  local alt_dir prefix parts_regex p
  alt_dir="$(dirname "$alt")"
  prefix="$(basename "$alt")"
  prefix="${prefix%.*}"
  parts_regex="^$(printf '%s' "$prefix" | sed 's/[.]/\\./g')\.[0-9]{3}$"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    rclone deletefile "${alt_base}/${alt_dir}/${p}" "${rflags[@]}" >/dev/null 2>&1 || true
  done < <(rclone lsf "${alt_base}/${alt_dir}" --files-only --retries 1 2>/dev/null | grep -E "$parts_regex")
}

# 还原单个条目（内部函数，输出一行状态: OK 或 FAIL: <原因>）
# 用法: _restore_one_entry <dest_path> <orig> <alt> <method> <tmp_base>
_restore_one_entry() {
  local dest="$1" orig="$2" alt="$3" method="$4" tmp_base="$5"
  local src_full="${dest}/${alt}"
  local dst_full="${dest}/${orig}"
  local rflags=("${RCLONE_RETRY_FLAGS[@]}" --timeout 15m)

  # 原路径原名: 只验证存在
  if [ "$alt" = "$orig" ]; then
    if _dst_file_exists "$dst_full"; then
      echo "OK"
    else
      echo "FAIL: 原路径文件不存在且无替代路径可还原"
    fi
    return 0
  fi

  # 按方法分类
  local kind
  kind=$(_restore_classify_kind "$method")

  if [ "$kind" = "move" ]; then
    # 改名类: 服务端移动回原路径
    if ! rclone move "$src_full" "$dst_full" "${rflags[@]}" >/dev/null 2>&1; then
      echo "FAIL: rclone move 失败（替代文件可能已不存在）"
      return 0
    fi
    if _dst_file_exists "$dst_full"; then
      echo "OK"
    else
      echo "FAIL: move 返回成功但原路径未见文件（疑似假成功）"
    fi
    return 0
  fi

  local tmp="${tmp_base}/$(echo "$orig" | md5sum | cut -c1-12)"
  rm -rf "$tmp"
  mkdir -p "$tmp"

  local res payload
  res=$(_restore_build_payload "$alt" "$dest" "$tmp")
  if [ "${res%%:*}" != "OK" ]; then
    echo "${res:-FAIL: 未知错误}"
    rm -rf "$tmp"
    return 0
  fi
  payload="${res#OK:}"
  rclone copyto "$payload" "$dst_full" "${rflags[@]}" >/dev/null 2>&1 || { echo "FAIL: 上传还原文件失败"; rm -rf "$tmp"; return 0; }

  # 验证原路径已存在 → 清理目标端替代文件
  if _dst_file_exists "$dst_full"; then
    _restore_cleanup_alternative "$dest" "$alt"
    echo "OK"
  else
    echo "FAIL: 上传返回成功但原路径未见文件（疑似假成功，替代文件已保留）"
  fi
  rm -rf "$tmp"
  return 0
}

# 一键还原入口
# 用法: restore_fixed_files [task_name|all]
restore_fixed_files() {
  local task_filter="${1:-all}"
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local tmp_base="/tmp/restore_fixed_${ts}"
  mkdir -p "$tmp_base"

  echo "=== 修复文件一键还原 (filter=${task_filter}) ==="

  local markers m task marker_path json dest count
  markers=$(rclone lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    echo "未找到任何 marker（${SYNC_STATE_DIR}）"
    return 0
  fi

  local total_ok=0 total_fail=0
  local ok_list="" fail_list=""

  for m in $markers; do
    [[ "$m" == *.json ]] || continue
    task="${m%%_*}"
    if [ "$task_filter" != "all" ] && [ "$task" != "$task_filter" ]; then
      continue
    fi
    marker_path="${SYNC_STATE_DIR}/${m}"
    json=$(rclone cat "$marker_path" 2>/dev/null) || continue
    dest=$(echo "$json" | jq -r '.dest_path // empty' 2>/dev/null)
    [ -z "$dest" ] && continue
    count=$(echo "$json" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    [ "$count" -eq 0 ] && continue

    echo "--- marker: ${m} (dest=${dest}, 待还原 ${count} 条) ---"

    while IFS=$'\t' read -r orig alt method; do
      [ -z "$orig" ] && continue
      [ "$alt" = "null" ] || [ -z "$alt" ] && alt="$orig"

      echo "还原中: ${orig} ← ${alt} [${method}]"
      local status
      status=$(_restore_one_entry "$dest" "$orig" "$alt" "$method" "$tmp_base")
      echo "  → ${status}"

      if [ "${status%%:*}" = "OK" ]; then
        total_ok=$((total_ok + 1))
        ok_list+="• <code>$(escape_html "$orig")</code>"$'\n'
        # 从 marker 移除该条目（fixed_files + fix_blacklist），即时写回
        json=$(echo "$json" | marker_remove_fix_entry "$orig" 1) || true
        _marker_write "$json" "$marker_path" >/dev/null 2>&1 || true
      else
        total_fail=$((total_fail + 1))
        fail_list+="• <code>$(escape_html "$orig")</code> · <i>$(escape_html "${status#FAIL: }")</i>"$'\n'
      fi
    done < <(echo "$json" | jq -r '(.fixed_files // [])[] | [.original, .alternative, .method] | @tsv' 2>/dev/null)
  done

  rm -rf "$tmp_base"

  # 汇总通知
  local msg=""
  tg_add_title msg "🔧 修复文件一键还原完成"
  tg_add_kv msg "还原成功" "${total_ok} 个"
  tg_add_kv msg "还原失败" "${total_fail} 个"
  if [ -n "$ok_list" ]; then
    tg_add_section msg "✅ 已还原（原路径原文件名）"
    tg_add_block msg "$ok_list"
  fi
  if [ -n "$fail_list" ]; then
    tg_add_section msg "❌ 失败清单"
    tg_add_block msg "$fail_list"
  fi
  tg_add_note msg "成功条目已从 marker 修复清单移除；失败条目保留，可重试。"
  send_telegram_message "$msg"
  echo "=== 还原完成: OK=${total_ok} FAIL=${total_fail} ==="
}

# rclone --exclude-from 行转义: 文件名里的 glob 字符（[ ] * ?）按字面匹配
_escape_exclude_path() {
  printf '%s' "$1" | sed 's/[][\*?]/\\&/g'
}

# ===== 灾难恢复: 目标端 → 源端 =====
# 思路: 修复文件以替代形态（短哈希名/编码目录名/分卷 zip）存在于目标端，正是因为它们
# 以原形态无法在该后端持久化——所以恢复绝不经过"目标端改回原名"，而是
# 一步直达源端:
#   1. 普通文件（含 alt == original 的修复条目）: crypt 层对 rclone 透明，
#      rclone copy 目标 → 源端（--size-only，源端已有且同大小则跳过）
#   2. 修复文件: 排除出批量拷贝后逐条处理——从目标端下载替代形态，
#      本地解码（合卷解压；改名类内容本就相同），
#      以原路径原文件名上传到源端，按 marker 记录的 size_bytes 校验
#   3. 全程不删除目标端任何文件（备份保持完整，可重复执行）
# 依赖 marker 的 original/alternative/method 映射（marker 与源端同在 OneDrive，
# 若 OneDrive 整体丢失则 marker 也丢，此工具的前提是 marker 仍可读或已外置备份）
# 用法: restore_source_from_target [task_name|all]

# 单个修复文件恢复到源端（内部函数，输出一行状态）
# 用法: _recover_one_to_source <src_remote> <dest_remote> <orig> <alt> <method> <expect_bytes> <tmp_base>
_recover_one_to_source() {
  local src_remote="$1" dest_remote="$2" orig="$3" alt="$4" method="$5" expect_bytes="$6" tmp_base="$7"
  local rflags=("${RCLONE_RETRY_FLAGS[@]}" --timeout 15m)
  local src_full="${src_remote}/${orig}"
  local src_file="${dest_remote}/${alt}"

  # 源端已存在同名同大小 → 无需恢复（重复执行幂等）
  local cur=0
  cur=$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
  if [ "$cur" = "$expect_bytes" ] && [ "$cur" != "0" ]; then
    echo "SKIP"
    return 0
  fi

  # 改名类: 内容与原文件相同，直接 目标端替代路径 → 源端原路径
  local kind
  kind=$(_restore_classify_kind "$method")

  if [ "$kind" = "move" ]; then
    if rclone copyto "$src_file" "$src_full" "${rflags[@]}" >/dev/null 2>&1 \
       && [ "$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0')" = "$expect_bytes" ]; then
      echo "OK"
    else
      echo "FAIL: 改名类恢复失败（替代文件可能已不存在于目标端）"
    fi
    return 0
  fi

  local tmp="${tmp_base}/$(echo "$orig" | md5sum | cut -c1-12)"
  rm -rf "$tmp"; mkdir -p "$tmp"

  local res payload
  res=$(_restore_build_payload "$alt" "$dest_remote" "$tmp")
  if [ "${res%%:*}" != "OK" ]; then
    echo "${res:-FAIL: 未知错误}"
    rm -rf "$tmp"
    return 0
  fi
  payload="${res#OK:}"
  rclone copyto "$payload" "$src_full" "${rflags[@]}" >/dev/null 2>&1 || { echo "FAIL: 上传源端失败"; rm -rf "$tmp"; return 0; }

  # 按 marker 记录的字节数校验（expect_bytes 为 0 时仅检查非空）
  local got=0
  got=$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
  if { [ "$expect_bytes" != "0" ] && [ "$got" = "$expect_bytes" ]; } || { [ "$expect_bytes" = "0" ] && [ "$got" != "0" ]; }; then
    echo "OK"
  else
    echo "FAIL: 大小校验不符 (期望 ${expect_bytes}, 实际 ${got})"
  fi
  rm -rf "$tmp"
  return 0
}

# 灾难恢复入口（目标端 → 源端，非破坏性，可重复执行）
restore_source_from_target() {
  local task_filter="${1:-all}"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local tmp_base="/tmp/restore_src_${ts}"
  mkdir -p "$tmp_base"

  echo "=== 灾难恢复: 目标端 → 源端 (filter=${task_filter}) ==="

  local markers m task marker_path json src dst entries
  markers=$(rclone lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    echo "未找到任何 marker（${SYNC_STATE_DIR}）"
    return 1
  fi

  local total_bulk=0 total_ok=0 total_fail=0 total_skip=0
  local fail_list=""

  for m in $markers; do
    [[ "$m" == *.json ]] || continue
    task="${m%%_*}"
    if [ "$task_filter" != "all" ] && [ "$task" != "$task_filter" ]; then
      continue
    fi
    marker_path="${SYNC_STATE_DIR}/${m}"
    json=$(rclone cat "$marker_path" 2>/dev/null) || continue
    src=$(echo "$json" | jq -r '.source_path // empty' 2>/dev/null)
    dst=$(echo "$json" | jq -r '.dest_path // empty' 2>/dev/null)
    [ -z "$src" ] || [ -z "$dst" ] && continue
    entries=$(echo "$json" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    echo "--- marker: ${m} (src=${src}, dst=${dst}, 修复条目 ${entries}) ---"

    # 1. 批量拷回普通文件（排除替代形态，防止 zip/分卷/改名件以替代名落到源端）
    local exf="${tmp_base}/exclude_${m}.txt"
    : > "$exf"
    local alt_lines="" line_orig line_alt
    while IFS=$'\t' read -r line_orig line_alt; do
      [ -z "$line_orig" ] && continue
      [ "$line_alt" = "null" ] || [ -z "$line_alt" ] && continue
      [ "$line_alt" = "$line_orig" ] && continue
      if echo "$line_alt" | grep -qE '\.zip\.[0-9]{3}$'; then
        # 分卷: 剥掉 .001 后前缀已含 .zip，按前缀通配排除所有卷（glob 转义）
        local pdir pfx
        pdir="$(dirname "$line_alt")"; pfx="$(basename "$line_alt")"; pfx="${pfx%.*}"
        printf '/%s/%s.[0-9][0-9][0-9]\n' "$(_escape_exclude_path "$pdir")" "$(_escape_exclude_path "$pfx")" >> "$exf"
      else
        printf '/%s\n' "$(_escape_exclude_path "$line_alt")" >> "$exf"
      fi
      alt_lines+="${line_orig}"$'\t'"${line_alt}"$'\n'
    done < <(echo "$json" | jq -r '(.fixed_files // [])[] | [.original, .alternative] | @tsv' 2>/dev/null)

    echo "批量拷回普通文件: ${dst} → ${src} (排除替代形态 $(grep -c . "$exf" 2>/dev/null || echo 0) 条)"
    local before after
    before=$(rclone size --json "$src" 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
    if [ -s "$exf" ]; then
      rclone copy "$dst" "$src" --size-only --exclude-from "$exf" --retries 2 --low-level-retries 3 --timeout 15m 2>&1 | tail -3
    else
      rclone copy "$dst" "$src" --size-only --retries 2 --low-level-retries 3 --timeout 15m 2>&1 | tail -3
    fi
    after=$(rclone size --json "$src" 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
    total_bulk=$((total_bulk + after - before))

    # 2. 修复文件逐条: 替代形态 → 解码 → 源端原路径
    if [ -n "$alt_lines" ]; then
      while IFS=$'\t' read -r line_orig line_alt; do
        [ -z "$line_orig" ] && continue
        local method ebytes entry
        entry=$(echo "$json" | jq -c --arg f "$line_orig" '[.fixed_files[] | select(.original == $f)] | .[0] // empty' 2>/dev/null)
        method=$(echo "$entry" | jq -r '.method // ""' 2>/dev/null)
        ebytes=$(echo "$entry" | jq -r '.size_bytes // 0' 2>/dev/null)
        echo "恢复修复文件: ${line_orig} ← ${line_alt} [${method}]"
        local status
        status=$(_recover_one_to_source "$src" "$dst" "$line_orig" "$line_alt" "$method" "$ebytes" "$tmp_base")
        echo "  → ${status}"
        case "$status" in
          OK) total_ok=$((total_ok + 1)) ;;
          SKIP) total_skip=$((total_skip + 1)) ;;
          *) total_fail=$((total_fail + 1)); fail_list+="• <code>$(escape_html "$line_orig")</code> · <i>$(escape_html "${status#FAIL: }")</i>"$'\n' ;;
        esac
      done <<< "$alt_lines"
    fi
  done

  rm -rf "$tmp_base"

  local msg=""
  tg_add_title msg "🆘 灾难恢复完成（目标端 → 源端）"
  tg_add_kv msg "批量拷回普通文件" "${total_bulk} 个"
  tg_add_kv msg "修复文件恢复成功" "${total_ok} 个"
  tg_add_kv msg "源端已存在跳过" "${total_skip} 个"
  tg_add_kv msg "失败" "${total_fail} 个"
  if [ -n "$fail_list" ]; then
    tg_add_section msg "❌ 失败清单"
    tg_add_block msg "$fail_list"
  fi
  tg_add_note msg "目标端未做任何删改，可重复执行补齐失败条目。"
  send_telegram_message "$msg"
  echo "=== 恢复完成: bulk=${total_bulk} ok=${total_ok} skip=${total_skip} fail=${total_fail} ==="
}
