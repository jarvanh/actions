#!/usr/bin/env bash
# qingyan-proxy 部署脚本（清言 chatglm.cn 反代 → OpenAI 兼容 API，端口 8320）
#
# 位置：.github/scripts/services/qingyan_deploy.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 的 "Run qingyan-proxy" 步骤；托管由 services.sh 负责
#
# 为什么替换 glm2api（2026-09-30）：qingyan-proxy 是自研单文件零依赖反代
# （函数调用桥 + 两步式写入协议 + 推理档位），已在本机 ZCode/TraeWork/openclaw
# 四类客户端端到端验证；glm2api 退役。本机同款常驻于 macOS LaunchAgent。
#
# 与 glm2api 部署的关键差别：
#   - 代码源不是 git 仓库而是 Dropbox：项目在本机 ~/AI/qingyan-proxy（非 git
#     仓库），经 rclone 存到 dropbox:self-hosted/qingyan-proxy/app，每轮 pull。
#     本机改动同步：rclone copy <项目目录> dropbox:self-hosted/qingyan-proxy/app
#     --exclude .DS_Store（本机 CLI 需带系统代理环境变量，rclone 不读 scutil）。
#   - 零依赖不需要 venv：/usr/bin/python3 直接跑 proxy.py。
#   - 凭据模型：qingyan-proxy 原生读本机 App 的 Cookies SQLite；Actions 上没有
#     该库，走 QINGYAN_CRED_FILE 文件模式（JSON 状态文件）。上游 refresh 是
#     轮换式（旧票立即作废），Secret GLM_REFRESH_TOKEN 只做首轮种子，之后以
#     数据目录里轮换出的新票为准——所以 data/ 必须随 Dropbox 跨轮持久化，
#     丢了也能用种子重来，但种子早已作废、得回本机重新提取。
#   - 设备号：状态文件里首次生成 uuid4().hex（与 App 的 32 位 hex 同形）并持久化。
#
# 凭据口径（与 glm2api 同）：token 只从环境变量注入（workflow step 从仓库
# Secrets 取），脚本绝不写进仓库、绝不回显到日志或通知；落盘只有运行目录
# env.sh（600）。未注入时以非零退出并给出明确原因。
#
# 持久化口径：Dropbox 数据目录 ↔ 本地 data/，起前 pull / 停后 push。
#   data/ 里是凭证状态文件 qingyan-credentials.json + 积分快照 quota-snapshot。
#
# 用法：
#   qingyan_deploy.sh prepare   # 从 Dropbox 拉代码 + 写 env.sh（幂等）
#   qingyan_deploy.sh pull      # 从 Dropbox 拉回持久数据（起服务前）
#   qingyan_deploy.sh push      # 回推持久数据 + 日志到 Dropbox（收尾）
#   qingyan_deploy.sh selftest  # 端到端自检：glm-5.3 与 glm-5.3-flash 各发一条
#   qingyan_deploy.sh status    # 端口存活（/healthz 需带 key）
set -u

RUN_DIR="/tmp/local_qingyan"
PORT="${QINGYAN_PORT:-8320}"
# 长输出超时（秒）。⚠️ proxy.py 的两步式写入要跑两轮完整长生成，
# 默认 300s 第二轮必撞 deadline（实测 900 也不够），1800 才稳。
UPSTREAM_TIMEOUT="${QINGYAN_UPSTREAM_TIMEOUT:-1800}"
LOG_DIR="$RUN_DIR/logs"
LOG="$LOG_DIR/qingyan.log"
ENV_FILE="$RUN_DIR/env.sh"
# 代码源（Dropbox 侧，rclone remote 形式）。空=不拉取（目录里已有代码才能跑）。
APP_REMOTE="${QINGYAN_APP_REMOTE:-}"
# 持久数据目录（本地侧）：凭证状态文件 + 积分快照。
DATA_DIR="${QINGYAN_DATA_DIR:-$RUN_DIR/data}"
# Dropbox 侧数据远端。空=不同步（本地单轮跑）。
DATA_REMOTE="${QINGYAN_DATA_REMOTE:-}"
# 迁移兜底：glm2api 时代的积分快照在其数据目录下。新位置为空时取一次，取到即用。
LEGACY_SNAP_REMOTE="${QINGYAN_LEGACY_SNAP_REMOTE:-dropbox:self-hosted/glm2api}"
CRED_FILE="$DATA_DIR/qingyan-credentials.json"

log() { printf '[qingyan] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# ── prepare：从 Dropbox 拉代码 + 写 env.sh，让运行目录达到「可被 systemd 拉起」──
cmd_prepare() {
  [ -n "${QINGYAN_REFRESH_TOKEN:-}" ] || die "未注入 QINGYAN_REFRESH_TOKEN 环境变量（仓库 Secret GLM_REFRESH_TOKEN），拒绝部署无凭据服务"
  # 网关鉴权：本网关专属 key（与 8318/8319/旧 8320 各自独立的口径一致，不共用
  # AI_GATEWAY_API_KEY）。监听 0.0.0.0，缺 key 等于把清言账号裸奔在同机所有
  # 网卡上，不如显式失败（与 services.sh 的密钥缺失同口径）。
  [ -n "${QINGYAN_GATEWAY_KEY:-}" ] || die "未注入 QINGYAN_GATEWAY_KEY 环境变量（仓库 Secret GLM2API_GATEWAY_KEY），拒绝起无鉴权服务"

  mkdir -p "$RUN_DIR" "$LOG_DIR" "$DATA_DIR" || die "无法创建运行目录 $RUN_DIR"

  # 代码：单文件项目，从 Dropbox 拉取（幂等 copy，每轮都拉保证跑在最新版上）。
  # 拉不到且本地已有 proxy.py 时沿用旧副本（Dropbox 抖动不阻断部署）。
  if [ -n "$APP_REMOTE" ]; then
    if rclone copy "$APP_REMOTE" "$RUN_DIR" \
         --exclude '.DS_Store' --exclude 'logs/**' --exclude 'data/**' \
         --retries 5 --low-level-retries 10 --timeout 1m --contimeout 15s 2>/dev/null; then
      log "已从 Dropbox 拉取代码：$APP_REMOTE"
    elif [ -s "$RUN_DIR/proxy.py" ]; then
      log "⚠️ 代码拉取失败，沿用运行目录现有副本"
    else
      die "从 Dropbox 拉取代码失败且无本地副本：$APP_REMOTE"
    fi
  fi
  [ -s "$RUN_DIR/proxy.py" ] || die "运行目录缺 proxy.py（未指定 QINGYAN_APP_REMOTE 且本地无代码）"

  # env.sh：凭据 + 服务参数，systemd 单元 EnvironmentFile 读取。600 落盘。
  # proxy.py 纯读环境变量，一份 env.sh 全覆盖（glm2api 时代的 .env/env.sh 双文件
  # 是因为它自身读 .env，这里没有这个需求）。
  umask 077
  cat > "$ENV_FILE" <<EOF
# 监听 0.0.0.0：与 8318/8319 同口径（同机其它反代都对外网卡开放），便于
# 容器/局域网客户端接入。安全边界由 PROXY_API_KEY 承担。
PROXY_HOST=0.0.0.0
PROXY_PORT=${PORT}
PROXY_API_KEY=${QINGYAN_GATEWAY_KEY}
# 长输出超时：两步式写入需两轮长生成，默认 300 必撞 deadline，实测 1800 才稳
QINGYAN_UPSTREAM_TIMEOUT=${UPSTREAM_TIMEOUT}
# 凭证状态文件：轮换式 refresh 的新票写回这里，随 data/ 与 Dropbox 对齐
QINGYAN_CRED_FILE=${CRED_FILE}
# 首轮种子：仅当状态文件里还没有 refresh token 时生效一次（上游轮换式刷新，
# 旧票作废，之后以状态文件里的新票为准）
QINGYAN_REFRESH_TOKEN=${QINGYAN_REFRESH_TOKEN}
QINGYAN_DELETE_CONVERSATIONS=1
EOF
  chmod 600 "$ENV_FILE" || true
  log "✅ 运行目录就绪（$RUN_DIR，端口 $PORT）"
}

# ── pull：起服务前把 Dropbox 上的持久数据拉进本地 data/ ────────────────────
# rclone copy 单向拉取、不删本地多余文件；远端为空是首轮正常情况，不判失败。
cmd_pull() {
  [ -n "$DATA_REMOTE" ] || { log "ℹ️ 未指定 QINGYAN_DATA_REMOTE，跳过数据拉取"; return 0; }
  command -v rclone >/dev/null 2>&1 || { log "⚠️ rclone 不可用，跳过数据拉取"; return 0; }
  mkdir -p "$DATA_DIR" || return 1

  log "拉取持久数据：$DATA_REMOTE → $DATA_DIR"
  # 失败不 return：远端目录尚未创建（首轮）时 rclone copy 会报「目录不存在」，
  # 若提前返回会连下面的旧快照迁移一起跳过。故只记警告，流程继续。
  rclone copy "$DATA_REMOTE" "$DATA_DIR" \
    --retries 5 --low-level-retries 10 --timeout 1m --contimeout 15s 2>/dev/null \
    || log "⚠️ 数据拉取失败/远端为空，按首轮空数据启动"

  # 迁移兜底：glm2api 的积分快照在其数据目录下，替换后第一次拉取时搬过来，
  # 避免替换当轮把「今日累计」清零。
  if [ ! -s "$DATA_DIR/quota-snapshot" ] && [ -n "$LEGACY_SNAP_REMOTE" ]; then
    if rclone copyto "$LEGACY_SNAP_REMOTE/quota-snapshot" "$DATA_DIR/quota-snapshot" \
         --retries 3 --low-level-retries 5 --timeout 30s --contimeout 10s 2>/dev/null; then
      log "✅ 已从 glm2api 数据目录迁移积分快照（$LEGACY_SNAP_REMOTE）"
    else
      log "ℹ️ glm2api 数据目录无积分快照，按首轮处理"
    fi
  fi
  log "✅ 数据拉取完成"
}

# ── push：收尾把本地 data/ + 日志回推 Dropbox ──────────────────────────────
# 只 copy 不 sync：远端的历史内容不该被本轮删掉（与 glm2api/workbuddy 收尾同口径）。
# 失败不阻断收尾通知——下一轮 pull 不到最多是凭证退回种子/累计从 0 起。
cmd_push() {
  [ -n "$DATA_REMOTE" ] || { log "ℹ️ 未指定 QINGYAN_DATA_REMOTE，跳过数据回推"; return 0; }
  command -v rclone >/dev/null 2>&1 || { log "⚠️ rclone 不可用，跳过数据回推"; return 0; }
  [ -d "$DATA_DIR" ] || { log "ℹ️ 数据目录不存在，跳过回推"; return 0; }

  log "回持久数据：$DATA_DIR → $DATA_REMOTE"
  rclone copy "$DATA_DIR" "$DATA_REMOTE" \
    --exclude '*.tmp' \
    --retries 5 --low-level-retries 10 --timeout 1m --contimeout 15s 2>/dev/null \
    || log "⚠️ 数据回推失败（下轮凭证退回种子/累计从 0 起）"

  # 日志单独带一份上去便于事后回看（纯 INFO 行，体积小）。
  if [ -d "$LOG_DIR" ]; then
    rclone copy "$LOG_DIR" "$DATA_REMOTE/logs" \
      --retries 3 --low-level-retries 5 --timeout 1m --contimeout 15s 2>/dev/null \
      || log "⚠️ 日志回推失败（不影响数据）"
  fi
  log "✅ 数据回推完成"
}

# 端口存活：/healthz 在设置了 PROXY_API_KEY 时同样要求鉴权（proxy.py 的 GET
# 一律先 _authed），故探测必须带 key；key 现取 env.sh（600），不进日志。
cmd_status() {
  local key code
  key="$(grep -m1 '^PROXY_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${key}" \
    "http://127.0.0.1:${PORT}/healthz" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" != "401" ]; then
    log "✅ 服务已监听 ${PORT}（HTTP ${code}）"
    return 0
  fi
  log "⛔ 服务未监听 ${PORT}（HTTP ${code:-无响应}）"
  return 1
}

# 端到端自检：两个模型各发一条，判据是返回了助手内容（content 或
# reasoning_content 任一非空——deep_thinking 档下短回复可能全文在思考段）。
# 只验「有内容」不比对文本：模型回复内容不稳定，比对文本会 flaky。
cmd_selftest() {
  local out model ok=0 total=0
  local models="glm-5.3 glm-5.3-flash"
  local api_key=""
  api_key="$(grep -m1 '^PROXY_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  for model in $models; do
    total=$((total + 1))
    out="$(curl -sS --max-time 120 -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
      -H 'content-type: application/json' \
      -H "Authorization: Bearer ${api_key}" \
      -d "{\"model\":\"${model}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"回复 ok 即可\"}]}" 2>&1)"
    if printf '%s' "$out" | jq -e '[(.choices[0].message.content // ""), (.choices[0].message.reasoning_content // "")] | map(length) | add > 0' >/dev/null 2>&1; then
      log "✅ ${model} 自检通过"
      ok=$((ok + 1))
    else
      log "❌ ${model} 自检失败：$(printf '%s' "$out" | head -c 200)"
    fi
  done
  [ "$ok" -eq "$total" ] || return 1
  return 0
}

case "${1:-}" in
  prepare)  cmd_prepare ;;
  pull)     cmd_pull ;;
  push)     cmd_push ;;
  status)   cmd_status ;;
  selftest) cmd_selftest ;;
  *) echo "用法: $0 {prepare|pull|push|status|selftest}"; exit 1 ;;
esac
