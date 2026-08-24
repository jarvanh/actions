#!/bin/bash
# _batch_consolidate（批次级巩固）——逻辑验证（mock rclone/_restart_openlist_for_truth 等）
# 验证:
#   1. 非 openlist: 目标 → 直接跳过（不重启/不列表/不重试）
#   2. 本批无传输（日志无 Copied 行）→ 跳过巩固
#   3. 传输全部真实落盘（真值清单都在）→ 重启校验但不重试
#   4. 假成功/失败混合 → 未落盘文件（排除 object not found）串行重试一次
#   5. 容器重启失败 → 跳过校验（不列表/不重试），恒返回 0
#   6. 目标端列表为空/失败 → 跳过重试（避免半截列表误判全量缺失）
#   7. OPENLIST_BATCH_CONSOLIDATE=0 → 关闭巩固
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- source 被测代码 ---
source "$_REPO_ROOT/.github/scripts/openlist/tasks.sh" 2>/dev/null

BC_DIR="/tmp/bc_test_dir"
LSF_OUT="/tmp/bc_lsf_out.txt"
RESTART_RC=0

# --- mocks（source 之后定义）---
timeout() { shift; "$@"; }                 # 剥掉时长参数（rclone 是函数，不能被真 timeout 执行）
progress_update() { :; }
_refresh_ol_drivers() { :; }
_restart_openlist_for_truth() {
  [ "$RESTART_RC" = "0" ] || return 1
  touch /tmp/bc_restarted
  return 0
}
rclone() {
  case "$1" in
    lsf)
      echo $(( $(cat /tmp/bc_lsf_calls 2>/dev/null || echo 0) + 1 )) > /tmp/bc_lsf_calls
      cat "$LSF_OUT" 2>/dev/null
      ;;
    copy)
      echo $(( $(cat /tmp/bc_copy_calls 2>/dev/null || echo 0) + 1 )) > /tmp/bc_copy_calls
      # 捕获 --files-from 清单；对清单内每个文件模拟串行重传成功
      local _prev="" _a
      for _a in "$@"; do
        [ "$_prev" = "--files-from" ] && cp "$_a" /tmp/bc_files_from
        _prev="$_a"
      done
      local _f
      while IFS= read -r _f; do
        [ -z "$_f" ] && continue
        echo "INFO  : ${_f}: Copied (new)"
      done < /tmp/bc_files_from
      ;;
    *) return 0 ;;
  esac
}

# 作用域包装: _batch_consolidate 依赖调用方作用域变量（bash 动态作用域）
run_consolidate() {
  local dest_path="$BC_DEST"
  local source_path="onedrive:0"
  local task_name="t"
  local batch_dir="$BC_DIR"
  local extra_args=(--delete-before)
  _batch_consolidate "$1" "$2"
}

setup() {
  rm -rf "$BC_DIR"
  mkdir -p "$BC_DIR"
  rm -f /tmp/bc_restarted /tmp/bc_files_from
  echo 0 > /tmp/bc_lsf_calls
  echo 0 > /tmp/bc_copy_calls
  RESTART_RC=0
  : > "$LSF_OUT"
}
calls() { cat "$1" 2>/dev/null || echo 0; }

# 含传输的批次日志: 2 个 Copied（其一将成假成功）+ 1 个真失败 + 1 个源端不存在
write_batch_log() {
  cat > "$1" <<'EOF'
INFO  : ok/file1.mp4: Copied (new)
INFO  : ghost/file2.mp4: Copied (new)
ERROR : bad/file3.mp4: Failed to copy: 500 Internal Server Error
ERROR : gone/file4.mp4: Failed to copy: object not found
EOF
}
LOG="$BC_DIR/batch.log"

# --- 场景1: 非 openlist: 目标 → 直接跳过 ---
setup
BC_DEST="onedrive:backup"
write_batch_log "$LOG"
OUT=$(run_consolidate 0 "$LOG")
[ ! -f /tmp/bc_restarted ] && [ "$(calls /tmp/bc_lsf_calls)" = "0" ] && [ "$(calls /tmp/bc_copy_calls)" = "0" ] \
  && ok "1 非 openlist: 目标 → 不重启/不列表/不重试" || bad "1: restart/lsf/copy 异常"

# --- 场景2: 无传输 → 跳过巩固 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
echo "INFO  : stats line only, no transfers" > "$LOG"
OUT=$(run_consolidate 0 "$LOG")
[ ! -f /tmp/bc_restarted ] && [ "$(calls /tmp/bc_lsf_calls)" = "0" ] && [ "$(calls /tmp/bc_copy_calls)" = "0" ] \
  && ok "2 无传输 → 不重启/不列表/不重试" || bad "2: restart/lsf/copy 异常"
echo "$OUT" | grep -q "本批无传输" && ok "2b 走无传输路径提示" || bad "2b: $OUT"

# --- 场景3: 传输全部落盘 → 重启校验但不重试 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
cat > "$LOG" <<'EOF'
INFO  : ok/file1.mp4: Copied (new)
INFO  : ok/file2.mp4: Copied (new)
EOF
printf 'ok/file1.mp4\nok/file2.mp4\n' > "$LSF_OUT"
OUT=$(run_consolidate 0 "$LOG")
[ -f /tmp/bc_restarted ] && ok "3a 有传输 → 重启容器取真值" || bad "3a: 未重启"
[ "$(calls /tmp/bc_lsf_calls)" = "1" ] && ok "3b 真值列表取 1 次" || bad "3b: lsf=$(calls /tmp/bc_lsf_calls)"
[ "$(calls /tmp/bc_copy_calls)" = "0" ] && ok "3c 全部落盘 → 不重试" || bad "3c: copy=$(calls /tmp/bc_copy_calls)"
echo "$OUT" | grep -q "全部真实落盘" && ok "3d 全部落盘提示" || bad "3d: $OUT"

# --- 场景4: 假成功 + 失败混合 → 未落盘文件串行重试（排除 object not found）---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
OUT=$(run_consolidate 0 "$LOG")
[ -f /tmp/bc_restarted ] && ok "4a 有传输 → 重启容器" || bad "4a"
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "4b 触发一次串行重试" || bad "4b: copy=$(calls /tmp/bc_copy_calls)"
# 重试清单 = 假成功 ghost/file2 + 真失败 bad/file3（gone 为 object not found，源端不存在不重试）
diff <(sort /tmp/bc_files_from) <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "4c 重试清单 = 假成功+失败（排除 object not found）" || bad "4c: $(cat /tmp/bc_files_from 2>/dev/null | tr '\n' ' ')"
echo "$OUT" | grep -q "重传 2/2" && ok "4d 重传计数 2/2" || bad "4d: $OUT"

# --- 场景5: 容器重启失败 → 跳过校验 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
RESTART_RC=1
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_lsf_calls)" = "0" ] && [ "$(calls /tmp/bc_copy_calls)" = "0" ] \
  && ok "5a 重启失败 → 不列表/不重试" || bad "5a: lsf/copy 异常"
echo "$OUT" | grep -q "容器重启失败" && ok "5b 重启失败提示（最终检查兜底）" || bad "5b: $OUT"

# --- 场景6: 目标端列表为空 → 跳过重试（防半截列表误判全量缺失）---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
: > "$LSF_OUT"
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_copy_calls)" = "0" ] && ok "6a 列表为空 → 不重试" || bad "6a: copy=$(calls /tmp/bc_copy_calls)"
echo "$OUT" | grep -q "列表获取失败/为空" && ok "6b 空列表提示" || bad "6b: $OUT"

# --- 场景7: 开关关闭 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
OUT=$(OPENLIST_BATCH_CONSOLIDATE=0 run_consolidate 0 "$LOG")
[ ! -f /tmp/bc_restarted ] && [ "$(calls /tmp/bc_lsf_calls)" = "0" ] && [ "$(calls /tmp/bc_copy_calls)" = "0" ] \
  && ok "7 OPENLIST_BATCH_CONSOLIDATE=0 → 全部跳过" || bad "7: restart/lsf/copy 异常"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$BC_DIR" /tmp/bc_* "$LSF_OUT"
[ $FAIL -eq 0 ]
