#!/bin/bash
# diag_reject.sh（拒收归因专项）——逻辑验证（mock rclone/docker/sleep）
# 覆盖判读矩阵的六个分支（计划文档 §12.13.4 定向诊断的载体）:
#   1. 空 DIAG_REJECT_SRC → 报告提示未启用，秒退，不建诊断目录
#   2. C 存活 + B 蒸发     → 「按内容拒收坐实」（且 trace 呈「可见→可见→缺失」经典蒸发形态）
#   3. C 存活 + B 存活(A 蒸发) → 「按文件名/状态拒收 · 改名可绕」
#   4. C 蒸发              → 「通路/目录异常，实验作废」
#   5. 全部存活            → 「改名可绕」+「V3 现象未复现」
#   6. A/B 上传全部被拒    → 「受理层失败」（不得误判成「未复现」）
# 另验证产物形态: A=原名 / B=oldiag_ren_0_<ts>.<原扩展名> / C 载荷字节数=源 bytes
#
# mock 关键机制: lsf 三时点共用一个状态文件，restart 前输出全量（缓存口径），
# restart 时按场景的 after_grep 过滤（真值口径）——与脚本「重启取真值」的语义对齐。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$_REPO_ROOT/.github/scripts/openlist/diag_reject.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: 被测脚本不存在: $SCRIPT"; exit 1; }

MOCKBIN=/tmp/ol_reject_test/bin
MOCKDIR=/tmp/ol_reject_test/state
setup_mocks() {
  rm -rf /tmp/ol_reject_test
  mkdir -p "$MOCKBIN" "$MOCKDIR"
  : > "$MOCKDIR/uploaded"
  echo before > "$MOCKDIR/mode"
  echo . > "$MOCKDIR/after_grep"
  cat > "$MOCKBIN/rclone" <<'EOF'
#!/bin/bash
D=/tmp/ol_reject_test/state
case "$1" in
  size)   echo '{"count":1,"bytes":1024}' ;;
  mkdir)  echo "mkdir $2" >> "$D/uploaded_calls"; exit 0 ;;
  copyto)
    echo "copyto $2 -> $3" >> "$D/uploaded_calls"
    if [ -f "$D/fail_upload" ]; then echo "ERROR : mock upload refused" >&2; exit 1; fi
    basename "$3" >> "$D/uploaded"; exit 0 ;;
  lsf)
    if [ "$(cat "$D/mode")" = after ]; then grep -E "$(cat "$D/after_grep")" "$D/uploaded"
    else cat "$D/uploaded"; fi
    exit 0 ;;
  deletefile|purge) echo "$1 $2" >> "$D/cleanup_calls"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat > "$MOCKBIN/docker" <<'EOF'
#!/bin/bash
D=/tmp/ol_reject_test/state
if [ "$1 $2" = "restart openlist" ]; then echo after > "$D/mode"; echo restarted >> "$D/restarts"; fi
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' > "$MOCKBIN/sleep"
  chmod +x "$MOCKBIN"/*
}

# 场景注入经环境变量（run_case 内 setup 完 mock 立刻跑脚本，顺序才对）:
#   AFTER_GREP  → 写进 mock 的 after_grep（restart 后 lsf 的过滤模式）
#   FAIL_UPLOAD → 触发 mock copyto 拒绝
run_case() {  # <SRC内容>
  setup_mocks
  [ -n "${AFTER_GREP:-}" ] && printf '%s' "$AFTER_GREP" > "$MOCKDIR/after_grep"
  [ -n "${FAIL_UPLOAD:-}" ] && touch "$MOCKDIR/fail_upload"
  DIAG_REPORT="$MOCKDIR/report.txt" DIAG_REJECT_SRC="$1" \
    DIAG_REJECT_MAX="${MAX_OVERRIDE:-1}" DIAG_REJECT_WAIT=120 \
    PATH="$MOCKBIN:$PATH" bash "$SCRIPT" "openlist:wopan176Crypt/2" openlist >/dev/null 2>&1
  RC=$?
}

# ── 场景 1: 空 SRC ──
run_case ""
[ "$RC" -eq 0 ] && ok "1a 空 SRC 恒 exit 0" || bad "1a: rc=$RC"
grep -q "未提供" "$MOCKDIR/report.txt" && ok "1b 报告提示未启用" || bad "1b: $(cat "$MOCKDIR/report.txt")"
grep -q "mkdir" "$MOCKDIR/uploaded_calls" 2>/dev/null && bad "1c 不该建诊断目录" || ok "1c 未建诊断目录"

# ── 公共: 单源文件场景的 SRC（含空格/括号/方括号，贴近真实形态）──
SRC='onedrive:0/1024j/视频/a b (2024) [group] file.ph.mp4'

# ── 场景 2: 内容拒收（restart 后只剩 rand）──
AFTER_GREP='rand' run_case "$SRC"
REPORT="$MOCKDIR/report.txt"
grep -q "按内容拒收坐实" "$REPORT" && ok "2a 判「按内容拒收坐实」" || bad "2a: $(grep '结论' "$REPORT" | head -2 | tr '\n' ' ')"
grep -q "变量只剩内容" "$REPORT" && ok "2b 点明内容变量（对照 C 存活）" || bad "2b"
grep -q 'B\[0\] 可见→可见→缺失' "$REPORT" && ok "2c B 组 trace 呈经典蒸发形态" || bad "2c: $(grep 'B\[0\]' "$REPORT" | head -1)"

# ── 场景 3: 改名可绕（restart 后留 ren + rand，原名蒸发）──
AFTER_GREP='rand|oldiag_ren_' run_case "$SRC"
grep -q "按文件名/状态拒收" "$MOCKDIR/report.txt" && ok "3a 判「按文件名/状态拒收」" || bad "3a"
grep -q "改名可绕过" "$MOCKDIR/report.txt" && ok "3b 给出改名可绕的修法方向" || bad "3b"
grep -q "原名（或其既有状态）就是触发因素" "$MOCKDIR/report.txt" && ok "3c 点明原名触发" || bad "3c"

# ── 场景 4: 通路异常（restart 后全空）──
AFTER_GREP='^NOMATCH$' run_case "$SRC"
grep -q "通路/目录异常" "$MOCKDIR/report.txt" && ok "4a 判「通路异常，实验作废」" || bad "4a"

# ── 场景 5: 全部存活（restart 后全留）──
AFTER_GREP='.' run_case "$SRC"
grep -q "按文件名/状态拒收" "$MOCKDIR/report.txt" && ok "5a 判「改名可绕」" || bad "5a"
grep -q "未复现" "$MOCKDIR/report.txt" && ok "5b 附注 V3 现象未复现" || bad "5b: $(grep '结论' "$MOCKDIR/report.txt" | tr '\n' ' ')"

# ── 场景 6: 上传全被拒 ──
FAIL_UPLOAD=1 run_case "$SRC"
grep -q "受理层被拒" "$MOCKDIR/report.txt" && ok "6a 判「受理层失败」而非误判" || bad "6a: $(grep '结论' "$MOCKDIR/report.txt" | tr '\n' ' ')"

# ── 产物形态核验（重跑一次拿 mock 状态）──
setup_mocks
DIAG_REPORT="$MOCKDIR/report.txt" DIAG_REJECT_SRC="$SRC" PATH="$MOCKBIN:$PATH" \
  bash "$SCRIPT" "openlist:wopan176Crypt/2" openlist >/dev/null 2>&1
# A 组必须用原名（空格/括号/方括号原样、oldiag_reject_ 目录下）
grep -qE 'oldiag_reject_[0-9]+_[0-9]+/a b \(2024\) \[group\] file\.ph\.mp4$' "$MOCKDIR/uploaded_calls" \
  && ok "7a A 组走原名直传" || bad "7a: $(grep copyto "$MOCKDIR/uploaded_calls" | head -2 | tr '\n' ' ')"
# B 组必须 oldiag_ren_0_<ts>.mp4（保留原扩展名）
grep -qE 'oldiag_reject_[0-9]+_[0-9]+/oldiag_ren_0_[0-9]+\.mp4$' "$MOCKDIR/uploaded_calls" \
  && ok "7b B 组改名保留原扩展名" || bad "7b"
# C 载荷字节数 = size 返回的 1024
[ "$(stat -c%s /tmp/ol_diag/reject_rand.bin 2>/dev/null)" = "1024" ] \
  && ok "7c C 载荷与源同字节数（1024）" || bad "7c: $(stat -c%s /tmp/ol_diag/reject_rand.bin 2>/dev/null)"
# 容器确实被重启过（真值口径）
grep -q restarted "$MOCKDIR/restarts" 2>/dev/null && ok "7d 真值复核前重启了容器" || bad "7d: 未重启"
# 清理: 有 deletefile/purge 调用
grep -q "purge" "$MOCKDIR/cleanup_calls" 2>/dev/null && ok "7e 收尾清了诊断目录" || bad "7e: 无 purge"

echo ""
echo "=== diag_reject: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
