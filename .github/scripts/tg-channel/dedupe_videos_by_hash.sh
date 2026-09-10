#!/bin/bash
# 视频按哈希去重脚本（适用于无统一 ID 的视频集合，如 91-tg 工作流）
#
# 按服务端哈希分组检测重复视频，并按以下规则处理：
#   规则1（文件名相同）：同哈希同文件名 → 删除文件小/旧的，保留最大/最新
#   规则2（文件名不同）：同哈希不同文件名 → 删除旧文件，保留最新
#
# 哈希来源：rclone hashsum（OneDrive 服务端哈希，不下载文件）
#   自动按优先级尝试 SHA1 → SHA256 → MD5 → QuickXorHash，
#   个人版 OneDrive 仅支持 QuickXorHash，企业版/SharePoint 支持 SHA1/SHA256
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

# 排版助手提前加载：明细条目构建时即做 escape_html（文件名含 & < > 未转义会
# 触发 400、整条通知发送失败（不重发））；后文发送处的重复 source 为幂等。
# 加载失败必须显式暴露（勿 2>/dev/null || true 吞掉）：助手缺失时后续
# escape_html/tree_lines 全部 command-not-found，通知会静默缺损
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

# ===== 通知明细折叠（规范 §4: 超长列表禁全量穷举）=====
# 组内条目上限 8 条（_grp_add 超出转计数），通知中最多展示 8 组（_grp_block 超出折叠）
GRP_SHOWN=0 GRP_HIDDEN=0
GRP_BLOCK_SHOWN=0 GRP_BLOCK_HIDDEN=0
_grp_reset() { GRP_SHOWN=0 GRP_HIDDEN=0; }
_grp_add() {
  if [ "$GRP_SHOWN" -ge 8 ]; then
    GRP_HIDDEN=$((GRP_HIDDEN + 1))
    return 0
  fi
  GRP_SHOWN=$((GRP_SHOWN + 1))
  printf -v "$1" '%s%s' "${!1}" "$2"
}
_grp_fold() {
  [ "$GRP_HIDDEN" -gt 0 ] && printf '%s' "还有 ${GRP_HIDDEN} 条…"$'\n'
  return 0
}
_grp_block() {
  if [ "$GRP_BLOCK_SHOWN" -ge 8 ]; then
    GRP_BLOCK_HIDDEN=$((GRP_BLOCK_HIDDEN + 1))
    return 0
  fi
  GRP_BLOCK_SHOWN=$((GRP_BLOCK_SHOWN + 1))
  DUP_DETAILS+=$'\n'"$1"
}

# 一次性获取所有文件的服务端哈希（不下载文件，不修改元数据）
# OneDrive 个人版仅支持 QuickXorHash，企业版/SharePoint 支持 SHA1/SHA256
# 按优先级尝试：SHA1 → SHA256 → MD5 → QuickXorHash，使用第一个返回结果的哈希类型
# 用 python 解析 rclone hashsum 输出（hash 和 path 之间是空白分隔），生成 hash;path 格式
# 注意：rclone hashsum 递归子目录是默认行为，不支持 -R 标志（与 lsf/ls 不同）
HASH_TYPE=""
for h in sha1 sha256 md5 QuickXorHash; do
  # 同时捕获 stdout 到解析管道、stderr 到错误日志文件
  if rclone hashsum "$h" "$SOURCE_REMOTE/" 2>/tmp/rclone_hash_err.log \
    | python3 -c "import sys;[print(f'{p[0]};{p[1]}') for line in sys.stdin if len(p:=line.strip().split(None,1))==2]" \
    > /tmp/91_hashes.txt; then
    if [ -s /tmp/91_hashes.txt ]; then
      HASH_TYPE="$h"
      break
    fi
  fi
done

# 获取文件列表（time;size;path），path 放最后，文件名含 ; 时最后一个字段获取剩余全部，安全
# -R 递归子目录，path 包含子目录前缀
rclone lsf "$SOURCE_REMOTE/" --files-only --format "tsp" -R 2>/dev/null \
  | grep -iE '\.mp4$' > /tmp/91_videos_tsp.txt || true

TOTAL=$(wc -l < /tmp/91_videos_tsp.txt)
HASH_COUNT=$(wc -l < /tmp/91_hashes.txt)
echo "📊 数据采集: $TOTAL 个 mp4 文件, $HASH_COUNT 个哈希${HASH_TYPE:+（哈希类型: $HASH_TYPE）}"
if [ "$TOTAL" -eq 0 ]; then
  echo "未在 $SOURCE_REMOTE 中找到 mp4 文件"
  exit 0
fi
if [ "$HASH_COUNT" -eq 0 ]; then
  echo "⚠️ 哈希采集失败（已尝试 sha1/sha256/md5/QuickXorHash 均返回空），跳过去重"
  echo "  最后一次 rclone 错误（如有）:"
  tail -n 5 /tmp/rclone_hash_err.log 2>/dev/null | sed 's/^/    /' || echo "    无错误输出"
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
    group_entries=""
    _grp_reset
    while IFS=';' read -r t s p; do
      [ "$p" = "$kept_path" ] && continue
      [ -z "$p" ] && continue
      if [ "$AUTO_DELETE" = "true" ]; then
        if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
          REMOVED_COUNT=$((REMOVED_COUNT + 1))
          _grp_add group_entries "🗑 删除 <code>$(escape_html "${p}")</code> · ${s} 字节 · ${t}"$'\n'
        else
          _grp_add group_entries "❌ 删除失败 <code>$(escape_html "${p}")</code>"$'\n'
          echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
        fi
      else
        _grp_add group_entries "⚠️ 待删除 · 已跳过 <code>$(escape_html "${p}")</code> · ${s} 字节 · ${t}"$'\n'
      fi
    done <<< "$sorted"
    _fold=$(_grp_fold)
    _grp_block "🔖 哈希 ${hash:0:12} · 第 ${IDX}/${DUP_TOTAL} 组 · ${count} 个 · 文件名相同 · 保留 <code>$(escape_html "${kept_path}")</code>"$'\n'"$(tree_lines "${group_entries}${_fold}")"
  else
    # 规则2：文件名不同但内容相同 → 删除修改时间旧的，保留最新
    sorted=$(echo "$entries" | sort -t';' -k1,1)
    kept_path=$(echo "$sorted" | tail -n1 | cut -d';' -f3-)
    group_entries=""
    _grp_reset
    while IFS=';' read -r t s p; do
      [ "$p" = "$kept_path" ] && continue
      [ -z "$p" ] && continue
      if [ "$AUTO_DELETE" = "true" ]; then
        if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
          REMOVED_COUNT=$((REMOVED_COUNT + 1))
          _grp_add group_entries "🗑 删除 <code>$(escape_html "${p}")</code> · 哈希一致 · 旧文件"$'\n'
        else
          _grp_add group_entries "❌ 删除失败 <code>$(escape_html "${p}")</code>"$'\n'
          echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
        fi
      else
        _grp_add group_entries "⚠️ 待删除 · 已跳过 <code>$(escape_html "${p}")</code> · 哈希一致 · 旧文件"$'\n'
      fi
    done <<< "$sorted"
    _fold=$(_grp_fold)
    _grp_block "🔖 哈希 ${hash:0:12} · 第 ${IDX}/${DUP_TOTAL} 组 · ${count} 个 · 文件名不同 · 保留 <code>$(escape_html "${kept_path}")</code>"$'\n'"$(tree_lines "${group_entries}${_fold}")"
  fi
done

# 组级折叠行（通知最多展示 8 组，超出并入条目流；逐组处理过程已在 Actions 日志回显）
if [ "$GRP_BLOCK_HIDDEN" -gt 0 ]; then
  DUP_DETAILS+=$'\n'"还有 ${GRP_BLOCK_HIDDEN} 组未展开 · 明细见运行日志"$'\n'
fi

# 去重日志输出到 Actions 日志，便于追溯
echo "=== ${WORKFLOW_LABEL} 去重日志 ==="
echo "重复哈希数量: ${DUP_COUNT}"
echo "删除重复文件数量: ${REMOVED_COUNT}"
echo "--- 详情 ---"
printf '%s\n' "${DUP_DETAILS}" | sed -E 's/<[^>]*>//g'

# 发送通知（按 4000 字符分片，避免超过 Telegram 4096 字符限制）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

if [ "$DUP_COUNT" -gt 0 ]; then
  msg=""
  tg_add_title msg "🔍 ${WORKFLOW_LABEL} 重复视频检测与去重"
  tg_add_path msg "目录" "$DIR_LABEL"
  tg_add_kv msg "重复哈希" "${DUP_COUNT}"
  tg_add_kv msg "已删除" "${REMOVED_COUNT}"
  if [ "$AUTO_DELETE" = "true" ]; then
    tg_add_kv msg "模式" "自动删除已开启"
  else
    tg_add_kv msg "模式" "仅通知 · 手动触发可开启 auto_delete_duplicates"
  fi
  if [ -n "$DUP_DETAILS" ]; then
    tg_add_section msg "📋 详情 · ${DUP_COUNT}"
    tg_add_block msg "$DUP_DETAILS"
  fi
  tg_add_footer msg
  send_tg_chunked "$msg"
else
  echo "未发现重复视频"
fi
