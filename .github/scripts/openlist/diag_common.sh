#!/bin/bash
# ===== diag_* 诊断脚本族的公共函数（零副作用: 只定义函数，不设任何变量/不执行命令）=====
#
# 2026-09-29 结构优化: say/sec/http_code_of/is_409/is_mkparentdir/_mk 此前在
#   6~7 个 diag 脚本里逐字重复 —— 改一处要同步六处，已发生过口径漂移风险
#   （各 _short_ol 的截断宽度就悄悄长成了 3 种），收敛到本文件。
#
# 引入方式（各 diag 脚本在设置完 REPORT 等全局后）:
#   source "$(dirname "${BASH_SOURCE[0]}")/diag_common.sh"
#
# 依赖（调用方须先就绪，本文件不设默认值）:
#   - REPORT                       报告文件路径（say/sec 追加写入）
#   - MKDIR_TIMEOUT / PROBE_TIMEOUT  仅 _mk 使用
#
# 注: _short_ol 各脚本保留本地定义 —— 截断宽度是有意差异化（报告排版口径），
#     不做统一。_recheck 仅 depth 用、_mk 调用方口径已统一（_K_HTTP 多余赋值
#     对 l2/escape 无影响），故 _mk 收敛为 depth 版（输出最多的超集）。

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

# 从 rclone 输出里摘出 HTTP 码（405/401/423/500…）
# 不用 \b: BSD grep -E 不支持词边界，会静默零匹配（与本机已知的 \S 同类坑）。
# 改要求「码 + 空格 + 字母」——这同时避开了进度行的 "450.089 MiB"（后随 '.'）。
http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
is_mkparentdir() { grep -Eqi 'mkParentDir' <<<"$1"; }

# 统一探测: mkdir → lsd 复核，输出四元组（l2/escape/depth 三份同口径，收敛于此）
# 用法: _mk <远端目录> <标签>
#   全局: _K_RC / _K_409 / _K_EXISTS / _K_HTTP
_mk() {
  local dir="$1" label="$2"
  local _out _rc _409 _http
  _out=$(rclone mkdir "$dir" --timeout "$MKDIR_TIMEOUT" 2>&1); _rc=$?
  _409=0; is_409 "$_out" && _409=1
  _http=$(http_code_of "$_out")
  local _exists=0
  rclone lsd "$dir" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _exists=1
  say "   ${label}: mkdir rc=${_rc} · http=${_http:-无} · 409特征=${_409} · **lsd 存在=${_exists}**"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -2 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  _K_RC="$_rc"; _K_409="$_409"; _K_EXISTS="$_exists"; _K_HTTP="$_http"
  [ "$_exists" -eq 1 ] && return 0 || return 1
}
