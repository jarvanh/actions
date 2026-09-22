#!/usr/bin/env bash
# 统一 cloudflared 隧道管理器（systemd 化，带自动重启）
#
# 位置：.github/scripts/tunnels/tunnels.sh（随仓库 checkout 分发）
# 调用：由各 workflow 在启动隧道的步骤中调用，不由 setup-env.sh 调用
#
# 用法：
#   tunnels.sh ensure [name]    # 收敛：确保隧道在跑（缺失则安装单元并启动）
#   tunnels.sh status           # 查看全部隧道状态
#   tunnels.sh restart [name]   # 重启
#
# 隧道清单：同目录 tunnels.conf（每行：名字|cloudflared 参数|源站端口）
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/tunnels.conf"
UNIT_DIR="/etc/systemd/system"
LOG_DIR="${HOME}/.openclaw/logs"

# 单实例锁，避免并发调用打架
LOCK="/tmp/.cftun-$(id -u).lock"
exec 9>"$LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || { echo "[tunnels] 另一个实例正在运行，跳过"; exit 0; }

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() { printf '[tunnels] %s\n' "$*"; }

# 端口是否在监听（前置源站是否就绪）
port_ready() {
  local port="$1"
  [ -z "$port" ] && return 0
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

unit_name() { echo "cftun-$1.service"; }

# 生成 systemd 单元：模板先落 mktemp，再 sudo 安装到 /etc/systemd/system
write_unit() {
  local name="$1" args="$2" port="$3"
  local unit="$(unit_name "$name")"
  local tmp
  tmp="$(mktemp /tmp/cftun-unit-XXXXXX)"
  cat > "$tmp" <<EOF
[Unit]
Description=cloudflared tunnel: $name -> 127.0.0.1:$port
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$(id -un)
Environment=HOME=${HOME}
ExecStart=/usr/bin/cloudflared tunnel run $args
Restart=always
RestartSec=10
StandardOutput=append:${LOG_DIR}/cloudflared_${name}.log
StandardError=append:${LOG_DIR}/cloudflared_${name}.log

[Install]
WantedBy=multi-user.target
EOF
  sudo cp "$tmp" "$UNIT_DIR/$unit" 2>/dev/null
  rm -f "$tmp"
}

ensure_one() {
  local name="$1" args="$2" port="$3"
  local unit="$(unit_name "$name")"

  # 源站未就绪则跳过：避免隧道对着空端口狂重启刷日志
  if ! port_ready "$port"; then
    log "跳过 $name：源站 127.0.0.1:$port 未监听"
    return 0
  fi

  write_unit "$name" "$args" "$port"
  sudo systemctl daemon-reload 2>/dev/null

  sudo systemctl enable "$unit" >/dev/null 2>&1

  if ! sudo systemctl is-active --quiet "$unit" 2>/dev/null; then
    log "启动 $name ($unit)"
    sudo systemctl restart "$unit" >/dev/null 2>&1
    sleep 3
  fi

  if sudo systemctl is-active --quiet "$unit" 2>/dev/null; then
    log "✅ $name 运行中"
  else
    log "❌ $name 启动失败，查看: journalctl -u $unit"
  fi
}

read_conf() {
  [ -f "$CONF" ] || { log "缺少清单 $CONF" >&2; exit 1; }
}

cmd_ensure() {
  local only="${1:-}"
  read_conf
  while IFS='|' read -r name args port; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    ensure_one "$name" "$args" "$port"
  done < "$CONF"
}

cmd_status() {
  read_conf
  printf '%-14s %-16s %s\n' "隧道" "状态" "单元"
  while IFS='|' read -r name args port; do
    case "$name" in ''|\#*) continue ;; esac
    local unit="$(unit_name "$name")" st
    if sudo systemctl is-active --quiet "$unit" 2>/dev/null; then st="✅ 运行"
    elif port_ready "$port"; then st="⚠️ 源站在但未起"
    else st="— 源站未起"; fi
    printf '%-14s %-16s %s\n' "$name" "$st" "$unit"
  done < "$CONF"
}

cmd_restart() {
  local only="${1:-}"
  read_conf
  while IFS='|' read -r name args port; do
    case "$name" in ''|\#*) continue ;; esac
    [ -n "$only" ] && [ "$name" != "$only" ] && continue
    sudo systemctl restart "$(unit_name "$name")" >/dev/null 2>&1
    log "已重启 $name"
  done < "$CONF"
}

case "${1:-ensure}" in
  ensure)  cmd_ensure "${2:-}" ;;
  status)  cmd_status ;;
  restart) cmd_restart "${2:-}" ;;
  *) echo "用法: $0 {ensure|status|restart} [name]"; exit 1 ;;
esac
