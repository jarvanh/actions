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
      echo "${_f}|${_f}|修复mock|restore|1B|1|文件修复方法3 zip_split_original: zip 压缩 + 分卷上传（原文件名基底，默认 1GB 分卷）" >> "$fix_list"
    done < "$SYNC_FIX_MISSING_OVERRIDE"
  fi
  return 0
}
_sync_serialize_fixed_files() { :; }
_sync_accumulate_fixed_results() { :; }
# 复核步骤依赖的黑名单/展示工具（真实实现在 fix.sh / utils.sh）
# 拉黑明细落文件: 函数内对关联数组的写入发生在被测函数的作用域里，
# 父作用域直接读数组读不到，断言改用文件内容校验
declare -A FIX_METHOD_BLACKLIST=()
_blacklist_add() {
  echo "$1|$2" >> /tmp/bc_blacklist_ops
  local cur="${FIX_METHOD_BLACKLIST[$1]:-}"
  case "|$cur|" in *"|$2|"*) return 0 ;; esac
  FIX_METHOD_BLACKLIST["$1"]="${cur:+$cur|}$2"
}
_flush_blacklist_to_marker() { :; }
_method_short() { echo "$1"; }
_short_path() { echo "$1"; }
# RESTART_FAIL_FROM: 从第 N 次调用起开始失败（0/空 = 永不失败）
# 用于"只让复核阶段重启失败"这类定向场景
RESTART_FAIL_FROM=0
_restart_openlist_for_truth() {
  local _n
  _n=$(( $(cat /tmp/bc_restart_calls 2>/dev/null || echo 0) + 1 ))
  echo "$_n" > /tmp/bc_restart_calls
  if [ "${RESTART_FAIL_FROM:-0}" -gt 0 ] && [ "$_n" -ge "$RESTART_FAIL_FROM" ]; then
    return 1
  fi
  [ "$RESTART_RC" = "0" ] || return 1
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
  BATCH_BACKEND_DEAD=0
  _batch_consolidate "$1" "$2"
  echo "${BATCH_BACKEND_DEAD:-0}" > /tmp/bc_backend_dead
}

setup() {
  rm -rf "$BC_DIR"
  mkdir -p "$BC_DIR"
  rm -f /tmp/bc_restarted /tmp/bc_files_from /tmp/bc_fixpipe_override /tmp/bc_blacklist_ops
  echo 0 > /tmp/bc_lsf_calls
  echo 0 > /tmp/bc_copy_calls
  echo 0 > /tmp/bc_restart_calls
  echo 0 > /tmp/bc_refresher_starts
  echo 0 > /tmp/bc_refresher_stops
  echo 0 > /tmp/bc_fixpipe_calls
  RESTART_RC=0
  RESTART_FAIL_FROM=0
  RETRY_COPY_OK=1
  LSF_OUT2=""
  FIX_METHOD_BLACKLIST=()
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
[ "$(cat /tmp/bc_backend_dead 2>/dev/null)" = "0" ] && ok "4j 重试有产出 → 不触发后端全拒" || bad "4j: dead=$(cat /tmp/bc_backend_dead 2>/dev/null)"

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
diff <(sort "$(cat /tmp/bc_fixpipe_override 2>/dev/null)") <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "8c 修复管线收到的清单 = 重试后仍未落盘的顽固缺失" || bad "8c: $(cat "$(cat /tmp/bc_fixpipe_override 2>/dev/null)" 2>/dev/null | tr '\n' ' ')"
echo "$OUT" | grep -q "顽固缺失" && echo "$OUT" | grep -q "修复管线换方法落盘" \
  && ok "8d 顽固缺失转修复管线提示" || bad "8d: $OUT"
echo "$OUT" | grep -q "修复管线完成，2/2" && ok "8e 修复计数汇总" || bad "8e: $OUT"

# --- 场景9: 重试全部失败（0 重传）→ 不二次重启，直接全部转修复管线 ---
# 注: 修复管线之后还有一次"修复成果复核重启"（见场景 11），故 restart 计 2 次
#  （入口校验 1 + 修复复核 1）；0 重传省掉的是"重试后二次重启"那一次
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
RETRY_COPY_OK=0
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "9a 串行重试执行" || bad "9a: copy=$(calls /tmp/bc_copy_calls)"
[ "$(calls /tmp/bc_restart_calls)" = "2" ] && ok "9b 0 重传 → 不做重试后二次重启（restart=入口校验+修复复核）" || bad "9b: restart=$(calls /tmp/bc_restart_calls)"
[ "$(calls /tmp/bc_fixpipe_calls)" = "1" ] && ok "9c 全部转修复管线" || bad "9c: fixpipe=$(calls /tmp/bc_fixpipe_calls)"
diff <(sort "$(cat /tmp/bc_fixpipe_override 2>/dev/null)") <(printf 'bad/file3.mp4\nghost/file2.mp4\n') >/dev/null 2>&1 \
  && ok "9d 修复清单 = 全部重试失败文件" || bad "9d: $(cat "$(cat /tmp/bc_fixpipe_override 2>/dev/null)" 2>/dev/null | tr '\n' ' ')"
[ "$(cat /tmp/bc_backend_dead 2>/dev/null)" = "0" ] && ok "9e 缺失数 <3 → 不触发后端全拒（仍进修复管线）" || bad "9e: dead=$(cat /tmp/bc_backend_dead 2>/dev/null)"

# --- 场景10: 后端写入全拒（≥3 触碰文件 0 落盘 + 重试 0 成功）→ 置标志跳过修复管线 ---
setup
BC_DEST="openlist:wopan175/0/j-1024j-视频-pornhub-favorites"
cat > "$LOG" <<'EOF'
INFO  : dead/file1.mp4: Copied (new)
INFO  : dead/file2.mp4: Copied (new)
INFO  : dead/file3.mp4: Copied (new)
ERROR : dead/file4.mp4: Failed to copy: unchunked simple update failed: Method Not Allowed: 405 Method Not Allowed
EOF
printf 'other/old.mp4\n' > "$LSF_OUT"   # 真值列表仅有无关旧文件: 本批 4 个文件后端一个都没收到（405 全拒）
RETRY_COPY_OK=0         # 串行重试全部 405
OUT=$(run_consolidate 0 "$LOG")
[ "$(calls /tmp/bc_copy_calls)" = "1" ] && ok "10a 串行重试执行" || bad "10a: copy=$(calls /tmp/bc_copy_calls)"
[ "$(cat /tmp/bc_backend_dead 2>/dev/null)" = "1" ] && ok "10b 全拒 → 置 BATCH_BACKEND_DEAD" || bad "10b: dead=$(cat /tmp/bc_backend_dead 2>/dev/null)"
[ "$(calls /tmp/bc_fixpipe_calls)" = "0" ] && ok "10c 全拒 → 跳过修复管线" || bad "10c: fixpipe=$(calls /tmp/bc_fixpipe_calls)"
echo "$OUT" | grep -q "后端写入全拒" && ok "10d 全拒提示" || bad "10d: $OUT"
echo "$OUT" | grep -q "跳过修复管线" && ok "10e 跳过修复管线提示" || bad "10e: $OUT"

# --- 场景11: 修复管线后重启复核 — 假成功条目被剔除，真成果保留 ---
# 背景: 修复方法返回成功只代表 PUT 被接受，与批次传输假成功同源。修复
#   管线此前没有重启复核，17/68 这类成功数里混有多少假成功无从得知，
#   写进 marker 后还会被下一轮当"沿用上轮修复"永久跳过。
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
RETRY_COPY_OK=0
# 修复 mock 产出 2 条（bad/file3、ghost/file2）；复核真值只认下 bad/file3
# → ghost/file2 判假成功，应从 fix_list 剔除 + 拉黑 + 转失败清单
cat > "/tmp/bc_lsf_out3.txt" <<'EOF'
ok/file1.mp4
other/old.mp4
bad/file3.mp4
EOF
LSF_OUT2="/tmp/bc_lsf_out3.txt"
OUT=$(run_consolidate 0 "$LOG")
echo "$OUT" | grep -q "修复复核 1 个真实落盘 / 1 个假成功已剔除" \
  && ok "11a 复核识别出 1 真 1 假" || bad "11a: $OUT"
[ "$(wc -l < "$BC_DIR/consolidate_fix_0.txt" | tr -d ' ')" = "1" ] \
  && ok "11b fix_list 只留真成果（假成功已剔除，不进 marker）" || bad "11b: $(cat "$BC_DIR/consolidate_fix_0.txt")"
cut -d'|' -f1 "$BC_DIR/consolidate_fix_0.txt" | grep -qxF "bad/file3.mp4" \
  && ok "11c 保留的是重启后仍在的条目" || bad "11c: $(cat "$BC_DIR/consolidate_fix_0.txt")"
cut -d'|' -f1 "$BC_DIR/consolidate_fix_0.txt" | grep -qxF "ghost/file2.mp4" \
  && bad "11c2 假成功不应留在 fix_list" || ok "11c2 假成功已移出 fix_list"
grep -q "ghost/file2.mp4" "$BC_DIR/consolidate_fail_0.txt" \
  && ok "11d 假成功转记失败清单（下轮继续修）" || bad "11d: $(cat "$BC_DIR/consolidate_fail_0.txt" 2>/dev/null)"
grep -q "^ghost/file2.mp4|" /tmp/bc_blacklist_ops 2>/dev/null \
  && ok "11e 假成功所用方法被拉黑（下轮跳过重演）" || bad "11e: 黑名单未记录 $(cat /tmp/bc_blacklist_ops 2>/dev/null)"

# --- 场景12: 复核重启失败 → 保留修复成果不误删（宁漏判勿误删） ---
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
RETRY_COPY_OK=0
# 复核真值含两条修复成果（替代路径 = 原路径，见 _sync_fix_missing_files mock）
LSF_OUT2="/tmp/bc_lsf_out_all.txt"
printf 'ok/file1.mp4\nother/old.mp4\nbad/file3.mp4\nghost/file2.mp4\n' > "$LSF_OUT2"
OUT=$(run_consolidate 0 "$LOG")
[ "$(wc -l < "$BC_DIR/consolidate_fix_0.txt" | tr -d ' ')" = "2" ] \
  && ok "12a 复核通过时 2 条修复成果全保留" || bad "12a: $(cat "$BC_DIR/consolidate_fix_0.txt")"
echo "$OUT" | grep -q "0 个假成功已剔除" && ok "12a2 复核无假成功" || bad "12a2: $OUT"
setup
BC_DEST="openlist:wopan176Crypt/0"
write_batch_log "$LOG"
printf 'ok/file1.mp4\nother/old.mp4\n' > "$LSF_OUT"
RETRY_COPY_OK=0
# 只让第 2 次（修复复核）重启失败: 入口校验必须成功，否则走不到修复管线
RESTART_FAIL_FROM=2
OUT=$(run_consolidate 0 "$LOG")
RESTART_FAIL_FROM=0
echo "$OUT" | grep -q "跳过修复复核" && ok "12b 复核重启失败 → 跳过复核" || bad "12b: $OUT"
[ "$(wc -l < "$BC_DIR/consolidate_fix_0.txt" | tr -d ' ')" = "2" ] \
  && ok "12c 复核跳过时修复成果不被误删（宁漏判勿误删）" || bad "12c: $(cat "$BC_DIR/consolidate_fix_0.txt")"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -rf "$BC_DIR" /tmp/bc_* "$LSF_OUT" /tmp/bc_lsf_out2.txt
[ $FAIL -eq 0 ]
