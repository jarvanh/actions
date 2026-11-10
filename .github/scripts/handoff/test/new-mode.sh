#!/usr/bin/env bash
# ── 交接协议 · 实测·继任者侧（测试 workflow 专用，2026-11-10）──
# 在另一台真 runner 上扮演「继任者」：恢复基座包 → 真 takeover.sh（等交出 +
# rsync 增量 + 校验）→ 真 serving.sh → 真 gate.sh(archives_done) → 验收内容。
set -euo pipefail
HS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S=/tmp/openclaw-handoff; rm -rf "$S"; mkdir -p "$S"

echo "═══ [new] 基座恢复（模拟 Install OpenClaw 解包 ≤20min 前周期包）"
rclone copyto "${HANDOFF_REMOTE_DIR}/base.tar.gz" /tmp/base.tar.gz
tar -xzf /tmp/base.tar.gz -C ~
ls -la ~/.openclaw/workspace/ | head -5

READY_EPOCH=$(date +%s)
echo "═══ [new] 接管（真 takeover.sh：ready → 等交出 → rsync ∥ → quick_check）"
bash "$HS/takeover.sh"
DONE_EPOCH=$(date +%s)

echo "═══ [new] 上线回执（真 serving.sh）"
bash "$HS/serving.sh"
CHAT_READY=$(date +%s)
STOP_EPOCH=$(rclone cat "${HANDOFF_REMOTE_DIR}/timing.json" 2>/dev/null | jq -r '.stop_epoch // 0' 2>/dev/null)
case "${STOP_EPOCH:-0}" in ''|*[!0-9]*) STOP_EPOCH=0 ;; esac
[ "$STOP_EPOCH" -gt 0 ] && echo "📉 [chat] 旧轮停机 → 聊天路径恢复: $(( CHAT_READY - STOP_EPOCH ))s"

echo "═══ [new] 模型通道闸门（真 gate.sh ai_archives_done = Phase 1.5 后的等待点）"
GATE_T0=$(date +%s)
bash "$HS/gate.sh" ai_archives_done
echo "ai 闸门等待 $(( $(date +%s) - GATE_T0 ))s 后放行"
MODEL_READY=$(date +%s)
[ "${STOP_EPOCH:-0}" -gt 0 ] && echo "📉 [model] 旧轮停机 → 模型通道恢复: $(( MODEL_READY - STOP_EPOCH ))s"

echo "═══ [new] 归档循环闸门（真 gate.sh archives_done，仍需等整段归档）"
bash "$HS/gate.sh" archives_done
echo "archive 闸门放行（归档循环用，不影响服务可用性）"

echo "═══ [new] 模拟各服务端口就绪（测试环境无真实服务，起假监听器代表全栈）"
# 与生产 full-ready.sh 探测的端口集合一致；AI 侧端口在 ai 闸门之后才起，
# 用来复现「聊天先好、AI 后好」的真实时序。
_start_listener() { ( python3 -c "
import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',int(sys.argv[1]))); s.listen(16)
while True: time.sleep(3600)
" "$1" >/dev/null 2>&1 & ) ; }
for p in 18789 8318 8319 8320 8322 8790 8321; do _start_listener "$p"; done
_start_listener 20128   # OmniRoute 数据已就绪（ai 闸门已放行）
sleep 3

echo "═══ [new] 整体上线（所有服务端口就绪才算——主人口径）"
bash "$HS/full-ready.sh" 120 || echo "::warning::测试环境只有部分端口，按可得端口计"
FULL_READY=$(date +%s)
[ "${STOP_EPOCH:-0}" -gt 0 ] && echo "📉 [full] 旧轮停机 → 整体上线: $(( FULL_READY - STOP_EPOCH ))s"

echo "═══ [new] 验收"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ✅ $1"; else echo "  ❌ $1（期望=$3 实际=$2）"; fail=$((fail+1)); fi; }
chk "增量文件 last-minute.txt 已到达" "$(cat ~/.openclaw/workspace/last-minute.txt 2>/dev/null | grep -c 'written at')" "1"
chk "活文件 live.log 已到达" "$([ -s ~/.openclaw/workspace/live.log ] && echo yes)" "yes"
chk "--delete 生效（base.txt 已删）" "$([ -e ~/.openclaw/workspace/base.txt ] && echo 还在 || echo 已删)" "已删"
chk "主 state 库内容完整" "$(sqlite3 ~/.openclaw/state/openclaw.sqlite 'select count(*) from t;' 2>/dev/null)" "2"
chk "agent 库内容完整" "$(sqlite3 ~/.openclaw/agents/main/agent/openclaw.sqlite 'select x from a;' 2>/dev/null)" "42"
chk "~/.zcode 增量同步" "$(cat ~/.zcode/cli/base.txt 2>/dev/null)" "zbase"
chk "标记归属正确(serving)" "$(rclone cat "${HANDOFF_REMOTE_DIR}/new.json" 2>/dev/null | jq -r .state)" "serving"

echo "╔══════════════════════════════════════════════"
echo "║ 继任者就位→rsync 完成: $((DONE_EPOCH - READY_EPOCH))s"
if [ "${STOP_EPOCH:-0}" -gt 0 ]; then
  echo "║ 聊天路径下线(停机→serving):      $(( CHAT_READY - STOP_EPOCH ))s"
  echo "║ 模型通道下线(停机→数据可用):     $(( MODEL_READY - STOP_EPOCH ))s"
  echo "║ ★ 整体上线(停机→全部服务可用):  $(( FULL_READY - STOP_EPOCH ))s"
fi
echo "╚══════════════════════════════════════════════"
[ "$fail" = "0" ] || { echo "❌ 验收失败 $fail 项"; exit 1; }
echo "✅ [new] 全部验收通过"
