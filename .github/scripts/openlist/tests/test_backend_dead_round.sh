#!/bin/bash
# 后端熔断跨轮持久化（F6）——逻辑验证（mock rclone/_marker_write/_run_registry_entry）
# 背景: 轮转游标只能让"这一对"让路，让不了"这个后端"——同一后端有多对时游标
#   后移一位，下轮照样撞上它的下一对；而 attempts 上限 8 次 ≈ 44h（实测
#   task_rotation.json cursor=8 attempts=6 钉死在 wopan176Crypt，其余 15 对
#   近四轮零执行）。F6 把本轮判死的后端连同时间戳写进 backend_dead.json，
#   下轮直接跳过它的全部同步对；死后端常是暂态（登录失效/限流），故带 TTL。
# 验证:
#   1. 无状态文件 → 载入为空，不跳过任何同步对
#   2. mark → 落盘含 dead_at；重新 load 命中
#   3. TTL 过期 → 不再命中（死后端自动重新参战）
#   4. run_all_tasks 跳过判死后端的同步对，健康的照常执行
#   5. 判死后端会随 SYNC_BACKEND_DEAD=1 自动标记（跨轮生效 + 同轮即让路）
#   6. 全线皆死 → 忽略熔断记录并告警（宁可重试死后端，不可全线停摆）
#   7. **判死信号分级**（2026-09-15 加固）: 只有强证据（写探针 / F5 全拒复核）才写
#      backend_dead.json；弱证据（修复管线目录级熔断）只在本轮让路。逃生口
#      OPENLIST_BACKEND_DEAD_PERSIST=all。起因: 一次误判让健康后端停摆 12h。
#   8. TTL 默认 4h（12h → 4h，缩小误判影响面）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

WORK="/tmp/backend_dead_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
SYNC_STATE_DIR="$WORK"

# --- mocks ---
# rclone cat 按路径读本地文件（SYNC_STATE_DIR 用的就是本地目录）
rclone() { case "$1" in cat) cat "$2" 2>/dev/null ;; *) return 0 ;; esac; }
_marker_write() { printf '%s' "$1" > "$2"; return 0; }

SYNC_TASK_REGISTRY=(
  "p0|src0|openlist:wopan176Crypt/0|task0|--auto-split"
  "p1|src1|openlist:baidupanCrypt/1|task1|--auto-split"
  "p2|src2|openlist:wopan176Crypt/2|task2|--auto-split"
)
EXEC_LOG=()
declare -A FAKE_DEAD_MAP=()
declare -A FAKE_FAIL_MAP=()
# 判死证据强度: 生产里写探针/全拒复核会在置 SYNC_BACKEND_DEAD 的同时置 STRONG=1，
# 修复管线的目录级熔断不置 —— mock 要能分别模拟两者（见场景 7）
declare -A FAKE_STRONG_MAP=()
_run_registry_entry() {
  local _p="${1%%|*}"
  EXEC_LOG+=("$_p")
  SYNC_SKIPPED=0
  SYNC_FAILED="${FAKE_FAIL_MAP[$_p]:-0}"
  SYNC_BACKEND_DEAD="${FAKE_DEAD_MAP[$_p]:-0}"
  SYNC_BACKEND_DEAD_STRONG="${FAKE_STRONG_MAP[$_p]:-0}"
}
# 本测试验证**串行**轮转语义: 显式关掉并行同步对
OPENLIST_PAIR_PARALLEL=1

OPENLIST_TASK_ROTATION=1
ROTATION_MAX_CONSECUTIVE_ATTEMPTS=8
reset_case() {
  rm -f "$WORK"/backend_dead.json "$WORK"/task_rotation.json
  EXEC_LOG=()
  FAKE_DEAD_MAP=()
  FAKE_FAIL_MAP=()
  FAKE_STRONG_MAP=()
  _BACKEND_DEAD_ROUND=()
  SYNC_TIME_EXHAUSTED=0
  SYNC_BACKEND_DEAD_STRONG=0
  unset OPENLIST_BACKEND_DEAD_PERSIST 2>/dev/null || true
}

# --- 1. 无状态文件 → 载入为空 ---
reset_case
_backend_dead_load
[ "${#_BACKEND_DEAD_ROUND[@]}" -eq 0 ] && ok "1 无状态文件 → 熔断表为空" || bad "1: ${#_BACKEND_DEAD_ROUND[@]} 条"

# --- 2. mark → 落盘 + 重新 load 命中（强证据）---
# 只有强证据（写探针 / 全拒复核）才允许写跨轮熔断，故这里必须置 STRONG=1 —
# 弱证据路径见场景 7
reset_case
SYNC_BACKEND_DEAD_STRONG=1
_backend_dead_mark "openlist:wopan176Crypt"
[ -s "$WORK/backend_dead.json" ] && ok "2a mark 落盘 backend_dead.json" || bad "2a: 文件未生成"
_DEAD_AT=$(jq -r '.["openlist:wopan176Crypt"].dead_at // empty' "$WORK/backend_dead.json" 2>/dev/null)
case "$_DEAD_AT" in
  ''|*[!0-9]*) bad "2b dead_at 非整数时间戳: [$_DEAD_AT]" ;;
  *) ok "2b dead_at 为整数时间戳" ;;
esac
_BACKEND_DEAD_ROUND=()
_backend_dead_load
[ -n "${_BACKEND_DEAD_ROUND[openlist:wopan176Crypt]:-}" ] \
  && ok "2c 重新 load 命中判死后端" || bad "2c: 未命中"

# --- 3. TTL 过期 → 不再命中 ---
# 必须置 STRONG=1: 否则弱证据门直接不落盘，"过期后不命中"会因为文件根本没写
# 而假通过（测不到 TTL 逻辑本身）
reset_case
SYNC_BACKEND_DEAD_STRONG=1
OPENLIST_BACKEND_DEAD_TTL=1
_backend_dead_mark "openlist:wopan176Crypt"
[ -s "$WORK/backend_dead.json" ] || bad "3 前置: 条目未落盘，TTL 用例无效"
sleep 2
_BACKEND_DEAD_ROUND=()
_backend_dead_load
[ -z "${_BACKEND_DEAD_ROUND[openlist:wopan176Crypt]:-}" ] \
  && ok "3 TTL 过期 → 自动重新参战" || bad "3: 过期条目仍生效"
OPENLIST_BACKEND_DEAD_TTL=14400

# --- 4. run_all_tasks 跳过判死后端的同步对 ---
reset_case
SYNC_BACKEND_DEAD_STRONG=1
_backend_dead_mark "openlist:wopan176Crypt"
_BACKEND_DEAD_ROUND=()
run_all_tasks >/dev/null 2>&1
[ "${#EXEC_LOG[@]}" -eq 1 ] && [ "${EXEC_LOG[0]}" = "p1" ] \
  && ok "4a wopan176Crypt 两对被跳过，只执行 baidupanCrypt 的 p1" \
  || bad "4a: 执行序列 [${EXEC_LOG[*]}]"

# --- 5. 本轮判死 → 自动落盘供下轮跳过 + 同轮即让路（强证据）---
reset_case
# 生产形态: 后端判死的同步对同时以 SYNC_FAILED=1 收场（先失败再让路）
FAKE_DEAD_MAP["p0"]=1
FAKE_FAIL_MAP["p0"]=1
FAKE_STRONG_MAP["p0"]=1     # 写探针/全拒复核类强证据（弱证据见场景 7）
run_all_tasks > "$WORK/same_round.log" 2>&1
[ -s "$WORK/backend_dead.json" ] \
  && ok "5a 本轮判死 → 写入 backend_dead.json" || bad "5a: 未落盘"
[ -n "$(jq -r '.["openlist:wopan176Crypt"].dead_at // empty' "$WORK/backend_dead.json" 2>/dev/null)" ] \
  && ok "5b 落盘记录的是该同步对的后端挂载根" || bad "5b: 根不正确"
# 5c/5d 同轮传播: _backend_dead_mark 在写文件之前先把 root 记进内存熔断表
# （task_engine.sh 的 _BACKEND_DEAD_ROUND["$root"]="$now"），所以同一轮里排在
# 该后端后面的 p2 必须**当场**被跳过，不能等下轮才让路。
# 为什么单列这一条: 退出标准 D（非 wopan176 的同步对开始被执行）正是靠这条性质
# 在同一轮成立——只看 5a/5b 的落盘断言，把内存那行删掉测试照样全绿（假通过）。
[ "${#EXEC_LOG[@]}" -eq 2 ] && [ "${EXEC_LOG[0]}" = "p0" ] && [ "${EXEC_LOG[1]}" = "p1" ] \
  && ok "5c 同轮传播: p0 判死后 p2（同后端）当场被跳过，只跑 p0 p1" \
  || bad "5c: 执行序列 [${EXEC_LOG[*]}]"
grep -q "跳过让路" "$WORK/same_round.log" \
  && ok "5d 同轮跳过有「跳过让路」提示" || bad "5d: 无跳过提示"

# --- 6. 全线皆死 → 忽略熔断记录照常执行 ---
reset_case
SYNC_BACKEND_DEAD_STRONG=1
_backend_dead_mark "openlist:wopan176Crypt"
_backend_dead_mark "openlist:baidupanCrypt"
_BACKEND_DEAD_ROUND=()
run_all_tasks > "$WORK/all_dead.log" 2>&1
[ "${#EXEC_LOG[@]}" -eq 3 ] && ok "6a 全线皆死 → 三对全部照常执行" || bad "6a: [${EXEC_LOG[*]}]"
grep -q "宁可重试死后端，不可全线停摆" "$WORK/all_dead.log" \
  && ok "6b 全线皆死有告警" || bad "6b: 无告警"

# --- 7. 弱证据（目录级熔断）→ 本轮让路但不跨轮持久化 ---
# 实测动机（2026-09-14）: 4af1cbc 回归期间，修复管线的目录级熔断把**健康**后端
# wopan175 判死（该后端 A 轮刚真实搬了 13.08GB），并经 F6 写进 backend_dead.json，
# 使其 6 个同步对被整体跳过 —— 一次误判的代价是 TTL 内整个后端停摆（当时 12h）。
# 目录级熔断依赖"探针文件可见性"，列表未就绪时会假阴性，故只允许它本轮生效。
reset_case
FAKE_DEAD_MAP["p0"]=1
FAKE_FAIL_MAP["p0"]=1
# 不设 FAKE_STRONG_MAP ⇒ 弱证据
run_all_tasks > "$WORK/weak.log" 2>&1
[ ! -s "$WORK/backend_dead.json" ] && ok "7a 弱证据 → 不写 backend_dead.json" || bad "7a: 仍落盘"
grep -q "证据为弱信号" "$WORK/weak.log" && ok "7b 日志说明只在本轮熔断" || bad "7b: 无说明"
[ "${#EXEC_LOG[@]}" -eq 2 ] && [ "${EXEC_LOG[1]}" = "p1" ] \
  && ok "7c 本轮仍让路: p2（同后端）当场被跳过" || bad "7c: [${EXEC_LOG[*]}]"

# 7d 逃生口: OPENLIST_BACKEND_DEAD_PERSIST=all 时弱证据也持久化（排查用）
reset_case
FAKE_DEAD_MAP["p0"]=1
FAKE_FAIL_MAP["p0"]=1
OPENLIST_BACKEND_DEAD_PERSIST=all run_all_tasks > /dev/null 2>&1
[ -s "$WORK/backend_dead.json" ] && ok "7d PERSIST=all → 弱证据也落盘（逃生口）" || bad "7d: 未落盘"

# --- 8. TTL 默认 4h（误判影响面收敛）---
# 12h → 4h（2026-09-15 加固）: 一次误判最多影响下一轮前半段；4h 仍覆盖
# "暂态故障 + 一轮观察"这个决策周期
[ "${OPENLIST_BACKEND_DEAD_TTL:-0}" = "14400" ] \
  && ok "8 TTL 默认 4h（误判影响面收敛）" || bad "8: TTL=${OPENLIST_BACKEND_DEAD_TTL:-未设}"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
