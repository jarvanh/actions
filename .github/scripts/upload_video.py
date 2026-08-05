import os
import sys
import asyncio
import subprocess
import json

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
    from telethon.tl.types import DocumentAttributeVideo
except ImportError:
    print("Telethon library not found. Please install it first.")
    sys.exit(1)


def get_video_attributes(file_path):
    """用 ffprobe 读取视频元数据，返回 DocumentAttributeVideo。
    显式提供 duration/width/height 确保 Telegram 以视频（可流式播放）而非文档方式接收。"""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'quiet', '-print_format', 'json',
             '-show_format', '-show_streams', file_path],
            capture_output=True, text=True, timeout=30
        )
        data = json.loads(result.stdout)
        width = 0
        height = 0
        duration = 0
        for stream in data.get('streams', []):
            if stream.get('codec_type') == 'video':
                width = int(stream.get('width', 0) or 0)
                height = int(stream.get('height', 0) or 0)
                break
        fmt = data.get('format', {})
        duration = int(float(fmt.get('duration', 0) or 0))
        if width > 0 and height > 0:
            return DocumentAttributeVideo(
                duration=duration,
                w=width,
                h=height,
                supports_streaming=True
            )
    except Exception as e:
        print(f"Warning: Could not detect video metadata: {e}", file=sys.stderr)
    return None

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
    video_attributes = get_video_attributes(file_path)
    if video_attributes:
        print(f"Video attributes: {video_attributes.w}x{video_attributes.h}, duration={video_attributes.duration}s")
    else:
        print("Warning: No video attributes detected, uploading may be sent as document", file=sys.stderr)

    MAX_RETRIES = 3
    INITIAL_BACKOFF = 5
    last_error = None
    try:
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                send_kwargs = {
                    'entity': chat_id,
                    'file': file_path,
                    'caption': caption,
                    'force_document': False,
                    'supports_streaming': True,
                    'progress_callback': progress_callback,
                }
                if video_attributes:
                    send_kwargs['attributes'] = [video_attributes]
                await client.send_file(**send_kwargs)
                print("\nUpload successful!")
                return
            except Exception as e:
                last_error = e
                print(f"\nAttempt {attempt}/{MAX_RETRIES} failed: {e}", file=sys.stderr)
                if attempt < MAX_RETRIES:
                    backoff = INITIAL_BACKOFF * (2 ** (attempt - 1))
                    print(f"Retrying in {backoff}s...", file=sys.stderr)
                    await asyncio.sleep(backoff)
        print(f"\nAll {MAX_RETRIES} attempts failed. Last error: {last_error}", file=sys.stderr)
        sys.exit(1)
    finally:
        await client.disconnect()

if __name__ == '__main__':
    asyncio.run(main())
