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
#   - 缺失文件修复管线编排（4 种方法轮换 + 增量持久化）→ fix_pipeline.sh
#   - 同步结果通知构建（源/目标大小、差异列表、排除规则）→ sync_notify.sh
#
# 完整流程（本文件只做编排，各环节实现在上述模块）:
#   预检健康校验 → rclone sync → 重试(423/8005) → truth-check 取后端真值
#   → diff 出缺失文件 → 修复管线 → 结果通知
#
# 依赖: utils.sh, rclone_query.sh, openlist_api.sh, openlist_driver.sh,
#       fix_pipeline.sh, sync_notify.sh, marker.sh, telegram.sh, progress.sh
# 依赖环境变量:
#   RCLONE_DEFAULT_FLAGS — 共用 rclone 参数数组（在 flags.sh 中定义）
#   TELEGRAM_BOT_TOKEN   — 用于发送日志文件
#   TELEGRAM_CHAT_ID     — 用于发送日志文件

# 初始化同步会话状态（计数器/日志名/进度系统）
# 变量不加 local，故意写入调用方 shell（各 step source 后直接调用）
# 由 workflow 在每个同步 step 开头调用；依赖 progress.sh 的 progress_init
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


# ===== object not found 错误解析（源文件不存在）=====
# 依赖调用方作用域: LAST_ATTEMPT_LOG / fail_list / LOG_FILENAME / task_name / HAS_OBJECT_NOT_FOUND
_sync_parse_object_not_found() {
  if grep -Eqi 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null; then
    HAS_OBJECT_NOT_FOUND=1
    echo "=== ${task_name} 检测到 object not found 错误（源文件不存在）===" | tee -a "$LOG_FILENAME"
    while IFS= read -r failed_line; do
      [ -z "$failed_line" ] && continue
      # 跳过已在缺失文件修复中处理的文件
      grep -qF "${failed_line}|" "$fail_list" 2>/dev/null && continue
      echo "源文件不存在: ${failed_line}" | tee -a "$LOG_FILENAME"
      echo "${failed_line}|未知|源文件不存在 (object not found)" >> "$fail_list"
    done < <(
      grep -E 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
        sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
    )
  fi
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
  local LOG_FILENAME="${task_name}_sync_${TIMESTAMP}.log"

  echo "开始同步: $source_path -> $dest_path"

  if ! _check_openlist_backend_connectivity "$dest_path" "$LOG_FILENAME"; then
    SYNC_FAILED=1
    SYNC_SKIPPED=0
    SYNC_TRANSFERRED_BYTES=0
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

    # OpenList 目标端（特别是 wopan176 crypt 后端）上传速度慢且不支持高并发
    # 上传保持串行（transfers=1，给后端足够时间持久化每个文件，避免 "object not found"）；
    # 检查阶段只读列表，可提高并发大幅缩短 diff/比对耗时（上传仍逐个进行）
    # 同时增加超时时间（单个文件可能耗时 1-2 分钟）
    local openlist_guard_flags=()
    if [[ "$dest_path" == openlist:* ]]; then
      openlist_guard_flags=(
        "--transfers" "${OPENLIST_TRANSFERS:-1}"
        "--checkers" "${OPENLIST_CHECKERS:-8}"
        "--contimeout" "30s"
        "--timeout" "30m"
      )
      echo "OpenList 目标端：启用低并发保护 (transfers=1, checkers=8, timeout=30m)" | tee -a "$LOG_FILENAME"

      # 同步前主动刷新 OpenList 驱动 token
      # wopan176 的 OAuth access token 有效期约 5 分钟，长时间同步会过期
      _refresh_ol_drivers "$LOG_FILENAME"

      # 二次预检熔断：驱动刷新方法1 load_all 失败后走容器重启时，"重启成功"只证明
      # 容器活了，不证明后端驱动登录有效（run 33026674750: baidupan 登录
      # 失效，重启容器判成功后放行，rclone PUT 全部 409 Conflict 并空转
      # m1-m11 修复管线直至 job 被取消；m1-m11 为当时旧版 11 种方法的编号，
      # 现行方法已精简为 4 种并改用语义 ID，见 fix.sh 函数头）。此处用完整
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

    rclone sync "$source_path" "$dest_path" \
      "${RCLONE_DEFAULT_FLAGS[@]}" \
      "${openlist_guard_flags[@]}" \
      "${extra_args[@]}" \
      2>&1 | tee "$LAST_ATTEMPT_LOG"
    local attempt_status=${PIPESTATUS[0]}

    _stop_token_refresher
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true

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

  # 二次预检熔断哨兵（88, rclone 理论上不会返回的退出码）：驱动刷新/
  # 容器重启后目标端仍不健康 ⇒ 与入口预检失败同义，无传输、不进
  # truth-check/修复管线、不发部分失败通知，直接置失败态收尾，
  # 留下本次同步日志供排查，交由后续轮次自愈
  if [ "$SYNC_STATUS" -eq "${OPENLIST_POSTCHECK_SKIP_RC:-88}" ]; then
    SYNC_FAILED=1
    SYNC_SKIPPED=0
    SYNC_TRANSFERRED_BYTES=0
    return 0
  fi

  _sync_retry_8005

  _sync_retry_423

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
  _send_sync_result_notification \
    "$source_path" "$dest_path" "$task_name" "$SYNC_STATUS" \
    "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" \
    "$fail_list" "$fix_list" "$fix_log" \
    "$HAS_OBJECT_NOT_FOUND" \
    "${extra_args[@]}"

  _sync_serialize_fixed_files

  _sync_accumulate_fixed_results

  rm -f "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" "$fail_list" "$fix_list" "$fix_log" 2>/dev/null || true
  # 始终返回 0：失败状态已通过 SYNC_FAILED 全局变量传递，
  # 在 set -e 下返回非零会导致整个 step 立即退出，后续同步与
  # split_on_sync_failure 均无法执行。
  return 0
}
