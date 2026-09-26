#!/usr/bin/env bash
# 宿主进程形态 AI 网关的 systemd --user 管理器（workbuddy-gateway / zcode2api）
#
# 位置：.github/scripts/gateways/gateways.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 的两个网关启动步骤（ensure）与收尾停止步骤（stop）
#
# 为什么不含 trae2api：它是 docker 容器，compose 的 restart: unless-stopped
# 已覆盖崩溃自愈、dockerd 重启也会拉回容器，再包一层 systemd 是重复托管。
#
# 为什么是 systemd --user 而不是 nohup/setsid（2026-09-25 定）：
#   每轮 run 起服务后 Keep alive ~340 分钟才收尾，窗口期内网关进程崩溃
#   （实测 2026-09-25 11:24 workbuddy-gateway 无报错静默退出）没有任何东西
#   拉起，请求 connection refused 直到几小时后下一轮 run。systemd
#   Restart=always 把「崩溃→自愈」收敛到秒级；runner 的 user manager 常驻
#   （openclaw-gateway.service 同款，Linger=yes）。
#
#   bash "$GITHUB_WORKSPACE/.github/scripts/gateways/gateways.sh" ensure <workbuddy|zcode2api|glm2api>
#
# 用法：
#   gateways.sh ensure <workbuddy|zcode2api|glm2api>  # 写单元(幂等)+reload+重启
#   gateways.sh stop <name>                            # 收尾停止（等退出，不 pkill）
#   gateways.sh status [name]                          # 状态总览
#
# ensure 语义是「每轮重启一次」而不是「已运行则跳过」：与原 nohup 方案每轮
# pkill + 重启完全一致，重启点就是每轮 run 的起点。窗口期内的崩溃自愈由
# systemd 的 Restart=always 负责，不经过本脚本。
#
# 单元里内嵌的密钥（AI_GATEWAY_API_KEY / ZCODE_GATEWAY_KEY）本来就在进程
# cmdline 和环境里可见（同机只有 runner 一个真实用户），单元文件按 600 落盘，
# 没有扩大暴露面；通知/日志里依然绝不回显（docs/telegram-notify.md 口径不变）。
#
# 前置条件（由各启动步骤负责，本脚本不做）：
#   workbuddy  /tmp/local_workbuddy/{workbuddy-gateway,data/}（含 logs/ 目录）
#   zcode2api  /tmp/local_zcode2api/{.venv,cli.py,.env,logs/}
set -u

UNIT_DIR="${HOME}/.config/systemd/user"
LOG_DIR="${HOME}/.openclaw/logs"

# 单实例锁，避免并发调用打架（与 tunnels.sh 同款）
LOCK="/tmp/.gateways-$(id -u).lock"
exec 9>"$LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || { echo "[gateways] 另一个实例正在运行，跳过"; exit 0; }

mkdir -p "$UNIT_DIR" "$LOG_DIR" 2>/dev/null || true

log() { printf '[gateways] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# 单元名与服务名解耦：workbuddy 用完整语义的单元名，避免歧义
unit_name() {
  case "$1" in
    workbuddy) echo "workbuddy-gateway.service" ;;
    *)         echo "$1.service" ;;
  esac
}

# systemd --user 单元模板。两份各自内联（与服务耦合的路径/参数差异大，
# 抽通用模板反而难读）；写盘走 mktemp + install -m 600，避免 umask 意外放权。
write_unit() {
  local name="$1"
  local unit
  unit="$(unit_name "$name")"
  local tmp
  tmp="$(mktemp /tmp/gateway-unit-XXXXXX)"
  umask 077
  case "$name" in
    workbuddy)
      # 缺密钥直接拒绝生成：网关缺 -api-key 会静默不校验，客户端不带 Bearer
      # 也能过，等于裸奔，不如显式失败暴露问题（与启动步骤的密钥注入同口径）
      [ -n "${AI_GATEWAY_API_KEY:-}" ] || { rm -f "$tmp"; die "workbuddy: AI_GATEWAY_API_KEY 未注入，拒绝生成无鉴权单元"; }
      cat > "$tmp" <<EOF
[Unit]
Description=workbuddy-gateway (CodeBuddy/Hunyuan -> OpenAI, 8318)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
WorkingDirectory=/tmp/local_workbuddy/data
Environment=AI_GATEWAY_API_KEY=${AI_GATEWAY_API_KEY}
ExecStart=/tmp/local_workbuddy/workbuddy-gateway serve -addr 0.0.0.0 -port 8318 -api-key \${AI_GATEWAY_API_KEY}
Restart=always
RestartSec=5
StandardOutput=append:/tmp/local_workbuddy/data/logs/serve.log
StandardError=append:/tmp/local_workbuddy/data/logs/serve.log

[Install]
WantedBy=default.target
EOF
      ;;
    zcode2api)
      [ -n "${ZCODE_GATEWAY_KEY:-}" ] || { rm -f "$tmp"; die "zcode2api: ZCODE_GATEWAY_KEY 未注入，拒绝生成无鉴权单元"; }
      cat > "$tmp" <<EOF
[Unit]
Description=zcode2api (GLM Anthropic+OpenAI gateway, 8319)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
WorkingDirectory=/tmp/local_zcode2api
Environment=ZCODE_GATEWAY_KEY=${ZCODE_GATEWAY_KEY}
# 环境变量优先于 .env（python-dotenv 默认不覆盖已存在的环境变量），
# 与仓库 Secrets 对齐无需改数据快照里的 .env
ExecStart=/tmp/local_zcode2api/.venv/bin/python cli.py serve
Restart=always
RestartSec=5
StandardOutput=append:/tmp/local_zcode2api/logs/zcode2api.log
StandardError=append:/tmp/local_zcode2api/logs/zcode2api.log

[Install]
WantedBy=default.target
EOF
      ;;
    glm2api)
      # 凭据口径与其余两个网关相反：token 不进单元文件（避免同一份凭据落到
      # 单元 + .env 两处，轮换时容易漏改一处），只写在运行目录 .env（600），
      # 由服务自行读取。故这里只校验部署脚本是否已把 .env 写好。
      [ -s /tmp/local_glm2api/.env ] || { rm -f "$tmp"; die "glm2api: 运行目录 .env 缺失或为空，请先跑 glm2api_deploy.sh prepare"; }
      grep -q '^GLM_REFRESH_TOKEN=.' /tmp/local_glm2api/.env || { rm -f "$tmp"; die "glm2api: .env 内无 GLM_REFRESH_TOKEN，拒绝起游客态服务"; }
      cat > "$tmp" <<EOF
[Unit]
Description=glm2api (ChatGLM 清言反代 -> OpenAI, ${GLM2API_PORT:-8320})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
WorkingDirectory=/tmp/local_glm2api
# 源码是 src/ 布局，经 PYTHONPATH 指过去，避免为启动做一次 pip install
EnvironmentFile=/tmp/local_glm2api/env.sh
# GLM_REFRESH_TOKEN 只存在于运行目录 .env（600），不进单元文件（理由见脚本注释）
ExecStart=/tmp/local_glm2api/.venv/bin/python main.py
Restart=always
RestartSec=5
StandardOutput=append:/tmp/local_glm2api/logs/glm2api.log
StandardError=append:/tmp/local_glm2api/logs/glm2api.log

[Install]
WantedBy=default.target
EOF
      ;;
    *) die "未知网关: $name（可选 workbuddy | zcode2api | glm2api）" ;;
  esac
  install -m 600 "$tmp" "$UNIT_DIR/$(unit_name "$name")"
  rm -f "$tmp"
}

cmd_ensure() {
  local name="${1:-}"
  [ -n "$name" ] || die "用法: $0 ensure <workbuddy|zcode2api|glm2api>"
  local unit
  unit="$(unit_name "$name")"

  write_unit "$name"
  systemctl --user daemon-reload

  # 幂等 enable：runner user manager 常驻（Linger=yes），enable 让单元在
  # user manager 意外重启后也能被拉回
  systemctl --user enable "$unit" >/dev/null 2>&1

  # 每轮重启一次（语义对齐原 nohup 方案的 pkill + 重启；理由见文件头）
  log "重启 $unit（每轮 run 起点，确保跑在最新二进制/依赖上）"
  systemctl --user restart "$unit"
  sleep 3

  if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    log "✅ $name 运行中 ($unit)"
  else
    log "❌ $name 启动失败，查看: journalctl --user -u $unit"
    return 1
  fi
}

cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || die "用法: $0 stop <workbuddy|zcode2api|glm2api>"
  local unit
  unit="$(unit_name "$name")"

  # 必须走 systemd stop 而不是 pkill：Restart=always 会把 pkill 杀掉的进程
  # 在 5 秒内拉回来，「等待退出」循环会误判进程残留（收尾步骤语义见 openclaw.yml）
  systemctl --user stop "$unit" 2>/dev/null || true
  for _ in $(seq 1 30); do
    systemctl --user is-active --quiet "$unit" 2>/dev/null || { log "✅ $name 已停止"; return 0; }
    sleep 1
  done
  log "⚠️ $name 未在 30 秒内退出，强制结束"
  systemctl --user kill --signal=SIGKILL "$unit" 2>/dev/null || true
  systemctl --user stop "$unit" 2>/dev/null || true
  return 0
}

cmd_status() {
  local only="${1:-}"
  local names="workbuddy zcode2api glm2api"
  printf '%-12s %-24s %s\n' "网关" "状态" "单元"
  local n unit st
  for n in $names; do
    [ -n "$only" ] && [ "$n" != "$only" ] && continue
    unit="$(unit_name "$n")"
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then st="✅ 运行"
    elif systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then st="⛔ 已停止"
    else st="— 未安装"; fi
    printf '%-12s %-24s %s\n' "$n" "$st" "$unit"
  done
}

case "${1:-}" in
  ensure) cmd_ensure "${2:-}" ;;
  stop)   cmd_stop "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  *) echo "用法: $0 {ensure|stop|status} [name]"; exit 1 ;;
esac
