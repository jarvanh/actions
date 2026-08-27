#!/bin/bash
# auto-split 分支穿透回归测试（run 32169924747 实锤的 bug）
# _sync_task_impl 的 5 个终态分支（auto-split 关闭/≤50GB/达最大深度/无子目录/
# 全部子目录被排除）调用 _sync_task_finalize 后缺少 return，导致:
#   1. ≤50GB 任务直同步后又落入"按子目录拆分"，递归拆到 depth=10
#   2. 同一目录被完整同步 2-4 遍（直同步 + 无子目录批次 + 全排除完整 + 最终完整）
#   3. "源端大小 0B 超过 50GB 阈值" 这类自相矛盾日志
# 本测试 mock rclone/sync_with_logging/sync_by_file_batches 等，统计各分支
# 的实际调用次数与穿透行为
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/tasks.sh" 2>/dev/null

# --- mocks（必须在 source 之后定义）---
SWL_CALLS=0; SWL_LOG=""
SBB_CALLS=0
SSM_CALLS=0   # save_sync_marker
SOSF_CALLS=0  # split_on_sync_failure
SWL_FAIL=0
sync_with_logging() {
  SWL_CALLS=$((SWL_CALLS+1))
  SWL_LOG+="sync: $1"$'\n'
  SYNC_FAILED=$SWL_FAIL
  SYNC_TRANSFERRED_BYTES=123
  return $SWL_FAIL
}
sync_by_file_batches() {
  SBB_CALLS=$((SBB_CALLS+1))
  SYNC_FAILED=0
  SYNC_TRANSFERRED_BYTES=456
  return 0
}
save_sync_marker() { SSM_CALLS=$((SSM_CALLS+1)); }
split_on_sync_failure() { SOSF_CALLS=$((SOSF_CALLS+1)); }
progress_update() { :; }
progress_update_force() { :; }
progress_scope_init() { :; }
send_sync_skipped() { :; }
send_sync_warning() { :; }

# rclone mock: size 按 path 映射（R_SIZE_<sfx>=bytes），lsf 返回 R_LSF 内容
# 注意用 printf 避免 echo 的换行混进变量名后缀
R_LSF=""
rclone() {
  case "$1" in
    size)
      local p="$2" v
      v=$(eval "echo \${R_SIZE_$(printf '%s' "$p" | tr -c 'a-zA-Z0-9' '_'):-}")
      [ -z "$v" ] && v=0
      echo "{\"bytes\":${v},\"count\":1}"
      ;;
    lsf) printf '%s' "$R_LSF" ;;
    *) return 0 ;;
  esac
}

run_impl() {  # run_impl <auto_split> <skip_days> <src> <dst> <task> [extra...]
  SWL_CALLS=0; SWL_LOG=""; SBB_CALLS=0; SSM_CALLS=0; SOSF_CALLS=0; SWL_FAIL=0
  SYNC_AUTO_SPLIT_DEPTH=0
  _TASK_AUTO_SPLIT=$1 _TASK_SKIP_DAYS=$2 _sync_task_impl "$3" "$4" "$5" "${@:6}"
}

OUT=$(mktemp)

# --- 场景1: 42GiB ≤ 50GB + auto-split 开 → 只直同步 1 次，绝不拆分 ---
R_SIZE_src=45000000000
run_impl 1 0 src dst t1 > "$OUT" 2>&1
[ "$SWL_CALLS" = "1" ] && ok "1a 42GiB 直同步恰好 1 次（实际 $SWL_CALLS）" || bad "1a: sync=${SWL_CALLS}"
[ "$SBB_CALLS" = "0" ] && ok "1b 未走文件批次拆分" || bad "1b: batch=${SBB_CALLS}"
grep -q "未超过 50GB 阈值" "$OUT" && ok "1c 走 ≤50GB 分支" || bad "1c: $(cat "$OUT")"
! grep -q "按子目录拆分同步" "$OUT" && ok "1d 未穿透到子目录拆分" || bad "1d: 穿透了"
! grep -q "最终完整同步" "$OUT" && ok "1e 未重复最终完整同步" || bad "1e: 重复完整同步"
[ "$SOSF_CALLS" = "1" ] && ok "1f 收尾切割检查恰好 1 次" || bad "1f: sosf=${SOSF_CALLS}"

# --- 场景2: 0B 空源 + auto-split 开 → 直同步 1 次（原 bug: 0B 也"超过阈值"）---
R_SIZE_src=0
run_impl 1 0 src dst t2 > "$OUT" 2>&1
[ "$SWL_CALLS" = "1" ] && ok "2a 0B 直同步恰好 1 次" || bad "2a: sync=${SWL_CALLS}"
! grep -q "按子目录拆分同步" "$OUT" && ok "2b 0B 不再被判定超过阈值" || bad "2b: $(grep 阈值 "$OUT")"

# --- 场景3: 60GB + auto-split 关 → 只直同步 1 次 ---
R_SIZE_src=60000000000
run_impl 0 0 src dst t3 > "$OUT" 2>&1
[ "$SWL_CALLS" = "1" ] && ok "3a auto-split 关闭时直同步恰好 1 次" || bad "3a: sync=${SWL_CALLS}"
! grep -q "按子目录拆分同步" "$OUT" && ok "3b 未拆分" || bad "3b: 穿透了"

# --- 场景4: 60GB + 两个子目录 + auto-split 开 → 子目录各 1 次 + 最终完整 1 次 ---
R_LSF=$'a/\nb/\n'
R_SIZE_src=60000000000; R_SIZE_src_a=1000; R_SIZE_src_b=2000
run_impl 1 0 src dst t4 > "$OUT" 2>&1
# 子目录 a、b 各直同步 1 次 + 顶层最终完整同步 1 次 = 3；孙目录不再递归
[ "$SWL_CALLS" = "3" ] && ok "4a 拆分路径: 子目录 2 次 + 最终完整 1 次 = 3（实际 $SWL_CALLS）" || bad "4a: sync=${SWL_CALLS}"
grep -q "按子目录拆分同步" "$OUT" && ok "4b 走拆分分支" || bad "4b: $(cat "$OUT")"
[ "$SBB_CALLS" = "0" ] && ok "4c 子目录未被批次拆分/递归拆分" || bad "4c: batch=${SBB_CALLS}"
echo "$SWL_LOG" | grep -cx "sync: src" | grep -q "^1$" && ok "4d 顶层最终完整同步恰好 1 次" || bad "4d: $(echo "$SWL_LOG" | grep -cx 'sync: src')"
grep -q "已达最大拆分深度" "$OUT" && bad "4e 不应达最大深度" || ok "4e 未触发最大深度兜底"

# --- 场景5: 60GB + 无子目录 → 批次拆分 1 次，不再追加完整同步 ---
R_LSF=""
run_impl 1 0 src dst t5 > "$OUT" 2>&1
[ "$SBB_CALLS" = "1" ] && ok "5a 无子目录走批次拆分恰好 1 次" || bad "5a: batch=${SBB_CALLS}"
[ "$SWL_CALLS" = "0" ] && ok "5b 批次拆分后未穿透追加完整同步" || bad "5b: sync=${SWL_CALLS}"

# --- 场景6: 60GB + 子目录全被排除 → 完整同步 1 次，不再追加 ---
R_LSF=$'notion/\n'
run_impl 1 0 src dst t6 --exclude 'notion/**' > "$OUT" 2>&1
grep -q "所有子目录均被排除" "$OUT" && ok "6a 走全排除分支" || bad "6a: $(cat "$OUT")"
[ "$SWL_CALLS" = "1" ] && ok "6b 全排除完整同步恰好 1 次" || bad "6b: sync=${SWL_CALLS}"
[ "$SBB_CALLS" = "0" ] && ok "6c 未批次拆分" || bad "6c: batch=${SBB_CALLS}"

# --- 场景7: 同步失败 → 恰好 1 次且返回码传播 ---
R_LSF=""; R_SIZE_src=1000; SWL_FAIL=1
SWL_CALLS=0; SWL_LOG=""; SBB_CALLS=0; SSM_CALLS=0; SOSF_CALLS=0
SYNC_AUTO_SPLIT_DEPTH=0
_TASK_AUTO_SPLIT=1 _TASK_SKIP_DAYS=0 _sync_task_impl src dst t7 > "$OUT" 2>&1
rc=$?
[ "$SWL_CALLS" = "1" ] && ok "7a 失败也只同步 1 次" || bad "7a: sync=${SWL_CALLS}"
[ "$rc" = "1" ] && ok "7b 返回码传播 rc=1" || bad "7b: rc=$rc"

# --- 场景8: 42GiB + 1d-skip → marker 恰好保存 1 次（原穿透会存 2+ 次）---
R_SIZE_src=45000000000; SWL_FAIL=0
run_impl 1 1 src dst t8 > "$OUT" 2>&1
[ "$SSM_CALLS" = "1" ] && ok "8a skip marker 恰好保存 1 次（实际 $SSM_CALLS）" || bad "8a: marker=${SSM_CALLS}"
[ "$SOSF_CALLS" = "0" ] && ok "8b skip 模式不走切割检查" || bad "8b: sosf=${SOSF_CALLS}"

rm -f "$OUT"
echo "=== 结果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = "0" ]
