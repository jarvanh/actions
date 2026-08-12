import os
import sys
import base64
import asyncio

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
    from telethon.errors import FloodWaitError
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
# 单次 API 请求超时（秒），避免 FLOOD_WAIT 时无提示静默等待数小时
REQUEST_TIMEOUT = 60
# 整个脚本最长运行时间（秒），避免 GitHub Actions 6 小时挂死
SCRIPT_TIMEOUT = 10 * 60


async def _with_timeout(coro, label):
    """统一给每个 Telegram API 调用加超时，并显式报告 FLOOD_WAIT。"""
    try:
        return await asyncio.wait_for(coro, timeout=REQUEST_TIMEOUT)
    except asyncio.TimeoutError:
        print(f"Error: {label} timed out after {REQUEST_TIMEOUT}s "
              f"(likely network issue or silent FLOOD_WAIT).")
        raise
    except FloodWaitError as e:
        print(f"Error: Telegram FLOOD_WAIT on {label}: must wait {e.seconds}s.")
        raise


async def main():
    # connection_timeout: 连接建立超时
    # request_retries: 单次请求失败重试次数（避免无限重试）
    # flood_sleep_threshold: 小于该秒数的 FLOOD_WAIT 自动 sleep，大于则抛异常
    client = TelegramClient(
        StringSession(session_string), api_id, api_hash,
        connection_timeout=30,
        request_retries=2,
        flood_sleep_threshold=10,
    )
    await client.connect()

    if not await client.is_user_authorized():
        print("Error: Session string is invalid or expired.")
        sys.exit(1)

    print(f"Resolving entity for channel {channel_id}...")
    entity = await _with_timeout(client.get_entity(channel_id), "get_entity")

    # 先用 limit=0 探测频道消息总数，避免空频道仍走完整 iter 流程
    print(f"Counting messages in channel {channel_id} (limit=0 probe)...")
    probe = await _with_timeout(client.get_messages(entity, limit=0), "get_messages(limit=0)")
    total = getattr(probe, 'total', None) if probe is not None else None
    print(f"Channel {channel_id} reports total={total} messages.")

    if total == 0:
        print("Channel is already empty, nothing to delete.")
        await client.disconnect()
        return

    print(f"Fetching messages from channel {channel_id}...")
    batch = []
    deleted = 0
    async for msg in client.iter_messages(entity, limit=None):
        batch.append(msg.id)
        if len(batch) >= BATCH_SIZE:
            await _with_timeout(
                client.delete_messages(entity, batch), "delete_messages(batch)")
            deleted += len(batch)
            print(f"Deleted {deleted} messages...")
            batch = []
            await asyncio.sleep(SLEEP_BETWEEN_BATCHES)

    # Delete remaining messages
    if batch:
        await _with_timeout(
            client.delete_messages(entity, batch), "delete_messages(remainder)")
        deleted += len(batch)

    print(f"Total deleted: {deleted} messages.")
    await client.disconnect()


if __name__ == '__main__':
    # 全局脚本超时保护：避免任何一步静默挂死导致 GitHub Actions 撑到 6h 默认超时
    try:
        asyncio.run(asyncio.wait_for(main(), timeout=SCRIPT_TIMEOUT))
    except asyncio.TimeoutError:
        print(f"Error: Script exceeded overall timeout of {SCRIPT_TIMEOUT}s, aborting.")
        sys.exit(2)

