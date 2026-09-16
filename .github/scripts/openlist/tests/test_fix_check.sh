#!/bin/bash
# fix_check.sh（修复能力定点验证驱动）—— 逻辑验证（纯 bash mock，无容器）
#
# 覆盖:
#   1. 清单解析: 密文名后缀命中定位；**未命中的条目必须显式报 not_found**（不能静默丢弃）
#   2. already_ok 短路: 目标端原路径已在 / marker 已记账 ⇒ 不调 try_fix_failed_file
#   3. 真值复核: 通过 ⇒ fixed + 写 marker；失败 ⇒ fake_success + **不写** marker
#   4. **叶子同步单元**: 按已有 marker 反查（生产 auto-split 逐层 `task_sub` 命名）；
#      无 marker 时按最深目录推定；marker 记账落在**叶子 marker**（不是任务根 marker）
#   5. 黑名单重置: 叶子 marker 里该文件的键被删、**其它键保留**；关掉开关时保留
#   6. VERDICT 行格式: 固定 6 段，字段内 `|`/换行被清洗（否则逐行 grep 会错位）
#   7. 退出码三态（0 / 1 / 2）+ diff 模式候选推导
#
# 手法: 脚本按 `GITHUB_WORKSPACE` 找 `load_all.sh` ⇒ 造一个**假 workspace**，里面放
#   stub `load_all.sh`（只提供脚本需要的那层 API，含**真实规则**的 get_marker_path）；
#   `rclone` 与 `docker` 分别用导出函数 / 假可执行文件 mock。
#   这样跑的是**真实控制流**（含退出码与汇总），不需要容器。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SCRIPT="$_REPO_ROOT/.github/scripts/openlist/fix_check.sh"

WORK="/tmp/fixcheck_test"
rm -rf "$WORK"; mkdir -p "$WORK"
WS="$WORK/ws"; mkdir -p "$WS/.github/scripts/openlist"
OUT="$WORK/out"; MOCK="$WORK/mock"; STATE="$WORK/state"
mkdir -p "$MOCK" "$STATE"
# 假 docker: 脚本用 `command -v docker` 决定是否做真值复核
BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/docker"; chmod +x "$BIN/docker"
export PATH="$BIN:$PATH"

SRC_BASE="onedrive:5/1024j-视频-pornhub-channel"
DST_BASE="openlist:wopan176Crypt/5/1024j-视频-pornhub-channel"
SUB="1024j-视频-pornhub-channel"
LEAF_DIR="kate-bloom"
F1="$LEAF_DIR/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4"
F2="rolakiki/A cute maid who provides pornographic services to the host-ph5f12b2166785f.mp4"
R1="$SUB/$F1"          # 相对任务根的路径
R2="$SUB/$F2"
LEAF_TASK="task5_${SUB}_${LEAF_DIR}"                       # 生产规则: ${task}_${subdir//\//_}
LEAF_DST="openlist:wopan176Crypt/5/${SUB}/${LEAF_DIR}"

# 生产同款 marker 命名: <task>_<md5(task_dest)[0:8]>.json（sync_marker.sh:24-30）
marker_path() { printf '%s/%s_%s.json' "$STATE" "$1" "$(printf '%s' "$1_$2" | md5sum | cut -c1-8)"; }
LEAF_MARKER="$(marker_path "$LEAF_TASK" "$LEAF_DST")"
ROOT_MARKER="$(marker_path "task5" "openlist:wopan176Crypt/5")"

# ============================================================
# stub load_all.sh
# ============================================================
cat > "$WS/.github/scripts/openlist/load_all.sh" <<STUB
SYNC_TASK_REGISTRY=(
  "task5|onedrive:5|openlist:wopan176Crypt/5|task5|--auto-split --1d-skip"
)
declare -A FIX_METHOD_BLACKLIST=()
SYNC_STATE_DIR="$STATE"
get_marker_path() { printf '%s/%s_%s.json' "\$SYNC_STATE_DIR" "\$1" "\$(printf '%s' "\$1_\$2" | md5sum | cut -c1-8)"; }
_marker_write() { printf '%s' "\$1" > "\$2"; }
_ensure_crypt_config() { return 1; }
_raw_count_view_for() { echo "\$1"; }
_raw_remote_for() { echo "\$1"; }
_rebuild_raw_baseline() { _RAW_VERIFY_BUDGET=0; return 1; }
format_bytes() { printf '%sB' "\$1"; }
_fix_method_short() { printf '%s' "\${1:-}"; }
_fix_event() { :; }
_fix_event_fail() { :; }
_get_openlist_token() { echo ""; }
_sync_restart_for_verify() { return "\${FC_MOCK_RESTART_RC:-0}"; }
_persist_verify_entries() {
  PERSIST_IDX=\$(grep -c . "\$2" 2>/dev/null || true)
  PERSIST_OK=0; PERSIST_FAIL=0; PERSIST_FAILED_ORIGS=()
  if [ "\${FC_MOCK_VERIFY_FAIL_ALL:-0}" = "1" ]; then
    PERSIST_FAIL="\$PERSIST_IDX"
    while IFS='|' read -r _a _b _o _m _mid; do
      [ -n "\$_a" ] && PERSIST_FAILED_ORIGS+=("\$_o")
    done < "\$2"
  else
    PERSIST_OK="\$PERSIST_IDX"
  fi
}
_persist_fix_entry_now() {
  # 第 11/10 个位置参数必须写成花括号形式（单位数写法会被解析成"第一个参数后面跟个 1"）；
  # 本 heredoc 未加引号 ⇒ 连花括号前的美元符也要反斜杠转义，否则测试 shell 当场展开
  printf 'MARKER|%s|%s|%s|%s|%s|%s\n' "\$1" "\$5" "\$6" "\${11}" "\$9" "\${10}" >> "\$FC_TEST_MARKER_WRITES"
}
try_fix_failed_file() {
  printf '%s\n' "\$4" >> "\$FC_TEST_TRY_CALLS"
  TRY_FIX_STATUS="\${FC_MOCK_TRY_STATUS:-failed}"
  TRY_FIX_ORIGINAL="\$4"
  TRY_FIX_ALTERNATIVE="\${FC_MOCK_TRY_ALT:-}"
  TRY_FIX_METHOD="\${FC_MOCK_TRY_METHOD:-rclone copyto（测试）}"
  TRY_FIX_METHOD_ID="\${FC_MOCK_TRY_MID:-copyto_original}"
  TRY_FIX_RESTORE="\${FC_MOCK_TRY_RESTORE:-rclone move（测试）}"
  TRY_FIX_MESSAGE="\${FC_MOCK_TRY_MSG:-所有修复方法均失败}"
  TRY_FIX_MD5=""
}
STUB

# ============================================================
# rclone mock（导出函数，子进程可见）
# ============================================================
rclone() {
  case "$1" in
    lsf)
      case "$*" in
        *"$FC_MOCK_SRC"*)
          case "$*" in
            *"-R"*) cat "$FC_MOCK_SRC_LIST" 2>/dev/null ;;
            *)      cat "$FC_MOCK_SRC_LIST_NONREC" 2>/dev/null ;;
          esac ;;
        *"$FC_MOCK_DST"*) cat "$FC_MOCK_DST_LIST" 2>/dev/null ;;
        # state 目录在测试里是**真实本地目录**（marker 文件真的建在那里）⇒ 直接列它
        *) ls -1 "$2" 2>/dev/null ;;
      esac ;;
    size)
      local p="${3:-}" b
      b=$(awk -v p="$p" -F'\t' '$1==p{print $2; exit}' "$FC_MOCK_SIZES" 2>/dev/null)
      printf '{"bytes":%s}\n' "${b:-0}" ;;
    cat) cat "$2" 2>/dev/null ;;
    *) return 0 ;;
  esac
}
export -f rclone

# ============================================================
# 场景脚手架
# ============================================================
reset_case() {
  rm -rf "$OUT" "$STATE"; mkdir -p "$OUT" "$STATE"
  : > "$MOCK/src.lsf"; : > "$MOCK/dst.lsf"; : > "$MOCK/sizes.tsv"
  : > "$MOCK/src_nonrec.lsf"
  : > "$MOCK/try_calls"; : > "$MOCK/marker_writes"
  export FC_MOCK_SRC="$SRC_BASE" FC_MOCK_DST="$DST_BASE"
  export FC_MOCK_SRC_LIST="$MOCK/src.lsf" FC_MOCK_DST_LIST="$MOCK/dst.lsf"
  export FC_MOCK_SRC_LIST_NONREC="$MOCK/src_nonrec.lsf"
  export FC_MOCK_SIZES="$MOCK/sizes.tsv"
  export FC_TEST_TRY_CALLS="$MOCK/try_calls" FC_TEST_MARKER_WRITES="$MOCK/marker_writes"
  export FIXCHECK_WORK_DIR="$OUT" GITHUB_WORKSPACE="$WS" FIXCHECK_CONTAINER=openlist
  export FIXCHECK_MODE=list FIXCHECK_TASK=task5 FIXCHECK_SUBDIR="$SUB"
  export FIXCHECK_MAX=10 FIXCHECK_RESET_BLACKLIST=1 FIXCHECK_TRUTH_RESTART=1
  export FIXCHECK_FILES=""
  unset FC_MOCK_TRY_STATUS FC_MOCK_TRY_ALT FC_MOCK_TRY_MSG FC_MOCK_VERIFY_FAIL_ALL \
        FC_MOCK_RESTART_RC 2>/dev/null || true
}
run_case() {
  RC=0
  bash "$SCRIPT" > "$WORK/run.log" 2>&1 || RC=$?
  VERDICTS="$OUT/verdicts.txt"
}
verdict_of() { grep -h '^VERDICT|' "$VERDICTS" 2>/dev/null | grep -F "|$1|" | head -1; }
set_size() { printf '%s\t%s\n' "$1" "$2" >> "$MOCK/sizes.tsv"; }
# 建一个"该叶子单元已存在"的 marker（叶子反查靠它命中）
mk_marker() {  # <marker 路径> <JSON>
  printf '%s' "$2" > "$1"
}

# ============================================================
# 场景1: 清单解析 —— 后缀命中 + 未命中条目显式报 not_found
# ============================================================
reset_case
printf '%s\n' "$F1" "$F2" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/$LEAF_DIR/$F1" 0
export FIXCHECK_FILES=$'ph5ebc05eca6793\nno-such-file-xyz'
export FC_MOCK_TRY_STATUS=failed FC_MOCK_TRY_MSG="目标目录不可写（测试）"
run_case
[ "$(grep -c . "$MOCK/try_calls")" = "1" ] && ok "1a 后缀命中 1 个候选（另一条目未命中不参与修复）" || bad "1a: try=$(tr '\n' ' ' < "$MOCK/try_calls")"
grep -qF "清单条目在源端未匹配到任何文件" "$VERDICTS" && ok "1b 未命中条目显式报 not_found（不静默丢弃）" || bad "1b: $(cat "$VERDICTS")"
[ "$RC" = "2" ] && ok "1c 有 not_found ⇒ 退出码 2" || bad "1c: rc=$RC"

# ============================================================
# 场景2: 叶子单元反查 + already_ok 两种短路
# ============================================================
# 2a: 无 marker ⇒ 按最深目录推定（首次处理的单元）
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
export FIXCHECK_FILES="ph5ebc05eca6793" FC_MOCK_TRY_STATUS=failed
run_case
grep -q "按最深目录推定" "$WORK/run.log" && ok "2a 无 marker ⇒ 叶子单元按最深目录推定" || bad "2a: $(grep -c 叶子单元 "$WORK/run.log")"
grep -qF "$LEAF_DST" "$WORK/run.log" && ok "2b 叶子 dest 正确（任务根 + 子路径 + 叶子目录）" || bad "2b: $(grep -m1 叶子单元 "$WORK/run.log")"

# 2c: 有 marker ⇒ 按 marker 反查命中该单元
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 1000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
mk_marker "$LEAF_MARKER" '{}'
export FIXCHECK_FILES="ph5ebc05eca6793" FC_MOCK_TRY_STATUS=failed
run_case
grep -q "按已有 marker 反查" "$WORK/run.log" && ok "2c 有 marker ⇒ 叶子单元按 marker 反查（= 生产实际用过的单元）" || bad "2c: $(grep -m1 叶子单元 "$WORK/run.log")"

# 2d: 目标端原路径已在 ⇒ 不调用修复
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 258000000
export FIXCHECK_FILES="ph5ebc05eca6793"
run_case
[ "$(grep -c . "$MOCK/try_calls")" = "0" ] && ok "2d 原路径已在 ⇒ 不调用修复（幂等）" || bad "2d: try=$(tr '\n' ' ' < "$MOCK/try_calls")"
verdict_of "$R1" | grep -q 'already_ok' && ok "2e 结论 already_ok" || bad "2e: $(verdict_of "$R1")"

# 2f: marker 已记账（alternative 形态落盘）⇒ 不重复上传
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
mk_marker "$LEAF_MARKER" "$(jq -cn --arg o "OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" \
  '{fixed_files:[{original:$o,alternative:"abc12345.mp4"}]}')"
export FIXCHECK_FILES="ph5ebc05eca6793"
run_case
[ "$(grep -c . "$MOCK/try_calls")" = "0" ] && ok "2f marker 已记账 ⇒ 不重复上传（防幽灵文件）" || bad "2f: try=$(tr '\n' ' ' < "$MOCK/try_calls")"
[ "$RC" = "0" ] && ok "2g 退出码 0" || bad "2g: rc=$RC"

# ============================================================
# 场景3: 真值复核失败 ⇒ fake_success 且不写 marker
# ============================================================
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
export FIXCHECK_FILES="ph5ebc05eca6793"
export FC_MOCK_TRY_STATUS=success FC_MOCK_TRY_ALT="abc123.mp4" FC_MOCK_VERIFY_FAIL_ALL=1
run_case
verdict_of "$R1" | grep -q 'fake_success' && ok "3a 复核未通过 ⇒ fake_success" || bad "3a: $(verdict_of "$R1")"
[ ! -s "$MOCK/marker_writes" ] && ok "3b 假成功不写 marker（先验后写）" || bad "3b: 误写 $(cat "$MOCK/marker_writes")"
[ "$RC" = "1" ] && ok "3c 有 fake_success ⇒ 退出码 1" || bad "3c: rc=$RC"

# ============================================================
# 场景4: 复核通过 ⇒ fixed + 记账落在**叶子 marker**
# ============================================================
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 258000000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
export FIXCHECK_FILES="ph5ebc05eca6793"
export FC_MOCK_TRY_STATUS=success FC_MOCK_TRY_ALT="abc123.mp4" FC_MOCK_TRY_MID=copyto_shorthash
run_case
verdict_of "$R1" | grep -q 'fixed' && ok "4a 复核通过 ⇒ fixed" || bad "4a: $(verdict_of "$R1")"
grep -qF "MARKER|$LEAF_MARKER|OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4|abc123.mp4|copyto_shorthash|258000000B|258000000" "$MOCK/marker_writes" \
  && ok "4b 记账落在**叶子 marker**（生产下轮才认账，否则会重传）" || bad "4b: $(cat "$MOCK/marker_writes")"
grep -qF "$ROOT_MARKER" "$MOCK/marker_writes" && bad "4c 误写到任务根 marker" || ok "4c 未误写任务根 marker"
[ "$RC" = "0" ] && ok "4d 退出码 0" || bad "4d: rc=$RC"

# ============================================================
# 场景5: 黑名单重置（叶子 marker 粒度）
# ============================================================
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 1000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
mk_marker "$LEAF_MARKER" "$(jq -cn \
  '{dest_path:"openlist:wopan176Crypt/5/'"${SUB}/${LEAF_DIR}"'",
    fix_blacklist:{"OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4":"修复方法2|修复方法4","other.mp4":"修复方法1"}}')"
export FIXCHECK_FILES="ph5ebc05eca6793" FC_MOCK_TRY_STATUS=failed
run_case
_bk=$(jq -r '.fix_blacklist | keys | join(",")' "$LEAF_MARKER" 2>/dev/null)
[ "$_bk" = "other.mp4" ] && ok "5a 重置: 该文件键被删、其它键保留" || bad "5a: keys=[$_bk]"

reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 1000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
mk_marker "$LEAF_MARKER" "$(jq -cn '{fix_blacklist:{"OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4":"修复方法2"}}')"
export FIXCHECK_FILES="ph5ebc05eca6793" FIXCHECK_RESET_BLACKLIST=0 FC_MOCK_TRY_STATUS=failed
run_case
_bk=$(jq -r '.fix_blacklist | keys | join(",")' "$LEAF_MARKER" 2>/dev/null)
[ "$_bk" = "OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" ] && ok "5b 关闭重置 ⇒ 黑名单原样保留" || bad "5b: keys=[$_bk]"

# ============================================================
# 场景6: VERDICT 行格式 + 字段清洗
# ============================================================
reset_case
printf '%s\n' "$F1" > "$MOCK/src.lsf"
set_size "$SRC_BASE/$F1" 1000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
export FIXCHECK_FILES="ph5ebc05eca6793"
export FC_MOCK_TRY_STATUS=failed FC_MOCK_TRY_MSG=$'目标目录不可写|含分隔符\n第二行'
run_case
_nf=$(awk -F'|' 'NF!=6' "$VERDICTS" | grep -c . || true)
[ "$_nf" = "0" ] && ok "6a VERDICT 恒为 6 段（字段内 | 与换行已清洗）" || bad "6a: $(awk -F'|' 'NF!=6' "$VERDICTS")"
grep -q '目标目录不可写/含分隔符' "$VERDICTS" && ok "6b 原因字段清洗后可 grep" || bad "6b: $(cat "$VERDICTS")"

# ============================================================
# 场景7: diff 模式候选推导
# ============================================================
reset_case
export FIXCHECK_MODE=diff FIXCHECK_FILES=""
printf '%s\n' "$F1" "$F2" "$LEAF_DIR/already-there.mp4" > "$MOCK/src.lsf"
printf '%s\n' "$LEAF_DIR/already-there.mp4" > "$MOCK/dst.lsf"
set_size "$SRC_BASE/$F1" 1000
set_size "$LEAF_DST/OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4" 0
set_size "$SRC_BASE/$F2" 1000
export FC_MOCK_TRY_STATUS=failed
run_case
_calls=$(tr '\n' ' ' < "$MOCK/try_calls")
case "$_calls" in
  *"OnlyTeenBlowjobs - Cute Teen Is Not So Innocent-ph5ebc05eca6793.mp4"*) ok "7a diff: 源端有·目标端无 ⇒ 进候选" ;;
  *) bad "7a: calls=[$_calls]" ;;
esac
case "$_calls" in
  *"already-there.mp4"*) bad "7b 目标端已有的文件不该进候选: [$_calls]" ;;
  *) ok "7b diff: 目标端已有的文件已排除" ;;
esac

# ============================================================
# 场景8: 环境/参数错误 ⇒ 退出码 2
# ============================================================
reset_case
export FIXCHECK_TASK=no-such-task FIXCHECK_FILES="x"
run_case
[ "$RC" = "2" ] && ok "8a 未知任务 id ⇒ 退出码 2" || bad "8a: rc=$RC"
grep -q "未知任务 id" "$WORK/run.log" && ok "8b 日志列出可用 id（便于修正）" || bad "8b: $(tail -3 "$WORK/run.log")"

# ============================================================
# 场景9: 源端列举为空时必须能区分"列举失败"与"路径不存在"
#   2026-09-16 实测: 主轮同时在读同一 OneDrive 时列举被限流，错误被 /dev/null 吞掉，
#   表现为"0 个文件"，与"路径写错"长得一模一样，白排查一轮 ⇒ 锁住这个可观测性
# ============================================================
reset_case
printf '%s\n' "$LEAF_DIR" > "$MOCK/src_nonrec.lsf"      # 非递归有内容 ⇒ 列举失败
export FIXCHECK_FILES="ph5ebc05eca6793"
run_case
[ "$RC" = "2" ] && ok "9a 递归列举为空 ⇒ 退出码 2" || bad "9a: rc=$RC"
grep -q "列举失败" "$WORK/run.log" && ok "9b 报"列举失败"并给处置建议（不是静默 0 命中）" || bad "9b: $(grep -m1 源端 "$WORK/run.log")"

reset_case
export FIXCHECK_FILES="ph5ebc05eca6793"                   # 非递归也空 ⇒ 路径不对
run_case
[ "$RC" = "2" ] && ok "9c 路径不存在 ⇒ 退出码 2" || bad "9c: rc=$RC"
grep -q "源端路径不存在或不可读" "$WORK/run.log" && ok "9d 明确指向路径拼写" || bad "9d: $(grep -m1 源端 "$WORK/run.log")"

# ============================================================
# 场景10: rclone 参数形态回归锁（2026-09-16 实跑踩到两个真 bug）
#   · `--retry` **不是** rclone 的 flag（正确 `--retries`）⇒ 列举 rc=2 静默失败
#   · `--timeout` 要求**带单位**；workflow 注入的 OPENLIST_RCLONE_LISTING_TIMEOUT
#     曾是裸 "900" ⇒ 生产的折叠落盘列举**全部失败**、折叠成果从未记账（幽灵落盘）
# ============================================================
grep -q 'OPENLIST_RCLONE_LISTING_TIMEOUT: "900s"' "$_REPO_ROOT/.github/workflows/openlist.yml" \
  && ok "10a workflow 注入值带单位（900s）" || bad "10a: $(grep -n OPENLIST_RCLONE_LISTING_TIMEOUT "$_REPO_ROOT/.github/workflows/openlist.yml" | head -2 | tr '\n' ' ')"
# 只查**非注释行**（沿革注释里会引用旧写法），并排除本测试自身（断言里含这些字符串）
_n=$(grep -rn 'LISTING_TIMEOUT:-900}' "$_REPO_ROOT/.github/scripts/openlist/" 2>/dev/null \
     | grep -v 'tests/test_fix_check.sh' | grep -vE ':[0-9]+: *#' | wc -l | tr -d ' ')
[ "$_n" = "0" ] && ok "10b 脚本内无裸数字兜底（rclone --timeout 会失败）" || bad "10b: ${_n} 处裸数字（$(grep -rn 'LISTING_TIMEOUT:-900}' "$_REPO_ROOT/.github/scripts/openlist/" | grep -v test_fix_check | head -2 | tr '\n' ' ')）"
_bad=$(grep -nE -- '--retry [0-9]' "$SCRIPT" | grep -vE '^[0-9]+: *#' | head -2 | tr '\n' ' ')
[ -z "$_bad" ] && ok "10c 用 --retries（合法 flag），无 --retry" || bad "10c 仍用 --retry: ${_bad}"

echo "-----------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
