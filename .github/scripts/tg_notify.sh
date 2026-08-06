#!/bin/bash
# 共享脚本：Telegram 通知发送工具
# 支持单条发送和按 4000 字符分片发送，避免超过 Telegram sendMessage 接口 4096 字符限制
# 用法: source tg_notify.sh
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
# 函数:
#   send_tg <text>               单条发送（短消息用）
#   send_tg_chunked <text>       按 4000 字符分片发送（长消息用）

send_tg() {
  local text="$1"
  [ -z "$text" ] && return 0
  local resp
  resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="$text" 2>&1)
  if ! echo "$resp" | grep -q '"ok":true'; then
    echo "⚠️ Telegram 通知发送失败: $(echo "$resp" | head -c 200)" >&2
    return 1
  fi
  return 0
}

# 按 4000 字符分片，尽量在换行处断开，避免切断 UTF-8 多字节字符
send_tg_chunked() {
  local text="$1"
  [ -z "$text" ] && return 0
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
for idx, c in enumerate(chunks, 1):
    sys.stderr.write(f"--- 发送分片 {idx}/{len(chunks)} ({len(c)} 字符) ---\n")
    sys.stdout.write(c + "\x00")
' | while IFS= read -r -d "" chunk; do
    send_tg "$chunk"
    sleep 0.3
  done
}
