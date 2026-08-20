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
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/marker.sh"

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
CARRIED=$(_carry_forward_fixed "openlist:dst" "$OLD_MARKER")
[ "$(echo "$CARRIED" | jq 'length')" = "200" ] && ok "4a 继承 200 个未对齐条目（aligned 200 个被剔除）" || bad "4a: [$(echo "$CARRIED" | jq 'length')]"
[ "$(echo "$CARRIED" | jq '[.[].original | startswith("keep_")] | all')" = "true" ] && ok "4b 继承条目全部为 keep_*" || bad "4b"

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

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$MARKER_FILE" "$RCAP_FILE" "$RCAT_N"
[ $FAIL -eq 0 ]
