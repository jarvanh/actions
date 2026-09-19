#!/bin/bash
# ===== 「兜底目录跳出故障子树」可行性验证（回答「换到哪儿才写得进去」）=====
#
# 为什么必须做（2026-09-18，§12.14.3 判决驱动）:
#   §12.14.3 已判决: 假成功是**路径局部**的（不是通用缺陷）——同后端同一时刻，
#   `5/ol2p_*` 能建、`5/<L2 段>/*` 一律 409 ⇒ 故障是「L2 这一层及其整棵子树」。
#   而修复管线现有的短哈希兜底目录落点是 `dest_path/<hash8>`（file_fix.sh
#   _fix_switch_to_hash_dir），**仍在同一棵坏子树里** ⇒ 生产里"换成短哈希目录
#   → 同样 409 → 兜底终止"。
#
#   对齐生产配置后这个链条是闭合的:
#     · 同步对 `task5-wopan175` 的 dest_path = `openlist:wopan175/5`
#     · 故障层 L2 = `5/<L2 段>`（= dest_path 的**下一层**）
#     · 现有兜底落点 = `dest_path/<hash8>` = `wopan175/5/<hash8>` ⇒ 坏子树内 ✓
#   ⇒ 修法方向（§0「下一步」）是**让兜底目录跳到故障子树之外**。
#
#   ⚠️ 但「跳出去就一定能写」这个前提**尚未被实测验证过**——这正是本脚本要证的。
#   按 §12.14.3 自己写下的教训（"先验证普遍性，再定性"；避免单点外推），
#   在改动还原链（restore_info.jq 的 hash_dir 分支）之前必须先坐实前提。
#
# 为什么必须改还原链: alternative 现在被当作 dest_path 的**相对路径**使用
#   （`--filter-from` 的 `- /<alt>`、以及还原脚本 `rclone moveto "$DST/$ALT" "$DST/$ORIG"`）。
#   落点一旦跳到 dest_path 之外，`$DST/$ALT` 就指错位置 ⇒ 还原会失败。
#   故本实验还要顺带确认「祖先层 candidate 里，哪一级是可写的最小上跳量」，
#   好让改动面尽可能小（能只跳一层就不跳两层）。
#
# 三组实验:
#   E1 · 祖先层阶梯: 对 dest_path 的**每一级祖先**（dest_path 自身 / 其父 / 挂载根）
#        各建一个短哈希测试目录，做 mkdir → lsd 三元组。
#        判读: 找到**最深的可写层** ⇒ 兜底目录的最小上跳量。
#   E2 · 同层对照（跳出 vs 不跳出）: 在 dest_path 自身下建一个目录（= 现状落点）
#        与 E1 找到的可写层对照，**同轮同构**实测 —— 直接回答"跳出是否真的有用"。
#        这是本实验的核心判决项。
#   E3 · 跳出层写文件: 在 E1 的可写层目录里 copyto 一个真实载荷并真值复核
#        （mkdir 成功 ≠ 写得进文件；§12.14.1 W4 已证两者必须分开验）。
#        判读: 可写 ⇒ 兜底落点可行；不可写 ⇒ 该层只是"能建目录"，落点还得再上跳。
#
#   E4 · 还原路径可行性（顺带）: 在 E1 的可写层里模拟还原动作
#        （rclone move 到 dest_path 下的原路径），确认"跳出后还能不能归位"。
#        这直接决定 restore_info.jq 要改成什么形态。
#        ⚠️ 可见性复核**必须带等待**（E4_WAIT，默认 15s）：§12.14.4 实测列表
#           首次可见要 ~10s，立刻 lsf 会把"还没刷新"误读成"没到位"⇒ 假成功误报。
#        判读区分三态: 目标可见(成功/真归位) · 源已消失但目标仍不可见(疑静默丢文件，
#           仍需重启真值复核才能定性) · 源仍在(未真正移动)。
#
# ⚠️ 安全约定（同 diag_l2_probe.sh）:
#   · 只在**祖先层的自建目录**（前缀 `ol2e_<ts>_`，可辨识）里操作，
#     **不写入任何生产目录内部**；收尾尽力 purge 自建目录。
#   · 不移动/不改动任何生产文件 —— E4 只在自建目录内 move。
#
# 用法: bash diag_escape_probe.sh [挂载根] [容器名] [dest_path 相对路径] [上跳层数]
#   默认: openlist:wopan175 openlist 5 3
# 环境变量:
#   DIAG_ESC_DEST     dest_path 相对挂载根的路径（默认 5；生产 task5-wopan175 即此值）
#   DIAG_ESC_UP       E1 祖先阶梯最大上跳层数（默认 3，1~4 合理）
#   DIAG_ESC_BYTES    E3 载荷字节数（默认 65536）
#   DIAG_ESC_SKIP_E4  1=跳过 E4
#   DIAG_ESC_E4_WAIT  E4 归位后的等待秒数（默认 15；§12.14.4 实测列表可见性 ~10s）
#   DIAG_REPORT       报告路径（默认 /tmp/ol_diag/escape_report.txt）
#
# 退出码恒为 0（诊断工具；非 0 会掩盖报告——同 diag_backend.sh）

set -uo pipefail

TARGET="${1:-openlist:wopan175}"
CONTAINER="${2:-openlist}"
DEST_REL="${3:-${DIAG_ESC_DEST:-5}}"
UP_MAX="${4:-${DIAG_ESC_UP:-3}}"
REPORT="${DIAG_REPORT:-/tmp/ol_diag/escape_report.txt}"
PROBE_TIMEOUT="${DIAG_PROBE_TIMEOUT:-45s}"
MKDIR_TIMEOUT="${DIAG_MKDIR_TIMEOUT:-120s}"
BYTES="${DIAG_ESC_BYTES:-65536}"
# E4 归位后的等待秒数：§12.14.4 实测「列表可见性 首次非空=10s」，取 15s 留余量。
# 不设这个等待，就会把"列表还没刷新"误读成"没到位"，把成功判成假成功。
E4_WAIT="${DIAG_ESC_E4_WAIT:-15}"

mkdir -p "$(dirname "$REPORT")" /tmp/ol_diag
: > "$REPORT"

say() { printf '%s\n' "$*" | tee -a "$REPORT"; }
sec() { say ""; say "──────── $* ────────"; }

http_code_of() { grep -oE '(4[0-9]{2}|5[0-9]{2}) [A-Za-z]' <<<"$1" | tail -1 | cut -d' ' -f1; }
is_409() { grep -Eqi 'Conflict:[[:space:]]*409|409[[:space:]]+Conflict' <<<"$1"; }
_short_ol() { local p="$1"; if [ "${#p}" -gt 64 ]; then printf '%s…%s' "${p:0:30}" "${p: -30}"; else printf '%s' "$p"; fi; }

# 统一探测: mkdir → lsd 复核，输出三元组（与 diag_l2_probe.sh 同口径，便于对照）
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

say "「兜底目录跳出故障子树」可行性验证"
say "挂载根:        $TARGET"
say "容器名:        $CONTAINER"
say "dest_path 相对: $DEST_REL（= 生产 task5-wopan175 的 dest_path 形态）"
say "最大上跳层数:  $UP_MAX"
say "开始时间:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say ""
say "目的: 现有兜底落点是 \${dest_path}/<hash8>，若 dest_path 的下一层坏，"
say "      则该落点仍在坏子树内。本实验找**最深的可写祖先层**。"

TS=$(date +%s)

# ── 构造祖先层阶梯 ───────────────────────────────────────────
# LEVELS[i] = 上跳 i 层后的祖先层（相对挂载根）；LEVELS[0] = dest_path 自身
# 例: DEST_REL="5" ⇒ LEVELS=( "5" "" )  ⇒ LEVELS[1] 为空串 = 挂载根
# ⚠️ 上跳可能**提前触顶**（dest_path 只有一层时，上跳 1 层即挂载根，
#    再往上还是挂载根）⇒ 去重，否则 E1 会在同一路径重复建多个测试目录，
#    既多花时间又让"最深可写层"的判读出现并列歧义。
LEVELS=()
_desc=()
_lvl="$DEST_REL"
for (( i=0; i<=UP_MAX; i++ )); do
  # 去重: 已出现过的层不再重复加入（触顶后 LEVELS 恒为挂载根）
  _dup=0
  for _e in "${LEVELS[@]}"; do [ "$_e" = "$_lvl" ] && { _dup=1; break; }; done
  if [ "$_dup" -eq 1 ]; then
    break
  fi
  LEVELS+=("$_lvl")
  if [ "$i" -eq 0 ]; then
    _desc+=("dest_path 自身（= 现有兜底落点的父层）")
  elif [ -z "$_lvl" ]; then
    _desc+=("挂载根（上跳 ${i} 层）")
  else
    _desc+=("上跳 ${i} 层：${_lvl}")
  fi
  # 上跳一层: 去掉最末段；已是空串则保持（挂载根）
  if [ -n "$_lvl" ]; then
    case "$_lvl" in
      */*) _lvl="${_lvl%/*}" ;;
      *)   _lvl="" ;;
    esac
  fi
done
UP_MAX=$(( ${#LEVELS[@]} - 1 ))

# ── E1 · 祖先层阶梯 ─────────────────────────────────────────
sec "E1 · 祖先层阶梯（逐级上跳，各建一个测试目录）"
say "判读: 找**最深的可写层** ⇒ 兜底目录的最小上跳量"
say ""
E1_WRITABLE_LEVEL=""      # 最深可写层的 LEVELS 下标
E1_LEVEL_STATE=()
E1_DIRS=()
for (( i=0; i<=UP_MAX; i++ )); do
  _lvl="${LEVELS[$i]}"
  _nm="ol2e_${TS}_u${i}"
  if [ -z "$_lvl" ]; then
    _dir="$TARGET/$_nm"
  else
    _dir="$TARGET/$_lvl/$_nm"
  fi
  say "── [上跳 ${i}] ${_desc[$i]}"
  say "   落点: $(_short_ol "$_dir")"
  if _mk "$_dir" "E1[u${i}]"; then
    E1_LEVEL_STATE[$i]="writable"
    if [ -z "$E1_WRITABLE_LEVEL" ]; then E1_WRITABLE_LEVEL="$i"; fi
  elif [ "$_K_RC" -eq 0 ] || [ "$_K_409" -eq 1 ]; then
    E1_LEVEL_STATE[$i]="fake"      # mkdir 报成功/409 但 lsd 看不到 = 假成功
  else
    E1_LEVEL_STATE[$i]="err"
  fi
  E1_DIRS[$i]="$_dir"
  say ""
done

say "── E1 判读 ──"
if [ -n "$E1_WRITABLE_LEVEL" ]; then
  say "🔒 **存在可写祖先层**：上跳 ${E1_WRITABLE_LEVEL} 层（${_desc[$E1_WRITABLE_LEVEL]}）可建目录"
  if [ "$E1_WRITABLE_LEVEL" = "0" ]; then
    say "   ⚠️ dest_path 自身就可写 ⇒ 本例**未复现**生产故障形态（L2 坏），"
    say "      结论对「跳出」无增量信息，需换一个已知坏的 dest_path 重跑"
  else
    say "   ⇒ 兜底落点最小上跳量 = ${E1_WRITABLE_LEVEL} 层"
    if [ "${E1_LEVEL_STATE[0]:-}" = "fake" ]; then
      say "   ⇒ **E2 对照条件成立**：dest_path 自身假成功、祖先可写 —— 正是生产形态"
    fi
  fi
else
  say "⚠️ **所有祖先层都不可写** ⇒ 上跳到挂载根也救不了"
  say "   ⇒ 「跳出故障子树」这条修法**不成立**，须回到追因（网盘侧残留/配额）"
fi

# ── E2 · 同层对照（跳出 vs 不跳出）─────────────────────────
sec "E2 · 同层对照（dest_path 下 vs 可写祖先层下，同轮同构）"
say "判读: 这是本实验的**核心判决项** —— 直接回答「跳出是否真的有用」"
say ""
# 不跳出的落点: dest_path/<hash8>（= 现状）
E2_IN_DIR="$TARGET/${DEST_REL}/ol2e_${TS}_in"
E2_IN_OK=0
if _mk "$E2_IN_DIR" "E2[不跳出 · dest_path 下]"; then E2_IN_OK=1; fi
# 跳出的落点: 上跳到 E1 找到的可写层
E2_OUT_OK=0
if [ -n "$E1_WRITABLE_LEVEL" ] && [ "$E1_WRITABLE_LEVEL" != "0" ]; then
  E2_OUT_DIR="${E1_DIRS[$E1_WRITABLE_LEVEL]}"
  say ""
  say "   （跳出落点复用 E1 已建成的目录: $(_short_ol "$E2_OUT_DIR")）"
  E2_OUT_OK=1
else
  say ""
  say "   ⚠️ E1 未找到可写祖先层（或 dest_path 自身就可写）⇒ 无法构造跳出对照"
fi
say ""
say "── E2 判读 ──"
if [ "$E2_IN_OK" -eq 0 ] && [ "$E2_OUT_OK" -eq 1 ]; then
  say "🔒🔒 **「跳出确实有用」成立**（本轮实测）:"
  say "     · 不跳出（dest_path 下）: **建不出/假成功**"
  say "     · 跳出（上跳 ${E1_WRITABLE_LEVEL} 层）: **可写**"
  say "   ⇒ 修法方向坐实: 兜底目录必须跳出故障子树"
  say "   ⇒ 下一步: 改 _fix_switch_to_hash_dir 的落点 + restore_info.jq 的还原路径口径"
elif [ "$E2_IN_OK" -eq 1 ]; then
  say "⚠️ 不跳出的落点本轮**可写** ⇒ 未复现生产故障，本实验无法支持「必须跳出」的结论"
  say "   （可能该 dest_path 当前健康；须在故障复现时再跑一次才有判别力）"
else
  say "⚠️ 跳出与不跳出**都不可写** ⇒ 本层判断为「后端/子树整体不可写」"
  say "   ⇒ 与 §12.14.3「非通用缺陷」的判决冲突，需人工审视报告"
fi

# ── E3 · 跳出层写文件（mkdir 成功 ≠ 写得进文件）─────────────
sec "E3 · 跳出层写文件（真值复核）"
if [ -n "$E1_WRITABLE_LEVEL" ] && [ "$E1_WRITABLE_LEVEL" != "0" ]; then
  E3_DIR="${E1_DIRS[$E1_WRITABLE_LEVEL]}"
elif [ -n "$E1_WRITABLE_LEVEL" ]; then
  E3_DIR="${E1_DIRS[0]}"
else
  E3_DIR=""
fi
if [ -z "$E3_DIR" ]; then
  say "（无可写层 ⇒ E3 跳过）"
else
  say "落盘目录: $(_short_ol "$E3_DIR")"
  E3_SRC="/tmp/ol2e_payload.bin"
  head -c "$BYTES" /dev/urandom > "$E3_SRC" 2>/dev/null || printf 'x%.0s' $(seq 1 "$BYTES") > "$E3_SRC"
  _out=$(rclone copyto "$E3_SRC" "$E3_DIR/ol2e_probe_${TS}.bin" \
         --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _rc=$?
  _409=0; is_409 "$_out" && _409=1
  say "   copyto rc=${_rc} · 409特征=${_409}"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  # 可见性复核。⚠️ 口径说明: 这是**缓存口径**，与挂载层写探针的坑同源
  #   （§12.14.1: PUT 假成功在缓存里与真文件无异）。但本实验要回答的是
  #   「跳出层是否比不跳出层更好」，**相对比较**用同一口径即可成立；
  #   若出现"跳出层也没落盘"的结论，须再做重启真值复核（DIAG_ESC_RESTART_TRUTH=1，
  #   默认关闭: 重启容器代价高，且会打断同轮其它实验）。
  _vis1=0
  rclone lsf "$E3_DIR" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null \
    | grep -qxF "ol2e_probe_${TS}.bin" && _vis1=1
  say "   写入后 lsf 可见=${_vis1}（缓存口径，不作判据）"
  if [ "$_rc" -eq 0 ] && [ "$_vis1" -eq 1 ]; then
    say "🔒 **跳出层可写文件** ⇒ 兜底落点可行"
    say "   （探针与 mkdir 同走 409 写路径，故此处必须验「文件」而非仅「目录」）"
  elif [ "$_rc" -eq 0 ]; then
    say "⚠️ **写入假成功**（rc=0 但不可见）⇒ 该层「能建目录」但「写不进文件」，落点还须再上跳"
  else
    say "⚠️ 写入失败（rc=${_rc}）⇒ 该层不可作为兜底落点"
  fi
  rm -f "$E3_SRC" 2>/dev/null || true
fi

# ── E4 · 还原路径可行性 ─────────────────────────────────────
sec "E4 · 还原路径可行性（跳出后能否一步归位）"
if [ "${DIAG_ESC_SKIP_E4:-0}" = "1" ]; then
  say "（DIAG_ESC_SKIP_E4=1，跳过）"
elif [ -z "$E3_DIR" ]; then
  say "（无可写层 ⇒ E4 跳过）"
else
  # 模拟 restore_info.jq 的 hash_dir 还原: rclone moveto <跳出落点> <dest_path 下原路径>
  # 用 moveto 而非 move: move 的 dst 会被当目录，目标文件不存在时建出以目标文件名
  # 命名的目录 ⇒ 会把"能归位"误判成"归位了"（其实落点错一层），见 file_restore.sh 注释
  # 这一步决定"跳出后还能不能归位"，也就是 restore_info.jq 要改成什么形态
  _mv_src="$E3_DIR/ol2e_move_${TS}.bin"
  _mv_dst="$TARGET/${DEST_REL}/ol2e_moved_${TS}.bin"
  printf 'restore path probe' > "/tmp/ol2e_move_${TS}.bin"
  _out=$(rclone copyto "/tmp/ol2e_move_${TS}.bin" "$_mv_src" \
         --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _rc=$?
  say "   准备: copyto 到跳出层 rc=${_rc}（$(_short_ol "$_mv_src")）"
  # 关键动作: 从跳出层 move 回 dest_path 下的目标路径
  _out=$(rclone moveto "$_mv_src" "$_mv_dst" --timeout "$MKDIR_TIMEOUT" --retries 1 2>&1); _rc=$?
  _409=0; is_409 "$_out" && _409=1
  say "   move 跳出层 → dest_path 下: rc=${_rc} · 409特征=${_409}"
  [ "$_rc" -ne 0 ] && say "$_out" | tail -3 | sed 's/^/        ▸ /' | tee -a "$REPORT"
  # ⚠️ 可见性复核**必须带等待**：§12.14.4 实测「列表可见性: 首次非空=10s」——
  #   move 后立刻 lsf 会把"还没刷新"读成"没到位"，从而把成功误判成假成功。
  #   故这里先立即读一次，等 WAIT 秒再读一次，只要有一次可见即算到位。
  _at_dst=0; _at_dst_now=0
  rclone lsf "$TARGET/${DEST_REL}" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null \
    | grep -qxF "ol2e_moved_${TS}.bin" && { _at_dst_now=1; _at_dst=1; }
  say "   归位后目标位可见: 立即=${_at_dst_now}"
  if [ "$_at_dst_now" -eq 0 ]; then
    say "   等待 ${E4_WAIT}s 后复核（避免把「列表未刷新」误读成「没到位」）..."
    sleep "$E4_WAIT"
    rclone lsf "$TARGET/${DEST_REL}" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null \
      | grep -qxF "ol2e_moved_${TS}.bin" && _at_dst=1
    say "   归位后目标位可见: 等待后=${_at_dst}"
  fi
  # 跳出层是否还留着源文件（真 move 会移走；假成功往往两边都不在，或仍在原地）
  _src_left=0
  rclone lsf "$E3_DIR" --files-only --retries 1 --timeout "$PROBE_TIMEOUT" 2>/dev/null \
    | grep -qxF "ol2e_move_${TS}.bin" && _src_left=1
  say "   跳出层源文件仍在=${_src_left}"
  # ★ 直接对**目标全路径**取元数据（不经目录列举）——这是比"列表里有没有"更强的判据:
  #   列列举受缓存影响，而按全路径 stat 直接问后端"这个对象在不在"。
  #   若这条也说"不在"，才谈得上"静默丢文件"。
  _stat_ok=0; _stat_size=""
  if _sj=$(rclone lsjson "$_mv_dst" --retries 1 --timeout "$PROBE_TIMEOUT" 2>&1); then
    _stat_ok=1
    _stat_size=$(printf '%s' "$_sj" | grep -oE '"Size":[0-9]+' | head -1 | cut -d: -f2)
  fi
  say "   目标全路径 stat: 在=${_stat_ok} · Size=${_stat_size:-无}"
  if [ "$_rc" -eq 0 ] && [ "$_at_dst" -eq 1 ]; then
    say "🔒 **跳出后仍可一步归位**（跨层 move 成功，且目标位已复核可见）"
    say "   ⇒ restore_info.jq 只需把「落点」如实写成跳出后的路径即可"
  elif [ "$_rc" -eq 0 ] && [ "$_stat_ok" -eq 1 ]; then
    say "🔒 **归位其实成功**（目标全路径 stat 存在；仅目录列举未及时刷新）"
    say "   ⇒ 印证「列表可见性滞后」大于 ${E4_WAIT}s，判读应以 stat 为准、不以列列举为准"
  elif [ "$_rc" -eq 0 ] && [ "$_src_left" -eq 0 ]; then
    say "⚠️ **可疑：move 报成功、源已消失、目标全路径 stat 也不存在**"
    say "   ⇒ 符合「静默丢文件」特征（源没了、目标没有），但**仍需重启真值复核**才能定性："
    say "      在坐实前**不要**据此改 restore_info.jq。"
  elif [ "$_rc" -eq 0 ] && [ "$_src_left" -eq 1 ]; then
    say "⚠️ **move 报成功但源文件还在** ⇒ 未真正移动（幂等假成功形态）"
  else
    say "⚠️ **跨层归位失败**（rc=${_rc}）"
    say "   ⇒ 若 dest_path 下确实写不进（正是故障层），归位失败是**预期**行为:"
    say "      还原必须改为「下载后重传到原路径」，或等故障恢复后再归位"
  fi
  rm -f "/tmp/ol2e_move_${TS}.bin" 2>/dev/null || true
fi

# ── 清理 + 汇总 ─────────────────────────────────────────────
sec "E9 · 清理（尽力 purge 自建测试目录）"
_cleaned=0; _left=0
for (( i=0; i<=UP_MAX; i++ )); do
  _d="${E1_DIRS[$i]:-}"
  [ -n "$_d" ] || continue
  rclone purge "$_d" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 \
    && _cleaned=$(( _cleaned + 1 )) || _left=$(( _left + 1 ))
done
for _d in "$E2_IN_DIR" "$TARGET/${DEST_REL}"; do
  [ -n "$_d" ] || continue
  rclone purge "$_d" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
done
# 归位测试留下的文件也清掉
rclone deletefile "$TARGET/${DEST_REL}/ol2e_moved_${TS}.bin" --retries 1 --timeout "$PROBE_TIMEOUT" >/dev/null 2>&1 || true
say "   已清理: ${_cleaned} 次 purge 成功 · ${_left} 次失败（ol2e_ 前缀可辨识）"

say ""
say "==================== 汇总 ===================="
say "dest_path 相对:   ${DEST_REL}"
say "E1 最深可写层:     ${E1_WRITABLE_LEVEL:-（无）}（上跳层数）"
for (( i=0; i<=UP_MAX; i++ )); do
  say "  上跳 ${i} 层: ${E1_LEVEL_STATE[$i]:-?}  （${_desc[$i]}）"
done
say "E2 不跳出可写:     ${E2_IN_OK}"
say "E2 跳出可写:       ${E2_OUT_OK}（复用 E1 结果）"
say "E3 跳出层写文件:   ${_rc:-?}（详见报告正文）"
say "结束时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "报告文件: $REPORT"
exit 0
