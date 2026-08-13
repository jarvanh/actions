#!/bin/bash
# ===== OpenList 同步工具 — 核心同步引擎 =====
# 封装 rclone sync/copy，提供:
#   - 同步前 OpenList 缓存刷新（避免 stale listing 导致重复上传）
#   - HTTP 423 Locked 重试（OpenList/WebDAV 临时文件锁）
#   - HTTP 405 Method Not Allowed 补救（预删除冲突文件 + 刷新缓存）
#   - 405/409 失败文件修复（调用 try_fix_failed_file）
#   - object not found 错误处理
#   - 结构化同步结果通知（含源/目标大小、差异文件列表、排除规则）
#
# 依赖: utils.sh, telegram.sh, fix.sh (try_fix_failed_file)
# 依赖环境变量:
#   RCLONE_DEFAULT_FLAGS — 共用 rclone 参数数组（在 workflow 文件中定义）
#   TELEGRAM_BOT_TOKEN   — 用于发送日志文件
#   TELEGRAM_CHAT_ID     — 用于发送日志文件

# 同步前刷新 OpenList 服务端目录缓存
# 避免 PROPFIND 返回 stale listing 导致 rclone 看不到已存在文件而重复上传
# 用法: _refresh_openlist_cache <dest_path>
_refresh_openlist_cache() {
  local dest_path="$1"
  [[ "$dest_path" == openlist:* ]] || return 0

  local ol_path="${dest_path#openlist:}"
  ol_path="/${ol_path}"
  local ol_token
  ol_token=$(jq -r '.token' /dropbox/self-hosted/openlist/data/config.json 2>/dev/null || echo "")
  if [ -z "$ol_token" ] || [ "$ol_token" = "null" ]; then
    echo "OpenList token 不可用，跳过缓存刷新"
    return 0
  fi

  # 刷新前获取文件数，用于校验缓存是否已过期
  local before_count=0 before_json
  before_json=$(timeout 120 rclone size "$dest_path" --json 2>/dev/null || true)
  before_count=$(echo "$before_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  echo "刷新 OpenList 缓存: $ol_path (刷新前文件数: $before_count)"

  curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"$ol_path\",\"recursive\":true}" \
    >/dev/null 2>&1 || true

  # 等待缓存刷新完成（60s，确保递归刷新大目录完成）
  echo "等待缓存刷新完成 (60s)..."
  sleep 60

  # 刷新后获取文件数，校验缓存是否已更新
  local after_count=0 after_json
  after_json=$(timeout 120 rclone size "$dest_path" --json 2>/dev/null || true)
  after_count=$(echo "$after_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  echo "缓存刷新后文件数: $after_count"

  if [ "$before_count" != "$after_count" ]; then
    echo "⚠️ 缓存刷新改变了 listing: $before_count → $after_count 个文件（刷新前缓存已过期）"
  else
    echo "缓存刷新前后文件数一致 ($after_count)，listing 稳定"
  fi
}

# 带探测、重试和详细日志的同步函数
# 用法: sync_with_logging <source_path> <dest_path> <task_name> [rclone_extra_args...]
# 设置全局变量: SYNC_FAILED, SYNC_SKIPPED, SYNC_TRANSFERRED_BYTES
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

  # OpenList 目标端在同步前刷新缓存，减少重复上传
  _refresh_openlist_cache "$dest_path"

  local LAST_ATTEMPT_LOG="${LOG_FILENAME}.last"

  # 执行一次 rclone sync/copy，带心跳输出
  # 用法: run_rclone_sync_once <attempt_label>
  run_rclone_sync_once() {
    local attempt_label="$1"
    echo "=== ${task_name} ${attempt_label} ===" | tee -a "$LOG_FILENAME"
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

    # _SYNC_MODE=copy 时用 rclone copy（不删除目标端多余文件），否则 rclone sync
    local rclone_cmd="sync"
    if [ "${_SYNC_MODE:-sync}" = "copy" ]; then
      rclone_cmd="copy"
    fi

    rclone "$rclone_cmd" "$source_path" "$dest_path" \
      "${RCLONE_DEFAULT_FLAGS[@]}" \
      "${extra_args[@]}" \
      2>&1 | tee "$LAST_ATTEMPT_LOG"
    local attempt_status=${PIPESTATUS[0]}

    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true

    cat "$LAST_ATTEMPT_LOG" >> "$LOG_FILENAME"
    return "$attempt_status"
  }

  : > "$LOG_FILENAME"
  local SYNC_STATUS=0
  run_rclone_sync_once "initial sync" || SYNC_STATUS=$?

  # ===== HTTP 423 Locked 重试 =====
  # OpenList / WebDAV 可能临时锁定目标对象并返回 HTTP 423。
  # 延迟后重跑整次 sync；已完成文件会被 rclone 跳过，主要补偿锁定残留文件。
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

  # ===== HTTP 405 Method Not Allowed 补救 =====
  # OpenList 后端不允许 PUT 覆盖已存在文件，返回 405。
  # rclone check 预删除可能因 WebDAV PROPFIND 不完整而漏掉部分文件，
  # 这里在 sync 失败后从日志解析 405 失败的文件，逐个 deletefile 后重试。
  if [[ "$dest_path" == openlist:* ]] && grep -Eqi 'Method Not Allowed: 405|405 Method Not Allowed' "$LAST_ATTEMPT_LOG"; then
    local retry_405_attempts="${OPENLIST_405_RETRY_ATTEMPTS:-3}"
    local retry_405_index

    for ((retry_405_index = 1; retry_405_index <= retry_405_attempts; retry_405_index++)); do
      echo "检测到 OpenList 405 Method Not Allowed，解析失败文件并预删除后重试 ${retry_405_index}/${retry_405_attempts}。" | tee -a "$LOG_FILENAME"

      local retry_405_deleted=0
      while IFS= read -r failed_line; do
        [ -z "$failed_line" ] && continue
        echo "405 补救: 预删除 ${dest_path}/${failed_line}" | tee -a "$LOG_FILENAME"
        local delete_out
        delete_out=$(rclone deletefile "${dest_path}/${failed_line}" \
             --retries 1 --low-level-retries 1 \
             --timeout 2m --contimeout 30s \
             2>&1) && retry_405_deleted=$((retry_405_deleted + 1)) || \
             echo "405 补救: deletefile 结果: $delete_out" | tee -a "$LOG_FILENAME"
      done < <(
        grep -E 'ERROR : .+: Failed to copy.*405 Method Not Allowed' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
          sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
      )

      # 刷新 OpenList 服务端目录缓存，清除"幽灵文件"
      # （PROPFIND 返回缓存中已不存在的文件 → rclone 尝试覆盖 → 405）
      local ol_path="${dest_path#openlist:}"
      ol_path="/${ol_path}"
      local ol_token
      ol_token=$(jq -r '.token' /dropbox/self-hosted/openlist/data/config.json 2>/dev/null || echo "")
      if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
        echo "405 补救: 刷新 OpenList 缓存 $ol_path" | tee -a "$LOG_FILENAME"
        curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
          -H "Authorization: $ol_token" \
          -H "Content-Type: application/json" \
          -d "{\"path\":\"$ol_path\",\"recursive\":true}" \
          >/dev/null 2>&1 || true
        sleep 3
      fi

      echo "405 补救: 已预删除 $retry_405_deleted 个文件，已刷新缓存，重新 sync" | tee -a "$LOG_FILENAME"
      SYNC_STATUS=0
      run_rclone_sync_once "405 retry ${retry_405_index}/${retry_405_attempts}" || SYNC_STATUS=$?

      if ! grep -Eqi 'Method Not Allowed: 405|405 Method Not Allowed' "$LAST_ATTEMPT_LOG"; then
        break
      fi
    done
  fi

  # ===== 405/409 失败文件修复 =====
  # 尝试修复 405/409 失败的文件（目录创建→base64URL编码→多种方式同步），不阻止后续 task
  local fail_list="/tmp/${task_name}_sync_failures.txt"
  local fix_list="/tmp/${task_name}_sync_fixes.txt"
  : > "$fail_list"
  : > "$fix_list"
  local fix_log=""
  local HAS_405_409=0
  local HAS_OBJECT_NOT_FOUND=0
  if [[ "$dest_path" == openlist:* ]] && grep -Eqi 'Method Not Allowed: 405|405 Method Not Allowed|409 Conflict' "$LAST_ATTEMPT_LOG"; then
    HAS_405_409=1
    echo "=== ${task_name} 尝试修复 405/409 失败文件 ===" | tee -a "$LOG_FILENAME"

    local fix_log="file_fix_${task_name}_$(date +%Y%m%d_%H%M%S).log"
    echo "=== 405/409 修复日志 - $(date) ===" > "$fix_log"

    while IFS= read -r failed_line; do
      [ -z "$failed_line" ] && continue

      local file_size="未知"
      local file_size_bytes=0
      local size_json
      size_json=$(rclone size "${source_path}/${failed_line}" --json 2>/dev/null || echo '{}')
      if [ -n "$size_json" ] && [ "$size_json" != "{}" ]; then
        file_size_bytes=$(echo "$size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
        [[ "$file_size_bytes" =~ ^[0-9]+$ ]] || file_size_bytes=0
        file_size=$(format_bytes "$file_size_bytes")
      fi

      echo "修复中: ${failed_line} (${file_size})" | tee -a "$LOG_FILENAME"

      try_fix_failed_file "$source_path" "$dest_path" "$task_name" "$failed_line" "$fix_log" || true

      if [ "$TRY_FIX_STATUS" = "success" ]; then
        echo "修复成功: ${failed_line} -> 方法: ${TRY_FIX_METHOD}" | tee -a "$LOG_FILENAME"
        echo "${TRY_FIX_ORIGINAL}|${TRY_FIX_ALTERNATIVE}|${TRY_FIX_METHOD}|${file_size}|${file_size_bytes}" >> "$fix_list"
      else
        echo "修复失败: ${failed_line} - ${TRY_FIX_MESSAGE}" | tee -a "$LOG_FILENAME"
        echo "${failed_line}|${file_size}|${TRY_FIX_MESSAGE}" >> "$fail_list"
      fi
    done < <(
      grep -E 'ERROR : .+: Failed to copy.*(405 Method Not Allowed|409 Conflict)' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
        sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
    )

  fi

  # ===== object not found 错误解析（源文件不存在）=====
  if grep -Eqi 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null; then
    HAS_OBJECT_NOT_FOUND=1
    echo "=== ${task_name} 检测到 object not found 错误（源文件不存在）===" | tee -a "$LOG_FILENAME"
    while IFS= read -r failed_line; do
      [ -z "$failed_line" ] && continue
      # 跳过已在 405/409 修复中处理的文件
      grep -qF "${failed_line}|" "$fail_list" 2>/dev/null && continue
      echo "源文件不存在: ${failed_line}" | tee -a "$LOG_FILENAME"
      echo "${failed_line}|未知|源文件不存在 (object not found)" >> "$fail_list"
    done < <(
      grep -E 'ERROR : .+: Failed to copy.*object not found' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
        sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' | sort -u
    )
  fi

  # 发送同步结果通知
  _send_sync_result_notification \
    "$source_path" "$dest_path" "$task_name" "$SYNC_STATUS" \
    "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" \
    "$fail_list" "$fix_list" "$fix_log" \
    "$HAS_405_409" "$HAS_OBJECT_NOT_FOUND" \
    "${extra_args[@]}"

  # 把 fix_list 序列化为 JSON 供 save_sync_marker 使用
  # 格式: [{original, alternative, method, size_human, size_bytes, restore: {kind, summary, steps, script}}]
  # restore 字段记录还原方式，便于日后从目标端恢复原始文件
  LAST_SYNC_FIXED_FILES_JSON="[]"
  if [ -s "$fix_list" ]; then
    LAST_SYNC_FIXED_FILES_JSON=$(jq -R -s '
      def restore_info($orig; $alt; $method; $src; $dst):
        # 10 种修复方式精确识别：
        #   "base64URL 编码目录 + 原文件名"                → 仅 b64 目录
        #   "原路径 + 原文件名"                             → 原样 copy
        #   "base64URL 编码目录 + base64URL 编码文件名"    → b64 目录+文件名
        #   "原路径 + base64URL 编码文件名"                → 仅 b64 文件名
        #   "base64URL 编码目录 + zip 压缩包"              → zip(+b64dir)
        #   "原路径 + zip 压缩包"                          → zip
        #   "base64URL 编码目录 + 7z 压缩包"               → 7z(+b64dir)
        #   "原路径 + 7z 压缩包"                           → 7z
        #   "base64URL 编码目录 + API 自动生成文件名"      → api rename(+b64dir)
        #   "原路径 + API 自动生成文件名"                  → api rename
        # 注: 不能用 ".*文件名" 模糊匹配，"原文件名" 里也有 "文件名" 3 个字，会误判
        ($method | test("base64URL 编码目录 ")) as $has_b64_dir
        | ($method | test("base64URL 编码文件名")) as $has_b64_name
        | ($method | test("zip 压缩包")) as $has_zip
        | ($method | test("7z 压缩包")) as $has_7z
        | ($method | test("API 自动生成文件名")) as $has_api
        # 原目录部分（去掉文件名）和文件名
        | ([$orig | split("/") | .[0:-1] | join("/"), $orig | split("/") | .[-1]]) as [$orig_dir, $orig_name]
        | ([$alt  | split("/") | .[0:-1] | join("/"), $alt  | split("/") | .[-1]]) as [$alt_dir,  $alt_name]
        | if   $has_zip      then {kind:"zip",
            summary: "文件被打包为 .zip（存储模式 mx=0）",
            steps:   ["下载目标端 " + $alt, "执行: 7z x <alt_zip> -o<output_dir>（或 unzip）", "解压后得到 " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.zip\" --progress\n7z x \"$TMP/package.zip\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/out/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_7z       then {kind:"seven_zip",
            summary: "文件被打包为 .7z（存储模式 mx=0）",
            steps:   ["下载目标端 " + $alt, "执行: 7z x <alt_7z> -o<output_dir>", "解压后得到 " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.7z\" --progress\n7z x \"$TMP/package.7z\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/out/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_api      then {kind:"api_rename",
            summary: "文件名被 OpenList API 自动改写（前缀 file_<ts>_<pid>_api，扩展名保留）",
            steps:   ["下载目标端 " + $alt, "根据内容哈希对比或直接重命名为: " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_FNAME=\"" + $alt_name + "\"\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 已直接保存为原始文件名。内容校验可用: rclone hashsum SHA1 \"${SRC}/${ORIG}\" 与 sha1sum \"$TMP/${ORIG_FNAME}\" 对比\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif ($has_b64_dir and $has_b64_name) then {kind:"base64url_both",
            summary: "目录最末一层和文件名均做了 base64URL 编码",
            steps:   ["取目录最末层路径段 → base64URL 解码得到原目录名", "取文件名（扩展名前部分） → base64URL 解码得到原文件名"],
            script:  "set -euo pipefail\n# base64URL 解码工具: base64 -d 时要把 -_ 替换为 +/ 并补齐 = 填充\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\n# 把 ALT 路径按 / 分段，dir 末段和文件名做 base64URL 解码即可还原 ORIG 路径\n# 脚本给出示例：下载后按原名保存\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_b64_dir then {kind:"base64url_dir",
            summary: "最末一层目录名做了 base64URL 编码，文件名保持原样",
            steps:   ["取目录最末层路径段 → base64URL 解码即得原目录名", "文件名无需改动"],
            script:  "set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_b64_name then {kind:"base64url_name",
            summary: "文件名（不含扩展名部分）做了 base64URL 编码，目录保持原样",
            steps:   ["取文件名扩展名前部分 → base64URL 解码得到原文件名", "目录名无需改动"],
            script:  "set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          else {kind:"copy",
            summary: "文件按原路径原文件名直接 copyto，无需还原处理",
            steps:   ["目标端路径与源端相同，直接使用即可"],
            script:  "# 路径未变化，无需还原\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\n# 如需取回: rclone copyto \"${DST}/${ALT}\" ./local_copy"}
          end;
      split("\n") | map(select(length > 0)) | map(
        split("|") as $f
        | {
            original:    $f[0],
            alternative: $f[1],
            method:      $f[2],
            size_human:  $f[3],
            size_bytes:  ($f[4] // "0" | tonumber)
          }
        | . + {restore: (restore_info(.original; .alternative; .method; "'"$source_path"'"; "'"$dest_path"'"))}
      )
    ' "$fix_list" 2>/dev/null || echo "[]")
  fi

  # 累计到全局变量（供 auto-split 拆分模式下顶级 save_sync_marker 收集所有子目录的修复）
  # _sync_task_impl 在 current_depth=0 时初始化 GLOBAL_FIXED_FILES_JSON="[]"
  if [ -z "${GLOBAL_FIXED_FILES_JSON:-}" ]; then
    GLOBAL_FIXED_FILES_JSON="[]"
  fi
  if [ "$LAST_SYNC_FIXED_FILES_JSON" != "[]" ]; then
    GLOBAL_FIXED_FILES_JSON=$(jq -sc --argjson acc "$GLOBAL_FIXED_FILES_JSON" --argjson cur "$LAST_SYNC_FIXED_FILES_JSON" \
      '($acc + $cur) | unique_by(.original)' 2>/dev/null || echo "$GLOBAL_FIXED_FILES_JSON")
  fi

  rm -f "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" "$fail_list" "$fix_list" "$fix_log" /tmp/probe_src.txt /tmp/probe_dst.txt 2>/dev/null || true
  # 始终返回 0：失败状态已通过 SYNC_FAILED 全局变量传递，
  # 在 set -e 下返回非零会导致整个 step 立即退出，后续同步与
  # split_on_sync_failure 均无法执行。
  return 0
}

# 发送同步结果通知（从 sync_with_logging 拆分出来）
# 构建包含源/目标大小、差异文件列表、排除规则、修复结果的通知消息
# 设置全局变量: SYNC_FAILED, SYNC_SKIPPED, SYNC_TRANSFERRED_BYTES
_send_sync_result_notification() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  local sync_status="$4"
  local log_filename="$5"
  local last_attempt_log="$6"
  local fail_list="$7"
  local fix_list="$8"
  local fix_log="$9"
  local has_405_409="${10}"
  local has_object_not_found="${11}"
  shift 11
  local extra_args=("$@")

  SYNC_FAILED=0

  # 获取源端和目标端大小及文件数量（各只调一次 --json）
  local source_size_human="未知"
  local dest_size_human="未知"
  local source_count="未知"
  local dest_count="未知"
  local count_info=""
  local src_stats dst_stats

  src_stats=$(_get_path_stats "$source_path" "${extra_args[@]}")
  source_count=$(echo "$src_stats" | awk '{print $2}')
  source_size_human=$(echo "$src_stats" | awk '{print $3 ($4? " "$4 : "")}')
  local source_count_raw="$source_count"
  [ "$source_count" = "0" ] && source_count="未知"

  # 同步后刷新 OpenList 缓存，确保 _get_path_stats 拿到真实文件数
  # 避免 stale 缓存里残留"幽灵文件"导致 dest_count 虚高，误报同步成功
  if [[ "$dest_path" == openlist:* ]]; then
    echo "同步后刷新 OpenList 缓存以获取真实文件数..." | tee -a "$LOG_FILENAME"
    _refresh_openlist_cache "$dest_path"
  fi

  dst_stats=$(_get_path_stats "$dest_path" "${extra_args[@]}")
  dest_count=$(echo "$dst_stats" | awk '{print $2}')
  dest_size_human=$(echo "$dst_stats" | awk '{print $3 ($4? " "$4 : "")}')
  local dest_count_raw="$dest_count"
  [ "$dest_count" = "0" ] && dest_count="未知"

  # 始终显示文件数信息
  local diff_files_list=""
  if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]]; then
    local diff=$((source_count_raw - dest_count_raw))
    if [ "$diff" -ne 0 ]; then
      count_info="文件数差异：${diff} (源端 ${source_count} / 目标 ${dest_count})"
      diff_files_list=$(_build_diff_files_list "$source_path" "$dest_path" "${extra_args[@]}")
    else
      count_info="文件数：${source_count} (一致)"
    fi
  else
    count_info="文件数：源端 ${source_count} / 目标 ${dest_count}"
  fi

  # 提取 --exclude 规则，方便在通知中说明
  local exclude_list=""
  exclude_list=$(_build_exclude_bullets "${extra_args[@]}")

  # 构建 fix_summary（已修复文件：原始文件名 → 实际文件名）
  local fix_summary=""
  if [ -s "$fix_list" ]; then
    while IFS='|' read -r f_original f_alternative f_method f_size; do
      [ -z "$f_original" ] && continue
      if [ "$f_original" = "$f_alternative" ]; then
        fix_summary+="• ${f_original} (${f_size}) — ${f_method}"$'\n'
      else
        fix_summary+="• ${f_original} → ${f_alternative} (${f_size}, ${f_method})"$'\n'
      fi
    done < "$fix_list"
  fi
  [ -z "$fix_summary" ] && fix_summary="无"

  # 构建 fail_summary（无法修复的文件，含源/目标完整路径与修复过程）
  local fail_summary=""
  local fail_idx=0
  if [ -s "$fail_list" ]; then
    while IFS='|' read -r fpath fsize fmsg; do
      [ -z "$fpath" ] && continue
      fail_idx=$((fail_idx + 1))
      [ -n "$fail_summary" ] && fail_summary+=$'\n'
      fail_summary+="[${fail_idx}] 源文件：${source_path}/${fpath}"$'\n'
      fail_summary+="    目标文件：${dest_path}/${fpath}"$'\n'
      fail_summary+="    文件大小：${fsize}"$'\n'
      fail_summary+="    失败原因：${fmsg}"$'\n'
      # 从 fix_log 中按文件名分隔提取该文件对应的修复过程
      local fix_section=""
      if [ -f "$fix_log" ]; then
        fix_section=$(awk -v rel="$fpath" '
          index($0, "=== 尝试修复失败文件: " rel " ===") > 0 { capture=1; next }
          /=== 尝试修复失败文件: / && capture { capture=0 }
          capture { sub(/^\[[^]]*\] /, ""); print }
        ' "$fix_log" 2>/dev/null)
      fi
      if [ -n "$fix_section" ]; then
        fail_summary+="    修复过程："$'\n'
        while IFS= read -r log_line; do
          [ -z "$log_line" ] && continue
          fail_summary+="      ${log_line}"$'\n'
        done <<< "$fix_section"
      elif echo "$fmsg" | grep -qi 'object not found'; then
        fail_summary+="    修复过程：源文件不存在，无需修复"$'\n'
      else
        fail_summary+="    修复过程：无记录"$'\n'
      fi
    done < "$fail_list"
  fi
  [ -z "$fail_summary" ] && fail_summary="无"

  # 解析本次同步传输的字节数
  SYNC_TRANSFERRED_BYTES=$(get_transferred_bytes_from_log "$log_filename")
  SYNC_SKIPPED=0

  # 子目录拆分模式下，如果没有文件变更且无错误，跳过通知
  if [ "$SYNC_SKIP_QUIET" = "1" ] && [ ! -s "$fail_list" ] && [ ! -s "$fix_list" ]; then
    if ! grep -Eqi 'Copied|Deleted|Renamed|Moved' "$log_filename" 2>/dev/null; then
      SYNC_SKIPPED=1
      echo "无文件变更，跳过通知 (SYNC_SKIP_QUIET=1, task=${task_name})"
      rm -f "$log_filename" 2>/dev/null || true
      return 0
    fi
  fi

  # ===== 构建并发送通知消息 =====

  if [ -s "$fail_list" ]; then
    # 有无法同步的文件，标记失败以便上层触发大文件切割
    SYNC_FAILED=1
    # 根据错误类型构建状态消息
    local fail_status_msg="部分文件无法同步"
    if [ "$has_405_409" -eq 1 ] && [ "$has_object_not_found" -eq 1 ]; then
      fail_status_msg="OpenList 405/409 错误及源文件不存在，部分文件无法同步"
    elif [ "$has_405_409" -eq 1 ]; then
      fail_status_msg="OpenList 405/409 错误，部分文件无法同步"
    elif [ "$has_object_not_found" -eq 1 ]; then
      fail_status_msg="源文件不存在 (object not found)，部分文件无法同步"
    fi
    local partial_msg=""
    partial_msg+="⚠️ ${task_name} 部分文件同步失败"$'\n'
    partial_msg+='━━━━━━━━━━━━━━'$'\n'
    partial_msg+="源端大小：${source_size_human}"$'\n'
    partial_msg+="目标大小：${dest_size_human}"$'\n'
    partial_msg+="状态：${fail_status_msg}"$'\n'
    partial_msg+="${count_info}"$'\n'
    [ -n "$AUTO_SPLIT_INFO" ] && partial_msg+=$'\n'"${AUTO_SPLIT_INFO}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='📁 任务信息'$'\n'
    partial_msg+="• 任务：${task_name}"$'\n'
    partial_msg+="• 源端：${source_path}"$'\n'
    partial_msg+="• 目标：${dest_path}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='🚫 排除规则'$'\n'
    partial_msg+="${exclude_list}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='✅ 已通过其他方式同步（原始文件名 → 实际文件名）：'$'\n'
    partial_msg+="${fix_summary}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='❌ 无法同步文件：'$'\n'
    partial_msg+="${fail_summary}"
    if [ -n "$diff_files_list" ]; then
      partial_msg+=$'\n\n'"📋 差异文件列表："$'\n'
      partial_msg+="$diff_files_list"
    fi

    send_telegram_message "$partial_msg"

  elif [ -s "$fix_list" ]; then
    # 所有 405/409 文件都已通过其他方式同步
    local partial_msg=""
    partial_msg+="⚠️ ${task_name} 部分文件已通过其他方式同步"$'\n'
    partial_msg+='━━━━━━━━━━━━━━'$'\n'
    partial_msg+="源端大小：${source_size_human}"$'\n'
    partial_msg+="目标大小：${dest_size_human}"$'\n'
    partial_msg+="状态：405/409 文件已修复，但部分文件使用了其他方式同步"$'\n'
    partial_msg+="${count_info}"$'\n'
    [ -n "$AUTO_SPLIT_INFO" ] && partial_msg+=$'\n'"${AUTO_SPLIT_INFO}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='📁 任务信息'$'\n'
    partial_msg+="• 任务：${task_name}"$'\n'
    partial_msg+="• 源端：${source_path}"$'\n'
    partial_msg+="• 目标：${dest_path}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='🚫 排除规则'$'\n'
    partial_msg+="${exclude_list}"$'\n'
    partial_msg+=$'\n'
    partial_msg+='✅ 已通过其他方式同步（原始文件名 → 实际文件名）：'$'\n'
    partial_msg+="${fix_summary}"
    if [ -n "$diff_files_list" ]; then
      partial_msg+=$'\n\n'"📋 差异文件列表："$'\n'
      partial_msg+="$diff_files_list"
    fi

    send_telegram_message "$partial_msg"

  elif [ "$sync_status" -ne 0 ] || grep -Eqi '(^|[^[:alpha:]])(ERROR|Failed|timeout|forbidden|unauthorized|permission denied|connection refused)([^[:alpha:]]|$)' "$last_attempt_log"; then
    # 同步返回非零或日志包含错误关键字
    SYNC_FAILED=1
    # 检测是否为部分失败：目标已有部分文件但少于源端
    local is_partial_failure=0
    if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]] && \
     [ "$dest_count_raw" -gt 0 ] && [ "$dest_count_raw" -lt "$source_count_raw" ]; then
      is_partial_failure=1
    fi
    # 提取关键错误日志
    local critical_logs="无明显错误关键字"
    if [ -f "$log_filename" ]; then
      critical_logs=$(grep -Ei "error|failed|too large|timeout|permission denied|connection refused" "$log_filename" | tail -n 5 || echo "无明显错误关键字")
    fi
    local err_msg=""
    if [ "$is_partial_failure" -eq 1 ]; then
      err_msg+="⚠️ ${task_name} 部分文件同步失败"$'\n'
    else
      err_msg+="⚠️ ${task_name} 同步失败"$'\n'
    fi
    err_msg+='━━━━━━━━━━━━━━'$'\n'
    err_msg+="源端大小：${source_size_human}"$'\n'
    err_msg+="目标大小：${dest_size_human}"$'\n'
    if [ "$is_partial_failure" -eq 1 ]; then
      err_msg+="状态：部分文件同步失败 (exit=${sync_status})"$'\n'
    else
      err_msg+="状态：同步失败 (exit=${sync_status})"$'\n'
    fi
    err_msg+="${count_info}"$'\n'
    [ -n "$AUTO_SPLIT_INFO" ] && err_msg+=$'\n'"${AUTO_SPLIT_INFO}"$'\n'
    err_msg+=$'\n''📁 任务信息'$'\n'
    err_msg+="• 任务：${task_name}"$'\n'
    err_msg+="• 源端：${source_path}"$'\n'
    err_msg+="• 目标：${dest_path}"$'\n'
    err_msg+=$'\n''🚫 排除规则'$'\n'
    err_msg+="${exclude_list}"$'\n'
    err_msg+=$'\n''🧾 错误详情'$'\n'
    err_msg+="• 关键日志："$'\n'
    while IFS= read -r line; do
      [ -n "$line" ] && err_msg+="  ${line}"$'\n'
    done <<< "$critical_logs"
    if [ -n "$diff_files_list" ]; then
      err_msg+=$'\n'"📋 差异文件列表："$'\n'
      err_msg+="$diff_files_list"
    fi
    send_telegram_message "$err_msg"
    # 发送完整日志文件
    local err_log_size
    err_log_size=$(stat -c%s "$log_filename" 2>/dev/null || echo 0)
    if [ "$err_log_size" -gt 0 ] && [ "$err_log_size" -lt 50000000 ]; then
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"$log_filename" \
        -F caption="📁 ${task_name} 错误日志" || true
    fi
  else
    # 同步返回成功，检查是否有文件缺失（部分失败）
    local is_partial_success=0
    if [[ "$source_count_raw" =~ ^[0-9]+$ ]] && [[ "$dest_count_raw" =~ ^[0-9]+$ ]] && \
       [ "$dest_count_raw" -lt "$source_count_raw" ]; then
      is_partial_success=1
      SYNC_FAILED=1
    fi
    local ok_message
    if [ "$is_partial_success" -eq 1 ]; then
      # 同步"成功"但目标文件数少于源端，视为部分失败
      ok_message=""
      ok_message+="⚠️ ${task_name} 部分文件同步失败"$'\n'
      ok_message+='━━━━━━━━━━━━━━'$'\n'
      ok_message+="源端大小：${source_size_human}"$'\n'
      ok_message+="目标大小：${dest_size_human}"$'\n'
      ok_message+="状态：部分文件同步失败 (exit=0，文件数不一致)"$'\n'
      ok_message+="${count_info}"$'\n'
      ok_message+=$'\n''📁 任务信息'$'\n'
      ok_message+="• 任务：${task_name}"$'\n'
      ok_message+="• 源端：${source_path}"$'\n'
      ok_message+="• 目标：${dest_path}"$'\n'
      ok_message+=$'\n''🚫 排除规则'$'\n'
      ok_message+="${exclude_list}"$'\n'
      if [ -n "$diff_files_list" ]; then
        ok_message+=$'\n''📋 差异文件列表：'$'\n'
        ok_message+="$diff_files_list"
      fi
    elif [ -n "$diff_files_list" ]; then
      printf -v ok_message '%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s\n\n%s\n%s' \
        "✅ ${task_name} 同步完成" \
        '━━━━━━━━━━━━━━' \
        "源端大小：${source_size_human}" \
        "目标大小：${dest_size_human}" \
        "$count_info" \
        '📁 任务信息' \
        "• 任务：${task_name}" \
        "• 源端：${source_path}" \
        "• 目标：${dest_path}" \
        '🚫 排除规则' \
        "$exclude_list" \
        '📋 差异文件列表' \
        "$diff_files_list"
    else
      printf -v ok_message '%s\n%s\n%s\n%s\n%s\n\n%s\n%s\n%s\n%s\n\n%s\n%s' \
        "✅ ${task_name} 同步完成" \
        '━━━━━━━━━━━━━━' \
        "源端大小：${source_size_human}" \
        "目标大小：${dest_size_human}" \
        "$count_info" \
        '📁 任务信息' \
        "• 任务：${task_name}" \
        "• 源端：${source_path}" \
        "• 目标：${dest_path}" \
        '🚫 排除规则' \
        "$exclude_list"
    fi

    [ -n "$AUTO_SPLIT_INFO" ] && ok_message="${ok_message}"$'\n\n'"${AUTO_SPLIT_INFO}"

    send_telegram_message "$ok_message"
  fi
}
