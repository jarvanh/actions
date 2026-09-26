#!/bin/bash
# marker 修复记录持久化——大 JSON 防 argv 溢出回归测试
# 背景: fixed_files 条目内嵌 restore 脚本、fix_blacklist 跨轮积累，总量可超
# Linux 单参数 128KB 上限（MAX_ARG_STRLEN ≈ 131072B）。历史上这些大 JSON 经
# --argjson 走命令行传给 jq，execve E2BIG "Argument list too long" 失败被
# 2>/dev/null 吞掉:
#   - marker_add_fix_entry / *_merge_json / save_*_marker 的合并结果静默变空
#     → 修复记录/黑名单丢失，甚至把旧 marker 已落盘的记录整体清零
# 修复后大 JSON 一律经 stdin 文档流喂 jq -s（slurp 后解构绑定）。
# 本测试用 >128KB 的真实尺寸载荷验证各写路径不再丢数据，
# 并覆盖 _marker_write 对空/非法 JSON 的拒绝写入防护。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# 排版助手 + 发送层的唯一真源（openlist 侧已不再自带副本，2026-09-06 收敛）
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
timeout() { shift; "$@"; }

MARKER_FILE=$(mktemp); RCAP_FILE=$(mktemp); RCAT_N=$(mktemp)
echo 0 > "$RCAT_N"; : > "$RCAP_FILE"

rclone() {
  case "$1" in
    cat) cat "$MARKER_FILE" ;;
    rcat) cat > "$RCAP_FILE"; _n=$(cat "$RCAT_N"); echo $((_n+1)) > "$RCAT_N" ;;
    lsjson)
      # carry-forward 探测: 路径含 "aligned" 视为目标端已出现（无需继承）
      case "$2" in
        *aligned*) echo '[{"Path":"aligned.bin","Size":1}]' ;;
        *) echo '[]' ;;
      esac
      ;;
    size) echo '{"bytes":123456,"count":42}' ;;
    lsf) printf 'dir1/\ndir2/\n' ;;
    *) return 0 ;;
  esac
}
rcat_count() { cat "$RCAT_N"; }

# 构造大载荷: N 个条目 × 500B padding（模拟内嵌 restore 脚本的体积）
build_big_fixed_json() {
  local n="$1" pad out="[" sep="" i
  pad=$(printf 'x%.0s' $(seq 1 500))
  for ((i=0; i<n; i++)); do
    out+="${sep}{\"original\":\"d/file_${i}.bin\",\"alternative\":\"alt_${i}.bin\",\"method\":\"方法1: 打包重传\",\"size_bytes\":100,\"pad\":\"${pad}\"}"
    sep=","
  done
  echo "${out}]"
}
build_big_bl_json() {
  local n="$1" out="{" sep="" i
  for ((i=0; i<n; i++)); do
    out+="${sep}\"d/file_${i}.bin\":\"方法1: 打包重传|方法3: 分卷\""
    sep=","
  done
  echo "${out}}"
}

BIG_FIXED=$(build_big_fixed_json 300)   # ~300 × 600B ≈ 180KB > 128KB
BIG_BL=$(build_big_bl_json 300)
[ "${#BIG_FIXED}" -gt 131072 ] && ok "0a 测试载荷超 128KB（${#BIG_FIXED} B）" || bad "0a 载荷未超上限 [${#BIG_FIXED} B]"

# ===== 场景 1: marker_add_fix_entry 大 state + 大黑名单 =====
# state 本身也必须用 stdin 方式构造（测试里同样不能走 argv）
STATE=$(printf '%s\n%s\n%s\n' "$BIG_FIXED" '{"k1":"方法1: x"}' '{"last_success":"2020-01-01T00:00:00Z"}' \
  | jq -sc '. as [$ff, $bl, $m] | $m + {fixed_files: $ff, fix_blacklist: $bl}')
ENTRY='{"original":"d/new.bin","alternative":"alt_new.bin","method":"方法2: 分卷","size_bytes":999}'

OUT=$(printf '%s' "$STATE" | marker_add_fix_entry "$ENTRY" "$BIG_BL")
[ -n "$OUT" ] && ok "1a 大载荷下 marker_add_fix_entry 成功（历史 E2BIG 症状为空输出）" || bad "1a 输出为空"
[ "$(echo "$OUT" | jq -r '.fixed_count')" = "301" ] && ok "1b 条目数 300+1=301" || bad "1b: [$(echo "$OUT" | jq -r '.fixed_count')]"
[ "$(echo "$OUT" | jq -r '.fixed_bytes')" = "30999" ] && ok "1c fixed_bytes 重算 300×100+999" || bad "1c: [$(echo "$OUT" | jq -r '.fixed_bytes')]"
[ "$(echo "$OUT" | jq '.fix_blacklist | length')" = "301" ] && ok "1d 黑名单合并 300+旧1=301" || bad "1d: [$(echo "$OUT" | jq '.fix_blacklist | length')]"
[ "$(echo "$OUT" | jq -r '.last_success')" = "2020-01-01T00:00:00Z" ] && ok "1e 其余字段保留" || bad "1e"

# 同 original 覆盖（新条目替换旧条目，不新增）
ENTRY2='{"original":"d/file_5.bin","alternative":"alt_5v2","method":"方法2: 分卷","size_bytes":777}'
OUT2=$(printf '%s' "$STATE" | marker_add_fix_entry "$ENTRY2" "$BIG_BL")
[ "$(echo "$OUT2" | jq -r '.fixed_count')" = "300" ] && ok "1f 同 original 覆盖不新增（300）" || bad "1f: [$(echo "$OUT2" | jq -r '.fixed_count')]"
[ "$(echo "$OUT2" | jq -r '.fixed_files[] | select(.original=="d/file_5.bin") | .alternative')" = "alt_5v2" ] \
  && ok "1g 覆盖后内容为新条目" || bad "1g"

# ===== 场景 2: marker_merge_blacklist 大黑名单 + 多行 pretty marker =====
PRETTY_STATE=$(printf '%s' "$STATE" | jq .)   # 模拟 rclone cat 读回的多行 marker
OUT3=$(printf '%s' "$PRETTY_STATE" | marker_merge_blacklist "$BIG_BL")
[ "$(echo "$OUT3" | jq '.fix_blacklist | length')" = "301" ] && ok "2a pretty marker + 大黑名单合并 301 条" || bad "2a: [$(echo "$OUT3" | jq '.fix_blacklist | length')]"
[ "$(echo "$OUT3" | jq -r '.last_success')" = "2020-01-01T00:00:00Z" ] && ok "2b marker 其余字段无损" || bad "2b"

# ===== 场景 3: _marker_merge_json 大对象 =====
OUT4=$(_marker_merge_json "$BIG_BL" '{"zzz":"m"}')
[ "$(echo "$OUT4" | jq 'length')" = "301" ] && ok "3a 大对象合并 300+1=301" || bad "3a: [$(echo "$OUT4" | jq 'length')]"

# ===== 场景 4: _carry_forward_fixed 大清单 + 索引选择 =====
_old="["; _sep=""
for ((i=0; i<200; i++)); do
  _old+="${_sep}{\"original\":\"keep_${i}.bin\",\"alternative\":\"a${i}\",\"size_bytes\":10}"
  _sep=","
  _old+="${_sep}{\"original\":\"aligned_${i}.bin\",\"alternative\":\"b${i}\",\"size_bytes\":20}"
done
_old+="]"
OLD_MARKER=$(printf '{"fixed_files":%s}' "$_old")
CARRY4=$(_carry_forward_fixed "openlist:dst" "$OLD_MARKER")
CARRIED=$(echo "$CARRY4" | jq -c '.carried')
[ "$(echo "$CARRIED" | jq 'length')" = "200" ] && ok "4a 继承 200 个未对齐条目（aligned 200 个被剔除）" || bad "4a: [$(echo "$CARRIED" | jq 'length')]"
[ "$(echo "$CARRIED" | jq '[.[].original | startswith("keep_")] | all')" = "true" ] && ok "4b 继承条目全部为 keep_*" || bad "4b"
[ "$(echo "$CARRY4" | jq -r '.deleted')" = "0" ] && ok "4c 收尾删除计数 0（mock Size=1 ≠ size_bytes=20，不满足删除条件）" || bad "4c: [$(echo "$CARRY4" | jq -r '.deleted')]"

# ===== 场景 5: save_fix_state_marker 大载荷端到端（本轮修复 + 继承 + 黑名单）=====
echo 0 > "$RCAT_N"
GLOBAL_FIXED_FILES_JSON="$BIG_FIXED"
GLOBAL_FIX_BLACKLIST_JSON="$BIG_BL"
printf '%s' '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1,"fixed_files":[{"original":"keep_a.bin","alternative":"alt_a","size_bytes":50},{"original":"aligned_1.bin","alternative":"alt_b","size_bytes":60}],"fix_blacklist":{"old_k":"方法1"}}' > "$MARKER_FILE"
save_fix_state_marker "onedrive:src" "openlist:dst" "taskX" >/dev/null 2>&1
[ "$(rcat_count)" = "1" ] && ok "5a marker 恰好写入一次" || bad "5a: [$(rcat_count)]"
PAY=$(cat "$RCAP_FILE")
[ "$(echo "$PAY" | jq -r '.fixed_count')" = "301" ] && ok "5b 合计 300 新 + 1 继承 = 301" || bad "5b: [$(echo "$PAY" | jq -r '.fixed_count')]"
[ "$(echo "$PAY" | jq -r '.last_success')" = "2020-01-01T00:00:00Z" ] && ok "5c 旧 marker last_success 保留" || bad "5c: [$(echo "$PAY" | jq -r '.last_success')]"
[ "$(echo "$PAY" | jq '.fix_blacklist | length')" = "301" ] && ok "5d 黑名单 旧1+新300=301" || bad "5d: [$(echo "$PAY" | jq '.fix_blacklist | length')]"
[ "$(echo "$PAY" | jq '.fixed_files | map(select(.original=="keep_a.bin")) | length')" = "1" ] && ok "5e 继承条目 keep_a 在列" || bad "5e"
[ "$(echo "$PAY" | jq '.fixed_files | map(select(.original=="aligned_1.bin")) | length')" = "0" ] && ok "5f 已对齐条目被剔除" || bad "5f"

# ===== 场景 6: save_sync_marker 大载荷端到端（new ∪ carried 去重合并）=====
echo 0 > "$RCAT_N"
printf '%s' '{"last_success":"2019-01-01T00:00:00Z","fixed_files":[{"original":"keep_b.bin","alternative":"alt_b","size_bytes":50},{"original":"aligned_2.bin","alternative":"alt_c","size_bytes":60}]}' > "$MARKER_FILE"
save_sync_marker "onedrive:src" "openlist:dst" "taskY" >/dev/null 2>&1
[ "$(rcat_count)" = "1" ] && ok "6a marker 恰好写入一次" || bad "6a: [$(rcat_count)]"
PAY2=$(cat "$RCAP_FILE")
[ "$(echo "$PAY2" | jq -r '.fixed_count')" = "301" ] && ok "6b 300 新 + 1 继承 = 301（去重生效）" || bad "6b: [$(echo "$PAY2" | jq -r '.fixed_count')]"
[ "$(echo "$PAY2" | jq -r '.fixed_bytes')" = "30050" ] && ok "6c fixed_bytes 300×100+50" || bad "6c: [$(echo "$PAY2" | jq -r '.fixed_bytes')]"
[ "$(echo "$PAY2" | jq -r '.source_bytes')" = "123456" ] && ok "6d 源端统计写入" || bad "6d"
[ "$(echo "$PAY2" | jq '.top_dirs | length')" = "2" ] && ok "6e top_dirs 写入" || bad "6e"
[ "$(echo "$PAY2" | jq -r '.stats_filtered')" = "true" ] && ok "6f stats_filtered 标记" || bad "6f"
[ "$(echo "$PAY2" | jq -r '.last_success' | wc -c)" -gt 10 ] && ok "6g last_success 为新时间戳" || bad "6g"

# ===== 场景 7: _marker_write 拒绝空/非法 JSON（防空白 marker 覆盖好记录）=====
echo 0 > "$RCAT_N"
if _marker_write "" "onedrive:/x.json" 2>/dev/null; then bad "7a 空 JSON 应拒绝"; else ok "7a 空 JSON 拒绝写入"; fi
if _marker_write '{"broken": ' "onedrive:/x.json" 2>/dev/null; then bad "7b 非法 JSON 应拒绝"; else ok "7b 非法 JSON 拒绝写入"; fi
[ "$(rcat_count)" = "0" ] && ok "7c 两次拒绝均未触发 rcat（旧 marker 保留）" || bad "7c: [$(rcat_count)]"
if _marker_write '{"a":1}' "onedrive:/x.json" >/dev/null 2>&1; then ok "7d 合法 JSON 正常写入"; else bad "7d 合法 JSON 应成功"; fi
[ "$(rcat_count)" = "1" ] && ok "7e rcat 恰好一次" || bad "7e: [$(rcat_count)]"

# ===== 场景 8: 已对齐收尾——原名落位后删除冗余替代形态（治短名孤儿堆积，2026-09-21）=====
# 原行为只剔 marker 记录、不删远端文件 ⇒ 替代形态在目标端无限堆积（用户看到的
# 「目标端文件数越堆越多」）。现行为: 原名已落位（probe 命中且 size 一致）⇒ 删替代。
# 锁: 删对位置（含 ./ 归一化）/ size 不匹配不删（防半截原名冒充落位丢唯一副本）/
#     分卷·编码类放过 / 未对齐照旧继承 / size_bytes 缺失放过 / 开关可关。
echo 0 > "$RCAT_N"; : > "$RCAP_FILE"
DELFILE=$(mktemp); : > "$DELFILE"
# mock rclone 是被**子进程/子 shell**调用的 ⇒ 必须 export，否则子 shell 里
# DELFILE 为空、删除记录落到空路径，断言恒绿（假绿）
export DELFILE
rclone() {
  case "$1" in
    cat) cat "$MARKER_FILE" ;;
    rcat) cat > "$RCAP_FILE"; _n=$(cat "$RCAT_N"); echo $((_n+1)) > "$RCAT_N" ;;
    lsjson)
      case "$2" in
        *sz123*) echo '[{"Name":"x","Size":123}]' ;;
        *sz456*) echo '[{"Name":"x","Size":456}]' ;;
        *) echo '[]' ;;
      esac ;;
    # 命令替换是子 shell: 删除调用走文件记录才能带回父 shell 断言
    deletefile) echo "$2" >> "$DELFILE"; return 0 ;;
    size) echo '{"bytes":123456,"count":42}' ;;
    lsf) printf 'dir1/\ndir2/\n' ;;
    *) return 0 ;;
  esac
}
M8='{"fixed_files":[{"original":"sz123/a.flac","alternative":"sz123/sh1.flac","size_bytes":123},{"original":"sz456/b.flac","alternative":"sz123/sh2.flac","size_bytes":999},{"original":"sz123/c.zip","alternative":"sz123/sh3.zip.001","size_bytes":123},{"original":"sz123/d.enc","alternative":"sz123/sh4.enc","size_bytes":123},{"original":"sz123/e.flac","alternative":"./sz123/sh5.flac","size_bytes":123},{"original":"sz123/f.flac","alternative":"sz123/sh6.flac","size_bytes":0},{"original":"nomatch/g.flac","alternative":"nomatch/sh7.flac","size_bytes":1}]}'
# ⚠️ 2026-09-26 起默认**不删**（保留备份副本，与还原 copyto 同决策）⇒ 本组必须
#   显式打开开关才测得到删除路径；否则测的是"默认保留"的存量行为，删不删都绿。
#   另加 8i/8j: 默认（开关不动）下 deleted 必须为 0 —— 锁住"同步轮不再删副本"。
CARRY8=$(OPENLIST_CARRY_DELETE_ALIGNED=1 _carry_forward_fixed "openlist:dst" "$M8")
CAR8=$(echo "$CARRY8" | jq -c '.carried')
[ "$(echo "$CARRY8" | jq -r '.deleted')" = "2" ] && ok "8a 已对齐且 size 一致 ⇒ 删除 2 个替代形态" || bad "8a: deleted=$(echo "$CARRY8" | jq -r '.deleted')"
grep -qF "openlist:dst/sz123/sh1.flac" "$DELFILE" && ok "8b 短名 sh1 被删（精确 deletefile）" || bad "8b: $(cat "$DELFILE")"
grep -qF "openlist:dst/sz123/sh5.flac" "$DELFILE" && ok "8c ./ 形态归一化后删对实际落点" || bad "8c"
[ "$(echo "$CAR8" | jq 'length')" = "1" ] && ok "8d 未对齐条目照旧继承（1 条）" || bad "8d: $(echo "$CAR8" | jq 'length')"
grep -qF "sh2" "$DELFILE" && bad "8e size 不匹配 ⇒ 不得删（防半截原名冒充落位）" || ok "8e size 不匹配 ⇒ 不删"
grep -qF "sh3" "$DELFILE" && bad "8f 分卷类放过（第一版不处理）" || ok "8f 分卷类不删"
grep -qF "sh4" "$DELFILE" && bad "8g 编码类放过" || ok "8g 编码类不删"
grep -qF "sh6" "$DELFILE" && bad "8h size_bytes 缺失 ⇒ 不删" || ok "8h size_bytes 缺失不删"
: > "$DELFILE"
OPENLIST_CARRY_DELETE_ALIGNED=0 _carry_forward_fixed "openlist:dst" "$M8" >/dev/null
[ ! -s "$DELFILE" ] && ok "8i 开关=0 ⇒ 收尾删除关闭（回退到只剔记录）" || bad "8i: $(cat "$DELFILE")"
# 8j: **默认态**（不设该变量）必须也是不删 —— 锁住 2026-09-26 的默认翻转。
#   只测开关=0 测不到默认值被改坏（开关显式给值时默认值根本不参与判断）。
#   ⚠️ 不能用 `env -u X 函数`: env 只影响**子进程**，而 _carry_forward_fixed 是
#   当前 shell 的**函数**，env -u 对它无效 ⇒ 断言恒绿（假绿）。必须在子 shell 里
#   先 unset 再调用（子 shell 继承变量，unset 后才走默认分支）。
: > "$DELFILE"
( unset OPENLIST_CARRY_DELETE_ALIGNED; _carry_forward_fixed "openlist:dst" "$M8" >/dev/null )
[ ! -s "$DELFILE" ] && ok "8j ★默认（未设开关）⇒ 不删备份副本（2026-09-26 默认翻转）" || bad "8j: 默认竟在删副本: $(cat "$DELFILE")"
rm -f "$DELFILE"

# ===== 场景 9: 病灶 C——游标拒写时仍持久化修复记录（2026-09-21，§14.21）=====
# 旧行为: save_sync_marker 拒写（目标端 < 源端，防假成功）直接 return 1，本轮
# fold/修复落盘记录随内存丢失 → 下轮 initial sync 无 filter 保护 → 产物被删
# → 重 fold（接力轮 35629676323 实证: fold 97 → 拒写 → 删 → 重 fold 97）。
# 新行为: 拒写分支立即 save_fix_state_marker——只合并 fixed_files/fix_blacklist，
# 保留旧 marker 其余字段（游标不被触碰）；无旧 marker 时建不含 last_success 的
# 骨架（不会误触发 24h 跳过判断）。
echo 0 > "$RCAT_N"; : > "$RCAP_FILE"
rclone() {
  case "$1" in
    cat) cat "$MARKER_FILE" ;;
    rcat) cat > "$RCAP_FILE"; _n=$(cat "$RCAT_N"); echo $((_n+1)) > "$RCAT_N" ;;
    lsjson) echo '[]' ;;
    size)
      case "$2" in
        onedrive:src*) echo '{"bytes":1000,"count":42}' ;;
        *) echo '{"bytes":900,"count":40}' ;;
      esac ;;
    lsf) printf 'dir1/\n' ;;
    *) return 0 ;;
  esac
}
: > "$MARKER_FILE"
GLOBAL_FIXED_FILES_JSON='[{"original":"fold/a.jpg","alternative":"f27becd6/0 (1).jpg","method":"batch_fold","size_bytes":1487623}]'
GLOBAL_FIX_BLACKLIST_JSON='{"fold/a.jpg|copyto_original":1}'
SR9=$(save_sync_marker "onedrive:src" "openlist:dst" "taskZ" 2>&1); RC9=$?
[ "$RC9" -ne 0 ] && ok "9a 拒写场景返回非零（游标未写）" || bad "9a: rc=$RC9"
echo "$SR9" | grep -q "拒绝写入同步标记" && ok "9b 拒写日志在" || bad "9b: $SR9"
[ "$(rcat_count)" = "1" ] && ok "9c 拒写分支触发修复状态写入（恰好一次）" || bad "9c: [$(rcat_count)]"
PAY9=$(cat "$RCAP_FILE")
[ "$(echo "$PAY9" | jq -r '.fixed_count')" = "1" ] && ok "9d fold 记录已持久化" || bad "9d: $PAY9"
echo "$PAY9" | jq -e 'has("last_success") | not' >/dev/null && ok "9e 骨架不含 last_success（不触发跳过判断）" || bad "9e: $PAY9"
[ "$(echo "$PAY9" | jq -r '.fixed_files[0].alternative')" = "f27becd6/0 (1).jpg" ] && ok "9f alternative 原样保留（供下轮 filter）" || bad "9f"
echo "$PAY9" | jq -e '.fix_blacklist | has("fold/a.jpg|copyto_original")' >/dev/null && ok "9g 黑名单一并持久化" || bad "9g"
echo "$SR9" | grep -q "已保存修复状态" && ok "9h 拒写分支保存日志可见（可观测）" || bad "9h: $SR9"
# 9i-9j: 有旧 marker——只并修复字段，游标字段（last_success 等）不被触碰
echo 0 > "$RCAT_N"; : > "$RCAP_FILE"
printf '%s' '{"last_success":"2020-01-01T00:00:00Z","source_count":18031,"fixed_files":[],"fix_blacklist":{}}' > "$MARKER_FILE"
save_sync_marker "onedrive:src" "openlist:dst" "taskZ" >/dev/null 2>&1
PAY9B=$(cat "$RCAP_FILE")
[ "$(echo "$PAY9B" | jq -r '.last_success')" = "2020-01-01T00:00:00Z" ] && ok "9i 旧 marker last_success 保留（游标不前进）" || bad "9i: $PAY9B"
[ "$(echo "$PAY9B" | jq -r '.fixed_count')" = "1" ] && ok "9j 修复记录并入旧 marker" || bad "9j"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$MARKER_FILE" "$RCAP_FILE" "$RCAT_N"
[ $FAIL -eq 0 ]
