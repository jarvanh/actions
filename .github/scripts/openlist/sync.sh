#!/bin/bash
# ===== OpenList 同步工具 — 核心同步引擎 =====
# 封装 rclone sync/copy，提供:
#   - 同步前 OpenList 缓存刷新（避免 stale listing 导致重复上传）
#   - wopan176 后端 token 刷新（处理 OAuth access token 过期）
#   - HTTP 423 Locked 重试（OpenList/WebDAV 临时文件锁）
#   - 8005 登录失败重试（wopan176 token 过期后刷新并重试）
#   - raw-vs-crypt 校验（wopan176Crypt 目标：对比 wopan176 裸路径密文数，
#     检测"上传成功但未持久化"的幽灵文件，重启容器还原真实列表）
#   - 缺失文件修复（同步后 diff 源端/目标端，缺失文件送 try_fix_failed_file，
#     不依赖任何错误码——假成功文件没有 ERROR 日志、退出码为 0，只能靠 diff 发现）
#   - 假成功两层防护:
#     A. 即时检测（_confirm_raw_persist）— 方法返回成功后对比 wopan176 裸路径
#        密文计数，未增长即假成功，当场拉黑该方法并尝试下一种方式
#     B. 失败记忆（FIX_METHOD_BLACKLIST + marker fix_blacklist）— 持久化
#        每文件已判定假成功的方法；持久化验证（重启容器复核）发现假成功后
#        本轮立即换方法重试并二次复核，跨轮修复同样跳过已拉黑方法；
#        上轮已真实持久化的修复（替代路径仍存在）直接沿用，不再重复上传
#   - object not found 错误处理
#   - 结构化同步结果通知（含源/目标大小、差异文件列表、排除规则）
#
# 依赖: utils.sh, telegram.sh, fix.sh (try_fix_failed_file)
# 依赖环境变量:
#   RCLONE_DEFAULT_FLAGS — 共用 rclone 参数数组（在 workflow 文件中定义）
#   TELEGRAM_BOT_TOKEN   — 用于发送日志文件
#   TELEGRAM_CHAT_ID     — 用于发送日志文件

# 刷新 OpenList wopan176 后端的 OAuth access token
# wopan176 的 access token 有效期短（约 5 分钟），长时间同步会过期
# 用法: _refresh_wopan_token [log_filename]
# 返回: 0=成功刷新, 非0=刷新失败
_refresh_wopan_token() {
  local log_file="${1:-/dev/null}"
  local ol_token
  ol_token=$(_get_openlist_token)
  if [ -z "$ol_token" ]; then
    echo "  wopan176 token 刷新: OpenList token 不可用" | tee -a "$log_file"
    return 1
  fi

  echo "  刷新 wopan176 后端 token..." | tee -a "$log_file"

  # 方法 1: 通过 OpenList /api/driver/update 强制重新初始化驱动配置
  # 这会触发 wopan176 驱动用 refresh_token 换取新的 access_token
  local refresh_result
  refresh_result=$(curl -s -X POST "http://127.0.0.1:5244/api/driver/update" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d '{}' \
    --max-time 30 2>&1)

  if echo "$refresh_result" | grep -qi '"code":0\|"status":"ok\|success'; then
    echo "  wopan176 token 刷新成功 (方法1: /api/driver/update)" | tee -a "$log_file"
    sleep 5
    return 0
  fi

  # 方法 2: 通过 /api/storage/list 后逐个刷新 storage 配置
  echo "  方法1 失败，尝试方法2: 重新加载 storage 配置..." | tee -a "$log_file"
  local storage_list
  storage_list=$(curl -s -X GET "http://127.0.0.1:5244/api/storage/list" \
    -H "Authorization: $ol_token" \
    --max-time 30 2>&1)

  if [ -n "$storage_list" ] && [ "$storage_list" != "null" ]; then
    echo "  storage 配置已加载，触发刷新..." | tee -a "$log_file"
    sleep 3
    return 0
  fi

  echo "  ⚠️ wopan176 token 刷新失败: $refresh_result" | tee -a "$log_file"
  return 1
}

# 检测 wopan176 登录失败（8005）
# OpenList 把 8005 包装成 HTTP 405 返回给 rclone，rclone 日志里只有 "405 Method Not Allowed"
# 因此需要同时检查 OpenList 容器日志中的 rsp_code: 8005
# 用法: _has_wopan_login_failure <rclone_log_file> [openlist_log_file]
# 返回: 0=检测到 8005 错误, 1=未检测到
_has_wopan_login_failure() {
  local rclone_log="$1"
  local ol_log="${2:-}"

  # 检查 OpenList 容器日志（包含真实的 8005 错误）
  if [ -n "$ol_log" ] && [ -f "$ol_log" ]; then
    # 只检查最近 5 分钟的日志，避免匹配到历史错误
    local recent_ol_log
    recent_ol_log=$(tail -500 "$ol_log" 2>/dev/null)
    if echo "$recent_ol_log" | grep -q 'rsp_code.*8005\|rep_desc.*登录失败'; then
      return 0
    fi
  fi

  # 兜底：也检查 rclone 日志（虽然 rclone 日志里通常只有 405，不含 8005）
  if [ -n "$rclone_log" ] && [ -f "$rclone_log" ]; then
    if grep -q 'rsp_code.*8005\|登录失败' "$rclone_log" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

# 查找 OpenList 最新日志文件
# （数据库本地化后日志在 /opt/openlist-data/log，旧路径保留兜底）
_find_openlist_log() {
  for logdir in \
    "/opt/openlist-data/log" \
    "/opt/openlist-data/logs" \
    "/dropbox/self-hosted/openlist/data/log" \
    "/dropbox/self-hosted/openlist/data/logs" \
    "/opt/openlist/data/log"; do
    if [ -d "$logdir" ]; then
      local latest
      latest=$(ls -t "$logdir"/*.log 2>/dev/null | head -1)
      [ -n "$latest" ] && echo "$latest" && return 0
    fi
  done
  return 1
}

# 同步前刷新 OpenList 服务端目录缓存
# 避免 PROPFIND 返回 stale listing 导致 rclone 看不到已存在文件而重复上传
# 用法: _refresh_openlist_cache <dest_path>
_refresh_openlist_cache() {
  local dest_path="$1"
  [[ "$dest_path" == openlist:* ]] || return 0

  local ol_path="${dest_path#openlist:}"
  ol_path="/${ol_path}"
  local ol_token
  ol_token=$(_get_openlist_token)
  if [ -z "$ol_token" ]; then
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

# 轻量刷新 OpenList 单个路径缓存（无长等待，供校验流程使用）
# 用法: _refresh_ol_cache_fast <ol_path（不带 openlist: 前缀）>
_refresh_ol_cache_fast() {
  local ol_path="/${1#/}"
  local ol_token
  ol_token=$(_get_openlist_token) || true
  [ -z "$ol_token" ] && return 0
  curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"$ol_path\",\"recursive\":true}" \
    >/dev/null 2>&1 || true
  sleep 5
}

# raw-vs-crypt 校验（仅 wopan176Crypt 目标端）
# wopan176Crypt 的每个文件在 wopan176 裸存储中必须有对应密文。
# 裸路径密文数 < crypt 文件数 → 存在"幽灵文件"：OpenList PUT 返回成功、
# crypt 列表里可见，但密文从未写入联通云后端（仅存在于 OpenList 内存缓存，
# 容器重启后消失）。
# 检测到幽灵文件时重启 OpenList 容器，清空被污染的内存缓存，使后续
# 源端 vs crypt 的 lsf diff 能把这些假成功文件暴露出来交给修复管线。
# 用法: _wopan_raw_verify <dest_path> [log_file]
# 设置全局: RAW_CRYPT_GHOST_COUNT — 幽灵文件数（供通知展示）
# 返回: 0=无幽灵文件（或非 wopan176Crypt 目标），1=检测到幽灵文件
_wopan_raw_verify() {
  RAW_CRYPT_GHOST_COUNT=0
  local dest_path="$1"
  local log_file="${2:-/dev/null}"
  [[ "$dest_path" == openlist:wopan176Crypt/* ]] || return 0

  # 裸路径取 API 权威推导（crypt addition.path），失败退化为字符串替换
  # raw_dest 可能是含密码的 crypt 即时远程（仅用于计数，绝不能进日志）
  local raw_dest raw_display
  raw_dest=$(_raw_count_view_for "$dest_path")
  raw_display=$(_raw_remote_for "${dest_path%%/*}" 2>/dev/null || echo "${dest_path/Crypt/}")
  local _sub=""
  [[ "${dest_path#openlist:}" == */* ]] && _sub="/${dest_path#openlist:*/}"
  echo "=== raw-vs-crypt 校验: ${dest_path} vs ${raw_display}${_sub}（${_CRYPT_DNE:-?} dne, 解密口径计数）===" | tee -a "$log_file"

  # 缓存刷新: crypt 挂载 + 裸挂载根（dne=true 时裸存储无字面子路径，只能刷根）
  _refresh_ol_cache_fast "${dest_path#openlist:}"
  _refresh_ol_cache_fast "${raw_display#openlist:}"

  local crypt_count=0 raw_count=0 crypt_json raw_json raw_rc=0
  crypt_json=$(timeout 900 rclone size "$dest_path" --json 2>/dev/null || true)
  crypt_count=$(echo "$crypt_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  raw_json=$(timeout 900 rclone size "$raw_dest" --json 2>/dev/null) || raw_rc=$?
  raw_count=$(echo "$raw_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  [[ "$crypt_count" =~ ^[0-9]+$ ]] || crypt_count=0
  [[ "$raw_count" =~ ^[0-9]+$ ]] || raw_count=0
  echo "  crypt 文件数: ${crypt_count} / 裸路径密文数: ${raw_count}" | tee -a "$log_file"

  # 裸路径列表获取失败（路径不存在/驱动错误）→ 无法判定，跳过并提示
  if [ "$raw_rc" -ne 0 ]; then
    echo "  ⚠️ 裸路径计数失败 (rc=${raw_rc}, ${raw_display}${_sub} 视角无法列出)，跳过幽灵文件判定" | tee -a "$log_file"
    # 诊断: 列出 OpenList 根挂载，确认裸存储是否真的挂载（raw 校验/A 层检测/方法2 crypt 直写全依赖它）
    local root_mounts
    root_mounts=$(timeout 60 rclone lsf openlist: --dirs-only 2>/dev/null | sed 's|/$||' | head -20)
    if [ -n "$root_mounts" ]; then
      echo "  🔍 OpenList 根挂载(WebDAV 可见): $(echo "$root_mounts" | tr '\n' ' ')" | tee -a "$log_file"
      if ! echo "$root_mounts" | grep -qx "wopan176"; then
        echo "  🔴 WebDAV 根挂载中无 wopan176 —— 裸存储未挂载或被隐藏，raw 校验/A 层即时检测/方法2 crypt 直写均不可用" | tee -a "$log_file"
      fi
    else
      echo "  🔍 OpenList 根挂载列表获取失败（WebDAV 未就绪?）" | tee -a "$log_file"
    fi
    # 诊断: admin API 列出全部存储配置（含响应码——run 31918439043 此表为空，需看 code 定位）
    local ol_token storage_table api_resp api_code
    ol_token=$(_get_openlist_token) || ol_token=""
    if [ -n "$ol_token" ]; then
      api_resp=$(curl -s "http://127.0.0.1:5244/api/admin/storage/list" \
        -H "Authorization: $ol_token" --max-time 15 2>/dev/null || echo "")
      api_code=$(echo "$api_resp" | jq -r '.code // "无响应"' 2>/dev/null)
      storage_table=$(echo "$api_resp" | \
        jq -r '(.data.content // .data // [])[] | "  · \(.mount_path) [driver=\(.driver) disabled=\(.disabled // false)]"' 2>/dev/null | head -30)
      if [ -n "$storage_table" ]; then
        echo "  🔍 OpenList 存储配置(admin API, code=${api_code}):" | tee -a "$log_file"
        echo "$storage_table" | tee -a "$log_file"
      else
        echo "  🔍 admin API 无存储数据 (code=${api_code}, message=$(echo "$api_resp" | jq -r '.message // "?"' 2>/dev/null))——crypt 配置已自动走 data.db 兜底" | tee -a "$log_file"
      fi
    fi
    return 0
  fi
  # 裸路径列表为空但 crypt 非空 → wopan176 驱动大概率未就绪，无法判定，跳过
  if [ "$raw_count" -eq 0 ] && [ "$crypt_count" -gt 0 ]; then
    echo "  ⚠️ 裸路径列表为空（wopan176 驱动可能未就绪），跳过幽灵文件判定" | tee -a "$log_file"
    return 0
  fi

  # 裸路径密文数 >= crypt 文件数 → 无幽灵文件
  if [ "$raw_count" -ge "$crypt_count" ]; then
    echo "  ✅ 未检测到幽灵文件（每个 crypt 文件在裸路径都有对应密文）" | tee -a "$log_file"
    return 0
  fi

  RAW_CRYPT_GHOST_COUNT=$((crypt_count - raw_count))
  echo "  ⚠️ 检测到 ${RAW_CRYPT_GHOST_COUNT} 个幽灵文件（crypt 列表可见但裸路径密文缺失 → 上传未持久化）" | tee -a "$log_file"

  # 重启 OpenList 容器，清掉被污染的内存缓存，让列表回到后端真实状态
  if ! command -v docker >/dev/null 2>&1 || ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qw openlist; then
    echo "  ⚠️ docker/openlist 容器不可用，无法重启清缓存，保留当前列表继续" | tee -a "$log_file"
    return 1
  fi

  echo "  重启 OpenList 容器还原真实列表..." | tee -a "$log_file"
  sudo docker restart openlist >> "$log_file" 2>&1 || true

  local i http_ok=0
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1; then
      http_ok=1
      echo "  OpenList HTTP 就绪 (${i}次)" | tee -a "$log_file"
      break
    fi
    sleep 2
  done
  if [ "$http_ok" -ne 1 ]; then
    echo "  ⚠️ OpenList 重启后 HTTP 未就绪，缓存状态未知" | tee -a "$log_file"
    return 1
  fi

  echo "  等待驱动重新初始化 (60s)..." | tee -a "$log_file"
  sleep 60
  _refresh_ol_cache_fast "${dest_path#openlist:}"
  echo "  容器已重启，crypt 列表已还原为后端真实状态（幽灵文件已从列表消失，将进入修复管线）" | tee -a "$log_file"
  return 1
}

# 增量持久化单个修复条目到 marker（修复循环内每成功一个立即调用）
# 目的: step 超时/手动取消/runner 回收等中断发生时，已完成的修复不丢失，
#       下一轮 B 前置可直接"沿用上轮修复"，避免重复下载/打包/上传
# state_file 是修复循环开始时对当前 marker 的快照，每次调用在快照上合并后整体写回
# （保留 last_success 等其他字段；同 original 的新条目覆盖旧条目）
# 用法: _persist_fix_entry_now <marker_path> <state_file> <source_path> <dest_path> \
#         <orig> <alt> <method> <restore_hint> <size_human> <size_bytes> <method_id>
_persist_fix_entry_now() {
  local marker_path="$1" state_file="$2" source_path="$3" dest_path="$4"
  local orig="$5" alt="$6" method="$7" restore_hint="$8" size_human="$9"
  local size_bytes="${10}" method_id="${11}"
  [ -f "$state_file" ] || return 1

  local entry_json
  entry_json=$(jq -cn --arg o "$orig" --arg a "$alt" --arg m "$method" --arg rh "$restore_hint" \
    --arg sh "$size_human" --argjson sb "${size_bytes:-0}" --arg mid "${method_id:-}" \
    '{original:$o, alternative:$a, method:$m, restore_hint:$rh, size_human:$sh, size_bytes:$sb, method_id:$mid}') || return 1

  # 方法黑名单快照（本轮已判假成功的方法一并写入，中断后下轮仍生效）
  local bl_json="{}" f
  for f in "${!FIX_METHOD_BLACKLIST[@]}"; do
    bl_json=$(jq -cn --argjson j "$bl_json" --arg k "$f" --arg v "${FIX_METHOD_BLACKLIST[$f]}" \
      '$j + {($k): $v}' 2>/dev/null) || bl_json="{}"
  done

  local merged
  merged=$(jq -c --argjson e "$entry_json" --argjson bl "$bl_json" '
    . as $m
    | ($m.fixed_files // []) as $ff
    | ($ff | map(select(.original != $e.original)) + [$e]) as $nff
    | $m + {fixed_files: $nff,
            fixed_count: ($nff | length),
            fixed_bytes: ([$nff[].size_bytes] | add // 0),
            fix_blacklist: (($m.fix_blacklist // {}) * $bl)}
  ' "$state_file" 2>/dev/null) || return 1

  echo "$merged" > "$state_file"
  if echo "$merged" | rclone rcat "$marker_path" >/dev/null 2>&1; then
    echo "    ↳ 已即时记录到修复清单 (marker 合计 $(echo "$merged" | jq -r '.fixed_count') 个)"
  else
    echo "    ↳ ⚠️ 即时写入 marker 失败（任务结束的统一保存会兜底）"
  fi
}

# 从修复状态快照移除单个条目（按 original 精确匹配），并整体写回 marker
# 用于假成功条目重试失败后清理 marker 里的幽灵 fixed_files 记录
# 用法: _remove_fix_entry_from_state <state_file> <marker_path> <orig>
_remove_fix_entry_from_state() {
  local state_file="$1" marker_path="$2" orig="$3"
  [ -f "$state_file" ] || return 1
  local merged
  merged=$(jq -c --arg o "$orig" '
    .fixed_files //= []
    | .fixed_files |= map(select(.original != $o))
    | .fixed_count = (.fixed_files | length)
    | .fixed_bytes = ([.fixed_files[].size_bytes] | add // 0)
  ' "$state_file" 2>/dev/null) || return 1
  echo "$merged" > "$state_file"
  if echo "$merged" | rclone rcat "$marker_path" >/dev/null 2>&1; then
    echo "    ↳ 假成功条目已从修复清单移除 (marker 合计 $(echo "$merged" | jq -r '.fixed_count') 个)"
  else
    echo "    ↳ ⚠️ 移除条目写回 marker 失败（任务结束的统一保存会兜底）"
  fi
}

# 持久化验证单轮复核（在 OpenList 容器重启、缓存刷新之后调用）
# 逐条检查修复条目是否被后端真正持久化；失败条目当场加入方法黑名单，
# 供本轮"立即换方法重试"直接跳过失效方法（不再等下一轮）
# 输入清单格式: <alt_path>|<bytes>|<orig_path>|<method>|<method_id> 每行一条
# 结果写入全局: PERSIST_OK / PERSIST_FAIL / PERSIST_IDX /
#               PERSIST_FAILED_ORIGS（失败条目 original 数组）/ PERSIST_FAIL_DETAILS
# 用法: _persist_verify_entries <dest_path> <list_file> <max_sample> <log_file>
_persist_verify_entries() {
  local dest_path="$1" list_file="$2" max_sample="$3" log_file="$4"
  PERSIST_OK=0
  PERSIST_FAIL=0
  PERSIST_IDX=0
  PERSIST_FAILED_ORIGS=()
  PERSIST_FAIL_DETAILS=""
  local alt_path bytes orig_path f_method f_mid
  while IFS='|' read -r alt_path bytes orig_path f_method f_mid; do
    [ -z "$alt_path" ] && continue
    PERSIST_IDX=$((PERSIST_IDX + 1))
    [ "$PERSIST_IDX" -gt "$max_sample" ] && break

    local full_alt="${dest_path}/${alt_path}"
    local after_sz after_lsf_sz
    after_sz=$(rclone size --json "$full_alt" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
    after_lsf_sz=$(rclone lsf "$(dirname "$full_alt")" --files-only --format "ps" --separator ";" 2>/dev/null | awk -v FS=';' -v bn="$(basename "$full_alt")" '$1==bn{print $2; exit}')
    [ -z "$after_lsf_sz" ] && after_lsf_sz=0

    # 判断方法类型
    local is_transformed=0
    local is_split=0
    case "$f_method" in
      *zip*|*7z*|*分卷*|*base64*|*编码*|*加密*|*压缩*|*.enc.*|*.b64*|*enc_zip*)
        is_transformed=1 ;;
    esac
    if echo "$alt_path" | grep -qE '\.zip\.[0-9]{3}$'; then
      is_split=1
    fi

    local verified=0
    if [ "$is_split" -eq 1 ]; then
      # 分卷：检查同目录下所有编号分卷
      local alt_dir_alt=$(dirname "$alt_path")
      local alt_prefix=$(basename "$alt_path")
      alt_prefix="${alt_prefix%.*}"        # strip ".001"
      alt_prefix="${alt_prefix%.zip}"      # also strip ".zip" if leftover
      # 列当前存在的所有同前缀编号分卷
      local existing_parts
      existing_parts=$(rclone lsf "${dest_path}/${alt_dir_alt}" --files-only 2>/dev/null | grep -E "${alt_prefix}\.zip\.[0-9]{3}" | sort)
      local part_count=$(echo -n "$existing_parts" | grep -c . || echo 0)
      # 至少有 1 个分卷，且分卷大小都 > 0
      local parts_ok=0
      if [ "$part_count" -gt 0 ]; then
        parts_ok=1
        while IFS= read -r pn; do
          [ -z "$pn" ] && continue
          local p_sz
          p_sz=$(rclone lsf "${dest_path}/${alt_dir_alt}" --files-only --format "ps" --separator ";" 2>/dev/null | awk -v FS=';' -v bn="$pn" '$1==bn{print $2; exit}')
          if [ -z "$p_sz" ] || [ "$p_sz" = "" ] || [ "$p_sz" -le 0 ] 2>/dev/null; then
            parts_ok=0
            break
          fi
        done <<< "$existing_parts"
      fi
      if [ "$parts_ok" -eq 1 ]; then
        verified=1
        echo "  ✅ 持久化通过: $orig_path (${f_method}, 分卷 $part_count 个存在且大小合法)" | tee -a "$log_file"
      else
        echo "  ❌ 持久化失败: $orig_path (${f_method}, 分卷缺失或大小异常)" | tee -a "$log_file"
        echo "    → 当前目录分卷: $(echo "$existing_parts" | tr '\n' ' ')" | tee -a "$log_file"
        PERSIST_FAIL_DETAILS="${PERSIST_FAIL_DETAILS}• ${orig_path} (${f_method})：分卷缺失或大小异常，当前分卷=${existing_parts}
"
      fi
    elif [ "$is_transformed" -eq 1 ]; then
      # 压缩/编码类：只检查 size > 0（压缩包大小与原文件不同）
      if [ "$after_sz" -gt 0 ] 2>/dev/null && [ "$after_lsf_sz" -gt 0 ] 2>/dev/null; then
        verified=1
        echo "  ✅ 持久化通过: $orig_path (${f_method}, transformed_size=$after_sz bytes)" | tee -a "$log_file"
      else
        echo "  ❌ 持久化失败: $orig_path (${f_method}, 上传文件为空或不存在, size=$after_sz, lsf=$after_lsf_sz)" | tee -a "$log_file"
        PERSIST_FAIL_DETAILS="${PERSIST_FAIL_DETAILS}• ${orig_path} (${f_method})：上传文件为空或不存在, size=${after_sz}
"
      fi
    else
      # 原样 copy / rename 类：精确匹配大小
      if [ "$after_sz" = "$bytes" ] && [ "$after_lsf_sz" = "$bytes" ] && [ "$after_sz" -gt 0 ]; then
        verified=1
        echo "  ✅ 持久化通过: $orig_path (${f_method}, $bytes bytes)" | tee -a "$log_file"
      else
        echo "  ❌ 持久化失败: $orig_path (${f_method}, expected=$bytes, size=$after_sz, lsf=$after_lsf_sz)" | tee -a "$log_file"
        PERSIST_FAIL_DETAILS="${PERSIST_FAIL_DETAILS}• ${orig_path} (${f_method})：expected=${bytes}, actual=${after_sz}
"
      fi
    fi
    if [ "$verified" -eq 1 ]; then
      PERSIST_OK=$((PERSIST_OK + 1))
    else
      PERSIST_FAIL=$((PERSIST_FAIL + 1))
      # B: 复核失败 = 修复方法假成功 → 当场拉黑，本轮立即换方法重试
      if [ -n "$f_mid" ]; then
        _blacklist_add "$orig_path" "$f_mid"
        echo "  → $(_method_desc "$f_mid") 已加入 ${orig_path} 的假成功黑名单（本轮立即换方法重试）" | tee -a "$log_file"
      fi
      PERSIST_FAILED_ORIGS+=("$orig_path")
    fi
  done < "$list_file"
}

# 带探测、重试和详细日志的同步函数
# 用法: sync_with_logging <source_path> <dest_path> <task_name> [rclone_extra_args...]
# 设置全局变量: SYNC_FAILED, SYNC_SKIPPED, SYNC_TRANSFERRED_BYTES, RAW_CRYPT_GHOST_COUNT
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
    # fix_test 模式: 跳过实际 rclone 传输（调试目的是快速验证修复方法，
    # 全量 copy 动辄 GB 级/十分钟，与快速迭代背道而驰）。日志置空后
    # 8005/423/错误解析全部空匹配自动跳过，raw 校验 + lsf diff +
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

    # _SYNC_MODE=copy 时用 rclone copy（不删除目标端多余文件），否则 rclone sync
    local rclone_cmd="sync"
    if [ "${_SYNC_MODE:-sync}" = "copy" ]; then
      rclone_cmd="copy"
    fi

    # OpenList 目标端（特别是 wopan176 crypt 后端）上传速度慢且不支持高并发
    # 上传保持串行（transfers=1，给后端足够时间持久化每个文件，避免 "object not found"）；
    # 检查阶段只读列表，可提高并发大幅缩短 diff/比对耗时（上传仍逐个进行）
    # 同时增加超时时间（单个文件可能耗时 1-2 分钟）
    local openlist_guard_flags=()
    if [[ "$dest_path" == openlist:* ]]; then
      openlist_guard_flags=(
        "--transfers" "1"
        "--checkers" "8"
        "--contimeout" "30s"
        "--timeout" "30m"
      )
      echo "OpenList 目标端：启用低并发保护 (transfers=1, checkers=8, timeout=30m)" | tee -a "$LOG_FILENAME"

      # 同步前主动刷新 wopan176 token
      # wopan176 的 OAuth access token 有效期约 5 分钟，长时间同步会过期
      _refresh_wopan_token "$LOG_FILENAME"
    fi

    rclone "$rclone_cmd" "$source_path" "$dest_path" \
      "${RCLONE_DEFAULT_FLAGS[@]}" \
      "${openlist_guard_flags[@]}" \
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

  # ===== 已修复文件排除（405 防护 + sync 模式删除保护）=====
  # marker fixed_files 里的 original 当初就是原路径传不上（405/超长/假成功）
  # 才修复到 alternative 的；替代文件仍在时原路径重传必然再 405，
  # 还会被 OpenList 包装成 8005 触发 3 轮全量重试（每轮白白重查全目录）。
  # sync 模式下排除同时承担"删除保护"——rclone 语义: filter 排除的文件
  # 不传输也不删除（前提: 不能加 --delete-excluded，否则排除保护失效）:
  #   - original:   排除 → 不重传（无 405）、即使目标端有也不被删
  #   - alternative: 只存在于目标端、源端没有 → 不排除必被 sync 当多余删除
  #   - 分卷类:     alternative 只记录第一卷，.002/.003... 用前缀通配一并保护
  #   - auto-split 最终全量同步用 GLOBAL_FIXED_FILES_JSON 合并本轮子任务修复
  #   - lsf diff 不带 filter-from，缺失文件照常进修复管线复核
  #   - 文件名 glob 特殊字符 [ ] * ? { } 转成字符类
  if [[ "$dest_path" == openlist:* ]]; then
    _load_marker_fixed_files "$source_path" "$dest_path" "$task_name"
    local fixed_exclude_file="/tmp/${task_name}_fixed_exclude_$$.txt"
    : > "$fixed_exclude_file"
    local _fx_orig _fx_alt _fx_method
    _fx_escape() { printf '%s' "$1" | sed -e 's/[][*?{}]/[&]/g'; }
    while IFS=$'\t' read -r _fx_orig _fx_alt _fx_method; do
      [ -z "$_fx_orig" ] && [ -z "$_fx_alt" ] && continue
      if [ -n "$_fx_orig" ]; then
        printf -- "- /%s\n" "$(_fx_escape "$_fx_orig")" >> "$fixed_exclude_file"
      fi
      if [ -n "$_fx_alt" ]; then
        printf -- "- /%s\n" "$(_fx_escape "$_fx_alt")" >> "$fixed_exclude_file"
        if [[ "$_fx_method" == *分卷* ]]; then
          local _fx_prefix="${_fx_alt%.[0-9]*}"
          if [ "$_fx_prefix" != "$_fx_alt" ]; then
            printf -- "- /%s*\n" "$(_fx_escape "$_fx_prefix")" >> "$fixed_exclude_file"
          fi
        fi
      fi
    done < <(jq -rs 'add | unique_by(.original // "") | .[] | [(.original // ""), (.alternative // ""), (.method // "")] | @tsv' \
      <(echo "${MARKER_FIXED_FILES:-[]}") <(echo "${GLOBAL_FIXED_FILES_JSON:-[]}") 2>/dev/null)
    if [ -s "$fixed_exclude_file" ]; then
      sort -u "$fixed_exclude_file" -o "$fixed_exclude_file"
      extra_args+=("--filter-from" "$fixed_exclude_file")
      echo "已排除 $(wc -l < "$fixed_exclude_file" | tr -d ' ') 条修复文件路径（original+alternative；排除 = 不传输 + 不删除）" | tee -a "$LOG_FILENAME"
      sed 's/^/  exclude: /' "$fixed_exclude_file" | tee -a "$LOG_FILENAME"
    fi
  fi

  run_rclone_sync_once "initial sync" || SYNC_STATUS=$?

  # ===== 8005 登录失败重试 =====
  # wopan176 后端写操作可能返回 8005（OpenList 包装为 HTTP 405 返回给 rclone）
  # 需要检查 OpenList 容器日志中的真实 8005 错误，刷新 token 并重试
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

      _refresh_wopan_token "$LOG_FILENAME"
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

  # ===== raw-vs-crypt 校验（仅 wopan176Crypt 目标端）=====
  # 放在缺失文件 diff 之前：若存在幽灵文件（OpenList 报告上传成功但裸路径
  # 无对应密文），先重启 OpenList 容器还原真实列表，diff 才能把这批
  # "假成功"文件识别为缺失文件并送修复管线。
  _wopan_raw_verify "$dest_path" "$LOG_FILENAME" || true

  # ===== 缺失文件修复管线 =====
  # 不依赖任何错误码：同步后只要源端有、目标端没有的文件（含 rclone 报告
  # "成功"但未持久化的假成功文件），一律送 try_fix_failed_file 修复
  # （目录创建 → base64URL 编码 → zip/7z/分卷/API 多种方式），不阻止后续 task
  local fail_list="/tmp/${task_name}_sync_failures.txt"
  local fix_list="/tmp/${task_name}_sync_fixes.txt"
  : > "$fail_list"
  : > "$fix_list"
  local fix_log=""
  local HAS_OBJECT_NOT_FOUND=0

  if [[ "$dest_path" == openlist:* ]]; then
    # 收集缺失文件：
    #   1) 最后一次尝试日志中 Failed to copy 的文件（object not found 属于
    #      源文件不存在，由后面专门章节记录，这里排除）
    #   2) 源端 vs 目标端 lsf 递归 diff 出的缺失文件（假成功文件没有 ERROR
    #      日志、退出码为 0，只能靠 diff 发现）
    local missing_list="/tmp/${task_name}_missing_$$.txt"
    : > "$missing_list"
    grep -E 'ERROR : .+: Failed to copy' "$LAST_ATTEMPT_LOG" 2>/dev/null | \
      grep -Ev 'object not found' | \
      sed -E 's/^.*ERROR : //; s/: Failed to copy.*$//' >> "$missing_list"

    # lsf 递归列出两端（源端带上 --exclude/--include 过滤，口径与 sync 一致；
    # 只传纯 filter 参数，避免把 --delete-before/--no-traverse 等 sync/copy
    # 特有参数传给 lsf）
    _extract_filter_args "${extra_args[@]}"
    local src_ls="/tmp/${task_name}_src_ls_$$.txt"
    local dst_ls="/tmp/${task_name}_dst_ls_$$.txt"
    local src_ls_ok=0 dst_ls_ok=0
    timeout 900 rclone lsf "$source_path" -R --files-only "${FILTER_ARGS[@]}" > "$src_ls" 2>/dev/null && src_ls_ok=1 || true
    timeout 900 rclone lsf "$dest_path" -R --files-only > "$dst_ls" 2>/dev/null && dst_ls_ok=1 || true
    if [ "$src_ls_ok" -eq 1 ] && [ "$dst_ls_ok" -eq 1 ]; then
      # 仅当两端列表都完整获取时才做 diff，避免半截列表产生误报触发无谓修复
      comm -23 <(sort -u "$src_ls") <(sort -u "$dst_ls") >> "$missing_list"
    else
      echo "⚠️ 源/目标文件列表获取不完整（src=${src_ls_ok}, dst=${dst_ls_ok}），跳过 lsf diff，仅用日志错误修复" | tee -a "$LOG_FILENAME"
    fi
    rm -f "$src_ls" "$dst_ls"
    sort -u "$missing_list" -o "$missing_list"

    # ===== B: 失败记忆 — 比对上一轮修复记录（marker fixed_files）=====
    # 缺失清单中曾在上一轮"修复成功"的文件:
    #   - 替代路径在目标端仍存在 → 上轮修复真实持久化，直接沿用（跳过重复修复）
    #   - 替代路径已消失（本轮容器为全新实例，crypt 列表真实）→ 上轮方法为
    #     假成功，加入方法黑名单 FIX_METHOD_BLACKLIST，本轮修复直接跳过该方法
    FIX_METHOD_BLACKLIST=()
    if [ -s "$missing_list" ]; then
      _load_marker_fixed_files "$source_path" "$dest_path" "$task_name"
      # 直接加载 marker 中持久化的方法黑名单（仅保留本次缺失清单中的文件；
      # 覆盖"上轮全部方法失败、无 fixed_files 记录"的场景）
      if [ -n "${MARKER_FIX_BLACKLIST:-}" ] && [ "$MARKER_FIX_BLACKLIST" != "{}" ]; then
        while IFS=$'\t' read -r bl_f bl_m; do
          [ -z "$bl_f" ] && continue
          grep -qxF "$bl_f" "$missing_list" || continue
          FIX_METHOD_BLACKLIST["$bl_f"]="$bl_m"
        done < <(echo "$MARKER_FIX_BLACKLIST" | jq -r 'to_entries[] | [.key, .value] | @tsv' 2>/dev/null)
      fi
      if [ "${MARKER_FIXED_COUNT:-0}" -gt 0 ] && [ "$MARKER_FIXED_FILES" != "[]" ]; then
        local keep_list="/tmp/${task_name}_missing_keep_$$.txt"
        : > "$keep_list"
        while IFS= read -r mf; do
          [ -z "$mf" ] && continue
          # 同一轮内已修复过的文件（auto-split 子任务 → 最终完整同步），直接沿用
          if [ -n "${FIXED_THIS_RUN[$mf]:-}" ]; then
            echo "本轮已修复，跳过重复修复: ${mf} → ${FIXED_THIS_RUN[$mf]}" | tee -a "$LOG_FILENAME"
            continue
          fi
          local prev_entry prev_alt prev_mid prev_method prev_restore prev_shuman prev_sbytes
          prev_entry=$(echo "$MARKER_FIXED_FILES" | jq -c --arg f "$mf" '[.[] | select(.original == $f)] | .[0] // empty' 2>/dev/null)
          if [ -n "$prev_entry" ]; then
            prev_alt=$(echo "$prev_entry" | jq -r '.alternative // empty')
            prev_mid=$(echo "$prev_entry" | jq -r '.method_id // empty')
            if [ -n "$prev_alt" ] && rclone lsf "${dest_path}/$(dirname -- "$prev_alt")" --files-only 2>/dev/null | grep -qxF "$(basename -- "$prev_alt")"; then
              # 替代路径仍存在 → 沿用上轮修复，不重复上传
              prev_method=$(echo "$prev_entry" | jq -r '.method // "沿用上轮修复"')
              prev_restore=$(echo "$prev_entry" | jq -r '.restore_hint // ""')
              prev_shuman=$(echo "$prev_entry" | jq -r '.size_human // "未知"')
              prev_sbytes=$(echo "$prev_entry" | jq -r '.size_bytes // 0')
              echo "沿用上轮修复: ${mf} → ${prev_alt}（替代路径仍存在）" | tee -a "$LOG_FILENAME"
              echo "${mf}|${prev_alt}|${prev_method}|${prev_restore}|${prev_shuman}|${prev_sbytes}|${prev_mid}" >> "$fix_list"
              FIXED_THIS_RUN["$mf"]="$prev_alt"
              continue
            fi
            if [ -n "$prev_mid" ]; then
              echo "上轮 $(_method_desc "$prev_mid") 判定假成功（替代路径已消失）: ${mf}" | tee -a "$LOG_FILENAME"
              FIX_METHOD_BLACKLIST["$mf"]="$prev_mid"
            fi
          fi
          echo "$mf" >> "$keep_list"
        done < "$missing_list"
        mv "$keep_list" "$missing_list"
        # B: 沿用/拉黑判定完成后立即落盘（防异常路径丢失，与即时修复记录同哲学）
        _flush_blacklist_to_marker "$task_name" "$dest_path" "$LOG_FILENAME"
      fi
    fi

    # ===== A: 假成功即时检测初始化（仅 wopan176Crypt，方案 A）=====
    # 每个方法返回成功后用 _confirm_raw_persist 对比 wopan176 裸路径密文数；
    # _RAW_VERIFY_LAST 为运行基准（随真实落盘递增），budget 限制全量计数次数
    _RAW_VERIFY_DEST=""
    _RAW_VERIFY_DIR=""
    _RAW_VERIFY_LAST=-1
    _RAW_VERIFY_BUDGET=0
    if [[ "$dest_path" == openlist:wopan176Crypt/* ]] && [ -s "$missing_list" ]; then
      _RAW_VERIFY_DEST="$dest_path"
      # 计数视图: 配置可用时为 crypt 即时远程（dne=true 唯一正确口径），
      # 否则退化为字面裸路径；刷新路径始终为裸挂载根（dne 下无字面子路径）
      _RAW_VERIFY_DIR=$(_raw_count_view_for "$dest_path")
      _RAW_VERIFY_REFRESH=$(_raw_remote_for "${dest_path%%/*}" 2>/dev/null || echo "${dest_path/Crypt/}")
      _RAW_VERIFY_REFRESH="${_RAW_VERIFY_REFRESH#openlist:}"
      _RAW_VERIFY_BUDGET="${OPENLIST_RAW_CHECK_BUDGET:-40}"
      local _raw_base=0
      if _raw_base=$(_raw_dir_count "$_RAW_VERIFY_DIR" "$_RAW_VERIFY_REFRESH"); then
        _RAW_VERIFY_LAST=$_raw_base
        echo "raw 假成功即时检测已启用（基准 ${_raw_base}，dne=${_CRYPT_DNE:-?}，预算 ${_RAW_VERIFY_BUDGET}）" | tee -a "$LOG_FILENAME"
      else
        _RAW_VERIFY_BUDGET=0
        echo "⚠️ raw 基准计数失败，本轮禁用即时检测（退化为信任 rc，跨轮黑名单仍生效）" | tee -a "$LOG_FILENAME"
      fi
    fi

    # ===== 名长诊断初始化（wopan176Crypt）=====
    # 验证"密文文件名超长"假设: cryptencode 本地计算缺失文件的密文名长（无网络
    # 写操作），与后端实际已接受的最长密文名（裸路径 lsf 统计 basename）对比。
    # 注意用裸挂载根而非 /backup 子路径: dne=true 时子路径在裸存储是密文名，
    # 字面子路径列不出任何东西；根的 -R 递归列出覆盖全部密文名
    local _NAMELEN_RAW_MAX=0
    local _NAMELEN_OVER_255=0
    local _NAMELEN_OVER_RAWMAX=0
    if [[ "$dest_path" == openlist:wopan176Crypt/* ]] && [ -s "$missing_list" ] && _ensure_crypt_config "$dest_path"; then
      _NAMELEN_RAW_MAX=$(timeout 600 rclone lsf "${_CRYPT_REMOTE}" -R --files-only 2>/dev/null \
        | awk -F/ '{ n=length($NF); if (n>m) m=n } END { print m+0 }')
      echo "名长诊断已启用: crypt=${_CRYPT_REMOTE}, 后端已接受最长密文名 ${_NAMELEN_RAW_MAX} 字节" | tee -a "$LOG_FILENAME"
    fi

    if [ -s "$missing_list" ]; then
      # 单次修复数量上限（防止首次部署时积压大量缺失文件导致单次运行过久）
      local fix_max="${OPENLIST_MISSING_FIX_MAX:-200}"
      local missing_total
      missing_total=$(wc -l < "$missing_list" | tr -d ' ')
      if [ "$missing_total" -gt "$fix_max" ]; then
        echo "⚠️ 缺失文件 ${missing_total} 个超过单次上限 ${fix_max}（可用 OPENLIST_MISSING_FIX_MAX 调整），本次只修复前 ${fix_max} 个" | tee -a "$LOG_FILENAME"
        head -n "$fix_max" "$missing_list" > "${missing_list}.cut"
        mv "${missing_list}.cut" "$missing_list"
      fi

      echo "=== ${task_name} 缺失文件修复（共 $(wc -l < "$missing_list" | tr -d ' ') 个）===" | tee -a "$LOG_FILENAME"

      fix_log="file_fix_${task_name}_$(date +%Y%m%d_%H%M%S).log"
      echo "=== 缺失文件修复日志 - $(date) ===" > "$fix_log"

      # 增量持久化: 快照当前 marker 作为状态文件，每修复成功一个立即合并写回
      # （中断时已完成的修复不丢失；沿用上轮修复的条目本就来自 marker，无需重写）
      local incr_marker_path incr_state incr_base
      incr_marker_path=$(get_marker_path "$task_name" "$dest_path")
      incr_state="/tmp/${task_name}_fixstate_$$.json"
      incr_base=$(rclone cat "$incr_marker_path" 2>/dev/null) || true
      if ! echo "$incr_base" | jq -e 'type == "object"' >/dev/null 2>&1; then
        incr_base=$(jq -cn --arg sp "$source_path" --arg dp "$dest_path" '{source_path:$sp, dest_path:$dp}')
      fi
      echo "$incr_base" > "$incr_state"

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

        # 名长诊断: cryptencode 本地计算该文件密文名长（纯本地，不上传）
        if [ -n "${_CRYPT_ONTHEFLY:-}" ]; then
          local _nl_fn _nl_enc _nl_enc_len _nl_orig_len _nl_flag=""
          _nl_fn="$(basename -- "$failed_line")"
          _nl_enc=$(rclone cryptencode -- "$_CRYPT_ONTHEFLY" "$_nl_fn" 2>/dev/null || true)
          if [ -n "$_nl_enc" ]; then
            _nl_enc_len=$(printf '%s' "$_nl_enc" | wc -c | tr -d ' ')
            _nl_orig_len=$(printf '%s' "$_nl_fn" | wc -c | tr -d ' ')
            if [ "$_nl_enc_len" -gt 255 ] 2>/dev/null; then
              _nl_flag=" 🔴 >255B"
              _NAMELEN_OVER_255=$((_NAMELEN_OVER_255 + 1))
            fi
            if [ "${_NAMELEN_RAW_MAX:-0}" -gt 0 ] && [ "$_nl_enc_len" -gt "$_NAMELEN_RAW_MAX" ] 2>/dev/null; then
              _nl_flag="${_nl_flag} 🔴 >后端已接受最长(${_NAMELEN_RAW_MAX}B)"
              _NAMELEN_OVER_RAWMAX=$((_NAMELEN_OVER_RAWMAX + 1))
            fi
            echo "  📏 名长: 原名 ${_nl_orig_len}B → 密文名 ${_nl_enc_len}B${_nl_flag}" | tee -a "$LOG_FILENAME"
          fi
        fi

        try_fix_failed_file "$source_path" "$dest_path" "$task_name" "$failed_line" "$fix_log" || true

        if [ "$TRY_FIX_STATUS" = "success" ]; then
          echo "修复成功: ${failed_line} -> 方法: ${TRY_FIX_METHOD}" | tee -a "$LOG_FILENAME"
          echo "  还原方法: ${TRY_FIX_RESTORE}" | tee -a "$LOG_FILENAME"
          echo "${TRY_FIX_ORIGINAL}|${TRY_FIX_ALTERNATIVE}|${TRY_FIX_METHOD}|${TRY_FIX_RESTORE}|${file_size}|${file_size_bytes}|${TRY_FIX_METHOD_ID}" >> "$fix_list"
          FIXED_THIS_RUN["$TRY_FIX_ORIGINAL"]="$TRY_FIX_ALTERNATIVE"
          # 立即记录到修复文件清单（增量持久化，防中断丢失）
          _persist_fix_entry_now "$incr_marker_path" "$incr_state" "$source_path" "$dest_path" \
            "$TRY_FIX_ORIGINAL" "$TRY_FIX_ALTERNATIVE" "$TRY_FIX_METHOD" "$TRY_FIX_RESTORE" \
            "$file_size" "$file_size_bytes" "${TRY_FIX_METHOD_ID:-}" 2>&1 | tee -a "$LOG_FILENAME" || true
        else
          echo "修复失败: ${failed_line} - ${TRY_FIX_MESSAGE}" | tee -a "$LOG_FILENAME"
          echo "${failed_line}|${file_size}|${TRY_FIX_MESSAGE}" >> "$fail_list"
        fi
      done < "$missing_list"

      # 名长诊断汇总（证实/证伪"密文文件名超长"假设的关键数据）
      if [ -n "${_CRYPT_ONTHEFLY:-}" ]; then
        echo "名长诊断汇总: 密文名>255B 共 ${_NAMELEN_OVER_255} 个 / 超后端已接受最长(${_NAMELEN_RAW_MAX}B) 共 ${_NAMELEN_OVER_RAWMAX} 个" | tee -a "$LOG_FILENAME"
        if [ "${_NAMELEN_OVER_RAWMAX:-0}" -gt 0 ]; then
          echo "  → 长度假设成立: 缺失文件密文名超过后端实际接受上限，将由 $(_method_desc m3) 兜底落盘" | tee -a "$LOG_FILENAME"
        elif [ "${_NAMELEN_OVER_255:-0}" -eq 0 ]; then
          echo "  → 长度假设不成立: 缺失文件密文名均未超限，根因另有其因（看 $(_method_desc m2) 的真实报错）" | tee -a "$LOG_FILENAME"
        fi
      fi
    fi
    rm -f "$missing_list"
  fi

  # ===== 修复文件持久化验证：重启 OpenList 容器后检查修复的文件是否仍存在 =====
  # 目的：确认通过 try_fix_failed_file 同步到 wopan176 的文件真正被后端持久化，
  # 而不仅仅存在于 OpenList 内存缓存中（重启容器后即消失）
  # 仅在：有修复成功的文件、目标是 OpenList 远程、能找到 docker 命令的情况下执行
  if [[ "$dest_path" == openlist:* ]] && [ -s "$fix_list" ] && command -v docker >/dev/null 2>&1; then
    echo "=== ${task_name} 修复持久化验证：重启 OpenList 容器后复核修复文件 ===" | tee -a "$LOG_FILENAME"

    # 1. 先过滤出"修复成功且路径仍在该 dest_path 下"的条目，保存待验证清单
    local PERSIST_VERIFY_LIST="/tmp/${task_name}_persist_verify_$$.txt"
    : > "$PERSIST_VERIFY_LIST"
    while IFS='|' read -r f_orig f_alt f_method f_restore f_size f_bytes f_mid; do
      [ -z "$f_alt" ] && continue
      # ALT 路径相对于 dest_path 已经记录在 fix_list，直接用
      echo "${f_alt}|${f_bytes}|${f_orig}|${f_method}|${f_mid}" >> "$PERSIST_VERIFY_LIST"
    done < "$fix_list"
    local verify_total=$(wc -l < "$PERSIST_VERIFY_LIST" | tr -d ' ' || echo 0)
    echo "  待验证修复条目: ${verify_total} 个" | tee -a "$LOG_FILENAME"

    if [ "$verify_total" -gt 0 ] && sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qw openlist; then
      # 2. 刷新 OpenList 缓存（重启前的"最后检查"快照）
      local persist_ol_token
      persist_ol_token=$(_get_openlist_token)
      local persist_ol_path="${dest_path#openlist:}"
      persist_ol_path="/${persist_ol_path}"
      if [ -n "$persist_ol_token" ]; then
        curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh"           -H "Authorization: $persist_ol_token"           -H "Content-Type: application/json"           -d "{"path":"$persist_ol_path","recursive":true}" >/dev/null 2>&1 || true
        sleep 10
      fi

      # 3. 保存重启前的大小快照（用于对比）
      local PERSIST_BEFORE="/tmp/${task_name}_persist_before_$$.txt"
      : > "$PERSIST_BEFORE"
      while IFS='|' read -r alt_path bytes orig_path f_method f_mid; do
        [ -z "$alt_path" ] && continue
        local full_alt="${dest_path}/${alt_path}"
        local sz
        sz=$(rclone size --json "$full_alt" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
        echo "${alt_path}|${bytes}|${sz}" >> "$PERSIST_BEFORE"
        echo "  重启前大小检查: $alt_path (expected=$bytes, actual=$sz)" | tee -a "$LOG_FILENAME"
      done < "$PERSIST_VERIFY_LIST"

      # 4. 重启 OpenList 容器
      echo "  重启 OpenList 容器..." | tee -a "$LOG_FILENAME"
      sudo docker restart openlist 2>&1 | tee -a "$LOG_FILENAME"

      # 5. 等待 HTTP 就绪 + 驱动重新初始化
      local persist_http_ok=0
      for i in $(seq 1 30); do
        if curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1; then
          persist_http_ok=1
          echo "  OpenList HTTP 就绪 (${i}次)" | tee -a "$LOG_FILENAME"
          break
        fi
        sleep 2
      done
      if [ "$persist_http_ok" -eq 1 ]; then
        echo "  等待驱动重新初始化 (60s) ..." | tee -a "$LOG_FILENAME"
        sleep 60
        # 重新刷新缓存（驱动重启后强制从后端拉列表）
        persist_ol_token=$(_get_openlist_token)
        if [ -n "$persist_ol_token" ]; then
          curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh"             -H "Authorization: $persist_ol_token"             -H "Content-Type: application/json"             -d "{"path":"$persist_ol_path","recursive":true}" >/dev/null 2>&1 || true
          sleep 20
        fi

        # 6. 逐个复核修复文件（最多抽取前 6 条，避免耗时过长）
        # 判定规则见 _persist_verify_entries（原样 copy 精确匹配大小；
        # 压缩/分卷/编码类只检查存在且非空）；失败条目当场拉黑并收集，
        # 供第 7 步本轮立即换方法重试
        _persist_verify_entries "$dest_path" "$PERSIST_VERIFY_LIST" 6 "$LOG_FILENAME"
        local persist_ok=$PERSIST_OK
        local persist_fail=$PERSIST_FAIL
        local persist_idx=$PERSIST_IDX
        echo "  持久化验证汇总: 抽样 ${persist_idx} / 通过 ${persist_ok} / 失败 ${persist_fail}" | tee -a "$LOG_FILENAME"
        if [ "$persist_fail" -gt 0 ] && [ "$persist_ok" -eq 0 ]; then
          echo "  🔴 结论：所有抽样修复文件在容器重启后均消失 → OpenList PUT 返回成功但 wopan176 后端未真正持久化（写入内存缓存后未刷盘/未提交）" | tee -a "$LOG_FILENAME"
          # 标记为持久化失败（影响通知但不阻止后续 task）
          SYNC_PERSIST_FAIL=1
        elif [ "$persist_fail" -gt 0 ]; then
          echo "  🟡 结论：部分修复文件在容器重启后消失 → 存在间歇性持久化失败" | tee -a "$LOG_FILENAME"
          SYNC_PERSIST_FAIL=1
        else
          echo "  🟢 结论：抽样修复文件均已被后端持久化（重启后仍然存在）" | tee -a "$LOG_FILENAME"
        fi
        # B: 复核拉黑的方法立即落盘 marker（不等任务结束统一保存——
        # run 31917285452 实测拉黑 5 条最终保存 0 条，黑名单在进程内丢失）
        _flush_blacklist_to_marker "$task_name" "$dest_path" "$LOG_FILENAME"

        # 7. 假成功条目本轮立即换方法重试（不再等下一轮）
        # 黑名单已含刚才判定的假成功方法，try_fix_failed_file 会直接跳过
        # 失效方法、从下一个方法继续尝试；重试成功后再重启容器二次复核
        if [ "$persist_fail" -gt 0 ] && [ "${#PERSIST_FAILED_ORIGS[@]}" -gt 0 ]; then
          echo "=== ${task_name} 假成功条目本轮立即换方法重试（${#PERSIST_FAILED_ORIGS[@]} 个）===" | tee -a "$LOG_FILENAME"

          # fix_log 可能为空（缺失清单为空、条目全部沿用上轮修复的场景）
          if [ -z "$fix_log" ]; then
            fix_log="file_fix_${task_name}_$(date +%Y%m%d_%H%M%S).log"
            echo "=== 缺失文件修复日志 - $(date) ===" > "$fix_log"
          fi

          # 重试状态快照: 从当前 marker 重建（成功条目按 original 覆盖假成功条目）
          local incr_marker_path incr_state incr_base
          incr_marker_path=$(get_marker_path "$task_name" "$dest_path")
          incr_state="/tmp/${task_name}_fixstate_retry_$$.json"
          incr_base=$(rclone cat "$incr_marker_path" 2>/dev/null) || true
          if ! echo "$incr_base" | jq -e 'type == "object"' >/dev/null 2>&1; then
            incr_base=$(jq -cn --arg sp "$source_path" --arg dp "$dest_path" '{source_path:$sp, dest_path:$dp}')
          fi
          echo "$incr_base" > "$incr_state"

          # A 层即时检测基线重建: 容器重启后幽灵文件已从计数中消失，
          # 旧基线偏高会把重试的真实落盘误判为假成功
          if [ -n "${_RAW_VERIFY_DEST:-}" ]; then
            _RAW_VERIFY_BUDGET="${OPENLIST_RAW_CHECK_BUDGET:-40}"
            local _retry_raw_base
            if _retry_raw_base=$(_raw_dir_count "$_RAW_VERIFY_DIR" "${_RAW_VERIFY_REFRESH:-}"); then
              _RAW_VERIFY_LAST=$_retry_raw_base
              echo "  重试前 raw 基准已重建: ${_retry_raw_base}" | tee -a "$LOG_FILENAME"
            fi
          fi

          local retry_orig retry_fixed=0
          local PERSIST_RETRY_LIST="/tmp/${task_name}_persist_retry_$$.txt"
          : > "$PERSIST_RETRY_LIST"
          for retry_orig in "${PERSIST_FAILED_ORIGS[@]}"; do
            [ -z "$retry_orig" ] && continue
            echo "重试修复（换方法）: ${retry_orig}" | tee -a "$LOG_FILENAME"

            # 先从 fix_list 移除旧假成功条目（无论重试成败都不保留）
            RO="$retry_orig" awk 'BEGIN{FS="|"} $1 != ENVIRON["RO"]' "$fix_list" > "${fix_list}.tmp" && mv "${fix_list}.tmp" "$fix_list"

            try_fix_failed_file "$source_path" "$dest_path" "$task_name" "$retry_orig" "$fix_log" || true

            if [ "$TRY_FIX_STATUS" = "success" ]; then
              retry_fixed=$((retry_fixed + 1))
              echo "重试修复成功: ${retry_orig} -> 方法: ${TRY_FIX_METHOD}" | tee -a "$LOG_FILENAME"
              echo "  还原方法: ${TRY_FIX_RESTORE}" | tee -a "$LOG_FILENAME"
              local retry_size_json retry_size_bytes retry_size_human
              retry_size_json=$(rclone size "${source_path}/${retry_orig}" --json 2>/dev/null || echo '{}')
              retry_size_bytes=$(echo "$retry_size_json" | jq -r '.bytes // 0' 2>/dev/null || echo 0)
              [[ "$retry_size_bytes" =~ ^[0-9]+$ ]] || retry_size_bytes=0
              retry_size_human=$(format_bytes "$retry_size_bytes")
              echo "${TRY_FIX_ORIGINAL}|${TRY_FIX_ALTERNATIVE}|${TRY_FIX_METHOD}|${TRY_FIX_RESTORE}|${retry_size_human}|${retry_size_bytes}|${TRY_FIX_METHOD_ID}" >> "$fix_list"
              FIXED_THIS_RUN["$TRY_FIX_ORIGINAL"]="$TRY_FIX_ALTERNATIVE"
              # 覆盖 marker 里的假成功条目（同 original 新条目替换旧条目）
              _persist_fix_entry_now "$incr_marker_path" "$incr_state" "$source_path" "$dest_path" \
                "$TRY_FIX_ORIGINAL" "$TRY_FIX_ALTERNATIVE" "$TRY_FIX_METHOD" "$TRY_FIX_RESTORE" \
                "$retry_size_human" "$retry_size_bytes" "${TRY_FIX_METHOD_ID:-}" 2>&1 | tee -a "$LOG_FILENAME" || true
              echo "${TRY_FIX_ALTERNATIVE}|${retry_size_bytes}|${TRY_FIX_ORIGINAL}|${TRY_FIX_METHOD}|${TRY_FIX_METHOD_ID}" >> "$PERSIST_RETRY_LIST"
            else
              echo "重试修复失败: ${retry_orig} - ${TRY_FIX_MESSAGE}" | tee -a "$LOG_FILENAME"
              echo "${retry_orig}|未知|重试修复失败: ${TRY_FIX_MESSAGE:-所有修复方法均失败}" >> "$fail_list"
              unset "FIXED_THIS_RUN[$retry_orig]" 2>/dev/null || true
              # 从 marker 移除假成功条目，避免下一轮作为"沿用上轮修复"空转
              _remove_fix_entry_from_state "$incr_state" "$incr_marker_path" "$retry_orig" 2>&1 | tee -a "$LOG_FILENAME" || true
            fi
          done

          # 8. 二次复核: 重启容器验证换方法后的重试结果是否真正持久化
          if [ "$retry_fixed" -gt 0 ]; then
            echo "  重启 OpenList 容器二次复核重试结果（${retry_fixed} 个）..." | tee -a "$LOG_FILENAME"
            sudo docker restart openlist >/dev/null 2>&1 || true
            local retry_http_ok=0 retry_i
            for retry_i in $(seq 1 30); do
              if curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1; then
                retry_http_ok=1
                echo "  OpenList HTTP 就绪 (${retry_i}次)" | tee -a "$LOG_FILENAME"
                break
              fi
              sleep 2
            done
            if [ "$retry_http_ok" -eq 1 ]; then
              echo "  等待驱动重新初始化 (60s) ..." | tee -a "$LOG_FILENAME"
              sleep 60
              persist_ol_token=$(_get_openlist_token)
              if [ -n "$persist_ol_token" ]; then
                curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" -H "Authorization: $persist_ol_token" -H "Content-Type: application/json" -d "{\"path\":\"$persist_ol_path\",\"recursive\":true}" >/dev/null 2>&1 || true
                sleep 20
              fi
              _persist_verify_entries "$dest_path" "$PERSIST_RETRY_LIST" 999 "$LOG_FILENAME"
              echo "  重试持久化验证汇总: 抽样 ${PERSIST_IDX} / 通过 ${PERSIST_OK} / 失败 ${PERSIST_FAIL}" | tee -a "$LOG_FILENAME"
              # 二次复核仍失败的条目: 移出 fix_list、清理 marker、记入 fail_list
              local r2_orig
              for r2_orig in "${PERSIST_FAILED_ORIGS[@]}"; do
                [ -z "$r2_orig" ] && continue
                echo "  二次复核失败，转入失败清单: ${r2_orig}" | tee -a "$LOG_FILENAME"
                RO="$r2_orig" awk 'BEGIN{FS="|"} $1 != ENVIRON["RO"]' "$fix_list" > "${fix_list}.tmp" && mv "${fix_list}.tmp" "$fix_list"
                echo "${r2_orig}|未知|换方法重试后仍未持久化（黑名单已记录，下一轮从剩余方法继续）" >> "$fail_list"
                unset "FIXED_THIS_RUN[$r2_orig]" 2>/dev/null || true
                _remove_fix_entry_from_state "$incr_state" "$incr_marker_path" "$r2_orig" 2>&1 | tee -a "$LOG_FILENAME" || true
              done
              if [ "$PERSIST_FAIL" -gt 0 ]; then
                echo "  🔴 重试结论：换方法后仍有 ${PERSIST_FAIL} 个文件未持久化（黑名单已更新，下一轮从剩余方法继续）" | tee -a "$LOG_FILENAME"
                SYNC_PERSIST_FAIL=1
              else
                echo "  🟢 重试结论：换方法后全部通过持久化验证，清除持久化失败标记" | tee -a "$LOG_FILENAME"
                SYNC_PERSIST_FAIL=0
              fi
              _flush_blacklist_to_marker "$task_name" "$dest_path" "$LOG_FILENAME"
            else
              echo "  ⚠️ 二次复核重启后 HTTP 未就绪，跳过重试结果验证（本轮以即时校验为准）" | tee -a "$LOG_FILENAME"
            fi
          else
            echo "  重试全部失败（所有方法均不可用），黑名单已保留（下一轮从剩余方法继续）" | tee -a "$LOG_FILENAME"
          fi
          rm -f "$PERSIST_RETRY_LIST"
        fi
      else
        echo "  ⚠️ OpenList 容器重启后 HTTP 60s 内未就绪，跳过持久化验证" | tee -a "$LOG_FILENAME"
      fi
      rm -f "$PERSIST_VERIFY_LIST" "$PERSIST_BEFORE"
    else
      echo "  跳过持久化验证（无修复成功条目或 openlist 容器不存在）" | tee -a "$LOG_FILENAME"
    fi
  fi

  # ===== object not found 错误解析（源文件不存在）=====
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

  # 发送同步结果通知
  _send_sync_result_notification \
    "$source_path" "$dest_path" "$task_name" "$SYNC_STATUS" \
    "$LOG_FILENAME" "$LAST_ATTEMPT_LOG" \
    "$fail_list" "$fix_list" "$fix_log" \
    "$HAS_OBJECT_NOT_FOUND" \
    "${extra_args[@]}"

  # 把 fix_list 序列化为 JSON 供 save_sync_marker 使用
  # 格式: [{original, alternative, method, size_human, size_bytes, restore: {kind, summary, steps, script}}]
  # restore 字段记录还原方式，便于日后从目标端恢复原始文件
  LAST_SYNC_FIXED_FILES_JSON="[]"
  if [ -s "$fix_list" ]; then
    LAST_SYNC_FIXED_FILES_JSON=$(jq -R -s '
      def restore_info($orig; $alt; $method; $src; $dst):
        # 14 种修复方式精确识别（方法 1-14）：
        #   "原路径 + 原文件名"                             → 原样 copy (方法1)
        #   "base64URL 编码目录 + 原文件名"                → 仅 b64 目录 (方法1变体)
        #   "原路径 + base64URL 编码文件名"                → 仅 b64 文件名 (方法2)
        #   "base64URL 编码目录 + base64URL 编码文件名"    → b64 目录+文件名 (方法2变体)
        #   "原路径 + zip 压缩包"                          → zip (方法3)
        #   "base64URL 编码目录 + zip 压缩包"              → zip(+b64dir) (方法3变体)
        #   "原路径 + 7z 压缩包"                           → 7z (方法4)
        #   "base64URL 编码目录 + 7z 压缩包"               → 7z(+b64dir) (方法4变体)
        #   "原路径 + 100MB 分卷切割"                      → split zip (方法5)
        #   "base64URL 编码目录 + 100MB 分卷切割"          → split zip(+b64dir) (方法5变体)
        #   "原路径 + base64URL 编码文件名 + 100MB 分卷切割" → split zip + b64name (方法6)
        #   "base64URL 编码目录 + base64URL 编码文件名 + 100MB 分卷切割" → split zip(+b64dir+b64name) (方法6变体)
        #   "原路径 + API 自动生成文件名"                  → api rename (方法7)
        #   "base64URL 编码目录 + API 自动生成文件名"      → api rename(+b64dir) (方法7变体)
        #   "重命名 .bak"                                 → rename .bak (方法8)
        #   "父目录 + 编码原始目录名的文件名"              → parent dir (方法9)
        #   "上传到根 backup 目录 + 编码文件名"            → root backup (方法10/11)
        #   "base64 编码文件内容 + .b64 扩展名"            → base64 content (方法12)
        #   "AES256 加密 zip + .enc.zip 扩展名"             → encrypted zip (方法13)
        #   "临时目录上传 + OpenList API move"             → tmp + move (方法14)
        # 注: 不能用 ".*文件名" 模糊匹配，"原文件名" 里也有 "文件名" 3 个字，会误判
        ($method | test("base64URL 编码目录 ")) as $has_b64_dir
        | ($method | test("base64URL 编码文件名")) as $has_b64_name
        | ($method | test("zip 压缩包")) as $has_zip
        | ($method | test("7z 压缩包")) as $has_7z
        | ($method | test("API 自动生成文件名")) as $has_api
        | ($method | test("重命名 .bak")) as $has_bak
        | ($method | test("父目录")) as $has_parent
        | ($method | test("base64 编码文件内容")) as $has_b64_content
        | ($method | test("AES256 加密 zip")) as $has_enc_zip
        | ($method | test("临时目录上传")) as $has_tmp_move
        | ($method | test("短哈希文件名")) as $has_short_hash
        | ($method | test("分卷切割") and ($method | test("base64URL 编码文件名") | not)) as $has_split_zip
        | ($method | test("分卷切割") and ($method | test("base64URL 编码文件名"))) as $has_split_zip_b64name
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
          elif $has_short_hash then {kind:"short_hash_rename",
            summary: "文件名替换为 8 位 md5 前缀（规避密文名超长），内容未变",
            steps:   ["下载目标端 " + $alt, "重命名为原文件名: " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
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
          elif $has_b64_content then {kind:"base64_content",
            summary: "文件内容被 base64 编码后上传，完全改变了 hash 和内容特征",
            steps:   ["下载目标端 " + $alt, "执行: base64 -d <alt_file> > <orig_file>", "解码后得到原始文件 " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/encoded.b64\" --progress\nbase64 -d \"$TMP/encoded.b64\" > \"$TMP/" + $orig_name + "\"\n# 还原后的源文件在: $TMP/" + $orig_name + "\n# 如需回传源端: rclone copyto \"$TMP/" + $orig_name + "\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_enc_zip   then {kind:"encrypted_zip",
            summary: "文件被 AES256 加密 zip 打包后上传，改变了二进制特征",
            steps:   ["下载目标端 " + $alt, "执行: 7z x -p<password> <enc_zip> -o<output_dir>", "解压后得到 " + $orig_name],
            script:  "set -euo pipefail\n# 密码在修复时的 restore_hint 中记录\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nrclone copyto \"${DST}/${ALT}\" \"$TMP/package.enc.zip\" --progress\n# 密码格式: OpenList<timestamp>，从 restore_hint 中获取\n7z x -p\"OpenList<password>\" \"$TMP/package.enc.zip\" -o\"$TMP/out\" -y\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\nrm -rf \"$TMP\""}
          elif $has_bak       then {kind:"rename_bak",
            summary: "文件被重命名为 .bak 后缀后上传",
            steps:   ["下载目标端 " + $alt, "重命名为原始文件名: " + $orig_name],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 文件已恢复原始文件名\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_parent    then {kind:"parent_dir",
            summary: "文件上传到父目录（跳过有问题的子目录），文件名编码了原始目录信息",
            steps:   ["下载目标端 " + $alt, "从文件名 __fixed__<base64>__<filename> 中解码原始目录名", "移动到正确的目录路径"],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nORIG_FNAME=\"" + $orig_name + "\"\nrclone copyto \"${DST}/${ALT}\" \"$TMP/${ORIG_FNAME}\" --progress\n# 如需回传源端: rclone copyto \"$TMP/${ORIG_FNAME}\" \"${SRC}/${ORIG}\"\nrm -rf \"$TMP\""}
          elif $has_split_zip then {kind:"split_zip",
            summary: "文件被打包为 zip（存储模式 mx=0）并切割为 100MB 分卷上传，分卷命名 <name>.zip.001/.002/...",
            steps:   ["下载所有 .zip.0* 分卷到同一目录", "按顺序合并: cat *.zip.0* > merged.zip", "执行: 7z x merged.zip -o<output_dir>（或 unzip merged.zip）"],
            script:  "set -euo pipefail\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_DIR=$(dirname \"$ALT\")\nALT_FNAME=$(basename \"$ALT\")\nSPLIT_PREFIX=\"${ALT_FNAME%.*}\"\necho \"分卷前缀: $SPLIT_PREFIX\"\nrclone copy \"${DST}/${ALT_DIR}\" \"$TMP\" --include \"${SPLIT_PREFIX}.zip.*\" --progress 2>&1 | tail -5\ncd \"$TMP\"\ncat ${SPLIT_PREFIX}.zip.0* > merged.zip\necho \"合并后 zip 大小: $(stat -c%s merged.zip 2>/dev/null || stat -f%z merged.zip 2>/dev/null) bytes\"\n7z x merged.zip -o\"$TMP/out\" -y || unzip merged.zip -d \"$TMP/out\"\n# 还原后的源文件在: $TMP/out/" + $orig_name + "\nrm -rf \"$TMP\""}
          elif $has_split_zip_b64name then {kind:"split_zip_b64name",
            summary: "文件名 base64URL 编码后，zip 打包并切割为 100MB 分卷上传（分卷命名 <encoded>.zip.001/.002/...）",
            steps:   ["下载所有 .zip.0* 分卷到同一目录", "按顺序合并: cat *.zip.0* > merged.zip", "解压 merged.zip 得到原始内容文件", "文件名还原：对编码文件名的 base64URL 前缀部分解码"],
            script:  "set -euo pipefail\nb64url_decode() {\n  local s=\"$1\"; s=\"${s//-/+}\"; s=\"${s//_/}\"\n  local pad=$(( (4 - ${#s} % 4) % 4 )); while [ $pad -gt 0 ]; do s=\"$s=\"; pad=$((pad-1)); done\n  printf \"%s\" \"$s\" | base64 -d\n}\nSRC=\"" + $src + "\"\nDST=\"" + $dst + "\"\nORIG=\"" + $orig + "\"\nALT=\"" + $alt + "\"\nTMP=$(mktemp -d)\nALT_DIR=$(dirname \"$ALT\")\nALT_FNAME=$(basename \"$ALT\")\nSPLIT_FULL_PREFIX=\"${ALT_FNAME%.*}\"\nENCODED_BASE=\"${SPLIT_FULL_PREFIX%.zip}\"\n[ -z \"$ENCODED_BASE\" ] && ENCODED_BASE=\"${SPLIT_FULL_PREFIX}\"\nif [[ \"$ENCODED_BASE\" == *.* ]]; then\n  NAME_EXT=\"${ENCODED_BASE##*.}\"\n  NAME_NOEXT=\"${ENCODED_BASE%.*}\"\n  DECODED_NOEXT=$(b64url_decode \"$NAME_NOEXT\")\n  DECODED_FNAME=\"${DECODED_NOEXT}.${NAME_EXT}\"\nelse\n  DECODED_FNAME=$(b64url_decode \"$ENCODED_BASE\")\nfi\necho \"还原文件名: $ENCODED_BASE -> $DECODED_FNAME\"\nrclone copy \"${DST}/${ALT_DIR}\" \"$TMP\" --include \"${SPLIT_FULL_PREFIX}.*\" --progress 2>&1 | tail -5\ncd \"$TMP\"\ncat ${SPLIT_FULL_PREFIX}.0* > merged.zip 2>/dev/null || ( ls *.zip.0* >/dev/null 2>&1 && cat *.zip.0* > merged.zip )\necho \"合并后 zip 大小: $(stat -c%s merged.zip 2>/dev/null || stat -f%z merged.zip 2>/dev/null) bytes\"\n7z x merged.zip -o\"$TMP/out\" -y || unzip merged.zip -d \"$TMP/out\"\nls -la \"$TMP/out/\"\nrm -rf \"$TMP\""}
                    elif $has_tmp_move  then {kind:"tmp_move",
            summary: "文件上传到临时目录后用 OpenList API move 移动（可能已移动或保留在临时目录）",
            steps:   ["检查目标路径是否已有原文件", "如未移动，用 OpenList API move 从临时目录移动"],
            script:  "set -euo pipefail\n# 检查目标是否已存在\nrclone lsjson \u0027" + $dst + "/" + $orig + "\u0027 --max-depth 1 2>/dev/null | jq \u0027length\u0027\n# 如不存在，用 OpenList API move\n# curl -X POST http://127.0.0.1:5244/api/fs/move -H \u0027Authorization: <token>\u0027 -d \u0027{\"src_dir\":\"/wopan176Crypt/backup/" + $alt + "\",\"dst_dir\":\"/wopan176Crypt/backup/" + $orig + "\"}\u0027"}
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
            restore_hint: $f[3],
            size_human:  $f[4],
            size_bytes:  ($f[5] // "0" | tonumber),
            method_id:   ($f[6] // "")
          }
        | . + {restore: (restore_info(.original; .alternative; .method; "'"$source_path"'"; "'"$dest_path"'") + {hint: .restore_hint})}
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

  # 累计方法假成功黑名单到全局变量（B: 失败记忆，供 save_sync_marker 写入 marker
  # 的 fix_blacklist 字段，下一轮修复时跳过对应方法）
  local _task_bl_json="{}"
  if [ "${#FIX_METHOD_BLACKLIST[@]}" -gt 0 ]; then
    local _bl_f
    for _bl_f in "${!FIX_METHOD_BLACKLIST[@]}"; do
      _task_bl_json=$(jq -cn --argjson j "$_task_bl_json" --arg k "$_bl_f" --arg v "${FIX_METHOD_BLACKLIST[$_bl_f]}" \
        '$j + {($k): $v}' 2>/dev/null || echo "{}")
    done
  fi
  if [ -z "${GLOBAL_FIX_BLACKLIST_JSON:-}" ] || ! echo "${GLOBAL_FIX_BLACKLIST_JSON:-}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    GLOBAL_FIX_BLACKLIST_JSON="{}"
  fi
  GLOBAL_FIX_BLACKLIST_JSON=$(jq -cn --argjson a "$GLOBAL_FIX_BLACKLIST_JSON" --argjson b "$_task_bl_json" \
    '$a * $b' 2>/dev/null || echo "$GLOBAL_FIX_BLACKLIST_JSON")
  # 面包屑: 定位黑名单在链路（数组→GLOBAL→save）中的实际流转（排查 31917285452 丢失问题）
  # 注意: 不能写 ${VAR:-{}} —— bash 把默认词的 } 当作展开结束符，会给已赋值变量
  # 追加一个字面 }（"{...5条...}}"），jq 解析失败后面包屑拆成 "GLOBAL 5 / ? 条"
  # 两行矛盾日志，marker 侧同因把黑名单清零（详见 marker.sh save_fix_state_marker）
  local _global_bl_len="?"
  _global_bl_len=$(printf '%s' "$GLOBAL_FIX_BLACKLIST_JSON" | jq -r 'length' 2>/dev/null) || _global_bl_len="?"
  [[ "$_global_bl_len" =~ ^[0-9]+$ ]] || _global_bl_len="?"
  if [ "${#FIX_METHOD_BLACKLIST[@]}" -gt 0 ] || [ "$_global_bl_len" != "0" ]; then
    echo "黑名单累计: 数组 ${#FIX_METHOD_BLACKLIST[@]} 条 → GLOBAL ${_global_bl_len} 条" | tee -a "$LOG_FILENAME"
  fi

  [ -n "${incr_state:-}" ] && rm -f "$incr_state" 2>/dev/null || true
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
  local has_object_not_found="${10}"
  shift 10
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

  # raw-vs-crypt 幽灵文件提示（仅 wopan176Crypt 目标且检测到时展示）
  if [ "${RAW_CRYPT_GHOST_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    count_info+=$'\n'"⚠️ raw-vs-crypt 幽灵文件：${RAW_CRYPT_GHOST_COUNT} 个（密文未落盘，已重启 OpenList 后重新修复）"
  fi

  # 提取 --exclude 规则，方便在通知中说明
  local exclude_list=""
  exclude_list=$(_build_exclude_bullets "${extra_args[@]}")

  # 构建 fix_summary（已修复文件：原始文件名 → 实际文件名）
  local fix_summary=""
  if [ -s "$fix_list" ]; then
    while IFS='|' read -r f_original f_alternative f_method f_restore f_size f_bytes f_mid; do
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
    if [ "$has_object_not_found" -eq 1 ]; then
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
    # 所有缺失文件都已通过其他方式同步
    local partial_msg=""
    partial_msg+="⚠️ ${task_name} 部分文件已通过其他方式同步"$'\n'
    partial_msg+='━━━━━━━━━━━━━━'$'\n'
    partial_msg+="源端大小：${source_size_human}"$'\n'
    partial_msg+="目标大小：${dest_size_human}"$'\n'
    partial_msg+="状态：缺失文件已全部通过替代方式同步"$'\n'
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
