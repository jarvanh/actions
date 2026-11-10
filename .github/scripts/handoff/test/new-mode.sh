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

echo "═══ [new] 闸门（真 gate.sh archives_done，应阻塞到旧轮推进）"
GATE_T0=$(date +%s)
bash "$HS/gate.sh" archives_done
echo "gate 等待 $(( $(date +%s) - GATE_T0 ))s 后放行"

echo "═══ [new] 验收"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ✅ $1"; else echo "  ❌ $1（期望=$2 实际=$3）"; fail=$((fail+1)); fi; }
chk "增量文件 last-minute.txt 已到达" "$(cat ~/.openclaw/workspace/last-minute.txt 2>/dev/null | grep -c 'written at')" "1"
chk "活文件 live.log 已到达" "$([ -s ~/.openclaw/workspace/live.log ] && echo yes)" "yes"
chk "--delete 生效（base.txt 已删）" "$([ -e ~/.openclaw/workspace/base.txt ] && echo 还在 || echo 已删)" "已删"
chk "主 state 库内容完整" "$(sqlite3 ~/.openclaw/state/openclaw.sqlite 'select count(*) from t;' 2>/dev/null)" "2"
chk "agent 库内容完整" "$(sqlite3 ~/.openclaw/agents/main/agent/openclaw.sqlite 'select a from a;' 2>/dev/null)" "42"
chk "~/.zcode 增量同步" "$(cat ~/.zcode/cli/base.txt 2>/dev/null)" "zbase"
chk "标记归属正确(serving)" "$(rclone cat "${HANDOFF_REMOTE_DIR}/new.json" 2>/dev/null | jq -r .state)" "serving"

echo "╔══════════════════════════════════════════════"
echo "║ 继任者就位→rsync 完成: $((DONE_EPOCH - READY_EPOCH))s"
echo "╚══════════════════════════════════════════════"
[ "$fail" = "0" ] || { echo "❌ 验收失败 $fail 项"; exit 1; }
echo "✅ [new] 全部验收通过"
