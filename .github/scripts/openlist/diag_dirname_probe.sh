#!/bin/bash
# ===== 目录名/路径变量实验（回答「为什么这个特定目录建不出来」）=====
#
# 为什么必须做（2026-09-18，run 35289924584 驱动）:
#   上一次诊断（diag_write_probe.sh）已排除「后端整体不可写」与
#   「绕开隐式 mkParentDir 就能写」两个假设：
#     · W4 在**已存在的隔离目录**里写入 rc=0 ⇒ 后端对已存在目录可写
#     · W3 用 --no-check-dest 仍 409（报错仍是 mkParentDir）⇒ rclone 上传
#       必须确保父目录存在，参数绕不开
#     · W1 里 lsd rc=3 ⇒ 目标目录**根本不存在**（"目录已就绪"是 API 200 的假阳性）
#   ⇒ 问题收敛到一点: **这个特定路径的目录建不出来**。
#   本脚本用**变量分离**区分三种可能:
#     ① 名字相关 —— 只有这个名字建不出来（后端对某些名字有保留/限制）
#     ② 路径相关 —— 是父层/层级的问题（父目录本身建不出来）
#     ③ 后端残留 —— wopan 侧已有同名目录但驱动看不到 → MKCOL 恒冲突
#
# 三组实验（变量分离，逐级定位）:
#   D1 · 父层递进: 从挂载根开始**逐级** mkdir + lsd，找出**第一层**建不出来的位置
#        （这一组回答"是路径相关还是名字相关"——若中间某层就失败，则与末层名字无关）
#   D2 · 末层名字变量: 在同级分别用 4 种名字建目录（隔离前缀，**不动生产目录**）
#        · 原样名（重现）
#        · 原样名+后缀（同字符集、不同串）
#        · 纯 ASCII 短名（排除非 ASCII 因素）
#        · 短哈希名（生产兜底实际用的形态）
#        判读: 若"原样名失败、其它成功" ⇒ 名字相关；若全失败 ⇒ 路径/父层相关
#   D3 · 生产同级探测: 对该目录的**同级兄弟目录**（如 chilibomba/rolakiki）做 mkdir/lsd，
#        看它们是"已存在且可写"还是"同样建不出来" —— 区分"全区不可写"与"单目录异常"
#
# ⚠️ 本脚本**不写入任何生产目录内部**，D2 只在隔离目录（oldiagd_<ts>/）下建子目录；
#    D1/D3 只做 mkdir + lsd（mkdir 与 lsd 对已存在目录是幂等的），不落文件。
#
# 用法: bash diag_dirname_probe.sh [挂载根] [容器名] [故障目录相对路径] [同级兄弟目录相对路径(可多个,空格分隔)]
#   默认: openlist:wopan175 openlist  <空>  <空>
# 环境变量:
#   DIAG_DN_DIR     故障目录相对路径（等价第 3 参数）
#   DIAG_DN_SIBS    同级兄弟目录相对路径（空格分隔，等价第 4 参数）
#   DIAG_DN_SKIP_D3 1=跳过 D3
#   DIAG_REPORT     报告路径（默认 /tmp/ol_diag/dirname_report.txt）
#
# 退出码恒为 0（诊断工具；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan175}"
CONTAINER="${2:-openlist}"
FAIL_DIR_REL="${3:-${DIAG_DN_DIR:-}}"
SIBS_RAW="${4:-${DIAG_DN_SIBS:-}}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/dirname_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
is_mkparentdir() { grep -Eqi 'mkParentDir' <<<"$1"; }
_short_ol() { local p="$1"; if [ "${#p}" -gt 64 ]; then printf '%s…%s' "${p:0:30}" "${p: -30}"; else printf '%s' "$p"; fi; }

say "目录名/路径变量实验（为什么这个特定目录建不出来）"
say "挂载根:       $TARGET"
say "容器名:       $CONTAINER"
say "故障目录:     ${FAIL_DIR_REL:-（未给）}"
say "同级兄弟目录: ${SIBS_RAW:-（未给）}"
say "开始时间:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TS=$(date +%s)

# 统一探测函数: mkdir 后 lsd 复核，输出一行结论
# 用法: _probe_mkdir <远端目录> <标签>
#   全局: _PM_MKDIR_RC / _PM_409 / _PM_EXISTS
_probe_mkdir() {
  local dir="$1" label="$2"
  local _out _rc _409 _http
  _out=$(rclone mkdir "$dir" --timeout "$MKDIR_TIMEOUT" 2>&1); _rc=$?
  _409=0; is_409 "$_out" && _409=1
  _http=$(http_code_of "$_out")
  # 无论 mkdir 的 rc 如何，都用**只读** lsd 判存在性（存在性 ≠ 可写性）
  local _exists=0
  rclone lsd "$dir" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 && _exists=1
  say "   ${label}: mkdir rc=${_rc} · http=${_http:-无} · 409特征=${_409} · **lsd 存在=${_exists}**"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -2 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  _PM_MKDIR_RC="$_rc"; _PM_409="$_409"; _PM_EXISTS="$_exists"
  # 判定: 只有"mkdir 成功或 409 且 lsd 存在"才算这一层 OK
  if [ "$_exists" -eq 1 ]; then return 0; else return 1; fi
}

# ============================================================
# D1 · 父层递进（逐级找出第一层建不出来的位置）
# ============================================================
sec "D1 · 父层递进（逐级 mkdir + lsd，找第一层失败点）"
if [ -z "$FAIL_DIR_REL" ]; then
  say "（未给故障目录 ⇒ D1 跳过）"
else
  # 拆段递进: 5 → 5/1024j-... → 5/1024j-.../aeon-marks
  IFS='/' read -r -a _segs <<< "$FAIL_DIR_REL"
  _acc=""
  D1_FIRST_FAIL_LEVEL=""
  D1_OK_LEVELS=0
  for _i in "${!_segs[@]}"; do
    [ -n "${_segs[$_i]}" ] || continue
    if [ -z "$_acc" ]; then _acc="${_segs[$_i]}"; else _acc="${_acc}/${_segs[$_i]}"; fi
    _lvl=$(( _i + 1 ))
    if _probe_mkdir "$TARGET/$_acc" "L${_lvl}"; then
      D1_OK_LEVELS=$(( D1_OK_LEVELS + 1 ))
    else
      D1_FIRST_FAIL_LEVEL="L${_lvl}（${_segs[$_i]}）"
      say "   ⇢ **第一层失败点 = L${_lvl}（段名: ${_segs[$_i]}）**"
      # 父层失败 ⇒ 后面各层必然也失败，不再逐级浪费时间
      break
    fi
  done
  say ""
  if [ -n "$D1_FIRST_FAIL_LEVEL" ]; then
    say "D1 结论: 第一层失败于 ${D1_FIRST_FAIL_LEVEL}（前 ${D1_OK_LEVELS} 层均 OK）"
    if [ "$D1_OK_LEVELS" -le 2 ]; then
      say "  ⇒ 失败在**浅层**（挂载根附近）⇒ 更像**后端整体/挂载层**问题，非末层名字问题"
    else
      say "  ⇒ 失败在**末层**（深层）⇒ 更像**该层名字或该层路径残留**问题"
    fi
  else
    say "D1 结论: 所有层级均已存在/可建（未找到失败层）"
    say "  ⇒ 若 D2 里原件名仍建不出，则问题**不在父层**，而在末层名字或残留"
  fi
fi

# ============================================================
# D2 · 末层名字变量（隔离目录内，不动生产目录）
# ============================================================
sec "D2 · 末层名字变量（在隔离目录内，4 种名字对比）"
BASE="$TARGET/oldiagd_${TS}"
if ! rclone mkdir "$BASE" --timeout "$MKDIR_TIMEOUT" >/dev/null 2>&1; then
  say "❌ 隔离父目录创建失败: $(_short_ol "$BASE")（后端可能整体不可写）"
else
  say "隔离父目录: $(_short_ol "$BASE")（已就绪）"
  # 若给了故障目录，取其**末层段名**作为"原样名"
  FAIL_LEAF=""
  if [ -n "$FAIL_DIR_REL" ]; then
    IFS='/' read -r -a _fs <<< "$FAIL_DIR_REL"
    # 取最后一个非空段
    for (( _k=${#_fs[@]}-1; _k>=0; _k-- )); do
      if [ -n "${_fs[$_k]}" ]; then FAIL_LEAF="${_fs[$_k]}"; break; fi
    done
  fi
  [ -n "$FAIL_LEAF" ] || FAIL_LEAF="aeon-marks"

  # 四种名字: 原样 / 原样+后缀 / 纯 ASCII 短名 / 短哈希
  NAME_ORIG="$FAIL_LEAF"
  NAME_ORIG_SUF="${FAIL_LEAF}_probe${TS}"
  NAME_ASCII="dnprobe_ascii_${TS}"
  NAME_HASH="$(printf '%s' "$FAIL_DIR_REL" | md5sum | cut -c1-8)"
  say ""
  say "待测名字: 原样=[$NAME_ORIG] · +后缀=[$NAME_ORIG_SUF] · ASCII=[$NAME_ASCII] · 短哈希=[$NAME_HASH]"

  D2_RESULTS=""
  for _pair in "原样:$NAME_ORIG" "+后缀:$NAME_ORIG_SUF" "ASCII:$NAME_ASCII" "短哈希:$NAME_HASH"; do
    _lbl="${_pair%%:*}"; _nm="${_pair#*:}"
    say ""
    if _probe_mkdir "$BASE/$_nm" "   D2[$_lbl]"; then
      _r="OK"
    else
      _r="FAIL"
    fi
    D2_RESULTS="${D2_RESULTS}${_lbl}=${_r}(409=${_PM_409}) "
  done
  say ""
  say "D2 原始结果: $D2_RESULTS"
  # 判读
  _orig_ok=0; _others_ok=0; _others_n=0
  case "$D2_RESULTS" in *"原样=OK"*) _orig_ok=1;; esac
  for _p in "+后缀" "ASCII" "短哈希"; do
    _others_n=$(( _others_n + 1 ))
    case "$D2_RESULTS" in *"${_p}=OK"*) _others_ok=$(( _others_ok + 1 ));; esac
  done
  say "── D2 判读 ──"
  if [ "$_orig_ok" -eq 0 ] && [ "$_others_ok" -eq "$_others_n" ]; then
    say "🔒 **名字相关**：只有「原样名」建不出来，其它形态都成功"
    say "   ⇒ 后端对**这个特定名字**有保留/限制（或该名字在网盘侧已残留）"
    say "   ⇒ 修法方向: 修复管线为这类名字准备**改名/短哈希**兜底（生产已有短哈希目录机制）"
  elif [ "$_orig_ok" -eq 0 ] && [ "$_others_ok" -eq 0 ]; then
    say "🔒 **非名字相关**：4 种名字**都**建不出来 ⇒ 与末层名字无关"
    say "   ⇒ 指向**父层/路径/挂载层**问题（结合 D1 的第一失败层判读）"
  elif [ "$_orig_ok" -eq 1 ]; then
    say "ℹ️ 隔离目录里「原样名」能建出来 ⇒ **该名字本身没问题**"
    say "   ⇒ 生产里的失败很可能来自**该路径的残留状态**（③）或**父层**（②），"
    say "     而非名字本身。需结合 D1/D3 判读。"
  else
    say "⚠️ 形态混合（$_orig_ok / $_others_ok of $_others_n）—— 见上方原始结果人工判读"
  fi
fi

# ============================================================
# D3 · 生产同级兄弟目录探测
# ============================================================
sec "D3 · 生产同级兄弟目录探测（区分「单目录异常」与「全区不可写」）"
if [ "${DIAG_DN_SKIP_D3:-0}" = "1" ]; then
  say "（DIAG_DN_SKIP_D3=1，跳过）"
elif [ -z "$SIBS_RAW" ]; then
  say "（未给同级兄弟目录 ⇒ D3 跳过）"
else
  D3_OK=0; D3_N=0
  for _sib in $SIBS_RAW; do
    D3_N=$(( D3_N + 1 ))
    say ""
    if _probe_mkdir "$TARGET/$_sib" "   D3[$(basename "$_sib")]"; then
      D3_OK=$(( D3_OK + 1 ))
    fi
  done
  say ""
  say "D3 结果: ${D3_OK}/${D3_N} 个兄弟目录存在/可建"
  if [ "$D3_N" -gt 0 ] && [ "$D3_OK" -eq "$D3_N" ]; then
    say "🔒 **单目录异常**：同级兄弟目录**全部 OK** ⇒ 不是「整个区不可写」"
    say "   ⇒ 与 D2 结合: 若 D2 也指向名字/残留，则可确认为**该目录个体问题**"
  elif [ "$D3_OK" -eq 0 ]; then
    say "🔒 **整区异常**：同级兄弟目录**全部**建不出来 ⇒ 指向父层/挂载层问题"
  else
    say "⚠️ 部分兄弟 OK（${D3_OK}/${D3_N}）⇒ 该层有**选择性**失败，需人工看哪些失败"
  fi
fi

# ────────────────────────────────────────────────────────────
sec "D9 · 清理（尽力）"
rclone purge "$BASE" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 隔离目录未能清除: $(_short_ol "$BASE")（oldiagd_ 前缀可辨识）"

say ""
say "==================== 汇总 ===================="
say "D1 第一失败层: ${D1_FIRST_FAIL_LEVEL:-无/未跑}"
say "D2 末层名字:   ${D2_RESULTS:-未跑}"
say "D3 同级兄弟:   ${D3_OK:-?}/${D3_N:-?} OK"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
