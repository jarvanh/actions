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
import shlex
import subprocess
import sys
import time
from datetime import datetime


SOURCE_REMOTE = sys.argv[1]
CHANNEL_ID = sys.argv[2]
CAPTION_PREFIX = sys.argv[3]
TMP = sys.argv[4]
GITHUB_WORKSPACE = os.environ.get("GITHUB_WORKSPACE", "")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm", ".m4v", ".ts"}
UPLOADED_RAW = os.path.join(TMP, "uploaded_videos.raw")
UPLOADED_OUT = os.path.join(TMP, "uploaded_videos.txt")
STATS_FILE = os.path.join(TMP, "stats.json")
WORK_DIR = os.path.join(TMP, "work")


def run(cmd, capture=True, **kwargs):
    """执行命令，返回 CompletedProcess，不抛异常。
    capture=True 时用 PIPE 捕获输出供解析（如 lsjson）；
    capture=False 时直接透传到当前 stdout/stderr，长任务（下载/转码/上传）可实时看到进度。
    """
    if capture:
        return subprocess.run(cmd, shell=isinstance(cmd, str), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, **kwargs)
    return subprocess.run(cmd, shell=isinstance(cmd, str), text=True, **kwargs)


def notify(message):
    """立即发送 Telegram 通知。失败只打印日志，不中断主流程。"""
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        print(f"[notify] 跳过：缺少 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID，消息: {message}")
        return
    tg_script = os.path.join(GITHUB_WORKSPACE, ".github", "scripts", "tg_notify.sh")
    if not os.path.exists(tg_script):
        print(f"[notify] 跳过：通知脚本不存在: {tg_script}")
        return
    print(f"[notify] 发送即时通知: {message[:200]}")
    result = run(["bash", "-c", f"source {shlex.quote(tg_script)} && send_tg {shlex.quote(message)}"])
    if result.returncode != 0:
        print(f"[notify] 发送通知失败 (code {result.returncode}): {result.stderr}")


def is_video(path: str) -> bool:
    return os.path.splitext(path)[1].lower() in VIDEO_EXTS


def read_uploaded() -> set:
    """读取已上传名单（JSON 数组格式）。"""
    uploaded = set()
    if not os.path.exists(UPLOADED_RAW):
        print(f"[read_uploaded] 文件不存在，视为空列表: {UPLOADED_RAW}")
        return uploaded
    size = os.path.getsize(UPLOADED_RAW)
    if size == 0:
        print(f"[read_uploaded] 文件为空: {UPLOADED_RAW}")
        return uploaded

    print(f"[read_uploaded] 开始读取，文件大小: {size} bytes, 路径: {UPLOADED_RAW}")
    try:
        with open(UPLOADED_RAW, "rb") as f:
            raw = f.read()
        # 记录前 500 字节用于排查编码/格式问题
        preview = raw[:500]
        print(f"[read_uploaded] 原始内容前 500 bytes (repr): {preview!r}")

        with open(UPLOADED_RAW, "r", encoding="utf-8") as f:
            data = json.load(f)

        if isinstance(data, list):
            for idx, item in enumerate(data):
                if isinstance(item, str) and item:
                    uploaded.add(item)
                else:
                    print(f"[read_uploaded] 跳过无效条目 #{idx}: type={type(item).__name__}, value={item!r}")
            print(f"[read_uploaded] 解析成功，有效条目数: {len(uploaded)}, 总条目数: {len(data)}")
        else:
            print(f"[read_uploaded] WARN: JSON 根节点不是数组，实际类型: {type(data).__name__}, 值: {data!r}")
    except json.JSONDecodeError as e:
        print(f"[read_uploaded] ERROR: JSON 解析失败: {e}")
        # 输出失败位置附近的内容，方便定位
        try:
            with open(UPLOADED_RAW, "rb") as f:
                raw = f.read()
            err_pos = getattr(e, "pos", 0)
            start = max(0, err_pos - 100)
            end = min(len(raw), err_pos + 100)
            print(f"[read_uploaded] ERROR: 出错位置附近 bytes (pos={err_pos}): {raw[start:end]!r}")
        except Exception as ex:
            print(f"[read_uploaded] ERROR: 无法读取出错位置详情: {ex}")
    except Exception as e:
        print(f"[read_uploaded] ERROR: 读取失败: {type(e).__name__}: {e}")
    return uploaded


def write_uploaded(uploaded: set):
    """写回 uploaded_videos.txt（JSON 数组格式）。"""
    lines = sorted(uploaded, key=lambda x: x.lower())
    print(f"[write_uploaded] 开始写入，条目数: {len(lines)}, 路径: {UPLOADED_OUT}")
    if lines:
        print(f"[write_uploaded] 前 5 条示例: {lines[:5]!r}")
    try:
        with open(UPLOADED_OUT, "w", encoding="utf-8") as f:
            json.dump(lines, f, ensure_ascii=False, indent=2)
        size = os.path.getsize(UPLOADED_OUT)
        print(f"[write_uploaded] 写入完成，文件大小: {size} bytes")
    except Exception as e:
        print(f"[write_uploaded] ERROR: 写入失败: {type(e).__name__}: {e}")
        raise


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
        err_msg = f"❌ rclone lsjson 失败 (code {result.returncode})"
        print(err_msg)
        print(f"[get_video_list] stderr: {result.stderr[-2000:] if result.stderr else '(无)'}")
        notify(f"{err_msg}\n{CAPTION_PREFIX}\nstderr 见 Actions 日志")
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
        err_msg = f"❌ rclone lsjson 解析失败: {e}"
        print(err_msg)
        notify(f"{err_msg}\n{CAPTION_PREFIX}\n请检查 rclone lsjson 输出格式")
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
        videos.append((it.get("ModTime") or "", path))

    # 旧的先处理
    videos.sort(key=lambda x: x[0])
    return videos, skipped


def main():
    uploaded = read_uploaded()
    all_videos, skipped = get_video_list()

    # 去重：保留原始值，不 NFC 归一化
    seen = set()
    deduped = []
    for modtime, p in all_videos:
        if p in seen:
            skipped.append(("duplicate", p))
            continue
        seen.add(p)
        deduped.append((modtime, p))
    all_videos = deduped

    pending = [(m, p) for m, p in all_videos if p not in uploaded]

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

    for modtime, file in pending:
        # 将 ISO 8601 modtime 格式化为更易读的本地样式
        modtime_display = modtime
        if modtime:
            try:
                dt = datetime.fromisoformat(modtime.replace("Z", "+00:00"))
                modtime_display = dt.strftime("%Y-%m-%d %H:%M:%S")
            except Exception:
                pass

        # 本地临时文件名直接使用原始文件名
        local_file = os.path.join(WORK_DIR, os.path.basename(file))
        if os.path.exists(WORK_DIR):
            import shutil
            shutil.rmtree(WORK_DIR)
        os.makedirs(WORK_DIR, exist_ok=True)

        print(f"⬇️  正在下载: {file} (modtime={modtime_display})")
        dl_start = time.time()
        # 透传输出：rclone --progress 的进度实时进 Actions 日志，避免长时间静默
        result = run(["rclone", "copyto", f"{SOURCE_REMOTE}/{file}", local_file, "--progress"], capture=False)
        dl_elapsed = time.time() - dl_start
        if result.returncode != 0 or not os.path.isfile(local_file):
            err_msg = f"❌ FAILED: rclone copy failed: {file} (耗时 {dl_elapsed:.2f}s)"
            print(err_msg)
            print("(rclone 进度/错误已实时输出到上方日志)")
            failed += 1
            failed_list.append(f"- {file}（rclone copy failed, {dl_elapsed:.2f}s）")
            notify(f"{err_msg}\n{CAPTION_PREFIX}\nrclone 进度见 Actions 日志")
            continue
        file_size = os.path.getsize(local_file)
        print(f"✅ 下载完成: {file} (大小 {file_size} bytes, 耗时 {dl_elapsed:.2f}s)")

        # 预处理 + 上传到 Telegram
        proc_one = os.path.join(GITHUB_WORKSPACE, ".github", "scripts", "process_one_file.sh")
        print(f"🎬 开始处理/上传: {file}")
        up_start = time.time()
        # 透传输出：转码/上传进度实时进 Actions 日志，避免长时间静默
        up_result = run(["bash", proc_one, local_file, CHANNEL_ID, modtime_display], capture=False)
        up_elapsed = time.time() - up_start
        if up_result.returncode == 0:
            uploaded.add(file)
            sent += 1
            sent_list.append(f"- {file} (上传耗时 {up_elapsed:.2f}s)")
            print(f"✅ 上传完成: {file} (总处理耗时 {up_elapsed:.2f}s)")
        else:
            err_msg = f"❌ FAILED: 处理/上传失败: {file} (耗时 {up_elapsed:.2f}s)"
            print(err_msg)
            print("(处理/上传过程已实时输出到上方日志)")
            failed += 1
            failed_list.append(f"- {file}（处理/上传失败, {up_elapsed:.2f}s）")
            notify(f"{err_msg}\n{CAPTION_PREFIX}\n详细输出见 Actions 日志")

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
