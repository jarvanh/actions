#!/usr/bin/env python3
"""原子性地向 uploaded_videos.json 追加一个已上传条目。

避免 shell 中用 >> 追加纯文本破坏 JSON 结构。

用法: add_uploaded_video.py <json_file_path> <filename> [size_bytes] [source_modified_at] [source_created_at]

  json_file_path      - uploaded_videos.json 的本地路径
  filename            - 成功上传的视频文件名（作为 dict 键）
  size_bytes          - 可选，文件大小（整数 bytes）
  source_modified_at  - 可选，视频源的修改时间（ISO 格式）；不传则从本地文件 mtime 推断
  source_created_at   - 可选，视频源的创建时间（ISO 格式）；不传则从本地文件 birthtime/ctime 推断

写回策略: 临时文件 + os.replace 原子替换，同目录下保证写文件过程中进程崩溃不丢失已有数据。
JSON 结构与 sync_to_tg.sh 保持一致 v1 版本：
{
  "version": 1,
  "uploaded": {
    "filename": {
      "uploaded_at": "2025-08-11T10:00:00Z",
      "size_bytes": 119600942,
      "size": "114.06MB",
      "source_created_at": "2017-01-10T08:27:22Z",
      "source_modified_at": "2017-01-10T08:27:22Z"
    }
  }
}
"""
import json
import os
import sys
import tempfile
from datetime import datetime, timezone


def load_existing(path: str) -> dict:
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return {"version": 1, "uploaded": {}}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("uploaded"), dict):
            if "version" not in data:
                data["version"] = 1
            return data
        if isinstance(data, dict) and not isinstance(data.get("uploaded"), dict):
            return {"version": 1, "uploaded": {}}
    except json.JSONDecodeError:
        print(f"[add_uploaded_video] WARN: 现有文件 JSON 解析失败，按空结构重建: {path}")
    except Exception as e:
        print(f"[add_uploaded_video] WARN: 读取失败，按空结构重建: {type(e).__name__}: {e}")
    return {"version": 1, "uploaded": {}}


def atomic_write(path: str, payload: dict):
    dir_ = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(dir_, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".uploaded_videos.", suffix=".json.tmp", dir=dir_)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def local_file_to_iso(filepath: str, attr: str = "mtime") -> str:
    """读取本地文件时间并格式化为 ISO 8601 UTC 字符串。
    attr: "mtime" → 修改时间, "ctime" → 创建时间（birthtime 优先，fallback ctime）
    """
    try:
        st = os.stat(filepath)
        if attr == "ctime":
            # macOS/FreeBSD: st_birthtime, Linux: st_ctime (inode change time)
            ts = getattr(st, 'st_birthtime', None) or st.st_ctime
        else:
            ts = st.st_mtime
        return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return ""


def human_size(num_bytes: int) -> str:
    """将字节数格式化为易读字符串：B / KB / MB / GB / TB（1024 进制，保留 2 位小数）。"""
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.2f}{unit}"
        size /= 1024
    return f"{size:.2f}TB"


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <json_file_path> <filename> [size_bytes] [source_modified_at] [source_created_at]", file=sys.stderr)
        sys.exit(2)

    json_path = sys.argv[1]
    filename = sys.argv[2]
    size_bytes = None
    source_modified_at = None
    source_created_at = None

    if len(sys.argv) >= 4:
        try:
            size_bytes = int(sys.argv[3])
        except ValueError:
            pass
    if len(sys.argv) >= 5:
        source_modified_at = sys.argv[4] or None
    if len(sys.argv) >= 6:
        source_created_at = sys.argv[5] or None

    if not filename:
        print("ERROR: filename 为空", file=sys.stderr)
        sys.exit(2)

    # 若未显式传 size_bytes，尝试基于文件名在同目录下找同名本地文件读取 stat
    if size_bytes is None:
        candidates = [
            os.path.join(os.path.dirname(json_path) or ".", filename),
        ]
        for cand in candidates:
            if os.path.isfile(cand):
                size_bytes = os.path.getsize(cand)
                # 如果没传 source_modified_at / source_created_at，也从本地文件推断
                if source_modified_at is None:
                    source_modified_at = local_file_to_iso(cand, "mtime")
                if source_created_at is None:
                    source_created_at = local_file_to_iso(cand, "ctime")
                break

    data = load_existing(json_path)
    entry = {"uploaded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if size_bytes is not None:
        entry["size_bytes"] = size_bytes
        entry["size"] = human_size(size_bytes)
    if source_created_at:
        entry["source_created_at"] = source_created_at
    if source_modified_at:
        entry["source_modified_at"] = source_modified_at
    data["uploaded"][filename] = entry

    atomic_write(json_path, data)
    print(f"[add_uploaded_video] 已记录: {filename} (total={len(data['uploaded'])}, size={entry.get('size','N/A')})", flush=True)


if __name__ == "__main__":
    main()
