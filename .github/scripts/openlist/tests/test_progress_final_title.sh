#!/usr/bin/env bash
# 收尾进度通知标题四态回归测试（run 撞 6h job 上限实录: 16 任务 / 13 待处理
#   / 1 进行中 / 1 完成 / 1 失败，标题却是"⚠️ 同步完成（有失败）"）
# 背景: 旧判定的 failed>0 分支排在 pending/running 之前，中断与"跑完但有
#   顽固失败"共用同一个 ⚠️ 标题，被中断的一轮看着像正常收尾。
# 契约（四态，按严重度从高到低，互斥）:
#   T1 有 pending/running          -> ⛔ 同步中断（无论是否有 failed，失败数并入标题）
#   T2 一个任务都没注册            -> ⛔ 同步中断（未注册任何任务）
#   T3 全部跑完、无失败、无修复    -> ✅ 同步全部完成
#   T4 全部跑完、无失败、有修复    -> ✅ 同步全部完成（N 个文件经修复同步）
#   T5 全部跑完、既有失败又有修复  -> ⚠️ 同步完成（N 个任务有文件无法同步）（失败优先）
#   T6 progress_add_fixed_files 跨轮次累加，progress_init 清零
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "✅ $1"
  else
    FAIL=$((FAIL + 1))
    echo "❌ $1 (期望 [$3] 实际 [$2])"
  fi
}

# ---------- 加载被测模块（部分 source: 只依赖 utils + telegram 排版助手）----------
source "$SCRIPT_DIR/../utils.sh"
source "$SCRIPT_DIR/../telegram.sh"
source "$SCRIPT_DIR/../sync_progress.sh"

# 状态文件重定向到临时目录（模块顶层写死 /tmp，source 后覆盖）
PROGRESS_TASKS_FILE="$WORK_DIR/tasks.tsv"
PROGRESS_START_FILE="$WORK_DIR/start"
PROGRESS_FINALIZED_FILE="$WORK_DIR/finalized"
PROGRESS_FIXED_FILE="$WORK_DIR/fixed"
PROGRESS_MSG_ID_FILE="$WORK_DIR/msgid"
PROGRESS_CURRENT_FILE="$WORK_DIR/current"
# 阶段槽位路径由 _progress_slot_rows 生成（/tmp 固定），finalized 态不读槽位，
# 但其清理由 progress_init 走 progress_scope_init，不在此处使用

# ---------- 场景装配 ----------
# 写入任务队列: <id> <显示名> <状态> [详情]
add_task() {
  local id="$1" name="$2" status="$3" detail="${4:--}"
  printf '%s\t%s\t%s\t%s\t-\n' "$id" "$name" "$status" "$detail" >> "$PROGRESS_TASKS_FILE"
}

reset_case() {
  : > "$PROGRESS_TASKS_FILE"
  : > "$PROGRESS_FIXED_FILE"
  echo "1" > "$PROGRESS_FINALIZED_FILE"
  echo "$(( $(date +%s) - 3600 ))" > "$PROGRESS_START_FILE"
}

# 渲染后取首行（tg_add_title 输出 "<b>标题</b>"）
title_of() { _progress_render | head -1; }
expect_title() { printf '<b>%s</b>' "$(escape_html "$1")"; }

# ---------- T1: 中断优先于失败（13 待处理 + 1 进行中 + 1 完成 + 1 失败）----------
reset_case
add_task t_done "onedrive:backup → aliyundriveCrypt/backup" completed
add_task t_fail "onedrive:backup → wopan176Crypt/backup" failed "部分文件无法同步"
add_task t_run "onedrive:0 → wopan176Crypt/0" running "同步中"
local_i=0
while [ "$local_i" -lt 13 ]; do
  local_i=$((local_i + 1))
  add_task "p${local_i}" "onedrive:$((local_i % 6)) → wopan175/$((local_i % 6))" pending
done
chk "T1 中断（含失败数）优先于失败态" "$(title_of)" \
  "$(expect_title '⛔ 同步中断（13 个待处理、1 个进行中未执行完、1 个失败）')"

# ---------- T2: 无进行中/待处理、无失败 -> 中断文案不带失败数 ----------
reset_case
add_task t_done "onedrive:backup → aliyundriveCrypt/backup" completed
add_task t_run "onedrive:0 → wopan176Crypt/0" running
add_task t_pend "onedrive:1 → wopan175/1" pending
chk "T2 中断无失败时不带失败数" "$(title_of)" \
  "$(expect_title '⛔ 同步中断（1 个待处理、1 个进行中未执行完）')"

# ---------- T3: 未注册任何任务 ----------
reset_case
chk "T3 未注册任务判中断" "$(title_of)" "$(expect_title '⛔ 同步中断（未注册任何任务）')"

# ---------- T4: 全部跑完、无失败、无修复 ----------
reset_case
add_task t1 "onedrive:backup → aliyundriveCrypt/backup" completed
add_task t2 "onedrive:1 → wopan175/1" skipped
chk "T4 完全完成" "$(title_of)" "$(expect_title '✅ 同步全部完成')"

# ---------- T5: 全部跑完、无失败、有修复 ----------
reset_case
add_task t1 "onedrive:backup → aliyundriveCrypt/backup" completed
progress_add_fixed_files 5
progress_add_fixed_files 2
chk "T5 带修复的完成（跨上报累加）" "$(title_of)" \
  "$(expect_title '✅ 同步全部完成（7 个文件经修复同步）')"

# ---------- T6: 全部跑完、既有失败又有修复 -> 失败优先 ----------
reset_case
add_task t1 "onedrive:backup → aliyundriveCrypt/backup" completed
add_task t2 "onedrive:backup → wopan176Crypt/backup" failed "部分文件无法同步"
add_task t3 "onedrive:3 → wopan175/3" failed "部分文件无法同步"
progress_add_fixed_files 3
chk "T6 失败优先于修复" "$(title_of)" \
  "$(expect_title '⚠️ 同步完成（2 个任务有文件无法同步）')"

# ---------- T7: 计数器健壮性 ----------
reset_case
progress_add_fixed_files 0
progress_add_fixed_files ""
progress_add_fixed_files "abc"
chk "T7 非法/零值上报不写入" "$(_progress_get_fixed_files)" "0"
progress_add_fixed_files 4
chk "T7 正常上报累加" "$(_progress_get_fixed_files)" "4"
echo "garbage" > "$PROGRESS_FIXED_FILE"
chk "T7 文件内容非法按 0 处理" "$(_progress_get_fixed_files)" "0"
progress_add_fixed_files 1
chk "T7 非法内容之上仍可累加" "$(_progress_get_fixed_files)" "1"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
