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
echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
