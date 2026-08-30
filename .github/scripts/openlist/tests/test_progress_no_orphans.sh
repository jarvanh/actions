#!/usr/bin/env bash
# 进度消息孤儿防护回归测试（2026-08-30 聊天里堆积多条「🔄 同步进度」实录）
# 根因: 刷新链「读 id → 删旧 → 发新 → 写回」非原子，且 rt 线程被 kill 于发送
#   中途 → 新消息已发出但 id 未写回追踪文件 → 无人删除 → 永久残留。
# 修复: ① rt 线程优雅停止（停止标志 + 退出标记，强杀仅兜底）
#       ② _progress_refresh 全程 flock 串行化
#       ③ 已发 id 记账 + progress_finalize 兜底清理孤儿
# 契约:
#   T1 顺序刷新不变式: 每个已发送 id，要么仍被追踪（最新一条），要么已被删除
#   T2 rt 线程优雅停止: 线程干净退出、状态文件清干净、期间刷新不产生孤儿
#   T3 id 记账: 每次 sendMessage 成功都追加进 PROGRESS_SENT_IDS_LOG
#   T4 并发刷新不变式（需 flock，macOS 无 flock 时跳过）: 并发 progress_reload 后仍无孤儿
#   T5 强杀兜底 + finalize 自愈: 卡死线程被强杀后产生孤儿（复现旧行为），
#      progress_finalize 的 _progress_cleanup_orphan_ids 必须清掉它，终态消息保留
# 运行: bash tests/test_progress_no_orphans.sh（需 bash 4+，脚本用 declare -A）
set -u
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

# ---------- 假 Telegram API（fakebin/curl + fakebin/jq）----------
mkdir -p fakebin
cat > fakebin/curl <<'EOF'
#!/usr/bin/env bash
# 假 Telegram API: 记录调用并返回合法 JSON。
# sendMessage 先记账再等待（FAKE_SLOW_SEND 存在时睡眠），模拟「请求已被服务端
# 处理、响应未返回」的窗口 —— 在此窗口强杀线程即产生孤儿。
case "$*" in
  *deleteMessage*)
    _mid=""
    for _a in "$@"; do case "$_a" in message_id=*) _mid="${_a#message_id=}";; esac; done
    echo "del ${_mid:-unknown}" >> "$FAKE_TG_LOG"
    echo '{"ok":true}' ;;
  *sendMessage*)
    _n=$(( $(cat "$FAKE_TG_IDF" 2>/dev/null || echo 100) + 1 ))
    echo "$_n" > "$FAKE_TG_IDF"
    echo "send $_n" >> "$FAKE_TG_LOG"
    [ -n "${FAKE_SLOW_SEND:-}" ] && sleep "$FAKE_SLOW_SEND"
    printf '{"ok":true,"result":{"message_id":%s}}' "$_n" ;;
  *)
    echo "other" >> "$FAKE_TG_LOG"
    echo '{"ok":true}' ;;
esac
EOF
cat > fakebin/jq <<'EOF'
#!/usr/bin/env bash
# 最小 jq shim: 只支撑 telegram.sh 用到的 '.result.message_id // empty'。
# 注意 jq 语法是 `jq -r 'FILTER'`，过滤器在第 2 个参数，因此匹配 "$*" 而非 "$1"
_input=$(cat)
case "$*" in
  *message_id*) printf '%s\n' "$_input" | sed -n 's/.*"message_id":\([0-9][0-9]*\).*/\1/p' ;;
esac
EOF
chmod +x fakebin/curl fakebin/jq

export FAKE_TG_LOG="$WORK_DIR/tg_calls.log"
export FAKE_TG_IDF="$WORK_DIR/tg_next_id"
echo 100 > "$FAKE_TG_IDF"
: > "$FAKE_TG_LOG"
export PATH="$WORK_DIR/fakebin:$PATH"
export TELEGRAM_BOT_TOKEN=fake-token
export TELEGRAM_CHAT_ID=fake-chat

# ---------- 加载被测模块（与 test_progress_final_title 同款部分 source）----------
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
PROGRESS_LAST_UPDATE_FILE="$WORK_DIR/last_update"
PROGRESS_BATCH_HISTORY_FILE="$WORK_DIR/batch_history"
PROGRESS_SENT_IDS_LOG="$WORK_DIR/sent_ids"
PROGRESS_RT_PID_FILE="$WORK_DIR/rt_pid"
PROGRESS_RT_STOP_FILE="$WORK_DIR/rt_stop"
PROGRESS_RT_EXIT_FILE="$WORK_DIR/rt_exit"
PROGRESS_LOCK_FILE="$WORK_DIR/refresh.lock"

# 装配一个 running 任务（绕开 progress_task_begin 的 grep -qP，BSD grep 无 -P）
setup_task() {
  progress_register_task t1 "onedrive:0 → wopan176Crypt/0"
  echo t1 > "$PROGRESS_CURRENT_FILE"
  _progress_set_task_status t1 running
}

# 无孤儿不变式（服务端视角）: 每个已发送 id，要么仍被追踪，要么出现在删除清单里
no_orphans() {
  local tracked dels sid
  tracked=$(cat "$PROGRESS_MSG_ID_FILE" 2>/dev/null || true)
  dels=$(grep '^del ' "$FAKE_TG_LOG" 2>/dev/null | awk '{print $2}')
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    [ "$sid" = "$tracked" ] && continue
    printf '%s\n' "$dels" | grep -qx "$sid" || { echo "  孤儿: send $sid 未删除 (tracked=$tracked)"; return 1; }
  done < <(grep '^send ' "$FAKE_TG_LOG" 2>/dev/null | awk '{print $2}')
  return 0
}
# 无已知孤儿（脚本视角）: 记账清单里每个 id 都已删除或仍被追踪。
# 「服务端已处理但响应未返回」的不可知 id（强杀落在发送窗口内）不在脚本
# 认知内，只能靠优雅停止预防，不在本不变式内
no_known_orphans() {
  local tracked sid
  tracked=$(cat "$PROGRESS_MSG_ID_FILE" 2>/dev/null || true)
  [ -s "$PROGRESS_SENT_IDS_LOG" ] || return 0
  while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    [ "$sid" = "$tracked" ] && continue
    grep '^del ' "$FAKE_TG_LOG" 2>/dev/null | awk '{print $2}' | grep -qx "$sid" || { echo "  已知孤儿: $sid"; return 1; }
  done < "$PROGRESS_SENT_IDS_LOG"
  return 0
}
invariant() { no_orphans >/dev/null 2>&1 && echo "无孤儿" || echo "有孤儿"; }
sends() { grep -c '^send ' "$FAKE_TG_LOG" 2>/dev/null || true; }
dels_for() { grep '^del ' "$FAKE_TG_LOG" 2>/dev/null | awk '{print $2}' | grep -cx "$1" || true; }

# ---------- T1: 顺序刷新不变式 ----------
progress_init
setup_task
progress_reload
progress_reload
progress_reload
chk "T1 顺序刷新后无孤儿" "$(invariant)" "无孤儿"
chk "T1 追踪指向最后一次发送" "$(cat "$PROGRESS_MSG_ID_FILE")" "$(grep '^send ' "$FAKE_TG_LOG" | awk '{print $2}' | tail -1)"

# ---------- T2: rt 线程优雅停止 ----------
printf 'Transferred: 1.500 MiB / 10.000 MiB, ETA 5s\n' > "$WORK_DIR/batch.log"
PROGRESS_RT_INTERVAL=1
_start_batch_progress_thread "$WORK_DIR/batch.log"
_rt_pid=$(cat "$PROGRESS_RT_PID_FILE")
sleep 3
_sends_rt=$(sends)
chk "T2 rt 线程期间确实刷新过（发送数 >3）" "$([ "$_sends_rt" -gt 3 ] && echo 是 || echo 否)" "是"
_stop_batch_progress_thread
chk "T2 线程已退出" "$(kill -0 "$_rt_pid" 2>/dev/null && echo 活着 || echo 已退出)" "已退出"
chk "T2 pid 文件已清理" "$([ -f "$PROGRESS_RT_PID_FILE" ] && echo 残留 || echo 已清)" "已清"
chk "T2 停止标志已清理" "$([ -f "$PROGRESS_RT_STOP_FILE" ] && echo 残留 || echo 已清)" "已清"
chk "T2 退出标记已清理" "$([ -f "$PROGRESS_RT_EXIT_FILE" ] && echo 残留 || echo 已清)" "已清"
chk "T2 rt 线程全程无孤儿" "$(invariant)" "无孤儿"

# ---------- T3: 已发 id 记账 ----------
_send_n=$(sends)
_log_n=$(wc -l < "$PROGRESS_SENT_IDS_LOG" | tr -d ' ')
chk "T3 记账条数 = 发送条数" "$_log_n" "$_send_n"

# ---------- T4: 并发刷新不变式（需 flock）----------
if command -v flock >/dev/null 2>&1; then
  progress_init
  setup_task
  : > "$FAKE_TG_LOG"
  echo 200 > "$FAKE_TG_IDF"
  for _i in 1 2 3 4 5 6 7 8; do progress_reload & done
  wait
  chk "T4 8 路并发刷新后无孤儿" "$(invariant)" "无孤儿"
  chk "T4 并发后追踪唯一" "$(sort -un "$PROGRESS_SENT_IDS_LOG" | wc -l | tr -d ' ')" "$(sends)"
else
  echo "⏭️ T4 跳过（本机无 flock；ubuntu runner 上正常执行）"
fi

# ---------- T5: 强杀兜底 + finalize 自愈 ----------
progress_init
setup_task
progress_reload
printf 'Transferred: 2.000 MiB / 10.000 MiB, ETA 4s\n' > "$WORK_DIR/batch2.log"
# 慢发送: 模拟请求已被服务端处理、响应未返回的窗口
FAKE_SLOW_SEND=30 _start_batch_progress_thread "$WORK_DIR/batch2.log" && unset FAKE_SLOW_SEND
_rt_pid=$(cat "$PROGRESS_RT_PID_FILE")
sleep 3
_stop_start=$(date +%s)
_stop_batch_progress_thread
_stop_cost=$(( $(date +%s) - _stop_start ))
chk "T5 卡死线程被兜底强杀" "$(kill -0 "$_rt_pid" 2>/dev/null && echo 活着 || echo 已退出)" "已退出"
chk "T5 强杀路径有超时上限（<15s）" "$([ "$_stop_cost" -lt 15 ] && echo 是 || echo 否)" "是"
chk "T5 强杀后服务端视角存在孤儿（复现不可知 id 场景）" "$(invariant)" "有孤儿"
# 注入合成已知孤儿（模拟路径 B/C: 消息已发出、已记账、但从未被删除）
echo "send 999" >> "$FAKE_TG_LOG"
echo 999 >> "$PROGRESS_SENT_IDS_LOG"
# 收尾自愈: 任务正常完结后 finalize 刷新终态 + 清理全部已知孤儿
_progress_set_task_status t1 completed
progress_finalize
chk "T5 finalize 自愈后无已知孤儿（999 被清理）" "$(no_known_orphans >/dev/null 2>&1 && echo 无孤儿 || echo 有孤儿)" "无孤儿"
chk "T5 终态消息未被误删" "$(dels_for "$(cat "$PROGRESS_MSG_ID_FILE")")" "0"
chk "T5 终态标题为完成" "$(_progress_render | head -1 | grep -c '同步全部完成' || true)" "1"
chk "T5 记账清单已清空" "$(wc -l < "$PROGRESS_SENT_IDS_LOG" | tr -d ' ')" "0"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
