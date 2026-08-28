#!/bin/bash
# ===== OpenList 同步工具 — 驱动维护 / 健康预检 / 缓存与真值校验 =====
#
# 职责边界:
#   - 驱动 token 刷新与保鲜（load_all 重载 / 容器重启 / 定时保鲜循环）
#   - 同步前健康预检（WebDAV 层错误签名归类 + 管理面 API 强制列目录）
#   - OpenList 缓存刷新与 truth-check（重启容器取后端真值，暴露"上传成功
#     但未持久化"的假成功文件）
#
# 拆分缘由: sync_engine.sh 曾同时承担同步编排、驱动维护、修复管线、通知排版四类
#   职责（2000+ 行）。本组是"与 OpenList 服务打交道"的部分，与同步编排逻辑
#   无耦合，独立后按职责即可定位。
#
# 依赖: openlist_api.sh (_get_openlist_token), utils.sh (_log_section, _short_path),
#       file_fix.sh (_raw_remote_for, _raw_dir_count)
# 被依赖: sync_engine.sh (sync_with_logging, _sync_retry_8005,
#         _sync_persist_verify_and_retry), sync_notify.sh (_refresh_openlist_cache)

# 刷新 OpenList 全部驱动的 token（重建驱动，非 wopan176 专属）
# 主要动机: wopan176 的 access token 有效期短（约 5 分钟），长时间同步会过期，
#           过期后 wopan 驱动的 PUT 全部假成功（rclone 报 Copied (new)，密文
#           从未落盘，容器重启后消失）——run 32749862280 实锤: 3 小时批次
#           139/139 假成功，30.757 GiB 全部未落盘。
#
# 注意区分两个时效层次（勿混淆，doc.oplist.org/guide/drivers/wopan）:
#   - 上述"约 5 分钟"是 OAuth access_token 的短时效，由 refresh_token 自动
#     续期——本函数维护的就是这条自动链路；
#   - 文档所述"登录态有效期 7 天（方法一）/2 个月（方法二）"是手动抓取凭据
#     的整体寿命上限，到期无法自动续，只能人工重抓；且重抓时跨端登录互踢
#     （方法一怕网页端登录、方法二怕手机 APP 登录），操作前须核对挂载所用
#     方法。真失效属人工事件，预检不应也无法自动修复它。
#
# 驱动刷新方法1: POST /api/admin/storage/load_all — OpenList 官方"重新加载所有
#        存储" API，从数据库重新初始化全部驱动（等效容器重启的驱动重建，秒级
#        完成、可无限次重复，传输期间的定时保鲜循环也用它）。
#        历史教训: 旧端点 /api/driver/update 在 AList/OpenList API 中不存在，
#        恒失败（run 32749862280: 容器重启后 76 秒仍失败实锤）——其失败
#        ≠驱动坏，不能当驱动状态信号。run 31945907528/31951008332 的
#        "storage 配置重载后放行 → 窗口期 PUT 全部假成功"事故，根因正是
#        驱动刷新方法1 恒失败 + 驱动刷新方法3 不重建驱动。
# 驱动刷新方法2: 重启容器（load_all 不可用且本轮未重启过时；驱动完整重初始化 +
#        换新 token，一次 ~2 分钟），_OL_DRIVER_RESTART_DONE 每轮（进程
#        生命周期）最多标记一次
# 驱动刷新方法3（兜底）: storage/list 探测——不重建驱动，仅确认 API 可达
#
# 命名口径: 以上"驱动刷新方法N"是本函数的三招，与 file_fix.sh 的"文件修复方法N"
#   （copyto_original 等 4 种）是两套互不相干的编号体系，日志与注释里的
#   简写必须带领域限定词，否则读到"方法1"时无从判断指哪一套。
# 用法: _refresh_ol_drivers [log_filename]
# 返回: 0=成功刷新, 非0=刷新失败
_OL_DRIVER_RESTART_DONE=0
_refresh_ol_drivers() {
  local log_file="${1:-/dev/null}"
  local ol_token
  ol_token=$(_get_openlist_token)
  if [ -z "$ol_token" ]; then
    echo "  OpenList 驱动 token 刷新: OpenList token 不可用" | tee -a "$log_file"
    return 1
  fi

  echo "  刷新 OpenList 后端驱动 token（含 wopan176，access token 约 5 分钟过期）..." | tee -a "$log_file"

  # 方法 1: POST /api/admin/storage/load_all 从数据库重载全部存储，
  # 触发各驱动用 refresh_token 换取新的 access_token（wopan176 为典型）
  local refresh_result
  refresh_result=$(curl -s -X POST "http://127.0.0.1:5244/api/admin/storage/load_all" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d '{}' \
    --max-time 30 2>&1)

  if echo "$refresh_result" | grep -qE '"code":(200|0)|"message":"success'; then
    echo "  OpenList 驱动 token 刷新成功 (驱动刷新方法1: /api/admin/storage/load_all 驱动已重建)" | tee -a "$log_file"
    sleep 5
    return 0
  fi

  # 驱动刷新方法2: 重启容器（load_all 不可用 = token 权限不足/版本差异，见函数头注释）
  if [ "$_OL_DRIVER_RESTART_DONE" -eq 0 ]; then
    echo "  驱动刷新方法1 (/api/admin/storage/load_all) 失败: ${refresh_result:0:200} → 重启容器重建驱动..." | tee -a "$log_file"
    if _restart_openlist_for_truth "" "$log_file"; then
      _OL_DRIVER_RESTART_DONE=1
      echo "  OpenList 驱动 token 刷新成功 (驱动刷新方法2: 容器重启，驱动已完整重初始化)" | tee -a "$log_file"
      return 0
    fi
    echo "  ⚠️ 驱动刷新方法2 容器重启失败，退回驱动刷新方法3: storage 配置重载..." | tee -a "$log_file"
  else
    echo "  驱动刷新方法1 失败（本轮已重启过容器，跳过重复重启），退回驱动刷新方法3: storage 配置重载..." | tee -a "$log_file"
  fi

  # 驱动刷新方法3（兜底）: 通过 /api/storage/list 后逐个刷新 storage 配置
  # 仅在容器不可重启/本轮已重启过仍失败时使用——该方法不重建驱动，
  # 若驱动真处坏状态则放行同步会重演假成功窗口
  local storage_list
  storage_list=$(curl -s -X GET "http://127.0.0.1:5244/api/storage/list" \
    -H "Authorization: $ol_token" \
    --max-time 30 2>&1)

  if [ -n "$storage_list" ] && [ "$storage_list" != "null" ]; then
    echo "  storage 配置已加载，触发刷新..." | tee -a "$log_file"
    sleep 3
    return 0
  fi

  echo "  ⚠️ OpenList 驱动 token 刷新失败: $refresh_result" | tee -a "$log_file"
  return 1
}

# ===== 传输期间的后台 token 保鲜循环 =====
# wopan access token 约 5 分钟过期，OpenList 驱动 token 失效后 PUT 全部
# 假成功（run 32749862280: 3 小时批次 139/139 假成功、30.757 GiB 全部
# 未落盘实锤）。仅靠传输前刷新一次远远不够——长时间 rclone 命令（批次
# 上传/巩固重试/主同步动辄数小时）执行期间，每 OPENLIST_TOKEN_REFRESH_SECS
# 秒（默认 240s < 5min）后台调一次 load_all 重建驱动，保证任意时刻新
# 请求拿到的 token 剩余有效期 > 1 分钟。
# 重建瞬间的在途请求由旧驱动实例收尾（其 token 龄 ≤ 刷新周期 < 5 分钟，
# 仍在有效期内），不受影响。
# 用法: 传输命令前 _start_token_refresher，结束后 _stop_token_refresher
# 开关: OPENLIST_TOKEN_REFRESH_SECS=0 显式关闭保鲜循环
OPENLIST_TOKEN_REFRESH_SECS="${OPENLIST_TOKEN_REFRESH_SECS:-240}"
_OL_TOKEN_REFRESHER_PID=""
_start_token_refresher() {
  _stop_token_refresher
  local interval="${OPENLIST_TOKEN_REFRESH_SECS:-0}"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=240
  [ "$interval" -eq 0 ] && return 0
  (
    while :; do
      sleep "$interval"
      _t=$(_get_openlist_token 2>/dev/null) || continue
      curl -s -m 30 -X POST "http://127.0.0.1:5244/api/admin/storage/load_all" \
        -H "Authorization: $_t" \
        -H "Content-Type: application/json" \
        -d '{}' >/dev/null 2>&1 || true
    done
  ) &
  _OL_TOKEN_REFRESHER_PID=$!
  echo "  🔁 token 保鲜循环已启动（每 ${interval}s load_all 重建驱动，pid=${_OL_TOKEN_REFRESHER_PID}）"
}

_stop_token_refresher() {
  if [ -n "${_OL_TOKEN_REFRESHER_PID:-}" ]; then
    kill "$_OL_TOKEN_REFRESHER_PID" 2>/dev/null || true
    wait "$_OL_TOKEN_REFRESHER_PID" 2>/dev/null || true
    _OL_TOKEN_REFRESHER_PID=""
    echo "  🔁 token 保鲜循环已停止"
  fi
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

# 对 rclone lsd 预检失败输出归类，返回: auth=认证失效 unreachable=网络不可达
# backend=后端/驱动异常 notfound=目录尚未创建 unknown=未知错误。
# 教训（run 33026674750）: baidupan 登录失效时 OpenList 层报的是
# "Conflict: 409 Conflict"/mkParentDir failed 这类非典型形态，
# 旧版关键词规则匹配不上会静默放行，直接带着死驱动进入写流程。
_classify_probe_failure() {
  local out="$1"
  if echo "$out" | grep -Eqi 'unauthorized|permission denied|not authenticated|login|登录失败|登录失效|登录已过期|授权|token.*(expired|invalidated|invalid)|invalidated|auth.*fail|auth.*error|credential|identity|invalid_grant|401|403|Method Not Allowed'; then
    echo auth
  elif echo "$out" | grep -Eqi 'connection refused|connection timed out|no such host|network unreachable|dial tcp|i/o timeout|couldn.t connect|8005'; then
    echo unreachable
  elif echo "$out" | grep -Eqi 'conflict|mkParentDir|internal server error|bad gateway|service unavailable|gateway timeout|too many requests|failed get storage|failed to reload.*storage|storage.*(not found|not exist)|存储不存在|存储加载失败|HTTP/[0-9.]+ 5[0-9][0-9]'; then
    echo backend
  elif echo "$out" | grep -Eqi 'directory not found|file does not exist|no such file|object not found|目录不存在|路径不存在|没有找到文件'; then
    echo notfound
  else
    echo unknown
  fi
}

# WebDAV 层预检：rclone lsd 探测 + 失败归类。
# 返回 0=通过；返回 1=应跳过（原因已输出到日志）。
# unknown 类先重试一次排除网络抖动，仍失败则保守跳过——放行的代价
# 是 rclone 写入全挂后还要空转一整轮修复管线，跳过的代价只是等下一轮。
_pre_webdav_health_check() {
  local probe_path="$1"
  local label="$2"
  local log_file="${3:-}"

  local tries=${OPENLIST_PROBE_RETRIES:-2}
  local rc=0 kind out=""
  while :; do
    out=$(rclone lsd "$probe_path" --max-depth 1 \
      --contimeout "${OPENLIST_PROBE_TIMEOUT:-15}s" \
      --timeout "${OPENLIST_PROBE_TIMEOUT:-15}s" 2>&1) && rc=0 || rc=$?
    kind=""
    [ "$rc" -ne 0 ] && kind=$(_classify_probe_failure "$out")
    if [ "$rc" -eq 0 ] || [ "$kind" != "unknown" ]; then break; fi
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && break
    sleep "${OPENLIST_PROBE_RETRY_SLEEP:-10}"
  done

  [ "$rc" -eq 0 ] && return 0
  # 目录尚未创建属于首次同步的正常状态，放行由后续流程建目录
  [ "$kind" = "notfound" ] && return 0

  local reason
  case "$kind" in
    auth)       reason="认证失效" ;;
    unreachable) reason="不可达" ;;
    backend)    reason="后端异常" ;;
    *)          reason="探测持续失败（未知错误）" ;;
  esac
  echo "🚫 $label ${reason}（WebDAV 预检），跳过本轮同步" | tee ${log_file:+-a "$log_file"}
  echo "$out" | head -5 | sed 's/^/   ▸ /' | tee ${log_file:+-a "$log_file"}
  return 1
}

# API 层强校验：POST /api/fs/list (refresh=true) 强制 OpenList 实时拉取驱动。
# 动机: WebDAV/rclone 层的列表可能命中服务端缓存——百度网盘这类后端登录
# 已失效时照样能列出旧数据，写入才会触发真实驱动请求（run 33026674750:
# baidupan 死而 baidupanCrypt 列表正常）。refresh=true 绕开缓存，是当前
# 唯一无需写盘即可验证驱动真实登录态的探针。
# 用法: _openlist_api_health_check <openlist路径> <日志标签> [日志文件]
# 返回 0=通过（含 token 缺失/API 无响应时的降级放行）；1=应跳过。
_openlist_api_health_check() {
  local target_path="$1"
  local label="${2:-目标端}"
  local log_file="${3:-}"
  [[ "$target_path" == openlist:* ]] || return 0

  local ol_token
  ol_token=$(_get_openlist_token || true)
  if [ -z "$ol_token" ]; then
    echo "⚠️ $label OpenList token 不可用，API 层健康校验降级放行" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  local resp curl_rc=0 code message
  resp=$(curl -s --max-time "${OPENLIST_API_HEALTH_TIMEOUT:-30}" \
    -X POST "http://127.0.0.1:5244/api/fs/list" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"/${target_path#openlist:}\",\"page\":1,\"per_page\":1,\"refresh\":true}" 2>&1) || curl_rc=$?
  if [ "$curl_rc" -ne 0 ] || [ -z "$resp" ]; then
    echo "⚠️ $label API 强校验无响应(rc=$curl_rc)，降级放行" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  code=$(echo "$resp" | jq -r '.code // 0' 2>/dev/null)
  [ "$code" = "200" ] && return 0

  message=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)

  # 管理面/驱动面区分（run 33048121562）: code=401 且消息指向我方 API 凭据
  # （token is invalidated）时，失效的是 OpenList 管理面的 Authorization
  # token（config.json 缓存凭据与运行实例不匹配，容器重启也无法自愈），
  # 请求在鉴权中间件即被拒——根本没触达驱动，不能据此判定"后端驱动认证失效"
  # 而跳过同步。数据面 WebDAV 探针（调用方前置执行）已通过时降级放行，
  # 以探针结果为准；驱动真实故障的表现形态是 code=500 + failed get storage /
  # 登录失败类消息，仍走下方原有分类拦截。
  if [ "$code" = "401" ] && echo "$message" | grep -Eqi 'invalidated|token.*(invalid|expired)|unauthorized'; then
    echo "⚠️ $label OpenList 管理面 token 失效（API 凭据问题，非驱动故障），API 强校验降级放行（以数据面探针为准）；请在服务端重新获取 token 并更新 config.json" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  # 目录尚未创建属于首次同步的正常状态
  if echo "$message" | grep -Eqi 'object not found|path.*not.*found|目录不存在|路径不存在|没有找到文件'; then
    echo "ℹ️ $label API 强校验: 目标目录尚未创建（${message}），放行由同步流程建立" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  # 注意分支顺序: 认证/存储异常判定必须在密码降级之前——凭据类错误
  # （如"密码错误"）不能被"需访问密码=配置项"的降级规则吞掉。
  if echo "$message" | grep -Eqi 'unauthorized|permission denied|not authenticated|login|登录|授权|token|auth.*fail|auth.*error|credential|identity|密码错误'; then
    echo "🚫 $label 后端驱动认证失效（API 强校验 code=${code}）: ${message}，跳过本轮同步" | tee ${log_file:+-a "$log_file"}
    # wopan 登录态有效期有上限（方法一 7 天/方法二 2 个月）且无法自动续期，
    # 真失效只能人工重抓；重抓时跨端登录互踢，先核对挂载用的方法再动手
    if [[ "$label" == *wopan* || "$message" == *wopan* ]]; then
      echo "   ▸ wopan 运维提示: 登录令牌有效期 方法一 7 天 / 方法二 2 个月，到期需人工重抓（doc.oplist.org/guide/drivers/wopan）；重抓登录时跨端互踢——方法一别登网页版、方法二别登手机 APP，以免把其他健康挂载踢下线" | tee ${log_file:+-a "$log_file"}
    fi
    return 1
  fi
  if echo "$message" | grep -Eqi 'storage|存储|driver|驱动|reload|internal server|服务器内部|exception|panic|bad gateway|service unavailable|gateway timeout|request failed|请求失败|too many requests'; then
    echo "🚫 $label 后端驱动异常（API 强校验 code=${code}）: ${message}，跳过本轮同步" | tee ${log_file:+-a "$log_file"}
    return 1
  fi

  # 目录设置了访问密码属于配置项而非故障，不能据此判定后端死掉
  if echo "$message" | grep -Eqi 'password|密码'; then
    echo "ℹ️ $label API 强校验: 目标目录需访问密码（配置项，${message}），降级放行" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  # 未识别的错误一律保守跳过并留痕，等待人工观察或下轮自愈
  echo "🚫 $label API 强校验未通过（未知错误 code=${code}）: ${message}，保守跳过本轮同步" | tee ${log_file:+-a "$log_file"}
  return 1
}

# 同步前连通性预检总入口。
# 两层校验都针对目标本身与 Crypt 底层裸存储各执行一次：
#   第1层 _pre_webdav_health_check — 快速、无凭据依赖，抓典型故障签名；
#   第2层 _openlist_api_health_check — refresh=true 绕过服务端缓存，
#         验证底层驱动真实登录态（baidupan/baidupanCrypt 事故主防线）。
# 用法: _check_openlist_backend_connectivity <dest_path> [log_filename]
# 返回: 0=继续同步, 1=跳过本轮
_check_openlist_backend_connectivity() {
  local dest_path="$1"
  local log_file="${2:-}"
  [[ "$dest_path" == openlist:* ]] || return 0

  _pre_webdav_health_check "$dest_path" "目标端 $dest_path" "$log_file" || return 1
  _openlist_api_health_check "$dest_path" "目标端 $dest_path" "$log_file" || return 1

  if [[ "$dest_path" == openlist:*Crypt/* ]]; then
    local rel="${dest_path#openlist:}"
    local base="${rel%%/*}"
    base="${base%Crypt}"
    local underlying="openlist:${base}"

    # 加密挂载完全建立在底层驱动之上，底层不健康时上层必然写入失败，
    # 必须把两层校验对底层裸存储再走一遍（baidupanCrypt ← baidupan）
    _pre_webdav_health_check "$underlying" "Crypt 挂载 $dest_path 底层驱动 $underlying" "$log_file" || return 1
    _openlist_api_health_check "$underlying" "Crypt 挂载 $dest_path 底层驱动 $underlying" "$log_file" || return 1
  fi

  return 0
}

# 查找 OpenList 最新日志文件
# （数据库本地化后日志在 /opt/openlist-data/log，旧路径保留兜底）
_find_openlist_log() {
  local logdir
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
  before_json=$(timeout "${OPENLIST_CACHE_REFRESH_WAIT:-120}" rclone size "$dest_path" --json 2>/dev/null || true)
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
  after_json=$(timeout "${OPENLIST_CACHE_REFRESH_WAIT:-120}" rclone size "$dest_path" --json 2>/dev/null || true)
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

# 重启 OpenList 容器并等待驱动就绪——为拿到"后端真实列表"
# （PUT 假成功条目只存在于 OpenList 缓存/后端可见列表，容器重启即消失；
#   持久化验证/假成功重试一直在用这个口径，此处抽出复用）
# 用法: _restart_openlist_for_truth [ol_path 不带 openlist: 前缀] [log_file]
#   ol_path 为空时跳过路径级缓存刷新（重启后列表本就是后端新拉的，
#   且对根路径 recursive 刷新代价大）
# 返回: 0=重启且驱动就绪（列表已从后端重拉），1=不可重启/未就绪
_restart_openlist_for_truth() {
  local ol_path="${1#/}"
  local log_file="${2:-/dev/null}"
  command -v docker >/dev/null 2>&1 || return 1
  sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qw openlist || return 1
  echo "  ↻ 重启 OpenList 容器（清掉假成功污染的列表，从后端取真值）..." | tee -a "$log_file"
  sudo docker restart openlist >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 30); do
    curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1 && break
    sleep 2
  done
  curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1 || {
    echo "  ⚠️ 重启后 HTTP 60s 内未就绪" | tee -a "$log_file"
    return 1
  }
  echo "  等待驱动重新初始化 (60s)..." | tee -a "$log_file"
  sleep 60
  if [ -n "$ol_path" ]; then
    local t
    t=$(_get_openlist_token) || true
    if [ -n "$t" ]; then
      curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
        -H "Authorization: $t" -H "Content-Type: application/json" \
        -d "{\"path\":\"/${ol_path#/}\",\"recursive\":true}" >/dev/null 2>&1 || true
    fi
    sleep 10
  fi
  return 0
}

# OpenList 目标列表真值校验（任意 openlist: 挂载目标通用）
#
# 功能: 同步主流程结束后、缺失文件 diff 之前校验目标端列表可信度。
#       OpenList PUT 假成功文件（rclone 报 Copied、退出码 0，但数据从未
#       写入后端，仅存在于 OpenList 内存缓存）在缓存列表里与真实文件
#       无异，diff 无法识别。本函数在有传输的轮次重启 OpenList 容器、
#       清空缓存、从后端重拉列表，让紧随其后的 diff 把假成功文件识别
#       为缺失文件、当轮送进修复管线，而不是等容器偶然重启才暴露。
#
# 原理: 假成功条目只存在于驱动内存缓存，任何不重启的读取——缓存刷新、
#       crypt/裸双视图计数对比——最终都可能读到同一份被污染的缓存
#       （run 31951008332 实锤: 同步后 crypt=raw=1413 判"无幽灵"，重启后
#       真值 1394，19 个假成功当轮漏网；历史 crypt-vs-raw 计数对比分支
#       因此移除）。唯一可靠口径 = 重启容器后从后端重拉。重启代价约
#       2 分钟，仅在"本轮有实际传输"时支付：无传输即无新写入，无新
#       写入即无新污染，缓存列表可信直接放行（上轮遗留污染会带进 diff，
#       但下一轮有传输即被重启暴露，一天内自愈）。
#       重启前后目标视图计数差 = 假成功文件数（仅供通知展示；真正的
#       暴露与修复靠重启后的 diff，不靠该差值本身）。
#
# 用法: _openlist_truth_check <dest_path> [log_file]
# 设置全局: FAKE_SUCCESS_COUNT — 假成功文件数（供通知展示）
# 返回: 0=列表可信（非 openlist 目标 / 无传输 / 已重启取到后端真值）
#       1=重启失败（列表可能仍被污染，diff 口径不可信）
# 示例:
#   _openlist_truth_check "openlist:wopan176Crypt/backup" "$LOG"  # Crypt 目标（展示裸存储对照）
#   _openlist_truth_check "openlist:wopan175/1" "$LOG"            # 普通挂载目标
#   _openlist_truth_check "remote:bucket/path" "$LOG"             # 非 openlist 目标，直接返回 0
_openlist_truth_check() {
  FAKE_SUCCESS_COUNT=0
  local dest_path="$1"
  local log_file="${2:-/dev/null}"
  [[ "$dest_path" == openlist:* ]] || return 0

  # Crypt 目标展示裸存储对照路径（dne=true 时裸存储无字面子路径，仅作展示用）
  local header="=== truth-check: ${dest_path}（重启后后端真值口径）==="
  if [[ "$dest_path" == openlist:*Crypt/* ]]; then
    local raw_display
    raw_display=$(_raw_remote_for "${dest_path%%/*}" 2>/dev/null || echo "${dest_path/Crypt/}")
    header="=== truth-check: ${dest_path}（对照 ${raw_display}，重启后后端真值口径）==="
  fi
  echo "$header" | tee -a "$log_file"

  # 缓存刷新: 目标挂载（dne=true 的 Crypt 目标裸存储无字面子路径——目录名也是密文，只刷 crypt 侧）
  _refresh_ol_cache_fast "${dest_path#openlist:}"

  # 本轮 rclone 实际传输数（Copied 行）
  # 注意 grep -c 无匹配时输出 0 且退出码 1，`|| echo 0` 会拼成 "0\n0" 双行，
  # [ -gt ] 直接报 integer expression expected —— 用正则防护归零
  local uploaded=0
  if [ -n "${LAST_ATTEMPT_LOG:-}" ] && [ -f "$LAST_ATTEMPT_LOG" ]; then
    uploaded=$(grep -cE 'Copied \((new|replaced existing)\)' "$LAST_ATTEMPT_LOG" 2>/dev/null || true)
    [[ "$uploaded" =~ ^[0-9]+$ ]] || uploaded=0
  fi

  # 无传输 → 无新写入即无新污染，缓存列表可信，直接放行给 diff
  # （上轮遗留污染会带进 diff，但下一轮有传输即重启暴露，一天内自愈）
  if [ "$uploaded" -eq 0 ]; then
    echo "  本轮无传输，无新污染，直接放行给 diff" | tee -a "$log_file"
    return 0
  fi

  # 有传输 → 列表可能含"PUT 假成功"条目，重启容器取后端真值
  local pre_count=0 dest_json
  dest_json=$(timeout "${OPENLIST_RCLONE_LISTING_TIMEOUT:-900}" rclone size "$dest_path" --json 2>/dev/null || true)
  pre_count=$(echo "$dest_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  [[ "$pre_count" =~ ^[0-9]+$ ]] || pre_count=0
  echo "  本轮传输 ${uploaded} 个文件，目标视图 ${pre_count}（缓存口径）—— 重启容器取后端真值" | tee -a "$log_file"

  if ! _restart_openlist_for_truth "${dest_path#openlist:}" "$log_file"; then
    echo "  ⚠️ 容器重启失败，保留当前列表继续（可能含假成功条目，diff 口径被污染）" | tee -a "$log_file"
    return 1
  fi

  # 重启后重新计数（此即后端真值）; pre-post 差 = 假成功文件数（供通知）
  local post_json post_count
  post_json=$(timeout "${OPENLIST_RCLONE_LISTING_TIMEOUT:-900}" rclone size "$dest_path" --json 2>/dev/null || true)
  post_count=$(echo "$post_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  [[ "$post_count" =~ ^[0-9]+$ ]] || post_count=0
  echo "  重启后目标视图: ${pre_count} → ${post_count}" | tee -a "$log_file"
  if [ "$pre_count" -gt "$post_count" ]; then
    FAKE_SUCCESS_COUNT=$((pre_count - post_count))
    echo "  ⚠️ 检测到 ${FAKE_SUCCESS_COUNT} 个假成功文件（重启后从列表消失 → 未持久化），已暴露为缺失，将由下方 diff 送修复管线" | tee -a "$log_file"
  else
    echo "  ✅ 重启前后列表一致，无假成功污染" | tee -a "$log_file"
  fi
  # 列表已是后端真值，直接放行给 diff
  return 0
}
# 重启 OpenList 容器并等待驱动就绪 + 刷新路径缓存（持久化验证/假成功重试共用）
# 用法: _sync_restart_for_verify <log_file> <ol_path 以 / 开头>
# 返回: 0=重启且 HTTP 就绪, 1=HTTP 60s 内未就绪
_sync_restart_for_verify() {
  local log_file="$1" ol_path="$2"
  sudo docker restart openlist >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1; then
      echo "  OpenList HTTP 就绪 (${i}次)" | tee -a "$log_file"
      break
    fi
    sleep 2
  done
  curl -sf http://127.0.0.1:5244/ping >/dev/null 2>&1 || return 1
  echo "  等待驱动重新初始化 (60s) ..." | tee -a "$log_file"
  sleep 60
  local t
  t=$(_get_openlist_token)
  if [ -n "$t" ]; then
    curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
      -H "Authorization: $t" -H "Content-Type: application/json" \
      -d "{\"path\":\"$ol_path\",\"recursive\":true}" >/dev/null 2>&1 || true
    sleep 20
  fi
  return 0
}
