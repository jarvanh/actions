#!/bin/bash
# 安装系统健康看门狗（systemd user timer，每 5 分钟一次）
#
# 2026-11-10 引入：1033 事故全程无通知（挂载被 AppArmor 拒绝 → 凭据缺失 →
# 隧道空转 3 小时），主人只能自己发现。本脚本把 system_health.sh 装成常驻定时器，
# 状态变化时发 TG（alert 档）。
#
# 由 openclaw.yml 在 Mount Dropbox 成功后调用；凭据通过 step env 注入，写进
# 600 权限的 EnvironmentFile，不上命令行、不进日志。
set -eu

ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
BIN="$HOME/.openclaw/bin"
UNIT_DIR="$HOME/.config/systemd/user"
ENV_FILE="$HOME/.openclaw/health-watchdog.env"

install -d -m 755 "$BIN" "$UNIT_DIR"

install -m 755 "$ROOT/.github/scripts/health/system_health.sh" "$BIN/system_health.sh"
install -m 644 "$ROOT/.github/scripts/telegram/tg_notify.sh" "$BIN/tg_notify.sh"

# 凭据：优先 alert 档（重要通知走 @SaberFuckBot），缺失时退回主 bot
tok="${TELEGRAM_BOT_TOKEN_ALERT:-${TELEGRAM_BOT_TOKEN:-}}"
chat="${TELEGRAM_CHAT_ID_ALERT:-${TELEGRAM_CHAT_ID:-}}"
umask 077
{
  echo "TELEGRAM_BOT_TOKEN=${tok}"
  echo "TELEGRAM_CHAT_ID=${chat}"
  if [ -n "${TELEGRAM_BOT_TOKEN_ALERT:-}" ]; then
    echo "TELEGRAM_BOT_TOKEN_ALERT=${TELEGRAM_BOT_TOKEN_ALERT}"
    echo "TELEGRAM_CHAT_ID_ALERT=${TELEGRAM_CHAT_ID_ALERT:-}"
  fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

cat > "$UNIT_DIR/openclaw-health.service" <<EOF
[Unit]
Description=OpenClaw 系统健康看门狗（挂载/隧道/看板/gateway）
After=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=oneshot
Environment=HOME=$HOME
EnvironmentFile=$ENV_FILE
ExecStart=$BIN/system_health.sh
StandardOutput=append:$HOME/.openclaw/logs/health-watchdog.log
StandardError=append:$HOME/.openclaw/logs/health-watchdog.log
EOF

cat > "$UNIT_DIR/openclaw-health.timer" <<EOF
[Unit]
Description=每 5 分钟检查 OpenClaw 系统级健康

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Unit=openclaw-health.service

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now openclaw-health.timer >/dev/null 2>&1 || true
systemctl --user start openclaw-health.service || true

if systemctl --user is-active --quiet openclaw-health.timer; then
  echo "✅ 健康看门狗已启动（每 5 分钟，日志 ~/.openclaw/logs/health-watchdog.log）"
else
  echo "⚠️ 健康看门狗定时器未激活，检查: systemctl --user status openclaw-health.timer"
fi