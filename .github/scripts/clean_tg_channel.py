import os
import sys
import base64
import asyncio

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
except ImportError:
    print("Telethon library not found. Please install it first.")
    sys.exit(1)

api_id = os.environ.get('TG_API_ID')
api_hash = os.environ.get('TG_API_HASH')
# GitHub secrets 偶尔会带尾随换行/空白，会破坏 base64 解码导致
# telethon 抛出 struct.error: unpack requires a buffer of 275 bytes
session_string = os.environ.get('TG_SESSION_STRING', '').strip()

if not api_id or not api_hash or not session_string:
    print("Error: Missing TG_API_ID, TG_API_HASH, or TG_SESSION_STRING in environment variables.")
    sys.exit(1)

# Telethon StringSession v1 以字符 '1' 开头，后接 urlsafe base64
# 非 '1' 开头通常是 Pyrogram 字符串、被截断或格式错误
if session_string[0] != '1':
    print(f"Error: TG_SESSION_STRING is not a valid Telethon StringSession "
          f"(expected to start with '1', got {session_string[0]!r}). "
          f"Make sure it was generated with Telethon, not Pyrogram/Telegraf. "
          f"Length={len(session_string)}")
    sys.exit(1)

# 预先校验 base64 可解码且长度足够（telethon 1.44 期望 275 字节解码缓冲）
try:
    _decoded = base64.urlsafe_b64decode(session_string[1:].encode('ascii'))
except Exception as e:
    print(f"Error: TG_SESSION_STRING is not valid base64: {e}")
    sys.exit(1)

if len(_decoded) < 261:
    print(f"Error: TG_SESSION_STRING appears truncated or corrupted "
          f"(decoded length {len(_decoded)} bytes, expected at least 261). "
          f"Re-generate it with Telethon's StringSession.save().")
    sys.exit(1)

if len(sys.argv) < 2:
    print("Usage: python clean_tg_channel.py <channel_id>")
    sys.exit(1)

channel_id = sys.argv[1]
try:
    channel_id = int(channel_id)
except ValueError:
    pass

try:
    api_id = int(api_id)
except ValueError:
    print("Error: TG_API_ID must be an integer.")
    sys.exit(1)

BATCH_SIZE = 100
SLEEP_BETWEEN_BATCHES = 1


async def main():
    client = TelegramClient(StringSession(session_string), api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        print("Error: Session string is invalid or expired.")
        sys.exit(1)

    print(f"Fetching messages from channel {channel_id}...")
    entity = await client.get_entity(channel_id)

    batch = []
    deleted = 0
    async for msg in client.iter_messages(entity, limit=None):
        batch.append(msg.id)
        if len(batch) >= BATCH_SIZE:
            await client.delete_messages(entity, batch)
            deleted += len(batch)
            print(f"Deleted {deleted} messages...")
            batch = []
            await asyncio.sleep(SLEEP_BETWEEN_BATCHES)

    # Delete remaining messages
    if batch:
        await client.delete_messages(entity, batch)
        deleted += len(batch)

    print(f"Total deleted: {deleted} messages.")
    await client.disconnect()


if __name__ == '__main__':
    asyncio.run(main())
