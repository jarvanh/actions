#!/bin/bash
# ===== 共享脚本：Telegram 统一通知发送层 + 排版助手 =====
# 规范唯一真源: docs/telegram-notify.md（版式模板/收尾区/禁止事项/检查清单，
# 改版式先改文档再同步实现）。所有 Telegram 通知（workflows 内联 +
# scripts/telegram 下脚本）统一经本文件发送：
#   - parse_mode=HTML，动态内容必须经 escape_html 转义（tg_* 助手已内置）
#   - HTML 解析失败（400 can't parse entities）直接报错、不重发：消息本来就没发出去，
#     退化纯文本只会把版式 bug 藏起来；动态内容一律经 tg_* 助手转义即可避免
#   - 429 限流按 retry_after 等待重试；长消息按 4000 字符分片（断在换行处，
#     不切 UTF-8 多字节字符）
# 用法: source tg_notify.sh
# 目录职责: 本目录 = 通知域（bash 真源 tg_notify.sh，pwsh 真源 tg_notify.ps1）。
#   Telegram 频道内容管线（同步/上传/去重/清理）见 scripts/tg-channel/ ——
#   它与本文件是单向依赖: tg-channel/ 只 source 本文件，本文件不反向引用。
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#   （历史名 TG_BOT_TOKEN / TG_CHAT_ID 自动兼容——见下方别名回退）
# 收尾接线（可选，缺席时 tg_add_footer 优雅降级）:
#   TG_RUN_URL        运行日志链接（workflow 注入 https://github.com/<repo>/actions/runs/<id>）
#   TG_RUN_STARTED_AT run 起始 ISO 时间（历史由 workflow 注入 ${{ github.run_started_at }}；
#     该表达式上下文已从平台移除，注入后通常为空值，故时长实际走 /proc/1 兜底）
# 版式规范（openlist 侧经 load_all.sh L0 层 source 本文件，不再自带副本）:
#   {emoji} <b>标题</b>          ← tg_add_title
#   ━━━━━━━━━━━━━━━━━━           ← TG_SEP（勿手写分隔线）
#   标签：值               ← tg_add_kv / 路径 tg_add_path
#   {emoji} <b>分节 · N</b>       ← tg_add_section（段前空行，紧跟标题时无；列表分节计数一律 " · N"）
#   ├─/└─ 树形条目               ← 唯一条目前缀（tree_lines / tree_code_fold，无平铺形态）
#   <pre>日志</pre>              ← tg_add_block
#   {可选 备注}            ← tg_add_note
#   （空行）⏱ 已运行 X · 🔗 运行日志 ← tg_add_footer（全库唯一收尾形态，自带空行）
# 函数:
#   send_tg <text>                     单条发送（短消息用）
#   send_tg_chunked <text>             分片发送（长消息用）
#   escape_html / tg_append / tg_add_title / tg_add_kv / tg_add_path /
#   tg_add_section / tg_add_note / tg_add_block / tg_add_footer
#   tree_conn / tree_sub / tree_lines / tree_code_fold（树形条目与折叠）

# bash 5.2+ patsub_replacement 会破坏 escape_html 的实体替换（"&" 被当作匹配
# 文本引用），旧 bash 无此选项，shopt 报错被吞（与 openlist/utils.sh 同款防护）
shopt -u patsub_replacement 2>/dev/null || true

# 凭据变量名兼容：本层真源是 TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID，但历史上
# 部分调用方（如 emby.yml watchdog）注入的是 TG_BOT_TOKEN / TG_CHAT_ID——名字
# 错接时 chat_id 为空、API 400、再被调用方的 || true 吞掉 = 通知静默消失
# （2026-09-05 审计发现）。这里做一次性别名回退，调用方两种名字都能用。
: "${TELEGRAM_BOT_TOKEN:=${TG_BOT_TOKEN:-}}"
: "${TELEGRAM_CHAT_ID:=${TG_CHAT_ID:-}}"

# ===== 排版助手 =====

# HTML 实体转义（用于 HTML parse_mode 消息）
escape_html() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  echo "$s"
}

# 统一分隔线（18 个全角横线）
TG_SEP='━━━━━━━━━━━━━━━━━━'

# 追加原始文本到消息变量（不做任何转义/格式化）
tg_append() {
  printf -v "$1" '%s%s' "${!1}" "$2"
}

# 拆出前导 emoji 序列（含 VS16/ZWJ/keycap）——emoji 不入 <b>（2026-09-10 拍板），
# 真源自动拆分，调用方仍传「emoji + 短语」整串、无需感知。
# 输出两行: 第一行=前导 emoji（可为空），第二行=剩余文字
_split_leading_emoji() {
  printf '%s' "$1" | perl -CSD -ne '
    if (/^((?:[\x{2100}-\x{2BFF}\x{1F000}-\x{1FAFF}\x{FE0F}\x{200D}\x{20E3}])+)\s*(.*)\z/s) { print "$1\n$2"; }
    else { print "\n$_"; }
  '
}

# 标题块: "{emoji} <b>标题文字</b>\n分隔线\n"（emoji 在 <b> 外）
tg_add_title() {
  local _split _e _t
  _split=$(_split_leading_emoji "$2") || _split=$'\n'"$2"
  _e="${_split%%$'\n'*}"
  _t="${_split#*$'\n'}"
  tg_append "$1" "${_e:+$_e }<b>$(escape_html "$_t")</b>"$'\n'"${TG_SEP}"$'\n'
}

# 键值行（值不再加粗，2026-09-09 拍板：结论值/状态/计数/数值一律裸文本加转义，
# <b> 只留给标题/分节/组头/条目主体；标签后的全角冒号 + 空格已足够分隔）
tg_add_kv() {
  tg_append "$1" "$2：$(escape_html "$3")"$'\n'
}

# 键值行（路径/版本/命令等宽展示）: "标签：<code>值</code>\n"
tg_add_path() {
  tg_append "$1" "$2：<code>$(escape_html "$3")</code>"$'\n'
}

# 分节标题: "\n{标题（含 emoji）加粗}\n"（段前空一行与上一区块分隔）
# 段前空行的两个例外:
#   1. 紧跟标题时（消息以 "分隔线\n" 结尾）—— 否则视觉上等于"分隔线自带空行"，
#      与全库"分隔线后不空行"冲突（任务预览 / openclaw·tailscale 入口通知的首个分节即此形态）
#   2. 空消息（首个分节）—— 消息开头不需要空行
# 另: 正文无尾换行时（手拼变量，如 emby.yml 播放通知的 text）先补一个再进分节 ——
#   否则下面的 \n 只给正文末行收尾，段前空行消失（与 tg_add_footer 同款处理）
tg_add_section() {
  case "${!1}" in
    ''|*"${TG_SEP}"$'\n') ;;
    *$'\n') tg_append "$1" $'\n' ;;
    *) tg_append "$1" $'\n'$'\n' ;;
  esac
  local _split _e _t
  _split=$(_split_leading_emoji "$2") || _split=$'\n'"$2"
  _e="${_split%%$'\n'*}"
  _t="${_split#*$'\n'}"
  tg_append "$1" "${_e:+$_e }<b>$(escape_html "$_t")</b>"$'\n'
}

# 说明段（段前空一行；不再套 ，2026-09-09 全库去掉斜体标签）
# 段前空行的例外与 tg_add_section 完全一致（紧跟分隔线 / 空消息不补；正文无尾换行先补）
tg_add_note() {
  case "${!1}" in
    ''|*"${TG_SEP}"$'\n') ;;
    *$'\n') tg_append "$1" $'\n' ;;
    *) tg_append "$1" $'\n'$'\n' ;;
  esac
  tg_append "$1" "$(escape_html "$2")"$'\n'
}

# 追加多行文本块并保证段尾换行
tg_add_block() {
  tg_append "$1" "$2"
  case "$2" in
    *$'\n') ;;
    *) tg_append "$1" $'\n' ;;
  esac
}

# 统一收尾区（全库唯一收尾形态，自带与正文间的空行）:
#   "\n⏱ 已运行 <b>X 小时 Y 分</b> · 🔗 <a href="TG_RUN_URL">运行日志</a>\n"
# 时长来源优先级:
#   1. TG_RUN_STARTED_AT（workflow 注入，精确）
#   2. /proc/1 启动时刻兜底 —— GitHub 平台已于 2026-09-05 移除 github.run_started_at
#      表达式上下文（API 字段仍在），hosted runner 的 PID 1 随 job 启动，误差秒级
# 降级链: 无 TG_RUN_STARTED_AT 且无 /proc/1 → 不显示时长；无 TG_RUN_URL → 整行跳过
# 附加链接: tg_add_footer <var> ["标签" "URL"]... → 追加 " · 🔗 <a>标签</a>"
# 注意: <var> 必须是已积累正文的消息变量（原地追加）。勿用"中间空变量接 footer 再拼到
# 正文"的两步写法——补尾换行检查的是 <var> 自身，空变量会跳过补换行，空行丢失。
tg_add_footer() {
  local var="$1"
  shift
  local line="" elapsed=0
  if [ -n "${TG_RUN_STARTED_AT:-}" ]; then
    local started
    started=$(date -d "${TG_RUN_STARTED_AT}" +%s 2>/dev/null || echo 0)
    [ "$started" -gt 0 ] && elapsed=$(( $(date +%s) - started ))
  elif [ -r /proc/1 ]; then
    local p1ts
    p1ts=$(stat -c %Y /proc/1 2>/dev/null || echo 0)
    [ "${p1ts:-0}" -gt 0 ] && elapsed=$(( $(date +%s) - p1ts ))
  fi
  if [ "$elapsed" -gt 0 ]; then
    local mins=$((elapsed / 60)) dur
    if [ "$mins" -ge 60 ]; then
      dur="$((mins / 60)) 小时 $((mins % 60)) 分"
    elif [ "$mins" -gt 0 ]; then
      dur="${mins} 分钟"
    else
      dur="${elapsed} 秒"
    fi
    line="⏱ 已运行 ${dur}"
  fi
  if [ -n "${TG_RUN_URL:-}" ]; then
    [ -n "$line" ] && line+=" · "
    line+="🔗 <a href=\"$(escape_html "${TG_RUN_URL}")\">运行日志</a>"
    while [ $# -ge 2 ]; do
      line+=" · 🔗 <a href=\"$(escape_html "$2")\">$(escape_html "$1")</a>"
      shift 2
    done
  fi
  [ -z "$line" ] && return 0
  # 收尾区规范形态 = 与正文间固定一个空行。对"正文是否以换行结尾"不作要求：
  # 缺尾换行时先补一个，否则下面的 \n 只是给正文末行收尾，空行会消失
  local cur="${!var}"
  case "$cur" in
    ''|*$'\n') ;;
    *) tg_append "$var" $'\n' ;;
  esac
  tg_append "$var" $'\n'"${line}"$'\n'
}

# 树形条目前缀: tree_conn <0|1 是否末条> → "  ├─ " / "  └─ "
# openlist 的 task_preview / sync_progress 等直接调用（2026-09-06 从 openlist/utils.sh
# 收敛至此——此前 utils.sh 删副本时漏迁，导致任务预览通知树形连接符全丢、粘成一坨）
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
  _total=$(printf '%s\n' "$_in" | { grep -c . || true; })
  [ "$_total" -eq 0 ] && return 0
  while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    _n=$((_n + 1))
    local _last=0
    [ "$_n" -eq "$_total" ] && _last=1
    if [ "$_last" = "1" ]; then _out+="  └─ ${_line}"$'\n'; else _out+="  ├─ ${_line}"$'\n'; fi
  done <<< "$_in"
  printf '%s' "${_out%$'\n'}"
}

# 文件列表渲染一站式：逐行 <code>转义</code> → 超过 max 行折叠"还有 N 条…"
# （折叠行并入条目流，末条 └─ 由 tree_lines 统一决定，禁双 └─）→ tree_lines。
# 用法: tree_code_fold <多行文本> [每组上限，默认 8]
# 输入必须是未转义的裸行；动态文件名含 & < > 时未转义会触发 400、整条发送失败（不重发）
tree_code_fold() {
  local _in="$1" _max="${2:-8}" _total _entries="" _l _n=0
  _total=$(printf '%s\n' "$_in" | { grep -c . || true; })
  [ "${_total:-0}" -eq 0 ] && return 0
  while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    _n=$((_n + 1))
    [ "$_n" -gt "$_max" ] && break
    _entries+="<code>$(escape_html "$_l")</code>"$'\n'
  done <<< "$_in"
  if [ "$_total" -gt "$_max" ]; then
    _entries+="还有 $((_total - _max)) 条…"$'\n'
  fi
  tree_lines "$_entries"
}

# ===== 发送层 =====

# 单次发送尝试（429 自动重试；其余失败直接返回非 0 并输出错误信息）
# 退出码: 0 成功 / 2 HTML 解析失败（can't parse entities）/ 1 其他失败
_tg_send_once() {
  local text="$1" parse_mode="$2"
  local resp retry_after attempt max_attempts=5
  for attempt in $(seq 1 "$max_attempts"); do
    if [ -n "$parse_mode" ]; then
      resp=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" \
        -d "parse_mode=${parse_mode}" 2>&1)
    else
      resp=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" 2>&1)
    fi
    if echo "$resp" | grep -q '"ok":true'; then
      return 0
    fi
    # 429 限流: 按 retry_after 等待后重试
    retry_after=$(echo "$resp" | grep -oE '"retry_after":[0-9]+' | head -1 | cut -d: -f2)
    if [ -n "$retry_after" ]; then
      echo "⚠️ Telegram 限流 (429)，等待 ${retry_after}s 后重试 (尝试 $attempt/$max_attempts)..." >&2
      sleep "$retry_after"
      continue
    fi
    # HTML 解析失败: 不退化重发（消息本就没发出去，退化只会把版式 bug 藏起来），
    # 直接报错暴露——动态内容一律经 tg_add_* 助手转义即可避免
    if echo "$resp" | grep -q "can't parse entities"; then
      echo "❌ Telegram HTML 解析失败（400 can't parse entities），消息未发送: $(echo "$resp" | head -c 200)" >&2
      return 2
    fi
    echo "⚠️ Telegram 通知发送失败: $(echo "$resp" | head -c 200)" >&2
    return 1
  done
  echo "⚠️ Telegram 通知发送失败（重试 $max_attempts 次仍失败）: $(echo "$resp" | head -c 200)" >&2
  return 1
}

# 单条发送（HTML parse_mode；429 自动重试，其余失败直接返回非 0 并在 stderr 输出错误）
send_tg() {
  local text="$1"
  [ -z "$text" ] && return 0
  _tg_send_once "$text" "HTML"
}

# 按 4000 字符分片，尽量在换行处断开，避免切断 UTF-8 多字节字符
send_tg_chunked() {
  local text="$1"
  [ -z "$text" ] && return 0
  local delay="${TG_CHUNK_DELAY:-2}"
  printf '%s' "$text" | python3 -c '
import sys
data = sys.stdin.read()
chunk_size = 4000
chunks = []
i = 0
n = len(data)
while i < n:
    end = min(i + chunk_size, n)
    if end < n:
        last_nl = data.rfind("\n", i, end)
        if last_nl > i + chunk_size // 2:
            end = last_nl + 1
    chunks.append(data[i:end])
    i = end
try:
    for idx, c in enumerate(chunks, 1):
        sys.stderr.write(f"--- 发送分片 {idx}/{len(chunks)} ({len(c)} 字符) ---\n")
        sys.stdout.write(c + "\x00")
        sys.stdout.flush()
except BrokenPipeError:
    pass
' | while IFS= read -r -d "" chunk; do
    send_tg "$chunk" || true
    sleep "$delay"
  done
}

# 凭据/密码类消息（如 OpenList 改密回执）不需要单独的发送函数：
# 用 tg_add_* 助手构建（密码走 tg_add_path，自动 escape_html）后一律 send_tg。
# 不要为凭据自造"单发不重试"通道 —— 429 与 400 都表示上一条没被 Telegram 接收，
# 重试/退化不会产生两条密码；反过来放弃重试会让凭据在限流时直接丢失。
