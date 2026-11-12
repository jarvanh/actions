#!/bin/bash
# 同步日志名必须唯一（2026-11-13 加，run 43173429624 实证）
#
# 现场: 第 13 对（task2-wopan175）报 `834.004 GiB / 34.4min` ≈ 410 MiB/s ——
#   物理不可能（同期 rclone 自报 1.4–2.9 MiB/s；该对结束前真实进度是
#   `3.430 GiB / 14.902 GiB`）。该虚高一路累加进"本轮传输 907.086 GiB"，
#   使整个指标失真，并一度让我据此得出"20 倍提升"的错误结论。
#
# 根因: LOG_FILENAME 只有**秒级**时间戳、没有 pid ⇒ 同一父任务下并行派发的
#   子目录 worker 若 task_name 相同且同一秒启动，会写**同一个日志文件**:
#     ① 后启动者 `: > "$LAST_ATTEMPT_LOG"` 截断前者；
#     ② 并发写导致内容交错；
#     ③ get_transferred_bytes_from_log 取"最后一条 X / Y" ⇒ 取到**别人**的
#        大额进度行 ⇒ 记账虚高。
#
# 断言:
#   L1 并发同名同步产生**两个不同**的日志文件（不再共享）
#   L2 两个文件的最后一条进度行各自独立（不互相污染）
#   L3 串行两次也不会复用同一文件（时间戳同秒时必须靠 pid 区分）
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_SRC="$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

sed -n '/^sync_with_logging()/,/^}$/p' "$_SRC" > "$WORK/swl.sh"
[ -s "$WORK/swl.sh" ] || { echo "FATAL: 抽取失败"; exit 1; }
grep -q 'BASHPID' "$WORK/swl.sh" || { echo "FATAL: 日志名未含唯一后缀（BASHPID）"; exit 1; }
echo "抽取: $(wc -l < "$WORK/swl.sh") 行"

# ---------- PATH 桩 rclone：打印一条"累计"进度行后成功 ----------
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/rclone" <<'EOS'
#!/usr/bin/env bash
# 每个 worker 打印自己独有的数值，便于断言"没串味"
echo "  ${FAKE_BYTES:-1} MiB / 100 MiB, 1%, 1.0 MiB/s, ETA 10m (xfr#1/2)"
exit 0
EOS
chmod +x "$STUB/rclone"
export PATH="$STUB:$PATH"
case "$(command -v rclone)" in "$STUB/rclone") : ;; *) echo "FATAL: rclone 未被桩接管"; exit 1 ;; esac

# ---------- 协作者桩 ----------
_check_openlist_backend_connectivity() { return 0; }
_refresh_openlist_cache() { :; }
_slice_cap_seconds() { echo ""; }
_budget_slice_seconds() { echo ""; }
_backend_root_of() { echo "$1"; }
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
get_transferred_bytes_from_log() { echo 1048576; }
_send_sync_result_notification() { :; }
source "$WORK/swl.sh"
cd "$WORK"

# ---------- L1/L2: 并发同名同秒 ----------
FAKE_BYTES=11 sync_with_logging "onedrive:2" "openlist:wopan175/2" "same_name" >/dev/null 2>&1 &
_p1=$!
FAKE_BYTES=22 sync_with_logging "onedrive:2" "openlist:wopan175/2" "same_name" >/dev/null 2>&1 &
_p2=$!
wait "$_p1" "$_p2" 2>/dev/null || true

_n=$(ls same_name_sync_*.log 2>/dev/null | wc -l | tr -d ' ')
[ "$_n" -ge 2 ] && ok "L1 并发同名同步产生 ${_n} 个独立日志文件（不再共享同一文件）" \
  || bad "L1 只产生 ${_n} 个日志文件（仍会互相截断/污染）"

# L2: 每个文件的最后一条进度行应来自它自己（不同数值），且不出现"两行交错"
_distinct=$(grep -hoE '^  [0-9]+ MiB / 100 MiB' same_name_sync_*.log 2>/dev/null | sort -u | wc -l | tr -d ' ')
[ "$_distinct" -ge 2 ] && ok "L2 各日志保留了各自独立的进度值（未互相覆盖）" \
  || bad "L2 只看到 ${_distinct} 种进度值（疑似被覆盖）"

# ---------- L3: 名字里必须带唯一后缀（静态锁）----------
# 行为层已由 L1/L2 覆盖（并发同名同秒 ⇒ 两个独立文件）。
# 这里再静态锁一次，防止有人日后把 BASHPID 后缀"简化"掉 —— 那会让 L1/L2
# 在某些时序下重新变成偶发（同一秒 + 同名才撞，平时看不出来）。
grep -q 'LOG_FILENAME="${task_name}_sync_${TIMESTAMP}_${BASHPID' "$WORK/swl.sh" \
  && ok "L3 日志名模板含 \${BASHPID} 唯一后缀（静态锁）" \
  || bad "L3 日志名模板缺少唯一后缀（并发同名会重新撞名）"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
