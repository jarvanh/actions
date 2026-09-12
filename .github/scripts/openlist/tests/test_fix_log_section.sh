#!/bin/bash
# 修复日志区段头 —— 日志可切分性验证
#
# 背景: 每个失败文件在 fix.log 里占一段，以 "=== 尝试修复失败文件: <rel> ===" 开头。
#   该头部曾是通知的提取锚点（sync_notify.sh 按它切出"修复过程"子行）；2026-09-12
#   通知侧删掉子行后不再有自动消费方，头部保留为**人读日志的定界符**——失败时
#   fix.log 会作为文档发到 Telegram，读者要能按文件切成段。故以下性质仍需锁住:
#   1. 区段头写入的是完整相对路径（不被 _short_path 截断到 56 字符）
#   2. 相邻两个文件的区段互不串味（按头部即可切成段）
#   3. 段内含目录创建经过（排查失败原因的关键行）
#
# 历史 bug: 4e43120 日志美化时该头部随旧写法一起消失，try_fix_failed_file 只剩下
#   "── 修复 <_short_path 截断路径>"——头部没了、路径还被截断到 56 字符，通知侧
#   两端都匹配不上 → 所有失败文件一律显示"修复过程：无记录"（backup 任务的
#   options.xml 就是这么丢掉全部失败原因的）。头部今天虽不再被程序消费，
#   "写完整路径"这条依然不能退化：截断后连人都分不清这一段是哪个文件。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null
# 排版助手 + 发送层的唯一真源（openlist 侧已不再自带副本，2026-09-06 收敛）
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
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

# 按区段头切出一段日志（人读日志时的切法）
slice_section() {
  awk -v rel="$1" '
    index($0, "=== 尝试修复失败文件: " rel " ===") > 0 { capture=1; next }
    /=== 尝试修复失败文件: / && capture { capture=0 }
    capture { sub(/^\[[^]]*\] /, ""); print }
  ' "$2" 2>/dev/null
}

FIX_LOG="$WORK/fix.log"
: > "$FIX_LOG"

# 故意取超过 _short_path 默认 56 字符上限的长路径: 复现"头部被截断 → 切不出段"
REL="Emby Backup - 2021-11-18 08.40.36 - Auto/library/gd - j - 社交/options.xml"
REL2="dad/另一个失败文件.mp4"

try_fix_failed_file "onedrive:backup" "openlist:wopan176Crypt/backup" "t" "$REL" "$FIX_LOG" >/dev/null 2>&1
try_fix_failed_file "onedrive:backup" "openlist:wopan176Crypt/backup" "t" "$REL2" "$FIX_LOG" >/dev/null 2>&1

grep -qF "=== 尝试修复失败文件: ${REL} ===" "$FIX_LOG" \
  && ok "1 区段头写入完整相对路径（未被 _short_path 截断）" \
  || bad "1: 头部缺失或被截断: $(head -3 "$FIX_LOG")"

S1=$(slice_section "$REL" "$FIX_LOG")
[ -n "$S1" ] && ok "2 按区段头能切出该文件的日志段" \
  || bad "2: 切不出段（读者无法定位这个文件报了什么错）"

S2=$(slice_section "$REL2" "$FIX_LOG")
[ -n "$S2" ] && ok "3 第二个文件同样可切" || bad "3: 第二个文件切不出段"

! printf '%s' "$S1" | grep -qF "$REL2" \
  && ok "4 区段边界正确（首个文件的段不含后一个文件的内容）" \
  || bad "4: 区段串味，未在后一个头部处停止捕获"

printf '%s' "$S1" | grep -q "目录" \
  && ok "5 段内含目录创建经过（排查失败原因的关键行）" \
  || bad "5: 段内缺少目录创建记录"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
