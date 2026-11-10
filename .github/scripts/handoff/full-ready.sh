#!/usr/bin/env bash
# ── 「整体上线」判据（2026-11-10，主人定：所有服务都能正常使用才算上线）──
# 只探本地端口（与生产实际入口一致），逐个探活，全部就绪才算整体上线：
#   18789 openclaw 网关 / 20128 OmniRoute / 8318 workbuddy / 8319 zcode2api
#   8320 qingyan / 8322 autoclaw / 8790 qoder2api-hub / 8321 quota-board
# 用法: full-ready.sh [超时秒数，默认 600]
# 输出: 全部就绪时打印「★ 整体上线」，并给出相对旧轮停机时刻（old.json.cutoff_epoch）
#       的下线秒数；超时则打印未就绪清单（非零退出）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"

TIMEOUT="${1:-600}"
P0=$(date +%s)
# 端口 → 服务名（顺序 = 依赖序，便于日志阅读）
PORTS="18789:openclaw 20128:omniroute 8318:workbuddy 8319:zcode2api 8320:qingyan 8322:autoclaw 8790:qoder2api 8321:quota-board"

port_up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

while :; do
  missing=""; up=0; total=0
  for pair in $PORTS; do
    p="${pair%%:*}"; n="${pair#*:}"; total=$((total+1))
    if port_up "$p"; then up=$((up+1)); else missing="$missing $n($p)"; fi
  done
  if [ -z "$missing" ]; then
    echo "✅ 全服务就绪（${up}/${total}）"
    # 与旧轮停机时刻对齐（production: old.json.cutoff_epoch；测试: timing.json.stop_epoch）
    ref="$(handoff_get "$HANDOFF_OLD_REMOTE" '.cutoff_epoch')"
    [ -n "$ref" ] || ref="$(rclone cat "${HANDOFF_REMOTE_DIR}/timing.json" 2>/dev/null | jq -r '.stop_epoch // empty' 2>/dev/null || true)"
    case "${ref:-}" in ''|*[!0-9]*) ref=0 ;; esac
    if [ "$ref" -gt 0 ] 2>/dev/null; then
      echo "★ 整体上线：旧轮停机 → 全部服务可用 = $(( $(date +%s) - ref ))s"
    else
      echo "★ 整体上线（无停机基准，单看本轮耗时 $(( $(date +%s) - P0 ))s）"
    fi
    exit 0
  fi
  if [ $(( $(date +%s) - P0 )) -ge "$TIMEOUT" ]; then
    echo "⚠️ 整体上线超时（${TIMEOUT}s）：${up}/${total} 就绪，未就绪:${missing}"
    exit 1
  fi
  sleep 3
done
