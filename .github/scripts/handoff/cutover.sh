#!/usr/bin/env bash
# 旧轮交出（teardown 在「2.5 网关停稳」之后调用；Phase 1，2026-11-10）。
#
# 时序（本脚本运行期间服务下线中，每一步都在压缩 T0→新网关就绪的窗口）：
#   1. sqlite wal_checkpoint(TRUNCATE)  —— 把 -wal 并回主库，rsync 单文件一致快照
#   2. 停本机 cloudflared 隧道          —— 公网入口与网关同步死亡，继任者接管后自起
#   3. 起 rsync 只读 daemon             —— 绑 tailscale IP（公网不可达），绕开
#                                          Dropbox 单流 13MB/s 的上传天花板
#   4. old.json=handing_over → 等 new.json=serving（≤15min）
# 成功 → handoff_done：调用方跳过「Trigger next」（继任者已在跑），最终归档降级为
#        纯灾备备份、彻底移出关键路径（此时继任者已在服务，旧轮慢慢传）。
# 失败 → handoff_aborted：调用方走传统收尾（含归档+Trigger next）；继任者读到
#        该标记即自我放弃，不会出现双服。
# 返回 0=交接成功；1=未尝试或失败（调用方两种都走传统收尾）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init

SID_FILE="$HANDOFF_STATE_DIR/successor-run-id"
ENABLED="$HANDOFF_STATE_DIR/enabled"
RSYNCD_CONF="/tmp/rsyncd-handoff.conf"
RSYNCD_PID="/tmp/rsyncd-handoff.pid"

stop_rsyncd() {
  if [ -f "$RSYNCD_PID" ]; then
    kill "$(cat "$RSYNCD_PID" 2>/dev/null | tr -dc '0-9')" 2>/dev/null || true
    rm -f "$RSYNCD_PID"
  fi
  pkill -f "rsyncd-handoff.conf" 2>/dev/null || true
}

abort_handoff() { # <原因>
  echo "⛔ [cutover] 交接失败：$1 → 回退传统收尾（归档+Trigger next）"
  handoff_put "$HANDOFF_OLD_REMOTE" "$(handoff_old_json handoff_aborted "${SID:-0}" "${TS_IP:-}" "${CUTOVER_TS:-0}" "${BASE_MARKER:-0}")"
  stop_rsyncd
  exit 1
}

# ── 0. 总开关（与 tick.sh 同源；未启用则直接走传统收尾）──
if [ "${OPENCLAW_HANDOFF:-}" != "1" ]; then
  echo "ℹ️ [cutover] OPENCLAW_HANDOFF!=1，交接未启用 → 传统收尾"
  exit 1
fi

# ── 0. 预检：必须已武装，且继任者存活 ──
[ -f "$ENABLED" ] && [ -f "$SID_FILE" ] || { echo "ℹ️ [cutover] 未武装交接，走传统收尾"; exit 1; }
SID="$(cat "$SID_FILE" 2>/dev/null | tr -dc '0-9')"
[ -n "$SID" ] || abort_handoff "继任者 run id 缺失"
case "$(handoff_run_status "$SID")" in
  completed|failure|cancelled) abort_handoff "继任者 run=$SID 已终止" ;;
esac

# 非托管 daemon（测试/sudo 场景）下 runner 用户可能读不到 CLI socket，sudo 兜底
TS_IP="$( { tailscale ip -4 2>/dev/null || sudo -n tailscale ip -4 2>/dev/null; } | head -n 1 | tr -d '[:space:]')"
[ -n "$TS_IP" ] || abort_handoff "拿不到本机 tailscale IP"
CUTOVER_TS=$(date +%s)
BASE_MARKER="$(cat /tmp/openclaw-archive-marker.openclaw 2>/dev/null | tr -dc '0-9')"
BASE_MARKER="${BASE_MARKER:-0}"

# ── 0.5 继任者未就绪就到了死线（优雅重启早于 T-12min 触发等）：最多再等 5min ──
_ns="$(handoff_new_state "$SID")"
# 继任者已自我放弃 = 无需再等，立刻回退（否则要白等 5min，服务白白多停 5 分钟）
if [ "$_ns" = "aborted" ]; then
  abort_handoff "继任者已自我放弃（state=aborted）"
fi
if ! printf '%s' "$_ns" | grep -qE '^(ready|rsync_started|rsync_done|serving)$'; then
  echo "⏳ [cutover] 继任者尚未 ready（state=${_ns:-<无标记>}），最多再等 5min…"
  _ok=0
  for _i in $(seq 1 60); do
    _ns="$(handoff_new_state "$SID")"
    if printf '%s' "$_ns" | grep -qE '^(ready|rsync_started|rsync_done|serving)$'; then _ok=1; break; fi
    if [ "$_ns" = "aborted" ]; then abort_handoff "继任者已自我放弃（state=aborted）"; fi
    case "$(handoff_run_status "$SID")" in completed|failure|cancelled) break ;; esac
    sleep 5
  done
  [ "$_ok" = "1" ] || abort_handoff "继任者 5min 内未就绪"
fi

# ── 1. sqlite checkpoint：网关已停、写入方清零，-wal 并回主库 ──
# 用 timeout 兜底：checkpoint 卡住不能拖死整个交出（rsync 照传 wal 文件，只是多搬一点）
_checkpoint_db() {
  local db="$1"
  [ -f "$db" ] || return 0
  timeout 30 sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>&1 \
    || echo "⚠️ [cutover] checkpoint 失败（继续，rsync 会连 wal 一起传）: $db"
}
_checkpoint_db "$HOME/.openclaw/state/openclaw.sqlite"
for _db in "$HOME"/.openclaw/agents/*/agent/openclaw.sqlite; do
  [ -e "$_db" ] || continue
  _checkpoint_db "$_db"
done
# zcode 侧：只处理存在非空 -wal 的库（写入方为 openclaw 拉起的 zcode 工具进程，网关停即静默）
while IFS= read -r _db; do
  [ -n "$_db" ] || continue
  _checkpoint_db "$_db"
done < <(find "$HOME/.zcode" -name '*.sqlite-wal' -size +0c -printf '%h\n' 2>/dev/null \
  | sed 's/-wal$//' | sort -u)
echo "✅ [cutover] sqlite checkpoint 完成"

# ── 2. 停本机自愈看门狗（必须在停隧道/停 AI 栈**之前**）──
# openclaw-health 有「cftun-* 隧道自愈」：停掉的隧道 ≤5min 内会被它 sudo start
# 拉回来 → 旧 VM 的 cloudflared connector 重新并入隧道 → 流量可能被路由到
# 已停网关的旧机（用户侧表现为随机 5xx）。gateway-watchdog 只告警不重启，
# zcode2api-proxy-watchdog 会拉起 node 代理 —— 一并暂停。旧 VM 随 job 销毁，
# 无需恢复；继任 VM 的看门狗由新 run 自己安装（自带启动宽限期）。
systemctl --user stop openclaw-health.timer gateway-watchdog.timer \
  zcode2api-proxy-watchdog.timer 2>/dev/null || true
echo "✅ [cutover] 本机自愈看门狗已暂停（防交接期间拉回隧道/服务）"

# ── 2b. 停**全部**服务与入口（2026-11-11 主人定调）──
# 原则：切换空窗期不留半活状态。只要旧实例还在跑，就存在「继任者已按 T0 快照恢复、
# 旧实例继续写盘 → 这些写入随 VM 销毁永久丢失」的窗口。所以交出即全停，
# 由继任者确认切换成功后统一拉起（与其零丢失口径完全一致）。
#
# 顺序：先停服务（让它落盘干净），再停入口（避免入口指向已停服务）。
# ① 先停「写 ~/.zcode/cli/db/db.sqlite 的进程」—— 它是会话真源（2026-11-11 实证：
#   session/message/part 都在此），且实测有 4.1MB 活跃 -wal。不停就抓活体库，
#   rsync 会把撕裂快照或停机后的写入丢掉。WorkBuddy Server 的单元名带随机后缀，
#   用通配停；zcode-cli 是裸进程，pkill 兜底。
for _u in $(systemctl --user list-units --all --plain --no-legend 'com.zhipu.zcode.server.*.service' 2>/dev/null | awk '{print $1}'); do
  systemctl --user stop "$_u" >/dev/null 2>&1 || true
done
pkill -x zcode-cli 2>/dev/null || true
sleep 2
# checkpoint：复用本文件上方已有的 _checkpoint_db（与 openclaw 侧同款口径），
# 把 -wal 并回主库，rsync 抓到的是一致静树
_checkpoint_db "$HOME/.zcode/cli/db/db.sqlite"
_checkpoint_db "$HOME/.zcode/v2/tasks-index.sqlite"
echo "✅ [cutover] WorkBuddy Server / zcode-cli 已停，db.sqlite 已 checkpoint"

# ①b autoclaw 累计用量回推（必须在停进程之前：运行中该文件被周期改写，
#    停止前的最后一次读取即终值）。原在收尾批2 的同一位置；现在批2 在交接轮
#    被跳过，故把这一步挪到交出侧，保证 OPENCLAW_AI_EARLY=0 时也不丢统计。
_stats_local=/dropbox/self-hosted/autoclaw-proxy/app/lifetime_stats.json
_stats_remote="${AUTOCLAW_STATS_REMOTE:-dropbox:self-hosted/autoclaw-proxy/lifetime_stats.json}"
if [ -f "$_stats_local" ]; then
  rclone copyto "$_stats_local" "$_stats_remote" >/dev/null 2>&1 \
    && echo "✅ [cutover] autoclaw lifetime_stats 已回推" \
    || echo "⚠️ [cutover] autoclaw stats 回推失败（下轮启动以本地残留续计）"
fi

# ② 其余服务与入口
for _s in workbuddy zcode2api qingyan autoclaw quota-board; do
  bash "$GITHUB_WORKSPACE/.github/scripts/services/services.sh" stop "$_s" >/dev/null 2>&1 || true
done
for _c in omniroute rss-to-telegram trae2api qoder2api; do
  docker stop "$_c" >/dev/null 2>&1 || true
done
sudo systemctl stop cftun-oc.service cftun-qb.service cftun-ai-api.service 2>/dev/null || true
echo "✅ [cutover] 全部服务与入口已停（切换空窗期不留半活实例）"

# ── 3. rsync 只读 daemon（绑 tailscale IP；模块 oc/zc 映射状态树，ai 放 AI 整包）──
mkdir -p /tmp/handoff-ai-payload
cat > "$RSYNCD_CONF" <<EOF_RSYNC
port = ${HANDOFF_RSYNC_PORT}
address = ${TS_IP}
pid file = ${RSYNCD_PID}
log file = /tmp/rsyncd-handoff.log
use chroot = no
[oc]
    path = ${HOME}/.openclaw
    read only = yes
    comment = openclaw state (handoff source)
[zc]
    path = ${HOME}/.zcode
    read only = yes
    comment = zcode state (handoff source)
[ai]
    # Phase 2：放「交出瞬间现做的 OmniRoute 整包」（含 compose/.env + data.tar.gz）。
    # 继任者用 rsync 直取这个包，交给**原有** restore 逻辑消费（校验+载入命名卷），
    # 传输方式换了、恢复语义一行没动；取不到就退回 Dropbox 归档（ai.json 路径）。
    # 注意：绝不能只铺 ~/omniroute 目录 —— 数据在命名卷里，只铺目录会让
    # restore 的「部署目录已就绪」短路命中空卷，等于丢数据。
    path = /tmp/handoff-ai-payload
    read only = yes
    comment = omniroute archive tarball (Phase 2 fast path)
EOF_RSYNC
rsync --daemon --config="$RSYNCD_CONF" 2>/dev/null || true
# daemon fork 后子进程绑定有亚秒级延迟，轮询等它。⚠️ 锚点用 [[:space:]] 而非 $：
# ss 输出是「LISTEN 0 5 127.0.0.1:8730 0.0.0.0:*」，本地地址列在行中间，
# 用 8730$ 锚行尾恒不匹配（合成测试实测：daemon 已监听但检查恒假）。
_listen_ok=0
for _i in $(seq 1 20); do
  if ss -tln 2>/dev/null | grep -qE "[:.]${HANDOFF_RSYNC_PORT}([[:space:]]|\$)"; then _listen_ok=1; break; fi
  sleep 0.5
done
[ "$_listen_ok" = "1" ] \
  || abort_handoff "rsync daemon 未监听 ${HANDOFF_RSYNC_PORT}（日志: $(tail -n 3 /tmp/rsyncd-handoff.log 2>/dev/null | tr '\n' ' '))"
echo "✅ [cutover] rsync 源就绪（${TS_IP}:${HANDOFF_RSYNC_PORT}，只读，仅 tailnet 可达）"

# ── 4. 交出标记 → 等 serving ──
handoff_put "$HANDOFF_OLD_REMOTE" "$(handoff_old_json handing_over "$SID" "$TS_IP" "$CUTOVER_TS" "$BASE_MARKER")"
# ── 3.5 Phase 1.5（必须在 handing_over 之后：ai-archives 用 old.json 的
# ownership 自证「本机确是本轮旧轮」，先启会读到上一轮 owner 而拒跑 —— 实测踩到）：后台快照 AI 栈（停服+归档+上传），与继任者 rsync 并行 ──
# 位置：紧随 handing_over 之后（既让 ai-archives 的 ownership 自检能通过，
# 又不拖慢交出）。失败不影响交出本身（继任者 gate 超时降级）。
# 2026-11-10：默认**不**在交出瞬间停 AI 栈 —— 实测快照要 ~8min，比「AI 栈在线到
# 归档后、继任者等 archives_done」（~213s）更慢。只有 OPENCLAW_AI_EARLY=1 才启用。
if [ "${OPENCLAW_AI_EARLY:-}" = "1" ] && [ -f "$GITHUB_WORKSPACE/.github/scripts/handoff/ai-archives.sh" ]; then
  setsid nohup bash "$GITHUB_WORKSPACE/.github/scripts/handoff/ai-archives.sh" \
    >>/tmp/handoff-ai-archives.log 2>&1 < /dev/null &
  disown 2>/dev/null || true
  echo "🚀 [cutover] AI 栈快照已后台开跑（与 rsync 并行）"
fi


echo "🤝 [cutover] 已交出（handing_over），等继任者 serving（≤${HANDOFF_SERVING_WAIT_SEC}s）…"
bash "$GITHUB_WORKSPACE/.github/scripts/handoff/handoff-notify.sh" cutover \
  "old_run=${GITHUB_RUN_ID}" "new_run=${SID}" || true
_chk=0
for _i in $(seq 1 $(( HANDOFF_SERVING_WAIT_SEC / 5 ))); do
  _ns="$(handoff_new_state "$SID")"
  case "$_ns" in
    serving)
      handoff_put "$HANDOFF_OLD_REMOTE" "$(handoff_old_json handoff_done "$SID" "$TS_IP" "$CUTOVER_TS" "$BASE_MARKER")"
      stop_rsyncd
      echo "🎉 [cutover] 继任者已 serving → handoff_done（本轮回退为纯备份收尾，不再 Trigger next）"
      exit 0
      ;;
    aborted)
      # 继任者主动放弃（rsync 失败/校验失败）：立刻回退，不必等 run 状态或 15min 超时。
      # 每 5s 轮询一次，最坏 5s 就知道，把暂停的服务尽快拉回传统收尾。
      abort_handoff "继任者自我放弃（state=aborted）"
      ;;
  esac
  _chk=$((_chk + 1))
  if [ $((_chk % 12)) -eq 0 ]; then   # 每 60s 看一眼继任者死活
    case "$(handoff_run_status "$SID")" in
      completed|failure|cancelled) abort_handoff "等待期间继任者 run=$SID 终止（state=${_ns:-<无标记>}）" ;;
    esac
  fi
  sleep 5
done
abort_handoff "等 serving 超时（${HANDOFF_SERVING_WAIT_SEC}s，state=${_ns:-<无标记>}）"
