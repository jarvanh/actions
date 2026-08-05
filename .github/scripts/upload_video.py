import os
import sys
import asyncio
import subprocess
import json

try:
    from telethon import TelegramClient
    from telethon.sessions import StringSession
    from telethon.tl.types import DocumentAttributeVideo, DocumentAttributeFilename
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

def generate_thumbnail(video_path):
    """用 ffmpeg 从视频截取一帧作为缩略图，确保 Telegram 显示预览"""
    thumb_path = video_path + '.thumb.jpg'
    try:
        # 获取时长，在 10% 处截图（避免黑屏片头）
        result = subprocess.run(
            ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'csv=p=0', video_path],
            capture_output=True, text=True, timeout=10
        )
        duration = float(result.stdout.strip()) if result.stdout.strip() else 0
        seek = max(1, min(10, duration * 0.1)) if duration > 0 else 5

        subprocess.run(
            ['ffmpeg', '-y', '-ss', str(seek), '-i', video_path,
             '-vframes', '1', '-vf', 'scale=320:-2', thumb_path],
            capture_output=True, timeout=30
        )
        if os.path.exists(thumb_path) and os.path.getsize(thumb_path) > 0:
            return thumb_path
    except Exception as e:
        print(f"Thumbnail generation failed: {e}", file=sys.stderr)
    return None

def get_video_attributes(video_path):
    """用 ffprobe 获取视频尺寸/时长，构造 DocumentAttributeVideo"""
    try:
        result = subprocess.run(
            ['ffprobe', '-v', 'error', '-print_format', 'json',
             '-show_format', '-show_streams', video_path],
            capture_output=True, text=True, timeout=10
        )
        data = json.loads(result.stdout)
        duration = int(float(data.get('format', {}).get('duration', 0)))
        for stream in data.get('streams', []):
            if stream.get('codec_type') == 'video':
                w = int(stream.get('width', 0))
                h = int(stream.get('height', 0))
                if w > 0 and h > 0:
                    return [
                        DocumentAttributeFilename(os.path.basename(video_path)),
                        DocumentAttributeVideo(
                            duration=duration,
                            w=w,
                            h=h,
                            supports_streaming=True
                        )
                    ]
    except Exception as e:
        print(f"Metadata extraction failed: {e}", file=sys.stderr)
    return None

async def main():
    client = TelegramClient(StringSession(session_string), api_id, api_hash)
    await client.connect()

    if not await client.is_user_authorized():
        print("Error: Session string is invalid or expired.")
        sys.exit(1)

    print(f"\nUploading {file_path} to {chat_id}...")

    # 生成缩略图和视频属性，确保 Telegram 显示预览
    thumb = generate_thumbnail(file_path)
    attributes = get_video_attributes(file_path)
    if attributes:
        print(f"Video attributes: {attributes[1].w}x{attributes[1].h}, duration={attributes[1].duration}s")
    if thumb:
        print(f"Thumbnail: {thumb}")

    MAX_RETRIES = 3
    INITIAL_BACKOFF = 5
    last_error = None
    try:
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                await client.send_file(
                    entity=chat_id,
                    file=file_path,
                    caption=caption,
                    force_document=False,
                    supports_streaming=True,
                    thumb=thumb,
                    attributes=attributes,
                    progress_callback=progress_callback
                )
                print("\nUpload successful!")
                return
            except Exception as e:
                last_error = e
                print(f"\nAttempt {attempt}/{MAX_RETRIES} failed: {e}", file=sys.stderr)
                # 缩略图可能被 Telegram 拒绝（尺寸/格式问题），重试时去掉缩略图
                if thumb and 'thumb' in str(e).lower():
                    print("Retrying without thumbnail...", file=sys.stderr)
                    if os.path.exists(thumb):
                        os.remove(thumb)
                    thumb = None
                if attempt < MAX_RETRIES:
                    backoff = INITIAL_BACKOFF * (2 ** (attempt - 1))
                    print(f"Retrying in {backoff}s...", file=sys.stderr)
                    await asyncio.sleep(backoff)
        print(f"\nAll {MAX_RETRIES} attempts failed. Last error: {last_error}", file=sys.stderr)
        sys.exit(1)
    finally:
        if thumb and os.path.exists(thumb):
            os.remove(thumb)
        await client.disconnect()

if __name__ == '__main__':
    asyncio.run(main())
