#!/usr/bin/env bash
# ── 交接协议 · 实测·旧轮侧（测试 workflow 专用，2026-11-10）──
# 在真 runner 上扮演「serving 旧轮」：造真实结构的状态树 → 打基座包（模拟周期包）
# → 伪装服务中（每 5s 追加写入 + 假网关占 18789）→ 走真 tick.sh 触发继任者
# → 停机瞬间再写最后一批（必须到达继任者）→ 走真 cutover.sh 交出 → 验收。
# 与生产的唯一差异：标记根目录走 HANDOFF_REMOTE_DIR 测试前缀（handoff-test/），
# 触发目标走 HANDOFF_WORKFLOW 测试 workflow，并发组独立 —— 生产一个字节都不碰。
set -euo pipefail
HS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S=/tmp/openclaw-handoff; rm -rf "$S"; mkdir -p "$S"

echo "═══ [old] 造状态树（结构与生产同构）"
mkdir -p ~/.openclaw/{state,agents/main/agent,workspace} ~/.zcode/cli
echo '{"fake":true}' > ~/.openclaw/openclaw.json
sqlite3 ~/.openclaw/state/openclaw.sqlite \
  "PRAGMA journal_mode=wal; CREATE TABLE t(x); INSERT INTO t VALUES(1),(2);" >/dev/null
sqlite3 ~/.openclaw/agents/main/agent/openclaw.sqlite \
  "PRAGMA journal_mode=wal; CREATE TABLE a(x); INSERT INTO a VALUES(42);" >/dev/null
echo base > ~/.openclaw/workspace/base.txt
echo zbase > ~/.zcode/cli/base.txt

echo "═══ [old] 打基座包（模拟 ≤20min 前的周期包）→ ${HANDOFF_REMOTE_DIR}/base.tar.gz"
tar -czf /tmp/base.tar.gz -C ~ .openclaw .zcode
rclone copyto /tmp/base.tar.gz "${HANDOFF_REMOTE_DIR}/base.tar.gz"
BASE_EPOCH=$(date +%s)
echo "base_epoch=$BASE_EPOCH"

echo "═══ [old] 伪装 serving（每 5s 追加写入 + 假网关 18789）"
( while :; do date +%s%N >> ~/.openclaw/workspace/live.log 2>/dev/null; sleep 5; done ) & LIVEPID=$!
python3 -m http.server 18789 --bind 127.0.0.1 >/dev/null 2>&1 & GW=$!
sleep 2
curl -sf -o /dev/null http://127.0.0.1:18789/ && echo "假网关已就绪"

echo "═══ [old] 保活循环（10min，真 tick.sh：T-8min 触发 / T-4min 看门狗）"
SLEEP_SECONDS=600; _waited=0; TICKED=0
while [ "$_waited" -lt "$SLEEP_SECONDS" ]; do
  bash "$HS/tick.sh" "$((SLEEP_SECONDS - _waited))" || true
  [ -f "$S/successor-run-id" ] && [ "$TICKED" = "0" ] && { TICKED=1; echo "继任者 run=$(cat "$S/successor-run-id")"; }
  sleep 15; _waited=$((_waited + 15))
done

echo "═══ [old] 停机瞬间：写最后一批 + 删一个基座文件（验证 rsync --delete）"
echo "written at $(date '+%F %T')" > ~/.openclaw/workspace/last-minute.txt
rm -f ~/.openclaw/workspace/base.txt
# 真实量级载荷：模拟生产里 ~1.9GB 的 sqlite 增量（随机数据 = 不可压缩，最坏情况）
PAYLOAD_MB="${PAYLOAD_MB:-1500}"
if [ "$PAYLOAD_MB" -gt 0 ]; then
  echo "注入 ${PAYLOAD_MB}MB 真实载荷（不可压缩）…"
  dd if=/dev/urandom of=~/.openclaw/workspace/payload.bin bs=1M count="$PAYLOAD_MB" status=none
  ls -lh ~/.openclaw/workspace/payload.bin
fi
kill "$GW" "$LIVEPID" 2>/dev/null || true
STOP_EPOCH=$(date +%s)
echo "stop_epoch=$STOP_EPOCH"
printf '{"stop_epoch":%s,"payload_mb":%s,"archive_sim_seconds":%s}' \
  "$STOP_EPOCH" "${PAYLOAD_MB:-0}" "${ARCHIVE_SIM_SECONDS:-0}" \
  | rclone rcat "${HANDOFF_REMOTE_DIR}/timing.json"

echo "═══ [old] 交出（真 cutover.sh）"
if bash "$HS/cutover.sh"; then
  DONE_EPOCH=$(date +%s)
  echo "handoff_done_epoch=$DONE_EPOCH"
  echo "╔══════════════════════════════════════════════"
  echo "║ ✅ 交接成功"
  echo "║ 停机→继任者 serving: $((DONE_EPOCH - STOP_EPOCH))s（轮询粒度 5s）"
  echo "║ 继任者 run: $(cat "$S/successor-run-id" 2>/dev/null || echo '?')"
  echo "╚══════════════════════════════════════════════"
  # 仿真旧轮最终归档耗时（生产实测：主包 243s + 其余 ~45s）
  ARCHIVE_SIM_SECONDS="${ARCHIVE_SIM_SECONDS:-300}"
  echo "═══ [old] 仿真最终归档 ${ARCHIVE_SIM_SECONDS}s（模型通道要等的就是这段）"
  sleep "$ARCHIVE_SIM_SECONDS"
  # 归档完成 → 推进 archives_done，并验证继任者的闸门
  bash "$HS/mark-archives-done.sh"
  bash "$HS/gate.sh" archives_done
  echo "✅ [old] archives_done 已推进，gate 放行验证通过"
else
  echo "❌ [old] 交接失败（回退路径），原因见上方 [cutover] 日志"
  exit 1
fi
