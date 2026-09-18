#!/bin/bash
# F22 写探针周期性重探 + F10 405 快速失败 —— 纯判据函数单测
#
# 背景:
#   F22（_write_reprobe_due）: 写探针的"可写"结论只对 t=0 有效（实测同一路径
#     单文件顺序写全过、生产同路径 1034 文件全 405）。批次循环按时间周期清缓存
#     重探，才能发现"跑着跑着后端才变坏"。本测覆盖判据本身（到期/未到期/未设锚点）。
#   F10（_batch_405_flood）: 单批 405 计数达阈值即判"该目录本轮写不进"，
#     先于巩固中止剩余批次（历史一个坏目录逐文件烧 115min）。本测覆盖阈值判定。
#
# 两者是纯判据（无远端依赖），可脱离批次 harness 单独验证；批次循环里的接线
# 由 test_batch_precheck_circuit_breaker.sh 的 G10/G11 覆盖。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

WORK="/tmp/write_reprobe_405_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

# ===== F22 _write_reprobe_due =====
# 未设锚点（本轮首次调用）→ 视为到期（入口预检刚探过，重探成本秒级、幂等无害）
_WRITE_PROBE_LAST_TS=""
if _write_reprobe_due; then ok "1a 未设锚点 → 到期（视为需重探）"; else bad "1a: 未设锚点却判未到期"; fi

# 刚探过（now）→ 未到期
_WRITE_PROBE_LAST_TS=$(date +%s)
if _write_reprobe_due; then bad "1b: 刚探过却判到期"; else ok "1b 刚探过 → 未到期"; fi

# 距今超过间隔（默认 1800s）→ 到期
_WRITE_PROBE_LAST_TS=$(( $(date +%s) - 1801 ))
if _write_reprobe_due; then ok "1c 距今 1801s（>默认 1800）→ 到期"; else bad "1c: 超间隔却判未到期"; fi

# 自定义间隔生效
OPENLIST_WRITE_REPROBE_INTERVAL=100
_WRITE_PROBE_LAST_TS=$(( $(date +%s) - 101 ))
if _write_reprobe_due; then ok "1d 自定义间隔 100s、距今 101s → 到期"; else bad "1d: 自定义间隔未生效"; fi
_WRITE_PROBE_LAST_TS=$(( $(date +%s) - 50 ))
if _write_reprobe_due; then bad "1e: 自定义间隔 100s、距今 50s 却判到期"; else ok "1e 自定义间隔内 → 未到期"; fi
unset OPENLIST_WRITE_REPROBE_INTERVAL

# 间隔=0/非数字 → 关闭重探（不得因脏配置误重探或报错）
OPENLIST_WRITE_REPROBE_INTERVAL=0
_WRITE_PROBE_LAST_TS=$(( $(date +%s) - 99999 ))
if _write_reprobe_due; then bad "1f: 间隔=0 却判到期（应关闭重探）"; else ok "1f 间隔=0 → 关闭重探"; fi
unset OPENLIST_WRITE_REPROBE_INTERVAL

# 非数字间隔 → 回落默认 1800（不得报错；距今 1s → 未到期）
OPENLIST_WRITE_REPROBE_INTERVAL="abc"
_WRITE_PROBE_LAST_TS=$(( $(date +%s) - 1 ))
if _write_reprobe_due; then bad "1g: 非数字间隔未回落默认"; else ok "1g 非数字间隔回落默认 1800（距今 1s 未到期）"; fi
unset OPENLIST_WRITE_REPROBE_INTERVAL

# 非数字锚点（脏值）→ 视为到期（保守重探，宁可多探不可漏探）
_WRITE_PROBE_LAST_TS="garbage"
if _write_reprobe_due; then ok "1h 脏锚点 → 到期（保守重探）"; else bad "1h: 脏锚点却判未到期"; fi

# ===== F10 _batch_405_flood =====
# 阈值 = OPENLIST_405_FAST_FAIL_MIN（默认 20）
LOG="$WORK/batch.log"

# 恰好达阈值（20 条）→ 洪泛
: > "$LOG"
for i in $(seq 1 20); do
  echo "ERROR : dir/file$i.mp4: Failed to copy: unchunked simple update failed: Method Not Allowed: 405 Method Not Allowed" >> "$LOG"
done
if _batch_405_flood "$LOG"; then ok "2a 恰好 20 条 405 → 判洪泛"; else bad "2a: 达阈值未触发"; fi

# 19 条（差一条）→ 非洪泛（阈值边界）
: > "$LOG"
for i in $(seq 1 19); do
  echo "ERROR : dir/file$i.mp4: Failed to copy: 405 Method Not Allowed" >> "$LOG"
done
if _batch_405_flood "$LOG"; then bad "2b: 19 条却触发（阈值边界错）"; else ok "2b 19 条 → 非洪泛（阈值边界正确）"; fi

# 自定义阈值生效
OPENLIST_405_FAST_FAIL_MIN=3
: > "$LOG"
for i in 1 2 3; do echo "ERROR : d/f$i: 405 Method Not Allowed" >> "$LOG"; done
if _batch_405_flood "$LOG"; then ok "2c 自定义阈值 3、3 条 → 洪泛"; else bad "2c: 自定义阈值未生效"; fi
: > "$LOG"
for i in 1 2; do echo "ERROR : d/f$i: 405 Method Not Allowed" >> "$LOG"; done
if _batch_405_flood "$LOG"; then bad "2d: 2 条却触发（自定义阈值边界）"; else ok "2d 自定义阈值 3、2 条 → 非洪泛"; fi
unset OPENLIST_405_FAST_FAIL_MIN

# 阈值=0 → 关闭判定
OPENLIST_405_FAST_FAIL_MIN=0
: > "$LOG"
for i in $(seq 1 100); do echo "405 Method Not Allowed" >> "$LOG"; done
if _batch_405_flood "$LOG"; then bad "2e: 阈值=0 却触发（应关闭判定）"; else ok "2e 阈值=0 → 关闭判定"; fi
unset OPENLIST_405_FAST_FAIL_MIN

# 反向锁死: 409/423（重试可自愈的竞争冲突）不得计入 405 洪泛
# 若有人把计数正则放宽到 "Conflict|409|423"，此断言立刻变红
: > "$LOG"
for i in $(seq 1 100); do
  echo "ERROR : dir/file$i.mp4: Failed to copy: Conflict: 409 Conflict: mkParentDir failed" >> "$LOG"
done
if _batch_405_flood "$LOG"; then bad "2f: 409 被误计为 405 洪泛（正则过宽）"; else ok "2f 409/423 不计入 405 洪泛（自愈形态不误杀）"; fi

# 空日志 / 不存在文件 → 非洪泛且不报错
: > "$LOG"
if _batch_405_flood "$LOG"; then bad "2g: 空日志却触发"; else ok "2g 空日志 → 非洪泛"; fi
if _batch_405_flood "$WORK/does_not_exist.log"; then bad "2h: 不存在文件却触发"; else ok "2h 不存在文件 → 非洪泛（不报错）"; fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
