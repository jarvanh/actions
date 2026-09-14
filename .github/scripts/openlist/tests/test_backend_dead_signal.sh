#!/bin/bash
# 写探针判死信号键错位（F21）—— 逻辑验证（mock 预检层与 rclone）
#
# 背景: _backend_write_probe 按「后端 × 路径」分层缓存（F4），写的是
#   _BACKEND_WRITE_PROBE_CACHE[$dest_path]（如 openlist:wopan176Crypt/2）；
#   而 sync_with_logging 的两处读取曾按**后端根**取（openlist:wopan176Crypt）。
#   键对不上 ⇒ 判死信号恒丢 ⇒ SYNC_BACKEND_DEAD 永不置位 ⇒ 既不立即后移游标、
#   也不调 _backend_dead_mark（无跨轮 TTL 跳过）⇒ 死后端只能靠
#   ROTATION_MAX_CONSECUTIVE_ATTEMPTS=8 阀门脱身，8 × 5.5h ≈ 44h 零产出。
#   这正是「死后端钉住游标」的直接成因（不是熔断器本身没写对）。
#
# 验证:
#   1. 真 _backend_write_probe 失败 → 判死落在**同步对路径**键上（且不写根键）
#   2. 入口预检失败 + 同步对键=0 → SYNC_BACKEND_DEAD=1（修复目标）
#   3. 反向锁死: 只把后端根键置 0 → 必须**仍为 0**（防有人改回按根读）
#   4. 后端可写（同步对键=1）→ 不误置位
#   5. rc=88 二次预检熔断路径同口径（该路径也读同一个键）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/openlist_driver.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh" 2>/dev/null

WORK="/tmp/backend_dead_signal_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

DEST="openlist:wopan176Crypt/2"
ROOT="openlist:wopan176Crypt"

# --- 1. 真 _backend_write_probe 失败 → 键落在同步对路径 ---
# 只让写探针失败: 读探针层（webdav/API 强校验）全部放行，rclone 一律失败
_pre_webdav_health_check() { return 0; }
_openlist_api_health_check() { return 0; }
_get_openlist_token() { printf 'dummy-token'; }
rclone() { return 1; }
declare -A _BACKEND_WRITE_PROBE_CACHE=()

_check_openlist_backend_connectivity "$DEST" /dev/null
rc=$?
[ "$rc" -ne 0 ] && ok "1a 写探针失败 → 连通性预检返回非 0" || bad "1a: rc=$rc"
[ "${_BACKEND_WRITE_PROBE_CACHE[$DEST]:-}" = "0" ] \
  && ok "1b 判死落在同步对路径键 [$DEST]" \
  || bad "1b: cache[$DEST]=${_BACKEND_WRITE_PROBE_CACHE[$DEST]:-<空>}"
[ -z "${_BACKEND_WRITE_PROBE_CACHE[$ROOT]:-}" ] \
  && ok "1c 后端根键未被写入（键口径确实是同步对路径）" \
  || bad "1c: 根键被写入 = ${_BACKEND_WRITE_PROBE_CACHE[$ROOT]}"

# --- 2. 入口预检失败 + 同步对键=0 → 置位 ---
_check_openlist_backend_connectivity() { return 1; }
declare -A _BACKEND_WRITE_PROBE_CACHE=(["$DEST"]=0)
SYNC_BACKEND_DEAD=0
sync_with_logging "src" "$DEST" "task2" >/dev/null 2>&1
[ "${SYNC_BACKEND_DEAD:-0}" = "1" ] \
  && ok "2 入口预检失败 + 同步对键=0 → SYNC_BACKEND_DEAD=1" \
  || bad "2: SYNC_BACKEND_DEAD=${SYNC_BACKEND_DEAD:-0}"

# --- 3. 反向锁死: 只有后端根键=0 → 不得置位 ---
# 若有人把读取改回按 _backend_root_of 取，此断言立刻变红
declare -A _BACKEND_WRITE_PROBE_CACHE=(["$ROOT"]=0)
SYNC_BACKEND_DEAD=0
sync_with_logging "src" "$DEST" "task2" >/dev/null 2>&1
[ "${SYNC_BACKEND_DEAD:-0}" = "0" ] \
  && ok "3 反向锁死: 仅后端根键=0 不得置位（读取口径必须是同步对键）" \
  || bad "3: 误置位（读取又改回按后端根取了）"

# --- 4. 后端可写（同步对键=1）→ 不误置位 ---
declare -A _BACKEND_WRITE_PROBE_CACHE=(["$DEST"]=1)
SYNC_BACKEND_DEAD=0
sync_with_logging "src" "$DEST" "task2" >/dev/null 2>&1
[ "${SYNC_BACKEND_DEAD:-0}" = "0" ] \
  && ok "4 后端可写（键=1）→ 不误置位" \
  || bad "4: 误置位"

# --- 5. rc=88 二次预检熔断路径 ---
# 入口预检放行（第 1 次调用），传输前的二次预检失败（第 2 次调用）→ 哨兵 88。
# 该分支同样读 cache[$dest_path]，必须与入口路径同口径。
_cbc_calls=0
_check_openlist_backend_connectivity() {
  _cbc_calls=$((_cbc_calls + 1))
  [ "$_cbc_calls" -ge 2 ] && return 1
  return 0
}
_refresh_openlist_cache() { return 0; }
_refresh_ol_drivers() { return 0; }

declare -A _BACKEND_WRITE_PROBE_CACHE=(["$DEST"]=0)
SYNC_BACKEND_DEAD=0
sync_with_logging "src" "$DEST" "task2" >/dev/null 2>&1
[ "${SYNC_BACKEND_DEAD:-0}" = "1" ] \
  && ok "5a rc=88 二次预检熔断路径同口径置位（同步对键=0）" \
  || bad "5a: SYNC_BACKEND_DEAD=${SYNC_BACKEND_DEAD:-0}"

_cbc_calls=0
declare -A _BACKEND_WRITE_PROBE_CACHE=(["$ROOT"]=0)
SYNC_BACKEND_DEAD=0
sync_with_logging "src" "$DEST" "task2" >/dev/null 2>&1
[ "${SYNC_BACKEND_DEAD:-0}" = "0" ] \
  && ok "5b rc=88 路径同样反向锁死（仅根键=0 不置位）" \
  || bad "5b: 误置位"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
