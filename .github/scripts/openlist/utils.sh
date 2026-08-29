#!/bin/bash
# ===== OpenList 同步工具 — 通用工具函数 =====
# 本文件只放与业务无关的通用工具：字符串转义、树形列表渲染、日志内容判定、
# 字节数格式化、base64URL 编码。
#
# 领域函数已按职责拆出，勿再往本文件堆放业务逻辑:
#   - rclone 查询与过滤参数解析 → rclone_query.sh
#   - OpenList 服务访问（管理面登录/就绪等待） → openlist_api.sh
#
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

# ===== 树形列表渲染（Telegram 通知统一风格）=====
# 多条目分组列表统一树形层级（├─/└─ 连接符标记条目边界，组间空行分隔，
# 路径/目录类组头加 📁 前缀），模板规则见 telegram.sh 头部注释;
# 单行平铺列表（排除规则等无层级条目）仍用 "• " 前缀。

# 树形条目前缀: tree_conn <0|1 是否末条> → "  ├─ " / "  └─ "
tree_conn() {
  if [ "$1" = "1" ]; then printf '  └─ '; else printf '  ├─ '; fi
}

# 树形条目子行前缀（内容对齐条目文本）: tree_sub <0|1 是否末条> → "  │   " / "      "
tree_sub() {
  if [ "$1" = "1" ]; then printf '      '; else printf '  │   '; fi
}

# 多行单行条目 → 树形条目列表（每行 "  ├─/└─ 条目"，末条 └─；输出去尾换行）
# 用法: tree_lines <多行文本>（每行一个条目，条目内容需已转义/含 HTML 标签）
tree_lines() {
  local _in="$1" _total _n=0 _line _out=""
  # grep -c 空输入时输出 0 但 rc=1, pipefail 下会传染调用语句
  _total=$(printf '%s\n' "$_in" | { grep -c . || true; })
  [ "$_total" -eq 0 ] && return 0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _n=$((_n + 1))
    local _last=0
    [ "$_n" -eq "$_total" ] && _last=1
    _out+="$(tree_conn "$_last")${_line}"$'\n'
  done <<< "$_in"
  printf '%s' "${_out%$'\n'}"
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

# 统一的双通道日志函数（修复/分割/下载等过程共用）
# 文件落时间戳；控制台不再重复前缀时间戳（GitHub Actions 每行自带），
# 行首越短越可读
log_fix() {
  local log_file="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$log_file" 2>/dev/null || true
  echo "$message"
}

# 分节横幅（控制台+文件同写）: 视觉切分长日志的不同阶段
# 用法: _log_section <log_file> <标题>
_log_section() {
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
  # 优先匹配多行汇总块的 "Transferred:" 行（最终 stats）
  line=$(grep 'Transferred:' "$log_file" 2>/dev/null | tail -1)
  local size_str=""
  if [ -n "$line" ]; then
    size_str=$(echo "$line" | sed -n 's/.*Transferred:[[:space:]]*\([0-9.]*[[:space:]]*[KMGTPEZY]iB\).*/\1/p')
    [ -z "$size_str" ] && size_str=$(echo "$line" | sed -n 's/.*Transferred:[[:space:]]*\([0-9.]*[[:space:]]*B\).*/\1/p')
  fi
  # 兼容 --stats-one-line --progress 格式: 动态刷新行没有 Transferred: 前缀，
  # 形如 "... :  164.484 MiB / 18.378 GiB, 1%, 32.897 MiB/s, ETA ..."，
  # 要取的是 "X / Y" 对中的已传段 —— 用 "X / " 且下一字段是总量的模式:
  # grep -oE 提取所有 "NUM UNIT / NUM UNIT," 对，取已传段；排除 MiB/s 速度段
  # （速度段的特征是后随 s, 而不是数字）
  if [ -z "$size_str" ]; then
    size_str=$(grep -aoE '[0-9.]+[[:space:]]+[KMGTPEZY]?iB[[:space:]]*/[[:space:]]*[0-9.]+[[:space:]]+[KMGTPEZY]?iB' "$log_file" 2>/dev/null | tail -1 | grep -oE '^[0-9.]+[[:space:]]+[KMGTPEZY]?iB')
    [ -z "$size_str" ] && size_str=$(grep -aoE '[0-9.]+[[:space:]]+B[[:space:]]*/[[:space:]]*[0-9.]+[[:space:]]+[KMGTPEZY]?iB' "$log_file" 2>/dev/null | tail -1 | grep -oE '^[0-9.]+[[:space:]]+B')
  fi
  if [ -z "$size_str" ]; then
    echo 0
    return
  fi
  local num unit
  num=$(echo "$size_str" | awk '{print $1}')
  unit=$(echo "$size_str" | awk '{print $2}')
  case "$unit" in
    KiB) awk "BEGIN {printf \"%.0f\", $num * 1024}" ;;
    MiB) awk "BEGIN {printf \"%.0f\", $num * 1048576}" ;;
    GiB) awk "BEGIN {printf \"%.0f\", $num * 1073741824}" ;;
    TiB) awk "BEGIN {printf \"%.0f\", $num * 1099511627776}" ;;
    PiB) awk "BEGIN {printf \"%.0f\", $num * 1125899906842624}" ;;
    B)   awk "BEGIN {printf \"%d\", $num}" ;;
    *) echo 0 ;;
  esac
}

# 格式化字节数为人类可读字符串（如 "1.234 GiB"）
format_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u)
    for(i=1; b>=1024 && i<6; i++) b/=1024
    if(i==1) printf "%d %s\n", b, u[i]
    else printf "%.3f %s\n", b, u[i]
  }'
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
