#!/usr/bin/env python3
"""计算工作目录下的视频文件统计：总数 / 已上传 / 待上传 / 失败上传 / 损坏已跳过

用法: compute_video_stats.py <target_dir>
输出: total|uploaded|pending|failed|corrupt  (管道符分隔的一行)

读取 uploaded_videos.json（v1 JSON 对象格式）。不再兼容旧的 .txt 格式。
同时读取 failed_videos.json（v1 JSON 对象格式），命中损坏指纹的文件不再计入"待上传"
——它们指纹不变就不会被重试，计入待上传会形成永远清不掉的假库存。
"""
import os, json, sys

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm", ".m4v", ".ts"}


def read_uploaded(uploaded_file: str) -> int:
    """返回已上传条目数（只统计键数）。"""
    if not os.path.isfile(uploaded_file) or os.path.getsize(uploaded_file) == 0:
        return 0
    try:
        with open(uploaded_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("uploaded"), dict):
            return len(data["uploaded"])
        # 简写格式（直接对象）
        if isinstance(data, dict):
            # 不是标准 v1，但如果所有值都是 dict，也统计一下
            if all(isinstance(v, dict) or v is None for v in data.values()):
                return len(data)
    except json.JSONDecodeError:
        print(f"[compute_video_stats] WARN: {uploaded_file} JSON 解析失败", file=sys.stderr)
    except Exception as e:
        print(f"[compute_video_stats] WARN: 读取失败: {type(e).__name__}: {e}", file=sys.stderr)
    return 0


def read_corrupt(failed_file: str) -> dict:
    """返回损坏名单: filename -> meta（含 size_bytes / source_modified_at 指纹）。"""
    if not os.path.isfile(failed_file) or os.path.getsize(failed_file) == 0:
        return {}
    try:
        with open(failed_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        failed = data.get("failed") if isinstance(data, dict) else None
        if not isinstance(failed, dict):
            failed = data if isinstance(data, dict) else {}
        return {
            fn: (meta if isinstance(meta, dict) else {})
            for fn, meta in failed.items()
            if isinstance(fn, str) and fn
        }
    except Exception as e:
        print(f"[compute_video_stats] WARN: 读取 {failed_file} 失败: {type(e).__name__}: {e}", file=sys.stderr)
        return {}


def count_corrupt(target_dir: str, video_files: list, failed_map: dict) -> int:
    """统计命中损坏指纹的视频数（文件名命中 + size_bytes 指纹一致；无指纹时仅按文件名）。"""
    corrupt = 0
    for name in video_files:
        meta = failed_map.get(name)
        if meta is None:
            continue
        size = meta.get("size_bytes")
        if size is None:
            corrupt += 1
            continue
        try:
            if int(size) == os.path.getsize(os.path.join(target_dir, name)):
                corrupt += 1
        except OSError:
            continue
    return corrupt


def main():
    if len(sys.argv) < 2:
        print("Usage: compute_video_stats.py <target_dir>", file=sys.stderr)
        print("0|0|0|0|0")
        sys.exit(0)
    target_dir = os.path.expanduser(sys.argv[1])

    # 统计视频文件总数
    total = 0
    video_files = []
    if os.path.isdir(target_dir):
        try:
            entries = os.listdir(target_dir)
        except OSError:
            entries = []
        for f in entries:
            if os.path.splitext(f)[1].lower() in VIDEO_EXTS:
                total += 1
                video_files.append(f)

    uploaded_file = os.path.join(target_dir, "uploaded_videos.json")
    uploaded_count = read_uploaded(uploaded_file)
    corrupt = count_corrupt(
        target_dir, video_files, read_corrupt(os.path.join(target_dir, "failed_videos.json"))
    )
    pending = max(total - uploaded_count - corrupt, 0)
    failed = 0

    print(f"{total}|{uploaded_count}|{pending}|{failed}|{corrupt}")


if __name__ == "__main__":
    main()
