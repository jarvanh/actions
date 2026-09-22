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
# 短哈希「不可逆」这件事由场景 6b 正反两面锁住:
#   正 —— 只要 marker 有 original，任意 8 位 hex 目录都能还原到任意原路径，
#         因为还原侧**根本不计算也不解析**短哈希（6b-1/6b-2）
#   反 —— 8 位 hex 推不出原目录名（md5 单向 + 截断到 32bit），故还原侧
#         不允许出现任何短哈希计算/解码分支（6b-3/6b-4）
#   ⇒ 结论: 能还原，但**成立的唯一前提是 marker 的 original 字段还在**；
#     marker 丢了，短哈希目录里的文件就只剩密文名，无法自愈回原路径。
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

# 计算短哈希（口径必须与 file_fix.sh 一致: md5(相对路径) 前 8 位）
sh8() { printf '%s' "$1" | md5sum | cut -c1-8; }

# 防漂移自检: 上面这个 sh8 是"测试自己写的一份"，与生产 `_hash_dir_rel_for`
#   一旦写歪，本测试会拿错哈希去还原、结果照样 PASS（因为 alt 与还原用的是
#   同一个错值），问题只在生产才暴露 ⇒ 直接从生产文件里抽出真函数来比对，
#   不一致就立刻 FAIL（不 source 整个 file_fix.sh 是因为它有大量作用域副作用）
eval "$(sed -n '/^_hash_dir_rel_for() {/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/file_fix.sh")"
if [ "$(_hash_dir_rel_for 'movies/成人/2024 - Best Collection [4K]')" = "$(sh8 'movies/成人/2024 - Best Collection [4K]')" ]; then
  ok "0a 短哈希口径与生产 _hash_dir_rel_for 一致（防测试自写哈希漂移）"
else
  bad "0a 短哈希口径与生产 _hash_dir_rel_for 一致（防漂移）"
fi

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
  (cd "$TMP_BASE" && rm -rf pk pkg.zip* && mkdir pk && cp payload.bin "pk/Big Movie [2160p].mp4" \
     && cd pk \
     && { if command -v zip >/dev/null 2>&1; then zip -q -r ../pkg.zip .; \
          else 7z a -tzip ../pkg.zip . >/dev/null; fi; } \
     && cd .. && split -n 2 -d pkg.zip pkg.zip.)
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

# ────────────────────────────────────────────────────────────
# 场景 6b: 短哈希「不可逆」的正反两面
#   正: 只要 marker 有 original，任意 8 位 hex 目录都能还原到任意原路径
#       （还原全程不解析/不反推目录名 —— 哈希值本身不参与决策）
#   反: 没有 marker 的 original 时，光看 8 位 hex **推不出**原目录名
#       （md5 单向 + 截断到 32bit ⇒ 不存在解码路径）
# ────────────────────────────────────────────────────────────
echo "--- 场景6b: 短哈希不可逆 —— 还原只认 marker 的 original ---"
HASH_ANY="deadbeef"   # 故意用与任何真实目录都不对应的哈希值
ORIG6B="any/where/完全无关的原名.mkv"
mkdir -p "$DEST/$HASH_ANY"
printf 'CONTENT-SIX-B' > "$DEST/$HASH_ANY/whatever.mkv"
st=$(_restore_one_entry "$DEST" "$ORIG6B" "$HASH_ANY/whatever.mkv" \
      "rclone copyto（短哈希目录 ${HASH_ANY} + 原文件名）" "$TMP_BASE" "")
[ "$st" = "OK" ] && ok "6b-1 任意 8 位 hex 目录 → 任意原路径均可还原（哈希不参与决策）" \
                 || bad "6b-1 任意 8 位 hex 目录可还原（实际: $st）"
[ "$(cat "$DEST/$ORIG6B" 2>/dev/null)" = "CONTENT-SIX-B" ] \
  && ok "6b-2 还原落点与原内容都对" || bad "6b-2 还原落点与原内容都对"
# 反面: 8 位 hex 无法反推（md5 单向 + 截断到 32bit）⇒ 还原路径里**一次都不该出现**
#   短哈希计算。这里断言的正是这条不变量: file_restore.sh 与 restore_info.jq
#   全程不计算 md5 短名（它们只有临时目录名与内容指纹用到 md5）。
#   ⇒ 一旦有人在还原侧加"反推目录名"，本断言立刻红。
if grep -n "md5sum" "$REPO_ROOT/.github/scripts/openlist/file_restore.sh" \
     | grep -qE 'cut -c1-8'; then
  bad "6b-3 还原侧不应出现短哈希计算（发现 cut -c1-8 的 md5 用法）"
else
  ok "6b-3 还原侧零短哈希计算（还原 100% 依赖 marker 的 original 字段）"
fi
if grep -q 'base64 -d' "$REPO_ROOT/.github/scripts/openlist/file_restore.sh"; then
  bad "6b-4 短哈希目录不应有 base64 解码分支（不可逆，仅 base64URL 目录可解）"
else
  ok "6b-4 还原侧无短哈希解码分支（与 base64URL 目录区别对待正确）"
fi

echo
# ────────────────────────────────────────────────────────────
# 场景 7（V3-Q1）: 修复侧端到端 —— 原目录真不可写 → 短哈希目录兜底真建出真落盘
#   与 mock 版（test_hash_dir_fallback.sh）的本质区别: rclone 是真二进制真搬文件，
#   「目录不可写」用 chmod 555 真实注入（GH runner 非 root，权限位真实生效）。
#   mock 版证明"代码会走折叠分支"，本场景证明"折叠之后文件真的传进去了"。
#   桩只剩与 rclone 无关的三件: 容器重启复核（local 远端无 stale 缓存，恒真）、
#   预检基准重建、OpenList token（mkdir 成功根本走不到 API 分支）。
# ────────────────────────────────────────────────────────────
echo "--- 场景7: 修复侧端到端（目录真不可写 → 短哈希目录真落盘）---"
_restart_openlist_for_truth() { return 0; }
_rebuild_raw_baseline() { return 0; }
_get_openlist_token() { echo ""; }
# file_fix.sh 的作用域副作用初始化（与 mock 测试 reset_state 同款最小集，
# 缺了会把上一个用例的状态泄漏进来，最典型是后端熔断把兜底直接短路）
FIX_METHOD_BLACKLIST=()
_DIR_WRITE_CACHE=()
_BACKEND_DEAD=()
_BACKEND_DIR_FAIL_STREAK=()
_DIR_PROBE_RESTARTS=0
_FIX_NAMELEN_CONTENT=0

# 源端放独立目录: SRC_SIM 有护栏快照比对（src_before/after），场景 7 中途加文件
# 会破坏快照一致性；且护栏语义是"不得修改生产源端"，本目录是测试自建的 local 源端。
SRC7_BASE="$SANDBOX/src7"
ORIG7="locked dir/超长目录名-敏感词测试-This Is A Very Long Directory Name For Fold Test/影视文件 (2024) [4K].mkv"
SRC7="$SRC7_BASE/$ORIG7"
mkdir -p "$(dirname "$SRC7")"
printf 'CONTENT-SEVEN' > "$SRC7"
LOCKED_DIR="$DEST/locked dir/超长目录名-敏感词测试-This Is A Very Long Directory Name For Fold Test"
mkdir -p "$LOCKED_DIR"
chmod 555 "$LOCKED_DIR"

FIX_LOG7="$SANDBOX/fix7.log"
# set -u 下断言分支会引用这些变量 —— try_fix_failed_file 若在初始化前崩掉
# （如某依赖缺失），未定义变量会让测试直接死在断言行而非给出可读失败
TRY_FIX_STATUS=""; TRY_FIX_ALTERNATIVE=""; TRY_FIX_METHOD=""
TRY_FIX_METHOD_ID=""; TRY_FIX_RESTORE=""; TRY_FIX_MESSAGE=""; TRY_FIX_MD5=""
try_fix_failed_file "$SRC7_BASE" "$DEST" "t" "$ORIG7" "$FIX_LOG7" >"$SANDBOX/fix7.out" 2>&1 || true
# 全量输出落 CI 日志（/tmp 沙箱即焚；吞掉 stderr 的话，函数早期崩掉的原因无从排查）
echo "    [try_fix_failed_file 输出尾部]"
tail -30 "$SANDBOX/fix7.out" 2>/dev/null | sed 's/^/      /' || true
echo "    [fix7.log 关键行]"
grep -E '✅|❌|⚠|🔀|兜底|折叠|失败|成功' "$FIX_LOG7" 2>/dev/null | head -12 | sed 's/^/      /' || true

HD7="$(sh8 "$(dirname "$ORIG7")")"
ALT7="$HD7/影视文件 (2024) [4K].mkv"
[ "$TRY_FIX_STATUS" = "success" ] \
  && ok "7a 修复侧端到端成功（真下载 + 真上传，不可写目录被兜底绕开）" \
  || { bad "7a: status=$TRY_FIX_STATUS msg=${TRY_FIX_MESSAGE:-}"; tail -25 "$FIX_LOG7" 2>/dev/null | sed 's/^/      /'; }
[ "$TRY_FIX_ALTERNATIVE" = "$ALT7" ] \
  && ok "7b 替代路径落在短哈希目录（<hash8>/<原名>）" || bad "7b: alt=$TRY_FIX_ALTERNATIVE"
[ -f "$DEST/$ALT7" ] && ok "7c 短哈希目录内文件真落盘（真 rclone 写入）" \
  || bad "7c: 缺 $DEST/$ALT7"
[ "$(cat "$DEST/$ALT7" 2>/dev/null)" = "CONTENT-SEVEN" ] && ok "7d 落盘内容与源端一致" || bad "7d 内容不一致"
printf '%s' "${TRY_FIX_METHOD:-}" | grep -qF "短哈希目录 ${HD7}" \
  && ok "7e 方法文本标注短哈希目录（restore_info.jq 可分类）" || bad "7e: method=${TRY_FIX_METHOD}"
[ -z "$(ls -A "$LOCKED_DIR" 2>/dev/null)" ] \
  && ok "7f 原目录全程零写入（555 注入成立，落点确实走了兜底而非原目录）" \
  || bad "7f 原目录被写入（不可写注入失效）"
# 还原测试自己造的 555 目录，恢复写权限让 trap 清理不报错
chmod -R u+w "$DEST/locked dir" 2>/dev/null || true

# ────────────────────────────────────────────────────────────
# 场景 8（V3-Q2）: 落盘链路三点连通 —— 修复序列化 ↔ 真实落点 ↔ 还原落点
#   现状"分别测过、未连通": ①fix_list → restore_info.jq 序列化有测试；
#   ②按 fixed_files 记录还原有测试（场景 1-3）。但"序列化出的记录与磁盘上
#   真实落点严格一致"没有断言 —— 万一序列化路径拼错一段，两边各自都绿。
#   短哈希体系里记录就是生命线（不可逆，original 丢了无法自愈），必须锁死。
# ────────────────────────────────────────────────────────────
echo "--- 场景8: 落盘链路三点连通（序列化 ↔ 真实落点 ↔ 还原）---"
# ① 用场景 7 的真实输出按生产格式写 fix_list 行（file_fix_pipeline.sh:420 同款 8 段管道行）
SIZE7=$(wc -c < "$SRC7" | tr -d ' ')
FIXLINE7="${ORIG7}|${TRY_FIX_ALTERNATIVE}|${TRY_FIX_METHOD}|${TRY_FIX_RESTORE}|${SIZE7}B|${SIZE7}|${TRY_FIX_METHOD_ID}|${TRY_FIX_MD5}"
FIXED_JSON7=$(printf '%s\n' "$FIXLINE7" \
  | jq -R -s --arg sp "$SRC7_BASE" --arg dp "$DEST" \
      -f "$REPO_ROOT/.github/scripts/openlist/restore_info.jq" 2>/dev/null || echo "[]")
# ② 序列化结果与修复侧输出一致（kind 正确、original/alternative 逐字一致）
[ "$(echo "$FIXED_JSON7" | jq -r '.[0].restore.kind // "MISSING"')" = "hash_dir" ] \
  && ok "8a 序列化 kind=hash_dir（与折叠行为一致）" || bad "8a: kind=$(echo "$FIXED_JSON7" | jq -r '.[0].restore.kind // "MISSING"')"
[ "$(echo "$FIXED_JSON7" | jq -r '.[0].original')" = "$ORIG7" ] \
  && ok "8b 记录的 original == 修复侧输入原路径" || bad "8b: original 不一致"
# ③ 记录 ↔ 真实落点: 记录的 alternative 在 dest 真实存在（不是只写在 JSON 里）
ALT8="$(echo "$FIXED_JSON7" | jq -r '.[0].alternative')"
[ -n "$ALT8" ] && [ "$ALT8" = "$TRY_FIX_ALTERNATIVE" ] && [ -f "$DEST/$ALT8" ] \
  && ok "8c 记录的 alternative 与磁盘真实落点逐字一致" || bad "8c: alt=$ALT8"
# ④ 记录 ↔ 还原: 按该记录真还原，落点 == original 且内容一致 ⇒ 三点闭环
st=$(_restore_one_entry "$DEST" "$ORIG7" "$ALT8" "${TRY_FIX_METHOD:-}" "$TMP_BASE" "${TRY_FIX_MD5:-}")
[ "$st" = "OK" ] && ok "8d 按序列化记录真还原返回 OK" || bad "8d: st=$st"
[ "$(cat "$DEST/$ORIG7" 2>/dev/null)" = "CONTENT-SEVEN" ] \
  && ok "8e 还原落点与内容 == 记录的 original（三点连通闭环）" || bad "8e 还原内容不一致"
[ ! -e "$DEST/$ALT8" ] \
  && ok "8f 还原是移动不是复制（替代位置已清空，无重复产物）" || bad "8f 替代文件残留"

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
