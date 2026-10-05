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
SYSTEM_UNIT_DIR="/etc/systemd/system"

# ── systemd 级别分流（2026-10-05 主人拍板 C 方案）───────────────────────────
# 本脚本同时管理 --user 级与 system 级单元。为什么要混两级：
#   归属按**服务性质**定（服务 vs 隧道），不按 systemd 级别定 —— 级别只是实现
#   细节。tailscaled 必须 system 级（TUN 设备 /dev/net/tun 是 root:root，
#   --user 单元起不来），但它显然不是"隧道"，不该塞进 tunnels.sh。
#   于是 services.sh 自己按级别分流，对外仍是"所有服务一个入口"。
svc_level() {
  case "$1" in
    tailscaled) echo system ;;
    *)          echo user ;;
  esac
}

# 单元目录按级别取
svc_unit_dir() {
  case "$(svc_level "$1")" in
    system) echo "$SYSTEM_UNIT_DIR" ;;
    user)   echo "$UNIT_DIR" ;;
  esac
}

# systemctl 包装：按级别决定加不加 sudo / --user
svc() {
  local name="$1"; shift
  local unit; unit="$(unit_name "$name")"
  case "$(svc_level "$name")" in
    system) sudo systemctl "$@" "$unit" ;;
    user)   systemctl --user "$@" "$unit" ;;
  esac
}

# 名称白名单：校验必须在**当前 shell** 做（放进 $(...) 时 die 只退子 shell）
valid_name() {
  case "$1" in
    workbuddy|zcode2api|qingyan|workbuddy-cred-sync|quota-board|rclone-dropbox|archive-loop|tailscaled) return 0 ;;
    *) return 1 ;;
  esac
}

# 裸跑实例检测：单元尚未接管，但同功能进程已在跑（历史 nohup / action spawn 的）。
# 这些服务 ensure 时**不能无条件重启** —— 见 cmd_ensure 里的说明。
has_bare_instance() {
  case "$1" in
    rclone-dropbox) mount 2>/dev/null | grep -q " on /dropbox " ;;
    archive-loop)   pgrep -f "openclaw-archive-loop.sh" >/dev/null 2>&1 ;;
    tailscaled)     pgrep -x tailscaled >/dev/null 2>&1 &&
                      ! sudo systemctl is-active --quiet tailscaled.service 2>/dev/null ;;
    *) return 1 ;;
  esac
}

log() { printf '[services] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# ───────────────────────── 日志保留（自动清理） ─────────────────────────
# 背景（2026-10-05）：日志统一落 Dropbox 后只增不减 ——
#   - gateway-*.log 按天切分，但网关 config.json 的 keepDays: 7 **实测未生效**
#     （目录下躺着 19 个、最早 09-17 已存 18 天，日志里也搜不到任何清理动作）；
#   - serve.log 等 append 型单文件：append: 模式 systemd 不轮转，
#     /etc/logrotate.d/ 也没有任何规则命中 Dropbox 这些路径。
# 故在此按天删除 + 按体积原地截断，随每轮 ensure 顺带跑，无需新增定时器。
#   LOG_KEEP_DAYS  按天文件的保留天数（默认 90，主人 2026-10-05 定）
#   LOG_MAX_MB     单个 append 型日志的体积上限（默认 100MB，主人 2026-10-05 定），超出保留尾部一半
#   LOG_PRUNE_DRY_RUN=1  只预览不执行
LOG_KEEP_DAYS="${LOG_KEEP_DAYS:-90}"
LOG_MAX_MB="${LOG_MAX_MB:-100}"

prune_logs() {
  local dir f size max_bytes keep rel
  max_bytes=$(( LOG_MAX_MB * 1024 * 1024 ))
  # 服务日志目录（board.log 直接在服务根目录，不在 logs/ 下）
  for dir in \
    "$LOG_ROOT/workbuddy-gateway/logs" \
    "$LOG_ROOT/zcode2api/logs" \
    "$LOG_ROOT/qingyan-proxy/logs" \
    "$LOG_ROOT/quota-board"
  do
    [ -d "$dir" ] || continue
    # ① 按天文件：gateway-YYYY-MM-DD.log 超期删除（mtime 早于保留窗口）
    for f in "$dir"/gateway-*.log; do
      [ -f "$f" ] || continue
      [ -n "$(find "$f" -type f -mtime +"$LOG_KEEP_DAYS" -print -quit 2>/dev/null)" ] || continue
      rel="${f#$LOG_ROOT/}"
      if [ -n "${LOG_PRUNE_DRY_RUN:-}" ]; then
        log "[dry-run] 将删除超期日志: $rel"
        continue
      fi
      rm -f "$f" && log "🗑 超期日志已删: $rel（>${LOG_KEEP_DAYS} 天）"
    done
    # ② append 型单文件：超体积原地截断
    for f in "$dir"/*.log; do
      [ -f "$f" ] || continue
      size=$(stat -c %s "$f" 2>/dev/null || echo 0)
      [ "$size" -gt "$max_bytes" ] || continue
      keep=$(( max_bytes / 2 ))
      rel="${f#$LOG_ROOT/}"
      if [ -n "${LOG_PRUNE_DRY_RUN:-}" ]; then
        log "[dry-run] 将截断超限日志: $rel（$(( size / 1048576 ))MB → 留尾部 $(( keep / 1048576 ))MB）"
        continue
      fi
      # ⚠️ 必须原地重写（cat > 同一路径）：mv 换 inode 会让 systemd 持有的 fd
      #    继续写到已脱离目录的旧 inode，新日志全部不可见 —— 日志"看似停更"。
      if tail -c "$keep" "$f" > "$f.prune.tmp" 2>/dev/null && \
         cat "$f.prune.tmp" > "$f" 2>/dev/null; then
        rm -f "$f.prune.tmp"
        log "✂️ 超限日志已截断: $rel（$(( size / 1048576 ))MB → 留尾部 $(( keep / 1048576 ))MB）"
      else
        rm -f "$f.prune.tmp"
        log "⚠️ 日志截断失败（已跳过）: $rel"
      fi
    done
  done
}

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
# -uz：先 lazy unmount 再强制，避免 "device is busy" 把停止卡成 SIGKILL
ExecStop=/usr/bin/fusermount3 -uz /dropbox
TimeoutStopSec=60
StandardOutput=append:${LOG_DIR}/rclone-dropbox.log
StandardError=append:${LOG_DIR}/rclone-dropbox.log

[Install]
WantedBy=default.target
EOF
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
      ;;
    tailscaled)
      # systemd 级（root）：TUN 设备 /dev/net/tun 属 root，--user 单元起不来。
      # ⚠️ 关键坑（2026-10-05 实测）：原写法 `tailscaled --state=mem:` 把登录态
      #    只放内存 —— 进程一死认证即丢，Restart=always 拉起来的只是个
      #    Logged out 空壳，托管形同虚设。改用 --statedir 落盘后崩溃重启
      #    自动恢复登录，自愈才是真的自愈。
      #    /var/lib/tailscale 需预先存在，否则 tailscaled 直接退出。
      cat > "$tmp" <<EOF
[Unit]
Description=Tailscale daemon (systemd 托管, 持久 state)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=0

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/tailscale /var/lib/tailscale
# 与 tailscale/github-action 的 statedir 入参同路径，共享同一份登录态
ExecStart=/usr/local/bin/tailscaled --statedir=/var/lib/tailscale --socket=/run/tailscale/tailscaled.sock
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      ;;
    *) die "未知服务: $name（可选 workbuddy | zcode2api | qingyan | workbuddy-cred-sync | quota-board | rclone-dropbox | archive-loop | tailscaled）" ;;
  esac
  # 写盘按级别分流：system 级落到 /etc/systemd/system（需 sudo，权限 644）
  case "$(svc_level "$name")" in
    system)
      sudo install -m 644 "$tmp" "$(svc_unit_dir "$name")/$(unit_name "$name")" 2>/dev/null \
        || { rm -f "$tmp"; die "$name: system 级单元写盘失败（sudo 不可用？）"; }
      ;;
    user)
      install -m 600 "$tmp" "$(svc_unit_dir "$name")/$(unit_name "$name")"
      ;;
  esac
  rm -f "$tmp"
}

cmd_ensure() {
  local name="${1:-}"
  [ -n "$name" ] || die "用法: $0 ensure <workbuddy|zcode2api|qingyan|workbuddy-cred-sync|quota-board|rclone-dropbox|archive-loop|tailscaled>"
  valid_name "$name" || die "未知服务: $name"
  local unit
  unit="$(unit_name "$name")"

  # 日志保留：ensure 会对各服务各调一次，用当日戳去重，每轮 run 只跑一次
  _prune_stamp="/tmp/.services-prune-$(date +%F)"
  if [ ! -f "$_prune_stamp" ]; then
    prune_logs
    : > "$_prune_stamp"
  fi

  write_unit "$name"
  case "$(svc_level "$name")" in
    system) sudo systemctl daemon-reload 2>/dev/null ;;
    user)   systemctl --user daemon-reload ;;
  esac

  # 幂等 enable：user manager 常驻（Linger=yes），system 级随 multi-user.target
  svc "$name" enable >/dev/null 2>&1

  # ⚠️ 裸跑实例优先（2026-10-05 加）：单元尚未接管、但同功能进程已在跑时，
  #    **不重启** —— 过渡期单元与旧裸跑实例并存，无条件 restart 会造成：
  #      rclone   挂载点抖动，所有读写 /dropbox 的进程遭殃
  #      archive  双份归档同时传同一 tar.gz（flock 抢锁、云端反复覆盖）
  #    只安装单元并提示：每轮 run 都是新 VM，下一轮单元自然接管。
  if has_bare_instance "$name"; then
    log "⚠️ $name 检测到裸跑实例（非 systemd 托管），本轮不打断"
    log "   单元已安装就绪，新 VM / 服务重启后自动接管"
    return 0
  fi

  # 每轮重启一次（语义对齐原 nohup 方案的 pkill + 重启；理由见文件头）
  log "重启 $unit（每轮 run 起点，确保跑在最新二进制/依赖上）"
  svc "$name" restart
  sleep 3

  if svc "$name" is-active --quiet; then
    log "✅ $name 运行中 ($unit)"
  else
    case "$(svc_level "$name")" in
      system) log "❌ $name 启动失败，查看: sudo journalctl -u $unit" ;;
      user)   log "❌ $name 启动失败，查看: journalctl --user -u $unit" ;;
    esac
    return 1
  fi
}

cmd_stop() {
  local name="${1:-}"
  [ -n "$name" ] || die "用法: $0 stop <workbuddy|zcode2api|qingyan|workbuddy-cred-sync|quota-board|rclone-dropbox|archive-loop|tailscaled>"
  valid_name "$name" || die "未知服务: $name"
  local unit
  unit="$(unit_name "$name")"

  # 必须走 systemd stop 而不是 pkill：Restart=always 会把 pkill 杀掉的进程
  # 在 5 秒内拉回来，「等待退出」循环会误判进程残留（收尾步骤语义见 openclaw.yml）
  svc "$name" stop || true
  for _ in $(seq 1 30); do
    svc "$name" is-active --quiet || { log "✅ $name 已停止"; return 0; }
    sleep 1
  done
  log "⚠️ $name 未在 30 秒内退出，强制结束"
  svc "$name" kill --signal=SIGKILL || true
  svc "$name" stop || true
  return 0
}

cmd_status() {
  local only="${1:-}"
  local names="workbuddy zcode2api qingyan workbuddy-cred-sync quota-board rclone-dropbox archive-loop tailscaled"
  printf '%-20s %-10s %-34s %s\n' "服务" "级别" "状态" "单元"
  local n unit st lvl
  for n in $names; do
    [ -n "$only" ] && [ "$n" != "$only" ] && continue
    unit="$(unit_name "$n")"
    lvl="$(svc_level "$n")"
    if svc "$n" is-active --quiet; then st="✅ 运行"
    elif svc "$n" is-enabled --quiet; then st="⛔ 已停止"
    else st="— 未安装"; fi
    printf '%-20s %-10s %-34s %s\n' "$n" "$lvl" "$st" "$unit"
  done
}

case "${1:-}" in
  ensure) cmd_ensure "${2:-}" ;;
  stop)   cmd_stop "${2:-}" ;;
  restart) cmd_ensure "${2:-}" ;;
  status) cmd_status "${2:-}" ;;
  *) echo "用法: $0 {ensure|stop|status} [name]"; exit 1 ;;
esac
