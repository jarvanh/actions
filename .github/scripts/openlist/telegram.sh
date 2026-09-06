#!/bin/bash
# ===== OpenList 同步工具 — Telegram 消息函数 =====
# 规范唯一真源: docs/telegram-notify.md（版式模板/收尾区/禁止事项/检查清单，
# 改版式先改文档再同步实现；本文件与 scripts/telegram/tg_notify.sh 需同步维护）
# 依赖环境变量:
#   TELEGRAM_BOT_TOKEN — Telegram Bot API Token（由 workflow secrets 注入）
#   TELEGRAM_CHAT_ID   — 目标 Chat ID（由 workflow secrets 注入）
#   （历史名 TG_BOT_TOKEN / TG_CHAT_ID 自动兼容——与 tg_notify.sh 同款别名回退）
# 依赖全局变量:
#   PROGRESS_MSG_ID_FILE — 进度消息 ID 存储文件路径
#   PROGRESS_SENT_IDS_LOG — 本轮已发进度消息 id 清单（finalize 兑底清孤儿，sync_progress.sh 定义）
# 依赖函数: utils.sh (escape_html)

# ===== 通知排版助手（统一所有 Telegram 通知的结构与风格）=====
# 统一模板（一律 HTML parse_mode，动态内容必须转义——助手函数已内置）:
#
#   {emoji} <b>标题</b>            ← tg_add_title（emoji + 短语，副标题说明下沉 kv 行）
#   ━━━━━━━━━━━━━━━━━━             ← TG_SEP（单点定义，勿手写分隔线）
#   标签：<b>值</b>                ← 头部键值区（数值 tg_add_kv / 路径 tg_add_path）
#
#   {emoji} <b>分节标题 · N</b>     ← tg_add_section（段前自动空一行；计数一律 " · N"，
#                                    量词并入正文）
#   • 条目                         ← 单行平铺列表统一 "• " 前缀（无层级条目）
#   📁 <b>组头</b> · <i>大小</i>   ← 分组列表: 组头路径加粗，条目内路径才用 <code>
#     ├─ <code>条目</code> · <i>备注</i>  ← 树形连接符 ├─/└─ 标记边界，条目路径 <code>，
#                                          元数据一律 " · <i>…</i>
#     │   子行                     ← 条目子行缩进对齐（末条目子行 6 空格）
#   <b>状态组头</b>                ← 块内状态分组（如"✅ 已同步的子目录"），下接树形条目
#   <pre>块</pre>                  ← 日志/流量图等需对齐的多行内容
#
#   条目内多字段一律用 " · " 分隔（勿用全角冒号/括号堆一行）；
#   数值与状态用 <i>，统计行数值统一 <b>，路径/文件名/模式用 <code>
#   树形渲染助手 tree_conn/tree_sub/tree_lines 定义在 utils.sh（全库共用）
#
#   {emoji} <b>结尾提示</b>         ← 收尾状态（如"已跳过此同步"）
#   斜体说明                        ← tg_add_note
#   （空行）⏱ 已运行 X · 🔗 运行日志 ← tg_add_footer（全库唯一收尾形态：
#                                    收尾区与正文间固定一个空行；读 TG_RUN_URL /
#                                    TG_RUN_STARTED_AT，缺席时优雅降级跳过）
#
# 状态 emoji 语义（全库统一）:
#   ✅ 成功 / ⚠️ 部分失败 / ❌ 失败 / ⏭️ 跳过 / 🔄 进行中 / ⛔ 中断 / 🚨 危险警告

# 统一分隔线（18 个全角横线）
TG_SEP='━━━━━━━━━━━━━━━━━━'

# 凭据变量名兼容（与 tg_notify.sh 同款，两文件同步维护）：历史名自动回退，
# 防止名字错接导致 chat_id 为空、通知静默消失
: "${TELEGRAM_BOT_TOKEN:=${TG_BOT_TOKEN:-}}"
: "${TELEGRAM_CHAT_ID:=${TG_CHAT_ID:-}}"

# 追加原始文本到消息变量（不做任何转义/格式化）
# 用法: tg_append <var> <text>
tg_append() {
  printf -v "$1" '%s%s' "${!1}" "$2"
}

# 追加多行文本块并保证段尾换行（"无" 等单行内容无自带换行时补齐，
# 保证后续 tg_add_section 的段前空行生效）
# 用法: tg_add_block <var> <文本块>
tg_add_block() {
  tg_append "$1" "$2"
  case "$2" in
    *$'\n') ;;
    *) tg_append "$1" $'\n' ;;
  esac
}

# 标题块: "{标题（含 emoji）加粗}\n分隔线\n"
# 用法: tg_add_title <var> "⚠️ 标题文本"
tg_add_title() {
  tg_append "$1" "<b>$(escape_html "$2")</b>"$'\n'"${TG_SEP}"$'\n'
}

# 键值行（关键值加粗）: "标签：<b>值</b>\n"
# 用法: tg_add_kv <var> <标签> <值>
tg_add_kv() {
  tg_append "$1" "$2：<b>$(escape_html "$3")</b>"$'\n'
}

# 键值行（路径等宽展示）: "标签：<code>值</code>\n"
# 用法: tg_add_path <var> <标签> <值>
tg_add_path() {
  tg_append "$1" "$2：<code>$(escape_html "$3")</code>"$'\n'
}

# 分节标题（段前空一行）: "\n{标题（含 emoji）加粗}\n"
# 用法: tg_add_section <var> "📁 分节标题"
tg_add_section() {
  tg_append "$1" $'\n'"<b>$(escape_html "$2")</b>"$'\n'
}

# 斜体说明（段前空一行，常用于收尾备注）: "\n<i>说明</i>\n"
# 用法: tg_add_note <var> "说明文字"
tg_add_note() {
  tg_append "$1" $'\n'"<i>$(escape_html "$2")</i>"$'\n'
}

# 统一收尾区（全库唯一收尾形态，自带与正文间的空行）:
#   "\n⏱ 已运行 <b>X 小时 Y 分</b> · 🔗 <a href="TG_RUN_URL">运行日志</a>\n"
# 时长来源优先级:
#   1. TG_RUN_STARTED_AT（workflow 注入，精确）
#   2. /proc/1 启动时刻兜底 —— GitHub 平台已于 2026-09-05 移除 github.run_started_at
#      表达式上下文（API 字段仍在），hosted runner 的 PID 1 随 job 启动，误差秒级
# 降级链: 无 TG_RUN_STARTED_AT 且无 /proc/1 → 不显示时长；无 TG_RUN_URL → 整行跳过
# 附加链接: tg_add_footer <var> ["标签" "URL"]... → 追加 " · 🔗 <a>标签</a>"
# 环境变量（openlist.yml 注入容器）: TG_RUN_URL / TG_RUN_STARTED_AT
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
    line="⏱ 已运行 <b>${dur}</b>"
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
  # （历史踩坑：task_preview 合计行经 tg_append 拼接、无尾换行）
  local cur="${!var}"
  case "$cur" in
    ''|*$'\n') ;;
    *) tg_append "$var" $'\n' ;;
  esac
  tg_append "$var" $'\n'"${line}"$'\n'
}

# 去标签 + 解码基础实体（HTML 解析失败时的纯文本退化版；与 tg_notify.sh 同款）
_tg_strip_html() {
  printf '%s' "$1" \
    | sed -e 's/<[^>]*>//g' \
          -e 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#39;/'"'"'/g'
}

# 单次发送尝试（不退化）。退出码: 0 成功 / 2 HTML 解析失败（可退化）/ 1 其他失败
# 与 tg_notify.sh 同款（两文件同步维护）；429 按 retry_after 等待重试，
# curl 带 -m 15 防网络挂起阻塞调用链
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
    # HTML 解析失败: 交由 send_tg 退化纯文本重发（不消耗重试次数）
    if echo "$resp" | grep -q "can't parse entities"; then
      echo "⚠️ Telegram HTML 解析失败，将退化纯文本重发" >&2
      return 2
    fi
    echo "⚠️ Telegram 通知发送失败: $(echo "$resp" | head -c 200)" >&2
    return 1
  done
  echo "⚠️ Telegram 通知发送失败（重试 $max_attempts 次仍失败）: $(echo "$resp" | head -c 200)" >&2
  return 1
}

# 单条发送（HTML 优先，解析失败退化纯文本；空消息守卫与 tg_notify.sh 同款）
send_tg() {
  local text="$1"
  [ -z "$text" ] && return 0
  local rc=0
  _tg_send_once "$text" "HTML"
  rc=$?
  [ "$rc" -ne 2 ] && return "$rc"
  _tg_send_once "$(_tg_strip_html "$text")" ""
}

# 按 4000 字符分片，尽量在换行处断开，避免切断 UTF-8 多字节字符（与 tg_notify.sh 同款）
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

# 通用 Telegram 消息发送（静默，不返回 message_id）
# 用法: send_telegram_message <message> [parse_mode=HTML]
# 消息内容必须已按 HTML 规则转义（推荐用上方 tg_* 助手构建）
# 统一走发送层：HTML 解析失败退化纯文本 + 429 限流重试（send_tg 内建），
# 超 4000 字符自动分片（send_tg_chunked）
# disable_web_page_preview 必须带上：收尾区"运行日志"是消息里唯一的链接，
# 缺了它 Telegram 会在消息下方渲染 GitHub 页面预览卡片（与 tg_notify.sh 同参数）
send_telegram_message() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  [ -z "$message" ] && return 0
  if [ "${#message}" -gt 4000 ]; then
    send_tg_chunked "$message" >/dev/null 2>&1 || true
    return 0
  fi
  send_tg "$message" >/dev/null 2>&1 || true
}

# 发送 Telegram 消息并返回 message_id
# 用法: _tg_send_and_get_id <message> [parse_mode=HTML]
# 输出: message_id（失败时为空）
# 与 send_telegram_message 同降级链：429 按 retry_after 重试、HTML 解析失败退化纯文本
_tg_send_and_get_id() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  local response attempt retry_after
  for attempt in 1 2 3 4 5; do
    if [ -n "$parse_mode" ]; then
      response=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="$parse_mode" \
        -d disable_web_page_preview=true \
        --data-urlencode text="$message" 2>/dev/null) || true
    else
      response=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d disable_web_page_preview=true \
        --data-urlencode text="$message" 2>/dev/null) || true
    fi
    echo "$response" | grep -q '"ok":true' && break
    retry_after=$(echo "$response" | grep -oE '"retry_after":[0-9]+' | head -1 | cut -d: -f2)
    if [ -n "$retry_after" ]; then
      echo "⚠️ Telegram 限流 (429)，等待 ${retry_after}s 后重试 (尝试 $attempt/5)..." >&2
      sleep "$retry_after"
      continue
    fi
    if echo "$response" | grep -q "can't parse entities"; then
      echo "⚠️ Telegram HTML 解析失败，退化纯文本重发" >&2
      message=$(_tg_strip_html "$message")
      parse_mode=""
      continue
    fi
    break
  done
  # jq 对非 JSON 响应（如网关 502 页面）返回非零 → set -e 下会沿
  # _tg_ensure_bottom_message → _progress_refresh → progress_update 调用链
  # 传染并终止整个 step；通知属 fire-and-forget，失败只吞不传
  echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null || true
}

# 删除 Telegram 消息
# 用法: _tg_delete_message <message_id>
_tg_delete_message() {
  local message_id="$1"
  [ -z "$message_id" ] && return
  curl -s -m 8 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$message_id" >/dev/null 2>&1 || true
}

# 确保进度消息始终是 bot 最后一条消息
# 策略：始终删除旧消息并重新发送，保证进度消息在聊天底部
# 用法: _tg_ensure_bottom_message <message> [parse_mode=HTML]
# 输出: 当前有效的 message_id
_tg_ensure_bottom_message() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  local old_id=""
  [ -f "$PROGRESS_MSG_ID_FILE" ] && old_id=$(head -1 "$PROGRESS_MSG_ID_FILE" 2>/dev/null)

  # 先删除旧消息（如果存在）
  if [ -n "$old_id" ]; then
    _tg_delete_message "$old_id"
  fi

  # 发送新消息（一定是最后一条）
  local new_id
  new_id=$(_tg_send_and_get_id "$message" "$parse_mode")
  if [ -n "$new_id" ]; then
    echo "$new_id" > "$PROGRESS_MSG_ID_FILE"
    # 已发 id 记账: 即使后续某次刷新丢失追踪（发成功但响应丢失/写回被打断），
    # progress_finalize 仍能按这份清单兑底删除孤儿
    echo "$new_id" >> "$PROGRESS_SENT_IDS_LOG" 2>/dev/null || true
    echo "$new_id"
  fi
}
