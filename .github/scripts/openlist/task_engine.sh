#!/bin/bash
# ===== OpenList 同步工具 — 任务编排函数 =====
# 提供 sync_task 用户接口函数，
# 支持:
#   --auto-split  — 源端 > 50GB 时按一级子目录自动分批（阈值 SYNC_SPLIT_THRESHOLD_BYTES 可调）
#                   注: 这是"任务级分批"，与 file_split.sh 的"文件级分割"（把单个
#                   大文件切成多段）无关，两者维度不同（任务 vs 文件）。
#                   SYNC_SPLIT_* 系历史命名，因属用户可配环境变量故保留不改。
#   --1d-skip     — 1 天内已成功同步则跳过；--Nd-skip 任意天数（如 --2d-skip / --3d-skip）
#   其余参数（如 --exclude）原样传给 rclone
#
# 依赖: sync_engine.sh, file_split.sh, sync_marker.sh, task_preview.sh, sync_progress.sh, file_fix.sh
# 依赖环境变量:
#   RCLONE_SYNC_TASK_FLAGS          — sync_task 特有 rclone 参数（在 rclone_flags.sh 中定义；
#                                     已移除全部 --delete-*，目标端只增不减）
#   SYNC_SPLIT_THRESHOLD_BYTES      — auto-split 阈值（默认 50GB）
#   OPENLIST_TASK_ROTATION          — 同步对轮转开关（=0 关闭，见下方说明）
#   ROTATION_MAX_CONSECUTIVE_ATTEMPTS — 轮转阀门上限（默认 8）
#   OPENLIST_FIX_TEST_MODE / OPENLIST_MISSING_FIX_MAX / OPENLIST_BATCH_CONSOLIDATE 等
#   TASK_PREVIEW_ONLY / TASK_REGISTER_ONLY — 预览/仅注册 pass 标记（由 workflow 设置）

# 常量定义
readonly DEFAULT_SPLIT_THRESHOLD_BYTES="${SYNC_SPLIT_THRESHOLD_BYTES:-50000000000}" # 50GB 自动拆分阈值

# ===== 同步任务清单（单点定义，增减任务只需在此添加/删除一行）=====
# 格式: "id|源端|目标端|任务名|附加参数"
#   id:       调试模式（run_task_by_id）的选择器，无需单独调试的任务填 "-"
#   附加参数: --auto-split / --1d-skip / --exclude 等，原样透传给 sync_task
# 所有任务统一 sync_task（rclone sync，删除目标端多余文件）:
#   - --delete-before 等由 RCLONE_SYNC_TASK_FLAGS 自动追加
#   - 已修复文件（original/alternative）由 sync_engine.sh 的 filter-from 排除，
#     排除 = 不传输 + 不删除，sync 模式下不会被误删
SYNC_TASK_REGISTRY=(
  "backup-aliyundrive|onedrive:backup|openlist:aliyundriveCrypt/backup|backup|--auto-split --1d-skip --exclude /notion/** --exclude notion/** --exclude /self-hosted_latest.tar.gz --exclude self-hosted_latest.tar.gz --exclude /github_repos_latest.tar.gz --exclude github_repos_latest.tar.gz"
  "backup|onedrive:backup|openlist:wopan176Crypt/backup|backup|--auto-split --1d-skip"
  # "backup-gd|onedrive:backup|gd:backup|backup|--1d-skip"

  "task0|onedrive:0|openlist:wopan176Crypt/0|task0|--auto-split --1d-skip"
  "task0-baidupan|onedrive:0|openlist:baidupanCrypt/0|task0|--auto-split --1d-skip"
  "task0-wopan175|onedrive:0/j-1024j-视频-pornhub-favorites|openlist:wopan175/0/j-1024j-视频-pornhub-favorites|task0|--auto-split --1d-skip"
  # "task0-gd|onedrive:0|gd:0|task0|--1d-skip"

  "task1|onedrive:1|openlist:wopan176Crypt/1|task1|--auto-split --1d-skip"
  "task1-baidupan|onedrive:1|openlist:baidupanCrypt/1|task1|--auto-split --1d-skip"
  "task1-wopan175|onedrive:1|openlist:wopan175/1|task1|--auto-split --1d-skip"
  # "task1-gd|onedrive:1|gd:1|task1|--1d-skip"

  "task2|onedrive:2|openlist:wopan176Crypt/2|task2|--auto-split --1d-skip"
  "task2-wopan175|onedrive:2|openlist:wopan175/2|task2|--auto-split --1d-skip"
  # "task2-gd|onedrive:2|gd:2|task2|--1d-skip"

  "task3|onedrive:3|openlist:wopan176Crypt/3|task3|--auto-split --1d-skip"
  "task3-wopan175|onedrive:3|openlist:wopan175/3|task3|--auto-split --1d-skip"
  # "task3-gd|onedrive:3|gd:3|task3|--1d-skip"

  "task4|onedrive:4|openlist:wopan176Crypt/4|task4|--auto-split --1d-skip"
  "task4-wopan175|onedrive:4|openlist:wopan175/4|task4|--auto-split --1d-skip"

  "task5|onedrive:5|openlist:wopan176Crypt/5|task5|--auto-split --1d-skip"
  "task5-wopan175|onedrive:5|openlist:wopan175/5|task5|--auto-split --1d-skip"
)

# 执行清单中的一条任务（供 run_all_tasks / run_task_by_id 复用）
_run_registry_entry() {
  local _e="$1"
  local _id _src _dst _name _flags
  local -a _flag_arr
  IFS='|' read -r _id _src _dst _name _flags <<< "$_e"
  read -ra _flag_arr <<< "$_flags"
  sync_task "$_src" "$_dst" "$_name" "${_flag_arr[@]}"
}

# ===== 同步对轮转（防饿死）=====
# 问题: run_all_tasks 按清单固定顺序执行，排在前面的大同步对（如 task0 的
#       wopan176Crypt/0，200GB+）常态吃满 6h job 上限，后面的同步对
#       （baidupanCrypt/0、wopan175/...）永远轮不到 —— 预览差值长期不动。
# 方案: 游标持久化在 sync_state 目录（onedrive），语义 = "下一个待执行的同步对":
#   - 每个 run 从游标位置开始按序执行，绕一圈回到开头
#   - 同步对执行前先落盘 attempts+1 —— run 被取消（6h 上限）时游标已指向
#     该同步对，下轮从它继续（配合批次级巩固 _batch_consolidate，已落盘
#     进度不丢，续传即可）
#   - 同步对完成/被跳过标记跳过 → 游标后移一位，attempts 清零
#   - 同步对失败（run 未被取消）→ 继续执行后续同步对（不堵队列），失败者
#     下个循环回来重试
#   - 阀门: 游标指向的同步对连续尝试（含被取消）超过上限仍未完成 → 强制
#     后移一轮（防病态同步对把"取消-重试"变成死循环，永久堵死队列）
#   - 预览/仅注册 pass 按同一顺序执行但只读不写（游标不被预览推进）
# 开关: OPENLIST_TASK_ROTATION=0 关闭（回退清单固定顺序）
ROTATION_MAX_CONSECUTIVE_ATTEMPTS="${ROTATION_MAX_CONSECUTIVE_ATTEMPTS:-8}"

_rotation_state_path() {
  echo "${SYNC_STATE_DIR}/task_rotation.json"
}

# 读取游标 → 全局 ROTATION_CURSOR / ROTATION_ATTEMPTS（读取失败回退 0）
_rotation_load() {
  ROTATION_CURSOR=0
  ROTATION_ATTEMPTS=0
  local n=${#SYNC_TASK_REGISTRY[@]}
  [ "$n" -eq 0 ] && return 0
  local json cursor attempts
  json=$(rclone cat "$(_rotation_state_path)" 2>/dev/null) || true
  cursor=$(echo "$json" | jq -r '.cursor // 0' 2>/dev/null)
  attempts=$(echo "$json" | jq -r '.attempts // 0' 2>/dev/null)
  [[ "$cursor" =~ ^[0-9]+$ ]] || cursor=0
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
  [ "$cursor" -ge "$n" ] && cursor=0
  ROTATION_CURSOR=$cursor
  ROTATION_ATTEMPTS=$attempts
}

# 写游标（_marker_write 负责校验与 pretty-print；失败静默保留旧值，不影响同步）
_rotation_save() {
  local cursor="$1" attempts="$2"
  local json
  json=$(jq -cn --argjson c "$cursor" --argjson a "$attempts" \
    --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{cursor:$c, attempts:$a, updated:$u}' 2>/dev/null) || return 0
  _marker_write "$json" "$(_rotation_state_path)" >/dev/null 2>&1 || true
}

# ===== 优雅到站（P2）: 时间预算将尽时不再开新工作 =====
# 背景: 大任务常态撞 6h runner 上限被硬杀——收尾/Persist 虽是 always() 会跑，
# 但 run 以 cancelled 收场、在途批次通知统计被截断。改为: 同步 step 启动时
# 设定预算锚点 OPENLIST_SYNC_DEADLINE_EPOCH（step 时刻 + BUDGET_SECONDS），
# 剩余预算不足"一个最小工作片"时不再启动新的同步对/子目录/最终完整同步，
# 当前工作做完即正常退出 → run 以 success 收场，接力 step 立即触发下轮。
# 预算未设置（调试/还原模式）→ 永不触发停止。
OPENLIST_SYNC_BUDGET_SECONDS="${OPENLIST_SYNC_BUDGET_SECONDS:-19200}"      # 320min
OPENLIST_SYNC_MIN_SLICE_SECONDS="${OPENLIST_SYNC_MIN_SLICE_SECONDS:-600}"  # 10min
sync_budget_stop() {
  [ -n "${OPENLIST_SYNC_DEADLINE_EPOCH:-}" ] || return 1
  [ $(( $(date +%s) + OPENLIST_SYNC_MIN_SLICE_SECONDS )) -ge "$OPENLIST_SYNC_DEADLINE_EPOCH" ]
}

# 顺序执行清单中的全部任务（支持同步对轮转，防饿死，见上方说明）
run_all_tasks() {
  local n=${#SYNC_TASK_REGISTRY[@]}
  [ "$n" -eq 0 ] && return 0

  local rotation_enabled=1
  [ "${OPENLIST_TASK_ROTATION:-1}" = "0" ] && rotation_enabled=0

  local start=0
  if [ "$rotation_enabled" -eq 1 ]; then
    _rotation_load
    start=$ROTATION_CURSOR
    # 阀门（取消死循环保护）: 游标同步对连续尝试超上限仍未完成 → 本轮从
    # 下一个开始，给后面的同步对让路；它会在下个循环回来被重试
    if [ "$ROTATION_ATTEMPTS" -ge "$ROTATION_MAX_CONSECUTIVE_ATTEMPTS" ]; then
      echo "⚠️ 同步对轮转: 第 $((start + 1))/${n} 个同步对已连续尝试 ${ROTATION_ATTEMPTS} 次未完成，本轮跳过它从第 $(( (start + 1) % n + 1 )) 个开始（下个循环回来重试）"
      start=$(( (start + 1) % n ))
      _rotation_save "$start" 0
    else
      echo "同步对轮转: 本轮从第 $((start + 1))/${n} 个同步对开始（已连续尝试 ${ROTATION_ATTEMPTS} 次）"
    fi
  fi

  # 预览/仅注册 pass 不写游标（顺序与正式执行一致）
  local real_pass=1
  [ -n "${TASK_PREVIEW_ONLY:-}" ] && real_pass=0
  [ "${TASK_REGISTER_ONLY:-0}" = "1" ] && real_pass=0

  local i idx _e
  local _rot_attempts="${ROTATION_ATTEMPTS:-0}"
  for ((i = 0; i < n; i++)); do
    idx=$(( (start + i) % n ))
    _e="${SYNC_TASK_REGISTRY[$idx]}"
    # P2 优雅到站: 剩余预算不足一个最小工作片时不再开新同步对。
    # 游标停在上一个已完成同步对（本轮已推进），剩余任务由下轮接力
    if [ "$real_pass" -eq 1 ] && sync_budget_stop; then
      echo "⏳ 时间预算将尽，优雅收摊: 剩余 $((n - i)) 个同步对留给下轮接力（游标已指向下一个待重试同步对）"
      SYNC_TIME_EXHAUSTED=1
      break
    fi
    # 非起点同步对在本 run 内是首次尝试（连续尝试数从 1 重新计）
    [ "$i" -gt 0 ] && _rot_attempts=0

    if [ "$rotation_enabled" -eq 1 ] && [ "$real_pass" -eq 1 ]; then
      # 执行前先落盘"正在尝试第 idx 个（第 N 次）"—— run 在执行中被取消时
      # 游标已指向该同步对，下轮继续；连续尝试数也因此能跨取消累计
      _rot_attempts=$((_rot_attempts + 1))
      _rotation_save "$idx" "$_rot_attempts"
    fi

    if [ "$real_pass" -eq 0 ]; then
      local _hb_src _hb_dst
      IFS='|' read -r _ _hb_src _hb_dst _ _ <<< "$_e"
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] 注册进度: $((i + 1))/${n} ${_hb_src} → ${_hb_dst}"
    fi

    # 每个同步对开始前置位重置: 由 sync_engine 在"后端级熔断"时置 1
    SYNC_BACKEND_DEAD=0
    _run_registry_entry "$_e" || true

    if [ "$real_pass" -eq 0 ]; then
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] 注册完成: $((i + 1))/${n} ${_hb_src} → ${_hb_dst}"
    fi

    if [ "$rotation_enabled" -eq 1 ] && [ "$real_pass" -eq 1 ]; then
      if [ "${SYNC_SKIPPED:-0}" = "1" ] || [ "${SYNC_FAILED:-0}" = "0" ]; then
        # 完成/跳过 → 游标后移，连续尝试数清零
        _rotation_save "$(( (idx + 1) % n ))" 0
        _rot_attempts=0
      elif [ "${SYNC_BACKEND_DEAD:-0}" = "1" ]; then
        # 后端级熔断（写探针/读探针判定该后端本轮不可用）: 不必等满
        # ROTATION_MAX_CONSECUTIVE_ATTEMPTS 次——死后端重试多少次都一样，
        # 立即让路，把剩余预算交给健康后端（run #12615/#12616 连续两轮
        # 烧在同一个 wopan175 同步对上，各 5h 零产出）
        echo "⚠️ 同步对轮转: 第 $((idx + 1))/${n} 个同步对所属后端本轮已判不可用，立即后移游标（把剩余时间让给健康后端，下个循环再试它）"
        _rotation_save "$(( (idx + 1) % n ))" 0
        _rot_attempts=0
      elif [ "$_rot_attempts" -ge "$ROTATION_MAX_CONSECUTIVE_ATTEMPTS" ]; then
        # 阀门（失败路径）: 连续失败/取消超上限 → 后移让路（下个循环回来重试）
        echo "⚠️ 同步对轮转: 第 $((idx + 1))/${n} 个同步对已连续尝试 ${_rot_attempts} 次未完成，强制后移游标（下个循环回来重试）"
        _rotation_save "$(( (idx + 1) % n ))" 0
        _rot_attempts=0
      fi
      # 失败但未到阀门: 游标停留在当前同步对 —— 若后续同步对继续执行，其
      # 执行前落盘会推进游标；若 run 到此结束/被取消，下轮优先重试本同步对
    fi
  done
}

# 按 id 执行清单中的单条任务（调试模式专用）
run_task_by_id() {
  local _want="$1" _e _id
  local -a _ids=()
  for _e in "${SYNC_TASK_REGISTRY[@]}"; do
    _id="${_e%%|*}"
    _ids+=("$_id")
    [ "$_id" = "$_want" ] || continue
    _run_registry_entry "$_e"
    return $?
  done
  echo "未知任务: ${_want}（可用 id: $(IFS='、'; echo "${_ids[*]}")）"
  return 1
}

# 从 task_name 和 dest_path 派生唯一 task_id（用于进度跟踪）
# 例: _derive_task_id "task0" "openlist:wopan176Crypt/0" → "task0_wopan176Crypt"
_derive_task_id() {
  local task_name="$1"
  local dest_path="$2"
  local dest_clean="${dest_path#*:}"
  local first_component="${dest_clean%%/*}"
  [ -z "$first_component" ] && first_component="${dest_clean}"
  [ -z "$first_component" ] && first_component="dest"
  echo "${task_name}_${first_component}"
}

# 预览/仅注册模式：注册任务到进度系统（不实际同步）
#   TASK_PREVIEW_ONLY=1  — 注册 + 发送预览通知
#   TASK_REGISTER_ONLY=1 — 仅注册（skip_preview=true 时使用，保证进度消息
#                          "总任务"从一开始就是全量，而非随 progress_task_begin 逐个增长）
_preview_register() {
  local task_name="$1"
  local source_path="$2"
  local dest_path="$3"
  shift 3
  local extra_args=("$@")

  if [ "${TASK_REGISTER_ONLY:-0}" != "1" ]; then
    PREVIEW_TASK_NAME="$task_name"
    add_preview_pair "$source_path" "$dest_path" "${extra_args[@]}"
  fi

  # 注册到进度系统（pending 状态）
  # 显示名: 源端 → 目标端完整路径；附源端大小提示（add_preview_pair 刚算过，缓存命中）
  local _task_id _src_bytes _size_hint
  _task_id=$(_derive_task_id "$task_name" "$dest_path")
  _src_bytes=$(_get_source_size_with_excludes "$source_path" "${extra_args[@]}" | awk '{print $1}')
  _size_hint=""
  [[ "$_src_bytes" =~ ^[0-9]+$ ]] && [ "$_src_bytes" -gt 0 ] && _size_hint=$(format_bytes "$_src_bytes")
  progress_register_task "$_task_id" "${source_path} → ${dest_path}" "$_size_hint"
}

# 渲染子目录阶段树原始行（多行、不带连接符——├─/└─ 由进度渲染器统一补，
# 多层级嵌套时各层分别加连接符才能对齐）
# 依赖调用方（_sync_task_impl）作用域内的变量（bash 动态作用域可见）:
#   subdirs（排序后的子目录列表）/ subdir_size_map / subdir_status_map
# 输出格式（状态由 emoji 表达，不重复文字说明，紧凑单行）:
#   ✅ a · 4 GiB
#   🔄 b · 17 GiB
# 不再带 "📁 源端 X" 首行: 源端大小已由进度消息的任务分组头
# （"📁 onedrive:0 · 280.790 GiB"）给出，重复一遍只占一行；
# 且它不带状态 emoji，与本层统计行（▸ 📊 子目录：x/y）同为表头，
# 会让紧随其后的子目录行看起来与它是同级而非从属。
_render_subdir_phase_tree() {
  local _tree="" _name _mark
  while IFS= read -r _name; do
    [ -z "$_name" ] && continue
    case "${subdir_status_map[$_name]:-pending}" in
      synced)  _mark="✅" ;;
      skipped) _mark="⏭️" ;;
      partial) _mark="⚠️" ;;
      failed)  _mark="❌" ;;
      syncing) _mark="🔄" ;;
      *)       _mark="⏳" ;;
    esac
    _tree+="${_mark} $(escape_html "$_name") · $(format_bytes "${subdir_size_map[$_name]:-0}")"$'\n'
  done <<< "$subdirs"
  printf '%s' "${_tree%$'\n'}"
}

# 任务收尾：成功且启用 skip 时写跳过标记；顶级调用失败时切割大文件
# 依赖调用方（_sync_task_impl）作用域内的变量（bash 动态作用域可见）:
#   source_path / dest_path / task_name / extra_args / current_depth
_sync_task_finalize() {
  local _rc="$1"
  # P0 趋势: 记录本次实际净传字节。仅"本调用内 sync_with_logging 真正
  # 执行过"的直接同步路径会走到这里（预览/跳过/子目录聚合不经过此函数
  # 或不计入），各调用相加即本轮真实净传，无重复计数（另一记录点:
  # _sync_task_impl 顶层的最终完整同步尾部）
  if [ "${SYNC_SKIPPED:-0}" != "1" ]; then
    trend_record_transferred "${SYNC_TRANSFERRED_BYTES:-0}"
  fi
  if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  elif [ "$current_depth" -eq 0 ]; then
    split_on_sync_failure "$source_path" "$task_name"
  fi
  return "$_rc"
}

# ===== 并行子目录同步（可选: OPENLIST_SUBDIR_PARALLEL>=2 且 depth=0 启用）=====
# 设计（与串行路径语义对齐，默认关闭 = 行为不变）:
#   - worker = 子 shell 跑 _sync_task_impl（递归深度+1，内部仍串行），结果经
#     .done 文件回传父级（subdir/status/transferred/修复累计器 base64）
#   - worker 全程 PROGRESS_WORKER_MUTE=1: 深度槽位是跨 worker 共享文件，
#     worker 互清/互写会打碎父级渲染 —— 子目录树由父进程按完成事件统一渲染
#   - marker 按子目录各自落盘（文件互不相干，天然并行安全）；worker 的修复
#     累计器（GLOBAL_FIXED_FILES_JSON 数组 / GLOBAL_FIX_BLACKLIST_JSON 对象）
#     回传父级合并，保证顶层 marker 的 fixed_files/fix_blacklist 完整性
#   - 传输持容器共享锁、truth-check 容器重启持独占锁（openlist_driver.sh
#     读写锁）→ 重启只发生在无 worker 在途传输时
#   - reap 用"结果文件为准 + kill -0 存活探测"轮询（wait -n -p 对被信号
#     杀死的子进程不回填 pid 变量，实测 rc=127，故弃用），无版本要求
# ⚠️ 并行会把对同一后端的并发 PUT 数翻倍，与 run 32749862280 整批假成功
#   事故的规避方向相悖（transfers=1 的保守性被部分放弃）。启用前先用调试
#   模式单任务观察一轮 "object not found" 率与修复管线触发量。
_sync_par_render() {
  # 依赖调用方（_sync_task_impl）作用域: subdirs / subdir_status_map /
  # subdir_size_map / total_subdirs_count / 各分类计数（bash 动态作用域）
  PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
  local _completed=$((synced_subtasks + skipped_subtasks + failed_subtasks))
  # 分隔符与同文件另外两处统计行、以及 sync_progress.sh 顶部注释的面板契约一致：
  # 「X/Y 完成 | 状态计数」（| 分隔进度与计数两段，计数内部用空格）
  progress_update_force "" "▸ 📊 子目录：${_completed}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⏳$((total_subdirs_count - _completed)) ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
  return 0
}

_sync_par_consume() {
  # 消费一个 worker 结果文件并按串行同款口径分类
  local _f="$1" _subdir _st _tr _fb _bb _fj _bj
  _subdir=$(sed -n 's/^subdir=//p' "$_f" | head -1)
  _st=$(sed -n 's/^status=//p' "$_f" | head -1)
  _tr=$(sed -n 's/^transferred=//p' "$_f" | head -1)
  _fb=$(sed -n 's/^fixed_b64=//p' "$_f" | head -1)
  _bb=$(sed -n 's/^blacklist_b64=//p' "$_f" | head -1)
  [[ "$_tr" =~ ^[0-9]+$ ]] || _tr=0
  rm -f "$_f"
  case "$_st" in
    skipped)
      skipped_subtasks=$((skipped_subtasks + 1))
      subdir_status_map["$_subdir"]="skipped"
      tg_add_entry skipped_list "$_subdir" "$(format_bytes "${subdir_size_map[$_subdir]:-0}")"
      ;;
    synced)
      synced_subtasks=$((synced_subtasks + 1))
      subdir_status_map["$_subdir"]="synced"
      total_transferred=$((total_transferred + _tr))
      tg_add_entry synced_list "$_subdir" "$(format_bytes "${subdir_size_map[$_subdir]:-0}")"
      ;;
    partial)
      partial_subtasks=$((partial_subtasks + 1))
      failed_subtasks=$((failed_subtasks + 1))
      subdir_status_map["$_subdir"]="partial"
      total_transferred=$((total_transferred + _tr))
      tg_add_entry failed_list "$_subdir" "$(format_bytes "${subdir_size_map[$_subdir]:-0}")" "部分失败"
      ;;
    *)
      failed_subtasks=$((failed_subtasks + 1))
      subdir_status_map["$_subdir"]="failed"
      tg_add_entry failed_list "$_subdir" "$(format_bytes "${subdir_size_map[$_subdir]:-0}")"
      ;;
  esac
  # 修复累计器合并: fixed_files 是数组（拼接），fix_blacklist 是对象
  # （方法级失败记忆，用 _marker_merge_json 与 save_sync_marker 同口径合并）
  _fj=$(printf '%s' "$_fb" | base64 -d 2>/dev/null || echo "")
  _bj=$(printf '%s' "$_bb" | base64 -d 2>/dev/null || echo "")
  if [ -n "$_fj" ] && [ "$_fj" != "[]" ]; then
    GLOBAL_FIXED_FILES_JSON=$(printf '%s\n%s' "${GLOBAL_FIXED_FILES_JSON:-[]}" "$_fj" | jq -sc 'add' 2>/dev/null) \
      || GLOBAL_FIXED_FILES_JSON="${GLOBAL_FIXED_FILES_JSON:-[]}"
  fi
  if [ -n "$_bj" ] && [ "$_bj" != "{}" ]; then
    GLOBAL_FIX_BLACKLIST_JSON=$(_marker_merge_json "${GLOBAL_FIX_BLACKLIST_JSON:-}" "$_bj" 2>/dev/null) \
      || GLOBAL_FIX_BLACKLIST_JSON="${GLOBAL_FIX_BLACKLIST_JSON:-}"
  fi
  _sync_par_render
  return 0
}

_sync_par_reap_one() {
  # 等待并收割任意一个完成的 worker（阻塞，每 2s 轮询——对分钟级同步开销
  # 可忽略）。依赖调用方（_sync_subdirs_parallel_run）作用域:
  #   _par_dir / _w_subdir[idx]=子目录 / _w_pid[idx]=worker pid
  # 为什么不用 wait -n -p 归因: 子进程被 SIGKILL 等信号杀死时实测不回填
  # pid 变量（rc=127，dbg 复现），归因会落空 → 改为"结果文件为准 +
  # kill -0 存活探测": 有 .done 即正常收；无 .done 但进程已死即崩溃兜底
  local _par_dir="$1" _tries=0 _idx _pid _sub _f
  while :; do
    _tries=$((_tries + 1))
    for _idx in "${!_w_subdir[@]}"; do
      _pid=${_w_pid[$_idx]:-}
      _sub=${_w_subdir[$_idx]:-}
      _f="$_par_dir/$_idx.done"
      if [ -f "$_f" ]; then
        # 正常完成: 回收 zombie 后消费结果
        [ -n "$_pid" ] && wait "$_pid" 2>/dev/null || true
        unset '_w_subdir[$_idx]' '_w_pid[$_idx]'
        _sync_par_consume "$_f"
        return 0
      fi
      if [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; then
        # 崩溃且无结果文件: 按失败分类保持统计一致，marker 未落盘，
        # 下轮 run 自动重试
        wait "$_pid" 2>/dev/null || true
        unset '_w_subdir[$_idx]' '_w_pid[$_idx]'
        echo "⚠️ 并行子目录 worker 异常退出（无结果文件），按失败计: ${_sub}"
        failed_subtasks=$((failed_subtasks + 1))
        subdir_status_map["$_sub"]="failed"
        tg_add_entry failed_list "$_sub" "worker 崩溃"
        _sync_par_render
        return 0
      fi
    done
    sleep 2
  done
}

_sync_subdirs_parallel_run() {
  # 依赖调用方（_sync_task_impl）作用域（读）: subdirs / source_path /
  #   dest_path / task_name / extra_args / current_depth / subdir_size_map /
  #   total_subdirs_count
  # （写，均为 _sync_task_impl 的 local，此处赋值即更新调用方变量）:
  #   subdir_status_map / total_subtasks / synced_subtasks / failed_subtasks /
  #   partial_subtasks / skipped_subtasks / total_transferred /
  #   synced_list / failed_list / skipped_list / GLOBAL_FIXED_FILES_JSON /
  #   GLOBAL_FIX_BLACKLIST_JSON
  local _par="${OPENLIST_SUBDIR_PARALLEL:-2}"
  [ "$_par" -lt 2 ] && _par=2
  local _par_dir="/tmp/ol_par_$(date +%s)_$$"
  mkdir -p "$_par_dir"
  declare -A _w_subdir=()
  declare -A _w_pid=()
  local _idx=0 _running=0 _pid
  while IFS= read -r subdir || [ -n "$subdir" ]; do
    [ -z "$subdir" ] && continue
    # P2 优雅到站: 预算将尽不再分发新 worker（在途的等待自然完成）
    if sync_budget_stop; then
      echo "⏳ 时间预算将尽，停止分发新子目录（未分发的留给下轮接力）"
      SYNC_TIME_EXHAUSTED=1
      break
    fi
    # 满载: 先收割一个完成槽位再分发
    while [ "$_running" -ge "$_par" ]; do
      _sync_par_reap_one "$_par_dir"
      _running=$((_running - 1))
    done
    _idx=$((_idx + 1))
    total_subtasks=$((total_subtasks + 1))
    local _safe="${task_name}_${subdir//\//_}"
    echo "=== 子目录同步(并行): ${_safe} ==="
    subdir_status_map["$subdir"]="syncing"
    _sync_par_render
    (
      PROGRESS_WORKER_MUTE=1
      # 修复累计器从零开始: worker 只上交"本子目录新增"，父级负责合并。
      # 不重置的话，worker 会继承父级当前累计值并随 .done 回传，被父级
      # 再合并一次 —— 尤其跳过/失败分支不改累计器，继承值被原样回传，
      # 造成条目指数级重复（实测复现）
      GLOBAL_FIXED_FILES_JSON='[]'
      GLOBAL_FIX_BLACKLIST_JSON='{}'
      SYNC_AUTO_SPLIT_DEPTH=$((current_depth + 1))
      _sync_task_impl "${source_path}/${subdir}" "${dest_path}/${subdir}" "${_safe}" "${extra_args[@]}" < /dev/null || true
      # 注意: worker 是子 shell 不是函数，此处禁用 local（"local: can only
      # be used in a function" 在 set -e 下会杀死 worker，.done 永不落盘）
      _st=""; _tr="0"
      if [ "${SYNC_SKIPPED:-0}" = "1" ]; then
        _st="skipped"
      elif [ "${SYNC_FAILED:-0}" = "0" ]; then
        _st="synced"
      elif [ "${SYNC_PARTIAL:-0}" = "1" ]; then
        _st="partial"
      else
        _st="failed"
      fi
      _tr="${SYNC_TRANSFERRED_BYTES:-0}"
      {
        printf 'subdir=%s\n' "$subdir"
        printf 'status=%s\n' "$_st"
        printf 'transferred=%s\n' "$_tr"
        printf 'fixed_b64=%s\n' "$(printf '%s' "${GLOBAL_FIXED_FILES_JSON:-[]}" | base64 -w0 2>/dev/null || true)"
        printf 'blacklist_b64=%s\n' "$(printf '%s' "${GLOBAL_FIX_BLACKLIST_JSON:-}" | base64 -w0 2>/dev/null || true)"
      } > "${_par_dir}/${_idx}.done" 2>/dev/null || true
      exit 0
    ) &
    _pid=$!
    _w_subdir[$_idx]="$subdir"
    _w_pid[$_idx]=$_pid
    _running=$((_running + 1))
  done <<< "$subdirs"
  while [ "$_running" -gt 0 ]; do
    _sync_par_reap_one "$_par_dir"
    _running=$((_running - 1))
  done
  rm -rf "$_par_dir"
  return 0
}

# 自动拆分同步实现：源端 > 50GB 时按一级子目录拆分，最后再完整同步一次
# 用法: _sync_task_impl <source_path> <dest_path> <task_name> [rclone_extra_args...]
_sync_task_impl() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  # 按 rclone 远端类型分路由（整合自 task0 专项验证结论）:
  #   openlist:* 目标（wopan176Crypt/baidupanCrypt/wopan175/aliyundriveCrypt 等全部
  #   OpenList 挂载盘）: 批次阈值 5GiB（可 OPENLIST_BATCH_BYTES 覆盖）、
  #   并发 transfers=OPENLIST_TARGET_TRANSFERS（默认 4）
  #   非 openlist 目标: 阈值 20GB、并发 transfers=RCLONE_TRANSFERS（默认 2）

  local current_depth=${SYNC_AUTO_SPLIT_DEPTH:-0}

  # 只在顶级调用（非递归）时重置状态标志，避免递归子任务覆盖父任务状态
  if [ "$current_depth" -eq 0 ]; then
    SYNC_SKIPPED=0
    SYNC_FAILED=0
    SYNC_PARTIAL=0
    # 初始化修复文件累计器（sync_with_logging 每次执行后会累加到此变量）
    # auto-split 子目录的修复也会累计到这里，最终由 save_sync_marker 写入 marker
    GLOBAL_FIXED_FILES_JSON="[]"
    # 方法假成功黑名单累计器（B: 失败记忆）与本轮已修复文件表
    GLOBAL_FIX_BLACKLIST_JSON="{}"
    FIXED_THIS_RUN=()
  fi

  local max_depth=10
  local subdir

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    case "$MARKER_ACTION" in
      skip)
        # 透传 extra_args: 跳过通知要按同一过滤口径算"本次未传"量
        send_sync_skipped "$task_name" "$source_path" "$dest_path" "${extra_args[@]}"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
      warning)
        send_sync_warning "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
    esac
  fi

  # 清空本层及更深层的阶段槽位: 同名深度可能被上一个兄弟子树遗留过期内容
  # （尤其"直接同步中"这类不写树的路径）；祖先层槽位保持不动，
  # 子任务内容由深度路由写入自己的槽位，不再覆盖父树
  progress_scope_init "$current_depth"

  # 未开启 --auto-split 时跳过大小检查和子目录拆分，直接同步
  if [ "${_TASK_AUTO_SPLIT:-0}" = "0" ]; then
    progress_update "直接同步中"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  # 根据阈值判断是否拆分: openlist 系目标用独立阈值（默认 5GiB），其他沿用 env
  local threshold
  if [[ "$dest_path" == openlist:* ]]; then
    threshold="${OPENLIST_BATCH_BYTES:-5368709120}"
  else
    threshold="${SYNC_SPLIT_THRESHOLD_BYTES:-$DEFAULT_SPLIT_THRESHOLD_BYTES}"
  fi

  # 检查源端大小
  local source_size_bytes=0
  local size_json
  size_json=$(_rclone_size_json "$source_path")
  if [ -n "$size_json" ]; then
    source_size_bytes=$(_size_json_field "$size_json" bytes)
  fi
  # 确保 source_size_bytes 是有效整数，否则置 0
  [[ "$source_size_bytes" =~ ^[0-9]+$ ]] || source_size_bytes=0

  if [ "$source_size_bytes" -le "$threshold" ]; then
    echo "源端大小 $(format_bytes_iec "$source_size_bytes") 未超过拆分阈值 $(format_bytes_iec "$threshold")，直接同步"
    progress_update "直接同步中 · 源端 $(format_bytes "$source_size_bytes")"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  # 超过 50GB，需要拆分
  if [ "$current_depth" -ge "$max_depth" ]; then
    echo "已达最大拆分深度 ${max_depth}，按文件批次拆分 (depth=${current_depth}, size=$(format_bytes_iec "$source_size_bytes"))"
    progress_update "文件批次拆分 · 已达最大深度 ${current_depth}"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  echo "源端大小 $(format_bytes_iec "$source_size_bytes") 超过拆分阈值 $(format_bytes_iec "$threshold")，按子目录拆分同步 (depth=${current_depth})"

  # 列出一级子目录
  local subdirs
  subdirs=$(rclone lsf --dirs-only "$source_path" 2>/dev/null | sed 's|/$||')
  if [ -z "$subdirs" ]; then
    echo "无子目录，按文件批次拆分同步"
    progress_update "无子目录，按文件批次拆分"
    sync_by_file_batches "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    local _rc=$?
    _sync_task_finalize "$_rc"
    return "$_rc"
  fi

  # 从 extra_args 中提取排除的目录名（模式如 notion/** 或 /notion/**）
  local exclude_dir_list=""
  local i=0
  while [ $i -lt ${#extra_args[@]} ]; do
    if [ "${extra_args[$i]}" = "--exclude" ] && [ $((i+1)) -lt ${#extra_args[@]} ]; then
      local pattern="${extra_args[$((i+1))]}"
      if [[ "$pattern" == */** ]]; then
        local dirname="${pattern#/}"
        dirname="${dirname%/**}"
        if [ -n "$dirname" ]; then
          exclude_dir_list="${exclude_dir_list}${dirname}"$'\n'
        fi
      fi
      i=$((i+2))
    else
      i=$((i+1))
    fi
  done

  # 过滤掉匹配排除规则的子目录
  if [ -n "$exclude_dir_list" ]; then
    local filtered_subdirs=""
    while IFS= read -r subdir; do
      [ -z "$subdir" ] && continue
      if echo "$exclude_dir_list" | grep -qxF "$subdir"; then
        echo "跳过排除的子目录: ${subdir}"
        continue
      fi
      if [ -z "$filtered_subdirs" ]; then
        filtered_subdirs="$subdir"
      else
        filtered_subdirs="${filtered_subdirs}"$'\n'"${subdir}"
      fi
    done <<< "$subdirs"
    subdirs="$filtered_subdirs"
    if [ -z "$subdirs" ]; then
      echo "所有子目录均被排除，直接执行完整同步"
      progress_update "所有子目录被排除，直接完整同步"
      sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
      local _rc=$?
      _sync_task_finalize "$_rc"
      return "$_rc"
    fi
  fi

  # 按子目录大小从小到大排序
  echo "按子目录大小排序..."
  # 排序阶段还没有子目录树可展示，用标签行（"▸" 开头）说明正在做什么；
  # 不再夹带源端大小（任务分组头已给出），避免同一数字重复两遍
  PROGRESS_PHASE_INFO="▸ 📂 子目录拆分 · depth=${current_depth}"
  progress_update "正在统计并排序子目录..."
  local sorted_subdirs=""
  declare -A subdir_size_map=()
  declare -A subdir_status_map=()
  # 并行统计子目录大小（纯只读列举，无状态冲突；_rclone_size_json 单次
  # 1-3s，串行在 150+ 子目录的任务上要耗 5 分钟以上，8 路并行 <1 分钟）。
  # 结果按索引写临时文件回收，保持与串行完全一致的排序口径与日志输出
  local _sz_dir="/tmp/ol_sz_$(date +%s)_$$"
  mkdir -p "$_sz_dir"
  local -a _sz_names=()
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    _sz_names+=("$subdir")
  done <<< "$subdirs"
  local _sz_n=${#_sz_names[@]}
  local _sz_k=0
  while [ "$_sz_k" -lt "$_sz_n" ]; do
    local _sz_c=0
    while [ "$_sz_c" -lt "${OPENLIST_SUBDIR_LIST_PARALLEL:-8}" ] && [ "$_sz_k" -lt "$_sz_n" ]; do
      local _sz_sub="${_sz_names[$_sz_k]}"
      local _sz_idx=$_sz_k
      (
        local _j _b
        _j=$(_rclone_size_json "${source_path}/${_sz_sub}") || _j=""
        _b=0
        [ -n "$_j" ] && _b=$(_size_json_field "$_j" bytes)
        [[ "$_b" =~ ^[0-9]+$ ]] || _b=0
        printf '%s' "$_b" > "$_sz_dir/$_sz_idx"
      ) &
      _sz_k=$((_sz_k + 1))
      _sz_c=$((_sz_c + 1))
    done
    wait || true
  done
  _sz_k=0
  while [ "$_sz_k" -lt "$_sz_n" ]; do
    local _sz_sub="${_sz_names[$_sz_k]}"
    local _sz_bytes=0
    _sz_bytes=$(cat "$_sz_dir/$_sz_k" 2>/dev/null || echo 0)
    [[ "$_sz_bytes" =~ ^[0-9]+$ ]] || _sz_bytes=0
    subdir_size_map["$_sz_sub"]=$_sz_bytes
    echo "  ${_sz_sub}: $(format_bytes "$_sz_bytes")"
    sorted_subdirs+="${_sz_bytes} ${_sz_sub}"$'\n'
    _sz_k=$((_sz_k + 1))
  done
  rm -rf "$_sz_dir"
  subdirs=$(echo "$sorted_subdirs" | sort -n | cut -d' ' -f2-)

  # 预统计子目录总数（用于进度展示）
  local total_subdirs_count
  total_subdirs_count=$(echo "$subdirs" | grep -c . 2>/dev/null || echo 0)

  # 按子目录逐个同步（静默模式：无文件变更时跳过通知）
  SYNC_SKIP_QUIET=1
  local total_subtasks=0
  local synced_subtasks=0
  local failed_subtasks=0
  local partial_subtasks=0
  local skipped_subtasks=0
  local total_transferred=0
  local synced_list=""
  local failed_list=""
  local skipped_list=""
  local subtask_idx=0
  # ===== 并行子目录同步分支（默认关闭，行为不变）=====
  # 启用条件: OPENLIST_SUBDIR_PARALLEL>=2 且 仅顶层拆分（depth=0，递归层
  # 仍串行避免锁嵌套）且 子目录数>=2。默认串行，开启前见
  # _sync_subdirs_parallel_run 头注释
  if [ "${OPENLIST_SUBDIR_PARALLEL:-1}" -ge 2 ] \
     && [ "$current_depth" -eq 0 ] \
     && [ "${total_subdirs_count:-0}" -ge 2 ]; then
    _sync_subdirs_parallel_run
  else
  while IFS= read -r subdir; do
    [ -z "$subdir" ] && continue
    # P2 优雅到站: 预算将尽不再开新子目录（已完成的子目录 marker 已各自落盘）
    if sync_budget_stop; then
      echo "⏳ 时间预算将尽，停止开新子目录（未同步的留给下轮接力）"
      SYNC_TIME_EXHAUSTED=1
      break
    fi
    total_subtasks=$((total_subtasks + 1))
    subtask_idx=$((subtask_idx + 1))
    local safe_subtask="${task_name}_${subdir//\//_}"
    echo "=== 子目录同步: ${safe_subtask} ==="
    subdir_status_map["$subdir"]="syncing"
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    local _completed_before=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    # detail 留空: 任务行只显示名称，进度由阶段树（🔄 标记）+ 统计行表达；
    # 必须用 force: 上一个子目录的完成刷新刚更新过节流时间戳，普通 update
    # 会被 2s 节流吞掉，导致整个子目录同步期间消息停留在旧树（当前子目录
    # 一直显示 ⏳ 待同步而非 🔄 同步中）
    progress_update_force "" "▸ 📊 子目录：${_completed_before}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⏳$((total_subdirs_count - _completed_before)) ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
    SYNC_AUTO_SPLIT_DEPTH=$((current_depth + 1))
    # 不再抑制子任务内部的进度更新: 子任务内容经深度路由写入自己深度
    # 的槽位，渲染时缩进嵌套展示在父层树下方（父子互不覆盖）
    # < /dev/null: 子任务全链路（sync/fix/marker）不读 stdin；不隔离的话
    # 链路里任何误读 stdin 的命令（jq/rclone rcat 等）会把本循环的子目录
    # 列表吃掉，剩余子任务被静默跳过（run 31954162437 实锤: 只同步了
    # archive 就跳去最终完整同步，照片/j-1024j 两个子任务丢失）
    _sync_task_impl "${source_path}/${subdir}" "${dest_path}/${subdir}" "${safe_subtask}" "${extra_args[@]}" < /dev/null || true
    SYNC_AUTO_SPLIT_DEPTH=$current_depth
    # 子任务已收尾: 清掉它那一层（及更深）的阶段行/统计/细粒度状态。
    # 不清则已完成子目录下仍挂着它最后一批的 "📦 文件批次拆分 / 📊 批次 n/m"，
    # 看着像还在跑；下一个子任务进入时也会清，但那要等到它自己开口说话，
    # 中间的最终完整同步阶段会一直顶着上一个子任务的残留
    progress_scope_init $((current_depth + 1))
    if [ "$SYNC_SKIPPED" = "1" ]; then
      skipped_subtasks=$((skipped_subtasks + 1))
      subdir_status_map["$subdir"]="skipped"
      tg_add_entry skipped_list "$subdir" "$(format_bytes "${subdir_size_map[$subdir]:-0}")"
    elif [ "$SYNC_FAILED" = "0" ]; then
      synced_subtasks=$((synced_subtasks + 1))
      subdir_status_map["$subdir"]="synced"
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      tg_add_entry synced_list "$subdir" "$(format_bytes "${subdir_size_map[$subdir]:-0}")"
    else
      failed_subtasks=$((failed_subtasks + 1))
      if [ "${SYNC_PARTIAL:-0}" = "1" ]; then
        # 有文件成功但有文件失败/缺失（sync_with_logging 导出的部分失败标志）
        partial_subtasks=$((partial_subtasks + 1))
        subdir_status_map["$subdir"]="partial"
      else
        subdir_status_map["$subdir"]="failed"
      fi
      total_transferred=$((total_transferred + SYNC_TRANSFERRED_BYTES))
      tg_add_entry failed_list "$subdir" "$(format_bytes "${subdir_size_map[$subdir]:-0}")" \
        "$([ "${subdir_status_map[$subdir]}" = partial ] && echo '部分失败')"
    fi
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    local _completed_after=$((synced_subtasks + skipped_subtasks + failed_subtasks))
    progress_update_force "" "▸ 📊 子目录：${_completed_after}/${total_subdirs_count} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⏳$((total_subdirs_count - _completed_after)) ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
  done <<< "$subdirs"
  fi
  SYNC_SKIP_QUIET=0

  # 设置拆分信息供最终通知使用（HTML 片段，由 sync_engine.sh 通知按分节插入；
  # 统一走 tg_add_section/tg_add_block 助手构建——段前空行/结尾换行由助手保证）
  AUTO_SPLIT_INFO=""
  tg_add_section AUTO_SPLIT_INFO "🔀 子任务拆分统计"
  tg_add_kv AUTO_SPLIT_INFO "总子目录" "${total_subtasks}"
  tg_add_kv AUTO_SPLIT_INFO "传输总量" "$(format_bytes "$total_transferred")"
  local _counts="✅ ${synced_subtasks} · ❌ ${failed_subtasks}"
  [ "$partial_subtasks" -gt 0 ] && _counts+=" · ⚠️ ${partial_subtasks}"
  _counts+=" · ⏭️ ${skipped_subtasks}"
  tg_add_block AUTO_SPLIT_INFO "${_counts}"
  # 列表分节带计数（规模一眼可见）
  if [ -n "$synced_list" ]; then
    tg_add_section AUTO_SPLIT_INFO "✅ 已同步的子目录 · ${synced_subtasks}"
    tg_add_block AUTO_SPLIT_INFO "$(tree_lines "$synced_list")"
  fi
  if [ -n "$failed_list" ]; then
    tg_add_section AUTO_SPLIT_INFO "❌ 未同步的子目录 · ${failed_subtasks}"
    tg_add_block AUTO_SPLIT_INFO "$(tree_lines "$failed_list")"
  fi
  if [ -n "$skipped_list" ]; then
    tg_add_section AUTO_SPLIT_INFO "⏭️ 已跳过的子目录 · ${skipped_subtasks}"
    # 「无文件变动」是说明，交给 tg_add_note（此前裸贴在树末尾、无前缀）
    tg_add_block AUTO_SPLIT_INFO "$(tree_lines "$skipped_list")"
    tg_add_note AUTO_SPLIT_INFO "无文件变动"
  fi

  # 最终完整同步（仅在顶层执行，正常通知）
  if [ "$current_depth" -eq 0 ]; then
    # P2 优雅到站: 预算将尽跳过最终完整同步——各子目录 marker 已落盘，
    # 直接收摊不保存 pair 级成功 marker（任务确实未完整，下轮继续）
    if sync_budget_stop; then
      echo "⏳ 时间预算将尽，跳过最终完整同步（子目录 marker 已落盘，下轮接力）"
      SYNC_TIME_EXHAUSTED=1
    else
    echo "=== 最终完整同步: ${task_name} ==="
    PROGRESS_PHASE_INFO="$(_render_subdir_phase_tree)"
    progress_update_force "最终完整同步中" "▸ 📊 子目录：${total_subtasks}/${total_subtasks} 完成 | ✅${synced_subtasks} ⏭️${skipped_subtasks} ⚠️${partial_subtasks} ❌$((failed_subtasks - partial_subtasks))"
    sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    # P0 趋势: 最终完整同步的净传字节（此前各子目录已各自记录，这里只
    # 记本调用自己的 sync_with_logging，二者相加无重复）
    trend_record_transferred "${SYNC_TRANSFERRED_BYTES:-0}"
    AUTO_SPLIT_INFO=""
    if [ "$SYNC_FAILED" = "0" ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    else
      split_on_sync_failure "$source_path" "$task_name"
    fi
    fi
  else
    # 递归子任务收尾：把聚合状态传回父级（父循环依据 SYNC_FAILED/SYNC_SKIPPED
    # 对本子目录分类）。失败子目录数 > 0 时必须保持 SYNC_FAILED=1，否则父级
    # 会把本任务误判为"已同步"，深层失败被静默吞掉
    SYNC_SKIPPED=0
    if [ "$failed_subtasks" -gt 0 ]; then SYNC_FAILED=1; else SYNC_FAILED=0; fi
    if [ "$partial_subtasks" -gt 0 ]; then SYNC_PARTIAL=1; else SYNC_PARTIAL=0; fi
    SYNC_TRANSFERRED_BYTES=$total_transferred
    if [ "$failed_subtasks" -eq 0 ] && [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
      save_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    fi
  fi
}

# sync_task: rclone sync 模式（删除目标端多余文件）
# 可选参数:
#   --auto-split   开启 50GB 子目录自动拆分
#   --1d-skip      开启 1 天跳过（--2d-skip / --3d-skip 可自定义天数）
#   其余参数（如 --exclude）原样传给 rclone
# sync_task 特有参数（--delete-before 等）由 RCLONE_SYNC_TASK_FLAGS 自动追加
sync_task() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3

  # 解析任务级开关，剩余参数作为 extra_args 传给 rclone
  local _auto_split=0
  local _skip_days=0
  local extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto-split) _auto_split=1; shift ;;
      --*d-skip)
        _skip_days="${1#--}"
        _skip_days="${_skip_days%d-skip}"
        [[ "$_skip_days" =~ ^[0-9]+$ ]] || _skip_days=0
        shift ;;
      *) extra_args+=("$1"); shift ;;
    esac
  done

  # 追加 sync_task 特有 rclone 参数（RCLONE_SYNC_TASK_FLAGS；已不再包含任何 --delete-*）
  extra_args=("${RCLONE_SYNC_TASK_FLAGS[@]}" "${extra_args[@]}")

  # 根据 skip 天数设置 SYNC_SKIP_SECONDS
  if [ "$_skip_days" -gt 0 ]; then
    SYNC_SKIP_SECONDS=$((_skip_days * 24 * 60 * 60))
  fi

  local current_depth=${SYNC_AUTO_SPLIT_DEPTH:-0}

  # 预览/仅注册模式：只注册，不实际同步
  if [ "$current_depth" -eq 0 ] && { [ -n "$TASK_PREVIEW_ONLY" ] || [ "${TASK_REGISTER_ONLY:-0}" = "1" ]; }; then
    # _TASK_SKIP_DAYS 前缀赋值（与下方 _sync_task_impl 同一手法）: 让预览能按
    # --Nd-skip 天数预判断"本轮会不会被跳过"，否则预览算出的待同步量会被
    # 同步 pass 的跳过静默吞掉，看上去像丢数据（详见 add_preview_pair）
    _TASK_SKIP_DAYS=$_skip_days _preview_register "$task_name" "$source_path" "$dest_path" "${extra_args[@]}"
    return 0
  fi

  # 顶级调用时自动 progress_task_begin/progress_task_done
  if [ "$current_depth" -eq 0 ]; then
    local _task_id
    _task_id=$(_derive_task_id "$task_name" "$dest_path")
    progress_task_begin "$_task_id" "${source_path} → ${dest_path}"
  fi

  _TASK_AUTO_SPLIT=$_auto_split _TASK_SKIP_DAYS=$_skip_days _sync_task_impl "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  local _rc=$?

  # 无论本轮成败，持久化修复状态（fixed_files + fix_blacklist）
  # 部分失败轮（SYNC_FAILED=1）不写跳过 marker，但修复成果必须记录：
  # 否则下一轮会重复下载/打包/上传已持久化的替代文件，跨轮方法黑名单也会丢失。
  # 任务被跳过时（SYNC_SKIPPED=1）本轮无修复活动，不写。
  if [ "$SYNC_SKIPPED" != "1" ]; then
    save_fix_state_marker "$source_path" "$dest_path" "$task_name" || true
  fi

  if [ "$current_depth" -eq 0 ]; then
    # 兜底状态映射: 实现层若只回传了非零返回码而未置位 SYNC_FAILED（批次
    # 熔断分支的历史教训，run 33048121562: return 1 的失败任务被记成已完成、
    # 失败计 0、轮转游标当成功后移），进度 progress_task_done 与 run_all_tasks 轮转
    # 都以全局标志为准会双双误判。此处保证顶级任务 rc≠0 ⇔ 失败标志。
    # sync_with_logging 契约是恒返回 0、经 SYNC_FAILED 报告失败（见其函数头），
    # 正常成功路径 rc=0 不受影响；被跳过的任务 rc 可能为 0/1 均不算失败
    if [ "$_rc" -ne 0 ] && [ "${SYNC_SKIPPED:-0}" != "1" ]; then
      SYNC_FAILED=1
    fi
    if [ "$SYNC_SKIPPED" = "1" ]; then
      progress_task_done "skipped"
    elif [ "$SYNC_FAILED" = "1" ]; then
      progress_task_done "failed"
    else
      progress_task_done "completed"
    fi
  fi
  return $_rc
}

# 批次级巩固: 批次上传完成后立即"重启容器取后端真值 → 校验落盘 → 串行重试
# → 顽固缺失转修复管线"
# 背景: truth-check / lsf diff / 修复管线原本只在所有批次完成后的最终
#       sync_with_logging 里执行，而大任务常态在批次阶段被 6h job 上限取消，
#       巩固链路从未运行 —— PUT 假成功文件（OpenList 缓存里有、后端没有，
#       容器重启即消失）每轮重传，预览差值纹丝不动（task0 wopan176Crypt
#       长期 +225GiB 的根因）。
# 本函数把巩固单元从"整个任务"缩小到"单个批次"（~50GB）:
#   1. 本批触碰过文件（Copied 声称成功 或 Failed to copy 直接失败——含全批
#      405: 只看 Copied 会让 405 批次跳过巩固，复核/重试/修复/熔断全饿死，
#      2026-08-31 用户反馈实录）→ 重启 OpenList 容器，清缓存取后端真值列表
#   2. 本批触碰过的文件（Copied + Failed to copy）diff 真值清单 → 未落盘清单
#   3. 未落盘文件立即串行重试一次（transfers=1，对齐 sync_with_logging 的
#      openlist_guard_flags 保护参数；重试期间跑 token 保鲜循环防再次假成功）
#   4. 重试后再重启取真值复核 → 仍未落盘的"顽固缺失"（后端内容性拒收，
#      如密文文件名超长——run 32749862280 名长诊断实锤，原路径原名重试
#      永远失败）复用 _sync_fix_missing_files 修复管线换方法落盘
#      （原名 copyto/短哈希名/zip 分卷等 4 种方法 + 增量持久化 + 名长诊断，
#      方法编号以 file_fix.sh _fix_method_desc 为准）
# 价值: 重启后仍在的文件是真成果 —— 即使本 run 随后被取消，下一轮
#       --size-only 也会跳过它们，进度不回退；且批次间容器已被重启、缓存即
#       真值，历史遗留的假成功文件会被后续批次正常识别为缺失并补传；
#       顽固缺失当场换方法修复并即时写 marker，不再依赖大概率被取消的
#       最终检查。
# 只校验"本批触碰过"的文件而非整个批次清单: --exclude 排除的文件从未被传输，
# 不产生 Copied/Failed 日志，自然不会进重试清单（避免每批对排除项无谓重扫）。
# 依赖调用方（sync_by_file_batches）作用域（bash 动态作用域）:
#   source_path / dest_path / task_name / batch_dir / extra_args
# 用法: _batch_consolidate <batch_idx> <batch_log>（恒返回 0，异常仅告警）
# 开关: OPENLIST_BATCH_CONSOLIDATE=0 关闭（调试用）
_batch_consolidate() {
  local batch_idx="$1"
  local batch_log="$2"
  local label="批次 $((batch_idx + 1))"

  # 本批巩固产出（供调用方累加进进度行的 ⚠️ 未落盘 / 🔁 重传 / 🔧 修复）:
  # 每次进入先归零 —— 下方有多处提前 return（非 openlist 目标端、开关关闭、
  # 无传输），不归零会把上一批的产出重复累加到统计行
  CONSOLIDATE_MISSING=0
  CONSOLIDATE_RETRY_COPIED=0
  CONSOLIDATE_FIXED=0

  [[ "$dest_path" == openlist:* ]] || return 0
  [ "${OPENLIST_BATCH_CONSOLIDATE:-1}" = "0" ] && return 0

  # 本批触碰文件数: Copied（声称成功，需复核）+ Failed to copy（真失败，排除
  # object not found——源端不存在的重试无意义）
  # 旧逻辑只在 uploaded>0 时巩固: 全批 405（wopan 8005 经 OpenList 包装为 HTTP
  # 405 Method Not Allowed）时 rclone 零报成功 → 跳过巩固 → 重启复核/驱动刷新
  # 串行重试/修复管线/后端全拒熔断全部饿死，批次循环烧完所有批次（2026-08-31
  # 用户反馈实录）。新逻辑: 本批触碰过文件（有声称成功或有直接失败）就巩固;
  # 仅零触碰（无 Copied 且无非 onf 失败）才跳过。
  local uploaded=0 failed_n=0
  uploaded=$(grep -cE 'Copied \((new|replaced existing)\)' "$batch_log" 2>/dev/null || true)
  failed_n=$(grep -E 'ERROR : .+: Failed to copy' "$batch_log" 2>/dev/null | grep -cv 'object not found' || true)
  [[ "$uploaded" =~ ^[0-9]+$ ]] || uploaded=0
  [[ "$failed_n" =~ ^[0-9]+$ ]] || failed_n=0
  if [ "$uploaded" -eq 0 ] && [ "$failed_n" -eq 0 ]; then
    echo "${label}: 本批无传输无失败，跳过巩固（无新写入即无假成功污染）"
    return 0
  fi

  echo "── ${label} 巩固: 本批成功 ${uploaded} 个 / 直接失败 ${failed_n} 个，重启容器校验后端真值 ──"
  progress_update "${label} 巩固: 重启容器校验落盘真值"
  if ! _restart_openlist_for_truth "${dest_path#openlist:}" "$batch_log"; then
    echo "⚠️ ${label} 巩固: 容器重启失败，跳过校验（缺失文件由最终检查兜底）"
    return 0
  fi

  # 目标端真值清单（重启后缓存已清空，lsf 即后端实际列表）
  local dest_truth="${batch_dir}/dest_truth_${batch_idx}.txt"
  timeout 900 rclone lsf "$dest_path" -R --files-only > "$dest_truth" 2>/dev/null || true
  if ! [ -s "$dest_truth" ]; then
    echo "⚠️ ${label} 巩固: 目标端列表获取失败/为空，跳过校验（避免半截列表误判全量缺失）"
    return 0
  fi
  sort -u "$dest_truth" -o "$dest_truth"

  # 本批触碰过的文件 = Copied（含假成功）+ Failed to copy（真失败）
  # 排除 object not found（源端文件不存在的，重试无意义）
  local touched="${batch_dir}/touched_${batch_idx}.txt"
  {
    grep -E 'Copied \((new|replaced existing)\)' "$batch_log" 2>/dev/null | \
      sed -E 's/^.*INFO *: //; s/: Copied \(.*$//'
    grep -E 'ERROR : .+: Failed to copy' "$batch_log" 2>/dev/null | \
      grep -Ev 'object not found' | \
      sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//'
  } | sort -u > "$touched"

  # 触碰过但真值清单里没有的 = 未落盘（假成功 / 失败）
  local retry_list="${batch_dir}/retry_${batch_idx}.txt"
  comm -23 "$touched" "$dest_truth" > "$retry_list"

  local missing_n=0
  missing_n=$(wc -l < "$retry_list" | tr -d ' ')
  if [ "$missing_n" -eq 0 ]; then
    echo "✅ ${label} 巩固: 本批 ${uploaded} 个传输全部真实落盘（重启后仍在）"
    return 0
  fi

  CONSOLIDATE_MISSING=$missing_n
  echo "⚠️ ${label} 巩固: ${missing_n} 个文件未落盘（假成功/失败），串行重试..."
  progress_update "${label} 巩固: ${missing_n} 个未落盘，串行重试"

  # 重启+列表校验耗时可能已使 wopan token 过期，重试前刷新驱动；
  # 重试本身可能长达数小时（29 GiB 重传 ~2.5h >> 5 分钟 token 窗口），
  # 不跑保鲜循环的话重试会重演整批假成功（run 32749862280 实锤）
  _refresh_ol_drivers "$batch_log" || true
  _start_token_refresher

  local retry_log="${batch_dir}/retry_${batch_idx}.log"
  set +e
  # 容器共享锁（与并行 worker 的传输窗口互斥容器重启，见 openlist_driver.sh）
  _ol_lock_shared
  rclone copy "$source_path" "$dest_path" \
    --files-from "$retry_list" \
    --size-only \
    --no-traverse \
    --transfers "$( [[ "$dest_path" == openlist:* ]] && echo "${OPENLIST_TARGET_TRANSFERS:-4}" || echo "${RCLONE_TRANSFERS:-2}" )" \
    --checkers "${OPENLIST_CHECKERS:-8}" \
    --timeout 30m \
    --retries 1 \
    --low-level-retries "${OPENLIST_LOW_LEVEL_RETRIES:-3}" \
    --contimeout 30s \
    --ignore-errors \
    --progress \
    --stats 15s \
    --stats-one-line \
    --verbose \
    "${extra_args[@]}" \
    2>&1 | tee "$retry_log"
  _ol_lock_shared_release
  set -e
  _stop_token_refresher

  local retry_copied=0
  retry_copied=$(grep -cE 'Copied \((new|replaced existing)\)' "$retry_log" 2>/dev/null || true)
  [[ "$retry_copied" =~ ^[0-9]+$ ]] || retry_copied=0
  CONSOLIDATE_RETRY_COPIED=$retry_copied
  echo "${label} 巩固: 串行重试完成，重传 ${retry_copied}/${missing_n}"

  # ===== 后端写入全拒检测（中止剩余批次，止损）=====
  # 本批全部触碰文件未落盘 + 串行重试 0 成功（重试前已刷新驱动 + 跑保鲜
  # token）→ 后端级写入故障（如 wopan175 全量 405: OpenList WebDAV 层拒收
  # PUT，rclone 报 "unchunked simple update failed: Method Not Allowed"）。
  # 置 BATCH_BACKEND_DEAD 由调用方 sync_by_file_batches 中止剩余批次并标记
  # 同步对失败，避免每批烧数十分钟（run 32904752243 实锤）。
  # 门槛: 缺失 ≥3 且占触碰文件 100%（部分落盘 = 后端还活着，不触发）。
  # 注意: 熔断只中止"剩余批次"——本批顽固缺失仍转修复管线换方法（2026-08-31
  # 用户规格: 直接传输没成功就要进修复管线，不因后端级拒收豁免; 方法黑名单
  # 自带全拉黑重置兑底，死后端误拉黑不会永久锁死方法）。
  local touched_n=0
  touched_n=$(wc -l < "$touched" 2>/dev/null | tr -d ' ')
  if [ "$missing_n" -ge 3 ] && [ "$retry_copied" -eq 0 ] && [ "$touched_n" -gt 0 ] && [ "$missing_n" -ge "$touched_n" ]; then
    BATCH_BACKEND_DEAD=1
    echo "🛑 ${label} 巩固: 后端写入全拒（${missing_n}/${touched_n} 个触碰文件 0 落盘、串行重试 0 成功）→ 已请求中止剩余批次"
  fi

  # ===== 顽固缺失 → 修复管线（换方法兜底）=====
  # 普通重传后仍未落盘 = 后端内容性拒收（如密文文件名超长），原名重试永远失败
  local stubborn="${batch_dir}/stubborn_${batch_idx}.txt"
  : > "$stubborn"
  if [ "$retry_copied" -gt 0 ]; then
    # 重传过 → 再重启一次取真值，区分"已补上"与"顽固缺失"
    progress_update "${label} 巩固: 复核重试落盘真值"
    if _restart_openlist_for_truth "${dest_path#openlist:}" "$batch_log"; then
      local truth2="${batch_dir}/dest_truth2_${batch_idx}.txt"
      timeout 900 rclone lsf "$dest_path" -R --files-only > "$truth2" 2>/dev/null || true
      if [ -s "$truth2" ]; then
        sort -u "$truth2" -o "$truth2"
        comm -23 "$retry_list" "$truth2" > "$stubborn"
      else
        echo "⚠️ ${label} 巩固: 复核列表获取失败，重试清单全部转交修复管线（宁重复勿遗漏）"
        cp "$retry_list" "$stubborn"
      fi
    else
      echo "⚠️ ${label} 巩固: 复核重启失败，重试清单全部转交修复管线（宁重复勿遗漏）"
      cp "$retry_list" "$stubborn"
    fi
  else
    # 一个都没重传成功 → 全部是顽固缺失
    cp "$retry_list" "$stubborn"
  fi

  local stubborn_n=0
  stubborn_n=$(wc -l < "$stubborn" | tr -d ' ')
  if [ "$stubborn_n" -eq 0 ]; then
    echo "✅ ${label} 巩固: 重试后顽固缺失 0 个，本批全部真实落盘"
    return 0
  fi

  echo "⚠️ ${label} 巩固: ${stubborn_n} 个顽固缺失（后端内容性拒收，如密文名超长），转修复管线换方法落盘..."
  progress_update "${label} 巩固: ${stubborn_n} 个顽固缺失，修复管线处理中"

  # 复用 _sync_fix_missing_files 全套链路（marker 沿用/方法黑名单/即时落盘
  # 校验/名长诊断/增量持久化）。它依赖调用方作用域变量，在此对齐；
  # 修复成果由 _persist_fix_entry_now 即时写 marker（防 run 取消丢失），
  # 并累计到 GLOBAL_FIXED_FILES_JSON 供顶级 save_sync_marker 收集。
  local LOG_FILENAME="$batch_log"
  local LAST_ATTEMPT_LOG="$retry_log"
  local fail_list="${batch_dir}/consolidate_fail_${batch_idx}.txt"
  local fix_list="${batch_dir}/consolidate_fix_${batch_idx}.txt"
  local fix_log="${batch_dir}/consolidate_fixlog_${batch_idx}.log"
  : > "$fail_list"
  : > "$fix_list"
  : > "$fix_log"
  # 注意: bash 里 "VAR=x func" 的赋值在函数返回后会残留（非 POSIX 模式），
  # 必须显式 unset，否则最终 sync_with_logging 的 _sync_fix_missing_files
  # 会误用本批的顽固缺失清单
  # SYNC_FIX_LIST_CACHE: 把本函数刚取的真值清单递进去，让修复管线省掉
  # 一次目标端全量 lsf（大目录数分钟；同一轮内重复列两三次纯属浪费）
  SYNC_FIX_MISSING_OVERRIDE="$stubborn" SYNC_FIX_LIST_CACHE="$dest_truth" _sync_fix_missing_files || true
  unset SYNC_FIX_MISSING_OVERRIDE SYNC_FIX_LIST_CACHE
  _sync_serialize_fixed_files || true
  _sync_accumulate_fixed_results || true

  local fixed_n=0
  fixed_n=$(wc -l < "$fix_list" 2>/dev/null | tr -d ' ')
  CONSOLIDATE_FIXED=$fixed_n
  echo "${label} 巩固: 修复管线完成，${fixed_n}/${stubborn_n} 个换方法落盘成功"

  # ===== 修复管线后重启容器复核 =====
  # 修复方法返回"成功"只代表 PUT 被接受，与批次传输的假成功同源：
  # OpenList 缓存里有、重启即消失。批次巩固的价值就在于"重启后仍在的才是
  # 真成果"，修复管线却一直没有这道复核 —— 17/68 的成功数里混有多少假
  # 成功无从得知，下一轮 marker 沿用判定又把它们当已落盘跳过。
  # 此处重启取真值、逐条核对 fix_list 替代路径，未落盘的当场拉黑该方法并
  # 转失败清单（下一轮从剩余方法继续，靠 marker 黑名单收敛，不在此空转重跑）
  if [ "$fixed_n" -gt 0 ]; then
    # errexit-proof: verify 返回非零是预期分支（部分修复为假成功），且此处可能
    # 处于重试段重新开启的 set -e 下——直接调用会让函数当场终止（local verify_ok
    # 永远执行不到，CONSOLIDATE_FIXED 不再重新计数，进度面板修复数虚高；
    # run_consolidate 测试 harness 的 wrapper 记账 echo 也被跳过，2026-08-31 测试实录）
    local verify_ok=0
    _consolidate_verify_fixed "$label" "$batch_idx" "$batch_dir" "$dest_path" \
      "$fix_list" "$fail_list" "$batch_log" "$retry_log" || verify_ok=$?
    [ "$verify_ok" -eq 0 ] || echo "${label} 巩固: 修复复核完成，部分条目重启后未落盘（已拉黑，下轮换方法）"
    # 复核会剔除重启后消失的假成功，统计行只报真实落盘数
    CONSOLIDATE_FIXED=$(wc -l < "$fix_list" 2>/dev/null | tr -d ' ')
  fi
  return 0
}

# 批次巩固·修复成果重启复核（_batch_consolidate 的第 5 步）
# 重启容器取后端真值 → 逐条核对 fix_list 的替代路径是否仍在 → 未落盘者
# 拉黑所用方法、从 fix_list 剔除、转记 fail_list，避免假成功进入 marker
# 后被下一轮当作"沿用上轮修复"永久跳过。
# 依赖调用方作用域: task_name / source_path / dest_path（修复重试用）
# 用法: _consolidate_verify_fixed <label> <batch_idx> <batch_dir> <dest_path> \
#         <fix_list> <fail_list> <batch_log> <retry_log>
# 返回: 0=全部通过或跳过复核, 1=存在未落盘条目
_consolidate_verify_fixed() {
  local label="$1"
  local batch_idx="$2"
  local batch_dir="$3"
  local dest_path="$4"
  local fix_list="$5"
  local fail_list="$6"
  local batch_log="$7"
  local retry_log="$8"

  [ -s "$fix_list" ] || return 0

  progress_update "${label} 巩固: 重启容器复核修复成果"
  if ! _restart_openlist_for_truth "${dest_path#openlist:}" "$batch_log"; then
    echo "⚠️ ${label} 巩固: 复核重启失败，跳过修复复核（条目以即时校验为准，最终检查兜底）"
    return 0
  fi

  local truth3="${batch_dir}/dest_truth3_${batch_idx}.txt"
  timeout 900 rclone lsf "$dest_path" -R --files-only > "$truth3" 2>/dev/null || true
  if ! [ -s "$truth3" ]; then
    echo "⚠️ ${label} 巩固: 复核列表获取失败，跳过修复复核（宁漏判勿误删已落盘成果）"
    return 0
  fi
  sort -u "$truth3" -o "$truth3"

  local ghost_n=0 kept_n=0
  local kept="${batch_dir}/fix_kept_${batch_idx}.txt"
  : > "$kept"
  local f_orig f_alt f_method f_restore f_size f_bytes f_mid
  while IFS='|' read -r f_orig f_alt f_method f_restore f_size f_bytes f_mid; do
    [ -z "$f_alt" ] && continue
    if grep -qxF "$f_alt" "$truth3"; then
      echo "${f_orig}|${f_alt}|${f_method}|${f_restore}|${f_size}|${f_bytes}|${f_mid}" >> "$kept"
      kept_n=$((kept_n + 1))
    else
      # 假成功: 拉黑本条所用方法，下一轮直接从剩余方法继续
      [ -n "$f_mid" ] && _blacklist_add "$f_orig" "$f_mid"
      echo "🔴 ${label} 巩固: 修复假成功（重启后消失）· $(_fix_method_short "$f_mid") · $(_short_path "$f_orig")"
      echo "${f_orig}|${f_size}|修复后重启复核未落盘（$(_fix_method_short "$f_mid")，已拉黑）" >> "$fail_list"
      ghost_n=$((ghost_n + 1))
    fi
  done < "$fix_list"

  if [ "$ghost_n" -gt 0 ]; then
    # fix_list 只留真成果: 它是 _sync_serialize_fixed_files 与 marker 的来源，
    # 假成功条目写进 marker 会被下一轮当作"沿用上轮修复"永久跳过
    cp "$kept" "$fix_list"
    _flush_blacklist_to_marker "$task_name" "$dest_path" "$batch_log" 2>/dev/null || true
  fi
  echo "${label} 巩固: 修复复核 ${kept_n} 个真实落盘 / ${ghost_n} 个假成功已剔除"
  [ "$ghost_n" -eq 0 ] || return 1
  return 0
}

# 渲染文件批次阶段的统计行（进度通知 "▸ 📊 批次：..." 行）
# 依赖调用方（sync_by_file_batches）作用域变量（bash 动态作用域可见）:
#   batch_idx / total_batches / synced_batches / failed_batches /
#   batch_file_count / batch_total_files / total_files / batch_transferred_bytes /
#   consolidate_missing_total / consolidate_retry_total / consolidate_fix_total
# 信息粒度对齐 Actions 日志: 批次序号、成功/失败批次数、累计文件数、累计传输量、
# 巩固累计（未落盘 → 串行重传 → 换方法修复）。只报 "✅/❌ 批次数" 时看不出
# 本批在跑什么、跑了多少，与日志里的 "批次 N 巩固: X 个未落盘，串行重试"
# 完全对不上；巩固类字段为 0 时整段省略（常态批次无假成功，不占位）。
_render_batch_stats_line() {
  local _s="▸ 📊 进度：第 ${batch_idx:-0}/${total_batches:-0} 批 | 完成 ${synced_batches:-0} 批 · 失败 ${failed_batches:-0} 批"
  _s+=" · 已传 ${batch_total_files:-0}/${total_files:-0} 个文件 · 📤 本轮已传输 $(format_bytes "${batch_transferred_bytes:-0}")"
  # 目标端估算 = 本轮传输量 + 批次拆分前已有的目标端基线（若上游提供）
  [ "${DEST_BASE_BYTES:-0}" -gt 0 ] 2>/dev/null && _s+=" · 目标端约 $(format_bytes $((DEST_BASE_BYTES + ${batch_transferred_bytes:-0})))"
  [ "${consolidate_missing_total:-0}" -gt 0 ] && _s+=" · ⚠️ 未落盘 ${consolidate_missing_total}"
  [ "${consolidate_retry_total:-0}" -gt 0 ] && _s+=" · 🔁 重传 ${consolidate_retry_total}"
  [ "${consolidate_fix_total:-0}" -gt 0 ] && _s+=" · 🔧 修复 ${consolidate_fix_total}"
  echo "$_s"
}

# 按文件批次拆分同步（用于无子目录的大文件夹）
# 按 ~50GB 拆分为多个批次，每批用 rclone copy --files-from 同步
# 用法: sync_by_file_batches <source_path> <dest_path> <task_name> [rclone_extra_args...]
sync_by_file_batches() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")

  # skip 标记检查（需 --1d-skip / --2d-skip 等开启）
  MARKER_ACTION="proceed"
  if [ "${_TASK_SKIP_DAYS:-0}" -gt 0 ]; then
    check_sync_marker "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
    case "$MARKER_ACTION" in
      skip)
        echo "跳过 ${task_name} 文件批次同步: $((SYNC_SKIP_SECONDS / 3600))小时内已成功同步"
        send_sync_skipped "$task_name" "$source_path" "$dest_path" "${extra_args[@]}"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
      warning)
        send_sync_warning "$task_name" "$source_path" "$dest_path"
        SYNC_SKIPPED=1
        SYNC_FAILED=0
        SYNC_TRANSFERRED_BYTES=0
        return 0
        ;;
    esac
  fi

  local threshold
  if [[ "$dest_path" == openlist:* ]]; then
    threshold="${OPENLIST_BATCH_BYTES:-5368709120}"
  else
    threshold="${SYNC_SPLIT_THRESHOLD_BYTES:-$DEFAULT_SPLIT_THRESHOLD_BYTES}"
  fi
  local batch_dir="/tmp/file_batches_${task_name}"
  mkdir -p "$batch_dir"

  echo "=== 按文件批次拆分: ${task_name} ==="
  # 新一轮文件批次阶段: 清空上一轮批次历史，避免旧批次结果混入本次展示
  _progress_batch_history_clear

  # 递归列出所有文件（使用 lsjson，比 lsf --json 更可靠）
  local file_list_file="${batch_dir}/all_files.jsonl"
  echo "正在列出文件..."
  # 进入文件批次阶段：清空父级子目录阶段的 stats，避免在批次阶段
  # 仍显示 "📊 子目录: x/y 完成" 这类与当前阶段无关的旧数据。
  PROGRESS_STATS=""
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分 · depth=${SYNC_AUTO_SPLIT_DEPTH:-0} · 正在列出文件"
  progress_update "正在列出文件..."
  # 注意：GitHub Actions 默认 set -e -o pipefail，rclone lsjson 失败时管道会非零退出，
  # 此处只需文件列表（失败时 total_files=0 触发下方 lsf 备选），用 || true 避免 step 直接退出。
  # 记录 rclone 自身退出码: 供下方区分"源端为空"与"两次列举全失败"（防静默漏同步）。
  local _lsjson_rc=0 _lsf_rc=0
  rclone lsjson --recursive --files-only --no-modtime --no-mimetype "$source_path" 2>&1 | jq -c '.[]' > "$file_list_file" 2>/dev/null || true
  _lsjson_rc=${PIPESTATUS[0]}

  local total_files
  total_files=$(wc -l < "$file_list_file" | tr -d ' ')
  echo "总文件数: ${total_files}"
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分 · ${total_files} 文件 · 正在拆分批次"
  progress_update "总文件数: ${total_files}，正在拆分批次..."

  if [ "$total_files" -eq 0 ]; then
    echo "⚠️ 无文件列出，尝试 rclone lsf 备选方案..."
    # 备选：用 rclone lsf -l 获取文件列表和大小
    rclone lsf -l --files-only --recursive "$source_path" 2>&1 | \
      awk '{
        size=$1
        name=""
        # 文件名是第5个字段之后的所有内容（文件名可能含空格）
        for(i=5;i<=NF;i++) name = (i==5 ? $i : name " " $i)
        if (name != "") printf "{\"size\":%s,\"path\":\"%s\"}\n", size, name
      }' > "$file_list_file" 2>/dev/null || true
    _lsf_rc=${PIPESTATUS[0]}
    total_files=$(wc -l < "$file_list_file" | tr -d ' ')
    echo "备选方案文件数: ${total_files}"
  fi

  if [ "$total_files" -eq 0 ]; then
    if [ "$_lsjson_rc" -ne 0 ] || [ "$_lsf_rc" -ne 0 ]; then
      # 两次列举全失败 ≠ 空源端: 历史行为是按"无文件可同步"静默跳过，
      # 源端持续列举失败（驱动失效/网盘故障）会让任务无限期静默漏同步
      # 且无任何告警。按失败处理，交由通知与 marker 逻辑走失败分支。
      echo "🛑 两次列举均失败（lsjson exit=${_lsjson_rc} / lsf exit=${_lsf_rc}）且 0 文件: 无法区分『源端为空』与『列举失败』，按失败处理（防静默漏同步）"
      SYNC_SKIPPED=0
      SYNC_FAILED=1
      SYNC_TRANSFERRED_BYTES=0
      rm -rf "$batch_dir"
      return 0
    fi
    echo "两次列举均成功但源端 0 文件，视为空源端，跳过"
    SYNC_SKIPPED=1
    SYNC_FAILED=0
    SYNC_TRANSFERRED_BYTES=0
    rm -rf "$batch_dir"
    return 0
  fi

  # 按大小拆分为 ~50GB 的批次
  local batch_num=0
  local batch_size=0
  local batch_file="${batch_dir}/batch_${batch_num}.txt"
  > "$batch_file"

  while IFS= read -r line; do
    local size fpath
    # lsjson 用 .size 和 .path (小写)，lsf --json 用 .Size 和 .Path (大写)
    size=$(echo "$line" | jq -r '(.size // .Size // 0)' 2>/dev/null || echo 0)
    fpath=$(echo "$line" | jq -r '(.path // .Path // empty)' 2>/dev/null)
    [ -z "$fpath" ] && continue
    # 确保 size 是有效整数，否则置 0（避免 $(( )) 语法错误和 [: : integer expression expected）
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    # 当前批次加此文件超阈值则开新批次
    if [ "$batch_size" -gt 0 ] && [ $((batch_size + size)) -gt "$threshold" ]; then
      batch_num=$((batch_num + 1))
      batch_file="${batch_dir}/batch_${batch_num}.txt"
      > "$batch_file"
      batch_size=0
    fi

    echo "$fpath" >> "$batch_file"
    batch_size=$((batch_size + size))
  done < "$file_list_file"

  # 逐批同步（rclone copy + --files-from）
  # 计数器须在首个 progress_update 之前初始化: _render_batch_stats_line 直接
  # 读调用方作用域的变量，未初始化会得到空串并报未绑定变量（set -u）
  local total_batches=$((batch_num + 1))
  local synced_batches=0
  local failed_batches=0
  local failed_batch_list=""
  local batch_total_files=0
  local batch_idx=0
  # 累计量（跨批次）: 已传输字节 + 批次巩固的三类产出（未落盘/重传/换方法修复）
  local batch_transferred_bytes=0
  local consolidate_missing_total=0
  local consolidate_retry_total=0
  local consolidate_fix_total=0

  # 目标端基线（供进度行显示“目标端约 XX GiB”）：拆分前测一次，含 errors 容错
  DEST_BASE_BYTES=0
  local _dst_json
  _dst_json=$(rclone size "$dest_path" --json 2>/dev/null || true)
  [ -n "$_dst_json" ] && DEST_BASE_BYTES=$(echo "$_dst_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  [[ "$DEST_BASE_BYTES" =~ ^[0-9]+$ ]] || DEST_BASE_BYTES=0

  echo "拆分为 ${total_batches} 个批次"
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：共 ${total_batches} 批 · ${total_files} 个文件 · 每批 ≤ $(format_bytes "$threshold")"
  progress_update_force "拆分为 ${total_batches} 个批次" "$(_render_batch_stats_line)"

  for i in $(seq 0 $batch_num); do
    local bf="${batch_dir}/batch_${i}.txt"
    if [ -s "$bf" ]; then
      batch_idx=$((batch_idx + 1))
      local batch_file_count
      batch_file_count=$(wc -l < "$bf" | tr -d ' ')
      batch_total_files=$((batch_total_files + batch_file_count))
      echo "=== 批次 $((i+1))/${total_batches}: ${batch_file_count} 个文件 ==="
      # 标签行只保留总量（共 N 批 · M 个文件）；当前批次号/文件数已由
      # 统计行（📊 批次：n/m · 📄 x/y 文件）表达，detail 不再重复写进任务行
      # —— 三处重复（任务行 detail + 标签行尾 + 统计行）只留统计行（用户反馈）
      PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：共 ${total_batches} 批 · ${total_files} 个文件"
      progress_update "" "$(_render_batch_stats_line)"

      # 批次计时基准（历史记录耗时用）
      BATCH_START_TS=$(date +%s)

      local batch_log="${task_name}_batch_${i}.log"
      # 实时刷新线程（分钟级）: 必须在 batch_log 定义后启动
      _start_batch_progress_thread "$batch_log"

      # OpenList 目标端低并发保护（对齐 sync_with_logging 的 openlist_guard_flags）:
      # 批次 copy 此前无 transfers 限制（默认 4 并发上传），慢后端（wopan176 等）
      # 来不及持久化 → "object not found" / PUT 假成功（缓存里有、后端没有，
      # 容器重启即消失）—— 正是批次 exit=4 与预览差值不动的直接诱因之一
      local batch_guard_flags=()
      local batch_timeout="5m"
      if [[ "$dest_path" == openlist:* ]]; then
        local _ol_transfers
        if [[ "$dest_path" == openlist:* ]]; then
          _ol_transfers="${OPENLIST_TARGET_TRANSFERS:-4}"
        else
          _ol_transfers="${RCLONE_TRANSFERS:-2}"
        fi
        batch_guard_flags=("--transfers" "$_ol_transfers" "--checkers" "${OPENLIST_CHECKERS:-8}")
        batch_timeout="30m"
        echo "OpenList 目标端：批次上传启用低并发保护 (transfers=1, checkers=8, timeout=30m)"
        # 长批次开始前主动刷新驱动 token（wopan OAuth access token 有效期约 5
        # 分钟；批次循环没有 8005 重试兜底，驱动坏状态 = 整批 exit 4）。
        # 仅传前刷一次撑不过 5 分钟 token 窗口——批次动辄数小时，中途必须
        # 保鲜（run 32749862280: 3 小时批次 139/139 假成功实锤）
        _refresh_ol_drivers "$batch_log" || true
        # 批次级三层预检熔断: sync_with_logging 的入口预检覆盖不到本循环内
        # 的 rclone copy --files-from，登录失效后端会把第一个大批次（≤50GB）
        # 全额烧完才由 _batch_consolidate 行为启发式止损。此处与
        # run_rclone_sync_once 的二次预检同构（刷新驱动 → 两层强校验 → 起
        # 保鲜线程），把拦截前移到每个批次传输之前；含 Crypt 底层派生存储校验
        if ! _check_openlist_backend_connectivity "$dest_path" "$batch_log"; then
          local unbuilt_batches=$((total_batches - synced_batches - failed_batches))
          failed_batches=$((failed_batches + unbuilt_batches))
          # 条目统一走真源助手（规范 · 条目与树形）：主体为文字 → tg_add_entry_text，元数据 " · " 分隔
          [ "$unbuilt_batches" -gt 0 ] && tg_add_entry_text failed_batch_list \
            "批次 $((i+1))/${total_batches} 起共 ${unbuilt_batches} 批" "批次预检未通过" "后端不健康" "中止"
          echo "🛑 批次 $((i+1)) 预检未通过（后端不健康），中止剩余 ${unbuilt_batches} 个批次，本同步对标记失败（后端恢复后轮转回来重试）"
          _stop_batch_progress_thread
          AUTO_SPLIT_INFO=""
          tg_add_section AUTO_SPLIT_INFO "🔀 文件批次拆分统计"
          tg_add_kv AUTO_SPLIT_INFO "总批次" "${total_batches}"
          tg_add_kv AUTO_SPLIT_INFO "文件数" "${batch_total_files}"
          tg_add_block AUTO_SPLIT_INFO "✅ ${synced_batches} · ❌ ${failed_batches} 批次预检熔断中止"
          progress_update_force "批次预检未通过，中止同步" "▸ 📊 批次：${batch_idx}/${total_batches} · ✅${synced_batches} ❌${failed_batches}"
          # 失败状态必须随全局标志传递（与本函数开头 skip 分支置 SYNC_SKIPPED
          # 的惯例一致）: 下游 progress_task_done 状态映射与轮转游标都只认 SYNC_FAILED，
          # 只 return 1 会被双双误判为成功（run 33048121562: task0-wopan175
          # 预检熔断后被记成已完成、失败计 0、游标照常后移）
          SYNC_FAILED=1
          rm -rf "$batch_dir"
          return 1
        fi
        _start_token_refresher
      fi

      # set -e 下 rclone 非零退出（如 exit 4 部分失败）会直接终止 step，
      # 导致后续 sync_with_logging 通知无法发出。此处需捕获退出码，临时关闭 set -e。
      set +e
      rclone copy "$source_path" "$dest_path" \
        --files-from "$bf" \
        --size-only \
        --no-traverse \
        --retries 1 \
        --low-level-retries "${OPENLIST_LOW_LEVEL_RETRIES:-3}" \
        --timeout "$batch_timeout" \
        --contimeout 30s \
        --ignore-errors \
        --progress \
        --stats 15s \
        --stats-one-line \
        --verbose \
        "${batch_guard_flags[@]}" \
        "${extra_args[@]}" \
        2>&1 | stdbuf -oL tee "$batch_log"
      local rc=${PIPESTATUS[0]}
      set -e
      _stop_token_refresher
      _stop_batch_progress_thread

      # 批次耗时（mm:ss 补零，定宽对齐；≥1h 时 mm 延伸如 75:20）
      local _batch_elapsed=$(( $(date +%s) - ${BATCH_START_TS:-$(date +%s)} ))
      local _bh_mm=$((_batch_elapsed / 60)) _bh_ss=$((_batch_elapsed % 60))

      if [ "$rc" -eq 0 ]; then
        synced_batches=$((synced_batches + 1))
      elif [ "$rc" -eq 4 ]; then
        # exit code 4 = 部分文件失败，大部分成功
        synced_batches=$((synced_batches + 1))
        local err_count
        # grep -c 无匹配时已输出 0（退出码 1），用 || true 防止追加第二行 0
        err_count=$(grep -c 'ERROR.*object not found' "$batch_log" 2>/dev/null || true)
        echo "批次 $((i+1)) 部分成功 (exit=4, ${err_count} 个文件 object not found)"
        grep 'ERROR.*object not found' "$batch_log" 2>/dev/null | head -50 | while IFS= read -r line; do
          echo "  ${line}"
        done
      else
        failed_batches=$((failed_batches + 1))
        # 英文 token 不直出通知（规范 · 失败与异常）: exit=N 改写为中文说明
        # 条目主体（中文说明）→ 裸文本，元数据（文件数/退出码）→ · （规范 · 条目与树形）
        tg_add_entry_text failed_batch_list "批次 $((i+1))/${total_batches}" \
          "${batch_file_count} 文件" "传输退出码 ${rc}"
        echo "批次 $((i+1)) 失败 (exit=${rc})"
      fi

      # 累计本批传输字节（进度行的 📤 字段；日志里的 Transferred 行是唯一
      # 数据源，rclone 未回传任何计数器）
      local _batch_bytes
      _batch_bytes=$(get_transferred_bytes_from_log "$batch_log" 2>/dev/null || echo 0)
      [[ "$_batch_bytes" =~ ^[0-9]+$ ]] || _batch_bytes=0
      batch_transferred_bytes=$((batch_transferred_bytes + _batch_bytes))

      # 批次级巩固: 重启容器取后端真值 → 校验本批落盘 → 串行重试缺失
      # （把巩固单元从"整个任务"缩小到"单个批次"，run 被取消也锁住进度；
      #   详见 _batch_consolidate 函数头注释）
      BATCH_BACKEND_DEAD=0
      _batch_consolidate "$i" "$batch_log" || true
      # 巩固产出并入累计（CONSOLIDATE_* 由 _batch_consolidate 每次进入时归零，
      # 未跑巩固的批次全为 0，累加安全）
      consolidate_missing_total=$((consolidate_missing_total + ${CONSOLIDATE_MISSING:-0}))
      consolidate_retry_total=$((consolidate_retry_total + ${CONSOLIDATE_RETRY_COPIED:-0}))
      consolidate_fix_total=$((consolidate_fix_total + ${CONSOLIDATE_FIXED:-0}))

      # 后端写入全拒（如 OpenList WebDAV 层全量 405）→ 中止剩余批次。
      # 继续跑只会每批烧数十分钟产出假成功/失败，且最终 sync_with_logging
      # 的全量重传同样全拒（run 32904752243: wopan175 批次 1 全拒后修复
      # 管线又烧 45 分钟）。直接标记失败返回，轮转机制下轮给其他同步对让路。
      if [ "${BATCH_BACKEND_DEAD:-0}" = "1" ]; then
        local remaining_batches=$((total_batches - batch_idx))
        [ "$remaining_batches" -gt 0 ] && failed_batches=$((failed_batches + remaining_batches))
        tg_add_entry_text failed_batch_list "剩余 ${remaining_batches} 批" "后端写入全拒，中止"
        echo "🛑 后端写入全拒，中止剩余 ${remaining_batches} 个批次，本同步对标记失败（后端恢复后轮转回来重试）"
        _stop_batch_progress_thread
        # 统一走 tg_* 助手构建（与预检熔断出口同款；手拼 HTML = 版式漂移根源）
        AUTO_SPLIT_INFO=""
        tg_add_section AUTO_SPLIT_INFO "🔀 文件批次拆分统计"
        tg_add_kv AUTO_SPLIT_INFO "总批次" "${total_batches}"
        tg_add_kv AUTO_SPLIT_INFO "文件数" "${batch_total_files}"
        tg_add_block AUTO_SPLIT_INFO "✅ ${synced_batches} · ❌ ${failed_batches} 后端写入全拒中止"
        progress_update_force "后端写入全拒，中止同步" "$(_render_batch_stats_line)"
        # 同预检熔断出口: 失败状态经 SYNC_FAILED 全局标志传递（见上注释）
        SYNC_FAILED=1
        rm -rf "$batch_dir"
        return 1
      fi

      progress_update_force "第 ${batch_idx}/${total_batches} 批完成" "$(_render_batch_stats_line)"

      # 批次历史快照（供进度消息回显最近 N 批的结果）
      # 分项口径（用户反馈: 只写“82 文件”看不出成败）:
      #   成功 = rclone Copied 且巩固确认落盘（copied - missing）+ 巩固重传补齐（RETRY_COPIED）
      #   修复 = 修复管线替代方式落盘（FIXED）
      #   失败 = rclone 传输报错（failed_n）+ 假成功重传/修复后仍未落盘（stubborn）
      #   跳过 = 源端已不存在（object not found）；其余未传输文件为目标端已同步（已有）
      local _copied_n=0 _failed_n=0 _onf_n=0
      _copied_n=$(grep -ac 'Copied (new)\|Copied (replaced existing)' "$batch_log" 2>/dev/null || true)
      _failed_n=$(grep -ac 'Failed to copy' "$batch_log" 2>/dev/null || true)
      _onf_n=$(grep -ac 'ERROR.*object not found' "$batch_log" 2>/dev/null || true)
      [[ "$_copied_n" =~ ^[0-9]+$ ]] || _copied_n=0
      [[ "$_failed_n" =~ ^[0-9]+$ ]] || _failed_n=0
      [[ "$_onf_n" =~ ^[0-9]+$ ]] || _onf_n=0
      local _missing_n="${CONSOLIDATE_MISSING:-0}"
      [[ "$_missing_n" =~ ^[0-9]+$ ]] || _missing_n=0
      local _retried_n="${CONSOLIDATE_RETRY_COPIED:-0}"
      [[ "$_retried_n" =~ ^[0-9]+$ ]] || _retried_n=0
      local _fixed_n="${CONSOLIDATE_FIXED:-0}"
      [[ "$_fixed_n" =~ ^[0-9]+$ ]] || _fixed_n=0
      local _ok_direct=$(( _copied_n > _missing_n ? _copied_n - _missing_n : 0 ))
      local _ok_n=$((_ok_direct + _retried_n))
      local _stubborn_n=$(( _missing_n > _retried_n + _fixed_n ? _missing_n - _retried_n - _fixed_n : 0 ))
      local _fail_n=$((_failed_n + _stubborn_n))
      local _have_n=$(( batch_file_count - _copied_n - _failed_n - _onf_n ))
      [ "$_have_n" -lt 0 ] && _have_n=0
      local _bh_mark="✅"
      [ "$_fail_n" -gt 0 ] && _bh_mark="⚠️"
      { [ "$rc" -ne 0 ] && [ "$rc" -ne 4 ]; } && _bh_mark="❌"
      # 分项 emoji 计数恒显 + 定宽补零（用户偏好: 全字段恒显 + 数字列竖向对齐；形态 2，2026-09-07）:
      #   ✅00 🔧00 ❗33 ⏭️22 ♻️00（%02d 补零）⏱01:15（mm:ss）⬆️4.79G（GiB 两位，末列不补）
      #   代价: 行宽 ≈42 全角，手机折 2 行（用户接受，换数字列竖向对齐）；字段表规范 · 计数与量化
      #   状态: ✅全成 ⚠️部分失败 ❌失败 ⏭️整批跳过 ♻️整批已有；❗=失败（不用 ❌ 避免与状态撞形）
      local _bh_gib
      _bh_gib=$(awk "BEGIN{printf \"%.2f\", ${_batch_bytes:-0}/1073741824}")
      printf -v _bh_entry '%s#%d ✅%02d 🔧%02d ❗%02d ⏭️%02d ♻️%02d ⏱%02d:%02d ⬆️%sG' \
        "${_bh_mark}" "$((i+1))" "$_ok_n" "$_fixed_n" "$_fail_n" "$_onf_n" "$_have_n" \
        "$_bh_mm" "$_bh_ss" "$_bh_gib"
      _progress_batch_history_add "$((i+1))" "$_bh_entry"
    fi
  done

  # 清理批次文件
  rm -rf "$batch_dir"

  echo "=== 批次传输完成 (成功 ${synced_batches}/${total_batches}, 失败 ${failed_batches})，执行最终同步检查 ==="
  PROGRESS_PHASE_INFO="▸ 📦 文件批次拆分：共 ${total_batches} 批 · ${total_files} 个文件 · ✅${synced_batches} ❌${failed_batches}"
  progress_update_force "批次传输完成，最终同步检查中" "$(_render_batch_stats_line)"

  # 设置批次统计信息，供最终通知展示（与子目录拆分的 AUTO_SPLIT_INFO 对齐）；
  # 统一走 tg_* 助手构建（段前空行/结尾换行由助手保证）
  AUTO_SPLIT_INFO=""
  tg_add_section AUTO_SPLIT_INFO "🔀 文件批次拆分统计"
  tg_add_kv AUTO_SPLIT_INFO "总批次" "${total_batches}"
  tg_add_kv AUTO_SPLIT_INFO "文件数" "${batch_total_files}"
  tg_add_block AUTO_SPLIT_INFO "✅ ${synced_batches} · ❌ ${failed_batches}"
  if [ -n "$failed_batch_list" ]; then
    tg_add_section AUTO_SPLIT_INFO "❌ 失败的批次 · ${failed_batches}"
    tg_add_block AUTO_SPLIT_INFO "$(tree_lines "$failed_batch_list")"
  fi

  # 最终用 sync_with_logging 做完整同步检查（处理缺失文件修复、通知等）
  # 文件批次阶段已完成实质传输，最终 sync 即使无新增 Copied 记录也必须发通知；
  # 此处可能被子目录递归调用（SYNC_SKIP_QUIET=1），需临时关闭静默模式，避免通知被吞。
  # 跳过标记（save_sync_marker）不在本函数保存——调用方 _sync_task_impl 随后的
  # _sync_task_finalize 会按统一条件保存，这里保存会重复执行远端统计。
  # ⚡ 批次阶段已完成实质传输，最终 sync_with_logging 只需做 lsf diff + 修复管线，
  # 不需要再跑一次完整的 rclone sync（否则大目录需要再扫描数分钟）。
  # 通过 OPENLIST_FIX_TEST_MODE=1 跳过 run_rclone_sync_once 的实际传输步骤。
  local _saved_skip_quiet="${SYNC_SKIP_QUIET:-0}"
  local _saved_fix_test="${OPENLIST_FIX_TEST_MODE:-0}"
  SYNC_SKIP_QUIET=0
  OPENLIST_FIX_TEST_MODE=1
  sync_with_logging "$source_path" "$dest_path" "$task_name" "${extra_args[@]}"
  OPENLIST_FIX_TEST_MODE="$_saved_fix_test"
  AUTO_SPLIT_INFO=""
  SYNC_SKIP_QUIET="$_saved_skip_quiet"
  # 部分批次失败但循环跑完（含 exit=4 部分成功之外的真失败）: 最终全量同步
  # 自身恒返回 0（失败经其内部 SYNC_FAILED 传递），此处把批次维度的失败
  # 归并进任务级标志，供 finalize 跳过 marker / progress_task_done / 轮转正确判定。
  # 放在最终同步之后: sync_with_logging 内部不消费本标志，提前置位亦无碍，
  # 但紧跟尾部赋值最不易随下游改动被扰动
  if [ "$failed_batches" -gt 0 ]; then
    SYNC_FAILED=1
  fi
}
