#!/usr/bin/env bash
# /dropbox 依赖方自愈（2026-11-10「qoder 数据源失联」事故固化）
#
# 背景：rclone-dropbox 一旦重启，/dropbox 的 fuse 连接换代；此后
#   - docker 容器的 bind mount（qoder2api /app/accounts、trae2api /app/data）
#     仍指向旧连接 → 容器内读写直接 "Socket not connected"；
#   - 早于挂载启动的常驻服务（workbuddy-gateway / qingyan / autoclaw /
#     quota-board）继续握着旧句柄 → 状态快照/日志停更，看板误报「数据源失联」。
# 2026-11-10 13:02/13:07 两次 rclone 重启后无人重建依赖方：qoder 面板读不到
# accounts/settings.json → /panel/login 401→429 → /credits/summary 全 401，
# 看板连续 367 轮失败才被「数据源失联」告警抓到（详见 memory/2026-11-10.md）。
#
# 用法：
#   dropbox_dependents.sh check   # 只体检；有 stale 退出 1
#   dropbox_dependents.sh heal    # 体检并修复，修复后退出 0（硬失败仍 1）
#
# 环境：
#   DROPBOX_DEPS_DRY_RUN=1        只打印将执行的动作
#   DROPBOX_DEPS_GRACE_SECS=180   挂载刚启动的宽限秒数（避免与部署步骤抢容器）
#
# 调用方：services.sh cmd_ensure（rclone-dropbox 重启后）、system_health.sh（每 5 分钟）
#
# 设计约束：容器重建只复用**当前镜像**（不拉新 tag）——自愈不等于升级，
# 升级仍归 run-qoder2api.sh / run-trae2api.sh 的部署步骤。
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

log() { printf '[dropbox-deps] %s\n' "$*"; }

# 容器:探针路径（必须落在 /dropbox 的 bind mount 上）
CONTAINERS=(
  "qoder2api:/app/accounts"
  "trae2api:/app/data"
)
# 常驻服务（systemd --user）：启动早于当前挂载即视为 stale
SERVICES=(workbuddy-gateway qingyan autoclaw quota-board)

MODE="${1:-check}"
DRY_RUN="${DROPBOX_DEPS_DRY_RUN:-0}"
GRACE="${DROPBOX_DEPS_GRACE_SECS:-180}"

mono_now_us() { awk '{printf "%d", $1 * 1000000}' /proc/uptime 2>/dev/null || echo 0; }

# 用 Monotonic 时间戳比较，避开 systemctl 输出里的时区缩写歧义
# （CST 会被 date -d 当成美国中部时间，实测差 14 小时）
rclone_start_mono() {
  local v
  v=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value rclone-dropbox 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

service_start_mono() {
  local v
  v=$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "$1" 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}

container_state() {  # ok | stale | missing
  local c="$1" p="$2"
  docker inspect "$c" >/dev/null 2>&1 || { echo missing; return; }
  if docker exec "$c" sh -c "test -r '$p'" >/dev/null 2>&1; then
    echo ok
  else
    echo stale
  fi
}

recreate_qoder2api() {
  local image restart network i code
  image=$(docker inspect -f '{{.Config.Image}}' qoder2api 2>/dev/null || true)
  [ -n "$image" ] || { log "❌ qoder2api 镜像信息读取失败"; return 1; }
  restart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' qoder2api 2>/dev/null || true)
  [ -n "$restart" ] || restart=unless-stopped
  network=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' qoder2api 2>/dev/null || true)
  [ -n "$network" ] || network=omniroute_default
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] 重建 qoder2api（image=$image network=$network）"
    return 0
  fi
  log "重建 qoder2api（image=$image network=$network）"
  docker rm -f qoder2api >/dev/null 2>&1 || true
  docker run -d --name qoder2api --restart "$restart" --network "$network" \
    -p 8790:8790 \
    -e HOST=0.0.0.0 -e PORT=8790 -e TZ=Asia/Shanghai \
    -e QD_ERROR_COOLDOWN_WAIT_MAX=30 \
    -v /dropbox/self-hosted/qoder2api/accounts:/app/accounts \
    -v /dropbox/self-hosted/qoder2api/usage:/app/usage \
    "$image" >/dev/null || { log "❌ qoder2api docker run 失败"; return 1; }
  for i in $(seq 1 60); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8790/ping 2>/dev/null || true)
    [ "$code" = 200 ] && { log "✅ qoder2api 已恢复"; return 0; }
    sleep 1
  done
  log "❌ qoder2api 重建后 60s 未就绪"
  return 1
}

recreate_trae2api() {
  local image tag dir env i code
  image=$(docker inspect -f '{{.Config.Image}}' trae2api 2>/dev/null || true)
  [ -n "$image" ] || { log "❌ trae2api 镜像信息读取失败"; return 1; }
  tag="${image##*:}"
  dir=/tmp/local_trae2api-src
  env=/dropbox/self-hosted/trae2api/.env
  if [ ! -f "$dir/docker-compose.yml" ] || [ ! -f "$env" ]; then
    log "❌ trae2api 重建材料缺失（$dir/docker-compose.yml 或 $env）"
    return 1
  fi
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] 重建 trae2api（image=$image）"
    return 0
  fi
  log "重建 trae2api（image=$image）"
  docker rm -f trae2api >/dev/null 2>&1 || true
  TRAE2API_IMAGE_VERSION="$tag" TRAE2API_RELEASE_TAG="$tag" \
    docker compose --env-file "$env" -f "$dir/docker-compose.yml" \
      --project-directory "$dir" up -d >/dev/null 2>&1 \
    || { log "❌ trae2api compose up 失败"; return 1; }
  for i in $(seq 1 60); do
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:7864/healthz 2>/dev/null || true)
    [ "$code" = 200 ] && { log "✅ trae2api 已恢复"; return 0; }
    sleep 1
  done
  log "❌ trae2api 重建后 60s 未就绪"
  return 1
}

main() {
  local rs now_us stale=0 failed=0 pair c p state svc st
  rs=$(rclone_start_mono)
  if [ "$rs" -le 0 ]; then
    log "rclone-dropbox 未运行，跳过"
    return 0
  fi
  now_us=$(mono_now_us)
  if [ "$MODE" = heal ] && [ $(( (now_us - rs) / 1000000 )) -lt "$GRACE" ]; then
    log "挂载刚启动 $(( (now_us - rs) / 1000000 ))s（宽限 ${GRACE}s），交给部署步骤接管"
    return 0
  fi
  log "当前挂载启动于 $(systemctl --user show -p ActiveEnterTimestamp --value rclone-dropbox 2>/dev/null)"

  for pair in "${CONTAINERS[@]}"; do
    c="${pair%%:*}"
    p="${pair#*:}"
    state=$(container_state "$c" "$p")
    case "$state" in
      missing) log "⏭️ $c 未运行，跳过" ;;
      ok)      log "✅ $c 挂载可读（$p）" ;;
      stale)
        stale=$((stale + 1))
        log "⚠️ $c 的 $p 不可读（rclone 重启后 fuse bind 失效）"
        if [ "$MODE" = heal ]; then
          case "$c" in
            qoder2api) recreate_qoder2api || failed=$((failed + 1)) ;;
            trae2api)  recreate_trae2api  || failed=$((failed + 1)) ;;
          esac
        fi
        ;;
    esac
  done

  for svc in "${SERVICES[@]}"; do
    systemctl --user is-active --quiet "$svc" 2>/dev/null || { log "⏭️ $svc 未运行，跳过"; continue; }
    st=$(service_start_mono "$svc")
    if [ "$st" -eq 0 ]; then
      log "⏭️ $svc 启动时刻未知，跳过"
      continue
    fi
    if [ "$st" -ge "$rs" ]; then
      log "✅ $svc 启动于挂载之后"
      continue
    fi
    stale=$((stale + 1))
    log "⚠️ $svc 启动早于当前挂载（可能握着旧 fuse 句柄）"
    if [ "$MODE" = heal ]; then
      if [ "$DRY_RUN" = 1 ]; then
        log "[dry-run] 重启 $svc"
      elif systemctl --user restart "$svc"; then
        log "✅ $svc 已重启"
      else
        log "❌ $svc 重启失败"
        failed=$((failed + 1))
      fi
    fi
  done

  if [ "$stale" -eq 0 ]; then
    log "✅ /dropbox 依赖方均正常"
    return 0
  fi
  if [ "$MODE" != heal ]; then
    log "发现 $stale 个 stale 依赖方（用 heal 修复）"
    return 1
  fi
  if [ "$failed" -gt 0 ]; then
    log "❌ $failed 个依赖方修复失败"
    return 1
  fi
  log "✅ 已重建/重启 $stale 个依赖方（建议复检）"
  return 0
}

main
