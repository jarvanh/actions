#!/bin/bash
# 同步对轮转（run_all_tasks 游标持久化）——逻辑验证（mock rclone/_marker_write/_run_registry_entry）
# 验证:
#   1. 无状态文件 → 从第 1 个同步对开始，全量顺序执行
#   2. 被取消恢复: 状态 {cursor:N, attempts:K} → 本轮从第 N 个开始按序环绕执行
#   3. 执行前落盘 attempts+1（run 被取消时游标已指向执行中的同步对）
#   4. 完成/跳过 → 游标后移、attempts 清零
#   5. 失败不堵队列（后续同步对继续执行），游标随执行推进
#   6. 阀门: 失败且连续尝试达上限 → 强制后移（写入序列可观测）
#   7. 载入时阀门（取消死循环保护）→ 跳过该同步对从下一个开始
#   8. 预览 pass（TASK_PREVIEW_ONLY=1）只读不写游标
#   9. OPENLIST_TASK_ROTATION=0 → 回退固定顺序且不读写游标
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- source 被测代码（tasks.sh 顶层只有常量与数组，可直接 source）---
source "$_REPO_ROOT/.github/scripts/openlist/tasks.sh" 2>/dev/null

# --- 测试用 3 条同步对清单（覆盖真实清单结构）---
SYNC_TASK_REGISTRY=(
  "p0|src0|dst0|task0|--auto-split --1d-skip"
  "p1|src1|dst1|task0|--auto-split --1d-skip"
  "p2|src2|dst2|task0|--auto-split --1d-skip"
)
SYNC_STATE_DIR="/tmp/rotation_test_state"
ROT_STATE_FILE="/tmp/rotation_test_state.json"

# --- mocks（source 之后定义）---
# rclone cat 返回状态文件内容；其他子命令与本测试无关
rclone() {
  case "$1" in
    cat) cat "$ROT_STATE_FILE" 2>/dev/null ;;
    *) return 0 ;;
  esac
}
# _marker_write 记录调用参数（游标写落盘点），不真正上传
MARKER_WRITES=()
_marker_write() {
  MARKER_WRITES+=("$1")
  return 0
}
# 假执行器: 记录执行顺序，按用例声明的 FAKE_SKIP/FAKE_FAIL 状态表回填全局标志
EXEC_LOG=()
declare -A FAKE_SKIP_MAP=()
declare -A FAKE_FAIL_MAP=()
_run_registry_entry() {
  local _p="${1%%|*}"
  EXEC_LOG+=("$_p")
  SYNC_SKIPPED="${FAKE_SKIP_MAP[$_p]:-0}"
  SYNC_FAILED="${FAKE_FAIL_MAP[$_p]:-0}"
}

# 工具: 取第 N 次写入（0 起）的字段值
write_field() { # <idx> <field>
  [ "${#MARKER_WRITES[@]}" -gt "$1" ] || { echo ""; return; }
  echo "${MARKER_WRITES[$1]}" | jq -r ".$2" 2>/dev/null
}
last_write_field() {
  write_field "$((${#MARKER_WRITES[@]} - 1))" "$1"
}
reset_scenario() {
  rm -f "$ROT_STATE_FILE"
  EXEC_LOG=()
  MARKER_WRITES=()
  FAKE_SKIP_MAP=()
  FAKE_FAIL_MAP=()
}
write_state() { # cursor attempts
  jq -cn --argjson c "$1" --argjson a "$2" '{cursor:$c, attempts:$a}' > "$ROT_STATE_FILE"
}

# --- 场景1: 无状态文件 → 固定起点全量顺序，完成后游标绕回 ---
reset_scenario
run_all_tasks
[ "${EXEC_LOG[*]}" = "p0 p1 p2" ] && ok "1a 无状态 → 全量顺序执行 p0,p1,p2" || bad "1a: [${EXEC_LOG[*]}]"
[ "$(last_write_field cursor)" = "0" ] && ok "1b 全部完成 → 游标绕回 0" || bad "1b: cursor=$(last_write_field cursor)"
[ "$(last_write_field attempts)" = "0" ] && ok "1c 完成后 attempts 清零" || bad "1c: attempts=$(last_write_field attempts)"

# --- 场景2: 被取消恢复 → 从游标位置开始环绕执行，执行前计数+1 ---
reset_scenario
write_state 1 3
run_all_tasks
[ "${EXEC_LOG[*]}" = "p1 p2 p0" ] && ok "2a cursor=1 → 从 p1 开始环绕执行" || bad "2a: [${EXEC_LOG[*]}]"
[ "$(write_field 0 cursor)" = "1" ] && ok "2b 首次落盘指向 p1（取消时下轮继续）" || bad "2b: cursor=$(write_field 0 cursor)"
[ "$(write_field 0 attempts)" = "4" ] && ok "2c 执行前落盘 attempts=4（3+1，跨取消累计）" || bad "2c: attempts=$(write_field 0 attempts)"

# --- 场景3: 中途失败不堵队列，游标随执行推进（失败者下个循环重试）---
reset_scenario
FAKE_FAIL_MAP[p1]=1
run_all_tasks
[ "${EXEC_LOG[*]}" = "p0 p1 p2" ] && ok "3a p1 失败后 p2 仍被执行（不堵队列）" || bad "3a: [${EXEC_LOG[*]}]"
[ "$(write_field 2 cursor)" = "1" ] && [ "$(write_field 2 attempts)" = "1" ] \
  && ok "3b 失败的 p1 仅记录执行前落盘（attempts=1）" || bad "3b: $(write_field 2 cursor)/$(write_field 2 attempts)"
[ "$(last_write_field cursor)" = "0" ] && ok "3c p2 完成 → 游标后移绕回 0" || bad "3c: cursor=$(last_write_field cursor)"

# --- 场景4: 失败路径阀门 → 连续尝试达上限强制后移（写入序列第 2 项可观测）---
reset_scenario
write_state 0 7   # p0 已连续 7 次（含取消）未完成
FAKE_FAIL_MAP[p0]=1
run_all_tasks
[ "$(write_field 0 attempts)" = "8" ] && ok "4a 执行前落盘 attempts=8" || bad "4a: $(write_field 0 attempts)"
[ "$(write_field 1 cursor)" = "1" ] && ok "4b 阀门触发 → 游标强制后移到 1" || bad "4b: cursor=$(write_field 1 cursor)"
[ "$(write_field 1 attempts)" = "0" ] && ok "4c 阀门后移后 attempts 清零" || bad "4c: attempts=$(write_field 1 attempts)"

# --- 场景5: 载入时阀门（取消死循环保护）→ 跳过该同步对 ---
reset_scenario
write_state 1 8   # p1 连续 8 次全被 6h 取消（只剩执行前落盘）
run_all_tasks
[ "${EXEC_LOG[0]}" = "p2" ] && ok "5a attempts=8 → 本轮跳过 p1 从 p2 开始" || bad "5a: 首个执行=${EXEC_LOG[0]}"
[ "$(write_field 0 cursor)" = "2" ] && ok "5b 载入阀门先落盘 cursor=2" || bad "5b: cursor=$(write_field 0 cursor)"

# --- 场景6: 跳过（marker 命中）同样推进游标 ---
reset_scenario
write_state 0 2
FAKE_SKIP_MAP[p0]=1
run_all_tasks
[ "${EXEC_LOG[*]}" = "p0 p1 p2" ] && ok "6a 跳过的同步对仍被执行（快速返回）" || bad "6a: [${EXEC_LOG[*]}]"
[ "$(write_field 1 cursor)" = "1" ] && ok "6b p0 被跳过 → 游标后移到 1" || bad "6b: cursor=$(write_field 1 cursor)"

# --- 场景7: 预览 pass 只读不写 ---
reset_scenario
write_state 2 1
TASK_PREVIEW_ONLY=1 run_all_tasks
unset TASK_PREVIEW_ONLY
[ "${EXEC_LOG[*]}" = "p2 p0 p1" ] && ok "7a 预览 pass 按游标顺序执行（与正式一致）" || bad "7a: [${EXEC_LOG[*]}]"
[ "${#MARKER_WRITES[@]}" = "0" ] && ok "7b 预览 pass 不写游标" || bad "7b: 写了 ${#MARKER_WRITES[@]} 次"

# --- 场景8: 开关关闭 → 回退固定顺序、零读写 ---
reset_scenario
write_state 1 3
OPENLIST_TASK_ROTATION=0 run_all_tasks
[ "${EXEC_LOG[*]}" = "p0 p1 p2" ] && ok "8a 关闭轮转 → 清单原顺序执行" || bad "8a: [${EXEC_LOG[*]}]"
[ "${#MARKER_WRITES[@]}" = "0" ] && ok "8b 关闭轮转 → 不写游标" || bad "8b: 写了 ${#MARKER_WRITES[@]} 次"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$ROT_STATE_FILE"
[ $FAIL -eq 0 ]
