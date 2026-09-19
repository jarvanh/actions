#!/bin/bash
# 修复产物还原正确性 —— 本地临时目录**真 rclone** 实测（不用 mock rclone）
#
# 背景: 现有还原相关测试（test_marker_fixed.sh / test_hash_dir_fallback.sh 等）
#   一律 **mock 掉 rclone**，锁的是「判据与分支」；但用户真正关心的是
#   「**修复过的目录 / 文件，能不能真的还原回原目录、原文件名**」——
#   这是**端到端**性质，mock 测不出来（mock 不会真的搬文件）。
# 本测试补这一层: 用 rclone 的 **local 远端**（真二进制、真搬文件），
#   在 /tmp 下的临时目录里构造「修复产物」并跑真还原，断言落点路径与内容。
#
# 覆盖的还原形态（对应 restore_info.jq 的 kind 分类）:
#   1. short_hash_rename  — 方法2: 文件名变短哈希，目录不变
#   2. hash_dir           — 目录级折叠: 整条目录变 md5 短哈希目录（+ 可选短名）
#   3. copy (alt==orig)   — 方法1: 原路径原名，仅验存在
#   4. split_zip          — 方法3/4: 分卷 zip（需 7z；本环境无则标记跳过）
#
# ⚠️ 安全约束（用户明确要求）:
#   - **绝对不碰 rclone 源端**: SYNC_STATE_DIR 与 dest 全部指向 /tmp 临时目录，
#     本脚本只 source file_restore.sh 的**纯函数**并显式传 dest，
#     不调用会读 SYNC_STATE_DIR 默认值的入口（restore_fixed_files）。
#   - 全程在 mktemp -d 沙箱内，结束 trap 清理。
#
# 用法: bash test_restore_real_local.sh   （需 rclone 在 PATH；缺失则整件跳过）

set -u
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- 前置: rclone 必须为真二进制 ---
if ! command -v rclone >/dev/null 2>&1; then
  echo "SKIP: 本机无 rclone 二进制，整件跳过（CI ubuntu runner 上有）"
  exit 0
fi

# 排版助手 + 依赖（file_restore.sh 依赖 utils/telegram/sync_marker/rclone_flags）
source "$REPO_ROOT/.github/scripts/telegram/tg_notify.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/sync_marker.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/file_restore.sh"
# 未被上面加载时会缺数组，兜底（保持与生产一致的参数）
: "${RCLONE_RETRY_FLAGS:=()}"
if [ "${#RCLONE_RETRY_FLAGS[@]}" -eq 0 ]; then
  RCLONE_RETRY_FLAGS=(--retries 3 --low-level-retries 5 --contimeout 30s)
fi

SANDBOX="$(mktemp -d /tmp/restore_real_XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# ────────────────────────────────────────────────────────────
# 源端只读护栏（用户硬约束: 绝对不能修改 rclone 源端任何文件）
#   造一个"源端"快照，全测结束后比对 md5 清单，任何变化都直接判 FAIL
# ────────────────────────────────────────────────────────────
SRC_SIM="$SANDBOX/src_sim"
mkdir -p "$SRC_SIM/nested dir"
printf 'SOURCE-A' > "$SRC_SIM/plain.mp4"
printf 'SOURCE-B' > "$SRC_SIM/nested dir/中文 文件 (2024).mkv"
SRC_BEFORE="$(cd "$SRC_SIM" && find . -type f -exec md5sum {} \; | sort)"
SRC_LIST_BEFORE="$(cd "$SRC_SIM" && find . | sort)"
# 生产源端默认值也必须未被本测试改写（防止误用真实 onedrive: 等远端）
if [ "${SYNC_STATE_DIR:-}" != "onedrive:/logs/sync_state" ] && [ -n "${SYNC_STATE_DIR:-}" ]; then
  bad "源端护栏: SYNC_STATE_DIR 被改成 ${SYNC_STATE_DIR}（本测试不得改写源端）"
else
  ok "源端护栏: SYNC_STATE_DIR 未被改写（保持生产默认值或不设）"
fi

# local 远端: 直接指向沙箱目录用绝对路径即可（rclone local 支持绝对路径）
DEST="$SANDBOX/dest"
mkdir -p "$DEST"
TMP_BASE="$SANDBOX/tmpbase"
mkdir -p "$TMP_BASE"

# 计算短哈希（与 file_fix.sh 口径一致: md5(相对路径) 前 8 位）
sh8() { printf '%s' "$1" | md5sum | cut -c1-8; }

echo "=== 沙箱: $SANDBOX ==="
echo

# ────────────────────────────────────────────────────────────
# 场景 1: short_hash_rename（方法2）—— 目录不变，文件名变短哈希
# ────────────────────────────────────────────────────────────
echo "--- 场景1: 短哈希文件名（方法2）---"
ORIG1="subdir/Season 01/My Very Long Movie Name [1080p] - 中文标题.mp4"
NAME1="$(basename "$ORIG1")"
mkdir -p "$DEST/subdir/Season 01"
printf 'CONTENT-ONE' > "$DEST/subdir/Season 01/$(sh8 "$ORIG1").mp4"
ALT1="subdir/Season 01/$(sh8 "$ORIG1").mp4"

st=$(_restore_one_entry "$DEST" "$ORIG1" "$ALT1" "rclone copyto（原目录 + 短哈希文件名 $(sh8 "$ORIG1")）" "$TMP_BASE" "")
[ "$st" = "OK" ] && ok "1a 短哈希文件名还原返回 OK" || bad "1a 短哈希文件名还原返回 OK（实际: $st）"
[ -f "$DEST/$ORIG1" ] && ok "1b 原目录/原文件名已复原" || bad "1b 原目录/原文件名已复原（缺失 $ORIG1）"
[ ! -e "$DEST/$ALT1" ] && ok "1c 替代短名文件已移走（无残留）" || bad "1c 替代短名文件已移走（仍存在）"
[ "$(cat "$DEST/$ORIG1" 2>/dev/null)" = "CONTENT-ONE" ] && ok "1d 内容一致" || bad "1d 内容一致"

# ────────────────────────────────────────────────────────────
# 场景 2: hash_dir（目录级折叠）—— 整条目录变 md5 短哈希目录
#   这是用户最关心的「修复过的**目录**能不能还原」
# ────────────────────────────────────────────────────────────
echo "--- 场景2: 短哈希目录折叠（目录级兜底）---"
# 原目录相对路径（深层 + 中文 + 敏感字符形状）
ORIGDIR="movies/成人/2024 - Best Collection [4K]/"
ORIG2="movies/成人/2024 - Best Collection [4K]/Film Title (2024).mkv"
HASHDIR="$(sh8 "movies/成人/2024 - Best Collection [4K]")"
ALT2="${HASHDIR}/Film Title (2024).mkv"
mkdir -p "$DEST/$HASHDIR"
printf 'CONTENT-TWO' > "$DEST/$ALT2"

st=$(_restore_one_entry "$DEST" "$ORIG2" "$ALT2" "rclone copyto（短哈希目录 ${HASHDIR} + 原文件名）" "$TMP_BASE" "")
[ "$st" = "OK" ] && ok "2a 短哈希目录还原返回 OK" || bad "2a 短哈希目录还原返回 OK（实际: $st）"
[ -f "$DEST/$ORIG2" ] && ok "2b 原深层目录+原文件名已复原" || bad "2b 原深层目录+原文件名已复原（缺失 $ORIG2）"
[ ! -e "$DEST/$ALT2" ] && ok "2c 折叠目录内替代文件已移走" || bad "2c 折叠目录内替代文件已移走（仍存在）"
[ "$(cat "$DEST/$ORIG2" 2>/dev/null)" = "CONTENT-TWO" ] && ok "2d 内容一致" || bad "2d 内容一致"

# ────────────────────────────────────────────────────────────
# 场景 3: hash_dir + 短哈希文件名（目录与文件名双改）
# ────────────────────────────────────────────────────────────
echo "--- 场景3: 短哈希目录 + 短哈希文件名（双改）---"
ORIG3="shows/长目录名-With 中文/Some Extremely Long Episode Name S01E01.mkv"
HD3="$(sh8 "shows/长目录名-With 中文")"
ALT3="${HD3}/$(sh8 "$ORIG3").mkv"
mkdir -p "$DEST/$HD3"
printf 'CONTENT-THREE' > "$DEST/$ALT3"

st=$(_restore_one_entry "$DEST" "$ORIG3" "$ALT3" "rclone copyto（短哈希目录 ${HD3} + 短哈希文件名 $(sh8 "$ORIG3")）" "$TMP_BASE" "")
[ "$st" = "OK" ] && ok "3a 双改还原返回 OK" || bad "3a 双改还原返回 OK（实际: $st）"
[ -f "$DEST/$ORIG3" ] && ok "3b 原目录+原文件名双双复原" || bad "3b 原目录+原文件名双双复原（缺失 $ORIG3）"
[ "$(cat "$DEST/$ORIG3" 2>/dev/null)" = "CONTENT-THREE" ] && ok "3c 内容一致" || bad "3c 内容一致"

# ────────────────────────────────────────────────────────────
# 场景 4: alt == orig（方法1 原路径原名）—— 仅验存在，不该搬动
# ────────────────────────────────────────────────────────────
echo "--- 场景4: 原路径原名（方法1，仅验存在）---"
ORIG4="plain/Already Fine.mp4"
mkdir -p "$DEST/plain"
printf 'CONTENT-FOUR' > "$DEST/$ORIG4"
st=$(_restore_one_entry "$DEST" "$ORIG4" "$ORIG4" "rclone copyto（原路径 + 原文件名）" "$TMP_BASE" "")
[ "$st" = "OK" ] && ok "4a alt==orig 返回 OK" || bad "4a alt==orig 返回 OK（实际: $st）"
[ "$(cat "$DEST/$ORIG4" 2>/dev/null)" = "CONTENT-FOUR" ] && ok "4b 文件未被破坏" || bad "4b 文件未被破坏"

# 负例: alt==orig 但文件不存在 → 必须 FAIL 而非误报 OK
st=$(_restore_one_entry "$DEST" "plain/Ghost.mp4" "plain/Ghost.mp4" "rclone copyto（原路径 + 原文件名）" "$TMP_BASE" "")
[ "${st%%:*}" = "FAIL" ] && ok "4c alt==orig 但不存在 → FAIL（不误报）" || bad "4c alt==orig 但不存在 → FAIL（实际: $st）"

# ────────────────────────────────────────────────────────────
# 场景 5: 替代文件缺失 → 必须 FAIL（不能把"没搬成"当成功）
# ────────────────────────────────────────────────────────────
echo "--- 场景5: 替代文件不存在 → FAIL ---"
st=$(_restore_one_entry "$DEST" "subdir/Nope.mp4" "subdir/$(sh8 'zzz').mp4" "rclone copyto（原目录 + 短哈希文件名 x）" "$TMP_BASE" "")
[ "${st%%:*}" = "FAIL" ] && ok "5a 替代文件缺失 → FAIL" || bad "5a 替代文件缺失 → FAIL（实际: $st）"
[ ! -e "$DEST/subdir/Nope.mp4" ] && ok "5b 未凭空造出目标文件" || bad "5b 未凭空造出目标文件"

# ────────────────────────────────────────────────────────────
# 场景 6: 分卷 zip（方法3/4）—— 需 7z；本环境无 7z 则跳过
# ────────────────────────────────────────────────────────────
echo "--- 场景6: 分卷 zip（方法3/4）---"
if command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1; then
  ORIG6="split/Big Movie [2160p].mp4"
  mkdir -p "$DEST/split"
  : > "$TMP_BASE/payload.bin"
  head -c 4096 /dev/urandom > "$TMP_BASE/payload.bin"
  FMD5=$(md5sum "$TMP_BASE/payload.bin" | awk '{print $1}')
  (cd "$TMP_BASE" && rm -rf pk && mkdir pk && cp payload.bin "pk/Big Movie [2160p].mp4" \
     && cd pk && zip -q -r ../pkg.zip . && cd .. && rm -f pkg.zip.001 pkg.zip.002 \
     && split -n 2 -d pkg.zip pkg.zip.)
  mkdir -p "$DEST/split"
  cp "$TMP_BASE/pkg.zip.001" "$DEST/split/" 2>/dev/null
  cp "$TMP_BASE/pkg.zip.002" "$DEST/split/" 2>/dev/null
  ALT6="split/pkg.zip.001"
  st=$(_restore_one_entry "$DEST" "$ORIG6" "$ALT6" "分卷 zip（短哈希文件名 + 512MiB 分卷切割，共 2 卷）" "$TMP_BASE" "$FMD5")
  [ "$st" = "OK" ] && ok "6a 分卷还原返回 OK" || bad "6a 分卷还原返回 OK（实际: $st）"
  [ -f "$DEST/$ORIG6" ] && ok "6b 原文件已复原" || bad "6b 原文件已复原"
  if [ -f "$DEST/$ORIG6" ]; then
    GM=$(md5sum "$DEST/$ORIG6" | awk '{print $1}')
    [ "$GM" = "$FMD5" ] && ok "6c 解压还原后 md5 与原件一致" || bad "6c md5 一致（期望 $FMD5 实际 $GM）"
  fi
else
  skip "6a-c 分卷 zip 还原（本机无 7z）"
fi

echo
# ────────────────────────────────────────────────────────────
# 收尾: 断言源端零修改（用户硬约束）
# ────────────────────────────────────────────────────────────
SRC_AFTER="$(cd "$SRC_SIM" && find . -type f -exec md5sum {} \; | sort)"
SRC_LIST_AFTER="$(cd "$SRC_SIM" && find . | sort)"
[ "$SRC_BEFORE" = "$SRC_AFTER" ] && ok "源端文件内容零修改（md5 清单一致）" || bad "源端文件内容被修改！"
[ "$SRC_LIST_BEFORE" = "$SRC_LIST_AFTER" ] && ok "源端目录结构零修改（无增无删）" || bad "源端目录结构被修改！"

echo "===== 结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" -eq 0 ]
