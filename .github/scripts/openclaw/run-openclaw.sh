#!/usr/bin/env bash
# openclaw 工作流「Run OpenClaw」步骤本体（2026-10-30 原样搬移自 yml，零逻辑改动）。
# 外置背景：workflow 文件 2026-10-29（f08b15f）起突破 GitHub workflow 500KB
#（=512,000 字节）上限，每轮 push 全部 "workflow file issue" 零 job 失败、
# schedule 停摆 —— 按 .github/scripts/services/ 同款模式给 yml 减重。
# 消费方：/tmp/run-openclaw-step.log（失败通知取摘要）、/tmp/run-openclaw-meta.env。
# yml 薄包装保留 id=run_openclaw 与 if 条件；脚本非零退出即步骤失败。

set -euo pipefail

RUN_OPENCLAW_STEP_LOG="/tmp/run-openclaw-step.log"
RUN_OPENCLAW_META="/tmp/run-openclaw-meta.env"
: > "$RUN_OPENCLAW_STEP_LOG"
: > "$RUN_OPENCLAW_META"
exec > >(tee -a "$RUN_OPENCLAW_STEP_LOG") 2>&1

CURRENT_OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | head -n 1 || true)"
CURRENT_OPENCLAW_SEMVER="$(printf '%s\n' "$CURRENT_OPENCLAW_VERSION" | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n 1 || true)"
KNOWN_GOOD_VERSION_FILE="$HOME/.openclaw/openclaw-known-good-version"
echo "CURRENT_OPENCLAW_VERSION=$CURRENT_OPENCLAW_VERSION" >> "$RUN_OPENCLAW_META"
echo "CURRENT_OPENCLAW_SEMVER=$CURRENT_OPENCLAW_SEMVER" >> "$RUN_OPENCLAW_META"
echo "FAIL_STAGE=preflight_doctor" >> "$RUN_OPENCLAW_META"
PREFLIGHT_BEGIN_TS=$(date +%s)

fail_startup() {
  local msg="$1"
  echo "❌ $msg"
  exit 1
}

normalize_openclaw_version() {
  printf '%s\n' "${1:-}" | tr -d '[:space:]' | grep -oE '^[0-9]{4}\.[0-9]+\.[0-9]+$' || true
}

read_openclaw_version_file() {
  local file="$1"
  if [ -s "$file" ]; then
    normalize_openclaw_version "$(head -n 1 "$file" 2>/dev/null || true)"
  fi
}

record_successful_openclaw_version() {
  local version="$1"
  version="$(normalize_openclaw_version "$version")"
  if [ -z "$version" ]; then
    echo "⚠️ Cannot record successful OpenClaw version: current version is empty or invalid."
    return 0
  fi
  mkdir -p "$HOME/.openclaw"
  printf '%s\n' "$version" > "$KNOWN_GOOD_VERSION_FILE"
  echo "RECORDED_SUCCESSFUL_OPENCLAW_VERSION=$version" >> "$RUN_OPENCLAW_META"
  echo "✅ Recorded successful OpenClaw version: $version"
}

resolve_fallback_openclaw_version() {
  local version=""

  version="$(read_openclaw_version_file "$KNOWN_GOOD_VERSION_FILE")"
  if [ -n "$version" ]; then
    echo "FALLBACK_VERSION_SOURCE=known_good_file" >> "$RUN_OPENCLAW_META"
    echo "$version"
    return 0
  fi

  if [ -s "$HOME/.openclaw/openclaw.json" ]; then
    version="$(jq -r '.meta.lastTouchedVersion // empty' "$HOME/.openclaw/openclaw.json" 2>/dev/null | head -n 1 || true)"
    version="$(normalize_openclaw_version "$version")"
    if [ -n "$version" ]; then
      echo "FALLBACK_VERSION_SOURCE=meta_lastTouchedVersion" >> "$RUN_OPENCLAW_META"
      echo "$version"
      return 0
    fi
  fi

  echo ""
  return 1
}

fix_openclaw_permissions() {
  echo "🔧 Fixing file permissions to pass security checks..."
  sudo chmod -R o-w "$(npm root -g)"
  chmod 700 ~/.openclaw
  if [ -f ~/.openclaw/openclaw.json ]; then
    chmod 600 ~/.openclaw/openclaw.json
  fi
}

openclaw_port_listening() {
  sudo lsof -Pi :18789 -sTCP:LISTEN -t >/dev/null
}

openclaw_log_ready() {
  journalctl --user -u openclaw-gateway.service --since "5 minutes ago" --no-pager 2>/dev/null \
    | grep -q "\[gateway\] ready"
}

openclaw_health_http_ok() {
  [ "$(curl -fsS -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 15 http://127.0.0.1:18789/health || true)" = "200" ]
}

wait_for_openclaw_health() {
  local label="$1"
  local timeout_sec="${2:-180}"
  local interval_sec="${3:-5}"
  local start_ts now_ts elapsed
  start_ts=$(date +%s)

  echo "Waiting for OpenClaw health (${label}, timeout=${timeout_sec}s)..."
  while true; do
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))

    if openclaw_port_listening; then
      if openclaw_health_http_ok; then
        echo "✅ OpenClaw Gateway health is OK after ${elapsed}s (${label})."
        return 0
      fi

      if openclaw_log_ready; then
        echo "⏳ Gateway is listening and logged ready, but /health is still slow after ${elapsed}s (${label}); continuing grace wait."
      else
        echo "⏳ Gateway port is listening, waiting for ready/health... ${elapsed}/${timeout_sec}s (${label})"
      fi
    else
      echo "⏳ Gateway port is not listening yet... ${elapsed}/${timeout_sec}s (${label})"
    fi

    if [ "$elapsed" -ge "$timeout_sec" ]; then
      echo "❌ OpenClaw Gateway health did not become OK within ${timeout_sec}s (${label})."
      return 1
    fi
    sleep "$interval_sec"
  done
}

dump_openclaw_diagnostics() {
  echo "⚠️ Gateway not healthy yet. Diagnostics:"
  echo "--- systemd status ---"
  systemctl --user --no-pager --full status openclaw-gateway.service || true
  echo "--- recent journal ---"
  journalctl --user -u openclaw-gateway.service --since "10 minutes ago" --no-pager | tail -n 120 || true
  echo "--- /tmp/openclaw logs ---"
  find /tmp/openclaw -maxdepth 1 -type f -name 'openclaw-*.log' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | head -2 \
    | cut -d' ' -f2- \
    | while IFS= read -r log_file; do
        echo "--- tail $log_file ---"
        tail -n 80 "$log_file" || true
      done
}

fix_openclaw_permissions

echo "FAIL_STAGE=config_validate" >> "$RUN_OPENCLAW_META"
echo "🧪 Preflight config validation for $CURRENT_OPENCLAW_VERSION ..."
CONFIG_VALID_FOR_CURRENT=0
DOCTOR_RAN=0
if openclaw config validate >/tmp/config-validate.log 2>&1; then
  CONFIG_VALID_FOR_CURRENT=1
  echo "✅ Config valid for current version."
else
  echo "⚠️ Config invalid for current version. Trying 'openclaw doctor --fix' to repair, then re-validating. Details:"
  tail -n 15 /tmp/config-validate.log 2>/dev/null || true
  echo "🛠️ Running 'openclaw doctor --fix' to repair the config..."
  DOCTOR_RAN=1
  openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
  if openclaw config validate >/tmp/config-validate-2.log 2>&1; then
    CONFIG_VALID_FOR_CURRENT=1
    echo "✅ Config repaired by doctor; now valid for current version."
  else
    echo "❌ Config still invalid after doctor. Gateway start will be skipped; fallback reinstall, downgrade guard and snapshot rollback handle recovery. Details:"
    tail -n 10 /tmp/config-validate-2.log 2>/dev/null || true
  fi
fi

if [ "$CONFIG_VALID_FOR_CURRENT" = "1" ] && [ "$DOCTOR_RAN" != "1" ]; then
  # 优化（2026-10-02）：config 已校验通过时，preflight doctor 只在 OpenClaw
  # **版本变化**时才跑。实测该步固定耗时 79s，而配置合法时 doctor 并无
  # 修复动作（日志仅 warnings + registry 刷新 + agent-db 完整性检查）。
  # 版本未变 ⇒ 跳过（省 79s）；版本一变 ⇒ 照跑，保住升级时的自愈。
  # 状态文件放在 ~/.openclaw 内：它随主包归档/恢复，上轮记录得以延续。
  # 版本解析失败时（CURRENT_OPENCLAW_SEMVER 为空）一律照跑 —— 保守。
  DOCTOR_STATE_FILE="$HOME/.openclaw/openclaw-doctor-last-version"
  LAST_DOCTOR_VERSION="$(head -n 1 "$DOCTOR_STATE_FILE" 2>/dev/null || true)"
  if [ -n "$CURRENT_OPENCLAW_SEMVER" ] && [ "$LAST_DOCTOR_VERSION" = "$CURRENT_OPENCLAW_SEMVER" ]; then
    echo "⏭️ Skipping preflight doctor: config valid & version unchanged (${CURRENT_OPENCLAW_SEMVER})"
  else
    echo "🛠️ Running preflight 'openclaw doctor --fix' before gateway restart... (${LAST_DOCTOR_VERSION:-none} → ${CURRENT_OPENCLAW_SEMVER})"
    openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
    mkdir -p "$HOME/.openclaw"
    printf '%s\n' "$CURRENT_OPENCLAW_SEMVER" > "$DOCTOR_STATE_FILE"
  fi
fi
PREFLIGHT_END_TS=$(date +%s)
echo "PREFLIGHT_DOCTOR_DURATION_SEC=$((PREFLIGHT_END_TS - PREFLIGHT_BEGIN_TS))" >> "$RUN_OPENCLAW_META"

echo "FAIL_STAGE=initial_start" >> "$RUN_OPENCLAW_META"
INITIAL_START_BEGIN_TS=$(date +%s)
echo "Restarting OpenClaw gateway..."

# 2026-10-22 冷启动优化（run 39637798065 日志实证）：unit 由 CLI 生成时带
# TimeoutStopSec=330，而 `gateway install --force` 已经把服务拉起来了；
# 紧接着再 `gateway restart` 会走一遍完整 stop→start —— 首启进程还在 boot、
# 不响应 SIGTERM，systemd 就陪它等到 330s 才 SIGKILL。日志里
# 16:59:47 "Gateway service installed" → 17:05:23 "Restarted systemd service"
# 的 336s 静默正是它（冷启动根本没有「旧进程」要停）。
# 对策两层：① drop-in 保持 openclaw 要求的 TimeoutStopSec=330（install 重写主
#    unit 不影响 .d 覆盖）；② 冷启动不再调 CLI restart：install 已拉起就直接等
#    健康，unit 未激活才显式 start。② 生效后冷启动不会再出现 330s 的 stop 等待。
GW_UNIT="openclaw-gateway.service"
GW_DROPIN_DIR="$HOME/.config/systemd/user/${GW_UNIT}.d"
# 2026-10-22 修复（run 5507 日志+本机复现实证）：drop-in 必须在 install
# **之后**落盘。install 的发布事务会快照受管工件（unit/generated/service.d
# 系目录）并在发布间隙做严格指纹比对（systemd-definition-mutation:248），
# 事务开始前已存在的 drop-in 目录会被判「工件被外部改动」→ 中止 + 回滚
# 删 unit，该机后续 install 全部连带失败。EE6A3D5 起的正确顺序是 install
# 成功后再补 drop-in（TimeoutStopSec 对下一次 stop 依然生效，无损失）。
# 防御：若上一轮残留了 drop-in（如 10-22 失败轮），先摘除再装；
# 装完后由 apply_gw_dropin 统一重写（不依赖旧目录）。
GW_DROPIN_BACKUP=""
if [ -d "$GW_DROPIN_DIR" ]; then
  GW_DROPIN_BACKUP="${GW_DROPIN_DIR}.pre-install.$$.$(date +%s%N)"
  mv "$GW_DROPIN_DIR" "$GW_DROPIN_BACKUP" 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
fi

# install 成功后落盘 drop-in：目录 755 / 文件 644（install 的安全门会拒绝
# group/world-writable 的定义文件 —— run 5507 当晚本机复现的第二道坎）。
# 先回放上方摘除时侧移的运营者 drop-in（memory.conf / 20-*.conf 等），再写
# 托管项，避免每轮供应把运营者覆盖清空。
apply_gw_dropin() {
  mkdir -p "$GW_DROPIN_DIR"
  chmod 755 "$GW_DROPIN_DIR"
  if [ -n "${GW_DROPIN_BACKUP:-}" ] && [ -d "$GW_DROPIN_BACKUP" ]; then
    for _f in "$GW_DROPIN_BACKUP"/*.conf; do
      [ -e "$_f" ] || continue
      if [ "$(basename "$_f")" = "10-stop-timeout.conf" ]; then
        continue
      fi
      cp -p "$_f" "$GW_DROPIN_DIR/" 2>/dev/null || true
    done
    rm -rf "$GW_DROPIN_BACKUP"
  fi
  # L4 内存护栏（2026-10-21 16:50 事故 10G peak）：仅在缺失时创建，
  # 已存在的运营者配置由上方回放保留，不覆盖。
  if [ ! -f "$GW_DROPIN_DIR/memory.conf" ]; then
    cat > "$GW_DROPIN_DIR/memory.conf" <<'EOF_MEM'
[Service]
MemoryHigh=9G
MemoryMax=11G
EOF_MEM
    chmod 644 "$GW_DROPIN_DIR/memory.conf"
  fi
  GW_NODE_BIN_DIR="$(dirname "$(command -v node 2>/dev/null || echo /usr/bin/node)")"
  GW_SERVICE_PATH="$HOME/.bun/bin:$GW_NODE_BIN_DIR:/usr/local/bin:/usr/bin:/bin:$HOME/.nvm/current/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/bin:$HOME/.nix-profile/bin"
  cat > "$GW_DROPIN_DIR/10-stop-timeout.conf" <<EOF_STOP
[Service]
Environment=PATH=$GW_SERVICE_PATH
TimeoutStopSec=330
EOF_STOP
  chmod 644 "$GW_DROPIN_DIR/10-stop-timeout.conf"
  rm -rf "${GW_DROPIN_DIR}".pre-install.* 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
}

# 2026-10-24: install 生成 unit 时按目录是否存在决定是否收录 ~/.bun/bin
# （version-manager 黑名单不含 bun）。先建目录，让首启进程的 PATH 就包含 bun；
# bun 本体由后续 zcode2api 步骤装进同一目录，PATH 在 spawn 时查找。
mkdir -p "$HOME/.bun/bin"
INITIAL_START_RESTART_OK=1
if [ "$CONFIG_VALID_FOR_CURRENT" != "1" ]; then
  echo "⚠️ Skipping gateway start: config still invalid after doctor. Going straight to fallback reinstall with the recorded compatible version."
  INITIAL_START_RESTART_OK=0
elif ! openclaw gateway install --force; then
  echo "⚠️ Initial gateway install failed; will attempt fallback reinstall."
  INITIAL_START_RESTART_OK=0
else
  if [ "$(systemctl --user is-active "$GW_UNIT" 2>/dev/null || echo inactive)" = "active" ]; then
    echo "⏭️ unit 已由 install --force 拉起，跳过 gateway restart，直接等健康（冷启动快路径）"
  else
    echo "ℹ️ unit 未激活，systemctl --user start 拉起（不走 CLI restart）"
    systemctl --user reset-failed "$GW_UNIT" 2>/dev/null || true
    systemctl --user start "$GW_UNIT" 2>/dev/null || echo "⚠️ systemctl start 返回非零，交给健康检查判定"
  fi
  # drop-in 在 install 之后落盘（原因见上）：此刻 unit 已在盘上、服务已拉起，
  # 等健康前补齐 PATH 与 TimeoutStopSec=330（对下一次 stop 生效）
  apply_gw_dropin
  echo "COLD_START_SKIP_RESTART=1" >> "$RUN_OPENCLAW_META"
fi

if [ "$INITIAL_START_RESTART_OK" = "1" ] && wait_for_openclaw_health "initial_start" 180 5; then
    INITIAL_START_END_TS=$(date +%s)
    echo "INITIAL_START_DURATION_SEC=$((INITIAL_START_END_TS - INITIAL_START_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
    record_successful_openclaw_version "$CURRENT_OPENCLAW_SEMVER"
    echo "✅ OpenClaw Gateway is healthy!"
else
    INITIAL_START_END_TS=$(date +%s)
    echo "INITIAL_START_DURATION_SEC=$((INITIAL_START_END_TS - INITIAL_START_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
    dump_openclaw_diagnostics

    echo "FAIL_STAGE=fallback_reinstall" >> "$RUN_OPENCLAW_META"
    echo "🔄 Initial start failed after preflight doctor. Attempting to fallback and reinstall recorded OpenClaw version..."

    TARGET_VERSION="$(resolve_fallback_openclaw_version || true)"
    if [ -z "$TARGET_VERSION" ]; then
      fail_startup "No fallback OpenClaw version found. Checked $KNOWN_GOOD_VERSION_FILE and .meta.lastTouchedVersion."
    fi
    echo "✅ Selected fallback OpenClaw version: $TARGET_VERSION"

    echo "Installing openclaw@$TARGET_VERSION ..."
    echo "FALLBACK_TARGET_VERSION=$TARGET_VERSION" >> "$RUN_OPENCLAW_META"
    FALLBACK_REINSTALL_BEGIN_TS=$(date +%s)
    npm i -g "openclaw@$TARGET_VERSION"

    fix_openclaw_permissions

    echo "🧪 Validating config against fallback openclaw@$TARGET_VERSION ..."
    if openclaw config validate >/tmp/config-validate-fallback.log 2>&1; then
      echo "✅ Config valid for fallback version."
    else
      echo "⚠️ Config invalid for fallback version. Trying 'openclaw doctor --fix' first. Details:"
      tail -n 10 /tmp/config-validate-fallback.log 2>/dev/null || true
      openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
      if openclaw config validate >/tmp/config-validate-fallback-2.log 2>&1; then
        echo "✅ Config repaired by doctor for fallback version."
      else
        DOWNGRADE_TS="$(date +%Y%m%d-%H%M%S)"
        echo "❌ Config still invalid for fallback version after doctor. Moving the current state aside so the fallback version starts clean (kept as *.state-bak-$DOWNGRADE_TS; sessions will be lost, upgrade back to recover). Details:"
        tail -n 10 /tmp/config-validate-fallback-2.log 2>/dev/null || true
        for STATE_DB in "$HOME/.openclaw/state/openclaw.sqlite" "$HOME/.openclaw/state/openclaw.sqlite-wal" "$HOME/.openclaw/state/openclaw.sqlite-shm"; do
          if [ -f "$STATE_DB" ]; then
            mv "$STATE_DB" "$STATE_DB.state-bak-$DOWNGRADE_TS" && echo "➡️ Moved aside: $STATE_DB"
          fi
        done
        echo "🛠️ Running 'openclaw doctor --fix' on the clean state..."
        openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"
      fi
    fi

    echo "Restarting OpenClaw after fallback reinstall..."
    FALLBACK_RESTART_OK=1
    # 2026-10-03 事故：降级后的启动崩溃循环会烧光 systemd StartLimitBurst
    # （10 次/300s），此后 restart 恒报 "Start request repeated too quickly"，
    # 自愈还没开始就被熔断锁死。restart 前先清 failed 计数。
    systemctl --user reset-failed openclaw-gateway.service 2>/dev/null || true
    if [ -d "$GW_DROPIN_DIR" ]; then
      GW_DROPIN_BACKUP="${GW_DROPIN_DIR}.pre-install.$$.$(date +%s%N)"
      mv "$GW_DROPIN_DIR" "$GW_DROPIN_BACKUP" 2>/dev/null || true
    fi
    mkdir -p "$HOME/.bun/bin"
    if ! openclaw gateway install --force; then
      echo "⚠️ Fallback gateway install failed."
      FALLBACK_RESTART_OK=0
    elif ! openclaw gateway restart; then
      echo "⚠️ Fallback gateway restart failed."
      FALLBACK_RESTART_OK=0
    fi

    if [ "$FALLBACK_RESTART_OK" = "1" ]; then
      # 回退重装的 install 同样要求无 drop-in 现场；成功后先回放再等健康
      apply_gw_dropin
    fi
    if [ "$FALLBACK_RESTART_OK" = "1" ] && wait_for_openclaw_health "fallback_reinstall" 180 5; then
      FALLBACK_REINSTALL_END_TS=$(date +%s)
      echo "FALLBACK_REINSTALL_DURATION_SEC=$((FALLBACK_REINSTALL_END_TS - FALLBACK_REINSTALL_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
      record_successful_openclaw_version "$TARGET_VERSION"
      echo "✅ OpenClaw Gateway is healthy after fallback reinstall!"
    else
      FALLBACK_REINSTALL_END_TS=$(date +%s)
      echo "FALLBACK_REINSTALL_DURATION_SEC=$((FALLBACK_REINSTALL_END_TS - FALLBACK_REINSTALL_BEGIN_TS))" >> "$RUN_OPENCLAW_META"
      dump_openclaw_diagnostics

      # 2026-10-11 移除版本化快照回滚（主人拍板）：快照是主包的服务端副本，
      # 主包坏它也坏，兜底价值≈0，却长期占用一份 4.2GB 云端空间。自愈链
      # 收敛为：doctor --fix → 回退重装（已记录的兼容版本）。走到这里说明
      # 两条都失败了，直接判死走失败通知（人工介入，现场保留）。
      echo "FAIL_STAGE=fallback_reinstall" >> "$RUN_OPENCLAW_META"
      err="回退到最近记录版本（${TARGET_VERSION:-未知}）重装后，OpenClaw 依然无法启动（健康检查失败）"
      fail_startup "$err"
    fi
fi
