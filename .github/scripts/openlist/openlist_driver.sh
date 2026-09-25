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
# 被依赖: sync_engine.sh (sync_with_logging, _sync_retry_8005),
#         file_fix_pipeline.sh (_sync_persist_verify_and_retry),
#         sync_notify.sh (_refresh_openlist_cache)

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
#
# 2026-09-17 修正（run 35186977864）: 409 不能再一律归 backend。
#   该轮 2062 次 409 / 1088 次 mkParentDir failed 被整轮判"后端异常"跳过，
#   但用户后台看驱动是好的 —— 因为 409 的主因是**目录已存在**（MKCOL 语义）
#   或并发 mkdir 争用，而非驱动故障。判据是**读操作**: 这里本身就是一次
#   lsd 探测，探测失败的路径下无法再区分"目录在/不在"，故把 409 从
#   backend 里拆出来交给调用方做二次判定（见 _pre_webdav_health_check 的
#   conflict 分支），只有连二次判定都失败才当后端异常。
_classify_probe_failure() {
  local out="$1"
  if echo "$out" | grep -Eqi 'unauthorized|permission denied|not authenticated|login|登录失败|登录失效|登录已过期|授权|token.*(expired|invalidated|invalid)|invalidated|auth.*fail|auth.*error|credential|identity|invalid_grant|401|403|Method Not Allowed'; then
    echo auth
  elif echo "$out" | grep -Eqi 'connection refused|connection timed out|no such host|network unreachable|dial tcp|i/o timeout|couldn.t connect|8005'; then
    echo unreachable
  elif echo "$out" | grep -Eqi 'conflict|mkParentDir' \
       && [ "${_FIX_MKDIR_409_SEMANTICS:-1}" != "0" ]; then
    # 409/mkParentDir 单独成一类: 调用方会先判"目录是否已存在"，存在即放行
    echo conflict
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

  # 409/mkParentDir: 先做**二次判定**——目录是否其实已存在。
  # 已存在 ⇒ 放行（409 是 MKCOL 幂等语义，不是故障）；探测不到才当后端异常。
  # 为什么必须放行而不是跳过: 旧行为把这种"目录在、只是 mkdir 报了 409"整轮跳过，
  #   代价是整轮零落盘（run 35186977864 实测），而放行的最坏代价只是后续写入
  #   真失败时转修复管线 —— 后者本就有完整的失败处理。
  if [ "$kind" = "conflict" ]; then
    if rclone lsd "$probe_path" --max-depth 1 --retries 1 \
         --contimeout "${OPENLIST_PROBE_TIMEOUT:-15}s" \
         --timeout "${OPENLIST_PROBE_TIMEOUT:-15}s" >/dev/null 2>&1; then
      echo "✅ $label 409/mkParentDir 但目录实际存在 → 按幂等成功放行（非后端故障）" | tee ${log_file:+-a "$log_file"}
      return 0
    fi
    # 二次判定仍失败: 退回 backend 语义（可能是并发争用，交由 409 重试链处理）
    kind=backend
  fi

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

  _backend_write_probe "$dest_path" "$log_file" || return 1

  return 0
}

# ===== 后端级写探针（每个目标路径一次，按「后端 × 路径」缓存）=====
# 为什么必须有这一层（run #12616 实锤，2026-09-11）:
#   上面两层预检（lsd + API list refresh=true）**全是读操作**。wopan175 那轮
#   读全部正常、写入却恒定 `Update mkParentDir failed: Conflict: 409 Conflict`
#   （OpenList API mkdir 返回 200、rclone 侧 409，探针写入从不落盘），
#   结果: 一轮 394 次修复全败、769 次"目录不可写"、231 次容器重启/缓存刷新，
#   5 小时零产出。读探针放行了根本写不进的后端，整轮预算全烧在"逐目录、
#   逐文件证明写不了"上——失败是注定的，代价却是全额的。
# 做法: 每个目标路径**只做一次**写探针: 写几字节 → 刷新服务端缓存 → 复核可见
#   → 删除。不可见即假成功，与写入报错同判 dead。
#   探针写在任务子路径（不是挂载根）、结论按「后端 × 路径」缓存: wopan176 的
#   405 是路径特异性的（父目录密文名超长连坐短名文件），挂载根能写完全不能
#   说明深层任务目录能写——旧版按挂载根探测+缓存，正是"探针通过 89s 后即大量
#   405"的来源（run 34728107625）。命中缓存即短路（不重复探测、不重启容器）。
# 成本: 一次 copyto + 一次 lsf + 一次 deletefile，秒级。与之相比，漏检的代价
#   是整轮 5 小时。
# 开关: OPENLIST_BACKEND_WRITE_PROBE=0 关闭（回退纯读预检）
# 依赖: _cmd_log(file_fix.sh) 可缺省——本文件被单独 source 时不强依赖
# 用法: _backend_write_probe <dest_path> [log_file] → 0=可写, 1=该后端本轮不可用
declare -A _BACKEND_WRITE_PROBE_CACHE=()

# ===== 路径特异性坏目录记忆（2026-09-25 病灶 E）=====
# 为什么需要: `_BACKEND_WRITE_PROBE_CACHE[$dest]=1`（下方"目标路径写不进但挂载根
#   可写 ⇒ 按可写放行"）只解决了"别把健康后端误判成死"，但它把结论写成**可写**，
#   于是后续所有通路（sync 重试 / 8005 retry / 子目录同步 / 修复管线）都认为这个
#   目录能写 ⇒ **反复重入同一个已知写不进的目录**。
#   实测 run 35989879675: 同一个目录（巨乳が成長し続ける女子生徒）在 25 分钟内被
#   反复 sync，累计 **156 次 409 Conflict**，其中 90 次集中在同一目录 —— 该轮修复
#   成功率因此只有 2.7%（成功 7 / 缺失 259）。
# 语义（必须与熔断区分）: 这里是**路径级**记忆，不是后端级熔断 —— 后端仍然可用，
#   只是这个具体路径本轮已知写不进，应交给"折叠/换目录"兜底，而不是反复直撞。
# 用法: _path_unwritable_mark <dest> / _path_unwritable_hit <dest>
declare -A _PATH_UNWRITABLE_ROUND=()
_path_unwritable_mark() {
  local dest="${1:-}"
  [ -n "$dest" ] || return 0
  _PATH_UNWRITABLE_ROUND["$dest"]=1
}
_path_unwritable_hit() {
  local dest="${1:-}"
  [ -n "$dest" ] || return 1
  [ "${_PATH_UNWRITABLE_ROUND[$dest]:-0}" = "1" ]
}

# 清掉某目标路径的写探针结论，强制下一次 _backend_write_probe 真探（F22）。
# 为什么需要（F4 的固有缺口）: 探针现状是「整轮只跑一次」，结论被缓存后整轮复用；
#   但"探针 ✅ 与真实写入 405 并存"的长期悖论（diagnose 已定案）恰恰说明**探针的
#   可写结论只对 t=0 那一瞬有效** —— openlist-diag 首跑证明同一路径单文件顺序写
#   ~10 次全过（含 128B 长名与覆盖写），而生产在同一路径上 1034 文件/48 分钟全 405。
#   ⇒ 失效是**随时间/量累积**发生的，开跑前跑一次天然测不到。批次循环里按时间
#   周期性清缓存再探，才能把「跑着跑着后端才变坏」这种情况重新探测出来。
# 键口径与 F21 修复一致: 必须按 $dest_path 清，不能按挂载根清（否则清了个不存在
#   的键，探针照样命中缓存返回可写 = 等于没探）。
# 用法: _backend_write_probe_invalidate <dest_path>
_backend_write_probe_invalidate() {
  local dest="${1:-}"
  [ -n "$dest" ] || return 0
  unset "_BACKEND_WRITE_PROBE_CACHE[$dest]"
}

# 挂载根: openlist:wopan175/1/1024j → openlist:wopan175
_backend_root_of() {
  local p="$1"
  if [[ "$p" == openlist:* ]]; then
    printf 'openlist:%s' "${p#openlist:}" | cut -d/ -f1
  else
    printf '%s' "$p"
  fi
}

# 让 OpenList 服务端目录缓存失效（写探针复核用）
# PUT 假成功的文件活在 OpenList 的目录缓存里，不刷新就读，lsf 会把缓存里的
# 幽灵条目当真 → 写探针恒"通过"（run 34728107625: 探针通过后 89s 即大量 405）。
# 比 _refresh_openlist_cache 轻: 只刷一个目录（非递归）、等待可配（默认 5s），
# 因为写探针整体只有 60s 超时预算，扛不住那个函数的等待（默认 40s，
# `OPENLIST_FS_REFRESH_SLEEP` 可调；见 _refresh_openlist_cache 注释）。
_ol_refresh_path_cache() {
  local dest="$1"
  [[ "$dest" == openlist:* ]] || return 0
  local ol_path="/${dest#openlist:}"
  local ol_token
  ol_token=$(_get_openlist_token 2>/dev/null || true)
  [ -n "$ol_token" ] || return 0
  curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"$ol_path\",\"recursive\":false}" \
    >/dev/null 2>&1 || true
  sleep "${OPENLIST_FS_REFRESH_WAIT:-5}"
}

_backend_write_probe() {
  [ "${OPENLIST_BACKEND_WRITE_PROBE:-1}" = "0" ] && return 0
  [[ "$1" == openlist:* ]] || return 0
  local dest="$1" log_file="${2:-}"
  local root
  root=$(_backend_root_of "$dest")

  # 整轮缓存: 按「后端 × 路径」分层（结论不会在几分钟内翻转）。
  # 旧版按挂载根缓存 + 探针写在挂载根，把"某个深层目录拒写"当成整个后端
  # 可用/不可用: wopan176 的 405 是路径特异性的（父目录密文名超长连坐），
  # 挂载根能写 ≠ 任务子路径能写（run 34728107625 实锤）。
  if [ -n "${_BACKEND_WRITE_PROBE_CACHE[$dest]:-}" ]; then
    if [ "${_BACKEND_WRITE_PROBE_CACHE[$dest]}" = "1" ]; then
      return 0
    fi
    echo "🚫 目标端 $dest 本轮写探针已判不可用，跳过（不再重复探测/重启）" | tee ${log_file:+-a "$log_file"}
    return 1
  fi

  local probe_name="olwprobe_$(printf '%s' "${dest}$$" | md5sum | cut -c1-8).txt"
  local probe_local="${TMPDIR:-/tmp}/${probe_name}"
  # 探针写在真实任务子路径而非挂载根: 只有任务真正要写的那一层才知道能不能写
  local probe_dst="${dest}/${probe_name}"
  local probe_timeout="${OPENLIST_BACKEND_WRITE_PROBE_TIMEOUT:-60}s"
  printf '%s' "openlist backend write probe" > "$probe_local" 2>/dev/null || true

  echo "💉 后端写探针: $dest" | tee ${log_file:+-a "$log_file"}
  local out rc=0 seen=0
  out=$(rclone copyto "$probe_local" "$probe_dst" \
    --retries 1 --low-level-retries 3 --contimeout 30s --timeout "$probe_timeout" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    # rc=0 只说明 rclone 认为成功: PUT 假成功在缓存里与真文件无异，
    # 必须刷新服务端缓存后再读一次确认探针真的在后端（run 31951008332 同口径）。
    # 读空要重试: OpenList 对新建目录的列表有缓存延迟，一次读空就判死后端代价极大
    # （整个后端本轮被熔断），2026-09-14 已实测同类误判（折叠校验读空 → 误判零落盘）。
    local _rt
    for _rt in 1 2; do
      _ol_refresh_path_cache "$dest"
      if rclone lsf "$dest" --files-only --retries 1 --timeout "$probe_timeout" 2>/dev/null \
         | grep -qxF "$probe_name"; then
        seen=1
        break
      fi
    done
  fi
  # 写入失败时先在挂载根再探一次: 405 是**路径特异性**的（同一后端的挂载根与多数目录
  # 都正常，只有个别目录名写不进 —— 2026-09-14 诊断坐实: 真实祖先下写任意长名/深路径
  # 全 OK，唯那个具体目录名稳定 405）。单点失败就熔断整个后端，等于把"路径特异性"
  # 又提升成"后端级"，会把健康后端误判为死。两侧都写不进才认后端故障。
  if [ "$rc" -ne 0 ]; then
    local _root_probe="${root}/${probe_name}" _root_rc=0
    rclone copyto "$probe_local" "$_root_probe" \
      --retries 1 --low-level-retries 3 --contimeout 30s --timeout "$probe_timeout" >/dev/null 2>&1 || _root_rc=$?
    rclone deletefile "$_root_probe" --retries 1 --low-level-retries 3 --timeout "$probe_timeout" >/dev/null 2>&1
    if [ "$_root_rc" -eq 0 ]; then
      _BACKEND_WRITE_PROBE_CACHE["$dest"]=1
      echo "   ⚠️ 目标路径写不进但挂载根可写 ⇒ 判定为路径特异性（非后端故障），按可写放行（该目录交给折叠/换目录兜底）" | tee ${log_file:+-a "$log_file"}
      # 病灶 E: 后端放行 ≠ 这个目录能写。这里额外记一笔**路径级**坏目录，
      #   供下游通路（sync 重试 / 8005 retry / 修复管线）跳过重复直撞 —— 本轮
      #   实测同一目录被反复 sync 出 156 次 409（见 _PATH_UNWRITABLE_ROUND 注释）。
      _path_unwritable_mark "$dest"
      rm -f "$probe_local" 2>/dev/null || true
      return 0
    fi
  fi
  rclone deletefile "$probe_dst" --retries 1 --low-level-retries 3 --timeout "$probe_timeout" >/dev/null 2>&1

  rm -f "$probe_local" 2>/dev/null || true

  if [ "$rc" -eq 0 ] && [ "$seen" -eq 1 ]; then
    _BACKEND_WRITE_PROBE_CACHE["$dest"]=1
    echo "   ✅ 后端可写" | tee ${log_file:+-a "$log_file"}
    return 0
  fi

  _BACKEND_WRITE_PROBE_CACHE["$dest"]=0
  local reason
  if [ "$rc" -ne 0 ]; then
    reason="写入失败 (exit=${rc})"
    echo "$out" | head -5 | sed 's/^/   ▸ /' | tee ${log_file:+-a "$log_file"}
  else
    reason="写入返回成功但复核不可见（PUT 假成功）"
  fi
  echo "🚫 后端 $root ${reason}，判定本轮不可用 → 熔断该后端全部同步对（把时间让给健康后端）" | tee ${log_file:+-a "$log_file"}
  return 1
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

  # 刷新前文件数**仅用于日志对比**（不参与任何控制流）——它是两次全量 rclone size
  # 之一，单次最长 120s；本函数一轮被调 ~12 次，静默间隔分析显示"缓存刷新"这一档
  # 吃掉 42min（轮次的 12%），主体就是这两次 size。
  # 故默认跳过（OPENLIST_CACHE_REFRESH_COUNT=1 可打开用于排查"缓存是否真的过期"）。
  local _cnt_on="${OPENLIST_CACHE_REFRESH_COUNT:-0}"
  local before_count=0 before_json
  if [ "$_cnt_on" = "1" ]; then
    before_json=$(timeout "${OPENLIST_CACHE_REFRESH_WAIT:-120}" rclone size "$dest_path" --json 2>/dev/null || true)
    before_count=$(echo "$before_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
    echo "刷新 OpenList 缓存: $ol_path (刷新前文件数: $before_count)"
  else
    echo "刷新 OpenList 缓存: $ol_path (跳过前后计数: 该项仅用于日志，默认关闭以省 ~30min/轮)"
  fi

  curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
    -H "Authorization: $ol_token" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"$ol_path\",\"recursive\":true}" \
    >/dev/null 2>&1 || true

  # 等待缓存刷新完成（默认 60s，确保递归刷新大目录完成）
  # ✅ 可配: OPENLIST_FS_REFRESH_SLEEP（2026-09-15 加）。
  # 为什么值得关注: 静态间隔分析显示一轮被调 ~14 次 ⇒ 60s × 14 = **14min**，
  # 占 72min 短轮的 **19%**（长轮里也有 7%）。这个 sleep 是在赌"递归刷新在 N 秒内
  # 完成"，赌错会让 diff 读到 stale 列表、把已落盘文件当缺失 → 白重传 + 修复管线空跑，
  # 所以**不要默默调小**: 要跑一轮对比"缺失文件数 / 修复触发量 / 重传量"再定。
  # 0 = 不等（仅调试用）。
  # 默认 60 → **40**（2026-09-15 实测依据）: 对比轮 `34949253305`（sleep=30，6 次调用
  # = 3min）与基线轮（sleep=60，14 次 = 14min）相比，**「重启前后列表不一致」两侧都是 0**
  # ⇒ 30s 未观察到 stale 症状；取 40 留 1/3 余量（14 次 × 40s ≈ 9min，省 ~5min/轮）。
  # 进一步压缩的判定条件: 在**高写入轮**（传输量 ≫ 2GB）里若出现"缺失数/修复触发量异常
  # 抬升"或「重启前后列表不一致」，即说明递归刷新 40s 不够，回退 60。
  local _rsleep="${OPENLIST_FS_REFRESH_SLEEP:-40}"
  [[ "$_rsleep" =~ ^[0-9]+$ ]] || _rsleep=40
  echo "等待缓存刷新完成 (${_rsleep}s)..."
  [ "$_rsleep" -gt 0 ] && sleep "$_rsleep"

  # 刷新后文件数同理: 仅日志用途，默认跳过（见上）
  if [ "$_cnt_on" = "1" ]; then
    local after_count=0 after_json
    after_json=$(timeout "${OPENLIST_CACHE_REFRESH_WAIT:-120}" rclone size "$dest_path" --json 2>/dev/null || true)
    after_count=$(echo "$after_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
    echo "缓存刷新后文件数: $after_count"
    if [ "$before_count" != "$after_count" ]; then
      echo "⚠️ 缓存刷新改变了 listing: $before_count → $after_count 个文件（刷新前缓存已过期）"
    else
      echo "缓存刷新前后文件数一致 ($after_count)，listing 稳定"
    fi
  fi
  return 0
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

# ===== 容器级读写锁（并行子目录同步的互斥基础，串行模式无争用直通）=====
# 共享锁（fd 7）: rclone 传输 / 巩固重试等"容器必须存活"的窗口，多个并行
#   worker 可同时持有；独占锁（fd 6）: 容器重启（truth-check / 驱动刷新
#   方法2）—— 等全部共享持有者退出后才重启，杜绝"重启打断在途上传"。
#   串行模式下只有一个执行流，锁总是立即可得，行为不变。
# fd 口径: 9 已被进度系统占用（PROGRESS_LOCK_FILE），此处用 7/6。
OPENLIST_CONTAINER_LOCK="${OPENLIST_CONTAINER_LOCK:-/tmp/ol_container.lock}"
# 独占锁最长等待 1h（另一 worker 的大文件传输可能很久）；超时放弃重启，
# 列表可能仍被假成功污染 —— 与"无传输轮次不重启"同一自愈语义：下轮有
# 传输即再重启暴露
_OL_EXCLUSIVE_LOCK_WAIT="${_OL_EXCLUSIVE_LOCK_WAIT:-3600}"
_ol_lock_shared() {
  exec 7>>"$OPENLIST_CONTAINER_LOCK" 2>/dev/null || return 0
  flock -s 7 2>/dev/null || true
  return 0
}
_ol_lock_shared_release() {
  flock -u 7 2>/dev/null || true
  eval "exec 7>&-" 2>/dev/null || true
  return 0
}
_ol_lock_exclusive() {
  # $1 = log_file（超时警告写入；可省略）
  exec 6>>"$OPENLIST_CONTAINER_LOCK" 2>/dev/null || return 0
  if ! flock -x -w "$_OL_EXCLUSIVE_LOCK_WAIT" 6 2>/dev/null; then
    echo "  ⚠️ 容器独占锁等待超时（${_OL_EXCLUSIVE_LOCK_WAIT}s），跳过重启（下轮自愈）" | tee -a "${1:-/dev/null}"
    eval "exec 6>&-" 2>/dev/null || true
    return 1
  fi
  return 0
}
_ol_lock_exclusive_release() {
  flock -u 6 2>/dev/null || true
  eval "exec 6>&-" 2>/dev/null || true
  return 0
}

# 重启后等待驱动就绪 —— **必须盲等 OPENLIST_DRIVER_READY_WAIT 秒（默认 60s）**。
# 2026-09-14 曾改成「自适应轮询: 目标路径可列出即就绪」（4af1cbc），已回滚 —— 实测是回归:
#   A 轮（盲等 60s）: Copied 817 · 传输 13.08GB · 「列表获取不完整」0 次 · 「重启后列表未就绪」0 次
#   B‘ 轮（自适应）: Copied 39 · 传输 148MB · 「列表获取不完整」30 次 · 「重启后列表未就绪」29 次
# 原因: 容器重启后 `rclone lsf` 很快返回**成功但内容为空/不完整**（驱动在补水）。
#   ⇒ "可列出" ≠ "列表完整"。拿不完整清单去做 diff 会跳过修复管线（661 缺失 0 修复）。
#   诊断单次测到 12s 完整（新容器+小目录），不代表生产中运行中的容器+大目录。
# 想再优化只能换**更强的就绪信号**（如 OpenList API 的 raw 计数达到预期值），不能只凭 lsf 成功。
#
# ⚠️⚠️ 不要再把这个等待调短（2026-09-18 实测补充，run 35296822507）:
#   同一轮探针实测「重启后立即写: FAIL()」→「+10s: OK」→「+30s/+60s: OK」，
#   且「列表可见性: 首次非空=10s · 凑齐20=10s」—— 后端重启后**约 10 秒才真正就绪**
#   （写入与列表同窗）。当前 60s 是**安全裕度**，不是浪费。
#   尤其注意: 若把这里改成"轮询到 ping 通就返回"（ping 往往 2-3s 就通），
#   会直接掉进这个 10s 窗口 —— 预检读到空列表 ⇒ 判目录不可写 ⇒ 跳过修复方法。
#   该窗口同时是 _fix_probe_dir_writable 复核的脆弱点（见 file_fix.sh 的三态判定）。
# 用法: _wait_driver_ready <ol_path 不带 openlist: 前缀> [log_file]
_wait_driver_ready() {
  local _w="${OPENLIST_DRIVER_READY_WAIT:-60}" log_file="${2:-/dev/null}"
  echo "  驱动就绪等待 ${_w}s（盲等；自适应轮询已回滚，见函数头注释）" | tee -a "$log_file"
  sleep "$_w"
  return 0
}

# 重启 OpenList 容器并等待驱动就绪——为拿到"后端真实列表"
# （PUT 假成功条目只存在于 OpenList 缓存/后端可见列表，容器重启即消失；
#   持久化验证/假成功重试一直在用这个口径，此处抽出复用）
# 并行模式下经容器独占锁互斥: 有 worker 在传输（共享锁）时等待其完成
# 用法: _restart_openlist_for_truth [ol_path 不带 openlist: 前缀] [log_file]
#   ol_path 为空时跳过路径级缓存刷新（重启后列表本就是后端新拉的，
#   且对根路径 recursive 刷新代价大）
# 返回: 0=重启且驱动就绪（列表已从后端重拉），1=不可重启/未就绪/锁超时
_restart_openlist_for_truth() {
  if ! _ol_lock_exclusive "${2:-/dev/null}"; then
    return 1
  fi
  local _rc=0
  _restart_openlist_for_truth_impl "$@" || _rc=$?
  _ol_lock_exclusive_release
  return "$_rc"
}
_restart_openlist_for_truth_impl() {
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
  echo "  等待驱动重新初始化（自适应轮询，上限 60s）..." | tee -a "$log_file"
  _wait_driver_ready "$ol_path" "$log_file"
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
  dest_json=$(timeout "${OPENLIST_RCLONE_LISTING_TIMEOUT:-900s}" rclone size "$dest_path" --json 2>/dev/null || true)
  pre_count=$(echo "$dest_json" | jq -r '.count // 0' 2>/dev/null || echo 0)
  [[ "$pre_count" =~ ^[0-9]+$ ]] || pre_count=0
  echo "  本轮传输 ${uploaded} 个文件，目标视图 ${pre_count}（缓存口径）—— 重启容器取后端真值" | tee -a "$log_file"

  if ! _restart_openlist_for_truth "${dest_path#openlist:}" "$log_file"; then
    echo "  ⚠️ 容器重启失败，保留当前列表继续（可能含假成功条目，diff 口径被污染）" | tee -a "$log_file"
    return 1
  fi

  # 重启后重新计数（此即后端真值）; pre-post 差 = 假成功文件数（供通知）
  local post_json post_count
  post_json=$(timeout "${OPENLIST_RCLONE_LISTING_TIMEOUT:-900s}" rclone size "$dest_path" --json 2>/dev/null || true)
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
  echo "  等待驱动重新初始化（自适应轮询，上限 60s）..." | tee -a "$log_file"
  _wait_driver_ready "$ol_path" "$log_file"
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
