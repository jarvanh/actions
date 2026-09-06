#!/bin/bash
# ===== OpenList 同步工具 — Telegram 进度面板（原地编辑）=====
# 规范唯一真源: docs/telegram-notify.md（版式模板/收尾区/禁止事项/检查清单）
#
# 本文件只放 openlist 独有的「需要 message_id」能力:
#   send_telegram_message      静默发送（openlist 各脚本的统一出口）
#   _tg_send_and_get_id        发送并返回 message_id
#   _tg_delete_message         删除消息（面板刷新时删旧）
#   _tg_ensure_bottom_message  保证最新面板始终在会话底部
# 排版助手（tg_add_* / tree_* / escape_html）与发送层（send_tg / send_tg_chunked）
# 全部来自全库真源 scripts/telegram/tg_notify.sh，由 load_all.sh 在 L0 层最先 source；
# 本文件不再自带副本（两份实现必然漂移，2026-09-06 收敛）。
#
# 依赖环境变量:
#   TELEGRAM_BOT_TOKEN — Telegram Bot API Token（由 workflow secrets 注入）
#   TELEGRAM_CHAT_ID   — 目标 Chat ID（由 workflow secrets 注入）
#   （历史名 TG_BOT_TOKEN / TG_CHAT_ID 自动兼容——真源内别名回退）
# 依赖全局变量:
#   PROGRESS_MSG_ID_FILE — 进度消息 ID 存储文件路径
#   PROGRESS_SENT_IDS_LOG — 本轮已发进度消息 id 清单（finalize 兜底清孤儿，sync_progress.sh 定义）

# 统一分隔线（18 个全角横线）
TG_SEP='━━━━━━━━━━━━━━━━━━'

# 凭据变量名兼容（与 tg_notify.sh 同款，两文件同步维护）：历史名自动回退，
# 防止名字错接导致 chat_id 为空、通知静默消失
: "${TELEGRAM_BOT_TOKEN:=${TG_BOT_TOKEN:-}}"
: "${TELEGRAM_CHAT_ID:=${TG_CHAT_ID:-}}"
# ===== 排版助手与发送层来自全库真源 =====
# tg_append / tg_add_* / tree_* / escape_html / send_tg / send_tg_chunked 已收敛到
# scripts/telegram/tg_notify.sh，由 load_all.sh 在 L0 层最先 source（2026-09-06 收敛）。
# 本文件只保留 openlist 独有的「进度面板原地编辑」相关函数。

# 通用 Telegram 消息发送（静默，不返回 message_id）
# 用法: send_telegram_message <message> [parse_mode=HTML]
# 消息内容必须已按 HTML 规则转义（推荐用上方 tg_* 助手构建）
# 统一走发送层：429 限流重试（send_tg 内建）；HTML 解析失败直接报错不重发，
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
# 429 按 retry_after 重试；HTML 解析失败直接报错、不重发（见 docs/telegram-notify.md §5）
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
      echo "❌ Telegram HTML 解析失败（400 can't parse entities），消息未发送" >&2
      break
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
