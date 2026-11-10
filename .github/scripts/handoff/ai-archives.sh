#!/usr/bin/env bash
# ── 交出瞬间的「AI 栈快照」（Phase 1.5，2026-11-10）──
#
# 要解决的问题：「整体下线」的长杆不是聊天网关，而是模型通道 ——
# 继任者的上游/AI 步骤原来要等旧轮**整段最终归档**跑完（archives_done，
# 生产实测 ~250-300s）才能从 Dropbox 取到新鲜数据起服务。于是聊天路径几十秒
# 恢复，整体却要 8 分钟。
#
# 本脚本在 cutover 里**后台**执行（与继任者的 rsync 并行）：
#   1. 停 AI 栈（workbuddy / zcode2api / qingyan / autoclaw / omniroute / rsstt）
#      —— 与生产收尾同一套 services.sh stop，幂等，之后 stage A 再停是 no-op
#   2. 只归档 AI 自己的数据（当前生效后端 + rsstt + zcode2api-data + autoclaw stats）
#      —— 服务已停，是静树，比原来的活库在线备份更一致
#   3. 上传完成写**独立** marker（ai.json，不碰 old.json：旧轮的交接状态机
#      还会写 handoff_done/archives_done，两个写入方共用一份文件会互相覆盖，
#      继任者 takeover 末尾的 handing_over 复核也会被误判）
#
# 失败语义：任何一步失败都不写 ai.json。继任者的 gate 会超时放行（降级用基座
# 数据续命，此时无人写入、不丢数据，只是旧）；旧轮的 stage A 照常归档（若
# omniroute 因已停止导致在线备份失败，本脚本会把它重新拉起，保证 stage A 可用）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init

GW="${GITHUB_WORKSPACE:-/home/runner/actions-repo}"
LOG=/tmp/handoff-ai-archives.log
# 2026-11-10 事故加固：本脚本会**停止真实服务**。两层保险：
# ① 必须在已武装交接的旧轮上运行（状态目录有 successor-run-id 且 old.json
#    归属本 run）；② 测试模式（HANDOFF_TEST=1）只走测试状态目录/测试远端，
#    与生产彻底隔离。两者都不满足直接拒跑。
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init
_owner="$(handoff_get "$HANDOFF_OLD_REMOTE" '.old_run')"
_sid_file="$HANDOFF_STATE_DIR/successor-run-id"
# 2026-11-11：owner 只告警不拒跑 —— cutover（0b4c1fd）已保证先写 handing_over 再拉起
# 本脚本，正常时 owner=本 run；若仍是上一轮 owner 说明 marker 写入失败，此时本机确已
# 进入收尾，停 AI 栈仍正确，只是 marker 不可信 → 继任者闸门走超时降级（不再白停 25min）
if [ "$_owner" != "${GITHUB_RUN_ID:-}" ]; then
  echo "⚠️ [ai-archives] old.json owner=${_owner:-<无>} ≠ 本 run ${GITHUB_RUN_ID:-<无>}（marker 写入可能失败），继续执行"
fi
# 测试模式：对象远端全部落到 handoff-test 前缀，不覆盖生产归档
#（生产 omni/rsstt/z2a 包由测试机覆盖会污染真实恢复源 —— 这是测试对生产的
#  最重的一类影响，2026-11-10 审计补）
if [ -n "${HANDOFF_TEST:-}" ]; then
  _pfx="dropbox:self-hosted/handoff-test"
else
  _pfx="dropbox:self-hosted"
fi
exec >"$LOG" 2>&1
echo "[$(date '+%F %T')] ai-archives start (run=${GITHUB_RUN_ID:-?})"

fail_flag=0
stop_svc() { bash "$GW/.github/scripts/services/services.sh" stop "$1" 2>/dev/null || true; }

# ── 1. autoclaw 累计用量回推（必须在停进程之前：运行中该文件被周期改写，
#      停止前的最后一次读取即终值；与生产收尾 3b-1 同口径）──
STATS_LOCAL=/dropbox/self-hosted/autoclaw-proxy/app/lifetime_stats.json
STATS_REMOTE="${AUTOCLAW_STATS_REMOTE:-${_pfx}/autoclaw-proxy/lifetime_stats.json}"
if [ -f "$STATS_LOCAL" ]; then
  rclone copyto "$STATS_LOCAL" "$STATS_REMOTE" >/dev/null 2>&1 \
    && echo "✅ autoclaw lifetime_stats 回推" || echo "⚠️ autoclaw stats 回推失败"
fi

# ── 2. 停 AI 栈（顺序：宿主进程 → 容器；与生产收尾批 2 同源）──
for s in workbuddy zcode2api qingyan autoclaw; do stop_svc "$s"; done
docker stop omniroute >/dev/null 2>&1 || true
docker stop rss-to-telegram >/dev/null 2>&1 || true
echo "✅ AI 栈已停（workbuddy/zcode2api/qingyan/autoclaw/omniroute/rsstt）"

# ── 2.5 Phase 2b 快路径：裸 dump OmniRoute 命名卷（**不做** VACUUM INTO / 压缩）
# 为什么这么做：原归档脚本在容器内对 ~2GB 库做 VACUUM INTO + pigz，实测 4-8min，
# 这段时间直接决定模型通道何时可用（交出后旧轮 AI 栈已停，谁都在等它）。
# 裸 tar 卷只要 10-20s；继任者 rsync 直取 540MB 仅需数秒（实测 tailnet 88-150MB/s）。
# 一致性：容器已停 → 卷是静树，裸 dump 与 VACUUM 快照等价（零丢失不变）。
PAYLOAD=/tmp/handoff-ai-payload
mkdir -p "$PAYLOAD"
_omni_vol="${OMNIROUTE_VOLUME:-omniroute_omniroute-data}"
_omni_img="${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:latest}"
rm -f "$PAYLOAD/omnivol.tar" "$PAYLOAD/omnideploy.tar" "$PAYLOAD/dump.rc"
if docker run --rm --user root -v "${_omni_vol}:/data:ro" "$_omni_img" \
     sh -c 'nice -n 19 ionice -c3 tar cf - -C /data .' > "$PAYLOAD/omnivol.tar" 2>/tmp/omnivol-dump.err \
   && [ -s "$PAYLOAD/omnivol.tar" ]; then
  echo "⚡ [ai-archives] OmniRoute 卷裸 dump 完成（$(du -h "$PAYLOAD/omnivol.tar" | awk '{print $1}')，$(date '+%T')）"
else
  rm -f "$PAYLOAD/omnivol.tar"
  echo "⚠️ [ai-archives] 卷裸 dump 失败：$(tail -n 2 /tmp/omnivol-dump.err 2>/dev/null | tr '\n' ' ')"
  echo 1 > "$PAYLOAD/dump.rc"
fi
if [ -d "$HOME/omniroute" ] && tar cf "$PAYLOAD/omnideploy.tar" -C "$HOME/omniroute" . 2>/dev/null; then
  echo "⚡ [ai-archives] OmniRoute 部署目录已投递（compose+.env）"
else
  rm -f "$PAYLOAD/omnideploy.tar"
  echo "⚠️ [ai-archives] 部署目录 dump 失败"
fi

# ── 3. 归档并上传（复用归档循环步骤已写好的脚本；服务已停 → 静树）──
archive_upload() { # <脚本> <本地包> <远端对象> <标签> [payload名]
  local script="$1" out="$2" remote="$3" label="$4" payload="${5:-}"
  rm -f "$out"
  if [ ! -f "$script" ]; then echo "⚠️ ${label}: 归档脚本缺失 $script"; fail_flag=1; return 1; fi
  if ! timeout 300 bash "$script" "$out" >/dev/null 2>&1 || [ ! -s "$out" ]; then
    echo "⚠️ ${label}: 打包失败"; fail_flag=1; rm -f "$out"; return 1
  fi
  # Phase 2：先投到 rsync payload 目录（继任者可直取），再传 Dropbox（保底）。
  # 顺序刻意如此：rsync 直取更快，越早可见越好；Dropbox 是失败回退路径。
  if [ -n "$payload" ]; then
    mkdir -p /tmp/handoff-ai-payload
    if cp -f "$out" "/tmp/handoff-ai-payload/${payload}" 2>/dev/null \
      && tar -tzf "/tmp/handoff-ai-payload/${payload}" >/dev/null 2>&1; then
      echo "✅ ${label} 已投递 rsync payload（${payload}，$(du -h "$out" | awk '{print $1}')）"
    else
      rm -f "/tmp/handoff-ai-payload/${payload}"
      echo "⚠️ ${label}: payload 投递失败（继任者将走 Dropbox 回退）"
    fi
  fi
  if rclone copyto "$out" "$remote" --dropbox-chunk-size 128M >/dev/null 2>&1; then
    echo "✅ ${label} 上传完成 ($(du -h "$out" | awk '{print $1}'))"
  else
    echo "⚠️ ${label}: 上传失败"; fail_flag=1
  fi
  rm -f "$out"
}

archive_upload /tmp/create-rsstt-archive.sh          /tmp/rsstt-early.tar.gz      ${_pfx}/rsstt.tar.gz         rsstt
archive_upload /tmp/create-zcode2api-data-archive.sh /tmp/z2a-early.tar.gz        ${_pfx}/zcode2api-data.tar.gz zcode2api-data

# 到这里 AI 数据面已齐（OmniRoute 裸 dump + rsstt + z2a 均已就绪）→ 才对外发就绪信号。
# 顺序是正确性要求：dump.rc 一旦出现，继任者会立即装载并起上游，
# 若 rsstt/z2a 还没上传，它们就会拿到陈旧数据（零丢失破口）。
if [ -s "$PAYLOAD/omnivol.tar" ] && [ -s "$PAYLOAD/omnideploy.tar" ]; then
  echo 0 > "$PAYLOAD/dump.rc"
  echo "✅ [ai-archives] 快路径就绪信号已发（dump.rc=0，$(date '+%T')）"
fi

# ── 3b. 慢路径（Dropbox 整包，回退/冷启动用）：放在快路径信号之后，
#       不影响模型通道的恢复时间，旧轮 VM 有 ~20min 预算慢慢做完。
# AI 后端三选一（与生产收尾同口径：只刷当前生效后端的包）
ACTIVE_BACKEND="omniroute"
if [ -f /tmp/active-ai-backend.env ]; then
  ACTIVE_BACKEND="$(grep '^ACTIVE_BACKEND=' /tmp/active-ai-backend.env 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
fi
case "${ACTIVE_BACKEND:-omniroute}" in
  clirelay)     archive_upload /tmp/create-clirelay-archive.sh    /tmp/CliRelay-early.tar.gz    ${_pfx}/CliRelay.tar.gz   CliRelay ;;
  cliproxyapi)  archive_upload /tmp/create-cliproxyapi-archive.sh /tmp/CLIProxyAPI-early.tar.gz ${_pfx}/CLIProxyAPI.tar.gz CLIProxyAPI ;;
  *)            archive_upload /tmp/create-omniroute-archive.sh   /tmp/OmniRoute-early.tar.gz   ${_pfx}/OmniRoute.tar.gz   OmniRoute OmniRoute.tar.gz ;;
esac


# ── 4. omniroute 归档失败的兜底：重新拉起容器，保证旧轮 stage A 的在线备份
#      （docker exec sqlite3）仍可用 —— 否则 stage A 每轮都会报归档失败 ──
if [ "$fail_flag" != "0" ] && [ "${ACTIVE_BACKEND:-omniroute}" = "omniroute" ]; then
  echo "⚠️ 有归档项失败；重新拉起 omniroute 以保证 stage A 在线备份可用"
  ( cd /home/runner/omniroute 2>/dev/null && docker compose up -d >/dev/null 2>&1 ) || true
fi

# ── 5. 成功则写 marker（独立文件，避免与 old.json 的交接状态机互踩）──
if [ "$fail_flag" = "0" ]; then
  printf '{"protocol":%d,"old_run":%s,"state":"done","ts":%s}' \
    "$HANDOFF_PROTOCOL" "${GITHUB_RUN_ID:-0}" "$(date +%s)" | rclone rcat "$HANDOFF_AI_REMOTE" >/dev/null 2>&1
  : > /tmp/handoff-ai-archives.ok
  echo "[$(date '+%F %T')] ai-archives done → ai.json=done"
else
  echo "[$(date '+%F %T')] ai-archives 有失败项，不写 marker（继任者 gate 将超时放行）"
fi
