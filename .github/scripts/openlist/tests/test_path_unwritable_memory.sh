#!/usr/bin/env bash
# 病灶 E 回归: 路径特异性坏目录必须被记住，不得反复重撞（2026-09-25）
#
# 背景: run 35989879675 单轮 156 次 `409 Conflict`，其中 90 次集中在**同一个
#   目录**（巨乳が成長し続ける女子生徒），25 分钟内被反复 sync；该轮修复成功率
#   因此只有 2.7%（成功 7 / 缺失 259）。
#
# 根因: `_backend_write_probe` 判"目标路径写不进但挂载根可写"时，为**不误熔断
#   健康后端**而按"可写"放行（_BACKEND_WRITE_PROBE_CACHE[dest]=1）。这个结论是
#   **后端级**的，却被下游当成"这个路径能写" ⇒ sync 重试 / 8005 retry /
#   409 retry 反复重入同一个已知写不进的目录。
#
# 修法: 加**路径级**坏目录记忆 _PATH_UNWRITABLE_ROUND（与后端级熔断解耦），
#   下游三条重试通路消费它，跳过重传、交折叠/换目录兜底。
#
# 本测试用**行为级**验证（非静态断言）: 真实调用标记/命中助手与"喂进去 409
#   日志"的重试函数，确认它们真的不再跑整次 sync。

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PASS=0; FAIL=0
_ok()   { PASS=$((PASS+1)); echo "  ✅ $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }

echo "=== 病灶 E: 路径特异性坏目录不得反复重撞 ==="
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# ---------- 加载被测的坏目录记忆助手 ----------
# ⚠️ 数组必须与函数配套加载: _PATH_UNWRITABLE_ROUND 在 openlist_driver.sh 里
#   `declare -A`，只截取函数体、不声明数组 ⇒ `set -u` 下访问报 unbound variable
#   （本机实测踩到）。测试桩环境要与生产声明保持一致。
DRV="$REPO_ROOT/.github/scripts/openlist/openlist_driver.sh"
declare -A _PATH_UNWRITABLE_ROUND=()
_fn_mark="$(sed -n '/^_path_unwritable_mark() {/,/^}/p' "$DRV")"
_fn_hit="$(sed -n '/^_path_unwritable_hit() {/,/^}/p' "$DRV")"
[ -n "$_fn_mark" ] && [ -n "$_fn_hit" ] || { _fail "无法截取坏目录记忆助手"; exit 1; }
eval "$_fn_mark"
eval "$_fn_hit"

echo "── T1 坏目录记忆的读写语义 ──"
DEST="openlist:wopan175/3/fc2/巨乳が成長し続ける女子生徒"
_path_unwritable_hit "$DEST" && _fail "T1a 未标记却命中（会误伤正常目录）" \
                            || _ok   "T1a 未标记时不命中"
_path_unwritable_mark "$DEST"
_path_unwritable_hit "$DEST" && _ok "T1b 标记后命中" || _fail "T1b 标记后未命中（修法无效）"
_path_unwritable_hit "openlist:wopan175/3/fc2/另一个目录" \
  && _fail "T1c 命中了未标记的邻目录（记忆串味）" || _ok "T1c 不串味到邻目录"
_path_unwritable_hit "" && _fail "T1d 空路径不应命中" || _ok "T1d 空路径不命中（非 0 返回，不会误伤）"

# ---------- 下游通路: 真跑一次 409 重试函数，看它是否还调用 sync ----------
echo "── T2 409 重试遇已知坏目录必须跳过重传 ──"
SE="$REPO_ROOT/.github/scripts/openlist/sync_engine.sh"
_fn409="$(sed -n '/^_sync_retry_409() {/,/^}/p' "$SE")"
[ -n "$_fn409" ] || { _fail "T2 无法截取 _sync_retry_409"; exit 1; }
eval "$_fn409"

# 桩: 模拟"整次 sync 被跑了一次"
SYNC_CALLS=0
run_rclone_sync_once() { SYNC_CALLS=$((SYNC_CALLS+1)); return 0; }
sync_hard_limit_stop() { return 1; }   # 硬顶尚远，排除干扰
LOG_FILENAME="$SANDBOX/round.log"
: > "$LOG_FILENAME"
dest_path="$DEST"
LAST_ATTEMPT_LOG="$SANDBOX/attempt.log"
# 喂一份含 409 的日志，触发重试分支
printf 'ERROR : x: Failed to copy: Update mkParentDir failed: Conflict: 409 Conflict\n' > "$LAST_ATTEMPT_LOG"
export OPENLIST_409_RETRY_SLEEP_SECONDS=0

SYNC_CALLS=0
_sync_retry_409
if [ "$SYNC_CALLS" -eq 0 ]; then
  _ok "T2a 已知坏目录: 409 重试未跑整次 sync（实测 ${SYNC_CALLS} 次）"
else
  _fail "T2a 已知坏目录仍跑了 ${SYNC_CALLS} 次 sync ⇒ 会重演 156 次 409"
fi
grep -q "跳过 409 重传" "$LOG_FILENAME" \
  && _ok "T2b 打出了跳过日志（可从生产核对）" || _fail "T2b 未打出跳过日志"

# 反向: 未标记的目录仍应正常重试（不能因修法把正常重试也掐了）
_path_unwritable_mark "__reset__"   # 占位，避免空数组
unset "_PATH_UNWRITABLE_ROUND[$DEST]"
SYNC_CALLS=0
_sync_retry_409
[ "$SYNC_CALLS" -ge 1 ] && _ok "T2c 未标记目录仍正常重试（不误伤，实测 ${SYNC_CALLS} 次）" \
                        || _fail "T2c 未标记目录也不重试了 ⇒ 修法过猛，会丢正常自愈机会"

echo
echo "=== 病灶 E 回归: PASS=${PASS} FAIL=${FAIL} ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
