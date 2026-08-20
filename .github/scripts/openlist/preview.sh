#!/bin/bash
# ===== OpenList 同步工具 — 任务预览系统 =====
# 在实际同步前，发送预览通知展示:
#   - 每个同步对的源端大小、预估待同步量（按源端分组的树形列表）
#   - 合计预估待同步量
#
# 估算口径（与实际 sync 的 rclone --size-only 逐文件对齐）:
#   对源端/目标端各拉一次递归文件清单（rclone lsjson -R，两端同一
#   --exclude 口径），按文件路径比对:
#     新增 = 源端有、目标端无     → 需上传整个文件
#     更新 = 两端同名但大小不同   → --size-only 下必然整文件重传
#   预估待同步 = Σ(新增 + 更新文件的源端大小)。
#   已修复文件（marker fixed_files[].original，实际 sync 用 filter-from
#   排除 = 不传输不删除）从差异中精确剔除——只剔除真实出现在差异里的条目，
#   不再按总数盲减。
#   目标端清单获取失败时（OpenList 驱动懒加载/网盘限流等）: 快速失败先重试，
#   仍失败则按空目标端全量估算（同步口径上界），且必须在预览里明示 ⚠️——
#   历史缺陷: 失败只打 job 日志，预览静默把全量当精确值展示，目标端已有
#   大半文件时合计虚高数倍，用户无从辨别。
#   历史缺陷（总量差值法）: bytes 与 count 各自做总量减法再按总数盲减
#   fixed_files，同名更新文件（如每日轮转的 *_latest.tar.gz）只贡献字节差
#   不贡献文件数差，产生 "+6.7 GiB / +0 文件" 的矛盾展示，且盲减可能把
#   真实缺失文件从预估中吞掉。
#
# 依赖: utils.sh (format_bytes, _extract_filter_args, escape_html, tree_*)
# 依赖: telegram.sh (send_telegram_message, tg_add_title/tg_add_section/tg_append)

# 拉取远端递归文件清单（lsjson，仅文件，含 Path/Size）
# 用法: _get_listing_json <remote_path> [--exclude pat] ...
# 输出: lsjson JSON 数组（空目录为 []）; 失败/非数组输出空串
# 注意: 只传纯 filter 参数（--exclude/--include），调用方须先用
# _extract_filter_args 剥离 --delete-before 等 sync 特有参数
_get_listing_json() {
  local remote_path="$1"
  shift
  local -a filter_args=("$@")
  local listing
  if [ ${#filter_args[@]} -gt 0 ]; then
    listing=$(timeout 900 rclone lsjson "$remote_path" --recursive --files-only "${filter_args[@]}" 2>/dev/null || true)
  else
    listing=$(timeout 900 rclone lsjson "$remote_path" --recursive --files-only 2>/dev/null || true)
  fi
  if [ -n "$listing" ] && printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$listing"
  fi
}

# 源端文件清单缓存（按 source_path + 过滤参数组合做 key，
# 同源端多目标/进度注册复用，rclone lsjson 只拉一次）
# 注意: 缓存写入必须在主 shell 完成——本函数常在命令替换（子 shell）里
# 被调用，子 shell 里的数组赋值回不到父进程（历史实现因此从未真正命中，
# 每次统计都重新拉清单）。真正的落盘由 add_preview_pair 在主 shell 执行。
declare -A PREVIEW_SRC_LIST_CACHE

# 获取源端大小/文件数（带 --exclude 过滤，读 PREVIEW_SRC_LIST_CACHE 缓存）
# 用法: _get_source_size_with_excludes <source_path> [原始 extra_args...]
#   （可含 --delete-before 等非过滤参数，内部会剥离，仅保留过滤口径）
# 返回: "bytes count"
_get_source_size_with_excludes() {
  local source_path="$1"
  shift
  _extract_filter_args "$@"
  local cache_key="${source_path} ${FILTER_ARGS[*]}"
  local listing
  if [ -n "${PREVIEW_SRC_LIST_CACHE[$cache_key]:-}" ]; then
    listing="${PREVIEW_SRC_LIST_CACHE[$cache_key]}"
  else
    listing=$(_get_listing_json "$source_path" "${FILTER_ARGS[@]}")
    [ -z "$listing" ] && listing="[]"
    # 尽力写缓存（子 shell 场景写不回父进程，主流程由 add_preview_pair 落盘）
    PREVIEW_SRC_LIST_CACHE[$cache_key]="$listing"
  fi
  local out
  out=$(echo "$listing" | jq -r '"\((map(.Size // 0) | add // 0)) \(length)"' 2>/dev/null) || out=""
  [ -z "$out" ] && out="0 0"
  echo "$out"
}

# 开始一个主任务的预览
# 用法: start_task_preview <task_name>
start_task_preview() {
  local task_name="$1"
  PREVIEW_TASK_NAME="$task_name"
  PREVIEW_PAIR_COUNT=0
  PREVIEW_TOTAL_SYNC_BYTES=0
  PREVIEW_TOTAL_SYNC_COUNT=0
  PREVIEW_TOTAL_NEW_COUNT=0
  PREVIEW_TOTAL_UPD_COUNT=0
  PREVIEW_FAIL_PAIRS=0
  PREVIEW_PAIRS_TSV=""
  echo "=== 预览任务: ${task_name} ==="
}

# 添加一个同步对到预览
# 用法: add_preview_pair <source_path> <dest_path> [--exclude pat] ...
#   （与 tasks.sh 调用约定一致: extra_args 可能含 --delete-before 等
#   sync 特有参数，统计前先剥离为纯过滤口径）
add_preview_pair() {
  local source_path="$1"
  local dest_path="$2"
  shift 2
  local -a extra_args=("$@")

  PREVIEW_PAIR_COUNT=$((PREVIEW_PAIR_COUNT + 1))
  echo "  同步对 ${PREVIEW_PAIR_COUNT}: ${source_path} → ${dest_path}"

  # 源端清单 + 缓存（主 shell 内读写: 命令替换子 shell 里的数组赋值
  # 回不到父进程，缓存必须由本函数落盘，供 tasks.sh 进度注册等复用）
  _extract_filter_args "${extra_args[@]}"
  local _src_cache_key="${source_path} ${FILTER_ARGS[*]}"
  local src_json
  if [ -n "${PREVIEW_SRC_LIST_CACHE[$_src_cache_key]:-}" ]; then
    src_json="${PREVIEW_SRC_LIST_CACHE[$_src_cache_key]}"
  else
    src_json=$(_get_listing_json "$source_path" "${FILTER_ARGS[@]}")
    if [ -z "$src_json" ]; then
      echo "⚠️ add_preview_pair: 源端清单获取失败 (${source_path})" >&2
      src_json="[]"
    fi
    PREVIEW_SRC_LIST_CACHE[$_src_cache_key]="$src_json"
  fi

  # 源端大小/文件数（从同一份清单推导，避免再拉一次 rclone size）
  local src_bytes src_count
  src_bytes=$(echo "$src_json" | jq -r 'map(.Size // 0) | add // 0' 2>/dev/null) || src_bytes=0
  src_count=$(echo "$src_json" | jq -r 'length' 2>/dev/null) || src_count=0
  [[ "$src_bytes" =~ ^[0-9]+$ ]] || src_bytes=0
  [[ "$src_count" =~ ^[0-9]+$ ]] || src_count=0

  # 目标端清单（与源端同一 exclude 口径，避免被排除路径/历史残留混入比对）
  # 失败重试: OpenList 刚启动时驱动懒加载、网盘限流等瞬时错误常见（线上实测
  # baidupan/wopan175 目标端已有大半文件，却因列举失败被按空目标端全量估算，
  # 合计虚高近 3 倍）。快速失败（<300s，是错误而非超时）间隔 20s 重试至多 3 次;
  # 超时型失败重试大概率继续超时（最长 900s/次），不重试
  # 注意: 空目录 lsjson 返回 "[]"（非空串），不会误触发重试
  local dst_json="" _dst_try _dst_t0
  for _dst_try in 1 2 3; do
    _dst_t0=$SECONDS
    dst_json=$(_get_listing_json "$dest_path" "${FILTER_ARGS[@]}")
    [ -n "$dst_json" ] && break
    [ $((SECONDS - _dst_t0)) -ge 300 ] && break
    [ "$_dst_try" -lt 3 ] && sleep 20
  done
  local dst_fail=0
  if [ -z "$dst_json" ]; then
    dst_fail=1
    PREVIEW_FAIL_PAIRS=$((PREVIEW_FAIL_PAIRS + 1))
    echo "⚠️ add_preview_pair: 目标端清单获取失败 (${dest_path})，按目标端为空估算（全量待同步）" >&2
    # 抓一次真实错误进 job 日志（驱动未加载/限流/路径不存在），便于定位
    local _dst_err
    _dst_err=$(timeout 60 rclone lsjson "$dest_path" --max-depth 1 2>&1 >/dev/null | tail -n 2)
    [ -n "$_dst_err" ] && echo "   目标端列举错误: ${_dst_err}" >&2
    dst_json="[]"
  fi

  # 已修复文件（marker fixed_files: original 以替代名存在于目标端）
  # 实际 sync 用 filter-from 排除 original/alternative（不传输不删除），
  # 预览同口径剔除，保证预估与 sync 实际行为一致
  _load_marker_fixed_files "$source_path" "$dest_path" "${PREVIEW_TASK_NAME:-}"

  # 逐文件比对（--size-only 口径），输出 TSV:
  #   new_count new_bytes upd_count upd_bytes fixed_hit_count fixed_hit_bytes
  # fixed_hit_* = 差异中命中 marker original 的条目（被剔除的部分）
  # 三份清单必须经 stdin 喂给 jq（-s slurp 成数组后解构），禁止 --argjson 传参:
  #   内核单参数上限 MAX_ARG_STRLEN ≈ 128KB，真实任务清单（约 700+ 文件）必超，
  #   execve 直接 E2BIG "Argument list too long"，被 2>/dev/null 吞掉后
  #   diff_tsv 为空、差异恒为 0 —— 线上所有任务预览恒示 "0 B / 0 文件" 的元凶
  #   （源端大小另有管道计算不受影响，故预览里源端大小正常、待同步恒 0）
  local diff_tsv
  diff_tsv=$(printf '%s\n%s\n%s\n' "$src_json" "$dst_json" "${MARKER_FIXED_FILES:-[]}" | jq -sr '
    . as [$src, $dst, $fixed]
    | ($dst | map({key: .Path, value: (.Size // -1)}) | from_entries) as $dmap
    | (($fixed // []) | map(.original)) as $excl
    | [$src[]
        | select(($dmap[.Path] // -1) != .Size)
        | { size: (.Size // 0),
            kind: (if ($dmap[.Path] == null) then "new" else "upd" end),
            fixed: ((.Path as $p | $excl | index($p)) != null) }] as $diff
    | ($diff | map(select(.fixed))) as $fx
    | ($diff | map(select(.fixed | not))) as $need
    | ($need | map(select(.kind == "new"))) as $news
    | ($need | map(select(.kind == "upd"))) as $upds
    | [($news | length), ($news | map(.size) | add // 0),
      ($upds | length), ($upds | map(.size) | add // 0),
      ($fx   | length), ($fx   | map(.size) | add // 0)]
    | @tsv
  ' 2>/dev/null || echo "")

  local new_count=0 new_bytes=0 upd_count=0 upd_bytes=0 fixed_hit_count=0 fixed_hit_bytes=0
  if [ -n "$diff_tsv" ]; then
    IFS=$'\t' read -r new_count new_bytes upd_count upd_bytes fixed_hit_count fixed_hit_bytes <<< "$diff_tsv"
  fi
  local _v
  for _v in new_count new_bytes upd_count upd_bytes fixed_hit_count fixed_hit_bytes; do
    [[ "${!_v}" =~ ^[0-9]+$ ]] || eval "$_v=0"
  done

  local sync_bytes=$((new_bytes + upd_bytes))
  local sync_count=$((new_count + upd_count))
  local fixed_note=""
  if [ "$fixed_hit_count" -gt 0 ]; then
    fixed_note=" · <i>已扣减 ${fixed_hit_count} 个修复文件 / $(format_bytes "$fixed_hit_bytes")</i>"
  fi

  PREVIEW_TOTAL_SYNC_BYTES=$((PREVIEW_TOTAL_SYNC_BYTES + sync_bytes))
  PREVIEW_TOTAL_SYNC_COUNT=$((PREVIEW_TOTAL_SYNC_COUNT + sync_count))
  PREVIEW_TOTAL_NEW_COUNT=$((PREVIEW_TOTAL_NEW_COUNT + new_count))
  PREVIEW_TOTAL_UPD_COUNT=$((PREVIEW_TOTAL_UPD_COUNT + upd_count))

  # exclude 摘要
  local exclude_summary
  exclude_summary=$(_extract_exclude_summary "${extra_args[@]}")

  # 同步对数据缓冲（TSV），flush_task_preview 时按源端分组渲染为
  # 📁 组头 + ├─/└─ 树形条目（与进度通知的任务列表同风格）
  # 空字段写 "-" 占位: tab 是 IFS 空白类字符，read 会吞掉空列导致字段错位
  # （同 progress.sh 的任务队列 TSV 约定）
  # 字段: src/excl/sbytes/scount/dst/ybytes/ycount/ynew/yupd/fnote/dfail
  # dfail=1 → 目标端列举失败，该条目为按空目标端的全量估算（不可靠）
  local _excl_ph="${exclude_summary:--}"
  local _fnote_ph="${fixed_note:--}"
  PREVIEW_PAIRS_TSV+="${source_path}"$'\t'"${_excl_ph}"$'\t'"${src_bytes}"$'\t'"${src_count}"$'\t'"${dest_path}"$'\t'"${sync_bytes}"$'\t'"${sync_count}"$'\t'"${new_count}"$'\t'"${upd_count}"$'\t'"${_fnote_ph}"$'\t'"${dst_fail}"$'\n'
}

# 同步对详情渲染: 仅按源端分组（同源端多目标一组的树形列表）
#   📁 <code>src</code> · <i>源端 X / N 文件</i>        ← 组内各条目源端大小一致时上提组头
#     ├─ <code>dst</code> · <i>源端 X / N 文件</i> · <b>+Y / +K 文件</b>
#     │   差异构成：新增 a · 同名更新 b                  ← 存在同名更新时的说明子行
#     │   排除：<code>pat</code>                          ← 有排除规则的条目子行
#     └─ <code>dst</code> · <i>无变动</i>
#   组内源端大小不一（如部分目标带排除规则）时组头不带大小、各条目单独标注，
#   避免同一源端因排除规则不同而分裂成多组; 组间空一行分隔。
# 输入: PREVIEW_PAIRS_TSV（每行 src/excl/sbytes/scount/dst/ybytes/ycount/ynew/yupd/fnote）
_preview_render_pairs_detail() {
  # 第一遍: 按源端聚合条目数，并判断组内源端大小是否一致（能否上提组头）
  declare -A _g_total=() _g_size=()
  local -a _g_order=()
  while IFS=$'\t' read -r _src _excl _sbytes _scount _dst _ybytes _ycount _ynew _yupd _fnote _dfail; do
    [ -z "$_src" ] && continue
    if [ -z "${_g_total[$_src]+x}" ]; then
      _g_total[$_src]=0
      _g_order+=("$_src")
      _g_size[$_src]="${_sbytes}|${_scount}"
    elif [ "${_g_size[$_src]}" != "${_sbytes}|${_scount}" ]; then
      _g_size[$_src]=""   # 大小不一 → 不上提
    fi
    _g_total[$_src]=$(( ${_g_total[$_src]} + 1 ))
  done <<< "$PREVIEW_PAIRS_TSV"
  # 第二遍: 渲染条目（含子行），按组缓冲
  declare -A _g_seen=() _g_block=()
  while IFS=$'\t' read -r _src _excl _sbytes _scount _dst _ybytes _ycount _ynew _yupd _fnote _dfail; do
    [ -z "$_src" ] && continue
    # 还原 "-" 占位为空
    [ "$_excl" = "-" ] && _excl=""
    [ "$_fnote" = "-" ] && _fnote=""
    _g_seen[$_src]=$(( ${_g_seen[$_src]:-0} + 1 ))
    local _last=0
    [ "${_g_seen[$_src]}" -eq "${_g_total[$_src]}" ] && _last=1
    # 目标端 openlist: 前缀冗余（与进度通知一致），统一裁剪
    local _entry="<code>$(escape_html "${_dst#openlist:}")</code>"
    # 源端大小未上提组头时在条目行标注
    [ -z "${_g_size[$_src]}" ] && _entry+=" · <i>源端 $(format_bytes "$_sbytes") / ${_scount} 文件</i>"
    if [ "$_ybytes" -gt 0 ] || [ "$_ycount" -gt 0 ]; then
      _entry+=" · <b>+$(format_bytes "$_ybytes") / +${_ycount} 文件</b>"
    else
      _entry+=" · <i>无变动</i>"
    fi
    _g_block[$_src]+="$(tree_conn "$_last")${_entry}"$'\n'
    local _sub
    _sub=$(tree_sub "$_last")
    # 差异构成子行: 存在同名更新时展示（纯新增自明，不占行），
    # 直接回答 "+X / +0 文件" 类困惑——同名更新文件也计入待同步数
    if [ "${_yupd:-0}" -gt 0 ]; then
      local _comp="差异构成："
      [ "${_ynew:-0}" -gt 0 ] && _comp+="新增 ${_ynew} · "
      _comp+="同名更新 ${_yupd}"
      _g_block[$_src]+="${_sub}${_comp}"$'\n'
    fi
    [ -n "$_excl" ] && _g_block[$_src]+="${_sub}排除：<code>$(escape_html "$_excl")</code>"$'\n'
    [ -n "$_fnote" ] && _g_block[$_src]+="${_sub}${_fnote# · }"$'\n'
    # 目标端列举失败: 该条目数值是按空目标端的全量估算，必须明示（否则合计
    # 虚高被当成精确值，正是 "目标端已有文件却显示全量待同步" 的困惑来源）
    [ "${_dfail:-0}" = "1" ] && _g_block[$_src]+="${_sub}⚠️ 目标端列举失败 · 按全量估算，实际待同步可能更少"$'\n'
  done <<< "$PREVIEW_PAIRS_TSV"
  # 组装: 组头 + 树形条目块，组间空一行（首组前不加——tg_add_section 已带段前空行）
  local _out="" _src _gi=0
  for _src in "${_g_order[@]}"; do
    [ "$_gi" -gt 0 ] && _out+=$'\n'
    _out+="📁 <code>$(escape_html "$_src")</code>"
    if [ -n "${_g_size[$_src]}" ]; then
      _out+=" · <i>源端 $(format_bytes "${_g_size[$_src]%%|*}") / ${_g_size[$_src]##*|} 文件</i>"
    fi
    _out+=$'\n'"${_g_block[$_src]%$'\n'}"$'\n'
    _gi=$((_gi + 1))
  done
  printf '%s' "$_out"
}

# 发送任务预览通知到 Telegram
# 用法: flush_task_preview
flush_task_preview() {
  # 合计构成说明: 存在同名更新时附注（与条目子行同规则），纯新增自明
  local _total_note=""
  if [ "${PREVIEW_TOTAL_UPD_COUNT:-0}" -gt 0 ]; then
    _total_note="（"
    [ "${PREVIEW_TOTAL_NEW_COUNT:-0}" -gt 0 ] && _total_note+="新增 ${PREVIEW_TOTAL_NEW_COUNT} · "
    _total_note+="同名更新 ${PREVIEW_TOTAL_UPD_COUNT}）"
  fi
  # 有目标端列举失败的对时，合计里混着按全量估算的不可靠分量，必须明示——
  # 该数字是上界不是精确值（历史缺陷: 只打 job 日志，预览静默虚高无从辨别）
  local _fail_note=""
  if [ "${PREVIEW_FAIL_PAIRS:-0}" -gt 0 ]; then
    _fail_note=$'\n'"⚠️ ${PREVIEW_FAIL_PAIRS} 个同步对目标端列举失败，按全量估算，实际待同步可能更少"
  fi

  local msg=""
  tg_add_title msg "📋 任务预览 · ${PREVIEW_TASK_NAME}"
  tg_add_section msg "📊 同步对（${PREVIEW_PAIR_COUNT} 对）"
  tg_append msg "$(_preview_render_pairs_detail)"
  tg_append msg $'\n\n'"📦 合计预估待同步：<b>$(format_bytes "$PREVIEW_TOTAL_SYNC_BYTES")</b> / <b>${PREVIEW_TOTAL_SYNC_COUNT}</b> 文件${_total_note}${_fail_note}"

  send_telegram_message "$msg"
  echo "  已发送 ${PREVIEW_TASK_NAME} 预览通知"
}
