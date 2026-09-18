#!/bin/bash
# ===== 「层级/深度 vs 健康窗口」同构分离实验（回答 §0 的待解矛盾）=====
#
# 为什么必须做（2026-09-18，主轮 35308273431 驱动）:
#   §0 当前列着一条**未解就不能改修法方向**的矛盾:
#     · §12.14.3（run 35294896071 / 35295178274）: 在 `5/` 下新建 4 个互不相关
#       的**全新**顶层目录 → **4/4 真成功** ⇒ 判「非通用缺陷，路径局部」。
#     · §12.14.6（主轮 35308273431）: `API mkdir` 对 `5/5058f1af`
#       （**同样是 dest_path(`5/`) 直属的全新名字**）报 `HTTP_CODE:200`
#       但 `lsd` 读不到 ⇒ **假成功**。
#
#   ⚠️ 关键修正（本脚本设计时核对代码得出，文档此前表述为"深度差"）:
#     生产里那个 `5058f1af` **不是深层路径** —— 它是**根目录文件折叠**的产物:
#       `file_dir_rel = "."` ⇒ `_hash_dir_rel_for` 对 `"."` 取 md5 前 8 位
#       = `md5(".")[0:8]` = **`5058f1af`**（本机已核: `printf '%s' "." | md5sum`）。
#     而 `hash_dst_dir = "${dest_path}/${HASH_DIR_REL}"` = `openlist:wopan175/5/5058f1af`
#       ⇒ 它与 §12.14.3 的 `5/ol2p_*` **同深度（都是 dest_path 直属）、同形状
#         （都是全新名字）**。
#   ⇒ 故「深度差异」这个解释**在落点上不成立**。剩下的差异只可能有三类:
#     ① **名字内容**: `5058f1af`（8 位 hex）vs `ol2p_<ts>_a1`（带字母/下划线）；
#     ② **该名字已被 mkdir 过**（生产 `06:10` 与 `06:11` 两次同构，且更早轮次
#        也可能建过）⇒ **后端残留了"半个对象"**；
#     ③ **健康窗口**: §12.14.3 当轮恰好健康（两轮相隔数小时，非同时段）。
#
# 三组实验（同轮、同构、逐变量分离 —— 教训「实验设计要数清变量」）:
#   E1 · 同深度、同形状、只差"名字已被建过与否":
#        在 dest_path(`5/`) 下同一轮内建:
#          a. **复刻生产失败落点** `5/5058f1af`（历史名字，可能已残留）
#          b. 3 个**同深度全新**目录（复刻 §12.14.3 的 ol2p_* 形态）
#        判读: a 失败而 b 成功 ⇒ **变量②（名字已建过/后端残留）成立**，与深度无关；
#              a、b 都成功 ⇒ **变量③（健康窗口/时间）成立**，§12.14.6 当轮是坏窗口；
#              a、b 都失败 ⇒ **变量①（名字内容）或后端整体**，需再看 E2。
#   E2 · 深度阶梯（沿**生产真实故障路径**逐级下探）:
#        对 `5/<L2 段>/`（生产里 mkdir 假成功的那层）:
#          a. 每级建**全新名字**目录（固定用同一种 ol2p_ 形态，排除名字变量）
#          b. 对照建**该级真实生产名**（`1024j-视频-pornhub-channel` / `kate-bloom`）
#        判读: 只有深层失败 ⇒ 深度相关；各级都失败 ⇒ 该 L2 子树整体坏（§12.14.3 的判决）；
#              全新名成功而生产名失败 ⇒ 名字/残留相关。
#   E3 · 健康窗口锚点（**时间维度的同轮对照**）:
#        在 E1/E2 跑完之后，**再重跑一次 E1 的 (a) 落点**。
#        判读: 若"先失败后成功" ⇒ **健康窗口确实在漂移**（同轮内自证，不靠跨轮对照）；
#              两次一致 ⇒ 窗口稳定，前两组的差异可归因到名字/深度。
#   E5 · **兜底落点真写入判决**（2026-09-18 补，回答用户"同步到底能不能救回"）:
#        前提: E1a 已建出兜底落点。在该落点里 `copyto` 一个自建小文件 + **全路径直读**复核。
#        为什么必须补: 前面全是"目录能否建"，而用户要的是**文件能否落盘**；
#        「目录建得出」≠「文件写得进」。生产故障轮里失败文件走的正是这条落点。
#        判读: 写得进 ⇒ 兜底本可救回，问题在**兜底流程/判据走死**（可修 bug）；
#              写不进 ⇒ dest_path 整体不可写（**后端问题，代码无解**）。
#
# ⚠️ 安全约定（同 diag_l2_probe.sh）:
#   · 只在**自建目录**（前缀 `ol2d_<ts>_`，可辨识）里写；收尾尽力 purge。
#   · ⚠️ E1a 会**复用生产失败落点名 `5/5058f1af`** —— 这是本实验的**核心对照**，
#     不能改名。风险: 若后端确实残留了坏对象，我们可能把 `5/5058f1af` 建成真目录。
#     为控风险: 只有当它在本轮**被成功建成**时才在收尾 purge（否则它本来就是坏的，
#     purge 也无意义）；且该目录**只被 mkdir，不写文件**，不会影响任何生产文件。
#   · 不移动/不改动任何生产文件。
#
# 用法: bash diag_depth_probe.sh [挂载根] [容器名] [dest_path 相对路径] [L2 段名] [全新名个数]
#   默认: openlist:wopan175 openlist 5 "1024j-视频-pornhub-channel" 3
# 环境变量:
#   DIAG_DP_DEST      dest_path 相对挂载根的路径（默认 5；生产 task5-wopan175 即此值）
#   DIAG_DP_L2        L2 段名（默认 1024j-视频-pornhub-channel，生产故障层）
#   DIAG_DP_L2_LEAF   L2 下的叶子段（默认 kate-bloom，生产故障路径的第三段）
#   DIAG_DP_N         E1b 全新名个数（默认 3，2~4 合理）
#   DIAG_DP_HASH8     生产失败落点名（默认 5058f1af = md5(".")[0:8]，勿改）
#   DIAG_DP_SKIP_E2   1=跳过 E2 深度阶梯
#   DIAG_DP_SKIP_E3   1=跳过 E3 健康窗口锚点
#   DIAG_DP_WAIT      E1 假成功后等待秒数（默认 15；§12.14.4 实测列表可见性 ~10s）
#   DIAG_REPORT       报告路径（默认 /tmp/ol_diag/depth_report.txt）
#
# 退出码恒为 0（诊断工具；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan175}"
CONTAINER="${2:-openlist}"
DEST_REL="${3:-${DIAG_DP_DEST:-5}}"
L2_SEG="${4:-${DIAG_DP_L2:-1024j-视频-pornhub-channel}}"
L2_LEAF="${DIAG_DP_L2_LEAF:-kate-bloom}"
L2_N="${5:-${DIAG_DP_N:-3}}"
HASH8="${DIAG_DP_HASH8:-5058f1af}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/depth_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"
# 假成功后的等待：§12.14.4 实测「列表可见性 首次非空=10s」，取 15s 留余量。
# 不带等待会把"列表还没刷新"误读成"根本没落"，把成功判成失败（AGENTS.md 已记为教训）。
WAIT="${DIAG_DP_WAIT:-15}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
_short_ol() { local p="$1"; if [ "${#p}" -gt 64 ]; then printf '%s…%s' "${p:0:30}" "${p: -30}"; else printf '%s' "$p"; fi; }

# 统一探测: mkdir → lsd 复核，输出三元组（与 diag_l2_probe.sh / diag_escape_probe.sh 同口径）
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

# 假成功复核: 立即 lsd 若不可见，等 WAIT 秒再 lsd 一次（区分"列表滞后"与"根本没落"）
# 用法: _recheck <远端目录> → 全局 _R_NOW / _R_AFTER
_recheck() {
  local dir="$1"
  _R_NOW=0; _R_AFTER=0
  rclone lsd "$dir" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _R_NOW=1
  if [ "$_R_NOW" -eq 1 ]; then
    _R_AFTER=1
    return 0
  fi
  sleep "$WAIT"
  rclone lsd "$dir" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _R_AFTER=1
  [ "$_R_AFTER" -eq 1 ] && return 0 || return 1
}

say "「层级/深度 vs 健康窗口」同构分离实验"
say "挂载根:        $TARGET"
say "容器名:        $CONTAINER"
say "dest_path 相对: $DEST_REL"
say "L2 段（生产故障层）: $L2_SEG"
say "L2 下叶子段:    $L2_LEAF"
say "生产失败落点名: $HASH8（= md5(\".\")[0:8]，与 dest_path 同深度）"
say "全新名个数:     $L2_N    等待: ${WAIT}s"
say "开始时间:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say ""
say "核心: §12.14.3 测 \${dest_path}/ol2p_* **能建**，§12.14.6 测 \${dest_path}/${HASH8}"
say "      **假成功** —— 两者**同深度、同形状**，只差'名字内容'与'是否被建过'。"
say "      本实验在同一轮内把'名字'与'时间窗口'两个变量分开。"

TS=$(date +%s)
DEST_ABS="$TARGET/$DEST_REL"
L2_ABS="$DEST_ABS/$L2_SEG"
LEAF_ABS="$L2_ABS/$L2_LEAF"

# ── E0 · 前置 ────────────────────────────────────────────────
sec "E0 · 前置（dest_path / L2 / 叶子 各级现状）"
E0_OK=0
if _mk "$DEST_ABS" "E0[dest_path ${DEST_REL}]"; then E0_OK=1; fi
say "   判读: dest_path 本身$( [ "$E0_OK" = "1" ] && echo '存在（健康窗口锚点正常）' || echo '**不存在** ⇒ 本轮后端整体异常，结论弱' )"
say "   逐步确认 L2 / 叶子 是否存在（只读，不建）:"
for _p in "$L2_ABS" "$LEAF_ABS"; do
  _ex=0; rclone lsd "$_p" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _ex=1
  say "     lsd $(_short_ol "$_p") → 存在=${_ex}"
done

# ── E1 · 同深度、同形状：只差"名字内容 / 是否被建过" ─────────
sec "E1 · 同深度同形状对照（生产失败落点名 vs 全新名，同在 dest_path 下）"
say "判读: a 失败而 b 成功 ⇒ 变量是**名字/残留**（与深度无关）"
say "      a、b 都成功 ⇒ 变量是**健康窗口**（§12.14.6 当轮是坏窗口）"
say "      a、b 都失败 ⇒ 后端整体/该层坏，看 E2"
say ""

# E1a · 复刻生产失败落点（历史名字，可能已被建过 ⇒ 后端或残留半个对象）
E1A_DIR="$DEST_ABS/$HASH8"
say "── [E1a] 复刻生产失败落点（历史名字）"
say "   落点: $(_short_ol "$E1A_DIR")"
E1A_OK=0; E1A_FAKE=0
if _mk "$E1A_DIR" "E1a[历史名 $HASH8]"; then
  E1A_OK=1
elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
  E1A_FAKE=1
  say "   ⇒ 立即不可见，复核是否延迟落盘（等 ${WAIT}s）..."
  if _recheck "$E1A_DIR"; then E1A_OK=1; E1A_FAKE=0; fi
  say "   复核: 立即=${_R_NOW} · 等待后=${_R_AFTER}"
fi
say ""

# E1b · 同深度全新名（复刻 §12.14.3 的 ol2p_* 形态，排除"名字内容"变量）
E1B_NAMES=()
for (( i=1; i<=L2_N; i++ )); do
  case $(( i % 3 )) in
    1) E1B_NAMES+=("ol2d_${TS}_n${i}") ;;
    2) E1B_NAMES+=("ol2d${TS}${i}") ;;
    0) E1B_NAMES+=("ol2d-${TS}-x${i}") ;;
  esac
done
say "── [E1b] 同深度**全新名**（名字形态与 §12.14.3 的 ol2p_* 同构）"
say "   待测: ${E1B_NAMES[*]}"
E1B_OK=0; E1B_FAKE=0; E1B_DIRS=()
for _nm in "${E1B_NAMES[@]}"; do
  _d="$DEST_ABS/$_nm"
  E1B_DIRS+=("$_d")
  if _mk "$_d" "E1b[$_nm]"; then
    E1B_OK=$(( E1B_OK + 1 ))
  elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
    if _recheck "$_d"; then
      E1B_OK=$(( E1B_OK + 1 ))
      say "       ↳ 复核: 立即=${_R_NOW} · 等待后=${_R_AFTER} ⇒ 延迟落盘，计入真成功"
    else
      E1B_FAKE=$(( E1B_FAKE + 1 ))
      say "       ↳ 复核: 立即=${_R_NOW} · 等待后=${_R_AFTER} ⇒ **确认假成功**"
    fi
  fi
done
say ""
say "── E1 判读 ──"
if [ "$E1A_OK" -eq 0 ] && [ "$E1A_FAKE" -eq 1 ] && [ "$E1B_OK" -eq "$L2_N" ]; then
  say "🔒🔒 **变量 = 名字/残留，与深度无关**（本轮同轮实测）:"
  say "     · 历史名「${HASH8}」（同深度、同形状）: **假成功/失败**"
  say "     · 同深度全新名 ${L2_N}/${L2_N}: **真成功**"
  say "   ⇒ §12.14.3 与 §12.14.6 的矛盾**不是深度造成的**，而是「这个名字被建过」"
  say "     （后端残留半个对象 / 该名字被拒）⇒ 修法方向应指向"
  say "     「**兜底目录名不能复用历史失败名**，须带随机盐/时间戳」，不是「跳出子树」"
  say "   ⇒ ⚠️ 但 §12.14.6 的落点名「5058f1af」是 md5(.) 的**确定性产物**"
  say "     ⇒ 每轮重算都是同一个名字 ⇒ 一旦它坏，就**永远坏**（自我复现），"
  say "       这正是生产里「两次 mkdir 同构失败」的机制"
elif [ "$E1A_OK" -eq 1 ] && [ "$E1B_OK" -eq "$L2_N" ]; then
  say "🔒 **同深度名全部真成功**（含历史名 ${HASH8}）"
  say "   ⇒ 说明**本轮处于健康窗口**，§12.14.6 的失败是**当轮坏窗口**（变量③成立）"
  say "   ⇒ 与 §12.14.3「非通用缺陷」一致；矛盾解释为「窗口漂移」"
elif [ "$E1A_OK" -eq 0 ] && [ "$E1B_OK" -eq 0 ]; then
  say "⚠️ **同深度全部建不出** ⇒ 无论名字新旧都失败"
  say "   ⇒ 既非深度、也非名字 ⇒ 疑**该 dest_path 层整体坏**或**后端当轮异常**，看 E2/E3"
else
  say "⚠️ 混合结果（E1a 成功=${E1A_OK} · E1b 真成功=${E1B_OK}/${L2_N} · E1b 假成功=${E1B_FAKE}）"
  say "   ⇒ 对照 E1b 里成功与失败名单的差异（长度/字符集/前缀）找规律"
fi

# ── E2 · 深度阶梯（沿生产真实故障路径逐级下探）──────────────
sec "E2 · 深度阶梯（沿生产故障路径逐级下探，每级「全新名 vs 生产名」对照）"
if [ "${DIAG_DP_SKIP_E2:-0}" = "1" ]; then
  say "（DIAG_DP_SKIP_E2=1，跳过）"
else
  say "判读: 只有深层失败 ⇒ 深度相关；各级都失败 ⇒ 该 L2 子树整体坏；"
  say "      全新名成功而生产名失败 ⇒ 名字/残留相关"
  say ""
  # 逐级: dest_path 下建 L2（全新名 vs 生产 L2 名）
  #       L2 下建叶子（全新名 vs 生产叶子名）
  #       ⚠️ 全部用「全新名」做载体，避免与生产数据混淆
  E2_ROWS=()
  # 自建目录登记表（收尾 purge 用；E2 建的层级最深，必须显式登记否则会残留）
  E2_DIRS=()

  # 第 1 级: L2 层（生产里 mkdir 假成功的就是这一层）
  _new_l2="ol2d_${TS}_l2"
  _d="$DEST_ABS/$_new_l2"
  E2_DIRS+=("$_d")
  say "── [E2-1] 在 dest_path 下新建 L2 级目录（全新名）"
  _st="fake"
  if _mk "$_d" "E2-1[全新 L2 名]"; then
    _st="ok"
  elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
    _recheck "$_d" && _st="ok_late" || _st="fake"
  fi
  E2_ROWS+=("dest_path/<全新L2名> = $_st")
  say ""
  say "── [E2-1'] dest_path 下的**生产 L2 名**（只读判定，不新建）"
  _ex=0; rclone lsd "$L2_ABS" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _ex=1
  say "   生产 L2 ($L2_SEG) lsd 存在=${_ex}"
  E2_ROWS+=("dest_path/<生产L2名> = $([ "$_ex" -eq 1 ] && echo ok || echo absent)")
  say ""

  # 第 2 级: L2 下建叶子（用 E2-1 建成的全新 L2 作父层，保证父层健康）
  _new_leaf="ol2d_${TS}_leaf"
  if [ "$_st" = "ok" ] || [ "$_st" = "ok_late" ]; then
    _d2="$DEST_ABS/$_new_l2/$_new_leaf"
    E2_DIRS+=("$_d2")
    say "── [E2-2] 在**新建的** L2 下再建一级（深度 +1，隔离父层变量）"
    _st2="fake"
    if _mk "$_d2" "E2-2[全新叶子名]"; then
      _st2="ok"
    elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
      _recheck "$_d2" && _st2="ok_late" || _st2="fake"
    fi
    E2_ROWS+=("dest_path/<全新L2>/<全新叶> = $_st2")
  else
    say "── [E2-2] 跳过（E2-1 的父层未建成，深度对照不成立）"
    E2_ROWS+=("dest_path/<全新L2>/<全新叶> = 跳过")
  fi
  say ""

  # 第 3 级: 生产 L2 下建全新名（直接验「该子树是否整体坏」）
  say "── [E2-3] 在**生产 L2 子树**下新建全新名（验「子树整体坏」）"
  _d3="$L2_ABS/ol2d_${TS}_inbad"
  E2_DIRS+=("$_d3")
  _st3="fake"
  if _mk "$_d3" "E2-3[坏子树内·全新名]"; then
    _st3="ok"
  elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
    _recheck "$_d3" && _st3="ok_late" || _st3="fake"
  fi
  E2_ROWS+=("dest_path/<生产L2>/<全新名> = $_st3")

  say ""
  say "── E2 汇总 ──"
  for _r in "${E2_ROWS[@]}"; do say "   $_r"; done
  say ""
  if [ "$_st3" = "fake" ] && { [ "$_st" = "ok" ] || [ "$_st" = "ok_late" ]; }; then
    say "🔒 **该 L2 子树整体坏**（dest_path 直下能建、进该子树就假成功）"
    say "   ⇒ 与 §12.14.3「路径局部、故障污染整棵子树」**完全一致**"
  elif [ "$_st3" = "ok" ] || [ "$_st3" = "ok_late" ]; then
    say "⚠️ **该 L2 子树内新建目录成功** ⇒ §12.14.6 当轮坏窗口的可能性上升（看 E3）"
  fi
fi

# ── E3 · 健康窗口锚点（时间维度的同轮对照）──────────────────
sec "E3 · 健康窗口锚点（E1/E2 之后，再测一次 E1a 落点）"
if [ "${DIAG_DP_SKIP_E3:-0}" = "1" ]; then
  say "（DIAG_DP_SKIP_E3=1，跳过）"
else
  say "判读: 「先失败后成功」⇒ **健康窗口在漂移**（同轮自证）；两次一致 ⇒ 窗口稳定"
  say ""
  _ex=0; rclone lsd "$E1A_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _ex=1
  say "── [E3-1] 只读复核 E1a 落点当前是否已落盘"
  say "   $(_short_ol "$E1A_DIR") lsd 存在=${_ex}"
  if [ "$E1A_FAKE" -eq 1 ] && [ "$_ex" -eq 1 ]; then
    say "   🔒🔒 **窗口漂移实锤**: 同轮内「mkdir 假成功 → 稍后自行落盘」"
    say "      ⇒ 生产失败的机制是**异步延迟落盘**，且延迟 > ${WAIT}s"
    say "      ⇒ 修法: 建后**带真值复核的等待/重试**即可，不必换通路"
  else
    say "── [E3-2] 重复 build E1a 落点（复审一次 mkdir）"
    _st_e3="fake"
    if _mk "$E1A_DIR" "E3-2[复测历史名]"; then
      _st_e3="ok"
    elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
      _recheck "$E1A_DIR" && _st_e3="ok_late" || _st_e3="fake"
    fi
    say "   复测结论: $_st_e3 （首测: $([ "$E1A_OK" -eq 1 ] && echo ok || echo fake/失败)）"
    if [ "$E1A_FAKE" -eq 1 ] && { [ "$_st_e3" = "ok" ] || [ "$_st_e3" = "ok_late" ]; }; then
      say "   🔒🔒 **窗口漂移实锤**: 同轮内「首测假成功 → 复测成功」"
      say "      ⇒ 差异是**时间**，不是名字/深度 ⇒ 修法: 带真值复核的重试（成本最低）"
    elif [ "$E1A_FAKE" -eq 1 ] && [ "$_st_e3" = "fake" ]; then
      say "   ⇒ 两次一致假成功 ⇒ **窗口稳定**，该名字确实建不出"
      say "      ⇒ 结合 E1b: 若全新名成功 ⇒ 归因「历史名/残留」（须给兜底名录带随机盐）"
    fi
  fi
fi

# ── E4 · 已存在目录可写性（对照）────────────────────────────
sec "E4 · 已存在目录可写性（对照：目录能建 ≠ 能写文件）"
if [ "$E1B_OK" -gt 0 ]; then
  _w="${E1B_DIRS[0]}"
  say "   落盘目录: $(_short_ol "$_w")（E1b 真成功目录）"
  printf 'depth probe payload' > "/tmp/ol2d_${TS}.bin"
  _out=$(rclone copyto "/tmp/ol2d_${TS}.bin" "$_w/ol2d_${TS}.bin" \
         --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _rc=$?
  say "   copyto rc=${_rc}"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -2 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  # ⚠️ 用**直读**判「文件在不在」（AGENTS.md 教训：列列举会滞后，等也未必够）
  _stat=0
  rclone lsjson "$_w/ol2d_${TS}.bin" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _stat=1
  say "   目标全路径 stat: 在=${_stat}（直读判据，优先于列列举）"
  rm -f "/tmp/ol2d_${TS}.bin" 2>/dev/null || true
else
  say "（E1b 无真成功目录 ⇒ E4 跳过）"
fi

# ── E5 · 兜底落点的「真写入」判决（回答「能否靠兜底救回同步」）──
# 为什么必须补这一组（2026-09-18，用户指出前几轮"越走越偏"后回归目标）:
#   前面所有组只判「目录能不能建」（mkdir+lsd），但**用户要的是文件能不能落盘**。
#   「目录建得出」≠「文件写得进」（E4 已证同一点：同一目录 copyto 才是最终判据）。
#   生产故障轮里失败文件走的正是**这条兜底落点**（`dest_path/<hash8>`）⇒ 必须直接
#   在这条真实落点上**写一个真文件并直读复核**，否则无法区分下面两种结局:
#     · 落点能写 ⇒ 兜底流程自己走死了（有可修的 bug，改代码即可救回同步）
#     · 落点也写不进 ⇒ dest_path 整体不可写（后端问题，代码无解，只能等恢复）
#   ⚠️ 只写一个**自建小文件**（前缀 ol2d_，收尾 purge），不碰任何生产文件。
sec "E5 · 兜底落点真写入（判决：能建目录 ≠ 能落文件）"
E5_VERDICT="未测"
E5_DIR="$DEST_ABS/$HASH8"
if [ "$E1A_OK" -eq 1 ]; then
  say "   前提满足: E1a 已把兜底落点建出来（$(_short_ol "$E5_DIR")）"
  printf 'depth probe write payload' > "/tmp/ol2d_w_${TS}.bin"
  _o=$(rclone copyto "/tmp/ol2d_w_${TS}.bin" "$E5_DIR/ol2d_w_${TS}.bin" \
       --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _r=$?
  _w409=0; is_409 "$_o" && _w409=1
  say "   copyto rc=${_r} · 409特征=${_w409}"
  [ "$_r" -ne 0 ] && say "$_o" | tail -2 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  # ⚠️ 直读判据（AGENTS.md 教训：列列举滞后，等也未必够 ⇒ 必须全路径 stat）
  _s=0
  rclone lsjson "$E5_DIR/ol2d_w_${TS}.bin" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _s=1
  say "   目标全路径 stat: 在=${_s}（直读判据）"
  rm -f "/tmp/ol2d_w_${TS}.bin" 2>/dev/null || true
  if [ "$_s" -eq 1 ]; then
    E5_VERDICT="落点可写（文件真落盘）"
    say "   🔒🔒 **判决: 兜底落点「建得出**且**写得进」**"
    say "      ⇒ 生产故障轮里失败文件**本可以被兜底救回**"
    say "      ⇒ 问题在**兜底流程/判据自己走死**（可修的代码 bug），不是后端不可写"
  else
    E5_VERDICT="落点建得出但写不进"
    say "   🔒 **判决: 兜底落点「建得出但文件写不进」**（rc=${_r}）"
    say "      ⇒ 目录层与文件层是两条通路: 建目录成功不代表能落文件"
    say "      ⇒ 与 §12.14.6 生产形态一致 ⇒ 修法须针对**写入通路**，非目录名/落点"
  fi
else
  say "   （E1a 未建成兜底落点 ⇒ 无法测写入；见 E1/E3 判读）"
  E5_VERDICT="落点建不出，未测写入"
fi
say ""

# ── 清理 + 汇总 ─────────────────────────────────────────────
sec "E9 · 清理（尽力 purge 自建测试目录）"
_cleaned=0; _left=0
# ⚠️ E1a 是**生产失败落点名**，只在"本轮确实建成了它"时才 purge：
#   若它本来就没落盘，purge 毫无意义且可能触碰后端残留状态。
#   ⚠️ E5 在 E1a 目录内写过一个自建文件 ⇒ 此时 purge 会把该文件一并清掉（正是所需）。
if [ "$E1A_OK" -eq 1 ]; then
  rclone purge "$E1A_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
    && _cleaned=$(( _cleaned + 1 )) || _left=$(( _left + 1 ))
fi
# ⚠️ 用 `set -u` 安全展开: 数组为空时 "${arr[@]}" 在旧 bash 会报未绑定变量。
#    E2 被跳过时 E2_DIRS 从未赋值 ⇒ 必须用 ${E2_DIRS[@]:-} 形态。
for _d in ${E1B_DIRS[@]:-} ${E2_DIRS[@]:-}; do
  [ -n "$_d" ] || continue
  rclone purge "$_d" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
    && _cleaned=$(( _cleaned + 1 )) || _left=$(( _left + 1 ))
done
say "   已清理: ${_cleaned} 次 purge 成功 · ${_left} 次失败（ol2d_ 前缀可辨识）"

say ""
say "==================== 汇总 ===================="
say "E0 dest_path 存在:     ${E0_OK}"
say "E1a 历史名 $HASH8:     $( [ "$E1A_OK" -eq 1 ] && echo '真成功' || echo '假成功/失败' )"
say "E1b 同深度全新名:      ${E1B_OK}/${L2_N} 真成功 · ${E1B_FAKE} 假成功"
say "E5 兜底落点真写入:     ${E5_VERDICT}"
say "E3 窗口:               $( [ "$E1A_FAKE" -eq 1 ] && echo '首测失败（见 E3 判读）' || echo '首测即成功（窗口健康）' )"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
