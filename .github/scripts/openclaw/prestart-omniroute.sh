#!/usr/bin/env bash
# 2026-11-06 启动提速（主人拍板）：OmniRoute 恢复 + 起容器后台化。
# 原先这两段全在 Run AI API gateway 步骤的关键路径里（实测数据恢复 20s +
# 镜像重拉 28s + 容器启动/健康检查 110s）。本脚本在 Mount Dropbox 之后立即
# 后台起跑，与 ZCode 还原 / Install OpenClaw / Tailscale 段完全重叠；网关步骤
# 只按 rc 收口 + 做 20128 健康判定（P5b 等齐门与降级链语义不变）。
#
# 契约（与 Start OpenClaw install 后台步同款）：
#   /tmp/omniroute-prestart.rc   出现即代表终态（0=数据+容器就绪，非0=未就绪）
#   /tmp/omniroute-prestart.log  全量日志，收口步回放
# 收口步检测到 rc 非 0 / 进程死亡无 rc 时，回落「网关步骤内原同步路径」。
# 上游等齐门（P5b）仍留在网关步骤：容器可在上游未齐时先启动（与旧降级
# 路径同性质，circuit breaker 兜底），但「对外宣告就绪」仍等上游。
set -uo pipefail

GWS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE 未设置}"
RC=/tmp/omniroute-prestart.rc
LOG=/tmp/omniroute-prestart.log
: > "$LOG"
rm -f "$RC"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>&1; }

# pinned 到 clirelay / cliproxyapi 时不该抢先起 OmniRoute（占 20128 会让
# pinned 后端端口冲突）。auto / omniroute 才预起；后者仍由网关步做健康判定。
BACKEND="${AI_BACKEND_INPUT:-auto}"
if [ "$BACKEND" != "auto" ] && [ "$BACKEND" != "omniroute" ]; then
  log "pinned=${BACKEND}，跳过 OmniRoute 预起"
  echo 2 > "$RC"
  exit 0
fi

# 复用网关脚本里的真源逻辑，避免逻辑漂移：抽取它的「变量段 + 函数定义段」
# （从 BACKEND_STATE 定义到「主流程」注释之前，不含 P5b barrier / 降级链），
# source 后即可直接调用 restore_omniroute_data / bootstrap_omniroute /
# start_omniroute / fetch_via_prefetch，与网关步消费的是同一份实现。
GW="$GWS/.github/scripts/openclaw/run-ai-gateway.sh"
if [ ! -f "$GW" ]; then
  log "run-ai-gateway.sh 缺失，放弃预起（网关步走原同步路径）"
  echo 1 > "$RC"; exit 0
fi
PREFIX=$(mktemp /tmp/omniroute-prestart-prefix.XXXXXX)
# ⚠️ 边界必须是「最后一个函数 start_omniroute 的闭合 }」：按注释/调用点
# 截断都会把主流程（restore/bootstrap/P5b）source 进来执行一遍，或截在
# 函数中间导致语法错误（沙箱实测两种都中过）。用大括号计数精确收口。
awk '
  /^BACKEND_STATE=/{on=1}
  on {
    if ($0 !~ /^echo "Configuring/ && $0 !~ /^set -euo pipefail$/) print
    n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth += n-m
    if (saw_fn && depth <= 0) exit
    if (/^start_omniroute\(\)/) saw_fn=1
  }
' "$GW" > "$PREFIX"
# shellcheck disable=SC1090
source "$PREFIX" 2>>"$LOG" || { log "source 函数/变量片段失败"; rm -f "$PREFIX"; echo 1 > "$RC"; exit 0; }
rm -f "$PREFIX"

mkdir -p "$OMNIROUTE_DIR" ~/.openclaw/logs

log "开始：归档恢复 + 容器启动（后台）"
if ! restore_omniroute_data >>"$LOG" 2>&1; then
  log "归档恢复失败 → bootstrap 空库兜底（与网关步原语义一致）"
  bootstrap_omniroute >>"$LOG" 2>&1 || { log "bootstrap 失败"; echo 1 > "$RC"; exit 0; }
  if [ "${OMNIROUTE_ARCHIVE_SEEN:-0}" = "1" ]; then
    log "⚠️ 归档存在却恢复失败（空库兜底）；网关步会按原路径再判一次并告警"
  fi
fi
if ! start_omniroute >>"$LOG" 2>&1; then
  log "start_omniroute 失败"
  echo 1 > "$RC"; exit 0
fi
log "✅ 数据 + 容器已就位（健康检查留待网关步）"
echo 0 > "$RC"
