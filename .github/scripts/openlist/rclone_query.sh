#!/bin/bash
# ===== OpenList 同步工具 — rclone 查询与过滤参数解析 =====
#
# 职责边界:
#   - rclone 查询类: size --json 调用、字段解析、路径统计
#   - 过滤参数提取: 从 sync 参数串中剥离出 lsf 等子命令可接受的过滤类参数
#     （lsf 不接受 --delete-before/--no-traverse 等 sync 特有参数，
#      不剥离会导致 lsf 报错或过滤口径与实际 sync 不一致）
#
# 依赖: utils.sh (format_bytes)
# 被依赖: sync_marker.sh, task_engine.sh, task_preview.sh, sync_engine.sh

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
# ===== 源端缩小检测 · 按扩展名分层统计 =====
# 为什么需要分层: 总量口径无法区分「元数据重写」与「正片损坏」——
#   Emby 刮削器批量重写 .nfo 会让总字节数上下抖动几 B ~ 几 KB（纯文本，评分/
#   ID/空行微调），这与「正片被删/损坏」是两种性质，但总量上都表现为"减小"。
#   因此缩小是否告警，要看减少量**落在哪一类文件上**:
#     meta 类（纯文本元数据/字幕）减少 → 正常变动，放行并刷新基线
#     payload 类（正片/图片/压缩包等二进制）减少 → 潜在损坏或被删，必须告警
#
# 抖动容忍类扩展名（可经 SYNC_SHRINK_META_EXTS 覆盖，空格分隔、大小写不敏感）:
#   仅收**纯文本** —— nfo/xml/json 是刮削元数据，srt/ass/sub 是字幕（同样会被
#   重新刮削/校对改写）。图片(jpg/png)虽也会被刮削替换，但替换为二进制重编码、
#   字节变化幅度大且不可预期，归入 payload 从严处理。
SYNC_SHRINK_META_EXTS="${SYNC_SHRINK_META_EXTS:-nfo xml json srt ass ssa sub idx txt db ini log csv yaml yml md}"

# 一次性列举远端并把字节数按「meta / payload」两类汇总
# 输出 JSON: {"meta":N,"payload":M,"count":C}；列举失败或空目录输出空串（调用方
#  须把空串与 0 区分开，空串 = 无法判定，走保守路径）
# 用法: _rclone_class_bytes_json <path> [filter_args...]
_rclone_class_bytes_json() {
  local path="$1"
  shift
  local listing
  listing=$(rclone lsjson "$path" --recursive --files-only --no-mimetype --no-modtime "$@" 2>/dev/null) || return 0
  [ -z "$listing" ] && return 0
  printf '%s' "$listing" | jq -c --arg exts "$SYNC_SHRINK_META_EXTS" '
    ($exts | split(" ") | map(select(length > 0)) | map(ascii_downcase)) as $m
    | (map(select((.IsDir // false) | not))) as $files
    | (reduce $files[] as $f ({meta: 0, payload: 0};
         (($f.Path | split(".")) | if length > 1 then (last | ascii_downcase) else "" end) as $e
         | if ($m | index($e)) != null then .meta += ($f.Size // 0)
           else .payload += ($f.Size // 0) end))
    | . + {count: ($files | length)}
  ' 2>/dev/null || echo ""
}

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
