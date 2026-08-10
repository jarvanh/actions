#!/bin/bash
# ===== OpenList 同步工具 — 失败文件修复函数 =====
# 处理 OpenList/WebDAV 405/409 等无法同步的文件，尝试多种修复方式：
#   1. 创建目标目录（rclone mkdir → OpenList API mkdir → base64URL 编码目录名）
#   2. 多种方式同步文件：
#      方法1: 直接 rclone copyto
#      方法2: 文件名 base64URL 编码后上传
#      方法3: zip 压缩后上传
#      方法4: 7z 压缩后上传
#      方法5: OpenList API /fs/form 直传
#
# 依赖: utils.sh (log_fix), telegram.sh (间接)
# 结果写入全局变量:
#   TRY_FIX_STATUS       — "success" 或 "failed"
#   TRY_FIX_ORIGINAL     — 原始文件相对路径
#   TRY_FIX_ALTERNATIVE  — 实际上传后的文件相对路径
#   TRY_FIX_METHOD       — 使用的修复方法描述
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
    ol_token=$(jq -r '.token' /dropbox/self-hosted/openlist/data/config.json 2>/dev/null || echo "")
    if [ -n "$ol_token" ] && [ "$ol_token" != "null" ]; then
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
  ol_token=$(jq -r '.token' /dropbox/self-hosted/openlist/data/config.json 2>/dev/null || echo "")

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
    else
      TRY_FIX_METHOD="rclone copyto（原路径 + 原文件名）"
      TRY_FIX_ALTERNATIVE="$failed_file_rel"
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
      rm -rf "$temp_dir" 2>/dev/null || true
      return 0
    fi
    log_fix "$fix_log" "方法 5 失败 (${upload_http})"
  else
    log_fix "$fix_log" "方法 5 跳过（无法读取 OpenList token）"
  fi

  # 所有方法均失败
  log_fix "$fix_log" "所有修复方法均失败"
  TRY_FIX_MESSAGE="所有修复方法均失败"
  rm -rf "$temp_dir" 2>/dev/null || true
  return 1
}
