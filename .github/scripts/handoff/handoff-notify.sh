#!/usr/bin/env bash
# ── 交接进度通知（2026-11-11）──
# 用法: handoff-notify.sh <stage> [key=value ...]
#   stage: prepare | ready | cutover | serving | full
# 设计口径（遵循 docs/telegram-notify.md）:
#   · 标题 + 分隔线 + kv 行 + 收尾区；全角冒号；不使用 <b>/<i>
#   · 一条通知回答三件事：现在到哪一步、服务是否可用、还要多久/已经多久
#   · 「下线」只在真正停机后才有意义（cutover 之后的阶段），此前只报进度
# 失败静默：任何发送错误都不影响交接（交接正确性优先于通知）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 通知真源在顶层 source 一次（规范 · 4.4：不得放进函数体内）
# shellcheck source=../telegram/tg_notify.sh
source "${GITHUB_WORKSPACE:-$(cd "$here/../../.." && pwd)}/.github/scripts/telegram/tg_notify.sh"

stage="${1:-}"; shift || true
declare -A KV=()
for kv in "$@"; do KV["${kv%%=*}"]="${kv#*=}"; done

# 没有凭据就静默跳过（隐藏/测试环境）
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || exit 0

msg=""
case "$stage" in
  prepare)
    tg_add_title msg "🤝 OpenClaw 交接 · 准备中"
    tg_add_kv msg "阶段" "继任者已启动，正在恢复基座并预热链路"
    [ -n "${KV[old_run]:-}" ] && tg_add_kv msg "旧轮" "run ${KV[old_run]}"
    [ -n "${KV[new_run]:-}" ] && tg_add_kv msg "继任" "run ${KV[new_run]}"
    [ -n "${KV[eta]:-}" ] && tg_add_kv msg "预计交出" "约 ${KV[eta]} 分钟后"
    tg_add_note msg "此阶段服务完全在线，可正常使用；真正停机会在交出前单独提示。"
    ;;
  ready)
    tg_add_title msg "✅ OpenClaw 交接 · 继任者已就绪"
    tg_add_kv msg "阶段" "基座已恢复，等待旧轮交出"
    [ -n "${KV[elapsed]:-}" ] && tg_add_kv msg "准备耗时" "$(tg_format_ms "${KV[elapsed]}")"
    tg_add_note msg "服务仍在线；旧轮按死线停止网关后即完成移交。"
    ;;
  cutover)
    tg_add_title msg "⏳ OpenClaw 交接 · 已交出"
    tg_add_kv msg "阶段" "旧轮已停网关并交出，继任者正在同步增量"
    [ -n "${KV[transfer]:-}" ] && tg_add_kv msg "增量" "${KV[transfer]}"
    [ -n "${KV[speed]:-}" ] && tg_add_kv msg "链路" "${KV[speed]}"
    tg_add_note msg "此刻起到继任者网关就绪为下线窗口，通常在 1-3 分钟内。"
    ;;
  serving)
    tg_add_title msg "🚀 OpenClaw 交接 · 新轮已上线"
    tg_add_kv msg "阶段" "继任者网关已健康，聊天路径恢复"
    [ -n "${KV[downtime]:-}" ] && tg_add_kv msg "下线时长" "$(tg_format_ms "${KV[downtime]}")"
    [ -n "${KV[ai]:-}" ] && tg_add_kv msg "AI 数据" "${KV[ai]}"
    tg_add_note msg "模型通道与看板随后自动就绪，全部服务可用时会再发一条。"
    ;;
  full)
    tg_add_title msg "🏁 OpenClaw 交接完成"
    tg_add_kv msg "结果" "全部服务可用"
    [ -n "${KV[downtime]:-}" ] && tg_add_kv msg "整体下线" "$(tg_format_ms "${KV[downtime]}")"
    [ -n "${KV[chat]:-}" ] && tg_add_kv msg "聊天路径" "$(tg_format_ms "${KV[chat]}")"
    [ -n "${KV[ai]:-}" ] && tg_add_kv msg "AI 数据" "${KV[ai]}"
    [ -n "${KV[run]:-}" ] && tg_add_path msg "新 run" "${KV[run]}"
    ;;
  *) exit 0 ;;
esac
tg_add_footer msg
send_tg "$msg" || true
exit 0
