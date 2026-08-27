#!/usr/bin/env bash
# 批次级三层预检熔断回归测试（对应 tasks.sh 批次循环的熔断分支）
# 背景: sync_with_logging 的入口预检覆盖不到 sync_by_file_batches 批次循环内的
#   rclone copy --files-from。登录失效后端（openlist 服务端缓存掩盖驱动死活）
#   会把第一个大批次（≤50GB）全额烧完才由 _batch_consolidate 行为启发式止损。
# 批次熔断把拦截前移到每个批次传输之前（与 run_rclone_sync_once 二次预检同构）。
# 场景:
#   G1 openlist 目标 + 首批预检失败 -> 0 个 copy, 全部批次计失败, return 1,
#      SYNC_FAILED=1（run 33048121562 回归: 只 return 1 不置标志会被 task_done
#      与轮转游标双双误判为成功）
#   G2 openlist 目标 + 第 2 批预检失败 -> 只有第 1 批 copy, ✅1❌2, SYNC_FAILED=1
#   G3 openlist 目标 + 预检全通过 -> 3 批照常 + 每批一次预检 + 最终 sync_with_logging
#   G4 非 openlist 目标 -> 预检零调用
#   G5 openlist 目标 + 批次传输真失败（exit≠4）-> 最终同步照跑, 尾部归并 SYNC_FAILED=1
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
# sed 单函数抽取而非 source 整个 tasks.sh: 保持与 utils/sync/marker 等模块零耦合，
# 全部协作者用显式 stub 替代，行为断言不受无关改动影响
sed -n '/^sync_by_file_batches()/,/^}/p' "$SCRIPT_DIR/../tasks.sh" > extracted.sh
echo "被测函数抽取: $(wc -l < extracted.sh) 行"
source extracted.sh

# ---------- 协作者 stub ----------
DEFAULT_SPLIT_THRESHOLD_BYTES=$((50 * 1024 * 1024 * 1024))
SYNC_SPLIT_THRESHOLD_BYTES=100
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

SYNC_WITH_LOGGING_CALLS=0
sync_with_logging() { SYNC_WITH_LOGGING_CALLS=$((SYNC_WITH_LOGGING_CALLS + 1)); }

REFRESH_CALLS=0
_refresh_ol_drivers() { REFRESH_CALLS=$((REFRESH_CALLS + 1)); return 0; }
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

clean_batch_dirs() { rm -rf /tmp/file_batches_t_* || true; }
prepare_case() {
  CHECK_CALLS=0
  SYNC_WITH_LOGGING_CALLS=0
  REFRESH_CALLS=0
  START_TR_CALLS=0
  STOP_TR_CALLS=0
  CONSOLIDATE_CALLS=0
  AUTO_SPLIT_INFO=""
  rm -f "$RCLONE_COPY_CALLS_FILE"
  clean_batch_dirs
}
# 必须复刻生产调用形态 (tasks.sh run_all_tasks `_run_registry_entry || true`):
# || 列表豁免随动态调用链穿透，函数体内批次循环的 set ±e 重开不会击穿进程；
# 若改用 set +e 手工保护，errexit 判定取 "return 完成时刻" 的 options 状态 ->
# 第一个经历过传输路径的熔断分支 (G2) 会静默杀死整个 harness
capture_rc() {
  RC=0
  sync_by_file_batches "/src" "$1" "$2" || RC=$?
}

# ---------- G1: openlist 目标 + 首批预检失败 ----------
CHECK_FAIL_FROM_OVERRIDE=1
prepare_case
capture_rc "openlist:crypt" "t_g1"
chk "G1 return 1" "$RC" "1"
chk "G1 零批次传输" "$(copy_count)" "0"
chk "G1 预检被调用 1 次" "$CHECK_CALLS" "1"
chk "G1 未进入最终全量同步" "$SYNC_WITH_LOGGING_CALLS" "0"
chk "G1 三批全部计失败" "$(echo "$AUTO_SPLIT_INFO" | grep -c '❌ <b>3</b>' || true)" "1"
chk "G1 统计含熔断标注" "$(echo "$AUTO_SPLIT_INFO" | grep -c '批次预检熔断中止' || true)" "1"
unset CHECK_FAIL_FROM_OVERRIDE

# ---------- G2: openlist 目标 + 第 2 批预检失败 ----------
CHECK_FAIL_FROM_OVERRIDE=2
prepare_case
capture_rc "openlist:crypt" "t_g2"
chk "G2 return 1" "$RC" "1"
chk "G2 仅第 1 批完成传输" "$(copy_count)" "1"
chk "G2 预检被调用 2 次" "$CHECK_CALLS" "2"
chk "G2 统计 ✅1❌2" "$(echo "$AUTO_SPLIT_INFO" | grep -c '✅ <b>1</b> · ❌ <b>2</b>' || true)" "1"
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

clean_batch_dirs
echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
