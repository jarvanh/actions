#!/usr/bin/env python3
"""计算工作目录下的视频文件统计：总数 / 已上传 / 待上传 / 失败上传

用法: compute_video_stats.py <target_dir>
输出: total|uploaded|pending|failed  (管道符分隔的一行)

读取 uploaded_videos.json（v1 JSON 对象格式）。不再兼容旧的 .txt 格式。
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


def main():
    if len(sys.argv) < 2:
        print("Usage: compute_video_stats.py <target_dir>", file=sys.stderr)
        print("0|0|0|0")
        sys.exit(0)
    target_dir = os.path.expanduser(sys.argv[1])

    # 统计视频文件总数
    total = 0
    if os.path.isdir(target_dir):
        try:
            entries = os.listdir(target_dir)
        except OSError:
            entries = []
        for f in entries:
            if os.path.splitext(f)[1].lower() in VIDEO_EXTS:
                total += 1

    uploaded_file = os.path.join(target_dir, "uploaded_videos.json")
    uploaded_count = read_uploaded(uploaded_file)
    pending = max(total - uploaded_count, 0)
    failed = 0

    print(f"{total}|{uploaded_count}|{pending}|{failed}")


if __name__ == "__main__":
    main()
