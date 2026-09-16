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
#   3. 后端本轮已熔断 → 逐文件修复循环立即短路（熔断是后端级结论，逐文件
#      重试改变不了它；只置 SYNC_BACKEND_DEAD，不置 SYNC_TIME_EXHAUSTED）
#   8. 修复成效拆分（ROUND_REUSED / 新落盘 = 成功 − 沿用上轮，2026-09-15）:
#      沿用条目是上轮成果、不是本轮产出；混在一起会让"本轮零产出"告警永远不响
#      （run 34752801560 报"成功 183"，183 全是沿用、本轮真实落盘 0）。
#   9. 修复管线事件日志（2026-09-16）: ATTEMPT/FAIL/EXHAUSTED/DEFERRED 四类事件，
#      收尾据此打印「尝试 N · 失败 F（其中方法耗尽 E · 顺延下轮 D）· 成功率 P%」。
#      **方法耗尽单列**是关键 —— 它是"文件修不好、同步永远完不成"的唯一证据；
#      落文件而非全局计数，因为并行 worker 是子 shell（全局计数会丢）。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# 关闭目录级批量折叠: 本测试只针对「名长拉黑」与「目标端清单复用」两处优化。
# 折叠是后加的独立能力（有自己的 tests/test_bulk_hash_fold.sh），不关的话场景4
# 的 diff 会产出 2 个缺失文件并触发折叠，折叠自身的目标端 lsf（目录可写性探测
# + 落盘校验）会被这里的计数器算进去，与本用例「复用清单后不应再列目标端」
# 的意图无关 —— 那是折叠的必要开销，不是清单复用失效。
OPENLIST_BULK_HASH_FOLD=0
# 排版助手 + 发送层的唯一真源（openlist 侧已不再自带副本，2026-09-06 收敛）
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null
# 修复管线编排（_sync_fix_missing_files / _persist_fix_entry_now 等）已从 sync_engine.sh
# 拆到 file_fix_pipeline.sh，本测试测的就是它，漏 source 会全线 command not found
source "$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/sync_engine.sh" 2>/dev/null

WORK="/tmp/fixopt_test_dir"
rm -rf "$WORK"; mkdir -p "$WORK"
# 被测代码用相对路径写修复日志（file_fix_pipeline.sh 的
#   fix_log="file_fix_${task_name}_$(date +%Y%m%d_%H%M%S).log"）
# 测试若不切进临时目录，日志会落在源码目录污染工作区（task_name 为 t 时即
# file_fix_t_*.log）。本测试全部路径都是绝对路径，cd 无副作用。
cd "$WORK"
# 末尾虽有 rm -rf，但异常退出时执行不到，用 EXIT trap 兜底。
# 注意: 必须先 cd 出 $WORK 再删，否则删除自身 CWD 会让 shell 报 getcwd 错误
trap 'cd / && rm -rf "$WORK" /tmp/marker.json' EXIT

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

# ===== 场景6: 修复管线时间预算 —— 到点即停，不再开新文件 =====
# 此前修复管线完全不看 OPENLIST_SYNC_DEADLINE_EPOCH，调大 MISSING_FIX_MAX 会让
# step 撞 330min 被强杀、在途 marker 全丢。这道闸是安全调大上限的前提。
LSF_OUT=$'short_a\n'
printf 'a/one.mp4\na/two.mp4\n' > "$MISSING"
: > "$TRY_LOG"
SYNC_TIME_EXHAUSTED=0
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 5 )) \
  SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene6.log" 2>&1
[ ! -s "$TRY_LOG" ] && ok "6a 预算将尽 → 不再开工新文件" || bad "6a 仍修了 $(wc -l < "$TRY_LOG") 个"
[ "${SYNC_TIME_EXHAUSTED:-0}" = "1" ] && ok "6b 置 SYNC_TIME_EXHAUSTED=1" || bad "6b 未置位（=${SYNC_TIME_EXHAUSTED:-0}）"
grep -q "优雅收摊" "$WORK/scene6.log" && ok "6c 日志记录优雅收摊" || bad "6c 无收摊日志"

# 反例: 预算充足时不该误停
: > "$TRY_LOG"
SYNC_TIME_EXHAUSTED=0
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 7200 )) \
  SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene6b.log" 2>&1
[ -s "$TRY_LOG" ] && ok "6d 预算充足 → 正常修复" || bad "6d 预算充足却没修"
[ "${SYNC_TIME_EXHAUSTED:-0}" = "0" ] && ok "6e 预算充足不置位" || bad "6e 误置位"

# ===== 场景7: 后端本轮已熔断 → 逐文件循环立即短路（不再逐个探测/重启）=====
# 背景: run 34752801560 熔断后 1943 个文件全部"未试写"，每个仍要付一次目标端
# 读列表开销，5h 零产出。熔断是后端级结论，逐文件重试改变不了它。
_BACKEND_DEAD["openlist:wopan176Crypt"]=1
: > "$TRY_LOG"
SYNC_BACKEND_DEAD=0
SYNC_TIME_EXHAUSTED=0
printf 'a/one.mp4\na/two.mp4\n' > "$MISSING"
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 7200 )) \
  SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene7.log" 2>&1
[ ! -s "$TRY_LOG" ] && ok "7a 后端已熔断 → 不再开工新文件" || bad "7a 仍修了 $(wc -l < "$TRY_LOG") 个"
[ "${SYNC_BACKEND_DEAD:-0}" = "1" ] && ok "7b 置 SYNC_BACKEND_DEAD=1" || bad "7b: =${SYNC_BACKEND_DEAD:-0}"
[ "${SYNC_TIME_EXHAUSTED:-0}" = "0" ] && ok "7c 不置 SYNC_TIME_EXHAUSTED（两种出口语义不得混用）" || bad "7c 误置位"
grep -q "本轮已熔断" "$WORK/scene7.log" && ok "7d 日志记录熔断短路" || bad "7d: 无熔断日志"

# 反例: 未熔断 → 正常修复（短路不能常态化）
unset "_BACKEND_DEAD[openlist:wopan176Crypt]"
: > "$TRY_LOG"
SYNC_BACKEND_DEAD=0
SYNC_FIX_MISSING_OVERRIDE="$MISSING" run_fix > "$WORK/scene7b.log" 2>&1
[ -s "$TRY_LOG" ] && ok "7e 未熔断 → 正常修复" || bad "7e: 未熔断却被短路"
[ "${SYNC_BACKEND_DEAD:-0}" = "0" ] && ok "7f 未熔断不置位" || bad "7f 误置位"

# ===== 场景8: 修复成效拆分（新落盘 vs 沿用上轮）=====
# 收尾告警若只看 ROUND_FIXED_OK，"本轮零产出"永远查不出来: run 34752801560
# 报"成功 183"，其中 183 全是沿用上轮，本轮真实落盘 0 —— 必须把沿用数单列，
# 新落盘 = 成功 − 沿用（收尾用这个数判零产出）。
jq() { echo "${JQ_LEN:-0}"; }        # 临时替换: 本场景只需要 jq length 的返回值
rm -f /tmp/ol_round_stats.env
JQ_LEN=2
_ol_round_stats_bump '["a","b"]' 10 2
. /tmp/ol_round_stats.env
[ "$ROUND_FIXED_OK" = "2" ] && ok "8a 成功总数落盘（2）" || bad "8a: ${ROUND_FIXED_OK}"
[ "$ROUND_REUSED" = "2" ] && ok "8b 沿用数落盘（2）" || bad "8b: ${ROUND_REUSED}"
[ "$ROUND_MISSING" = "10" ] && ok "8c 缺失总数落盘（10）" || bad "8c: ${ROUND_MISSING}"
JQ_LEN=1
_ol_round_stats_bump '["c"]' 10 2
. /tmp/ol_round_stats.env
[ "$ROUND_FIXED_OK" = "3" ] && ok "8d 成功数跨任务累加（2+1）" || bad "8d: ${ROUND_FIXED_OK}"
[ "$ROUND_REUSED" = "2" ] && ok "8e 沿用数按 run 级绝对值写（不重复累加）" || bad "8e: ${ROUND_REUSED}"
rm -f /tmp/ol_round_stats.env
jq() { echo '{}'; }

# ===== 场景9: 修复管线事件日志（成功率/方法耗尽的唯一数据源，2026-09-16）=====
# 为什么要落文件而不是全局计数: 并行 worker 是**子 shell**，全局计数在并行模式下
# 会丢 —— 收尾统计会静默失真。这里锁住"事件分类正确 + 方法耗尽单独归类"。
#   ATTEMPT   尝试修复
#   FAIL      尝试失败
#   EXHAUSTED 失败且原因为"所有修复方法均失败" ⇒ **永久性失败**（修不好的证据）
#   DEFERRED  轮数/预算耗尽未修完 ⇒ "没轮到"，与方法耗尽语义不同、不混算
_FIX_EVENT_LOG="$WORK/fix_events.log"
: > "$_FIX_EVENT_LOG"
_fix_event ATTEMPT "d/1.mp4"
_fix_event_fail "d/1.mp4" "目标目录不可写（已复核确认写不进去；无目录可换）"
_fix_event ATTEMPT "d/2.mp4"
_fix_event_fail "d/2.mp4" "所有修复方法均失败"
_fix_event ATTEMPT "d/3.mp4"
_fix_event DEFERRED "d/3.mp4" "重试轮数耗尽"
[ "$(grep -c '^ATTEMPT|' "$_FIX_EVENT_LOG")" = "3" ] && ok "9a 尝试数 3" || bad "9a: $(grep -c '^ATTEMPT|' "$_FIX_EVENT_LOG")"
[ "$(grep -c '^FAIL|' "$_FIX_EVENT_LOG")" = "2" ] && ok "9b 失败数 2" || bad "9b: $(grep -c '^FAIL|' "$_FIX_EVENT_LOG")"
[ "$(grep -c '^EXHAUSTED|' "$_FIX_EVENT_LOG")" = "1" ] && ok "9c 方法耗尽单列（仅'所有修复方法均失败'计入）" || bad "9c: $(grep -c '^EXHAUSTED|' "$_FIX_EVENT_LOG")"
[ "$(grep -c '^DEFERRED|' "$_FIX_EVENT_LOG")" = "1" ] && ok "9d 顺延下轮单列（不混入方法耗尽）" || bad "9d: $(grep -c '^DEFERRED|' "$_FIX_EVENT_LOG")"
grep -q '^FAIL|d/1.mp4|目标目录不可写' "$_FIX_EVENT_LOG" && ok "9e 失败原因随事件落盘（可归类取证）" || bad "9e: 原因未落盘"

# 9f~9j 埋点接线（防重构时把埋点删掉而统计静默归零）
_SRC="$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh"
grep -q '_fix_event ATTEMPT "$failed_line"' "$_SRC" && ok "9f 逐文件循环埋点（尝试）" || bad "9f: 逐文件 ATTEMPT 埋点缺失"
grep -q '_fix_event_fail "$failed_line"' "$_SRC" && ok "9g 逐文件失败分支埋点" || bad "9g: 逐文件 FAIL 埋点缺失"
grep -q '_fix_event ATTEMPT "$retry_orig"' "$_SRC" && ok "9h 假成功重试循环埋点（尝试）" || bad "9h: 重试 ATTEMPT 埋点缺失"
grep -q '_fix_event_fail "$retry_orig"' "$_SRC" && ok "9i 重试失败分支埋点（方法耗尽在此归类）" || bad "9i: 重试 FAIL 埋点缺失"
grep -q '_fix_event DEFERRED "$leftover_orig"' "$_SRC" && ok "9j 轮数耗尽埋点（顺延）" || bad "9j: DEFERRED 埋点缺失"
rm -f "$_FIX_EVENT_LOG"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
# $WORK 交给 EXIT trap 清理：此处删掉自身 CWD 会让后续 shell 报 getcwd 错误
rm -f /tmp/marker.json
[ $FAIL -eq 0 ]
