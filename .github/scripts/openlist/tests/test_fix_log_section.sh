#!/bin/bash
# 修复日志区段头 —— 通知侧可提取性验证
#
# 背景: sync_notify.sh 用 awk 按 "=== 尝试修复失败文件: <rel> ===" 切分每个
#   文件的修复过程，作为通知里"修复过程："的子行。4e43120 日志美化时该
#   头部随旧写法一起消失，try_fix_failed_file 只剩下
#   "── 修复 <_short_path 截断路径>" —— 头部没了、路径还被截断到 56 字符，
#   awk 两端都匹配不上 → 所有失败文件在通知里一律显示"修复过程：无记录"
#   （本次 backup 任务的 options.xml 就是这么丢掉全部失败原因的）。
#
# 本测试锁死生产者↔消费者的契约:
#   1. 区段头写入的是完整相对路径（不被 _short_path 截断）
#   2. 通知侧那段 awk 能提取到非空片段
#   3. 相邻两个文件的区段互不串味
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null

WORK="/tmp/fixlog_test_dir"
rm -rf "$WORK"; mkdir -p "$WORK"
# try_fix_failed_file 用相对路径建临时目录，必须切进临时目录避免污染工作区
cd "$WORK"
trap 'cd / && rm -rf "$WORK"' EXIT

# --- mocks ---
_get_openlist_token() { echo fake-token; }
_restart_openlist_for_truth() { return 0; }   # 目录预检走成功路径，不需要重启
# 目标端文件清单用文件维护: 被测代码的 rclone 调用全在管道里（... | _cmd_log），
# 跑在子 shell，shell 变量累加不会写回父 shell，lsf 会永远读到空清单
DST_FILES_FILE="$WORK/dst_files.txt"
: > "$DST_FILES_FILE"
rclone() {
  case "$1" in
    copyto)
      local dst="$3"
      case "$dst" in
        # 下载阶段 rclone copyto <src> <local> ...: 造出本地文件即视为下载成功
        openlist:*) printf '%s\n' "$(basename "$dst")" >> "$DST_FILES_FILE"; return 0 ;;
        *) : > "$dst"; return 0 ;;
      esac ;;
    deletefile)
      grep -vxF "$(basename "$3")" "$DST_FILES_FILE" > "${DST_FILES_FILE}.tmp" 2>/dev/null || true
      mv "${DST_FILES_FILE}.tmp" "$DST_FILES_FILE" 2>/dev/null || true
      return 0 ;;
    lsf) cat "$DST_FILES_FILE" 2>/dev/null ;;
    mkdir|lsd) return 0 ;;
    *) return 0 ;;
  esac
}
# 落盘即时校验未初始化（_RAW_VERIFY_DEST 为空）时本身就直通返回 0，无需 mock

# 通知侧提取逻辑（与 sync_notify.sh 逐字一致；改动任一侧都要同步这里）
extract_section() {
  awk -v rel="$1" '
    index($0, "=== 尝试修复失败文件: " rel " ===") > 0 { capture=1; next }
    /=== 尝试修复失败文件: / && capture { capture=0 }
    capture { sub(/^\[[^]]*\] /, ""); print }
  ' "$2" 2>/dev/null
}

FIX_LOG="$WORK/fix.log"
: > "$FIX_LOG"

# 故意取超过 _short_path 默认 56 字符上限的长路径: 复现"头部被截断 → 匹配失败"
REL="Emby Backup - 2021-11-18 08.40.36 - Auto/library/gd - j - 社交/options.xml"
REL2="dad/另一个失败文件.mp4"

try_fix_failed_file "onedrive:backup" "openlist:wopan176Crypt/backup" "t" "$REL" "$FIX_LOG" >/dev/null 2>&1
try_fix_failed_file "onedrive:backup" "openlist:wopan176Crypt/backup" "t" "$REL2" "$FIX_LOG" >/dev/null 2>&1

grep -qF "=== 尝试修复失败文件: ${REL} ===" "$FIX_LOG" \
  && ok "1 区段头写入完整相对路径（未被 _short_path 截断）" \
  || bad "1: 头部缺失或被截断: $(head -3 "$FIX_LOG")"

S1=$(extract_section "$REL" "$FIX_LOG")
[ -n "$S1" ] && ok "2 通知侧 awk 提取到修复过程" \
  || bad "2: 提取为空（通知会显示'修复过程：无记录'）"

S2=$(extract_section "$REL2" "$FIX_LOG")
[ -n "$S2" ] && ok "3 第二个文件同样可提取" || bad "3: 第二个文件提取为空"

! printf '%s' "$S1" | grep -qF "$REL2" \
  && ok "4 区段边界正确（首个文件不含后一个文件的内容）" \
  || bad "4: 区段串味，未在后一个头部处停止捕获"

printf '%s' "$S1" | grep -q "目录" \
  && ok "5 片段含目录创建经过（排查失败原因的关键行）" \
  || bad "5: 片段缺少目录创建记录"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
