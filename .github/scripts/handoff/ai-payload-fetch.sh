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
# 日志同时落盘与回流：setsid 子进程默认不进 step 日志，排障时会「看起来什么都没发生」。
# 用 tee 写一份 /tmp，并经由调用方给的 FIFO/文件回流（见 takeover.sh 的重定向）。
exec >>/tmp/handoff-ai-fetch.log 2>&1
echo "[$(date '+%F %T')] ai-fetch pid=$$ src=${1:-?}"
echo "[$(date '+%F %T')] ai-fetch start (src ${OLD_TS_IP}:${HANDOFF_RSYNC_PORT})"

OMNI_VOL="${OMNIROUTE_VOLUME:-omniroute_omniroute-data}"
OMNI_IMG="${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:latest}"
DEB_DIR="$HOME/omniroute"

# ── Phase 2b 快路径：取「裸卷 dump」并装进同名卷 ──
# 旧轮在交出瞬间停 AI 栈后直接 tar 卷（不做 VACUUM/压缩，10-20s 完成），
# 这里 rsync 直取（540MB，实测 88-150MB/s）+ 解包进卷，全程 ~15-30s。
# 一致性：旧轮容器已停，卷是静树 → 裸 dump 与 VACUUM 快照等价。
for _i in $(seq 1 36); do   # 最多 180s
  if timeout 120 rsync -a --timeout=60 \
      "rsync://${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}/ai/" "$AI_PAYLOAD_DIR/" >/dev/null 2>&1 \
     && [ -f "$AI_PAYLOAD_DIR/dump.rc" ]; then
    if [ "$(cat "$AI_PAYLOAD_DIR/dump.rc" 2>/dev/null)" != "0" ] \
       || [ ! -s "$AI_PAYLOAD_DIR/omnivol.tar" ] || [ ! -s "$AI_PAYLOAD_DIR/omnideploy.tar" ]; then
      echo "⚠️ [ai-fetch] 旧轮 dump 失败（rc=$(cat "$AI_PAYLOAD_DIR/dump.rc" 2>/dev/null)），走 Dropbox 回退"
      break
    fi
    # 校验 tar 完整性（截断包绝不装载）
    if ! tar tf "$AI_PAYLOAD_DIR/omnivol.tar" >/dev/null 2>&1 \
       || ! tar tf "$AI_PAYLOAD_DIR/omnideploy.tar" >/dev/null 2>&1; then
      echo "⚠️ [ai-fetch] dump 包校验不过（第 ${_i} 次）"
      sleep 5; continue
    fi
    # ① 部署目录（compose + .env）：让 run-ai-gateway 的 restore 走「已就绪」短路
    mkdir -p "$DEB_DIR"
    if ! tar xf "$AI_PAYLOAD_DIR/omnideploy.tar" -C "$DEB_DIR" 2>/dev/null; then
      echo "⚠️ [ai-fetch] 部署目录解包失败，走 Dropbox 回退"; break
    fi
    # ② 装载命名卷
    docker volume create "$OMNI_VOL" >/dev/null 2>&1 || true
    if docker run --rm --user root -v "${OMNI_VOL}:/target" -v "$AI_PAYLOAD_DIR:/src:ro" "$OMNI_IMG" \
         sh -c 'nice -n 19 ionice -c3 tar xf /src/omnivol.tar -C /target' >/dev/null 2>&1 \
       && docker run --rm --user root -v "${OMNI_VOL}:/data:ro" "$OMNI_IMG" \
            sh -c 'test -s /data/storage.sqlite -o -s /data/server.env' >/dev/null 2>&1; then
      : > /tmp/handoff-ai-fast.ok
      echo "⚡ [ai-fetch] 卷直装完成（$(du -h "$AI_PAYLOAD_DIR/omnivol.tar" | awk '{print $1}')）—— AI 栈走快路径，跳过 Dropbox"
      exit 0
    fi
    echo "⚠️ [ai-fetch] 卷装载失败（第 ${_i} 次）"
  fi
  sleep 5
done
echo "ℹ️ [ai-fetch] 快路径未就绪 —— AI 栈走 Dropbox 归档（Phase 1.5 行为）"
exit 0
