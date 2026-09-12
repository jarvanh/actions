#!/bin/bash
# 目录级批量折叠（file_fix_pipeline.sh _sync_bulk_hash_dir_fold）—— 逻辑验证
#
# 背景: 短哈希目录兜底此前只在**逐文件修复管线**里触发（file_fix.sh
#   _fix_switch_to_hash_dir），批量 rclone sync 阶段对每个文件按原路径 PUT，
#   没有 per-file 决策能力。run 34674196629 实测: 1051 个文件里 1050 个因
#   加密后路径过长被后端 405 全拒，批量阶段白烧 69min，最后只剩 52min 给修复
#   管线，逐文件修了 73 个（~30s/个 ≈ 29 KiB/s）；而同样的文件切到短哈希目录
#   后立刻可写、批量速率 2-3 MiB/s —— 慢路径与快路径差约 100 倍。
#
# 本测试锁住"把整目录折叠搬到批量通道"后的判定与记账行为:
#   该折叠的折叠、不该动的一个不许动、没落盘的一个不许记。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix_pipeline.sh" 2>/dev/null

WORK="/tmp/bulkfold_test"
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"
trap 'cd / && rm -rf "$WORK"' EXIT

# --- mocks ---
tee() { cat; }                      # 剥掉 tee: 输出仍可见，但不写文件
_log_section() { :; }
_short_path() { echo "$1"; }
format_bytes() { echo "${1}B"; }
format_bytes_iec() { echo "${1}B"; }
_fix_backend_root_of() { echo "openlist:wopan176Crypt"; }
log_fix() { :; }
_get_openlist_token() { echo fake-token; }
curl() { echo 'HTTP_CODE:200'; }

# 目录可写性探测: 由 PROBE_WRITABLE 控制（1=可写 0=不可写）。
# 完整模拟 file_fix.sh 的后端熔断语义（用真实变量 _BACKEND_DIR_FAIL_STREAK /
# _BACKEND_DEAD，而不是自造计数器）——否则测不出"折叠成功后要清熔断"这条:
# 真实数据是 43 个长路径目录连续探测失败，不清就会在第 3 个目录停摆。
PROBE_WRITABLE=0
PROBE_CALLS=""
_fix_probe_dir_writable() {
  PROBE_CALLS="${PROBE_CALLS} $1"
  local _be="openlist:wopan176Crypt"
  if [ "$PROBE_WRITABLE" = "1" ]; then
    _BACKEND_DIR_FAIL_STREAK["$_be"]=0
    unset "_BACKEND_DEAD[$_be]" 2>/dev/null || true
    return 0
  fi
  local _s=$(( ${_BACKEND_DIR_FAIL_STREAK["$_be"]:-0} + 1 ))
  _BACKEND_DIR_FAIL_STREAK["$_be"]=$_s
  [ "$_s" -ge "${OPENLIST_BACKEND_DEAD_THRESHOLD:-3}" ] && _BACKEND_DEAD["$_be"]=1
  return 1
}

# 目标端落盘清单（lsf 输出），空串模拟"零落盘"
LAND_OUT="001.jpg
002.jpg"
SYNC_CALLS=""
rclone() {
  case "$1" in
    lsf)    printf '%s\n' "$LAND_OUT" ;;
    lsjson) echo '[{"Name":"001.jpg","Size":100},{"Name":"002.jpg","Size":200},{"Name":"003.jpg","Size":300}]' ;;
    sync)   SYNC_CALLS="${SYNC_CALLS} $2->$3"; SYNC_ARGS="$*" ;;
    mkdir|lsd) return 0 ;;
    *) return 0 ;;
  esac
}

# marker 写入不测（既有函数职责），只记录被记入的 original。
# 注意: 必须写文件而不是累加变量 —— 调用处是 `_persist_fix_entry_now ... | tee`，
# 管道左支在子 shell 里执行，变量的修改传不回父 shell（记变量会得到假通过）
_PERSIST_LOG="/tmp/bulkfold_persist.txt"
_persist_fix_entry_now() { echo "${5}" >> "$_PERSIST_LOG"; return 0; }

_missing="/tmp/bulkfold_missing.txt"
_fixlist="/tmp/bulkfold_fixlist.txt"
reset_state() {
  FIXED_THIS_RUN=()
  _BACKEND_DEAD=()
  _BACKEND_DIR_FAIL_STREAK=()
  _DIR_WRITE_CACHE=()
  PROBE_CALLS=""
  SYNC_CALLS=""
  : > "$_PERSIST_LOG"
  : > "$_fixlist"
  LOG_FILENAME="/tmp/bulkfold_main.log"; : > "$LOG_FILENAME"
  fix_log="/tmp/bulkfold_fix.log";       : > "$fix_log"
  incr_state="/tmp/bulkfold_state.json"; echo '{}' > "$incr_state"
  incr_marker_path="openlist:x/marker.json"
  missing_list="$_missing"
  fix_list="$_fixlist"
  # 调用方作用域三件套（_sync_bulk_hash_dir_fold 与 set -u 都要用）
  source_path="onedrive:2"
  dest_path="openlist:wopan176Crypt/2"
  task_name="t"
  unset OPENLIST_BULK_HASH_FOLD OPENLIST_BULK_FOLD_MIN_FILES OPENLIST_BULK_FOLD_MAX_DIRS
  unset OPENLIST_SYNC_DEADLINE_EPOCH
}
set_missing() { printf '%s\n' "$@" > "$_missing"; }
lines() { [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ============================================================
# T1: 基本折叠 —— 达标目录整组搬走，未达标目录不动
# ============================================================
reset_state
PROBE_WRITABLE=0
set_missing "d/001.jpg" "d/002.jpg" "e/003.jpg"
_sync_bulk_hash_dir_fold
[ "$(lines "$_missing")" = "1" ] && ok "T1a 折叠后缺失清单只剩 1 条" || bad "T1a 剩余 $(lines "$_missing") 条: $(cat "$_missing")"
grep -qxF "e/003.jpg" "$_missing" && ok "T1b 未达标目录(e/ 仅1个文件)留在清单里" || bad "T1b e/003.jpg 不见了"
[ "$(lines "$_fixlist")" = "2" ] && ok "T1c 2 个文件记入 fix_list" || bad "T1c fix_list $(lines "$_fixlist") 条"
_first_alt=$(head -1 "$_fixlist" 2>/dev/null | cut -d'|' -f2)
if [[ "$_first_alt" =~ ^[0-9a-f]{8}/001\.jpg$ ]]; then ok "T1d alternative 为 <8位短哈希>/原文件名 ($_first_alt)"; else bad "T1d alternative 格式不对: $_first_alt"; fi
grep -q '短哈希目录' "$_fixlist" 2>/dev/null && ok "T1e method 文本含『短哈希目录』(restore_info.jq 据此判 hash_dir)" || bad "T1e method 文本不含短哈希目录"
[ -n "$SYNC_CALLS" ] && ok "T1f 走的是批量 rclone sync" || bad "T1f 没有触发 sync"

# ============================================================
# T2: 原目录可写 —— 不许动目录结构（折叠会不可逆丢掉目录名）
# ============================================================
reset_state
PROBE_WRITABLE=1
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T2a 原目录可写时不折叠" || bad "T2a 可写却折叠了: $SYNC_CALLS"
[ "$(lines "$_missing")" = "2" ] && ok "T2b 缺失清单原样保留" || bad "T2b 缺失清单被改动: $(lines "$_missing")"

# ============================================================
# T3: 零落盘 —— 假成功防护，一个都不许记账
# ============================================================
reset_state
PROBE_WRITABLE=0
LAND_OUT=""
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ "$(lines "$_missing")" = "2" ] && ok "T3a 零落盘时文件退回清单（不丢条目）" || bad "T3a 缺失清单只剩 $(lines "$_missing") 条"
[ "$(lines "$_fixlist")" = "0" ] && ok "T3b 零落盘时不写 fix_list" || bad "T3b 误记了 $(lines "$_fixlist") 条"
[ ! -s "$_PERSIST_LOG" ] && ok "T3c 零落盘时不写 marker" || bad "T3c 误写 marker: $(cat "$_PERSIST_LOG" | tr '\n' ' ')"
LAND_OUT="001.jpg
002.jpg"

# ============================================================
# T4: 开关
# ============================================================
reset_state
PROBE_WRITABLE=0
OPENLIST_BULK_HASH_FOLD=0
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T4a OPENLIST_BULK_HASH_FOLD=0 时不折叠" || bad "T4a 开关失效: $SYNC_CALLS"

reset_state
PROBE_WRITABLE=0
OPENLIST_HASH_DIR_FALLBACK=0
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T4b OPENLIST_HASH_DIR_FALLBACK=0 时不折叠（与逐文件兜底同开关）" || bad "T4b 开关失效: $SYNC_CALLS"
unset OPENLIST_HASH_DIR_FALLBACK

# ============================================================
# T5: 文件数门槛 —— 只有 1 个文件的目录不值得开一次批量 sync
# ============================================================
reset_state
PROBE_WRITABLE=0
OPENLIST_BULK_FOLD_MIN_FILES=3
set_missing "d/001.jpg" "d/002.jpg"      # 2 < 3
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T5a 目录文件数低于门槛时不折叠" || bad "T5a 门槛失效: $SYNC_CALLS"

reset_state
PROBE_WRITABLE=0
OPENLIST_BULK_FOLD_MIN_FILES=2
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -n "$SYNC_CALLS" ] && ok "T5b 达到门槛时折叠" || bad "T5b 达到门槛却没折叠"

# ============================================================
# T6: 时间预算 —— 到点即停，剩余交下轮
# ============================================================
reset_state
PROBE_WRITABLE=0
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) - 10 ))
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T6 预算已过时停止折叠" || bad "T6 超预算仍折叠: $SYNC_CALLS"

# ============================================================
# T7: 子目录不串组 —— 折叠 d 时不能把 d/sub 下的文件算成 d 的直属文件
# ============================================================
reset_state
PROBE_WRITABLE=0
LAND_OUT="001.jpg
002.jpg
003.jpg"
set_missing "d/001.jpg" "d/002.jpg" "d/sub/003.jpg"
_sync_bulk_hash_dir_fold
grep -qxF "d/sub/003.jpg" "$_missing" 2>/dev/null \
  && ok "T7a 子目录文件不被父目录折叠带走" || bad "T7a d/sub/003.jpg 被误处理: $(cat "$_missing")"
if [ "$(lines "$_fixlist")" = "2" ]; then ok "T7b 只记 d 的 2 个直属文件"; else bad "T7b fix_list $(lines "$_fixlist") 条（应为 2）"; fi

# ============================================================
# T8: 后端熔断 —— 整后端写不进时不再逐个目录白跑
# ============================================================
reset_state
PROBE_WRITABLE=0
_BACKEND_DEAD["openlist:wopan176Crypt"]=1
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T8 后端已熔断时不折叠" || bad "T8 熔断后仍折叠: $SYNC_CALLS"

# ============================================================
# T9: 折叠成功后不得重复处理（FIXED_THIS_RUN 记账）
# ============================================================
reset_state
PROBE_WRITABLE=0
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -n "${FIXED_THIS_RUN[d/001.jpg]:-}" ] && ok "T9a FIXED_THIS_RUN 已记账" || bad "T9a FIXED_THIS_RUN 未记账"
if [ "$(lines "$_PERSIST_LOG")" = "2" ]; then ok "T9b marker 记入 2 条折叠条目"; else bad "T9b marker 记入 $(lines "$_PERSIST_LOG") 条（应为 2）"; fi

# ============================================================
# T10: 不递归 —— 子目录文件若被顺带搬进短哈希目录，会变成"落了盘却没 marker
#      记录"的幽灵条目（还原时无从映射），必须用 --max-depth 1 挡住
# ============================================================
reset_state
PROBE_WRITABLE=0
SYNC_ARGS=""
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
case "${SYNC_ARGS:-}" in
  *"--max-depth 1"*) ok "T10 批量折叠限定 --max-depth 1（不递归搬运子目录）" ;;
  *) bad "T10 缺少 --max-depth 1: ${SYNC_ARGS:-<未调用>}" ;;
esac

# ============================================================
# T11: 批量规模 —— 折叠必须能一次吞下整组文件（逐文件修复被
#      OPENLIST_MISSING_FIX_MAX=200 卡着，run 34674196629 单目录就有 1051 个）。
# 规模说明: 取 3×30=90 而非真实量级，是因为**沙箱下每起一个外部进程约 0.15s**
#      （tee mock 的 cat / grep 都算），360 个文件会让测试跑过 2 分钟。
#      真实 runner 上 fork 约 1ms，1051 个文件的折叠记账是秒级——
#      为此实现里刻意把"落盘清单"和"源端尺寸"都转成关联数组查表，
#      避免每个文件一次 grep/jq 进程启动。
# ============================================================
reset_state
PROBE_WRITABLE=0
LAND_OUT="$(for i in $(seq 1 30); do printf 'f%03d.jpg\n' "$i"; done)"
: > "$_missing"
for d in d1 d2 d3; do
  for i in $(seq 1 30); do printf '%s/f%03d.jpg\n' "$d" "$i" >> "$_missing"; done
done
_sync_bulk_hash_dir_fold
if [ "$(lines "$_missing")" = "0" ]; then ok "T11a 90 个文件全部折叠（无遗漏）"; else bad "T11a 剩余 $(lines "$_missing") 个"; fi
if [ "$(lines "$_fixlist")" = "90" ]; then ok "T11b fix_list 记满 90 条"; else bad "T11b fix_list $(lines "$_fixlist") 条（应为 90）"; fi
if [ "$(lines "$_PERSIST_LOG")" = "90" ]; then ok "T11c marker 记满 90 条"; else bad "T11c marker $(lines "$_PERSIST_LOG") 条（应为 90）"; fi
LAND_OUT="001.jpg
002.jpg"

# ============================================================
# T12: 预算要按"工作片"预留，不是等过期 —— 剩余 300s < slice 600s 时就不该开新目录
#      （单个目录的 sync 可能跑很久，等过期再收摊会吃掉后面持久化复核的时间）
# ============================================================
reset_state
PROBE_WRITABLE=0
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 300 ))
set_missing "d/001.jpg" "d/002.jpg"
_sync_bulk_hash_dir_fold
[ -z "$SYNC_CALLS" ] && ok "T12 剩余预算不足一个工作片 → 不开新目录" || bad "T12 仍开工: $SYNC_CALLS"

# ============================================================
# T13: 一整片长路径目录不能被后端熔断中断
#  真实形态（run 34674196629）: 43 个目录 1050 个文件**全部**因长路径 405，
#  探测会连续失败并触发 _BACKEND_DEAD（阈值 3）。但后端是健康的——短哈希
#  目录写得进。折叠成功即证明后端可写，必须据此清熔断，否则第 3 个目录就停摆，
#  剩下的 40 个目录全放弃（覆盖率会从 100% 掉到 29%）。
# ============================================================
reset_state
PROBE_WRITABLE=0
LAND_OUT="001.jpg
002.jpg"
set_missing "d1/001.jpg" "d1/002.jpg" "d2/001.jpg" "d2/002.jpg" "d3/001.jpg" "d3/002.jpg" \
            "d4/001.jpg" "d4/002.jpg" "d5/001.jpg" "d5/002.jpg"
_sync_bulk_hash_dir_fold
if [ "$(lines "$_missing")" = "0" ]; then ok "T13a 5 个连续长路径目录全部折叠（熔断未中断）"; else bad "T13a 剩 $(lines "$_missing") 个未被折叠: $(tr '\n' ' ' < "$_missing")"; fi
if [ "$(lines "$_fixlist")" = "10" ]; then ok "T13b 10 个文件全部记账"; else bad "T13b fix_list $(lines "$_fixlist") 条（应为 10）"; fi
if [ -z "${_BACKEND_DEAD["openlist:wopan176Crypt"]:-}" ]; then ok "T13c 折叠成功后后端熔断已清除"; else bad "T13c 熔断未清除"; fi

echo "-----------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
