#!/bin/bash
# ===== L2 级「mkdir 假成功」普遍性实验（回答「是通用缺陷还是个例」）=====
#
# 为什么必须做（2026-09-18，run 35291770701 驱动）:
#   目录名变量实验已排除「名字相关」与「父层不可建」:
#     · D1: L1(5) mkdir rc=0 · lsd 存在=1  ⇒ 挂载根与第一层 OK
#     · D1: L2(1024j-视频-pornhub-channel) mkdir rc=0 · 409特征=0 · **lsd 存在=0**
#           ⇒ **mkdir 回报成功但目录并未落盘**（假成功）
#     · D2: 4 种名字（含原样名）在隔离目录下全部 OK ⇒ 与末层名字无关
#     · D3: L2 下的兄弟目录 chilibomba/rolakiki 全部 409 且 lsd 存在=0
#           ⇒ L2 假成功**污染其整个子树**
#   ⇒ 问题收敛到: **在已存在的 L1 下新建顶层目录会「mkdir 假成功」**。
#   但这是**单点**（只试了一个 L2 名字）——按「单点外推」的教训，必须验证**普遍性**:
#     ① 是「该挂载下新建顶层目录一律假成功」（通用缺陷）？
#     ② 还是「只有 1024j-... 这一个名字/路径有问题」（个例）？
#   本脚本用**多个互不相关的顶层目录名**做同构实验，直接判决。
#
# 四组实验:
#   P1 · 普遍性矩阵: 在 L1 下**新建 N 个互不相关**的顶层目录（ASCII/数字/中文混合），
#        每个都做 mkdir → lsd 复核 → 记录「mkdir rc / 409 / lsd 存在」三元组。
#        判读: 全部假成功 ⇒ 通用缺陷；部分/全部真成功 ⇒ 个例（与名字/路径相关）
#   P2 · 假成功的时间维度: 对 P1 里**假成功**的目录，做「立即 lsd → 等待 W 秒 → 再 lsd」，
#        回答「是异步落盘延迟（等等就有）还是根本不落」——
#        这决定修法方向（等待/重试 vs 换建目录通路）
#   P3 · 假成功是否自愈: 对同一个目录**重复 mkdir N 次**并每次 lsd 复核，
#        回答「重试能否自愈」（若能，修复管线只要加重试；若不能，重试纯浪费）
#   P4 · 已存在目录的可写性: 在一个**已存在**的目录里 copyto 一个小文件（真值复核），
#        与 P1 的假成功对照 —— 确认「建不出新目录」但「已有目录能写」
#
# ⚠️ 本脚本在 L1 下**新建测试目录**（前缀 `ol2p_<ts>_`，可辨识、收尾尽力 purge），
#    不写入任何生产目录内部；P4 只在自建目录里落文件。
#
# 用法: bash diag_l2_probe.sh [挂载根] [容器名] [L1 相对路径] [测试目录个数] [等待秒数]
#   默认: openlist:wopan175 openlist 5  4  30
# 环境变量:
#   DIAG_L2_L1       L1 相对路径（在它下面建测试目录；默认 5）
#   DIAG_L2_N        测试目录个数（默认 4，2~8 合理）
#   DIAG_L2_WAIT     P2 等待秒数（默认 30；太短看不出延迟落盘）
#   DIAG_L2_RETRIES  P3 重复 mkdir 次数（默认 3）
#   DIAG_L2_SKIP_P3  1=跳过 P3
#   DIAG_L2_SKIP_P4  1=跳过 P4
#   DIAG_L2_BYTES    P4 载荷字节数（默认 65536）
#   DIAG_REPORT      报告路径（默认 /tmp/ol_diag/l2_report.txt）
#
# 退出码恒为 0（诊断工具；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan175}"
CONTAINER="${2:-openlist}"
L1_REL="${3:-${DIAG_L2_L1:-5}}"
L2_N="${4:-${DIAG_L2_N:-4}}"
L2_WAIT="${5:-${DIAG_L2_WAIT:-30}}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/l2_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"
RETRIES="${DIAG_L2_RETRIES:-3}"
BYTES="${DIAG_L2_BYTES:-65536}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
_short_ol() { local p="$1"; if [ "${#p}" -gt 64 ]; then printf '%s…%s' "${p:0:30}" "${p: -30}"; else printf '%s' "$p"; fi; }

say "L2 级「mkdir 假成功」普遍性实验"
say "挂载根:   $TARGET"
say "容器名:   $CONTAINER"
say "L1 层:    $L1_REL"
say "测试个数: $L2_N   等待: ${L2_WAIT}s   重试: ${RETRIES}"
say "开始时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TS=$(date +%s)
L1_ABS="$TARGET/$L1_REL"

# 统一探测: mkdir → lsd 复核，输出三元组
# 用法: _mk <远端目录> <标签>
#   全局: _K_RC / _K_409 / _K_EXISTS
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
  _K_RC="$_rc"; _K_409="$_409"; _K_EXISTS="$_exists"
  [ "$_exists" -eq 1 ] && return 0 || return 1
}

# ── 前置: L1 必须存在（否则整组结论弱） ──────────────────────
sec "P0 · 前置检查（L1 是否存在）"
P0_L1_OK=0
_mk "$L1_ABS" "P0[L1 ${L1_REL}]" && P0_L1_OK=1
if [ "$P0_L1_OK" = "1" ]; then
  say "⇒ L1 存在，可以做「在其下新建顶层目录」实验"
else
  say "⚠️ **L1 本身不存在** ⇒ 本实验退化为「深度 1 建目录」，"
  say "   与生产故障形态（L1 已存在、建 L2 假成功）**不同构**，结论要打折扣"
fi

# ── P1 · 普遍性矩阵 ─────────────────────────────────────────
sec "P1 · 普遍性矩阵（在 L1 下新建 $L2_N 个互不相关的顶层目录）"
# 名字刻意异构: 纯 ASCII / 数字 / 连字符 / 下划线 / 无扩展名 vs 像扩展名
NAMES=()
for (( i=1; i<=L2_N; i++ )); do
  case $(( i % 4 )) in
    1) NAMES+=("ol2p_${TS}_a${i}") ;;
    2) NAMES+=("ol2p${TS}${i}") ;;
    3) NAMES+=("ol2p-${TS}-c${i}") ;;
    0) NAMES+=("ol2p_${TS}_v${i}.d") ;;
  esac
done
say "待测目录名: ${NAMES[*]}"
say ""
P1_FAKE=0; P1_REAL=0
P1_FAKE_LIST=""
declare -A P1_STATE=()
for _nm in "${NAMES[@]}"; do
  if _mk "$L1_ABS/$_nm" "P1[$_nm]"; then
    P1_REAL=$(( P1_REAL + 1 )); P1_STATE["$_nm"]="real"
  elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
    P1_FAKE=$(( P1_FAKE + 1 )); P1_STATE["$_nm"]="fake"
    P1_FAKE_LIST="${P1_FAKE_LIST}${_nm} "
  else
    P1_STATE["$_nm"]="err"
  fi
done
say ""
say "P1 结果: 真成功 ${P1_REAL} · **假成功 ${P1_FAKE}** · 其它 $(( L2_N - P1_REAL - P1_FAKE ))"
say "假成功名单: ${P1_FAKE_LIST:-（无）}"
say "── P1 判读 ──"
if [ "$P1_FAKE" -eq "$L2_N" ]; then
  say "🔒 **通用缺陷**：$L2_N 个互不相关的名字**全部假成功**"
  say "   ⇒ 不是名字问题，而是「**在该挂载下新建顶层目录一律不落盘**」"
  say "   ⇒ 修法方向: 换建目录通路（显式 API / 换驱动）或建后真值复核+多次重试，"
  say "     而不是继续在 rclone mkdir 这一条路上加语义分支"
elif [ "$P1_FAKE" -eq 0 ]; then
  say "🔒 **非通用缺陷**：$L2_N 个名字**全部真成功** ⇒ 新建顶层目录本身没问题"
  say "   ⇒ 生产里的失败是**路径/状态个体问题**（结合 D1/D2/D3 判读）"
else
  say "⚠️ **选择性失败**：${P1_REAL} 真成功 / ${P1_FAKE} 假成功 ⇒ 与名字/长度/字符集相关"
  say "   ⇒ 对照假成功与真成功名单的差异（长度/字符集/前缀），找规律"
fi

# ── P2 · 假成功的时间维度 ───────────────────────────────────
sec "P2 · 假成功的时间维度（立即 → 等 ${L2_WAIT}s → 再 lsd）"
if [ "$P1_FAKE" -eq 0 ]; then
  say "（P1 无假成功样本 ⇒ P2 跳过）"
else
  for _nm in $P1_FAKE_LIST; do
    _d="$L1_ABS/$_nm"
    _e1=0; rclone lsd "$_d" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _e1=1
    say "   [$_nm] 立即 lsd 存在=${_e1} · 等待 ${L2_WAIT}s ..."
    sleep "$L2_WAIT"
    _e2=0; rclone lsd "$_d" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _e2=1
    say "   [$_nm] 等待后 lsd 存在=${_e2}"
    if [ "$_e1" -eq 0 ] && [ "$_e2" -eq 1 ]; then
      say "        ⇒ **异步延迟落盘**：等一等就出现了（修法: 建后等待+复核，不必换通路）"
    elif [ "$_e1" -eq 0 ] && [ "$_e2" -eq 0 ]; then
      say "        ⇒ **根本不落盘**：延迟不是原因（修法: 换通路或真值复核后重试）"
    else
      say "        ⇒ 已存在（状态变化，见上）"
    fi
  done
fi

# ── P3 · 假成功是否自愈（重复 mkdir） ───────────────────────
sec "P3 · 假成功是否自愈（对同目录重复 mkdir ${RETRIES} 次）"
if [ "${DIAG_L2_SKIP_P3:-0}" = "1" ]; then
  say "（DIAG_L2_SKIP_P3=1，跳过）"
elif [ "$P1_FAKE" -eq 0 ]; then
  say "（P1 无假成功样本 ⇒ P3 跳过）"
else
  P3_HEAL=0; P3_STUCK=0
  for _nm in $P1_FAKE_LIST; do
    say ""
    say "   ── [$_nm] ──"
    _healed=0
    for (( _r=1; _r<=RETRIES; _r++ )); do
      _out=$(rclone mkdir "$L1_ABS/$_nm" --timeout "$MKDIR_TIMEOUT" 2>&1); _rc=$?
      _409=0; is_409 "$_out" && _409=1
      _ex=0; rclone lsd "$L1_ABS/$_nm" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _ex=1
      say "      第 ${_r} 次: rc=${_rc} · 409=${_409} · lsd 存在=${_ex}"
      if [ "$_ex" -eq 1 ]; then _healed=1; break; fi
      sleep 3
    done
    if [ "$_healed" -eq 1 ]; then
      P3_HEAL=$(( P3_HEAL + 1 ))
      say "      ⇒ **可自愈**（重试后落盘）"
    else
      P3_STUCK=$(( P3_STUCK + 1 ))
      say "      ⇒ **不可自愈**（${RETRIES} 次重试后仍不落盘）"
    fi
  done
  say ""
  say "P3 结果: 可自愈 ${P3_HEAL} · 不可自愈 ${P3_STUCK}"
  if [ "$P3_STUCK" -gt 0 ] && [ "$P3_HEAL" -eq 0 ]; then
    say "🔒 **重试无效** ⇒ 修复管线里的「重复 mkdir / 顺延下轮」对这类失败是纯浪费，"
    say "   须换通路（显式 API mkdir 或改驱动），或建后做真值复核再决定是否顺延"
  elif [ "$P3_HEAL" -gt 0 ]; then
    say "⇒ **重试有效**（至少部分样本）⇒ 修复管线加重试/等待即可缓解，成本低"
  fi
fi

# ── P4 · 已存在目录的可写性（对照） ─────────────────────────
sec "P4 · 已存在目录的可写性（对照 P1 的假成功）"
if [ "${DIAG_L2_SKIP_P4:-0}" = "1" ]; then
  say "（DIAG_L2_SKIP_P4=1，跳过）"
else
  # 用一个我们**确认已存在**的目录: 优先 P1 里真成功的；否则退回 L1 自身
  P4_DIR=""
  for _nm in "${NAMES[@]}"; do
    if [ "${P1_STATE[$_nm]:-}" = "real" ]; then P4_DIR="$L1_ABS/$_nm"; break; fi
  done
  [ -n "$P4_DIR" ] || P4_DIR="$L1_ABS"
  say "落盘目录: $(_short_ol "$P4_DIR")（$( [ "$P4_DIR" = "$L1_ABS" ] && echo 'L1 自身（已存在）' || echo 'P1 真成功目录' )）"
  P4_SRC="/tmp/ol2_payload.bin"
  head -c "$BYTES" /dev/urandom > "$P4_SRC" 2>/dev/null || printf 'x%.0s' $(seq 1 "$BYTES") > "$P4_SRC"
  _out=$(rclone copyto "$P4_SRC" "$P4_DIR/ol2p_probe_${TS}.bin" \
         --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _rc=$?
  _409=0; is_409 "$_out" && _409=1
  say "   copyto rc=${_rc} · 409特征=${_409}"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  _vis=0
  rclone lsf "$P4_DIR/ol2p_probe_${TS}.bin" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _vis=1
  say "   写入后 lsf 可见=${_vis}"
  if [ "$_rc" -eq 0 ] && [ "$_vis" -eq 1 ]; then
    say "🔒 **已存在目录可写**确实成立 ⇒ 与 P1 对照: 「新目录建不出」≠「后端不可写」"
    say "   ⇒ 「可写性预检」把两者混为一谈正是误判根源"
  elif [ "$_rc" -eq 0 ] && [ "$_vis" -eq 0 ]; then
    say "⚠️ **写入假成功**（rc=0 但不可见）⇒ 与 P1 同源的假成功也出现在文件层"
  else
    say "⚠️ 写入失败（rc=${_rc}）⇒ 与 P1 不同形态，需人工看报错"
  fi
  rm -f "$P4_SRC" 2>/dev/null || true
fi

# ── 清理 + 汇总 ─────────────────────────────────────────────
sec "P9 · 清理（尽力 purge 自建测试目录）"
_cleaned=0; _left=0
for _nm in $P1_FAKE_LIST "${NAMES[@]}"; do
  rclone purge "$L1_ABS/$_nm" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
    && _cleaned=$(( _cleaned + 1 )) || _left=$(( _left + 1 ))
done
say "   已清理: ${_cleaned} 次 purge 成功 · ${_left} 次失败（ol2p_ 前缀可辨识）"

say ""
say "==================== 汇总 ===================="
say "P0 L1 存在:      ${P0_L1_OK}"
say "P1 真成功/假成功: ${P1_REAL}/${P1_FAKE}（共 ${L2_N}）"
say "P1 假成功名单:    ${P1_FAKE_LIST:-（无）}"
say "P3 自愈:          $([ "${DIAG_L2_SKIP_P3:-0}" = "1" ] && echo '跳过' || echo "${P3_HEAL:-?} 自愈 / ${P3_STUCK:-?} 不自愈")"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
