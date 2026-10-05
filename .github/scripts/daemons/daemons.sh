#!/usr/bin/env bash
# 长驻进程统一 systemd 托管器（接住所有"死了没人拉"的裸跑守护进程）
#
# 位置：.github/scripts/daemons/daemons.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 各启动步骤（ensure / restart）
#
# 背景（2026-10-05 主人拍板）：此前一批进程用 nohup / sudo 裸跑，进程被 signal
# sweep 或崩溃后没有任何东西拉起，只能等下一轮 run（可达数小时）。本机约定
# 「长驻服务一律 systemd 托管」（见 AGENTS.md），本脚本把仍裸跑的三类补齐：
#
#   tailscaled        system 级（root）—— 原 `sudo nohup tailscaled --state=mem:`
#   rclone-dropbox    user 级（runner）—— 原 `nohup rclone mount dropbox: /dropbox`
#   archive-loop      user 级（runner）—— 原 `nohup bash /tmp/openclaw-archive-loop.sh`
#
# 与既有两套管理器的分工（不要混用）：
#   services.sh  → systemd --user，宿主进程形态的 AI 网关/看板（业务进程）
#   tunnels.sh   → systemd system，cloudflared 隧道（已有，本脚本不重复）
#   daemons.sh   → 上面那些"基础设施型"守护进程（挂载 / 组网 / 归档循环）
#
# ⚠️ tailscaled 的关键坑（2026-10-05 实测）：
#   原写法 `tailscaled --state=mem:` 把认证态只放内存 —— 进程一死，Restart=always
#   拉起来的只是个**没登录的空壳**（tailscale status 报Logged out）。所以托管
#   必须同时把 state 落到磁盘（--state=/var/lib/tailscale/tailscaled.state），
#   认证态随之持久化，崩溃重启后自动恢复登录，自愈才是真的自愈。
#
# 用法：
#   daemons.sh ensure <name>     # 幂等：确保在跑（已运行则跳过，不动现有实例）
#   daemons.sh restart <name>    # 强制重启（跑最新脚本/二进制时用）
#   daemons.sh status [name]     # 状态总览
#   daemons.sh ts-login [host]   # 仅 tailscaled：生成 authkey 并登录
#
# ensure 语义与 services.sh **不同**：这里一律「已运行则跳过」。
#   原因：这三类都是基础设施（挂载点 / 组网 / 正在跑的归档循环），每轮无条件
#   重启会造成 umount 抖动、SSH 断连、归档中断。要跑最新脚本请显式用 restart。
set -u

LOG_DIR="${HOME}/.openclaw/logs"

# 单实例锁，避免 workflow 并发步骤打架
LOCK="/tmp/.daemons-$(id -u).lock"
exec 9>"$LOCK" 2>/dev/null || true
flock -n 9 2>/dev/null || { echo "[daemons] 另一个实例正在运行，跳过"; exit 0; }

mkdir -p "$LOG_DIR" 2>/dev/null || true

log()  { printf '[daemons] %s\n' "$*"; }
die()  { printf '[daemons] ❌ %s\n' "$*" >&2; exit 1; }

# 名称白名单（独立于 svc_level）：校验必须在**当前 shell** 做。
# 踩过的坑：若靠 svc_level 里的 die 兜底，调用方把它放进 $(...) 命令替换，
# die 的 exit 只退出子 shell，脚本继续往下跑 —— 未知服务名会被当成
# 「已在运行」静默跳过。故显式校验一次。
valid_name() {
  case "$1" in
    tailscaled|rclone-dropbox|archive-loop) return 0 ;;
    *) return 1 ;;
  esac
}

# 服务级别：决定用 systemctl 还是 systemctl --user
svc_level() {
  case "$1" in
    tailscaled)     echo system ;;
    rclone-dropbox) echo user ;;
    archive-loop)   echo user ;;
    *) die "未知服务: $1（可选 tailscaled | rclone-dropbox | archive-loop）" ;;
  esac
}

unit_name() { echo "$1.service"; }

# 按级别包装 systemctl 调用
svc() {
  local name="$1"; shift
  local unit; unit="$(unit_name "$name")"
  case "$(svc_level "$name")" in
    system) sudo systemctl "$@" "$unit" ;;
    user)   systemctl --user "$@" "$unit" ;;
  esac
}

is_active() {
  local name="$1" unit; unit="$(unit_name "$name")"
  case "$(svc_level "$name")" in
    system) sudo systemctl is-active --quiet "$unit" 2>/dev/null ;;
    user)   systemctl --user is-active --quiet "$unit" 2>/dev/null ;;
  esac
}

# 裸跑实例检测：单元尚未接管，但同功能进程已在跑（历史 nohup / action spawn 起的）。
# ensure 时**绝不启动单元** —— 挂载点 / socket 已被占用，强起必然失败，还会
# 打断正在服务的实例（rclone 挂载一抖，所有读写 /dropbox 的进程全遭殃）。
# 只安装单元并提示：每轮 run 都是新 VM，下一轮单元自然接管。
# 这是过渡期安全阀 —— 改完不用等维护窗口，也不会打断当前这一轮。
has_bare_instance() {
  case "$1" in
    rclone-dropbox) mount 2>/dev/null | grep -q " on /dropbox " ;;
    archive-loop)   pgrep -f "openclaw-archive-loop.sh" >/dev/null 2>&1 ;;
    tailscaled)     pgrep -x tailscaled >/dev/null 2>&1 &&
                      ! sudo systemctl is-active --quiet tailscaled.service 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# ── 单元模板 ──────────────────────────────────────────────────────────────
# 本文件是这些单元的**唯一真源**：写盘走 mktemp + 安装，避免 umask 意外放权。
# 要改单元内容，改这里并 push —— 手改现役单元文件会被下一轮 ensure 冲掉。
write_unit() {
  local name="$1"
  local tmp; tmp="$(mktemp /tmp/daemons-unit-XXXXXX)"
  umask 077

  case "$name" in
    tailscaled)
      cat > "$tmp" <<'EOF'
[Unit]
Description=Tailscale daemon (systemd 托管, 持久 state)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
# state 落磁盘（非 --state=mem:）：认证态持久化，Restart 后自动恢复登录，
# 而不是拉起一个 Logged out 的空壳。目录需预先存在，否则 tailscaled 直接退出。
ExecStartPre=/bin/mkdir -p /run/tailscale /var/lib/tailscale
# 用 --statedir（而非 --state=mem:），且与 tailscale/github-action 的 statedir
# 入参设成同一路径：action 起的 tailscaled 与本单元共享同一份登录态。
# 登录态落在 /var/lib/tailscale/，崩溃重启后自动恢复登录，而不是拉起一个
# Logged out 的空壳（2026-10-05 实测：mem: 态进程一死认证即丢）。
ExecStart=/usr/local/bin/tailscaled --statedir=/var/lib/tailscale --socket=/run/tailscale/tailscaled.sock
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      sudo install -m 644 "$tmp" "/etc/systemd/system/$(unit_name "$name")" 2>/dev/null \
        || { rm -f "$tmp"; die "tailscaled: 单元写盘失败（sudo 不可用？）"; }
      ;;

    rclone-dropbox)
      cat > "$tmp" <<EOF
[Unit]
Description=rclone mount dropbox: -> /dropbox
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
# 参数画像："配置 / Docker 数据卷"——小文件随机读写，不需要大块顺序预读。
#   --cache-dir        默认 ~/.cache/rclone 会落进根分区（≈14GB），必须指向 /mnt
#   --attr-timeout 1m  原 10m：容器内文件频繁增删改，属性缓存 10 分钟有陈旧风险
#   --poll-interval 0  run 期间远端目录不会自己变，关轮询省 API 配额
#   --buffer-size 16M  原 100M：每个打开的文件常驻一份，小文件场景用不到
# 以 runner 身份挂载（不用 sudo）：root 挂载会在 token 刷新时把 rclone.conf
# 回写成 root 属主 600，之后归档循环读它就 permission denied。
ExecStart=/usr/bin/rclone mount dropbox: /dropbox \\
  --config %h/.config/rclone/rclone.conf \\
  --cache-dir /mnt/vfs/dropbox \\
  --allow-other --umask 000 --no-gzip-encoding \\
  --attr-timeout 1m \\
  --dir-cache-time 72h --poll-interval 0 \\
  --vfs-cache-mode full \\
  --vfs-cache-max-size 2G --vfs-cache-max-age 1h \\
  --vfs-cache-min-free-space 2G \\
  --vfs-cache-poll-interval 30s \\
  --buffer-size 16M \\
  --log-file /opt/logs/rclone-dropbox.log --log-level INFO
Restart=always
RestartSec=10
# -uz：先 lazy unmount 再强制，避免"device is busy"把停止卡成 SIGKILL
ExecStop=/usr/bin/fusermount3 -uz /dropbox
TimeoutStopSec=60
StandardOutput=append:${LOG_DIR}/rclone-dropbox.log
StandardError=append:${LOG_DIR}/rclone-dropbox.log

[Install]
WantedBy=default.target
EOF
      install -m 600 "$tmp" "${HOME}/.config/systemd/user/$(unit_name "$name")"
      ;;

    archive-loop)
      cat > "$tmp" <<EOF
[Unit]
Description=OpenClaw periodic archive loop (Dropbox 归档循环)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
# 脚本由 openclaw.yml 每轮用 heredoc 现场生成到 /tmp；不存在则安静跳过，
# 不要进入"启动即失败"的崩溃循环（与 tunnels.sh 的端口预检同口径）。
ConditionPathExists=/tmp/openclaw-archive-loop.sh
ExecStart=/bin/bash /tmp/openclaw-archive-loop.sh
Restart=always
RestartSec=30
# 一轮归档最长 40m（脚本内 timeout），留足排空时间
TimeoutStopSec=180
StandardOutput=append:${LOG_DIR}/openclaw-archive-loop.log
StandardError=append:${LOG_DIR}/openclaw-archive-loop.log

[Install]
WantedBy=default.target
EOF
      install -m 600 "$tmp" "${HOME}/.config/systemd/user/$(unit_name "$name")"
      ;;
  esac
  rm -f "$tmp"
}

# ── 命令实现 ──────────────────────────────────────────────────────────────

ensure_one() {
  local name="$1"
  valid_name "$name" || die "未知服务: $name（可选 tailscaled | rclone-dropbox | archive-loop）"
  write_unit "$name"

  case "$(svc_level "$name")" in
    system) sudo systemctl daemon-reload 2>/dev/null ;;
    user)   systemctl --user daemon-reload 2>/dev/null ;;
  esac

  # 幂等 enable：user manager 常驻（Linger=yes），system 级随 multi-user.target
  svc "$name" enable >/dev/null 2>&1

  if is_active "$name"; then
    log "✅ $name 已在运行（systemd 托管，跳过，不打断）"
    return 0
  fi

  if has_bare_instance "$name"; then
    log "⚠️ $name 检测到裸跑实例（非 systemd 托管），本轮不打断"
    log "   单元已安装就绪，新 VM / 服务重启后自动接管"
    return 0
  fi

  log "启动 $name ($(unit_name "$name"))"
  svc "$name" restart >/dev/null 2>&1 || svc "$name" start >/dev/null 2>&1
  sleep 3

  if is_active "$name"; then
    log "✅ $name 运行中"
  else
    log "❌ $name 启动失败，查看: $([ "$(svc_level "$name")" = system ] && echo "sudo " )journalctl -u $(unit_name "$name")"
    return 1
  fi
}

restart_one() {
  local name="$1"
  valid_name "$name" || die "未知服务: $name（可选 tailscaled | rclone-dropbox | archive-loop）"
  write_unit "$name"
  case "$(svc_level "$name")" in
    system) sudo systemctl daemon-reload 2>/dev/null ;;
    user)   systemctl --user daemon-reload 2>/dev/null ;;
  esac
  svc "$name" enable >/dev/null 2>&1
  log "重启 $name（跑最新脚本/二进制）"
  svc "$name" restart >/dev/null 2>&1
  sleep 3
  is_active "$name" && log "✅ $name 运行中" \
                    || log "❌ $name 重启后未运行"
}

cmd_status() {
  local list="${1:-tailscaled rclone-dropbox archive-loop}"
  printf '%-18s %-10s %s\n' "守护进程" "状态" "单元"
  for name in $list; do
    local st
    if is_active "$name"; then st="✅ 运行"; else st="— 未运行"; fi
    printf '%-18s %-10s %s\n' "$name" "$st" "$(unit_name "$name")"
  done
}

# tailscaled 专用：生成一次性 authkey 并登录。
# 为什么自己发 authkey 而不用 tailscale/github-action：
#   action 自己拉起 `tailscaled --state=mem:`（硬编码），与 systemd 单元抢
#   /run/tailscale/tailscaled.sock。要托管就必须自己管登录，登录态随 state
#   落盘，崩溃重启后自动恢复，不再依赖每轮重新认证。
# authkey 只在进程 cmdline/环境可见（同机仅 runner 一个真实用户），
# 日志与通知里绝不回显。
cmd_ts_login() {
  local hostname="${1:-openclaw}"
  [ -n "${TS_API_KEY:-}" ] || die "TS_API_KEY 未注入，无法生成 authkey"

  local resp key
  resp="$(curl -fsS --max-time 30 -u "${TS_API_KEY}:" \
    -H "Content-Type: application/json" \
    -X POST https://api.tailscale.com/api/v2/tailnet/-/keys \
    -d '{"capabilities":{"devices":{"create":{"ephemeral":true,"preauthorized":true,"tags":["tag:ci"]}}},"expirySeconds":3600}' 2>&1)" \
    || die "authkey 生成失败: ${resp}"
  key="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])' 2>/dev/null)" \
    || die "authkey 解析失败"
  [ -n "$key" ] || die "authkey 为空"

  log "已取得 authkey（不回显），登录 hostname=${hostname} ..."
  sudo tailscale up --authkey="$key" --hostname="$hostname" \
    --ssh --advertise-exit-node 2>&1 | sed 's/tskey-[A-Za-z0-9_-]*/***/g'
  log "✅ tailscale up 完成"
}

case "${1:-status}" in
  ensure)   [ -n "${2:-}" ] && ensure_one "$2" || die "用法: $0 ensure <name>" ;;
  restart)  [ -n "${2:-}" ] && restart_one "$2" || die "用法: $0 restart <name>" ;;
  status)   cmd_status "${2:-}" ;;
  ts-login) cmd_ts_login "${2:-openclaw}" ;;
  *) echo "用法: $0 {ensure|restart|status} [name] | ts-login [hostname]"; exit 1 ;;
esac
