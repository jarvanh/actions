#!/bin/bash
# 共享脚本：转码并上传视频到 Telegram 频道
# 用法: process_and_upload.sh <SOURCE_REMOTE> <CHANNEL_ID> <CAPTION_PREFIX>
# 环境变量: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE, GITHUB_REPOSITORY, GITHUB_RUN_ID

set +e

# 强制使用 C.UTF-8 locale，保证所有文本处理对 UTF-8 文件名（含中文、特殊符号）一致
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

SOURCE_REMOTE="$1"
CHANNEL_ID="$2"
CAPTION_PREFIX="$3"

TMP_DIR="/tmp/tg-upload"
mkdir -p "$TMP_DIR"

###############################################################################
# 阶段一：用 rclone lsjson + Python 获取远端文件列表并计算 pending
# —— 彻底避免「rclone 打印文本 → shell cut/sort/grep 解析」的编码/分隔符歧义
#    整个列表获取和 pending 过滤统一在 Python 里完成
###############################################################################

# 1. 拉取 uploaded_videos.txt 到本地（已上传名单）
rclone cat "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null > "$TMP_DIR/uploaded_videos.raw" || true

# 2. 拉取远端目录的 JSON 列表（结构化，零歧义）
#    lsjson 输出固定 JSON 数组；Path 字段即为相对目录的文件名（不含子路径）
rclone lsjson "$SOURCE_REMOTE/" 2>"$TMP_DIR/lsjson.err" > "$TMP_DIR/ls.json" || true

# 3. Python 统一处理：解析 JSON → 过滤视频扩展名 → 按修改时间升序 →
#    读取 uploaded → NFC 归一化 → 计算 pending → 写入三个输出文件
#    同时打印统计信息到 stdout，并把遇到的异常文件名（BOM/空文件名）打印出来
python3 - "$SOURCE_REMOTE" "$TMP_DIR" <<'PYEOF'
import sys, os, json, unicodedata, re
from pathlib import PurePosixPath

SOURCE_REMOTE = sys.argv[1]
TMP = sys.argv[2]

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".flv", ".wmv", ".webm", ".m4v", ".ts"}
ALL_VIDEOS = os.path.join(TMP, "all_videos.txt")
PENDING   = os.path.join(TMP, "pending.txt")
UPLOADED  = os.path.join(TMP, "uploaded_videos.txt")
SKIPPED   = os.path.join(TMP, "skipped.txt")  # 仅用于记录非视频文件/安全异常

# 原则：只要 lsjson 能列出来的文件，rclone 就能访问。
# 我们只做最小必要处理：
#   1) 按扩展名筛选视频（目录里的 uploaded_videos.txt、archive.txt 等不是视频）
#   2) 拒绝包含路径分隔符的文件名（安全）
#   3) 保留原始文件名，不清理、不修改、不归一化，全部原样交给 rclone
#   4) 去重和判断是否已上传时，使用字节级/原始字符串比较（不 NFC）

def is_video_file(path: str) -> bool:
    """仅按扩展名判断是否是视频文件。"""
    if not path:
        return False
    ext = os.path.splitext(path)[1].lower()
    return ext in VIDEO_EXTS

def is_safe_path(path: str) -> bool:
    """检查不包含路径分隔符或跨目录。"""
    return "/" not in path and "\\" not in path and ".." not in PurePosixPath(path).parts

# ------- 3a. 解析 lsjson，产出 all_videos 列表（按 ModTime 从旧到新排序） -------
# 使用 lsjson 返回的原始 Path，不做任何修改。
all_entries = []   # list of (modtime_str, original_path)
raw_count = 0
skipped = []       # 仅记录非视频/不安全路径，这些确实不是我们要处理的视频

lsjson_path = os.path.join(TMP, "ls.json")
if os.path.getsize(lsjson_path) if os.path.exists(lsjson_path) else 0:
    try:
        with open(lsjson_path, "rb") as f:
            data = f.read()
        # 只剥离整个 JSON 文本可能的 BOM，不改变文件名内容
        if data.startswith(b"\xef\xbb\xbf"):
            data = data[3:]
        items = json.loads(data.decode("utf-8", errors="replace"))
    except Exception as e:
        print(f"WARN: rclone lsjson 解析失败: {e}", file=sys.stderr)
        items = []
else:
    print("WARN: rclone lsjson 返回空，尝试读取 stderr:")
    err_path = os.path.join(TMP, "lsjson.err")
    if os.path.exists(err_path) and os.path.getsize(err_path):
        with open(err_path, "r", errors="replace") as ef:
            sys.stderr.write(ef.read()[:2000])
    items = []

if isinstance(items, list):
    for it in items:
        if not isinstance(it, dict):
            continue
        if it.get("IsDir"):
            continue
        path = it.get("Path") or it.get("Name") or ""
        if not path:
            continue
        raw_count += 1
        if not is_video_file(path):
            skipped.append(f"NOT_VIDEO: {path!r}")
            continue
        if not is_safe_path(path):
            skipped.append(f"UNSAFE_PATH: {path!r}")
            continue
        modtime = it.get("ModTime") or ""
        all_entries.append((modtime, path))

# 按修改时间升序排（旧的先处理）
all_entries.sort(key=lambda x: x[0])
all_videos = [p for _, p in all_entries]

# 去重：保留原始值，不做任何归一化（如果 OneDrive 上有两个"看起来一样"但实际编码不同的文件，也当作不同文件处理）
seen = set()
deduped = []
for p in all_videos:
    if p in seen:
        skipped.append(f"DUPLICATE: {p!r}")
        continue
    seen.add(p)
    deduped.append(p)
all_videos = deduped

# 写入 all_videos.txt（UTF-8，原始文件名，每行一个）
with open(ALL_VIDEOS, "wb") as f:
    for p in all_videos:
        f.write(p.encode("utf-8") + b"\n")

# ------- 3b. 读取 uploaded_videos.txt，构建已上传集合（原始字符串精确匹配） -------
uploaded_raw_path = os.path.join(TMP, "uploaded_videos.raw")
uploaded_set = set()
uploaded_names = []  # 原始文件名列表，用于回写
if os.path.exists(uploaded_raw_path):
    with open(uploaded_raw_path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    for line in raw.split(b"\n"):
        if not line:
            continue
        # 仅去掉行尾的 \r\n（Windows 换行兼容），不修改文件名内容
        line = line.rstrip(b"\r\n")
        if not line:
            continue
        try:
            s = line.decode("utf-8", errors="replace")
        except Exception:
            continue
        if not s:
            continue
        uploaded_set.add(s)
        uploaded_names.append(s)

# 去重并排序后写回 uploaded_videos.txt（保留原始文件名）
uploaded_names = sorted(set(uploaded_names), key=lambda x: x.lower())
with open(UPLOADED, "wb") as f:
    for name in uploaded_names:
        f.write(name.encode("utf-8") + b"\n")

# ------- 3c. 计算 pending = all_videos - uploaded（保留 all_videos 的 ModTime 顺序） -------
# 精确字符串匹配：原始文件名对原始文件名
pending = [p for p in all_videos if p not in uploaded_set]
with open(PENDING, "wb") as f:
    for p in pending:
        f.write(p.encode("utf-8") + b"\n")

# ------- 3d. 写入跳过/非视频文件列表，打印统计 -------
with open(SKIPPED, "wb") as f:
    for s in skipped:
        f.write(s.encode("utf-8") + b"\n")

print(f"rclone lsjson 返回 {raw_count} 条条目，视频文件 {len(all_videos)} 条，已上传 {len(uploaded_set)} 条，待上传 {len(pending)} 条")
if skipped:
    print(f"非视频/跳过文件数: {len(skipped)}")
    from collections import Counter
    reasons = Counter()
    for s in skipped:
        reason = s.split(":", 1)[0]
        reasons[reason] += 1
    for reason, cnt in reasons.most_common():
        print(f"   - {reason}: {cnt} 个")
    print(f"   详情见 {SKIPPED}")

# 如果 0 视频，把 lsjson 原始前几条打出来便于排错
if not all_videos and items:
    print("WARN: 没有视频文件，以下是 lsjson 前 5 条原始条目:")
    for it in items[:5]:
        try:
            print(" ", json.dumps(it, ensure_ascii=False)[:300])
        except Exception:
            print(" ", repr(it)[:300])
PYEOF

# shell 侧读取统计（纯数字，从 Python 输出里取可能不可靠，直接用 wc 更稳）
TOTAL_VIDEOS=$(wc -l < "$TMP_DIR/all_videos.txt" | tr -d ' ')
PENDING_COUNT=$(wc -l < "$TMP_DIR/pending.txt" | tr -d ' ')
[ -z "$TOTAL_VIDEOS" ] && TOTAL_VIDEOS=0
[ -z "$PENDING_COUNT" ] && PENDING_COUNT=0

echo "源目录视频总数: $TOTAL_VIDEOS, 待上传: $PENDING_COUNT"

if [ "$PENDING_COUNT" -eq 0 ] || [ ! -s "$TMP_DIR/pending.txt" ]; then
  echo "没有新视频需要上传"
  source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"
  SKIPPED_COUNT=0
  SKIPPED_CONTENT=""
  if [ -f "$TMP_DIR/skipped.txt" ]; then
    SKIPPED_COUNT=$(wc -l < "$TMP_DIR/skipped.txt" | tr -d ' ')
    if [ "$SKIPPED_COUNT" -gt 0 ]; then
      SKIPPED_CONTENT=$(cat "$TMP_DIR/skipped.txt")
    fi
  fi
  HEADER="📺 ${CAPTION_PREFIX}"$'\n'"📊 源目录: ${TOTAL_VIDEOS} 个视频"$'\n'"✅ 已上传（归一化后）: $(( TOTAL_VIDEOS - PENDING_COUNT ))"$'\n'"⏳ 待上传: 0"
  if [ "$SKIPPED_COUNT" -gt 0 ]; then
    HEADER+=$'\n'"⚠️ 跳过/过滤: ${SKIPPED_COUNT}"
  fi
  HEADER+=$'\n\n'"没有新视频需要上传"
  send_tg "$HEADER"
  if [ -n "$SKIPPED_CONTENT" ]; then
    send_tg_chunked "⚠️ 跳过/过滤文件详情:"$'\n\n'"${SKIPPED_CONTENT}"
  fi
  send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  rm -rf "$TMP_DIR"
  exit 0
fi

###############################################################################
# 阶段二：顺序处理每个 pending 视频
###############################################################################

SENT=0
FAILED=0
SENT_LIST=""
FAILED_LIST=""

# 顺序处理每个视频（不并行，避免 OneDrive 限速和 Telegram API 并发限制）
# pending.txt 由 Python 生成，包含从 rclone lsjson 获取的原始文件名。
# 我们不再对文件名做任何清理/过滤，直接交给 rclone 原样访问。
while IFS= read -r file || [ -n "$file" ]; do
  # 仅做最小安全校验：非空、不含路径分隔符
  [ -z "$file" ] && continue
  case "$file" in
    */*|*\\*) echo "SKIP unsafe path separator: $file"; continue ;;
  esac

  # 本地临时文件名直接使用原始文件名（Linux 支持 UTF-8）
  safe_local_name=$(basename "$file")
  [ -z "$safe_local_name" ] && { echo "SKIP empty basename: '$file'"; continue; }

  WORK_DIR="$TMP_DIR/work"
  LOCAL_FILE="$WORK_DIR/$safe_local_name"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  # ===== 第一步：从 OneDrive 下载视频到本地 =====
  # 远程路径使用原始文件名，不做任何修改！
  echo "⬇️  正在下载: $file"
  RCLONE_ERR="$TMP_DIR/rclone_err.log"
  if ! rclone copyto "$SOURCE_REMOTE/$file" "$LOCAL_FILE" 2>"$RCLONE_ERR" || [ ! -f "$LOCAL_FILE" ]; then
    echo "❌ FAILED: rclone copy failed: $file"
    echo "--- rclone 错误输出（最近 20 行）---"
    tail -n 20 "$RCLONE_ERR"
    echo "-----------------------------------"
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}（rclone copy failed）"$'\n'
    rm -rf "$WORK_DIR"
    continue
  fi
  echo "✅ 下载完成: $file"

  # ===== 第二步：预处理 + 上传到 Telegram =====
  if bash "${GITHUB_WORKSPACE}/.github/scripts/process_one_file.sh" "$LOCAL_FILE" "$CHANNEL_ID" "$CAPTION_PREFIX"; then
    # 成功后记录到 uploaded：使用原始文件名，不做任何归一化
    printf '%s\n' "$file" >> "$TMP_DIR/uploaded_videos.txt"
    SENT=$((SENT + 1))
    SENT_LIST+="- ${file}"$'\n'
  else
    FAILED=$((FAILED + 1))
    FAILED_LIST+="- ${file}"$'\n'
  fi

  rm -rf "$WORK_DIR"
done < "$TMP_DIR/pending.txt"

###############################################################################
# 阶段三：回写 uploaded_videos.txt + 汇总通知
###############################################################################

# 回写前用 Python 简单去重、排序（保留原始文件名，不做任何修改/归一化）
python3 - "$TMP_DIR/uploaded_videos.txt" <<'PYEOF'
import sys, os

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)

with open(path, "rb") as f:
    raw = f.read()
if raw.startswith(b"\xef\xbb\xbf"):
    raw = raw[3:]

names = set()
for line in raw.split(b"\n"):
    if not line:
        continue
    line = line.rstrip(b"\r\n")
    if not line:
        continue
    try:
        s = line.decode("utf-8", errors="replace")
    except Exception:
        continue
    if s:
        names.add(s)

lines = sorted(names, key=lambda x: x.lower())
with open(path, "wb") as f:
    for n in lines:
        f.write(n.encode("utf-8") + b"\n")
PYEOF

rclone copyto "$TMP_DIR/uploaded_videos.txt" "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null

echo "上传完成: 成功 $SENT, 失败 $FAILED"

# 使用 tg_notify.sh 分片发送长消息
source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"

SKIPPED_COUNT=0
SKIPPED_CONTENT=""
if [ -f "$TMP_DIR/skipped.txt" ]; then
  SKIPPED_COUNT=$(wc -l < "$TMP_DIR/skipped.txt" | tr -d ' ')
  if [ "$SKIPPED_COUNT" -gt 0 ]; then
    SKIPPED_CONTENT=$(cat "$TMP_DIR/skipped.txt")
  fi
fi

HEADER="📺 ${CAPTION_PREFIX} 上传完成"$'\n\n'"📊 总计: ${PENDING_COUNT}"$'\n'"✅ 成功: ${SENT}"$'\n'"❌ 失败: ${FAILED}"
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
if [ -n "$SKIPPED_CONTENT" ]; then
  send_tg_chunked "⚠️ 跳过/过滤文件详情:"$'\n\n'"${SKIPPED_CONTENT}"
fi
send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

rm -rf "$TMP_DIR"
