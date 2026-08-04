import os
import sys
import asyncio

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
except ImportError:
    print("Telethon library not found. Please install it first.")
    sys.exit(1)

api_id = os.environ.get('TG_API_ID')
api_hash = os.environ.get('TG_API_HASH')
session_string = os.environ.get('TG_SESSION_STRING')

if not api_id or not api_hash or not session_string:
    print("Error: Missing TG_API_ID, TG_API_HASH, or TG_SESSION_STRING in environment variables.")
    sys.exit(1)

if len(sys.argv) < 2:
    print("Usage: python clean_channel.py <channel_id>")
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
