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

def nfc(s: str) -> str:
    """统一 Unicode 归一化（解决 macOS NFD 与其他系统 NFC 对同一字符编码字节不同的问题）。"""
    return unicodedata.normalize("NFC", s)

def clean_name(raw: str) -> str:
    """剥离 BOM、控制字符、首尾空白/回车。保留合法文件名内部字符（包括 ; 和中文）。"""
    # 去掉 BOM (U+FEFF)
    s = raw.lstrip("\ufeff")
    # 去掉首尾 C0 控制字符 (\x00-\x1f)、\x7f、空白
    s = s.strip("\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f"
                "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f ")
    return s

# ------- 3a. 解析 lsjson，产出 all_videos 列表（按 ModTime 从旧到新排序） -------
all_entries = []   # list of (modtime_str, original_path, cleaned_path)
raw_count = 0
suspicious = []

lsjson_path = os.path.join(TMP, "ls.json")
if os.path.getsize(lsjson_path) if os.path.exists(lsjson_path) else 0:
    try:
        with open(lsjson_path, "rb") as f:
            data = f.read()
        # 某些版本 rclone 输出开头可能带 BOM，剥离
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
        cleaned = clean_name(path)
        # 扩展名判断（对 cleaned 做，并且用 NFC 归一化但 ext 是 ASCII 其实无所谓）
        ext = os.path.splitext(cleaned)[1].lower()
        if ext not in VIDEO_EXTS:
            continue
        # 空主名（纯扩展名 ".mp4" 这种）跳过
        if not cleaned or os.path.splitext(cleaned)[0] == "":
            suspicious.append(f"empty basename: {path!r}")
            continue
        # 安全检查：不允许路径分隔符（跨目录攻击）
        if "/" in cleaned or "\\" in cleaned or ".." in PurePosixPath(cleaned).parts:
            suspicious.append(f"path separator detected: {path!r}")
            continue
        # 原始 BOM / 控制字符被清理过，记日志
        if cleaned != path:
            suspicious.append(f"normalized name: {path!r} -> {cleaned!r}")
        modtime = it.get("ModTime") or ""
        all_entries.append((modtime, cleaned))

# 按修改时间升序排（旧的先处理）
all_entries.sort(key=lambda x: x[0])
all_videos = [p for _, p in all_entries]

# 去重（同一文件名可能因为大小写或编码差异在 OneDrive 上同时存在？Python set 用 NFC 做 key 但保留第一条）
seen_nfc = set()
deduped = []
for p in all_videos:
    k = nfc(p)
    if k in seen_nfc:
        continue
    seen_nfc.add(k)
    deduped.append(p)
all_videos = deduped

# 写入 all_videos.txt（UTF-8，每行一个文件名）
with open(ALL_VIDEOS, "wb") as f:
    for p in all_videos:
        f.write(p.encode("utf-8") + b"\n")

# ------- 3b. 读取 uploaded_videos.txt，构建已上传集合（NFC 归一化） -------
uploaded_raw_path = os.path.join(TMP, "uploaded_videos.raw")
uploaded_set = set()
if os.path.exists(uploaded_raw_path):
    with open(uploaded_raw_path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    for line in raw.split(b"\n"):
        if not line:
            continue
        try:
            s = line.decode("utf-8", errors="replace")
        except Exception:
            continue
        s = clean_name(s)
        if not s:
            continue
        uploaded_set.add(nfc(s))

# 再把 cleaned + 归一化后的 uploaded 写回 uploaded_videos.txt，供后面追加用
with open(UPLOADED, "wb") as f:
    for name in sorted(uploaded_set, key=lambda x: x.lower()):
        f.write(name.encode("utf-8") + b"\n")

# ------- 3c. 计算 pending = all_videos - uploaded（保留 all_videos 的 ModTime 顺序） -------
pending = [p for p in all_videos if nfc(p) not in uploaded_set]
with open(PENDING, "wb") as f:
    for p in pending:
        f.write(p.encode("utf-8") + b"\n")

# ------- 3d. 打印统计（shell 侧读数字用） -------
print(f"rclone lsjson 返回 {raw_count} 条条目，视频过滤后 {len(all_videos)} 条，已上传 {len(uploaded_set)} 条，待上传 {len(pending)} 条")
if suspicious:
    print(f"⚠️  文件名规范化条目数: {len(suspicious)}")
    for s in suspicious[:20]:
        print(f"   - {s}")
    if len(suspicious) > 20:
        print(f"   ... 其余 {len(suspicious)-20} 条省略")

# 如果 0 视频，把 lsjson 原始前几条打出来便于排错
if not all_videos and items:
    print("WARN: 没有合法视频，以下是 lsjson 前 5 条原始条目:")
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
  MSG="📺 ${CAPTION_PREFIX}"$'\n'"📊 源目录: ${TOTAL_VIDEOS} 个视频"$'\n'"✅ 已上传（归一化后）: $(( TOTAL_VIDEOS - PENDING_COUNT ))"$'\n'"⏳ 待上传: 0"$'\n\n'"没有新视频需要上传"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode text="${MSG}"
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
# pending.txt 由 Python 生成，已是规范 UTF-8，每行一个文件名且不含 BOM/控制字符。
# 这里仍保留 IFS= + -r，并加一层轻量防御性归一化（万一后续有人手工改了 pending.txt）
while IFS= read -r file || [ -n "$file" ]; do
  # 防御性再清理一次
  file=$(printf '%s' "$file" | python3 -c "import sys,unicodedata; s=sys.stdin.buffer.read(); s=s.lstrip(b'\xef\xbb\xbf').rstrip(b'\r\n\x00\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e\x0f\t '); sys.stdout.buffer.write(s)" 2>/dev/null || printf '%s' "$file")
  # 跳过空
  [ -z "$file" ] && continue
  # 纯扩展名跳过
  case "$file" in
    .*) [ -z "${file%.*}" ] && { echo "SKIP suspicious: '$file'"; continue; } ;;
  esac

  # 安全的本地文件名
  safe_local_name=$(basename "$file")
  [ -z "$safe_local_name" ] && { echo "SKIP empty basename: '$file'"; continue; }

  WORK_DIR="$TMP_DIR/work"
  LOCAL_FILE="$WORK_DIR/$safe_local_name"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  # ===== 第一步：从 OneDrive 下载视频到本地 =====
  # rclone copyto 用于单文件：远程路径必须严格与 OneDrive 实际文件名匹配
  # （我们已经在 Python 阶段做了 NFC 归一化 + BOM 清理，确保路径一致）
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
    # 成功后记录到 uploaded（用规范化后的文件名）
    echo "$file" >> "$TMP_DIR/uploaded_videos.txt"
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

# 回写前用 Python 归一化 + 去重排序，保证下次 grep/NFC 对比零歧义
python3 - "$TMP_DIR/uploaded_videos.txt" <<'PYEOF'
import sys, os, unicodedata

path = sys.argv[1]
if not os.path.exists(path):
    sys.exit(0)

def clean(s: str) -> str:
    s = s.lstrip("\ufeff")
    s = s.strip("\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r\x0e\x0f"
                "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f ")
    return unicodedata.normalize("NFC", s)

with open(path, "rb") as f:
    raw = f.read()
if raw.startswith(b"\xef\xbb\xbf"):
    raw = raw[3:]
names = set()
for line in raw.split(b"\n"):
    if not line:
        continue
    try:
        s = line.decode("utf-8", errors="replace")
    except Exception:
        continue
    s = clean(s)
    if s:
        names.add(s)

lines = sorted(names, key=lambda x: x.lower())
with open(path, "wb") as f:
    for n in lines:
        f.write(n.encode("utf-8") + b"\n")
PYEOF

rclone copyto "$TMP_DIR/uploaded_videos.txt" "$SOURCE_REMOTE/uploaded_videos.txt" 2>/dev/null

echo "上传完成: 成功 $SENT, 失败 $FAILED"

MSG="📺 ${CAPTION_PREFIX} 上传完成"$'\n\n'"📊 总计: ${PENDING_COUNT}"$'\n'"✅ 成功: ${SENT}"$'\n'"❌ 失败: ${FAILED}"
if [ -n "$SENT_LIST" ]; then
  MSG+=$'\n\n'"✅ 已上传:"$'\n'"${SENT_LIST}"
fi
if [ -n "$FAILED_LIST" ]; then
  MSG+=$'\n\n'"❌ 失败:"$'\n'"${FAILED_LIST}"
fi
MSG+=$'\n\n'"🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode text="${MSG}"

rm -rf "$TMP_DIR"
