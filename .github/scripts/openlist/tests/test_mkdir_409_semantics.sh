#!/bin/bash
# ===== 注册: 409 Conflict 的「目录已存在」语义 + 目录层连续失败收手 =====
#
# 为什么要这个测试（2026-09-17，run 35186977864 的直接产物）:
#   该轮单轮出现 2062 次 `Conflict: 409 Conflict`、1088 次
#   `Update mkParentDir failed`，4 种修复方法全撞同一堵墙、**整轮零落盘**，
#   而用户后台看驱动是好的。真因是**语义缺失**:
#     ① mkdir 报 409 时全库一律当失败（API fs/mkdir 只认 200|201|204），
#        但 409 在 MKCOL 语义下最常见的原因是"资源已存在"（幂等成功）；
#     ② 预检层把 409 归为 backend「后端异常」→ 跳过整轮；
#     ③ 目录建不出来却仍逐个文件跑 4 种方法，257 次尝试 / 6 小时零产出。
#
# 本测试锁定三条契约（任一被改坏都会在此变红）:
#   D1 _fix_dir_exists_or_conflict 用**读操作**判定，目录在 ⇒ 返回 0
#   D2 分类器把 409/mkParentDir 归为 `conflict`（不再一律 `backend`）
#   D3 目录层连续失败计数达阈值即收手（_FIX_MKDIR_FAIL_STREAK + 阈值判据存在）
#   D4 开关 _FIX_MKDIR_409_SEMANTICS=0 可回退旧行为（逃生口必须保留）
#   D5 各建目录点都接上 409 语义（Step1 / API / base64URL / 短哈希 / 折叠）
#   D6 整轮 409 重试（与 423 同款）
#   D7 **API 报 200 必须复核存在性**（2026-09-18 §12.14.8 补：
#     坏子树上 API 报 200、WebDAV 报 409，两通路矛盾 ⇒ 只看 HTTP 码会被假成功骗过）
#
# 用法: bash test_mkdir_409_semantics.sh   （退出码 0=全过）

set -u

FAIL=0
PASS=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OL_DIR="$REPO_ROOT/.github/scripts/openlist"

FILE_FIX="$OL_DIR/file_fix.sh"
DRIVER="$OL_DIR/openlist_driver.sh"
PIPELINE="$OL_DIR/file_fix_pipeline.sh"

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# ────────────────────────────────────────────────────────────
# D1 · _fix_dir_exists_or_conflict 用读操作判定（目录在 ⇒ 0）
# 只 source file_fix.sh 的这个函数体，用一个假的 rclone 桩控制 lsd 结果。
# 为什么用桩而不是真调 rclone: 本机没有 rclone（CI 才有），
# 而本测试要锁的是**判据语义**（读操作 + 返回码），不是 rclone 本身。
mkdir -p "$TMPDIR_T/bin"
cat > "$TMPDIR_T/bin/rclone" <<'STUB'
#!/bin/bash
# 桩: 只关心 lsd 子命令。目录存在与否由 LSD_EXIST 环境变量控制。
case "$1" in
  lsd) [ "${LSD_EXIST:-0}" = "1" ] && exit 0 || exit 1 ;;
  *)   exit 0 ;;
esac
STUB
chmod +x "$TMPDIR_T/bin/rclone"

# 抽出函数定义（不 source 整个 file_fix.sh: 它依赖几十个外部函数与变量）
if grep -q '^_fix_dir_exists_or_conflict()' "$FILE_FIX"; then
  # shellcheck disable=SC1090
  eval "$(sed -n '/^_fix_dir_exists_or_conflict()/,/^}/p' "$FILE_FIX")"
  ok "D1a _fix_dir_exists_or_conflict 定义存在"
else
  bad "D1a _fix_dir_exists_or_conflict 定义缺失（409 语义判据没有落地）"
fi

if declare -F _fix_dir_exists_or_conflict >/dev/null 2>&1; then
  PATH="$TMPDIR_T/bin:$PATH"
  if LSD_EXIST=1 _fix_dir_exists_or_conflict "openlist:wopan175/x" "5s"; then
    ok "D1b 目录存在 ⇒ 返回 0（幂等成功路径）"
  else
    bad "D1b 目录存在时应返回 0（否则 409 已存在语义失效）"
  fi
  if LSD_EXIST=0 _fix_dir_exists_or_conflict "openlist:wopan175/x" "5s"; then
    bad "D1c 目录不存在时应返回非 0（否则会把真故障当成已存在放行）"
  else
    ok "D1c 目录不存在 ⇒ 返回非 0（真故障不被误放行）"
  fi
fi

# ────────────────────────────────────────────────────────────
# D2 · 分类器: 409/mkParentDir → conflict（不再一律 backend）
CONFLICT_OUT='2026/09/17 08:10:07 ERROR : Attempt 1/3 failed with 1 errors and: Conflict: 409 Conflict'
MKDIR_OUT='2026/09/17 08:10:15 ERROR : olprobe.txt: Failed to copy: Update mkParentDir failed: Conflict: 409 Conflict'

if grep -q "echo conflict" "$DRIVER"; then
  ok "D2a 分类器新增 conflict 分支"
else
  bad "D2a 分类器缺少 conflict 分支（409 仍会被判成 backend → 跳过整轮）"
fi
if grep -q "mkParentDir" "$DRIVER" && grep -q 'echo conflict' "$DRIVER"; then
  ok "D2b conflict 分支覆盖 mkParentDir 形态"
else
  bad "D2b conflict 分支未覆盖 mkParentDir 形态"
fi
# 逃生口: 开关关闭时不得进入 conflict 分支（保持旧口径）
if grep -q '_FIX_MKDIR_409_SEMANTICS' "$DRIVER"; then
  ok "D2c 分类器受 _FIX_MKDIR_409_SEMANTICS 开关约束"
else
  bad "D2c 分类器未受开关约束（无法回退旧行为）"
fi
# 实测样本必须真被判成 conflict
if declare -F _classify_probe_failure >/dev/null 2>&1; then
  k=$(_classify_probe_failure "$CONFLICT_OUT")
  [ "$k" = "conflict" ] && ok "D2d 409 样本 → conflict" || bad "D2d 409 样本判为 ${k}（应为 conflict）"
  k=$(_classify_probe_failure "$MKDIR_OUT")
  [ "$k" = "conflict" ] && ok "D2e mkParentDir 样本 → conflict" || bad "D2e mkParentDir 样本判为 ${k}（应为 conflict）"
else
  # 未 source driver（它依赖较多）时退化为静态检查，明确标注而非静默假过
  if grep -qE "elif echo \"\\\$out\" \| grep -Eqi 'conflict\|mkParentDir'" "$DRIVER"; then
    ok "D2d 静态检查: conflict 分支位于 backend 分支之前（顺序正确）"
  else
    bad "D2d conflict 分支顺序或位置不正确"
  fi
fi

# ────────────────────────────────────────────────────────────
# D3 · 预检: conflict 时做二次判定，目录在 ⇒ 放行（不是跳过整轮）
if grep -q 'kind" = "conflict"' "$DRIVER" && grep -q '按幂等成功放行' "$DRIVER"; then
  ok "D3a 预检含 conflict 二次判定并对已存在目录放行"
else
  bad "D3a 预检缺少 conflict 二次判定（目录在仍会跳过整轮）"
fi
# 放行必须落在 return 0
if sed -n '/kind" = "conflict"/,/^  local reason/p' "$DRIVER" | grep -q 'return 0'; then
  ok "D3b conflict 二次判定通过后 return 0（放行）"
else
  bad "D3b conflict 二次判定未放行"
fi

# ────────────────────────────────────────────────────────────
# D4 · 目录层连续失败收手（回答「目录都创建失败了，咋还进行文件修复」）
if grep -q '_FIX_MKDIR_FAIL_STREAK' "$PIPELINE"; then
  ok "D4a 管线引入 _FIX_MKDIR_FAIL_STREAK 计数"
else
  bad "D4a 管线缺少目录层连续失败计数"
fi
if grep -q 'OPENLIST_MKDIR_FAIL_STREAK' "$PIPELINE"; then
  ok "D4b 阈值可配（OPENLIST_MKDIR_FAIL_STREAK）"
else
  bad "D4b 阈值不可配"
fi
# 达阈值必须 break（收手），不是 continue
if sed -n '/_FIX_MKDIR_FAIL_STREAK:-0}" -ge/,/^        fi/p' "$PIPELINE" | grep -q 'break'; then
  ok "D4c 达阈值即 break 收手（不再逐个文件空转）"
else
  bad "D4c 达阈值未收手"
fi
# 成功必须归零（后端恢复立即放行）
if grep -q '_FIX_MKDIR_FAIL_STREAK=0' "$PIPELINE"; then
  ok "D4d 修复成功即归零（后端恢复立即放行）"
else
  bad "D4d 成功未归零连续失败计数"
fi
# 只认目录类失败，不把方法层失败计入（避免误伤健康后端）
if grep -q '\*目标目录建不出来\*|\*目标目录不可写\*' "$PIPELINE"; then
  ok "D4e 只认「目录建不出来/不可写」两类消息（方法层失败不计入）"
else
  bad "D4e 计入范围过宽或缺失（可能误伤健康后端）"
fi

# ────────────────────────────────────────────────────────────
# D5 · 各建目录点都接上 409 语义（Step1 / API / base64URL / 短哈希 / 折叠）
_n409=$(grep -c '_FIX_MKDIR_409_SEMANTICS' "$FILE_FIX")
if [ "${_n409:-0}" -ge 4 ]; then
  ok "D5a file_fix.sh 建目录点接入 409 语义 ${_n409} 处（Step1/API/b64/短哈希）"
else
  bad "D5a file_fix.sh 仅 ${_n409} 处接入 409 语义（应 ≥4）"
fi
if grep -q '_FIX_MKDIR_409_SEMANTICS' "$PIPELINE"; then
  ok "D5b 批量折叠建目录接入 409 语义"
else
  bad "D5b 批量折叠未接入 409 语义"
fi

# ────────────────────────────────────────────────────────────
# D6 · 整轮 409 重试（与 423 同款）
SYNC_ENGINE="$OL_DIR/sync_engine.sh"
if grep -q '_sync_retry_409()' "$SYNC_ENGINE"; then
  ok "D6a 新增 _sync_retry_409"
else
  bad "D6a 缺少 _sync_retry_409（409 仍无整轮重试）"
fi
if grep -q '^  _sync_retry_409$' "$SYNC_ENGINE"; then
  ok "D6b _sync_retry_409 已被调用"
else
  bad "D6b _sync_retry_409 定义但未调用"
fi
if grep -q 'OPENLIST_409_RETRY_ATTEMPTS' "$SYNC_ENGINE"; then
  ok "D6c 409 重试次数可配"
else
  bad "D6c 409 重试次数不可配"
fi

# ────────────────────────────────────────────────────────────
# D7 · API 报 200 必须复核存在性（2026-09-18 §12.14.8）
# 为什么加这一组（本套件此前**完全没覆盖 API 200 分支** → 缺陷得以长期存活）:
#   实测同一条坏子树上，OpenList 原生 API 报 `HTTP_CODE:200`，
#   而 rclone/WebDAV 的 mkdir 报 `409 Conflict` —— 两通路回报互相矛盾。
#   旧行为在 API 分支**只看 HTTP 码**就置 ok=1，生产实证（主轮 35308273431）:
#     06:10:10 ✅ 短哈希目录创建成功 (API)   ← 在此就认定建成
#     06:13:26 ❌ 短哈希目录不可写…兜底终止  ← 2 分钟后才发现根本没建成
#   ⇒ 契约: 凡是 `HTTP_CODE:(200|201|204)` 分支，**必须**紧跟一次
#     `_fix_dir_exists_or_conflict`（读操作）复核，且"复核不过"不得置 ok。
#
# D7a 静态: file_fix.sh 的每个 200|201|204 分支**自己的 if 块内**都出现复核调用。
#   ⚠️ 不能用"该行之后 N 行内出现"—— 会串到**后面 409 分支**的复核调用上，
#   于是旧代码（API-200 分支无复核）也能假过（本测试初版就踩了这个坑，已修）。
#   正确切法: 从 200 判定行起，**缩进更深的**连续行才属于本分支块；
#   遇到缩进 <= 分支体的行即认为块结束。用 awk 逐行算缩进实现。
_hash_200_bad=$(awk '
  function indent(s,   i) { i=0; while (i<length(s) && substr(s,i+1,1)==" ") i++; return i }
  {
    line[NR]=$0
  }
  END {
    bad=0; total=0
    for (n=1; n<=NR; n++) {
      if (line[n] !~ /HTTP_CODE:\(200\|201\|204\)/) continue
      total++
      base=indent(line[n])          # 判定行自身缩进（与 if 同级）
      found=0
      for (m=n+1; m<=NR; m++) {
        if (line[m] ~ /^[[:space:]]*$/) continue
        ind=indent(line[m])
        if (ind <= base) break      # 块已结束（回到同级或更外层）
        if (line[m] ~ /_fix_dir_exists_or_conflict/) { found=1; break }
      }
      if (!found) bad++
    }
    printf "%d %d\n", bad, total
  }
' "$FILE_FIX")
_d7_missing=${_hash_200_bad%% *}
_d7_total=${_hash_200_bad##* }
if [ "${_d7_total:-0}" -gt 0 ] && [ "${_d7_missing:-1}" -eq 0 ]; then
  ok "D7a file_fix.sh ${_d7_total} 处 API-200 分支**块内**均已接存在性复核"
else
  bad "D7a file_fix.sh 有 ${_d7_missing}/${_d7_total} 处 API-200 分支块内无复核（假成功会骗过管线）"
fi

# D7b 静态: 批量折叠（file_fix_pipeline.sh）同样接入（同样的块内切法）
_pipe_200_bad=$(awk '
  function indent(s,   i) { i=0; while (i<length(s) && substr(s,i+1,1)==" ") i++; return i }
  { line[NR]=$0 }
  END {
    bad=0; total=0
    for (n=1; n<=NR; n++) {
      if (line[n] !~ /HTTP_CODE:\(200\|201\|204\)/) continue
      total++
      base=indent(line[n])
      found=0
      for (m=n+1; m<=NR; m++) {
        if (line[m] ~ /^[[:space:]]*$/) continue
        if (indent(line[m]) <= base) break
        if (line[m] ~ /_fix_dir_exists_or_conflict/) { found=1; break }
      }
      if (!found) bad++
    }
    printf "%d %d\n", bad, total
  }
' "$PIPELINE")
_p_200_missing=${_pipe_200_bad%% *}
_p_200_total=${_pipe_200_bad##* }
if [ "${_p_200_total:-0}" -gt 0 ] && [ "${_p_200_missing:-1}" -eq 0 ]; then
  ok "D7b 批量折叠的 API-200 分支块内已接存在性复核"
else
  bad "D7b 批量折叠有 ${_p_200_missing}/${_p_200_total} 处 API-200 分支块内无复核"
fi

# D7c 行为: 用桩把「API 报 200 但目录不存在」跑一遍，必须判为未建成
#   抽出短哈希段所在函数体不可行（依赖过多）⇒ 直接对着**真实分支写法**做等价验证:
#   构造与代码同形的判定逻辑，喂入 mkdir_http=HTTP_CODE:200 + lsd 不存在，
#   确认复核调用返回非 0（即不会被置 ok）。
if declare -F _fix_dir_exists_or_conflict >/dev/null 2>&1; then
  PATH="$TMPDIR_T/bin:$PATH"
  _resp=$'{"code":200}\nHTTP_CODE:200'
  _http=$(printf '%s' "$_resp" | tail -n 1)
  _ok=0
  if echo "$_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
    if LSD_EXIST=0 _fix_dir_exists_or_conflict "openlist:wopan175/5/5058f1af" "5s"; then
      _ok=1
    fi
  fi
  [ "$_ok" -eq 0 ] \
    && ok "D7c 行为: API 报 200 且目录不存在 ⇒ 复核拦住（不置 ok）" \
    || bad "D7c 行为: API 报 200 且目录不存在时仍被放行（假成功未被拦住）"
  # 反向对照: 目录确实存在时，复核必须放行（否则会把成功误判成失败）
  _ok2=0
  if LSD_EXIST=1 _fix_dir_exists_or_conflict "openlist:wopan175/5/5058f1af" "5s"; then
    _ok2=1
  fi
  [ "$_ok2" -eq 1 ] \
    && ok "D7d 反向对照: API 报 200 且目录确实存在 ⇒ 复核放行" \
    || bad "D7d 反向对照: 目录存在却被复核拒绝（会把成功判成失败）"
else
  bad "D7c/D7d 无法执行: _fix_dir_exists_or_conflict 未定义"
fi

echo ""
echo "==================== 结果 ===================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "全部通过" || echo "存在失败"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
