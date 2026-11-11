#!/usr/bin/env bash
# ── 「整体上线」判据（2026-11-10，主人定：所有服务都能正常使用才算上线）──
# 只探本地端口（与生产实际入口一致），逐个探活，全部就绪才算整体上线：
#   18789 openclaw 网关 / 20128 OmniRoute / 8318 workbuddy / 8319 zcode2api
#   8320 qingyan / 8322 autoclaw / 8790 qoder2api-hub / 8321 quota-board
# 用法: full-ready.sh [超时秒数，默认 600]
#       full-ready.sh --check        # 单次快照，不等待、不通知（看门狗用）
# 输出: 全部就绪时打印「★ 整体上线」，并给出相对旧轮停机时刻（old.json.cutoff_epoch）
#       的下线秒数；超时则打印未就绪清单（非零退出）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"

TIMEOUT=600
CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    ''|*[!0-9]*) ;;
    *) TIMEOUT="$a" ;;
  esac
done
P0=$(date +%s)
# 端口 → 服务名（顺序 = 依赖序，便于日志阅读）
PORTS="18789:openclaw 20128:omniroute 8318:workbuddy 8319:zcode2api 8320:qingyan 8322:autoclaw 8790:qoder2api 8321:quota-board"

port_up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# 单轮探测：结果落 CHECK_MISSING / CHECK_UP / CHECK_TOTAL
probe_once() {
  CHECK_MISSING=""; CHECK_UP=0; CHECK_TOTAL=0
  for pair in $PORTS; do
    p="${pair%%:*}"; n="${pair#*:}"; CHECK_TOTAL=$((CHECK_TOTAL+1))
    if port_up "$p"; then CHECK_UP=$((CHECK_UP+1)); else CHECK_MISSING="$CHECK_MISSING $n($p)"; fi
  done
}

# 看门狗快照模式：只回答「此刻 8 个入口是否都在听」，不等待、不发通知。
# 这里端口是「服务真的可用」的唯一判据 —— 单元 active 但没在听（卡死/绑错）同样算故障，
# 这是 2026-11-11 qb 事件后补的：当时看板单元 active、公网入口却不存在。
if [ "$CHECK_ONLY" = 1 ]; then
  probe_once
  if [ -z "$CHECK_MISSING" ]; then
    echo "✅ 服务入口全就绪（${CHECK_UP}/${CHECK_TOTAL}）"
    exit 0
  fi
  echo "⚠️ 服务入口未就绪（${CHECK_UP}/${CHECK_TOTAL}）：${CHECK_MISSING}"
  exit 1
fi

while :; do
  probe_once
  missing="$CHECK_MISSING"; up="$CHECK_UP"; total="$CHECK_TOTAL"
  if [ -z "$missing" ]; then
    echo "✅ 全服务就绪（${up}/${total}）"
    # 与旧轮停机时刻对齐（production: old.json.cutoff_epoch；测试: timing.json.stop_epoch）
    ref="$(handoff_get "$HANDOFF_OLD_REMOTE" '.cutoff_epoch')"
    [ -n "$ref" ] || ref="$(rclone cat "${HANDOFF_REMOTE_DIR}/timing.json" 2>/dev/null | jq -r '.stop_epoch // empty' 2>/dev/null || true)"
    case "${ref:-}" in ''|*[!0-9]*) ref=0 ;; esac
    if [ "$ref" -gt 0 ] 2>/dev/null; then
      _total=$(( $(date +%s) - ref ))
      echo "★ 整体上线：旧轮停机 → 全部服务可用 = ${_total}s"
      _ai="Dropbox 回退"; [ -f /tmp/handoff-ai-fast.ok ] && _ai="rsync 直装"
      bash "$here/handoff-notify.sh" full "downtime=$_total" "ai=$_ai" \
        "run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-0}" || true
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
