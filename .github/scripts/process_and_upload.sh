#!/bin/bash
# 共享脚本：从 OneDrive 下载视频并上传到 Telegram 频道
# 用法: process_and_upload.sh <SOURCE_REMOTE> <CHANNEL_ID> <CAPTION_PREFIX>
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE, GITHUB_REPOSITORY, GITHUB_RUN_ID

set +e

# 强制使用 C.UTF-8 locale，保证 UTF-8 文件名一致处理
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

SOURCE_REMOTE="$1"
CHANNEL_ID="$2"
CAPTION_PREFIX="$3"

if [ -z "$SOURCE_REMOTE" ] || [ -z "$CHANNEL_ID" ]; then
  echo "Usage: $0 <SOURCE_REMOTE> <CHANNEL_ID> <CAPTION_PREFIX>"
  exit 1
fi

TMP_DIR="/tmp/tg-upload"
mkdir -p "$TMP_DIR"

# 拉取已上传名单到本地（不要修改远程文件，工作结束后再写回）
rclone cat "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null > "$TMP_DIR/uploaded_videos.raw" || true

# 所有核心逻辑交给 Python：列出、比较、下载、上传、记录
# 只需要一个持久化文件 uploaded_videos.txt，不再需要 all_videos.txt / pending.txt / skipped.txt 等中间文件
python3 - "$SOURCE_REMOTE" "$CHANNEL_ID" "$CAPTION_PREFIX" "$TMP_DIR" <<'PYEOF'
import json
import os
import subprocess
import sys
from pathlib import PurePosixPath

SOURCE_REMOTE = sys.argv[1]
CHANNEL_ID = sys.argv[2]
CAPTION_PREFIX = sys.argv[3]
TMP = sys.argv[4]
GITHUB_WORKSPACE = os.environ.get("GITHUB_WORKSPACE", "")

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm", ".m4v", ".ts"}
UPLOADED_RAW = os.path.join(TMP, "uploaded_videos.raw")
UPLOADED_OUT = os.path.join(TMP, "uploaded_videos.txt")
STATS_FILE = os.path.join(TMP, "stats.json")
WORK_DIR = os.path.join(TMP, "work")


def run(cmd, **kwargs):
    """执行命令，返回 CompletedProcess，不抛异常。"""
    return subprocess.run(cmd, shell=isinstance(cmd, str), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kwargs)


def is_video(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in VIDEO_EXTS


def is_safe(path: str) -> bool:
    return "/" not in path and "\\" not in path and ".." not in PurePosixPath(path).parts


def read_uploaded() -> set:
    """读取已上传名单，兼容旧版 \n 分隔和新版 \0 分隔。"""
    uploaded = set()
    if not os.path.exists(UPLOADED_RAW) or os.path.getsize(UPLOADED_RAW) == 0:
        return uploaded
    with open(UPLOADED_RAW, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    # 自动判断分隔符
    if b"\0" not in raw and b"\n" in raw:
        parts = raw.split(b"\n")
    else:
        parts = raw.split(b"\0")
    for part in parts:
        part = part.rstrip(b"\r\n")
        if not part:
            continue
        try:
            s = part.decode("utf-8", errors="replace")
        except Exception:
            continue
        if s:
            uploaded.add(s)
    return uploaded


def write_uploaded(uploaded: set):
    """写回 uploaded_videos.txt，使用 NUL 分隔以支持含换行符的文件名。"""
    lines = sorted(uploaded, key=lambda x: x.lower())
    with open(UPLOADED_OUT, "wb") as f:
        for name in lines:
            f.write(name.encode("utf-8") + b"\0")


def get_video_list():
    """通过 rclone lsjson 获取远端视频文件列表，返回 [(modtime, filename)]。"""
    lsjson_path = os.path.join(TMP, "ls.json")
    err_path = os.path.join(TMP, "lsjson.err")
    result = run(f"rclone lsjson {SOURCE_REMOTE}/")
    with open(lsjson_path, "wb") as f:
        f.write(result.stdout.encode("utf-8", errors="replace") if isinstance(result.stdout, str) else result.stdout)
    with open(err_path, "wb") as f:
        f.write(result.stderr.encode("utf-8", errors="replace") if isinstance(result.stderr, str) else result.stderr)

    if result.returncode != 0:
        print(f"WARN: rclone lsjson 失败 (code {result.returncode})")
        return [], []

    try:
        data = result.stdout
        if isinstance(data, bytes):
            if data.startswith(b"\xef\xbb\xbf"):
                data = data[3:]
            items = json.loads(data.decode("utf-8", errors="replace"))
        else:
            items = json.loads(data)
    except Exception as e:
        print(f"WARN: rclone lsjson 解析失败: {e}")
        return [], []

    if not isinstance(items, list):
        return [], []

    videos = []
    skipped = []
    for it in items:
        if not isinstance(it, dict) or it.get("IsDir"):
            continue
        path = it.get("Path") or it.get("Name") or ""
        if not path:
            continue
        if not is_video(path):
            skipped.append(("not_video", path))
            continue
        if not is_safe(path):
            skipped.append(("unsafe_path", path))
            continue
        videos.append((it.get("ModTime") or "", path))

    # 旧的先处理
    videos.sort(key=lambda x: x[0])
    return [p for _, p in videos], skipped


def main():
    uploaded = read_uploaded()
    all_videos, skipped = get_video_list()

    # 去重：保留原始值，不 NFC 归一化
    seen = set()
    deduped = []
    for p in all_videos:
        if p in seen:
            skipped.append(("duplicate", p))
            continue
        seen.add(p)
        deduped.append(p)
    all_videos = deduped

    pending = [p for p in all_videos if p not in uploaded]

    total = len(all_videos)
    pending_count = len(pending)
    print(f"rclone lsjson 返回 {total + len(skipped)} 条条目，视频文件 {total} 条，已上传 {len(uploaded)} 条，待上传 {pending_count} 条")
    if skipped:
        from collections import Counter
        c = Counter(reason for reason, _ in skipped)
        print(f"非视频/跳过: {len(skipped)} 条")
        for reason, cnt in c.most_common():
            print(f"   - {reason}: {cnt}")

    sent = 0
    failed = 0
    sent_list = []
    failed_list = []

    for file in pending:
        # 本地临时文件名直接使用原始文件名
        local_file = os.path.join(WORK_DIR, os.path.basename(file))
        if os.path.exists(WORK_DIR):
            import shutil
            shutil.rmtree(WORK_DIR)
        os.makedirs(WORK_DIR, exist_ok=True)

        print(f"⬇️  正在下载: {file}")
        result = run(["rclone", "copyto", f"{SOURCE_REMOTE}/{file}", local_file])
        if result.returncode != 0 or not os.path.isfile(local_file):
            print(f"❌ FAILED: rclone copy failed: {file}")
            print("--- rclone 错误输出 ---")
            print(result.stderr[-2000:] if result.stderr else "(无错误输出)")
            print("------------------------")
            failed += 1
            failed_list.append(f"- {file}（rclone copy failed）")
            continue
        print(f"✅ 下载完成: {file}")

        # 预处理 + 上传到 Telegram
        proc_one = os.path.join(GITHUB_WORKSPACE, ".github", "scripts", "process_one_file.sh")
        up_result = run(["bash", proc_one, local_file, CHANNEL_ID, CAPTION_PREFIX])
        if up_result.returncode == 0:
            uploaded.add(file)
            sent += 1
            sent_list.append(f"- {file}")
        else:
            failed += 1
            failed_list.append(f"- {file}（Telegram 上传失败）")

        # 清理工作目录
        if os.path.exists(WORK_DIR):
            import shutil
            shutil.rmtree(WORK_DIR)

    write_uploaded(uploaded)

    stats = {
        "total": total,
        "pending": pending_count,
        "sent": sent,
        "failed": failed,
        "skipped_count": len(skipped),
        "skipped_details": "\n".join(f"{reason}: {path}" for reason, path in skipped),
        "sent_list": "\n".join(sent_list),
        "failed_list": "\n".join(failed_list),
    }
    with open(STATS_FILE, "w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)

    print(f"上传完成: 成功 {sent}, 失败 {failed}")


if __name__ == "__main__":
    main()
PYEOF

PYTHON_EXIT=$?
if [ $PYTHON_EXIT -ne 0 ]; then
  echo "ERROR: Python 处理脚本失败，退出码 $PYTHON_EXIT"
  exit $PYTHON_EXIT
fi

# 上传更新后的 uploaded_videos.txt 回 OneDrive
rclone copyto "$TMP_DIR/uploaded_videos.txt" "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null

# 读取 Python 输出的统计
STATS_FILE="$TMP_DIR/stats.json"
TOTAL_VIDEOS=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('total',0))" 2>/dev/null || echo 0)
PENDING_COUNT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('pending',0))" 2>/dev/null || echo 0)
SENT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('sent',0))" 2>/dev/null || echo 0)
FAILED=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('failed',0))" 2>/dev/null || echo 0)
SKIPPED_COUNT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('skipped_count',0))" 2>/dev/null || echo 0)
SENT_LIST=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('sent_list',''))" 2>/dev/null || echo "")
FAILED_LIST=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('failed_list',''))" 2>/dev/null || echo "")
SKIPPED_DETAILS=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('skipped_details',''))" 2>/dev/null || echo "")

# 发送通知
source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"

HEADER="📺 ${CAPTION_PREFIX}"$'\n'"📊 总计: ${PENDING_COUNT}"$'\n'"✅ 成功: ${SENT}"$'\n'"❌ 失败: ${FAILED}"
if [ "$SKIPPED_COUNT" -gt 0 ]; then
  HEADER+=$'\n'"⚠️ 跳过/过滤: ${SKIPPED_COUNT}"
fi
send_tg "$HEADER"

if [ -n "$SENT_LIST" ]; then
  send_tg_chunked "✅ 已上传:"$'\n\n'"${SENT_LIST}"
fi
if [ -n "$FAILED_LIST" ]; then
  send_tg_chunked "❌ 失败:"$'\n\n'"${FAILED_LIST}"
fi
if [ -n "$SKIPPED_DETAILS" ]; then
  send_tg_chunked "⚠️ 跳过/过滤文件详情:"$'\n\n'"${SKIPPED_DETAILS}"
fi
send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

rm -rf "$TMP_DIR"
