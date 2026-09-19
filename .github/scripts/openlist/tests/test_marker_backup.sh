#!/bin/bash
# marker 打包备份到 Dropbox —— 行为验证（mock rclone，真 tar）
#
# 为什么测这个（2026-09-19）: 短哈希不可逆 ⇒ marker 是还原链路**唯一**索引，
#   丢了就自愈不回来（详见计划文档 §13）。备份函数一旦"静默备份了空包"，
#   平时全绿、真丢数据时才发现备份也是空的 —— 这种失败**必须是红的**。
# 本测试锁的是"判据与副作用"，不联网:
#   1. 正常路径: 产出带时间戳归档 + latest 副本 + MANIFEST
#   2. ⚠️ 核心防护: 源端列表为空 → **拒绝上传**（绝不拿空包覆盖好备份）
#   3. ⚠️ 核心防护: 列表非空但下载为 0（读取异常）→ 拒绝上传
#   4. 只增不删: 存量历史归档**不得**被本函数删掉（与 sync 镜像的本质区别）
#   5. 保留期: 超出 keep 时只删**本函数命名的**最旧 N 份，其余原样保留
#   6. 隔离性: 目标远端里的其他文件（非本函数命名）永不删
#
# 用法: bash test_marker_backup.sh
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/sync_marker.sh"

WORK="$(mktemp -d /tmp/marker_backup_XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# 源端（模拟 onedrive:/logs/sync_state）与目标端（模拟 dropbox 备份目录）
SRC="$WORK/src"; DST="$WORK/dst"
mkdir -p "$SRC" "$DST"
# 覆盖生产默认值: sync_marker.sh 顶层把源端钉成 onedrive:/logs/sync_state，
# 这里改指本地沙箱（必须在 SRC 赋值之后）
SYNC_STATE_DIR="$SRC"

# 上传计数与"源端可读文件数"开关
UPLOADS=""       # 每次 copyto 的目标路径，一行一个
DELETED=""       # 每次 deletefile 的目标路径
SRC_LIST_N=0     # rclone lsf $SRC 返回的文件数
SRC_COPY_OK=1    # rclone copy 是否真的把文件拷出来

# rclone 桩: 全部落到本地目录。lsf 对源端按 SRC_LIST_N 返回模拟列表（模拟"远端能读到
# 几个文件"），对目标端列真实文件（模拟 Dropbox 备份目录）。
# copyto/deletefile 计数到 UPLOADS/DELETED，供"零上传/只删该删的"断言使用。
rclone() {
  case "$1" in
    lsf)
      case "$2" in
        *"/src"*)
          local i=1
          while [ "$i" -le "$SRC_LIST_N" ]; do echo "marker_${i}.json"; i=$((i+1)); done
          ;;
        *) (cd "$DST" 2>/dev/null && ls 2>/dev/null) ;;
      esac
      ;;
    copy)
      # copy <src> <dst_dir>: rclone 会自建目标目录，桩里也要 mkdir -p，
      # 否则 cp 到不存在的目录 → 0 个文件 → 被函数判成"读取异常"
      if [ "$SRC_COPY_OK" = "1" ]; then
        mkdir -p "$3"
        local f
        for f in "$SRC"/*; do [ -f "$f" ] && cp "$f" "$3/"; done
      fi
      ;;
    copyto)
      cp "$2" "$3" 2>/dev/null || return 1
      UPLOADS+="$(basename "$3")"$'\n'
      ;;
    deletefile)
      rm -f "$DST/$(basename "$2")" 2>/dev/null
      DELETED+="$(basename "$2")"$'\n'
      ;;
    mkdir) mkdir -p "$2" ;;
    *) return 0 ;;
  esac
  return 0
}

# 造两个有内容的 marker 文件
printf '{"original":"a/b.mp4","alternative":"deadbeef/b.mp4"}' > "$SRC/task0_11111111.json"
printf '{"original":"c/d.mkv","alternative":"cafebabe/d.mkv"}' > "$SRC/task1_22222222.json"

echo "=== 场景1: 正常路径 ==="
SRC_LIST_N=2; SRC_COPY_OK=1
if backup_sync_state_to_dropbox "$DST"; then
  ok "1a 正常路径返回 0"
else
  bad "1a 正常路径返回 0"
fi
DATED=$(cd "$DST" 2>/dev/null && ls | grep -E '^sync_state_[0-9]{8}-[0-9]{6}\.tar\.gz$' | head -1)
[ -n "$DATED" ] && ok "1b 产出带时间戳归档（${DATED}）" || bad "1b 产出带时间戳归档"
[ -f "$DST/sync_state_latest.tar.gz" ] && ok "1c 产出 latest 副本" || bad "1c 产出 latest 副本"
# 归档内容必须真含 marker（不是空包）
if [ -n "$DATED" ]; then
  LIST=$(tar -tzf "$DST/$DATED" 2>/dev/null)
  printf '%s' "$LIST" | grep -q "task0_11111111.json" \
    && ok "1d 归档内含真实 marker 文件" || bad "1d 归档内含真实 marker 文件"
  printf '%s' "$LIST" | grep -q "MANIFEST.txt" \
    && ok "1e 归档内含 MANIFEST.txt（可自证完整）" || bad "1e 归档内含 MANIFEST.txt"
fi

echo "=== 场景2: 源端列表为空 → 必须拒绝上传 ==="
rm -rf "$DST"; mkdir -p "$DST"
UPLOADS=""
SRC_LIST_N=0; SRC_COPY_OK=1
if backup_sync_state_to_dropbox "$DST"; then
  bad "2a 列表为空应返回 1（实际 0）"
else
  ok "2a 列表为空返回 1"
fi
[ -z "$UPLOADS" ] && ok "2b 列表为空时零上传（不覆盖已有备份）" || bad "2b 列表为空时零上传"
[ -z "$(cd "$DST" && ls)" ] && ok "2c 目标端未被写入任何文件" || bad "2c 目标端未被写入任何文件"

echo "=== 场景3: 列表非空但下载为 0 → 必须拒绝上传 ==="
UPLOADS=""
SRC_LIST_N=2; SRC_COPY_OK=0
if backup_sync_state_to_dropbox "$DST"; then
  bad "3a 读取异常应返回 1（实际 0）"
else
  ok "3a 读取异常返回 1"
fi
[ -z "$UPLOADS" ] && ok "3b 读取异常时零上传" || bad "3b 读取异常时零上传"

echo "=== 场景4: 只增不删 —— 存量历史归档不得被删 ==="
SRC_LIST_N=2; SRC_COPY_OK=1
rm -rf "$DST"; mkdir -p "$DST"
# 预置一份"上一轮"的归档，模拟保留期内的历史
printf 'OLD' > "$DST/sync_state_20260101-000000.tar.gz"
UPLOADS=""; DELETED=""
MARKER_BACKUP_KEEP=30 backup_sync_state_to_dropbox "$DST" >/dev/null 2>&1
[ -f "$DST/sync_state_20260101-000000.tar.gz" ] \
  && ok "4a 存量历史归档未被删除（与 sync 镜像的本质区别）" \
  || bad "4a 存量历史归档未被删除"
[ -z "$DELETED" ] && ok "4b 保留期内零删除" || bad "4b 保留期内零删除（实际删了 $(printf '%s' "$DELETED" | grep -c .) 个）"

echo "=== 场景5: 保留期 —— 只删本函数命名的最旧 N 份 ==="
rm -rf "$DST"; mkdir -p "$DST"
for i in 01 02 03 04 05; do printf "OLD$i" > "$DST/sync_state_202601${i}-000000.tar.gz"; done
UPLOADS=""; DELETED=""
# keep=2: 预置 5 份 + 本轮新增 1 份 = 6 份 ⇒ 应删掉最旧的 4 份
MARKER_BACKUP_KEEP=2 backup_sync_state_to_dropbox "$DST" >/dev/null 2>&1
PRUNED=$(printf '%s' "$DELETED" | grep -c . || true)
[ "$PRUNED" = "4" ] && ok "5a 超出保留期删 4 份（6-2）" || bad "5a 超出保留期删 4 份（实际 ${PRUNED}）"
# 最旧的两份应已消失，较新的三份应保留
[ ! -f "$DST/sync_state_20260101-000000.tar.gz" ] && ok "5b 最旧归档已被清理" || bad "5b 最旧归档已被清理"
[ -f "$DST/sync_state_20260105-000000.tar.gz" ] && ok "5c 较新归档被保留" || bad "5c 较新归档被保留"
[ -f "$DST/sync_state_latest.tar.gz" ] && ok "5d latest 始终是最新那份" || bad "5d latest 始终是最新那份"

echo "=== 场景6: 隔离性 —— 目标端其他文件永不删 ==="
rm -rf "$DST"; mkdir -p "$DST"
printf 'KEEPME' > "$DST/important_not_ours.txt"
printf 'KEEPME2' > "$DST/some_other_backup.tar.gz"
DELETED=""
MARKER_BACKUP_KEEP=1 backup_sync_state_to_dropbox "$DST" >/dev/null 2>&1
[ -f "$DST/important_not_ours.txt" ] && ok "6a 非归档文件未被删" || bad "6a 非归档文件未被删"
[ -f "$DST/some_other_backup.tar.gz" ] && ok "6b 他人 .tar.gz 未被误删（命名正则锁定生效）" || bad "6b 他人 .tar.gz 未被误删"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
