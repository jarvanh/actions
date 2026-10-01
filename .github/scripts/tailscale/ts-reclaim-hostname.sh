#!/usr/bin/env bash
# 主机名回收守护：周期重试把 Tailscale DNS 名收回 openclaw，收回后重写 ts.env 并退出。
#
# 用法: ts-reclaim-hostname.sh <tailnet后缀> <run_id>
#   例: ts-reclaim-hostname.sh taild54677.ts.net 36822381880
#
# 为什么需要它（2026-10-01 事故，openclaw → openclaw-1）：
#   workflow 里所有「回收主机名」的动作都只在 Enable Tailscale SSH 那一步试一次，
#   而残留的上一轮 ephemeral 节点要几十分钟后才被控制面清掉 —— 名字往往是在
#   那一步结束之后才空出来的，那时已经没有任何东西再去收回，于是这一整轮都顶着
#   openclaw-1（ts.env/通知/RustDesk 直连地址跟着全漂）。
#   且前置的「Clean stale Tailscale nodes」删不动：本仓库 OAuth client 只有
#   auth_keys scope，devices 列表接口 404，整段降级跳过 —— 删不掉就只能等，
#   等就必须有人周期重试。
#
# 行为：每 120s 检查一次 Self.DNSName；
#   已是 openclaw.<suffix> → 重写 ts.env 后退出（幂等，可重复跑）；
#   仍被占 → 走「临时名中转」把 openclaw 让出来再改回去（实测可强制收回名字），
#            然后继续下一轮重试。
# 生命周期：由 workflow 用 setsid + nohup 拉起，脱离步骤进程树；
#   job 结束随 runner 一起消失，无需收尾清理。
set -uo pipefail

SUFFIX="${1:-}"
RUN_ID="${2:-0}"
TMPN="openclaw-tmp-r${RUN_ID}"

if [ -z "$SUFFIX" ]; then
  echo "[ts-reclaim] ❌ 缺少参数：tailnet 后缀（形如 xxxx.ts.net）"
  exit 1
fi

_reclaim_once() {
  # 临时名中转：先把 openclaw 让出来，再改回去 —— 实测可强制收回名字
  sudo tailscale set --hostname="$TMPN" >/dev/null 2>&1 || true
  local i t
  for i in $(seq 1 10); do
    t="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
    case "$t" in "${TMPN}.${SUFFIX}") return 0 ;; esac
    sleep 3
  done
  sudo tailscale set --ssh --hostname=openclaw --advertise-exit-node >/dev/null 2>&1 || true
  return 0
}

while true; do
  sleep 120
  CUR="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
  [ -z "$CUR" ] && continue

  if [ "$CUR" = "openclaw.${SUFFIX}" ]; then
    IP="$(tailscale ip -4 2>/dev/null || true)"
    {
      printf 'TS_HOST=%s\n' "openclaw"
      printf 'TS_FQDN=%s\n' "openclaw.${SUFFIX}"
      printf 'TS_IP=%s\n' "$IP"
    } > "$HOME/ts.env"
    echo "[ts-reclaim] $(date -u +%FT%TZ) ✅ 已收回 openclaw.${SUFFIX}，ts.env 已更新"
    exit 0
  fi

  echo "[ts-reclaim] $(date -u +%FT%TZ) 仍为 ${CUR}，重试回收"
  _reclaim_once
done
