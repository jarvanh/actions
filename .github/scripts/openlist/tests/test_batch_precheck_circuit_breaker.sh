#!/usr/bin/env bash
# 批次级三层预检熔断回归测试（对应 task_engine.sh 批次循环的熔断分支）
# 背景: sync_with_logging 的入口预检覆盖不到 sync_by_file_batches 批次循环内的
#   rclone copy --files-from。登录失效后端（openlist 服务端缓存掩盖驱动死活）
#   会把第一个大批次（≤50GB）全额烧完才由 _batch_consolidate 行为启发式止损。
# 批次熔断把拦截前移到每个批次传输之前（与 run_rclone_sync_once 二次预检同构）。
# 场景:
#   G1 openlist 目标 + 首批预检失败 -> 0 个 copy, 全部批次计失败, return 1,
#      SYNC_FAILED=1（run 33048121562 回归: 只 return 1 不置标志会被 progress_task_done
#      与轮转游标双双误判为成功）
#   G2 openlist 目标 + 第 2 批预检失败 -> 只有第 1 批 copy, ✅1❌2, SYNC_FAILED=1
#   G3 openlist 目标 + 预检全通过 -> 3 批照常 + 每批一次预检 + 最终 sync_with_logging
#   G4 非 openlist 目标 -> 预检零调用
#   G5 openlist 目标 + 批次传输真失败（exit≠4）-> 最终同步照跑, 尾部归并 SYNC_FAILED=1
#   G6 批次循环预算闸（2026-09-15）: 剩余预算不足一个批次工作片 -> 零批次传输,
#      SYNC_TIME_EXHAUSTED=1, return 0（优雅收摊；近几轮 330min 硬杀的直接根因）
#   G7 在途批次的硬上限（2026-09-15）: 每批 copy 都套上"预算剩余 − 尾部预留"的 timeout
#   G8/G8b 批次字节并入趋势口径（F9 最小修复，2026-09-15）: 3 批 × 1.5MiB → 4718592；
#      解析不到字节 → 记 0（不凭空造数）
#   G6 批次循环预算闸: 剩余预算不足一个批次工作片 -> 零批次传输, SYNC_TIME_EXHAUSTED=1,
#      return 0（优雅收摊；近几轮 330min 硬杀的直接根因）
set -euo pipefail
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

# ---------- 抽取被测函数 ----------
# sed 单函数抽取而非 source 整个 task_engine.sh: 保持与 utils/sync/marker 等模块零耦合，
# 全部协作者用显式 stub 替代，行为断言不受无关改动影响
sed -n '/^sync_by_file_batches()/,/^}/p' "$SCRIPT_DIR/../task_engine.sh" > extracted.sh
echo "被测函数抽取: $(wc -l < extracted.sh) 行"
source extracted.sh

# ---------- 协作者 stub ----------
DEFAULT_SPLIT_THRESHOLD_BYTES=$((50 * 1024 * 1024 * 1024))
SYNC_SPLIT_THRESHOLD_BYTES=100
OPENLIST_BATCH_BYTES=100
_TASK_SKIP_DAYS=0
PROGRESS_STATS=""
PROGRESS_PHASE_INFO=""
AUTO_SPLIT_INFO=""
SYNC_FAILED=0

progress_update() { :; }
progress_update_force() { :; }
format_bytes() { echo "${1}B"; }
tree_lines() { cat; }
check_sync_marker() { :; }
send_sync_skipped() { :; }
send_sync_warning() { :; }
# 排版助手 stub（与 telegram/tg_notify.sh 同语义——AUTO_SPLIT_INFO 经其构建）
escape_html() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; echo "$s"; }
tg_append() { printf -v "$1" '%s%s' "${!1}" "$2"; }
tg_add_section() { tg_append "$1" $'\n'"$(escape_html "$2")"$'\n'; }
tg_add_kv() { tg_append "$1" "$2：$(escape_html "$3")"$'\n'; }
tg_add_block() { tg_append "$1" "$2"; case "$2" in *$'\n') ;; *) tg_append "$1" $'\n' ;; esac; }
# 进度面板统计行定义在 task_engine.sh（本测试按 sed 行号抽取，不含它）；
# 与批次熔断断言无关，补 stub 以消除 "command not found" 噪音
# （门禁：测试日志不得出现 command not found，否则会掩盖真实的未定义函数）
_render_batch_stats_line() { echo "批次统计"; }
# tg_add_entry_text（失败批次条目）: 真源在 telegram/tg_notify.sh，本测试不 source
tg_add_entry_text() {
  local v="$1"; shift
  tg_append "$v" "├─$(escape_html "$1")"$'\n'
}
# 批次循环预算闸: 真身在 task_engine.sh 顶层（sed 单函数抽取不含它）。
# 默认返回 1（不闸，保持既有场景行为），G6 用 BATCH_BUDGET_STOP_RC=0 置"预算将尽"
_batch_budget_stop() { return "${BATCH_BUDGET_STOP_RC:-1}"; }
# 在途传输硬上限: 默认空串 = 不套 timeout 包装（与未设预算锚点的生产行为一致），
# G7 用 BUDGET_SLICE_OVERRIDE 给出秒数，验证包装确实生效
_budget_slice_seconds() { echo "${BUDGET_SLICE_OVERRIDE:-}"; }

SYNC_WITH_LOGGING_CALLS=0
sync_with_logging() { SYNC_WITH_LOGGING_CALLS=$((SYNC_WITH_LOGGING_CALLS + 1)); }

REFRESH_CALLS=0
_refresh_ol_drivers() { REFRESH_CALLS=$((REFRESH_CALLS + 1)); return 0; }
# 批次历史/实时线程（progress 增强）stub
_progress_batch_history_clear() { :; }
_progress_batch_history_add() { :; }
_start_batch_progress_thread() { :; }
_stop_batch_progress_thread() { :; }
START_TR_CALLS=0
_start_token_refresher() { START_TR_CALLS=$((START_TR_CALLS + 1)); }
STOP_TR_CALLS=0
_stop_token_refresher() { STOP_TR_CALLS=$((STOP_TR_CALLS + 1)); }
CONSOLIDATE_CALLS=0
_batch_consolidate() { CONSOLIDATE_CALLS=$((CONSOLIDATE_CALLS + 1)); }
BATCH_BACKEND_DEAD=0

CHECK_CALLS=0
# OVERRIDE 必须在函数体内读取——顶层求值会被固化，场景中途修改就不会生效
_check_openlist_backend_connectivity() {
  CHECK_CALLS=$((CHECK_CALLS + 1))
  [ "$CHECK_CALLS" -ge "${CHECK_FAIL_FROM_OVERRIDE:-99999}" ] && return 1
  return 0
}

# rclone 在管道左侧以子 shell 运行，子 shell 内的变量自增对父 shell
# 不可见——传输计数落盘到文件做跨进程累计
RCLONE_COPY_CALLS_FILE="copy_calls.count"
rclone() {
  case "$1" in
    lsjson)
      # 与真实 rclone 一致: 输出一个 JSON 对象数组（60+60+40+40=200B，
      # 配合阈值 100 拆成 3 批: [60][60+40=100? 否 ->60][...]
      printf '%s\n' '[
        {"name":"a","size":60,"path":"f_a.bin"},
        {"name":"b","size":60,"path":"f_b.bin"},
        {"name":"c","size":40,"path":"f_c.bin"},
        {"name":"d","size":40,"path":"f_d.bin"}
      ]'
      ;;
    lsf) : ;;
    copy)
      echo copy >> "$RCLONE_COPY_CALLS_FILE"
      # G5 用: 非 0 非 4 的真失败码（如 exit 2 整批失败）
      [ "${COPY_FAIL_RC_OVERRIDE:-0}" -ne 0 ] && return "$COPY_FAIL_RC_OVERRIDE"
      return 0
      ;;
    *) return 0 ;;
  esac
}

copy_count() {
  [ -f "$RCLONE_COPY_CALLS_FILE" ] && wc -l < "$RCLONE_COPY_CALLS_FILE" | tr -d ' ' || echo 0
}

# 批次字节解析（真源 utils.sh get_transferred_bytes_from_log，本测试不 source 它）:
# 直接给固定值，让「每批累加 → 并入 SYNC_TRANSFERRED_BYTES」这条链路可断言 ——
# 解析本身的正确性属 utils.sh 的职责，不在这里重复测。
BYTES_PER_BATCH=0
get_transferred_bytes_from_log() { echo "${BYTES_PER_BATCH:-0}"; }

clean_batch_dirs() { rm -rf /tmp/file_batches_t_* || true; }
prepare_case() {
  CHECK_CALLS=0
  SYNC_WITH_LOGGING_CALLS=0
  REFRESH_CALLS=0
  START_TR_CALLS=0
  STOP_TR_CALLS=0
  CONSOLIDATE_CALLS=0
  AUTO_SPLIT_INFO=""
  # 预算耗尽是跨批次持久位（G6 会置 1），不清会污染后续场景（G7 直接零批次）
  SYNC_TIME_EXHAUSTED=0
  rm -f "$RCLONE_COPY_CALLS_FILE"
  clean_batch_dirs
}
# 必须复刻生产调用形态 (task_engine.sh run_all_tasks `_run_registry_entry || true`):
# || 列表豁免随动态调用链穿透，函数体内批次循环的 set ±e 重开不会击穿进程；
# 若改用 set +e 手工保护，errexit 判定取 "return 完成时刻" 的 options 状态 ->
# 第一个经历过传输路径的熔断分支 (G2) 会静默杀死整个 harness
capture_rc() {
  RC=0
  RC_BYTES=0
  sync_by_file_batches "/src" "$1" "$2" || RC=$?
  RC_BYTES="${SYNC_TRANSFERRED_BYTES:-0}"
}

# ---------- G1: openlist 目标 + 首批预检失败 ----------
CHECK_FAIL_FROM_OVERRIDE=1
prepare_case
capture_rc "openlist:crypt" "t_g1"
chk "G1 return 1" "$RC" "1"
chk "G1 零批次传输" "$(copy_count)" "0"
chk "G1 预检被调用 1 次" "$CHECK_CALLS" "1"
chk "G1 未进入最终全量同步" "$SYNC_WITH_LOGGING_CALLS" "0"
chk "G1 三批全部计失败" "$(echo "$AUTO_SPLIT_INFO" | grep -c '❌ 3' || true)" "1"
chk "G1 统计含熔断标注" "$(echo "$AUTO_SPLIT_INFO" | grep -c '批次预检熔断中止' || true)" "1"
unset CHECK_FAIL_FROM_OVERRIDE

# ---------- G2: openlist 目标 + 第 2 批预检失败 ----------
CHECK_FAIL_FROM_OVERRIDE=2
prepare_case
capture_rc "openlist:crypt" "t_g2"
chk "G2 return 1" "$RC" "1"
chk "G2 仅第 1 批完成传输" "$(copy_count)" "1"
chk "G2 预检被调用 2 次" "$CHECK_CALLS" "2"
chk "G2 统计 ✅1❌2" "$(echo "$AUTO_SPLIT_INFO" | grep -c '✅ 1 · ❌ 2' || true)" "1"
unset CHECK_FAIL_FROM_OVERRIDE

# ---------- G3: openlist 目标 + 预检全通过 ----------
CHECK_FAIL_FROM_OVERRIDE=99999
prepare_case
capture_rc "openlist:crypt" "t_g3"
chk "G3 return 0" "$RC" "0"
chk "G3 拆分为 3 个批次" "$(copy_count)" "3"
chk "G3 每批一次预检(3)" "$CHECK_CALLS" "3"
chk "G3 最终全量同步 1 次" "$SYNC_WITH_LOGGING_CALLS" "1"
chk "G3 保鲜线程启动 3 次" "$START_TR_CALLS" "3"
chk "G3 保鲜线程停止 3 次" "$STOP_TR_CALLS" "3"
chk "G3 巩固 3 次" "$CONSOLIDATE_CALLS" "3"

# ---------- G4: 非 openlist 目标 ----------
CHECK_FAIL_FROM_OVERRIDE=99999
prepare_case
capture_rc "minio:dest" "t_g4"
chk "G4 return 0" "$RC" "0"
chk "G4 预检零调用" "$CHECK_CALLS" "0"
chk "G4 三批全部传输" "$(copy_count)" "3"
chk "G4 最终全量同步 1 次" "$SYNC_WITH_LOGGING_CALLS" "1"

# ---------- G5: openlist 目标 + 批次传输真失败（exit=2 非 0 非 4） ----------
# 循环跑完不触发熔断/全拒出口，靠尾部归并把批次维度失败并入 SYNC_FAILED;
# run 33048121562 前的旧行为: 批次真失败只有 ✅/❌ 数字变化，任务级仍被判成功
COPY_FAIL_RC_OVERRIDE=2
prepare_case
capture_rc "openlist:crypt" "t_g5"
chk "G5 return 0 (恒 0, 失败经标志传递)" "$RC" "0"
chk "G5 三批均尝试传输" "$(copy_count)" "3"
chk "G5 每批一次预检(3)" "$CHECK_CALLS" "3"
chk "G5 最终全量同步照跑" "$SYNC_WITH_LOGGING_CALLS" "1"
chk "G5 尾部归并 SYNC_FAILED=1" "${SYNC_FAILED}" "1"
unset COPY_FAIL_RC_OVERRIDE

# ---------- G6: 批次循环预算闸（近几轮 330min 硬杀的直接根因） ----------
# 旧行为: 批次循环完全不看 OPENLIST_SYNC_DEADLINE_EPOCH，只剩十几分钟也照开新批
# → 320min 优雅到站永远拿不到，全被 timeout-minutes: 330 硬杀（run 34723502766 /
#   34728107625 / 34740440666 / 34752801560 同步 step 恒 330m±12s）。
# 新行为: 剩余预算不足一个批次工作片（默认 3600s）→ 不开新批、SYNC_TIME_EXHAUSTED=1。
CHECK_FAIL_FROM_OVERRIDE=99999
prepare_case
BATCH_BUDGET_STOP_RC=0
SYNC_TIME_EXHAUSTED=0
capture_rc "openlist:crypt" "t_g6"
chk "G6 return 0（优雅收摊，不判失败）" "$RC" "0"
chk "G6 预算将尽 → 零批次传输" "$(copy_count)" "0"
chk "G6 置 SYNC_TIME_EXHAUSTED=1" "${SYNC_TIME_EXHAUSTED}" "1"
chk "G6 预检零调用（批次根本没开）" "$CHECK_CALLS" "0"
chk "G6 巩固零调用" "$CONSOLIDATE_CALLS" "0"
chk "G6 仍走最终同步检查（通知不丢）" "$SYNC_WITH_LOGGING_CALLS" "1"
unset BATCH_BUDGET_STOP_RC

# ---------- G7: 在途批次的硬上限（预算剩余 − 尾部预留）----------
# 预算闸只拦得住"新开的工作"，拦不住"已在途的传输": batch copy 动辄 1-2h，会一路
# 跑过 320min 预算，直到 step 的 330min 超时把整轮杀掉（run 34779382573: 批次 1
# 在只剩 2h3m 时开启、自身跑 2h14m 仍未完成）。这里断言它确实被套上 timeout。
CHECK_FAIL_FROM_OVERRIDE=99999
prepare_case
BUDGET_SLICE_OVERRIDE=120
# 只为让 `${_b_to} rclone ...` 里的 timeout 能驱动 mock rclone（真 timeout 是外部
# 二进制，无法执行 shell 函数）；场景内单独定义，避免影响 G1-G6 的既有行为
timeout() { shift; "$@"; }
G7_OUT=$(sync_by_file_batches "/src" "openlist:crypt" "t_g7" 2>&1 || true)
unset -f timeout
chk "G7 三批照常传输（包装不改变流程）" "$(copy_count)" "3"
chk "G7 每批 copy 都套上预算内硬上限" \
  "$(echo "$G7_OUT" | grep -c '本轮剩余预算内最多传输 120s' || true)" "3"
unset BUDGET_SLICE_OVERRIDE

# ---------- G8: 批次字节并入趋势口径（F9 最小修复）----------
# 批次路径是主传输通道，此前从不喂 SYNC_TRANSFERRED_BYTES ⇒ trend 的
# transferred_bytes 只反映"未经批次的直接 sync"，批次重的轮次恒为 0
# （run 34920298417 实锤: 实际落盘 51 个文件，trend 记 0）。短轮下几乎每轮都走
# 批次路径，趋势会一直空转 ⇒ 必须并入。3 批 × 1.5 MiB = 4.5 MiB。
prepare_case
BYTES_PER_BATCH=1572864          # 1.5 MiB/批
capture_rc "openlist:crypt" "t_g8"
BYTES_PER_BATCH=0
chk "G8 批次字节并入 SYNC_TRANSFERRED_BYTES（3 批 × 1.5MiB）" "$RC_BYTES" "4718592"
# 反例: 解析不到字节 → 仍为 0（不能凭空造数）
prepare_case
capture_rc "openlist:crypt" "t_g8b"
chk "G8b 解析不到字节 → 记 0（不凭空造数）" "$RC_BYTES" "0"

clean_batch_dirs
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
