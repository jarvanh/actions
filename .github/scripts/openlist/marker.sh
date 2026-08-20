#!/bin/bash
# ===== OpenList 同步工具 — 同步标记系统 =====
# 通过在 OneDrive 上保存 JSON 标记文件来跟踪每个 task 的同步状态。
# 功能:
#   - 跳过短期内已成功同步的 task（默认 24 小时）
#   - 检测源端大小异常减小（可能数据丢失），发送警告并跳过
#
# 标记存储路径: onedrive:/logs/sync_state/<task_name>_<dest_hash>.json
# JSON 字段: last_success, source_path, dest_path, source_bytes, source_count,
#            top_dirs, stats_filtered, fixed_files, fixed_count, fixed_bytes,
#            fix_blacklist（详见 save_sync_marker / save_fix_state_marker）
#
# 依赖: utils.sh (escape_html, format_bytes), telegram.sh (send_telegram_message)
# 依赖环境变量: FORCE_SYNC — 为 "true" 时跳过所有标记检查

# 标记存储目录
SYNC_STATE_DIR="onedrive:/logs/sync_state"
# 默认跳过时间窗口（24 小时，可被 SYNC_SKIP_SECONDS 覆盖）
SYNC_SKIP_SECONDS=$((24 * 60 * 60))

# 生成标记文件路径（每个 task+dest 组合唯一）
# 用法: get_marker_path <task_name> <dest_path>
get_marker_path() {
  local task_name="$1"
  local dest_path="$2"
  local dest_hash
  dest_hash=$(echo -n "${task_name}_${dest_path}" | md5sum | cut -c1-8)
  echo "${SYNC_STATE_DIR}/${task_name}_${dest_hash}.json"
}

# 统一 marker 落盘: pretty-print（缩进格式化）后再 rcat 上传
# 中间变量一律 jq -c 紧凑格式（构建/合并省事），只有落盘这一步格式化，
# 保证 onedrive 上的 marker 始终是人可读的结构化 JSON
# （历史缺陷: 多数写入点直接 rcat 紧凑 JSON，marker 被"修复管线"重写后
#  变成不可读的一大坨单行）。
# jq 构建产物为空/非法时拒绝写入并返回 1 —— 若把空串原样 rcat 上去，
# 会直接抹掉旧 marker 里的 fixed_files/fix_blacklist 等修复记录
# （保留旧 marker + 走调用方兜底路径，远好于静默清零）。
# 用法: _marker_write <json_text> <marker_path>  返回 rclone 的退出码
_marker_write() {
  local json="$1" marker_path="$2" pretty
  if [ -z "$json" ]; then
    echo "⚠️ _marker_write: 拒绝写入空 JSON（保留旧 marker）: ${marker_path}" >&2
    return 1
  fi
  pretty=$(printf '%s' "$json" | jq . 2>/dev/null)
  if [ -z "$pretty" ]; then
    echo "⚠️ _marker_write: JSON 非法，拒绝写入（保留旧 marker）: ${marker_path}" >&2
    return 1
  fi
  printf '%s\n' "$pretty" | rclone rcat "$marker_path"
}

# 从旧 marker 继承仍有效的修复条目（original 在目标端仍不存在 = 未对齐，保留；
# original 已出现 = 本轮已正常同步对齐，剔除）。输出 carried JSON 数组到 stdout。
# 用法: _carry_forward_fixed <dest_path> <old_marker_json>
_carry_forward_fixed() {
  local dest_path="$1"
  local old_marker="$2"
  local carried_json="[]"

  local old_fixed_count
  old_fixed_count=$(echo "$old_marker" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
  # 数值防护: jq 可能输出空/null（旧 marker 非法 JSON 等），非数字一律按 0
  [[ "$old_fixed_count" =~ ^[0-9]+$ ]] || old_fixed_count=0
  if [ "$old_fixed_count" -eq 0 ]; then
    echo "[]"
    return 0
  fi

  local carried_entries=()
  local idx orig _dummy _size_bytes
  local tsv
  tsv=$(echo "$old_marker" | jq -r '
    (.fixed_files // []) | to_entries[]
    | [.key, (.value.original // ""), (.value.alternative // ""), (.value.size_bytes // 0)]
    | @tsv' 2>/dev/null || echo "")
  local old_fixed_json
  old_fixed_json=$(echo "$old_marker" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

  while IFS=$'\t' read -r idx orig _dummy _size_bytes; do
    [ -z "$orig" ] && continue
    # 探测目标端是否已出现原名文件（已存在则无需继承）
    local probe exists
    probe=$(timeout 20 rclone lsjson "${dest_path}/${orig}" --max-depth 1 2>/dev/null || echo "[]")
    exists=$(echo "$probe" | jq -r 'length // 0' 2>/dev/null || echo 0)
    [[ "$exists" =~ ^[0-9]+$ ]] || exists=0
    if [ "$exists" -eq 0 ]; then
      carried_entries+=("$idx")
    fi
  done <<< "$tsv"

  if [ "${#carried_entries[@]}" -gt 0 ]; then
    # 索引走 --argjson 数字数组（极小）; 大清单 old_fixed_json 本就在 stdin，
    # 不拼进 jq 程序文本——程序文本同受单参数 128KB 上限约束
    local idx_json
    local IFS=,
    idx_json="[${carried_entries[*]}]"
    carried_json=$(echo "$old_fixed_json" | jq -c --argjson idx "$idx_json" '[.[$idx[]]]' 2>/dev/null || echo "[]")
  fi
  echo "$carried_json"
}

# ===== marker 修复字段读写统一接口 =====
# 所有对 marker JSON 的修复字段（fixed_files / fix_blacklist）读写必须经由
# 以下函数，禁止在业务脚本内散落 jq 副本（历史上有 4 份实现，曾互相漂移）。

# 把全局关联数组 FIX_METHOD_BLACKLIST 序列化为 JSON 对象（空数组输出 {}）
fix_blacklist_to_json() {
  local bl_json="{}" f
  for f in "${!FIX_METHOD_BLACKLIST[@]}"; do
    bl_json=$(jq -cn --argjson j "$bl_json" --arg k "$f" --arg v "${FIX_METHOD_BLACKLIST[$f]}" \
      '$j + {($k): $v}' 2>/dev/null) || bl_json="{}"
  done
  echo "$bl_json"
}

# 合并两个 JSON 对象（b 并入 a，b 优先）；失败时回退为 a
# 注意: 调用方禁止写 ${VAR:-{}} —— bash 会给已赋值变量追加字面 }，产生非法 JSON
# a/b 经 stdin 喂给 jq（--argjson 走 argv，黑名单对象积累到上千条时
# 超 128KB 单参数上限，execve E2BIG 失败被吞 → 合并结果静默回退）
_marker_merge_json() {
  local a="$1" b="$2"
  [ -z "$a" ] && a="{}"
  [ -z "$b" ] && b="{}"
  printf '%s\n%s\n' "$a" "$b" | jq -sc '. as [$x, $y] | ($x // {}) * ($y // {})' 2>/dev/null || echo "$a"
}

# 从 marker JSON 安全提取 fix_blacklist 对象（缺失/非对象时输出 {}）
_marker_read_blacklist() {
  echo "${1:-}" | jq -c 'if (.fix_blacklist // null) | type == "object" then .fix_blacklist else {} end' 2>/dev/null || echo "{}"
}

# 在 marker JSON 上合并黑名单字段（旧 ∪ 新，新优先），stdin → stdout
# 用法: echo "$marker_json" | marker_merge_blacklist "$bl_json"
# bl_json 与 marker 均经 stdin 喂 jq（不走 argv，防 128KB 单参数上限）
marker_merge_blacklist() {
  local bl_json="$1"
  [ -z "$bl_json" ] && bl_json="{}"
  { cat; printf '\n%s\n' "$bl_json"; } | jq -sc \
    '. as [$m, $bl] | $m + {fix_blacklist: (($m.fix_blacklist // {}) * $bl)}' 2>/dev/null
}

# 在 marker JSON 上追加/覆盖一个修复条目（同 original 新覆盖旧）并合并黑名单，
# stdin → stdout；fixed_count/fixed_bytes 自动重算
# 用法: marker_add_fix_entry "$entry_json" "$bl_json" < "$state_file"
# marker（stdin）/entry/bl 全部并入 stdin 文档流喂 jq -s —— state_file 里的
# fixed_files 含内嵌 restore 脚本，条目多时远超 argv 单参数 128KB 上限，
# --argjson 传参会 E2BIG 失败 → merged 为空 → 修复条目静默丢失
marker_add_fix_entry() {
  local entry_json="$1" bl_json="$2"
  [ -z "$bl_json" ] && bl_json="{}"
  { cat; printf '\n%s\n%s\n' "$entry_json" "$bl_json"; } | jq -sc '
    . as [$m, $e, $bl]
    | ($m.fixed_files // []) as $ff
    | ($ff | map(select(.original != $e.original)) + [$e]) as $nff
    | $m + {fixed_files: $nff,
            fixed_count: ($nff | length),
            fixed_bytes: ([$nff[].size_bytes] | add // 0),
            fix_blacklist: (($m.fix_blacklist // {}) * $bl)}
  ' 2>/dev/null
}

# 从 marker JSON 移除指定 original 的修复条目，stdin → stdout
# also_blacklist=1 时同时删除该文件的 fix_blacklist 条目（还原成功场景）
# 用法: echo "$marker_json" | marker_remove_fix_entry "$orig" [also_blacklist]
marker_remove_fix_entry() {
  local orig="$1" also_bl="${2:-0}"
  if [ "$also_bl" = "1" ]; then
    jq -c --arg o "$orig" '
      del(.fix_blacklist[$o])
      | .fixed_files = ((.fixed_files // []) | map(select(.original != $o)))
      | .fixed_count = (.fixed_files | length)
      | .fixed_bytes = ([.fixed_files[].size_bytes] | add // 0)
    ' 2>/dev/null
  else
    jq -c --arg o "$orig" '
      .fixed_files //= []
      | .fixed_files |= map(select(.original != $o))
      | .fixed_count = (.fixed_files | length)
      | .fixed_bytes = ([.fixed_files[].size_bytes] | add // 0)
    ' 2>/dev/null
  fi
}

# 持久化修复状态（fixed_files + fix_blacklist）— 无论本轮成败都写入
# 与 save_sync_marker 的区别:
#   - 部分失败轮（SYNC_FAILED=1）也要保存修复成果。否则下一轮看不到上轮
#     已持久化的替代文件，会重复下载/打包/上传；跨轮方法黑名单也会丢失
#   - 合并写入：仅替换修复相关字段，保留旧 marker 的 last_success 等字段；
#     无旧 marker 时创建不含 last_success 的修复状态（不会触发 24h 跳过）
#   - 不做 missing_count>5 拒绝（本函数就是为存在缺失的场景设计的）
# 依赖全局变量: GLOBAL_FIXED_FILES_JSON, GLOBAL_FIX_BLACKLIST_JSON（tasks.sh 顶级初始化）
# 用法: save_fix_state_marker <source_path> <dest_path> <task_name>
save_fix_state_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  local new_fixed_json="${GLOBAL_FIXED_FILES_JSON:-[]}"
  # 不能写 ${VAR:-{}} —— bash 会给已赋值变量追加字面 }，产生非法 JSON，
  # 导致 new_bl_count=0、下方合并回退成 {}（实测把已落盘的黑名单清零）
  local new_bl_json="${GLOBAL_FIX_BLACKLIST_JSON:-}"
  [ -z "$new_bl_json" ] && new_bl_json="{}"
  local new_count new_bl_count
  new_count=$(echo "$new_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  new_bl_count=$(echo "$new_bl_json" | jq 'length' 2>/dev/null || echo 0)
  [[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
  [[ "$new_bl_count" =~ ^[0-9]+$ ]] || new_bl_count=0

  # 读取现有 marker（可能不存在）
  local old_marker=""
  old_marker=$(rclone cat "$marker_path" 2>/dev/null) || true
  local old_fixed_count=0
  [ -n "$old_marker" ] && old_fixed_count=$(echo "$old_marker" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
  [[ "$old_fixed_count" =~ ^[0-9]+$ ]] || old_fixed_count=0

  # 无新修复、无新黑名单、旧 marker 也无修复记录 → 无事可做
  if [ "$new_count" -eq 0 ] && [ "$new_bl_count" -eq 0 ] && [ "$old_fixed_count" -eq 0 ]; then
    return 0
  fi

  # carry-forward: 继承旧记录中 original 仍未对齐的条目，与本轮新修复合并（新优先）
  local carried_json="[]"
  [ "$old_fixed_count" -gt 0 ] && carried_json=$(_carry_forward_fixed "$dest_path" "$old_marker")
  local carried_count
  carried_count=$(echo "$carried_json" | jq 'length' 2>/dev/null || echo 0)
  [[ "$carried_count" =~ ^[0-9]+$ ]] || carried_count=0

  local merged_fixed_json
  # 两份清单经 stdin 文档流喂 jq -s（--argjson 走 argv，fixed_files 条目内嵌
  # restore 脚本、总量轻松超 128KB 单参数上限 → E2BIG 被吞 → 历史上静默
  # 回退 "[]"，把已落盘修复记录整体清零）
  merged_fixed_json=$(printf '%s\n%s\n' "$new_fixed_json" "$carried_json" | jq -sc '
    . as [$new, $carried]
    | $new + ([$carried[] | select((.original as $o | $new | map(.original == $o) | any) | not)])
  ' 2>/dev/null || echo "")
  # 降级链: 完整合并失败时优先保住本轮新修复（最新事实），其次继承清单，
  # 绝不静默回退 "[]"（那会把旧 marker 修复记录清零）
  if [ -z "$merged_fixed_json" ]; then
    if echo "$new_fixed_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      merged_fixed_json="$new_fixed_json"
    else
      merged_fixed_json="$carried_json"
    fi
  fi

  # 黑名单合并: 旧 ∪ 新（新优先）；对已对齐文件的黑名单条目一并清理
  local merged_bl_json="{}"
  if [ -n "$old_marker" ]; then
    merged_bl_json=$(_marker_read_blacklist "$old_marker")
  fi
  merged_bl_json=$(_marker_merge_json "$merged_bl_json" "$new_bl_json")

  local fixed_count fixed_bytes
  fixed_count=$(echo "$merged_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$merged_fixed_json" | jq '[.[].size_bytes] | add // 0' 2>/dev/null || echo 0)
  [[ "$fixed_count" =~ ^[0-9]+$ ]] || fixed_count=0
  [[ "$fixed_bytes" =~ ^[0-9]+$ ]] || fixed_bytes=0

  # 合并写入: 有旧 marker 时仅替换修复字段（保留 last_success 等）；
  # 无旧 marker 时创建仅含修复状态的对象（无 last_success → 不影响跳过判断）
  # 大字段（fixed_files/fix_blacklist）走 stdin，小标量走 --arg/--argjson
  local marker_json
  if [ -n "$old_marker" ] && echo "$old_marker" | jq -e 'type == "object"' >/dev/null 2>&1; then
    marker_json=$(printf '%s\n%s\n%s\n' "$old_marker" "$merged_fixed_json" "$merged_bl_json" | jq -sc \
      --argjson fixed_count "$fixed_count" \
      --argjson fixed_bytes "$fixed_bytes" '
      . as [$m, $fixed_files, $fix_blacklist]
      | $m + {fixed_files: $fixed_files, fixed_count: $fixed_count, fixed_bytes: $fixed_bytes, fix_blacklist: $fix_blacklist}')
  else
    marker_json=$(printf '%s\n%s\n' "$merged_fixed_json" "$merged_bl_json" | jq -sc \
      --arg source_path "$source_path" \
      --arg dest_path "$dest_path" \
      --argjson fixed_count "$fixed_count" \
      --argjson fixed_bytes "$fixed_bytes" '
      . as [$fixed_files, $fix_blacklist]
      | {source_path: $source_path, dest_path: $dest_path, fixed_files: $fixed_files,
         fixed_count: $fixed_count, fixed_bytes: $fixed_bytes, fix_blacklist: $fix_blacklist}')
  fi

  rclone mkdir "$SYNC_STATE_DIR" >/dev/null 2>&1 || true
  _marker_write "$marker_json" "$marker_path" 2>/dev/null
  local bl_total
  bl_total=$(echo "$merged_bl_json" | jq 'length' 2>/dev/null || echo 0)
  [[ "$bl_total" =~ ^[0-9]+$ ]] || bl_total=0
  echo "已保存修复状态: $marker_path (本轮修复 ${new_count} 个, 继承 ${carried_count} 个, 合计 ${fixed_count} 个; 方法黑名单 ${bl_total} 条)"
}

# 保存同步标记（同步成功后调用）
# 记录: 时间戳、源端路径、目标路径、源端大小/文件数、顶层目录列表、已修复文件列表
# 已修复文件列表 (fixed_files): 通过缺失文件修复机制以非原名上传的文件
#   预览时从差异中扣减这部分，避免显示"虚假缺失"
# 方法假成功黑名单 (fix_blacklist): {文件: "方法1: ...|方法3: ..."}（方法全名，|
# 分隔），跨轮失败记忆，
#   下一轮修复时跳过已判定假成功的方法
# 用法: save_sync_marker <source_path> <dest_path> <task_name> [rclone_extra_args...]
# 额外参数用于统一源端统计口径: 应用任务的 --exclude/--include 过滤规则，
# 否则被排除路径（如 notion/）计入源端却不计入目标端，会造成永久性假缺失
save_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 获取源端大小和文件数（与 sync 相同的过滤口径）
  _extract_filter_args "${extra_args[@]}"
  local size_json source_bytes source_count
  size_json=$(_rclone_size_json "$source_path" "${FILTER_ARGS[@]}")
  source_bytes=$(_size_json_field "$size_json" bytes)
  source_count=$(_size_json_field "$size_json" count)

  # 双重保险：校验目标端真实文件数
  # 即使 _send_sync_result_notification 已做了同步后缓存刷新 + is_partial_success 检测，
  # 这里再校验一次，防止 SYNC_FAILED=0 但 dest_count 仍小于 source_count 的情况
  # （比如 auto-split 子目录各自通过检测，但汇总后总数不一致）
  # 目标端不加过滤: 替代文件/分卷/历史残留只会让 dest_count 偏大（对缺失判定是安全方向）
  local dest_size_json dest_bytes dest_count
  dest_size_json=$(_rclone_size_json "$dest_path")
  dest_bytes=$(_size_json_field "$dest_size_json" bytes)
  dest_count=$(_size_json_field "$dest_size_json" count)

  # 严格校验: 源端（过滤口径）与目标端文件数完全一致才写 marker。
  # 有任何缺失即拒绝 → 下次运行重新同步（rclone --size-only 幂等，已对齐文件直接跳过，无副作用）
  local missing_count=$((source_count - dest_count))
  if [ "$missing_count" -gt 0 ]; then
    echo "⚠️ 拒绝写入同步标记: 目标端文件数 ${dest_count} < 源端 ${source_count}（缺失 ${missing_count} 个）"
    echo "  可能原因: OpenList stale 缓存导致 rclone 跳过上传，或部分文件上传失败但未被检测到"
    echo "  本次不写 marker，下次运行将重新同步"
    return 1
  fi

  # 获取顶层目录列表（用于检测目录变化）
  # top_dirs_json: JSON 数组格式，写入 marker
  # top_dirs_lines: 行排序文本格式，兼容旧 marker 读取和对比逻辑
  local top_dirs_lines top_dirs_json
  top_dirs_lines=$(rclone lsf --dirs-only "$source_path" "${FILTER_ARGS[@]}" 2>/dev/null | sed 's|/$||' | sort)
  top_dirs_json=$(printf '%s\n' "$top_dirs_lines" | jq -R -s 'split("\n") | map(select(length>0))')

  # 读取本任务（含 auto-split 子目录）累计的修复文件列表
  # sync_with_logging 每次执行后会把 fix_list 累计到 GLOBAL_FIXED_FILES_JSON
  local new_fixed_json="${GLOBAL_FIXED_FILES_JSON:-[]}"

  # fallback 扫描脚本路径（/tmp 与仓库目录双候选：workflow 会把 *.py 一并拷到 /tmp）
  local _scan_py
  for _scan_py in \
    "/tmp/scan_fix_signatures.py" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scan_fix_signatures.py"; do
    [ -f "$_scan_py" ] && break
  done

  # ===== Carry-Forward 机制 =====
  # 重新同步如果没触发修复，new_fixed_json 会是空数组，但旧 marker 里的修复记录
  # 仍然有效（目标端以替代名存在、源端原名路径仍未对齐）。这里从旧 marker 继承：
  #   - 目标端 <dest_path>/<original> 仍不存在的修复记录 → 保留
  #   - 目标端已经出现原名文件 → 说明这次同步已正常对齐，不再继承
  local carried_json="[]"
  local carried_count=0
  local old_marker
  old_marker=$(rclone cat "$marker_path" 2>/dev/null || echo "")
  if [ -n "$old_marker" ]; then
    local old_fixed_count
    old_fixed_count=$(echo "$old_marker" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    [[ "$old_fixed_count" =~ ^[0-9]+$ ]] || old_fixed_count=0
    if [ "$old_fixed_count" -gt 0 ]; then
      carried_json=$(_carry_forward_fixed "$dest_path" "$old_marker")
      carried_count=$(echo "$carried_json" | jq 'length' 2>/dev/null || echo 0)
      [[ "$carried_count" =~ ^[0-9]+$ ]] || carried_count=0
      echo "旧标记修复记录: ${old_fixed_count} 条，继承有效 ${carried_count} 条，已对齐自动剔除 $((old_fixed_count - carried_count)) 条"
    fi
  fi

  # ===== Fallback: marker 被删除或首次同步时，从目标端扫描"修复特征"文件 =====
  # 只在顶级调用（current_depth=0 或未定义）时扫描，避免 auto-split 子目录重复扫描
  local fallback_json="[]"
  local fallback_count=0
  local total_new total_carried depth="${current_depth:-0}"
  total_new=$(echo "$new_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  total_carried=$(echo "$carried_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "${total_new:-0}" -eq 0 ] && [ "${total_carried:-0}" -eq 0 ] && [ "${depth:-0}" -eq 0 ]; then
    echo "未发现修复记录（marker 可能被删），尝试从目标端扫描特征文件反推..."

    local _tmp_out
    _tmp_out=$(mktemp)
    # 扫描逻辑在 scan_fix_signatures.py（随 *.py 拷到 /tmp，见 Load helper functions）
    if [ ! -f "$_scan_py" ]; then
      echo "⚠️ 未找到 scan_fix_signatures.py，跳过 fallback 扫描"
      : > "$_tmp_out"
    elif timeout 600 python3 "$_scan_py" "$source_path" "$dest_path" "$_tmp_out" 300 </dev/null 2>/dev/null; then
      :
    else
      echo "扫描超时或出错（忽略 fallback）"
      : > "$_tmp_out"
    fi

    if [ -s "$_tmp_out" ]; then
      fallback_count=$(wc -l < "$_tmp_out" | tr -d ' ')
      if [ "${fallback_count:-0}" -gt 0 ]; then
        echo "目标端扫描命中修复特征文件: ${fallback_count} 个，写入 fixed_files"
        local fb_entries=()
        while IFS=$'\t' read -r fb_orig fb_alt fb_method fb_sz; do
          [ -z "$fb_orig" ] && continue
          local fb_shuman
          fb_shuman=$(format_bytes "$fb_sz" 2>/dev/null || echo "${fb_sz} B")
          local fb_script tmpl
          tmpl="此条目为 fallback 扫描生成，请参考 method 字段手动还原：original=${fb_orig} alternative=${fb_alt} method=${fb_method}"
          fb_entries+=("$(jq -cn \
            --arg o "$fb_orig" --arg a "$fb_alt" --arg m "$fb_method" \
            --arg sh "$fb_shuman" --argjson sb "${fb_sz:-0}" \
            --arg scr "$tmpl" \
            '{original:$o, alternative:$a, method:$m,
              size_human:$sh, size_bytes:$sb,
              restore:{kind:"scanned",
                       summary:"从目标端特征扫描反推（非修复时直接记录的精确信息）",
                       steps:["下载目标端 alternative 路径文件",
                              "根据 method 字段对应方式还原：base64URL 解码目录名/文件名、unzip/7z x 解压、重命名 API 文件"],
                       script: ("# " + $scr)}}')")
        done < "$_tmp_out"
        if [ "${#fb_entries[@]}" -gt 0 ]; then
          local _tmp_json
          _tmp_json=$(mktemp)
          printf '%s\n' "${fb_entries[@]}" | jq -sc '.' > "$_tmp_json" 2>/dev/null || echo "[]" > "$_tmp_json"
          fallback_json=$(cat "$_tmp_json")
          fallback_count=$(echo "$fallback_json" | jq 'length' 2>/dev/null || echo 0)
          rm -f "$_tmp_json"
        fi
      fi
    fi
    rm -f "$_tmp_out"
  fi

  # 合并: 本轮新修复 ∪ 继承修复 ∪ fallback 扫描修复，以 original 为 key 去重
  # 优先级: 新修复 > 继承 > fallback（新修复信息更精确）
  # 三份清单经 stdin 文档流喂 jq -s（--argjson 走 argv 受 128KB 单参数上限，
  # fixed_files 条目内嵌 restore 脚本，积累后必超 → E2BIG 失败 → 修复记录丢失）
  local merged_fixed_json
  merged_fixed_json=$(printf '%s\n%s\n%s\n' "$new_fixed_json" "$carried_json" "$fallback_json" | jq -sc '
    def without_originals($arr; $orig_set):
      [$arr[] | select(.original as $o | ($orig_set | map(.original) | index($o) | not))];
    . as [$new, $carried, $fb]
    | (without_originals($carried; $new)) as $C
    | (without_originals($fb; ($new + $C))) as $F
    | $new + $C + $F
  ' 2>/dev/null)
  # 上面 jq 写法较复杂容易错，失败时降级为 new ∪ carried（仍走 stdin）
  if [ -z "$merged_fixed_json" ]; then
    merged_fixed_json=$(printf '%s\n%s\n' "$new_fixed_json" "$carried_json" | jq -sc '
      . as [$new, $carried]
      | $new + ([$carried[] | select((.original as $o | $new | map(.original == $o) | any) | not)])
    ' 2>/dev/null || echo "")
  fi
  # 再降级: 合并彻底失败时保住本轮新修复（最新事实），绝不回退 "[]"
  if [ -z "$merged_fixed_json" ] && echo "$new_fixed_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    merged_fixed_json="$new_fixed_json"
  fi

  local fixed_count fixed_bytes
  fixed_count=$(echo "$merged_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$merged_fixed_json" | jq '[.[].size_bytes] | add // 0' 2>/dev/null || echo 0)
  [[ "$fixed_count" =~ ^[0-9]+$ ]] || fixed_count=0
  [[ "$fixed_bytes" =~ ^[0-9]+$ ]] || fixed_bytes=0

  # ===== 方法假成功黑名单（B: 失败记忆）=====
  # merge: 旧 marker 的 fix_blacklist ∪ 本轮新增（GLOBAL_FIX_BLACKLIST_JSON，
  # 由 sync_with_logging 累计），本轮结果优先。下一轮修复时 try_fix_failed_file
  # 跳过这些方法，避免已判定假成功的方式每轮重复白跑。
  local merged_blacklist_json="{}"
  if [ -n "$old_marker" ]; then
    merged_blacklist_json=$(_marker_read_blacklist "$old_marker")
  fi
  # 不能写 ${VAR:-{}} —— bash 会给已赋值变量追加字面 }，产生非法 JSON，
  # 合并失败回退成 {} 会把旧 marker 已落盘的黑名单整体清零
  local _new_bl_json="${GLOBAL_FIX_BLACKLIST_JSON:-}"
  [ -z "$_new_bl_json" ] && _new_bl_json="{}"
  merged_blacklist_json=$(_marker_merge_json "$merged_blacklist_json" "$_new_bl_json")

  # 构建 JSON 标记（大字段 fixed_files/fix_blacklist 走 stdin，小标量走 --arg/--argjson）
  local marker_json
  marker_json=$(printf '%s\n%s\n' "$merged_fixed_json" "$merged_blacklist_json" | jq -s \
    --arg last_success "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_path "$source_path" \
    --arg dest_path "$dest_path" \
    --argjson source_bytes "$source_bytes" \
    --argjson source_count "$source_count" \
    --argjson top_dirs "$top_dirs_json" \
    --argjson fixed_count "$fixed_count" \
    --argjson fixed_bytes "$fixed_bytes" \
    --argjson stats_filtered true \
    '. as [$fixed_files, $fix_blacklist]
    | {last_success: $last_success, source_path: $source_path, dest_path: $dest_path,
       source_bytes: $source_bytes, source_count: $source_count, top_dirs: $top_dirs,
       fixed_files: $fixed_files, fixed_count: $fixed_count, fixed_bytes: $fixed_bytes,
       fix_blacklist: $fix_blacklist, stats_filtered: $stats_filtered}')

  # 上传标记到 OneDrive
  rclone mkdir "$SYNC_STATE_DIR" >/dev/null 2>&1 || true
  _marker_write "$marker_json" "$marker_path" 2>/dev/null
  local summary=""
  local new_count fb_count
  new_count=$(echo "$new_fixed_json" | jq 'length' 2>/dev/null || echo 0)
  fb_count=$(echo "$fallback_json" | jq 'length' 2>/dev/null || echo 0)
  [[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
  [[ "$fb_count" =~ ^[0-9]+$ ]] || fb_count=0
  [ "$new_count" -gt 0 ] && summary+=" 本次修复 ${new_count} 个;"
  [ "$carried_count" -gt 0 ] && summary+=" 继承上轮 ${carried_count} 个;"
  [ "${fb_count:-0}" -gt 0 ] && summary+=" fallback扫描反推 ${fb_count} 个;"
  echo "已保存同步标记: $marker_path (源端 $(format_bytes "$source_bytes"), ${source_count} 文件, 修复合计 ${fixed_count} 个${summary})"
}

# 检查同步标记（同步前调用）
# 设置全局变量:
#   MARKER_ACTION        — "skip" | "warning" | "proceed"
#   MARKER_JSON          — 标记 JSON 原文
#   MARKER_CURRENT_BYTES — 当前源端字节数
#   MARKER_CURRENT_COUNT — 当前源端文件数
#   MARKER_CURRENT_DIRS  — 当前源端顶层目录列表
#   MARKER_LAST_SUCCESS  — 上次成功时间（ISO 8601）
#   MARKER_SINCE_HOURS   — 距上次同步的小时数
#   MARKER_FIXED_COUNT   — 已修复文件数（以非原名存在于目标端）
#   MARKER_FIXED_BYTES   — 已修复文件总字节数
#   MARKER_FIXED_FILES   — 已修复文件列表 JSON
# 用法: check_sync_marker <source_path> <dest_path> <task_name> [rclone_extra_args...]
check_sync_marker() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  MARKER_ACTION="proceed"
  MARKER_JSON=""
  MARKER_CURRENT_BYTES=0
  MARKER_CURRENT_COUNT=0
  MARKER_CURRENT_DIRS=""
  MARKER_LAST_SUCCESS=""
  MARKER_SINCE_HOURS=0
  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"

  # 强制同步跳过所有检查
  if [ "$FORCE_SYNC" = "true" ]; then
    echo "强制同步模式，跳过标记检查"
    return 0
  fi

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  # 下载标记
  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  if [ -z "$marker_json" ]; then
    echo "无同步标记，继续同步"
    return 0
  fi

  MARKER_JSON="$marker_json"

  # 解析已修复文件信息（用于预览扣减和跳过通知）
  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

  # 解析上次成功时间
  local last_success
  last_success=$(echo "$marker_json" | jq -r '.last_success // ""')

  if [ -z "$last_success" ]; then
    echo "标记无时间戳，继续同步"
    return 0
  fi

  # 检查是否在跳过时间窗口内
  local now_epoch last_epoch diff
  now_epoch=$(date +%s)
  last_epoch=$(date -d "$last_success" +%s 2>/dev/null || echo 0)

  if [ "$last_epoch" -gt 0 ]; then
    diff=$((now_epoch - last_epoch))
    if [ "$diff" -lt "$SYNC_SKIP_SECONDS" ]; then
      echo "$((SYNC_SKIP_SECONDS / 3600))小时内已成功同步（距今 $((diff / 3600)) 小时），跳过"
      MARKER_ACTION="skip"
      MARKER_LAST_SUCCESS="$last_success"
      MARKER_SINCE_HOURS=$((diff / 3600))
      return 0
    fi
  fi

  # 检查源端大小是否减小（可能数据丢失）
  # 源端统计与 save_sync_marker 保持相同的过滤口径（应用 --exclude/--include）
  local marker_bytes
  marker_bytes=$(echo "$marker_json" | jq -r '.source_bytes // 0')

  _extract_filter_args "${extra_args[@]}"
  local current_size_json
  current_size_json=$(_rclone_size_json "$source_path" "${FILTER_ARGS[@]}")
  MARKER_CURRENT_BYTES=$(_size_json_field "$current_size_json" bytes)
  MARKER_CURRENT_COUNT=$(_size_json_field "$current_size_json" count)
  MARKER_CURRENT_DIRS=$(rclone lsf --dirs-only "$source_path" "${FILTER_ARGS[@]}" 2>/dev/null | sed 's|/$||' | sort)

  if [ "$MARKER_CURRENT_BYTES" -lt "$marker_bytes" ]; then
    # 旧 marker（无 stats_filtered 标记）记录的是未过滤口径，与当前过滤口径不可比:
    # 视为口径迁移，跳过本轮缩小检测，同步成功后 marker 会按新口径重写
    local stats_filtered
    stats_filtered=$(echo "$marker_json" | jq -r '.stats_filtered // false')
    if [ "$stats_filtered" != "true" ]; then
      echo "旧 marker 为未过滤统计口径（无 stats_filtered），跳过源端缩小检测，本轮成功后将按新口径重写"
    else
      echo "⚠️ 源端大小减小: $(format_bytes "$marker_bytes") → $(format_bytes "$MARKER_CURRENT_BYTES")"
      MARKER_ACTION="warning"
      return 0
    fi
  fi

  echo "标记检查通过，继续同步"
  MARKER_ACTION="proceed"
  return 0
}

# 仅加载 marker 的 fixed_files 信息（不做跳过判断，供预览使用）
# 设置全局变量: MARKER_FIXED_COUNT, MARKER_FIXED_BYTES, MARKER_FIXED_FILES,
#               MARKER_FIX_BLACKLIST（方法假成功黑名单 JSON 对象）
# 用法: _load_marker_fixed_files <source_path> <dest_path> <task_name>
_load_marker_fixed_files() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"

  MARKER_FIXED_COUNT=0
  MARKER_FIXED_BYTES=0
  MARKER_FIXED_FILES="[]"
  MARKER_FIX_BLACKLIST="{}"

  local marker_path
  marker_path=$(get_marker_path "$task_name" "$dest_path")

  local marker_json
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || true

  [ -z "$marker_json" ] && return 0

  MARKER_FIXED_COUNT=$(echo "$marker_json" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_BYTES=$(echo "$marker_json" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)
  MARKER_FIXED_FILES=$(echo "$marker_json" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")
  MARKER_FIX_BLACKLIST=$(_marker_read_blacklist "$marker_json")
}

# 把 marker JSON 里的 top_dirs 统一转成"每行一个目录名、已排序"的文本格式
# 兼容: 新格式 JSON 数组 (["Apple","CloudMusic",...]) 和旧格式换行分隔字符串 ("Apple\nCloudMusic\n...")
# 用法: _top_dirs_to_lines <marker_json_text>
_top_dirs_to_lines() {
  local json="$1"
  # 先判断 top_dirs 是不是数组：是则逐项输出；否则按字符串原样输出（本身即多行）
  local is_array
  is_array=$(echo "$json" | jq -r 'if (.top_dirs // null) | type == "array" then "1" else "0" end' 2>/dev/null || echo 0)
  if [ "$is_array" = "1" ]; then
    echo "$json" | jq -r '.top_dirs[]' 2>/dev/null | sort
  else
    echo "$json" | jq -r '.top_dirs // ""' 2>/dev/null | sort
  fi
}

# 发送源端大小减小的警告通知（同时跳过本次同步）
# 依赖全局变量: MARKER_JSON, MARKER_CURRENT_BYTES, MARKER_CURRENT_COUNT, MARKER_CURRENT_DIRS
# 用法: send_sync_warning <task_name> <source_path> <dest_path>
send_sync_warning() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count marker_dirs
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0')
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0')
  marker_dirs=$(_top_dirs_to_lines "$MARKER_JSON")

  local diff_bytes=$((marker_bytes - MARKER_CURRENT_BYTES))
  local diff_count=$((marker_count - MARKER_CURRENT_COUNT))
  local pct=0
  if [ "$marker_bytes" -gt 0 ]; then
    pct=$((diff_bytes * 100 / marker_bytes))
  fi

  # 找出缺失和新增的目录
  local missing_dirs="" new_dirs=""
  if [ -n "$marker_dirs" ] && [ -n "$MARKER_CURRENT_DIRS" ]; then
    missing_dirs=$(comm -23 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
    new_dirs=$(comm -13 <(echo "$marker_dirs") <(echo "$MARKER_CURRENT_DIRS") 2>/dev/null || true)
  fi

  local msg=""
  tg_add_title msg "🚨 源端大小异常减小"
  tg_add_kv msg "任务" "$task_name"
  tg_add_path msg "源端" "$source_path"
  tg_add_path msg "目标" "$dest_path"
  tg_add_section msg "📊 大小对比"
  tg_add_kv msg "上次记录" "$(format_bytes "$marker_bytes") · ${marker_count} 文件"
  tg_add_kv msg "当前大小" "$(format_bytes "$MARKER_CURRENT_BYTES") · ${MARKER_CURRENT_COUNT} 文件"
  tg_add_kv msg "减少" "$(format_bytes "$diff_bytes") · ${pct}%"
  if [ "$diff_count" -ne 0 ]; then
    tg_add_kv msg "文件减少" "${diff_count} 个"
  fi

  if [ -n "$missing_dirs" ]; then
    tg_add_section msg "📁 缺失的目录（可能被删除）"
    while IFS= read -r d; do
      [ -n "$d" ] && tg_append msg "• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$missing_dirs"
  fi

  if [ -n "$new_dirs" ]; then
    tg_add_section msg "📁 新增的目录"
    while IFS= read -r d; do
      [ -n "$d" ] && tg_append msg "• <code>$(escape_html "$d")</code>"$'\n'
    done <<< "$new_dirs"
  fi

  tg_add_section msg "⏸️ 已跳过此同步，继续执行其他任务"
  tg_add_note msg "如确认无误，请手动触发 force_sync=true"

  send_telegram_message "$msg"
}

# 发送"近期已成功同步，本次跳过"的通知
# 依赖全局变量: MARKER_LAST_SUCCESS, MARKER_SINCE_HOURS, MARKER_JSON
# 用法: send_sync_skipped <task_name> <source_path> <dest_path>
send_sync_skipped() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"

  local marker_bytes marker_count
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0' 2>/dev/null || echo 0)
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0' 2>/dev/null || echo 0)

  # 已修复文件信息（通过缺失文件修复机制以非原名上传的文件）
  local fixed_count fixed_bytes
  fixed_count=$(echo "$MARKER_JSON" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$MARKER_JSON" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)

  local msg=""
  # 跳过窗口由任务开关决定（--1d-skip=24h / --2d-skip=48h / ...），标题动态展示
  local skip_window_hours=$((SYNC_SKIP_SECONDS / 3600))
  tg_add_title msg "⏭️ 同步任务跳过（${skip_window_hours} 小时内已成功）"
  tg_add_kv msg "任务" "$task_name"
  tg_add_path msg "源端" "$source_path"
  tg_add_path msg "目标" "$dest_path"
  tg_add_section msg "🕒 上次同步"
  tg_add_kv msg "时间" "$MARKER_LAST_SUCCESS"
  tg_add_kv msg "距今" "${MARKER_SINCE_HOURS} 小时"
  tg_add_kv msg "记录大小" "$(format_bytes "$marker_bytes") · ${marker_count} 文件"
  if [ "${fixed_count:-0}" -gt 0 ]; then
    tg_add_kv msg "已修复文件" "${fixed_count} 个 · $(format_bytes "$fixed_bytes")（以非原名存在于目标端）"
    # 修复方式汇总（按 restore.kind 分组统计；TSV 交给 bash 格式化，
    # 字节数走 format_bytes 人类可读单位，summary 缩进为说明行）
    local method_summary
    # 注意: 对象字面量的值表达式必须整体加括号 —— 裸写 `kind: .x // "y"` 是
    # jq 编译错误（unexpected //），jq 不读 stdin 即退出（exit 3），大 JSON 下
    # 上游 echo 写管道触发 Broken pipe（曾在线上报 line 735）
    method_summary=$(echo "$MARKER_JSON" | jq -r '
      (.fixed_files // []) | group_by(.restore.kind // "unknown")
        | map({kind: (.[0].restore.kind // "unknown"),
               summary: (.[0].restore.summary // ""),
               count: length,
               bytes: ([.[].size_bytes] | add // 0)})
        | sort_by(-.bytes)
        | map([.kind, (.count|tostring), (.bytes|tostring), .summary] | @tsv)
        | join("\n")
    ' 2>/dev/null || echo "")
    if [ -n "$method_summary" ]; then
      tg_add_section msg "🔧 修复方式构成"
      # 树形条目（├─/└─）: 方式 × 数量 · 大小，summary 缩进为子行
      local -a _m_entries=() _m_summaries=()
      while IFS=$'\t' read -r m_kind m_count m_bytes m_summary; do
        [ -z "$m_kind" ] && continue
        _m_entries+=("<b>$(escape_html "$m_kind")</b> × ${m_count} · <i>$(format_bytes "$m_bytes")</i>")
        _m_summaries+=("$(escape_html "$m_summary")")
      done <<< "$method_summary"
      local _i _n=${#_m_entries[@]} _last
      for (( _i=0; _i<_n; _i++ )); do
        _last=0
        [ $((_i + 1)) -eq "$_n" ] && _last=1
        tg_append msg "$(tree_conn "$_last")${_m_entries[$_i]}"$'\n'
        [ -n "${_m_summaries[$_i]}" ] && tg_append msg "$(tree_sub "$_last")${_m_summaries[$_i]}"$'\n'
      done
    fi
    tg_append msg "🔗 完整还原脚本保存在 OneDrive marker <code>$(escape_html "$(get_marker_path "$task_name" "$dest_path")")</code> 的 fixed_files[].restore.script 字段"$'\n'
  fi
  tg_add_section msg "⏸️ 本次跳过同步，继续执行其他任务"
  tg_add_note msg "如需强制同步，请手动触发 force_sync=true"

  send_telegram_message "$msg"
}
