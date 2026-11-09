#!/bin/bash
# ===== OpenList 同步工具 — OpenList 服务访问层 =====
#
# 职责边界:
#   - 与 OpenList 管理面的交互（登录换取 JWT）
#   - 服务就绪等待（HTTP /ping → 管理面登录 → 驱动初始化 → rclone 验证）
#
# 依赖: 无（自包含；wait_openlist_ready 依赖本文件的 _get_openlist_token）
# 被依赖: file_fix.sh, sync_engine.sh, workflow（wait_openlist_ready 由 workflow 直接调用）

# 获取 OpenList 管理面 token（账号密码动态登录，弃用静态读取）
# 历史: 曾从 config.json 读 .token/.jwt_secret 作为静态凭据，但登录态
# token 默认约 48h 过期、jwt_secret 是签名密钥而非通行证，两种形态都会
# 演变成 401 "token is invalidated" 潜伏故障（run 33048121562: wopan175
# 数据面健康却被误判驱动失效）。现改为每次现场 POST /api/auth/login 换取
# 新鲜 JWT；密码取环境变量 OPENLIST_ADMIN_PASSWORD（不在任何文件落盘），
# 用户名可用 OPENLIST_ADMIN_USER 覆盖（默认 admin）。静默重试一次；
# 失败不回显响应体，防账密痕迹入日志。
# 返回: 0 且 stdout 为 token 字符串；失败返回非零（stdout 空）
_get_openlist_token() {
  local user pass body resp tok code i
  user="${OPENLIST_ADMIN_USER:-admin}"
  pass="${OPENLIST_ADMIN_PASSWORD:-}"
  if [ -z "$pass" ]; then
    echo "_get_openlist_token: 环境变量 OPENLIST_ADMIN_PASSWORD 未设置，无法登录管理面" >&2
    return 1
  fi
  # jq -n 构造请求体: 密码含引号/反斜杠等特殊字符时仍保证 JSON 合法
  body=$(jq -nc --arg u "$user" --arg p "$pass" \
    '{username:$u,password:$p}' 2>/dev/null) || return 1
  # 重试策略（2026-11-09 修，run 42603463034 实证）:
  #   旧版只有 2 次、间隔 2s（≈4s 窗口）—— 而 container 刚拉起时 `/ping` 可能
  #   已经 200，但管理面还没就绪（数据库初始化 / admin 账号装载），此时
  #   `api/auth/login` 是**无响应**（连接被拒或超时），不是密码错。
  #   实测该轮: 容器 13:58:50 拉起、13:58:57 开始校验、13:59:29 判失败（32s），
  #   日志 `第1次登录无响应 / 第2次登录无响应` → 整轮 failure、同步 step 被 skip。
  #   故把「无响应」的重试窗口对齐阶段1 的耐心（默认 120s，可用
  #   OPENLIST_LOGIN_WAIT_SECONDS 调），而**被拒（有响应但无 token）仍然
  #   fail fast** —— 那才是密码不一致，等再久也没用。
  local _login_wait="${OPENLIST_LOGIN_WAIT_SECONDS:-120}"
  [[ "$_login_wait" =~ ^[0-9]+$ ]] || _login_wait=120
  local _login_ticks=$(( _login_wait / 3 ))
  [ "$_login_ticks" -lt 2 ] && _login_ticks=2
  for i in $(seq 1 "$_login_ticks"); do
    resp=""
    if [ "$i" -gt 1 ]; then sleep 3; fi
    resp=$(curl -s -m 15 -X POST "http://127.0.0.1:5244/api/auth/login" \
      -H 'Content-Type: application/json' \
      --data-binary "$body" 2>/dev/null) || resp=""
    if [ -z "$resp" ]; then
      # 无响应 = 服务/管理面尚未就绪 → 继续等（不判失败）
      echo "_get_openlist_token: 第${i}/${_login_ticks}次登录无响应（管理面可能仍在初始化），继续等待" >&2
      continue
    fi
    tok=$(jq -r '.data.token // empty' <<<"$resp" 2>/dev/null) || tok=""
    code=$(jq -r '.code // 0' <<<"$resp" 2>/dev/null) || code=0
    if [ -n "$tok" ] && [ "$tok" != "null" ]; then
      printf '%s' "$tok"
      return 0
    fi
    # 有响应但拿不到 token → 密码/账号问题，等再久也一样：fail fast
    echo "_get_openlist_token: 第${i}次登录被拒 (code=${code})，检查 OPENLIST_ADMIN_PASSWORD 是否与管理员密码一致" >&2
    return 1
  done
  echo "_get_openlist_token: ${_login_ticks} 次登录均无响应（约 ${_login_wait}s），管理面未就绪" >&2
  return 1
}

# 等待 OpenList 就绪（容器刚启动时 401/429 会导致预览 0 B/0 文件、同步无谓重传）
# 注意：不能用 rclone lsd 反复探测，会触发后端 429 Too Many Requests
wait_openlist_ready() {
  local i code
  # 阶段1: HTTP /ping 起来
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5244/ping 2>/dev/null || echo "000")
    [ "$code" = "200" ] && break
    sleep 2
  done
  if [ "$code" != "200" ]; then
    echo "⚠️ OpenList HTTP 未就绪 (code=${code})"
    return 1
  fi
  # 阶段2: 管理面账密实登验证（现场换取 token，后续 API 探测的前提）
  # 登录失败必须 fail fast: 后续所有驱动探测 / API 健康检查都拿不到 token，
  # 会一路"降级放行"，让本该 3 分钟结束的运行空转到 6h 上限（run #12613:
  # 登录失败 → 16 个目标端列举全部失败 → 预览吃掉 3h+ → 330min 硬超时）。
  local ol_token
  if ol_token=$(_get_openlist_token); then
    echo "HTTP 就绪，管理面登录成功（token 长度 ${#ol_token}）"
  else
    echo "❌ HTTP 就绪，但管理面登录失败（检查 OPENLIST_ADMIN_PASSWORD 是否已注入且与管理员密码一致），终止本次运行"
    return 1
  fi

  # 阶段2.5: 存储（驱动）清单校验 —— 数据库是从 Dropbox 拉回来的副本，
  # 空库/坏库会让后面所有探测"降级放行"（token 有、存储无），同样演变成
  # 整轮空转。此处 fail fast: 一个存储都没有即判定本次拉库失败。
  local storage_total
  storage_total=$(curl -s -m 20 -X GET "http://127.0.0.1:5244/api/admin/storage/list" \
    -H "Authorization: $ol_token" 2>/dev/null \
    | jq -r '.data.total // (.data.content | length) // empty' 2>/dev/null)
  if [ -z "$storage_total" ] || [ "$storage_total" = "0" ] || [ "$storage_total" = "null" ]; then
    echo "❌ OpenList 存储清单为空（total=${storage_total:-无响应}）: 拉取到的 data.db 为空或损坏，终止本次运行"
    return 1
  fi
  echo "存储清单校验通过: ${storage_total} 个存储"
  # 阶段3: 等驱动初始化（长等待 120s，给 ali + crypt 拉元数据）
  echo "等待驱动初始化 (120s) ..."
  sleep 120
  # 阶段4: rclone 验证（首次 + 两次退避重试 90s/60s，避免触发 429）
  if rclone lsd openlist: >/dev/null 2>&1; then
    echo "WebDAV(rclone) 验证通过"
    return 0
  fi
  echo "再等 90s ..."
  sleep 90
  if rclone lsd openlist: >/dev/null 2>&1; then
    echo "WebDAV(rclone) 验证通过（第二次）"
    return 0
  fi
  sleep 60
  rclone lsd openlist: >/dev/null 2>&1 \
    && { echo "WebDAV(rclone) 验证通过（第三次）"; return 0; } \
    || echo "⚠️ WebDAV 三次验证均未通过（返回 1，由调用方决定终止或忽略）"
  return 1
}
