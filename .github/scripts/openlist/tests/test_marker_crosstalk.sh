#!/bin/bash
# ⚠️ marker 串写回归测试（2026-09-20，用户「源端一直没移动过」驱动的实锤 bug）
#
# 真机形态（run 35516272044 marker 原文探针）:
#   同属 onedrive:1/1024j/套图/网易摄影/蓝白碗/ 的 19 条修复记录，被写进了
#   4 个**不同目录**的 marker（neko / 布丁丁姬 / 网易摄影 / 萝莉），且
#   4 个 marker 里的 19 条**逐字节完全相同**。而三个故障目录的源端 top_dirs
#   里**根本没有 `蓝白碗`** —— 这批文件从来不属于它们。
#
# 根因: auto-split **串行**子目录循环（_sync_task_impl）递归进每个子目录时，
#   修复累计器 GLOBAL_FIXED_FILES_JSON **没有按子目录边界重置**（它只在
#   current_depth=0 时初始化一次；子目录递归是 depth≥1 ⇒ 不重置）。
#   于是子目录 A 修完的条目残留下来，被子目录 B 的 save_sync_marker /
#   save_fix_state_marker 写进 B 的 marker。
#   对照: **并行** worker（_sync_subdirs_parallel_run）在 939 行显式
#   `GLOBAL_FIXED_FILES_JSON='[]'` 重置过 —— 这个不对称就是串写只在串行
#   路径出现的原因。
#
# 后果（比"多了几条脏记录"严重得多）:
#   串写进来的 original 指向**别处的文件**，一键还原按它会把 A 的备份搬到
#   B 的名下 —— 短哈希不可逆（md5 前 8 位），搬错就再也回不去。
#
# 本测试锁: 子目录 A 的修复条目**绝不能**出现在子目录 B 的 marker 里。
set -u
# 本测试验的是**串行**子目录循环 ⇒ 必须显式关掉并行（默认值一改断言就全错位，
# 与 test_autosplit_fallthrough.sh 同款取舍）
OPENLIST_SUBDIR_PARALLEL=1
OPENLIST_PAIR_PARALLEL=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

# --- mocks（必须在 source 之后定义）---
# 每个子目录"修好"的文件: 由 SUBDIR_FIX 按子目录名给出（相对路径）
declare -A SUBDIR_FIX=()
SSM_LOG=""      # save_sync_marker 的 (task|fixed_json) 记录
FSM_LOG=""      # save_fix_state_marker 的同款记录

sync_with_logging() {
  SYNC_FAILED=0
  SYNC_TRANSFERRED_BYTES=1
  # 模拟"本子目录修复了它自己的文件": 只有属于当前 dest 的才该被记
  local d="$2" fx="${SUBDIR_FIX[$2]:-}"
  if [ -n "$fx" ]; then
    GLOBAL_FIXED_FILES_JSON=$(printf '%s' "$fx" | jq -Rsc 'split("\n") | map(select(length>0))
      | map({original: ., alternative: ("6c73a635/" + (. | split("/")[-1])), method: "rclone copyto（短哈希目录 6c73a635 + 原文件名）", size_bytes: 1})' 2>/dev/null || echo '[]')
  fi
  return 0
}
sync_by_file_batches() { SYNC_FAILED=0; SYNC_FAILED_BATCH=0; SYNC_TRANSFERRED_BYTES=1; return 0; }
# 记 **dest_path**（$2）而不是 task_name: task_name 是 md5 派生名，按它匹配
# 子目录名既脆弱又不直观；dest_path 才是"这条记录归哪个目录"的真正标识
save_sync_marker() {
  SSM_LOG+="$2|${GLOBAL_FIXED_FILES_JSON:-[]}"$'\n'
}
save_fix_state_marker() {
  FSM_LOG+="$2|${GLOBAL_FIXED_FILES_JSON:-[]}"$'\n'
}
split_on_sync_failure() { :; }
progress_update() { :; }
progress_update_force() { :; }
progress_scope_init() { :; }
send_sync_skipped() { :; }
send_sync_warning() { :; }
_send_sync_result_notification() { :; }
# 依赖桩（不在本测试关注范围内，缺了会让 _sync_task_impl 早期就报错退出）
check_sync_marker() { MARKER_ACTION="proceed"; }
trend_record_transferred() { :; }
_extract_filter_args() { FILTER_ARGS=(); }

R_LSF=""
rclone() {
  case "$1" in
    size)
      local p="$2" v
      v=$(eval "echo \${R_SIZE_$(printf '%s' "$p" | tr -c 'a-zA-Z0-9' '_'):-}")
      [ -z "$v" ] && v=0
      echo "{\"bytes\":${v},\"count\":1}"
      ;;
    lsf)
      # ⚠️ 路径不一定在 $2: 生产调用是 `rclone lsf --dirs-only <path>`（flag 在前），
      #   按 $2 取会拿到 "--dirs-only" ⇒ 子目录永远列不出来 ⇒ 测试假绿。
      #   故取**最后一个非 flag 参数**作路径。
      local p=""
      for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; donelsf)
      # ⚠️ 路径不一定在 $2: 生产调用是 `rclone lsf --dirs-only <path>`（flag 在前），
      #   按 $2 取会拿到 "--dirs-only" ⇒ 子目录永远列不出来 ⇒ 测试**假绿**。
      #   故取**最后一个非 flag 参数**作路径。
      local p=""
      for a in "$@"; do case "$a" in -*) ;; *) p="$a" ;; esac; done
      # 顶层返回子目录列表；非顶层（子目录内部）返回空 ⇒ 视为叶子，不再深拆
      [ "$p" = "src" ] && printf '%s' "$R_LSF"
      ;;
    *) return 0 ;;
  esac
}

run_impl() {
  SSM_LOG=""; FSM_LOG=""
  GLOBAL_FIXED_FILES_JSON="[]"; GLOBAL_FIX_BLACKLIST_JSON="{}"
  SYNC_AUTO_SPLIT_DEPTH=0
  _TASK_AUTO_SPLIT=1 _TASK_SKIP_DAYS=1 _sync_task_impl "$1" "$2" "$3"
}

OUT=$(mktemp)

# --- 场景1（核心）: 两个子目录，只有 A 有修复 ⇒ B 的 marker 里绝不能出现 A 的条目 ---
# 复刻真机: 网易摄影(源端有蓝白碗) 先同步并修好 19 条，随后 neko 同步。
# neko 源端没有蓝白碗 ⇒ 它自己一条都没修 ⇒ 它的 marker 不该有任何 fixed_files。
R_LSF=$'wangyi\nneko\n'
R_SIZE_src=60000000000; R_SIZE_src_wangyi=1000; R_SIZE_src_neko=2000
SUBDIR_FIX[src/wangyi]=$'蓝白碗/1.jpg\n蓝白碗/2.jpg'
SUBDIR_FIX[src/neko]=""
run_impl src dst task1 > "$OUT" 2>&1

# 子目录递归收尾走的是 save_sync_marker（task_engine.sh 递归分支），
# save_fix_state_marker 只在 sync_task（任务级）里调 —— 两个都记，断言以 SSM 为准
NEKO_FIX=$(printf '%s' "$SSM_LOG" | awk -F'|' '$1 ~ /neko$/ {print $2}' | head -1)
WANGYI_FIX=$(printf '%s' "$SSM_LOG" | awk -F'|' '$1 ~ /wangyi$/ {print $2}' | head -1)
[ -n "$SSM_LOG" ] && ok "0 子目录各自写了自己的 marker（SSM 有调用）" \
  || bad "0 SSM 未被调用 —— 桩没接通，后面全是假绿/假红（FSM=$FSM_LOG）"

[ -n "$WANGYI_FIX" ] && ok "1a 子目录 wangyi 的 marker 拿到自己的修复记录" \
  || bad "1a wangyi 应有修复记录（FSM_LOG=$(printf '%s' "$FSM_LOG" | head -3)）"
printf '%s' "$WANGYI_FIX" | grep -q '蓝白碗/1.jpg' \
  && ok "1b wangyi 的 marker 含它自己的 蓝白碗/1.jpg" || bad "1b: $WANGYI_FIX"
# ★ 判决性断言: neko 自己没修任何东西 ⇒ 它的 marker 里不得有 wangyi 的条目
if [ -z "$NEKO_FIX" ] || [ "$NEKO_FIX" = "[]" ]; then
  ok "1c ⚠️ neko 的 marker 不含任何修复记录（无串写）"
else
  bad "1c ⚠️ 串写: neko 的 marker 里出现了别处的修复记录 ⇒ $NEKO_FIX"
fi
! printf '%s' "$NEKO_FIX" | grep -q '蓝白碗' \
  && ok "1d neko 的 marker 里绝无 蓝白碗（它源端没有这个目录）" \
  || bad "1d 串写了 蓝白碗 进 neko: $NEKO_FIX"

# --- 场景2: 两个子目录**各有**自己的修复 ⇒ 互不混入 ---
SUBDIR_FIX[src/wangyi]=$'蓝白碗/1.jpg'
SUBDIR_FIX[src/neko]=$'neko普通/9.jpg'
run_impl src dst task2 > "$OUT" 2>&1
NEKO_FIX2=$(printf '%s' "$SSM_LOG" | awk -F'|' '$1 ~ /neko$/ {print $2}' | head -1)
printf '%s' "$NEKO_FIX2" | grep -q 'neko普通/9.jpg' \
  && ok "2a neko 的 marker 含它自己的 neko普通/9.jpg" || bad "2a: $NEKO_FIX2"
! printf '%s' "$NEKO_FIX2" | grep -q '蓝白碗' \
  && ok "2b neko 的 marker 不含 wangyi 的 蓝白碗（子目录边界生效）" \
  || bad "2b 串写: $NEKO_FIX2"

# --- 场景3: 顺序反转（wangyi 后跑）⇒ 同样不得串写（证明与顺序无关）---
R_LSF=$'neko\nwangyi\n'
SUBDIR_FIX[src/wangyi]=$'蓝白碗/1.jpg'
SUBDIR_FIX[src/neko]=""
run_impl src dst task3 > "$OUT" 2>&1
# 子目录按大小排序（neko 2000 > wangyi 1000）⇒ neko 先跑，wangyi 后跑
NEKO_FIX3=$(printf '%s' "$SSM_LOG" | awk -F'|' '$1 ~ /neko$/ {print $2}' | head -1)
if [ -z "$NEKO_FIX3" ] || [ "$NEKO_FIX3" = "[]" ]; then
  ok "3a 先跑的 neko（自己无修复）marker 干净" || bad "3a"
else
  bad "3a 先跑的 neko 被串写: $NEKO_FIX3"
fi
! printf '%s' "$NEKO_FIX3" | grep -q '蓝白碗' \
  && ok "3b neko 的 marker 不含 蓝白碗（与顺序无关）" || bad "3b 串写: $NEKO_FIX3"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
