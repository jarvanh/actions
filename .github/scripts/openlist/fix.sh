#!/bin/bash
# ===== OpenList 同步工具 — 失败文件修复函数 =====
# 处理 OpenList/WebDAV 405/409/8005 等无法同步的文件，尝试多种修复方式：
#   1. 创建目标目录（rclone mkdir → OpenList API mkdir → base64URL 编码目录名）
#   2. 多种方式同步文件：
#      方法1: 直接 rclone copyto
#      方法2: 文件名 base64URL 编码后上传
#      方法3: zip 压缩后上传
#      方法4: 7z 压缩后上传
#      方法5: OpenList API /fs/form 直传
#      方法6: 重命名文件后上传（避开敏感文件名）
#      方法7: 上传到父目录（跳过有问题的目录层级）
#      方法8: OpenList API /fs/put 流式上传（绕过 WebDAV）
#      方法9: 上传到 backup 根目录（最后手段）
#      方法10: base64 编码文件内容后上传（改变文件 hash 和内容特征）
#      方法11: 加密 zip 后上传（改变二进制特征）
#      方法12: 上传到临时目录后用 OpenList API move 移动
#
# 依赖: utils.sh (log_fix), telegram.sh (间接)
# 结果写入全局变量:
#   TRY_FIX_STATUS       — "success" 或 "failed"
#   TRY_FIX_ORIGINAL     — 原始文件相对路径
#   TRY_FIX_ALTERNATIVE  — 实际上传后的文件相对路径
#   TRY_FIX_METHOD       — 使用的修复方法描述
#   TRY_FIX_RESTORE      — 还原方法描述（如何从 ALTERNATIVE 还原到 ORIGINAL）
#   TRY_FIX_MESSAGE      — 失败原因（仅 status=failed 时）

try_fix_failed_file() {
  local source_path="$1"
  local dest_path="$2"
  local task_name="$3"
  local failed_file_rel="$4"
  local fix_log="$5"

  local src_file="${source_path}/${failed_file_rel}"
  local dst_file="${dest_path}/${failed_file_rel}"

  local file_name
  file_name="$(basename -- "$failed_file_rel")"
  local file_dir_rel
  file_dir_rel="$(dirname -- "$failed_file_rel")"
  local dst_dir="${dest_path}/${file_dir_rel}"

  # OpenList 内部路径（去掉 openlist: 前缀）
  local ol_dst_base="${dest_path#openlist:}"
  ol_dst_base="${ol_dst_base#/}"

  # 初始化结果变量
  TRY_FIX_STATUS="failed"
  TRY_FIX_ORIGINAL="$failed_file_rel"
  TRY_FIX_ALTERNATIVE=""
  TRY_FIX_METHOD=""
  TRY_FIX_RESTORE=""
  TRY_FIX_MESSAGE=""

  log_fix "$fix_log" "=== 尝试修复失败文件: $failed_file_rel ==="
  log_fix "$fix_log" "源文件: $src_file"
  log_fix "$fix_log" "原始目标: $dst_file"

  # 下载源文件到本地临时目录
  local temp_dir="temp_fix_$(date +%s)_$$"
  mkdir -p "$temp_dir"
  local local_file="$temp_dir/$file_name"

  log_fix "$fix_log" "下载源文件到本地..."
  rclone copyto "$src_file" "$local_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "rclone copy: $line"; done
  local copy_status=${PIPESTATUS[0]}

  if [ "$copy_status" -ne 0 ] || [ ! -f "$local_file" ]; then
    log_fix "$fix_log" "下载源文件失败，跳过修复"
    TRY_FIX_MESSAGE="无法从源端下载文件"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 1
  fi

  local file_size
  file_size=$(stat -c%s "$local_file" 2>/dev/null || echo 0)
  log_fix "$fix_log" "源文件已下载，大小: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "${file_size}B")"

  # ===== Step 1: 创建/确认目标目录 =====
  local dir_ok=0
  local used_base64_dir=0
  local actual_dst_dir="$dst_dir"
  local actual_ol_dir="/${ol_dst_base}/${file_dir_rel}"

  # 尝试 rclone mkdir
  log_fix "$fix_log" "尝试创建目标目录: $dst_dir"
  rclone mkdir "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "rclone mkdir: $line"; done
  local mkdir_status=${PIPESTATUS[0]}

  # rclone mkdir 退出码为 0 时仍需验证目录是否实际存在（WebDAV 可能静默失败）
  if [ "$mkdir_status" -eq 0 ]; then
    log_fix "$fix_log" "rclone mkdir 退出码 0，用 rclone lsd 验证目录是否实际存在..."
    rclone lsd "$dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s >/dev/null 2>&1
    local verify_status=$?
    if [ "$verify_status" -eq 0 ]; then
      dir_ok=1
      log_fix "$fix_log" "rclone lsd 验证成功，目录已确认存在"
    else
      log_fix "$fix_log" "rclone lsd 验证失败 (exit=$verify_status)，目录未实际创建，降级处理"
    fi
  else
    log_fix "$fix_log" "rclone mkdir 失败 (exit=$mkdir_status)，尝试 OpenList API mkdir..."
  fi

  # 降级处理：mkdir 失败或 lsd 验证失败时执行（OpenList API + base64URL）
  if [ "$dir_ok" -ne 1 ]; then
    local ol_token
    ol_token=$(_get_openlist_token)
    if [ -n "$ol_token" ]; then
      local mkdir_resp mkdir_http
      mkdir_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "$actual_ol_dir" '{path:$path}')" 2>&1)
      mkdir_http=$(echo "$mkdir_resp" | tail -n 1)
      log_fix "$fix_log" "OpenList API mkdir 响应: ${mkdir_http}"
      if echo "$mkdir_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
        dir_ok=1
        log_fix "$fix_log" "OpenList API mkdir 成功"
      fi
    fi

    # 目录创建仍失败 → base64URL 编码最底层文件夹名后重试
    if [ "$dir_ok" -ne 1 ] && [ "$file_dir_rel" != "." ] && [ -n "$file_dir_rel" ]; then
      log_fix "$fix_log" "目录创建失败，尝试 base64URL 编码文件夹名..."

      local parent_dir leaf_dir encoded_leaf new_file_dir_rel
      parent_dir="$(dirname -- "$file_dir_rel")"
      leaf_dir="$(basename -- "$file_dir_rel")"
      encoded_leaf=$(printf '%s' "$leaf_dir" | base64 | tr '+/' '-_' | tr -d '=')

      if [ "$parent_dir" = "." ]; then
        new_file_dir_rel="$encoded_leaf"
      else
        new_file_dir_rel="${parent_dir}/${encoded_leaf}"
      fi

      actual_dst_dir="${dest_path}/${new_file_dir_rel}"
      actual_ol_dir="/${ol_dst_base}/${new_file_dir_rel}"

      log_fix "$fix_log" "原始目录: $file_dir_rel"
      log_fix "$fix_log" "base64URL 编码目录: $new_file_dir_rel"

      rclone mkdir "$actual_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
        while IFS= read -r line; do log_fix "$fix_log" "rclone mkdir (base64URL): $line"; done
      mkdir_status=${PIPESTATUS[0]}

      if [ "$mkdir_status" -eq 0 ]; then
        log_fix "$fix_log" "rclone mkdir (base64URL) 退出码 0，用 rclone lsd 验证目录..."
        rclone lsd "$actual_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s >/dev/null 2>&1
        local b64_verify_status=$?
        if [ "$b64_verify_status" -eq 0 ]; then
          dir_ok=1
          used_base64_dir=1
          dst_file="${actual_dst_dir}/${file_name}"
          log_fix "$fix_log" "rclone lsd 验证成功 (base64URL)，目录已确认存在"
        else
          log_fix "$fix_log" "rclone lsd 验证失败 (base64URL, exit=$b64_verify_status)"
        fi
      fi

      if [ "$dir_ok" -ne 1 ] && [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
        mkdir_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
          -H "Authorization: $ol_token" \
          -H "Content-Type: application/json" \
          -d "$(jq -n --arg path "$actual_ol_dir" '{path:$path}')" 2>&1)
        mkdir_http=$(echo "$mkdir_resp" | tail -n 1)
        log_fix "$fix_log" "OpenList API mkdir (base64URL) 响应: ${mkdir_http}"
        if echo "$mkdir_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
          dir_ok=1
          used_base64_dir=1
          dst_file="${actual_dst_dir}/${file_name}"
          log_fix "$fix_log" "base64URL 目录创建成功 (API)"
        fi
      fi
    fi
  fi

  if [ "$dir_ok" -ne 1 ]; then
    log_fix "$fix_log" "目录创建最终失败（含 base64URL 编码后），无法修复文件"
    TRY_FIX_MESSAGE="目录创建失败，base64URL 编码后仍失败"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 1
  fi

  # ===== Step 2: 目录已就绪，尝试多种方式同步文件 =====
  log_fix "$fix_log" "目录已就绪，开始尝试多种方式同步到: $dst_file"

  local ol_dst_dir
  ol_dst_dir="${dst_file#openlist:}"
  ol_dst_dir="/$(dirname -- "$ol_dst_dir")"

  local ol_token
  ol_token=$(_get_openlist_token)

  # 方法 1：直接 rclone copyto
  log_fix "$fix_log" "方法 1: 直接 rclone copyto"
  rclone copyto "$src_file" "$dst_file" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m1: $line"; done
  local m1_status=${PIPESTATUS[0]}
  if [ "$m1_status" -eq 0 ]; then
    log_fix "$fix_log" "方法 1 成功"
    TRY_FIX_STATUS="success"
    if [ "$used_base64_dir" -eq 1 ]; then
      TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 原文件名）"
      TRY_FIX_ALTERNATIVE="${dst_file#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${dst_file}' '${dest_path}/${failed_file_rel}'"
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + 原文件名）"
      TRY_FIX_ALTERNATIVE="$failed_file_rel"
      TRY_FIX_RESTORE="无需还原（文件已在正确路径）"
    fi
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi
  log_fix "$fix_log" "方法 1 失败 (exit=$m1_status)"

  # 方法 2：文件名 base64URL 编码后上传
  log_fix "$fix_log" "方法 2: 文件名 base64URL 编码后上传"
  local encoded_name m2_dst m2_status
  if [[ "$file_name" == *.* ]]; then
    local name_base="${file_name%.*}"
    local name_ext="${file_name##*.}"
    encoded_name="$(printf '%s' "$name_base" | base64 | tr '+/' '-_' | tr -d '=').${name_ext}"
  else
    encoded_name="$(printf '%s' "$file_name" | base64 | tr '+/' '-_' | tr -d '=')"
  fi
  m2_dst="${actual_dst_dir}/${encoded_name}"
  rclone copyto "$local_file" "$m2_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m2: $line"; done
  m2_status=${PIPESTATUS[0]}
  if [ "$m2_status" -eq 0 ]; then
    log_fix "$fix_log" "方法 2 成功"
    TRY_FIX_STATUS="success"
    if [ "$used_base64_dir" -eq 1 ]; then
      TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + base64URL 编码文件名）"
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + base64URL 编码文件名）"
    fi
    TRY_FIX_ALTERNATIVE="${m2_dst#${dest_path}/}"
    TRY_FIX_RESTORE="rclone move '${m2_dst}' '${dest_path}/${failed_file_rel}'"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi
  log_fix "$fix_log" "方法 2 失败 (exit=$m2_status)"

  # 方法 3：zip 压缩后上传
  log_fix "$fix_log" "方法 3: zip 压缩后上传"
  (cd "$temp_dir" && 7z a -tzip -mx=0 "${file_name}.zip" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m3 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.zip" ]; then
    local m3_dst m3_status
    m3_dst="${actual_dst_dir}/${file_name}.zip"
    rclone copyto "$temp_dir/${file_name}.zip" "$m3_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m3: $line"; done
    m3_status=${PIPESTATUS[0]}
    if [ "$m3_status" -eq 0 ]; then
      log_fix "$fix_log" "方法 3 成功"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + zip 压缩包）"
      else
        TRY_FIX_METHOD="rclone copyto（原路径 + zip 压缩包）"
      fi
      TRY_FIX_ALTERNATIVE="${m3_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m3_dst} 后解压: 7z x ${file_name}.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 3 失败 (exit=$m3_status)"
  else
    log_fix "$fix_log" "方法 3 zip 未生成"
  fi

  # 方法 4：7z 压缩后上传
  log_fix "$fix_log" "方法 4: 7z 压缩后上传"
  (cd "$temp_dir" && 7z a -t7z -mx=0 "${file_name}.7z" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m4 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.7z" ]; then
    local m4_dst m4_status
    m4_dst="${actual_dst_dir}/${file_name}.7z"
    rclone copyto "$temp_dir/${file_name}.7z" "$m4_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m4: $line"; done
    m4_status=${PIPESTATUS[0]}
    if [ "$m4_status" -eq 0 ]; then
      log_fix "$fix_log" "方法 4 成功"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 7z 压缩包）"
      else
        TRY_FIX_METHOD="rclone copyto（原路径 + 7z 压缩包）"
      fi
      TRY_FIX_ALTERNATIVE="${m4_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m4_dst} 后解压: 7z x ${file_name}.7z"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 4 失败 (exit=$m4_status)"
  else
    log_fix "$fix_log" "方法 4 7z 未生成"
  fi

  # 方法 5：OpenList API 直传
  log_fix "$fix_log" "方法 5: OpenList API 直传"
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg path "$ol_dst_dir" '{path:$path,recursive:true}')" >/dev/null 2>&1 || true
    sleep 3
    local api_name upload_resp upload_http
    if [[ "$file_name" == *.* ]]; then
      api_name="file_$(date +%s)_$$_api.${file_name##*.}"
    else
      api_name="file_$(date +%s)_$$_api"
    fi
    upload_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$ol_dst_dir" \
      -F "name=$api_name" 2>&1)
    upload_http=$(echo "$upload_resp" | tail -n 1)
    log_fix "$fix_log" "OpenList API 上传响应: ${upload_http}"
    if echo "$upload_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
      log_fix "$fix_log" "方法 5 成功"
      TRY_FIX_STATUS="success"
      if [ "$used_base64_dir" -eq 1 ]; then
        TRY_FIX_METHOD="OpenList API /fs/form（base64URL 编码目录 + API 自动生成文件名）"
      else
        TRY_FIX_METHOD="OpenList API /fs/form（原路径 + API 自动生成文件名）"
      fi
      local alt_rel_base
      alt_rel_base="${actual_dst_dir#${dest_path}/}"
      TRY_FIX_ALTERNATIVE="${alt_rel_base}/${api_name}"
      TRY_FIX_RESTORE="rclone move '${dest_path}/${alt_rel_base}/${api_name}' '${dest_path}/${failed_file_rel}'"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 5 失败 (${upload_http})"
  else
    log_fix "$fix_log" "方法 5 跳过（无法读取 OpenList token）"
  fi

  # 方法 6：重命名文件后上传（避开敏感文件名）
  # wopan176 后端可能对某些文件名（如 options.xml）有安全策略
  log_fix "$fix_log" "方法 6: 重命名文件后上传（避开可能的敏感文件名）"
  local renamed_file="${file_name}.bak"
  local m6_dst="${actual_dst_dir}/${renamed_file}"
  log_fix "$fix_log" "  重命名为: $renamed_file"
  rclone copyto "$local_file" "$m6_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m6: $line"; done
  local m6_status=${PIPESTATUS[0]}
  if [ "$m6_status" -eq 0 ]; then
    log_fix "$fix_log" "方法 6 成功"
    TRY_FIX_STATUS="success"
    if [ "$used_base64_dir" -eq 1 ]; then
      TRY_FIX_METHOD="rclone copyto（base64URL 编码目录 + 重命名 .bak）"
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + 重命名 .bak）"
    fi
    TRY_FIX_ALTERNATIVE="${m6_dst#${dest_path}/}"
    TRY_FIX_RESTORE="rclone move '${m6_dst}' '${dest_path}/${failed_file_rel}'"
    rm -rf "$temp_dir" 2>/dev/null || true
    return 0
  fi
  log_fix "$fix_log" "方法 6 失败 (exit=$m6_status)"

  # 方法 7：上传到父目录（跳过有问题的目录层级）
  # 如果当前目录写操作被 wopan176 拒绝，尝试上传到上级目录
  # 文件名编码原始目录信息，便于后续还原
  if [ "$file_dir_rel" != "." ] && [ "$file_dir_rel" != "" ]; then
    log_fix "$fix_log" "方法 7: 上传到父目录（跳过有问题的目录层级）"
    local parent_dst_dir
    parent_dst_dir="$(dirname -- "$actual_dst_dir")"
    local parent_ol_dir
    parent_ol_dir="$(dirname -- "$actual_ol_dir")"

    # 编码原始目录名到文件名中，格式: __fixed__<base64_原始目录>__<原文件名>
    local encoded_orig_dir
    encoded_orig_dir=$(printf '%s' "$(basename -- "$file_dir_rel")" | base64 | tr '+/' '-_' | tr -d '=')
    local fixed_name="__fixed__${encoded_orig_dir}__${file_name}"
    local m7_dst="${parent_dst_dir}/${fixed_name}"

    log_fix "$fix_log" "  父目录: $parent_dst_dir"
    log_fix "$fix_log" "  编码文件名: $fixed_name"

    # 确保父目录存在
    rclone mkdir "$parent_dst_dir" --retries 1 --low-level-retries 3 --timeout 2m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m7 mkdir: $line"; done

    rclone copyto "$local_file" "$m7_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m7: $line"; done
    local m7_status=${PIPESTATUS[0]}
    if [ "$m7_status" -eq 0 ]; then
      log_fix "$fix_log" "方法 7 成功"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（父目录 + 编码原始目录名的文件名）"
      TRY_FIX_ALTERNATIVE="${m7_dst#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${m7_dst}' '${dest_path}/${failed_file_rel}'"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 7 失败 (exit=$m7_status)"
  fi

  # 方法 8：通过 OpenList API /fs/put 流式上传（绕过 WebDAV）
  # /fs/put 接口直接以流的方式写入，不走 WebDAV 的 MKCOL+PUT 流程
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    log_fix "$fix_log" "方法 8: OpenList API /fs/put 流式上传（绕过 WebDAV）"
    local put_name="put_$(date +%s)_$$_${file_name}"
    local put_target="${actual_ol_dir}/${put_name}"
    local put_resp put_http
    put_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT "http://127.0.0.1:5244/api/fs/put" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/octet-stream" \
      -H "As-Task: true" \
      --data-binary "@$local_file" \
      --max-time 300 2>&1)
    put_http=$(echo "$put_resp" | tail -n 1)
    log_fix "$fix_log" "  /fs/put 响应: ${put_http}"
    # /fs/put 需要 file path 和 size 参数，这里改用 /api/fs/form 的方式但带不同参数
    # 尝试通过 /api/fs/form 上传到根 backup 目录
    local backup_dir="/${ol_dst_base}"
    local form_resp form_http
    form_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$backup_dir" \
      -F "name=$put_name" \
      --max-time 300 2>&1)
    form_http=$(echo "$form_resp" | tail -n 1)
    log_fix "$fix_log" "  /fs/form 到根目录响应: ${form_http}"
    if echo "$form_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
      log_fix "$fix_log" "方法 8 成功"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="OpenList API /fs/form（上传到根 backup 目录 + 编码文件名）"
      TRY_FIX_ALTERNATIVE="${put_name}"
      local alt_rel_base8="${actual_dst_dir#${dest_path}/}"
      TRY_FIX_RESTORE="rclone move '${dest_path}/${alt_rel_base8}/${put_name}' '${dest_path}/${failed_file_rel}'  # 或从 backup 根目录查找 ${put_name}"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 8 失败 (${form_http})"
  fi

  # 方法 9：上传到完全不同的路径（backup 根目录 + 时间戳文件名）
  # 最后手段：把文件上传到一个全新的简单路径，文件名包含原始路径的 hash
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    log_fix "$fix_log" "方法 9: 上传到 backup 根目录（最后手段）"
    local path_hash
    path_hash=$(printf '%s' "$failed_file_rel" | md5sum | cut -c1-8)
    local fallback_name="fixed_${path_hash}_${file_name}"
    local fallback_ol_dir="/${ol_dst_base}"
    log_fix "$fix_log" "  目标: ${fallback_ol_dir}/${fallback_name}"
    local fb_resp fb_http
    fb_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$fallback_ol_dir" \
      -F "name=$fallback_name" \
      --max-time 300 2>&1)
    fb_http=$(echo "$fb_resp" | tail -n 1)
    log_fix "$fix_log" "  响应: ${fb_http}"
    if echo "$fb_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
      log_fix "$fix_log" "方法 9 成功"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="OpenList API /fs/form（backup 根目录 + hash 文件名）"
      TRY_FIX_ALTERNATIVE="$fallback_name"
      TRY_FIX_RESTORE="rclone move '${dest_path}/${fallback_name}' '${dest_path}/${failed_file_rel}'  # hash=${path_hash}"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 9 失败 (${fb_http})"
  fi

  # 方法 10：base64 编码文件内容后上传（完全改变文件 hash 和内容特征）
  # 适用于 wopan176 后端可能基于文件内容或 hash 做安全检测的情况
  log_fix "$fix_log" "方法 10: base64 编码文件内容后上传（改变文件 hash）"
  local b64_content_file="${temp_dir}/${file_name}.b64"
  base64 "$local_file" > "$b64_content_file" 2>/dev/null
  if [ -f "$b64_content_file" ]; then
    local m10_dst="${actual_dst_dir}/${file_name}.b64"
    rclone copyto "$b64_content_file" "$m10_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m10: $line"; done
    local m10_status=${PIPESTATUS[0]}
    if [ "$m10_status" -eq 0 ]; then
      log_fix "$fix_log" "方法 10 成功"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（base64 编码文件内容 + .b64 扩展名）"
      TRY_FIX_ALTERNATIVE="${m10_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m10_dst} 后解码: base64 -d ${file_name}.b64 > ${file_name}"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 10 失败 (exit=$m10_status)"
  else
    log_fix "$fix_log" "方法 10 base64 编码失败"
  fi

  # 方法 11：加密 zip 后上传（改变二进制特征 + 密码保护）
  log_fix "$fix_log" "方法 11: 加密 zip 后上传（改变二进制特征）"
  local zip_password="OpenList$(date +%s)"
  (cd "$temp_dir" && 7z a -tzip -p"$zip_password" -mem=AES256 "${file_name}.enc.zip" "$file_name") 2>&1 | \
    while IFS= read -r line; do log_fix "$fix_log" "m11 7z: $line"; done
  if [ -f "$temp_dir/${file_name}.enc.zip" ]; then
    local m11_dst="${actual_dst_dir}/${file_name}.enc.zip"
    rclone copyto "$temp_dir/${file_name}.enc.zip" "$m11_dst" --retries 1 --low-level-retries 3 --timeout 5m --contimeout 30s 2>&1 | \
      while IFS= read -r line; do log_fix "$fix_log" "m11: $line"; done
    local m11_status=${PIPESTATUS[0]}
    if [ "$m11_status" -eq 0 ]; then
      log_fix "$fix_log" "方法 11 成功"
      TRY_FIX_STATUS="success"
      TRY_FIX_METHOD="rclone copyto（AES256 加密 zip + .enc.zip 扩展名）"
      TRY_FIX_ALTERNATIVE="${m11_dst#${dest_path}/}"
      TRY_FIX_RESTORE="下载 ${m11_dst} 后解压: 7z x -p${zip_password} ${file_name}.enc.zip"
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 11 失败 (exit=$m11_status)"
  else
    log_fix "$fix_log" "方法 11 加密 zip 未生成"
  fi

  # 方法 12：上传到临时目录后用 OpenList API move 移动
  # 在 backup 根目录创建临时目录，上传文件，然后用 API move 到目标路径
  if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
    log_fix "$fix_log" "方法 12: 上传到临时目录后用 OpenList API move 移动"
    local tmp_dir_name="_tmp_fix_$(date +%s)_$$"
    local tmp_ol_dir="/${ol_dst_base}/${tmp_dir_name}"
    # 通过 API 创建临时目录
    curl -s -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
      -H "Authorization: $ol_token" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg path "$tmp_ol_dir" '{path:$path}')" >/dev/null 2>&1 || true
    sleep 1
    # 上传文件到临时目录
    local m12_upload_name="${file_name}"
    local m12_upload_resp m12_upload_http
    m12_upload_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/form" \
      -H "Authorization: $ol_token" \
      -F "file=@$local_file" \
      -F "path=$tmp_ol_dir" \
      -F "name=$m12_upload_name" \
      --max-time 300 2>&1)
    m12_upload_http=$(echo "$m12_upload_resp" | tail -n 1)
    log_fix "$fix_log" "  临时目录上传响应: ${m12_upload_http}"
    if echo "$m12_upload_http" | grep -qE 'HTTP_CODE:(200|201|204)'; then
      log_fix "$fix_log" "方法 12 临时目录上传成功，尝试 move 到目标路径..."
      # 确保目标目录存在
      local target_ol_dir="/${ol_dst_base}/${file_dir_rel}"
      curl -s -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg path "$target_ol_dir" '{path:$path}')" >/dev/null 2>&1 || true
      sleep 1
      # 用 OpenList API move 移动文件
      local src_move="${tmp_ol_dir}/${file_name}"
      local dst_move="/${ol_dst_base}/${failed_file_rel}"
      local move_resp move_http
      move_resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/move" \
        -H "Authorization: $ol_token" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg src "$src_move" --arg dst "$dst_move" '{src_dir:$src,dst_dir:$dst}')")
      move_http=$(echo "$move_resp" | tail -n 1)
      log_fix "$fix_log" "  API move 响应: ${move_http}"
      if echo "$move_resp" | grep -q '"code":200'; then
        log_fix "$fix_log" "方法 12 move 成功"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传 + OpenList API move（原路径 + 原文件名）"
        TRY_FIX_ALTERNATIVE="$failed_file_rel"
        TRY_FIX_RESTORE="无需还原（文件已在正确路径）"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      else
        log_fix "$fix_log" "方法 12 move 失败，文件保留在临时目录: ${tmp_ol_dir}/${file_name}"
        TRY_FIX_STATUS="success"
        TRY_FIX_METHOD="临时目录上传（move 失败，文件保留在 ${tmp_dir_name}/）"
        TRY_FIX_ALTERNATIVE="${tmp_dir_name}/${file_name}"
        TRY_FIX_RESTORE="OpenList API: POST /api/fs/move {src_dir:'${tmp_ol_dir}/${file_name}', dst_dir:'/${ol_dst_base}/${failed_file_rel}'}"
        rm -rf "$temp_dir" 2>/dev/null || true
        return 0
      fi
    fi
    log_fix "$fix_log" "方法 12 临时目录上传失败 (${m12_upload_http})"
  fi

  # 所有方法均失败
  log_fix "$fix_log" "所有修复方法均失败"
  TRY_FIX_MESSAGE="所有修复方法均失败"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 1
}
