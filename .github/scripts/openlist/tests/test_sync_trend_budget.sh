#!/bin/bash
# P0 传输趋势 + P2 优雅到站——逻辑验证（mock rclone/telegram，python3 真实执行）
# 验证:
#   1. sync_budget_stop 三态: 未设锚点不停止 / 预算耗尽停止 / 预算充足不停止
#   2. trend_record_transferred 只累计正数字节，非法输入忽略
#   3. trend_capture_remaining 汇总 PREVIEW_PENDING_MAP（"bytes count" 口径）
#   4. trend.jsonl 三情形: 远端不存在→创建上传 / 存在→追加 / 读取失败→放弃
#      回传只发通知（宁丢样本不覆盖历史）
#   5. run_all_tasks 优雅中断: 预算将尽在首个任务前即停 / 中途耗尽停在下个
#      任务前，SYNC_TIME_EXHAUSTED=1 / 无锚点（调试模式）不干预
#   6. 接力护栏: 人工取消不接力（cancel 且 <5h50m）/ 6h 上限取消接力 /
#      有 queued/waiting 运行不重复触发 / 失败也接力（轮转自愈）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- mocks（被测模块依赖的最小面）---
format_bytes() { echo "$1"; }
send_telegram_message() { TG_SENT+=("$1"); return 0; }
tg_add_title() { local -n m=$1; m+="<t>${2}</t>"; }
tg_add_section() { local -n m=$1; m+="<s>${2}</s>"; }
tg_add_kv() { local -n m=$1; m+="<kv>${2}=${3}</kv>"; }
tg_add_block() { local -n m=$1; m+="${2}"; }
tg_add_footer() { local -n m=$1; m+="<f>"; }

# rclone 桩: 远端目录模拟 onedrive:/logs/sync_state/（文件名必须与
# TREND_FILE 的 basename 一致——模块按 basename 在 lsf 输出里判定存在性）
TREND_DIR="/tmp/trend_test_remote_$$"
TREND_FAKE_REMOTE="$TREND_DIR/trend.jsonl"
mkdir -p "$TREND_DIR"
TREND_CAT_FAIL=0
rclone() {
  case "$1" in
    lsf) ls "$TREND_DIR" 2>/dev/null ;;
    cat) if [ "$TREND_CAT_FAIL" = "1" ]; then return 3; fi
         cat "$TREND_FAKE_REMOTE" 2>/dev/null
         return 0 ;;
    copyto) cp "$2" "$TREND_FAKE_REMOTE" ;;
    *) return 0 ;;
  esac
}

# --- source 被测模块（trend 全量 + task_engine 全量；两者顶层均只定义
#     常量/函数，mock 在 source 之后覆盖，与 test_rotation.sh 同一手法）---
rm -rf "$TREND_DIR" /tmp/ol_trend_*.txt /tmp/ol_trend_transferred.log /tmp/ol_trend_start_ts /tmp/ol_trend.jsonl
mkdir -p "$TREND_DIR"
source "$_REPO_ROOT/.github/scripts/openlist/sync_trend.sh"
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

# --- 1. sync_budget_stop 三态 ---
unset OPENLIST_SYNC_DEADLINE_EPOCH
if sync_budget_stop 2>/dev/null; then bad "预算: 未设锚点不应停止"; else ok "预算: 未设锚点→不停止"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) - 5 ))
if sync_budget_stop 2>/dev/null; then ok "预算: 耗尽→停止"; else bad "预算: 耗尽却不停"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 7200 ))
if sync_budget_stop 2>/dev/null; then bad "预算: 充足却停止"; else ok "预算: 充足→不停止"; fi

# --- 2. trend_record_transferred ---
rm -f /tmp/ol_trend_transferred.log
trend_record_transferred "abc"          # 非法忽略
trend_record_transferred "0"            # 零忽略
trend_record_transferred "100"
trend_record_transferred "-5"           # 非法忽略
n=$(wc -l < /tmp/ol_trend_transferred.log 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "trend_record: 仅合法正数入账（1条）" || bad "trend_record: 期望1条实得$n"

# --- 3. trend_capture_remaining ---
declare -A PREVIEW_PENDING_MAP=( ["k1"]="100 1" ["k2"]="200 2" )
trend_capture_remaining
v=$(cat /tmp/ol_trend_remaining.txt 2>/dev/null || echo 0)
[ "$v" = "300" ] && ok "trend_capture: 合计 300" || bad "trend_capture: 期望300实得$v"

# --- 4. trend.jsonl 三情形 ---
trend_capture_start
: > /tmp/ol_trend_transferred.log
trend_record_transferred "1000"
# 4a) 远端不存在 → 创建上传
trend_record_and_notify "r1" "schedule" >/dev/null 2>&1
[ -s "$TREND_FAKE_REMOTE" ] && ok "trend.jsonl: 首次创建并上传" || bad "trend.jsonl: 首次未上传"
# 4b) 存在 → 追加（第二条）
: > /tmp/ol_trend_transferred.log
trend_record_transferred "2000"
trend_record_and_notify "r2" "workflow_dispatch" >/dev/null 2>&1
lines=$(wc -l < "$TREND_FAKE_REMOTE")
[ "$lines" = "2" ] && ok "trend.jsonl: 存在→追加（2条）" || bad "trend.jsonl: 期望2条实得$lines"
# 4c) 读取失败 → 放弃回传
: > /tmp/ol_trend_transferred.log
trend_record_transferred "9999"
TREND_CAT_FAIL=1
TG_SENT=()
trend_record_and_notify "r3" "schedule" >/dev/null 2>&1
TREND_CAT_FAIL=0
lines=$(wc -l < "$TREND_FAKE_REMOTE")
[ "$lines" = "2" ] && ok "trend.jsonl: 读取失败→不覆盖历史（仍2条）" || bad "trend.jsonl: 历史被覆盖（$lines条）"
[ ${#TG_SENT[@]} -ge 1 ] && ok "trend.jsonl: 读取失败仍发趋势通知" || bad "trend.jsonl: 失败时未发通知"

# --- 5. run_all_tasks 优雅中断 ---
SYNC_TASK_REGISTRY=("p0|s0|d0|task0|" "p1|s1|d1|task1|" "p2|s2|d2|task2|")
SYNC_STATE_DIR="/tmp/trend_rot_state_$$"
ROTATION_MAX_CONSECUTIVE_ATTEMPTS=8
rclone() { case "$1" in cat) cat /tmp/trend_rot_state_$$.json 2>/dev/null ;; *) return 0 ;; esac; }
_marker_write() { return 0; }
_run_registry_entry() { sleep 0.6; return 0; }
OPENLIST_TASK_ROTATION=0

OPENLIST_SYNC_MIN_SLICE_SECONDS=600
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 60 ))
SYNC_TIME_EXHAUSTED=0
run_all_tasks >/dev/null 2>&1
[ "$SYNC_TIME_EXHAUSTED" = "1" ] && ok "优雅到站: 预算将尽首个任务前即停" || bad "优雅到站: 未停止"

# 中途耗尽: 每任务 0.6s / 总预算 1s / 最小片 0 → t1 后停
OPENLIST_SYNC_MIN_SLICE_SECONDS=0
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 1 ))
SYNC_TIME_EXHAUSTED=0
run_all_tasks >/dev/null 2>&1
[ "$SYNC_TIME_EXHAUSTED" = "1" ] && ok "优雅到站: 中途耗尽停在下个任务前" || bad "优雅到站: 中途未停止"

# 调试模式（无锚点）不受影响
unset OPENLIST_SYNC_DEADLINE_EPOCH
SYNC_TIME_EXHAUSTED=0
run_all_tasks >/dev/null 2>&1
[ "$SYNC_TIME_EXHAUSTED" = "0" ] && ok "优雅到站: 无锚点（调试模式）不干预" || bad "优雅到站: 无锚点却停止"

# --- 6. 接力护栏（复刻 workflow step 判断逻辑）---
_retrigger() { # <conclusion> <elapsed> <pending>
  local SYNC_CONCLUSION="$1" ELAPSED="$2" PENDING="$3"
  if [ "$SYNC_CONCLUSION" = "cancelled" ] && [ "$ELAPSED" -lt 21000 ]; then echo "no"; return 0; fi
  if [ "${PENDING:-0}" -gt 0 ]; then echo "no"; return 0; fi
  echo "yes"
}
[ "$(_retrigger success 3600 0)" = "yes" ] && ok "接力: 成功收场→接力" || bad "接力: 成功未接力"
[ "$(_retrigger cancelled 1200 0)" = "no" ] && ok "接力: 人工取消不打架" || bad "接力: 人工取消误接力"
[ "$(_retrigger cancelled 21600 0)" = "yes" ] && ok "接力: 6h 上限被杀→接力" || bad "接力: 6h 被杀未接力"
[ "$(_retrigger success 3600 2)" = "no" ] && ok "接力: 有排队不重复触发" || bad "接力: 排队堆积"
[ "$(_retrigger failure 500 0)" = "yes" ] && ok "接力: 失败也接力（轮转自愈）" || bad "接力: 失败未接力"

# --- 清理 ---
rm -rf "$TREND_DIR" "$SYNC_STATE_DIR" /tmp/ol_trend_*.txt /tmp/ol_trend.jsonl /tmp/ol_trend_transferred.log /tmp/ol_trend_start_ts /tmp/trend_rot_state_$$

echo ""
echo "通过 $PASS / $((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
