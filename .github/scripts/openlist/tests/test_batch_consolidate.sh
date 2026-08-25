#!/bin/bash
# _batch_consolidate（批次级巩固）——逻辑验证（mock rclone/_restart_openlist_for_truth 等）
# 验证:
#   1. 非 openlist: 目标 → 直接跳过（不重启/不列表/不重试）
#   2. 本批无传输（日志无 Copied 行）→ 跳过巩固
#   3. 传输全部真实落盘（真值清单都在）→ 重启校验但不重试
#   4. 假成功/失败混合 → 未落盘文件（排除 object not found）串行重试一次；
#      重试全部补上 → 复核后顽固缺失 0 → 不进修复管线
#   5. 容器重启失败 → 跳过校验（不列表/不重试），恒返回 0
#   6. 目标端列表为空/失败 → 跳过重试（避免半截列表误判全量缺失）
#   7. OPENLIST_BATCH_CONSOLIDATE=0 → 关闭巩固
#   8. 重试后仍未落盘（后端内容性拒收）→ 顽固缺失转修复管线（换方法）
#   9. 重试一个都没成功 → 全部直接转修复管线（不二次重启复核）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- source 被测代码 ---
source "$_REPO_ROOT/.github/scripts/openlist/tasks.sh" 2>/dev/null

BC_DIR="/tmp/bc_test_dir"
LSF_OUT="/tmp/bc_lsf_out.txt"
LSF_OUT2=""          # 第 2+ 次 lsf（复核真值）输出；空 = 沿用 LSF_OUT
RETRY_COPY_OK=1      # 0 = 重试 rclone copy 不产生 Copied 行（全部失败）
RESTART_RC=0

# --- mocks（source 之后定义）---
timeout() { shift; "$@"; }                 # 剥掉时长参数（rclone 是函数，不能被真 timeout 执行）
progress_update() { :; }
_refresh_ol_drivers() { :; }
_start_token_refresher() { echo $(( $(cat /tmp/bc_refresher_starts 2>/dev/null || echo 0) + 1 )) > /tmp/bc_refresher_starts; }
_stop_token_refresher() { echo $(( $(cat /tmp/bc_refresher_stops 2>/dev/null || echo 0) + 1 )) > /tmp/bc_refresher_stops; }
# 修复管线三件套（真实实现在 sync.sh，这里只验证批次巩固的接线与清单传递）
_sync_fix_missing_files() {
  echo $(( $(cat /tmp/bc_fixpipe_calls 2>/dev/null || echo 0) + 1 )) > /tmp/bc_fixpipe_calls
  # SYNC_FIX_MISSING_OVERRIDE 语义 = 缺失清单文件路径（见 sync.sh 实现），记录路径
  echo "${SYNC_FIX_MISSING_OVERRIDE:-}" > /tmp/bc_fixpipe_override
  # 模拟: 清单内每个文件都换方法落盘成功 1 条（fix_list 行数 = 清单文件数）
  local _f
  if [ -n "${SYNC_FIX_MISSING_OVERRIDE:-}" ] && [ -s "$SYNC_FIX_MISSING_OVERRIDE" ]; then
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      echo "${_f}|${_f}|修复mock|restore|1B|1|m3" >> "$fix_list"
    done < "$SYNC_FIX_MISSING_OVERRIDE"
  fi
  return 0
}
_sync_serialize_fixed_files() { :; }
_sync_accumulate_fixed_results() { :; }
_restart_openlist_for_truth() {
  [ "$RESTART_RC" = "0" ] || return 1
  echo $(( $(cat /tmp/bc_restart_calls 2>/dev/null || echo 0) + 1 )) > /tmp/bc_restart_calls
  touch /tmp/bc_restarted
  return 0
}
rclone() {
  case "$1" in
    lsf)
      local _n
      _n=$(( $(cat /tmp/bc_lsf_calls 2>/dev/null || echo 0) + 1 )); echo "$_n" > /tmp/bc_lsf_calls
      if [ "$_n" -ge 2 ] && [ -n "$LSF_OUT2" ]; then cat "$LSF_OUT2" 2>/dev/null
      else cat "$LSF_OUT" 2>/dev/null; fi
      ;;
    copy)
      echo $(( $(cat /tmp/bc_copy_calls 2>/dev/null || echo 0) + 1 )) > /tmp/bc_copy_calls
      # 捕获 --files-from 清单；对清单内每个文件模拟串行重传成功
      local _prev="" _a
      for _a in "$@"; do
        [ "$_prev" = "--files-from" ] && cp "$_a" /tmp/bc_files_from
        _prev="$_a"
      done
      [ "$RETRY_COPY_OK" = "1" ] || return 0
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
  rm -f /tmp/bc_restarted /tmp/bc_files_from /tmp/bc_fixpipe_override
  echo 0 > /tmp/bc_lsf_calls
  echo 0 > /tmp/bc_copy_calls
  echo 0 > /tmp/bc_restart_calls
  echo 0 > /tmp/bc_refresher_starts
  echo 0 > /tmp/bc_refresher_stops
  echo 0 > /tmp/bc_fixpipe_calls
  RESTART_RC=0
  RETRY_COPY_OK=1
  LSF_OUT2=""
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

# --- 场景4: 假成功+失败混合 → 串行重试（排除 object not found）→ 重试补上 → 无顽固缺失 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
# 复核真值: 重试的 bad/file3 + ghost/file2 都已落盘
LSF_OUT2="/tmp/bc_lsf_out2.txt"
printf 'ok/file1.mp4\nother/old.mp4\nbad/file3.mp4\nghost/file2.mp4\n' > "$LSF_OUT2"
OUT=$(run_consolidate 0 "$LOG")
[ -f /tmp/bc_restarted ] && ok "4a 有传输 → 重启容器" || bad "4a"
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "4b 触发一次串行重试" || bad "4b: copy=$(calls /tmp/bc_copy_calls)"
# 重试清单 = 假成功 ghost/file2 + 真失败 bad/file3（gone 为 object not found，源端不存在不重试）
diff <(sort /tmp/bc_files_from) <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "4c 重试清单 = 假成功+失败（排除 object not found）" || bad "4c: $(cat /tmp/bc_files_from 2>/dev/null | tr '\n' ' ')"
echo "$OUT" | grep -q "重传 2/2" && ok "4d 重传计数 2/2" || bad "4d: $OUT"
[ "$(calls /tmp/bc_lsf_calls)" = "2" ] && ok "4e 重试后二次重启取真值复核" || bad "4e: lsf=$(calls /tmp/bc_lsf_calls)"
[ "$(calls /tmp/bc_restart_calls)" = "2" ] && ok "4f 容器重启 2 次（校验+复核）" || bad "4f: restart=$(calls /tmp/bc_restart_calls)"
echo "$OUT" | grep -q "顽固缺失 0 个" && ok "4g 重试补全 → 顽固缺失 0" || bad "4g: $OUT"
[ "$(calls /tmp/bc_fixpipe_calls)" = "0" ] && ok "4h 无顽固缺失 → 不进修复管线" || bad "4h: fixpipe=$(calls /tmp/bc_fixpipe_calls)"
[ "$(calls /tmp/bc_refresher_starts)" = "1" ] && [ "$(calls /tmp/bc_refresher_stops)" = "1" ] \
  && ok "4i 重试期间跑 token 保鲜循环（启停各 1 次）" || bad "4i: start=$(calls /tmp/bc_refresher_starts) stop=$(calls /tmp/bc_refresher_stops)"

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

# --- 场景8: 重试后仍未落盘（后端内容性拒收）→ 顽固缺失转修复管线 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
# 复核真值: 重传的 bad/file3 + ghost/file2 仍未落盘（后端拒收，如密文名超长）
LSF_OUT2="/tmp/bc_lsf_out2.txt"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT2"
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "8a 串行重试执行" || bad "8a: copy=$(calls /tmp/bc_copy_calls)"
[ "$(calls /tmp/bc_fixpipe_calls)" = "1" ] && ok "8b 顽固缺失 → 修复管线被调用" || bad "8b: fixpipe=$(calls /tmp/bc_fixpipe_calls)"
diff <(sort /tmp/bc_fixpipe_override) <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "8c 修复管线收到的清单 = 重试后仍未落盘的顽固缺失" || bad "8c: $(cat /tmp/bc_fixpipe_override 2>/dev/null | tr '\n' ' ')"
echo "$OUT" | grep -q "顽固缺失" && echo "$OUT" | grep -q "修复管线换方法落盘" \
  && ok "8d 顽固缺失转修复管线提示" || bad "8d: $OUT"
echo "$OUT" | grep -q "修复管线完成，2/2" && ok "8e 修复计数汇总" || bad "8e: $OUT"

# --- 场景9: 重试全部失败（0 重传）→ 不二次重启，直接全部转修复管线 ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
RETRY_COPY_OK=0
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "9a 串行重试执行" || bad "9a: copy=$(calls /tmp/bc_copy_calls)"
[ "$(calls /tmp/bc_restart_calls)" = "1" ] && ok "9b 0 重传 → 不做二次重启复核" || bad "9b: restart=$(calls /tmp/bc_restart_calls)"
[ "$(calls /tmp/bc_fixpipe_calls)" = "1" ] && ok "9c 全部转修复管线" || bad "9c: fixpipe=$(calls /tmp/bc_fixpipe_calls)"
diff <(sort /tmp/bc_fixpipe_override) <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "9d 修复清单 = 全部重试失败文件" || bad "9d: $(cat /tmp/bc_fixpipe_override 2>/dev/null | tr '\n' ' ')"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$BC_DIR" /tmp/bc_* "$LSF_OUT" /tmp/bc_lsf_out2.txt
[ $FAIL -eq 0 ]
