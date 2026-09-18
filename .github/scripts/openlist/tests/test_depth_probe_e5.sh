#!/bin/bash
# ===== 注册: diag_depth_probe.sh 的 E5「兜底落点真写入判决」逻辑 =====
#
# 为什么要这个测试（2026-09-18，用户指出前几轮"越走越偏"后回归目标）:
#   此前所有深度探针组只判「目录能不能建」（mkdir+lsd），但用户要的是
#   **文件能不能落盘**。「目录建得出」≠「文件写得进」。
#   生产故障轮里失败文件走的正是兜底落点 `dest_path/<hash8>` ⇒ 必须在该落点上
#   `copyto` 一个真文件 + **直读**复核，才能区分:
#     · 落点能写 ⇒ 兜底本可救回，问题在兜底流程/判据走死（可修 bug）
#     · 落点写不进 ⇒ dest_path 整体不可写（后端问题，代码无解）
#
# 本测试用 rclone 桩把 E5 的两条判决分支各跑一次，锁死判据（任一改坏即变红）:
#   E5a 落点可写（copyto rc=0 且直读在）⇒ 判「可写/流程 bug」
#   E5b 落点写不进（copyto rc!=0 且直读不在）⇒ 判「写不进/后端」
#   另: 直读判据必须是 lsjson（全路径 stat），不能用列列举——
#       否则会重蹈「列列举滞后把成功判成失败」的覆辙（AGENTS.md 教训）。
#
# 用法: bash test_depth_probe_e5.sh   （退出码 0=全过）

set -u

FAIL=0
PASS=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OL_DIR="$REPO_ROOT/.github/scripts/openlist"
PROBE="$OL_DIR/diag_depth_probe.sh"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# ────────────────────────────────────────────────────────────
# E5-0 · 静态契约: E5 组存在，且判据用直读（lsjson）而非列列举
# ────────────────────────────────────────────────────────────
if grep -q 'E5 · 兜底落点真写入' "$PROBE"; then
  ok "E5-0a E5 组已存在"
else
  bad "E5-0a E5 组缺失"
fi

# 在 E5 组范围内（从 E5 的 sec 调用到 E9 的 sec 调用）必须出现 lsjson 直读判据
_e5_block=$(awk '/sec "E5 · 兜底落点真写入/{f=1} /sec "E9 · 清理/{f=0} f' "$PROBE")
if printf '%s' "$_e5_block" | grep -q 'rclone lsjson'; then
  ok "E5-0b E5 用 lsjson 直读判据（非列列举）"
else
  bad "E5-0b E5 未使用直读判据（会重蹈列列举滞后误判）"
fi

# E5 必须只写自建小文件（ol2d_ 前缀），不得写生产文件名
if printf '%s' "$_e5_block" | grep -q 'ol2d_w_'; then
  ok "E5-0c E5 只写自建文件（ol2d_w_ 前缀）"
else
  bad "E5-0c E5 未用可辨识前缀，有触碰生产文件风险"
fi

# ────────────────────────────────────────────────────────────
# E5-1 · 行为契约: 用 rclone 桩把两条分支各跑一次
# ────────────────────────────────────────────────────────────
# 桩设计: 拦截 rclone 子命令，按预设脚本决定 mkdir/lsd/stat 结果。
#   环境变量:
#     STUB_MKDIR_EXISTS   lsd <dir> 是否报存在（控制 E1a 是否建成落点）
#     STUB_COPY_RC        copyto 退出码
#     STUB_STAT_EXISTS    lsjson <file> 是否报存在（直读判据结果）
_run_probe_with_stub() {
  local stub_bin="$TMPDIR_T/bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/rclone" <<'STUB'
#!/bin/bash
sub="$1"; shift
case "$sub" in
  mkdir)
    # 目录建不建得出来由 STUB_MKDIR_EXISTS 控制（rc 恒 0，模拟"报成功"）
    exit 0 ;;
  lsd)
    [ "${STUB_MKDIR_EXISTS:-1}" = "1" ] && exit 0 || exit 1 ;;
  copyto)
    exit "${STUB_COPY_RC:-0}" ;;
  lsjson)
    [ "${STUB_STAT_EXISTS:-1}" = "1" ] && exit 0 || exit 1 ;;
  purge|size|lsf)
    exit 0 ;;
  *)
    exit 0 ;;
esac
STUB
  chmod +x "$stub_bin/rclone"
  cat > "$stub_bin/date" <<'STUB'
#!/bin/bash
# 固定时间戳，避免报告文件名漂移；-u 形态直接透传给真 date
if [ "${1:-}" = "+%s" ]; then echo "1700000000"; exit 0; fi
exec /bin/date "$@"
STUB
  chmod +x "$stub_bin/date"

  PATH="$stub_bin:$PATH" \
  DIAG_REPORT="$TMPDIR_T/e5_report.txt" \
  DIAG_DP_SKIP_E2=1 \
  DIAG_DP_SKIP_E3=1 \
  DIAG_DP_WAIT=0 \
  STUB_MKDIR_EXISTS="${1:-1}" \
  STUB_COPY_RC="${2:-0}" \
  STUB_STAT_EXISTS="${3:-1}" \
    bash "$PROBE" "openlist:wopan175" "openlist" "5" "1024j-x" "1" \
    > "$TMPDIR_T/e5_stdout.txt" 2>&1
}

# E5a · 落点建成 + 写入成功 + 直读在 ⇒ 判「可写/流程 bug」
_run_probe_with_stub 1 0 1
if grep -q 'E5 兜底落点真写入:     落点可写（文件真落盘）' "$TMPDIR_T/e5_report.txt"; then
  ok "E5a 落点可写 ⇒ 判「可写（流程 bug）」"
else
  bad "E5a 落点可写但判决不符（期望「落点可写（文件真落盘）」）"
  sed 's/^/      ▸ /' "$TMPDIR_T/e5_report.txt" | tail -12
fi

# E5b · 落点建成 + 写入失败 + 直读不在 ⇒ 判「写不进/后端」
_run_probe_with_stub 1 1 0
if grep -q 'E5 兜底落点真写入:     落点建得出但写不进' "$TMPDIR_T/e5_report.txt"; then
  ok "E5b 落点写不进 ⇒ 判「写不进（后端）」"
else
  bad "E5b 落点写不进但判决不符（期望「落点建得出但写不进」）"
  sed 's/^/      ▸ /' "$TMPDIR_T/e5_report.txt" | tail -12
fi

# E5c · 落点根本没建成（E1a 失败）⇒ 不测写入，明确标注
_run_probe_with_stub 0 0 0
if grep -q 'E5 兜底落点真写入:     落点建不出，未测写入' "$TMPDIR_T/e5_report.txt"; then
  ok "E5c 落点建不出 ⇒ 明确标注「未测写入」（不误报）"
else
  bad "E5c 落点建不出时未正确标注"
  sed 's/^/      ▸ /' "$TMPDIR_T/e5_report.txt" | tail -12
fi

echo ""
echo "==================== 汇总 ===================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
