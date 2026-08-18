#!/bin/bash
# ===== OpenList 同步工具 — 通用工具函数 =====
# 本文件提供基础工具函数，被其他脚本文件依赖。
# 所有函数通过 load_all.sh 统一加载。

# bash 5.2+ 默认开启 patsub_replacement: ${var//pat/rep} 的 rep 中 "&" 表示
# 匹配文本，会让下方 escape_html 把 "<" 替换成 "<lt;"（实体里的 & 被吃掉），
# Telegram HTML 渲染随之损坏。关闭该选项恢复 bash 5.1 及更早的字面量语义；
# 旧 bash/zsh 无此选项，shopt 报错被吞，不影响加载。
shopt -u patsub_replacement 2>/dev/null || true

# HTML 实体转义（用于 HTML parse_mode 消息）
escape_html() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  echo "$s"
}

# 检查日志文件是否包含实质内容（排除 rclone 统计行和空行）
# 返回值: "empty" / "transfer_only" / "has_content"
check_log_has_content() {
  local log_file="$1"
  if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
    echo "empty"
    return
  fi
  local log_content
  log_content=$(grep -v "^Transferred:\|^Checks:\|^Elapsed time:\|^ *$" "$log_file" 2>/dev/null | head -20)
  if [ -z "$log_content" ]; then
    echo "transfer_only"
  else
    echo "has_content"
  fi
}

# 修复日志记录函数（独立于分割日志，用于缺失文件修复过程）
# 文件落时间戳；控制台不再重复前缀时间戳（GitHub Actions 每行自带），
# 行首越短越可读
log_fix() {
  local log_file="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$log_file" 2>/dev/null || true
  echo "$message"
}

# 统一的分割日志记录函数（同时输出到日志文件和 stdout）
# 注意：不仅用于视频分割，也用于非视频 7z 分卷，名称中的 "split" 为通用含义。
log_split() {
  log_fix "$@"
}

# 分节横幅（控制台+文件同写）: 视觉切分长日志的不同阶段
# 用法: _sec <log_file> <标题>
_sec() {
  local log_file="$1" title="$2"
  local line n
  n=$((72 - ${#title} - 5))
  [ "$n" -lt 1 ] && n=1
  line="$(printf '─── %s ' "$title"; printf '─%.0s' $(seq 1 "$n"))"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line" >> "$log_file" 2>/dev/null || true
  echo "$line"
}

# 长路径缩短显示: 保留目录前缀 + 文件名，超长时目录中间省略
# 仅用于日志展示（决策信息保留 basename），marker/黑名单仍存全路径
# 用法: _short_path <path> [max_len=56]
_short_path() {
  local p="${1:-}" max="${2:-56}"
  [ -z "$p" ] && echo "?" && return 0
  if [ "${#p}" -le "$max" ]; then echo "$p"; return 0; fi
  local base dir keep
  base="$(basename -- "$p")"
  dir="$(dirname -- "$p")"
  keep=$(( max - ${#base} - 2 ))
  if [ "$keep" -lt 6 ]; then
    # 文件名自身太长: 目录 + … + 文件名尾部（保留目录上下文）
    local tail_len=$(( max - ${#dir} - 3 ))
    if [ "$dir" = "." ] || [ "$tail_len" -lt 8 ]; then
      echo "…${base: -$((max - 1))}"
    else
      echo "${dir}/…${base: -$tail_len}"
    fi
    return 0
  fi
  echo "${dir:0:$keep}…/$base"
}

# 从 rclone 日志中解析传输字节数
# 解析 "Transferred: 1.234 GiB" 格式的行，返回字节数（整数）
get_transferred_bytes_from_log() {
  local log_file="$1"
  local line
  line=$(grep 'Transferred:' "$log_file" 2>/dev/null | tail -1)
  if [ -z "$line" ]; then
    echo 0
    return
  fi
  # 提取第一个大小值，如 "1.234 GiB" 或 "0 B"
  local size_str
  size_str=$(echo "$line" | sed -n 's/.*Transferred:[[:space:]]*\([0-9.]*[[:space:]]*[KMGTPEZY]iB\).*/\1/p')
  if [ -z "$size_str" ]; then
    size_str=$(echo "$line" | sed -n 's/.*Transferred:[[:space:]]*\([0-9.]*[[:space:]]*B\).*/\1/p')
  fi
  if [ -z "$size_str" ]; then
    echo 0
    return
  fi
  local num unit
  num=$(echo "$size_str" | awk '{print $1}')
  unit=$(echo "$size_str" | awk '{print $2}')
  case "$unit" in
    KiB) awk "BEGIN {printf \"%d\", $num * 1024}" ;;
    MiB) awk "BEGIN {printf \"%d\", $num * 1048576}" ;;
    GiB) awk "BEGIN {printf \"%d\", $num * 1073741824}" ;;
    TiB) awk "BEGIN {printf \"%d\", $num * 1099511627776}" ;;
    PiB) awk "BEGIN {printf \"%d\", $num * 1125899906842624}" ;;
    B)   awk "BEGIN {printf \"%d\", $num}" ;;
    *) echo 0 ;;
  esac
}

# 格式化字节数为人类可读字符串（如 "1.234 GiB"）
format_bytes() {
  local bytes="$1"
  if [ "$bytes" -ge 1125899906842624 ]; then
    awk "BEGIN {printf \"%.3f PiB\", $bytes / 1125899906842624}"
  elif [ "$bytes" -ge 1099511627776 ]; then
    awk "BEGIN {printf \"%.3f TiB\", $bytes / 1099511627776}"
  elif [ "$bytes" -ge 1073741824 ]; then
    awk "BEGIN {printf \"%.3f GiB\", $bytes / 1073741824}"
  elif [ "$bytes" -ge 1048576 ]; then
    awk "BEGIN {printf \"%.3f MiB\", $bytes / 1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    awk "BEGIN {printf \"%.3f KiB\", $bytes / 1024}"
  else
    echo "${bytes} B"
  fi
}

# IEC 格式字节数（等价 numfmt --to=iec-i --suffix=B，失败回退 "${bytes}B"）
# 与 format_bytes 的 "1.000 GiB" 风格不同，本函数输出 "1.0GiB"，用于既有日志格式
format_bytes_iec() {
  local bytes="$1"
  numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# base64URL 编码（+/ → -_，去掉 = 填充）
b64url_encode() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '='
}

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
  check_combined=$(timeout 300 rclone check "$source_path" "$dest_path" --size-only "${extra_args[@]}" --combined - 2>/dev/null || true)
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

# 截断过长的路径用于流量图显示
# 用法: _shorten_path <path> [max_len]
_shorten_path() {
  local p="$1"
  local max_len="${2:-50}"
  if [ ${#p} -gt "$max_len" ]; then
    echo "...${p: -$((max_len - 3))}"
  else
    echo "$p"
  fi
}

# 提取 --exclude 摘要（用于预览显示，逗号分隔）
_extract_exclude_summary() {
  local extra_args=("$@")
  local summary=""
  local j=0
  while [ $j -lt ${#extra_args[@]} ]; do
    if [ "${extra_args[$j]}" = "--exclude" ] && [ $((j+1)) -lt ${#extra_args[@]} ]; then
      if [ -n "$summary" ]; then
        summary+=", "
      fi
      summary+="${extra_args[$((j+1))]}"
    fi
    j=$((j+1))
  done
  echo "$summary"
}

# 获取 OpenList token（多路径 + 双字段查找）
# 与 workflow 里的候选路径保持一致
# （数据库本地化后 config.json 在 /opt/openlist-data，旧路径保留兜底）
# 返回: token 字符串（找到时）或空字符串（未找到时）
_get_openlist_token() {
  local c t
  for c in \
    "/opt/openlist-data/config.json" \
    "/dropbox/self-hosted/openlist/data/config.json" \
    "/dropbox/self-hosted/openlist/data/conf/config.json" \
    "/data/openlist/data/config.json" \
    "/tmp/openlist_data/config.json"; do
    [ -f "$c" ] || continue
    t=$(jq -r '.token // .jwt_secret // empty' "$c" 2>/dev/null || echo "")
    if [ -n "$t" ] && [ "$t" != "null" ]; then
      echo "$t"
      return 0
    fi
  done
  return 1
}

# 等待 OpenList 就绪（容器刚启动时 401/429 会导致预览 0 B/0 文件、同步无谓重传）
# 注意：不能用 rclone lsd 反复探测，会触发后端 429 Too Many Requests
wait_openlist_ready() {
  local i code c t
  # 阶段1: HTTP /ping 起来
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5244/ping 2>/dev/null || echo "000")
    [ "$code" = "200" ] && break
    sleep 2
  done
  if [ "$code" != "200" ]; then
    echo "⚠️ OpenList HTTP 未就绪 (code=${code})"
    return 1
  fi
  echo "HTTP 就绪，尝试获取 token..."
  # 阶段2: 获取 token 用于 API 探测（多个候选路径）
  local OL_TOKEN=""
  for c in \
    "/opt/openlist-data/config.json" \
    "/dropbox/self-hosted/openlist/data/config.json" \
    "/dropbox/self-hosted/openlist/data/conf/config.json" \
    "/data/openlist/data/config.json"; do
    [ -f "$c" ] || continue
    t=$(jq -r '.token // .jwt_secret // empty' "$c" 2>/dev/null || echo "")
    if [ -n "$t" ] && [ "$t" != "null" ]; then
      OL_TOKEN="$t"
      echo "  token: OK (来自 ${c}, 长度 ${#OL_TOKEN})"
      break
    fi
  done
  # 阶段3: 等驱动初始化（长等待 120s，给 ali + crypt 拉元数据）
  echo "等待驱动初始化 (120s) ..."
  sleep 120
  # 阶段4: 单次 rclone 验证（最多 3 次，避免 429）
  if rclone lsd openlist: >/dev/null 2>&1; then
    echo "WebDAV(rclone) 验证通过"
    return 0
  fi
  echo "再等 90s ..."
  sleep 90
  if rclone lsd openlist: >/dev/null 2>&1; then
    echo "WebDAV(rclone) 验证通过（第二次）"
    return 0
  fi
  sleep 60
  rclone lsd openlist: >/dev/null 2>&1 \
    && { echo "WebDAV(rclone) 验证通过（第三次）"; return 0; } \
    || echo "⚠️ WebDAV 仍未就绪，继续执行"
  return 1
}

# 初始化同步会话状态（计数器/日志名/进度系统）
# 变量不加 local，故意写入调用方 shell（各 step source 后直接调用）
init_sync_state() {
  PROCESSED_FILES_LOG="processed_videos.log"
  SYNC_SKIP_QUIET=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0
  SYNC_TRANSFERRED_BYTES=0
  AUTO_SPLIT_INFO=""
  SYNC_AUTO_SPLIT_DEPTH=0
  # 初始化全局进度通知（任务在预览阶段自动注册）
  progress_init
}
