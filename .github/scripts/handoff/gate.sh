#!/usr/bin/env bash
# 继任者步骤闸门（Phase 1，2026-11-10）。
# 用法: gate.sh cutover|archives_done   （调用处写 `|| true`，本脚本恒 exit 0）
#   serve 轮：直通（传统启动时序一个字节都不动）。
#   交接轮：  等旧轮 old.json 达到指定状态才放行 ——
#     cutover       隧道已随网关交出（Cloudflared Tunnel 步等这个，避免双 connector 分流）
#     archives_done 旧轮最终归档全部上传完成（上游/rsstt/归档循环等这个，
#                   保证从「旧轮的最终数据」起服务，而不是 20min 前的基座）
# 放行结果缓存（/tmp/openclaw-handoff/gate-<state>-passed），后续调用零开销。
# 超时 = 旧轮半路死了：放行 + ::warning::（用基座数据续命是比卡死更好的降级，
# 上游数据此刻无写入方，不存在丢失，只是旧）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init
handoff_is_successor || exit 0

need="${1:-archives_done}"
PASS_FILE="$HANDOFF_STATE_DIR/gate-$need-passed"
[ -f "$PASS_FILE" ] && exit 0

# 接管失败/自我放弃已在途：垫 45s 等取消落地，期间绝不放行服务启动
if [ -f "$HANDOFF_STATE_DIR/aborted" ]; then
  echo "🛑 [gate:$need] 接管已放弃，等待 run 取消落地…"
  sleep 45
  exit 0
fi

wait_state="$need"
case "$need" in
  cutover)        wait_sec=${HANDOFF_CUTOVER_WAIT_SEC} ;;
  ai_archives_done) wait_sec=${HANDOFF_ARCHIVES_WAIT_SEC} ;;
  archives_done)  wait_sec=${HANDOFF_ARCHIVES_WAIT_SEC} ;;
  *) echo "[gate:$need] 未知闸门，直接放行"; exit 0 ;;
esac

for _i in $(seq 1 $(( wait_sec / 5 ))); do
  _st="$(handoff_old_state "${HANDOFF_OF}")"
  case "$need" in
    cutover)
      case "$_st" in handing_over|handoff_done|archives_done) : > "$PASS_FILE"; exit 0 ;; esac
      ;;
    archives_done)
      case "$_st" in archives_done) : > "$PASS_FILE"; exit 0 ;; handoff_aborted) : > "$PASS_FILE"; exit 0 ;; esac
      # 2026-11-14 复核补：旧 job 在收尾中被硬上限杀死时，mark-archives-done 没跑，
      # archives_done 字段可能永远不是 true → 继任者空等 25min。
      # 只认 handoff_done（**不能**认 handing_over）：handing_over 出现在继任者
      # rsync **之前**，此时放行会让上游用 20min 前的基座起服务，破坏零丢失口径。
      # handoff_done 意味着 cutover 已收到 serving（rsync_done 早已完成、数据在手上），
      # 此时放行仅损失「旧轮最终归档」这一层备份，服务数据本身不丢。
      case "$_st" in handoff_done) : > "$PASS_FILE"; exit 0 ;; esac
      # 2026-11-11：移交成功时 state 保持 handoff_done（终态），归档完成改用
      # 独立字段 archives_done=true 表达 —— 否则闸门永远等不到（实测卡 30min，
      # 归档循环/保活被挡，watchdog 报 archive-loop 未运行）。
      case "$(handoff_old_archives_done "${HANDOFF_OF}")" in true) : > "$PASS_FILE"; exit 0 ;; esac
      ;;
    ai_archives_done)
      # 两条路取先到者：
      #   ① Phase 2 直取成功（ai-payload-fetch 已把整包播种进 prefetch 目录）
      #   ② Phase 1.5 的 Dropbox 快照完成（ai.json=done）—— 回退路径
      # 两条都指向「AI 数据已是旧轮停机后的状态」，零丢失口径不变。
      # Phase 2b 快路径：继任者已把裸卷 dump 装进命名卷（本地标记）
      if [ -f /tmp/handoff-ai-fast.ok ]; then
        : > "$PASS_FILE"; exit 0
      fi
      # Phase 2 旧快路径（整包播种，保留兼容）
      if [ -s /tmp/openclaw-prefetch/OmniRoute.tar.gz ]; then
        : > "$PASS_FILE"; exit 0
      fi
      # 2026-11-11 生产实测追加的兜底：ai.json 可能因身份闸拒跑/写入失败而缺失，
      # 但 old.json 的 archives_done 同样证明 AI 数据已上 Dropbox（归档结果 tsv 实证）
      if [ -s /tmp/openclaw-prefetch/OmniRoute.tar.gz ]; then
        : > "$PASS_FILE"; exit 0
      fi
      _ai="$(handoff_ai_state "${HANDOFF_OF}")"
      case "$_ai" in done) : > "$PASS_FILE"; exit 0 ;; esac
      _old="$(handoff_old_state "${HANDOFF_OF}")"
      case "$_old" in archives_done|handoff_done) : > "$PASS_FILE"; exit 0 ;; esac
      ;;
  esac
  sleep 5
done
echo "::warning::[gate:$need] 等旧轮 state=$wait_state 超时（${wait_sec}s，实际=${_st:-<无标记>}）—— 放行，用基座数据降级续命"
: > "$PASS_FILE"
exit 0
