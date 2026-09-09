#!/bin/bash
# check_sync_marker 跳过窗口与缩小检测的两道防护回归测试
# 背景（2026-09-09 审查修复）:
#   1. 时钟回拨防护: last_success 来自未来（runner 时钟回拨/时钟漂移）时
#      diff 为负，历史上直接命中 "diff < SYNC_SKIP_SECONDS" → 误判窗口内
#      → 静默跳过。修复后负 diff 对齐 check_marker_skip_window 口径（未命中
#      窗口 = 继续同步）。
#   2. 列举失败 ≠ 数据缩小: rclone size 瞬时失败回退 bytes=0，历史上把
#      0 < marker_bytes 误判成"源端大小减小"，发失真告警并跳过同步。
#      修复后列举失败 fail-open（放行同步，不把列举失败当缩小）。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_query.sh"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
timeout() { shift; "$@"; }

MARKER_FILE=$(mktemp)
SIZE_MODE="ok"   # ok / fail —— 控制 rclone size 的行为
SIZE_BYTES=0

rclone() {
  case "$1" in
    cat) cat "$MARKER_FILE" ;;
    size)
      if [ "$SIZE_MODE" = "fail" ]; then return 1; fi
      echo "{\"bytes\":${SIZE_BYTES},\"count\":10,\"human_size\":\"x\"}"
      ;;
    lsf) printf 'dir1/\ndir2/\n' ;;
    *) return 0 ;;
  esac
}

# ===== 场景 1: 时钟回拨（last_success 在未来）→ 不误判窗口内，放行同步 =====
FORCE_SYNC="false"
printf '%s' '{"last_success":"2030-01-01T00:00:00Z","source_bytes":1000,"stats_filtered":true}' > "$MARKER_FILE"
SIZE_BYTES=1000
check_sync_marker "onedrive:src" "openlist:dst" "taskSkew" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "1a 未来时间戳（diff<0）放行同步，不误跳过" || bad "1a: MARKER_ACTION=$MARKER_ACTION"

# sanity: 正常窗口内（1 小时前成功）仍应 skip——防护不破坏原语义
NOW_1H=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ')
printf '%s' "{\"last_success\":\"${NOW_1H}\",\"source_bytes\":1000,\"stats_filtered\":true}" > "$MARKER_FILE"
check_sync_marker "onedrive:src" "openlist:dst" "taskSkew" >/dev/null 2>&1
[ "$MARKER_ACTION" = "skip" ] && ok "1b 窗口内正常时间戳仍 skip（原语义保持）" || bad "1b: MARKER_ACTION=$MARKER_ACTION"

# ===== 场景 2: 列举失败 fail-open（不把列举失败当数据缩小）=====
printf '%s' '{"last_success":"2020-01-01T00:00:00Z","source_bytes":100000,"stats_filtered":true}' > "$MARKER_FILE"
SIZE_MODE="fail"
check_sync_marker "onedrive:src" "openlist:dst" "taskFail" >/tmp/_msg_fail.log 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "2a rclone size 失败放行同步（fail-open）" || bad "2a: MARKER_ACTION=$MARKER_ACTION"
grep -q "无法获取源端统计" /tmp/_msg_fail.log && ok "2b 失败原因写入日志（可排查）" || bad "2b: 缺失诊断日志"
SIZE_MODE="ok"

# ===== 场景 3: 真实缩小仍告警（防护不被本次修复废掉）=====
printf '%s' '{"last_success":"2020-01-01T00:00:00Z","source_bytes":100000,"stats_filtered":true}' > "$MARKER_FILE"
SIZE_BYTES=500
check_sync_marker "onedrive:src" "openlist:dst" "taskShrink" >/dev/null 2>&1
[ "$MARKER_ACTION" = "warning" ] && ok "3a 真实缩小仍判 warning" || bad "3a: MARKER_ACTION=$MARKER_ACTION"

# 场景 3b: 旧口径 marker（无 stats_filtered）缩小 → 口径迁移放行
printf '%s' '{"last_success":"2020-01-01T00:00:00Z","source_bytes":100000}' > "$MARKER_FILE"
check_sync_marker "onedrive:src" "openlist:dst" "taskShrink" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "3b 旧口径 marker 缩小按口径迁移放行" || bad "3b: MARKER_ACTION=$MARKER_ACTION"

# ===== 场景 4: FORCE_SYNC 仍跳过全部检查 =====
FORCE_SYNC="true"
check_sync_marker "onedrive:src" "openlist:dst" "taskForce" >/dev/null 2>&1
[ "$MARKER_ACTION" = "proceed" ] && ok "4a FORCE_SYNC 直接放行" || bad "4a: MARKER_ACTION=$MARKER_ACTION"
FORCE_SYNC="false"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$MARKER_FILE" /tmp/_msg_fail.log
[ $FAIL -eq 0 ]
