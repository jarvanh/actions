#!/bin/bash
# FORCE_SYNC_TASK 单任务强制同步的匹配口径回归测试
# 背景（2026-10-07 新增能力）:
#   force_sync=true 是**全量**开关，会放行本轮全部同步对。源端缩小告警往往只涉及
#   一个同步对，为它放行全部会白跑其余十几对（每对都要走 marker 检查 + size 列举）。
#   故引入 FORCE_SYNC_TASK: 按「任务键」精准点名，只放行被点名的同步对。
#
# 本测试锁死三件事（改动匹配逻辑时必须同步更新）:
#   1. 任务键口径 = <task_name>_<目标端首段>，与 task_engine.sh 的 _derive_task_id
#      同算法（那边用于进度跟踪槽位）。两份实现因分层无法复用（本文件 L3、
#      task_engine L6，反向依赖不可用），改一处必须改两处。
#   2. 精确匹配，不做前缀/子串匹配 —— task0_wopan176 不得放行 task0_wopan176Crypt。
#      这不是洁癖: 后端名 wopan175 / wopan176 互为前缀关系，子串匹配会张冠李戴，
#      把"放行 wopan175"变成"连 wopan176Crypt 一起放行"。
#   3. 与 FORCE_SYNC=true 的优先级: 全量优先，两者同时给时行为等同全量。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
rclone() { return 0; }

FORCE_SYNC="false"
FORCE_SYNC_TASK=""

# 匹配断言: chk <期望 0=放行/1=不放行> <描述> <task_name> <dest_path>
chk() {
  local want="$1" desc="$2"
  _force_sync_matches "$3" "$4"; local got=$?
  if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (want=$want got=$got)"; fi
}

echo "=== A. 任务键口径 ==="
[ "$(_sync_task_key task0 'openlist:wopan176Crypt/0')" = "task0_wopan176Crypt" ] \
  && ok "A1 task0 + wopan176Crypt/0 → task0_wopan176Crypt" \
  || bad "A1: $(_sync_task_key task0 'openlist:wopan176Crypt/0')"
[ "$(_sync_task_key task0 'openlist:wopan175/0')" = "task0_wopan175" ] \
  && ok "A2 同 task_name 不同后端 → 不同键" \
  || bad "A2: $(_sync_task_key task0 'openlist:wopan175/0')"
[ "$(_sync_task_key backup 'openlist:aliyundriveCrypt/backup')" = "backup_aliyundriveCrypt" ] \
  && ok "A3 backup + aliyundriveCrypt → backup_aliyundriveCrypt" \
  || bad "A3: $(_sync_task_key backup 'openlist:aliyundriveCrypt/backup')"
[ "$(_sync_task_key task0 'dest')" = "task0_dest" ] \
  && ok "A4 无冒号无斜杠路径的兜底" \
  || bad "A4: $(_sync_task_key task0 'dest')"

echo "=== B. 精确匹配（不做前缀/子串）==="
FORCE_SYNC_TASK="task0_wopan176Crypt"
chk 0 "B1 命中本任务" task0 'openlist:wopan176Crypt/0'
chk 1 "B2 同 task_name 不同后端不误放行" task0 'openlist:wopan175/0'
chk 1 "B3 不同任务不误放行" task5 'openlist:wopan176Crypt/5'
FORCE_SYNC_TASK="task0_wopan176"
chk 1 "B4 前缀不得误匹配（wopan176 vs wopan176Crypt）" task0 'openlist:wopan176Crypt/0'
FORCE_SYNC_TASK="wopan176Crypt"
chk 1 "B5 无 task_name 前缀不得误匹配" task0 'openlist:wopan176Crypt/0'

echo "=== C. 多选与分隔符 ==="
FORCE_SYNC_TASK="task0_wopan176Crypt, task2_wopan175"
chk 0 "C1 逗号+空格分隔 · 第二项" task2 'openlist:wopan175/2'
chk 0 "C2 逗号+空格分隔 · 第一项" task0 'openlist:wopan176Crypt/0'
FORCE_SYNC_TASK="task0_wopan176Crypt,task2_wopan175"
chk 0 "C3 纯逗号分隔" task2 'openlist:wopan175/2'
chk 1 "C4 多选下未点名任务仍不放行" task3 'openlist:wopan176Crypt/3'

echo "=== D. 空值与优先级 ==="
FORCE_SYNC_TASK=""
chk 1 "D1 留空 = 不按任务强制" task0 'openlist:wopan176Crypt/0'
FORCE_SYNC="true"; FORCE_SYNC_TASK=""
chk 0 "D2 全量强制仍生效" task5 'openlist:wopan175/5'
FORCE_SYNC="true"; FORCE_SYNC_TASK="task0_wopan176Crypt"
chk 0 "D3 全量优先（点名之外的任务也放行）" task5 'openlist:wopan175/5'
FORCE_SYNC="false"; FORCE_SYNC_TASK=""

echo
echo "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
