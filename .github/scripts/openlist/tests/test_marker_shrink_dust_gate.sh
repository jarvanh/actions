#!/bin/bash
# check_sync_marker「微抖动闸门」回归测试
# 背景（2026-10-09，实测新金瓶梅4 (1996)）:
#   源端 1.359 GiB 减少 2 B、6 个文件一个没少，却走完整告警要人工审批。
#   根因: 缩小检测只有「减少量落在哪类文件」这一维，没有「减少了多少」——
#     payload 类零容差 ⇒ 2 B 也告警。更糟的是 warning 会跳过同步 ⇒ marker
#     基线永不刷新 ⇒ 下轮同样 2 B 再告警。该任务 last_success 实测卡在
#     2026-10-05 不动（死循环），而 10-05 之后再没成功同步过。
#   本闸门在分层归因**之前**先按量级筛掉微抖动，放行同步 ⇒ 基线刷新 ⇒ 循环自解。
#
# 判据（两个条件「且」，另加文件数前置）:
#   ① 绝对量 < SYNC_SHRINK_MIN_BYTES（默认 1 MiB）
#   ② 相对量 < SYNC_SHRINK_MIN_PCT_BP（默认 1 bp = 0.01%）
#   前置: 文件数未减少（少文件 = 真删，不适用抖动放行）
#   ② 的意义: 兜住小库 —— 100 KB 的库删 50 KB 是 5000 bp，远超 1 bp，照样告警。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

# --- mocks ---
LSJSON_OUT='[]'
SIZE_BYTES=1000
SIZE_COUNT=10          # ← 现有 test_marker_shrink_classify.sh 的 mock 写死 count=10，
                       #    测不了「文件数减少」这个前置条件，这里做成可控
MARKER_FILE=$(mktemp)

rclone() {
  case "$1" in
    lsjson) printf '%s' "$LSJSON_OUT" ;;
    size)   echo "{\"bytes\":${SIZE_BYTES},\"count\":${SIZE_COUNT},\"human_size\":\"x\"}" ;;
    lsf)    printf 'dir1/\n' ;;
    cat)    cat "$MARKER_FILE" ;;
    *)      return 0 ;;
  esac
}
set_marker() { printf '%s' "$1" > "$MARKER_FILE"; }

# ===== 场景 1: 真实案例复现 —— 1.359 GiB 减 2 B、文件数不变 ⇒ 放行 =====
SIZE_BYTES=1459517260
SIZE_COUNT=6
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskDust2B" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "1 1.359GiB 减 2B / 6文件未少 → 放行（微抖动）" || bad "1 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 2: 同样只减 2 B，但文件数 6→5 ⇒ 仍告警（真删不适用抖动放行）=====
SIZE_BYTES=1459517260
SIZE_COUNT=5
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskDustButLostFile" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "2 减 2B 但少了 1 个文件 → 仍告警" || bad "2 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 3: 大库真删 50 MiB（远超绝对阈值）⇒ 告警 =====
SIZE_BYTES=$((1459517262 - 52428800))
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskRealDrop50M" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "3 大库删 50MiB → 告警（不被绝对阈值放水）" || bad "3 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 4: 小库删 30%（相对阈值兜住，不被绝对阈值放水）=====
SIZE_BYTES=700
SIZE_COUNT=10
LSJSON_OUT='[{"Path":"a.mkv","Size":700,"IsDir":false}]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1000,"source_count":10,"source_meta_bytes":0,"source_payload_bytes":1000,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskSmallLibDrop" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "4 小库 1000B→700B（30%）→ 告警（相对阈值生效）" || bad "4 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 5: 大小完全没变 ⇒ 放行（回归，不被新闸门影响）=====
SIZE_BYTES=1000
SIZE_COUNT=10
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1000,"source_count":10,"source_meta_bytes":0,"source_payload_bytes":1000,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskNoChange" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "5 大小无变化 → 放行" || bad "5 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 6: 相对阈值可收紧到 0（= 任何减少都不算抖动）=====
SIZE_BYTES=1459517260
SIZE_COUNT=6
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
SYNC_SHRINK_MIN_PCT_BP=0
check_sync_marker "onedrive:src" "openlist:dst" "taskStrictBp" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "6 阈值收紧到 0bp → 2B 也告警（可配置）" || bad "6 期望 warning，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_PCT_BP

# ===== 场景 7: 非法阈值回退默认（不因脏配置崩或误放行）=====
SIZE_BYTES=1459517260
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES="abc"
SYNC_SHRINK_MIN_PCT_BP="xyz"
check_sync_marker "onedrive:src" "openlist:dst" "taskBadThresholds" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "7 非法阈值 → 回退默认，仍正确放行" || bad "7 期望 proceed，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES SYNC_SHRINK_MIN_PCT_BP

# ===== 场景 8: marker 无 source_count 字段（旧 marker）⇒ 不崩，按 0 处理 =====
SIZE_BYTES=1459517260
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskNoCountField" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "8 marker 缺 source_count → 不崩、放行" || bad "8 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 9: 只放宽绝对阈值不够 —— 相对阈值仍兜住（双阈值互相制衡）=====
# 4.8 MiB / 1.36 GiB ≈ 0.34% = 34 bp，远超默认 1 bp ⇒ 即便绝对阈值放到 10 MiB，
# 相对条件不满足，仍走分层归因 ⇒ payload 减少 ⇒ 告警。
# 这条正是"只改一个阈值放不了水"的证明（初版把它写成期望 proceed，是期望写错）。
SIZE_BYTES=$((1459517262 - 5000000))   # 减约 4.8 MiB
SIZE_COUNT=6
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES=10485760        # 只放宽绝对阈值到 10 MiB
check_sync_marker "onedrive:src" "openlist:dst" "taskBigAbsOnly" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "9 只放宽绝对阈值 → 相对阈值仍兜住（不放水）" || bad "9 期望 warning，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES

# ===== 场景 10: 两个阈值都放宽 → 才真的放行 =====
SIZE_BYTES=$((1459517262 - 5000000))
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":2,"source_payload_bytes":1459517260,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES=10485760        # 10 MiB
SYNC_SHRINK_MIN_PCT_BP=100            # 1%
check_sync_marker "onedrive:src" "openlist:dst" "taskBothLoose" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "10 绝对+相对都放宽 → 减 4.8MiB 放行" || bad "10 期望 proceed，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES SYNC_SHRINK_MIN_PCT_BP

rm -f "$MARKER_FILE"
echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
