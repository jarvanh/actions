#!/bin/bash
# 修复管线两处优化 —— 逻辑验证
#   1. 密文名注定超限时跳过带原名的方法（copyto_original / zip_split_original）
#      背景: 名长诊断此前只打日志不驱动决策，密文名 150B 超过后端已接受
#      最长 100B 的文件照样先跑文件修复方法1·copyto 原名 —— 整文件下载 + PUT 全白
#      费（后端内容性拒收，重试多少次都一样）。现在诊断命中即拉黑带原名的
#      文件修复方法（copyto_original / zip_split_original），直接从对症的
#      短哈希名方法（copyto_shorthash / zip_split_shorthash）开始。
#   2. 目标端清单复用（SYNC_FIX_LIST_CACHE）
#      背景: 批次巩固 _batch_consolidate 刚做过 lsf 取真值，修复管线又全量
#      列一次目标端，同一轮内重复递归大目录数分钟。现在把清单递进去复用。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/fix.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/sync.sh" 2>/dev/null

WORK="/tmp/fixopt_test_dir"
rm -rf "$WORK"; mkdir -p "$WORK"

# --- mocks ---
timeout() { shift; "$@"; }
progress_update() { :; }
_progress_update_force() { :; }
_log_section() { :; }
tee() { cat; }              # 剥掉 tee，输出仍可见且不写文件
rclone() {
  case "$1" in
    lsf)  printf '%s' "${LSF_OUT:-}" ;;
    size) echo '{"bytes":1024,"count":1}' ;;
    mkdir) return 0 ;;
    lsd) return 0 ;;
    copyto|copy) return 0 ;;
    *) return 0 ;;
  esac
}
jq() { echo '{}'; }
curl() { echo 'HTTP_CODE:200'; echo '{"code":200,"data":{"content":[]}}'; }
_get_openlist_token() { echo fake-token; }
format_bytes() { echo "${1}B"; }
format_bytes_iec() { echo "${1}B"; }
_short_path() { echo "$1"; }
_load_marker_fixed_files() { MARKER_FIXED_COUNT=0; MARKER_FIXED_FILES="[]"; MARKER_FIX_BLACKLIST="{}"; }
_rebuild_raw_baseline() { return 0; }
_flush_blacklist_to_marker() { :; }
_restart_openlist_for_truth() { return 0; }
_persist_fix_entry_now() { :; }
_extract_filter_args() { FILTER_ARGS=(); }
get_marker_path() { echo "/tmp/marker.json"; }
# 名长探针: PROBE_LEN 控制返回长度（空 = 探针失败）
PROBE_LEN=150
_crypt_name_len_probe() { [ -n "${PROBE_LEN:-}" ] && echo "$PROBE_LEN" || return 1; }
_ensure_crypt_config() {
  _CRYPT_ONTHEFLY=":crypt,remote=openlist:wopan176:"
  _CRYPT_REMOTE="openlist:wopan176"
  return 0
}
_crypt_diag() { :; }

# try_fix_failed_file 记录被尝试/被跳过的方法（验证门禁实际生效）
TRY_LOG="$WORK/tried.log"
try_fix_failed_file() {
  echo "ATTEMPT|$3|${FIX_METHOD_BLACKLIST[$3]:-}" >> "$TRY_LOG"
  TRY_FIX_STATUS="success"
  TRY_FIX_ORIGINAL="$3"
  TRY_FIX_ALTERNATIVE="$3"
  TRY_FIX_METHOD="mock"
  TRY_FIX_METHOD_ID="$(_fix_method_desc copyto_shorthash)"
  TRY_FIX_RESTORE="restore"
  TRY_FIX_MESSAGE=""
  return 0
}

# 作用域包装: _sync_fix_missing_files 依赖调用方变量（bash 动态作用域）
run_fix() {
  local source_path="onedrive:0"
  local dest_path="openlist:wopan176Crypt/backup"
  local task_name="t"
  local extra_args=()
  local LOG_FILENAME="$WORK/out.log"
  local LAST_ATTEMPT_LOG="$WORK/last.log"
  local fail_list="$WORK/fail.txt"
  local fix_list="$WORK/fix.txt"
  local fix_log="$WORK/fix.log"
  : > "$LOG_FILENAME"; : > "$LAST_ATTEMPT_LOG"
  : > "$fail_list"; : > "$fix_list"; : > "$fix_log"
  _sync_fix_missing_files
}

MISSING="$WORK/missing.txt"

# ===== 场景1: 密文名 150B > 后端已接受最长 100B → 拉黑带原名的方法 =====
# 后端已接受最长 = LSF_OUT 中 basename 的最大长度
LSF_OUT=$'short_a\nshort_bb\nshort_ccc\n'   # 最长 9 字节
printf 'path/to/一个很长的中文文件名超过后端接受上限.mp4\n' > "$MISSING"
: > "$TRY_LOG"
SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene1.log" 2>&1
BL="${FIX_METHOD_BLACKLIST[path/to/一个很长的中文文件名超过后端接受上限.mp4]:-}"
# 拉黑的是方法全名（含语义 ID），按语义名断言而非序号
echo "$BL" | grep -q "copyto_original" && ok "1a 名长超限 → 拉黑 copyto_original" || bad "1a: BL=[$BL]"
echo "$BL" | grep -q "zip_split_original" && ok "1b 名长超限 → 拉黑 zip_split_original（zip 基底名也带原名）" || bad "1b: BL=[$BL]"
! echo "$BL" | grep -q "copyto_shorthash" && ok "1c copyto_shorthash 未被拉黑（对症方法保留）" || bad "1c: 不该拉黑短哈希直传"
! echo "$BL" | grep -q "zip_split_shorthash" && ok "1d zip_split_shorthash 未被拉黑" || bad "1d: 不该拉黑短哈希分卷"
grep -q "跳过" "$WORK/scene1.log" && ok "1e 日志注明跳过注定失败的方法" || bad "1e: 无跳过提示"

# ===== 场景2: 密文名未超后端已接受最长 → 不拉黑，正常从文件修复方法1 开始 =====
LSF_OUT=$'a-very-long-encrypted-name-that-is-200-bytes-long-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
printf 'path/to/normal.mp4\n' > "$MISSING"
: > "$TRY_LOG"
SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene2.log" 2>&1
BL2="${FIX_METHOD_BLACKLIST[path/to/normal.mp4]:-}"
[ -z "$BL2" ] && ok "2a 密文名未超限 → 不拉黑（后端接受过更长的名）" || bad "2a: BL=[$BL2]"

# ===== 场景3: 名长探针失败 → 不拉黑（诊断不可用时保守放行）=====
LSF_OUT=$'short_a\n'
printf 'path/to/probe_fail.mp4\n' > "$MISSING"
: > "$TRY_LOG"
PROBE_LEN=""
SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene3.log" 2>&1
PROBE_LEN=150
BL3="${FIX_METHOD_BLACKLIST[path/to/probe_fail.mp4]:-}"
[ -z "$BL3" ] && ok "3 探针失败 → 不拉黑（诊断不可用则保守放行）" || bad "3: BL=[$BL3]"

# ===== 场景4: SYNC_FIX_LIST_CACHE 命中 → 不再对目标端跑 lsf =====
# 非 OVERRIDE 路径（需要 src-vs-dst diff）才走清单复用分支
# 只统计 diff 用的那条目标端 lsf（按参数里的 openlist: 目标路径识别）:
# 名长诊断也会调 lsf（_NAMELEN_RAW_MAX），统计总次数会把它算进来
LSF_CALLS="$WORK/lsf_calls"
echo 0 > "$LSF_CALLS"
rclone() {
  case "$1" in
    lsf)
      case "$*" in
        *"openlist:wopan176Crypt/backup"*)
          echo $(( $(cat "$LSF_CALLS") + 1 )) > "$LSF_CALLS" ;;
      esac
      printf '%s' "${LSF_OUT:-}" ;;
    size) echo '{"bytes":1024,"count":1}' ;;
    *) return 0 ;;
  esac
}
CACHE="$WORK/dest_cache.txt"
printf 'old/file.mp4\n' > "$CACHE"
LSF_OUT=$'src/a.mp4\nsrc/b.mp4\n'
printf 'src/a.mp4\n' > "$MISSING"
echo 0 > "$LSF_CALLS"
SYNC_FIX_LIST_CACHE="$CACHE" run_fix > "$WORK/scene4.log" 2>&1
N=$(cat "$LSF_CALLS")
[ "$N" = "0" ] && ok "4a 清单缓存命中 → 目标端 lsf 零执行" || bad "4a: 目标端 lsf 调用 ${N} 次"
grep -q "复用调用方目标端清单" "$WORK/scene4.log" && ok "4b 日志记录复用" || bad "4b: 无复用日志"
[ -s "$CACHE" ] && ok "4c 调用方缓存未被误删（仍可供后续步骤使用）" || bad "4c: 缓存被删除"

# ===== 场景5: 无缓存 → 回退到现场列目标端（宁慢勿漏）=====
echo 0 > "$LSF_CALLS"
run_fix > "$WORK/scene5.log" 2>&1
N5=$(cat "$LSF_CALLS")
[ "$N5" = "1" ] && ok "5 无缓存 → 回退列目标端 1 次（行为不变）" || bad "5: 目标端 lsf 调用 ${N5} 次"
! grep -q "复用调用方目标端清单" "$WORK/scene5.log" && ok "5b 未误报复用" || bad "5b: 误报复用"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$WORK" /tmp/marker.json
[ $FAIL -eq 0 ]
