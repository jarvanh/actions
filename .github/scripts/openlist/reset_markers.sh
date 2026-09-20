#!/bin/bash
# ===== marker 归档 + 重置（一次性运维，2026-09-20 串写修复后的数据清洗）=====
#
# 为什么需要它:
#   marker 串写 bug（见 task_engine.sh 子目录循环注释）把**别处目录**的修复记录
#   写进了不该写的 marker。串写进来的 original 指向**别处的文件**，一键还原按它
#   会把 A 的备份搬到 B 名下 —— 短哈希不可逆（md5 前 8 位），搬错就再也回不去。
#   代码已修（2852b30），但**历史 marker 里的脏记录还在**，必须清掉。
#
# 为什么"先归档再清空"而不是直接删:
#   marker 是修复文件还原链路的唯一索引，与源端同在 OneDrive。清空前必须先留一份
#   可回滚的副本 —— 后续若发现"某条其实是有效记录"，还有得查。
#   归档走 backup_sync_state_to_dropbox 的**同一套两道判据**（列表非空 + 真下到文件），
#   避免"空包覆盖好备份"这类把退路变成陷阱的事故。
#
# ⚠️ 安全边界:
#   - 归档**先于**清空，且归档失败 ⇒ **拒绝清空**（没有退路就不许动手）
#   - 清空用 rclone delete（只删文件，保留 sync_state 目录本身）
#   - 默认 **dry-run**: 必须显式给 --commit 才真的删
#
# 用法: bash reset_markers.sh [--commit]
#   （需先装好 rclone 配置；无参数时只打印将要做什么）
set -u

COMMIT=0
[ "${1:-}" = "--commit" ] && COMMIT=1

STATE_DIR="${SYNC_STATE_DIR:-onedrive:/logs/sync_state}"
ARCHIVE_REMOTE="${MARKER_RESET_ARCHIVE:-dropbox:self-hosted/openlist/sync_state_reset_archive}"

echo "=== marker 归档 + 重置 ==="
echo "  marker 目录: ${STATE_DIR}"
echo "  归档目的地: ${ARCHIVE_REMOTE}"
echo "  模式: $([ "$COMMIT" = "1" ] && echo '**COMMIT（真会删）**' || echo 'dry-run（只打印，不删）')"
echo ""

# ---- 判据 1: 列表非空 ----
remote_files=$(rclone lsf "$STATE_DIR" --files-only --retries 2 2>/dev/null | grep -c . || true)
[[ "$remote_files" =~ ^[0-9]+$ ]] || remote_files=0
echo "  远端 marker 文件数: ${remote_files}"
if [ "$remote_files" -eq 0 ]; then
  echo "❌ 列表为空（读不到 marker）⇒ 拒绝继续（无法确认要清什么）"
  exit 1
fi

# ---- 判据 2: 真下到了文件 ----
TMP=$(mktemp -d /tmp/marker_reset_XXXXXX)
trap 'rm -rf "$TMP"' EXIT
rclone copy "$STATE_DIR" "$TMP/sync_state" --retries 2 --low-level-retries 5 --timeout 10m >/dev/null 2>&1
local_n=$(find "$TMP/sync_state" -type f 2>/dev/null | wc -l | tr -d ' ')
[[ "$local_n" =~ ^[0-9]+$ ]] || local_n=0
echo "  实际下载到: ${local_n} 个"
if [ "$local_n" -lt "$remote_files" ]; then
  echo "❌ 下载数 ${local_n} < 列表数 ${remote_files} ⇒ 读取异常，拒绝继续"
  echo "   （宁可不动手，也不在半截数据上做不可逆操作）"
  exit 1
fi

# ---- 归档（带时间戳 + MANIFEST，拿到的包能自证完整）----
ts=$(date -u +%Y%m%d-%H%M%S)
{
  echo "created_utc: ${ts}"
  echo "source: ${STATE_DIR}"
  echo "listed_files: ${remote_files}"
  echo "archived_files: ${local_n}"
  echo "reason: marker 串写修复（2852b30）后的历史数据清洗"
  echo "note: 本包是清空 sync_state **之前**的完整快照，用于回滚与事后核查"
} > "$TMP/sync_state/MANIFEST.txt"

arc="$TMP/sync_state_reset_${ts}.tar.gz"
if ! tar -czf "$arc" -C "$TMP" sync_state 2>/dev/null; then
  echo "❌ 打包失败 ⇒ 拒绝清空"
  exit 1
fi
echo "  归档包: $(basename "$arc") ($(wc -c < "$arc" | tr -d ' ') 字节)"

rclone mkdir "$ARCHIVE_REMOTE" >/dev/null 2>&1 || true
if [ "$COMMIT" = "1" ]; then
  if rclone copyto "$arc" "${ARCHIVE_REMOTE}/sync_state_reset_${ts}.tar.gz" \
       --retries 3 --low-level-retries 5 --timeout 15m >/dev/null 2>&1; then
    echo "✅ 归档已上传: ${ARCHIVE_REMOTE}/sync_state_reset_${ts}.tar.gz"
  else
    echo "❌ 归档上传失败 ⇒ **拒绝清空**（没有退路就不许动手）"
    exit 1
  fi
else
  echo "  [dry-run] 将上传归档到 ${ARCHIVE_REMOTE}/sync_state_reset_${ts}.tar.gz"
fi

# ---- 清空（只删文件，保留目录本身）----
if [ "$COMMIT" = "1" ]; then
  echo ""
  echo "  正在清空 ${STATE_DIR} ..."
  rclone delete "$STATE_DIR" --files-only --retries 3 --low-level-retries 5 --timeout 15m 2>&1 | tail -3
  left=$(rclone lsf "$STATE_DIR" --files-only --retries 2 2>/dev/null | grep -c . || true)
  [[ "$left" =~ ^[0-9]+$ ]] || left=0
  if [ "$left" -eq 0 ]; then
    echo "✅ 已清空（剩余 ${left} 个）"
    echo ""
    echo "ℹ️ 后续: 用含串写修复的代码（≥2852b30）跑一轮同步，marker 会重新生成。"
    echo "   重新生成前，目标端短哈希目录里的文件仍在，只是暂时失去索引 —— 不要跑一键还原。"
  else
    echo "⚠️ 清空后仍剩 ${left} 个文件（可能有个别删除失败）⇒ 请人工核对"
    exit 1
  fi
else
  echo ""
  echo "  [dry-run] 未做任何删除。确认无误后加 --commit 执行。"
fi
