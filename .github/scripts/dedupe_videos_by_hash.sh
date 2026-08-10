#!/bin/bash
# 视频按哈希去重脚本（适用于无统一 ID 的视频集合，如 91-tg 工作流）
#
# 按 SHA1 哈希分组检测重复视频，并按以下规则处理：
#   规则1（文件名相同）：同哈希同文件名 → 删除文件小/旧的，保留最大/最新
#   规则2（文件名不同）：同哈希不同文件名 → 删除旧文件，保留最新
#
# 哈希来源：rclone hashsum sha1（OneDrive 服务端哈希，不下载文件）
#
# 用法: dedupe_videos_by_hash.sh
# 环境变量:
#   SOURCE_REMOTE        - rclone 远程路径（如 onedrive:1/1024j/视频/91）
#   AUTO_DELETE          - "true" 时执行实际删除，否则仅标记"待删除"
#   WORKFLOW_LABEL       - 通知中显示的工作流名称（默认: 91-tg）
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE,
#   GITHUB_REPOSITORY, GITHUB_RUN_ID（用于发送 Telegram 通知）

set +e

WORKFLOW_LABEL="${WORKFLOW_LABEL:-91-tg}"
# 从 SOURCE_REMOTE 提取目录名作为通知中的目录标识（如 onedrive:1/1024j/视频/91 → 91）
DIR_LABEL=$(basename "${SOURCE_REMOTE#*:}")

# 一次性获取所有文件的 SHA1（OneDrive 服务端哈希，不下载文件，不修改元数据）
# 用 python 解析 rclone hashsum 输出（hash 和 path 之间是空白分隔），生成 hash;path 格式
# -R 递归子目录，path 包含子目录前缀
rclone hashsum sha1 "$SOURCE_REMOTE/" -R 2>/dev/null \
  | python3 -c "import sys;[print(f'{p[0]};{p[1]}') for line in sys.stdin if len(p:=line.strip().split(None,1))==2]" \
  > /tmp/91_hashes.txt || true

# 获取文件列表（time;size;path），path 放最后，文件名含 ; 时最后一个字段获取剩余全部，安全
# -R 递归子目录，path 包含子目录前缀
rclone lsf "$SOURCE_REMOTE/" --files-only --format "tsp" -R 2>/dev/null \
  | grep -iE '\.mp4$' > /tmp/91_videos_tsp.txt || true

TOTAL=$(wc -l < /tmp/91_videos_tsp.txt)
HASH_COUNT=$(wc -l < /tmp/91_hashes.txt)
echo "📊 数据采集: $TOTAL 个 mp4 文件, $HASH_COUNT 个哈希"
if [ "$TOTAL" -eq 0 ]; then
  echo "未在 $SOURCE_REMOTE 中找到 mp4 文件"
  exit 0
fi
if [ "$HASH_COUNT" -eq 0 ]; then
  echo "⚠️ 哈希采集失败（rclone hashsum 返回空），跳过去重"
  exit 0
fi

# 构建 path → time;size 映射
declare -A PATH_META
while IFS=';' read -r time size path; do
  [ -z "$path" ] && continue
  PATH_META["$path"]="${time};${size}"
done < /tmp/91_videos_tsp.txt

# 按哈希分组: hash → entries(time;size;path)
declare -A HASH_ENTRIES
while IFS=';' read -r hash path; do
  [ -z "$path" ] && continue
  echo "$path" | grep -qiE '\.mp4$' || continue
  meta="${PATH_META[$path]:-}"
  [ -z "$meta" ] && continue
  IFS=';' read -r time size <<< "$meta"
  entry="${time};${size};${path}"
  if [ -n "${HASH_ENTRIES[$hash]}" ]; then
    HASH_ENTRIES[$hash]+=$'\n'"${entry}"
  else
    HASH_ENTRIES[$hash]="${entry}"
  fi
done < /tmp/91_hashes.txt

# 预统计重复组数量（哈希出现 >1 次）
DUP_TOTAL=0
for h in "${!HASH_ENTRIES[@]}"; do
  c=$(echo "${HASH_ENTRIES[$h]}" | wc -l)
  [ "$c" -gt 1 ] && DUP_TOTAL=$((DUP_TOTAL + 1))
done
echo "🔍 发现 $DUP_TOTAL 个重复哈希组，开始处理..."

DUP_DETAILS=""
DUP_COUNT=0
REMOVED_COUNT=0
IDX=0
for hash in "${!HASH_ENTRIES[@]}"; do
  entries="${HASH_ENTRIES[$hash]}"
  count=$(echo "$entries" | wc -l)
  if [ "$count" -le 1 ]; then
    continue
  fi
  IDX=$((IDX + 1))
  DUP_COUNT=$((DUP_COUNT + 1))
  echo "[$IDX/$DUP_TOTAL] 处理哈希 ${hash:0:12}（$count 个文件）"

  # 判断文件名（不含扩展名）是否完全相同（NFC 归一化，避免 OneDrive/macOS NFD 编码差异误判）
  name_count=$(echo "$entries" | while IFS=';' read -r t s p; do
    [ -z "$p" ] && continue
    echo "${p%.*}"
  done | python3 -c "import sys,unicodedata; [print(unicodedata.normalize('NFC', l.rstrip('\n'))) for l in sys.stdin]" | sort -u | wc -l)

  if [ "$name_count" -eq 1 ]; then
    # 规则1：文件名相同（不含扩展名）→ 优先删除文件小的，其次删除修改时间旧的
    # 排序：size 升序（小的先删），size 相同则 time 旧者优先删；保留最后一个（最大/最新）
    sorted=$(echo "$entries" | sort -t';' -k2,2n -k1,1)
    kept_path=$(echo "$sorted" | tail -n1 | cut -d';' -f3-)
    group_details=""
    while IFS=';' read -r t s p; do
      [ "$p" = "$kept_path" ] && continue
      [ -z "$p" ] && continue
      if [ "$AUTO_DELETE" = "true" ]; then
        if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
          REMOVED_COUNT=$((REMOVED_COUNT + 1))
          group_details+=$'  🗑 删除 '"${p}"$'（'"${s}"$' 字节，'"${t}"$'）\n'
        else
          group_details+=$'  ❌ 删除失败 '"${p}"$'\n'
          echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
        fi
      else
        group_details+=$'  ⚠ 待删除（已跳过） '"${p}"$'（'"${s}"$' 字节，'"${t}"$'）\n'
      fi
    done <<< "$sorted"
    DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] 哈希 ${hash:0:12}"$'（'"${count}"$' 个，文件名相同，保留: '"${kept_path}"$'）\n'"${group_details}"
  else
    # 规则2：文件名不同但内容相同 → 删除修改时间旧的，保留最新
    sorted=$(echo "$entries" | sort -t';' -k1,1)
    kept_path=$(echo "$sorted" | tail -n1 | cut -d';' -f3-)
    group_details=""
    while IFS=';' read -r t s p; do
      [ "$p" = "$kept_path" ] && continue
      [ -z "$p" ] && continue
      if [ "$AUTO_DELETE" = "true" ]; then
        if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
          REMOVED_COUNT=$((REMOVED_COUNT + 1))
          group_details+=$'  🗑 删除 '"${p}"$'（哈希一致，旧文件）\n'
        else
          group_details+=$'  ❌ 删除失败 '"${p}"$'\n'
          echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
        fi
      else
        group_details+=$'  ⚠ 待删除（已跳过） '"${p}"$'（哈希一致，旧文件）\n'
      fi
    done <<< "$sorted"
    DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] 哈希 ${hash:0:12}"$'（'"${count}"$' 个，文件名不同，保留: '"${kept_path}"$'）\n'"${group_details}"
  fi
done

# 去重日志输出到 Actions 日志，便于追溯
echo "=== ${WORKFLOW_LABEL} 去重日志 ==="
echo "重复哈希数量: ${DUP_COUNT}"
echo "删除重复文件数量: ${REMOVED_COUNT}"
echo "--- 详情 ---"
echo "${DUP_DETAILS}"

# 发送通知（按 4000 字符分片，避免超过 Telegram 4096 字符限制）
source "${GITHUB_WORKSPACE}/.github/scripts/tg_notify.sh"

if [ "$DUP_COUNT" -gt 0 ]; then
  HEADER="🔍 ${WORKFLOW_LABEL} 重复视频检测与去重"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n'"📁 目录: ${DIR_LABEL}"$'\n'
  HEADER+=$'\n'"📊 统计"$'\n'"• 重复哈希: ${DUP_COUNT}"$'\n'"• 已删除: ${REMOVED_COUNT}"
  if [ "$AUTO_DELETE" = "true" ]; then
    HEADER+=$'\n'$'\n'"⚙️ 模式: 自动删除已开启"
  else
    HEADER+=$'\n'$'\n'"⚙️ 模式: 仅通知（手动触发可开启 auto_delete_duplicates）"
  fi
  send_tg "$HEADER"
  if [ -n "$DUP_DETAILS" ]; then
    send_tg_chunked "📋 详情"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n\n'"${DUP_DETAILS}"
  fi
  send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
  echo "未发现重复视频"
fi
