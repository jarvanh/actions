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
RC_DELETE_FAIL=0    # 1 = 模拟清空失败（如 flag 写错 / 权限不足）
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
      # ⚠️ 真 rclone delete **没有 --files-only**（那是 lsf/copy 的 flag）。mock 里把
      # 未知 flag 做成硬失败，才能锁住"写了一堆 filter flag 结果一条都没删"的事故
      # —— run 35521483745 就是这么静默失败的: 归档成功、清空 0 条、结论仍是"剩
      # 426 个"，靠人工看日志才发现。
      for a in "$@"; do
        case "$a" in
          --files-only|--include*|--exclude*|--filter*|--min-age*|--max-age*)
            echo "Fatal error: unknown flag: $a" >&2; return 1 ;;
        esac
      done
      # 同 lsf: 路径 = 第一个非 flag 参数（`rclone delete <path> [flags]`）
      local p=""; for a in "$@"; do case "$a" in "$sub"|-*) ;; *) p="$a"; break;; esac; done
      # RC_DELETE_FAIL 放在删之前: 真机的 unknown-flag 形态是**一条都不删**就返回
      # 非零（run 35521483745 实况）；"删到一半失败"则由脚本的 del_rc 分支 + left>0
      # 覆盖 —— 两种形态都必须判红，不能报"已清空"。
      [ "$RC_DELETE_FAIL" = "1" ] && return 1
      rm -f "$p"/*.json 2>/dev/null
      ;;
    mkdir) return 0 ;;
    *) return 0 ;;
  esac
  return 0
}
export -f rclone
export RC_DELETE_LOG RC_COPYTO_FAIL RC_DELETE_FAIL

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

# ===== 场景5: delete 失败（如 flag 写错）⇒ 必须报失败，不能假装清空 =====
# 真机教训（run 35521483745）: `rclone delete ... --files-only` 是 unknown flag，
# 一条都没删；而 `cmd | tail -3` 又把真实 rc 吞成 0 —— 两层掩盖叠加，只剩"剩 426 个"
# 这一句人肉可辨。这里用 delete 失败 + 脚本必须判红来锁住两层。
for i in 1 2 3; do printf '{}' > "$WORK/state/task_$i.json"; done
: > "$RC_DELETE_LOG"
RC_DELETE_FAIL=1
out=$(bash "$RESET_SH" --commit 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "5a delete 失败 ⇒ 脚本判红（rc 不被管道吞掉）" || bad "5a rc=0，失败被掩盖: $out"
echo "$out" | grep -q "rclone delete 返回非零" && ok "5b 明确报出 delete 失败" || bad "5b: $out"
[ "$(ls "$WORK/state" | wc -l | tr -d ' ')" = "3" ] && ok "5c 失败时 marker 仍在（未误判为已清空）" || bad "5c 文件被删了"
RC_DELETE_FAIL=0

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
