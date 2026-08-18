#!/bin/bash
# Pornhub 收藏视频去重脚本
#
# 按 ph ID 分组检测重复视频，并按以下规则处理：
#   规则1 (标题相同)：同 ID 同标题 → 删除文件小/旧的，保留最大/最新
#   规则2 (标题不同 + 哈希一致)：删除旧文件，保留最新
#   规则3 (标题不同 + 哈希各不相同)：仅通知，不删除
#   仅按 ID 去重模式：跳过标题/哈希校验，直接保留最大/最新并删除其余
#
# 用法: dedupe_ph_videos.sh
# 环境变量:
#   SOURCE_REMOTE        - rclone 远程路径（如 onedrive:0/j-1024j-视频-pornhub-favorites）
#   AUTO_DELETE          - "true" 时执行实际删除，否则仅标记"待删除"
#   DEDUPE_BY_ID_ONLY    - "true" 时仅按 ID 去重，跳过标题/哈希校验
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, GITHUB_WORKSPACE,
#   GITHUB_REPOSITORY, GITHUB_RUN_ID（用于发送 Telegram 通知）

set +e

# 从 SOURCE_REMOTE 提取目录名作为通知中的目录标识（如 onedrive:0/j-1024j-视频-pornhub-favorites → j-1024j-视频-pornhub-favorites）
DIR_LABEL=$(basename "${SOURCE_REMOTE#*:}")

# rclone lsf 列出文件（time;size;path），path 放最后，文件名含 ; 时最后一个字段获取剩余全部，安全
# -R 递归子目录，path 包含子目录前缀
rclone lsf "$SOURCE_REMOTE/" --files-only --format "tsp" -R 2>/dev/null \
  | grep -iE '\.mp4$' > /tmp/videos_tsp.txt || true
TOTAL=$(wc -l < /tmp/videos_tsp.txt)
echo "📊 数据采集: $TOTAL 个 mp4 文件"
if [ "$TOTAL" -eq 0 ]; then
  echo "未在 $SOURCE_REMOTE 中找到 mp4 文件"
  exit 0
fi

# 按 ID 分组，entry 格式: time;size;path（path 在最后，含 ; 安全）
declare -A ID_ENTRIES
while IFS=';' read -r time size path; do
  [ -z "$path" ] && continue
  id=$(echo "$path" | grep -oE 'ph[a-f0-9]+' | tail -n1)
  [ -n "$id" ] || continue
  entry="${time};${size};${path}"
  if [ -n "${ID_ENTRIES[$id]}" ]; then
    ID_ENTRIES[$id]+=$'\n'"${entry}"
  else
    ID_ENTRIES[$id]="${entry}"
  fi
done < /tmp/videos_tsp.txt

# 计算规范化标题：去扩展名 + 去掉所有位置的 ph ID + 方括号 + 压缩分隔符并 trim + NFC 归一化
# NFC 归一化解决 OneDrive/macOS(NFD) 与其他系统(NFC) 对同一字符（如 й）编码不同导致的误判
get_title() {
  local p="$1"
  local base="${p%.*}"
  echo "$base" \
    | sed -E 's/ph[a-f0-9]{6,}//g' \
    | sed -E 's/[][]//g' \
    | sed -E 's/[-_ ]+/ /g' \
    | sed -E 's/^ //; s/ $//' \
    | python3 -c "import sys,unicodedata; print(unicodedata.normalize('NFC', sys.stdin.read().rstrip('\n')))"
}

# 预统计重复 ID 组数量（出现 >1 次的 ID）
DUP_TOTAL=0
for i in "${!ID_ENTRIES[@]}"; do
  c=$(echo "${ID_ENTRIES[$i]}" | wc -l)
  [ "$c" -gt 1 ] && DUP_TOTAL=$((DUP_TOTAL + 1))
done
echo "🔍 发现 $DUP_TOTAL 个重复 ID 组，开始处理..."

DUP_DETAILS=""
DUP_COUNT=0
REMOVED_COUNT=0
NOTIFY_ONLY_COUNT=0
IDX=0
for id in "${!ID_ENTRIES[@]}"; do
  entries="${ID_ENTRIES[$id]}"
  count=$(echo "$entries" | wc -l)
  if [ "$count" -le 1 ]; then
    continue
  fi
  IDX=$((IDX + 1))
  DUP_COUNT=$((DUP_COUNT + 1))
  echo "[$IDX/$DUP_TOTAL] 处理 ID $id（$count 个文件）"

  # 仅按 ID 去重模式：跳过标题/哈希校验，直接保留最大/最新文件并自动删除其余
  if [ "$DEDUPE_BY_ID_ONLY" = "true" ]; then
    sorted=$(echo "$entries" | sort -t';' -k2,2n -k1,1)
    kept_path=$(echo "$sorted" | tail -n1 | cut -d';' -f3-)
    group_details=""
    while IFS=';' read -r t s p; do
      [ "$p" = "$kept_path" ] && continue
      [ -z "$p" ] && continue
      if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
        group_details+=$'  🗑 删除 '"${p}"$'（'"${s}"$' 字节，'"${t}"$'）\n'
      else
        group_details+=$'  ❌ 删除失败 '"${p}"$'\n'
        echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
      fi
    done <<< "$sorted"
    DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] ID ${id}"$'（'"${count}"$' 个，仅按 ID 去重，保留: '"${kept_path}"$'）\n'"${group_details}"
    continue
  fi

  # 判断所有文件的 title 是否完全相同
  title_count=$(while IFS=';' read -r t s p; do
    [ -z "$p" ] && continue
    get_title "$p"
  done <<< "$entries" | sort -u | wc -l)

  if [ "$title_count" -eq 1 ]; then
    # 规则1：ID 和 title 都相同 → 优先删除文件小的，其次删除修改时间旧的
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
    DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] ID ${id}"$'（'"${count}"$' 个，标题相同，保留: '"${kept_path}"$'）\n'"${group_details}"
  else
    # 规则2：title 不同 → 对比哈希
    # 打印各文件规范化 title，便于排查为何被判不同（如不可见字符）
    echo "  ⚠ 标题不同，需哈希确认："
    while IFS=';' read -r t s p; do
      [ -z "$p" ] && continue
      printf '    title=[%s] file=%s\n' "$(get_title "$p")" "$p"
    done <<< "$entries"
    # 计算每个文件哈希，写入: hash;time;size;path
    HASH_LIST="/tmp/hash_list_${id}.txt"
    > "$HASH_LIST"
    HCOUNT=0
    while IFS=';' read -r t s p; do
      [ -z "$p" ] && continue
      HCOUNT=$((HCOUNT + 1))
      echo "  计算哈希 [$HCOUNT/$count]: $p"
      hash=$(rclone hashsum sha1 "$SOURCE_REMOTE/$p" 2>/dev/null | awk '{print $1}')
      echo "${hash};${t};${s};${p}" >> "$HASH_LIST"
    done <<< "$entries"
    # 找出重复哈希（出现 >1 次的哈希）
    DUP_HASHES=$(awk -F';' '{print $1}' "$HASH_LIST" | sort | uniq -d)
    group_details=""
    if [ -n "$DUP_HASHES" ]; then
      # 哈希一致的组：每组删除修改时间旧的，保留最新
      while IFS= read -r hash; do
        [ -z "$hash" ] && continue
        hsorted=$(grep "^${hash};" "$HASH_LIST" | sort -t';' -k2)
        hkept_path=$(echo "$hsorted" | tail -n1 | cut -d';' -f4-)
        while IFS=';' read -r h t s p; do
          [ "$p" = "$hkept_path" ] && continue
          [ -z "$p" ] && continue
          if [ "$AUTO_DELETE" = "true" ]; then
            if rclone deletefile "$SOURCE_REMOTE/$p" 2>/tmp/rclone_err.log; then
              REMOVED_COUNT=$((REMOVED_COUNT + 1))
              group_details+=$'  🗑 删除 '"${p}"$'（哈希一致 '"${hash:0:12}"$'，旧文件）\n'
            else
              group_details+=$'  ❌ 删除失败 '"${p}"$'\n'
              echo "  ❌ 删除失败: $(tail -n 3 /tmp/rclone_err.log)"
            fi
          else
            group_details+=$'  ⚠ 待删除（已跳过） '"${p}"$'（哈希一致 '"${hash:0:12}"$'，旧文件）\n'
          fi
        done <<< "$hsorted"
      done <<< "$DUP_HASHES"
      DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] ID ${id}"$'（'"${count}"$' 个，标题不同，删除哈希一致的旧文件）\n'"${group_details}"
    else
      # 所有哈希各不相同 → 仅通知不删除
      NOTIFY_ONLY_COUNT=$((NOTIFY_ONLY_COUNT + 1))
      while IFS=';' read -r h t s p; do
        group_details+=$'  ⚠ 保留 '"${p}"$'（哈希 '"${h:0:12}"$'）\n'
      done < "$HASH_LIST"
      DUP_DETAILS+=$'\n'"🔖 [${IDX}/${DUP_TOTAL}] ID ${id}"$'（'"${count}"$' 个，标题不同且哈希各不相同，仅通知）\n'"${group_details}"
    fi
    rm -f "$HASH_LIST"
  fi
done

# 去重日志输出到 Actions 日志，便于追溯
echo "=== ph-dl 去重日志 ==="
echo "重复 ID 数量: ${DUP_COUNT}"
echo "删除重复文件数量: ${REMOVED_COUNT}"
echo "仅通知未删除数量: ${NOTIFY_ONLY_COUNT}"
echo "--- 详情 ---"
echo "${DUP_DETAILS}"

# 发送通知（按 4000 字符分片，避免超过 Telegram 4096 字符限制）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

if [ "$DUP_COUNT" -gt 0 ]; then
  HEADER="🔍 ph-dl 重复视频检测与去重"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n'"📁 目录: ${DIR_LABEL}"$'\n'
  HEADER+=$'\n'"📊 统计"$'\n'"• 重复 ID: ${DUP_COUNT}"$'\n'"• 已删除: ${REMOVED_COUNT}"$'\n'"• 仅通知: ${NOTIFY_ONLY_COUNT}"
  if [ "$DEDUPE_BY_ID_ONLY" = "true" ]; then
    HEADER+=$'\n'$'\n'"⚙️ 模式: 仅按 ID 自动删除（跳过标题/哈希校验）"
  elif [ "$AUTO_DELETE" = "true" ]; then
    HEADER+=$'\n'$'\n'"⚙️ 模式: 自动删除已开启"
  else
    HEADER+=$'\n'$'\n'"⚙️ 模式: 仅通知（手动触发可开启 auto_delete_duplicates）"
  fi
  if [ "$REMOVED_COUNT" -eq 0 ] && [ "$NOTIFY_ONLY_COUNT" -gt 0 ]; then
    HEADER+=$'\n'"ℹ 标题不同且哈希各不相同，未自动删除"
  fi
  send_tg "$HEADER"
  if [ -n "$DUP_DETAILS" ]; then
    send_tg_chunked "📋 详情"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n\n'"${DUP_DETAILS}"
  fi
  send_tg "🔗 任务链接: https://github.com/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
else
  echo "未发现重复视频 ID"
fi
