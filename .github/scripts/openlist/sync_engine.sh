#!/bin/bash
# ===== OpenList 同步工具 — 核心同步引擎（编排 + 重试）=====
# 封装 rclone sync/copy，负责同步编排与错误重试:
#   - HTTP 423 Locked 重试（OpenList/WebDAV 临时文件锁）
#   - 8005 登录失败重试（wopan176 token 过期后刷新并重试）
#   - object not found 错误处理（源端文件已不存在，无需修复）
#   - 同步会话状态初始化（init_sync_state）
#
# 已拆出的职责（勿再放回本文件，各模块头部有其设计说明与历史教训）:
#   - 驱动维护 / 健康预检 / 缓存与 truth-check → openlist_driver.sh
#   - 缺失文件修复管线编排（4 种方法轮换 + 增量持久化）→ file_fix_pipeline.sh
#   - 同步结果通知构建（源/目标大小、差异列表、排除规则）→ sync_notify.sh
#
# 完整流程（本文件只做编排，各环节实现在上述模块）:
#   预检健康校验 → rclone sync → 重试(423/8005) → truth-check 取后端真值
#   → diff 出缺失文件 → 修复管线 → 结果通知
#
# 依赖: utils.sh, rclone_query.sh, openlist_api.sh, openlist_driver.sh,
#       file_fix_pipeline.sh, sync_notify.sh, sync_marker.sh, telegram.sh, sync_progress.sh
# 依赖环境变量:
#   RCLONE_DEFAULT_FLAGS — 共用 rclone 参数数组（在 rclone_flags.sh 中定义）
#   TELEGRAM_BOT_TOKEN   — 用于发送日志文件
#   TELEGRAM_CHAT_ID     — 用于发送日志文件

# 清单分隔符兜底（真源 utils.sh）: 单测可能只 source 本文件，set -u 下未绑定会中止
: "${OL_FIELD_SEP=$'\037'}"

# 初始化同步会话状态（计数器/日志名/进度系统）
# 变量不加 local，故意写入调用方 shell（各 step source 后直接调用）
# 由 workflow 在每个同步 step 开头调用；依赖 sync_progress.sh 的 progress_init
init_sync_state() {
  PROCESSED_FILES_LOG="processed_videos.log"
  SYNC_SKIP_QUIET=0
  SYNC_SKIPPED=0
  SYNC_FAILED=0
  SYNC_TRANSFERRED_BYTES=0
  AUTO_SPLIT_INFO=""
  SYNC_AUTO_SPLIT_DEPTH=0
  # 初始化全局进度通知（任务在预览阶段自动注册）
  progress_init
}

# ===== 8005 登录失败重试 =====
# wopan176 后端写操作可能返回 8005（OpenList 包装为 HTTP 405 返回给 rclone）
# 需要检查 OpenList 容器日志中的真实 8005 错误，刷新 token 并重试
# 依赖调用方作用域: dest_path / LOG_FILENAME / SYNC_STATUS；调用嵌套函数 run_rclone_sync_once
_sync_retry_8005() {
  local OL_LOG_FILE=""
  OL_LOG_FILE=$(_find_openlist_log) || true

  if [[ "$dest_path" == openlist:* ]] && _has_wopan_login_failure "$LAST_ATTEMPT_LOG" "$OL_LOG_FILE"; then
    local wopan_retry_attempts="${OPENLIST_8005_RETRY_ATTEMPTS:-3}"
    local wopan_retry_index

    for ((wopan_retry_index = 1; wopan_retry_index <= wopan_retry_attempts; wopan_retry_index++)); do
      echo ""
      echo "============================================"
      echo "检测到 wopan176 登录失败 (8005)，刷新 token 并重试 ${wopan_retry_index}/${wopan_retry_attempts}" | tee -a "$LOG_FILENAME"
      echo "  OpenList 日志: ${OL_LOG_FILE:-未找到}" | tee -a "$LOG_FILENAME"
      echo "============================================"

      _refresh_ol_drivers "$LOG_FILENAME"
      # 等待 token 生效
      sleep 10

      # 刷新驱动后先用一次**便宜**的写探针决定要不要跑整次重传。
      # 为什么必须先探: 后端真死时 run_rclone_sync_once 会把每个文件都试一遍才
      # 报 8005——实测单次重试烧 48min（18:41→19:29，450MiB 重传、xfr#0 零落盘），
      # 而探针 60s 内就能给出同样结论。探针通过才值得花那 48min。
      # 必须清缓存: 同步前的入口探针已把 cache[$dest_path] 置 1（可写），
      # 不清就会命中缓存直接返回"可写"，等于没探（键口径同 F21 修复）。
      # 注: 这里**手写 unset 而非调 _backend_write_probe_invalidate** —— 本文件
      # 会被部分 source（只加载 sync_engine.sh 的测试，如 test_8005_probe_gate.sh），
      # 该助手定义在 openlist_driver.sh 里，改用函数会让那些测试报 command not found。
      # 键口径必须与助手一致（按同步对路径），改一处要同时核对另一处。
      unset "_BACKEND_WRITE_PROBE_CACHE[$dest_path]"
      # 病灶 E（2026-09-25）: 探针结论是**后端级**的（挂载根可写 ⇒ 放行），但放行
      #   不代表**这个路径**能写。若本轮已实测该路径写不进（路径特异性），再跑一次
      #   整次重传必然重复撞 409 —— 实测同一目录 25 分钟内被反复 sync 出 156 次
      #   409（其中 90 次集中同一目录）。这里直接跳过重传，交给折叠/换目录兜底。
      if declare -F _path_unwritable_hit >/dev/null 2>&1 && _path_unwritable_hit "$dest_path"; then
        echo "  ⏭ 本轮已实测该路径写不进（路径特异性），跳过整次重传（交折叠/换目录兜底，不再重复撞 409）" | tee -a "$LOG_FILENAME"
        break
      fi
      if ! _backend_write_probe "$dest_path" "$LOG_FILENAME"; then
        SYNC_BACKEND_DEAD=1
        # 写探针判死 = 强证据（真实 PUT + 刷新缓存复核），可跨轮持久化（F6）
        SYNC_BACKEND_DEAD_STRONG=1
        echo "  ▸ 刷新驱动后写探针仍失败: 判定该后端本轮不可写，跳过整次重传" | tee -a "$LOG_FILENAME"
        break
      fi

      # 刷新 OpenList 缓存
      _refresh_openlist_cache "$dest_path"

      # 重新查找日志文件（可能轮转了）
      OL_LOG_FILE=$(_find_openlist_log) || true

      SYNC_STATUS=0
      run_rclone_sync_once "8005 retry ${wopan_retry_index}/${wopan_retry_attempts}" || SYNC_STATUS=$?

      if ! _has_wopan_login_failure "$LAST_ATTEMPT_LOG" "$OL_LOG_FILE"; then
        echo "  wopan176 8005 错误已消除，重试成功" | tee -a "$LOG_FILENAME"
        break
      fi
      echo "  8005 错误仍然存在，继续重试..." | tee -a "$LOG_FILENAME"
    done
  fi
}

# ===== HTTP 423 Locked 重试 =====
# OpenList / WebDAV 可能临时锁定目标对象并返回 HTTP 423。
# 延迟后重跑整次 sync；已完成文件会被 rclone 跳过，主要补偿锁定残留文件。
# 依赖调用方作用域: dest_path / LOG_FILENAME / SYNC_STATUS；调用嵌套函数 run_rclone_sync_once
_sync_retry_423() {
  if [[ "$dest_path" == openlist:* ]] && grep -Eqi 'Locked:[[:space:]]*423|423[[:space:]]+Locked' "$LAST_ATTEMPT_LOG"; then
    local lock_retry_attempts="${OPENLIST_423_RETRY_ATTEMPTS:-3}"
    local lock_retry_sleep="${OPENLIST_423_RETRY_SLEEP_SECONDS:-300}"
    local lock_retry_index

    for ((lock_retry_index = 1; lock_retry_index <= lock_retry_attempts; lock_retry_index++)); do
      # 硬顶闸（2026-09-24 病灶 D 第四处）: 退避是 300s 的**纯等待**，而等待
      #   之后还要再跑一整次 sync（可能又几十分钟）。距平台硬顶不足收尾预留时
      #   这次退避必然把 step 拖过 330min 硬杀线 ⇒ 直接放弃整轮重试，剩余交
      #   下轮接力（已落盘内容不丢，sync 是幂等的）。
      if declare -F sync_hard_limit_stop >/dev/null 2>&1 && sync_hard_limit_stop; then
        echo "⏰ 距平台硬顶不足收尾预留，放弃 423 退避重试（第 ${lock_retry_index}/${lock_retry_attempts} 次未执行，sync 幂等，下轮接力）" | tee -a "$LOG_FILENAME"
        break
      fi
      # 病灶 E（同 _sync_retry_8005 内注释）: 本轮已实测该路径写不进 ⇒ 重跑整次
      #   sync 只会再撞一遍同样的 409/423，直接跳过交折叠/换目录兜底。
      if declare -F _path_unwritable_hit >/dev/null 2>&1 && _path_unwritable_hit "$dest_path"; then
        echo "⏭ 本轮已实测该路径写不进（路径特异性），跳过 423 重传（交折叠/换目录兜底）" | tee -a "$LOG_FILENAME"
        break
      fi
      echo "检测到 OpenList 423 Locked，等待 ${lock_retry_sleep}s 后重试 ${lock_retry_index}/${lock_retry_attempts}。" | tee -a "$LOG_FILENAME"
      sleep "$lock_retry_sleep"
      SYNC_STATUS=0
      run_rclone_sync_once "423 retry ${lock_retry_index}/${lock_retry_attempts}" || SYNC_STATUS=$?

      if ! grep -Eqi 'Locked:[[:space:]]*423|423[[:space:]]+Locked' "$LAST_ATTEMPT_LOG"; then
        break
      fi
    done
  fi
}

# ===== HTTP 409 Conflict 重试（2026-09-17 加，与 423 同款）=====
# 为什么需要: run 35186977864 单轮 2062 次 409 Conflict / 1088 次 mkParentDir failed，
#   整轮零落盘。409 有两个来源: ① 目录已存在（MKCOL 语义，本该幂等成功）
#   ② 并发 mkdir 竞争（与 423 同因，多个 worker 同时建同一父目录）。
#   两者都是**重试可自愈**的，但此前只有 423 有重试、409 直接走熔断判死，
#   于是一次竞争冲突就赔掉整轮。这里给 409 与 423 同等的机会。
#   注: "目录已存在"的更优解是在建目录处直接判存在（见 file_fix.sh
#   _fix_dir_exists_or_conflict），本函数兜的是**rclone 内部 mkParentDir**
#   那条代码里碰不到的路径。
# 依赖调用方作用域: dest_path / LOG_FILENAME / SYNC_STATUS；调用嵌套函数 run_rclone_sync_once
_sync_retry_409() {
  if [[ "$dest_path" == openlist:* ]] && grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict|mkParentDir failed' "$LAST_ATTEMPT_LOG"; then
    local conflict_retry_attempts="${OPENLIST_409_RETRY_ATTEMPTS:-3}"
    local conflict_retry_sleep="${OPENLIST_409_RETRY_SLEEP_SECONDS:-300}"
    local conflict_retry_index

    for ((conflict_retry_index = 1; conflict_retry_index <= conflict_retry_attempts; conflict_retry_index++)); do
      # 硬顶闸（2026-09-24 病灶 D 第四处）: 与 423 退避同款（见该函数内注释）。
      if declare -F sync_hard_limit_stop >/dev/null 2>&1 && sync_hard_limit_stop; then
        echo "⏰ 距平台硬顶不足收尾预留，放弃 409 退避重试（第 ${conflict_retry_index}/${conflict_retry_attempts} 次未执行，sync 幂等，下轮接力）" | tee -a "$LOG_FILENAME"
        break
      fi
      # 病灶 E（同 _sync_retry_8005 内注释）: 409 正是"路径写不进"的直接症状，
      #   本轮已实测过就别再撞一遍。
      if declare -F _path_unwritable_hit >/dev/null 2>&1 && _path_unwritable_hit "$dest_path"; then
        echo "⏭ 本轮已实测该路径写不进（路径特异性），跳过 409 重传（交折叠/换目录兜底）" | tee -a "$LOG_FILENAME"
        break
      fi
      echo "检测到 OpenList 409 Conflict/mkParentDir 失败，等待 ${conflict_retry_sleep}s 后重试 ${conflict_retry_index}/${conflict_retry_attempts}（目录已存在或并发争用，均可自愈）。" | tee -a "$LOG_FILENAME"
      sleep "$conflict_retry_sleep"
      SYNC_STATUS=0
      run_rclone_sync_once "409 retry ${conflict_retry_index}/${conflict_retry_attempts}" || SYNC_STATUS=$?

      if ! grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict|mkParentDir failed' "$LAST_ATTEMPT_LOG"; then
        break
      fi
    done
  fi
}

# ===== object not found 错误解析（源文件不存在）=====
# 依赖调用方作用域: LAST_ATTEMPT_LOG / fail_list / LOG_FILENAME / task_name / HAS_OBJECT_NOT_FOUND
_sync_parse_object_not_found() {
  if grep -Eqi 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null; then
    HAS_OBJECT_NOT_FOUND=1
    echo "=== ${task_name} 检测到 object not found 错误（源文件不存在）===" | tee -a "$LOG_FILENAME"
    while IFS= read -r failed_line; do
      [ -z "$failed_line" ] && continue
      # 跳过已在缺失文件修复中处理的文件
      grep -qF "${failed_line}${OL_FIELD_SEP}" "$fail_list" 2>/dev/null && continue
      echo "源文件不存在: ${failed_line}" | tee -a "$LOG_FILENAME"
      echo "${failed_line}${OL_FIELD_SEP}未知${OL_FIELD_SEP}源文件不存在 (object not found)" >> "$fail_list"
    done < <(
      grep -E 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
        sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
    )
  fi
}

# ===== 目标端镜像清理（受控 delete 通道，2026-11-02）=====
# 需求: 目标端要镜像源端（源端删了目标端也要删），但**不能**退回裸 rclone sync ——
#   它的清理阶段在 OpenList 上不可信（run 41196672258/41219905962 实锤）:
#   stale 缓存/超长文件名场景下列举出幻影条目，会把刚复制的文件和修复产物
#   当"多余"删掉，造成"修复→被删→重修"跨轮空转。
# 做法: initial sync（copy，只增不减）完成后，用**双侧刚列举的新清单**求差集
#   找出"源端没有、目标端有"的候选，经保护后 rclone deletefile 逐个删除。
# 差集口径（关键，2026-11-02 修）: 源端清单**不带任务过滤**（不传 FILTER_ARGS）。
#   镜像语义是「目标端 == 源端」，不是「目标端 == 源端 ∩ 本任务过滤」——
#   用过滤口径会把 --exclude 范围内的目标端文件（如 backup 的 notion/**）
#   误判成"源端没有"而越界删除。改全量口径后，exclude 内文件因源端确实有
#   而天然不进候选，无需再做模式匹配（也省掉一遍列举）。
# 保护:
#   ① 修复产物不删: 排除清单（marker ∪ 本轮 ∪ 父级守卫，_sync_fixed_files_exclusion
#     产出的 fixed_exclude 文件）里的 original/alternative 路径。全量口径下
#     original 通常已在源端清单里，但 alternative（短哈希/base64/压缩形态）以及
#     marker 记录孤儿化（任务改名）的场景仍需这层按路径精确挡；
#   ② 顶层短哈希目录（^[0-9a-f]{8}$）不删: 折叠/短名修复落点恒为
#     dest_path/<hash8>（见 file_fix.sh _hash_dir_rel_for），是还原链路唯一
#     映射载体，marker 记录丢失时这是最后一道硬保护；
#   ③ 单轮删除总量上限: OPENLIST_MIRROR_PRUNE_MAX（默认 200）——
#     大规模删源端（用户手动清目录）时分轮跟进，stale 缓存造成的批量
#     假"多余"也不会一轮烧光；OPENLIST_MIRROR_PRUNE=0 整体关闭。
# 删除前复核: 候选非空时**再列一次**源端（只在真要删时才付这份成本），凡在
#   该快照里出现的候选一律不删（防同步窗口内源端又出现/列举误差）。
#   ⚠️ 绝不对每个候选各列一次 —— 200 个候选 = 200 次全量列举，比传输还慢。
# 失败不阻断: 清理是附加能力，任何失败只记日志/告警，不置 SYNC_FAILED。
# 用法: _sync_mirror_prune <source_path> <dest_path> <fixed_exclude_file|空>
# 依赖调用方作用域: task_name / LOG_FILENAME
_sync_mirror_prune() {
  local source_path="$1" dest_path="$2" fixed_exclude_file="$3"
  # 只对 openlist: 目标端生效；测试/调试模式跳过（diff 口径不同）
  [[ "$dest_path" == openlist:* ]] || return 0
  [ "${OPENLIST_FIX_TEST_MODE:-0}" = "1" ] && return 0
  [ "${OPENLIST_MIRROR_PRUNE:-1}" = "1" ] || { echo "镜像清理已关闭（OPENLIST_MIRROR_PRUNE=0），跳过"; return 0; }

  local prune_max="${OPENLIST_MIRROR_PRUNE_MAX:-200}"
  [[ "$prune_max" =~ ^[0-9]+$ ]] || prune_max=200

  local listing_timeout="${OPENLIST_RCLONE_LISTING_TIMEOUT:-900s}"
  local src_json dst_json
  # 源端: 全量（刻意不加 FILTER_ARGS，见函数头"差集口径"）
  src_json=$(rclone lsjson "$source_path" --recursive --files-only --no-mimetype --no-modtime \
    --timeout "$listing_timeout" 2>/dev/null) || src_json=""
  dst_json=$(rclone lsjson "$dest_path" --recursive --files-only --no-mimetype --no-modtime \
    --timeout "$listing_timeout" 2>/dev/null) || dst_json=""
  [ -n "$src_json" ] && [ -n "$dst_json" ] || {
    echo "⚠️ 镜像清理: 源端或目标端列举失败，本轮跳过清理（宁漏勿错）"
    return 0
  }
  # 空/非法 JSON 可能是"真没有"也可能是列举静默失败（超时/驱动异常返回空）。
  # 源端清单失效 = 会把目标端删光（高危方向），必须区分并拒删。
  printf '%s' "$src_json" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "⚠️ 镜像清理: 源端清单不是合法 JSON 数组，本轮跳过清理（防误删）"
    return 0
  }

  # 保护①: 排除清单 → 关联数组。行格式 "- /path"（_escape_filter_glob 转过
  #   glob 元字符）；按字面比较，转义导致的失配方向是"少保护"，故对含元字符
  #   的行额外按去转义后的原文再存一份
  local -A _protect=()
  if [ -n "$fixed_exclude_file" ] && [ -f "$fixed_exclude_file" ]; then
    local _pl _pl_raw
    while IFS= read -r _pl; do
      _pl=${_pl#- }
      _pl=${_pl#/}
      [ -n "$_pl" ] && _protect["$_pl"]=1
      _pl_raw=$(printf '%s' "$_pl" | sed -e 's/\[\([][*?{}]\)\]/\1/g')
      [ -n "$_pl_raw" ] && [ "$_pl_raw" != "$_pl" ] && _protect["$_pl_raw"]=1
    done < "$fixed_exclude_file"
  fi

  local _cands
  _cands=$(printf '%s\n%s' "$src_json" "$dst_json" | jq -c -s --argjson smax "$prune_max" '
    (.[0] | map(.Path)) as $src_set
    | (.[1] | map(select((.IsDir // false) | not)))
    | map(select(.Path as $p | ($src_set | index($p)) | not))
    | .[0:($smax + 200)]  # 采样上限: 防病态巨型差集撑爆内存（真实删除另有 smax 闸）
    | map(.Path)' 2>/dev/null) || _cands="[]"

  local n_total n_protected=0 n_skip=0 deleted_this=0
  n_total=$(echo "$_cands" | jq 'length' 2>/dev/null || echo 0)
  [[ "$n_total" =~ ^[0-9]+$ ]] || n_total=0
  [ "$n_total" -gt 0 ] || return 0

  # 空源端拒删（高危方向最后一道闸）:
  #   源端清单为空数组而目标端有文件 ⇒ 差集 = 目标端全部 ⇒ 会把整个目标端删光。
  #   真实场景里"用户把 10TB 源端清空"远比"驱动异常返回空清单 / 源端路径配错 /
  #   临时不可读"罕见，二者在当前信息下不可区分 ⇒ 一律拒删并要求显式放行
  #   （OPENLIST_MIRROR_PRUNE_ALLOW_EMPTY_SOURCE=1）。宁可不镜像，不能误清备份。
  local _src_n
  _src_n=$(printf '%s' "$src_json" | jq 'length' 2>/dev/null || echo 0)
  [[ "$_src_n" =~ ^[0-9]+$ ]] || _src_n=0
  if [ "$_src_n" -eq 0 ] && [ "${OPENLIST_MIRROR_PRUNE_ALLOW_EMPTY_SOURCE:-0}" != "1" ]; then
    echo "⛔ 镜像清理拒绝执行: 源端清单为空但目标端有 ${n_total} 个文件 —— 更可能是驱动异常/路径配错而非真清空，本轮不删（确需清空请设 OPENLIST_MIRROR_PRUNE_ALLOW_EMPTY_SOURCE=1）"
    return 0
  fi

  # 删除前复核快照（见函数头）: 只在有候选时列举这一次
  local -A _recheck_set=()
  local _rc_json
  _rc_json=$(rclone lsjson "$source_path" --recursive --files-only --no-mimetype --no-modtime \
    --timeout "$listing_timeout" 2>/dev/null) || _rc_json=""
  printf '%s' "$_rc_json" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    echo "⚠️ 镜像清理: 删除前源端复核列举失败，本轮不删任何文件（宁漏勿错，下轮重试）"
    return 0
  }
  local _rp
  while IFS= read -r _rp; do
    [ -n "$_rp" ] && _recheck_set["$_rp"]=1
  done < <(printf '%s' "$_rc_json" | jq -r '.[] | select((.IsDir // false)|not) | .Path' 2>/dev/null)

  echo "🧹 镜像清理: 目标端多出 ${n_total} 个候选（源端已无），开始逐个复核删除（上限 ${prune_max}）"
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$deleted_this" -ge "$prune_max" ] && { n_skip=$((n_skip + 1)); continue; }
    # 保护①: 修复产物路径（排除清单）
    if [ -n "${_protect[$p]:-}" ]; then
      n_protected=$((n_protected + 1))
      continue
    fi
    # 保护②: 短哈希形态保护（折叠/短名修复落点，还原链路唯一载体）。
    #   两种形态，run 41516270971 实测后扩展:
    #   a) 任意层级的 **8位hex 文件名**（方法2·短名直传落点 <hash8>.<ext>）——
    #     跨任务/子任务视角下 marker 记录不可见（记录在修复时任务名的 marker
    #     里，sync 的是另一个同步对），排除清单护不到 ⇒ 按文件名形态硬保护。
    #     误保护代价 = 该文件留在目标端不镜像（安全方向）；真实源端文件恰好
    #     8位hex 命名的概率极低，且即使有也只是"少删"不是"错删"。
    #   b) 8位hex **目录**下的文件（目录级批量折叠落点 dest/<hash8>/<file>）。
    local _base="${p##*/}"
    if [[ "$_base" =~ ^[0-9a-f]{8}\.[A-Za-z0-9]{1,8}$ ]]; then
      n_protected=$((n_protected + 1))
      continue
    fi
    local _top="${p%%/*}"
    if [[ "$_top" =~ ^[0-9a-f]{8}$ ]] && [ "$p" != "$_top" ]; then
      n_protected=$((n_protected + 1))
      continue
    fi
    # 删除前复核: 该快照里仍有 → 不删（源端又出现/列举误差）
    if [ -n "${_recheck_set[$p]:-}" ]; then
      n_protected=$((n_protected + 1))
      continue
    fi
    if rclone deletefile "${dest_path}/${p}" "${RCLONE_RETRY_FLAGS[@]}" \
         --timeout "${OPENLIST_MKDIR_TIMEOUT:-120}s" >/dev/null 2>&1; then
      deleted_this=$((deleted_this + 1))
      echo "  🗑 镜像删除: $p"
    else
      n_skip=$((n_skip + 1))
      echo "  ⚠️ 删除失败（下轮重试）: $p"
    fi
  done < <(echo "$_cands" | jq -r '.[]' 2>/dev/null)
  echo "镜像清理完成: 删除 ${deleted_this} · 保护/复核放行 ${n_protected:-0} · 失败或超限跳过 ${n_skip}（候选 ${n_total}，上限 ${prune_max}）"
  # 事件留痕: 与修复管线事件日志同文件，收尾统计可引用
  if [ "$deleted_this" -gt 0 ]; then
    printf 'MIRROR_PRUNE|%s|%s|%s\n' "$task_name" "$deleted_this" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> /tmp/ol_fix_events.log 2>/dev/null || true
  fi
  return 0
}

# 带探测、重试和详细日志的同步函数
# 用法: sync_with_logging <source_path> <dest_path> <task_name> [rclone_extra_args...]
# 设置全局变量: SYNC_FAILED, SYNC_SKIPPED, SYNC_TRANSFERRED_BYTES, FAKE_SUCCESS_COUNT
# 注意: 始终返回 0，失败状态通过 SYNC_FAILED 传递（避免 set -e 下 step 直接退出）
sync_with_logging() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  shift 3
  local extra_args=("$@")
  local TIMESTAMP
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  # ⚠️ 必须带唯一后缀（2026-11-13 修，run 43173429624 实证）:
  #   旧写法只有**秒级**时间戳、没有 pid ⇒ 同一父任务下并行派发的子目录 worker
  #   若 task_name 相同且同一秒启动，会写**同一个日志文件**:
  #     ① 后启动者 `: > "$LAST_ATTEMPT_LOG"` 把前者内容截断；
  #     ② 两进程并发写同一文件，内容交错；
  #     ③ get_transferred_bytes_from_log 取"最后一条 X / Y"，可能取到**别人**的
  #        大额进度行 ⇒ 记账虚高。现场: 第 13 对（task2-wopan175）报
  #        `834.004 GiB / 34.4min`（≈410 MiB/s，物理不可能；同期 rclone 自报
  #        1.4–2.9 MiB/s，该对结束前真实进度是 `3.430 GiB / 14.902 GiB`）。
  #        该虚高一路累加进"本轮传输 907.086 GiB"，使整个指标失真。
  #   加 BASHPID 后每个 worker 日志独立，冲突根除（也保住错误解析不丢）。
  local LOG_FILENAME="${task_name}_sync_${TIMESTAMP}_${BASHPID:-$$}.log"

  echo "开始同步: $source_path -> $dest_path"

  if ! _check_openlist_backend_connectivity "$dest_path" "$LOG_FILENAME"; then
    SYNC_FAILED=1
    SYNC_SKIPPED=0
    SYNC_TRANSFERRED_BYTES=0
    # 后端级熔断（写探针判定该后端本轮不可写）→ 置位供 run_all_tasks
    # 立即后移轮转游标，而不是连续多轮把预算烧在同一个死后端上。
    # ⚠️ 键必须是 $dest_path（同步对路径），不能是 _backend_root_of 的结果:
    #   _backend_write_probe 按「后端 × 路径」分层缓存（F4），写的是 cache[$dest_path]；
    #   此处曾按后端根读，键对不上 ⇒ 判死信号恒丢 ⇒ SYNC_BACKEND_DEAD 永不置位
    #   ⇒ 既不立即后移游标、也不调 _backend_dead_mark ⇒ 死后端只能靠
    #   ROTATION_MAX_CONSECUTIVE_ATTEMPTS 阀门脱身（8 × 5.5h ≈ 44h，实测症状）。
    if [ "${_BACKEND_WRITE_PROBE_CACHE[$dest_path]:-}" = "0" ]; then
      SYNC_BACKEND_DEAD=1
      # 写探针（真实 PUT + 刷新缓存复核）判死属**强证据**，允许跨轮持久化（F6）
      SYNC_BACKEND_DEAD_STRONG=1
    fi
    return 0
  fi

  # OpenList 目标端在同步前刷新缓存，减少重复上传
  _refresh_openlist_cache "$dest_path"

  local LAST_ATTEMPT_LOG="${LOG_FILENAME}.last"

  # 执行一次 rclone sync/copy，带心跳输出
  # 用法: run_rclone_sync_once <attempt_label>
  run_rclone_sync_once() {
    local attempt_label="$1"
    echo "=== ${task_name} ${attempt_label} ===" | tee -a "$LOG_FILENAME"
    # fix_test 模式: 跳过实际 rclone 传输（调试目的是快速验证修复方法，
    # 全量 copy 动辄 GB 级/十分钟，与快速迭代背道而驰）。日志置空后
    # 8005/423/错误解析全部空匹配自动跳过，truth-check + lsf diff +
    # 修复管线 + 持久化验证照常执行
    if [ "${OPENLIST_FIX_TEST_MODE:-0}" = "1" ]; then
      echo "fix_test 模式: 跳过 ${attempt_label} 实际传输（直接 diff + 修复）" | tee -a "$LOG_FILENAME"
      : > "$LAST_ATTEMPT_LOG"
      return 0
    fi
    echo "OpenList sync args: ${extra_args[*]}" | tee -a "$LOG_FILENAME"
    : > "$LAST_ATTEMPT_LOG"

    # 心跳线程：rclone 扫描/检查阶段可能长时间没有换行输出，
    # 每分钟输出一次心跳，避免 GitHub Actions 页面看起来像卡死。
    (
      while true; do
        sleep 60
        echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ${task_name} ${attempt_label} still running..."
      done
    ) &
    local heartbeat_pid=$!

    # OpenList 目标端（特别是 wopan176 crypt 后端）上传速度慢，高并发易触发
    # 423 锁与假成功。transfers 默认 6（2026-09-15 由 1 提升: 隔离吞吐阶梯
    # 实测拐点在 12 流，6 × subdir_parallel=2 ≈ 12；重试已抬到 retries=3/
    # low-level=5 消化新目录并发 mkdir 的 423，见 rclone_flags.sh 头注释）；
    # 检查阶段只读列表，可提高并发大幅缩短 diff/比对耗时（上传并发低于检查）
    # 同时增加超时时间（单个文件可能耗时 1-2 分钟）
    local openlist_guard_flags=()
    if [[ "$dest_path" == openlist:* ]]; then
      openlist_guard_flags=(
        "--transfers" "${OPENLIST_TRANSFERS:-6}"
        "--checkers" "${OPENLIST_CHECKERS:-8}"
        "--contimeout" "30s"
        "--timeout" "30m"
      )
      echo "OpenList 目标端：启用低并发保护 (transfers=${OPENLIST_TRANSFERS:-6}, checkers=${OPENLIST_CHECKERS:-8}, timeout=30m)" | tee -a "$LOG_FILENAME"

      # 同步前主动刷新 OpenList 驱动 token
      # wopan176 的 OAuth access token 有效期约 5 分钟，长时间同步会过期
      _refresh_ol_drivers "$LOG_FILENAME"

      # 二次预检熔断：驱动刷新方法1 load_all 失败后走容器重启时，"重启成功"只证明
      # 容器活了，不证明后端驱动登录有效（run 33026674750: baidupan 登录
      # 失效，重启容器判成功后放行，rclone PUT 全部 409 Conflict 并空转
      # m1-m11 修复管线直至 job 被取消；m1-m11 为当时旧版 11 种方法的编号，
      # 现行方法已精简为 4 种并改用语义 ID，见 file_fix.sh 函数头）。此处用完整
      # 两层预检再验一次，
      # 仍不健康则带哨兵码退出——88 是 rclone 理论上不会返回的退出码，
      # 由 sync_with_logging 消费并转为入口预检失败的跳过语义。
      if ! _check_openlist_backend_connectivity "$dest_path" "$LOG_FILENAME"; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
        echo "🚫 OpenList 驱动刷新/重启后目标端仍未通过二次预检，熔断本轮传输（哨兵码 ${OPENLIST_POSTCHECK_SKIP_RC:-88}）" | tee -a "$LOG_FILENAME"
        return "${OPENLIST_POSTCHECK_SKIP_RC:-88}"
      fi

      # 传输期间定时保鲜: 仅传前刷一次撑不过 5 分钟 token 窗口，
      # 整批假成功事故的根因（run 32749862280 实锤，见函数头注释）
      _start_token_refresher
    fi

    # 容器共享锁: 传输期间声明"容器必须存活"，truth-check 的容器重启
    # （独占锁）会等全部共享持有者退出后才执行 —— 串行模式无争用，
    # 并行子目录同步（OPENLIST_SUBDIR_PARALLEL>=2）时防止重启打断在途上传。
    # 锁在心跳/token 保鲜线程全部停止后释放（子进程不持有 fd 7）
    _ol_lock_shared
    # 硬上限（2026-09-15 补，F23 的最后一处漏网）: 本次 sync 最多用「预算剩余 −
    # 尾部预留」，到点由 timeout 收掉（rc=124 → 失败分支 → 巩固/各级预算闸优雅收摊）。
    # 为什么必须加: 批次 copy 与巩固重试早已包装，**唯独子目录级 sync 没有** ——
    # run 34967321544 在 60min 预算下**超预算 12+ 分钟仍在跑**（状态文件 59min 无写入），
    # 长尾叠加就会撞 step 的 330min 硬杀（正是"预算闸只拦得住新开的工作、拦不住在途"
    # 那条教训的最后一处）。无预算锚点（调试/还原）时输出空串 = 不包装，行为不变。
    local _st_tmo="" _st_to=""
    # 单片上限统一走 _slice_cap_seconds（min(剩余预算−尾部预留, 批次片长)）。
    #   run 42141210516 实证: 只按「剩余预算 − 尾部预留」在轮初给 16130s（4.5h），
    #   task5-wopan175 的 `house-of-ester` 单目录跑 3.5h（速率掉到 34KiB/s、
    #   ETA 1 天），整轮只推进 20 个子目录、净传 0.74 GiB。与批次路径同口径封顶后，
    #   慢目录到点被 timeout 收掉，rclone sync 幂等、下轮续传，轮转名额不再被独占。
    if declare -F _slice_cap_seconds >/dev/null 2>&1; then
      _st_tmo=$(_slice_cap_seconds)
    elif declare -F _budget_slice_seconds >/dev/null 2>&1; then
      _st_tmo=$(_budget_slice_seconds)
    fi
    if [ -n "$_st_tmo" ]; then
      _st_to="timeout ${_st_tmo}"
      echo "本次 sync 硬上限 ${_st_tmo}s（min(预算剩余−尾部预留, 单片片长)；超出由 timeout 收掉后走优雅收摊）" | tee -a "$LOG_FILENAME"
    fi
    # openlist: 目标端用 copy 而非 sync（2026-11-01，run 41196672258/41219905962 实证）:
    #   sync 的清理阶段在 OpenList 上不可信，会删两类不该删的文件 ——
    #   ① 修复产物: 排除清单三来源（marker ∪ 本轮 ∪ 父级守卫）有结构性缺口
    #     （任务拆分/重命名后旧 marker 记录孤儿化，如 f27becd6 短哈希目录被
    #      整目录 Deleted + Removing directory），删了下轮重折叠，跨轮净进度为零；
    #   ② 源端真实文件: WebDAV+crypt 超长文件名场景下列举出现幻影条目，
    #     同一条 rclone 命令先 Copied (new) 后 Deleted 同一路径（aHR0cDov…jpg，
    #     84 分钟内 copy→删→copy 拉锯 3 轮）。
    #   备份语义本就"只增不减"（见 rclone_flags.sh 头注释），sync 的删除从未是需求；
    #   改 copy 同时省去传前的目标端全量列举（万级文件目录省数分钟）。
    #   非openlist 目标（无 guard flags 的远端）维持 sync 行为不变。
    if [ "${#openlist_guard_flags[@]}" -gt 0 ]; then
      ${_st_to} rclone copy "$source_path" "$dest_path" \
        "${RCLONE_DEFAULT_FLAGS[@]}" \
        "${openlist_guard_flags[@]}" \
        "${extra_args[@]}" \
        2>&1 | tee "$LAST_ATTEMPT_LOG"
    else
      ${_st_to} rclone sync "$source_path" "$dest_path" \
        "${RCLONE_DEFAULT_FLAGS[@]}" \
        "${openlist_guard_flags[@]}" \
        "${extra_args[@]}" \
        2>&1 | tee "$LAST_ATTEMPT_LOG"
    fi
    local attempt_status=${PIPESTATUS[0]}

    _stop_token_refresher
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
    _ol_lock_shared_release

    cat "$LAST_ATTEMPT_LOG" >> "$LOG_FILENAME"
    return "$attempt_status"
  }

  : > "$LOG_FILENAME"
  local SYNC_STATUS=0

  local fail_list="/tmp/${task_name}_sync_failures.txt"
  local fix_list="/tmp/${task_name}_sync_fixes.txt"
  : > "$fail_list"
  : > "$fix_list"

  _sync_fixed_files_exclusion

  run_rclone_sync_once "initial sync" || SYNC_STATUS=$?

  # ===== 预算/份额到点被 timeout 收掉 ⇒ 是"到点交棒"，不是失败 =====
  # 2026-11-11 加（run 42887432510 实证）:
  #   rc=124 只可能来自本文件包在外面的 `timeout ${_st_tmo}`（GNU timeout 的
  #   专属退出码），含义是"预算/份额到点被收掉"，**不是数据错误**。
  #   但下游判据是 `sync_status != 0` 即失败 ⇒ 每个被份额截断的直连对都被记成
  #   「同步失败」: 现场 gd:1 `0 B / 0 B, 0 B/s` 收尾 failed；两个轮次各 15/21
  #   判失败里有一大批属于这种。三个连带伤害:
  #     ① 发「同步失败」告警（用户看到假故障）；
  #     ② _sync_task_finalize 见 SYNC_FAILED≠0 会对 openlist 目标调用
  #        split_on_sync_failure（真去切大文件）—— 被假失败触发；
  #     ③ 父级按 failed 聚合子目录，统计与事实不符。
  #   份额机制让"到点截断"成为常态（每个大对每轮都会遇到），故必须改语义。
  #   只在 rc=124 时降级: 真失败（4xx/5xx/连接断）退出码不是 124，不受影响。
  if [ "$SYNC_STATUS" -eq 124 ]; then
    echo "⏳ initial sync 被预算/份额上限截断（rc=124）→ 按「到点交棒」处理: 不判失败、不进重试链、不触发大文件切割（未传部分下轮接力）"
    SYNC_TIME_EXHAUSTED=1
    SYNC_STATUS=0
  fi

  # ===== 目标端配额已满 ⇒ 终态错误，快速失败（2026-11-12 加）=====
  # 现场（run 43001486184，gd:backup）:
  #   `googleapi: Error 403: The user's Drive storage quota has been exceeded.`
  #   实际配额: Used 2.883 TiB / Total 15 GiB（付费容量掉了）⇒ 任何写入必失败。
  #   当时的浪费: rclone 内部 --retries 3，每次 ~3 分钟，一个 gd 对白烧 ~13 分钟；
  #   一轮 5 个 gd 对 ≈ 65 分钟（占 320 分钟预算 20%），且必然 0 产出。
  # 做法: 识别该错误 → ①判失败（这是真错误，不是到点交棒）②写"本轮该后端配额满"
  #   标记，供并行调度跳过同后端其余同步对 ③跳过镜像清理/truth-check/修复管线
  #   （配额满时它们全是空转）④发一条明确的人话告警，指向"扩容或清理"。
  # 为什么必须快速失败: 配额是**账号侧终态**，重试再多次也不会自愈 —— 与登录
  #   "被拒即 fail fast"同一判断（见 openlist_api.sh _get_openlist_token 注释）。
  local _quota_hit=0
  if [ -f "$LAST_ATTEMPT_LOG" ] \
     && grep -qiE 'storage quota has been exceeded|quota exceeded|storageQuotaExceeded' "$LAST_ATTEMPT_LOG" 2>/dev/null; then
    _quota_hit=1
  fi
  if [ "$_quota_hit" -eq 1 ]; then
    local _qroot
    # 键必须按**远端**分组（gd / openlist:<upstream>），不能用 _backend_root_of：
    #   后者对非 openlist 目标返回整个 dest 路径 ⇒ gd:0/gd:1/gd:backup 各成一键，
    #   「跳过同后端」永远匹配不到（run 43125112722 实测命中 0 次、403 仍 17 次）。
    if declare -F _quota_backend_key >/dev/null 2>&1; then
      _qroot=$(_quota_backend_key "$dest_path")
    else
      _qroot=$(_backend_root_of "$dest_path" 2>/dev/null || echo "$dest_path")
    fi
    echo "🈵 目标端配额已满（${_qroot}）: 写入被服务端拒绝 → 本轮跳过该后端其余同步对（扩容/清理容量后自愈，非代码问题）"
    SYNC_FAILED=1
    SYNC_TIME_EXHAUSTED=0
    : > "${OPENLIST_QUOTA_FLAG_DIR:-/tmp}/ol_quota_exhausted_$(printf '%s' "$_qroot" | tr '/:' '__')" 2>/dev/null || true
    # 配额满时的下游全无意义: 直接收尾（不清理、不 truth-check、不修复、不重试）
    _sync_serialize_fixed_files 2>/dev/null || true
    _sync_accumulate_fixed_results 2>/dev/null || true
    return 0
  fi

  # ===== 目标端镜像清理（受控 delete 通道）=====
  # 位置: initial sync 之后、重试链之前 —— 423/409 重传会把误删的源端文件
  #   重新传回（copy 不删除，但 rclone 内部 attempt 仍按文件清单跑），清理
  #   放在它前面避免刚删的候选又被重传。复制了 _sync_fixed_files_exclusion
  #   的排除文件路径形态（同 BASHPID 命名）供保护②复用。
  # 注意: fixed_exclude 文件由 _sync_fixed_files_exclusion 在本函数作用域内
  #   以 local 变量生成，这里按同一命名约定重新推导（存在才保护，不存在=无
  #   修复条目，保护②自动为空）。
  if [[ "$dest_path" == openlist:* ]]; then
    # 二次预检熔断（88）时目标端已判不健康，清理只会逐个 delete 全失败白烧
    # 时间 ⇒ 跳过（不删 = 安全方向，下轮再说）
    if [ "$SYNC_STATUS" -eq "${OPENLIST_POSTCHECK_SKIP_RC:-88}" ]; then
      echo "⏭ 镜像清理跳过: 本次 initial sync 触发二次预检熔断（后端不健康）"
    else
      _sync_mirror_prune "$source_path" "$dest_path" \
        "/tmp/${task_name}_fixed_exclude_${BASHPID:-$$}.txt" || true
    fi
  fi

  # 二次预检熔断哨兵（88, rclone 理论上不会返回的退出码）：驱动刷新/
  # 容器重启后目标端仍不健康 ⇒ 与入口预检失败同义，无传输、不进
  # truth-check/修复管线、不发部分失败通知，直接置失败态收尾，
  # 留下本次同步日志供排查，交由后续轮次自愈
  if [ "$SYNC_STATUS" -eq "${OPENLIST_POSTCHECK_SKIP_RC:-88}" ]; then
    SYNC_FAILED=1
    SYNC_SKIPPED=0
    SYNC_TRANSFERRED_BYTES=0
    # 键口径与入口预检同（见上文注释）: 写探针按 $dest_path 缓存
    if [ "${_BACKEND_WRITE_PROBE_CACHE[$dest_path]:-}" = "0" ]; then
      SYNC_BACKEND_DEAD=1
      # 写探针（真实 PUT + 刷新缓存复核）判死属**强证据**，允许跨轮持久化（F6）
      SYNC_BACKEND_DEAD_STRONG=1
    fi
    return 0
  fi

  _sync_retry_8005

  _sync_retry_423

  # 409 与 423 同因（并发 mkdir 竞争 / 目录已存在），2026-09-17 起同等对待。
  # 顺序放在 423 之后: 先走完已有重试链，再对 409 兜一轮，避免两者互相等待。
  _sync_retry_409

  # ===== 子目录级 409 死目录快速失败（2026-11-03 加）=====
  # 为什么需要: 批次路径有 _batch_409_deadlock 闸，但**子目录级 initial sync**
  #   绕开了批次循环。run 41568255043 实证: task1_1024j_套图_逐月su 的子目录
  #   sync 跑 09:06→10:59（近 2h），仅 4 个文件成功落地、487 次 409 ——
  #   超长文件名（FireShot Capture …）在该后端确定性建不出父目录，
  #   rclone 的 retries × low-level 全打在同一处，2h 预算换 4 个文件。
  # 判据与批次闸同口径（两个条件同时成立，防误杀可自愈的竞争冲突）:
  #   ① 409 计数 ≥ OPENLIST_409_FAST_FAIL_MIN（默认 20）
  #   ② 本次 sync 零字节落盘（Transferred 为 0 且无 Copied 行）
  # 命中后不再等下一轮重试，直接交修复管线（它有 base64 目录/短哈希/分卷
  #   等 4 种方法，实测能把这类文件救回来），省下的时间给其他子目录。
  local _n409_sync=0
  _n409_sync=$(grep -acE 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' "$LAST_ATTEMPT_LOG" 2>/dev/null || true)
  [[ "$_n409_sync" =~ ^[0-9]+$ ]] || _n409_sync=0
  if [ "$_n409_sync" -ge "${OPENLIST_409_FAST_FAIL_MIN:-20}" ]; then
    # 条件②内联判定（不调 task_engine 的 _batch_409_deadlock: 本文件是更底层的
    #   模块，反向依赖上层函数是反模式，且 load_all 顺序一变就静默失效）
    local _d_bytes _d_copied=0
    _d_bytes=$(get_transferred_bytes_from_log "$LAST_ATTEMPT_LOG" 2>/dev/null || echo 0)
    [[ "$_d_bytes" =~ ^[0-9]+$ ]] || _d_bytes=0
    grep -qE 'INFO  : .*: Copied' "$LAST_ATTEMPT_LOG" 2>/dev/null && _d_copied=1
    if [ "$_d_bytes" -eq 0 ] && [ "$_d_copied" -eq 0 ]; then
      echo "🛑 子目录级 sync: ${_n409_sync} 次 409 且零字节落盘（阈值 ${OPENLIST_409_FAST_FAIL_MIN:-20}）→ 判该目录确定性建不出来，跳过后续重试，直接交修复管线（折叠/短名/base64/分卷）" | tee -a "$LOG_FILENAME"
      SYNC_STATUS=0
    fi
  fi

  # ===== truth-check（任意 openlist: 目标端通用）=====
  # 放在缺失文件 diff 之前：本轮有传输则重启 OpenList 容器取后端真值列表，
  # diff 才能把"PUT 假成功"文件（仅存在于缓存）识别为缺失并送修复管线。
  _openlist_truth_check "$dest_path" "$LOG_FILENAME" || true

  # ===== 缺失文件修复管线 =====
  # 不依赖任何错误码：同步后只要源端有、目标端没有的文件（含 rclone 报告
  # "成功"但未持久化的假成功文件），一律送 try_fix_failed_file 修复
  # （目录创建 → base64URL 编码 → zip/7z/分卷/API 多种方式），不阻止后续 task
  local fix_log=""
  local HAS_OBJECT_NOT_FOUND=0

  _sync_fix_missing_files

  _sync_persist_verify_and_retry

  _sync_parse_object_not_found

  # 发送同步结果通知
  # 重试链（8005/423/409）内也可能再次被 timeout 收掉（各自 run_rclone_sync_once
  # 共用同一 _slice_cap_seconds 包装）⇒ 调用方若在链尾才拿到 124，仍会被判失败。
  # 故在**交给通知层之前**再归一化一次（与 initial sync 后那次同义，见其注释）。
  if [ "$SYNC_STATUS" -eq 124 ]; then
    echo "⏳ 重试链末尾仍被预算/份额上限截断（rc=124）→ 按「到点交棒」处理（不判失败）"
    SYNC_TIME_EXHAUSTED=1
    SYNC_STATUS=0
  fi

  _send_sync_result_notification \
    "$source_path" "$dest_path" "$task_name" "$SYNC_STATUS" \
    "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" \
    "$fail_list" "$fix_list" \
    "$HAS_OBJECT_NOT_FOUND" \
    "${extra_args[@]}"

  _sync_serialize_fixed_files

  _sync_accumulate_fixed_results

  # 后端级熔断（修复阶段才暴露的那一类: 同一挂载根连续 N 个目录不可写，
  # 见 file_fix.sh _BACKEND_DEAD）: 预检当时还放行了，但本同步对的实际
  # 结果是"写不进"，同样给轮转让路信号，避免连续多轮重复烧预算
  local _be_root
  _be_root=$(_backend_root_of "$dest_path" 2>/dev/null || echo "$dest_path")
  [ "${_BACKEND_DEAD[$_be_root]:-0}" = "1" ] && SYNC_BACKEND_DEAD=1

  rm -f "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" "$fail_list" "$fix_list" "$fix_log" 2>/dev/null || true
  # 始终返回 0：失败状态已通过 SYNC_FAILED 全局变量传递，
  # 在 set -e 下返回非零会导致整个 step 立即退出，后续同步与
  # split_on_sync_failure 均无法执行。
  return 0
}
