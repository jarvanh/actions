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

try:
    api_id = int(api_id)
except ValueError:
    print("Error: TG_API_ID must be an integer.")
    sys.exit(1)

if len(sys.argv) < 3:
    print("Usage: python upload_video.py <file_path> <chat_id> [caption]")
    sys.exit(1)

file_path = sys.argv[1]
chat_id = sys.argv[2]
caption = sys.argv[3] if len(sys.argv) > 3 else ""

try:
    chat_id = int(chat_id)
except ValueError:
    pass

async def progress_callback(current, total):
    percent = (current / total) * 100
    # Print progress every 10%
    if int(percent) % 10 == 0:
        print(f"Uploaded: {current}/{total} bytes ({percent:.1f}%)", end='\r')

async def main():
    client = TelegramClient(StringSession(session_string), api_id, api_hash)
    await client.connect()
    
    if not await client.is_user_authorized():
        print("Error: Session string is invalid or expired.")
        sys.exit(1)

    print(f"\nUploading {file_path} to {chat_id}...")
    try:
        await client.send_file(
            entity=chat_id,
            file=file_path,
            caption=caption,
            force_document=False,
            progress_callback=progress_callback
        )
        print("\nUpload successful!")
    except Exception as e:
        print(f"\nFailed to upload: {e}")
        sys.exit(1)
    finally:
        await client.disconnect()

if __name__ == '__main__':
    asyncio.run(main())
