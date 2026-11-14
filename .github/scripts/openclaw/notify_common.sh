#!/bin/bash
# ===== AI 网关通知共用构件 =====
# 版式真源: docs/telegram-notify.md。调用方必须先 source telegram/tg_notify.sh，
# 再 source 本文件；本文件不重复实现排版助手。
#
# 只收「同一语义、多个网关都要写」的片段——账号池分节、模型倍率分节、看板资产 /
# 用量块、原始输出块、收尾 + 发送。网关特有字段（状态机、风控、签到、凭据）仍留在
# 各自 run-*.sh，避免把六套通知做成一个难读的大模板。
#
# 看板（quota-board）是资产 / 用量口径真源；这里只负责调 CLI 与空输出跳过。

GW_BOARD="${GW_BOARD:-/dropbox/self-hosted/quota-board/board.py}"

# 资产段：board.py assets <源>，空输出静默跳过
gw_add_board_assets() {
  local _var="$1" _src="$2" _out
  _out="$(python3 "$GW_BOARD" assets "$_src" 2>/dev/null || true)"
  [ -n "$_out" ] && tg_append "$_var" "$_out"
}

# 用量 + 流水：board.py usage-ledger <源> <行数>，空输出静默跳过
gw_add_board_usage() {
  local _var="$1" _src="$2" _rows="${3:-12}" _out
  _out="$(python3 "$GW_BOARD" usage-ledger "$_src" "$_rows" 2>/dev/null || true)"
  [ -n "$_out" ] && tg_append "$_var" "$_out"
}

# 账号池分节标题：💳 账号池 · N [· 可用 M]
gw_pool_title() {
  # 分开赋值：set -u 下 `local a="$1" b="${a}"` 会在同一条 local 里读到未初始化的 a
  local _total="$1"
  local _active="${2:-}"
  local _title="💳 账号池 · ${_total}"
  [ -n "$_active" ] && _title+=" · 可用 ${_active}"
  printf '%s' "$_title"
}

gw_add_pool_section() {
  local _var="$1"
  shift
  tg_add_section "$_var" "$(gw_pool_title "$@")"
}

# 模型倍率分节：📊 模型倍率 · N
gw_add_rates_section() {
  tg_add_section "$1" "📊 模型倍率 · ${2:-0}"
}

# 原始输出块：分节 + 尾部 1200 字节（UTF-8 安全），空值整段跳过
gw_add_original_output() {
  local _var="$1" _text="$2"
  [ -n "$_text" ] || return 0
  tg_add_section "$_var" "🧾 原始输出"
  tg_add_pre "$_var" "$(tg_tail_safe "$_text" 1200)"
}

# 收尾 + 发送（含失败留痕）：六套网关通知的统一尾部。
# 用法: gw_send <消息变量名> [tier]；tier 缺省 alert（网关就绪 / 失败 / 停服均属重要通知）。
# 返回 send_tg 的退出码，调用方据此写状态标记（如 *_NOTIFY_OK）或补 ::warning::。
gw_send() {
  # ${2-alert}（不是 :-）：显式传空串 = 普通档，省略才默认 alert
  local _var="$1" _tier="${2-alert}"
  tg_add_footer "$_var"
  send_tg "${!_var}" "$_tier"
}
