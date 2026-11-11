#!/usr/bin/env bash
# 资产段桥接冒烟：验证「看板 board.py → 网关就绪通知」引用链的契约
# （docs/telegram-notify.md · 8.3；路线 B，2026-11-01 拍板：口径真源在看板，通知只引用）
#
# 防的是 2026-11-07 _DAYS_CACHE 式静默回归：看板改口径/改结构，通知端悄悄坏掉没人发现。
# 验证的是契约，不是数据快照（数据每天在变，比对快照必然天天假红）：
#   1. 六源 CLI 可调用：rc=0、无 Traceback；
#   2. 五渲染源（wb/trae/zcode/qoder/autoclaw）：空=合法（当日无数据整段省略）；
#      非空则「📅 资产」节标题必须出现在数据行之前（2026-11-07 实锤过标题被
#      tg_section 追加语义放反的坏版式）、无 TAB、无分隔线、<code> 配平；
#   3. qingyan：TSV 契约——空=合法（live 未命中宁缺毋滥），非空则 3 列且金额列
#      为 %.2f 数值；
#   4. 看板自身健康代理：board.log 近 300 行无 NameError / UnboundLocalError
#      （_DAYS_CACHE 事故的形态）；
#   5. 端到端：用 bash 真源 tg_notify.sh 把五源片段按调用方原样 $( ) 直拼渲染，
#      走渲染预览同款校验（二次转义、条目粘连、标题吞行、分隔线重复）。
#
# 用法:
#   bash skills/telegram-notify-audit/scripts/smoke_assets_bridge.sh [仓库根目录] [board.py 路径]
# 退出码: 0=全绿  1=契约破坏  2=SKIP（本机无看板真源，如非宿主机/GitHub runner）
set -uo pipefail

_script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-}"
if [ -z "$ROOT" ]; then
  _d="$_script_dir"
  while [ "$_d" != "/" ]; do
    if [ -f "$_d/.github/scripts/telegram/tg_notify.sh" ]; then ROOT="$_d"; break; fi
    _d="$(dirname "$_d")"
  done
fi
[ -n "$ROOT" ] || ROOT="$_script_dir/../../.."
SOURCE="$ROOT/.github/scripts/telegram/tg_notify.sh"
BOARD="${2:-/dropbox/self-hosted/quota-board/board.py}"
BOARD_LOG="$(dirname "$BOARD")/board.log"

if [ ! -f "$BOARD" ]; then
  echo "SKIP: 看板真源不存在: $BOARD（桥接冒烟仅在本机宿主机有意义）"
  exit 2
fi
if [ ! -f "$SOURCE" ]; then
  echo "FAIL: 找不到 bash 通知真源: $SOURCE" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "FAIL: 无 python3"; exit 1; }

FAIL=0
check() { # check <描述> <条件成立与否 0/1>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; FAIL=1; fi
}

RENDER_SRCS="workbuddy trae zcode qoder autoclaw"
TSV_SRC="qingyan"
ASSET_TITLE="📅 资产 · 签到与有效期"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 1+2. 渲染源契约 ----------
for src in $RENDER_SRCS; do
  echo "── assets $src ──"
  _t0=$SECONDS
  if ! timeout 60 python3 "$BOARD" assets "$src" >"$TMP/$src.out" 2>"$TMP/$src.err"; then
    check "assets $src 可调用（rc=0）" 1
    head -3 "$TMP/$src.err" >&2
    continue
  fi
  check "assets $src 可调用（rc=0，耗时 $((SECONDS-_t0))s）" 0
  if grep -q "Traceback" "$TMP/$src.err"; then
    check "assets $src 无 Traceback" 1
    head -5 "$TMP/$src.err" >&2
  else
    check "assets $src 无 Traceback" 0
  fi
  if [ ! -s "$TMP/$src.out" ]; then
    echo "  · 输出为空 = 合法（当日无数据，整段省略）"
    continue
  fi
  _n_title=$(grep -cF "$ASSET_TITLE" "$TMP/$src.out" || true)
  check "节标题恰好 1 次（实际 $_n_title）" $([ "$_n_title" = "1" ] && echo 0 || echo 1)
  _line_title=$(grep -nF "$ASSET_TITLE" "$TMP/$src.out" | head -1 | cut -d: -f1)
  # 首个数据行 = 标题之后第一个非空行之前应有数据……直接判「标题行号 < 第一条 kv 行号」
  _line_kv=$(grep -n "^[^[:space:]].*：" "$TMP/$src.out" | head -1 | cut -d: -f1)
  if [ -n "$_line_kv" ]; then
    check "节标题在数据行之前（标题 L${_line_title} < 数据 L${_line_kv}）" \
      $([ "${_line_title:-99999}" -lt "${_line_kv:-0}" ] && echo 0 || echo 1)
  else
    check "节标题在数据行之前（暂无数据行可比较）" 0
  fi
  if grep -qP "\t" "$TMP/$src.out"; then
    check "渲染源不含 TAB（TSV 是 qingyan 专属契约）" 1
  else
    check "渲染源不含 TAB" 0
  fi
  if grep -q "━━" "$TMP/$src.out"; then
    check "不含分隔线 ━（分隔线只由通知标题层产出）" 1
  else
    check "不含分隔线 ━" 0
  fi
  _open=$(grep -o "<code>" "$TMP/$src.out" | wc -l | tr -d ' ')
  _close=$(grep -o "</code>" "$TMP/$src.out" | wc -l | tr -d ' ')
  check "<code> 标签配平（$_open/$_close）" $([ "$_open" = "$_close" ] && echo 0 || echo 1)
done

# ---------- 3. qingyan TSV 契约 ----------
echo "── assets qingyan（TSV）──"
_t0=$SECONDS
if ! timeout 10 python3 "$BOARD" assets qingyan >"$TMP/qingyan.out" 2>"$TMP/qingyan.err"; then
  check "assets qingyan 可调用（rc=0）" 1
else
  check "assets qingyan 可调用（rc=0，耗时 $((SECONDS-_t0))s，预算 10s=零联网代理）" 0
fi
if grep -q "Traceback" "$TMP/qingyan.err" 2>/dev/null; then
  check "assets qingyan 无 Traceback" 1
  head -5 "$TMP/qingyan.err" >&2
else
  check "assets qingyan 无 Traceback" 0
fi
if [ -s "$TMP/qingyan.out" ]; then
  _nf=$(awk -F'\t' 'NR==1{print NF}' "$TMP/qingyan.out")
  check "TSV 3 列（实际 $_nf）" $([ "$_nf" = "3" ] && echo 0 || echo 1)
  # 两位小数固定精度（%.2f）：一位或三位小数都判红（恒真断言会让口径漂移无感）
  if awk -F'\t' 'NR==1 && ($1 !~ /^[0-9]+\.[0-9][0-9]$/ || $3 !~ /^[0-9]+\.[0-9][0-9]$/){exit 1}' "$TMP/qingyan.out"; then
    check "金额列为 %.2f 数值（净过期/该批净剩）" 0
  else
    check "金额列为 %.2f 数值（净过期/该批净剩）" 1
  fi
else
  echo "  · 输出为空 = 合法（live 未命中回退快照，宁缺毋滥不冒充净额）"
fi

# ---------- 4. 看板健康代理 ----------
echo "── board.log 健康（NameError 形态）──"
if [ -f "$BOARD_LOG" ]; then
  if tail -300 "$BOARD_LOG" | grep -qE "NameError|UnboundLocalError"; then
    check "board.log 近 300 行无 NameError/UnboundLocalError" 1
    tail -300 "$BOARD_LOG" | grep -nE "NameError|UnboundLocalError" | head -3 >&2
  else
    check "board.log 近 300 行无 NameError/UnboundLocalError" 0
  fi
else
  echo "  · board.log 不存在，跳过（CLI 单跑场景）"
fi

# ---------- 5. 端到端渲染（真源助手 + 调用方原样拼接）----------
if [ -n "${BASH_VERSION:-}" ]; then
  # bash 真源是 bash 语法（printf -v / ${!var}），zsh 下 source 会 bad substitution
  # shellcheck disable=SC1090
  source "$SOURCE"
  export TG_RUN_URL="${TG_RUN_URL:-https://github.com/example/repo/actions/runs/123456}"
  export TG_RUN_STARTED_AT="${TG_RUN_STARTED_AT:-2026-11-07T04:00:00Z}"
  for src in $RENDER_SRCS; do
    [ -s "$TMP/$src.out" ] || continue
    echo "── 端到端渲染 $src ──"
    msg=""
    tg_add_title msg "🟢 $src 冒烟"
    tg_add_kv msg "版本" "test"
    # 关键：调用方就是这么写的 —— $( ) 直拼（run-*.sh 全体同款），尾换行会被吃掉
    _assets="$(cat "$TMP/$src.out")"
    tg_append msg "$_assets"
    tg_add_footer msg
    if printf '%s' "$msg" | grep -q "&amp;amp;\|&amp;lt;\|&amp;gt;"; then
      check "[$src] 无二次转义" 1
    else
      check "[$src] 无二次转义" 0
    fi
    if [[ "$msg" == *"$ASSET_TITLE"$'\n'* ]]; then
      check "[$src] 节标题独立成行（无命令替换吞行粘连）" 0
    else
      check "[$src] 节标题独立成行（无命令替换吞行粘连）" 1
    fi
    if [[ "$msg" == *$'\n\n'"$ASSET_TITLE"* ]]; then
      check "[$src] 节标题段前空一行（tg_section 语义）" 0
    else
      check "[$src] 节标题段前空一行（tg_section 语义）" 1
    fi
    _nsep=$(printf '%s' "$msg" | grep -c "━━━━━━━━━━━━━━━━━━" || true)
    check "[$src] 分隔线仅标题 1 条（实际 $_nsep，看板段不得自带）" \
      $([ "$_nsep" = "1" ] && echo 0 || echo 1)
  done
else
  echo "── 端到端渲染：非 bash 环境跳过 ──"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: 资产段桥接契约全部成立"
else
  echo "FAIL: 存在契约破坏，见上方 ❌ 项"
fi
exit "$FAIL"
