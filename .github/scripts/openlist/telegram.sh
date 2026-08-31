#!/bin/bash
# ===== OpenList 同步工具 — Telegram 消息函数 =====
# 依赖环境变量:
#   TELEGRAM_BOT_TOKEN — Telegram Bot API Token（由 workflow secrets 注入）
#   TELEGRAM_CHAT_ID   — 目标 Chat ID（由 workflow secrets 注入）
# 依赖全局变量:
#   PROGRESS_MSG_ID_FILE — 进度消息 ID 存储文件路径
#   PROGRESS_SENT_IDS_LOG — 本轮已发进度消息 id 清单（finalize 兑底清孤儿，sync_progress.sh 定义）
# 依赖函数: utils.sh (escape_html)

# ===== 通知排版助手（统一所有 Telegram 通知的结构与风格）=====
# 统一模板（一律 HTML parse_mode，动态内容必须转义——助手函数已内置）:
#
#   {emoji} <b>标题</b>            ← tg_add_title
#   ━━━━━━━━━━━━━━━━━━             ← TG_SEP（单点定义，勿手写分隔线）
#   标签：值                        ← 头部键值区（数值 tg_add_kv / 路径 tg_add_path）
#
#   {emoji} <b>分节标题</b>         ← tg_add_section（段前自动空一行）
#   • 条目                         ← 单行平铺列表统一 "• " 前缀（无层级条目）
#   📁 <b>组头</b> · <i>大小</i>   ← 分组列表: 路径/目录类组头加 📁，组间空行分隔
#     ├─ 条目 · <i>备注</i>        ← 条目用树形连接符 ├─/└─ 标记边界
#     │   子行                     ← 条目子行缩进对齐（末条目子行 6 空格）
#   <b>状态组头</b>                ← 块内状态分组（如"✅ 已同步的子目录"），下接树形条目
#   <pre>块</pre>                  ← 日志/流量图等需对齐的多行内容
#
#   条目内多字段一律用 " · " 分隔（勿用全角冒号/括号堆一行）；
#   数值与状态用 <i>，路径/文件名/模式用 <code>
#   树形渲染助手 tree_conn/tree_sub/tree_lines 定义在 utils.sh（全库共用）
#
#   {emoji} <b>结尾提示</b>         ← 收尾状态（如"已跳过此同步"）
#   斜体说明                        ← tg_add_note
#
# 状态 emoji 语义（全库统一）:
#   ✅ 成功 / ⚠️ 部分失败 / ❌ 失败 / ⏭️ 跳过 / 🔄 进行中 / ⛔ 中断 / 🚨 危险警告

# 统一分隔线（18 个全角横线）
TG_SEP='━━━━━━━━━━━━━━━━━━'

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

# 通用 Telegram 消息发送（静默，不返回 message_id）
# 用法: send_telegram_message <message> [parse_mode=HTML]
# 消息内容必须已按 HTML 规则转义（推荐用上方 tg_* 助手构建）
send_telegram_message() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="$parse_mode" \
    --data-urlencode text="$message" >/dev/null 2>&1 || true
}

# 发送 Telegram 消息并返回 message_id
# 用法: _tg_send_and_get_id <message> [parse_mode=HTML]
# 输出: message_id（失败时为空；失败原因写 job log stderr——响应摘要+消息长度，
# 供排查 4096 超长/HTML 解析拒绝/网络等）
_tg_send_and_get_id() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  local response _mid
  response=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="$parse_mode" \
    --data-urlencode text="$message" 2>/dev/null) || true
  _mid=$(printf '%s' "$response" | jq -r '.result.message_id // empty' 2>/dev/null || true)
  if [ -z "$_mid" ]; then
    echo "[tg] sendMessage 失败: 响应=$(printf '%s' "$response" | head -c 200) 消息长度=$(printf '%s' "$message" | wc -c | tr -d ' ')" >&2
  fi
  printf '%s' "$_mid"
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
