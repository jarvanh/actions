#!/usr/bin/env bash
# ── AI 整包直取（Phase 2，2026-11-10）──
# 由 takeover.sh 在 rsync_done 之后**后台**拉起：不占聊天路径的关键路径，
# 但一旦取到就能让 AI 栈跳过 Dropbox 下载。
#
# 契约：旧轮在交出瞬间用归档脚本现做 OmniRoute 整包并投到 /tmp/handoff-ai-payload
#（rsyncd 的 [ai] 模块）。取到 + tar 校验通过 → 播种 prefetch 协议
#（/tmp/openclaw-prefetch/OmniRoute.tar.gz + omniroute-tar.rc=0/.pid），
# 让 run-ai-gateway.sh 原有的 fetch_via_prefetch 命中它；校验/解包/载入命名卷
# 全部沿用原逻辑，只换传输通道。
# 取不到 → 什么都不播种 → gate 走 ai.json（Dropbox 归档，Phase 1.5 行为）。
# 这是「直传优先、失败回退 Dropbox」的落地方式。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"

OLD_TS_IP="${1:-}"
[ -n "$OLD_TS_IP" ] || { echo "⚠️ [ai-fetch] 缺旧轮 IP，放弃直取"; exit 0; }
AI_PAYLOAD_DIR=/tmp/handoff-ai-payload
PF_DIR=/tmp/openclaw-prefetch
mkdir -p "$AI_PAYLOAD_DIR" "$PF_DIR"
exec >>/tmp/handoff-ai-fetch.log 2>&1
echo "[$(date '+%F %T')] ai-fetch start (src ${OLD_TS_IP}:${HANDOFF_RSYNC_PORT})"

for _i in $(seq 1 36); do   # 最多 180s：旧轮要先停 AI 栈再打包上传
  if timeout 120 rsync -a --timeout=60 \
      "rsync://${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}/ai/" "$AI_PAYLOAD_DIR/" >/dev/null 2>&1 \
     && [ -s "$AI_PAYLOAD_DIR/OmniRoute.tar.gz" ]; then
    if tar -tzf "$AI_PAYLOAD_DIR/OmniRoute.tar.gz" >/dev/null 2>&1; then
      mv -f "$AI_PAYLOAD_DIR/OmniRoute.tar.gz" "$PF_DIR/OmniRoute.tar.gz"
      echo 0 > "$PF_DIR/omniroute-tar.rc"
      echo 999999 > "$PF_DIR/omniroute-tar.pid"   # 死 pid：fetch 侧不等，直接读 rc
      echo "⚡ [ai-fetch] 直取成功（$(du -h "$PF_DIR/OmniRoute.tar.gz" | awk '{print $1}')）—— AI 栈跳过多余下载"
      exit 0
    fi
    echo "⚠️ [ai-fetch] tar 校验不过（第 ${_i} 次）"
  fi
  sleep 5
done
echo "ℹ️ [ai-fetch] 未取到 AI 整包 —— AI 栈走 Dropbox 归档（Phase 1.5 行为）"
exit 0
