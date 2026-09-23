#!/usr/bin/env bash
# 病灶 D 回归测试（2026-09-23）: 预算闸外的无界段必须收敛
#
# 背景: run 35717590337 / 35773926579 连续两轮 conclusion=failure，死因同为
#   `The action '任务预览与全量同步' has timed out after 330 minutes`。
#   根因不是"预算算错"，而是**预算闸只拦循环入口**: 一旦进入循环体，内部的
#   逐条远端 marker 写回（2–4s/条）就在闸外无界 —— 74 条 leftover 即溢出 ~11min，
#   正好吃光 320min 预算与 330min 平台硬顶之间的 10min 缓冲。
#
# 本测试锁三条不变量（任一条破了就会重演 330min 硬杀）:
#   T1 leftover 清理: N 条假成功条目 → marker 写回 **1 次**（不是 N 次）
#   T2 折叠记账: N 条落盘条目 → marker 写回 **1 次**（不是 N 次）
#   T3 sync_hard_limit_stop 语义: 未注入锚点不触发；距硬顶 <reserve> 触发；
#      距硬顶 >reserve 不触发；非数字 reserve 回落 480
#
# 与 test_restore_real_local.sh 的分工: 那个验"文件真的落盘且能还原"（真 rclone），
#   本测试只验"写回次数与硬顶判据"（纯计数 + 时间算术），不需要真实网盘。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PASS=0; FAIL=0
_ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 病灶 D: 预算闸外无界段回归 ==="

# ---------- 公共桩: 只 source 被测函数所在文件，桩掉它的外部依赖 ----------
# file_fix_pipeline.sh 依赖面很大（rclone/jq/openlist 驱动），这里只计量写回次数，
# 故用最小桩把 _marker_write 换成计数器，其余依赖按需桩掉。
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

MARKER_WRITES=0
_marker_write() { MARKER_WRITES=$((MARKER_WRITES+1)); cat > "$SANDBOX/marker_written.json"; return 0; }
fix_blacklist_to_json() { echo '{}'; }
_short_path() { echo "${1##*/}"; }
_fix_event() { :; }
format_bytes() { echo "1 KiB"; }

# T1: leftover 清理的批量写回
echo "── T1 leftover 清理: N 条 → 1 次写回 ──"
T1_STATE="$SANDBOX/t1_state.json"
cat > "$T1_STATE" <<'JSON'
{"fixed_files":[{"original":"a/1.jpg","size_bytes":10},{"original":"a/2.jpg","size_bytes":20},{"original":"a/3.jpg","size_bytes":30}],"fixed_count":3,"fixed_bytes":60}
JSON
# 只取 _remove_fix_entries_batch 一个函数: 用 sed 截出函数体再 eval，避免 source
# 整个管道文件（那会拉起 rclone/openlist 依赖）。
_fn="$(sed -n '/^_remove_fix_entries_batch() {/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh")"
[ -n "$_fn" ] || { _fail "T1 无法截取 _remove_fix_entries_batch（函数签名可能被改名）"; }
eval "$_fn"

MARKER_WRITES=0
out_file="$SANDBOX/t1_out.txt"
_remove_fix_entries_batch "$T1_STATE" "openlist:/fake/marker.json" "a/1.jpg" "a/2.jpg" "a/3.jpg" > "$out_file" 2>&1
out="$(cat "$out_file")"
[ "$MARKER_WRITES" -eq 1 ] && _ok "T1a 3 条 leftover 只触发 1 次 marker 写回（实测 ${MARKER_WRITES}）" \
                           || _fail "T1a 期望 1 次写回，实测 ${MARKER_WRITES} 次"
left=$(jq -r '.fixed_count' "$T1_STATE")
[ "$left" = "0" ] && _ok "T1b 3 条全部从 marker 移除（fixed_count=${left}）" \
                  || _fail "T1b 期望 fixed_count=0，实测 ${left}"
case "$out" in *"批量移除 3 条"*) _ok "T1c 汇总日志含条数";; *) _fail "T1c 汇总日志异常: $out";; esac

# 空命中（条目都不在 marker 里）时不应再花一次远端往返 —— 本段的存在意义
# 就是省掉无谓往返，空写回属于自相矛盾。
MARKER_WRITES=0
_remove_fix_entries_batch "$T1_STATE" "openlist:/fake/marker.json" "a/1.jpg" >/dev/null 2>&1
[ "$MARKER_WRITES" -eq 0 ] && _ok "T1d 空命中不写回（省掉无谓的远端往返）" \
                           || _fail "T1d 空命中写回次数=${MARKER_WRITES}，期望 0"

# T2: 折叠记账的批量写回
echo "── T2 折叠记账: N 条 → 1 次写回 ──"
T2_STATE="$SANDBOX/t2_state.json"
T2_ENT="$SANDBOX/t2_entries.ndjson"
cp "$REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh" /dev/null 2>/dev/null
cat > "$T2_STATE" <<'JSON'
{"fixed_files":[],"fixed_count":0,"fixed_bytes":0}
JSON
: > "$T2_ENT"
f="abc12345"
for i in 1 2 3 4 5; do
  jq -cn --arg o "d/f${i}.jpg" --arg a "h${f}/f${i}.jpg" --argjson sb "$((i*100))" \
    '{original:$o, alternative:$a, method:"rclone copyto（短哈希目录 h + 原文件名）", restore_hint:"rclone moveto ..", size_human:"1 KiB", size_bytes:$sb, method_id:"copyto_original"}' >> "$T2_ENT"
done
_fn2="$(sed -n '/^_persist_fix_entries_batch() {/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh")"
[ -n "$_fn2" ] || { _fail "T2 无法截取 _persist_fix_entries_batch"; }
eval "$_fn2"

MARKER_WRITES=0
_persist_fix_entries_batch "openlist:/fake/marker.json" "$T2_STATE" "src" "dst" "$T2_ENT"
[ "$MARKER_WRITES" -eq 1 ] && _ok "T2a 5 条折叠条目只触发 1 次写回（实测 ${MARKER_WRITES}）" \
                           || _fail "T2a 期望 1 次写回，实测 ${MARKER_WRITES} 次"
n2=$(jq -r '.fixed_count' "$T2_STATE")
[ "$n2" = "5" ] && _ok "T2b 5 条全部进 marker（fixed_count=${n2}）" \
                 || _fail "T2b 期望 fixed_count=5，实测 ${n2}"
# 条目必须带 restore_hint（还原链依赖它判 hash_dir）
rh=$(jq -r '[.fixed_files[] | select(.restore_hint != null)] | length' "$T2_STATE")
[ "$rh" = "5" ] && _ok "T2c 全部条目带 restore_hint（还原链可消费）" \
                 || _fail "T2c 带 restore_hint 的条目数=${rh}，期望 5"
# 幂等覆盖: 同 original 再记一次不应产生重复条目
MARKER_WRITES=0
_persist_fix_entries_batch "openlist:/fake/marker.json" "$T2_STATE" "src" "dst" "$T2_ENT"
n2b=$(jq -r '.fixed_count' "$T2_STATE")
[ "$n2b" = "5" ] && _ok "T2d 重复记账不产生重复条目（仍 ${n2b}）" \
                  || _fail "T2d 重复记账后 fixed_count=${n2b}，期望 5（幂等覆盖被破坏）"

# T3: 硬顶闸语义
echo "── T3 sync_hard_limit_stop 判据 ──"
_fn3="$(sed -n '/^sync_hard_limit_stop() {/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/task_engine.sh")"
[ -n "$_fn3" ] || { _fail "T3 无法截取 sync_hard_limit_stop"; }
eval "$_fn3"

# 3a 未注入锚点 → 不触发（return 1），否则调试/单测会被误伤
( unset OPENLIST_STEP_HARD_LIMIT_EPOCH OPENLIST_STEP_TAIL_RESERVE_SECONDS
  sync_hard_limit_stop ) && _fail "T3a 未注入锚点时应不触发" || _ok "T3a 未注入锚点不触发"

# 3b 距硬顶 10min > reserve 480s → 不触发
( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 600 ))
  sync_hard_limit_stop ) && _fail "T3b 距硬顶 600s 不应触发（reserve=480）" \
                        || _ok "T3b 距硬顶 600s 不触发"

# 3c 距硬顶 60s < reserve → 触发
( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 60 ))
  sync_hard_limit_stop ) && _ok "T3c 距硬顶 60s 触发" \
                        || _fail "T3c 距硬顶 60s 应触发"

# 3d reserve 可配（显式传 60，距硬顶 300s → 不触发）
( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 300 ))
  sync_hard_limit_stop 60 ) && _fail "T3d 显式 reserve=60 且距硬顶 300s 不应触发" \
                           || _ok "T3d 显式 reserve 生效"

# 3e 非数字 reserve 回落 480（距硬顶 600s → 不触发；若回落失效按 0 处理也不会触发，
#     故改用距硬顶 300s 且传非数字: 回落 480 会触发，按 0 处理则不触发）
( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 300 ))
  export OPENLIST_STEP_TAIL_RESERVE_SECONDS="abc"
  sync_hard_limit_stop ) && _ok "T3e 非数字 reserve 回落 480（距硬顶 300s 触发）" \
                         || _fail "T3e 非数字 reserve 未回落 480"

echo
echo "=== 病灶 D 回归: PASS=${PASS} FAIL=${FAIL} ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
