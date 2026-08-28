#!/bin/bash
# ===== OpenList 同步工具 — rclone 查询与过滤参数解析 =====
#
# 职责边界:
#   - rclone 查询类: size --json 调用、字段解析、路径统计、check 差异比对
#   - 过滤参数提取: 从 sync 参数串中剥离出 lsf 等子命令可接受的过滤类参数
#     （lsf 不接受 --delete-before/--no-traverse 等 sync 特有参数，
#      不剥离会导致 lsf 报错或过滤口径与实际 sync 不一致）
#
# 依赖: utils.sh (format_bytes)
# 被依赖: marker.sh, tasks.sh, preview.sh, sync.sh

# 调用 rclone size --json，输出原始 JSON（失败输出空）；额外参数原样透传
_rclone_size_json() {
  local path="$1"
  shift
  rclone size "$path" --json "$@" 2>/dev/null || true
}

# 从 rclone size --json 输出中解析字段（bytes/count），失败/空输入回退 0
_size_json_field() {
  local v
  v=$(echo "${1:-}" | jq -r ".${2} // 0" 2>/dev/null) || v=""
  [ -z "$v" ] && v=0
  echo "$v"
}

# 一次性获取远端路径的 bytes/count/human_size（只调一次 rclone size --json）
# 返回格式: "bytes count human_size"
_get_path_stats() {
  local path="$1"
  shift
  local size_json
  size_json=$(_rclone_size_json "$path" "$@")
  if [ -z "$size_json" ]; then
    echo "0 0 未知"
    return
  fi
  local bytes count
  bytes=$(_size_json_field "$size_json" bytes)
  count=$(_size_json_field "$size_json" count)
  echo "${bytes} ${count} $(format_bytes "$bytes")"
}

# 运行 rclone check 并构建差异文件列表（最多 20 条）
# 返回多行文本，每条格式: "• [差异类型] 文件路径"（与通知 bullet 风格一致）
_build_diff_files_list() {
  local source_path="$1"
  local dest_path="$2"
  shift 2
  local -a extra_args=("$@")
  local check_combined
  check_combined=$(timeout "${OPENLIST_DOWNLOAD_TIMEOUT:-300}" rclone check "$source_path" "$dest_path" --size-only "${extra_args[@]}" --combined - 2>/dev/null || true)
  local result="" diff_count=0
  while IFS= read -r line; do
    local marker="${line:0:1}"
    local fpath="${line:2}"
    case "$marker" in
      +) result+="• [源端有/目标缺失] ${fpath}"$'\n' ;;
      -) result+="• [目标多余/仅目标存在] ${fpath}"$'\n' ;;
      '*') result+="• [大小/内容不一致] ${fpath}"$'\n' ;;
    esac
    diff_count=$((diff_count + 1))
    if [ "$diff_count" -ge 20 ]; then
      result+="... (更多差异文件省略)"$'\n'
      break
    fi
  done <<< "$(echo "$check_combined" | grep -E '^[-+*] ')"
  echo "$result"
}

# 从 extra_args 中提取 --exclude 规则（每行一条 glob 模式，无规则时输出空）
# 模式原样输出（不含 HTML），由调用方决定展示格式与转义
_build_exclude_patterns() {
  local -a extra_args=("$@")
  local result="" i
  for ((i=0; i<${#extra_args[@]}; i++)); do
    if [ "${extra_args[$i]}" == "--exclude" ] && [ $((i+1)) -lt ${#extra_args[@]} ]; then
      result+="${extra_args[$((i+1))]}"$'\n'
    fi
  done
  printf '%s' "$result"
}

# 从 rclone 参数中提取过滤类参数（--exclude/--include 及其值）
# 供 lsf 等不接受 sync/copy 特有参数（--delete-before/--no-traverse 等）的命令使用，
# 保证 lsf diff 的过滤口径与实际 sync 一致
# 结果写入全局数组: FILTER_ARGS
_extract_filter_args() {
  FILTER_ARGS=()
  local i nxt flag
  for ((i=1; i<=$#; i++)); do
    flag="${!i}"
    case "$flag" in
      --exclude|--include)
        nxt=$((i+1))
        if [ "$nxt" -le $# ]; then
          FILTER_ARGS+=("$flag" "${!nxt}")
          i=$nxt
        fi
        ;;
    esac
  done
}

# 提取 --exclude 摘要（用于预览显示，顿号连接）
# 去重: 任务配置常同时传 "/pat" 与 "pat" 两种锚定形式（rclone 语义有别但
# 展示冗余），按去前导 / 的形式去重并展示该写法
_extract_exclude_summary() {
  local extra_args=("$@")
  local -a _pats=()
  declare -A _seen=()
  local j=0 p
  while [ $j -lt ${#extra_args[@]} ]; do
    if [ "${extra_args[$j]}" = "--exclude" ] && [ $((j+1)) -lt ${#extra_args[@]} ]; then
      p="${extra_args[$((j+1))]#/}"
      if [ -z "${_seen[$p]+x}" ]; then
        _seen[$p]=1
        _pats+=("$p")
      fi
    fi
    j=$((j+1))
  done
  local IFS='、'
  echo "${_pats[*]}"
}
