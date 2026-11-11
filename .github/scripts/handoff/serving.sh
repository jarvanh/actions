#!/usr/bin/env bash
# 继任者上线回执（Run OpenClaw 网关健康之后调用；Phase 1，2026-11-10）。
#   1. new.json=serving → 旧轮的 cutover 等的就是它，收到即转纯备份收尾
#   2. 拉起主机名回收守护（openclaw-next → openclaw；旧节点退场后自动收回，
#      ts-reclaim-hostname.sh 自带周期重试 + serve 端口重建）
#   3. 后台 quick_check 其余 agent 库（不阻塞上线；坏库只告警不掀桌 ——
#      主 state 库已在 takeover inline 查过）
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init
handoff_is_successor || exit 0

handoff_put "$HANDOFF_NEW_REMOTE" "$(handoff_new_json serving)"
echo "🎉 [serving] new.json=serving 已写 —— 旧轮收到后 handoff_done，下线窗口就此关闭"
_cut="$(handoff_get "$HANDOFF_OLD_REMOTE" '.cutoff_epoch')"
case "${_cut:-}" in ''|*[!0-9]*) _cut=0 ;; esac
_dt=0; [ "$_cut" -gt 0 ] && _dt=$(( $(date +%s) - _cut ))
_ai="Dropbox 回退"; [ -f /tmp/handoff-ai-fast.ok ] && _ai="rsync 直装"
bash "$here/handoff-notify.sh" serving "downtime=$_dt" "ai=$_ai" || true

# ── 主机名回收（等效 Enable Tailscale SSH 步的守护，但目标是交接后的名字）──
_dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' 2>/dev/null | head -n 1 || true)"
_dns="${_dns%.}"
_ts_suffix="${_dns#*.}"
# 2026-11-10：先当场试一次改名（旧节点此时已退场，成功率最高），再落守护兜底。
# 只靠守护出过事故：守护自身有 bug 时名字会静默永久停在 openclaw-next/tmp，
# 而 ts.env / RustDesk / serve 地址都跟着错。
if [ -n "$_ts_suffix" ] && [ "$_dns" != "openclaw.${_ts_suffix}" ]; then
  for _i in 1 2 3 4 5; do
    sudo -n tailscale set --ssh --hostname=openclaw --advertise-exit-node >/dev/null 2>&1 || true
    sleep 2
    _dns2="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
    if [ "$_dns2" = "openclaw.${_ts_suffix}" ]; then
      echo "✅ [serving] 主机名已当场收回：${_dns2}"
      _dns="$_dns2"
      break
    fi
  done
  [ "$_dns" = "openclaw.${_ts_suffix}" ] || echo "⚠️ [serving] 当场改名未生效（当前 ${_dns}），交给守护重试"
fi

if [ -n "$_ts_suffix" ] && [ "$_dns" != "openclaw.${_ts_suffix}" ] \
   && [ -f "${GITHUB_WORKSPACE}/.github/scripts/tailscale/ts-reclaim-hostname.sh" ]; then
  TS_API_KEY="${TS_API_KEY:-}" setsid nohup bash "${GITHUB_WORKSPACE}/.github/scripts/tailscale/ts-reclaim-hostname.sh" \
    "$_ts_suffix" "${GITHUB_RUN_ID:-0}" >> "$HOME/.openclaw/logs/ts-reclaim.log" 2>&1 < /dev/null &
  disown 2>/dev/null || true
  echo "✅ [serving] 主机名回收守护已启动（当前 ${_dns} → 目标 openclaw.${_ts_suffix}）"
fi

# ── 后台完整性快查（仅观测）──
(
  set +e
  bad=0
  for db in "$HOME"/.openclaw/agents/*/agent/openclaw.sqlite; do
    [ -e "$db" ] || continue
    qc="$(timeout 120 sqlite3 "$db" 'PRAGMA quick_check;' 2>/dev/null | head -n 1)"
    if [ "$qc" != "ok" ]; then
      echo "::warning::[handoff] agent 库 quick_check 异常: $db → ${qc:-<无输出>}"
      bad=$((bad + 1))
    fi
  done
  echo "[serving] agent 库后台快查完成：异常 ${bad} 个（详见上方 warning）"
) > /tmp/handoff-agent-check.log 2>&1 &
disown 2>/dev/null || true
exit 0
