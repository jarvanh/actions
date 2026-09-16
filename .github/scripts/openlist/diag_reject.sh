#!/bin/bash
# ===== 拒收归因专项诊断: 「按内容拒收」vs「按文件名/状态拒收」（单次 ~10–20 分钟）=====
#
# 为什么单独存在（而不是塞进 diag_backend.sh 的 13 组）:
#   V3 复验（run 35085986592，计划文档 §12.13.4）实锤: 方法 1 真实上传
#   （88s/211MB 真实流量、即时尺寸匹配全过）→ 重启容器后 3 文件全部「实际0」。
#   数据进了 OpenList 却从未在后端持久化。而 diag 第 13 组「大文件落盘阶梯」
#   2026-09-15 已收口（16/64/256MB 随机内容全 OK）——它从未测过**内容**这个变量。
#   本脚本补上: 同一批源文件，分三组对照直传同一个诊断目录，重启取真值后归因。
#
# 三组对照（变量分离，全部落在 $TARGET/oldiag_reject_<ts>/ 下）:
#   A 组 · 原名   : 源文件**原名**直传（贴近生产行为，可能走覆盖写路径）
#   B 组 · 改名   : **同内容**换 oldiag_ren_<i>_<ts>.<原扩展名> ⇒ 真值在 = 改名可绕
#   C 组 · 随机   : 与首个 B 源**同字节数**的随机数据 ⇒ 对照通路；C 在而 B 不在
#                   = 内容拒收坐实（与第 13 组「尺寸随机全 OK」互补，锁死内容维度）
#
# 三时点复核（区分「丢失」与「延迟落盘」）:
#   ① 上传后即时（OpenList 缓存口径）→ ② 等 DIAG_REJECT_WAIT 秒再查
#   （OpenList→后端若为异步队列，立即重启会把"还没推完"误判成"拒收"）
#   → ③ 重启容器后（后端真值口径，与 truth-check/第 13 组同哲学）
#
# 用法: bash diag_reject.sh [目标父目录] [容器名]
#   默认: openlist:wopan176Crypt/2  openlist
# 环境变量:
#   DIAG_REJECT_SRC   换行分隔的源端文件远程路径（如 onedrive:0/xx/a.mp4）；**必须换行分隔**
#                     （V3 教训: run 35085545044 用逗号拼成一行，候选匹配按行比对 → not_found）
#   DIAG_REJECT_MAX   最多取前 N 个源文件（默认 1；每个源文件上传两份 ≈ 2×大小，控时长）
#   DIAG_REJECT_WAIT  上传完成后、重启前的等待秒数（默认 120）
#   DIAG_REPORT       报告路径（默认 /tmp/ol_diag/reject_report.txt，独立于 diag_backend.sh）
#
# ⚠️ 副作用: 会在目标下创建 oldiag_reject_<ts>/ 目录并尽力删除（A/B/C 产物一律删除，
#   包括 B——即使 B 落盘也删，结论已记录在报告里，不留生产树污染源）。
#   后端半死时删除可能失败，残留以 oldiag_reject_ 前缀可辨识（不参与同步）。
#
# 退出码恒为 0（诊断工具，失败信息在报告里；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan176Crypt/2}"
CONTAINER="${2:-openlist}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/reject_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
REJECT_WAIT="${DIAG_REJECT_WAIT:-120}"
RESTART_WAIT="${DIAG_REJECT_RESTART_WAIT:-45}"
# 上传参数与 diag_backend.sh 第 13 组（大文件落盘阶梯）同款——同一口径才能横向对比
UP_TIMEOUT="${DIAG_REJECT_TIMEOUT:-1200s}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }
http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }

say "拒收归因专项诊断（V3 §12.13.4 的定向跟进）"
say "目标父目录: $TARGET"
say "容器名:     $CONTAINER"
say "开始时间:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ────────────────────────────────────────────────────────────
sec "R1 · 输入与源文件核验"
SRC_RAW="${DIAG_REJECT_SRC:-}"
REJECT_MAX="${DIAG_REJECT_MAX:-1}"
[[ "$REJECT_MAX" =~ ^[0-9]+$ ]] && [ "$REJECT_MAX" -gt 0 ] || REJECT_MAX=1
if [ -z "$SRC_RAW" ]; then
  say "❌ DIAG_REJECT_SRC 未提供（换行分隔的源端远程路径）——专项未启用，退出"
  say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi
# 必须换行分隔（V3 教训，见文件头）；顺手剥掉空行与首尾空白
mapfile -t SRC_ALL < <(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$SRC_RAW" | grep -v '^$' || true)
SOURCES=()
SRC_BYTES=()
i=0
for _s in "${SRC_ALL[@]}"; do
  [ "${#SOURCES[@]}" -ge "$REJECT_MAX" ] && break
  _sz=$(rclone size --json "$_s" --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null | jq -r '.bytes // empty' 2>/dev/null)
  if [ -z "$_sz" ] || ! [[ "$_sz" =~ ^[0-9]+$ ]]; then
    say "   ⚠️ 跳过（size 拿不到，源不存在或不可读）: $_s"
    continue
  fi
  SOURCES+=("$_s")
  SRC_BYTES+=("$_sz")
  say "   源[$(( ${#SOURCES[@]} - 1 ))] ${_s##*/}（${_sz} B）"
  i=$((i + 1))
done
if [ "${#SOURCES[@]}" -eq 0 ]; then
  say "❌ 没有可用的源文件（全部 size 失败）——退出"
  say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi

DIAGDIR="$TARGET/oldiag_reject_$(date +%s)_$$"
if ! rclone mkdir "$DIAGDIR" >/dev/null 2>&1; then
  say "❌ 诊断目录创建失败: $DIAGDIR——退出"
  say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi
say "诊断目录: $DIAGDIR"

# ────────────────────────────────────────────────────────────
sec "R2 · 三组对照上传"
NAMES_A=()
NAMES_B=()
TS=$(date +%s)
for _i in "${!SOURCES[@]}"; do
  _src="${SOURCES[$_i]}"
  _base="${_src##*/}"
  case "$_base" in *.*) _ext=".${_base##*.}";; *) _ext="";; esac
  _ren="oldiag_ren_${_i}_${TS}${_ext}"

  # A 组 · 原名
  _out=$(rclone copyto "$_src" "$DIAGDIR/$_base" \
    --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$UP_TIMEOUT" 2>&1)
  if [ $? -eq 0 ]; then
    say "   ✅ A[$_i] 原名上传被受理: $_base（${SRC_BYTES[$_i]} B）"
    NAMES_A+=("$_base")
  else
    say "   ❌ A[$_i] 原名上传失败 (http=$(http_code_of "$_out")): $(printf '%s' "$_out" | grep -oE 'ERROR.*' | head -1)"
    say "$_out" | tail -2 | sed 's/^/      ▸ /' | tee -a "$REPORT"
    NAMES_A+=("")
  fi
  sleep "${DIAG_PROBE_GAP:-2}"

  # B 组 · 改名（同内容）
  _out=$(rclone copyto "$_src" "$DIAGDIR/$_ren" \
    --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$UP_TIMEOUT" 2>&1)
  if [ $? -eq 0 ]; then
    say "   ✅ B[$_i] 改名上传被受理: $_ren（${SRC_BYTES[$_i]} B）"
    NAMES_B+=("$_ren")
  else
    say "   ❌ B[$_i] 改名上传失败 (http=$(http_code_of "$_out")): $(printf '%s' "$_out" | grep -oE 'ERROR.*' | head -1)"
    say "$_out" | tail -2 | sed 's/^/      ▸ /' | tee -a "$REPORT"
    NAMES_B+=("")
  fi
  sleep "${DIAG_PROBE_GAP:-2}"
done

# C 组 · 随机对照（一次；字节数对齐首个 B 源——变量只剩「内容」）
RAND_NAME="oldiag_rand_${TS}.bin"
_rand_bytes="${SRC_BYTES[0]}"
[ "$_rand_bytes" -lt 1 ] && _rand_bytes=1
head -c "$_rand_bytes" /dev/urandom > /tmp/ol_diag/reject_rand.bin 2>/dev/null || true
_out=$(rclone copyto /tmp/ol_diag/reject_rand.bin "$DIAGDIR/$RAND_NAME" \
  --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$UP_TIMEOUT" 2>&1)
if [ $? -eq 0 ]; then
  say "   ✅ C 随机对照上传被受理: $RAND_NAME（${_rand_bytes} B，与 B[0] 同大小）"
else
  say "   ❌ C 随机对照上传失败 (http=$(http_code_of "$_out")): $(printf '%s' "$_out" | grep -oE 'ERROR.*' | head -1)"
  say "$_out" | tail -2 | sed 's/^/      ▸ /' | tee -a "$REPORT"
  RAND_NAME=""
fi

# ────────────────────────────────────────────────────────────
# 三时点复核: 同一个 lsf 口径查三次，结果落文件供判读
LSDIR=/tmp/ol_diag/reject_lsf
mkdir -p "$LSDIR"
lsf_now() {  # <输出文件>
  rclone lsf "$DIAGDIR" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null > "$1" || true
}
in_snap() {  # <名字> <快照文件> → 0/1
  [ -n "$1" ] && grep -qxF "$1" "$2" 2>/dev/null && return 0 || return 1
}

sec "R3 · 三时点复核"
lsf_now "$LSDIR/t1_immediate"
say "① 即时（缓存口径）: $(grep -c . "$LSDIR/t1_immediate" 2>/dev/null || echo 0) 个条目可见"

say "② 等待 ${REJECT_WAIT}s（观察延迟落盘）..."
sleep "$REJECT_WAIT"
lsf_now "$LSDIR/t2_delayed"
say "   延迟（等待后）: $(grep -c . "$LSDIR/t2_delayed" 2>/dev/null || echo 0) 个条目可见"

docker restart "$CONTAINER" >/dev/null 2>&1 || say "   ⚠️ docker restart 失败——真值口径退化为重启前列表"
sleep "$RESTART_WAIT"
# 真值查询给重试余量（驱动刚就绪时列表可能瞬时抖动）
lsf_now "$LSDIR/t0_truth"
say "③ 真值（重启后）: $(grep -c . "$LSDIR/t0_truth" 2>/dev/null || echo 0) 个条目可见"

# ────────────────────────────────────────────────────────────
sec "R4 · 判读"
# 逐组真值状态行 + 三时点轨迹（即时→延迟→真值）
trace_of() {  # <名字> → "可见/缺失/缺失/缺失" 形态
  local n="$1" t1="缺失" t2="缺失" t3="缺失"
  in_snap "$n" "$LSDIR/t1_immediate" && t1="可见"
  in_snap "$n" "$LSDIR/t2_delayed" && t2="可见"
  in_snap "$n" "$LSDIR/t0_truth" && t3="可见"
  printf '%s→%s→%s' "$t1" "$t2" "$t3"
}

B_ALIVE=0
B_DEAD=0
B_VALID=0
A_ALIVE=0
for _i in "${!NAMES_A[@]}"; do
  _a="${NAMES_A[$_i]}"
  _b="${NAMES_B[$_i]}"
  [ -n "$_a" ] && say "   A[$_i] $(trace_of "$_a")  ($_a)"
  if [ -n "$_b" ]; then
    say "   B[$_i] $(trace_of "$_b")  ($_b)"
    B_VALID=$((B_VALID + 1))
    if in_snap "$_b" "$LSDIR/t0_truth"; then B_ALIVE=$((B_ALIVE + 1)); else B_DEAD=$((B_DEAD + 1)); fi
  fi
  [ -n "$_a" ] && in_snap "$_a" "$LSDIR/t0_truth" && A_ALIVE=$((A_ALIVE + 1))
done
if [ -n "$RAND_NAME" ]; then
  say "   C    $(trace_of "$RAND_NAME")  ($RAND_NAME)"
  say "   （三时点读法: 即时→延迟→真值；「可见→可见→缺失」= 经典假成功蒸发）"
fi

C_OK=0
[ -n "$RAND_NAME" ] && in_snap "$RAND_NAME" "$LSDIR/t0_truth" && C_OK=1

say ""
if [ -n "$RAND_NAME" ] && [ "$C_OK" -eq 0 ]; then
  say "❌ 结论: 通路/目录异常——连随机对照都没在真值里存活，本实验作废。"
  say "   先查该目录可写性（diag_backend.sh 常规探针）或后端驱动状态，再重跑本专项。"
elif [ "$B_VALID" -eq 0 ]; then
  say "❌ 结论: A/B 组上传全部在受理层被拒（WebDAV 层，http 码见 R2 段）——"
  say "   未到「拒收归因」环节；先按 diag_backend.sh 判读指引处理受理层失败。"
elif [ "$B_ALIVE" -gt 0 ]; then
  say "✅ 结论: **按文件名/状态拒收**——同内容改名后真值存活（B 存活 ${B_ALIVE}，蒸发 ${B_DEAD}）。"
  say "   ⇒ 改名可绕过；修复管线可加「改名直传」方法（改名规则要避开触发形态）。"
  [ "$A_ALIVE" -eq 0 ] && say "   A 组（原名）全部蒸发 ⇒ 原名（或其既有状态）就是触发因素。"
  if [ "$B_DEAD" -eq 0 ]; then
    say "   ⚠️ 所有产物真值存活 ⇒ V3 的蒸发现象本次未复现——可能为时段性/时序性"
    say "      （后端行为随时间变化），建议在主轮同款时序下再观察，或换时段重跑本专项。"
  fi
elif [ "$B_DEAD" -gt 0 ]; then
  say "🔒 结论: **按内容拒收坐实**——同内容改名后仍全部蒸发（${B_DEAD} 个），"
  [ "$C_OK" -eq 1 ] && say "   而同大小随机对照（C）真值存活 ⇒ 变量只剩内容（网盘内容审核类静默丢弃）。"
  say "   ⇒ 「换写入方法/换 API 入口」都过不去同一层；止损（标记云端拒收·不可修）有据。"
fi

# ────────────────────────────────────────────────────────────
sec "R5 · 清理（尽力）"
for _n in "${NAMES_A[@]}" "${NAMES_B[@]}" "$RAND_NAME"; do
  [ -n "$_n" ] && rclone deletefile "$DIAGDIR/$_n" --retries 1 --timeout "$PROBE_TIMEOUT" \
    >/dev/null 2>&1 || true
done
rclone purge "$DIAGDIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 诊断目录未能清除: $DIAGDIR（以 oldiag_reject_ 前缀可辨识，不参与同步）"

say ""
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
