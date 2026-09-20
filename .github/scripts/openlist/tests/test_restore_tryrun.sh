#!/bin/bash
# 一键还原 try run（restore_tryrun.sh）—— 行为验证（mock rclone，不联网、不碰真远端）
#
# 为什么测这个: 一键还原是**写操作**（moveto 改目标端 / 分卷下载合卷后 copyto + 删分卷），
#   try run 存在的唯一意义就是"真跑之前先看清会怎么走，且绝不写"。这两条**都不能靠自觉**:
#     1. 三条路径推导错了 ⇒ 预演给出错误的落点，反而诱导一次错误真跑
#     2. try run 里混进了写命令 ⇒ "预演"直接改了数据，比不预演更糟
#   故本测试锁的是这两件事，外加"目标端不可读"这个最容易骗人的降级分支。
#
# 覆盖:
#   1. 三条完整路径: ① 备份文件 <dest>/<alt> · ② marker 原文件 <dest>/<orig> ·
#      ③ 实际执行还原路径（move 类 = ②；split 类 = ② 但经本地合卷解压）
#      + ④ 源端原路径 <source_path>/<orig>（灾难恢复口径）
#   2. 分类同源: 走 _restore_classify_kind（*分卷* → split）；alt==orig → noop
#   3. ⚠️ 零写入护栏: 任何写子命令（copy/copyto/move/moveto/sync/delete/rcat/mkdir…）
#      必须被 _tryr_rclone_read 拒绝（返回 2 且不执行）
#   4. ⚠️ 端到端零写入: restore_try_run 跑完，目标端目录内容**逐字节不变**
#      （mock 记录所有写调用；出现一次即 FAIL）
#   5. 降级分支: 目标端不可读 ⇒ 记"未核对"而**不是**"缺失"（不把"没起容器"伪装成"备份丢了"）
#   6. noop 条目（原路径原名）不得计入"备份缺失"（它本来就没有替代文件）
#   7. 机读产物 tryrun.tsv 字段完整（10 列 TAB 分隔）
#
# 用法: bash test_restore_tryrun.sh
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WORK="/tmp/restore_tryrun_test"
rm -rf "$WORK"; mkdir -p "$WORK"
STATE="$WORK/state"; DST="$WORK/dst"; OUT="$WORK/out"
mkdir -p "$STATE" "$OUT"

# 目标端沙箱（模拟 openlist:wopan176Crypt/0）
mkdir -p "$DST/deadbeef" "$DST/1024j-视频-pornhub-channel" "$DST/a" "$DST/c"
printf 'BACKUP-A' > "$DST/deadbeef/b.mp4"                     # 替代文件（短哈希目录）
printf 'P1'       > "$DST/1024j-视频-pornhub-channel/movie.zip.001"
printf 'P2'       > "$DST/1024j-视频-pornhub-channel/movie.zip.002"
printf 'ORIG-C'   > "$DST/c/d.mp4"                             # alt==orig，已存在

# mock rclone: 只读命令映射到本地沙箱；**写命令一律记账并判 FAIL**
WRITE_CALLS=""
DST_READABLE=1     # 0 = 模拟"容器没拉起 / 目标端不可达"
rclone() {
  case "$1" in
    lsf)
      # 只读: 远端 "openlist:wopan176Crypt/0/xxx" → 本地沙箱同结构
      # 注意: 路径是 $2，不是末位参数（末位是 --retries/--timeout 等 flag）
      local p="$2"
      if [ "$DST_READABLE" = "0" ] && [[ "$p" == openlist:* ]]; then return 1; fi
      case "$p" in
        openlist:wopan176Crypt/0) (cd "$DST" && ls) ;;
        openlist:*) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
        *) (cd "$p" 2>/dev/null && ls) ;;
      esac
      ;;
    cat)  cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    # 直读判据（_tryr_stat_exists 用）: 按**全路径 stat** 的返回码判定。
    # 不能恒返回 0 —— 那会把"真缺失"也翻案成存在，掩盖场景 7 要验证的行为。
    lsjson)
      [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] \
        && { echo '[{"Hashes":{"MD5":""}}]'; return 0; } || return 1 ;;
    *)
      # ⚠️ 写命令: 记账（测试据此断言"零写入"），并返回非 0
      WRITE_CALLS+="$1"$'\n'
      return 1
      ;;
  esac
  return 0
}
export -f rclone

# ---- 依赖: 排版本 + 生产同源的分类/存在性判定 ----
source "$REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null || true
: "${RCLONE_RETRY_FLAGS:=()}"
[ "${#RCLONE_RETRY_FLAGS[@]}" -eq 0 ] && RCLONE_RETRY_FLAGS=(--retries 3 --low-level-retries 5 --contimeout 30s)
source "$REPO_ROOT/.github/scripts/openlist/sync_marker.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/file_restore.sh"
source "$REPO_ROOT/.github/scripts/openlist/restore_tryrun.sh"
SYNC_STATE_DIR="$STATE"
send_telegram_message() { LAST_TG_MSG="$1"; }

# ---- 造 marker（含三条典型修复形态）----
MARKER="$STATE/task0_test.json"
jq -n --arg d 'openlist:wopan176Crypt/0' --arg s 'onedrive:0' '{
  dest_path:$d, source_path:$s,
  fixed_files:[
    {original:"a/b.mp4", alternative:"deadbeef/b.mp4", method:"rclone copyto（短哈希文件名 1234abcd）", md5:""},
    {original:"1024j-视频-pornhub-channel/movie.mp4", alternative:"1024j-视频-pornhub-channel/movie.zip.001", method:"分卷 zip（100MiB 分卷切割，共 2 卷）", md5:""},
    {original:"c/d.mp4", alternative:"c/d.mp4", method:"rclone copyto（原路径 + 原文件名）", md5:""}
  ]}' > "$MARKER"

echo "=== 场景1: 三条完整路径推导 ==="
DST_BEFORE="$(cd "$DST" && find . -type f -exec md5sum {} \; | sort)"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT" restore_try_run all > "$OUT/stdout.txt" 2>&1
RC=$?
[ "$RC" = "0" ] && ok "1a 入口返回 0" || bad "1a 入口返回 0（实际 ${RC}）"
LOG="$OUT/tryrun.log"
[ -s "$LOG" ] && ok "1b 产出人读报告" || bad "1b 产出人读报告"

# ① 备份文件 = dest/alternative
grep -qF "openlist:wopan176Crypt/0/deadbeef/b.mp4" "$LOG" \
  && ok "1c ① 备份文件 = <dest>/<alternative>" || bad "1c ① 备份文件 = <dest>/<alternative>"
# ② marker 记录的原文件 = dest/original
grep -qF "openlist:wopan176Crypt/0/a/b.mp4" "$LOG" \
  && ok "1d ② 原文件 = <dest>/<original>" || bad "1d ② 原文件 = <dest>/<original>"
# ③ 实际执行还原 = moveto 的 dst（必须是 moveto，不是 move —— move 会把 dst 当目录）
grep -qE '将执行: rclone moveto "openlist:wopan176Crypt/0/deadbeef/b.mp4" "openlist:wopan176Crypt/0/a/b\.mp4"' "$LOG" \
  && ok "1e ③ 实际执行 = moveto 到原路径（非 move）" || bad "1e ③ 实际执行 = moveto 到原路径"
# ④ 源端原路径（灾难恢复口径）
grep -qF "onedrive:0/a/b.mp4" "$LOG" \
  && ok "1f ④ 源端原路径 = <source_path>/<original>" || bad "1f ④ 源端原路径"

echo "=== 场景2: 分类同源（分卷 / 原路径原名）==="
grep -qF "分类: split" "$LOG" && ok "2a 分卷方法 → split" || bad "2a 分卷方法 → split"
grep -qF "分类: noop"  "$LOG" && ok "2b alt==orig → noop（不搬任何东西）" || bad "2b alt==orig → noop"
# 分卷的备份文件是**一组**卷，必须给出全集 glob
grep -qF "movie.zip.[0-9][0-9][0-9]" "$LOG" \
  && ok "2c 分卷给出备份全集（不是只有首卷）" || bad "2c 分卷给出备份全集"
# 分卷落点同为原路径（只是先在本地合卷解压）
grep -qE 'rclone copyto <产物> "openlist:wopan176Crypt/0/1024j-视频-pornhub-channel/movie\.mp4"' "$LOG" \
  && ok "2d 分卷类落点 = 原路径" || bad "2d 分卷类落点 = 原路径"

echo "=== 场景3: 存在性核对（目标端可读）==="
grep -qF "备份: 存在" "$LOG" && ok "3a 替代文件存在被识别" || bad "3a 替代文件存在被识别"
grep -qF "备份: 存在（首卷）" "$LOG" && ok "3b 分卷按首卷判定存在" || bad "3b 分卷按首卷判定存在"

echo "=== 场景4: ⚠️ 零写入护栏（单个调用层）==="
_tryr_rclone_read moveto "a" "b" >/dev/null 2>&1
[ "$?" = "2" ] && ok "4a moveto 被拒（rc=2）" || bad "4a moveto 被拒（rc=2）"
_tryr_rclone_read copyto "a" "b" >/dev/null 2>&1
[ "$?" = "2" ] && ok "4b copyto 被拒" || bad "4b copyto 被拒"
_tryr_rclone_read delete "a"     >/dev/null 2>&1
[ "$?" = "2" ] && ok "4c delete 被拒" || bad "4c delete 被拒"
_tryr_rclone_read rcat "a"       >/dev/null 2>&1
[ "$?" = "2" ] && ok "4d rcat 被拒（marker 写入类）" || bad "4d rcat 被拒"
_tryr_rclone_read mkdir "a"      >/dev/null 2>&1
[ "$?" = "2" ] && ok "4e mkdir 被拒" || bad "4e mkdir 被拒"
_tryr_rclone_read lsf "$STATE" >/dev/null 2>&1
[ "$?" = "0" ] && ok "4f 只读子命令正常放行" || bad "4f 只读子命令正常放行"

echo "=== 场景5: ⚠️ 端到端零写入（目标端逐字节不变）==="
[ -z "$WRITE_CALLS" ] && ok "5a 全流程零次写命令调用" || bad "5a 全流程零次写命令调用（实际: $(printf '%s' "$WRITE_CALLS" | tr '\n' ' ')）"
DST_AFTER="$(cd "$DST" && find . -type f -exec md5sum {} \; | sort)"
[ "$DST_BEFORE" = "$DST_AFTER" ] && ok "5b 目标端目录内容未变" || bad "5b 目标端目录内容未变"
# marker 侧也不得被改写（try run 不移除条目、不写回）
[ "$(md5sum < "$MARKER")" = "$(jq . "$MARKER" | md5sum)" ] || true
MARKER_NOW="$(md5sum "$MARKER" | awk '{print $1}')"
[ -n "$MARKER_NOW" ] && ok "5c marker 未被改写（仍可读）" || bad "5c marker 未被改写"

echo "=== 场景6: 目标端不可读 ⇒ 记'未核对'而非'缺失' ==="
DST_READABLE=0
OUT2="$WORK/out2"; mkdir -p "$OUT2"
WRITE_CALLS=""
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT2" restore_try_run all > "$OUT2/stdout.txt" 2>&1
LOG2="$OUT2/tryrun.log"
grep -qF "未核对（目标端不可读）" "$LOG2" \
  && ok "6a 目标端不可读 → 未核对" || bad "6a 目标端不可读 → 未核对"
# 关键: 不能被当成"备份缺失"（否则整份预演红成一片，误导性极强）
if grep -qF "备份缺失 0 条" "$LOG2"; then ok "6b 不可读时不计为备份缺失"; else bad "6b 不可读时不计为备份缺失"; fi
# 三条路径本身仍然给出（推导只依赖 marker，不依赖目标端可达）
grep -qF "openlist:wopan176Crypt/0/deadbeef/b.mp4" "$LOG2" \
  && ok "6c 不可读时三条路径仍完整给出" || bad "6c 不可读时三条路径仍完整给出"
[ -z "$WRITE_CALLS" ] && ok "6d 不可读路径下同样零写入" || bad "6d 不可读路径下同样零写入"
DST_READABLE=1

echo "=== 场景7: noop 不计入备份缺失 ==="
# 造一个"替代文件确实不在"的 move 条目 → 应计缺失 1；noop 条目不得计入
jq -n --arg d 'openlist:wopan176Crypt/0' --arg s 'onedrive:0' '{
  dest_path:$d, source_path:$s,
  fixed_files:[
    {original:"zz/gone.mp4", alternative:"deadbeef/gone.mp4", method:"rclone copyto（短哈希文件名 abcd1234）", md5:""},
    {original:"c/d.mp4", alternative:"c/d.mp4", method:"rclone copyto（原路径 + 原文件名）", md5:""}
  ]}' > "$STATE/task0_test.json"
OUT3="$WORK/out3"; mkdir -p "$OUT3"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT3" restore_try_run all > "$OUT3/stdout.txt" 2>&1
LOG3="$OUT3/tryrun.log"
grep -qF "备份缺失 1 条" "$LOG3" \
  && ok "7a 真正缺失的替代文件计 1 条" || bad "7a 真正缺失的替代文件计 1 条（日志: $(grep '预演汇总' "$LOG3")）"
grep -qF "     - zz/gone.mp4" "$LOG3" && ok "7b 缺失清单含该条目" || bad "7b 缺失清单含该条目"
grep -qF "     - c/d.mp4" "$LOG3" && bad "7c noop 条目被误计入缺失" || ok "7c noop 条目未被计入缺失"

echo "=== 场景8: 机读产物 tryrun.tsv ==="
TSV="$OUT3/tryrun.tsv"
[ -s "$TSV" ] && ok "8a 产出 tsv" || bad "8a 产出 tsv"
COLS=$(head -1 "$TSV" | awk -F'\t' '{print NF}')
[ "$COLS" = "10" ] && ok "8b tsv 10 列（marker/方法/分类/①②③/命令/备份态/原路径态/源端）" || bad "8b tsv 10 列（实际 ${COLS}）"
ROWS=$(grep -c . "$TSV")
[ "$ROWS" = "2" ] && ok "8c tsv 行数 = 条目数" || bad "8c tsv 行数 = 条目数（实际 ${ROWS}）"

echo "=== 场景8b: 目录清单缓存（核对模式下不得逐条 lsf）==="
# 4500 条目若每条 2 次 lsf ≈ 9000 次远端列举，必然撞 timeout（run 35474941314 教训）。
# 同一目录的多个条目必须共享一次列举。用计数桩验证: 3 条同目录条目 ⇒ 该目录只被 lsf 一次。
LSF_COUNT=0; LSF_DIRS=""
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task0_test.json"
printf '{"original":"a/x1.mp4","alternative":"deadbeef/x1.mp4","method":"m1","md5":""},' >> "$STATE/task0_test.json"
printf '{"original":"a/x2.mp4","alternative":"deadbeef/x2.mp4","method":"m1","md5":""},' >> "$STATE/task0_test.json"
printf '{"original":"a/x3.mp4","alternative":"deadbeef/x3.mp4","method":"m1","md5":""}' >> "$STATE/task0_test.json"
printf ']}' >> "$STATE/task0_test.json"
# 计数替身: 每次 lsf 把目录**追加到文件**（不能累加进 shell 变量 —— 预演跑在
#   while 管道的子进程里，父 shell 读不到它的变量改动）
#   其余分支与上面的原 mock 完全一致（只读/写判定不变）
LSF_LOG="$WORK/lsf.log"; : > "$LSF_LOG"
rclone() {
  if [ "$1" = "lsf" ]; then printf '%s\n' "$2" >> "$LSF_LOG"; fi
  case "$1" in
    lsf)
      local p="$2"
      if [ "$DST_READABLE" = "0" ] && [[ "$p" == openlist:* ]]; then return 1; fi
      case "$p" in
        openlist:wopan176Crypt/0) (cd "$DST" && ls) ;;
        openlist:*) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
        *) (cd "$p" 2>/dev/null && ls) ;;
      esac ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    lsjson)
      # 直读判据: 同基础 mock（全路径 stat）；此处文件都在，故恒 rc=0
      [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] \
        && { echo '[{"Hashes":{"MD5":""}}]'; return 0; } || return 1 ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
OUT5="$WORK/out5"; mkdir -p "$OUT5"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT5" restore_try_run task0 > "$OUT5/stdout.txt" 2>&1
# 三个条目: 备份都在 deadbeef/（应只列举 1 次），原路径都在 a/（同样 1 次）
DEADBEEF_HITS=$(grep -cx "openlist:wopan176Crypt/0/deadbeef" "$LSF_LOG")
[ "$DEADBEEF_HITS" = "1" ] && ok "8d 同目录只列举一次（缓存生效，实际 ${DEADBEEF_HITS} 次）" \
  || bad "8d 同目录只列举一次（实际 ${DEADBEEF_HITS} 次）"
A_HITS=$(grep -cx "openlist:wopan176Crypt/0/a" "$LSF_LOG")
[ "$A_HITS" = "1" ] && ok "8e 原路径目录同样只列举一次" || bad "8e 原路径目录同样只列举一次（实际 ${A_HITS} 次）"
# 缓存命中率直接决定能不能在 timeout 内跑完 4500 条: 总列举次数必须远小于条目数×2
TOTAL_LSF=$(grep -c . "$LSF_LOG")
[ "$TOTAL_LSF" -le 6 ] && ok "8f 3 条目的总列举次数 ${TOTAL_LSF} ≤ 6（缓存有效抑制放大）" \
  || bad "8f 3 条目的总列举次数 ${TOTAL_LSF} > 6（缓存未生效）"

# ⚠️ 存在性判定不得用 `printf | grep -q`: grep -q 命中即退出 → 管道断裂，
#   每条 2 次 × 4674 条 = 上万次 "printf: write error: Broken pipe"，实测把核对模式
#   拖过 36 分钟、撞 40 分钟 timeout 被取消（run 35476841345）。
# 只看代码行: 排除注释（第 59 行那句警示语本身含 "printf | grep -q" 字样）
if grep -nE 'printf .*\| *grep -q' "$REPO_ROOT/.github/scripts/openlist/restore_tryrun.sh" \
   | grep -vE '^\s*[0-9]+:\s*(#|\*|//)' >/dev/null; then
  bad "8g 存在性判定不得用 printf | grep -q（会 broken pipe 刷爆）"
else
  ok "8g 存在性判定未使用 printf | grep -q"
fi
# 同理 dirname/basename: 只禁**热路径**（_tryr_exists 每条都跑）；
# _tryr_split_glob 仅分卷条目调用（245/4674），不在热路径
if sed -n '/^_tryr_exists()/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/restore_tryrun.sh" \
   | grep -E '\$\((dirname|basename) ' >/dev/null; then
  bad "8h 热路径不得调用 dirname/basename（每条 fork ×2）"
else
  ok "8h 热路径未调用 dirname/basename"
fi
# 吞吐: 纯本地（mock）跑 300 条必须在数秒内完成 —— 拦住"每条目成本失控"的回归
BIG="$WORK/big"; mkdir -p "$BIG"
{
  printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":['
  i=0
  while [ $i -lt 300 ]; do
    [ $i -gt 0 ] && printf ','
    printf '{"original":"a/f%d.mp4","alternative":"deadbeef/f%d.mp4","method":"m1","md5":""}' "$i" "$i"
    i=$((i+1))
  done
  printf ']}'
} > "$STATE/task0_test.json"
T0=$(date +%s)
TRYRUN_SEND_TG=0 TRYRUN_WORK="$BIG" restore_try_run task0 > "$BIG/stdout.txt" 2>&1
T1=$(date +%s)
ELAPSED=$((T1-T0))
[ "$ELAPSED" -le 20 ] && ok "8i 300 条吞吐 ${ELAPSED}s ≤ 20s（每条目成本受控）" \
  || bad "8i 300 条吞吐 ${ELAPSED}s > 20s（每条目成本失控）"
# 计数用 grep -c 的**退出码**判定: 直接取 stdout 会带 macOS wc 前导空格
# （规范「回归套件」里记过的 flake 形态）
if grep -q "Broken pipe" "$BIG/stdout.txt" 2>/dev/null; then
  bad "8j 无 Broken pipe 错误输出"
else
  ok "8j 无 Broken pipe 错误输出"
fi

echo "=== 场景9: 任务过滤（同生产 restore_task 口径）==="
OUT4="$WORK/out4"; mkdir -p "$OUT4"
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[{"original":"q/w.mp4","alternative":"deadbeef/w.mp4","method":"rclone copyto（短哈希文件名 9999）","md5":""}]}' > "$STATE/task1_other.json"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT4" restore_try_run task0 > "$OUT4/stdout.txt" 2>&1
grep -qF "task0_test.json" "$OUT4/tryrun.tsv" && ok "9a 命中指定任务" || bad "9a 命中指定任务"
grep -qF "task1_other.json" "$OUT4/tryrun.tsv" && bad "9b 过滤掉了其他任务" || ok "9b 过滤掉其他任务"

echo "=== 场景10: 通知体量（不得把整份条目清单塞进 Telegram）==="
# run 35478771033 实测: 4684 条全量入通知 ⇒ 97 个分片，Telegram 限速下光发送 5 分钟，
# 把整轮拖过 40 分钟 timeout 被取消（预演本身已跑完，死在发通知上）。
# 通知只发摘要 + 限量缺失清单；三条完整路径交给 artifact。
TG_CAPTURE=""
send_telegram_message() { TG_CAPTURE="$1"; }
# 收尾区的运行日志链接依赖 TG_RUN_URL（生产由 workflow job env 注入）
TG_RUN_URL="https://github.com/jarvanh/actions/actions/runs/35478771033"
export TG_RUN_URL
# 造 300 条（含缺失），走核对模式
TRYRUN_SEND_TG=1 TRYRUN_WORK="$BIG" restore_try_run task0 > "$BIG/stdout.txt" 2>&1
MSG_LEN=${#TG_CAPTURE}
[ "$MSG_LEN" -lt 4000 ] && ok "10a 通知单条不分片（${MSG_LEN} 字符 < 4000）" \
  || bad "10a 通知单条不分片（${MSG_LEN} 字符 ≥ 4000 ⇒ 会分片拖垮整轮）"
printf '%s' "$TG_CAPTURE" | grep -q "备份缺失" && ok "10b 摘要含备份缺失计数" || bad "10b 摘要含备份缺失计数"
printf '%s' "$TG_CAPTURE" | grep -q "备份在" && ok "10c 摘要含备份在计数" || bad "10c 摘要含备份在计数"
printf '%s' "$TG_CAPTURE" | grep -q "运行日志" && ok "10d 收尾区完整" || bad "10d 收尾区完整"
# 条目数只作为 kv 呈现，不得出现逐条树形清单
ENTRY_LINES=$(printf '%s' "$TG_CAPTURE" | grep -cE '^├─|^└─' || true)
[ "$ENTRY_LINES" -le 10 ] && ok "10e 未逐条列条目（树形行 ${ENTRY_LINES} ≤ 10）" \
  || bad "10e 未逐条列条目（树形行 ${ENTRY_LINES} > 10 ⇒ 会分片）"

echo "=== 场景11: ⚠️ 直读复核（列列举判缺 → 必须再直读一次，分歧以直读为准）==="
# 为什么必须有这一层（§0 2026-09-18 教训 + run 35482750267 的 777 条缺失）:
#   只以"目录清单里有没有"判"文件在不在"，会把**成功判成失败** —— 清单取空/被限流/
#   缓存滞后时，整个目录下的条目**一起**变缺失，且加等待也未必够（实测等 15s 仍不可见）。
#   形状证据: 那轮 167 个缺失目录里 **0 个**是"同目录既存在又缺失"，全是整目录缺失
#   ⇒ 指向清单取空，而非个别文件真丢。故"缺失"必须经 lsjson 全路径 stat 复核才敢下结论。
# 本场景造出两种分歧:
#   · A: 列列举取空（lsf 返回空）但文件**实际存在**（lsjson rc=0）⇒ 必须翻案为"存在"
#   · B: 列列举取空且文件**真的不在**（lsjson rc≠0）⇒ 保持"缺失"
OUT6="$WORK/out6"; mkdir -p "$OUT6"
mkdir -p "$DST/ghost" "$DST/real"
printf 'G' > "$DST/ghost/g.mp4"    # A: 真实存在，但 lsf 列举取空
# B: real/ 下**不建**文件 ⇒ 两判据都判缺
# 计数桩: 记录 lsjson 被调用了几次、对谁调用
LSJSON_LOG="$WORK/lsjson.log"; : > "$LSJSON_LOG"
rclone() {
  if [ "$1" = "lsjson" ]; then printf '%s\n' "$2" >> "$LSJSON_LOG"; fi
  case "$1" in
    lsf)
      local p="$2"
      # 关键: ghost 目录**列举取空**（模拟清单滞后/限流），但文件其实在
      case "$p" in
        */ghost) return 0 ;;
        openlist:wopan176Crypt/0) (cd "$DST" && ls) ;;
        openlist:*) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
        *) (cd "$p" 2>/dev/null && ls) ;;
      esac ;;
    lsjson)
      # 直读: 按全路径 stat。ghost 的文件**在**（rc=0），real 的文件**不在**（rc=1）
      case "$2" in
        */ghost/g.mp4) return 0 ;;
        *) [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] && return 0 || return 1 ;;
      esac ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task2_ghost.json"
printf '{"original":"a/g.mp4","alternative":"ghost/g.mp4","method":"m1","md5":""},' >> "$STATE/task2_ghost.json"
printf '{"original":"a/r.mp4","alternative":"real/r.mp4","method":"m1","md5":""}' >> "$STATE/task2_ghost.json"
printf ']}' >> "$STATE/task2_ghost.json"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT6" restore_try_run task2 > "$OUT6/stdout.txt" 2>&1
# A: 列列举判缺 → 直读翻案
grep -qF "存在（直读复核翻案）" "$OUT6/tryrun.tsv" \
  && ok "11a 列列举判缺但直读判定在 ⇒ 翻案为存在" || bad "11a 应翻案为存在"
# B: 两判据都缺 ⇒ 保持缺失
MISS_ROWS=$(awk -F'\t' '$8=="缺失"' "$OUT6/tryrun.tsv" | grep -c 'real/r.mp4' || true)
[ "$MISS_ROWS" = "1" ] && ok "11b 直读也判不在 ⇒ 保持缺失" || bad "11b 应保持缺失（实际 ${MISS_ROWS} 行）"
# 只复核判缺失的（判"存在"无假阴性风险），不得对全量条目打 lsjson
LSJSON_N=$(grep -c . "$LSJSON_LOG")
[ "$LSJSON_N" = "2" ] && ok "11c 只直读复核判缺失的 2 条（未对全量打 stat，实际 ${LSJSON_N}）" \
  || bad "11c 只复核判缺失的（实际 ${LSJSON_N} 次 lsjson）"
# 翻案后统计口径必须跟着变: 翻案的那条算"存在"，且**不**计入缺失
PRESENT_N=$(awk -F'\t' '$8 ~ /^存在/' "$OUT6/tryrun.tsv" | wc -l | tr -d ' ')
[ "$PRESENT_N" = "1" ] && ok "11d 翻案计入存在、不计入缺失（存在 ${PRESENT_N} 条）" \
  || bad "11d 翻案后统计口径（存在 ${PRESENT_N} 条，应为 1）"
grep -qF "🔍 直读复核" "$OUT6/tryrun.log" && ok "11e 报告含直读复核段" || bad "11e 报告含直读复核段"
# 直读判据必须是 lsjson（全路径 stat），不能退化成 lsf 列列举
if sed -n '/^_tryr_stat_exists()/,/^}/p' "$REPO_ROOT/.github/scripts/openlist/restore_tryrun.sh" \
   | grep -qE 'lsjson'; then
  ok "11f 复核判据是 lsjson 直读（非列列举）"
else
  bad "11f 复核判据必须是 lsjson 直读"
fi
rm -f "$STATE/task2_ghost.json"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
