#!/usr/bin/env bash
# 病灶 D 第五处**行为级**快速验证（秒级，不需生产轮）
#
# 为什么需要它: T7 是静态断言，只能证明"闸装进去了"，证明不了"等待中途到顶
#   真的能退出来"——而第五处的死因恰恰是**等待中途**到顶退不出来。生产轮验证
#   一次要 5.5h，本机仿真几秒即可覆盖该时序。
#
# 复现的真实时序（run 35989879675）:
#   进入等待时距硬顶 14min（> reserve 480s）⇒ 闸未触发 ⇒ 进入 reap 无限轮询
#   ⇒ 再也没回到主循环 ⇒ 被硬杀。
#   修法前: 永远出不来（超时）
#   修法后: 轮询内每轮查硬顶，到顶即 return 1

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PASS=0; FAIL=0
_ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 病灶 D 第五处: 等待中途撞硬顶必须能退出 ==="

# ---- 最小桩环境: 只加载被测函数 ----
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# 判据（直接内联，与 task_engine.sh 的同名实现保持一致）
sync_hard_limit_stop() {
  [ -n "${OPENLIST_STEP_HARD_LIMIT_EPOCH:-}" ] || return 1
  local reserve="${1:-${OPENLIST_STEP_TAIL_RESERVE_SECONDS:-480}}"
  [ $(( $(date +%s) + reserve )) -ge "$OPENLIST_STEP_HARD_LIMIT_EPOCH" ]
}
format_bytes() { echo "0 B"; }

# 取出被测函数（不 source 整个 engine，避免拉起 rclone/openlist 依赖）
_fn="$(sed -n '/^_pairs_parallel_reap_one() {/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/task_engine.sh")"
[ -n "$_fn" ] || { _fail "无法截取 _pairs_parallel_reap_one"; echo "EXIT=1"; exit 1; }
eval "$_fn"

# 构造"永远不会有 worker 完成"的等待场景: _pp_pid 为空 ⇒ 扫描不到 .done 文件
# ⇒ 每轮都走到底部 sleep 2（用_wait_sleep 替换真实 sleep 以便秒级仿真）
_pp_dir="$SANDBOX/pp"
mkdir -p "$_pp_dir"
declare -A _pp_pid=() _pp_be=() _pp_dst=() _busy_be=()
_pp_n=16 _done_n=0 _failed_n=0 total_transferred=0

# 把 sleep 2 替换成 sleep 0.05，让"等待中途到顶"在 1 秒内发生
_fn_fast="${_fn//sleep 2/sleep 0.05}"
eval "$_fn_fast"

# ---- 场景: 进入时距硬顶 4s（闸未触发），硬顶在 2s 后到达 ----
# reserve=1s ⇒ 触发条件为 now+1 >= 硬顶；进入时 4s 后到顶 ⇒ 未触发
export OPENLIST_STEP_TAIL_RESERVE_SECONDS=1
export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 4 ))

_timeout_bin="$(command -v timeout || echo '')"
if [ -n "$_timeout_bin" ]; then
  # timeout 不能直接跑 shell 函数（函数是当前 shell 的，不是外部命令）
  # ⇒ 放到后台子进程里跑，用后台 wait + 计时判断它是否在超时前退出。
  _pairs_parallel_reap_one "$_pp_dir" > "$SANDBOX/out.txt" 2>&1 &
  _pid=$!
  _deadline=$(( $(date +%s) + 10 ))
  rc=0
  while kill -0 "$_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$_deadline" ]; then
      kill "$_pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 0.1
  done
  if [ "$rc" != 124 ]; then wait "$_pid"; rc=$?; fi
else
  _pairs_parallel_reap_one "$_pp_dir" > "$SANDBOX/out.txt" 2>&1
  rc=$?
fi

if [ "$rc" -eq 124 ]; then
  _fail "等待中途撞硬顶仍退不出来（10s 超时）⇒ 第五处未修，生产会重演 330min 硬杀"
else
  _ok "等待中途撞硬顶能退出（rc=${rc}，未超时）"
fi

case "$(cat "$SANDBOX/out.txt")" in
  *"⏰ 距平台硬顶不足收尾预留，放弃等待在途同步对"*)
    _ok "退出时打出了收摊文案（可从生产日志核对）" ;;
  *) _fail "退出但未打出收摊文案: $(cat "$SANDBOX/out.txt")" ;;
esac

# rc 必须非 0，调用方才能据此 break
[ "$rc" -eq 1 ] && _ok "以 rc=1 返回（调用方据此 break 收摊）" \
                || _fail "返回码应为 1（撞顶），实测 ${rc}"

# ---- 反向: 硬顶尚远时不应提前放弃 ----
export OPENLIST_STEP_HARD_LIMIT_EPOCH=$(( $(date +%s) + 3600 ))
_pairs_parallel_reap_one "$_pp_dir" > "$SANDBOX/out2.txt" 2>&1 &
_pid2=$!
_deadline2=$(( $(date +%s) + 3 ))
rc2=0
while kill -0 "$_pid2" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$_deadline2" ]; then
    kill "$_pid2" 2>/dev/null || true
    rc2=124
    break
  fi
  sleep 0.1
done
if [ "$rc2" != 124 ]; then wait "$_pid2"; rc2=$?; fi
[ "$rc2" -eq 124 ] && _ok "硬顶尚远时不误退（仍在等待，未提前放弃）" \
                   || _fail "硬顶尚远却提前放弃（rc=${rc2}）⇒ 会白丢在途成果"

echo
echo "=== 第五处行为验证: PASS=${PASS} FAIL=${FAIL} ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
