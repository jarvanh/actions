#!/usr/bin/env bash
# openclaw 工作流「Run AI API gateway」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：AI_BACKEND_INPUT / TELEGRAM_BOT_TOKEN(_ALERT) /
#     TELEGRAM_CHAT_ID(_ALERT) / TG_RUN_URL / GITHUB_WORKSPACE
#   落盘契约：/tmp/active-ai-backend.env（BACKEND_STATE，下游通知读取）、
#     /tmp/upstream-rc-*（P5b 等齐门，上游六脚本的标记）
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）；体内Barrier 段自带
# set +e（等齐轮询）与 set -euo pipefail（部署段），失败语义与原 run 块一致。
# 注：compose heredoc 原本靠 `sed 's/^          //'` 剥 run-block 缩进，
# 外置后内容天然顶格，该 sed 成为无害 no-op，保留以防口径漂移。

# ── 2026-10-30 P5b：上游并行拉起汇合门（屏障）──
# workbuddy/trae2api/zcode2api/qingyan 已改后台部署（rc → /tmp/upstream-rc-*）。
# 此处等齐（上限 480s）才开始部署 OmniRoute —— 守住「上游先于代理」的启动
# 顺序（主人原则）。全健康 → 正常；有失败/超时 → 渠道降级照常部署（与原
# 串行语义一致：上游失败不阻断 AI 网关，失败详情由各步骤 TG 告警与下方日志承担）。
# ── 2026-10-31 P5b 契约拆分 ──
# rc 语义收紧为「服务已监听」：各上游脚本在端口就绪判定点直写 rc，签到/积分收割/
# 端到端自检/TG 通知等收尾段全部移到 rc 之后。旧契约 rc 压在整段流程末尾，
# 实测被收尾段（autoclaw 签到+收割最慢）拖到 480s 上限才放行 —— OmniRoute 每轮
# 白等 ~8 分钟（run 41129523878 实锤，三轮 gateway 步骤 533/536/538s 恒定）。
# 本屏障的等待/降级语义不变：rc=0 视为就绪，非 0/缺席按渠道降级照常部署。
# 代价（已知并接受）：自检未跑完时 OmniRoute 即开始接入，个别渠道首请求可能
# 撞上未预热/自检失败的上游 —— 由 OmniRoute 自身 circuit breaker 兜底，
# 与「自检失败也照常部署」的旧降级路径同性质，只是时间点提前。
_up_names="workbuddy trae2api zcode2api qingyan autoclaw qoder2api"
_up_deadline=$(( $(date +%s) + 480 ))
while [ "$(date +%s)" -lt "$_up_deadline" ]; do
  _up_done=0
  for _u in $_up_names; do
    if [ -f "/tmp/upstream-rc-$_u" ]; then _up_done=$((_up_done+1)); fi
  done
  if [ "$_up_done" -eq 6 ]; then break; fi
  sleep 2
done
for _u in $_up_names; do
  if [ -f "/tmp/upstream-rc-$_u" ]; then
    _up_rc="$(cat "/tmp/upstream-rc-$_u")"
    if [ "$_up_rc" = "0" ]; then
      echo "✅ [P5b] 上游 $_u 就绪"
    else
      echo "⚠️ [P5b] 上游 $_u 退出码 $_up_rc（渠道降级，OmniRoute 照常部署）"
    fi
    tail -n 8 "/opt/logs/upstream-$_u.log" 2>/dev/null | sed 's/^/    │ /' || true
  else
    echo "⚠️ [P5b] 上游 $_u 未在 480s 内完成（照常部署，渠道可能降级）"
  fi
done

set -euo pipefail

# 2026-10-11 网关迁移：CliRelay（compose 全栈）/ CLIProxyAPI（回退）→ OmniRoute 单后端。
# 部署形态：/home/runner/omniroute（compose + .env 密钥）+ 命名卷 omniroute_omniroute-data
# （storage.sqlite：全部渠道/入站 key/combo；server.env：STORAGE_ENCRYPTION_KEY）。
# 灾备 = Dropbox OmniRoute.tar.gz 一起恢复这两样。旧链路归档的处置：
# CliRelay.tar.gz 由生产侧归档循环在备用容器存活期间继续刷新（备用网关口径），
# CLIProxyAPI.tar.gz 为历史快照不再刷新 —— DR workflow 均不再消费，仅作手动回滚素材。
# 本机渠道上游（workbuddy 8318 / zcode2api 8319 / qingyan 8320 / trae 7864）
# 由 extra_hosts host.docker.internal:host-gateway 回连。
echo "Configuring AI API gateway: requested backend = ${AI_BACKEND_INPUT:-auto} (port 20128)..."
mkdir -p /home/runner/omniroute ~/.openclaw/logs

BACKEND_STATE=/tmp/active-ai-backend.env
: > "$BACKEND_STATE"

OMNIROUTE_DIR=/home/runner/omniroute
OMNIROUTE_TAR=/tmp/OmniRoute.tar.gz
OMNIROUTE_ARCHIVE="dropbox:self-hosted/OmniRoute.tar.gz"
OMNIROUTE_IMAGE="diegosouzapw/omniroute:3.8.51"
OMNIROUTE_VOLUME="omniroute_omniroute-data"
# 恢复路径观测标记：ARCHIVE_PRESENT=探测通过；ARCHIVE_SEEN=确认云端归档存在
# （bootstrap 告警判据——归档存在却没恢复成 = 数据事故，见 restore 失败分支）
OMNIROUTE_ARCHIVE_PRESENT=0
OMNIROUTE_ARCHIVE_SEEN=0

cleanup_archive_workdir() {
  rm -f /tmp/OmniRoute.tar.gz 2>/dev/null || true
  rm -rf /tmp/omniroute-restore 2>/dev/null || true
}
free_kb() { df -Pk "${1:-/tmp}" | awk 'NR==2 {print $4}'; }
require_free_kb() {
  local path="$1" min_kb="$2" label="$3"
  local avail
  avail=$(free_kb "$path")
  if [ "${avail:-0}" -lt "$min_kb" ]; then
    echo "❌ ${label}: insufficient free space at ${path}. available=${avail}KB required=${min_kb}KB" >&2
    exit 1
  fi
  echo "✅ ${label}: free space ok at ${path}. available=${avail}KB required=${min_kb}KB"
}

wait_api_ready() {
  local label="$1"
  local tries="${2:-120}"
  local code
  for i in $(seq 1 "$tries"); do
    code=$(curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:20128/healthz || true)
    if [ -n "$code" ] && [ "$code" -ge 100 ] && [ "$code" -lt 600 ]; then
      echo "✅ [$label] OmniRoute 已就绪 (HTTP ${code})"
      return 0
    fi
    echo "⏳ [$label] 等待中... ${i}/${tries}"
    sleep 2
  done
  return 1
}

fetch_via_prefetch() {
  # 2026-10-29（B2）：Prefetch 步骤 .part→mv→rc 协议的收货函数。
  # 用法: fetch_via_prefetch <Name> <dest>；命中 = 返回 0 且产物已 mv 到 dest。
  # 与后置 ZCode 恢复步骤的同名函数互为副本（分处不同 step 无法共享定义，
  # 改一处必须两处同改 —— 同 wb_stop_notify 的双份实现口径）。
  local name="$1" dest="$2" key pf_dir rc pid waited
  key="$(printf '%s' "$name" | tr 'A-Z' 'a-z')"
  pf_dir="/tmp/openclaw-prefetch"
  [ -f "$pf_dir/${key}-tar.pid" ] || return 1
  waited=0
  while [ ! -f "$pf_dir/${key}-tar.rc" ] && [ "$waited" -lt 600 ]; do
    pid="$(cat "$pf_dir/${key}-tar.pid" 2>/dev/null | tr -dc '0-9')"
    [ -n "$pid" ] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
    waited=$((waited + 2))
  done
  rc="$(cat "$pf_dir/${key}-tar.rc" 2>/dev/null || echo none)"
  if [ "$rc" = "0" ] && [ -s "$pf_dir/${name}.tar.gz" ]; then
    mv "$pf_dir/${name}.tar.gz" "$dest"
    rm -f "$pf_dir/${name}.tar.gz.part" "$pf_dir/${key}-tar.rc" "$pf_dir/${key}-tar.pid" 2>/dev/null || true
    echo "✅ ${name}.tar.gz prefetch 命中（等待 ${waited}s）"
    return 0
  fi
  rm -f "$pf_dir/${name}.tar.gz.part" 2>/dev/null || true
  echo "⚠️ ${name}.tar.gz prefetch 未命中（rc=${rc}），回落同步下载"
  return 1
}

# ---------- OmniRoute 部署目录 + 数据卷恢复（Dropbox 归档优先，缺失则 bootstrap） ----------
restore_omniroute_data() {
  if [ -f "$OMNIROUTE_DIR/docker-compose.yml" ] && [ -f "$OMNIROUTE_DIR/.env" ]; then
    echo "ℹ️ OmniRoute 部署目录已就绪，跳过恢复"
    return 0
  fi
  cleanup_archive_workdir
  require_free_kb /tmp $((2 * 1024 * 1024)) "OmniRoute restore preflight"
  # 探测重试 3 次再定性（与 ~/.openclaw 恢复 2026-10-02 加固同口径）：
  # rclone 瞬时失败被误判成"无归档"会静默 bootstrap 空库——比"恢复失败"更
  # 危险，它连 ARCHIVE_SEEN 标记都立不起来，告警都不会响。
  OMNIROUTE_ARCHIVE_PRESENT=0
  for _probe in 1 2 3; do
    if rclone ls "$OMNIROUTE_ARCHIVE" > /dev/null 2>&1; then
      OMNIROUTE_ARCHIVE_PRESENT=1
      break
    fi
    echo "⚠️ rclone ls 探测归档失败（第 ${_probe}/3 次），15s 后重试..."
    sleep 15
  done
  if [ "$OMNIROUTE_ARCHIVE_PRESENT" != "1" ]; then
    echo "ℹ️ 未找到 OmniRoute 归档，走全新 bootstrap"
    return 1
  fi
  OMNIROUTE_ARCHIVE_SEEN=1
  echo "📦 Found OmniRoute.tar.gz! Downloading and validating..."
  # 2026-10-29（B2）：OmniRoute.tar.gz 已在 Prefetch 后台预取，命中则 mv 收货；
  # 未命中/失败回落原同步下载，判据与语义不变。
  if ! fetch_via_prefetch OmniRoute "$OMNIROUTE_TAR"; then
    if ! rclone copyto "$OMNIROUTE_ARCHIVE" "$OMNIROUTE_TAR"; then
      echo "⚠️ OmniRoute.tar.gz 下载失败，走全新 bootstrap"
      cleanup_archive_workdir
      return 1
    fi
  fi
  local archive_kb actual_size
  archive_kb=$(du -sk "$OMNIROUTE_TAR" | awk '{print $1}')
  if [ -z "${archive_kb:-}" ] || [ "$archive_kb" -le 0 ]; then
    echo "❌ OmniRoute extract preflight: unable to calculate archive size" >&2
    exit 1
  fi
  echo "OmniRoute.tar.gz 大小: ${archive_kb}KB"
  require_free_kb /tmp $((archive_kb * 3 + 512 * 1024)) "OmniRoute extract preflight"
  local min_size=$((1024 * 1024))
  actual_size=$(stat -c%s "$OMNIROUTE_TAR" 2>/dev/null || echo 0)
  if [ "$actual_size" -lt "$min_size" ] || ! tar -tzf "$OMNIROUTE_TAR" >/dev/null 2>&1; then
    echo "⚠️ OmniRoute.tar.gz validation failed，走全新 bootstrap"
    cleanup_archive_workdir
    return 1
  fi
  rm -rf /tmp/omniroute-restore
  mkdir -p /tmp/omniroute-restore
  tar -xzf "$OMNIROUTE_TAR" -C /tmp/omniroute-restore
  # cleanup_archive_workdir 会 rm -rf /tmp/omniroute-restore，
  # 必须等数据卷恢复消费完 data.tar.gz 之后才能调用，不能放在检查前
  if [ ! -f /tmp/omniroute-restore/docker-compose.yml ] || [ ! -f /tmp/omniroute-restore/.env ]; then
    echo "⚠️ OmniRoute.tar.gz 缺少 docker-compose.yml/.env，走全新 bootstrap"
    cleanup_archive_workdir
    return 1
  fi
  mkdir -p "$OMNIROUTE_DIR"
  cp -a /tmp/omniroute-restore/docker-compose.yml /tmp/omniroute-restore/.env "$OMNIROUTE_DIR/"
  chmod 600 "$OMNIROUTE_DIR/.env"
  # 数据卷恢复：归档内 data.tar.gz → docker 卷。server.env（STORAGE_ENCRYPTION_KEY）
  # 与 storage.sqlite 必须同代，否则存量 key 解不开 —— 二者同一份归档，天然同代。
  # storage-backup.sqlite（归档侧 sqlite 在线一致性备份）优先于活库三件套。
  if [ -f /tmp/omniroute-restore/data.tar.gz ]; then
    docker volume create "$OMNIROUTE_VOLUME" >/dev/null
    docker run --rm --user root -v "$OMNIROUTE_VOLUME:/target" -v /tmp/omniroute-restore:/src:ro \
      "$OMNIROUTE_IMAGE" sh -c '
        tar xzf /src/data.tar.gz -C /target
        if [ -f /target/storage-backup.sqlite ]; then
          mv -f /target/storage-backup.sqlite /target/storage.sqlite
          rm -f /target/storage.sqlite-wal /target/storage.sqlite-shm
        fi
        find /target -name "._*" -delete 2>/dev/null || true
        chown -R 1000:1000 /target'
    echo "✅ OmniRoute 数据卷已恢复"
  else
    echo "⚠️ 归档内无 data.tar.gz（纯部署目录），数据卷留空"
  fi
  echo "=== restored OmniRoute tree ==="
  find "$OMNIROUTE_DIR" -maxdepth 2 | sort || true
  cleanup_archive_workdir
  return 0
}

# ---------- 全新 bootstrap（无归档时）：生成 compose + 随机密钥，空库起服 ----------
# 空库 = 无渠道无入站 key，客户端会 401 —— 仅用于首次冷启动兜底；首轮 Final
# Archive 会把这份空库打包上传，之后每次重建都走归档恢复路径。
# compose 内容经 sed 剥掉 run-block 的 10 空格缩进后再落盘（heredoc 无法用 <<- 剥空格）；
# 2026-10-30 外置后 heredoc 天然顶格，sed 成为无害 no-op（保留防口径漂移）。
bootstrap_omniroute() {
  echo "🔄 Bootstrapping fresh OmniRoute deployment..."
  mkdir -p "$OMNIROUTE_DIR"
  cat <<'OMNIROUTE_COMPOSE_EOF' | sed 's/^          //' > "$OMNIROUTE_DIR/docker-compose.yml"
services:
  omniroute:
    image: diegosouzapw/omniroute:3.8.51
    container_name: omniroute
    restart: unless-stopped
    stop_grace_period: 40s
    ports:
      - "127.0.0.1:20128:20128"
    env_file: .env
    environment:
      PORT: 20128
      OMNIROUTE_MEMORY_MB: "4096"
      BASE_URL: http://omniroute:20128
      AUTH_COOKIE_SECURE: "false"
      # 上下文窗口自动校正（auto:discovery）周期：24h 扫描上游同步缓存，
      # 上游 /v1/models 报窗口（context_length 等字段）→ 自动写 auto override；
      # model_context_overrides 里的 manual 行永不覆盖（跳过）。设 0 可关闭。
      CONTEXT_WINDOW_RECONCILE_INTERVAL: "86400"
      # ---- 长上下文容忍度（2026-10-12，按实测调；与 CliRelay 时代同口径）----
      # runner-autoclaw 承接 40 万 token 级上下文：上游实测 96 万字符
      # 请求 61s、常规长请求 25~27s。默认首事件 readiness 80s + provider
      # 失败计数（DEGRADED=7 / OPEN=15）会把「慢」判成「坏」，OmniRoute
      # 侧刷屏 "[503] circuit breaker is open (reset after 7s/11s)"。
      # 数值全部按实测延迟量级给，不拍脑袋。
      # ---- 慢透传容差（2026-10-12 二次调，见 docs/openclaw.md）----
      # direct response-start 的 30s 闸比 SSE readiness 更前置：workbuddy
      # (8318) 长上下文实测 24~85s 才出响应头，11 次 30s 超时靠重试救回，
      # 却全计入 provider 失败计数并沿 combo 传染 autoclaw 熔断。
      # 总口径对齐 CliRelay main-api-read-timeout-seconds=1800
      # 与官方推荐 "Long-running code generation: REQUEST_TIMEOUT_MS=900000"
      REQUEST_TIMEOUT_MS: "1800000"
      OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS: "150000"
      OMNIROUTE_DIRECT_RESPONSE_RETRY_TIMEOUT_MS: "600000"
      STREAM_READINESS_TIMEOUT_MS: "600000"
      STREAM_READINESS_MAX_TIMEOUT_MS: "900000"
      OMNIROUTE_AGENT_GOAL_READINESS_MAX_TIMEOUT_MS: "900000"
      # 流式总寿命：镜像默认 1260000（21min）短于 CliRelay 1800s，长任务会在
      # 第 21 分钟被砍 → 显式设 1800s 对齐（0=禁用，这里不用）。
      STREAM_ACTIVE_TIMEOUT_MS: "1800000"
      FETCH_TIMEOUT_MS: "1800000"
      STREAM_IDLE_TIMEOUT_MS: "1800000"
      # API-key provider 熔断（autoclaw / zcode2api 均属此类）
      OMNIROUTE_CIRCUIT_BREAKER_API_KEY_THRESHOLD: "30"
      OMNIROUTE_CIRCUIT_BREAKER_API_KEY_RESET_MS: "60000"
      OMNIROUTE_PROVIDER_BREAKER_API_KEY_FAILURE_THRESHOLD: "60"
      OMNIROUTE_PROVIDER_BREAKER_API_KEY_DEGRADATION_THRESHOLD: "20"
      OMNIROUTE_PROVIDER_BREAKER_API_KEY_COOLDOWN_MS: "180000"
      OMNIROUTE_PROVIDER_BREAKER_API_KEY_MAX_BACKOFF_MULTIPLIER: "2"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - omniroute-data:/app/data
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:20128/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 60s
      timeout: 15s
      start_period: 120s
      retries: 5
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"

volumes:
  omniroute-data:
OMNIROUTE_COMPOSE_EOF
  if [ ! -f "$OMNIROUTE_DIR/.env" ]; then
    {
      printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)"
      printf 'API_KEY_SECRET=%s\n' "$(openssl rand -hex 32)"
      printf 'INITIAL_PASSWORD=%s\n' "$(openssl rand -base64 18 | tr '+/' '-_' | tr -d '=')"
    } > "$OMNIROUTE_DIR/.env"
  fi
  chmod 600 "$OMNIROUTE_DIR/.env"
  echo "✅ OmniRoute 部署目录就绪: $OMNIROUTE_DIR（bootstrap 空库，无渠道/无入站 key）"
}

# ===== 回退后端（2026-10-11 恢复自动降级）：CliRelay 全栈 + CLIProxyAPI 单容器 =====
# 从 dcf418e 迁移提交的父版本移植，改动仅两点：
#   ① 端口统一：官方 compose "8317:8317" → 降级路径 docker run 侧 -p 20128:8317
#     （容器内仍 8317，凭据/配置零改动）；健康检查探测 20128。
#   ② 函数化保持旧语义：归档恢复优先，无效则 bootstrap。
CLIRELAY_DIR=/tmp/local_CliRelay
CLIRELAY_TAR=/tmp/CliRelay.tar.gz
CLIRELAY_ARCHIVE="dropbox:self-hosted/CliRelay.tar.gz"
COMPOSE="docker compose -p clirelay -f $CLIRELAY_DIR/docker-compose.yml --project-directory $CLIRELAY_DIR"

# CliRelay/CLIProxyAPI 服务 8317（容器内），宿主侧统一映射 20128：
# 健康检查与 OmniRoute 同一探测点，降级后客户端/隧道零改动
wait_clirelay_ready() {
  local label="$1"
  local tries="${2:-120}"
  local code
  for i in $(seq 1 "$tries"); do
    code=$(curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:20128/ || true)
    if [ -n "$code" ] && [ "$code" -ge 100 ] && [ "$code" -lt 600 ]; then
      echo "✅ [$label] 20128 已就绪 (HTTP ${code})"
      return 0
    fi
    echo "⏳ [$label] 等待中... ${i}/${tries}"
    sleep 2
  done
  return 1
}

# ---------- CLIProxyAPI 数据恢复（旧逻辑原样移植，幂等；回退与 bootstrap 共用） ----------
restore_cliproxyapi_data() {
  if [ -f /tmp/local_CLIPProxyAPI/config.yaml ]; then
    echo "ℹ️ CLIProxyAPI 数据目录已就绪，跳过恢复"
    return 0
  fi
  echo "Configuring local CLIProxyAPI directory with persistent data..."
  cleanup_archive_workdir
  require_free_kb /tmp $((2 * 1024 * 1024)) "CLIProxyAPI restore preflight"
  rm -rf /tmp/local_CLIPProxyAPI
  mkdir -p /tmp/local_CLIPProxyAPI
  if rclone ls dropbox:self-hosted/CLIProxyAPI.tar.gz > /dev/null 2>&1; then
    echo "📦 Found CLIProxyAPI.tar.gz! Downloading and extracting..."
    rclone copyto dropbox:self-hosted/CLIProxyAPI.tar.gz /tmp/CLIProxyAPI.tar.gz
    archive_kb=$(du -sk /tmp/CLIProxyAPI.tar.gz | awk '{print $1}')
    if [ -z "${archive_kb:-}" ] || [ "$archive_kb" -le 0 ]; then
      echo "❌ CLIProxyAPI extract preflight: unable to calculate archive size" >&2
      exit 1
    fi
    echo "CLIProxyAPI.tar.gz 大小: ${archive_kb}KB"
    require_free_kb /tmp $((archive_kb * 3 + 512 * 1024)) "CLIProxyAPI extract preflight"
    local min_size=$((5 * 1024))
    local actual_size
    actual_size=$(stat -c%s /tmp/CLIProxyAPI.tar.gz 2>/dev/null || echo 0)
    if [ "$actual_size" -ge "$min_size" ] && tar -tzf /tmp/CLIProxyAPI.tar.gz >/dev/null 2>&1; then
      tar -xzf /tmp/CLIProxyAPI.tar.gz -C /tmp/local_CLIPProxyAPI
    else
      echo "⚠️ CLIProxyAPI.tar.gz validation failed, skipping archive restore."
    fi
    cleanup_archive_workdir
  else
    echo "⚠️ No CLIProxyAPI archive found. Falling back to sync from raw directory..."
    rclone copy dropbox:self-hosted/CLIProxyAPI /tmp/local_CLIPProxyAPI \
      --retries 10 \
      --low-level-retries 20 \
      --timeout 1m \
      --contimeout 15s \
      -P || true
  fi
  mkdir -p /tmp/local_CLIPProxyAPI/auth-dir /tmp/local_CLIPProxyAPI/logs
  touch /tmp/local_CLIPProxyAPI/config.yaml
  touch /tmp/local_CLIPProxyAPI/stats.json
  echo "=== restored CLIProxyAPI tree ==="
  find /tmp/local_CLIPProxyAPI -maxdepth 3 | sort || true
}

# ---------- CLIProxyAPI 数据 → CliRelay 部署目录（bootstrap 迁移，旧逻辑原样移植） ----------
bootstrap_clirelay_from_cliproxyapi() {
  echo "🔄 Bootstrapping CliRelay deployment from CLIProxyAPI data..."
  rm -rf "$CLIRELAY_DIR"
  mkdir -p "$CLIRELAY_DIR"/auths "$CLIRELAY_DIR"/sql "$CLIRELAY_DIR"/postgres-data "$CLIRELAY_DIR"/redis-data "$CLIRELAY_DIR"/logs "$CLIRELAY_DIR"/data
  if [ -f /tmp/local_CLIPProxyAPI/config.yaml ]; then
    cp -a /tmp/local_CLIPProxyAPI/config.yaml "$CLIRELAY_DIR/config.yaml"
  else
    touch "$CLIRELAY_DIR/config.yaml"
  fi
  if [ -d /tmp/local_CLIPProxyAPI/auth-dir ]; then
    cp -a /tmp/local_CLIPProxyAPI/auth-dir/. "$CLIRELAY_DIR/auths/" 2>/dev/null || true
  fi
  find "$CLIRELAY_DIR/auths" -name '._*' -delete 2>/dev/null || true
  curl -fsSL --retry 3 https://raw.githubusercontent.com/kittors/CliRelay/main/docker-compose.yml \
    -o "$CLIRELAY_DIR/docker-compose.yml" || { echo "❌ 无法下载 CliRelay docker-compose.yml"; return 1; }
  local pgpass
  pgpass=$(openssl rand -hex 16)
  {
    printf 'CLIRELAY_PROJECT_DIR=%s\n' "$CLIRELAY_DIR"
    printf 'AUTH_PATH=/root/.cli-proxy-api\n'
    printf 'CLIRELAY_POSTGRES_DB=clirelay\n'
    printf 'CLIRELAY_POSTGRES_USER=clirelay\n'
    printf 'CLIRELAY_POSTGRES_PASSWORD=%s\n' "$pgpass"
  } > "$CLIRELAY_DIR/.env"
  chmod 600 "$CLIRELAY_DIR/.env"
  echo "✅ CliRelay 部署目录就绪: $CLIRELAY_DIR"
}

# ---------- CliRelay 数据恢复：Dropbox 归档优先，无效则 bootstrap 迁移（旧逻辑原样移植） ----------
restore_clirelay_data() {
  rm -rf "$CLIRELAY_DIR"
  local restored=0
  if rclone ls "$CLIRELAY_ARCHIVE" > /dev/null 2>&1; then
    echo "📦 Found CliRelay.tar.gz! Downloading and validating..."
    require_free_kb /tmp $((2 * 1024 * 1024)) "clirelay restore preflight"
    if rclone copyto "$CLIRELAY_ARCHIVE" "$CLIRELAY_TAR"; then
      if [ -s "$CLIRELAY_TAR" ] && tar -tzf "$CLIRELAY_TAR" >/dev/null 2>&1; then
        rm -rf /tmp/clirelay-restore
        mkdir -p /tmp/clirelay-restore
        tar -xzf "$CLIRELAY_TAR" -C /tmp/clirelay-restore
        if [ -f /tmp/clirelay-restore/docker-compose.yml ] && [ -f /tmp/clirelay-restore/.env ]; then
          mkdir -p "$CLIRELAY_DIR"
          cp -a /tmp/clirelay-restore/. "$CLIRELAY_DIR/"
          mkdir -p "$CLIRELAY_DIR"/auths "$CLIRELAY_DIR"/sql "$CLIRELAY_DIR"/postgres-data "$CLIRELAY_DIR"/redis-data "$CLIRELAY_DIR"/logs "$CLIRELAY_DIR"/data
          echo "✅ Restored CliRelay deployment from archive"
          restored=1
        else
          echo "⚠️ CliRelay.tar.gz 缺少 docker-compose.yml/.env，转 bootstrap 迁移。"
        fi
      else
        echo "⚠️ CliRelay.tar.gz validation failed, 转 bootstrap 迁移。"
      fi
    else
      echo "⚠️ CliRelay.tar.gz 下载失败，转 bootstrap 迁移。"
    fi
  else
    echo "ℹ️ 未找到 CliRelay 归档，从 CLIProxyAPI 数据 bootstrap 迁移。"
  fi
  cleanup_archive_workdir
  if [ "$restored" != 1 ]; then
    restore_cliproxyapi_data
    bootstrap_clirelay_from_cliproxyapi
  fi
}

# ---------- CliRelay 全栈启动：postgres 先行 → SQL 导入 → 全栈 up（旧逻辑移植 + 统一端口） ----------
start_clirelay() {
  echo "🚀 Starting CliRelay compose stack..."
  docker rm -f cli-proxy-api clirelay 2>/dev/null || true
  # CliRelay 路径若残留上一轮 socat/端口桥接，先拆
  sudo pkill -f 'socat.*TCP-LISTEN:20128' 2>/dev/null || true
  $COMPOSE down --remove-orphans 2>/dev/null || true
  # 统一端口 override：官方 compose 绑 8317:8317（0.0.0.0），覆盖为宿主
  # 127.0.0.1:20128 → 容器 8317。与 OmniRoute 同宿主端口，降级后客户端/隧道零改动；
  # override 独立成文件不碰云端归档恢复来的 compose 原件。
  printf '%s\n' \
    'services:' \
    '  cli-proxy-api:' \
    '    ports: !override' \
    '      - "127.0.0.1:20128:8317"' \
    '      - "127.0.0.1:8085:8085"' \
    '      - "127.0.0.1:1455:1455"' \
    '      - "127.0.0.1:54545:54545"' \
    '      - "127.0.0.1:51121:51121"' \
    '      - "127.0.0.1:11451:11451"' \
    > "$CLIRELAY_DIR/docker-compose.port-override.yml"
  $COMPOSE -f "$CLIRELAY_DIR/docker-compose.yml" -f "$CLIRELAY_DIR/docker-compose.port-override.yml" up -d postgres || return 1
  local pg_ok=0
  for i in $(seq 1 30); do
    if $COMPOSE exec -T postgres sh -c '. /clirelay-deploy/.env; pg_isready -U "$CLIRELAY_POSTGRES_USER" -d "$CLIRELAY_POSTGRES_DB"' >/dev/null 2>&1; then
      pg_ok=1
      break
    fi
    sleep 2
  done
  if [ "$pg_ok" != 1 ]; then
    echo "❌ CliRelay postgres 未在预期时间内就绪"
    return 1
  fi
  # 恢复脚本：先导 SQL 再起全栈（PG 数据卷不入归档，每轮均为全新库，直接导入无冲突）
  shopt -s nullglob
  local sql_files=( "$CLIRELAY_DIR"/sql/*.sql )
  shopt -u nullglob
  if [ "${#sql_files[@]}" -gt 0 ]; then
    local latest_sql
    latest_sql=$(ls -1t "${sql_files[@]}" | head -n 1)
    echo "📥 Importing PostgreSQL snapshot: $latest_sql"
    $COMPOSE exec -T postgres sh -c '. /clirelay-deploy/.env; exec psql -U "$CLIRELAY_POSTGRES_USER" -d "$CLIRELAY_POSTGRES_DB" -v ON_ERROR_STOP=1' < "$latest_sql" || return 1
    echo "✅ PostgreSQL 数据导入完成"
  fi
  $COMPOSE -f "$CLIRELAY_DIR/docker-compose.yml" -f "$CLIRELAY_DIR/docker-compose.port-override.yml" up -d || return 1
}

# ---------- CLIProxyAPI 单容器启动（回退后端；端口改绑 20128→容器 8317） ----------
start_cliproxyapi() {
  echo "🚀 Starting CLIProxyAPI container (fallback backend)..."
  docker rm -f cliproxyapi cli-proxy-api clirelay 2>/dev/null || true
  # CliRelay 路径残留的 socat 会抢 20128，先拆
  sudo pkill -f 'socat.*TCP-LISTEN:20128' 2>/dev/null || true
  mkdir -p /tmp/local_CLIPProxyAPI/auth-dir /tmp/local_CLIPProxyAPI/logs
  touch /tmp/local_CLIPProxyAPI/config.yaml
  touch /tmp/local_CLIPProxyAPI/stats.json
  # ① 容器原生即 8317，宿主侧直接绑 20128（与 OmniRoute 同端口，客户端/隧道零改动）
  # ② 官方 compose 的 clirelay-init 会写 config，这里数据是归档/旧目录恢复的，直接挂
  docker run -d \
    --name cliproxyapi \
    --restart unless-stopped \
    -p 127.0.0.1:20128:8317 \
    -e TZ=Asia/Shanghai \
    -v /tmp/local_CLIPProxyAPI/config.yaml:/CLIProxyAPI/config.yaml \
    -v /tmp/local_CLIPProxyAPI/auth-dir:/root/.cli-proxy-api \
    -v /tmp/local_CLIPProxyAPI/logs:/CLIProxyAPI/logs \
    -v /tmp/local_CLIPProxyAPI/stats.json:/CLIProxyAPI/stats.json \
    eceasy/cli-proxy-api:latest || return 1
}

# ---------- 启动：恢复路径走 compose（卷已由 compose 声明复用），bootstrap 路径走 docker run ----------

start_omniroute() {
  echo "🚀 Starting OmniRoute container..."
  docker rm -f omniroute 2>/dev/null || true
  docker volume create "$OMNIROUTE_VOLUME" >/dev/null
  if [ -f "$OMNIROUTE_DIR/docker-compose.yml" ]; then
    docker compose -p omniroute -f "$OMNIROUTE_DIR/docker-compose.yml" --project-directory "$OMNIROUTE_DIR" up -d || return 1
  else
    # bootstrap 路径同样要带长上下文阈值 —— 与上方 compose heredoc
    # （restore 路径）保持同值，否则归档缺失的冷启动会被默认
    # readiness 80s + provider 失败计数 7/15 又快快打成熔断。
    # 阈值依据见 compose heredoc 处的注释块（2026-10-12 实测调参）。
    docker run -d \
      --name omniroute \
      --restart unless-stopped \
      --stop-timeout 40 \
      -p 127.0.0.1:20128:20128 \
      -e PORT=20128 \
      -e OMNIROUTE_MEMORY_MB=4096 \
      -e BASE_URL=http://omniroute:20128 \
      -e AUTH_COOKIE_SECURE=false \
      -e REQUEST_TIMEOUT_MS=1800000 \
      -e OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS=150000 \
      -e OMNIROUTE_DIRECT_RESPONSE_RETRY_TIMEOUT_MS=600000 \
      -e STREAM_READINESS_TIMEOUT_MS=600000 \
      -e STREAM_READINESS_MAX_TIMEOUT_MS=900000 \
      -e OMNIROUTE_AGENT_GOAL_READINESS_MAX_TIMEOUT_MS=900000 \
      -e STREAM_ACTIVE_TIMEOUT_MS=1800000 \
      -e FETCH_TIMEOUT_MS=1800000 \
      -e STREAM_IDLE_TIMEOUT_MS=1800000 \
      -e OMNIROUTE_CIRCUIT_BREAKER_API_KEY_THRESHOLD=30 \
      -e OMNIROUTE_CIRCUIT_BREAKER_API_KEY_RESET_MS=60000 \
      -e OMNIROUTE_PROVIDER_BREAKER_API_KEY_FAILURE_THRESHOLD=60 \
      -e OMNIROUTE_PROVIDER_BREAKER_API_KEY_DEGRADATION_THRESHOLD=20 \
      -e OMNIROUTE_PROVIDER_BREAKER_API_KEY_COOLDOWN_MS=180000 \
      -e OMNIROUTE_PROVIDER_BREAKER_API_KEY_MAX_BACKOFF_MULTIPLIER=2 \
      --add-host host.docker.internal:host-gateway \
      -v "$OMNIROUTE_VOLUME:/app/data" \
      --env-file "$OMNIROUTE_DIR/.env" \
      "$OMNIROUTE_IMAGE" || return 1
  fi
}

cleanup_archive_workdir
# 数据准备失败不终止（bootstrap 全新部署兜底，与旧 CliRelay 同口径）
if ! restore_omniroute_data; then
  bootstrap_omniroute
  # P0 加固（2026-10-11）：归档明明存在却没恢复成 = 数据事故信号，必须炸响。
  # 当天事故即此形态：cleanup 误删解包目录 → 恒报"缺少 docker-compose.yml/.env"
  # → 静默 bootstrap 空库上岗，全靠归档脚本 1MB 体积门才没让空库覆盖云端好包。
  if [ "$OMNIROUTE_ARCHIVE_SEEN" = "1" ]; then
    if source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh" 2>/dev/null; then
      msg=""
      tg_add_title msg "🚨 OmniRoute 归档恢复失败 · 空库兜底"
      tg_add_kv msg "现象" "Dropbox 归档存在，但本轮恢复未走通，已 bootstrap 空库"
      tg_add_kv msg "影响" "无渠道/无入站 key，客户端 401；1MB 体积门将拦住空库回传"
      tg_add_note msg "根因看本轮日志 OmniRoute 步骤 Found OmniRoute.tar.gz 之后的段"
      tg_add_footer msg
      send_tg "$msg" alert || true
    fi
  fi
fi

# ---------- 主流程：三后端降级链 OmniRoute → CliRelay → CLIProxyAPI（2026-10-11 恢复自动降级） ----------
# 统一端口方案：三个后端全部服务在宿主机 127.0.0.1:20128 —— OpenClaw 客户端
# （openclaw.json，随主包归档持久化）硬编码指向 127.0.0.1:20128/v1，ai-api 隧道
# 也是固定地址模式指向 20128（tunnels.conf），因此降级不换端口、不改客户端、
# 不重建隧道。CliRelay/CLIProxyAPI 官方 compose/容器原生端口 8317，降级路径用
# docker run 侧端口映射改绑 20128，容器内仍是 8317，凭据/配置零改动。
# 降级链：主用 OmniRoute 起不来 → 回退 CliRelay 全栈（数据随 CliRelay.tar.gz 恢复）
# → CliRelay 也起不来 → 回退 CLIProxyAPI 单容器（数据随 CLIProxyAPI.tar.gz 恢复）。
# 每次降级记录 FALLBACK_REASON 写入 BACKEND_STATE，通知步骤自动向 Telegram 报告。
ACTIVE_BACKEND=""
FALLBACK_REASON=""
# pinned 模式：手动运行时显式指定后端 → 只跑它，失败即失败（不降级），
# 便于定点验证单个后端；auto（默认/定时触发）走完整降级链
PINNED_BACKEND="${AI_BACKEND_INPUT:-auto}"

if [ "$PINNED_BACKEND" = "omniroute" ]; then
  if start_omniroute && wait_api_ready "omniroute" 150; then
    ACTIVE_BACKEND=omniroute
    docker ps -a
    echo "✅ 当前生效 AI 网关: OmniRoute（pinned）"
  else
    echo "❌ OmniRoute（pinned）未就绪 —— pinned 模式不降级，直接失败"
    docker logs omniroute --tail 100 || true
    exit 1
  fi
elif [ "$PINNED_BACKEND" = "clirelay" ]; then
  restore_clirelay_data || true
  if start_clirelay && wait_clirelay_ready "clirelay" 120; then
    ACTIVE_BACKEND=clirelay
    docker ps -a
    echo "✅ 当前生效 AI 网关: CliRelay（pinned）"
  else
    echo "❌ CliRelay（pinned）未就绪 —— pinned 模式不降级，直接失败"
    $COMPOSE logs --tail 80 2>/dev/null || true
    exit 1
  fi
elif [ "$PINNED_BACKEND" = "cliproxyapi" ]; then
  restore_cliproxyapi_data
  if start_cliproxyapi && wait_clirelay_ready "cliproxyapi" 120; then
    ACTIVE_BACKEND=cliproxyapi
    docker ps -a
    echo "✅ 当前生效 AI 网关: CLIProxyAPI（pinned）"
  else
    echo "❌ CLIProxyAPI（pinned）未就绪 —— pinned 模式不降级，直接失败"
    docker logs cliproxyapi --tail 100 || true
    exit 1
  fi
elif start_omniroute && wait_api_ready "omniroute" 150; then
  ACTIVE_BACKEND=omniroute
  docker ps -a
  echo "✅ 当前生效 AI 网关: OmniRoute"
else
  if [ -z "${FALLBACK_REASON:-}" ]; then
    FALLBACK_REASON="OmniRoute 未能在预期时间内就绪 · compose 启动或 20128 健康检查失败"
  fi
  echo "⚠️ $FALLBACK_REASON，打印日志并回退 CliRelay..."
  echo "--- omniroute logs (tail 100) ---"
  docker logs omniroute --tail 100 || true
  docker rm -f omniroute 2>/dev/null || true

  restore_clirelay_data || {
    [ -z "${FALLBACK_REASON:-}" ] && FALLBACK_REASON="CliRelay 数据准备失败 · 归档缺失/校验失败或 bootstrap 迁移失败"
    echo "⚠️ CliRelay 数据准备失败，跳过 CliRelay 直接回退 CLIProxyAPI"
  }

  if [ -z "${ACTIVE_BACKEND:-}" ] && [ -f "$CLIRELAY_DIR/docker-compose.yml" ] \
    && start_clirelay && wait_clirelay_ready "clirelay" 120; then
    ACTIVE_BACKEND=clirelay
    docker ps -a
    echo "✅ 已回退，当前生效 AI 网关: CliRelay（全栈，20128 统一端口）"
  else
    [ -z "${ACTIVE_BACKEND:-}" ] && [ -z "${FALLBACK_REASON:-}" ] && \
      FALLBACK_REASON="CliRelay 未能在预期时间内就绪 · compose 启动或 20128 健康检查失败"
    echo "⚠️ CliRelay 也未就绪，打印日志并回退 CLIProxyAPI..."
    echo "--- clirelay compose logs (tail 80) ---"
    $COMPOSE logs --tail 80 2>/dev/null || true
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
    docker rm -f cli-proxy-api clirelay 2>/dev/null || true

    restore_cliproxyapi_data
    if start_cliproxyapi && wait_clirelay_ready "cliproxyapi" 120; then
      ACTIVE_BACKEND=cliproxyapi
      docker ps -a
      echo "✅ 已回退，当前生效 AI 网关: CLIProxyAPI（单容器，20128 统一端口）"
    else
      echo "❌ 三个后端全部未就绪（omniroute/clirelay/cliproxyapi）"
      docker logs cliproxyapi --tail 100 2>/dev/null || true
      exit 1
    fi
  fi
fi
{
  printf 'ACTIVE_BACKEND=%s\n' "$ACTIVE_BACKEND"
  if [ -n "${FALLBACK_REASON:-}" ]; then printf 'FALLBACK_REASON=%s\n' "$FALLBACK_REASON"; fi
} > "$BACKEND_STATE"

# Hand off to the systemd unit (Restart=always) instead of a bare
# nohup, so the tunnel survives signal sweeps and restarts itself.
if [ -f "$GITHUB_WORKSPACE/.github/scripts/tunnels/tunnels.sh" ]; then
  bash "$GITHUB_WORKSPACE/.github/scripts/tunnels/tunnels.sh" ensure ai-api || true
else
  nohup cloudflared tunnel run --protocol http2 --url http://127.0.0.1:20128 ai-api \
    > ~/.openclaw/logs/cloudflared_omniroute.log 2>&1 &
  sleep 5
  echo $! > ~/.openclaw/logs/cloudflared_omniroute.pid
fi

echo "ai-api 命名隧道已启动（systemd 托管，固定地址模式），当前后端: ${ACTIVE_BACKEND}"
