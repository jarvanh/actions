#!/bin/bash
# 单子目录跳过大小枚举（2026-11-11 加，run 42830717609 实证）
#
# 背景: wopan176Crypt 的 task1/task0 这类大任务，一级子目录常常只有 1 个
#   （现场: `1024j`，782.286 GiB / 约 20 万文件）。原实现无条件对每个子目录
#   跑 `rclone size`（全递归列举）来"按大小排序"，于是为一个子目录付了
#   **15.5 分钟**（15:37:54 → 15:53:22），把 20 分钟的公平份额吃光 ⇒ 一个字节
#   没传、该对以 `failed · 0 B` 收场。两个含份额修复的轮次里各出现 7 个 0 B 对
#   ≈ 140 分钟/轮（占 320 分钟预算的 44%）纯列举开销。
#
# 断言:
#   A. 只有 1 个子目录 → 完全不调用 rclone size，且排序结果/大小映射仍正确
#   B. 有多个子目录 → 行为不变（仍然逐个列举并按大小升序排序）
#   这两条一起锁住"不改变语义、只省掉无意义列举"。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_SRC="$_REPO_ROOT/.github/scripts/openlist/task_engine.sh"
WORK_DIR="$(mktemp -d)"; trap 'rm -rf "$WORK_DIR"' EXIT

# --- 抽取被测代码块（源码原文，不是复写）---
# 从"只有一个子目录时跳过大小枚举"注释起，到 else 分支末尾的 `fi`
awk '
  /只有一个子目录时\*\*跳过大小枚举/ {start=1}
  start {print}
  start && /rm -rf "\$_sz_dir"/ {saw_rm=1}
  start && saw_rm && /^  fi$/ {exit}
' "$_SRC" > /tmp/ss_block.sh
echo "抽取行数: $(wc -l < /tmp/ss_block.sh)"
grep -q '跳过大小枚举' /tmp/ss_block.sh || { echo "FATAL: 抽取失败(无注释头)"; exit 1; }
grep -q '_rclone_size_json' /tmp/ss_block.sh || { echo "FATAL: 抽取失败(无列举分支)"; exit 1; }
grep -q '^  fi$' /tmp/ss_block.sh || { echo "FATAL: 抽取失败(无收尾 fi)"; exit 1; }
# 快照分支的辅助函数也抽真源（不是复写）
sed -n '/^_subdir_sizes_from_snapshot()/,/^}$/p' "$_SRC" > "$WORK_DIR/snapfn.sh"
[ -s "$WORK_DIR/snapfn.sh" ] || { echo "FATAL: 抽取 _subdir_sizes_from_snapshot 失败"; exit 1; }
# 深层跳过分支依赖 _pair_share_binding（不抽会让条件恒假 → 静默回退枚举，
# 测试就变成"看起来通过其实没测到"）
sed -n '/^_pair_share_binding()/,/^}$/p' "$_SRC" >> "$WORK_DIR/snapfn.sh"
grep -q '_pair_share_binding' "$WORK_DIR/snapfn.sh" || { echo "FATAL: 抽取 _pair_share_binding 失败"; exit 1; }
source "$WORK_DIR/snapfn.sh"

format_bytes() { echo "$1"; }
# 真源按 jq 取字段；这里用 sed 等价实现（桩返回 0 会让所有大小相同、排序断言失效）
_size_json_field() {
  printf '%s' "${1:-}" | sed -n 's/.*"'"${2:-bytes}"'":[[:space:]]*\([0-9]\+\).*/\1/p' | head -1
}

# 计数桩: 每次被调用就记一行，用来断言"有没有真的去列举"
CALLS_FILE=/tmp/ss_calls_$$
: > "$CALLS_FILE"
_rclone_size_json() {
  echo "$1" >> "$CALLS_FILE"
  # 按路径名确定性给大小（并行子 shell 里"第几次调用"不确定，不能用调用序）
  case "$1" in
    *big*)   echo '{"bytes":300}' ;;
    *small*) echo '{"bytes":100}' ;;
    *)       echo '{"bytes":0}' ;;
  esac
}

run_block() {  # $1=subdirs(多行)  $2=source_path  $3=source_size_bytes
  local subdirs="$1" source_path="$2" source_size_bytes="$3"
  # 快照分支会算 stem = task_name + md5(task_name_dest)，故必须提供这两个变量
  local task_name="t_test" dest_path="gd:1"
  local sorted_subdirs=""
  declare -gA subdir_size_map=()
  declare -gA subdir_status_map=()
  eval "$(cat /tmp/ss_block.sh)"
  SUBDIRS_OUT="$subdirs"
  SORTED_OUT="$sorted_subdirs"
}

# ---------- A. 单子目录: 不列举 ----------
: > "$CALLS_FILE"
run_block "1024j" "onedrive:1" "839840000000"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" = "0" ] && ok "A1 单子目录 → 一次 rclone size 都没调用（省掉 15.5 分钟全递归列举）" \
  || bad "A1 单子目录却列举了 ${_n} 次"
[ "${subdir_size_map[1024j]:-}" = "839840000000" ] \
  && ok "A2 大小映射沿用已算好的源端总量（同一棵子树，无需重列）" \
  || bad "A2 映射值=${subdir_size_map[1024j]:-空}"
[ "$(printf '%s' "$SORTED_OUT" | tr -d '\n')" = "839840000000 1024j" ] \
  && ok "A3 排序串仍产出（后续 subdirs 提取口径不变）" \
  || bad "A3 排序串=[$SORTED_OUT]"

# ---------- A4. 单子目录且名字含空格: 不能被切坏 ----------
: > "$CALLS_FILE"
run_block "my big dir" "onedrive:1" "12345"
_after=$(printf '%s' "$SORTED_OUT" | sort -n | cut -d' ' -f2-)
[ "$_after" = "my big dir" ] && ok "A4 名字含空格仍能完整取回" || bad "A4 取回=[$_after]"

# ---------- B. 多子目录: 行为不变 ----------
: > "$CALLS_FILE"
run_block $'big\nsmall' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" = "2" ] && ok "B1 2 个子目录 → 仍然逐个列举（语义不变）" || bad "B1 列举次数=${_n}"
_ordered=$(printf '%s' "$SORTED_OUT" | sort -n | cut -d' ' -f2- | tr '\n' ',')
[ "$_ordered" = "small,big," ] \
  && ok "B2 仍按大小升序（小目录先同步，进度可见）" \
  || bad "B2 排序=[$_ordered]"

# ---------- C. 空/零字节兜底不能崩 ----------
: > "$CALLS_FILE"
run_block "only" "onedrive:1" ""
[ "${subdir_size_map[only]:-x}" = "0" ] \
  && ok "C1 source_size_bytes 为空 → 映射记 0（不产生非数字）" \
  || bad "C1 映射=${subdir_size_map[only]:-空}"

rm -f "$CALLS_FILE"
# ---------- D. 快照可用时: 多子目录也零列举（2026-11-11 加）----------
# 单子目录跳过只治最外层；task1 递归进 1024j（782 GiB / 20 万文件）后这一层
# 仍会全递归列举。系统写 marker 时已存源端清单快照，直接本地求和即可。
# 注: 真实 stem 由 md5(task_name_dest) 决定，测试无法预置 ⇒ 桩掉
#     _listing_snapshot_path 指向固定文件（被测逻辑只关心"能不能读到快照"）。
SNAP_DIR="$WORK_DIR/snap"; mkdir -p "$SNAP_DIR"
SNAP_FILE="$SNAP_DIR/fixed.listing.json.gz"
_listing_snapshot_path() { echo "$SNAP_FILE"; }
# 桩 rclone: 只支持 cat（读快照）；其余调用记入 CALLS_FILE 视为"真去列举了"
rclone() {
  if [ "$1" = "cat" ]; then cat "$2"; return 0; fi
  echo "UNEXPECTED rclone $*" >> "$CALLS_FILE"; return 0
}
printf 'big/a.mkv\t300\nbig/b.mkv\t100\nsmall/c.jpg\t50\n' | gzip -c > "$SNAP_FILE"

: > "$CALLS_FILE"
run_block $'big\nsmall' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" = "0" ] && ok "D1 快照覆盖全部子目录 → 一次 rclone size 都没调用" \
  || bad "D1 仍列举了 ${_n} 次"
[ "${subdir_size_map[big]:-}" = "400" ] && ok "D2 快照求和正确（big=300+100）" \
  || bad "D2 big=${subdir_size_map[big]:-空}"
[ "${subdir_size_map[small]:-}" = "50" ] && ok "D3 small=50" || bad "D3 small=${subdir_size_map[small]:-空}"
_ord=$(printf '%s' "$SORTED_OUT" | sort -n | cut -d' ' -f2- | tr '\n' ',')
[ "$_ord" = "small,big," ] && ok "D4 仍按大小升序" || bad "D4 排序=[$_ord]"

# ---------- D5. 快照缺新子目录 → 必须回退列举（不能把新目录当 0 字节）----------
: > "$CALLS_FILE"
run_block $'big\nbrandnew' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" -ge 2 ] && ok "D5 快照未覆盖新子目录 → 回退列举（${_n} 次）" \
  || bad "D5 未回退，列举次数=${_n}"

# ---------- D6. 快照不存在 → 回退列举 ----------
SNAP_FILE="$SNAP_DIR/does_not_exist.listing.json.gz"
: > "$CALLS_FILE"
run_block $'big\nsmall' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" -ge 2 ] && ok "D6 无快照 → 回退列举（${_n} 次）" || bad "D6 未回退，列举次数=${_n}"

# ---------- E. 深层 + 份额生效: 完全不枚举（2026-11-11 加）----------
# 现场（run 42957096246，head 82effd6）: 大对递归进 depth=1 后仍要全递归列举
#   782 GiB / 6 万文件，第 11 对为此花了 23 分钟（06:20 → 06:43）然后份额到点
#   ⇒ 0 B。整轮 12 个 0 B 对、净传仅 3.339 GiB（前一轮 42.469 GiB）。
#   深层没有快照（该层从未写成功 marker ⇒ 鸡生蛋），故必须整段跳过枚举。
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 1200 ))
: > "$CALLS_FILE"
current_depth=1
run_block $'zeta\nalpha\nmid' "onedrive:1" "839840000000"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" = "0" ] && ok "E1 depth=1 且份额生效 → 一次 rclone size 都没调用" \
  || bad "E1 仍列举了 ${_n} 次"
# 不能再排序（键全为 0，sort 不稳定会打乱）⇒ 必须是原列举顺序
_ord=$(printf '%s' "$SORTED_OUT" | cut -d' ' -f2- | tr '\n' ',')
[ "$_ord" = "zeta,alpha,mid," ] && ok "E2 保持 rclone lsf 的列举顺序（不排序、不打乱）" \
  || bad "E2 顺序=[$_ord]"

# E3: 深层但**无份额**（串行/调试）→ 必须保持原行为（仍枚举并排序）
unset OPENLIST_PAIR_DEADLINE_EPOCH OPENLIST_SYNC_DEADLINE_EPOCH
: > "$CALLS_FILE"
current_depth=1
run_block $'zeta\nalpha\nmid' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" -ge 3 ] && ok "E3 depth=1 但无份额约束 → 仍枚举（串行/调试行为不变，${_n} 次）" \
  || bad "E3 无份额却跳过枚举（会改变串行/调试行为，${_n} 次）"

# E4: depth=0 + 份额生效 → 不走该捷径（外层仍按大小排序，便于小目录先完成）
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 1200 ))
: > "$CALLS_FILE"
current_depth=0
run_block $'big\nsmall' "onedrive:1" "999"
_n=$(wc -l < "$CALLS_FILE")
[ "$_n" -ge 2 ] && ok "E4 depth=0 + 份额生效 → 仍按大小枚举排序（外层保留观感优化）" \
  || bad "E4 depth=0 也跳过了枚举（${_n} 次）"
unset OPENLIST_SYNC_DEADLINE_EPOCH OPENLIST_PAIR_DEADLINE_EPOCH
current_depth=0

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
