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
#   qingyan_deploy.sh selftest  # 端到端自检：glm-5.3 与 glm-5.3-flash 各发一条
#   qingyan_deploy.sh status    # 端口存活（/healthz 需带 key）
set -u

# 2026-10-06 起 qingyan 全面跑在 Dropbox 上（代码/数据/凭据/日志），
# 不再往 /tmp/local_qingyan 拉运行副本。APP_DIR 是代码真源（unit 直跑这里）。
APP_DIR="/dropbox/self-hosted/qingyan-proxy/app"
RUN_DIR="/tmp/local_qingyan"
PORT="${QINGYAN_PORT:-8320}"
# 长输出超时（秒）。⚠️ proxy.py 的两步式写入要跑两轮完整长生成，
# 默认 300s 第二轮必撞 deadline（实测 900 也不够），1800 才稳。
UPSTREAM_TIMEOUT="${QINGYAN_UPSTREAM_TIMEOUT:-1800}"
LOG_DIR="$RUN_DIR/logs"
LOG="$LOG_DIR/qingyan.log"
# 凭据也落 Dropbox（主人 2026-10-06 决定）：unit 的 EnvironmentFile 读这里。
# ⚠️ 挂载点权限恒 666（chmod 600 是空操作），env.sh 内含 refresh token 明文，
#    对同机所有用户可读可写 —— 已知并接受的风险。
ENV_FILE="/dropbox/self-hosted/qingyan-proxy/env.sh"
# 代码源（Dropbox 侧，rclone remote 形式）。空=不拉取（目录里已有代码才能跑）。
APP_REMOTE="${QINGYAN_APP_REMOTE:-}"
# 持久数据目录（本地侧）：凭证状态文件 + 积分快照。
DATA_DIR="${QINGYAN_DATA_DIR:-$RUN_DIR/data}"
# Dropbox 侧数据远端。空=不同步（本地单轮跑）。
# 迁移兜底：glm2api 时代的积分快照在其数据目录下。新位置为空时取一次，取到即用。
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

  mkdir -p "$RUN_DIR" "$DATA_DIR" || die "无法创建数据目录 $DATA_DIR"

  # 代码（2026-10-06 起）：真源就是 Dropbox 的 app 目录，unit 用绝对路径直跑它，
  # 不再往 /tmp/local_qingyan 拉运行副本 —— 拉了也没人用，且 /tmp 被清理时会
  # 误判「运行目录缺 proxy.py」而 die。这里只校验真源在位。
  [ -s "$APP_DIR/proxy.py" ] || die "Dropbox app 目录缺 proxy.py：$APP_DIR（APP_REMOTE=$APP_REMOTE）"

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
  status)   cmd_status ;;
  selftest) cmd_selftest ;;
  *) echo "用法: $0 {prepare|status|selftest}"; exit 1 ;;
esac
