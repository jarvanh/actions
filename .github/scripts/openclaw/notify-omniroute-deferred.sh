#!/usr/bin/env bash
# 2026-11-08（主人拍板）：OmniRoute 就绪通知延后到容器健康结论出来再发，且不阻塞
# 部署收口 —— run-ai-gateway.sh 通知块在「主用就绪 + 无降级」时 nohup 本脚本后台跑。
#
# 背景：compose healthcheck 带 start_period:120s 保护期，保护期内 Docker 状态恒为
# starting；同步通知必然撞上它，每轮都出「🟡 健康检查未通过」假警报（探针从未
# 失败，run 42434537774 实锤）。等首个结论（healthy/unhealthy）再发，🟢/🟡 语义
# 就是真实定性，不再需要「等即可」的过渡口径。
#
# 用法: notify-omniroute-deferred.sh <容器名> <镜像引用>
# env 继承自父脚本 step：TELEGRAM_BOT_TOKEN(_ALERT) / TELEGRAM_CHAT_ID(_ALERT) /
#   TG_RUN_URL / GITHUB_WORKSPACE / OMNIROUTE_NOTIFY
set -uo pipefail

CT_NAME="${1:-omniroute}"
IMAGE="${2:-diegosouzapw/omniroute:latest}"
GWS="${GITHUB_WORKSPACE:-/home/runner/work/actions/actions}"
NOTIFY_SRC="$GWS/.github/scripts/telegram/tg_notify.sh"

# 有界等待：上限 300s（5min > start_period 120s + interval 60s 两轮，留余量）。
# 仅 starting 值得等；healthy/unhealthy 即结论；none（无 healthcheck）/空（inspect
# 失败）无可等对象，立即按现值放行（与同步路径旧口径一致，不罚）。
waited=0 st=""
while [ "$waited" -lt 300 ]; do
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CT_NAME" 2>/dev/null || true)"
  case "${st:-none}" in
    healthy|unhealthy|none|"") break ;;
  esac
  sleep 5
  waited=$((waited + 5))
done
# 空（inspect 失败）与 none 同口径归 none → 🟢 不罚；仅超时的 starting 才如实报 🟡。
# 与同步路径旧口径一致（""|none|healthy 都不算 bad）。
st="${st:-none}"
echo "[$(date '+%F %T')] 容器健康结论：${st}（等待 ${waited}s）"

[ "${OMNIROUTE_NOTIFY:-1}" = "0" ] && { echo "OMNIROUTE_NOTIFY=0，跳过发送"; exit 0; }
[ -f "$NOTIFY_SRC" ] || { echo "tg_notify.sh 不存在，通知跳过"; exit 0; }
# 必须在构建消息前顶层 source（503b30b 教训：子 shell/迟到 source 对函数表不可见，
# tg_add_* 会 command not found）；send_tg 失败仅告警不影响任务。
# shellcheck disable=SC1091
if ! source "$NOTIFY_SRC" 2>/dev/null; then
  echo "::warning::tg_notify.sh source 失败，OmniRoute 延后就绪通知跳过"
  exit 0
fi

hc="$(curl -s --connect-timeout 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:20128/healthz 2>/dev/null || true)"

m=""
if [ "$st" = "healthy" ] || [ "$st" = "none" ] || [ -z "$st" ]; then
  tg_add_title m "🟢 AI 网关已就绪 · omniroute"
  tg_add_kv m "结论" "服务已就绪，健康检查通过"
else
  # 🟡 = 降级但服务在（等即可）；此处必为真实未通过（unhealthy/超时现态），
  # 不再是保护期过渡态。unhealthy 会随 interval:60s/retries:5 自动复查，
  # 连续失败最终会在容器状态上固化 —— 需要动手时看这条。
  tg_add_title m "🟡 AI 网关已就绪 · omniroute"
  tg_add_kv m "结论" "服务已监听，容器健康检查未通过（${st}），等即可"
fi
tg_add_path m "接口" "http://127.0.0.1:20128/v1"
tg_add_path m "镜像" "${IMAGE}"
# 自检是两个机器值（端口+HTTP 码、容器状态）→ 手拼 <code>（规范 · 取值行口径）
hc_txt="<code>20128 HTTP $(escape_html "${hc:-000}")</code>"
[ -n "$st" ] && [ "$st" != "none" ] && hc_txt+=" · 容器 <code>$(escape_html "$st")</code>"
tg_add_block m "自检：${hc_txt}"

# alert 档，与同步路径同档
if tg_add_footer m && send_tg "$m" alert; then
  echo "[$(date '+%F %T')] 延后就绪通知已发送（容器=${st}）"
else
  echo "::warning::OmniRoute 延后就绪通知发送失败（不影响任务）"
  exit 0
fi
