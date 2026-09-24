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

# T4: 硬顶时放弃等待在途同步对（病灶 D 第二轮，run 35810082306 死因）
# 主循环在预算到点后仍会**阻塞** reap 在途 worker，必须能在硬顶临近时 break。
# 这里不复刻整个 _run_registry_pairs_parallel（依赖面太大），只锁判据组合:
#   「有在途(_running>0) 且 硬顶触发 → 必须停」，以及「有在途但硬顶未触发 → 继续等」。
echo "── T4 在途等待遇硬顶必须放弃 ──"
( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 60 ))
  _running=1
  if [ "$_running" -gt 0 ] && sync_hard_limit_stop; then exit 0; else exit 1; fi
) && _ok "T4a 有在途 + 硬顶触发 → 放弃等待（break 分支可达）" \
   || _fail "T4a 有在途 + 硬顶触发却未放弃等待（会重演 330min 硬杀）"

( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 3600 ))
  _running=1
  if [ "$_running" -gt 0 ] && sync_hard_limit_stop; then exit 0; else exit 1; fi
) && _fail "T4b 有在途但硬顶尚远 → 不应放弃（否则白丢在途成果）" \
   || _ok "T4b 硬顶尚远时继续等待（不误伤正常收尾）"

( export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 60 ))
  _running=0
  if [ "$_running" -gt 0 ] && sync_hard_limit_stop; then exit 0; else exit 1; fi
) && _fail "T4c 无在途不应走放弃分支（语义上是自然收工）" \
   || _ok "T4c 无在途不走放弃分支"

# T5: 锁**实际代码路径**（2026-09-23 第三处漏网点，run 35837806532 死因）
# T4 只验判据组合，不验代码里到不到得了那个分支 ⇒ T4 全绿而漏网点仍在:
#   _run_registry_pairs_parallel 里"等待在途"有**两处** —
#     ① 预算耗尽分支（要求 _pick >= 0）
#     ② 无可分发位置的收尾分支（_pick == -1: 剩余候选的后端全被在途 worker 占着）
#   run 35837806532 走的正是 ②，而修法只装在 ① ⇒ 死循环 sleep 2 到被硬杀。
#   故这里直接对源码做静态断言: 两处等待分支外层都必须在调用 reap 前查硬顶闸。
# 静态检查（而非跑函数）的理由: 复刻 _run_registry_pairs_parallel 需要
# SYNC_TASK_REGISTRY/子进程/worker 脚本等一整套依赖，成本高且易与实现漂移；
# 而"两处 reap 调用点前面都要有 sync_hard_limit_stop"是结构性事实，静态可判。
echo "── T5 等待在途的两处分支都必须有硬顶闸 ──"
_TE_SRC="$(dirname "${BASH_SOURCE[0]}")/../task_engine.sh"
if [ ! -f "$_TE_SRC" ]; then
  _fail "T5a 找不到 task_engine.sh（$_TE_SRC）"
elif [ "$(grep -c '_pairs_parallel_reap_one "\$_pp_dir"' "$_TE_SRC")" -ne 3 ]; then
  _fail "T5a reap 调用点数量变了（期望 3: 满载/预算耗尽/无可分发），需复核硬顶闸是否仍全覆盖"
else
  _ok "T5a reap 调用点共 3 处（满载 / 预算耗尽 / 无可分发）"
fi

# 逐处核对: 每个 reap 调用点**向前 12 行**内必须出现 sync_hard_limit_stop 或
# 满载分支（满载分支靠预算闸在后续重入时收敛，本身就是有界等待）。
if [ -f "$_TE_SRC" ]; then
  _miss=""
  while IFS=: read -r _ln _; do
    _win=$(sed -n "$(( _ln > 12 ? _ln - 12 : 1 )),${_ln}p" "$_TE_SRC")
    case "$_win" in
      *sync_hard_limit_stop*) : ;;
      *'$_running" -ge "$_par"'*) : ;;
      *) _miss="$_miss $_ln" ;;
    esac
  done < <(grep -n '_pairs_parallel_reap_one "\$_pp_dir"' "$_TE_SRC")
  if [ -n "$_miss" ]; then
    _fail "T5b 这些 reap 调用点(${_miss} )前 12 行内既无硬顶闸也无满载保护 ⇒ 会无界阻塞"
  else
    _ok "T5b 全部 reap 调用点均由硬顶闸或满载保护覆盖"
  fi
fi

# 反向断言: 无可分发分支（_pick == -1 时落到的那处）必须带 SYNC_TIME_EXHAUSTED 置位
# —— 否则跳出后上层仍以为"预算未耗尽"，会继续开后续工作。
if [ -f "$_TE_SRC" ]; then
  _tail_block=$(awk '/# 没有可分发的位置/{f=1} f{print} f&&/^    break$/{exit}' "$_TE_SRC")
  case "$_tail_block" in
    *sync_hard_limit_stop*SYNC_TIME_EXHAUSTED=1*|*SYNC_TIME_EXHAUSTED=1*sync_hard_limit_stop*)
      _ok "T5c 无可分发收尾分支: 硬顶放弃时同时置 SYNC_TIME_EXHAUSTED" ;;
    *) _fail "T5c 无可分发收尾分支缺硬顶闸或未置 SYNC_TIME_EXHAUSTED" ;;
  esac
fi

# T6: 修复管线的**单次调用内部**也要有硬顶闸（2026-09-24 第四处，run 35946181786）
# 与前几处的区别: 前三处是"循环体内部无闸"，这里是"单次调用内部无闸，而单次
#   调用本身可达几十分钟"。4 种方法是**顺序块**，只有"取下一个文件前"那道闸，
#   进入 _try_fix_methods_round 后 deadline 早就过了（该轮 65min 全无产出）。
# 同样是**结构断言**（T5 教训: 判据型断言测不出路径可达性）。
echo "── T6 修复管线方法轮转与退避都必须有硬顶闸 ──"
_FF_SRC="$REPO_ROOT/.github/scripts/openlist/file_fix.sh"
_SE_SRC="$REPO_ROOT/.github/scripts/openlist/sync_engine.sh"

# T6a: 4 种方法（顺序块）每个入口前都得有闸。方法1/2 各一处，方法3/4 共用一处。
# ⚠️ 必须只数**调用点**（`if _fix_hard_limit_reached "..."`），不能把函数定义体
#   里的 `declare -F` 行算进来 —— 否则"闸只定义未接线"会被数成 2 处而漏判
#   （反向验证时发现: 撤光 3 处调用后仍报 2 ⇒ 断言形同虚设）。
if [ -f "$_FF_SRC" ]; then
  _gates=$(grep -c '^  if _fix_hard_limit_reached "' "$_FF_SRC")
  _gates="${_gates:-0}"
  if [ "$_gates" -ge 3 ]; then
    # 再验覆盖到的步骤名齐全（防止三处都装在同一方法上）
    _names=$(grep -o '_fix_hard_limit_reached "[^"]*"' "$_FF_SRC" | sort -u | wc -l | tr -d ' ')
    [ "$_names" -ge 3 ] && _ok "T6a 方法轮转处硬顶闸 ${_gates} 处，覆盖 ${_names} 个不同步骤" \
                        || _fail "T6a 闸虽 ${_gates} 处但只覆盖 ${_names} 个步骤（疑似重复装在同一方法）"
  else
    _fail "T6a 方法轮转处硬顶闸调用仅 ${_gates} 处，至少需 3（方法1/方法2/方法3-4）"
  fi
else
  _fail "T6a 找不到 file_fix.sh"
fi

# T6b: 闸不能只写调用——被调函数必须存在且有降级分支（未加载时不炸）
if [ -f "$_FF_SRC" ]; then
  _body="$(sed -n '/^_fix_hard_limit_reached() {/,/^}/p' "$_FF_SRC")"
  case "$_body" in
    *'declare -F sync_hard_limit_stop'*'sync_hard_limit_stop'*)
      _ok "T6b _fix_hard_limit_reached 已定义且对未加载场景降级（declare -F 探测）" ;;
    *) _fail "T6b _fix_hard_limit_reached 缺失或缺少 declare -F 降级 ⇒ 单测/还原模式会炸" ;;
  esac
fi

# T6c: 423 / 409 退避的 sleep 之前必须有闸（方案 B 的另一半）
# ⚠️ 反向验证时的教训: 初版用 grep -c 数 `sleep "$lock_retry_sleep"` 恒为 1，
#   于是"闸被撤掉了"也照样报绿 —— **计数型断言测不出闸是否还在**。故这里改为:
#   逐个 sleep 行取前 6 行窗口，窗口内必须出现 sync_hard_limit_stop，缺一个即红。
if [ -f "$_SE_SRC" ]; then
  _miss_sleep=""
  _seen=0
  while IFS=: read -r _ln _; do
    _seen=$((_seen + 1))
    _win=$(sed -n "$(( _ln > 6 ? _ln - 6 : 1 )),${_ln}p" "$_SE_SRC")
    case "$_win" in
      *sync_hard_limit_stop*) : ;;
      *) _miss_sleep="$_miss_sleep $_ln" ;;
    esac
  done < <(grep -n 'sleep "\$lock_retry_sleep"\|sleep "\$conflict_retry_sleep"' "$_SE_SRC")
  if [ "$_seen" -lt 2 ]; then
    _fail "T6c 只找到 ${_seen} 处退避 sleep（期望 ≥2: 423 与 409），签名可能已改名"
  elif [ -n "$_miss_sleep" ]; then
    _fail "T6c 这些退避 sleep(${_miss_sleep} )前 6 行内无硬顶闸 ⇒ 300s 纯等待可拖过硬杀线"
  else
    _ok "T6c 全部 ${_seen} 处退避 sleep 前均有硬顶闸（423 + 409）"
  fi
else
  _fail "T6c 找不到 sync_engine.sh"
fi

# T7: 阻塞等待函数**内部**必须自带硬顶复查（2026-09-25 第五处，run 35989879675）
# 这是第四次同形态教训的固化: 闸装在**调用点前**只能判"进入等待的那一瞬间"。
#   _pairs_parallel_reap_one 是 `while :; do ... sleep 2; done` 的无限轮询，
#   一旦进入就回不到主循环 ⇒ 调用点前的闸永远只有第一次有效。
#   实证对照: run 35900336446 进入时恰好已到硬顶 ⇒ 闸生效、success；
#             run 35989879675 进入时距硬顶 14min ⇒ 进去后再没出来 ⇒ 硬杀。
# 结构断言三件: ①轮询体内有闸 ②reap 返回 1 表示撞顶 ③三处调用点都用返回值收摊。
echo "── T7 阻塞等待内部必须自带硬顶复查 ──"
if [ -f "$_TE_SRC" ]; then
  # T7a: 闸必须在 _pairs_parallel_reap_one 函数体内（而非只在调用方）
  _reap_body="$(sed -n '/^_pairs_parallel_reap_one() {/,/^}/p' "$_TE_SRC")"
  case "$_reap_body" in
    *'while :; do'*sync_hard_limit_stop*'return 1'*)
      _ok "T7a reap 轮询体内有硬顶复查且撞顶返回 1" ;;
    *) _fail "T7a reap 轮询体内缺硬顶复查/未返回 1 ⇒ 进入后即无界（第五处死因）" ;;
  esac

  # T7b: 三处调用点必须**消费返回值**收摊（`if ! ...; then`），不能裸调用
  _bare=""
  while IFS=: read -r _ln _rest; do
    case "$_rest" in
      *'if ! _pairs_parallel_reap_one'*) : ;;
      *) _bare="$_bare $_ln" ;;
    esac
  done < <(grep -n '_pairs_parallel_reap_one "\$_pp_dir"' "$_TE_SRC")
  if [ -n "$_bare" ]; then
    _fail "T7b 这些 reap 调用(${_bare} )未消费返回值 ⇒ 撞顶后仍不收摊"
  else
    _ok "T7b 全部 reap 调用均消费返回值并在撞顶时收摊"
  fi
else
  _fail "T7 找不到 task_engine.sh"
fi

echo
echo "=== 病灶 D 回归: PASS=${PASS} FAIL=${FAIL} ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
