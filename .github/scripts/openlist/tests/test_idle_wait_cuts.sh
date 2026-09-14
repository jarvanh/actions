#!/bin/bash
# 两处"省时间"改动 —— 行为验证（静默间隔分析驱动，2026-09-14）
# 背景: 对 run 34793014398（334min）做"≥55s 无输出"的静默间隔分析，151min 静默里
#   盲等占 71min（缓存刷新 42min + 驱动就绪 29min）。两处改动都遵循同一原则:
#   **上界不变、只赚不亏**（最坏情况与旧行为完全一致），因此测试要同时钉住
#   "快路径真的快" 与 "慢路径不劣化"。
# 验证:
#   A. _wait_driver_ready: 目标可列出 → 立即返回（不等满上界）
#   B. _wait_driver_ready: 始终不可列出 → 到上界后**仍返回 0**（照旧往下走，不改变控制流）
#   C. _refresh_openlist_cache: 默认**不调用 rclone size**（该项只用于日志），
#      且仍必须发出 POST /api/fs/refresh（缓存失效语义一字未改）
#   D. _refresh_openlist_cache: OPENLIST_CACHE_REFRESH_COUNT=1 时恢复调用 size（排查用）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/openlist_driver.sh" 2>/dev/null

WORK="/tmp/idlewait_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# --- mocks ---
LSF_FAILS=0            # 前 N 次 lsf 失败（0=立即成功）
LSF_CALLS="$WORK/lsf_calls"
SIZE_CALLS="$WORK/size_calls"
CURL_CALLS="$WORK/curl_calls"
SLEEP_CALLS="$WORK/sleep_calls"
reset_mocks() {
  LSF_FAILS=0
  echo 0 > "$LSF_CALLS"; echo 0 > "$SIZE_CALLS"; echo 0 > "$CURL_CALLS"; echo 0 > "$SLEEP_CALLS"
  : > "$WORK/out"
}
_cnt() { local f="$1"; local n; n=$(cat "$f" 2>/dev/null || echo 0); echo $((n + 1)) > "$f"; }
# sleep 打成空操作: 测试不该真的等（上界由 date 控制，用例把它设成 1s）
sleep() { _cnt "$SLEEP_CALLS"; }
rclone() {
  case "$1" in
    lsf)
      local n; n=$(cat "$LSF_CALLS" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$LSF_CALLS"
      [ "$n" -lt "$LSF_FAILS" ] && return 1
      return 0 ;;
    size) _cnt "$SIZE_CALLS"; echo '{"count":42}' ;;
    *) return 0 ;;
  esac
}
curl() { _cnt "$CURL_CALLS"; return 0; }
_get_openlist_token() { echo fake-token; }
timeout() { shift; "$@"; }

# --- A/B. 驱动就绪等待: 回滚 4af1cbc 后恢复**盲等**（见 openlist_driver.sh 函数头注释）---
# 回滚原因（run 34837308985 实测）: 自适应轮询（lsf 成功即视为就绪）在容器重启后
# 会拿到「成功但为空」的列表 ⇒ diff 跳过、修复 0 尝试、传输从 13.08GB 崩到 148MB。
# 测试钉住三点: 盲等恰好一次 sleep、等待时长可配、**完全不触碰 lsf**（不再轮询）。
reset_mocks
OPENLIST_DRIVER_READY_WAIT=7 _wait_driver_ready "wopan175/2/待同步目录" "$WORK/out" >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "A1 盲等后返回 0" || bad "A1: rc=${_rc}"
[ "$(cat "$SLEEP_CALLS")" = "1" ] && ok "A2 恰好一次 sleep（盲等）" || bad "A2: 睡了 $(cat "$SLEEP_CALLS") 次"
[ "$(cat "$LSF_CALLS")" = "0" ] && ok "A3 不触碰 rclone lsf（无轮询）" || bad "A3: lsf 调用 $(cat "$LSF_CALLS") 次"
grep -q "驱动就绪等待 7s" "$WORK/out" && ok "A4 日志记录等待时长" || bad "A4: 无日志"

# --- C. 缓存刷新默认不跑 size，但仍发 refresh POST ---
reset_mocks
unset OPENLIST_CACHE_REFRESH_COUNT
_refresh_openlist_cache "openlist:wopan175/2/测试" > "$WORK/out" 2>&1
[ "$(cat "$SIZE_CALLS")" = "0" ] && ok "C1 默认不调用 rclone size（仅日志用途）" \
  || bad "C1: size 调用 $(cat "$SIZE_CALLS") 次"
[ "$(cat "$CURL_CALLS")" -ge 1 ] && ok "C2 仍发出缓存刷新 POST（失效语义未变）" \
  || bad "C2: 未发 POST"
grep -q "跳过前后计数" "$WORK/out" && ok "C3 日志明示跳过理由（防误判为 bug）" || bad "C3: 无说明"

# --- D. 排查开关打开后恢复计数 ---
reset_mocks
OPENLIST_CACHE_REFRESH_COUNT=1 _refresh_openlist_cache "openlist:wopan175/2/测试" > "$WORK/out" 2>&1
[ "$(cat "$SIZE_CALLS")" -ge 2 ] && ok "D1 COUNT=1 时恢复前后各一次 size" \
  || bad "D1: size 调用 $(cat "$SIZE_CALLS") 次"
grep -q "刷新前文件数" "$WORK/out" && ok "D2 计数日志恢复" || bad "D2: 无刷新前文件数"

# --- C. 缓存刷新默认不跑 size，但仍发 refresh POST ---
reset_mocks
unset OPENLIST_CACHE_REFRESH_COUNT
_refresh_openlist_cache "openlist:wopan175/2/测试" > "$WORK/out" 2>&1
[ "$(cat "$SIZE_CALLS")" = "0" ] && ok "C1 默认不调用 rclone size（仅日志用途）" \
  || bad "C1: size 调用 $(cat "$SIZE_CALLS") 次"
[ "$(cat "$CURL_CALLS")" -ge 1 ] && ok "C2 仍发出缓存刷新 POST（失效语义未变）" \
  || bad "C2: 未发 POST"
grep -q "跳过前后计数" "$WORK/out" && ok "C3 日志明示跳过理由（防误判为 bug）" || bad "C3: 无说明"

# --- D. 排查开关打开后恢复计数 ---
reset_mocks
OPENLIST_CACHE_REFRESH_COUNT=1 _refresh_openlist_cache "openlist:wopan175/2/测试" > "$WORK/out" 2>&1
[ "$(cat "$SIZE_CALLS")" -ge 2 ] && ok "D1 COUNT=1 时恢复前后各一次 size" \
  || bad "D1: size 调用 $(cat "$SIZE_CALLS") 次"
grep -q "刷新前文件数" "$WORK/out" && ok "D2 计数日志恢复" || bad "D2: 无刷新前文件数"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
