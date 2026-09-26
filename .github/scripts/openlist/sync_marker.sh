#!/bin/bash
# ===== OpenList 同步工具 — 同步标记系统 =====
# 通过在 OneDrive 上保存 JSON 标记文件来跟踪每个 task 的同步状态。
# 功能:
#   - 跳过短期内已成功同步的 task（默认 24 小时）
#   - 检测源端大小异常减小（可能数据丢失），发送警告并跳过
#   - 修复记录生命周期管理（fixed_files）:
#       carry-forward 继承（未对齐条目跨轮保留）→ 已对齐收尾（原名落位且 size
#       一致 ⇒ 删冗余替代形态 + 剔记录，防短名孤儿无限堆积）→ 父级守卫提取
#       （子任务 sync 的 filter 并入父 marker 中落在本子目录的记录，防「父修子删」，
#       见 _load_parent_marker_raw / _sync_parent_guard_extract）→ 拒写分支兜底
#       （游标拒写时立即 save_fix_state_marker 持久化修复记录，防「fold 后 marker
#       被拒写 → 记录丢 → 下轮 initial sync 删产物 → 重 fold」循环，§14.21）
#
# 标记存储路径: onedrive:/logs/sync_state/<task_name>_<dest_hash>.json
# JSON 字段: last_success, source_path, dest_path, source_bytes, source_count,
#            top_dirs, stats_filtered, fixed_files, fixed_count, fixed_bytes,
#            fix_blacklist（详见 save_sync_marker / save_fix_state_marker）
#
# ⚠️ marker 是**修复文件还原链路的唯一索引**（短哈希不可逆，见 backup_sync_state_to_dropbox
#    头部注释）——目录里除 `*_<hash>.json` 外还有 `task_rotation.json` / `backend_dead.json`
#    / `trend.jsonl`，它们共同构成"下轮从哪继续"的状态。OneDrive 账号级故障会一并带走
#    ⇒ 收尾必须打包外置备份（dropbox，只增不删，与 sync_state_mirror 的 sync 镜像互补）。
#
# 依赖: utils.sh (format_bytes), telegram.sh (send_telegram_message)
# 依赖: telegram/tg_notify.sh (escape_html, tree_* — 排版助手真源，L0 层 source)
# 依赖环境变量: FORCE_SYNC — 为 "true" 时跳过所有标记检查
#   OPENLIST_CARRY_DELETE_ALIGNED — 已对齐收尾删除开关（=0 只剔记录不删远端短名）
#     ⚠️ **默认已由 1 改为 0**（2026-09-26，与「还原保留备份副本」同决策）:
#       同步轮每 6h 自动跑一次，原名落位后删替代形态 ⇒ 副本每轮被删，marker 条目却
#       还在 ⇒ 下次预演把这些判成「备份缺失」（实测 98 条），把"已还原"伪装成"数据丢了"。
#       且短哈希不可逆，副本是唯一内容载体 ⇒ 删掉即放弃自证能力。保留的代价只是多占空间。

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

# ===== 父级修复记录 → 子任务 filter 保护（防「父修子删」，2026-09-21）=====
# 为什么需要: 父任务修复管线写的 alternative 相对**父根**（如 CloudMusic/92659aaa.flac），
#   记录在**父 marker**；而子目录 sync 的 filter 只读本子任务 marker —— 父级修好的
#   短名文件在子 sync 看来是「源端没有的多余文件」，会被 rclone sync 删掉。
#   run 35542821449 实锤双路径循环（详见计划 §14.20）:
#     A. 子任务修复的 `./短名` 规则失配 → 父级最终 sync 删 → 已由 _norm_rel_path 修掉；
#     B. 父级修复的 `子目录/短名` → 子目录 sync 的 filter 不含父 marker 记录 → 删
#        （日志 23:05-23:15 的 Deleted 行）。本函数即 B 路径的修法。
# 用法（两步，父 marker 只做一次远端 cat）:
#   raw=$(_load_parent_marker_raw <父task_name> <父dest_path>)
#   SYNC_PARENT_GUARD_JSON=$(_sync_parent_guard_extract "$raw" <subdir>)
_load_parent_marker_raw() {
  local p_task="$1" p_dest="$2"
  local mp
  mp=$(get_marker_path "$p_task" "$p_dest")
  rclone cat "$mp" 2>/dev/null || true
}

# 从父 marker 原文筛出 alternative 落在 <subdir>/ 下的条目，rebase 成子任务视角。
# 只取 alternative（保护的目的是「子 sync 别删父级修的短名」）；original 不取 ——
# 原名文件源端存在，子 sync 补传它正是想要的收尾，不该排除。
_sync_parent_guard_extract() {
  local raw="$1" subdir="$2"
  local out=""
  if [ -n "$raw" ]; then
    out=$(printf '%s' "$raw" | jq -c --arg pre "${subdir}/" '
      [(.fixed_files // [])[]
       | select(((.alternative // "") != "") and (.alternative | startswith($pre)))
       | {original: ((.original // "") | ltrimstr($pre)),
          alternative: (.alternative | ltrimstr($pre))}]' 2>/dev/null) || out=""
  fi
  # 空 marker / jq 解析失败统一兜底成合法空数组，消费方不必判空
  [ -z "$out" ] && out="[]"
  printf '%s\n' "$out"
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
# original 已出现 = 本轮已正常同步对齐，剔除**并删除替代形态文件**——原名落位后
# 替代形态冗余，只剔记录不删文件会让短名孤儿在目标端无限堆积。删除条件: size
# 一致 + 非分卷/编码类 + 开关 OPENLIST_CARRY_DELETE_ALIGNED 未关）。
# 输出 JSON 对象 {"carried":[...], "deleted":N}（N=本次删除的替代形态数）——
# 函数经命令替换调用（子 shell），计数必须走输出不能走全局变量。
# 用法: _carry_forward_fixed <dest_path> <old_marker_json>
_carry_forward_fixed() {
  local dest_path="$1"
  local old_marker="$2"

  local old_fixed_count
  old_fixed_count=$(echo "$old_marker" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
  # 数值防护: jq 可能输出空/null（旧 marker 非法 JSON 等），非数字一律按 0
  [[ "$old_fixed_count" =~ ^[0-9]+$ ]] || old_fixed_count=0
  if [ "$old_fixed_count" -eq 0 ]; then
    echo '{"carried":[],"deleted":0}'
    return 0
  fi

  local carried_entries=()
  local idx orig alt size_bytes
  local tsv
  tsv=$(echo "$old_marker" | jq -r '
    (.fixed_files // []) | to_entries[]
    | [.key, (.value.original // ""), (.value.alternative // ""), (.value.size_bytes // 0)]
    | @tsv' 2>/dev/null || echo "")
  local old_fixed_json
  old_fixed_json=$(echo "$old_marker" | jq -c '.fixed_files // []' 2>/dev/null || echo "[]")

  # 已对齐收尾计数（原名落位后删除的替代形态数，随返回对象回传）
  local _deleted_n=0
  while IFS=$'\t' read -r idx orig alt size_bytes; do
    [ -z "$orig" ] && continue
    # 探测目标端是否已出现原名文件（已存在则无需继承）
    local probe exists
    probe=$(timeout 20 rclone lsjson "${dest_path}/${orig}" --max-depth 1 2>/dev/null || echo "[]")
    exists=$(echo "$probe" | jq -r 'length // 0' 2>/dev/null || echo 0)
    [[ "$exists" =~ ^[0-9]+$ ]] || exists=0
    if [ "$exists" -eq 0 ]; then
      carried_entries+=("$idx")
      continue
    fi
    # ===== 已对齐收尾（2026-09-21，治「目标端文件数越堆越多」）=====
    # 原名已落位 ⇒ 替代形态（短哈希名）冗余。此前只剔 marker 记录、不删远端
    # 文件 ⇒ 历史短名孤儿在目标端无限堆积。删除的前提（全部满足才动手）:
    #   ① size 一致（防半截原名冒充落位，丢掉唯一副本）② 非分卷/编码类
    #   （多卷与还原形态复杂，第一版放过）③ 开关未关。
    #   probe 是本循环刚取的新鲜值；删除失败仅警告，不影响剔除语义。
    #   ⚠️ 2026-09-26 起默认**不删**（开关默认 0）: 详见文件头 OPENLIST_CARRY_DELETE_ALIGNED 说明。
    #     该删除与「还原保留备份副本」直接冲突——同步轮 6h 一次，删得比还原还勤。
    [ "${OPENLIST_CARRY_DELETE_ALIGNED:-0}" = "0" ] && continue
    [ -z "$alt" ] || [ "$alt" = "null" ] && continue
    case "$alt" in *.zip.[0-9][0-9][0-9]|*.7z.[0-9][0-9][0-9]|*.enc|*.enc.*|*.b64|*.b64.*) continue ;; esac
    local _alt_norm
    _alt_norm=$(_norm_rel_path "$alt")
    local _dst_size
    _dst_size=$(echo "$probe" | jq -r '.[0].Size // 0' 2>/dev/null || echo 0)
    [[ "$_dst_size" =~ ^[0-9]+$ ]] || _dst_size=0
    [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0
    if [ "$_dst_size" -gt 0 ] && [ "$size_bytes" -gt 0 ] && [ "$_dst_size" = "$size_bytes" ]; then
      if rclone deletefile "${dest_path}/${_alt_norm}" >/dev/null 2>&1; then
        _deleted_n=$((_deleted_n + 1))
        echo "🧹 已对齐收尾: 删除替代形态 ${dest_path}/${_alt_norm}（原名已落位，尺寸 ${_dst_size}B 一致）" >&2
      else
        echo "⚠️ 已对齐收尾: 删除替代形态失败（保留，下轮再试）: ${dest_path}/${_alt_norm}" >&2
      fi
    fi
  done <<< "$tsv"

  local carried_json="[]"
  if [ "${#carried_entries[@]}" -gt 0 ]; then
    # 索引走 --argjson 数字数组（极小）; 大清单 old_fixed_json 本就在 stdin，
    # 不拼进 jq 程序文本——程序文本同受单参数 128KB 上限约束
    local idx_json
    local IFS=,
    idx_json="[${carried_entries[*]}]"
    carried_json=$(echo "$old_fixed_json" | jq -c --argjson idx "$idx_json" '[.[$idx[]]]' 2>/dev/null || echo "[]")
  fi
  jq -cn --argjson c "${carried_json:-[]}" --argjson d "$_deleted_n" '{carried:$c, deleted:$d}' 2>/dev/null || echo '{"carried":[],"deleted":0}'
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
# 条目字段整对象透传（不白名单剥离），可选 md5 字段（原文件内容指纹）随行保留，
# 供 file_restore.sh 还原时做内容级硬校验；旧条目无此字段，读取方以 (.md5 // "") 兼容
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
# 依赖全局变量: GLOBAL_FIXED_FILES_JSON, GLOBAL_FIX_BLACKLIST_JSON（task_engine.sh 顶级初始化）
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
  if [ "$old_fixed_count" -gt 0 ]; then
    local _carry_out2
    _carry_out2=$(_carry_forward_fixed "$dest_path" "$old_marker")
    carried_json=$(echo "$_carry_out2" | jq -c '.carried // []' 2>/dev/null || echo "[]")
  fi
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
# 文件修复方法假成功黑名单 (fix_blacklist): {文件: 方法条目集合}
#   （2026-09-16 起条目为**归一语义 ID**，形如 "copyto_original" 或
#    "copyto_original|zip_split_original"，| 分隔；此前存冗长全名）
#   跨轮失败记忆，下一轮修复时跳过已判定假成功的方法。
#   读取侧 _fix_method_norm 会把新旧两种写法都归一到语义 ID，
#   故历史 marker 条目不会因命名口径变更而失效。
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
    # 病灶 C 修法（§14.21，2026-09-21 接力轮 35629676323 实证）: 游标拒写 ≠ 修复记录作废。
    # 已落盘的 fold/修复产物记录若只留在内存（GLOBAL_FIXED_FILES_JSON），下轮 initial sync
    # 的 filter 保护（marker ∪ 本轮 ∪ 父级守卫）读不到 ⇒ 产物被当「源端不存在的多余文件」
    # 删除 ⇒ 重新折叠/重修（实测: fold 97 → 拒写 → 删 10 + 删目录 → 重 fold 97 → 又拒写）。
    # 大任务（图片 18031 文件）每轮必拒写，其产物在整个追赶期永远裸奔。
    # 此处立即持久化修复记录的理由: sync_task 尾部的 save_fix_state_marker 兜底要等
    # _sync_task_impl 返回才执行，330min step 超时把任务杀在中途时永远轮不到它
    # （两轮生产日志「已保存修复状态」0 次即为实证）。save_fix_state_marker 只合并
    # 保存 fixed_files/fix_blacklist（保留旧 marker 其余字段；无旧 marker 时建不含
    # last_success 的骨架，不会误触发跳过判断），与「本次同步未完成」语义不冲突。
    if ! save_fix_state_marker "$source_path" "$dest_path" "$task_name"; then
      echo "⚠️ 拒写分支的修复记录保存失败（见上方日志）—— 下轮这些产物将无 filter 保护"
    fi
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
      local _carry_out
      _carry_out=$(_carry_forward_fixed "$dest_path" "$old_marker")
      carried_json=$(echo "$_carry_out" | jq -c '.carried // []' 2>/dev/null || echo "[]")
      CARRY_DELETED_N=$(echo "$_carry_out" | jq -r '.deleted // 0' 2>/dev/null || echo 0)
      carried_count=$(echo "$carried_json" | jq 'length' 2>/dev/null || echo 0)
      [[ "$carried_count" =~ ^[0-9]+$ ]] || carried_count=0
      echo "旧标记修复记录: ${old_fixed_count} 条，继承有效 ${carried_count} 条，已对齐自动剔除 $((old_fixed_count - carried_count)) 条"
      [ "${CARRY_DELETED_N:-0}" -gt 0 ] && echo "🧹 已对齐收尾: 共删除冗余替代形态 ${CARRY_DELETED_N} 个（原名已落位，短名孤儿清理）"
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

# ===== marker 打包备份到 Dropbox（外置、只增不删、带保留期）=====
# 为什么需要它（2026-09-19，由「短哈希不可逆」这条性质推导出的单点依赖）:
#   短哈希目录/文件名是 `md5(相对路径)` 前 8 位 —— **单向且截断**，不存在反推路径
#   （见 file_restore.sh 文件头注释）。还原 100% 依赖 marker 的 `original` 字段
#   ⇒ **marker 丢了，短哈希目录里的文件就只剩密文名，无法自愈回原路径**。
#   而 marker 与源端同在 OneDrive（`onedrive:/logs/sync_state`），账号级故障
#   （误删 / 封号 / 回收站清空）会**同时带走数据本体与索引**。
#
# 为什么现成的 `dropbox:sync_state_mirror` **不算**备份:
#   它是 `rclone sync` 镜像 —— **删除会传播**。源端 marker 被删/被清空后，
#   下一轮镜像会同步删掉 Dropbox 上的副本，两边几乎同时丢。
#   镜像解决的是"OneDrive **读不到**"，解决不了"OneDrive 上的数据**没了**"。
#
# 本函数的定位: 追加式的**时间点快照** ——
#   · 每轮产出 `sync_state_<UTC时间戳>.tar.gz`（只读上传，从不 sync/purge）
#   · 另维护一份 `sync_state_latest.tar.gz` 方便直接取用
#   · 按保留期清理**且只清理由本函数命名的过期归档**，绝不整目录操作
#   · 源端读空（列表为空 / 下载后文件数不足）时**拒绝上传**，绝不拿空包覆盖好备份
#     （与 sync_trend.sh「宁丢一条样本，不覆盖历史」同一原则）
#   · 归档内含 `MANIFEST.txt`（时间/来源/文件数），拿到包就能自证完整
#
# 用法: backup_sync_state_to_dropbox [dest_remote]
# 依赖: rclone, tar；SYNC_STATE_DIR 与下列 MARKER_BACKUP_* 可被环境变量覆盖
# 返回: 0 = 已备份；1 = 跳过/失败（调用方应告警，但不应阻断收尾）
MARKER_BACKUP_REMOTE="${MARKER_BACKUP_REMOTE:-dropbox:self-hosted/openlist/sync_state_backup}"
MARKER_BACKUP_KEEP="${MARKER_BACKUP_KEEP:-30}"
MARKER_BACKUP_MIN_FILES="${MARKER_BACKUP_MIN_FILES:-1}"

backup_sync_state_to_dropbox() {
  local dest_remote="${1:-${MARKER_BACKUP_REMOTE}}"
  local state_dir="${SYNC_STATE_DIR:-onedrive:/logs/sync_state}"
  local keep="${MARKER_BACKUP_KEEP:-30}"
  local min_files="${MARKER_BACKUP_MIN_FILES:-1}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=30
  [[ "$min_files" =~ ^[0-9]+$ ]] || min_files=1

  # 判据 1: 远端列表非空 —— 读都读不到时不上传（空包覆盖 = 把好备份变成坏备份）
  local remote_files
  remote_files=$(rclone lsf "$state_dir" --files-only --retries 2 2>/dev/null | grep -c . || true)
  [[ "$remote_files" =~ ^[0-9]+$ ]] || remote_files=0
  if [ "$remote_files" -eq 0 ]; then
    echo "🚨 marker 备份跳过: ${state_dir} 列表为空（读不到 marker），不上传以免覆盖好备份"
    return 1
  fi

  local tmp
  tmp=$(mktemp -d /tmp/marker_backup_XXXXXX) || return 1

  rclone copy "$state_dir" "$tmp/sync_state" \
    --retries 2 --low-level-retries 5 --timeout 10m >/dev/null 2>&1
  local local_n
  local_n=$(find "$tmp/sync_state" -type f 2>/dev/null | wc -l | tr -d ' ')
  [[ "$local_n" =~ ^[0-9]+$ ]] || local_n=0
  # 判据 2: 真下到了文件 —— 列表非空但下载为 0 是另一类读取异常，同样拒上传
  if [ "$local_n" -lt "$min_files" ]; then
    echo "🚨 marker 备份跳过: 下载后仅 ${local_n} 个文件（远端列表 ${remote_files} 个），判定读取异常，不上传"
    rm -rf "$tmp"
    return 1
  fi

  local ts arc
  ts=$(date -u +%Y%m%d-%H%M%S)
  {
    echo "created_utc: ${ts}"
    echo "source: ${state_dir}"
    echo "listed_files: ${remote_files}"
    echo "archived_files: ${local_n}"
    echo "note: ${MARKER_BACKUP_NOTE:-}"
  } > "$tmp/sync_state/MANIFEST.txt"

  arc="$tmp/sync_state_${ts}.tar.gz"
  if ! tar -czf "$arc" -C "$tmp" sync_state 2>/dev/null; then
    echo "🚨 marker 备份失败: tar 打包失败"
    rm -rf "$tmp"
    return 1
  fi

  rclone mkdir "$dest_remote" >/dev/null 2>&1 || true
  # 只增不删: copyto 覆盖同名（同秒重复执行）而不动其余历史归档
  if ! rclone copyto "$arc" "${dest_remote}/sync_state_${ts}.tar.gz" \
       --retries 3 --low-level-retries 5 --timeout 15m >/dev/null 2>&1; then
    echo "🚨 marker 备份失败: 上传 ${dest_remote}/sync_state_${ts}.tar.gz 失败"
    rm -rf "$tmp"
    return 1
  fi
  # latest 只在"本包确实有货"之后才覆盖（上面的两道判据已保证）
  rclone copyto "$arc" "${dest_remote}/sync_state_latest.tar.gz" \
    --retries 3 --low-level-retries 5 --timeout 15m >/dev/null 2>&1 \
    || echo "⚠️ marker 备份: latest 副本更新失败（本期归档 ${ts} 已落盘，不影响可用性）"

  # 保留最近 keep 份: 只删**本函数命名的**过期归档（正则锁定），不整目录 sync/purge
  # 不用 `head -n -N`（GNU-only，macOS 无），改为先数总数再取前 N 条
  local all_dated total
  all_dated=$(rclone lsf "$dest_remote" --files-only --retries 2 2>/dev/null \
    | grep -E '^sync_state_[0-9]{8}-[0-9]{6}\.tar\.gz$' | sort || true)
  total=$(printf '%s\n' "$all_dated" | grep -c . || true)
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  local pruned=0 drop_n dated
  if [ "$total" -gt "$keep" ]; then
    drop_n=$((total - keep))
    while IFS= read -r dated; do
      [ -n "$dated" ] || continue
      rclone deletefile "${dest_remote}/${dated}" \
        --retries 2 --low-level-retries 5 --timeout 5m >/dev/null 2>&1 \
        && pruned=$((pruned + 1))
    done < <(printf '%s\n' "$all_dated" | awk -v n="$drop_n" 'NR<=n')
  fi

  echo "✅ marker 打包备份完成: ${dest_remote}/sync_state_${ts}.tar.gz（${local_n} 个文件，保留 ${keep} 份，清理过期 ${pruned} 份）"
  rm -rf "$tmp"
  return 0
}

# ISO 8601 → epoch 秒（解析失败回退 0，调用方按"未知"处理 = 不跳过）
# GNU date -d 优先（生产 ubuntu runner）；BSD/macOS date -j -f 回退 ——
# 本地调试与单测在 macOS 上同样要能跑通跳过窗口判断
# 用法: _to_epoch <iso8601>
_to_epoch() {
  local ts="${1:-}" e=""
  [ -z "$ts" ] && echo 0 && return 0
  e=$(date -d "$ts" +%s 2>/dev/null) || e=""
  if [ -z "$e" ]; then
    # BSD/macOS: -j 不设置系统时间，-u 按 UTC 解析（marker 的 last_success
    # 由 date -u 生成、带 Z 后缀；不加 -u 会被当本地时间，差一个时区偏移）
    e=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) || e=""
  fi
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  echo "$e"
}

# 只读判断: 任务的同步标记是否仍落在跳过窗口内（不写 marker、不触碰
# MARKER_* 全局状态、不拉 rclone size，供预览阶段预判断"本轮会不会被跳过"）
# 存在意义: 预览 pass 不查 marker，而同步 pass 的跳过判断在任何传输之前，
#   于是带 --Nd-skip 的任务会"预览显示大量待同步、随后一个字节都不传"，
#   看上去像 bug（实际是窗口内的预期行为）。
# 与 check_sync_marker 的窗口判定同口径（last_success + 跳过秒数），但只做
# 窗口比较 —— 完整检查还含源端缩小检测，逐同步对执行代价过高。
# 用法: check_marker_skip_window <task_name> <dest_path> [skip_seconds]
# 输出: 命中时 "last_success<TAB>since_hours"
# 返回: 0 = 命中（本轮预计跳过）; 1 = 未命中（无 marker / 超窗口 / FORCE_SYNC）
check_marker_skip_window() {
  local task_name="$1"
  local dest_path="$2"
  local skip_secs="${3:-${SYNC_SKIP_SECONDS:-86400}}"
  [ "${FORCE_SYNC:-}" = "true" ] && return 1
  [[ "$skip_secs" =~ ^[0-9]+$ ]] || skip_secs="${SYNC_SKIP_SECONDS:-86400}"
  [ "$skip_secs" -le 0 ] && return 1

  local marker_path marker_json last_success now_epoch last_epoch diff
  marker_path=$(get_marker_path "$task_name" "$dest_path")
  marker_json=$(rclone cat "$marker_path" 2>/dev/null) || return 1
  [ -z "$marker_json" ] && return 1
  last_success=$(printf '%s' "$marker_json" | jq -r '.last_success // ""' 2>/dev/null) || return 1
  case "$last_success" in "" | null) return 1 ;; esac

  last_epoch=$(_to_epoch "$last_success")
  [ "$last_epoch" -le 0 ] && return 1
  now_epoch=$(date +%s)
  diff=$((now_epoch - last_epoch))
  # 时钟回拨（diff<0）与超窗口一样视为未命中，不做跳过推断
  if [ "$diff" -lt 0 ] || [ "$diff" -ge "$skip_secs" ]; then
    return 1
  fi
  printf '%s\t%s\n' "$last_success" "$((diff / 3600))"
  return 0
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
  last_epoch=$(_to_epoch "$last_success")

  if [ "$last_epoch" -gt 0 ]; then
    diff=$((now_epoch - last_epoch))
    # 时钟回拨防护: diff 为负（runner 时钟早于 last_success，或 marker 时间
    # 写入自未来）不得落入"窗口内"分支误跳过——与 check_marker_skip_window
    # 的 _diff<0 口径对齐（负 diff = 未命中窗口 = 继续同步）
    [ "$diff" -lt 0 ] && diff=$SYNC_SKIP_SECONDS
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
  # 列举失败 ≠ 数据缩小: rclone size 瞬时失败（网盘限流/驱动抖动）回退 0 会
  # 把 0 < marker_bytes 误判成"源端大小减小"，发失真告警并跳过同步，且持续
  # 失败时任务长期静默停摆。无法判定时放行同步（fail-open），由缩小检测的
  # 本意——真实数据丢失——之外的机制兜底。
  if [ -z "$current_size_json" ]; then
    echo "⚠️ 无法获取源端统计（rclone size 失败），跳过缩小检测并放行同步（不把列举失败当数据缩小误报）"
    MARKER_ACTION="proceed"
    return 0
  fi
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
    # 列表分节带计数（规范 · 分节：凡分节后跟条目列表必须 · N）+ 统一树形（规范 · 条目与树形，
    # 不再 "• "）+ 超 8 条折叠（规范 · 折叠规则，此前裸用 tree_lines 不折叠）。
    # 说明性文字不再与计数并列写进标题（此前 "📁 缺失的目录 · 可能被删除 · N" 会被
    # 读成两个计数），下沉为独立说明段（规范 · 说明段）。
    tg_add_section msg "📁 缺失的目录 · $(printf '%s' "$missing_dirs" | grep -c .)"
    _dirs_html=""
    while IFS= read -r d; do
      [ -n "$d" ] && tg_add_entry _dirs_html "$d"
    done <<< "$missing_dirs"
    tg_append msg "$(tree_fold "${_dirs_html%$'\n'}")"$'\n'
    tg_add_note msg "源端已不存在，可能是被删除。"
  fi

  if [ -n "$new_dirs" ]; then
    tg_add_section msg "📁 新增的目录 · $(printf '%s' "$new_dirs" | grep -c .)"
    _dirs_html=""
    while IFS= read -r d; do
      [ -n "$d" ] && tg_add_entry _dirs_html "$d"
    done <<< "$new_dirs"
    tg_append msg "$(tree_fold "${_dirs_html%$'\n'}")"$'\n'
  fi

  # 收尾区: 状态 + 备注（裸文本说明段），footer 自带空行。
  # 注意: tg_add_note 对整段做 escape_html，段内不能携带 HTML 标签——
  # emoji 只能随段裸置（转义边界决定的既定形态，勿套任何标签）
  tg_add_note msg "⏭️ 已跳过此同步，继续执行其他任务
如确认无误，请手动触发 force_sync=true"
  tg_add_footer msg

  send_telegram_message "$msg"
}

# 发送"近期已成功同步，本次跳过"的通知
# 额外展示"本次未传"量: 跳过只是窗口内的省流策略，源端与目标端的差异
#   依然存在（预览里算出的 +X GiB 就是它）。不写明这个量，"有待同步
#   却被跳过"在复盘时反复被当成故障排查。
#   数值优先复用预览 pass 已算好的同口径结果（零成本），未命中（auto-split
#   子任务没有独立预览条目）时现场估算；估算不可靠则整段不展示（宁缺毋滥）
# 依赖全局变量: MARKER_LAST_SUCCESS, MARKER_SINCE_HOURS, MARKER_JSON
# 用法: send_sync_skipped <task_name> <source_path> <dest_path> [rclone_extra_args...]
send_sync_skipped() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"
  shift 3

  local marker_bytes marker_count
  marker_bytes=$(echo "$MARKER_JSON" | jq -r '.source_bytes // 0' 2>/dev/null || echo 0)
  marker_count=$(echo "$MARKER_JSON" | jq -r '.source_count // 0' 2>/dev/null || echo 0)

  # 已修复文件信息（通过缺失文件修复机制以非原名上传的文件）
  local fixed_count fixed_bytes
  fixed_count=$(echo "$MARKER_JSON" | jq -r '.fixed_count // 0' 2>/dev/null || echo 0)
  fixed_bytes=$(echo "$MARKER_JSON" | jq -r '.fixed_bytes // 0' 2>/dev/null || echo 0)

  local msg=""
  # 跳过窗口由任务开关决定（--1d-skip=24h / --2d-skip=48h / ...）；
  # 标题只放 emoji+短语，动态细节下沉 kv 行
  local skip_window_hours=$((SYNC_SKIP_SECONDS / 3600))
  tg_add_title msg "⏭️ 同步任务跳过"
  tg_add_kv msg "任务" "$task_name"
  # 值只写时长，"已成功"由标签「跳过窗口」表达（值不重复标签语义）
  tg_add_kv msg "跳过窗口" "${skip_window_hours} 小时内"
  tg_add_path msg "源端" "$source_path"
  tg_add_path msg "目标" "$dest_path"
  tg_add_section msg "🕒 上次同步"
  # ISO 原始戳人性化（2026-09-05T11:34:19Z → 2026-09-05 11:34 UTC），
  # 解析失败保留原值；"距今"并作同行的 " · N 小时前"，少一行 kv
  local _last_fmt
  _last_fmt=$(date -u -d "${MARKER_LAST_SUCCESS}" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "${MARKER_LAST_SUCCESS}")
  tg_add_kv msg "时间" "${_last_fmt} · ${MARKER_SINCE_HOURS} 小时前"
  tg_add_kv msg "记录大小" "$(format_bytes "$marker_bytes") · ${marker_count} 文件"
  if [ "${fixed_count:-0}" -gt 0 ]; then
    tg_add_kv msg "已修复文件" "${fixed_count} 个 · $(format_bytes "$fixed_bytes") · 以非原名存在于目标端"
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
      # 计数取自 method_summary 行数（_m_entries 数组在下方才声明，此处引用会 unbound）
      tg_add_section msg "🔧 修复方式构成 · $(printf '%s' "$method_summary" | grep -c .)"
      # 树形条目（├─/└─）: 方式 × 数量 · 大小，summary 缩进为子行；
      # restore.kind 英文 token 映射中文标签（规范 · 失败与异常：英文原因 token 不得直出通知）
      local -a _m_entries=() _m_summaries=()
      local _m_kind_label
      while IFS=$'\t' read -r m_kind m_count m_bytes m_summary; do
        [ -z "$m_kind" ] && continue
        case "$m_kind" in
          split_zip)          _m_kind_label="分包上传";;
          hash_dir)           _m_kind_label="哈希目录还原";;
          short_hash_rename)  _m_kind_label="短哈希改名";;
          base64url_dir)      _m_kind_label="base64url 目录还原";;
          copy)               _m_kind_label="直接复制";;
          *)                  _m_kind_label="$m_kind";;
        esac
        # 条目行统一走 tg_entry_text（文字主体 + 元数据 " · " 分隔、统一转义）
        _m_entries+=("$(tg_entry_text "$_m_kind_label" "${m_count} 个" "$(format_bytes "$m_bytes")")")
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
  fi

  # 本次未传量（--size-only 口径的差异，即预览里那个 +X GiB）
  local _pending _p_bytes _p_count
  _pending=$(_lookup_skipped_pending "$task_name" "$dest_path" "$source_path" "$@" 2>/dev/null) || _pending=""
  if [ -n "$_pending" ]; then
    _p_bytes="${_pending%% *}"
    _p_count="${_pending##* }"
    if [[ "$_p_bytes" =~ ^[0-9]+$ ]] && [[ "$_p_count" =~ ^[0-9]+$ ]] \
       && { [ "$_p_bytes" -gt 0 ] || [ "$_p_count" -gt 0 ]; }; then
      tg_add_section msg "📦 本次未传"
      # 取值行走 tg_add_kv（规范 · kv 行），解释性文字另起说明段（规范 · 说明段）——
      # 此前两者挤在一行，且没走助手
      tg_add_kv msg "未传量" "$(format_bytes "$_p_bytes") / ${_p_count} 文件"
      tg_add_note msg "两端仍存在差异，因落在跳过窗口内未传，非故障"
    fi
  fi

  # 收尾区: 🛠️ 复制即用（规范 · 取值行口径）—— 给人可复制执行的 gh 命令（pre 不折行、
  # 整块复制），替代原「还原脚本：<marker JSON 路径> + 字段指引」（数据文件路径
  # 对人没有动作）。restore_task 按 marker 文件名首个 _ 前缀精确匹配
  # （file_restore.sh restore_fixed_files），填完整任务名匹配不到；
  # force_sync 作用于全部任务（无单任务参数），需注明"全量"。
  tg_add_section msg "🛠️ 复制即用"
  tg_add_note msg "▸ 强制同步（全量，含本任务）"
  tg_add_pre msg 'gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true'
  if [ "${fixed_count:-0}" -gt 0 ]; then
    tg_add_note msg "▸ 还原 ${fixed_count} 个非原名文件（restore_task=${task_name%%_*}）"
    tg_add_pre msg "gh workflow run openlist.yml \\
  -f run_mode='⚠️ 还原 · 修复文件还原为原路径' \\
  -f restore_task=${task_name%%_*}"
  fi
  tg_add_note msg "⏭️ 本次跳过同步，继续执行其他任务"
  tg_add_footer msg

  send_telegram_message "$msg"
}
