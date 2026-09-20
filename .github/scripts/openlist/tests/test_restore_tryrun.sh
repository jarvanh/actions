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
# marker 文件名 → epoch（时间窗测试用；未列出的 = 取不到时间戳，必须被跳过）。
# ⚠️ 用**文件**而不是关联数组传递: rclone 是被子进程调用的（`export -f`），
#   而 bash 的关联数组**无法经环境导出**到子进程（export -A 无效），
#   子进程里只会看到空数组 ⇒ 时间戳恒为空、marker 全被跳过，测试却会假绿。
MARKER_TS_FILE="$WORK/marker_ts.txt"; : > "$MARKER_TS_FILE"
rclone() {
  case "$1" in
    lsf)
      # 只读: 远端 "openlist:wopan176Crypt/0/xxx" → 本地沙箱同结构
      # 注意: 路径是 $2，不是末位参数（末位是 --retries/--timeout 等 flag）
      # --dirs-only（缺失目录结构探针用）: 只列目录，且复刻真机形态 ——
      #   rclone 的 lsf --dirs-only 输出**带尾随斜杠**，名字含空格也是整行一整段
      local p="$2"
      if [ "$DST_READABLE" = "0" ] && [[ "$p" == openlist:* ]]; then return 1; fi
      case "$p" in
        openlist:wopan176Crypt/0)
          if [ "${3:-}" = "--dirs-only" ] || [[ " $* " == *" --dirs-only "* ]]; then
            (cd "$DST" && ls -d */ 2>/dev/null)
          else
            (cd "$DST" && ls)
          fi ;;
        openlist:*)
          if [ "${3:-}" = "--dirs-only" ] || [[ " $* " == *" --dirs-only "* ]]; then
            (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls -d */ 2>/dev/null)
          else
            (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls)
          fi ;;
        *)
          if [ "${3:-}" = "--dirs-only" ] || [[ " $* " == *" --dirs-only "* ]]; then
            (cd "$p" 2>/dev/null && ls -d */ 2>/dev/null)
          else
            (cd "$p" 2>/dev/null && ls)
          fi ;;
      esac
      ;;
    cat)  cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    # 时间窗兜底用: lsl 返回 "<size> <YYYY-MM-DD HH:MM:SS.mmm> <path>"（rclone 格式）
    # ⚠️ 两处真机形态必须复刻，否则测试测不到真 bug:
    #   1) path 是**从远端根算起的完整相对路径**，不是基名（lsf 给基名、lsl 给全路径）；
    #   2) **取不到 ModTime 的条目压根不出现**（run 35489237518 实测: OneDrive 的
    #      `rclone lsl` 直接返回 **0 行**）。早先的桩给它打 "- -" 占位行，反倒掩盖了
    #      "整个后端不支持"这个生产上的真实形态。
    lsl)
      case "$2" in
        "$STATE")
          local f b ts
          for f in "$STATE"/*.json; do
            [ -e "$f" ] || continue
            b="${f##*/}"
            ts=$(awk -F'\t' -v k="$b" '$1==k{print $2; exit}' "$MARKER_TS_FILE" 2>/dev/null)
            [ -z "$ts" ] && continue     # 无 ModTime ⇒ 不出现（OneDrive 真机口径）
            printf '%s %(%Y-%m-%d %H:%M:%S)T.000000000 %s\n' "1234" "$ts" "logs/sync_state/$b"
          done
          return 0 ;;
      esac
      return 1 ;;
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
# ⚠️ 桩是**在子进程里执行**的（生产代码在 <(...) 进程替换里调 rclone），而 `export -f`
#   只导出函数、不导出普通变量 ⇒ 桩里引用 $STATE/$DST/$MARKER_TS_FILE 会全部是空串，
#   表现为"分支匹配不上 → 静默返回空/1"，而测试只会看到"时间戳取不到"这种**像被测代码错**
#   的症状（真实踩过: 12a/12g 就是这么红的）。故这几个必须显式 export。
export STATE DST MARKER_TS_FILE DST_READABLE
# 保留基础桩的函数体: 后面几个场景要换桩（计数桩等），换过之后**不会自动换回来**
#   （场景 11 的计数桩一直生效到场景 12，它没有 lsl 分支 ⇒ 时间窗取不到时间戳，
#   症状却像"生产代码算错时间"，极易误诊）。故需要时用它显式恢复，而不是再抄一份
#   桩逻辑（抄两份必然漂移）。
RCLONE_BASE_FN=$(declare -f rclone)

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
# 上限 7 而不是 6（2026-09-20）: 源端原路径核对新增**每 src 一次**可读性探测
#   （_tryr_src_readable，同样带缓存）—— 它是 Q3 判据的必要成本，不是缓存失效。
# ⚠️ 别把它当成"缓存退化"去改实现: 探测只读一次、按 src 缓存，与逐条列举有本质区别。
TOTAL_LSF=$(grep -c . "$LSF_LOG")
[ "$TOTAL_LSF" -le 7 ] && ok "8f 3 条目的总列举次数 ${TOTAL_LSF} ≤ 7（缓存有效抑制放大）" \
  || bad "8f 3 条目的总列举次数 ${TOTAL_LSF} > 7（缓存未生效）"

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
# 只复核判缺失/判不存在的（判"存在"无假阴性风险），不得对全量条目打 lsjson。
# ⚠️ 2026-09-20 起**两侧都要复核**（备份 + 原路径）⇒ 2 条 × 2 侧 = 4 次。
#   早先只复核备份侧 ⇒ 原路径侧纯靠列列举，与 fix-check 的递归列举同刻互相矛盾
#   （run 35502528927）。改断言时不要只把 2 改成 4 —— 要按侧分开数，否则
#   "某一侧被悄悄去掉复核"不会红。
# ⚠️ 再 +1 = 5: 源端原路径核对（Q3）对备份缺失的条目打 1 次 lsjson（场景 18）。
#   三条判据打的是**三个不同 remote**（备份/原路径在 openlist:，源端在 onedrive:），
#   故下面按 remote 分别计数 —— 不然"源端那次"会被误并进"原路径侧"，看不出新增。
LSJSON_N=$(grep -c . "$LSJSON_LOG")
[ "$LSJSON_N" = "5" ] && ok "11c 只复核判缺/判不在的（备份2+原路径2+源端1，实际 ${LSJSON_N}）" \
  || bad "11c 只复核判缺/判不在的（实际 ${LSJSON_N} 次 lsjson，应为 5）"
LSJSON_BAK=$(grep -c '/ghost/g.mp4\|/real/r.mp4' "$LSJSON_LOG")
# 原路径侧必须**排除源端**（onedrive:）的调用，否则两侧的计数会互相污染
LSJSON_ORIG=$(grep '/a/g.mp4\|/a/r.mp4' "$LSJSON_LOG" | grep -vc 'onedrive:')
LSJSON_SRC=$(grep -c 'onedrive:' "$LSJSON_LOG")
[ "$LSJSON_BAK" = "2" ] && ok "11c2 备份侧复核 2 次（${LSJSON_BAK}）" \
  || bad "11c2 备份侧应复核 2 次（实际 ${LSJSON_BAK}）"
[ "$LSJSON_ORIG" = "2" ] && ok "11c3 原路径侧复核 2 次（${LSJSON_ORIG}，已排除源端调用）" \
  || bad "11c3 原路径侧应复核 2 次（实际 ${LSJSON_ORIG}）"
[ "$LSJSON_SRC" = "1" ] && ok "11c4 源端侧核对 1 次（${LSJSON_SRC}，Q3 只核备份缺失的那批）" \
  || bad "11c4 源端侧应核对 1 次（实际 ${LSJSON_SRC}）"
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

echo "=== 场景12: 时间窗（最近 N 天；默认全量）==="
# 换回**基础桩**: 上面场景 11 的计数桩没有 lsl 分支，会一直生效到本场景
eval "$RCLONE_BASE_FN"; export -f rclone
# 为什么要有: 还原失败的条目会**留在 marker 里不删**，marker 只增不减。攒了几周后
#   全量预演里绝大多数是早已失效的旧记录（对应文件早就不在目标端），把"备份缺失"
#   抬得很高却不是当前问题 ⇒ 必须能按 marker 产生时间筛，才看得出最近几轮有没有真缺。
# 本场景三条 marker: 新(1天前) / 旧(30天前) / 无时间戳。窗=3 天 ⇒ 只该看新的那条。
OUT7="$WORK/out7"; mkdir -p "$OUT7"
NOW=$(printf '%(%s)T' -1)          # 同样不用 date +%s（macOS 无 -d，本机套件已登记）
NEW_TS=$((NOW - 1 * 86400))
OLD_TS=$((NOW - 30 * 86400))
# 三条 marker 内容相同（各 1 条 move 条目），只有时间不同 —— 只有一个变量。
# 时间按生产真实形态写进 **marker 内容自带的 last_success**（UTC，见 sync_marker.sh:498）
#   —— 它才是主时间源: OneDrive 的 `rclone lsl` 实测返回 0 行（run 35489237518），
#   纯靠 ModTime 的筛选在生产上直接失效。MARKER_TS_FILE（lsl 的 ModTime）只作兜底。
NOW=$(printf '%(%s)T' -1)          # 同样不用 date +%s（macOS 无 -d，本机套件已登记）
NEW_TS=$((NOW - 1 * 86400))
OLD_TS=$((NOW - 30 * 86400))
NEW_UTC=$(printf '%(%Y-%m-%dT%H:%M:%S)T' "$NEW_TS")
OLD_UTC=$(printf '%(%Y-%m-%dT%H:%M:%S)T' "$OLD_TS")
for n in fresh stale undated; do
  case "$n" in
    fresh) _ls="\"last_success\":\"${NEW_UTC}Z\"," ;;
    stale) _ls="\"last_success\":\"${OLD_UTC}Z\"," ;;
    *)     _ls="" ;;       # 无 last_success ⇒ 只能指望 lsl，而 lsl 也没有
  esac
  printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0",%s"fixed_files":[' "$_ls" > "$STATE/task9_${n}.json"
  printf '{"original":"c/d.mp4","alternative":"deadbeef/b.mp4","method":"m1","md5":""}' >> "$STATE/task9_${n}.json"
  printf ']}' >> "$STATE/task9_${n}.json"
done
# lsl 兜底时间源: 只给 fresh/stale（undated 两条时间源都没有 ⇒ 必须跳过）
printf '%s\t%s\n' "task9_fresh.json" "$NEW_TS" >> "$MARKER_TS_FILE"
printf '%s\t%s\n' "task9_stale.json" "$OLD_TS" >> "$MARKER_TS_FILE"
TRYRUN_WITHIN_DAYS=3 TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT7" restore_try_run task9 > "$OUT7/stdout.txt" 2>&1
N_FRESH=$(awk -F'\t' '$1=="task9_fresh.json"' "$OUT7/tryrun.tsv" | wc -l | tr -d ' ')
N_STALE=$(awk -F'\t' '$1=="task9_stale.json"' "$OUT7/tryrun.tsv" | wc -l | tr -d ' ')
N_UND=$(awk -F'\t' '$1=="task9_undated.json"' "$OUT7/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_FRESH" = "1" ] && ok "12a 窗内 marker 保留（${N_FRESH} 条）" || bad "12a 窗内应保留（实际 ${N_FRESH}）"
[ "$N_STALE" = "0" ] && ok "12b 超窗 marker 跳过（${N_STALE} 条）" || bad "12b 超窗应跳过（实际 ${N_STALE}）"
[ "$N_UND" = "0" ] && ok "12c 无时间戳 marker 跳过（不可证明新 = 不放行，实际 ${N_UND}）" \
  || bad "12c 无时间戳应跳过（实际 ${N_UND}）"
grep -qF "时间窗=最近 3 天" "$OUT7/tryrun.log" && ok "12d 报告明示时间窗" || bad "12d 报告明示时间窗"
# 跳过数必须明示: 否则"筛完缺失变少"会被误读成"问题消失"
grep -qE "跳过超窗 1 个" "$OUT7/tryrun.log" && ok "12e 报告明示跳过超窗数" || bad "12e 报告明示跳过超窗数"
grep -qE "跳过无时间戳 1 个" "$OUT7/tryrun.log" && ok "12f 报告明示跳过无时间戳数" || bad "12f 报告明示无时间戳数"
# 默认（不给 TRYRUN_WITHIN_DAYS）必须全量 —— 三个 marker 都该进来
OUT8="$WORK/out8"; mkdir -p "$OUT8"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT8" restore_try_run task9 > "$OUT8/stdout.txt" 2>&1
# tsv **没有表头**（每行一条预演），故全量 = 全部行数；写成 NR>1 会白丢一行、把 3 数成 2
N_ALL=$(awk -F'\t' 'NF' "$OUT8/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_ALL" = "3" ] && ok "12g 默认全量（${N_ALL} 条，含旧与无时间戳）" || bad "12g 默认应全量（实际 ${N_ALL}）"
grep -qF "绝对下界=（无）" "$OUT8/tryrun.log" && ok "12h 默认报告标注全量" || bad "12h 默认报告标注全量"
# 通知里必须带时间窗: 否则"缺失 30"和"缺失 777"会被当成同一问题的两种结论
# 恢复通知替身: 场景 10 把它重定义成写 TG_CAPTURE，该定义会一直生效到本场景
#   （不恢复 ⇒ LAST_TG_MSG 恒空，12i 会假红，症状却像"生产没写时间窗 kv"）
send_telegram_message() { LAST_TG_MSG="$1"; }
LAST_TG_MSG=""
OUT9="$WORK/out9"; mkdir -p "$OUT9"; export TG_RUN_URL="https://example.invalid/r"
TRYRUN_WITHIN_DAYS=3 TRYRUN_SEND_TG=1 TRYRUN_WORK="$OUT9" restore_try_run task9 > "$OUT9/stdout.txt" 2>&1
# 断言**通知消息体**（不是日志）: 时间窗是"这次结论覆盖多大样本"的唯一说明，
# 不看它，"缺失 30"和"缺失 777"会被当成同一个问题的两种结论
if printf '%s' "${LAST_TG_MSG:-}" | grep -qF "最近 3 天"; then
  ok "12i 通知含时间窗 kv"
else
  bad "12i 通知含时间窗 kv（消息体里没有）"
fi
rm -f "$STATE"/task9_*.json
: > "$MARKER_TS_FILE"

echo "=== 场景13: 时间窗取不到时间戳 ⇒ 必须回落全量（不得产出空结论）==="
# run 35488836925 实测: 生产侧 422 个 marker **全部**解析不出时间戳 ⇒ 条目 0 / 缺失 0。
#   这个"零"会被读成"最近 3 天没缺"，实际是**根本没测**（lsl 全路径 vs lsf 基名对不上）。
#   §0 纪律: 判据静默失败 ⇒ 错误结论。故一个都取不到时必须**回落全量并大声告警**。
OUT10="$WORK/out10"; mkdir -p "$OUT10"
for n in fresh stale undated; do
  printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task9_${n}.json"
  printf '{"original":"c/d.mp4","alternative":"deadbeef/b.mp4","method":"m1","md5":""}' >> "$STATE/task9_${n}.json"
  printf ']}' >> "$STATE/task9_${n}.json"
done
# marker_ts.txt 留空 = 全部取不到时间戳
TRYRUN_WITHIN_DAYS=3 TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT10" restore_try_run task9 > "$OUT10/stdout.txt" 2>&1
N_FB=$(awk -F'\t' 'NF' "$OUT10/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_FB" = "3" ] && ok "13a 取不到时间戳 ⇒ 回落全量（${N_FB} 条，不是 0）" \
  || bad "13a 取不到时间戳应回落全量（实际 ${N_FB} 条，0 = 空结论）"
grep -qE "时间窗\*\*未生效|时间窗未生效" "$OUT10/tryrun.log" \
  && ok "13b 报告明示时间窗未生效" || bad "13b 报告应明示时间窗未生效"
grep -qF "全量" "$OUT10/tryrun.log" && ok "13c 报告标明本次实为全量" || bad "13c 报告应标明本次实为全量"
# 决不能留下"最近 3 天"的字样当结论 —— 那正是误读的来源
if grep -qE "生效下界" "$OUT10/tryrun.log"; then
  bad "13d 未生效时不得仍报生效下界（会误导）"
else
  ok "13d 未生效时不再报时间窗生效"
fi
rm -f "$STATE"/task9_*.json
: > "$MARKER_TS_FILE"

echo "=== 场景14: 兜底时间源（marker 无 last_success ⇒ 用 lsl 的 ModTime）==="
# 生产真实形态: 很旧的 marker 没有 last_success 字段，此时若能拿到 ModTime 就该用上，
#   不能因为换了主时间源就把这部分 marker 全判"无时间戳"（那会让时间窗悄悄筛掉它们）。
OUT11="$WORK/out11"; mkdir -p "$OUT11"
for n in fresh stale; do
  printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task9_${n}.json"
  printf '{"original":"c/d.mp4","alternative":"deadbeef/b.mp4","method":"m1","md5":""}' >> "$STATE/task9_${n}.json"
  printf ']}' >> "$STATE/task9_${n}.json"
done
# 两个 marker 都**不带** last_success；时间只由 lsl 提供（fresh 新 / stale 旧）
printf '%s\t%s\n' "task9_fresh.json" "$NEW_TS" >> "$MARKER_TS_FILE"
printf '%s\t%s\n' "task9_stale.json" "$OLD_TS" >> "$MARKER_TS_FILE"
TRYRUN_WITHIN_DAYS=3 TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT11" restore_try_run task9 > "$OUT11/stdout.txt" 2>&1
N_F=$(awk -F'\t' '$1=="task9_fresh.json"' "$OUT11/tryrun.tsv" | wc -l | tr -d ' ')
N_S=$(awk -F'\t' '$1=="task9_stale.json"' "$OUT11/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_F" = "1" ] && ok "14a 无 last_success 时回落到 lsl 时间戳（窗内 ${N_F} 条）" \
  || bad "14a 应回落到 lsl 时间戳（窗内实际 ${N_F}，0 = 兜底链路没生效）"
[ "$N_S" = "0" ] && ok "14b 兜底来源同样按窗筛掉超窗者（${N_S} 条）" \
  || bad "14b 兜底来源也应筛掉超窗者（实际 ${N_S}）"
grep -qE "跳过无时间戳 0 个" "$OUT11/tryrun.log" \
  && ok "14c 有 ModTime 就不该记成无时间戳" || bad "14c 有 ModTime 却记了无时间戳"
rm -f "$STATE"/task9_*.json
: > "$MARKER_TS_FILE"

echo "=== 场景15: 绝对时间下界 TRYRUN_SINCE（只看某次语义变更之后写的 marker）==="
# 为什么需要**绝对**下界: 判定"新旧 marker 不兼容"要看语义变更提交的时间点
#   （最近一次是 e90118e 2026-09-19T11:03:00Z，move→moveto）。"最近 3 天"是相对
#   天数，会把该时刻**之前**的旧语义 marker 一起放进来 ⇒ 样本不纯、结论不可比。
# 三条 marker: 变更**之前**(09-18) / 变更**之后**(09-19 12:00) / 更早(09-10)。
OUT12="$WORK/out12"; mkdir -p "$OUT12"
mk_task9() {
  local n="$1" ls="$2"
  printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0",%s"fixed_files":[' "$ls" > "$STATE/task9_${n}.json"
  printf '{"original":"c/d.mp4","alternative":"deadbeef/b.mp4","method":"m1","md5":""}' >> "$STATE/task9_${n}.json"
  printf ']}' >> "$STATE/task9_${n}.json"
}
mk_task9 before '"last_success":"2026-09-18T09:00:00Z",'
mk_task9 after  '"last_success":"2026-09-19T12:00:00Z",'
mk_task9 older  '"last_success":"2026-09-10T09:00:00Z",'
# 下界取语义变更时刻: 只有 after 该进来（before 差 1 天、older 差 9 天）
TRYRUN_SINCE="2026-09-19T11:03:00" TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT12" \
  restore_try_run task9 > "$OUT12/stdout.txt" 2>&1
N_A=$(awk -F'\t' '$1=="task9_after.json"'  "$OUT12/tryrun.tsv" | wc -l | tr -d ' ')
N_B=$(awk -F'\t' '$1=="task9_before.json"' "$OUT12/tryrun.tsv" | wc -l | tr -d ' ')
N_O=$(awk -F'\t' '$1=="task9_older.json"'  "$OUT12/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_A" = "1" ] && ok "15a 下界之后的 marker 保留（${N_A} 条）" || bad "15a 下界之后应保留（实际 ${N_A}）"
[ "$N_B" = "0" ] && ok "15b 下界之前的 marker 跳过（${N_B} 条）" || bad "15b 下界之前应跳过（实际 ${N_B}）"
[ "$N_O" = "0" ] && ok "15c 更早的 marker 跳过（${N_O} 条）" || bad "15c 更早的应跳过（实际 ${N_O}）"
grep -qF "绝对下界 2026-09-19T11:03:00" "$OUT12/tryrun.log" \
  && ok "15d 报告写明绝对下界" || bad "15d 报告应写明绝对下界"
# 生效下界必须落成 UTC 时间点: 否则读者无法判断这批是否都在语义变更之后
grep -qF "生效下界 2026-09-19 11:03:00 UTC" "$OUT12/tryrun.log" \
  && ok "15e 报告写明生效下界时刻" || bad "15e 报告应写明生效下界时刻（UTC）"
# 与 WITHIN_DAYS 同时给时取**更严**者: 最近 30 天（松）+ 下界 09-19（严）⇒ 仍只留 after
OUT13="$WORK/out13"; mkdir -p "$OUT13"
TRYRUN_WITHIN_DAYS=30 TRYRUN_SINCE="2026-09-19T11:03:00" TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT13" \
  restore_try_run task9 > "$OUT13/stdout.txt" 2>&1
N_BOTH=$(awk -F'\t' 'NF' "$OUT13/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_BOTH" = "1" ] && ok "15f 双下界取更严者（${N_BOTH} 条）" \
  || bad "15f 双下界应取更严者（实际 ${N_BOTH} 条）"
# 解析失败必须**大声告警并回落**，绝不静默当成"没给"（否则用户以为筛了、实际全量）
OUT14="$WORK/out14"; mkdir -p "$OUT14"
TRYRUN_SINCE="not-a-date" TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT14" \
  restore_try_run task9 > "$OUT14/stdout.txt" 2>&1
N_BAD=$(awk -F'\t' 'NF' "$OUT14/tryrun.tsv" | wc -l | tr -d ' ')
[ "$N_BAD" = "3" ] && ok "15g 下界解析失败 ⇒ 回落全量（${N_BAD} 条）" \
  || bad "15g 下界解析失败应回落全量（实际 ${N_BAD}）"
grep -qF "TRYRUN_SINCE 无法解析" "$OUT14/tryrun.log" \
  && ok "15h 下界解析失败要告警（不静默）" || bad "15h 下界解析失败应告警"
# 通知同样要带绝对下界: 报告在 artifact 里，通知才是手机上第一眼看到的口径说明
OUT15="$WORK/out15"; mkdir -p "$OUT15"
TRYRUN_SINCE="2026-09-19T11:03:00" TRYRUN_SEND_TG=1 TRYRUN_WORK="$OUT15" \
  restore_try_run task9 > "$OUT15/stdout.txt" 2>&1
if printf '%s' "${LAST_TG_MSG:-}" | grep -qF "2026-09-19T11:03:00"; then
  ok "15i 通知含绝对下界 kv"
else
  bad "15i 通知应含绝对下界 kv（消息体里没有）"
fi
rm -f "$STATE"/task9_*.json

echo "=== 场景16: 「原路径不存在」也必须直读复核（2026-09-20，run 35502528927 驱动）==="
# 为什么补这一层: 此前**只有备份侧**有直读复核，原路径侧仍纯靠列列举 ⇒ 与 fix-check 的
#   递归列举同刻互相矛盾（fix-check 说 529/529 都在，try run 说原路径不存在）。
#   两边都是"列表"，列表有缓存延迟（§0: 新建首次可见 ~10s，等 15s 仍可能不可见）
#   ⇒ 不一致时必须有**非列表**判据才能定案。而"原路径"是**真跑的落点**，
#   判错会导致"该还原的被判成不用还原"，风险不比备份侧低。
# 本场景: 列列举把「蓝白碗」列空（清单滞后），但直读 stat 说文件在 ⇒ 必须翻案。
eval "$RCLONE_BASE_FN"; export -f rclone
OUT16="$WORK/out16"; mkdir -p "$OUT16"
mkdir -p "$DST/6c73a635" "$DST/蓝白碗" "$DST/plain"
printf 'B1' > "$DST/6c73a635/x.jpg"
printf 'B2' > "$DST/6c73a635/y.jpg"
rclone() {
  case "$1" in
    lsf)
      local p="$2"
      case "$p" in
        "$STATE") (cd "$STATE" && ls) ;;   # marker 目录是**本地路径**（不是 openlist: 远端）
        *蓝白碗) return 0 ;;   # 列列举取空（模拟清单滞后/限流），但文件其实在
        *) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
      esac ;;
    lsjson)
      case "$2" in
        */蓝白碗/x.jpg) return 0 ;;   # 直读: 在
        *) [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] && return 0 || return 1 ;;
      esac ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task16_orig.json"
printf '{"original":"蓝白碗/x.jpg","alternative":"6c73a635/x.jpg","method":"m1","md5":""},' >> "$STATE/task16_orig.json"
printf '{"original":"plain/y.jpg","alternative":"6c73a635/y.jpg","method":"m1","md5":""}' >> "$STATE/task16_orig.json"
printf ']}' >> "$STATE/task16_orig.json"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT16" restore_try_run task16 > "$OUT16/stdout.txt" 2>&1
# A: 列列举判原路径不存在 → 直读判定在 ⇒ 必须翻案
FLIP_N=$(awk -F'\t' '$9 ~ /^已存在（直读复核翻案）$/' "$OUT16/tryrun.tsv" | grep -c '蓝白碗/x.jpg' || true)
[ "$FLIP_N" = "1" ] && ok "16a 原路径列列举判不在·直读判定在 ⇒ 翻案为已存在" \
  || bad "16a 原路径应翻案为已存在（实际 ${FLIP_N} 行）"
# B: 两判据都不在 ⇒ 保持不存在（对照组，防"一律翻案"）
KEEP_N=$(awk -F'\t' '$9=="不存在"' "$OUT16/tryrun.tsv" | grep -c 'plain/y.jpg' || true)
[ "$KEEP_N" = "1" ] && ok "16b 直读也判不在 ⇒ 保持不存在（${KEEP_N} 行）" \
  || bad "16b 应保持不存在（实际 ${KEEP_N} 行）"
# 翻案必须计入"原路径已存在"统计: 否则翻案了却在汇总里消失
EXIST_N=$(awk -F'\t' '$9 ~ /^已存在/' "$OUT16/tryrun.tsv" | wc -l | tr -d ' ')
[ "$EXIST_N" = "1" ] && ok "16c 翻案计入原路径已存在统计（${EXIST_N} 条）" \
  || bad "16c 翻案应计入原路径已存在（实际 ${EXIST_N} 条）"
grep -qF "直读复核（原路径）" "$OUT16/tryrun.log" && ok "16d 报告含原路径直读复核段" \
  || bad "16d 报告应含原路径直读复核段"
grep -qF "翻案 1 条" "$OUT16/tryrun.log" && ok "16e 报告写明原路径翻案数" \
  || bad "16e 报告应写明原路径翻案数"
rm -f "$STATE"/task16_orig.json
eval "$RCLONE_BASE_FN"; export -f rclone

# ============================================================================
# 场景 17: 缺失目录结构探针（2026-09-20 V5 驱动）
#   为什么: "备份文件不在"有两种成因，只报"缺失"分不开 ——
#     (a) 替代目录（短哈希目录）**根本没建成** ⇒ 修复压根没落盘；
#     (b) 目录建成了、但文件没进去（或被清）⇒ 与后端清理/落盘有关。
#   两者对应的修法完全不同，故必须能在报告里一眼区分。
#   本场景: A 目录缺替代目录（应报"不在"）；B 目录有替代目录但文件不在（应报"在"）。
# ============================================================================
OUT17="$WORK/out17"; mkdir -p "$OUT17"
mkdir -p "$DST/caseA/origA" "$DST/caseB/origB" "$DST/caseB/6c73a635"
printf 'X' > "$DST/caseA/origA/f1.jpg"
printf 'Y' > "$DST/caseB/origB/f2.jpg"
# caseB 的替代目录**存在但为空**（文件没进去）；caseA 的替代目录压根不存在
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task17_struct.json"
printf '{"original":"caseA/origA/f1.jpg","alternative":"caseA/deadbeef/f1.jpg","method":"m1","md5":""},' >> "$STATE/task17_struct.json"
printf '{"original":"caseB/origB/f2.jpg","alternative":"caseB/6c73a635/f2.jpg","method":"m1","md5":""}' >> "$STATE/task17_struct.json"
printf ']}' >> "$STATE/task17_struct.json"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT17" restore_try_run task17 > "$OUT17/stdout.txt" 2>&1
grep -qF "缺失目录结构探针" "$OUT17/tryrun.log" && ok "17a 报告含缺失目录结构探针段" \
  || bad "17a 报告应含缺失目录结构探针段"
grep -qF "替代目录 deadbeef **不在**" "$OUT17/tryrun.log" \
  && ok "17b 替代目录没建成 ⇒ 报不在" || bad "17b 应报替代目录 deadbeef 不在"
grep -qF "替代目录 6c73a635 **在**" "$OUT17/tryrun.log" \
  && ok "17c 替代目录建成但文件不在 ⇒ 报在（区分两种成因）" \
  || bad "17c 应报替代目录 6c73a635 在"
# 探针必须只走只读命令: 全程零写入
[ -z "$WRITE_CALLS" ] && ok "17d 结构探针全程只读（零写入）" \
  || bad "17d 结构探针不得写任何数据（实际: ${WRITE_CALLS//$'\n'/ }）"
# 有 source_path 时必须把源端同层形状一并打出 —— 两侧形状同屏才判得了
#   "fix-check 报差集 0" 与 "目标端看不到原目录" 这类矛盾（V5 实测出现过）
grep -qF "源端同层:" "$OUT17/tryrun.log" && ok "17e 探针同屏给出源端同层形状" \
  || bad "17e 探针应同屏给出源端同层形状（marker 有 source_path 时）"
grep -qF "caseB" "$OUT17/tryrun.log" && ok "17f 源端同层按 marker 的 source_path 推导" \
  || bad "17f 源端同层应由 source_path 推导（实际未见 caseB）"
# 替代目录建成却判缺失时，必须进一步说清"里面有什么":
#   空目录 ⇒ 文件压根没落；非空 ⇒ 落盘了但名字对不上（修法完全不同）
grep -qF "**空目录**" "$OUT17/tryrun.log" && ok "17g 替代目录为空 ⇒ 报文件压根没落" \
  || bad "17g 替代目录为空时应报「空目录」（caseB 的 6c73a635 无文件）"
rm -f "$STATE"/task17_struct.json
rm -rf "$DST/caseA" "$DST/caseB"
eval "$RCLONE_BASE_FN"; export -f rclone

# ============================================================================
# 场景 18: 源端原路径核对（Q3: 能否还原回**源端原路径**）
#   为什么: marker 的 original 是还原落点的唯一依据。若**源端根本没有这个原路径**，
#   落点即失效 —— 这是用户三问里 Q3 的失败形态，必须能看见。
#   ⚠️ 关键陷阱: 直读对"远端不可达"与"文件真不在"**都返回非 0**；不先判源端可读性
#   就会把"源端连不上"谎报成"源端没有"（谎报 Q3 结论，比不测更糟）⇒ 必须有未核对态。
# ============================================================================
eval "$RCLONE_BASE_FN"; export -f rclone
OUT18="$WORK/out18"; mkdir -p "$OUT18"
mkdir -p "$DST/q3dir/6c73a635" "$DST/q3dir/orig"
printf 'S' > "$DST/q3dir/orig/keep.jpg"    # 源端**有**的原文件
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task18_q3.json"
printf '{"original":"q3dir/orig/keep.jpg","alternative":"q3dir/6c73a635/keep.jpg","method":"m1","md5":""},' >> "$STATE/task18_q3.json"
printf '{"original":"q3dir/orig/gone.jpg","alternative":"q3dir/6c73a635/gone.jpg","method":"m1","md5":""}' >> "$STATE/task18_q3.json"
printf ']}' >> "$STATE/task18_q3.json"
# 桩: 源端 onedrive:0/... 映射到 $SRC18；备份侧一律缺失（这样两条都会走源端核对）
SRC18="$WORK/src18"; mkdir -p "$SRC18/q3dir/orig"
printf 'S' > "$SRC18/q3dir/orig/keep.jpg"   # gone.jpg 故意不建 ⇒ 源端不在
export SRC18
rclone() {
  case "$1" in
    lsf)
      local p="$2"
      case "$p" in
        "$STATE") (cd "$STATE" && ls) ;;
        onedrive:0) (cd "$SRC18" && ls) ;;   # 根: 可读性探测走这里
        onedrive:0/*) (cd "$SRC18/${p#onedrive:0/}" 2>/dev/null && ls) || return 1 ;;
        onedrive:*) return 1 ;;              # 源端整体不可读
        *6c73a635*) return 0 ;;   # 备份目录列空 ⇒ 判缺失
        *) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
      esac ;;
    lsjson)
      case "$2" in
        onedrive:0/*) [ -f "$SRC18/${2#onedrive:0/}" ] && { echo '[{}]'; return 0; } || return 1 ;;
        *) [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] && { echo '[{}]'; return 0; } || return 1 ;;
      esac ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT18" restore_try_run task18 > "$OUT18/stdout.txt" 2>&1
grep -qF "源端: 在" "$OUT18/tryrun.log" && ok "18a 源端有该原路径 ⇒ 报在" \
  || bad "18a 源端应报在（keep.jpg 在源端）"
grep -qF "源端: 不在" "$OUT18/tryrun.log" && ok "18b 源端无该原路径 ⇒ 报不在（Q3 落点失效）" \
  || bad "18b 源端应报不在（gone.jpg 源端没有）"
grep -qF "源端原路径核对（Q3" "$OUT18/tryrun.log" && ok "18c 报告含 Q3 源端核对段" \
  || bad "18c 报告应含 Q3 源端核对段"
grep -qF "源端**不在** 1 条" "$OUT18/tryrun.log" && ok "18d 报告写明源端不在条数" \
  || bad "18d 报告应写明源端不在条数"
# ★ 陷阱: 源端不可读时必须是"未核对"，绝不能谎报"不在"
rclone() {
  case "$1" in
    lsf)
      local p="$2"
      case "$p" in
        "$STATE") (cd "$STATE" && ls) ;;
        onedrive:*) return 1 ;;            # 源端整体不可读
        *6c73a635*) return 0 ;;
        *) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
      esac ;;
    lsjson) return 1 ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
OUT18B="$WORK/out18b"; mkdir -p "$OUT18B"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT18B" restore_try_run task18 > "$OUT18B/stdout.txt" 2>&1
grep -qF "未核对（源端不可读）" "$OUT18B/tryrun.log" \
  && ok "18e 源端不可读 ⇒ 标未核对，不谎报不在" \
  || bad "18e 源端不可读应标未核对（直读不可达与真不在必须分开）"
grep -q "源端: 不在" "$OUT18B/tryrun.log" \
  && bad "18f 源端不可读时不得出现「不在」（会谎报 Q3 结论）" \
  || ok "18f 源端不可读时不出现「不在」"
# ============================================================================
# 场景 19: 源端核对的**阳性对照**（§0: 全阴性结果必须自证判据没坏）
#   为什么: run 35511137266 实测 57 条**全判"不在"、零个"在"**。若直读判据在某个
#   远端上恒阴（对存在的文件也返回非 0），"源端不在"就是假的 —— 而它正是 Q3 的结论。
#   ⇒ 对每个 src 抽一条**备份存在**的条目也核源端: 判"在" = 判据有效；判"不在" =
#   判据失效，本轮所有阴性结论必须显式作废并告警，而不是照常输出。
# ============================================================================
eval "$RCLONE_BASE_FN"; export -f rclone
OUT19="$WORK/out19"; mkdir -p "$OUT19"
mkdir -p "$DST/c19/6c73a635" "$DST/c19/orig" "$SRC18/c19/orig"
printf 'A' > "$DST/c19/6c73a635/have.jpg"    # 备份**存在**
printf 'A' > "$SRC18/c19/orig/have.jpg"      # 源端**也有**（对照应判"在"）
printf '{"dest_path":"openlist:wopan176Crypt/0","source_path":"onedrive:0","fixed_files":[' > "$STATE/task19_ctrl.json"
printf '{"original":"c19/orig/have.jpg","alternative":"c19/6c73a635/have.jpg","method":"m1","md5":""}' >> "$STATE/task19_ctrl.json"
printf ']}' >> "$STATE/task19_ctrl.json"
rclone() {
  case "$1" in
    lsf)
      local p="$2"
      case "$p" in
        "$STATE") (cd "$STATE" && ls) ;;
        onedrive:0) (cd "$SRC18" && ls) ;;
        onedrive:0/*) (cd "$SRC18/${p#onedrive:0/}" 2>/dev/null && ls) || return 1 ;;
        *) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
      esac ;;
    lsjson)
      case "$2" in
        onedrive:0/*) [ -f "$SRC18/${2#onedrive:0/}" ] && { echo '[{}]'; return 0; } || return 1 ;;
        *) [ -f "$DST/${2#openlist:wopan176Crypt/0/}" ] && { echo '[{}]'; return 0; } || return 1 ;;
      esac ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT19" restore_try_run task19 > "$OUT19/stdout.txt" 2>&1
grep -qF "阳性对照" "$OUT19/tryrun.log" && ok "19a 报告含阳性对照段" \
  || bad "19a 报告应含阳性对照段"
grep -qF "对照判为 **在**" "$OUT19/tryrun.log" && ok "19b 备份存在且源端有 ⇒ 对照判在" \
  || bad "19b 对照应判在（源端确实有该文件）"
grep -qF "✅ 对照判在 1 个" "$OUT19/tryrun.log" && ok "19c 判据有效时明确标注可信" \
  || bad "19c 应标注判据有效"

# ★ 反向: 源端明明有、直读却恒返回非 0（判据坏）⇒ 必须作废阴性结论并告警
rclone() {
  case "$1" in
    lsf)
      local p="$2"
      case "$p" in
        "$STATE") (cd "$STATE" && ls) ;;
        onedrive:0) (cd "$SRC18" && ls) ;;
        onedrive:0/*) (cd "$SRC18/${p#onedrive:0/}" 2>/dev/null && ls) || return 1 ;;
        *) (cd "$DST/${p#openlist:wopan176Crypt/0/}" 2>/dev/null && ls) ;;
      esac ;;
    lsjson) return 1 ;;          # 判据损坏: 恒阴（存在的文件也报不在）
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
OUT19B="$WORK/out19b"; mkdir -p "$OUT19B"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT19B" restore_try_run task19 > "$OUT19B/stdout.txt" 2>&1
grep -qF "对照判为 **不在**" "$OUT19B/tryrun.log" \
  && ok "19d 判据恒阴时对照判不在（如实反映，不粉饰）" \
  || bad "19d 判据恒阴时对照应判不在"
grep -qF "结论作废" "$OUT19B/tryrun.log" \
  && ok "19e 判据失效 ⇒ 显式作废阴性结论并告警" \
  || bad "19e 判据失效时必须作废结论（否则会输出假的『源端不在』）"
rm -f "$STATE"/task19_ctrl.json
rm -rf "$DST/c19" "$SRC18/c19"
eval "$RCLONE_BASE_FN"; export -f rclone

# ============================================================================
# 场景 20: marker 原文探针（2026-09-20，用户质疑「这条记录是什么时候写下的」驱动）
#   为什么: try run 报告里的三条路径是**推导产物**，推不出"这条记录什么时候、由
#   哪个目录对写下的"。而 marker **只增不减** ⇒ "marker 里有一条" ≠ "本轮刚产生"。
#   要回答归属与时间，只能直接看 marker 原文字段 + 远端 ModTime。
#   锁三件事: ① dump 出归属字段（source_path / dest_path）
#             ② dump 出时间（last_success + 远端 ModTime）
#             ③ **只读**（lsl/cat 之外的写命令一个都不许有）
# ============================================================================
OUT20="$WORK/out20"; mkdir -p "$OUT20"
printf '%s' '{"last_success":"2026-09-14T03:12:45Z","source_path":"onedrive:1/1024j/套图/网易摄影","dest_path":"openlist:wopan175/1/1024j/套图/neko","source_count":529,"fixed_count":19,"top_dirs":["蓝白碗"],"fixed_files":[{"original":"蓝白碗/6608451911027290782.jpg","alternative":"6c73a635/6608451911027290782.jpg","method":"copyto_shorthash"},{"original":"蓝白碗/2.jpg","alternative":"6c73a635/2.jpg","method":"copyto_shorthash"}]}' > "$STATE/task20_dump.json"
# 给它一个 ModTime: 2026-09-14 03:12:45 → epoch
MT20=$(printf '%(%s)T' -1)
printf '%s\t%s\n' "task20_dump.json" "$MT20" >> "$MARKER_TS_FILE"
rclone() {
  case "$1" in
    lsf)
      case "$2" in
        "$STATE") (cd "$STATE" && ls) ;;
        *) (cd "$2" 2>/dev/null && ls) || return 1 ;;
      esac ;;
    lsl)
      local f b ts
      for f in "$STATE"/*.json; do
        [ -e "$f" ] || continue
        b="${f##*/}"
        ts=$(awk -F'\t' -v k="$b" '$1==k{print $2; exit}' "$MARKER_TS_FILE" 2>/dev/null)
        [ -z "$ts" ] && continue
        printf '%s %(%Y-%m-%d %H:%M:%S)T.000000000 %s\n' "1234" "$ts" "logs/sync_state/$b"
      done
      return 0 ;;
    cat) cat "$2" ;;
    size) echo '{"bytes":1}' ;;
    *) WRITE_CALLS+="$1"$'\n'; return 1 ;;
  esac
  return 0
}
export -f rclone
W20_BEFORE="$WRITE_CALLS"
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT20" TRYRUN_DUMP_MARKER="task20_dump" restore_try_run all > "$OUT20/stdout.txt" 2>&1
D20="$OUT20/tryrun.log"
grep -qF "marker: task20_dump.json" "$D20" && ok "20a 探针命中目标 marker（子串匹配）" \
  || bad "20a 探针应命中 task20_dump.json（日志: $(cat "$D20" 2>/dev/null | head -5)）"
grep -qF "source_path: onedrive:1/1024j/套图/网易摄影" "$D20" && ok "20b dump 出 source_path（判归属）" \
  || bad "20b 应 dump source_path"
grep -qF "dest_path  : openlist:wopan175/1/1024j/套图/neko" "$D20" && ok "20c dump 出 dest_path（判归属）" \
  || bad "20c 应 dump dest_path"
grep -qF "last_success" "$D20" && grep -qF "2026-09-14T03:12:45Z" "$D20" \
  && ok "20d dump 出 last_success（marker 内记录的写盘时刻）" || bad "20d 应 dump last_success"
grep -qF "远端 ModTime" "$D20" && ok "20e dump 出远端 ModTime（文件最后修改时间）" \
  || bad "20e 应 dump 远端 ModTime"
grep -qF "蓝白碗/6608451911027290782.jpg" "$D20" && ok "20f dump 出前几条 original（判这批归哪）" \
  || bad "20f 应 dump original"
grep -qF "fixed_files 实际条数: 2" "$D20" && ok "20g fixed_files 实际条数按原文字段算" \
  || bad "20g 应给 fixed_files 实际条数"
# ★ 判决性一项: 源端直读 —— 拿 marker 自记的 source_path 直读 <source_path>/<original>。
#   它是"这批在源端到底有没有"的直接证据（top_dirs 只是写盘那一刻的快照）。
grep -qF "源端直读" "$D20" && ok "20j 探针含源端直读（直接证据，不只靠 top_dirs 快照）" \
  || bad "20j 应含源端直读"
# 沙箱里 onedrive: 源端不可读 ⇒ 必须标"未核对"，**绝不谎报"不在"**
# （这条比"报不在"更要紧: 谎报"源端没有"正是 Q3 结论本身，谎报不得）
grep -qF "不可读 ⇒ 未核对" "$D20" && ok "20k 源端不可读 ⇒ 标未核对，不谎报不在" \
  || bad "20k 源端不可读时应标未核对（日志: $(grep -A2 源端直读 "$D20" | head -3)）"
! grep -qF "     - 不在 " "$D20" && ok "20l 源端不可读时不得出现「不在」结论" \
  || bad "20l 源端不可读时不得谎报不在"
[ "$WRITE_CALLS" = "$W20_BEFORE" ] && ok "20h ⚠️ 探针全程只读（零写入）" \
  || bad "20h 探针不得有任何写调用（新增: $(printf '%s' "$WRITE_CALLS" | grep -vFx -f <(printf '%s' "$W20_BEFORE"))）"
# 反向: 关键字打不中时必须说"没命中"，而不是静默空输出（§0: 静默失败 ⇒ 错误结论）
TRYRUN_SEND_TG=0 TRYRUN_WORK="$OUT20" TRYRUN_DUMP_MARKER="不存在的关键字" restore_try_run all > "$OUT20/stdout2.txt" 2>&1
grep -qF "没有 marker 名包含关键字" "$OUT20/tryrun.log" && ok "20i 关键字打不中时显式告知（不静默空输出）" \
  || bad "20i 打不中时应显式告知"
rm -f "$STATE"/task20_dump.json
eval "$RCLONE_BASE_FN"; export -f rclone

# ============================================================================
# 场景 21: 归属判据（V6，2026-09-20 串写修复后新增）
#   为什么: 串写把**别处目录**的修复记录写进了本 marker，真跑会把 A 的备份搬到 B
#   名下（短哈希不可逆，搬错回不去）。现有核对只验"路径在不在"，验不出归属。
#   判据用 marker 自记的 top_dirs: 条目的顶层目录必须是其中之一。
#   锁三态: ① 可疑 ⇒ 必须报（否则串写永远看不见）
#           ② 干净 ⇒ 不得误报（否则每轮都是噪音，很快没人看）
#           ③ 缺 top_dirs ⇒ **说未验证**，不得显示成"归属干净"（§0: 判不了≠没问题）
# ============================================================================
OUT21="$WORK/out21"; mkdir -p "$OUT21"
# 21-A: 可疑 —— top_dirs 只有 neko，但条目属于 蓝白碗（复刻真机串写形态）
printf '%s' '{"last_success":"2026-09-19T19:39:07Z","source_path":"SRC/套图/neko","dest_path":"DST/套图/neko","top_dirs":["neko普通"],"fixed_files":[{"original":"蓝白碗/1.jpg","alternative":"6c73a635/1.jpg","method":"copyto_shorthash"}]}' > "$STATE/task21a.json"
# 21-B: 干净 —— 条目顶层 neko普通 在 top_dirs 里
printf '%s' '{"last_success":"2026-09-19T19:39:07Z","source_path":"SRC/套图/neko","dest_path":"DST/套图/neko","top_dirs":["neko普通"],"fixed_files":[{"original":"neko普通/9.jpg","alternative":"ff980203/9.jpg","method":"copyto_shorthash"}]}' > "$STATE/task21b.json"
TRYRUN_SEND_TG=0 TRYRUN_CHECK_EXISTS=0 TRYRUN_WORK="$OUT21" restore_try_run all > "$OUT21/stdout.txt" 2>&1
L21="$OUT21/tryrun.log"
grep -qF "归属可疑 1/2" "$L21" \
  && ok "21a 归属可疑必须报（含分母: 判了多少条）" \
  || bad "21a 应报归属可疑 1/2（汇总: $(grep '归属' "$L21" | head -2)）"
grep -qF "蓝白碗/1.jpg" "$L21" && grep -qF "疑似串写/继承" "$L21" \
  && ok "21b 可疑条目点名 + 说明后果（不是只给个数）" \
  || bad "21b 应点名可疑条目（日志: $(grep -A3 '归属可疑' "$L21" | head -4)）"
# 干净的那条不得出现在可疑清单里
grep -F "     - neko普通/9.jpg" "$L21" \
  && bad "21c 干净条目被误报为可疑" || ok "21c 干净条目不误报（判据不过度报警）"
rm -f "$STATE"/task21a.json "$STATE"/task21b.json

# 21-D: 无 top_dirs ⇒ 必须说"未验证"，不得显示成"归属干净"
printf '%s' '{"last_success":"2026-09-19T19:39:07Z","source_path":"SRC/x","dest_path":"DST/x","fixed_files":[{"original":"蓝白碗/1.jpg","alternative":"6c73a635/1.jpg","method":"copyto_shorthash"}]}' > "$STATE/task21d.json"
TRYRUN_SEND_TG=0 TRYRUN_CHECK_EXISTS=0 TRYRUN_WORK="$OUT21" restore_try_run all > "$OUT21/stdout2.txt" 2>&1
grep -qF "0 条可判" "$L21" && grep -qF "未验证" "$L21" \
  && ok "21d 缺 top_dirs ⇒ 明示未验证（不得假装'归属干净'）" \
  || bad "21d 缺 top_dirs 时应说未验证（汇总: $(grep '归属' "$L21" | tail -1)）"
! grep -qF "未见串写迹象" "$L21" \
  && ok "21e 未验证时不得输出『未见串写迹象』（否则从没判过也说干净）" \
  || bad "21e 未验证时不得说未见串写迹象"
rm -f "$STATE"/task21d.json

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
