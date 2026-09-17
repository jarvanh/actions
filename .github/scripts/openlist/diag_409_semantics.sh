#!/bin/bash
# ===== 409 语义验证 + 「短名改回原名是否蒸发」实验（单次 ~10–15 分钟）=====
#
# 为什么单独存在（方案 B 的验证环，2026-09-17）:
#   2026-09-17 的修复（commit 2bf7836）把 409 Conflict 重新解读为「目录已存在」
#   （MKCOL 幂等语义），据此改了 4 处建目录点 + 分类器 + 预检放行 + 整轮重试。
#   但那个解读**只有 RFC 语义与日志推断支撑，没有在后端实测过** —— 这是方案 B
#   自认的最大风险点: 若"已存在"解释不成立（真因是后端真故障），修复方向要推翻。
#   本脚本就是把这个语义钉死。
#
# 两组实验（变量分离）:
#   E1 · 409 语义判定（**判决性**，决定修复是否成立）
#     E1a 对**已存在的目录**发 mkdir → 若回 409 ⇒ "已存在即 409" 成立
#     E1b 对**不存在的目录**发 mkdir → 若回非 409 ⇒ 409 可区分"已存在"
#     判读: E1a=409 且 E1b≠409 ⇒ **修复方向正确**（409 是幂等语义，放行合理）
#           两者都回 409 ⇒ **"已存在"解释不成立** ⇒ 修复必须推翻，回到"后端故障"方向
#           两者都非 409 ⇒ 该后端不复现本形态（换时段/后端重跑）
#     为什么两条都要做: 只看 E1a 会把"后端对所有 mkdir 都回 409"误读成"已存在"。
#
#   E2 · 短名改回原名是否蒸发（回答用户最初的问题）
#     把一个**真实落盘的短名文件**（方法2 产物 `<md5前8位>.<ext>`）改名回**原名**，
#     三时点复核（即时→延迟→重启真值）。
#     为什么重要: 修复管线走的是"改名绕过"（短名直传），若改回原名就蒸发，
#       说明**还原步骤（restore）本身有风险** —— 后端有文件、但还原后消失。
#
# 用法: bash diag_409_semantics.sh [目标父目录] [容器名]
#   默认: openlist:wopan176Crypt/2  openlist
# 环境变量:
#   DIAG_409_SRC       E2 用的**源端**文件路径（如 onedrive:2/xx/原名.mp4，换行分隔，取第 1 个）。
#                      必须给: E2 要"同内容 + 原名"，只能从源端重传一份原名版本。
#                      未提供 ⇒ E2 跳过（E1 仍完整执行，E1 才是判决性的）。
#   DIAG_409_SKIP_E1   1=跳过 E1（只做 E2）
#   DIAG_409_SKIP_E2   1=跳过 E2（只做 E1，纯只读更快）
#   DIAG_REPORT        报告路径（默认 /tmp/ol_diag/diag409_report.txt）
#
# ⚠️ 副作用: 在 $TARGET 下创建 oldiag409_<ts>/ 目录并尽力删除（含 E2 的原名产物）。
#   后端半死时删除可能失败，残留以 oldiag409_ 前缀可辨识（不参与同步）。
#
# 退出码恒为 0（诊断工具，失败信息在报告里；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan176Crypt/2}"
CONTAINER="${2:-openlist}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/diag409_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
SOURCE_TIMEOUT="${DIAG_409_SRC_TIMEOUT:-1200s}"
RESTART_WAIT="${DIAG_409_RESTART_WAIT:-45}"
DELAY_WAIT="${DIAG_409_DELAY_WAIT:-120}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

# 从 rclone 输出摘 HTTP 码（同 diag_backend.sh 口径: 不用 \b，避开进度行 "450.089 MiB"）
http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
# 摘出 Conflict/409 特征（不管 http_code 能不能解析出来，文本特征更稳）
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
is_mkparentdir() { grep -Eqi 'mkParentDir' <<<"$1"; }
# 路径缩短展示（远端名很长，报告里要能读）
_short_ol() { local p="$1"; if [ "${#p}" -gt 56 ]; then printf '%s…%s' "${p:0:28}" "${p: -24}"; else printf '%s' "$p"; fi; }

say "409 语义验证 + 短名改回原名实验（方案 B 验证环）"
say "目标父目录: $TARGET"
say "容器名:     $CONTAINER"
say "开始时间:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TS=$(date +%s)
BASE="$TARGET/oldiag409_${TS}"

# ────────────────────────────────────────────────────────────
sec "E0 · 环境"
say "rclone: $(rclone version 2>/dev/null | head -1)"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  say "容器:   $(docker inspect -f '{{.State.Status}} since {{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
else
  say "容器:   ❌ docker inspect 失败"
fi
# 判定本组实验是否可做: 父目录必须可写，否则所有 mkdir 都失败，结论无意义
if ! rclone mkdir "$BASE" --timeout "$MKDIR_TIMEOUT" >/dev/null 2>&1; then
  say "❌ 诊断父目录创建失败: $BASE"
  say "   先查该后端可写性（diag_backend.sh 常规探针），否则本实验结论不可信。"
  say ""
  say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi
say "诊断父目录: $BASE（已就绪）"

# ────────────────────────────────────────────────────────────
# E1 · 409 语义判定（判决性）
# ────────────────────────────────────────────────────────────
if [ "${DIAG_409_SKIP_E1:-0}" = "1" ]; then
  say ""
  say "（E1 已按 DIAG_409_SKIP_E1=1 跳过）"
else
  sec "E1 · 409 语义判定（判决性）"

  # E1a: 对**已存在**的目录再发一次 mkdir
  EXIST_DIR="$BASE/exists_probe"
  rclone mkdir "$EXIST_DIR" --timeout "$MKDIR_TIMEOUT" >/dev/null 2>&1 || true
  say "E1a 目标: $(_short_ol "$EXIST_DIR")（**已存在**，刚创建）"
  say "  先确认它真的在:"
  if rclone lsd "$EXIST_DIR" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1; then
    say "  ✅ 目录存在（lsd 通过）"
    _out=$(rclone mkdir "$EXIST_DIR" --timeout "$MKDIR_TIMEOUT" 2>&1)
    _rc=$?
    _http=$(http_code_of "$_out")
    _409=0; is_409 "$_out" && _409=1
    _mkp=0; is_mkparentdir "$_out" && _mkp=1
    say "  重复 mkdir 退出码: $_rc · http=${_http:-无} · 409特征=$_409 · mkParentDir=$_mkp"
    [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
    E1A_RC="$_rc"; E1A_409="$_409"
  else
    say "  ❌ 目录建出来了但 lsd 读不到 —— 无法做 E1a（该后端目录列表不可信）"
    E1A_RC="na"; E1A_409="na"
  fi

  # E1b: 对**不存在**的目录发 mkdir（对照）
  say ""
  NEW_DIR="$BASE/brandnew_probe"
  say "E1b 目标: $(_short_ol "$NEW_DIR")（**不存在**）"
  _out=$(rclone mkdir "$NEW_DIR" --timeout "$MKDIR_TIMEOUT" 2>&1)
  _rc=$?
  _http=$(http_code_of "$_out")
  _409=0; is_409 "$_out" && _409=1
  _mkp=0; is_mkparentdir "$_out" && _mkp=1
  say "  首次 mkdir 退出码: $_rc · http=${_http:-无} · 409特征=$_409 · mkParentDir=$_mkp"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  E1B_RC="$_rc"; E1B_409="$_409"

  # E1c: 对刚建出来的新目录**再发一次** mkdir（看第二次是否 409 = 已存在语义的直接证据）
  say ""
  say "E1c 目标: $(_short_ol "$NEW_DIR")（**刚建出，现在应该已存在**）—— 重复 mkdir"
  _out=$(rclone mkdir "$NEW_DIR" --timeout "$MKDIR_TIMEOUT" 2>&1)
  _rc=$?
  _http=$(http_code_of "$_out")
  _409=0; is_409 "$_out" && _409=1
  say "  重复 mkdir 退出码: $_rc · http=${_http:-无} · 409特征=$_409"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  E1C_RC="$_rc"; E1C_409="$_409"

  # E1 判读
  say ""
  say "── E1 判读 ──"
  if [ "$E1A_409" = "1" ] && [ "$E1B_409" = "0" ]; then
    say "✅ **409 = 「目录已存在」成立**（E1a 已存在→409；E1b 不存在→非409）"
    say "   ⇒ commit 2bf7836 的修复方向正确：409 是幂等语义，复核后放行合理。"
  elif [ "$E1A_409" = "1" ] && [ "$E1B_409" = "1" ]; then
    say "🔒 **「已存在」解释不成立**（已存在与不存在**都**回 409）"
    say "   ⇒ 409 不是幂等语义，而是该后端的通用失败形态。"
    say "   ⇒ ⚠️ 必须推翻 commit 2bf7836 的①（409 放行），改回「后端故障」方向重判。"
  elif [ "$E1A_409" = "0" ] && [ "$E1B_409" = "0" ]; then
    say "ℹ️ 本后端**不复现** 409 形态（两次 mkdir 都未报 409）"
    say "   ⇒ 该现象有时段性/后端特异性；换时段或换后端（如 wopan175）重跑本实验。"
  else
    say "⚠️ 形态异常（E1a 409=$E1A_409 / E1b 409=$E1B_409）—— 见上方原始输出人工判读。"
  fi
  say "   原始数值: E1a(rc=$E1A_RC,409=$E1A_409) E1b(rc=$E1B_RC,409=$E1B_409) E1c(rc=$E1C_RC,409=$E1C_409)"
  say "   注: E1c（刚建出再 mkdir）若报 409，是与 E1a 独立的第二重「已存在」证据。"
fi

# ────────────────────────────────────────────────────────────
# E2 · 短名改回原名是否蒸发
# ────────────────────────────────────────────────────────────
E2_STATUS="skipped"
if [ "${DIAG_409_SKIP_E2:-0}" = "1" ]; then
  say ""
  say "（E2 已按 DIAG_409_SKIP_E2=1 跳过）"
elif [ -z "${DIAG_409_SRC:-}" ]; then
  say ""
  say "（E2 跳过: 未提供 DIAG_409_SRC —— 该实验需要源端文件做「同内容+原名」重传）"
else
  sec "E2 · 短名改回原名是否蒸发"

  # 取第一个源（换行分隔，剥空行）
  _src="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$DIAG_409_SRC" | grep -v '^$' | head -1)"
  if [ -z "$_src" ]; then
    say "❌ DIAG_409_SRC 解析后为空 —— E2 跳过"
  else
    _base="${_src##*/}"
    case "$_base" in *.*) _ext=".${_base##*.}";; *) _ext="";; esac
    _hash8=$(printf '%s' "$_base" | md5sum 2>/dev/null | cut -c1-8)
    [ -n "$_hash8" ] || _hash8="deadbeef"
    SHORT_NAME="${_hash8}${_ext}"          # 方法2 产物形态（短名）
    ORIG_NAME="$_base"                     # 原名

    _sz=$(rclone size --json "$_src" --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null | jq -r '.bytes // empty' 2>/dev/null)
    if [ -z "$_sz" ] || ! [[ "$_sz" =~ ^[0-9]+$ ]]; then
      say "❌ 源文件 size 拿不到: $_src —— E2 跳过"
    else
      say "源: $_src（${_sz} B）"
      say "短名形态: $SHORT_NAME"
      say "原名形态: $ORIG_NAME"
      say ""
      say "步骤1 · 以**短名**上传（模拟方法2 的修复产物）"
      _d="$BASE/e2"
      rclone mkdir "$_d" --timeout "$MKDIR_TIMEOUT" >/dev/null 2>&1 || true
      _out=$(rclone copyto "$_src" "$_d/$SHORT_NAME" \
        --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$SOURCE_TIMEOUT" 2>&1)
      if [ $? -eq 0 ]; then
        say "  ✅ 短名上传被受理"
      else
        say "  ❌ 短名上传失败 (http=$(http_code_of "$_out"))"
        say "$_out" | tail -2 | sed 's/^/     ▸ /' | tee -a "$REPORT"
      fi

      # 三时点复核: 即时 → 延迟 → 重启真值（与 diag_reject.sh 同哲学）
      LSDIR=/tmp/ol_diag/e2_lsf; mkdir -p "$LSDIR"
      lsf_now() { rclone lsf "$_d" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null > "$1" || true; }
      in_snap() { [ -n "$1" ] && grep -qxF "$1" "$2" 2>/dev/null && return 0 || return 1; }

      lsf_now "$LSDIR/s_t1"
      say "  ① 即时（缓存口径）: 短名可见=$(in_snap "$SHORT_NAME" "$LSDIR/s_t1" && echo 是 || echo 否)"

      say ""
      say "步骤2 · **改名回原名**（模拟 restore 还原步骤）"
      _out=$(rclone moveto "$_d/$SHORT_NAME" "$_d/$ORIG_NAME" \
        --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$SOURCE_TIMEOUT" 2>&1)
      _mv_rc=$?
      if [ $_mv_rc -eq 0 ]; then
        say "  ✅ 改名回原名被受理"
      else
        say "  ⚠️ 改名失败 (rc=$_mv_rc, http=$(http_code_of "$_out")) —— 记录并继续（这本身也是结论）"
        say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
      fi

      lsf_now "$LSDIR/t1_immediate"
      say "  ① 改名后即时: 原名可见=$(in_snap "$ORIG_NAME" "$LSDIR/t1_immediate" && echo 是 || echo 否) · 短名残留=$(in_snap "$SHORT_NAME" "$LSDIR/t1_immediate" && echo 是 || echo 否)"

      say "  ② 等待 ${DELAY_WAIT}s（观察延迟落盘）..."
      sleep "$DELAY_WAIT"
      lsf_now "$LSDIR/t2_delayed"
      say "    延迟后: 原名可见=$(in_snap "$ORIG_NAME" "$LSDIR/t2_delayed" && echo 是 || echo 否)"

      say "  ↻ 重启容器取后端真值..."
      if docker restart "$CONTAINER" >/dev/null 2>&1; then
        sleep "$RESTART_WAIT"
        lsf_now "$LSDIR/t0_truth"
        _t_orig=$(in_snap "$ORIG_NAME" "$LSDIR/t0_truth" && echo 是 || echo 否)
        _t_short=$(in_snap "$SHORT_NAME" "$LSDIR/t0_truth" && echo 是 || echo 否)
        say "  ③ 真值（重启后）: 原名可见=$_t_orig · 短名残留=$_t_short"
        say ""
        say "── E2 判读 ──"
        if [ "$_t_orig" = "是" ]; then
          E2_STATUS="原名存活"
          say "✅ **改回原名后真值存活** ⇒ 还原步骤安全，'改回原名会消失'不成立。"
          say "   ⇒ 修复产物可以正常还原成原名（或保留短名，两者都不会丢）。"
        elif [ "$_t_short" = "是" ]; then
          E2_STATUS="改成短名后蒸发"
          say "⚠️ 原名为空、短名也蒸发——改名操作本身触发了丢失（非'原名'问题）。"
        else
          E2_STATUS="改回原名后蒸发"
          say "🔒 **改回原名后真值蒸发** ⇒ 还原步骤有风险！"
          say "   ⇒ 短名产物在、改回原名就消失 ⇒ 后端对**原名**有拒收/覆盖问题。"
          say "   ⇒ 与 §12.13.6「按原名拒收」结论一致：**保留短名、不要还原原名**是更安全的选择。"
        fi
      else
        E2_STATUS="重启失败（真值口径退化）"
        say "  ⚠️ docker restart 失败——真值口径退化为重启前列表，结论不成立。"
      fi
    fi
  fi
fi

# ────────────────────────────────────────────────────────────
sec "E9 · 清理（尽力）"
rclone purge "$BASE" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 诊断目录未能清除: $BASE（以 oldiag409_ 前缀可辨识，不参与同步）"

say ""
say "==================== 汇总 ===================="
if [ "${DIAG_409_SKIP_E1:-0}" != "1" ]; then
  say "E1 (409 语义): E1a(已存在) 409=${E1A_409:-?} · E1b(不存在) 409=${E1B_409:-?} · E1c(刚建出) 409=${E1C_409:-?}"
fi
say "E2 (改回原名): $E2_STATUS"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
