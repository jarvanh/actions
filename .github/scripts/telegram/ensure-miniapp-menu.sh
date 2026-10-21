#!/usr/bin/env bash
# ensure-miniapp-menu.sh — 额度看板 Mini App 入口（TG 菜单按钮）幂等重建
#
# 背景（为什么存在）：
#   菜单按钮本体只存在 Telegram 服务端，不在任何本地持久化载体里。
#   2026-10-09 实测丢过一次、靠人工重设；2026-10-19 起由本脚本每轮 runner
#   幂等重建（workflow「Run quota-board」步骤调用）。
#   ⚠️ 2026-10-22 发现脚本本体曾长期缺失（commit 1e30239 只入库了调用），
#   自愈安全网空转 3 天 —— 本次重写并直接入库本仓库（B 类真源），
#   不再依赖 workspace 副本，runner 重置也冲不掉。
#
# 动作（幂等，重复执行无害）：
#   1) @openclaw_sb_bot    → web_app 按钮「📊 额度看板」→ https://qb.derrick.eu.org/p/<QUOTA_BOARD_TOKEN>
#   2) @sbsbsbsbsb_openclaw_bot（旧入口 bot）→ 清成 type=commands，避免双入口
#
# 凭据来源：~/.openclaw/.env（随 openclaw.tar.gz 归档每轮恢复）
#   TELEGRAM_BOT_TOKEN_OPENCLAW_SB_BOT / TELEGRAM_BOT_TOKEN_SBSBSBSBSB_OPENCLAW_BOT / QUOTA_BOARD_TOKEN
# 允许环境变量覆盖：QB_URL_BASE（默认 https://qb.derrick.eu.org）

set -euo pipefail

ENV_FILE="${HOME:-/home/runner}/.openclaw/.env"
QB_URL_BASE="${QB_URL_BASE:-https://qb.derrick.eu.org}"

[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE 不存在，无法取 token，跳过"; exit 0; }
# shellcheck disable=SC1090
source "$ENV_FILE"

SB_TOKEN="${TELEGRAM_BOT_TOKEN_OPENCLAW_SB_BOT:-}"
OLD_TOKEN="${TELEGRAM_BOT_TOKEN_SBSBSBSBSB_OPENCLAW_BOT:-}"
QB_TOKEN="${QUOTA_BOARD_TOKEN:-}"

if [ -z "$SB_TOKEN" ] || [ -z "$QB_TOKEN" ]; then
  echo "❌ .env 缺 TELEGRAM_BOT_TOKEN_OPENCLAW_SB_BOT 或 QUOTA_BOARD_TOKEN，跳过重建"
  exit 0
fi

API="https://api.telegram.org/bot"
QB_URL="${QB_URL_BASE}/p/${QB_TOKEN}"

# ⚠️ setChatMenuButton 不得传 "chat_id": null（实测 400 invalid chat_id）；
# 不传 chat_id 才是「默认全局菜单」语义（实测 ok:true）。
payload_web_app=$(printf '{"menu_button":{"type":"web_app","text":"📊 额度看板","web_app":{"url":"%s"}}}' "$QB_URL")
payload_commands='{"menu_button":{"type":"commands"}}'

# setChatMenuButton（不带 chat_id = 默认全局菜单）
tg_set() {
  local token="$1" body="$2" name="$3"
  local resp
  resp=$(curl -fsS -m 20 -X POST "${API}${token}/setChatMenuButton" \
    -H 'Content-Type: application/json' -d "$body" 2>&1) || { echo "❌ ${name} setChatMenuButton 请求失败: ${resp}"; return 1; }
  if printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "✅ ${name} 菜单按钮已重建"
  else
    echo "❌ ${name} setChatMenuButton 返回异常: ${resp}"
    return 1
  fi
}

rc=0
tg_set "$SB_TOKEN" "$payload_web_app" "openclaw_sb_bot(web_app)" || rc=1
# 旧 bot 清理属尽力而为：缺 token 或失败不阻断主入口判定
if [ -n "$OLD_TOKEN" ]; then
  tg_set "$OLD_TOKEN" "$payload_commands" "sbsbsbsbsb_openclaw_bot(commands)" || echo "⚠️ 旧 bot 清理失败（不影响主入口）"
else
  echo "⚠️ .env 无旧 bot token，跳过双入口清理"
fi

# 回读校验：主入口当前值必须 == 期望
verify=$(curl -fsS -m 20 "${API}${SB_TOKEN}/getChatMenuButton" -H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)
if printf '%s' "$verify" | grep -q "$QB_URL"; then
  echo "🔎 回读校验通过：web_app 指向 ${QB_URL_BASE}/p/<token>"
else
  echo "❌ 回读校验失败：getChatMenuButton=${verify}"
  rc=1
fi

exit $rc
