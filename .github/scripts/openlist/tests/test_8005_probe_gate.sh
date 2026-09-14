#!/bin/bash
# 8005 重试前写探针短路（F19）—— 逻辑验证（mock rclone 层与驱动刷新）
#
# 背景: _sync_retry_8005 检测到 8005 后是「刷新驱动 → 直接跑整次
#   run_rclone_sync_once」。后端真死时整次重传会把每个文件都试一遍才报同样的
#   8005——实测单次重试烧 48min（run 34770092689: 18:41→19:29，450MiB 重传、
#   xfr#0 零落盘，末行仍是「8005 错误仍然存在」），而一次写探针 60s 内就能
#   给出同样结论。F19 把探针插在整次重传之前，探针不过就立刻收手。
#
# 验证:
#   1. 探针仍失败 → 不跑整次重传、不刷缓存（连带省掉那个无条件 sleep 60）、置 SYNC_BACKEND_DEAD
#   2. 反向: 探针通过 → 整次重传照跑（不误短路）
#   3. 探针前必须清 cache[$dest_path]（不清会命中同步前入口探针的"可写"结论）
#   4. 无 8005 → 整段不进入（连驱动刷新都不该发生）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh" 2>/dev/null

WORK="/tmp/retry_8005_gate_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

DEST="openlist:wopan176Crypt/2"
declare -A _BACKEND_WRITE_PROBE_CACHE=()

# --- 调用记账一律写文件（变量记账在同进程内虽可行，但管道/子 shell 下会假通过）---
RESYNC_CALLS="$WORK/resync_calls"
CACHE_REFRESH_CALLS="$WORK/cache_refresh_calls"
DRIVER_REFRESH_CALLS="$WORK/driver_refresh_calls"
PROBE_CACHE_STATE="$WORK/probe_cache_state"
HLF_CALLS="$WORK/hlf_calls"
reset_case() {
  : > "$RESYNC_CALLS"; : > "$CACHE_REFRESH_CALLS"; : > "$DRIVER_REFRESH_CALLS"
  : > "$PROBE_CACHE_STATE"; : > "$HLF_CALLS"; : > "$WORK/probe_paths"
  _BACKEND_WRITE_PROBE_CACHE=()
  SYNC_BACKEND_DEAD=0
}
count_of() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

# --- mocks ---
sleep() { :; }                       # 跳过函数内的 sleep 10
_find_openlist_log() { return 1; }
# FAKE_8005_MODE 控制 8005 检测结果:
#   always   — 一直命中（后端真死，探针也过不了）
#   detected — 首次命中、其后消除（模拟"刷新驱动后后端恢复"）
#   none     — 从未命中（不该进这段逻辑）
_has_wopan_login_failure() {
  local n
  n=$(count_of "$HLF_CALLS")
  echo x >> "$HLF_CALLS"
  case "${FAKE_8005_MODE:-always}" in
    none)     return 1 ;;
    detected) [ "$n" -eq 0 ] && return 0 || return 1 ;;
    *)        return 0 ;;
  esac
}
_refresh_ol_drivers() { echo x >> "$DRIVER_REFRESH_CALLS"; return 0; }
_refresh_openlist_cache() { echo x >> "$CACHE_REFRESH_CALLS"; return 0; }
run_rclone_sync_once() { echo x >> "$RESYNC_CALLS"; return 0; }
# 探针: 结果由 FAKE_PROBE_RC 控制；同时记录调用时 cache[$dest_path] 是否已被清空
_backend_write_probe() {
  if [ -z "${_BACKEND_WRITE_PROBE_CACHE[$1]:-}" ]; then
    echo "cleared" >> "$PROBE_CACHE_STATE"
  else
    echo "still=${_BACKEND_WRITE_PROBE_CACHE[$1]}" >> "$PROBE_CACHE_STATE"
  fi
  echo "$1" >> "$WORK/probe_paths"
  return "${FAKE_PROBE_RC:-1}"
}

dest_path="$DEST"
LOG_FILENAME="$WORK/sync.log"
LAST_ATTEMPT_LOG="$WORK/sync.log.last"
SYNC_STATUS=0

# --- 1. 探针仍失败 → 短路 ---
reset_case
FAKE_8005_MODE=always FAKE_PROBE_RC=1 _sync_retry_8005
[ "$(count_of "$RESYNC_CALLS")" -eq 0 ] \
  && ok "1a 探针失败 → 不跑整次重传（省下约 48min）" \
  || bad "1a: run_rclone_sync_once 被调用 $(count_of "$RESYNC_CALLS") 次"
[ "$(count_of "$CACHE_REFRESH_CALLS")" -eq 0 ] \
  && ok "1b 探针失败 → 不刷缓存（连带省掉其无条件 sleep 60）" \
  || bad "1b: _refresh_openlist_cache 被调用 $(count_of "$CACHE_REFRESH_CALLS") 次"
[ "${SYNC_BACKEND_DEAD:-0}" = "1" ] \
  && ok "1c 探针失败 → 置 SYNC_BACKEND_DEAD=1（供轮转让路 + F6 跨轮熔断）" \
  || bad "1c: SYNC_BACKEND_DEAD=${SYNC_BACKEND_DEAD:-0}"
[ "$(count_of "$DRIVER_REFRESH_CALLS")" -eq 1 ] \
  && ok "1d 刷新驱动仍然发生（探针必须在刷新之后，否则测的是过期 token）" \
  || bad "1d: _refresh_ol_drivers 调用 $(count_of "$DRIVER_REFRESH_CALLS") 次"
grep -qxF "$DEST" "$WORK/probe_paths" \
  && ok "1e 探针打在同步对真实子路径上" \
  || bad "1e: 探针路径 = $(cat "$WORK/probe_paths" 2>/dev/null | tr '\n' ' ')"

# --- 2. 反向: 探针通过 + 首次重传后 8005 消除 → 只跑一次 ---
reset_case
FAKE_8005_MODE=detected FAKE_PROBE_RC=0 _sync_retry_8005
[ "$(count_of "$RESYNC_CALLS")" -eq 1 ] \
  && ok "2a 探针通过 → 整次重传照跑（不误短路）" \
  || bad "2a: run_rclone_sync_once 调用 $(count_of "$RESYNC_CALLS") 次"
[ "${SYNC_BACKEND_DEAD:-0}" = "0" ] \
  && ok "2b 探针通过 → 不误置 SYNC_BACKEND_DEAD" \
  || bad "2b: 误置位"

# --- 2c. 探针一直通过、8005 一直存在 → 仍受 OPENLIST_8005_RETRY_ATTEMPTS 约束 ---
reset_case
OPENLIST_8005_RETRY_ATTEMPTS=3 FAKE_8005_MODE=always FAKE_PROBE_RC=0 _sync_retry_8005
[ "$(count_of "$RESYNC_CALLS")" -eq 3 ] \
  && ok "2c 探针恒通过 + 8005 恒在 → 按上限重试 3 次（未改变原有重试语义）" \
  || bad "2c: 调用 $(count_of "$RESYNC_CALLS") 次（期望 3）"

# --- 3. 探针前必须清 cache[$dest_path] ---
# 不清的话，同步前入口探针留下的 cache=1（可写）会让 _backend_write_probe
# 命中缓存直接返回"可写"——等于没探，短路永远不触发。
reset_case
_BACKEND_WRITE_PROBE_CACHE["$DEST"]=1
FAKE_8005_MODE=always FAKE_PROBE_RC=1 _sync_retry_8005
grep -qxF "cleared" "$PROBE_CACHE_STATE" \
  && ok "3 探针调用时 cache[$DEST] 已清空（不命中入口探针的旧结论）" \
  || bad "3: 探针看到的状态 = $(cat "$PROBE_CACHE_STATE" 2>/dev/null | tr '\n' ' ')"

# --- 4. 无 8005 → 整段不进入 ---
reset_case
FAKE_8005_MODE=none FAKE_PROBE_RC=1 _sync_retry_8005
[ "$(count_of "$DRIVER_REFRESH_CALLS")" -eq 0 ] && [ "$(count_of "$RESYNC_CALLS")" -eq 0 ] \
  && ok "4 未检测到 8005 → 既不刷驱动也不重传" \
  || bad "4: driver=$(count_of "$DRIVER_REFRESH_CALLS") resync=$(count_of "$RESYNC_CALLS")"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
