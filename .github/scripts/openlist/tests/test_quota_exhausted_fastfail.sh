#!/bin/bash
# 目标端配额已满 → 快速失败 + 本轮跳过同后端（2026-11-12 加）
#
# 现场（run 43001486184，gd:backup）:
#   googleapi: Error 403: The user's Drive storage quota has been exceeded.
#   实测配额 Used 2.883 TiB / Total 15 GiB（付费容量掉了）⇒ 任何写入必失败。
#   浪费: rclone 内部 --retries 3 × 约 3 分钟 = 一个 gd 对白烧 ~13 分钟；
#   一轮 5 个 gd 对 ≈ 65 分钟（占 320 分钟预算 20%），必然 0 产出。
#
# 契约:
#   Q1 配额错误被识别 → SYNC_FAILED=1（真错误，不是到点交棒）
#   Q2 写出本轮标记文件（供并行调度跳过同后端）
#   Q3 不做下游（不清理/不 truth-check/不修复）—— 配额满时全是空转
#   Q4 并行调度看到标记 → 该后端剩余同步对直接 skipped，不再起 worker
#   Q5 无标记时行为不变（不得误跳过）
#   Q6 普通错误（非配额）不触发标记
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_TE="$_REPO_ROOT/.github/scripts/openlist/task_engine.sh"
_SE="$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------- 抽真源 ----------
sed -n '/^sync_with_logging()/,/^}$/p' "$_SE" > "$WORK/swl.sh"
sed -n '/^_quota_flag_path()/,/^}$/p' "$_TE" > "$WORK/qf.sh"
sed -n '/^_quota_backend_flagged()/,/^}$/p' "$_TE" >> "$WORK/qf.sh"
grep -q 'sync_with_logging' "$WORK/swl.sh" || { echo "FATAL: 抽 sync_with_logging 失败"; exit 1; }
grep -q '_quota_backend_flagged' "$WORK/qf.sh" || { echo "FATAL: 抽配额 helper 失败"; exit 1; }
grep -q 'storage quota has been exceeded' "$WORK/swl.sh" || { echo "FATAL: 抽取内容不含配额检测"; exit 1; }
echo "抽取: swl=$(wc -l < "$WORK/swl.sh") 行, quota=$(wc -l < "$WORK/qf.sh") 行"

# ---------- PATH 桩 rclone（绝不触真 rclone）----------
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/rclone" <<'EOS'
#!/usr/bin/env bash
echo "rclone $*" >> "${RCLONE_CALL_LOG:?}"
exit "${RC_RCLONE:-0}"
EOS
chmod +x "$STUB/rclone"
export RCLONE_CALL_LOG="$WORK/calls.log"; : > "$RCLONE_CALL_LOG"
export RC_RCLONE=1
export PATH="$STUB:$PATH"
case "$(command -v rclone)" in "$STUB/rclone") : ;; *) echo "FATAL: rclone 未被桩接管"; exit 1 ;; esac

export OPENLIST_QUOTA_FLAG_DIR="$WORK/flags"; mkdir -p "$OPENLIST_QUOTA_FLAG_DIR"

# ---------- 协作者桩 ----------
DOWNSTREAM=""
NOTIFY_STATUS="<未调用>"
SYNC_FAILED=0; SYNC_SKIPPED=0; SYNC_PARTIAL=0; SYNC_TIME_EXHAUSTED=0
SYNC_TRANSFERRED_BYTES=0
declare -A _BACKEND_WRITE_PROBE_CACHE=() _BACKEND_DEAD=()
_check_openlist_backend_connectivity() { return 0; }
_refresh_openlist_cache() { :; }
_slice_cap_seconds() { echo 600; }
_budget_slice_seconds() { echo 600; }
_backend_root_of() { printf '%s' "$1" | cut -d/ -f1; }
_sync_fixed_files_exclusion() { :; }
_start_token_refresher() { :; }
_stop_token_refresher() { :; }
_ol_lock_shared() { :; }
_ol_lock_shared_release() { :; }
_sync_mirror_prune() { DOWNSTREAM="${DOWNSTREAM}prune "; }
_openlist_truth_check() { DOWNSTREAM="${DOWNSTREAM}truth "; }
_sync_fix_missing_files() { DOWNSTREAM="${DOWNSTREAM}fix "; }
_sync_persist_verify_and_retry() { DOWNSTREAM="${DOWNSTREAM}persist "; }
_sync_parse_object_not_found() { :; }
_sync_serialize_fixed_files() { :; }
_sync_accumulate_fixed_results() { :; }
get_transferred_bytes_from_log() { echo 0; }
_send_sync_result_notification() { NOTIFY_STATUS="$4"; }
# _quota_backend_key 的真源在 utils.sh（基础层）。必须加载**真实现**：
# 用桩就测不到"键按远端分组"这个真缺陷（run 43125112722 现场: 标记被写成
# gd:0/gd:backup 两个键 ⇒ 跨对跳过命中 0 次、403 仍 17 次）。
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null || true
declare -F _quota_backend_key >/dev/null 2>&1 \
  || { echo "FATAL: _quota_backend_key 未定义（utils.sh 未加载）—— 跨对断言会假绿"; exit 1; }
source "$WORK/qf.sh"
source "$WORK/swl.sh"

# 让"配额错误"出现在 attempt 日志里：桩 rclone 写不出日志（被测代码用 tee 写），
# 故直接让假 rclone 往 tee 的目标写 —— 这里改用最简单办法: 预置日志内容由
# run_rclone_sync_once 里的 `: > "$LAST_ATTEMPT_LOG"` 清空，所以必须由 rclone
# 的标准输出产生。桩往 stdout 打一行配额错误即可经 tee 落入 attempt 日志。
cat > "$STUB/rclone" <<'EOS'
#!/usr/bin/env bash
echo "rclone $*" >> "${RCLONE_CALL_LOG:?}"
if [ "${EMIT_QUOTA:-0}" = "1" ]; then
  echo "ERROR : bitwarden_latest.tar.gz: Failed to copy: googleapi: Error 403: The user's Drive storage quota has been exceeded., storageQuotaExceeded"
fi
if [ "${EMIT_OTHER:-0}" = "1" ]; then
  echo "ERROR : something: Failed to copy: connection reset by peer"
fi
exit "${RC_RCLONE:-0}"
EOS
chmod +x "$STUB/rclone"

run_case() {  # $1=dest  $2=EMIT_QUOTA  $3=EMIT_OTHER
  DOWNSTREAM=""; NOTIFY_STATUS="<未调用>"; SYNC_FAILED=0; SYNC_TIME_EXHAUSTED=0; SYNC_PARTIAL=0
  rm -f "$OPENLIST_QUOTA_FLAG_DIR"/* 2>/dev/null || true
  EMIT_QUOTA="$2" EMIT_OTHER="$3" sync_with_logging "onedrive:backup" "$1" "t_q_$$" >/dev/null 2>&1
}

# ---------- Q1/Q2/Q3: 配额错误 ----------
run_case "gd:backup" 1 0
[ "$SYNC_FAILED" = "1" ] && ok "Q1 配额错误 → SYNC_FAILED=1（真错误，不冒充交棒）" || bad "Q1 SYNC_FAILED=$SYNC_FAILED"
[ "$SYNC_TIME_EXHAUSTED" = "0" ] && ok "Q1b 不置超时标志（区别于预算到点）" || bad "Q1b 超时标志=$SYNC_TIME_EXHAUSTED"
_nf=$(ls "$OPENLIST_QUOTA_FLAG_DIR" 2>/dev/null | wc -l | tr -d ' ')
[ "$_nf" -ge 1 ] && ok "Q2 写出本轮配额标记（${_nf} 个）" || bad "Q2 未写标记"
[ -z "$DOWNSTREAM" ] && ok "Q3 不做下游（清理/truth/修复全跳过，配额满时都是空转）" || bad "Q3 仍执行了下游: $DOWNSTREAM"

# ---------- Q4: 调度据此跳过 ----------
if _quota_backend_flagged "$(_quota_backend_key gd:backup)"; then ok "Q4 调度可查到该后端已判配额满"; else bad "Q4 标记查不到"; fi

# ---------- Q4b: 跨对跳过（2026-11-12 修的真缺陷）----------
# 现场（run 43125112722）: 标记被写成 `gd:0` / `gd:backup` 两个**不同**键
#   ⇒「跳过同后端」命中 0 次、403 仍出现 17 次（5 个 gd 对各烧 3 次重试）。
#   根因: 旧实现用 _backend_root_of，它对非 openlist 目标返回整个 dest 路径。
#   修: 按远端身份分组（gd:0/gd:1/gd:backup 全部 → gd）。
_eq_key() {  # 断言两个 dest 归到同一个配额键
  local a b
  a=$(_quota_backend_key "$1"); b=$(_quota_backend_key "$2")
  [ "$a" = "$b" ] && echo same || echo "diff:${a}/${b}"
}
[ "$(_eq_key gd:0 gd:1)" = same ] && ok "Q4b gd:0 与 gd:1 归同一配额键（可跨对跳过）" || bad "Q4b $(_eq_key gd:0 gd:1)"
[ "$(_eq_key gd:backup gd:1)" = same ] && ok "Q4c gd:backup 与 gd:1 归同一配额键" || bad "Q4c $(_eq_key gd:backup gd:1)"
[ "$(_quota_backend_key 'gd:0')" = "gd" ] && ok "Q4d 键值就是远端名 gd（不带路径）" || bad "Q4d 键=$(_quota_backend_key gd:0)"
# openlist 必须按上游区分（各盘容量独立，不能一锅端）
[ "$(_quota_backend_key 'openlist:wopan175/1')" = "openlist:wopan175" ] \
  && ok "Q4e openlist 按挂载上游区分（wopan175）" || bad "Q4e 键=$(_quota_backend_key 'openlist:wopan175/1')"
[ "$(_eq_key 'openlist:wopan175/1' 'openlist:wopan176Crypt/1')" != same ] \
  && ok "Q4f wopan175 与 wopan176Crypt 不共享配额键（不误跳过）" || bad "Q4f 两者被并成一个键"

# ---------- Q4g: 端到端——一个对触发后，同盘其余对全部可跳过 ----------
rm -f "$OPENLIST_QUOTA_FLAG_DIR"/* 2>/dev/null || true
run_case "gd:0" 1 0        # gd:0 撞 403 → 写 gd 键
for _d in "gd:1" "gd:2" "gd:3" "gd:backup"; do
  if _quota_backend_flagged "$(_quota_backend_key "$_d")"; then
    ok "Q4g 同盘 ${_d} 命中标记 → 会被跳过（不再烧 3 次重试）"
  else
    bad "Q4g 同盘 ${_d} 未命中标记（跨对跳过失效）"
  fi
done

# ---------- Q5: 无标记不误跳过 ----------
rm -f "$OPENLIST_QUOTA_FLAG_DIR"/* 2>/dev/null || true
if _quota_backend_flagged "$(_quota_backend_key gd:0)"; then bad "Q5 无标记却判配额满"; else ok "Q5 无标记 → 不跳过（不误伤）"; fi

# ---------- Q6: 普通错误不触发 ----------
run_case "gd:0" 0 1
_nf=$(ls "$OPENLIST_QUOTA_FLAG_DIR" 2>/dev/null | wc -l | tr -d ' ')
[ "$_nf" = "0" ] && ok "Q6 普通错误（连接重置）不写配额标记" || bad "Q6 普通错误也写了标记（${_nf} 个）"

# ---------- Q7: 配额恢复（新轮 /tmp 清空）后自动参战 ----------
rm -rf "$OPENLIST_QUOTA_FLAG_DIR"; mkdir -p "$OPENLIST_QUOTA_FLAG_DIR"
if _quota_backend_flagged "gd:backup"; then bad "Q7 清空后仍判满"; else ok "Q7 标记随本轮清空 → 容量恢复后自动参战"; fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
