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
# 通知真源在顶层 source 一次（规范 · 通知函数的正确接法：不得放进函数体内）
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
    # run id 做成可点链接（与收尾区「运行日志」同款 <a href>）
    _run_url() {
      printf '%s/%s/actions/runs/%s' \
        "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-jarvanh/actions}" "$1"
    }
    [ -n "${KV[old_run]:-}" ] && tg_add_link msg "旧轮" "$(_run_url "${KV[old_run]}")" "run ${KV[old_run]}"
    [ -n "${KV[new_run]:-}" ] && tg_add_link msg "继任" "$(_run_url "${KV[new_run]}")" "run ${KV[new_run]}"
    if [ -n "${KV[manual]:-}" ]; then
      # 手动交接：不等死线（继任者 ready 就交出，实测 3 分钟）→ 必须明确催促停写，
      # 否则读者以为还能用几小时，冻结后写入就丢了。
      tg_add_kv msg "交出" "手动交接：继任者就绪后立即交出（通常 3-5 分钟）"
      tg_add_note msg "⚠️ 请现在就停止写入：本轮不会等到死线。交出时会停 OpenClaw 网关，此后的写入不会进最终快照。"
    elif [ -n "${KV[eta]:-}" ]; then
      # 自动交接：距死线还有 N 分钟，仍可正常使用
      tg_add_kv msg "预计交出" "约 ${KV[eta]} 分钟后"
      tg_add_note msg "此阶段服务完全在线，可正常使用；停机会在交出前单独提示（T-2 倒计时）。"
    else
      tg_add_note msg "此阶段服务完全在线，可正常使用；真正停机会在交出前单独提示。"
    fi
    ;;
  ready)
    tg_add_title msg "✅ OpenClaw 交接 · 继任者已就绪"
    tg_add_kv msg "阶段" "基座已恢复，等待旧轮交出"
    [ -n "${KV[elapsed]:-}" ] && tg_add_kv msg "准备耗时" "$(tg_format_ms "${KV[elapsed]}")"
    [ -n "${KV[new_run]:-}" ] && tg_add_link msg "继任" \
      "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-jarvanh/actions}/actions/runs/${KV[new_run]}" "run ${KV[new_run]}"
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
    # 2026-11-11 口径修正：这一条只代表「OpenClaw 聊天入口」可用
    # （18789 /health=200 + 主机名回收），不代表模型通道就绪 ——
    # 之前写「新轮已上线」会让人误以为 AI 网关也好了。两个指标分开说。
    tg_add_title msg "🚀 OpenClaw 交接 · 聊天入口已恢复"
    tg_add_kv msg "阶段" "继任者 OpenClaw 网关已健康（18789 /health=200），聊天可用"
    [ -n "${KV[downtime]:-}" ] && tg_add_kv msg "聊天下线" "$(tg_format_ms "${KV[downtime]}")"
    [ -n "${KV[new_run]:-}" ] && tg_add_link msg "继任" \
      "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-jarvanh/actions}/actions/runs/${KV[new_run]}" "run ${KV[new_run]}"
    [ -n "${KV[ai]:-}" ] && tg_add_kv msg "AI 数据" "${KV[ai]}"
    tg_add_note msg "AI 网关（OmniRoute + 上游）与看板随后就绪；全部服务可用时会再发一条并报整体下线时长。"
    ;;
  full)
    tg_add_title msg "🏁 OpenClaw 交接完成"
    tg_add_kv msg "结果" "全部服务可用（含 AI 网关）"
    [ -n "${KV[downtime]:-}" ] && tg_add_kv msg "整体下线" "$(tg_format_ms "${KV[downtime]}")"
    [ -n "${KV[ai_ready]:-}" ] && tg_add_kv msg "AI 网关恢复" "$(tg_format_ms "${KV[ai_ready]}")"
    [ -n "${KV[chat]:-}" ] && tg_add_kv msg "聊天入口" "$(tg_format_ms "${KV[chat]}")"
    [ -n "${KV[ai]:-}" ] && tg_add_kv msg "AI 数据" "${KV[ai]}"
    if [ -n "${KV[run]:-}" ]; then
      _run_text="run ${KV[run]##*/}"
      case "${KV[run]}" in *"://"*) ;; *) _run_text="run ${KV[run]}" ;; esac
      tg_add_link msg "继任" "${KV[run]}" "$_run_text"
    fi
    ;;
  *) exit 0 ;;
esac
tg_add_footer msg
send_tg "$msg" || true
exit 0
