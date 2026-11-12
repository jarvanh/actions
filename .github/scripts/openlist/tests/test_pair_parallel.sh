#!/bin/bash
# 并行同步对（run_all_tasks 的 OPENLIST_PAIR_PARALLEL 分支）—— 调度逻辑验证
# 背景: 诊断实测后端有**总量带宽上限**（transfers 1→4 只把吞吐从 0.60 提到
#   1.00 MiB/s），所以单后端加并发收益有限；真正的杠杆是同时用多个后端各自的
#   额度。故引入"按后端分组调度"：跨后端并行、同后端串行。
# 验证:
#   1. 默认（OPENLIST_PAIR_PARALLEL=1）→ 走串行路径，不发生任何重叠
#   2. =2 → 不同后端可同时跑（记录到并发），**同一后端绝不并行**
#   3. 预算将尽 → 不再分发新同步对，且游标推进到"本轮未启动的第一个同步对"
#   4. 每个同步对的完成状态/字节被父级正确合并（失败计数、字节累加）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

WORK="/tmp/pair_par_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
SYNC_STATE_DIR="$WORK"

# --- mocks ---
rclone() { case "$1" in cat) cat "$2" 2>/dev/null ;; *) return 0 ;; esac; }
# 游标写入落到本地文件，便于断言（_rotation_save 经 _marker_write）
_marker_write() { printf '%s' "$1" > "$2"; return 0; }
progress_update_force() { :; }
format_bytes() { echo "${1}B"; }

REC="$WORK/rec"
INFLIGHT="$WORK/inflight"
_inc() { local v; v=$(cat "$1" 2>/dev/null || echo 0); echo $((v + 1)) > "$1"; }
_dec() { local v; v=$(cat "$1" 2>/dev/null || echo 0); [ "$v" -gt 0 ] && v=$((v - 1)); echo "$v" > "$1"; }

# 假执行器: 用 mkdir 做原子锁检测**并发**（比时间戳稳，不依赖 sleep 精度）。
# 关键手法: 锁在整个调用期间持有 —— 这样"第二个人拿到同一把锁失败"就等于
# "确有并发"。反过来写（一次调用里拿两把不同的锁）永远成功，检不出任何东西。
#   - 全局锁 in_call: 拿不到 ⇒ 有别人在跑 → 记 CONCURRENT
#   - 每后端锁 lock_<be>: 拿不到 ⇒ 同后端并发 → 记 OVERLAP
_run_registry_entry() {
  local _e="$1" _id _src _dst _name _flags
  IFS='|' read -r _id _src _dst _name _flags <<< "$_e"
  local _be="${_dst#openlist:}"; _be="${_be%%/*}"
  if ! mkdir "$WORK/in_call" 2>/dev/null; then
    echo "CONCURRENT $_id $_be" >> "$REC"
  fi
  if ! mkdir "$WORK/lock_$_be" 2>/dev/null; then
    echo "OVERLAP $_be $_id" >> "$REC"
  fi
  echo "START $_id $_be" >> "$REC"
  _inc "$INFLIGHT"
  sleep 0.6
  _dec "$INFLIGHT"
  echo "END $_id $_be" >> "$REC"
  rmdir "$WORK/lock_$_be" 2>/dev/null || true
  rmdir "$WORK/in_call" 2>/dev/null || true
  # 状态/字节: 由 status_map / bytes_map 控制（文件形式，跨子 shell 可见）
  local _st _by
  _st=$(sed -n "s/^${_id}=//p" "$WORK/status_map" 2>/dev/null | head -1)
  _by=$(sed -n "s/^${_id}=//p" "$WORK/bytes_map" 2>/dev/null | head -1)
  SYNC_SKIPPED=0; SYNC_FAILED=0; SYNC_PARTIAL=0
  case "${_st:-synced}" in
    skipped) SYNC_SKIPPED=1 ;;
    failed)  SYNC_FAILED=1 ;;
    partial) SYNC_PARTIAL=1; SYNC_FAILED=1 ;;
    *) : ;;
  esac
  SYNC_TRANSFERRED_BYTES="${_by:-0}"
}

SYNC_TASK_REGISTRY=(
  "p0|s0|openlist:wopan176Crypt/0|t0|"
  "p1|s1|openlist:wopan175/0|t1|"
  "p2|s2|openlist:wopan176Crypt/1|t2|"
  "p3|s3|openlist:baidupanCrypt/0|t3|"
)
ROTATION_MAX_CONSECUTIVE_ATTEMPTS=8
OPENLIST_TASK_ROTATION=1

reset_case() {
  rm -rf "$WORK"/lock_* "$WORK"/in_call
  rm -f "$REC" "$INFLIGHT" "$WORK/task_rotation.json" "$WORK/status_map" "$WORK/bytes_map"
  echo 0 > "$INFLIGHT"
  : > "$REC"; : > "$WORK/status_map"; : > "$WORK/bytes_map"
  unset OPENLIST_SYNC_DEADLINE_EPOCH
  SYNC_TIME_EXHAUSTED=0
}
cursor_now() { sed -n 's/.*"cursor"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$WORK/task_rotation.json" 2>/dev/null | head -1; }
# ⚠️ 不能写 `grep -c … || echo 0`: grep -c 无匹配时**已经打印 0 并返回 1**，
#   `|| echo 0` 会再追加一个 0 ⇒ 变量变成 "0\n0"，整数比较与等值比较都会失败。
#   此前计数恒 >0 时没暴露，一旦场景断言"0 个"就炸（3d 加进来时实测）。
starts() { local n; n=$(grep -c '^START ' "$REC" 2>/dev/null || true); printf '%s' "${n:-0}"; }

# --- 1. 默认串行: 不发生重叠 ---
reset_case
OPENLIST_PAIR_PARALLEL=1
run_all_tasks >/dev/null 2>&1
[ "$(starts)" = "4" ] && ok "1a 默认串行: 4 个同步对全部执行" || bad "1a: 执行 $(starts) 个"
[ "$(grep -c '^CONCURRENT' "$REC" 2>/dev/null || :)" = "0" ] && ok "1b 默认串行: 无任何并发" || bad "1b: 出现并发"

# --- 2. =2: 跨后端并行、同后端串行 ---
reset_case
OPENLIST_PAIR_PARALLEL=2
run_all_tasks >/dev/null 2>&1
[ "$(starts)" = "4" ] && ok "2a 并行: 4 个同步对全部执行" || bad "2a: 执行 $(starts) 个"
[ "$(grep -c '^OVERLAP' "$REC" 2>/dev/null || :)" = "0" ] \
  && ok "2b 同一后端绝不并行（无 OVERLAP）" || bad "2b: 同后端重叠 $(grep -c '^OVERLAP' "$REC" 2>/dev/null || :) 次"
[ "$(grep -c '^CONCURRENT' "$REC" 2>/dev/null || :)" -ge 1 ] \
  && ok "2c 确有跨后端并发（观察到两个同步对同时在跑）" || bad "2c: 未观察到并发"

# --- 3. 预算将尽: 不再分发；游标指向本轮未启动的第一个同步对 ---
# 注: 这里显式把「份额可用下限」关到 1s，**单独**验证预算闸（sync_budget_stop）。
#   否则 601s 的 deadline 会让有效份额只剩 60s（_budget_slice_seconds 扣掉尾部预留），
#   被"份额不足不下发"闸先拦掉，就测不到预算闸本身了（两条闸分别锁定，见 3d）。
reset_case
OPENLIST_PAIR_PARALLEL=2
OPENLIST_SYNC_MIN_SLICE_SECONDS=600
OPENLIST_PAIR_MIN_USABLE_SECONDS=1
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 601 ))   # 首轮可分发，随后即到点
run_all_tasks >/dev/null 2>&1
_n=$(starts)
[ "$_n" -lt 4 ] && ok "3a 预算将尽: 只执行 ${_n}/4 个（不再无限分发）" || bad "3a: 仍执行 4 个"
[ "${SYNC_TIME_EXHAUSTED:-0}" = "1" ] && ok "3b 置 SYNC_TIME_EXHAUSTED=1" || bad "3b: 未置位"
# 已启动的 id 集合 → 第一个未启动的索引就是期望游标
_started_ids=$(sed -n 's/^START \([^ ]*\) .*/\1/p' "$REC" | sort -u)
_expect=""
for _i in 0 1 2 3; do
  _id="p$_i"
  printf '%s\n' "$_started_ids" | grep -qxF "$_id" || { _expect="$_i"; break; }
done
_cur=$(cursor_now)
if [ -z "$_expect" ]; then
  ok "3c 全部启动过 → 游标回到起点（$_cur 为 0 或原起点）"
else
  [ "$_cur" = "$_expect" ] && ok "3c 游标指向未启动的第一个同步对（${_cur}）" \
    || bad "3c: 期望游标 ${_expect} 实得 ${_cur}"
fi

# --- 3d. 有效份额不足可用下限 ⇒ 本轮一个都不分发、游标留在起点 ---
# 现场（run 43125112722）: 轮末「份额 1min」的对被分发出去，却因
#   sync_budget_stop（需 ≥600s 才开新单元）一个单元都开不了，占槽位空转 7.7 分钟，
#   最后记 `truncated · 0 B` —— 看着像"传不动"，其实"没开工"。
#   现语义: 份额 < 300s 直接不分发，游标留在本对，下轮优先。
reset_case
OPENLIST_PAIR_PARALLEL=2
unset OPENLIST_PAIR_MIN_USABLE_SECONDS
OPENLIST_SYNC_MIN_SLICE_SECONDS=600
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 601 ))   # 有效份额仅 ~60s
run_all_tasks >/dev/null 2>&1
_n=$(starts)
[ "$_n" = "0" ] && ok "3d 份额 < 300s → 本轮 0 个分发（不再空转）" || bad "3d: 仍分发 ${_n} 个"
[ "$(cursor_now)" = "0" ] && ok "3d2 游标留在起点 0（下轮优先服务它）" || bad "3d2 游标=$(cursor_now)"

# --- 4. 完成状态与字节合并 ---
reset_case
OPENLIST_PAIR_PARALLEL=2
printf 'p0=failed\np1=synced\np2=skipped\np3=partial\n' > "$WORK/status_map"
printf 'p0=100\np1=200\np2=0\np3=300\n' > "$WORK/bytes_map"
run_all_tasks > "$WORK/out4.log" 2>&1
[ "$(starts)" = "4" ] && ok "4a 全部 4 个执行" || bad "4a: $(starts) 个"
grep -q "本轮 4 个（失败 2）" "$WORK/out4.log" \
  && ok "4b 失败计数合并正确（failed + partial = 2）" || bad "4b: $(grep '本轮' "$WORK/out4.log" | tail -1)"
grep -qE "600B" "$WORK/out4.log" && ok "4c 字节累加合并正确（100+200+0+300）" \
  || bad "4c: 未见 600B 汇总"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
