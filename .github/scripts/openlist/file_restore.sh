#!/bin/bash
# ===== OpenList 同步工具 — 修复文件一键还原 =====
# 把 marker fixed_files 中以替代路径/文件名存在的文件还原为「原路径 + 原文件名」。
# 触发: workflow_dispatch input run_mode="⚠️ 还原 · 修复文件还原为原路径"
#       （restore_task 指定任务名或 all）
#
# 还原策略按修复方式自动分类（方法编号对应 file_fix.sh 现行 4 种方法）:
#   - 改名类（短哈希文件名、base64URL 编码目录变体）: rclone move 服务端移动
#     回原路径（不经过本地，不重新上传）
#   - 分卷 zip（文件修复方法3/4）: 下载全部 .zip.00N 分卷 → cat 合并 → 解压 →
#       md5 与 marker 指纹核对（有记录则硬校验，不符拒上传）→
#       上传到原路径 → 验证后删除替代文件
#   - 原路径原名（alt == original，文件修复方法1）: 仅验证存在，跳过
#
# 每还原成功一个: 从 marker 的 fixed_files / fix_blacklist 移除该条目并即时写回，
# 中断后重跑不会重复处理。全部完成后发送 Telegram 汇总。
#
# 注意: 还原 = 把文件放回目标端原路径。若后端对该路径仍无法持久化（假成功），
# 下一轮同步会重新检测缺失并再次修复，数据不会丢。
#
# 依赖: utils.sh, telegram.sh, sync_marker.sh (SYNC_STATE_DIR), rclone, 7z

# 目标端文件存在性检查
# 用法: _dst_file_exists <full_remote_path>
_dst_file_exists() {
  local full="$1"
  rclone lsf "$(dirname "$full")" --files-only --retries 1 --low-level-retries 2 \
    --timeout 2m 2>/dev/null | grep -qxF "$(basename "$full")"
}

# 尽力取远端文件的服务端 md5（源端为普通后端如 OneDrive 时可用；
# crypt 端不暴露明文 hash → 恒返回空串，调用方必须容忍空值=跳过内容校验）
# 用法: _rclone_remote_md5 <full_remote_path>   输出: 32 位 hex 或空串
# 注: lsjson 不接受 --retries 等传输类 flag，故不带 RCLONE_RETRY_FLAGS
_rclone_remote_md5() {
  local h
  h=$(rclone lsjson --hash "$1" 2>/dev/null | jq -r '.[0].Hashes.MD5 // ""' 2>/dev/null)
  [[ "$h" =~ ^[0-9a-f]{32}$ ]] || h=""
  echo "$h"
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
  # pipefail 下 grep 无匹配(rc=1)会传染裸赋值直接杀 step; 缺失由下方 -z 判断处理
  parts=$(rclone lsf "${alt_base}/${alt_dir}" --files-only --retries 1 2>/dev/null | { grep -E "$parts_regex" || true; } | sort)
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
# 用法: _restore_one_entry <dest_path> <orig> <alt> <method> <tmp_base> [md5]
_restore_one_entry() {
  local dest="$1" orig="$2" alt="$3" method="$4" tmp_base="$5" fmd5="${6:-}"
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
    # 改名类: 服务端移动回原路径（目标端为 crypt，明文 md5 无从比对，
    # 内容级校验只在分卷类的本地解压产物上做，此处以存在性为验收）
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

  local res payload payload_bytes up_bytes
  # 命令替换返回码会传染: payload 内部 return 1（分卷缺失/下载/合并/解压失败）
  # 时，未保护的裸赋值在 set -e step 里会直接终止整个还原 run
  res=$(_restore_build_payload "$alt" "$dest" "$tmp") || true
  if [ "${res%%:*}" != "OK" ]; then
    echo "${res:-FAIL: 未知错误}"
    rm -rf "$tmp"
    return 0
  fi

  # 校验基准 = 本地解压产物字节数（7z 解压已过 zip CRC，产物可信）；
  # marker 的 size_bytes 在 fallback 条目上等于分卷总大小，不能作等值判据
  payload="${res#OK:}"
  payload_bytes=$(wc -c <"$payload")

  # 内容级硬门: marker 记录了原文件 md5 时，先验本地解压产物再上传
  # （zip CRC 只保证打包件自身完整，打包前原文件是否坏损只有 md5 能判定）；
  # 不符 → 拒上传，FAIL 保留替代文件。旧 marker 无 md5 字段 → 静默跳过此门
  if [ -n "$fmd5" ]; then
    local payload_md5
    payload_md5=$(md5sum "$payload" 2>/dev/null | awk '{print $1}')
    if [ "$payload_md5" != "$fmd5" ]; then
      echo "FAIL: 解压产物 md5 与 marker 不符 (期望 ${fmd5}, 实际 ${payload_md5})"
      rm -rf "$tmp"
      return 0
    fi
  fi

  rclone copyto "$payload" "$dst_full" "${rflags[@]}" >/dev/null 2>&1 || { echo "FAIL: 上传还原文件失败"; rm -rf "$tmp"; return 0; }

  # 原路径存在且大小与解压产物一致 → 才清理目标端替代文件
  up_bytes=$(rclone size --json "$dst_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
  if ! _dst_file_exists "$dst_full"; then
    echo "FAIL: 上传返回成功但原路径未见文件（疑似假成功，替代文件已保留）"
  elif [ "$up_bytes" != "$payload_bytes" ]; then
    echo "FAIL: 上传后大小与解压产物不符 (产物 ${payload_bytes}B, 现值 ${up_bytes}B)，替代文件已保留"
  else
    _restore_cleanup_alternative "$dest" "$alt"
    echo "OK"
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

    while IFS=$'\t' read -r orig alt method fmd5; do
      [ -z "$orig" ] && continue
      [ "$alt" = "null" ] || [ -z "$alt" ] && alt="$orig"

      echo "还原中: ${orig} ← ${alt} [${method}]"
      local status
      status=$(_restore_one_entry "$dest" "$orig" "$alt" "$method" "$tmp_base" "$fmd5") || true
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
    done < <(echo "$json" | jq -r '(.fixed_files // [])[] | [.original, .alternative, .method, (.md5 // "")] | @tsv' 2>/dev/null)
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
#      以原路径原文件名上传到源端。校验基准 = 本地解压产物
#      （marker 有 md5 指纹时先做内容硬门，7z 已过 zip CRC）；
#      源端为普通后端时另尽力核对服务端 md5（含 SKIP 前的内容核对，
#      等大坏件强制重传）——防"假成功/截断/等大坏件"；
#      marker 的 size_bytes 在 fallback 条目上等于分卷总大小，
#      故只降级为交叉核对注记，不用于成败判定
#   3. 全程不删除目标端任何文件（备份保持完整，可重复执行）
# 依赖 marker 的 original/alternative/method 映射（marker 与源端同在 OneDrive，
# 若 OneDrive 整体丢失则 marker 也丢，此工具的前提是 marker 仍可读或已外置备份）
# 用法: restore_source_from_target [task_name|all]

# 单个修复文件恢复到源端（内部函数，输出一行状态）
# 用法: _recover_one_to_source <src_remote> <dest_remote> <orig> <alt> <method> <expect_bytes> <tmp_base> [md5]
# 输出: "SKIP" / "OK" / "OK: <附注>"（调用方须按 ${status%%:*} 前缀判定成功）/ "FAIL: <原因>"
# md5: fix 时记录的原文件内容指纹；有值时升级为内容级校验（本地产物硬门 +
#      源端服务端 hash 尽力核对），无值时维持字节数口径（旧 marker 兼容）
_recover_one_to_source() {
  local src_remote="$1" dest_remote="$2" orig="$3" alt="$4" method="$5" expect_bytes="$6" tmp_base="$7" fmd5="${8:-}"
  local rflags=("${RCLONE_RETRY_FLAGS[@]}" --timeout 15m)
  local src_full="${src_remote}/${orig}"
  local src_file="${dest_remote}/${alt}"

  # 源端已存在同名同大小 → 无需恢复（重复执行幂等）；
  # 有 md5 指纹且服务端 hash 可读时升级为内容核对: 等大但内容不符 →
  # 不跳过，落到下方修复流程强制重传（否则等大坏件会永远被误判已恢复）
  local cur=0
  cur=$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
  if [ "$cur" = "$expect_bytes" ] && [ "$cur" != "0" ]; then
    if [ -n "$fmd5" ]; then
      local skip_md5
      skip_md5=$(_rclone_remote_md5 "$src_full")
      if [ -z "$skip_md5" ] || [ "$skip_md5" = "$fmd5" ]; then
        echo "SKIP"
        return 0
      fi
    else
      echo "SKIP"
      return 0
    fi
  fi

  # 改名类: 内容与原文件相同，直接 目标端替代路径 → 源端原路径
  local kind
  kind=$(_restore_classify_kind "$method")

  if [ "$kind" = "move" ]; then
    # 改名类: 内容与原文件相同，直接 目标端替代路径 → 源端原路径
    if ! rclone copyto "$src_file" "$src_full" "${rflags[@]}" >/dev/null 2>&1; then
      echo "FAIL: 改名类恢复失败（替代文件可能已不存在于目标端）"
      return 0
    fi
    if [ "$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0')" != "$expect_bytes" ]; then
      echo "FAIL: 改名类恢复失败（上传后大小与 marker 记录不符，疑似假成功/截断）"
      return 0
    fi
    # 内容级尽力核对: 服务端 hash 可读且与指纹不符 → 判失败（等大坏件不放行）
    if [ -n "$fmd5" ]; then
      local mv_md5
      mv_md5=$(_rclone_remote_md5 "$src_full")
      if [ -n "$mv_md5" ] && [ "$mv_md5" != "$fmd5" ]; then
        echo "FAIL: 源端 md5 与 marker 不符 (期望 ${fmd5}, 实际 ${mv_md5})"
        return 0
      fi
    fi
    echo "OK"
    return 0
  fi

  local tmp="${tmp_base}/$(echo "$orig" | md5sum | cut -c1-12)"
  rm -rf "$tmp"; mkdir -p "$tmp"

  local res payload payload_bytes got
  res=$(_restore_build_payload "$alt" "$dest_remote" "$tmp") || true
  if [ "${res%%:*}" != "OK" ]; then
    echo "${res:-FAIL: 未知错误}"
    rm -rf "$tmp"
    return 0
  fi

  # 唯一校验基准 = 本地解压产物（7z 解压已过 zip CRC，产物即真相）:
  #   先做内容级硬门（有指纹时），再做上传判定与同口径复查——防截断、防假成功
  payload="${res#OK:}"
  payload_bytes=$(wc -c <"$payload")
  if [ -n "$fmd5" ]; then
    local payload_md5
    payload_md5=$(md5sum "$payload" 2>/dev/null | awk '{print $1}')
    [ "$payload_md5" = "$fmd5" ] || { echo "FAIL: 解压产物 md5 与 marker 不符 (期望 ${fmd5}, 实际 ${payload_md5})"; rm -rf "$tmp"; return 0; }
  fi

  # 上传判定（内容级优先）:
  #   服务端 hash 可读 → md5 一致即内容一致，免重传（重跑幂等）；
  #     md5 不符 → 即使等大也强制重传（等大坏件若按字节口径会被跳过，重跑永远 FAIL）
  #   hash 不可读（源端后端不提供 md5）→ 退回字节数比对（既有口径）
  got=$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
  local rmd5="" need_upload=0
  [ -n "$fmd5" ] && rmd5=$(_rclone_remote_md5 "$src_full")
  if [ -n "$rmd5" ]; then
    [ "$rmd5" != "$fmd5" ] && need_upload=1
  else
    [ "$got" != "$payload_bytes" ] && need_upload=1
  fi
  if [ "$need_upload" -eq 1 ]; then
    rclone copyto "$payload" "$src_full" "${rflags[@]}" >/dev/null 2>&1 || { echo "FAIL: 上传源端失败"; rm -rf "$tmp"; return 0; }
    got=$(rclone size --json "$src_full" "${rflags[@]}" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null)
    [ "$got" = "$payload_bytes" ] || { echo "FAIL: 源端大小与解压产物不符 (期望 ${payload_bytes}B, 实际 ${got}B)"; rm -rf "$tmp"; return 0; }
    if [ -n "$fmd5" ]; then
      rmd5=$(_rclone_remote_md5 "$src_full")
      [ -n "$rmd5" ] && [ "$rmd5" != "$fmd5" ] && { echo "FAIL: 源端 md5 与 marker 不符 (期望 ${fmd5}, 实际 ${rmd5})"; rm -rf "$tmp"; return 0; }
    fi
  fi

  # marker 的 expect_bytes 仅作交叉核对: fallback 条目该值=分卷总大小≠原文件大小，
  # 与产物不一致只产生说明性附注，不影响成功判定（normal linkage 时两者恒等，走静默 OK）
  if [ "$expect_bytes" != "0" ] && [ "$expect_bytes" != "$payload_bytes" ]; then
    echo "OK: 已按解压产物 ${payload_bytes}B 核验（marker 记录 ${expect_bytes}B 为分卷总大小，仅供参考）"
  else
    echo "OK"
  fi
  rm -rf "$tmp"
  return 0
}

# 批量逐条恢复 marker 修复条目到源端（restore_source_from_target /
# rebuild_source_from_target 共用）。进度日志走 stderr，结果走 stdout，
# 每条输出一行 "<original>\t<status>"（status 口径同 _recover_one_to_source），
# 由调用方按前缀汇总统计与失败清单
# 用法: _recover_source_entries <src> <dst> <json> <alt_lines_tsv> <tmp_base>
_recover_source_entries() {
  local src="$1" dst="$2" json="$3" alt_lines="$4" tmp_base="$5"
  [ -n "$alt_lines" ] || return 0
  local line_orig line_alt
  while IFS=$'\t' read -r line_orig line_alt; do
    [ -z "$line_orig" ] && continue
    local method ebytes fmd5 entry status
    entry=$(echo "$json" | jq -c --arg f "$line_orig" '[.fixed_files[] | select(.original == $f)] | .[0] // empty' 2>/dev/null)
    method=$(echo "$entry" | jq -r '.method // ""' 2>/dev/null)
    ebytes=$(echo "$entry" | jq -r '.size_bytes // 0' 2>/dev/null)
    fmd5=$(echo "$entry" | jq -r '.md5 // ""' 2>/dev/null)
    [ "$fmd5" = "null" ] && fmd5=""
    echo "恢复修复文件: ${line_orig} ← ${line_alt} [${method}]" >&2
    status=$(_recover_one_to_source "$src" "$dst" "$line_orig" "$line_alt" "$method" "$ebytes" "$tmp_base" "$fmd5") || true
    echo "  → ${status}" >&2
    printf '%s\t%s\n' "$line_orig" "$status"
  done <<< "$alt_lines"
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
    while IFS=$'\t' read -r entry_orig entry_status; do
      [ -z "$entry_orig" ] && continue
      case "${entry_status%%:*}" in   # 前缀匹配: 兼容 "OK"/"OK: <附注>"，仍可区分 SKIP/FAIL
        OK) total_ok=$((total_ok + 1)) ;;
        SKIP) total_skip=$((total_skip + 1)) ;;
        *) total_fail=$((total_fail + 1)); fail_list+="• <code>$(escape_html "$entry_orig")</code> · <i>$(escape_html "${entry_status#FAIL: }")</i>"$'\n' ;;
      esac
    done < <(_recover_source_entries "$src" "$dst" "$json" "$alt_lines" "$tmp_base")
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

# ===== 镜像灾难恢复: 目标端 → 源端（删除源端多余文件）=====
# ⚠️ 破坏性变体（命名对照，勿混用）:
#   restore_source_from_target — 还原: 仅把 marker 修复条目回填源端，不删任何文件
#   rebuild_source_from_target — 重建: 先 sync 镜像再回填，源端最终 = 目标端内容
# 两者同是"目标端 → 源端"，但后者会删除源端多余文件（批量层从 copy 升级为
# sync），故用 rebuild 而非 restore 命名，避免从名字看不出删除风险。
# 安全边界:
#   - 排除清单 = 替代形态 + 全部修复条目的原路径: 前者防止分卷/改名/
#     编码目录以密文名被 sync 拷回源端；后者把待还原路径的增删完全交给
#     逐条还原（sync 若删除原路径，还原失败时源端现存旧文件也保不住）
#   - alt == original 的修复条目两端口径一致，交由 sync 正常处理
#   - marker 未登记的替代形态残留不在排除清单内，会被 sync 当普通文件
#     原样拷回源端（数据不丢但可能残留垃圾文件；不确定时先跑
#     restore_source_from_target 看失败清单再决定）
# 执行顺序: 先 sync 镜像、后逐条还原（修复文件路径已被排除，互不干扰）。
# 目标端全程只读；中断/失败可直接重跑补齐。
# 用法: rebuild_source_from_target [task_name|all]
rebuild_source_from_target() {
  local task_filter="${1:-all}"
  local ts; ts=$(date +%Y%m%d_%H%M%S)
  local tmp_base="/tmp/mirror_src_${ts}"
  mkdir -p "$tmp_base"

  echo "=== 镜像灾难恢复: 目标端 → 源端 (filter=${task_filter}, 将删除源端多余文件) ==="

  local markers m task marker_path json src dst entries
  markers=$(rclone lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    echo "未找到任何 marker（${SYNC_STATE_DIR}）"
    return 1
  fi

  local total_ok=0 total_fail=0 total_skip=0
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

    # 1. sync 镜像（排除替代形态 + 修复条目原路径，见函数头注释）
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
      # 原路径一并排除: 待还原路径的增删由逐条还原负责
      printf '/%s\n' "$(_escape_exclude_path "$line_orig")" >> "$exf"
      alt_lines+="${line_orig}"$'\t'"${line_alt}"$'\n'
    done < <(echo "$json" | jq -r '(.fixed_files // [])[] | [.original, .alternative] | @tsv' 2>/dev/null)

    echo "sync 镜像: ${dst} → ${src} (排除 $(grep -c . "$exf" 2>/dev/null || echo 0) 条, 删除源端多余文件)"
    local before after sync_rc=0
    before=$(rclone size --json "$src" 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
    if [ -s "$exf" ]; then
      rclone sync "$dst" "$src" --size-only --exclude-from "$exf" --retries 2 --low-level-retries 3 --timeout 15m 2>&1 | tail -3
      sync_rc=${PIPESTATUS[0]}
    else
      rclone sync "$dst" "$src" --size-only --retries 2 --low-level-retries 3 --timeout 15m 2>&1 | tail -3
      sync_rc=${PIPESTATUS[0]}
    fi
    after=$(rclone size --json "$src" 2>/dev/null | jq -r '.count // 0' 2>/dev/null)
    echo "源端文件数: ${before} → ${after}"
    [ "$sync_rc" -ne 0 ] && echo "⚠️ sync 退出码 ${sync_rc}（镜像可能不完整，可直接重跑本模式补齐）"

    # 2. 修复文件逐条还原（路径已被排除出 sync，不会被镜像删除）
    while IFS=$'\t' read -r entry_orig entry_status; do
      [ -z "$entry_orig" ] && continue
      case "${entry_status%%:*}" in
        OK) total_ok=$((total_ok + 1)) ;;
        SKIP) total_skip=$((total_skip + 1)) ;;
        *) total_fail=$((total_fail + 1)); fail_list+="• <code>$(escape_html "$entry_orig")</code> · <i>$(escape_html "${entry_status#FAIL: }")</i>"$'\n' ;;
      esac
    done < <(_recover_source_entries "$src" "$dst" "$json" "$alt_lines" "$tmp_base")
  done

  rm -rf "$tmp_base"

  local msg=""
  tg_add_title msg "🆘 镜像灾难恢复完成（目标端 → 源端 · 已删除源端多余文件）"
  tg_add_kv msg "修复文件恢复成功" "${total_ok} 个"
  tg_add_kv msg "源端已存在跳过" "${total_skip} 个"
  tg_add_kv msg "失败" "${total_fail} 个"
  if [ -n "$fail_list" ]; then
    tg_add_section msg "❌ 失败清单"
    tg_add_block msg "$fail_list"
  fi
  tg_add_note msg "源端已按目标端镜像（多余文件已删除）；目标端全程只读，失败条目可直接重跑补齐。"
  send_telegram_message "$msg"
  echo "=== 镜像恢复完成: ok=${total_ok} skip=${total_skip} fail=${total_fail} ==="
}
