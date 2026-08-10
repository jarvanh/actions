#!/bin/bash
# ===== OpenList 同步工具 — Telegram 消息函数 =====
# 依赖环境变量:
#   TELEGRAM_BOT_TOKEN — Telegram Bot API Token（由 workflow secrets 注入）
#   TELEGRAM_CHAT_ID   — 目标 Chat ID（由 workflow secrets 注入）
# 依赖全局变量:
#   PROGRESS_MSG_ID_FILE — 进度消息 ID 存储文件路径

# 通用 Telegram 消息发送（静默，不返回 message_id）
# 用法: send_telegram_message <message> [parse_mode]
send_telegram_message() {
  local message="$1"
  local parse_mode="${2:-}"
  if [ -n "$parse_mode" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d parse_mode="$parse_mode" \
      --data-urlencode text="$message" >/dev/null 2>&1 || true
  else
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      --data-urlencode text="$message" >/dev/null 2>&1 || true
  fi
}

# 发送 Telegram 消息并返回 message_id
# 用法: _tg_send_get_id <message> [parse_mode]
# 输出: message_id（失败时为空）
_tg_send_get_id() {
  local message="$1"
  local parse_mode="${2:-HTML}"
  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d parse_mode="$parse_mode" \
    --data-urlencode text="$message" 2>/dev/null) || true
  echo "$response" | jq -r '.result.message_id // empty' 2>/dev/null
}

# 编辑已有 Telegram 消息
# 用法: _tg_edit_message <message_id> <message> [parse_mode]
# 返回: "ok" 或 "failed"
_tg_edit_message() {
  local message_id="$1"
  local message="$2"
  local parse_mode="${3:-HTML}"
  [ -z "$message_id" ] && echo "failed" && return
  local edit_resp
  edit_resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/editMessageText" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$message_id" \
    -d parse_mode="$parse_mode" \
    --data-urlencode text="$message" 2>/dev/null) || true
  local edit_ok edit_desc
  edit_ok=$(echo "$edit_resp" | jq -r '.ok // false' 2>/dev/null)
  edit_desc=$(echo "$edit_resp" | jq -r '.description // ""' 2>/dev/null)
  if [ "$edit_ok" = "true" ] || [[ "$edit_desc" == *"not modified"* ]]; then
    echo "ok"
  else
    echo "failed"
  fi
}

# 删除 Telegram 消息
# 用法: _tg_delete_message <message_id>
_tg_delete_message() {
  local message_id="$1"
  [ -z "$message_id" ] && return
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d message_id="$message_id" >/dev/null 2>&1 || true
}

# 确保进度消息始终是 bot 最后一条消息
# 策略：始终删除旧消息并重新发送，保证进度消息在聊天底部
# 用法: _tg_ensure_bottom_message <message> [parse_mode]
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
  new_id=$(_tg_send_get_id "$message" "$parse_mode")
  if [ -n "$new_id" ]; then
    echo "$new_id" > "$PROGRESS_MSG_ID_FILE"
    echo "$new_id"
  fi
}
