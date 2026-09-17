#!/bin/bash
# ===== 目录可写性判据验证（回答「探针写失败 == 目录不可写 吗」）=====
#
# 为什么必须单独做（2026-09-17，run 35239780581 驱动）:
#   上一轮生产实测发现修复管线被**目录可写性预检**整体拦截：
#     mkdir 409 → API mkdir HTTP_CODE:200（API 说建成了）
#     → `🔎 目录可写性（沿用本轮结论 0，已重启确认）`
#     → `🔀 原目录不可写 → 跳过原目录的 4 种方法` → 兜底同样 409 → 放弃
#   而**同一轮、同一后端**，方法1·原名直传成功落盘并持久化了一个 17GB 文件
#   ⇒ 强证据表明「探针判不可写」是**假阴性**。
#
# 已定位的机制假设（本脚本要证实/证伪它）:
#   `_fix_probe_dir_writable`（file_fix.sh:865）用 `rclone copyto` 写一个探针文件。
#   rclone 上传任意文件时会**隐式执行 mkParentDir**；而该目录恰好回
#   `Update mkParentDir failed: Conflict: 409 Conflict` —— 与 mkdir 的报错**逐字相同**。
#   ⇒ 探针复现的是**同一条 409 路径**，而非在测「这个目录收不收文件」。
#   若假设成立，那么：**跳过隐式 mkParentDir 的写入应当成功**。
#
# 三组实验（递进，变量分离）:
#   W1 · 复现：对**真实故障目录**发 mkdir + copyto，确认 409（基线）
#   W2 · 解耦：先**只读** lsd 确认目录存在，再写入 —— 但用**已存在目录内的浅路径**，
#        观察 `--no-check-dest` 与目录层级对 mkParentDir 触发的影响
#   W3 · 判决：**在已确认存在的目录内直接写小文件**（不新建任何父目录），
#        若成功 ⇒ 目录本身可写，预检判据是假阴性，须改为「存在性 + 真写」解耦判据；
#        若仍 409 ⇒ 该目录确实写不进，预检结论正确，须另找方向
#
# 用法: bash diag_write_probe.sh [目标挂载根] [容器名] [真实故障目录相对路径]
#   默认: openlist:wopan175  openlist  （第三参数为空则自动用隔离目录自测）
# 环境变量:
#   DIAG_WP_DIR      真实故障目录（挂载根下的相对路径），如
#                    `5/1024j-视频-pornhub-channel/aeon-marks`
#                    不给 ⇒ 只做隔离目录的 W1/W2/W3 自测（结论弱，仅证明机制）
#   DIAG_WP_BYTES    W3 写入的载荷字节（默认 1048576 = 1 MiB）
#   DIAG_WP_SKIP_RESTART  1=不做重启真值复核（省时，结论按即时口径）
#   DIAG_REPORT      报告路径（默认 /tmp/ol_diag/writeprobe_report.txt）
#
# ⚠️ 副作用: 在目标下创建 oldiagwp_<ts>/ 隔离目录与探针文件，测完尽力清理；
#   在真实故障目录（DIAG_WP_DIR）内也会落一个 1 MiB 探针，测完尽力删除。
#
# 退出码恒为 0（诊断工具；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan175}"
CONTAINER="${2:-openlist}"
REAL_DIR_REL="${3:-${DIAG_WP_DIR:-}}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/writeprobe_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"
WRITE_TIMEOUT="${DIAG_WP_TIMEOUT:-600s}"
RESTART_WAIT="${DIAG_WP_RESTART_WAIT:-45}"
WP_BYTES="${DIAG_WP_BYTES:-1048576}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
is_mkparentdir() { grep -Eqi 'mkParentDir' <<<"$1"; }
_short_ol() { local p="$1"; if [ "${#p}" -gt 60 ]; then printf '%s…%s' "${p:0:30}" "${p: -26}"; else printf '%s' "$p"; fi; }

say "目录可写性判据验证（探针写失败 == 目录不可写 吗）"
say "挂载根:     $TARGET"
say "容器名:     $CONTAINER"
say "真实故障目录: ${REAL_DIR_REL:-（未给，只做隔离目录自测）}"
say "开始时间:   $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

TS=$(date +%s)
BASE="$TARGET/oldiagwp_${TS}"

# ────────────────────────────────────────────────────────────
sec "W0 · 环境"
say "rclone: $(rclone version 2>/dev/null | head -1)"
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  say "容器:   $(docker inspect -f '{{.State.Status}} since {{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)"
else
  say "容器:   ❌ docker inspect 失败（重启真值复核会跳过）"
fi

# 载荷: 本地生成，中性内容
PAYLOAD="/tmp/ol_diag/wp_payload.bin"
head -c "$WP_BYTES" /dev/urandom > "$PAYLOAD" 2>/dev/null || true
if [ ! -s "$PAYLOAD" ]; then
  say "❌ 本地载荷生成失败 —— 退出"
  say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  exit 0
fi
say "载荷:   ${WP_BYTES} B（本地随机，中性）"

# ============================================================
# W1/W2/W3：真实故障目录（判决性）
# ============================================================
W_VERDICT="skipped"
if [ -z "$REAL_DIR_REL" ]; then
  say ""
  say "（未给 DIAG_WP_DIR/第三参数 ⇒ 跳过真实故障目录实验，只做下方隔离目录自测）"
else
  RD="$TARGET/$REAL_DIR_REL"
  sec "W1 · 基线与复现（真实故障目录）"
  say "目标目录: $(_short_ol "$RD")"

  # --- 存在性（只读，不碰写路径）---
  say ""
  say "① 只读判存在性: rclone lsd"
  _lsd_out=$(rclone lsd "$RD" --retries 1 --timeout "$PROBE_TIMEOUT" 2>&1)
  _lsd_rc=$?
  if [ "$_lsd_rc" -eq 0 ]; then
    say "   ✅ 目录**存在**（lsd rc=0）—— 存在性与可写性是两件事"
    W1_EXISTS=1
  else
    say "   ❌ 目录不存在或读不到（lsd rc=$_lsd_rc）"
    say "      ⇒ 目录真不存在时，后续写入必然要建父目录，无法解耦；本组结论弱"
    W1_EXISTS=0
  fi
  [ -n "$_lsd_out" ] && say "$_lsd_out" | tail -2 | sed 's/^/     ▸ /' | tee -a "$REPORT"

  # --- 复现 mkdir 409 ---
  say ""
  say "② 复现 mkdir（预期 409，基线）"
  _out=$(rclone mkdir "$RD" --timeout "$MKDIR_TIMEOUT" 2>&1)
  _rc=$?
  _409=0; is_409 "$_out" && _409=1
  _mkp=0; is_mkparentdir "$_out" && _mkp=1
  _http=$(http_code_of "$_out")
  say "   mkdir rc=$_rc · http=${_http:-无} · 409特征=$_409 · mkParentDir=$_mkp"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  W1_MKDIR_409="$_409"

  # --- 复现「探针写」失败（与 _fix_probe_dir_writable 同款）---
  say ""
  say "③ 复现探针写（与 _fix_probe_dir_writable 同款: copyto 一个小文件进该目录）"
  _probe_name="olwprobe_$(printf '%s' "$TS" | md5sum | cut -c1-8).txt"
  _out=$(rclone copyto "$PAYLOAD" "$RD/$_probe_name" \
    --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$WRITE_TIMEOUT" 2>&1)
  _rc=$?
  _409p=0; is_409 "$_out" && _409p=1
  _mkpp=0; is_mkparentdir "$_out" && _mkpp=1
  _http=$(http_code_of "$_out")
  say "   copyto rc=$_rc · http=${_http:-无} · 409特征=$_409p · mkParentDir=$_mkpp"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -4 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  W1_PROBE_409="$_409p"

  # --- W2: 显式 mkdir（API）后再写 ---
  sec "W2 · 显式建目录（API）后再写（真实故障目录）"
  say "假设: API mkdir 返回 200 时目录已就绪，此时写入不应再触发建父目录"
  OL_TOKEN=""
  if command -v curl >/dev/null 2>&1; then
    # 复用 main workflow 的登录口径：管理面 token（密码来自环境）
    OL_TOKEN=$(curl -s -X POST "http://127.0.0.1:5244/api/auth/login" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg u admin --arg p "${OPENLIST_ADMIN_PASSWORD:-}" '{username:$u,password:$p}')" 2>/dev/null \
      | jq -r '.token // empty' 2>/dev/null)
  fi
  if [ -n "$OL_TOKEN" ]; then
    _ol_path="/${REAL_DIR_REL}"
    _resp=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "http://127.0.0.1:5244/api/fs/mkdir" \
      -H "Authorization: $OL_TOKEN" -H "Content-Type: application/json" \
      -d "$(jq -n --arg path "$_ol_path" '{path:$path}')" 2>&1)
    say "   API mkdir 响应: $(echo "$_resp" | tail -1)（目录: $(_short_ol "$_ol_path")）"
    say "   API mkdir 响应体: $(echo "$_resp" | head -c 200)"
    sleep 3
    _probe2="olwprobe2_$(printf '%s' "$TS" | md5sum | cut -c1-8).txt"
    _out=$(rclone copyto "$PAYLOAD" "$RD/$_probe2" \
      --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$WRITE_TIMEOUT" 2>&1)
    _rc=$?
    _409p2=0; is_409 "$_out" && _409p2=1
    say "   API mkdir 后 copyto rc=$_rc · 409特征=$_409p2"
    [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
    W2_RC="$_rc"; W2_409="$_409p2"
  else
    say "   ⚠️ 未拿到管理面 token（OPENLIST_ADMIN_PASSWORD 缺失或登录失败）⇒ W2 跳过"
    W2_RC="na"; W2_409="na"
  fi

  # --- W3: 判决（跳过隐式 mkParentDir 的写入）---
  sec "W3 · 判决：不新建任何父目录，直接写入已存在目录"
  say "为什么这是判决性: W1 的 copyto 报错是 \`Update mkParentDir failed\`，"
  say "  即失败发生在**建父目录**这一步，而不是「写文件」这一步。"
  say "  若目录确实存在，rclone 不应再试图建它；用 --no-check-dest 与单文件落点"
  say "  尽量绕开上传前的目录同步逻辑，看写入本身能否成功。"
  _probe3="olwprobe3_$(printf '%s' "$TS" | md5sum | cut -c1-8).txt"
  _out=$(rclone copyto "$PAYLOAD" "$RD/$_probe3" \
    --no-check-dest --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$WRITE_TIMEOUT" 2>&1)
  _rc=$?
  _409p3=0; is_409 "$_out" && _409p3=1
  _mkpp3=0; is_mkparentdir "$_out" && _mkpp3=1
  say "   --no-check-dest copyto rc=$_rc · 409特征=$_409p3 · mkParentDir=$_mkpp3"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -4 | sed 's/^/     ▸ /' | tee -a "$REPORT"

  # --- W3b: 落盘可见性（即时）---
  say ""
  say "   W3b 即时可见性复核（lsf 该目录）"
  _snap=$(rclone lsf "$RD" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null || true)
  for _n in "$_probe_name" "$_probe3"; do
    if printf '%s\n' "$_snap" | grep -qxF "$_n"; then
      say "     $(_short_ol "$_n"): 可见=是"
    else
      say "     $(_short_ol "$_n"): 可见=否"
    fi
  done

  # --- W3c: 重启真值 ---
  if [ "${DIAG_WP_SKIP_RESTART:-0}" = "1" ]; then
    say "   （DIAG_WP_SKIP_RESTART=1，跳过重启真值复核）"
  elif docker restart "$CONTAINER" >/dev/null 2>&1; then
    say "   ↻ 重启容器取后端真值..."
    sleep "$RESTART_WAIT"
    _snap2=$(rclone lsf "$RD" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null || true)
    for _n in "$_probe_name" "$_probe3"; do
      if printf '%s\n' "$_snap2" | grep -qxF "$_n"; then
        say "     真值 $(_short_ol "$_n"): 可见=是"
      else
        say "     真值 $(_short_ol "$_n"): 可见=否"
      fi
    done
  else
    say "   ⚠️ docker restart 失败，真值口径缺失"
  fi

  # --- W 判读 ---
  say ""
  say "── W 判读 ──"
  if [ "$W1_EXISTS" = "1" ] && [ "$W1_MKDIR_409" = "1" ] && [ "$W1_PROBE_409" = "1" ]; then
    if [ "$W2_409" = "0" ] || [ "$_409p3" = "0" ]; then
      W_VERDICT="目录存在且可写（预检假阴性坐实）"
      say "🔒 **预检判据是假阴性**：目录**存在**、mkdir 与探针都回 409，"
      say "   但绕开隐式 mkParentDir 后写入**成功** ⇒ 「探针写不进」≠「目录不可写」。"
      say "   ⇒ 修复方向: 把「存在性」(只读 lsd) 与「可写性」(不触发 mkParentDir 的真写)"
      say "     拆成两个判据；且「不可写」不应无条件跳过全部 4 种方法。"
    else
      W_VERDICT="目录存在但确实写不进（预检正确）"
      say "🔒 **预检结论正确**：目录存在，但所有写入路径（含绕开 mkParentDir 的）都回 409。"
      say "   ⇒ 该目录确实写不进，问题在写入路径而非判据；须另找方向（如改名/换目录策略）。"
    fi
  elif [ "$W1_EXISTS" = "0" ]; then
    W_VERDICT="目录不存在（结论弱）"
    say "ℹ️ 目录不存在/读不到 ⇒ 写入必然要建父目录，无法解耦可写性，本组不成立。"
  else
    W_VERDICT="形态异常"
    say "⚠️ 形态与预期不符（exists=$W1_EXISTS mkdir409=$W1_MKDIR_409 probe409=$W1_PROBE_409）"
    say "   —— 见上方原始输出人工判读。"
  fi
  say "   原始数值: W1(exists=$W1_EXISTS,mkdir409=$W1_MKDIR_409,probe409=$W1_PROBE_409) W2(rc=${W2_RC:-na},409=${W2_409:-na}) W3(rc=$_rc,409=$_409p3)"
fi

# ============================================================
# W4：隔离目录自测（机制验证，不依赖真实故障目录）
# ============================================================
sec "W4 · 隔离目录机制自测（证明「探针写会触发 mkParentDir」）"
if ! rclone mkdir "$BASE" --timeout "$MKDIR_TIMEOUT" >/dev/null 2>&1; then
  say "❌ 隔离父目录创建失败: $(_short_ol "$BASE")（该后端可能整体不可写）"
else
  say "隔离父目录: $(_short_ol "$BASE")（已就绪）"
  # 在**已存在**的隔离目录里写 → 若机制成立，不应触发 mkParentDir、应当成功
  _iso_name="olwpiso_$(printf '%s' "$TS" | md5sum | cut -c1-8).txt"
  _out=$(rclone copyto "$PAYLOAD" "$BASE/$_iso_name" \
    --retries 3 --low-level-retries 5 --contimeout 30s --timeout "$WRITE_TIMEOUT" 2>&1)
  _rc=$?
  _mkpiso=0; is_mkparentdir "$_out" && _mkpiso=1
  say "写入已存在隔离目录 rc=$_rc · mkParentDir=$_mkpiso"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  # 对照: 写一个**父目录不存在**的深层路径（必然触发 mkParentDir）
  _deep="$BASE/nonexistent_parent_$TS/deep.txt"
  _out2=$(rclone copyto "$PAYLOAD" "$_deep" \
    --retries 2 --low-level-retries 3 --contimeout 30s --timeout "$WRITE_TIMEOUT" 2>&1)
  _rc2=$?
  _mkpdeep=0; is_mkparentdir "$_out2" && _mkpdeep=1
  say "写入**新建**深层路径 rc=$_rc2 · mkParentDir=$_mkpdeep（预期触发 mkParentDir）"
  [ "$_rc2" -ne 0 ] && say "$_out2" | tail -3 | sed 's/^/     ▸ /' | tee -a "$REPORT"
  if [ "$_rc" -eq 0 ] && [ "$_mkpdeep" = "1" ]; then
    say "✅ 机制证实: 写**已存在**目录不触发 mkParentDir 且成功；写**新建**路径才触发。"
    say "   ⇒ 支持「探针失败源于隐式 mkParentDir，而非目录不可写」的假设。"
  fi
fi

# ────────────────────────────────────────────────────────────
sec "W9 · 清理（尽力）"
rclone purge "$BASE" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
  || say "   ⚠️ 隔离目录未能清除: $(_short_ol "$BASE")（oldiagwp_ 前缀可辨识）"
if [ -n "$REAL_DIR_REL" ]; then
  for _n in "${_probe_name:-}" "${_probe3:-}" "olwprobe2_$(printf '%s' "$TS" | md5sum | cut -c1-8).txt"; do
    [ -n "$_n" ] || continue
    rclone deletefile "$TARGET/$REAL_DIR_REL/$_n" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
  done
  say "   已尽力清理真实故障目录内的探针（若删除失败，olwprobe* 前缀可辨识）"
fi

say ""
say "==================== 汇总 ===================="
say "W 判决（真实故障目录）: $W_VERDICT"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
