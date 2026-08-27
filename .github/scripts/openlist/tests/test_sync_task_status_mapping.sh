#!/usr/bin/env bash
# sync_task 顶级任务状态映射回归测试（run 33048121562）
# 背景: 进度面板 task_done 分类与 run_all_tasks 轮转游标都只认 SYNC_FAILED/
#   SYNC_SKIPPED 全局标志；实现层若只回传非零返回码而漏置标志（批次预检
#   熔断分支的历史缺陷形态），失败任务会被双双记成"已完成"。
# 契约:
#   M1 impl 返回 1 且未置任何标志 -> 兜底 SYNC_FAILED=1 -> task_done("failed"),
#      sync_task 透传返回码 1
#   M2 impl 返回 0 且标志全零 -> task_done("completed")，不受兜底影响
#   M3 SKIP 任务（impl rc=1 + SYNC_SKIPPED=1）-> task_done("skipped")，
#      兜底不得覆盖 skip 分类，且不写修复状态 marker
#   M4 impl 自置 SYNC_FAILED=1 但返回 0 -> 仍按标志判 failed（标志优先）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "✅ $1"
  else
    FAIL=$((FAIL + 1))
    echo "❌ $1 (期望 [$3] 实际 [$2])"
  fi
}

# ---------- 抽取被测函数 ----------
# 与 test_batch_precheck_circuit_breaker.sh 同策略: 单函数抽取 + 显式 stub，
# 保持与 utils/sync/marker/progress 模块零耦合
sed -n '/^sync_task()/,/^}/p' "$SCRIPT_DIR/../tasks.sh" > extracted.sh
echo "被测函数抽取: $(wc -l < extracted.sh) 行"
source extracted.sh

# ---------- 协作者 stub ----------
RCLONE_SYNC_TASK_FLAGS=()
SYNC_AUTO_SPLIT_DEPTH="${SYNC_AUTO_SPLIT_DEPTH:-0}"
SYNC_SKIP_SECONDS=$((24 * 60 * 60))
TASK_PREVIEW_ONLY=""
TASK_REGISTER_ONLY=0
SYNC_SKIPPED=0
SYNC_FAILED=0

IMPL_RC=0
_sync_task_impl() { return "$IMPL_RC"; }
_derive_task_id() { echo "$1"; }

BEGIN_CALLED=0
task_begin() { BEGIN_CALLED=$((BEGIN_CALLED + 1)); }
DONE_STATUS=""
task_done() { DONE_STATUS="$1"; }
FIX_SAVED=0
save_fix_state_marker() { FIX_SAVED=1; }

reset_case() {
  IMPL_RC=0
  BEGIN_CALLED=0
  DONE_STATUS=""
  FIX_SAVED=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0
}

# 必须复刻生产调用形态 (tasks.sh run_all_tasks `_run_registry_entry || true`):
# || 列表豁免让 sync_task 的非零透传返回码不会击穿 harness 的 set -e
capture_rc() {
  RC=0
  sync_task "$@" || RC=$?
}

# ---------- M1: rc≠0 未置标志 -> 兜底 failed ----------
reset_case
IMPL_RC=1
capture_rc "/src" "/dst" "t_m1"
chk "M1 sync_task 透传 rc=1" "$RC" "1"
chk "M1 task_done 判 failed" "$DONE_STATUS" "failed"
chk "M1 兜底置 SYNC_FAILED=1" "${SYNC_FAILED}" "1"
chk "M1 进入过 begin/done 配对" "$BEGIN_CALLED" "1"
chk "M1 失败轮仍保存修复状态" "$FIX_SAVED" "1"

# ---------- M2: 正常成功 -> completed ----------
reset_case
capture_rc "/src" "/dst" "t_m2"
chk "M2 sync_task rc=0" "$RC" "0"
chk "M2 task_done 判 completed" "$DONE_STATUS" "completed"
chk "M2 不误置 SYNC_FAILED" "${SYNC_FAILED}" "0"

# ---------- M3: skipped 任务不被 rc≠0 映射覆盖 ----------
reset_case
SYNC_SKIPPED=1
IMPL_RC=1
capture_rc "/src" "/dst" "t_m3"
chk "M3 task_done 判 skipped" "$DONE_STATUS" "skipped"
chk "M3 不误置 SYNC_FAILED" "${SYNC_FAILED}" "0"
chk "M3 skip 任务不写修复 marker" "$FIX_SAVED" "0"

# ---------- M4: impl 自置标志 (恒返回 0) -> 标志优先 ----------
# 重定义 _sync_task_impl: sync_with_logging 的真实契约即恒返回 0、失败经标志传递
reset_case
_sync_task_impl() { SYNC_FAILED=1; return 0; }
capture_rc "/src" "/dst" "t_m4"
chk "M4 sync_task rc=0 (契约: 恒0)" "$RC" "0"
chk "M4 task_done 判 failed" "$DONE_STATUS" "failed"
chk "M4 标志保持为 1" "${SYNC_FAILED}" "1"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
