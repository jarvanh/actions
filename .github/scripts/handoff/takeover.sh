#!/usr/bin/env bash
# 继任者接管（workflow「Handoff takeover」步骤本体；Phase 1，2026-11-10）。
# 在「Install Cloudflared」之后、「上游服务」各步之前执行 —— 上游各步带 gate，
# 会在本步放行后才真正起服务，保证它们读到旧轮的最终归档而非 20min 前的基座。
#
# 流程：ready 标记 → 等旧轮 handing_over（≤25min，盯旧轮 run 死活）→
#       rsync 增量直传（oc ∥ zc，绕开 Dropbox 单流）→ state 库 quick_check →
#       rsync_done 标记。之后 workflow 继续走原启动链（网关在 Run OpenClaw 起来）。
# 任一环失败 → 自我取消整个 run（gh run cancel 是 step 内终止 job 的唯一手段），
# 数据零丢失由旧轮的传统收尾兜底（归档照常上传，cron/下一轮从归档恢复）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init

# serve 轮直通（YAML 的 if 已闸一层，这里兜底）
handoff_is_successor || { echo "ℹ️ [takeover] 非 handoff 轮，跳过"; exit 0; }

EXCLUDES="/tmp/handoff-oc-excludes.txt"
cat > "$EXCLUDES" <<'EOF_EXCL'
logs/**
cache/**
browser/*/Crashpad/**
browser/*/GPUCache/**
browser/*/Code Cache/**
browser/*/GrShaderCache/**
browser/*/GraphiteDawnCache/**
SingletonLock
SingletonSocket
SingletonCookie
*.lock
*.pid
*.jsonl.lock
EOF_EXCL
# ↑ 与 create-openclaw-archive.sh 的 rsync 排除清单逐条一致（改那边同步改这里）：
#   两份排除语义必须相同，否则「基座+增量」与「归档包」内容口径分叉。

abort_takeover() { # <原因>
  echo "⛔ [takeover] 接管失败：$1 → 自我取消（数据由旧轮传统收尾兜底，零丢失）"
  handoff_put "$HANDOFF_NEW_REMOTE" "$(handoff_new_json aborted)"
  : > "$HANDOFF_STATE_DIR/aborted"
  gh run cancel "${GITHUB_RUN_ID}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1 || true
  sleep 30   # 给取消传播留时间；若仍在跑，后续 gate 会再垫 45s
  exit 1
}

echo "[takeover] 继任轮接管开始（old_run=${HANDOFF_OF}）"

# ── 1. 基座在场校验（Install OpenClaw / Restore ZCode 都在前序步骤完成）──
[ -s "$HOME/.openclaw/openclaw.json" ] || abort_takeover "主包基座未恢复（~/.openclaw/openclaw.json 缺失）"

# ── 2. ready 标记：旧轮的 T-4min 看门狗认的就是它 ──
handoff_put "$HANDOFF_NEW_REMOTE" "$(handoff_new_json ready)"
echo "✅ [takeover] ready 已写（等旧轮死线交出，≤${HANDOFF_CUTOVER_WAIT_SEC}s）"

# ── 3. 等 CUTOVER（盯标记 + 盯旧轮 run 死活）──
_ns=""
_ok=0
for _i in $(seq 1 $(( HANDOFF_CUTOVER_WAIT_SEC / 5 ))); do
  _ns="$(handoff_old_state "${HANDOFF_OF}")"
  case "$_ns" in
    handing_over) _ok=1; break ;;
    handoff_done|handoff_aborted) abort_takeover "旧轮标记已到 $_ns（交接已被回退）" ;;
  esac
  if [ $((_i % 6)) -eq 0 ]; then   # 每 30s 看一眼旧轮死活：死了就早放弃，把恢复让给 cron
    case "$(handoff_run_status "${HANDOFF_OF}")" in
      completed|failure|cancelled) abort_takeover "旧轮 run=${HANDOFF_OF} 已 $_ns 未交出（提前死/被取消）" ;;
    esac
  fi
  sleep 5
done
[ "$_ok" = "1" ] || abort_takeover "等 CUTOVER 超时（${HANDOFF_CUTOVER_WAIT_SEC}s，旧轮 state=${_ns:-<无标记>}）"
OLD_TS_IP="$(rclone cat "$HANDOFF_OLD_REMOTE" 2>/dev/null | jq -r '.old_ts_ip // empty' 2>/dev/null | head -n 1)"
case "${OLD_TS_IP:-}" in ''|*[!0-9.]*) abort_takeover "handing_over 缺 old_ts_ip" ;; esac
echo "🤝 [takeover] 旧轮已交出（rsync 源 ${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}）"

# ── 4. 增量直传（oc ∥ zc 两路并行；基座是 ≤20min 前的周期包，实际传的是 delta）──
handoff_put "$HANDOFF_NEW_REMOTE" "$(handoff_new_json rsync_started)"
_zc_rc=0
( timeout 780 rsync -a --delete --timeout=60 --stats \
    rsync://"${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}"/zc/ "$HOME/.zcode/" 2>&1 \
  | tail -n 4; exit "${PIPESTATUS[0]}" ) > /tmp/handoff-rsync-zc.log 2>&1 & _zc_pid=$!
_rs_t0=$(date +%s)
if ! timeout 780 rsync -a --delete --exclude-from="$EXCLUDES" --timeout=60 --stats \
      rsync://"${OLD_TS_IP}:${HANDOFF_RSYNC_PORT}"/oc/ "$HOME/.openclaw/" > /tmp/handoff-rsync-oc.log 2>&1; then
  wait "$_zc_pid" 2>/dev/null || true
  abort_takeover "openclaw 增量 rsync 失败（$(tail -n 3 /tmp/handoff-rsync-oc.log 2>/dev/null | tr '\n' ' ')）"
fi
wait "$_zc_pid" || _zc_rc=$?
_rs_t1=$(date +%s)
_rs_bytes=$(awk -F': ' '/^Total transferred file size/{gsub(/,/,"",$2); print $2+0}' /tmp/handoff-rsync-oc.log 2>/dev/null | head -1)
_rs_bytes="${_rs_bytes:-0}"
_rs_sec=$(( _rs_t1 - _rs_t0 )); [ "$_rs_sec" -gt 0 ] || _rs_sec=1
echo "📊 [takeover] oc rsync: $(grep -E 'Number of regular files transferred' /tmp/handoff-rsync-oc.log 2>/dev/null | tr '\n' ' ')"
# 吞吐是「真实下线时长」的唯一未知量：每次交接都记下来，用于校准生产预期
echo "📊 [takeover] oc 传输量 $(( _rs_bytes / 1048576 ))MB / ${_rs_sec}s = $(( _rs_bytes / 1048576 / _rs_sec ))MB/s"
echo "📊 [takeover] zc rsync: $(grep -E 'total transferred file size|Number of regular files transferred' /tmp/handoff-rsync-zc.log 2>/dev/null | tr '\n' ' ')"
[ "$_zc_rc" = "0" ] || abort_takeover "zcode 增量 rsync 失败 rc=$_zc_rc（$(tail -n 3 /tmp/handoff-rsync-zc.log 2>/dev/null | tr '\n' ' ')）"

# ── 4.5 Phase 2：AI 整包直取（**后台**，不占聊天路径）──
# 关键：这段绝不能同步等 —— 旧轮要先停 AI 栈再打包，最坏 2-3 分钟；
# 放在关键路径上会直接拖长聊天路径的下线时长（本末倒置）。
# 后台取到就播种 prefetch（AI 栈跳过 Dropbox 下载），取不到 gate 自动回退。
if [ -f "$here/ai-payload-fetch.sh" ]; then
  setsid nohup bash "$here/ai-payload-fetch.sh" "${OLD_TS_IP}" \
    >/dev/null 2>&1 < /dev/null &
  disown 2>/dev/null || true
  echo "🚀 [takeover] AI 整包后台直取已启动（不阻塞上线）"
fi

# ── 5. 一致性校验：主 state 库 inline 快查（其余 agent 库由 serving 侧后台查）──
_qc="$(timeout 60 sqlite3 "$HOME/.openclaw/state/openclaw.sqlite" 'PRAGMA quick_check;' 2>&1 | head -n 1 || true)"
[ "$_qc" = "ok" ] || abort_takeover "state/openclaw.sqlite quick_check 异常（${_qc:-<无输出>}）"

# 2026-11-10 窗口收口：rsync 慢于旧轮的 15min 上限时，旧轮可能已经 abort 并回退传统
# 收尾（归档 + Trigger next）。此刻若还照原始计划起服务，就会出现「继任者 + 旧轮接力
# 起来的新 run」双服。故在宣布 rsync_done 前再核一次交出状态：只有仍是 handing_over
# 才允许上线；aborted/archives_done/handoff_done 一律放弃。
_st_final="$(handoff_old_state "${HANDOFF_OF}")"
if [ "$_st_final" != "handing_over" ]; then
  abort_takeover "rsync 完成后发现旧轮已回退（state=${_st_final:-<无标记>}），放弃上线避免双服"
fi

handoff_put "$HANDOFF_NEW_REMOTE" "$(handoff_new_json rsync_done)"
echo "✅ [takeover] 增量已同步并校验（rsync_done）—— 后续步骤用同步后的状态启动服务"
exit 0
