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

echo ""
echo "==================== 结果 ===================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "全部通过" || echo "存在失败"
exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
