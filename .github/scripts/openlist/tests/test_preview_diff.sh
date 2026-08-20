#!/bin/bash
# 预览差异估算（lsjson 逐文件比对，替代历史总量差值法）——逻辑验证
# mock rclone（lsjson/cat），覆盖:
#   1. 新增/同名更新分别计数; 修复文件按 marker original 精确剔除
#      （只剔除真实出现在差异里的条目，不再按总数盲减）
#   2. 源端清单缓存: 同源端重复统计（进度注册）不重复拉清单
#   3. 源端清单失败 → 无变动（不误报全量）
#   4. 目标端清单失败 → 快速失败重试 3 次后按全量待同步估算，
#      且预览明示 ⚠️（条目子行 + 合计附注——静默全量会把目标端已有大半
#      文件的对虚报成全量，合计虚高数倍）
#   5. 无 marker 修复记录 → 缺失文件全额计入
#   6. 渲染: 差异构成子行 / 无变动 / 合计构成附注
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/marker.sh"
source "$_REPO_ROOT/.github/scripts/openlist/preview.sh"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
timeout() { shift; "$@"; }
sleep()   { :; }   # 重试退避立即返回，测试不等 20s

LSJSON_CALLS=/tmp/test_preview_lsjson_calls; echo 0 > "$LSJSON_CALLS"
# dstflaky 前 2 次列举失败、第 3 次成功（模拟驱动懒加载/限流后恢复）
FLAKY_REMAIN=/tmp/test_preview_flaky; echo 2 > "$FLAKY_REMAIN"

SRC_JSON='[]'
DST_JSON='[]'
MARKER_JSON='{}'

rclone() {
  case "$1" in
    lsjson)
      # 计数落文件: 命令替换是子 shell，内存变量回不到父进程
      local n
      n=$(cat "$LSJSON_CALLS"); echo $((n+1)) > "$LSJSON_CALLS"
      case "$2" in
        "onedrive:backup")   printf '%s' "$SRC_JSON" ;;
        "onedrive:src6")     printf '%s' "$SRC_JSON" ;;
        "onedrive:srcbig")   printf '%s' "$SRC_JSON" ;;
        "onedrive:src8")     printf '%s' "$SRC_JSON" ;;
        "openlist:dst")      printf '%s' "$DST_JSON" ;;
        "onedrive:srcfail")  return 7 ;;
        "openlist:dstfail")  return 7 ;;
        "openlist:dstflaky")
          local _r
          _r=$(cat "$FLAKY_REMAIN")
          if [ "$_r" -gt 0 ]; then echo $((_r-1)) > "$FLAKY_REMAIN"; return 7; fi
          printf '%s' "$DST_JSON" ;;
        *) echo '[]' ;;
      esac
      ;;
    cat) printf '%s' "$MARKER_JSON" ;;
    *) return 0 ;;
  esac
}

SEND_CAPTURE=""
tg_add_title()   { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "TITLE:$2"$'\n'; }
tg_add_section() { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "SECTION:$2"$'\n'; }
tg_append()      { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "$2"; }
send_telegram_message() { SEND_CAPTURE="$1"; }

lsjson_call_count() { cat "$LSJSON_CALLS"; }

# ===== 场景 1: 新增 + 同名更新 + 修复文件精确剔除 =====
# 源端 5 文件:
#   same.bin    两端一致           → 不计
#   new.bin     目标缺失           → 新增(200)
#   latest      同名大小不同(700/500) → 同名更新(700)   ← 旧法只贡献字节差、文件数为 0 的元凶
#   fixed1.bin  目标缺失但 marker 有修复记录 → 剔除(300)
#   aligned.bin 两端一致           → 不计
# marker 另有 ghost.bin（源端没有，不在差异中）→ 不影响（旧法盲减会误吞）
SRC_JSON='[{"Path":"same.bin","Size":100},{"Path":"new.bin","Size":200},{"Path":"latest.tar.gz","Size":700},{"Path":"fixed1.bin","Size":300},{"Path":"aligned.bin","Size":50}]'
DST_JSON='[{"Path":"same.bin","Size":100},{"Path":"latest.tar.gz","Size":500},{"Path":"aligned.bin","Size":50},{"Path":"alt_of_fixed1.bin","Size":300}]'
MARKER_JSON='{"fixed_count":2,"fixed_bytes":1299,"fixed_files":[{"original":"fixed1.bin","alternative":"alt_of_fixed1.bin","size_bytes":300},{"original":"ghost.bin","alternative":"alt_ghost.bin","size_bytes":999}]}'

start_task_preview "backup" >/dev/null
add_preview_pair "onedrive:backup" "openlist:dst" --delete-before --exclude '/notion/**' >/dev/null

[ "$PREVIEW_TOTAL_SYNC_COUNT" = "2" ]  && ok "1a 待同步文件数 = 新增1+更新1 = 2" || bad "1a: [$PREVIEW_TOTAL_SYNC_COUNT]"
[ "$PREVIEW_TOTAL_SYNC_BYTES" = "900" ] && ok "1b 待同步字节 = 200+700 = 900" || bad "1b: [$PREVIEW_TOTAL_SYNC_BYTES]"
[ "$PREVIEW_TOTAL_NEW_COUNT" = "1" ]   && ok "1c 新增计数 = 1" || bad "1c: [$PREVIEW_TOTAL_NEW_COUNT]"
[ "$PREVIEW_TOTAL_UPD_COUNT" = "1" ]   && ok "1d 同名更新计数 = 1" || bad "1d: [$PREVIEW_TOTAL_UPD_COUNT]"

# TSV 字段: src/excl/sbytes/scount/dst/ybytes/ycount/ynew/yupd/fnote/dfail
_line="${PREVIEW_PAIRS_TSV%$'\n'}"
IFS=$'\t' read -r _src _excl _sb _sc _dst _yb _yc _yn _yu _fn _df <<< "$_line"
[ "$_sb" = "1350" ] && [ "$_sc" = "5" ] && ok "1e 源端总量 1350 B / 5 文件" || bad "1e: [$_sb/$_sc]"
[ "$_yb" = "900" ] && [ "$_yc" = "2" ] && ok "1f 条目待同步 900 B / 2 文件" || bad "1f: [$_yb/$_yc]"
[ "$_yn" = "1" ] && [ "$_yu" = "1" ] && ok "1g 条目构成 新增1/更新1" || bad "1g: [$_yn/$_yu]"
[ "$_fn" = " · <i>已扣减 1 个修复文件 / 300 B</i>" ] && ok "1h 修复扣减注记（仅剔除命中差异的 fixed1.bin）" || bad "1h: [$_fn]"
[ "$_df" = "0" ] && ok "1i dfail 字段 = 0（目标端列举正常）" || bad "1i: [$_df]"

# 渲染 + 发送
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '差异构成：新增 1 · 同名更新 1' && ok "1j 渲染差异构成子行" || bad "1j"
echo "$SEND_CAPTURE" | grep -q '+900 B / +2 文件' && ok "1k 条目行 +900 B / +2 文件" || bad "1k: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '已扣减 1 个修复文件 / 300 B' && ok "1l 渲染修复扣减子行" || bad "1l"
echo "$SEND_CAPTURE" | grep -q '合计预估待同步：<b>900 B</b> / <b>2</b> 文件（新增 1 · 同名更新 1）' \
  && ok "1m 合计行含构成附注" || bad "1m: $SEND_CAPTURE"
[ "$(lsjson_call_count)" = "2" ] && ok "1n 源/目标各列一次（2 次 lsjson）" || bad "1n: [$(lsjson_call_count)]"

# ===== 场景 2: 源端清单缓存（进度注册复用，不重复拉清单）=====
_out=$(_get_source_size_with_excludes "onedrive:backup" --delete-before --exclude '/notion/**')
[ "$_out" = "1350 5" ] && ok "2a 源端大小接口返回 \"1350 5\"" || bad "2a: [$_out]"
[ "$(lsjson_call_count)" = "2" ] && ok "2b 缓存命中，未新增 lsjson 调用" || bad "2b: [$(lsjson_call_count)]"

# ===== 场景 3: 源端清单失败 → 无变动（不误报全量）=====
start_task_preview "srcfail" >/dev/null
add_preview_pair "onedrive:srcfail" "openlist:dst" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "0" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "0" ] \
  && ok "3a 源端清单失败 → 待同步 0（无变动）" || bad "3a: [$PREVIEW_TOTAL_SYNC_COUNT/$PREVIEW_TOTAL_SYNC_BYTES]"
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '无变动' && ok "3b 渲染无变动" || bad "3b: $SEND_CAPTURE"

# ===== 场景 4: 目标端清单失败 → 重试 3 次后全量估算 + 预览明示 ⚠️ =====
# 源端 5 文件全部视为新增，fixed1.bin 仍被 marker 剔除 → 4 文件 / 1050 B
start_task_preview "dstfail" >/dev/null
add_preview_pair "onedrive:backup" "openlist:dstfail" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "4" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "1050" ] \
  && ok "4a 目标端失败 → 全量估算 4 文件 / 1050 B（修复文件仍剔除）" \
  || bad "4a: [$PREVIEW_TOTAL_SYNC_COUNT/$PREVIEW_TOTAL_SYNC_BYTES]"
[ "$(lsjson_call_count)" = "9" ] && ok "4b 快速失败重试 3 次 + 诊断 1 次（S3 的 2 + 源端 1 + 目标端 4 + 诊断 1）" \
  || bad "4b: [$(lsjson_call_count)]"
[ "$PREVIEW_FAIL_PAIRS" = "1" ] && ok "4c 失败对计数 = 1" || bad "4c: [$PREVIEW_FAIL_PAIRS]"
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '目标端列举失败 · 按全量估算' && ok "4d 条目子行明示 ⚠️ 不可靠估算" || bad "4d: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '1 个同步对目标端列举失败' && ok "4e 合计附注明示失败对数" || bad "4e: $SEND_CAPTURE"

# ===== 场景 5: 无 marker 修复记录 → 缺失文件全额计入 =====
# fixed1.bin 不再剔除: 新增 = new.bin + fixed1.bin = 2, 更新 = latest = 1
MARKER_JSON='{}'
start_task_preview "nomarker" >/dev/null
add_preview_pair "onedrive:backup" "openlist:dst" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "3" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "1200" ] \
  && ok "5a 无修复记录 → 3 文件 / 1200 B 全额计入" \
  || bad "5a: [$PREVIEW_TOTAL_SYNC_COUNT/$PREVIEW_TOTAL_SYNC_BYTES]"
[ "$(lsjson_call_count)" = "10" ] && ok "5b 同口径源端缓存命中（仅目标端 +1 次调用）" || bad "5b: [$(lsjson_call_count)]"

# ===== 场景 6: 纯新增（无同名更新）→ 不渲染差异构成子行 =====
# （用独立源端路径，避免读到场景 5 缓存的 5 文件清单）
SRC_JSON='[{"Path":"a.bin","Size":10}]'
DST_JSON='[]'
MARKER_JSON='{}'
start_task_preview "purenew" >/dev/null
add_preview_pair "onedrive:src6" "openlist:dst" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_NEW_COUNT" = "1" ] && [ "$PREVIEW_TOTAL_UPD_COUNT" = "0" ] \
  && ok "6a 纯新增 1/0" || bad "6a: [$PREVIEW_TOTAL_NEW_COUNT/$PREVIEW_TOTAL_UPD_COUNT]"
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '差异构成' && bad "6b 纯新增不应渲染差异构成" || ok "6b 纯新增无差异构成子行"
echo "$SEND_CAPTURE" | grep -q '（新增' && bad "6c 纯新增合计不应带构成附注" || ok "6c 纯新增合计无附注"
[ "$(lsjson_call_count)" = "12" ] && ok "6d 缓存生效（场景5 源端+目标各1、场景6 独立源端+目标各1）" \
  || bad "6d: [$(lsjson_call_count)]"

# ===== 场景 7: 大清单超内核单参数上限（MAX_ARG_STRLEN ≈ 128KB）=====
# 历史缺陷: src/dst 清单经 --argjson 命令行传参，清单超过 ~128KB（约 700+ 文件）时
# execve 直接 E2BIG "Argument list too long"，失败被 2>/dev/null 吞掉 → diff_tsv 空
# → 所有同步对恒显示 无变动/+0，合计恒 "0 B / 0 文件"（线上全量复现）
_big_src="["; _sep=""
for i in $(seq 1 5000); do
  _big_src+="$_sep{\"Path\":\"d/file_$i.bin\",\"Size\":100}"
  _sep=","
done
_big_src+="]"
[ "${#_big_src}" -gt 131072 ] && ok "7a 测试清单超 128KB（${#_big_src} B）" || bad "7a: 清单未超上限 [${#_big_src} B]"
SRC_JSON="$_big_src"
DST_JSON='[]'
MARKER_JSON='{}'
start_task_preview "biglist" >/dev/null
add_preview_pair "onedrive:srcbig" "openlist:dst" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "5000" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "500000" ] \
  && ok "7b 大清单差异 = 5000 文件 / 500000 B（不再被参数上限清零）" \
  || bad "7b: [$PREVIEW_TOTAL_SYNC_COUNT/$PREVIEW_TOTAL_SYNC_BYTES]"

# ===== 场景 8: 目标端瞬时失败 → 重试恢复（驱动懒加载/限流后自愈）=====
# dstflaky 前 2 次列举失败、第 3 次成功: 差异应精确，不虚报全量、无 ⚠️
SRC_JSON='[{"Path":"a.bin","Size":10},{"Path":"b.bin","Size":20}]'
DST_JSON='[{"Path":"a.bin","Size":10}]'
MARKER_JSON='{}'
start_task_preview "flaky" >/dev/null
add_preview_pair "onedrive:src8" "openlist:dstflaky" --delete-before >/dev/null
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "1" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "20" ] \
  && ok "8a 重试恢复后差异精确 = 1 文件 / 20 B（非全量 2 文件）" \
  || bad "8a: [$PREVIEW_TOTAL_SYNC_COUNT/$PREVIEW_TOTAL_SYNC_BYTES]"
[ "$PREVIEW_FAIL_PAIRS" = "0" ] && ok "8b 恢复后不计失败对" || bad "8b: [$PREVIEW_FAIL_PAIRS]"
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '目标端列举失败' && bad "8c 恢复后不应渲染 ⚠️" || ok "8c 恢复后无 ⚠️ 提示"
echo "$SEND_CAPTURE" | grep -q '+20 B / +1 文件' && ok "8d 条目行 +20 B / +1 文件" || bad "8d: $SEND_CAPTURE"
[ "$(lsjson_call_count)" = "18" ] && ok "8e 调用数 = S7 后 14 + 源端 1 + 目标端重试 3" \
  || bad "8e: [$(lsjson_call_count)]"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$LSJSON_CALLS" "$FLAKY_REMAIN"
[ $FAIL -eq 0 ]
