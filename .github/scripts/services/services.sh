#!/usr/bin/env bash
# 宿主进程形态 AI 网关与看板服务的 systemd --user 管理器
# （workbuddy-gateway / zcode2api / qingyan / workbuddy-cred-sync / quota-board）
#
# 位置：.github/scripts/services/services.sh（随仓库 checkout 分发）
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
#   bash "$GITHUB_WORKSPACE/.github/scripts/services/services.sh" ensure <workbuddy|zcode2api|qingyan|quota-board>
#
# 用法：
#   services.sh ensure <workbuddy|zcode2api|qingyan|quota-board>  # 写单元(幂等)+reload+重启
#   services.sh stop <name>                            # 收尾停止（等退出，不 pkill）
#   services.sh status [name]                          # 状态总览
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
#   qingyan    /tmp/local_qingyan/{proxy.py,env.sh,logs/}（单文件零依赖，无需 venv）
#   quota-board /dropbox/self-hosted/quota-board/board.py + ~/.openclaw/.env
#              （看板本体与凭据都在持久化目录，运行目录无需准备）
#
# 为什么 qingyan 取代了 glm2api（2026-09-30）：qingyan-proxy 是自研单文件反代，
# 已在本机端到端验证，glm2api 退役；部署脚本同步换成 qingyan_deploy.sh，
# 本脚本的单元模板也一并换掉，否则单元指向已删除的 main.py 会直接启动失败。
set -u

UNIT_DIR="${HOME}/.config/systemd/user"
LOG_DIR="${HOME}/.openclaw/logs"

# 服务日志统一落盘目录（2026-10-05 主人拍板：不要双目录，全部网关统一存 Dropbox）。
# 此前日志分散在 /tmp 各运行目录（/tmp/local_workbuddy/data/logs、/tmp/local_zcode2api/logs、
# /tmp/local_qingyan/logs），runner 重置即丢 —— 冷却与「无可用账号」等事件轨迹随之蒸发，
# quota-board 的告警解析读不到就静默失效（实测 hy4-preview-f 06:52 冷却、07:19 无可用账号
# 全程零通知）。统一到 Dropbox 后事件可跨轮次追溯，告警不再漏报。
# 挂载点上写日志已长期实证可行：网关自己的 gateway-*.log 与看板 board.log 都在
# Dropbox 上高频写入且正常（注意 openclaw.yml 里「工作目录不能放挂载点」指的是
# cwd 高频读写状态文件，与 StandardOutput 追加写日志不是一回事）。
LOG_ROOT="/dropbox/self-hosted"

# 日志目录必须存在：StandardOutput=append:<LOG> 在目录不存在时进程直接以
# status=209/STDOUT 退出 → Restart=always 崩溃循环（glm2api 时代实测踩过）。
# 日志改落 Dropbox 后目录未必预建，统一由此幂等补一道。
ensure_log_dir() { mkdir -p "$(dirname "$1")" 2>/dev/null || true; }

# 单实例锁，避免并发调用打架（与 tunnels.sh 同款）
LOCK="/tmp/.services-$(id -u).lock"
exec 9>"$LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || { echo "[services] 另一个实例正在运行，跳过"; exit 0; }

mkdir -p "$UNIT_DIR" "$LOG_DIR" 2>/dev/null || true

log() { printf '[services] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# 单元名与服务名解耦：workbuddy 用完整语义的单元名，避免歧义
unit_name() {
  case "$1" in
    workbuddy) echo "workbuddy-gateway.service" ;;
    *)         echo "$1.service" ;;
  esac
}

# systemd --user 单元模板。五份各自内联（与服务耦合的路径/参数差异大，
# 抽通用模板反而难读）；写盘走 mktemp + install -m 600，避免 umask 意外放权。
#
# 本文件是这些单元的**唯一真源**：每轮 ensure 无条件覆盖写盘，
# 因此任何手改 ~/.config/systemd/user/*.service 的行为都会被下一轮冲掉，
# 同理 Dropbox / 运行目录下的静态副本均无权威性（2026-10-04 统一清理）。
# 要改单元内容，改这里的 heredoc 并 push，不要改现役文件。
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
      ensure_log_dir "$LOG_ROOT/workbuddy-gateway/logs/serve.log"
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
# 停止超时：默认 90s 不够长连接/子进程排空，会被 systemd 升级 SIGKILL
# （zcode2api 2026-10-03 实证 stop-sigterm timeout）。三网关统一放宽。
TimeoutStopSec=180
StandardOutput=append:$LOG_ROOT/workbuddy-gateway/logs/serve.log
StandardError=append:$LOG_ROOT/workbuddy-gateway/logs/serve.log

[Install]
WantedBy=default.target
EOF
      ;;
    zcode2api)
      [ -n "${ZCODE_GATEWAY_KEY:-}" ] || { rm -f "$tmp"; die "zcode2api: ZCODE_GATEWAY_KEY 未注入，拒绝生成无鉴权单元"; }
      ensure_log_dir "$LOG_ROOT/zcode2api/logs/zcode2api.log"
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
# 停止超时：captcha 真浏览器子进程 + SSE 长连接排空需要时间，默认 90s
# 会被 SIGKILL（2026-10-03 重启实证），放宽到 180s 后退出干净。
TimeoutStopSec=180
StandardOutput=append:$LOG_ROOT/zcode2api/logs/zcode2api.log
StandardError=append:$LOG_ROOT/zcode2api/logs/zcode2api.log

[Install]
WantedBy=default.target
EOF
      ;;
    qingyan)
      # 凭据只落在运行目录 env.sh（600），不进单元文件——同一份 refresh token
      # 落到两处会在上游轮换式刷新时漏改一处。这里只校验部署脚本是否已写好。
      [ -s /tmp/local_qingyan/env.sh ] || { rm -f "$tmp"; die "qingyan: 运行目录 env.sh 缺失或为空，请先跑 qingyan_deploy.sh prepare"; }
      grep -q '^QINGYAN_REFRESH_TOKEN=.' /tmp/local_qingyan/env.sh || { rm -f "$tmp"; die "qingyan: env.sh 内无 QINGYAN_REFRESH_TOKEN，拒绝起无凭据服务"; }
      [ -s /tmp/local_qingyan/proxy.py ] || { rm -f "$tmp"; die "qingyan: 运行目录缺 proxy.py"; }
      # 日志目录必须存在：StandardOutput=append:<LOG> 在目录不存在时进程直接以
      # status=209/STDOUT 退出 → Restart=always 崩溃循环（glm2api 时代实测踩过）。
      # 部署脚本已建，这里幂等补一道。
      ensure_log_dir "$LOG_ROOT/qingyan-proxy/logs/qingyan.log"
      cat > "$tmp" <<EOF
[Unit]
Description=qingyan-proxy (清言 chatglm.cn 反代 -> OpenAI, ${QINGYAN_PORT:-8320})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
WorkingDirectory=/tmp/local_qingyan
EnvironmentFile=/tmp/local_qingyan/env.sh
# 单文件零依赖（纯标准库），系统 python3 直接跑，无需 venv
ExecStart=/usr/bin/python3 proxy.py
Restart=always
RestartSec=5
# 停止超时：同上，默认 90s 不够排空，统一放宽到 180s。
TimeoutStopSec=180
StandardOutput=append:$LOG_ROOT/qingyan-proxy/logs/qingyan.log
StandardError=append:$LOG_ROOT/qingyan-proxy/logs/qingyan.log

[Install]
WantedBy=default.target
EOF
      ;;
    workbuddy-cred-sync)
      # 同步循环依赖 openclaw.yml 生成的 /tmp/workbuddy-cred-sync.sh（rclone 把
      # Dropbox 凭据拉到运行目录）。脚本缺失时起单元只会空转崩溃循环。
      [ -s /tmp/workbuddy-cred-sync.sh ] || { rm -f "$tmp"; die "workbuddy-cred-sync: /tmp/workbuddy-cred-sync.sh 缺失"; }
      ensure_log_dir "$LOG_ROOT/workbuddy-gateway/logs/cred-sync.log"
      cat > "$tmp" <<EOF
[Unit]
Description=workbuddy credential sync (Dropbox -> /tmp/local_workbuddy/data, 300s)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
ExecStart=/tmp/workbuddy-cred-sync.sh 300
Restart=always
RestartSec=10
# 停止超时：循环可能正持有 flock / rclone 传输，默认 90s 不够，统一放宽。
TimeoutStopSec=180
StandardOutput=append:$LOG_ROOT/workbuddy-gateway/logs/cred-sync.log
StandardError=append:$LOG_ROOT/workbuddy-gateway/logs/cred-sync.log

[Install]
WantedBy=default.target
EOF
      ;;
    quota-board)
      # 看板不是网关，但同为宿主常驻进程，同样需要 Restart=always 自愈。
      # 与四个网关的差异：本体（board.py）和凭据都在持久化目录
      # （/dropbox/self-hosted/quota-board/ + ~/.openclaw/.env），
      # 运行目录无需准备，只需校验两份持久化文件在位。
      # 注意：fuse 挂载上脚本不可直接执行（bad interpreter），故用解释器显式调用。
      [ -s /dropbox/self-hosted/quota-board/board.py ] || { rm -f "$tmp"; die "quota-board: board.py 缺失"; }
      [ -s "${HOME}/.openclaw/.env" ] || { rm -f "$tmp"; die "quota-board: ~/.openclaw/.env 缺失（TG token / TRAE2API_KEY 依赖）"; }
      cat > "$tmp" <<EOF
[Unit]
Description=quota-board (workbuddy/trae/zcode 额度聚合 + TG 看板, 8321)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
# 复用全局敏感变量：TELEGRAM_BOT_TOKEN_*、TELEGRAM_CHAT_ID、TRAE2API_KEY
EnvironmentFile=%h/.openclaw/.env
ExecStart=/usr/bin/python3 /dropbox/self-hosted/quota-board/board.py
Restart=always
RestartSec=5
# 停止超时：看板每轮采集含 HTTP 请求与 sqlite 只读查询，统一放宽（同三网关）
TimeoutStopSec=180
StandardOutput=append:/dropbox/self-hosted/quota-board/board.log
StandardError=append:/dropbox/self-hosted/quota-board/board.log

[Install]
WantedBy=default.target
EOF
      ;;
    *) die "未知服务: $name（可选 workbuddy | zcode2api | qingyan | workbuddy-cred-sync | quota-board）" ;;
  esac
  install -m 600 "$tmp" "$UNIT_DIR/$(unit_name "$name")"
  rm -f "$tmp"
}

cmd_ensure() {
  local name="${1:-}"
  [ -n "$name" ] || die "用法: $0 ensure <workbuddy|zcode2api|qingyan|workbuddy-cred-sync|quota-board>"
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
  [ -n "$name" ] || die "用法: $0 stop <workbuddy|zcode2api|qingyan|workbuddy-cred-sync|quota-board>"
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
  local names="workbuddy zcode2api qingyan workbuddy-cred-sync quota-board"
  printf '%-20s %-34s %s\n' "单元" "状态" "服务"
  local n unit st
  for n in $names; do
    [ -n "$only" ] && [ "$n" != "$only" ] && continue
    unit="$(unit_name "$n")"
    if systemctl --user is-active --quiet "$unit" 2>/dev/null; then st="✅ 运行"
    elif systemctl --user is-enabled --quiet "$unit" 2>/dev/null; then st="⛔ 已停止"
    else st="— 未安装"; fi
    printf '%-20s %-34s %s\n' "$n" "$st" "$unit"
  done
}

case "${1:-}" in
  ensure) cmd_ensure "${2:-}" ;;
  stop)   cmd_stop "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  *) echo "用法: $0 {ensure|stop|status} [name]"; exit 1 ;;
esac
