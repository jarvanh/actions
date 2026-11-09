#!/bin/bash
# _fix_b64_targets_for —— base64URL 兜底落点推导（2026-11-09 加）
#
# 背景（用户告警 run 42514192753 + 定点验证 run 42588433890）:
#   task1_1024j_套图_女仆镂空胖次 的 306/307/308.jpg 报「目标目录建不出来
#   （换用编码目录后仍失败）」。真因是这几支文件位于**子任务根目录**
#   （failed_file_rel="306.jpg" ⇒ file_dir_rel="."），而 base64 分支的进入
#   条件曾带 `file_dir_rel != "."` ⇒ 被排除，只剩「短哈希目录」一条路，
#   在 wopan175 上被 409 打死。
#   定点验证证明: 只要编码 **dest_path 末段**（该子目录名）就能建出目录、
#   3 文件全部真值复核通过，落点 1024j/套图/5aWz5LuG6ZWC56m66IOW5qyh。
#
# 为什么要独立单测: 该分支只在「目录真的建不出来」时才走到，主轮里属概率
#   事件，无法按需在生产复现 ⇒ 把纯字符串推导抽成 _fix_b64_targets_for，
#   在这里确定性覆盖，避免"改了但没人验过"。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null

# 抽函数（与其它测试同款手法: 只取目标函数，零耦合）
sed -n '/^_fix_b64_targets_for()/,/^}$/p' "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" > /tmp/b64_extract.sh
echo "被测函数抽取: $(wc -l < /tmp/b64_extract.sh) 行"
[ -s /tmp/b64_extract.sh ] || { echo "FATAL: 抽取失败"; exit 1; }
source /tmp/b64_extract.sh

# 读两行输出
read2() { _fix_b64_targets_for "$1" "$2" 2>/dev/null; }

# --- 1. 根目录情形（本次告警的真实形态） ---
_dest="openlist:wopan175/1/1024j/套图/女仆镂空胖次"
_out=$(read2 "." "$_dest")
_l1=$(printf '%s\n' "$_out" | sed -n 1p)
_l2=$(printf '%s\n' "$_out" | sed -n 2p)
_expect_dst="openlist:wopan175/1/1024j/套图/5aWz5LuG6ZWC56m66IOW5qyh"
_expect_ol="/wopan175/1/1024j/套图/5aWz5LuG6ZWC56m66IOW5qyh"
[ "$_l1" = "$_expect_dst" ] && ok "1a 根目录: 落点=dest_path 父 + b64(末段)" || bad "1a: 实得 [$_l1]"
[ "$_l2" = "$_expect_ol" ] && ok "1b 根目录: OpenList 内部路径一致" || bad "1b: 实得 [$_l2]"
# 该 b64 必须与定点验证成功路径逐字节一致（跨轮可核对）
[ "$(printf '%s' '女仆镂空胖次' | base64 | tr '+/' '-_' | tr -d '=')" = "5aWz5LuG6ZWC56m66IOW5qyh" ] \
  && ok "1c b64(女仆镂空胖次) 与 run 42588433890 成功路径一致" || bad "1c: b64 不符"

# --- 2. 子目录情形（原有行为不能变） ---
_out=$(read2 "1024j/套图/女仆镂空胖次" "openlist:wopan175/1")
_l1=$(printf '%s\n' "$_out" | sed -n 1p)
[ "$_l1" = "$_expect_dst" ] && ok "2a 子目录: 只换最底层目录名，父路径不变" || bad "2a: 实得 [$_l1]"

# --- 3. 两种情形必须落到同一处（同目录不同入口应一致） ---
_a=$(read2 "." "openlist:wopan175/1/1024j/套图/女仆镂空胖次" | sed -n 1p)
_b=$(read2 "1024j/套图/女仆镂空胖次" "openlist:wopan175/1" | sed -n 1p)
[ "$_a" = "$_b" ] && ok "3a 根目录入口与子目录入口落到同一路径（幂等）" || bad "3a: $_a vs $_b"

# --- 4. 无法编码时返回非 0（不能臆造路径） ---
if read2 "." "openlist:wopan175" >/dev/null 2>&1; then
  bad "4a dest_path 只有一段却返回成功（会臆造路径）"
else
  ok "4a dest_path 只有一段 → 返回非 0（跳过 base64）"
fi
if read2 "." "" >/dev/null 2>&1; then bad "4b 空 dest_path 却返回成功"; else ok "4b 空 dest_path → 返回非 0"; fi
if read2 "." "/" >/dev/null 2>&1; then bad "4c 空路径却返回成功"; else ok "4c 空路径 → 返回非 0"; fi

# --- 5. 空 dir_rel 等价于根目录 ---
_d=$(read2 "" "openlist:wopan175/1/1024j/套图/女仆镂空胖次" | sed -n 1p)
[ "$_d" = "$_expect_dst" ] && ok "5a 空 file_dir_rel 等价根目录" || bad "5a: 实得 [$_d]"

# --- 6. 尾部斜杠不应产生空段 ---
_e=$(read2 "." "openlist:wopan175/1/1024j/套图/女仆镂空胖次/" | sed -n 1p)
[ "$_e" = "$_expect_dst" ] && ok "6a dest_path 带尾斜杠仍推导正确" || bad "6a: 实得 [$_e]"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
