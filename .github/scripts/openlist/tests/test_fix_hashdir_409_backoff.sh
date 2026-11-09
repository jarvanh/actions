#!/bin/bash
# _fix_switch_to_hash_dir 的 409 退避重试（2026-11-09 加）
#
# 背景（用户告警 run 42514192753 实证）:
#   task1_1024j_套图_女仆镂空胖次 的 306/307/308.jpg 报「目标目录建不出来」，
#   但**同一目录当轮另有 41 个文件成功落盘**、409 原文是 `unchanged simple
#   update failed`（改写已有对象失败）⇒ 目录可写、409 是瞬态风暴。
#   根因: sync 层对 409 有 3×300s 等待重试，而修复管线的 mkdir 只用 rclone
#   秒级重试就判死 —— 两条路径对同一个 409 的耐心完全不同。
#
# 本测锁住新行为:
#   1a 409 连续失败后重试成功 → hash_dir_ok=1，且确实 sleep 过
#   1b 重试次数受 OPENLIST_409_RETRY_ATTEMPTS 约束
#   2  同一目录第二次调用不再等待（避免 40+ 文件各自等 15min 烧光预算）
#   3  预算不足一个退避窗 → 跳过等待、不 sleep
#   4  全部重试仍失败 → hash_dir_ok 保持 0（继续走后续兜底/判死）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

WORK="/tmp/fix_hashdir_409_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

# --- 抽取被测函数（避免整库 source 带来的副作用）---
sed -n '/^_fix_switch_to_hash_dir()/,/^}$/p' "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" > extracted.sh
echo "被测函数抽取: $(wc -l < extracted.sh) 行"
[ -s extracted.sh ] || { echo "FATAL: 抽取失败"; exit 1; }
source extracted.sh

# --- 协作者 stub ---
RCLONE_RETRY_FLAGS=()
OPENLIST_MKDIR_TIMEOUT=120s
OPENLIST_HASH_DIR_FALLBACK=1
_FIX_MKDIR_409_SEMANTICS=0     # 关掉"已存在语义"分支，隔离测退避路径
_HASH_DIR_FAIL_REASON=""
declare -A FIX_METHOD_BLACKLIST=()
declare -A _FIX_HASHDIR_409_TRIED=()

SLEPT=0
sleep()  { SLEPT=$((SLEPT + 1)); }
log_fix() { printf '%s\n' "$2" >> "$WORK/fixlog.txt"; }
_cmd_log() { :; }
_hash_dir_rel_for() { echo "abc12345"; }
_get_openlist_token() { echo ""; }   # 空 token → 跳过 API 分支
_fix_dir_exists_or_conflict() { return 1; }
_fix_probe_dir_writable() { return 0; }   # 兜底目录可写（隔离测 409 退避路径）
declare -A _DIR_WRITE_CACHE=()
_DIR_PROBE_STATE="ok"
declare -A _BACKEND_DEAD=()

# rclone mock: mkdir 前 MK_FAIL_TIMES 次返回非 0（模拟 409），之后成功。
# ⚠️ 计数必须落文件: 被测代码是 `rclone mkdir ... | _cmd_log`，管道让 rclone 在
#    子 shell 里执行，变量累加会丢（实测踩到: MK_CALLS 恒为 1 → 永远失败）。
MK_CALLS_FILE="$WORK/mk_calls"
rclone() {
  case "$1" in
    mkdir)
      local _n
      _n=$(( $(cat "$MK_CALLS_FILE" 2>/dev/null || echo 0) + 1 ))
      echo "$_n" > "$MK_CALLS_FILE"
      MC_CALLS=$_n
      [ "$_n" -le "${MK_FAIL_TIMES:-99}" ] && return 1
      return 0 ;;
    lsd) return "${LSF_RC:-0}" ;;
    *) return 0 ;;
  esac
}

mk_calls() { cat "$MK_CALLS_FILE" 2>/dev/null || echo 0; }

reset_case() {
  : > "$WORK/fixlog.txt"
  SLEPT=0; : > "$MK_CALLS_FILE"
  _FIX_HASHDIR_409_TRIED=(); declare -gA _FIX_HASHDIR_409_TRIED=()
  dest_path="openlist:wopan175/1/x"
  file_dir_rel="."
  failed_file_rel="306.jpg"
  ol_dst_base="wopan175/1/x"
  fix_log="$WORK/fixlog.txt"
  used_base64_dir=0
  actual_dst_dir=""; actual_ol_dir=""
  HASH_DIR_REL=""; used_hash_dir=0
  unset OPENLIST_SYNC_DEADLINE_EPOCH OPENLIST_409_RETRY_ATTEMPTS OPENLIST_409_RETRY_SLEEP_SECONDS
}

# --- 1a/1b: 409 两次后成功 ---
reset_case
export OPENLIST_409_RETRY_ATTEMPTS=3
export OPENLIST_409_RETRY_SLEEP_SECONDS=1
MK_FAIL_TIMES=2      # 首次 + 第 1 次重试失败，第 2 次重试成功
if _fix_switch_to_hash_dir; then
  ok "1a 409 退避后目录建成 → 返回 0"
else
  bad "1a 409 退避后仍返回失败"
fi
[ "$SLEPT" = "2" ] && ok "1b 等待次数=2（第 2 次重试才成功）" || bad "1b: sleep=$SLEPT（期望 2）"
grep -q "409 退避后短哈希目录建成" "$WORK/fixlog.txt" \
  && ok "1c 日志记录退避成功" || bad "1c: 未记录退避成功"

# --- 2: 同目录第二次不再等待 ---
SLEPT=0; : > "$MK_CALLS_FILE"; MK_FAIL_TIMES=99
if _fix_switch_to_hash_dir; then
  bad "2a 目录仍建不出却返回 0"
else
  ok "2a 目录仍建不出 → 返回 1（交由后续兜底）"
fi
[ "$SLEPT" = "0" ] && ok "2b 同目录第二次不再等待（去重生效）" || bad "2b: sleep=$SLEPT（期望 0）"
grep -q "本次不再等待" "$WORK/fixlog.txt" && ok "2c 日志说明已去重" || bad "2c: 未说明去重"

# --- 3: 预算不足 → 跳过等待 ---
reset_case
export OPENLIST_409_RETRY_ATTEMPTS=3
export OPENLIST_409_RETRY_SLEEP_SECONDS=300
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 100 ))   # 远小于 300s+120
sync_hard_limit_stop() { return 1; }                    # 不触发硬顶，只测预算窗
MK_FAIL_TIMES=99
if _fix_switch_to_hash_dir; then
  bad "3a 预算不足却报告建成"
else
  ok "3a 预算不足 → 目录未建成（返回 1）"
fi
[ "$SLEPT" = "0" ] && ok "3b 预算不足时不等待（不烧预算）" || bad "3b: sleep=$SLEPT（期望 0）"
grep -q "预算不足一个 409 退避窗" "$WORK/fixlog.txt" && ok "3c 日志说明跳过原因" || bad "3c: 未说明"

# --- 4: 全部重试仍失败 ---
reset_case
export OPENLIST_409_RETRY_ATTEMPTS=2
export OPENLIST_409_RETRY_SLEEP_SECONDS=1
MK_FAIL_TIMES=99
if _fix_switch_to_hash_dir; then
  bad "4a 全部重试失败却返回 0"
else
  ok "4a 全部重试失败 → 返回 1"
fi
[ "$SLEPT" = "2" ] && ok "4b 用满 2 次重试" || bad "4b: sleep=$SLEPT（期望 2）"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
