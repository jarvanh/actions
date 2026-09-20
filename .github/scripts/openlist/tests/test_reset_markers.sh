#!/bin/bash
# marker 归档 + 重置脚本（reset_markers.sh）行为验证
#
# 为什么测它: 这是**不可逆**的运维操作（清空 marker = 丢掉修复文件还原链路的
#   唯一索引）。脚本自身的安全边界必须被锁住，不能靠"跑之前小心一点":
#     1. 归档失败 ⇒ 必须拒绝清空（没有退路就不许动手）
#     2. 读取异常（下载数 < 列表数）⇒ 必须拒绝继续（不在半截数据上做不可逆操作）
#     3. 默认 dry-run ⇒ 不得删除任何东西
#   这三条任一失守，都会把"清洗脏数据"变成"制造灾难"。
#
# 用法: bash test_reset_markers.sh
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WORK=/tmp/reset_markers_test
rm -rf "$WORK"; mkdir -p "$WORK/state" "$WORK/archive"
# 造 3 个 marker 文件
for i in 1 2 3; do printf '{"last_success":"2026-09-19T19:39:07Z","fixed_files":[]}' > "$WORK/state/task_$i.json"; done

export SYNC_STATE_DIR="$WORK/state"
export MARKER_RESET_ARCHIVE="$WORK/archive"

# rclone mock: 本地目录模拟远端；RC_DELETE_LOG 记录删除调用
RC_DELETE_LOG="$WORK/delete.log"; : > "$RC_DELETE_LOG"
RC_COPYTO_FAIL=0    # 1 = 模拟归档上传失败
rclone() {
  local sub="$1"
  case "$sub" in
    lsf)
      # 路径 = **第一个非 flag 参数**（生产调用是 `rclone lsf <path> --files-only`，
      # flag 在后；取"最后一个"会拿到 --files-only ⇒ 列表恒空 ⇒ 测试假红）
      local p=""; for a in "$@"; do case "$a" in "$sub"|-*) ;; *) p="$a"; break;; esac; done
      (cd "$p" 2>/dev/null && ls) || return 0
      ;;
    copy)
      # copy <src> <dst>
      local src="$2" dst="$3"
      mkdir -p "$dst"
      (cd "$src" && cp -r . "$dst"/) 2>/dev/null
      ;;
    copyto)
      [ "$RC_COPYTO_FAIL" = "1" ] && return 1
      cp "$2" "$3" 2>/dev/null || return 1
      ;;
    delete)
      echo "DELETE $*" >> "$RC_DELETE_LOG"
      # 同 lsf: 路径 = 第一个非 flag 参数（`rclone delete <path> --files-only`）
      local p=""; for a in "$@"; do case "$a" in "$sub"|-*) ;; *) p="$a"; break;; esac; done
      rm -f "$p"/*.json 2>/dev/null
      ;;
    mkdir) return 0 ;;
    *) return 0 ;;
  esac
  return 0
}
export -f rclone
export RC_DELETE_LOG RC_COPYTO_FAIL

RESET_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/reset_markers.sh"

# ===== 场景1: 默认 dry-run ⇒ 什么都不删 =====
out=$(bash "$RESET_SH" 2>&1)
echo "$out" | grep -q "dry-run（只打印，不删）" && ok "1a 默认走 dry-run" || bad "1a 未走 dry-run"
[ ! -s "$RC_DELETE_LOG" ] && ok "1b dry-run 未调用任何删除" || bad "1b 调了删除: $(cat "$RC_DELETE_LOG")"
[ "$(ls "$WORK/state" | wc -l | tr -d ' ')" = "3" ] && ok "1c 3 个 marker 都还在" || bad "1c 文件被删了"

# ===== 场景2: --commit 且归档成功 ⇒ 归档先落盘，再清空 =====
out=$(bash "$RESET_SH" --commit 2>&1)
echo "$out" | grep -q "✅ 归档已上传" && ok "2a 归档上传成功" || bad "2a: $out"
[ -n "$(ls "$WORK/archive" 2>/dev/null)" ] && ok "2b 归档包真落盘（有回滚副本）" || bad "2b 归档包没落盘"
echo "$out" | grep -q "✅ 已清空" && ok "2c 清空成功" || bad "2c: $out"
[ "$(ls "$WORK/state" | wc -l | tr -d ' ')" = "0" ] && ok "2d marker 目录已空" || bad "2d 仍有残留"

# 归档包内容可用性（回滚的前提: 包里得真有那 3 个 marker）
ARC=$(ls "$WORK/archive"/*.tar.gz 2>/dev/null | head -1)
[ -n "$ARC" ] && tar -tzf "$ARC" 2>/dev/null | grep -q "task_1.json" \
  && ok "2e 归档包含全部 marker（可回滚）" || bad "2e 归档包内容不全"

# ===== 场景3: 归档上传失败 ⇒ 必须拒绝清空（没有退路就不许动手）=====
# 重建现场
for i in 1 2 3; do printf '{}' > "$WORK/state/task_$i.json"; done
: > "$RC_DELETE_LOG"
RC_COPYTO_FAIL=1
out=$(bash "$RESET_SH" --commit 2>&1)
echo "$out" | grep -q "拒绝清空" && ok "3a 归档失败 ⇒ 拒绝清空" || bad "3a: $out"
[ ! -s "$RC_DELETE_LOG" ] && ok "3b 归档失败时未调用删除" || bad "3b 竟然删了: $(cat "$RC_DELETE_LOG")"
[ "$(ls "$WORK/state" | wc -l | tr -d ' ')" = "3" ] && ok "3c 3 个 marker 完好无损" || bad "3c 文件被删了"
RC_COPYTO_FAIL=0

# ===== 场景4: 列表为空 ⇒ 拒绝继续（无法确认要清什么）=====
rm -f "$WORK/state"/*.json
: > "$RC_DELETE_LOG"
out=$(bash "$RESET_SH" --commit 2>&1)
echo "$out" | grep -q "列表为空" && ok "4a 列表为空 ⇒ 拒绝继续" || bad "4a: $out"
[ ! -s "$RC_DELETE_LOG" ] && ok "4b 空列表时未删除" || bad "4b 竟然删了"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
