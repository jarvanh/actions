#!/usr/bin/env bash
# 主机名回收守护：周期重试把 Tailscale DNS 名收回 openclaw；收回后按 serve 现状重建全部端口。
#
# 用法: ts-reclaim-hostname.sh <tailnet后缀> <run_id>
#   例: ts-reclaim-hostname.sh taild54677.ts.net 36822381880
#   环境变量 TS_API_KEY（tskey-api-*，可选但强烈建议）：具备 devices 读写权限，
#   用于 API 直删已断联的僵尸节点 —— 不再干等控制面几十分钟的自动清理。
#
# 为什么需要它（2026-10-01 事故，openclaw → openclaw-1）：
#   workflow 里所有「回收主机名」的动作都只在 Enable Tailscale SSH 那一步试一次，
#   而残留的上一轮 ephemeral 节点要几十分钟后才被控制面清掉 —— 名字往往是在
#   那一步结束之后才空出来的，那时已经没有任何东西再去收回，于是这一整轮都顶着
#   openclaw-1（ts.env/通知/RustDesk 直连地址跟着全漂）。
#   2026-11-08 二次事故补充：Clean stale 步有 150s 心跳窗口等待，但窗口期后
#   仍可能漏（前任心跳 >150s / 控制面状态抖动），守护必须是最后一道兜底。
#
# 行为：每 120s 一轮 ——
#   ① 有 TS_API_KEY 时：API 删除已断联（connectedToControl=false）的 openclaw*
#      僵尸节点，名字当场空出来（实测删除后 set 改名即可收回）；
#   ② Self.DNSName 已是 openclaw.<suffix> → 重建 serve 全端口（见下）+ 重写
#      ts.env → 退出（幂等，可重复跑）；
#   ③ 仍被占 → 临时名中转（把 openclaw 让出来再改回去，实测可强制收回），
#      然后继续下一轮重试。
#
# ⚠️ 名字切换后 serve 配置会跟着旧 DNS 名一起失效（2026-11-08 实锤：收回名字后
#   443 TLS 握手失败 —— serve 绑定还挂在旧名 openclaw-1 的证书上）。故收回名字
#   后按 `tailscale serve status` 现状数据驱动重建全部端口，不硬编码清单：
#   新增/撤掉看板端口时改 serve 创建处即可，守护自动跟随。
# 生命周期：由 workflow 用 setsid + nohup 拉起，脱离步骤进程树；
#   job 结束随 runner 一起消失，无需收尾清理。
set -uo pipefail

SUFFIX="${1:-}"
RUN_ID="${2:-0}"
TMPN="openclaw-tmp-r${RUN_ID}"
TARGET="openclaw.${SUFFIX}"

if [ -z "$SUFFIX" ]; then
  echo "[ts-reclaim] ❌ 缺少参数：tailnet 后缀（形如 xxxx.ts.net）"
  exit 1
fi

# ---------- API 删僵尸（有 TS_API_KEY 才启用）----------
# 安全红线：只删 connectedToControl=false（已断联），绝不碰还连着的节点 ——
# 设备列表无 online 字段，connectedToControl 是唯一可靠判据（2026-10-01 实测）。
_purge_stale() {
  [ -n "${TS_API_KEY:-}" ] || return 0
  local _dev _ids _id _code
  _dev="$(curl -s --max-time 20 -u "${TS_API_KEY}:" \
    https://api.tailscale.com/api/v2/tailnet/-/devices 2>/dev/null || true)"
  [ -z "${_dev}" ] && return 0
  _ids="$(printf '%s' "${_dev}" | jq -r '
    (.devices // [])[]?
    | select(((.hostname // "") + " " + (.name // "")) | test("openclaw"))
    | select(.connectedToControl == false)
    | .id' 2>/dev/null || true)"
  [ -z "${_ids}" ] && return 0
  for _id in ${_ids}; do
    _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X DELETE \
      -u "${TS_API_KEY}:" "https://api.tailscale.com/api/v2/device/${_id}" 2>/dev/null || true)"
    case "${_code}" in
      200|204) echo "[ts-reclaim] $(date -u +%FT%TZ) 🗑️ 已 API 删除断联僵尸 ${_id} (HTTP ${_code})" ;;
      *) echo "[ts-reclaim] $(date -u +%FT%TZ) ⚠️ 删除僵尸 ${_id} 失败 (HTTP ${_code})" ;;
    esac
  done
}

# ---------- 临时名中转 ----------
_reclaim_once() {
  # 临时名中转：先把 openclaw 让出来，再改回去 —— 实测可强制收回名字
  sudo tailscale set --hostname="$TMPN" >/dev/null 2>&1 || true
  local i t
  for i in $(seq 1 10); do
    t="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
    # 2026-11-10 修复：临时名生效后必须继续走下面的 openclaw 改名。
    # 原为 return 0，导致每轮只把名字改成临时名就返回，永远收不回 openclaw
    # （现场 ts-reclaim.log 每 2 分钟重复「仍为 openclaw-tmp-…」即此症）。
    case "$t" in "${TMPN}.${SUFFIX}") break ;; esac
    sleep 3
  done
  sudo tailscale set --ssh --hostname=openclaw --advertise-exit-node >/dev/null 2>&1 || true
  return 0
}

# ---------- serve 重建（数据驱动，不硬编码端口清单）----------
# 从 `tailscale serve status --json` 解析现存绑定，reset 后逐条重建 —— 重建后
# 绑定挂在新名字下（serve 命令只认端口，host 始终是当前节点名），证书随缓存立即生效。
# 新旧名同名条目按（端口,路径,代理）去重后自动坍缩（2026-11-08 现场实测 24→13 条）。
# TCP 转发条目一并重建；单条失败只告警不退出：任何一条挂掉都不应拖垮其余入口。
_rebind_serves() {
  local _st _ok=0 _fail=0 _hp _path _proxy _proto _port _tgt
  _st="$(sudo tailscale serve status --json 2>/dev/null || true)"
  [ -z "${_st}" ] && { echo "[ts-reclaim] $(date -u +%FT%TZ) serve status 为空，跳过重建"; return 0; }
  sudo tailscale serve reset >/dev/null 2>&1 || true
  while IFS=$'\t' read -r _port _path _proxy _proto _tgt; do
    [ -n "${_proxy:-${_tgt}}" ] || continue
    if [ -n "${_tgt:-}" ]; then
      # TCP 转发条目（TCP.<port>.TCP = host:port）
      if sudo tailscale serve --bg --tcp="${_port}" "tcp://${_tgt}" >/dev/null 2>&1; then
        _ok=$((_ok + 1))
      else
        _fail=$((_fail + 1))
        echo "[ts-reclaim] $(date -u +%FT%TZ) ⚠️ serve 重建失败(TCP): ${_port} → ${_tgt}"
      fi
      continue
    fi
    [ -n "${_proxy}" ] || continue
    case "${_proto}" in
      https) _pflag="--https=${_port}" ;;
      *)     _pflag="--http=${_port}" ;;
    esac
    if [ "${_path:-/}" = "/" ]; then
      sudo tailscale serve --bg "${_pflag}" "${_proxy}" >/dev/null 2>&1 || { _fail=$((_fail + 1)); echo "[ts-reclaim] $(date -u +%FT%TZ) ⚠️ serve 重建失败: ${_pflag} → ${_proxy}"; continue; }
    else
      sudo tailscale serve --bg "${_pflag}" "${_path}" "${_proxy}" >/dev/null 2>&1 || { _fail=$((_fail + 1)); echo "[ts-reclaim] $(date -u +%FT%TZ) ⚠️ serve 重建失败: ${_pflag} ${_path} → ${_proxy}"; continue; }
    fi
    _ok=$((_ok + 1))
  done < <(printf '%s' "${_st}" | jq -r '
    (.TCP // {}) as $tcp
    | ([(.Web // {}) | to_entries[]
        | .key as $hp
        | (($hp | split(":")) | last) as $port
        | (if ($tcp[$port].HTTPS == true) then "https" else "http" end) as $proto
        | ((.value.Handlers // {}) | to_entries[])
        | [ $port, .key, (.value.Proxy // ""), $proto, ""]]
      + [(.TCP // {}) | to_entries[]
        | select((.value.TCP // "") != "")
        | [ .key, "/", "", "tcp", (.value.TCP // "") ]])
    | .[]
    | @tsv' 2>/dev/null | awk -F'\t' '$3 != "" || $5 != ""' | sort -u)
  echo "[ts-reclaim] $(date -u +%FT%TZ) 🔁 serve 重建完成: 成功 ${_ok} 条, 失败 ${_fail} 条"
}

# 2026-11-11：交接后前 5 分钟快速轮询（15s），之后回到 120s 常态。
# 原实现「先 sleep 120 再检查」→ 最早一次尝试在启动后 2 分钟；叠加旧 VM 迟迟
# 不放名字，实测 22:38:34 serving → 22:47:02 才收回，客户端 12 分钟连到死节点。
# 现在旧 VM 会在 rsync_done 后主动改名让位（cutover.sh 3.6），这里配合快轮询，
# 通常能在交出后 1-2 分钟内收回。僵尸清理依赖控制面收敛，前 5 分钟每 4 轮做一次即可。
_round=0
while true; do
  _round=$((_round + 1))
  if [ "$_round" -le 20 ]; then _pause=15; else _pause=120; fi
  if [ "$_round" -eq 1 ] || [ $((_round % 4)) -eq 0 ] || [ "$_round" -gt 20 ]; then
    _purge_stale
  fi
  CUR="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
  [ -z "$CUR" ] && { sleep "$_pause"; continue; }

  if [ "$CUR" = "$TARGET" ]; then
    _rebind_serves
    IP="$(tailscale ip -4 2>/dev/null || true)"
    {
      printf 'TS_HOST=%s\n' "openclaw"
      printf 'TS_FQDN=%s\n' "$TARGET"
      printf 'TS_IP=%s\n' "$IP"
    } > "$HOME/ts.env"
    echo "[ts-reclaim] $(date -u +%FT%TZ) ✅ 已收回 ${TARGET}，serve 已重建，ts.env 已更新"
    exit 0
  fi

  echo "[ts-reclaim] $(date -u +%FT%TZ) 仍为 ${CUR}，重试回收（第 ${_round} 轮）"
  _reclaim_once
  sleep "$_pause"
done
