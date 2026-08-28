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
  for i in 1 2; do
    resp=""
    if [ "$i" -gt 1 ]; then sleep 2; fi
    resp=$(curl -s -m 15 -X POST "http://127.0.0.1:5244/api/auth/login" \
      -H 'Content-Type: application/json' \
      --data-binary "$body" 2>/dev/null) || resp=""
    [ -n "$resp" ] || { echo "_get_openlist_token: 第${i}次登录无响应" >&2; continue; }
    tok=$(jq -r '.data.token // empty' <<<"$resp" 2>/dev/null) || tok=""
    code=$(jq -r '.code // 0' <<<"$resp" 2>/dev/null) || code=0
    if [ -n "$tok" ] && [ "$tok" != "null" ]; then
      printf '%s' "$tok"
      return 0
    fi
    echo "_get_openlist_token: 第${i}次登录被拒 (code=${code})，检查 OPENLIST_ADMIN_PASSWORD 是否与管理员密码一致" >&2
  done
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
  local ol_token
  if ol_token=$(_get_openlist_token); then
    echo "HTTP 就绪，管理面登录成功（token 长度 ${#ol_token}）"
  else
    echo "HTTP 就绪，但管理面登录失败（检查 OPENLIST_ADMIN_PASSWORD 是否已注入且与管理员密码一致）"
  fi
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
