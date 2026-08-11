#!/bin/bash
# 共享脚本：从远端存储（如 OneDrive）下载视频并批量上传到 Telegram 频道
# 用法: sync_to_tg.sh <SOURCE_REMOTE> <CHANNEL_ID> <CAPTION_PREFIX>
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
rclone cat "$SOURCE_REMOTE/uploaded_videos.json" 2>/dev/null > "$TMP_DIR/uploaded_videos.raw" || true

# 所有核心逻辑交给 Python：列出、比较、下载、上传、记录
# 只需要一个持久化文件 uploaded_videos.json（versioned JSON 对象，可扩展元数据），不再需要中间文件
python3 - "$SOURCE_REMOTE" "$CHANNEL_ID" "$CAPTION_PREFIX" "$TMP_DIR" <<'PYEOF'
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone


SOURCE_REMOTE = sys.argv[1]
CHANNEL_ID = sys.argv[2]
CAPTION_PREFIX = sys.argv[3]
TMP = sys.argv[4]
GITHUB_WORKSPACE = os.environ.get("GITHUB_WORKSPACE", "")
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm", ".m4v", ".ts"}
UPLOADED_RAW = os.path.join(TMP, "uploaded_videos.raw")
UPLOADED_OUT = os.path.join(TMP, "uploaded_videos.json")
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


def read_uploaded() -> dict:
    """读取已上传名单（纯 JSON 对象格式，不再兼容旧格式）。
    返回 dict: filename -> {uploaded_at: str, size_bytes: int, ...}（O(1) 键查找）
    """
    empty = {}
    if not os.path.exists(UPLOADED_RAW):
        print(f"[read_uploaded] 文件不存在，视为空: {UPLOADED_RAW}")
        return empty
    size = os.path.getsize(UPLOADED_RAW)
    if size == 0:
        print(f"[read_uploaded] 文件为空: {UPLOADED_RAW}")
        return empty

    print(f"[read_uploaded] 开始读取，文件大小: {size} bytes, 路径: {UPLOADED_RAW}")
    try:
        with open(UPLOADED_RAW, "r", encoding="utf-8") as f:
            data = json.load(f)

        # v1 格式: {"version": 1, "uploaded": {"file.mp4": {meta}}}
        if isinstance(data, dict) and isinstance(data.get("uploaded"), dict):
            filtered = {}
            for fn, meta in data["uploaded"].items():
                if isinstance(fn, str) and fn and isinstance(meta, dict):
                    filtered[fn] = meta
                elif isinstance(fn, str) and fn:
                    filtered[fn] = {}
            print(f"[read_uploaded] v1 JSON 对象格式解析成功，有效条目数: {len(filtered)}")
            return filtered

        # 兼容简写格式（直接一个对象就是 uploaded）
        if isinstance(data, dict):
            filtered = {}
            for fn, meta in data.items():
                if isinstance(fn, str) and fn and isinstance(meta, dict):
                    filtered[fn] = meta
                elif isinstance(fn, str) and fn and meta is None:
                    filtered[fn] = {}
            if filtered:
                print(f"[read_uploaded] 简写对象格式解析成功，有效条目数: {len(filtered)}")
                return filtered

        print(f"[read_uploaded] WARN: JSON 结构不匹配，返回空。根节点类型: {type(data).__name__}")
    except json.JSONDecodeError as e:
        print(f"[read_uploaded] ERROR: JSON 解析失败（旧格式已不再兼容，按空处理）: {e}")
    except Exception as e:
        print(f"[read_uploaded] ERROR: 读取失败: {type(e).__name__}: {e}")
    return empty


def write_uploaded(uploaded: dict):
    """写回 uploaded_videos.json（v1 JSON 对象格式，保留扩展字段）。"""
    print(f"[write_uploaded] 开始写入（v1 JSON 对象），条目数: {len(uploaded)}, 路径: {UPLOADED_OUT}")
    if uploaded:
        sample = sorted(uploaded.keys(), key=lambda x: x.lower())[:5]
        print(f"[write_uploaded] 前 5 条示例: {sample!r}")
    payload = {
        "version": 1,
        "uploaded": {k: (v if isinstance(v, dict) else {}) for k, v in uploaded.items()},
    }
    try:
        with open(UPLOADED_OUT, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        size = os.path.getsize(UPLOADED_OUT)
        print(f"[write_uploaded] 写入完成，文件大小: {size} bytes")
    except Exception as e:
        print(f"[write_uploaded] ERROR: 写入失败: {type(e).__name__}: {e}")
        raise


def human_size(num):
    """与 du -h 风格一致：1024 进制、四舍五入取整，单位 B/K/M/G/T。"""
    num = float(num)
    for unit in ("B", "K", "M", "G", "T"):
        if num < 1024 or unit == "T":
            return f"{round(num)}{unit}"
        num /= 1024
    return f"{round(num)}T"


def get_video_list():
    """通过 rclone lsjson 获取远端视频文件列表，返回 [(modtime, filename, size_bytes)]。"""
    lsjson_path = os.path.join(TMP, "ls.json")
    err_path = os.path.join(TMP, "lsjson.err")
    result = run(f"rclone lsjson --recursive {SOURCE_REMOTE}/")
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
        videos.append((it.get("ModTime") or "", path, it.get("Size") or 0))

    # 旧的先处理
    videos.sort(key=lambda x: x[0])
    return videos, skipped


def main():
    uploaded = read_uploaded()
    all_videos, skipped = get_video_list()

    # 去重：保留原始值，不 NFC 归一化
    seen = set()
    deduped = []
    for modtime, p, sz in all_videos:
        if p in seen:
            skipped.append(("duplicate", p))
            continue
        seen.add(p)
        deduped.append((modtime, p, sz))
    all_videos = deduped

    pending = [(m, p, sz) for m, p, sz in all_videos if p not in uploaded]

    total = len(all_videos)
    pending_count = len(pending)
    uploaded_before = len(uploaded)
    # 保持原 rclone lsjson 日志（含所有条目数），下一行按用户要求输出统一的统计格式
    print(f"rclone lsjson 返回 {total + len(skipped)} 条条目，视频文件 {total} 条，已上传 {uploaded_before} 条，待上传 {pending_count} 条，失败上传 0 条")
    print(f"视频文件 {total} 条，已上传 {uploaded_before} 条，待上传 {pending_count} 条，失败上传 0 条")
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

    for modtime, file, size in pending:
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

        print(f"⬇️  正在下载: {file} (大小 {human_size(size)} / {size} bytes, 修改时间 {modtime_display})")
        dl_start = time.time()
        # 捕获输出：rclone 原始进度属于噪音，靠 ✅ 标记即可；失败时再打印 stderr 便于排查
        result = run(["rclone", "copyto", f"{SOURCE_REMOTE}/{file}", local_file])
        dl_elapsed = time.time() - dl_start
        if result.returncode != 0 or not os.path.isfile(local_file):
            err_msg = f"❌ FAILED: rclone copy failed: {file} (耗时 {dl_elapsed:.2f}s)"
            print(err_msg)
            print("--- rclone 错误输出 ---")
            print(result.stderr[-2000:] if result.stderr else "(无错误输出)")
            print("------------------------")
            failed += 1
            failed_list.append(f"- {file}（rclone copy failed, {dl_elapsed:.2f}s）")
            notify(f"{err_msg}\n{CAPTION_PREFIX}\nrclone stderr 见 Actions 日志")
            continue
        file_size = os.path.getsize(local_file)
        print(f"✅ 下载完成: {file} (大小 {human_size(file_size)} / {file_size} bytes, 耗时 {dl_elapsed:.2f}s)")

        # 预处理 + 上传到 Telegram
        proc_one = os.path.join(GITHUB_WORKSPACE, ".github", "scripts", "transcode_and_send.sh")
        print(f"🎬 开始处理/上传: {file}")
        up_start = time.time()
        # 透传输出：转码/上传进度实时进 Actions 日志，避免长时间静默
        up_result = run(["bash", proc_one, local_file, CHANNEL_ID, modtime_display], capture=False)
        up_elapsed = time.time() - up_start
        if up_result.returncode == 0:
            uploaded_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            # source_modified_at: 将 rclone lsjson 返回的 ISO 时间标准化为带 Z 后缀的 UTC 格式
            source_modified_at = modtime
            if modtime:
                try:
                    dt_src = datetime.fromisoformat(modtime.replace("Z", "+00:00"))
                    source_modified_at = dt_src.strftime("%Y-%m-%dT%H:%M:%SZ")
                except Exception:
                    pass
            # source_created_at: 从本地下载的文件获取创建时间（macOS st_birthtime / Linux st_ctime）
            source_created_at = ""
            try:
                st = os.stat(local_file)
                ct = getattr(st, 'st_birthtime', None) or st.st_ctime
                source_created_at = datetime.fromtimestamp(ct, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            except OSError:
                pass
            uploaded[file] = {
                "uploaded_at": uploaded_at,
                "size_bytes": file_size,
                "size": human_size(file_size),
                "source_created_at": source_created_at,
                "source_modified_at": source_modified_at or "",
            }
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
        "uploaded_before": uploaded_before,
        "uploaded_total": len(uploaded),
        "pending": pending_count,
        "remaining": total - len(uploaded),
        "sent": sent,
        "failed": failed,
        "skipped_count": len(skipped),
        "skipped_details": "\n".join(f"{reason}: {path}" for reason, path in skipped),
        "sent_list": "\n".join(sent_list),
        "failed_list": "\n".join(failed_list),
    }
    with open(STATS_FILE, "w", encoding="utf-8") as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)

    summary_line = f"视频文件 {total} 条，已上传 {len(uploaded)} 条，待上传 {total - len(uploaded)} 条，失败上传 {failed} 条"
    print(summary_line)
    print(f"上传完成: 成功 {sent}, 失败 {failed}")


if __name__ == "__main__":
    main()
PYEOF

PYTHON_EXIT=$?
if [ $PYTHON_EXIT -ne 0 ]; then
  echo "ERROR: Python 处理脚本失败，退出码 $PYTHON_EXIT"
  exit $PYTHON_EXIT
fi

# 上传更新后的 uploaded_videos.json 回 OneDrive
rclone copyto "$TMP_DIR/uploaded_videos.json" "$SOURCE_REMOTE/uploaded_videos.json" 2>/dev/null

# 读取 Python 输出的统计
STATS_FILE="$TMP_DIR/stats.json"
TOTAL_VIDEOS=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('total',0))" 2>/dev/null || echo 0)
UPLOADED_TOTAL=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('uploaded_total',0))" 2>/dev/null || echo 0)
REMAINING=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('remaining',0))" 2>/dev/null || echo 0)
PENDING_COUNT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('pending',0))" 2>/dev/null || echo 0)
SENT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('sent',0))" 2>/dev/null || echo 0)
FAILED=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('failed',0))" 2>/dev/null || echo 0)
SKIPPED_COUNT=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('skipped_count',0))" 2>/dev/null || echo 0)
SENT_LIST=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('sent_list',''))" 2>/dev/null || echo "")
FAILED_LIST=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('failed_list',''))" 2>/dev/null || echo "")
SKIPPED_DETAILS=$(python3 -c "import json,sys; d=json.load(open('$STATS_FILE')); print(d.get('skipped_details',''))" 2>/dev/null || echo "")

# 发送通知
source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"

SUMMARY_LINE="视频文件 ${TOTAL_VIDEOS} 条，已上传 ${UPLOADED_TOTAL} 条，待上传 ${REMAINING} 条，失败上传 ${FAILED} 条"
HEADER="📺 ${CAPTION_PREFIX}"$'\n'"${SUMMARY_LINE}"$'\n'"📊 本次处理: ${PENDING_COUNT}"$'\n'"✅ 成功: ${SENT}"$'\n'"❌ 失败: ${FAILED}"
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
