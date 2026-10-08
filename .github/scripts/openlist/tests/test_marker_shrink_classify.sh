#!/bin/bash
# check_sync_marker 缩小检测「按格式分层归因」回归测试
# 背景（2026-10-08）:
#   源端缩小检测原本只看总字节数，无法区分性质完全不同的两种"变小":
#     ① Emby 刮削器批量重写 .nfo → 总字节数抖几 B~几 KB（正常变动）
#     ② 正片被删/损坏 → 总字节数下降（数据丢失，必须告警）
#   实测案例: 裤袜视界 (2019) 减少 3 B —— 14 个 nfo 被重写，62 文件/13 mkv
#   一个没少，却被当"数据丢失"发审批卡。故引入分层归因:
#     meta 类（nfo/xml/字幕等纯文本）减少 → 判定刮削重写，放行并刷新基线
#     payload 类（mkv/mp4/图片/压缩包等二进制）减少 → 零容差，告警
# 本文件覆盖: 归因判定 + 三条保守兜底（缺基线 / 列举失败 / 超上限）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

# --- mocks（source 之后定义，覆盖脚本内同名函数）---
LSJSON_OUT='[]'          # lsjson 返回的文件清单
LSJSON_FAIL=0            # =1 模拟列举失败
SIZE_BYTES=1000
# marker 必须走临时文件，不能用全局变量:
#   check_sync_marker 开头会先把全局 MARKER_JSON 重置为 ""，之后才调 rclone cat，
#   mock 若读该变量必然拿到空 → marker_json 为空 → 走"无同步标记"分支直接 proceed，
#   所有场景都会假通过。故与 test_marker_skip_guards.sh 一致，用文件承载。
MARKER_FILE=$(mktemp)

rclone() {
  case "$1" in
    lsjson)
      if [ "$LSJSON_FAIL" = "1" ]; then return 1; fi
      printf '%s' "$LSJSON_OUT"
      ;;
    size)   echo "{\"bytes\":${SIZE_BYTES},\"count\":10,\"human_size\":\"x\"}" ;;
    lsf)    printf 'dir1/\ndir2/\n' ;;
    cat)    cat "$MARKER_FILE" ;;
    *)      return 0 ;;
  esac
}

# 写 marker: set_marker <json>
set_marker() { printf '%s' "$1" > "$MARKER_FILE"; }

# 造 lsjson 清单: mk_json <"路径:大小" ...>
mk_json() {
  local out="" e p s
  for e in "$@"; do
    p="${e%%:*}"; s="${e##*:}"
    [ -n "$out" ] && out+=","
    out+="{\"Path\":\"$p\",\"Size\":$s,\"IsDir\":false}"
  done
  echo "[$out]"
}

# ===== 场景 1: 减少量全在 nfo（meta 类）→ 放行，不告警 =====
LSJSON_OUT=$(mk_json "S01/e01.nfo:100" "S01/e01.mkv:900")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskMetaDrop" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "1 nfo 重写导致变小 → 放行（不告警）" || bad "1 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 2: 正片 mkv 变小 → 零容差告警 =====
LSJSON_OUT=$(mk_json "S01/e01.nfo:103" "S01/e01.mkv:897")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskMkvDrop" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "2 正片变小 3 B → 仍然告警（零容差）" || bad "2 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 3: 旧 marker 缺分层基线 → 保守告警 =====
LSJSON_OUT=$(mk_json "S01/e01.nfo:100" "S01/e01.mkv:900")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskNoBaseline" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "3 缺分层基线 → 保守告警（不误放行）" || bad "3 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 4: 分层列举失败 → 保守告警 =====
LSJSON_FAIL=1
LSJSON_OUT=$(mk_json "S01/e01.nfo:100" "S01/e01.mkv:900")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskListFail" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "4 分层列举失败 → 保守告警" || bad "4 期望 warning，实际 ${MARKER_ACTION}"
LSJSON_FAIL=0

# ===== 场景 5: meta 减少超上限 → 告警（防元数据被成批清空）=====
# 真实量级: 元数据基线 100 MiB 掉到 100 B（刮削重写不会掉这么多，只可能是被清空）
LSJSON_OUT=$(mk_json "S01/e01.nfo:100" "S01/e01.mkv:90000000")
SIZE_BYTES=90000100
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":194857600,"source_meta_bytes":104857600,"source_payload_bytes":90000000,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskMetaCap" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "5 meta 掉 100MiB 超上限 → 告警" || bad "5 期望 warning，实际 ${MARKER_ACTION}"

# ===== 场景 5b: 上限可由 SYNC_SHRINK_META_MAX_BYTES 收紧 =====
LSJSON_OUT=$(mk_json "S01/e01.nfo:100" "S01/e01.mkv:900")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
SYNC_SHRINK_META_MAX_BYTES=2
check_sync_marker "onedrive:src" "openlist:dst" "taskMetaCap2" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "5b 上限收紧到 2B → 减 3B 也告警" || bad "5b 期望 warning，实际 ${MARKER_ACTION}"
unset SYNC_SHRINK_META_MAX_BYTES

# ===== 场景 6: meta 减少、payload 增加，总量仍减少 → 放行 =====
LSJSON_OUT=$(mk_json "S01/e01.nfo:50" "S01/e01.mkv:950")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskMixed" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "6 meta 减 + payload 增 → 放行" || bad "6 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 7: 扩展名大小写不敏感（.NFO / .MKV）=====
LSJSON_OUT=$(mk_json "S01/E01.NFO:100" "S01/E01.MKV:900")
SIZE_BYTES=1000
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskUpper" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "7 大写扩展名 .NFO 归入 meta → 放行" || bad "7 期望 proceed，实际 ${MARKER_ACTION}"

# ===== 场景 8: 真实数据丢失（文件数也降）仍告警（不因分层被误放行）=====
LSJSON_OUT=$(mk_json "S01/e01.nfo:103")
SIZE_BYTES=103
set_marker '{"last_success":"2020-01-01T00:00:00Z","source_bytes":1003,"source_meta_bytes":103,"source_payload_bytes":900,"stats_filtered":true}'
check_sync_marker "onedrive:src" "openlist:dst" "taskRealLoss" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "8 正片整段消失 → 告警" || bad "8 期望 warning，实际 ${MARKER_ACTION}"

rm -f "$MARKER_FILE"
echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
