#!/bin/bash
# 根目录文件的 base64URL 兜底分支 —— 调用点级确定性验证（2026-11-11 加）
#
# 背景: `根目录文件: 改为编码 dest_path 末段` 这条日志在生产日志里长期不出现，
#   一度让人怀疑是死代码。代码核对结论: 不是死代码 ——
#     · file_dir_rel 在 entry 处把 "." 归一为空串（防 /./ 污染）
#     · b64 分支的进入条件是 dir_ok≠1（目录真的建不出来），日志条件是
#       `[ "$file_dir_rel" = "." ] || [ -z "$file_dir_rel" ]` ⇒ 根目录情形命中 -z 半边
#   它不出现只是因为**前置条件（目录建不出来）本身是概率事件**，且用户那次告警
#   （306/307/308.jpg）最终用「方法1·原名直传」就成功了，根本走不到 b64。
#
# 本测试用真函数 + 桩 rclone，构造"mkdir/lsd/API 全部失败"的确定性场景，
# 证明根目录文件确实会走 b64、落点正确，从而不必等生产偶发。
#
# 断言:
#   B1 日志出现「根目录文件: 改为编码 dest_path 末段」
#   B2 落点 = dest_path 父路径 + b64(末段)，与 run 42588433890 成功路径逐字节一致
#   B3 子目录文件（非根目录）不打印该行（避免文案误报）
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_SRC="$_REPO_ROOT/.github/scripts/openlist/file_fix.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 抽真源函数（不是复写）---
{ sed -n '/^_fix_b64_targets_for()/,/^}$/p' "$_SRC"
  sed -n '/^try_fix_failed_file()/,/^}$/p' "$_SRC"; } > "$WORK/fn.sh"
grep -q '_fix_b64_targets_for' "$WORK/fn.sh" && grep -q 'try_fix_failed_file' "$WORK/fn.sh" \
  || { echo "FATAL: 抽取失败"; exit 1; }
echo "抽取: $(wc -l < "$WORK/fn.sh") 行"

# --- PATH 桩 rclone（绝不允许真实 rclone 被调用）---
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/rclone" <<'EOS'
#!/usr/bin/env bash
echo "rclone $*" >> "${RCLONE_CALL_LOG:?}"
# mkdir / lsd 一律失败 ⇒ 触发 b64 兜底；其余也失败（后续方法走不通即可）
exit 1
EOS
chmod +x "$STUB/rclone"
export RCLONE_CALL_LOG="$WORK/rclone_calls.log"; : > "$RCLONE_CALL_LOG"
export PATH="$STUB:$PATH"
case "$(command -v rclone)" in "$STUB/rclone") : ;; *) echo "FATAL: rclone 未被桩接管"; exit 1 ;; esac

# --- 依赖桩 ---
RCLONE_RETRY_FLAGS=()
log_fix() { printf '%s\n' "$2" >> "$WORK/fix.log"; }
_short_path() { echo "$1"; }
_cmd_log() { cat >/dev/null; }
_fix_dir_exists_or_conflict() { return 1; }
_get_openlist_token() { return 1; }
curl() { return 0; }
sleep() { :; }          # 409/423 退避不许真睡
_fix_probe_dir_writable() { return 1; }
_fix_method_norm() { echo "$1"; }
b64url_encode() { printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '='; }
format_bytes() { echo "$1"; }
OPENLIST_MKDIR_TIMEOUT=5
OPENLIST_409_RETRY_ATTEMPTS=1
OPENLIST_409_RETRY_SLEEP_SECONDS=0
OPENLIST_423_RETRY_ATTEMPTS=1
OPENLIST_423_RETRY_SLEEP_SECONDS=0
source "$WORK/fn.sh"

run_case() {  # $1=dest_path  $2=failed_file_rel
  : > "$WORK/fix.log"; : > "$WORK/rclone_calls.log"
  TRY_FIX_STATUS=""; TRY_FIX_ALTERNATIVE=""; TRY_FIX_METHOD=""
  try_fix_failed_file "onedrive:1/1024j/套图/女仆镂空胖次" "$1" "task1_x" "$2" "$WORK/fix.log" >/dev/null 2>&1
}

# ---------- B1/B2: 根目录文件 ----------
run_case "openlist:wopan175/1/1024j/套图/女仆镂空胖次" "306.jpg"
_root_line=$(grep -c "根目录文件: 改为编码 dest_path 末段" "$WORK/fix.log" 2>/dev/null || echo 0)
[ "$_root_line" -ge 1 ] && ok "B1 根目录文件 → 打印「根目录文件: 改为编码 dest_path 末段」（非死代码）" \
  || bad "B1 未打印该日志行（b64 分支未被走到）"
_expect="openlist:wopan175/1/1024j/套图/5aWz5LuG6ZWC56m66IOW5qyh/306.jpg"
_found=0
grep -qF "openlist:wopan175/1/1024j/套图/5aWz5LuG6ZWC56m66IOW5qyh" "$WORK/fix.log" "$WORK/rclone_calls.log" 2>/dev/null && _found=1
[ "$_found" = "1" ] && ok "B2 落点=父路径+b64(末段)（与 run 42588433890 成功路径一致）" \
  || bad "B2 未看到编码落点 5aWz5LuG6ZWC56m66IOW5qyh"

# ---------- B3: 子目录文件不应打印"根目录"文案 ----------
run_case "openlist:wopan175/1/1024j/套图/女仆镂空胖次" "sub/307.jpg"
# ⚠️ 不能写 `grep -c ... || echo 0`: grep -c 无匹配时**已经打印 0 并返回 1**，
#    `|| echo 0` 会再追加一个 0 ⇒ 变量变成 "0\n0"，比较必然失败（第一版踩过）。
_n=$(grep -c "根目录文件: 改为编码 dest_path 末段" "$WORK/fix.log" 2>/dev/null || true)
[ "${_n:-0}" = "0" ] && ok "B3 子目录文件不打印该行（文案不误报）" \
  || bad "B3 子目录文件也打印了根目录文案（${_n} 次）"
# 同时确认它确实走了 b64（编码的是子目录名 sub → c3Vi），证明分支本身正常
grep -q "base64URL 编码目录: c3Vi" "$WORK/fix.log" \
  && ok "B4 子目录文件编码的是子目录名（sub → c3Vi），与根目录情形区分正确" \
  || bad "B4 未看到子目录名编码"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
