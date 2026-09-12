#!/bin/bash
# 同步结果通知 —— 失败清单（❌ 无法同步文件）版式验证
#
# 背景: 失败清单原先是「1 条目行 + N 行"修复过程"子行」的二层列表——子行原样
#   灌入 file_fix 的日志片段，单个文件就能撑出 15+ 行（源/目标全路径、rclone
#   原始报错、内部机制术语），线上通知里最难看的就是它。而片段里的结论早已由
#   fail_list 第三列的失败原因概括（2026-09-12 用户拍板删掉子行，方案 C）。
#
# 本测试锁死四件事:
#   1. 不挂"修复过程"子行——fix_log 里就算有对应片段也不进通知
#   2. 条目行形态: `  ├─/└─ <code>主体</code> · 大小 · 原因`
#   3. 超 8 条折叠走真源 tree_fold（折叠行并入条目流作末条，禁双 └─）
#   4. 失败原因是人话——不得出现 熔断/探测/哈希/base64 这类内部术语
#   另: 参数表去掉 fix_log 后 shift 数必须跟着改，用"额外参数仍能生效"锁住
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_notify.sh"

WORK="/tmp/syncnotify_faillist_test"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

FAIL_LIST="$WORK/fail.txt"
FIX_LOG="$WORK/fix.log"
LOG="$WORK/sync.log"
: > "$LOG"

# --- mocks ---
_get_path_stats() {
  case "$1" in
    onedrive:*) echo "70185 1 68.540 KiB" ;;
    *)          echo "0 0 未知" ;;
  esac
}
_refresh_openlist_cache() { return 0; }
_build_diff_files_list() { printf '%s\n' '新增 · 1' '  └─ fSWP4H4.jpg'; }
_build_exclude_patterns() {
  local a
  for a in "$@"; do
    [ "$a" = "--exclude" ] && continue
    case "$a" in *.tmp) echo "$a" ;; esac
  done
}
get_transferred_bytes_from_log() { echo 70185; }
progress_add_fixed_files() { return 0; }
_fix_method_short() { echo "未知"; }
SYNC_SKIP_QUIET=0
AUTO_SPLIT_INFO=""
export TG_RUN_URL="https://github.com/example/repo/actions/runs/123"
export TG_RUN_STARTED_AT=""

captured=""
send_telegram_message() { captured="$1"; }

# 只取「❌ 无法同步文件」这一段（到下一个空行为止）——同一条通知里
# 差异文件列表也是 `  └─` 树形，按整条消息数行会把两者混在一起
fail_block() {
  printf '%s\n' "$captured" | awk '
    /^❌ 无法同步文件/ { capture=1 }
    capture && /^$/ { exit }
    capture { print }
  '
}

# 调用被测函数（参数表与 sync_engine.sh 一致: 9 个固定参数 + 额外 rclone 参数）
call_notify() {
  captured=""
  _send_sync_result_notification \
    "onedrive:1/media" "openlist:wopan175/1/media" "task0" 0 \
    "$LOG" "$LOG" "$FAIL_LIST" "$WORK/fix_list.txt" 0 \
    "$@"
}

# ===== 1. 不挂"修复过程"子行（fix_log 里存在片段也不进通知）=====
printf '%s\n' 'fSWP4H4.jpg|68.540 KiB|目标目录不可写（存储端本轮整体故障，未试写；无目录可换）' > "$FAIL_LIST"
cat > "$FIX_LOG" <<'EOF'
[2026/09/12 05:16:54] === 尝试修复失败文件: fSWP4H4.jpg ===
[2026/09/12 05:16:54] ── 修复 fSWP4H4.jpg
[2026/09/12 05:16:54] 源: onedrive:1/media/fSWP4H4.jpg
[2026/09/12 05:16:55] ⚠ mkdir | 2026/09/12 05:16:55 ERROR : Conflict: 409 Conflict
[2026/09/12 05:16:56] 🔎 目录可写性（后端 openlist:wopan175 本轮已熔断，直接判不可写: 不探测、不重启）
[2026/09/12 05:16:56] ❌ 无法换目录（无目录可换），无法修复文件
EOF
: > "$WORK/fix_list.txt"
call_notify
printf '%s' "$captured" | grep -q "修复过程" \
  && bad "1a 仍挂出「修复过程」子行" || ok "1a 不再挂「修复过程」子行"
printf '%s' "$captured" | grep -q "mkdir" \
  && bad "1b 原始日志片段漏进通知" || ok "1b 原始日志片段不进通知"
printf '%s' "$captured" | grep -q "目录可写性" \
  && bad "1c 内部诊断行漏进通知" || ok "1c 内部诊断行不进通知"
printf '%s' "$captured" | grep -q "^  └─ <code>fSWP4H4.jpg</code> · 68.540 KiB · " \
  && ok "1d 条目行为树形 + 主体等宽 + 原因" || bad "1d: 条目行形态不符"
printf '%s' "$captured" | grep -q "^❌ 无法同步文件 · 1$" \
  && ok "1e 分节带计数" || bad "1e: 分节计数缺失"
# 子行删除后整条清单只剩 1 行条目（分节行之外不再有缩进行）
n_lines=$(fail_block | grep -c '^  ' || true)
[ "$n_lines" -eq 1 ] && ok "1f 清单只剩 1 行条目（无子行）" || bad "1f: 缩进行数=${n_lines}"

# ===== 2. 失败原因是人话（规范 · 说人话）=====
! printf '%s' "$captured" | grep -qE "熔断|探测|哈希|base64|短哈希" \
  && ok "2a 失败原因不含内部术语" || bad "2a: 原因含内部术语"

# ===== 3. 超 8 条折叠走 tree_fold（折叠行并入条目流作末条）=====
for i in $(seq 1 10); do
  printf 'file%d.mp4|1.150 GiB|目标目录不可写（存储端本轮整体故障，未试写；无目录可换）\n' "$i"
done > "$FAIL_LIST"
call_notify
printf '%s' "$captured" | grep -q "^❌ 无法同步文件 · 10$" \
  && ok "3a 分节计数取真实总数（10）" || bad "3a: 计数未取总数"
printf '%s' "$captured" | grep -q "└─ 还有 2 条…" \
  && ok "3b 折叠行为「还有 2 条…」" || bad "3b: 无折叠行"
c_last=$(fail_block | grep -c '└─' || true)
[ "$c_last" -eq 1 ] && ok "3c 只有一个 └─（折叠行作末条）" || bad "3c: └─ 数量=${c_last}"
c_entry=$(fail_block | grep -c '^  [├└]─ <code>' || true)
[ "$c_entry" -eq 8 ] && ok "3d 展示 8 条条目（上限）" || bad "3d: 条目行数=${c_entry}"
fail_block | tail -1 | grep -q '^  └─ 还有 2 条…$' \
  && ok "3e 折叠行是末条" || bad "3e: 末行=$(fail_block | tail -1)"

# ===== 4. 参数表去掉 fix_log 后 shift 数正确（额外参数仍生效）=====
printf '%s\n' 'a.tmp|1.000 KiB|目标目录不可写（存储端本轮整体故障，未试写；无目录可换）' > "$FAIL_LIST"
call_notify "--exclude" "*.tmp"
printf '%s' "$captured" | grep -q "🚫 排除规则 · 1" \
  && ok "4a 额外 rclone 参数仍被正确解析（shift 数对）" || bad "4a: 排除规则段缺失（shift 数错位）"

# ===== 5. 无失败文件时该分节整段不出现（空清单不渲染 · 0）=====
: > "$FAIL_LIST"
: > "$WORK/fix_list.txt"
call_notify
! printf '%s' "$captured" | grep -q "无法同步文件" \
  && ok "5a 无失败文件时不出现该分节" || bad "5a: 空清单仍渲染分节"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
