#!/usr/bin/env bash
# Telegram 通知骨架生成器（对应 skills/telegram-notify-send）
#
# 用法:
#   bash scaffold_notify.sh <simple|list|pre|pwsh> [-o 输出文件]
#
# 四个骨架都取自本仓库真实实现（见 references/examples.md），生成后只需替换
# 占位内容。生成完记得跑渲染预览自检:
#   bash skills/telegram-notify-audit/scripts/render_preview.sh
#
# 说明: 骨架里的 $ 都是给目标脚本用的，本文件全部用 quoted heredoc 原样输出。
set -uo pipefail

usage() {
  cat <<'USAGE'
用法: bash scaffold_notify.sh <类型> [-o 输出文件]

类型:
  simple  最简单的通知（标题 + kv + 收尾），含 workflow 接线
  list    带条目清单的通知（tg_add_entry -> tree_fold -> tg_add_block）
  pre     带 <pre> 原始输出的通知（日志 / 异常栈 / 复制即用命令）
  pwsh    Windows runner 的 pwsh 版（dot-source + 手拼 + Get-TgFooter）

选项:
  -o FILE 写入文件（默认输出到 stdout）
  -h      显示本帮助
USAGE
}

emit_simple() {
  cat <<'EOF'
# ===== workflow step（接线四件套 + always 缺一不可）=====
      - name: "Notify: <任务名> 结果"
        if: ${{ always() }}
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
          TG_RUN_STARTED_AT: ${{ github.run_started_at }}
        run: |
          if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
            echo "Telegram 凭证未配置，跳过发送通知。"; exit 0
          fi
          source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

          # 状态语义只由标题 emoji 承担，kv 里不再重复（规范 · 结果通知）
          case "${{ job.status }}" in
            success)   _emoji="✅"; _status="完成" ;;
            cancelled) _emoji="⛔"; _status="已取消" ;;
            *)         _emoji="❌"; _status="失败" ;;
          esac

          msg=""
          tg_add_title msg "$_emoji <任务名>"
          tg_add_kv msg "状态" "$_status"
          # 机器值（路径/文件名/ID/退出码）→ tg_add_path 进 <code>
          # tg_add_path msg "对象" "$TARGET"
          tg_add_footer msg
          send_tg "$msg" || echo "::warning::TG 通知发送失败（不影响任务）"
EOF
}

emit_list() {
  cat <<'EOF'
# source 必须在明细构建之前
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

# 1) 累积条目：tg_add_entry <var> <机器值主体> [元数据...]（自动转义 + 补尾换行）
ITEMS=""
for f in "${FILES[@]}"; do
  # format_bytes 来自通知真源 tg_notify.sh（口径 1.150 GiB，勿用 du -h 的 1G）
  # stat: Linux runner -c%s / macOS 本地 -f%z
  tg_add_entry ITEMS "$(basename "$f")" "$(format_bytes "$(stat -c%s "$f")")"
done

# 2) 构建消息
msg=""
tg_add_title msg "✅ <任务名>完成"
tg_add_kv msg "处理数量" "${#FILES[@]} 个"
# 列表分节必须带 " · N"；清单为空时整段跳过，不要渲染成 "✅ … · 0"
if [ "${#FILES[@]}" -gt 0 ]; then
  tg_add_section msg "📋 明细 · ${#FILES[@]}"
  # 已构建条目流 → 只能 tree_fold（只截断+加折叠行）；
  # 用 tree_code_fold 会二次转义成 &amp;amp; → 整条 400 丢失
  tg_add_block msg "$(tree_fold "${ITEMS%$'\n'}")"
fi
tg_add_footer msg
send_tg_chunked "$msg" || echo "::warning::TG 通知发送失败（不影响任务）"
EOF
}

emit_pre() {
  cat <<'EOF'
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"

msg=""
tg_add_title msg "⚠️ <任务名>告警"
# 机器值 → <code>；自然语言（结论/原因）→ 裸文本，别混为一谈
tg_add_path msg "对象" "$OBJ"
tg_add_kv msg "结论" "$VERDICT"
[ -n "${REASON:-}" ] && tg_add_kv msg "原因" "$REASON"

if [ -n "${DETAIL:-}" ]; then
  # 分节后跟 <pre> 不带 " · N"（计数只用于条目列表）
  tg_add_section msg "🧾 原始输出"
  # 尾部 1200 字节：超长会让 <pre> 跨 4000 分片、标签断开即破版
  tg_add_pre msg "$(printf '%s' "$DETAIL" | tail -c 1200)"
fi
# 说明段（可选）：段内不能带 HTML 标签
# tg_add_note msg "如确认无误，可忽略本条"
tg_add_footer msg
send_tg "$msg" || echo "::warning::TG 通知发送失败（不影响任务）"
EOF
}

emit_pwsh() {
  cat <<'EOF'
# pwsh 真源只有 5 个成员：Esc-Html / Format-TgDuration / Get-TgFooter /
# Send-TgMessage / $TG_SEP —— 没有 kv 与条目助手，值必须手动 Esc-Html、树形前缀手写。
    - name: "Notify: <任务名>"
      if: ${{ always() }}
      shell: pwsh
      env:
        TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
        TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
        TG_RUN_STARTED_AT: ${{ github.run_started_at }}
      run: |
        . "$env:GITHUB_WORKSPACE\.github\scripts\telegram\tg_notify.ps1"
        # 自检: dot-source 失败会静默无通知（调用未定义函数是终止错误）
        if (-not (Get-Command Send-TgMessage -ErrorAction SilentlyContinue)) { throw "tg_notify.ps1 加载失败" }
        # 首个分节紧跟分隔线不补空行；分节 emoji 不与标题 emoji 重复
        $msg = "🖥️ <标题>`n$TG_SEP`n" +
          "🔐 <分节名> · 3`n" +
          "  ├─ 地址：<code>$(Esc-Html $Env:ADDR)</code>`n" +
          "  ├─ 用户：<code>runneradmin</code>`n" +
          "  └─ 密码：<code>$(Esc-Html $Env:PASSWORD)</code>"
        $msg += "`n`nℹ️ <说明段，无 HTML 标签>"
        $footer = Get-TgFooter
        # Get-TgFooter 可能返回空（无 TG_RUN_URL 时降级），必须判空
        if ($footer) { $msg += "`n`n$footer" }
        Send-TgMessage $msg
EOF
}

main() {
  local kind="${1:-}" out=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="${2:-}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) echo "未知参数: $1" >&2; usage; return 1 ;;
    esac
  done

  local body
  case "$kind" in
    simple) body="$(emit_simple)" ;;
    list)   body="$(emit_list)" ;;
    pre)    body="$(emit_pre)" ;;
    pwsh)   body="$(emit_pwsh)" ;;
    ""|-h|--help) usage; return 0 ;;
    *)
      echo "未知类型: $kind (可选: simple / list / pre / pwsh)" >&2
      usage
      return 1
      ;;
  esac

  if [ -n "$out" ]; then
    printf '%s\n' "$body" > "$out"
    echo "已写入: $out"
  else
    printf '%s\n' "$body"
  fi
}

main "$@"
