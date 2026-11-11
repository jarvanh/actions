#!/usr/bin/env bash
# 预算/份额截断（rc=124）不得被判成同步失败（2026-11-11 加）
#
# 现场（run 42887432510）: 份额机制生效后，大对每轮都会在份额到点被
#   `timeout ${_st_tmo}` 收掉 ⇒ rc=124。但下游判据是 `sync_status != 0` 即失败，
#   于是每个被截断的直连对都记成「同步失败」—— gd:1 连续两轮 `0 B / 0 B, 0 B/s`
#   收尾 failed。三个连带伤害:
#     ① 发「同步失败」告警（假故障）
#     ② _sync_task_finalize 见 SYNC_FAILED≠0 会对 openlist 目标调用
#        split_on_sync_failure（真去切大文件）
#     ③ 父级按 failed 聚合子目录，统计与事实不符
#
# 契约:
#   T1 initial sync rc=124 → SYNC_TIME_EXHAUSTED=1 且 SYNC_FAILED=0，
#      且交给通知层的状态是 0（不判失败）
#   T2 真失败（rc=1）→ 不受影响，仍按失败处理
#   T3 rc=88（二次预检熔断）→ 仍按失败处理（不能被 124 归一化顺手放过）
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_SRC="$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

sed -n '/^sync_with_logging()/,/^}$/p' "$_SRC" > "$WORK/swl.sh"
echo "抽取 sync_with_logging: $(wc -l < "$WORK/swl.sh") 行"
[ -s "$WORK/swl.sh" ] || { echo "FATAL: 抽取失败"; exit 1; }
grep -q 'eq 124' "$WORK/swl.sh" || { echo "FATAL: 抽取内容不含 124 归一化"; exit 1; }

# ---------- 协作者桩 ----------
# ⚠️⚠️ 安全铁律: **绝不能让真实 rclone 被调用**
#   第一版把 `rclone` 写成 shell 函数 —— 无效: 被测代码用的是
#   `${_st_to} rclone ...`（`_st_to="timeout 600"`），`timeout` 是外部命令，
#   看不到 shell 函数 ⇒ 它执行了**真实的 /usr/bin/rclone sync onedrive:1 gd:1**，
#   实测真跑起来约 3 分钟（事后核对 gd:1 与 onedrive:1 均为 60,256 对象 /
#   782.286 GiB 完全一致，未产生写入或删除，源端零写入）。
#   故改用 **PATH stub**（tests 里 login 套件的同款手法）: 把假 rclone 放到
#   PATH 最前，任何调用路径（含 timeout 包装）都只能命中假的那个。
STUB_BIN="$WORK/stub"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/rclone" <<'EOS'
#!/usr/bin/env bash
# 假 rclone: 记录调用并按 RC_RCLONE 返回（模拟 timeout 到点收掉的 124）
echo "rclone $*" >> "${RCLONE_CALL_LOG:?}"
exit "${RC_RCLONE:-0}"
EOS
chmod +x "$STUB_BIN/rclone"
export RCLONE_CALL_LOG="$WORK/rclone_calls.log"
: > "$RCLONE_CALL_LOG"
export PATH="$STUB_BIN:$PATH"
# 断言桩生效: 若 PATH 里 rclone 不是我们的假货就直接放弃（宁可测试失败，
# 也不能让真实 rclone 有机会跑生产同步）
_which=$(command -v rclone)
case "$_which" in
  "$STUB_BIN/rclone") : ;;
  *) echo "FATAL: rclone 未被 PATH 桩接管（$_which），拒绝继续以免触发真实同步"; exit 1 ;;
esac

RC_RCLONE=0
export RC_RCLONE   # 桩是外部进程，变量必须导出才看得见（否则 exit "" 得到非预期码）
NOTIFY_STATUS="<未调用>"
NOTIFY_CALLS=0
SYNC_FAILED=0; SYNC_SKIPPED=0; SYNC_PARTIAL=0; SYNC_TIME_EXHAUSTED=0
SYNC_TRANSFERRED_BYTES=0
declare -A _BACKEND_WRITE_PROBE_CACHE=() _BACKEND_DEAD=()

_check_openlist_backend_connectivity() { return 0; }
_refresh_openlist_cache() { :; }
_slice_cap_seconds() { echo 600; }
_budget_slice_seconds() { echo 600; }
_sync_fixed_files_exclusion() { :; }
_start_token_refresher() { :; }
_stop_token_refresher() { :; }
_ol_lock_shared() { :; }
_ol_lock_shared_release() { :; }
_sync_mirror_prune() { :; }
_openlist_truth_check() { :; }
_sync_fix_missing_files() { :; }
_sync_persist_verify_and_retry() { :; }
_sync_parse_object_not_found() { :; }
_sync_serialize_fixed_files() { :; }
_sync_accumulate_fixed_results() { :; }
_backend_root_of() { echo "$1"; }
get_transferred_bytes_from_log() { echo 0; }
_send_sync_result_notification() {
  NOTIFY_CALLS=$((NOTIFY_CALLS+1))
  NOTIFY_STATUS="$4"   # 形参顺序: source dest task sync_status
  return 0
}
source "$WORK/swl.sh"
# 被测函数把日志写成相对路径（${task_name}_sync_*.log）⇒ 必须切到 WORK 目录，
# 否则会往仓库根目录丢垃圾文件（第一版实测留下 t_case_88_sync_*.log）
cd "$WORK"

run_case() {  # $1=rclone 退出码 → 打印 "<状态>|<失败标志>|<超时标志>"
  RC_RCLONE="$1"
  NOTIFY_STATUS="<未调用>"; NOTIFY_CALLS=0
  SYNC_FAILED=0; SYNC_TIME_EXHAUSTED=0; SYNC_PARTIAL=0
  # 收窄超时: 万一桩失效也不至于在真实网络上跑很久（双保险，桩本身已拦住）
  local _tmo_saved="${OPENLIST_FAKE_GUARD:-}"
  sync_with_logging "onedrive:1" "gd:1" "t_case_$1" >/dev/null 2>&1
  printf '%s|%s|%s\n' "$NOTIFY_STATUS" "${SYNC_FAILED:-}" "${SYNC_TIME_EXHAUSTED:-}"
}

# ---------- T1: rc=124 = 到点交棒 ----------
out=$(run_case 124)
IFS='|' read -r st failed exhausted <<< "$out"
[ "$st" = "0" ] && ok "T1a 交给通知层的状态归一为 0（不判失败）" || bad "T1a 通知状态=[$st]"
[ "$failed" = "0" ] && ok "T1b SYNC_FAILED=0（不再触发假告警/大文件切割）" || bad "T1b SYNC_FAILED=[$failed]"
[ "$exhausted" = "1" ] && ok "T1c SYNC_TIME_EXHAUSTED=1（下游可识别为到点交棒）" || bad "T1c 超时标志=[$exhausted]"

# ---------- T2: 真失败不受影响 ----------
out=$(run_case 1)
IFS='|' read -r st failed exhausted <<< "$out"
[ "$st" = "1" ] && ok "T2a rc=1 原样传给通知层（真失败不被掩盖）" || bad "T2a 通知状态=[$st]"
[ "$exhausted" = "0" ] && ok "T2b rc=1 不置超时标志" || bad "T2b 超时标志=[$exhausted]"

# ---------- T3: 熔断哨兵 88 不被顺手放过 ----------
out=$(run_case 88)
IFS='|' read -r st failed exhausted <<< "$out"
[ "$failed" = "1" ] && ok "T3 rc=88（二次预检熔断）仍判失败" || bad "T3 SYNC_FAILED=[$failed]"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
