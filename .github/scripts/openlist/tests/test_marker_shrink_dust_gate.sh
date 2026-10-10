#!/usr/bin/env bash
# check_sync_marker「口径迁移闸门」回归测试
# 背景（实测 新金瓶梅4/5 (1996)）:
#   源端 1.359 GiB 减少 2 B、文件一个没少，却走完整告警要人工审批。
#   更严重的是 warning 会跳过同步 ⇒ marker 基线永不刷新 ⇒ 下轮同样 2 B 再告警
#   （last_success 实测卡在 2026-10-05 不动）。
#
# ⚠️ 语义（2026-10-10 主人纠正「要只对特定的文件生效」后定案）:
#   自动放行**不是按量级一刀切**，而是绑在文件类型上:
#     · meta 类（nfo/字幕/刮削元数据等无关紧要的文件）减少 ⇒ 放行
#     · payload 类（mkv/mp4/图片等正片）减少 ⇒ 告警，减 2 B 也告警
#   唯一的例外是「分层基线缺失」—— marker 写于分层归因功能(ebfcc41, 10-08)
#   之前，天生没有 source_meta_bytes/source_payload_bytes，无法按类型归因。
#   这类按既有 stats_filtered 旧口径先例**放行一次**以建立基线，
#   之后每轮回到按文件类型判定。放行时仍有两道保守闸门兜底:
#     ① 文件数未减少（少文件 = 真删，不适用迁移放行）
#     ② 绝对量 < SYNC_SHRINK_MIN_BYTES(默认 1 MiB) 且 相对量 < SYNC_SHRINK_MIN_PCT_BP(默认 1bp)
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
SIZE_COUNT=10          # ← 既有 test_marker_shrink_classify.sh 的 mock 写死 count=10，
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

# ===== 场景 1: 真实案例复现 —— 旧 marker 无分层基线，减 2 B、文件数不变 ⇒ 放行（迁移一次）=====
SIZE_BYTES=1459517260
SIZE_COUNT=6
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskDust2B" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "1 基线缺失·减2B·文件数不变 → 放行（口径迁移一次）" || bad "1 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 2: 基线缺失但少了 1 个文件 ⇒ 仍告警（真删不适用迁移放行）=====
SIZE_BYTES=1459517260
SIZE_COUNT=5
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskDustButLostFile" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "2 基线缺失·减2B·少1文件 → 仍告警" || bad "2 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 3: 基线缺失但真删 50 MiB（远超绝对阈值）⇒ 告警 =====
SIZE_BYTES=$((1459517262 - 52428800))
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskRealDrop50M" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "3 基线缺失·删50MiB → 告警（量级兜底）" || bad "3 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 4 ★核心: 基线存在 + 正片(payload)减 2 B ⇒ 必须告警 =====
# 这条是「只对特定的文件生效」的判据: 有了类型信息，正片减 2 B 不享受自动放行。
#   （若无这条，闸门退化成按量级一刀切，正片被静默放行 —— 正是主人反对的形态）
SIZE_BYTES=$((1459516260 + 1000 - 2))    # 正片少 2 B，nfo 不变
SIZE_COUNT=6
LSJSON_OUT='[{"Path":"a.mkv","Size":1459516258,"IsDir":false},{"Path":"b.nfo","Size":1000,"IsDir":false}]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":1000,"source_payload_bytes":1459516260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskPayloadDrop2B" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "4 ★ 基线存在·正片减2B → 告警（不放行）" || bad "4 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 5: 基线存在 + meta 类(nfo)减 2 B ⇒ 放行（无关紧要的文件）=====
SIZE_BYTES=$((1459516260 + 998))         # nfo 少 2 B，正片不变
SIZE_COUNT=6
LSJSON_OUT='[{"Path":"a.mkv","Size":1459516260,"IsDir":false},{"Path":"b.nfo","Size":998,"IsDir":false}]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"source_meta_bytes":1000,"source_payload_bytes":1459516260,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskMetaDrop2B" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "5 基线存在·nfo减2B → 放行（meta 类）" || bad "5 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 6: 大小完全没变 ⇒ 放行（回归，不被新闸门影响）=====
SIZE_BYTES=1000
SIZE_COUNT=10
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1000,"source_count":10,"source_meta_bytes":0,"source_payload_bytes":1000,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskNoChange" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "6 大小无变化 → 放行" || bad "6 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 7: 基线缺失 + 非法阈值 ⇒ 回退默认，仍正确放行 =====
SIZE_BYTES=1459517260
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES="abc"
SYNC_SHRINK_MIN_PCT_BP="xyz"
check_sync_marker "onedrive:src" "openlist:dst" "taskBadThresholds" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "7 非法阈值 → 回退默认，仍正确放行" || bad "7 期望 proceed，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES SYNC_SHRINK_MIN_PCT_BP

# ===== 场景 8: 基线缺失 + marker 无 source_count（旧 marker）⇒ 不崩，按 0 处理 =====
SIZE_BYTES=1459517260
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskNoCountField" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "8 marker 缺 source_count → 不崩、放行" || bad "8 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 9: 只放宽绝对阈值不够 —— 相对阈值仍兜住（双阈值互相制衡）=====
# 4.8 MiB / 1.36 GiB ≈ 0.34% = 34 bp，远超默认 1 bp ⇒ 即便绝对阈值放到 10 MiB，
# 相对条件不满足 ⇒ 落到分层归因 ⇒ 基线缺失判 payload ⇒ 告警。
SIZE_BYTES=$((1459517262 - 5000000))   # 减约 4.8 MiB
SIZE_COUNT=6
LSJSON_OUT='[]'
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES=10485760        # 只放宽绝对阈值到 10 MiB
check_sync_marker "onedrive:src" "openlist:dst" "taskBigAbsOnly" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "9 只放宽绝对阈值 → 相对阈值仍兜住（不放水）" || bad "9 期望 warning，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES

# ===== 场景 10: 两个阈值都放宽 → 才真的放行 =====
SIZE_BYTES=$((1459517262 - 5000000))
SIZE_COUNT=6
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1459517262,"source_count":6,"stats_filtered":true}'
SYNC_SHRINK_MIN_BYTES=10485760        # 10 MiB
SYNC_SHRINK_MIN_PCT_BP=100            # 1%
check_sync_marker "onedrive:src" "openlist:dst" "taskBothLoose" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "10 绝对+相对都放宽 → 减 4.8MiB 放行" || bad "10 期望 proceed，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_MIN_BYTES SYNC_SHRINK_MIN_PCT_BP

rm -f "$MARKER_FILE"
echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
