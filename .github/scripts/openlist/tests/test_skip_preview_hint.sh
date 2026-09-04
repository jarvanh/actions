#!/bin/bash
# 跳过窗口的"预览预判断" + 跳过通知的"本次未传"量 —— 逻辑验证
# 背景: 预览 pass 不查 marker，而同步 pass 的跳过判断在任何传输之前，
#   于是带 --Nd-skip 的任务会"预览显示 +1.7 GiB 待同步、随后一个字节都不传"，
#   事后复盘反复被当成丢数据（实为窗口内的省流策略）。本测试锁定两处修复:
#   1) 预览: 命中跳过窗口的同步对标 ⏭️ 本轮预计跳过，合计附"预计实际传输"
#   2) 跳过通知: 展示"本次未传"量（预览缓存优先，未命中则现场估算；
#      估算不可靠时整段不展示，宁缺毋滥）
# mock: rclone（lsjson/cat）、timeout、sleep、tg_* 与 send_telegram_message
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"
source "$_REPO_ROOT/.github/scripts/openlist/task_preview.sh"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
timeout() { shift; "$@"; }
sleep()   { :; }

LSJSON_CALLS=/tmp/test_skip_hint_lsjson; echo 0 > "$LSJSON_CALLS"

# 源端 3 文件、目标端仅 a.bin → 待同步 b.bin + c.bin = 500 B / 2 文件
SRC_JSON='[{"Path":"a.bin","Size":100},{"Path":"b.bin","Size":200},{"Path":"c.bin","Size":300}]'
DST_JSON='[{"Path":"a.bin","Size":100}]'
SUB_SRC_JSON='[{"Path":"x.bin","Size":50}]'
SUB_DST_JSON='[]'
MARKER_JSON='{}'

rclone() {
  case "$1" in
    lsjson)
      local n
      n=$(cat "$LSJSON_CALLS"); echo $((n+1)) > "$LSJSON_CALLS"
      case "$2" in
        "onedrive:skip")     printf '%s' "$SRC_JSON" ;;
        "openlist:skipdst")  printf '%s' "$DST_JSON" ;;
        "openlist:skipfail") return 7 ;;
        onedrive:skip/*)     printf '%s' "$SUB_SRC_JSON" ;;
        openlist:skipdst/*)  printf '%s' "$SUB_DST_JSON" ;;
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
tg_add_kv()      { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "$2: $3"$'\n'; }
tg_add_path()    { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "$2: $3"$'\n'; }
tg_append()      { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "$2"; }
tg_add_note()    { local _n="$1"; printf -v "$_n" '%s%s' "${!_n}" "$2"; }
tg_add_footer()  { :; }  # 收尾区接线（TG_RUN_URL/TG_RUN_STARTED_AT）不在本测试范围
send_telegram_message() { SEND_CAPTURE="$1"; }

# ISO8601 时间戳（N 小时前）: GNU date 优先（CI ubuntu），BSD/macOS date 回退
_hours_ago() {
  local h="$1"
  date -u -d "-${h} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -v-${h}H +%Y-%m-%dT%H:%M:%SZ
}

_reset_preview_state() {
  PREVIEW_TASK_NAME="$1"
  PREVIEW_PAIR_COUNT=0
  PREVIEW_TOTAL_SYNC_BYTES=0
  PREVIEW_TOTAL_SYNC_COUNT=0
  PREVIEW_TOTAL_NEW_COUNT=0
  PREVIEW_TOTAL_UPD_COUNT=0
  PREVIEW_FAIL_PAIRS=0
  PREVIEW_PAIRS_TSV=""
}

# 预览侧调用形态（task_engine.sh sync_task 用前缀赋值传 --Nd-skip 天数）
_add_pair() {
  _TASK_SKIP_DAYS="$1" add_preview_pair "onedrive:skip" "${2:-openlist:skipdst}" --delete-before >/dev/null
}

_tsv_field13() {
  local _line="${PREVIEW_PAIRS_TSV%$'\n'}"
  IFS=$'\t' read -r _t _s _e _sb _sc _d _yb _yc _yn _yu _fn _df _ps <<< "$_line"
  printf '%s' "${_ps:-}"
}

# ===== S1: marker 落在窗口内 → 预览标注"本轮预计跳过" =====
MARKER_JSON="{\"last_success\":\"$(_hours_ago 3)\",\"source_bytes\":600,\"source_count\":3}"
_reset_preview_state "backup"
_add_pair 1
_ps="$(_tsv_field13)"
case "$_ps" in
  1\|*) ok "S1a pskip 字段标记预计跳过 [$_ps]" ;;
  *) bad "S1a pskip 应标记跳过: [$_ps]" ;;
esac
[ "${_ps##*|}" = "3" ] && ok "S1b pskip 携带距今小时数 = 3" || bad "S1b: [${_ps##*|}]"
[ "$PREVIEW_TOTAL_SYNC_COUNT" = "2" ] && [ "$PREVIEW_TOTAL_SYNC_BYTES" = "500" ] \
  && ok "S1c 差异照常计入合计（500 B / 2 文件）" \
  || bad "S1c: [$PREVIEW_TOTAL_SYNC_BYTES/$PREVIEW_TOTAL_SYNC_COUNT]"

SEND_CAPTURE=""
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '+500 B / +2 文件' \
  && ok "S1d 条目行仍展示待同步量" || bad "S1d: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '⏭️ 上次成功距今 3 小时' \
  && ok "S1e 条目子行标注预计跳过" || bad "S1e: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '本轮预计跳过：<b>500 B</b> / <b>2</b> 文件' \
  && ok "S1f 合计附注给出预计跳过量" || bad "S1f: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '预计实际传输 <b>0 B</b> / <b>0</b> 文件' \
  && ok "S1g 合计附注给出预计实际传输 = 0" || bad "S1g: $SEND_CAPTURE"

# ===== S2: marker 超出窗口（72 小时前）→ 不标注 =====
MARKER_JSON="{\"last_success\":\"$(_hours_ago 72)\"}"
_reset_preview_state "expired"
_add_pair 1
[ "$(_tsv_field13)" = "0" ] && ok "S2a 超窗口 → pskip=0" || bad "S2a: [$(_tsv_field13)]"
SEND_CAPTURE=""
flush_task_preview >/dev/null
echo "$SEND_CAPTURE" | grep -q '本轮预计跳过' \
  && bad "S2b 超窗口不应渲染跳过附注" || ok "S2b 超窗口无跳过附注"
echo "$SEND_CAPTURE" | grep -q '⏭️ 上次成功距今' \
  && bad "S2c 超窗口不应渲染条目标记" || ok "S2c 超窗口无条目标记"

# ===== S3: marker 无 last_success → 不标注 =====
MARKER_JSON='{"source_bytes":600,"source_count":3}'
_reset_preview_state "nomarker_ts"
_add_pair 1
[ "$(_tsv_field13)" = "0" ] && ok "S3 无 last_success → pskip=0" || bad "S3: [$(_tsv_field13)]"

# ===== S4: FORCE_SYNC=true → 不标注（强制同步必然执行）=====
MARKER_JSON="{\"last_success\":\"$(_hours_ago 1)\"}"
FORCE_SYNC=true
_reset_preview_state "forced"
_add_pair 1
[ "$(_tsv_field13)" = "0" ] && ok "S4 FORCE_SYNC=true → pskip=0" || bad "S4: [$(_tsv_field13)]"
unset FORCE_SYNC

# ===== S5: 未开启 --Nd-skip → 不标注（窗口判断只对开启者生效）=====
MARKER_JSON="{\"last_success\":\"$(_hours_ago 1)\"}"
_reset_preview_state "noskipflag"
_add_pair 0
[ "$(_tsv_field13)" = "0" ] && ok "S5 未开启 --Nd-skip → pskip=0" || bad "S5: [$(_tsv_field13)]"

# ===== S6: 跳过通知命中预览缓存 → 展示本次未传（零额外列举）=====
MARKER_JSON="{\"last_success\":\"$(_hours_ago 3)\",\"source_bytes\":600,\"source_count\":3}"
_reset_preview_state "backup"
_add_pair 1
_calls_before=$(cat "$LSJSON_CALLS")
MARKER_JSON="{\"last_success\":\"$(_hours_ago 3)\",\"source_bytes\":600,\"source_count\":3}"
MARKER_LAST_SUCCESS="$(_hours_ago 3)"
MARKER_SINCE_HOURS=3
SEND_CAPTURE=""
send_sync_skipped "backup" "onedrive:skip" "openlist:skipdst"
echo "$SEND_CAPTURE" | grep -q '本次未传' \
  && ok "S6a 跳过通知含「本次未传」段" || bad "S6a: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '<b>500 B</b> / <b>2</b> 文件' \
  && ok "S6b 未传量取自预览缓存（500 B / 2 文件）" || bad "S6b: $SEND_CAPTURE"
[ "$(cat "$LSJSON_CALLS")" = "$_calls_before" ] \
  && ok "S6c 命中缓存未新增 lsjson 调用" || bad "S6c: [$(cat "$LSJSON_CALLS") vs $_calls_before]"

# ===== S7: 子任务（预览无独立条目）→ 现场估算 =====
SEND_CAPTURE=""
send_sync_skipped "backup_sub" "onedrive:skip/sub" "openlist:skipdst/sub"
echo "$SEND_CAPTURE" | grep -q '本次未传' \
  && ok "S7a 子任务跳过通知含「本次未传」" || bad "S7a: $SEND_CAPTURE"
echo "$SEND_CAPTURE" | grep -q '<b>50 B</b> / <b>1</b> 文件' \
  && ok "S7b 现场估算值正确（50 B / 1 文件）" || bad "S7b: $SEND_CAPTURE"

# ===== S8: 目标端列举失败 → 不展示（避免按空目标端虚报全量）=====
SEND_CAPTURE=""
send_sync_skipped "backup_fail" "onedrive:skip" "openlist:skipfail"
echo "$SEND_CAPTURE" | grep -q '本次未传' \
  && bad "S8 目标端列举失败不应展示未传量" || ok "S8 目标端列举失败 → 整段不展示"

# ===== S9: 关闭估算开关 → 子任务不展示 =====
OPENLIST_SKIP_ESTIMATE=0
SEND_CAPTURE=""
send_sync_skipped "backup_sub2" "onedrive:skip/sub2" "openlist:skipdst/sub2"
echo "$SEND_CAPTURE" | grep -q '本次未传' \
  && bad "S9 OPENLIST_SKIP_ESTIMATE=0 不应估算" || ok "S9 关闭估算开关 → 不展示"
unset OPENLIST_SKIP_ESTIMATE

# ===== S10: sync_task 在预览 pass 把 --Nd-skip 天数传给 _preview_register =====
# 抽取式（同 test_sync_task_status_mapping.sh）: 预览分支在任何 progress_*
# 调用之前 return，只需 stub _preview_register 捕获前缀变量
_S10_DIR="$(mktemp -d)"
sed -n '/^sync_task()/,/^}/p' "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" > "$_S10_DIR/extracted.sh"
source "$_S10_DIR/extracted.sh"
RCLONE_SYNC_TASK_FLAGS=()
SYNC_AUTO_SPLIT_DEPTH=0
TASK_PREVIEW_ONLY=1
TASK_REGISTER_ONLY=0
_CAP_SKIP_DAYS="unset"
_preview_register() { _CAP_SKIP_DAYS="${_TASK_SKIP_DAYS:-unset}"; }

sync_task "onedrive:0" "openlist:d/0" "task0" --auto-split --2d-skip >/dev/null 2>&1
[ "$_CAP_SKIP_DAYS" = "2" ] && ok "S10a --2d-skip → 预览收到 _TASK_SKIP_DAYS=2" \
  || bad "S10a: [$_CAP_SKIP_DAYS]"
_CAP_SKIP_DAYS="unset"
sync_task "onedrive:0" "openlist:d/0" "task0" --auto-split >/dev/null 2>&1
[ "$_CAP_SKIP_DAYS" = "0" ] && ok "S10b 未带 --Nd-skip → _TASK_SKIP_DAYS=0" \
  || bad "S10b: [$_CAP_SKIP_DAYS]"
rm -rf "$_S10_DIR"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$LSJSON_CALLS"
[ $FAIL -eq 0 ]
