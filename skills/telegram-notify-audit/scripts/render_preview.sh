#!/usr/bin/env bash
# Telegram 通知渲染预览（对应 docs/telegram-notify.md 8.1 节）
#
# 用法（skill 真身在仓库根的 skills/ 下，供所有 AI 工具共用）:
#   bash skills/telegram-notify-audit/scripts/render_preview.sh [仓库根目录]
#
# 用真源助手构造数据渲染一遍，能抓到纯代码审查漏掉的三类问题：
#   1. 转义被二次处理（& → &amp;amp;）
#   2. 空行数量不对（双空行 / 该有空行却没有）
#   3. $( ) 吃掉尾换行导致条目粘连
# 本脚本自带这三项的机器校验，输出末尾会打印 PASS/FAIL。
set -uo pipefail

# 本文件可能经符号链接被调用（例如 WorkBuddy 从 .workbuddy-ai/skills/ 链接过来），
# 此时 dirname 返回的是链接所在目录、按固定级数上溯会算错 → 先用 `cd -P` 取物理路径，
# 再逐级向上找含真源的目录，不依赖上溯级数。
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

if [ ! -f "$SOURCE" ]; then
  echo "找不到真源: $SOURCE" >&2
  echo "请把仓库根目录作为第一个参数传入" >&2
  exit 1
fi

# bash 真源是 bash 语法（printf -v / \${!var} / \$'\n'），zsh 下 source 会 bad substitution
if [ -n "${BASH_VERSION:-}" ]; then
  source "$SOURCE"
else
  echo "请用 bash 执行本脚本（zsh 下 source 真源会 bad substitution）" >&2
  exit 1
fi

# 让收尾区显示出来（不设 TG_RUN_URL 时会走降级、整行跳过，看不到收尾区版式）
export TG_RUN_URL="${TG_RUN_URL:-https://github.com/example/repo/actions/runs/123456}"
export TG_RUN_STARTED_AT="${TG_RUN_STARTED_AT:-2026-09-12T04:00:00Z}"

FAIL=0
check() { # check <描述> <期望成立的条件(0/1)>
  if [ "$2" -eq 0 ]; then echo "  ✅ $1"; else echo "  ❌ $1"; FAIL=1; fi
}

echo "=== 1. 结果通知（kv + 树形条目 + 折叠 + 说明段 + 收尾区）==="
msg=""
tg_add_title msg "⚠️ task0 部分文件同步失败"
tg_add_kv msg "任务" "task0"
tg_add_path msg "源端" "onedrive:0/media & <剧集>"
tg_add_kv msg "状态" "部分失败"
tg_add_section msg "❌ 无法同步文件 · 3"
entries=""
# 注意：tg_add_entry 收的是「裸主体 + 元数据」，传 \$(tg_entry …) 会套出双层 <code>
tg_add_entry entries "media/大文件A.mkv" "超过 45 GiB，需分割后重传"
tg_add_entry entries "media/损坏B.mp4" "moov atom 缺失"
tg_add_entry entries "media/被排除C.tmp" "命中排除规则"
tg_add_block msg "$(tree_fold "$entries")"
tg_add_note msg "成功条目已从 marker 修复清单移除；失败条目保留，可重试。"
tg_add_footer msg
printf '%s\n' "$msg"

echo ""
echo "=== 2. 多行块 tg_add_pre（转义 + <pre> 包裹）==="
m2=""
tg_add_title m2 "🚨 自愈失败"
tg_add_section m2 "🧾 关键日志"
tg_add_pre m2 "2026/09/12 ERROR: Failed to copy <a> & \"b\" > c"
tg_add_footer m2
printf '%s\n' "$m2"

echo ""
echo "=== 3. 折叠（12 条 → 8 条 + 折叠行）==="
big=""
for i in $(seq 1 12); do tg_add_entry big "file$i.mp4" "1.150 GiB"; done
folded="$(tree_fold "$big")"
printf '%s\n' "$folded"

echo ""
echo "=== 自动校验 ==="
sep_len=$(printf '%s' "$TG_SEP" | wc -m | tr -d ' ')
[ "$sep_len" -eq 18 ]; check "分隔线为 18 条（实测 ${sep_len}）" $?
# 注意：写 ━━\{18\} 会被解析成「1 个字面 ━ + 后一个重复 18 次」= 19 条，必须只写一个
printf '%s' "$msg" | grep -q '^━\{18\}$'; check "标题分隔线渲染正确" $?
printf '%s' "$msg" | grep -q '^  ├─ <code>media/大文件A.mkv</code> · '; check "条目为 ├─ 树形且主体等宽" $?
printf '%s' "$msg" | grep -q '&amp;amp;'; [ $? -ne 0 ]; check "无二次转义（&amp;amp;）" $?
printf '%s' "$msg" | grep -q '&amp; &lt;剧集&gt;'; check "动态内容已转义一次" $?
printf '%s' "$msg" | grep -q '└─ <code>media/被排除C.tmp</code>'; check "末条用 └─ 且无双 └─" $?
# 只校验链接部分：⏱ 时长依赖 GNU date 的 -d，macOS(BSD date) 下解析失败 → 时长按
# 3.9 节降级链消失，属预期，不判 FAIL（Linux runner 上会正常显示「⏱ 已运行 X 」）
printf '%s' "$msg" | grep -q '🔗 <a href=.*>运行日志</a>'; check "收尾区含运行日志链接" $?
case "$(printf '%s' "$msg")" in
  *"命中排除规则"$'\n\n'"成功条目"*) check "说明段前有且仅有一个空行" 0 ;;
  *) check "说明段前有且仅有一个空行" 1 ;;
esac
printf '%s' "$m2" | grep -q '<pre>2026/09/12 ERROR: Failed to copy &lt;a&gt; &amp;'; check "<pre> 内已转义" $?
printf '%s' "$folded" | grep -q '└─ 还有 4 条…'; check "12 条折叠为 8 条 + 「还有 4 条…」" $?
printf '%s' "$folded" | grep -c '└─' | grep -q '^1$'; check "折叠后只有一个 └─" $?

echo ""
if [ "$FAIL" -eq 0 ]; then echo "全部校验通过"; else echo "存在 FAIL，逐条看上面"; fi
exit "$FAIL"
