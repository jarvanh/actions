#!/bin/bash
# P0 传输趋势 + P2 优雅到站——逻辑验证（mock rclone/telegram，python3 真实执行）
# 验证:
#   1. sync_budget_stop 三态: 未设锚点不停止 / 预算耗尽停止 / 预算充足不停止
#   1b. _batch_budget_stop 三态（批次循环专用闸，最小工作片 60min）
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
# 版式助手 mock 用纯文本标记（TITLE:/SECTION:/KV:/FOOTER:），不冒充 HTML 标签。
# 此前是 <t>/<s>/<kv>/<f>：真源只产出裸文本 + <code>/<pre>/<a>，mock 里的
# <s> 更是 Telegram 真实存在的删除线标签，读测试的人容易误以为线上通知带删除线
# （2026-09-11 修）。形态与 test_skip_preview_hint.sh 同风格，并补上真源的
# 「每行带尾换行 / block 保证段尾换行」，让 mock 输出更接近真实消息。
tg_add_title()   { local -n m=$1; m+="TITLE:${2}"$'\n'; }
tg_add_section() { local -n m=$1; m+="SECTION:${2}"$'\n'; }
tg_add_kv()      { local -n m=$1; m+="KV:${2}=${3}"$'\n'; }
tg_add_block()   { local -n m=$1; m+="${2}"; case "${2}" in *$'\n') ;; *) m+=$'\n' ;; esac; }
tg_add_footer()  { local -n m=$1; m+="FOOTER"$'\n'; }

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

# --- source 被测模块（trend 全量 + task_engine 全量；两者顶层均只定义常量/函数，
#     且都不自行 source 通知真源 telegram/tg_notify.sh——版式助手全部由上方 mock
#     提供，故 mock 定义在 source 之前同样生效。手法同 test_rotation.sh，仅顺序不同）---
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

# --- 1b. _batch_budget_stop 三态（批次循环专用闸，工作片 120min 远大于全局 600s）---
# 一批 = copy + 巩固 + 修复管线；实测 wopan175 上 3178 个文件跑 2h14m 仍未完成
# （run 34779382573 在只剩 2h3m 时开批 → 又撞 330min 硬杀），故片长取 2h
unset OPENLIST_SYNC_DEADLINE_EPOCH
if _batch_budget_stop 2>/dev/null; then bad "批次预算: 未设锚点不应停止"; else ok "批次预算: 未设锚点→不停止"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 10800 ))  # 剩 3h > 2h 片 → 可开批
if _batch_budget_stop 2>/dev/null; then bad "批次预算: 充足却停止"; else ok "批次预算: 剩 3h→仍可开批"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 5400 ))   # 剩 90min < 2h 片 → 停
if _batch_budget_stop 2>/dev/null; then ok "批次预算: 剩 90min→不再开新批"; else bad "批次预算: 剩余不足一片却仍开批"; fi

# --- 1c. _budget_slice_seconds 三态（在途传输的硬上限 = 剩余预算 − 尾部预留）---
unset OPENLIST_SYNC_DEADLINE_EPOCH
[ -z "$(_budget_slice_seconds)" ] && ok "传输上限: 无预算锚点→空（不加 timeout 包装）" || bad "传输上限: 无锚点却给值"
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 7200 ))
_v=$(_budget_slice_seconds 2700)
[ "$_v" -gt 4200 ] && [ "$_v" -le 4500 ] && ok "传输上限: 剩 2h − 45min 预留 ≈ 75min" || bad "传输上限: 期望≈4500 实得 ${_v:-空}"
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 100 ))
_v=$(_budget_slice_seconds 2700)
[ "$_v" = "60" ] && ok "传输上限: 已过点→兜底 60s（不出现 0/负）" || bad "传输上限: 期望60实得 ${_v:-空}"
unset OPENLIST_SYNC_DEADLINE_EPOCH

# --- 1d. 预算派生阈值（支持"短轮快速迭代"，2026-09-15）---
# 绝对阈值只在 320min 预算下自洽: 45min 预算 + 120min 批次片长 ⇒ 一个批次都不开，
# 短轮退化成空轮（拿不到折叠/修复管线的日志）。故按比例缩放，且默认预算下精确还原。
unset OPENLIST_BATCH_MIN_SLICE_SECONDS
OPENLIST_SYNC_BUDGET_SECONDS=19200
[ "$(_batch_slice_effective)" = "7200" ] && ok "派生: 默认 320min → 批次片长 7200（原值不变）" || bad "派生: 期望7200 实得 $(_batch_slice_effective)"
[ "$(_budget_scaled 9 64 2700 600)" = "2700" ] && ok "派生: 默认 320min → 尾部预留 2700（原值不变）" || bad "派生: 期望2700 实得 $(_budget_scaled 9 64 2700 600)"
OPENLIST_SYNC_BUDGET_SECONDS=3600   # 60min 短轮
[ "$(_batch_slice_effective)" = "1350" ] && ok "派生: 60min 轮 → 批次片长 1350（仍开得起批次）" || bad "派生: 期望1350 实得 $(_batch_slice_effective)"
[ "$(_budget_scaled 9 64 2700 600)" = "600" ] && ok "派生: 60min 轮 → 尾部预留受下限保护 600" || bad "派生: 期望600 实得 $(_budget_scaled 9 64 2700 600)"
OPENLIST_SYNC_BUDGET_SECONDS=1800   # 30min 短轮
[ "$(_batch_slice_effective)" = "900" ] && ok "派生: 30min 轮 → 片长受下限保护 900" || bad "派生: 期望900 实得 $(_batch_slice_effective)"
OPENLIST_SYNC_BUDGET_SECONDS=999999
[ "$(_batch_slice_effective)" = "7200" ] && ok "派生: 超长预算 → 不超过原默认（min 语义）" || bad "派生: 期望7200 实得 $(_batch_slice_effective)"
OPENLIST_SYNC_BUDGET_SECONDS=19200
# 显式设置必须优先于缩放（否则调参失效）
OPENLIST_BATCH_MIN_SLICE_SECONDS=1800
[ "$(_batch_slice_effective)" = "1800" ] && ok "派生: 显式 OPENLIST_BATCH_MIN_SLICE_SECONDS 优先" || bad "派生: 显式值被覆盖为 $(_batch_slice_effective)"
unset OPENLIST_BATCH_MIN_SLICE_SECONDS

# **回归锁（2026-09-15 实测踩到的真 bug）**: workflow 的真实顺序是「先 source
# load_all.sh，再 export OPENLIST_SYNC_BUDGET_SECONDS」——若缩放值在 source 时就算进
# 变量，短轮会永远拿到默认 320min 对应的 7200s 片长 ⇒ 一个批次都不开（短轮空转，
# 且日志上看不出来）。故断言: **source 之后**改预算，派生值必须跟着变。
_v=$(bash -c "source '$_REPO_ROOT/.github/scripts/openlist/task_engine.sh' >/dev/null 2>&1
  OPENLIST_SYNC_BUDGET_SECONDS=3600
  echo \"\$(_batch_slice_effective)\"")
[ "$_v" = "1350" ] && ok "派生: 预算在 source 之后设置仍生效（回归锁）" || bad "派生: source 后改预算无效，实得 [$_v]（短轮会一个批次都不开）"
_v=$(bash -c "source '$_REPO_ROOT/.github/scripts/openlist/task_engine.sh' >/dev/null 2>&1
  OPENLIST_SYNC_BUDGET_SECONDS=3600
  OPENLIST_SYNC_DEADLINE_EPOCH=\$(( \$(date +%s) + 3600 ))
  echo \"\$(_budget_slice_seconds)\"")
[ "${_v:-0}" -gt 2500 ] && ok "派生: 传输上限也按运行期预算算（尾部预留缩到下限 600）" || bad "派生: 传输上限实得 ${_v:-空}（期望>2500）"

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
# 3b) 任一源端列举失败 → 写 unknown（jsonl 落 null），不拿"按 0 求和"的假
#     进展污染趋势曲线（源端失败时该对待同步量是未知，不是 0）
PREVIEW_FAIL_SRC_PAIRS=1
trend_capture_remaining >/dev/null
v=$(cat /tmp/ol_trend_remaining.txt 2>/dev/null || echo 0)
[ "$v" = "unknown" ] && ok "trend_capture: 源端失败 → 记 unknown" || bad "trend_capture: 期望unknown实得$v"
PREVIEW_FAIL_SRC_PAIRS=0
trend_capture_remaining >/dev/null
v=$(cat /tmp/ol_trend_remaining.txt 2>/dev/null || echo 0)
[ "$v" = "300" ] && ok "trend_capture: 无源端失败 → 恢复求和" || bad "trend_capture: 期望300实得$v"
# 3c) 空 map（skip_preview 仅注册模式 / 预览未产出）→ 必须记 unknown，不能写 0:
#     写 0 会让趋势显示"剩余量清零"，是最危险的假信号（看起来像同步完成）
declare -A PREVIEW_PENDING_MAP=()
trend_capture_remaining >/dev/null
v=$(cat /tmp/ol_trend_remaining.txt 2>/dev/null || echo 0)
[ "$v" = "unknown" ] && ok "trend_capture: 无预览数据 → 记 unknown（不写 0）" || bad "trend_capture: 空 map 期望unknown实得$v"
declare -A PREVIEW_PENDING_MAP=( ["k1"]="100 1" ["k2"]="200 2" )

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
