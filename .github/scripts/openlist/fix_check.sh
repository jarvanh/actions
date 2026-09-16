#!/bin/bash
# openlist 修复能力定点验证（fix-check）驱动脚本
#
# 用途: 对"已知修不好的文件"定点跑**生产同款修复管线**，逐文件给出可 grep 的判定
#   （fixed / fake_success / failed / not_found / already_ok），并回答那个一直答不上来的
#   问题: **这套管线到底能不能修好它**。
#
# 为什么需要它: 生产里验证修复能力只能"按任务全量 diff + 等 5.5h 长轮"，再从几万行日志里
#   反推；而失败清单（fail_list）只在 /tmp、**不跨轮持久化**，历史失败文件无法直接取回。
#   本脚本由独立的 openlist-fix-check.yml 调用（自带容器副本、分钟级），把"能力验证"
#   从生产轮次里彻底解耦。
#
# 两种取文件模式（FIXCHECK_MODE）:
#   list（默认）: 指定清单 —— 每行一个"文件名或密文名后缀"（如 ph5ebc05eca6793），
#                 对源端做一次 scoped 递归列举后按 basename/子串匹配定位；**未命中的
#                 条目会显式报 not_found**（不静默丢弃）。
#   diff        : 任务 diff 自动推导 —— 两侧递归列举求差集（源端有、目标端无）。
#                 覆盖全但慢（大任务两侧列举 30–60min），属已知代价。
#
# ★ 叶子同步单元（leaf unit）—— 本脚本最容易搞错、也最关键的一点:
#   生产用 auto-split 逐层把任务拆成"叶子同步单元"，每层都是
#     `_safe="${task_name}_${subdir//\//_}"` + `source/dest 各拼一级`（task_engine.sh:885 / 1208），
#   marker 也按**叶子**的 (task_name, dest_path) 命名。实测那些顽固文件属于
#   `task5` → `1024j-视频-pornhub-channel` → `kate-bloom` 这一层（marker 名形如
#   `task5_1024j-视频-pornhub-channel_kate-bloom_<hash8>.json`）。
#   ⇒ 修复与记账必须落在**同一个叶子单元**上，否则"真修了"下一轮仍会被当缺失重传
#     （幽灵落盘）。本脚本用**marker 存在性反查**叶子：从文件所在最深目录逐级向上，
#     取"已有 marker 的最深一级"（= 生产实际用过的单元）；都没有则用最深目录
#     （生产 auto-split 会一路分到无子目录那一层）。不靠猜阈值 —— 那会随文件数变化。
#
# 口径与生产**逐行同源**（不是另写一套判定）:
#   · 落盘即时校验: `_RAW_VERIFY_*` + `_rebuild_raw_baseline`
#     （同 file_fix_pipeline.sh:772-792，使 try_fix_failed_file 的轮内假成功快筛与生产一致）
#   · 真值复核: `_sync_restart_for_verify` + `_persist_verify_entries`
#     （同 _sync_persist_verify_and_retry:1058-1073；**只有重启容器后的可见性才算数**，
#      这批文件的失败形态正是"rclone 报成功但后端没落盘"）
#   · marker 记账: `_persist_fix_entry_now`（同 file_fix_pipeline.sh:959-962）
#
# 与生产的**有意差异**（必须知道）:
#   1. 默认**重置历史失败记忆**（FIXCHECK_RESET_BLACKLIST=1）: 不回填 marker 的
#      fix_blacklist 到内存，并清掉目标文件在**叶子 marker** 里的黑名单键 ⇒ 本轮从方法 1
#      开始全试，测的是"能力上限"而不是"生产实际会走的那条路"。
#   2. **先验后写**: 生产是"成功即写 marker，复核发现假成功再删条目"；本脚本先收集成功、
#      统一重启复核，只给**复核通过**的条目写 marker（避免假成功条目进 marker 再删）。
#   3. 复核判定为假成功时**不落盘新黑名单**（保持"能力上限"口径干净）；但注意
#      `_persist_fix_entry_now` 内部会把**当前内存黑名单**一并写入 marker（生产同款行为），
#      所以本轮实测出的新失败记忆仍可能随其它文件的记账落盘 —— 这是有意的（新测得的
#      结论比历史更可信）。
#   4. 不调用 `_flush_blacklist_to_marker`（不为"重置"之后的运行额外写黑名单）。
#
# 退出码（可直接当"修复能力回归门"）:
#   0 = 全部 fixed/already_ok
#   1 = 存在 failed 或 fake_success（能力不足，需看原因）
#   2 = 环境/参数错误，或存在 not_found（清单对不上源端，需修清单）
#
# 安全边界: 只做 copyto / move 到**正确路径**，绝不删除任何文件；不装 cloudflared、
#   不碰隧道、不回传 DB（与 openlist-diag.yml 同口径）。
#
# 入参（全部经 env 注入；workflow 侧禁止 ${{ }} 直接内插 bash，见 README「注入面」）:
#   FIXCHECK_MODE=list|diff        FIXCHECK_TASK=task5
#   FIXCHECK_FILES=<多行文本>      FIXCHECK_MAX=10
#   FIXCHECK_SUBDIR=<任务根下的子路径，可选，用于缩小列举范围>
#   FIXCHECK_RESET_BLACKLIST=1|0   FIXCHECK_TRUTH_RESTART=1|0
set -uo pipefail

FIXCHECK_MODE="${FIXCHECK_MODE:-list}"
FIXCHECK_TASK="${FIXCHECK_TASK:-task5}"
FIXCHECK_MAX="${FIXCHECK_MAX:-10}"
FIXCHECK_SUBDIR="${FIXCHECK_SUBDIR:-}"
FIXCHECK_RESET_BLACKLIST="${FIXCHECK_RESET_BLACKLIST:-1}"
FIXCHECK_TRUTH_RESTART="${FIXCHECK_TRUTH_RESTART:-1}"
[[ "$FIXCHECK_MAX" =~ ^[0-9]+$ ]] && [ "$FIXCHECK_MAX" -gt 0 ] || FIXCHECK_MAX=10

FC_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
export GITHUB_WORKSPACE="$FC_ROOT"
# 工作目录用**确定路径**（不是 mktemp）: workflow 的"上传报告"步骤要按固定路径取文件
FC_WORK="${FIXCHECK_WORK_DIR:-/tmp/fixcheck}"
rm -rf "$FC_WORK" 2>/dev/null || true
mkdir -p "$FC_WORK" || exit 2
FC_LOG="$FC_WORK/fixcheck.log"
FC_FIXLOG="$FC_WORK/fix_detail.log"      # try_fix_failed_file 的逐文件细节日志
FC_FIXLIST="$FC_WORK/fix_list.txt"       # 修复成功（待复核）条目
FC_VERDICTS="$FC_WORK/verdicts.txt"      # 结论行（可 grep / 上传）
: > "$FC_LOG"; : > "$FC_FIXLOG"; : > "$FC_FIXLIST"; : > "$FC_VERDICTS"

FC_COUNT_FIXED=0; FC_COUNT_ALREADY=0; FC_COUNT_FAKE=0; FC_COUNT_FAILED=0; FC_COUNT_NOTFOUND=0

_fc_log() { printf '%s\n' "$*" | tee -a "$FC_LOG"; }
# 结论行字段清洗: `|` 是分隔符、换行会打乱逐行 grep，统一换成 `/` 与空格
_fc_clean() { printf '%s' "${1:-}" | tr '|\n' '/ '; }
_fc_verdict() {  # <status> <method_id> <rel> <alternative> <reason>
  local line="VERDICT|$1|$(_fc_clean "${2:-}")|$(_fc_clean "$3")|$(_fc_clean "${4:-}")|$(_fc_clean "${5:-}")"
  printf '%s\n' "$line" | tee -a "$FC_VERDICTS" | tee -a "$FC_LOG"
  case "$1" in
    fixed)        FC_COUNT_FIXED=$((FC_COUNT_FIXED + 1)) ;;
    already_ok)   FC_COUNT_ALREADY=$((FC_COUNT_ALREADY + 1)) ;;
    fake_success) FC_COUNT_FAKE=$((FC_COUNT_FAKE + 1)) ;;
    failed)       FC_COUNT_FAILED=$((FC_COUNT_FAILED + 1)) ;;
    not_found)    FC_COUNT_NOTFOUND=$((FC_COUNT_NOTFOUND + 1)) ;;
  esac
}

# ============================================================
# 0. 加载既有库（唯一正确入口；函数在调用时才解析，顺序由 load_all 保证）
# ============================================================
if [ -f "$FC_ROOT/.github/scripts/openlist/load_all.sh" ]; then
  # shellcheck disable=SC1091
  source "$FC_ROOT/.github/scripts/openlist/load_all.sh"
else
  echo "❌ 找不到 load_all.sh（GITHUB_WORKSPACE=${FC_ROOT}）" >&2
  exit 2
fi

# try_fix_failed_file 用**相对路径**建临时目录（file_fix.sh:1205）⇒ 必须切到可写目录，
# 否则 mkdir 落在只读的 runner 工作目录根上会失败
cd "$FC_WORK" || exit 2

_fc_log "=== openlist 修复能力定点验证（fix-check） ==="
_fc_log "  模式=${FIXCHECK_MODE} 任务=${FIXCHECK_TASK} 上限=${FIXCHECK_MAX} 子路径=${FIXCHECK_SUBDIR:-（任务根）}"
_fc_log "  重置历史黑名单=${FIXCHECK_RESET_BLACKLIST} 真值复核重启=${FIXCHECK_TRUTH_RESTART}"
_fc_log "  工作目录=${FC_WORK}"
# ⚠️ 容器名必须是 openlist: 真值复核走的 `_sync_restart_for_verify`（openlist_driver.sh:782）
# 硬编码 `sudo docker restart openlist`，容器叫别的名字会重启到空气上（复核永远"失败"）
if [ "${FIXCHECK_CONTAINER:-openlist}" != "openlist" ]; then
  _fc_log "❌ FIXCHECK_CONTAINER=${FIXCHECK_CONTAINER}：真值复核函数硬编码容器名 openlist，本脚本只支持 openlist"
  exit 2
fi

# ============================================================
# 1. 解析任务（SYNC_TASK_REGISTRY: "id|源端|目标端|任务名|附加参数"）
# ============================================================
FC_SRC=""; FC_DST=""; FC_TASK=""
for _e in "${SYNC_TASK_REGISTRY[@]}"; do
  IFS='|' read -r _id _src _dst _name _flags <<< "$_e"
  [ "$_id" = "$FIXCHECK_TASK" ] || continue
  FC_SRC="$_src"; FC_DST="$_dst"; FC_TASK="$_name"; break
done
if [ -z "$FC_DST" ]; then
  _fc_log "❌ 未知任务 id: ${FIXCHECK_TASK}"
  _fc_log "   可用 id: $(for _e in "${SYNC_TASK_REGISTRY[@]}"; do printf '%s ' "${_e%%|*}"; done)"
  exit 2
fi
_fc_log "  任务解析: 源=${FC_SRC} 目标=${FC_DST} marker前缀=${FC_TASK}"

# Crypt 目标必须先完成配置解析（_RAW_VERIFY_DIR 的计数视图与名长诊断都依赖它）
_ensure_crypt_config "$FC_DST" || _fc_log "  ⚠️ crypt 配置解析失败（计数口径将退化为裸挂载根）"

# ============================================================
# 2. 落盘即时校验初始化（同 file_fix_pipeline.sh:772-792）
#    _RAW_VERIFY_LAST 是运行基准计数，_confirm_persist_by_count 靠"计数是否增长"
#    在轮内就筛掉一部分假成功；不初始化会让本脚本的判定比生产宽松
# ============================================================
_RAW_VERIFY_DEST=""
_RAW_VERIFY_DIR=""
_RAW_VERIFY_LAST=-1
_RAW_VERIFY_BUDGET=0
if [[ "$FC_DST" == openlist:* ]]; then
  _RAW_VERIFY_DEST="$FC_DST"
  if [[ "$FC_DST" == openlist:*Crypt/* ]]; then
    _RAW_VERIFY_DIR="$(_raw_count_view_for "$FC_DST")"
    _RAW_VERIFY_REFRESH="$(_raw_remote_for "${FC_DST%%/*}" 2>/dev/null || echo "${FC_DST/Crypt/}")"
    _RAW_VERIFY_REFRESH="${_RAW_VERIFY_REFRESH#openlist:}"
  else
    _RAW_VERIFY_DIR="$FC_DST"
    _RAW_VERIFY_REFRESH="${FC_DST#openlist:}"
  fi
  _rebuild_raw_baseline "$FC_LOG" || _fc_log "  ⚠️ raw 基准不可用（计数恒 0）⇒ 本轮不做轮内假成功快筛，只靠重启真值复核"
fi

# ============================================================
# 3. 构造候选清单（相对**任务根**的路径）
# ============================================================
FC_SUB_PATH=""
[ -n "$FIXCHECK_SUBDIR" ] && FC_SUB_PATH="/${FIXCHECK_SUBDIR#/}"
FC_CAND="$FC_WORK/candidates.txt"
: > "$FC_CAND"

# rclone `--timeout` 的取值归一化: 环境变量若被设成裸数字（历史坑）补上 `s`，
# 否则 rclone 会以 `missing unit in duration` 失败 —— 而失败常被 2>/dev/null 吞掉
_fc_timeout_arg() {
  local t="${OPENLIST_RCLONE_LISTING_TIMEOUT:-900s}"
  case "$t" in *[a-zA-Z]*) printf '%s' "$t" ;; *) printf '%ss' "$t" ;; esac
}
# 列举远端目录（**不吞错误**: 失败与"目录为空"必须能区分开 —— 2026-09-16 实测踩到:
# 主轮同时在读同一 OneDrive 时列举被限流，错误被 /dev/null 吞掉后表现为"0 个文件"，
# 与"路径写错"长得一模一样，白排查一轮）
_fc_list_remote() {  # <remote 路径> <输出文件> <标签>
  local path="$1" out="$2" label="${3:-列表}" t0 t1 rc
  t0=$(date +%s)
  # flag 名与取值都要小心（2026-09-16 实跑踩到两个）:
  #   · `--retry` **不是** rclone 的 flag，正确是 `--retries`（写错直接 rc=2 unknown flag）
  #   · `--timeout` 要求**带单位**（`900s`），裸数字会 `missing unit in duration` 而失败
  rclone lsf -R --files-only --retries 3 --low-level-retries 5 --contimeout 30s \
    --timeout "$(_fc_timeout_arg)" "$path" > "$out" 2> "${out}.err"
  rc=$?
  t1=$(date +%s)
  _fc_log "  📋 ${label}: ${path} → $(grep -c . "$out" 2>/dev/null || true) 个文件（rc=${rc}，$((t1 - t0))s）"
  if [ "$rc" -ne 0 ]; then
    _fc_log "  ⚠️ ${label}失败（rc=${rc}）: $(tail -3 "${out}.err" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
  fi
}
# 源端列举为空时的定性: 非递归列举有内容 ⇒ 是列举失败（多为限流/超时）；也空 ⇒ 路径不对
_fc_diagnose_empty_src() {  # <remote 路径>
  local path="$1" probe="$FC_WORK/probe_nonrec.lsf"
  rclone lsf "$path" --files-only --retries 1 --timeout 120s > "$probe" 2> "${probe}.err"
  if [ -s "$probe" ]; then
    _fc_log "❌ 源端递归列举为空，但非递归列举有内容 ⇒ **列举失败**（常见成因: 主轮同时在读同一网盘被限流/超时）"
    _fc_log "   ↳ 处置: 避开主轮（或先取消主轮）后重跑；错误尾部: $(tail -2 "${probe}.err" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  else
    _fc_log "❌ 源端路径不存在或不可读: ${path}"
    _fc_log "   ↳ 处置: 检查 FIXCHECK_TASK / FIXCHECK_SUBDIR 拼写；错误尾部: $(tail -2 "${probe}.err" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
  fi
  exit 2
}

if [ "$FIXCHECK_MODE" = "diff" ]; then
  _fc_log "🔍 diff 模式: 两侧递归列举（源 ${FC_SRC}${FC_SUB_PATH} vs 目标 ${FC_DST}${FC_SUB_PATH}）..."
  _fc_list_remote "${FC_SRC}${FC_SUB_PATH}" "$FC_WORK/src.lsf" "源端"
  _fc_list_remote "${FC_DST}${FC_SUB_PATH}" "$FC_WORK/dst.lsf" "目标端"
  [ -s "$FC_WORK/src.lsf" ] || _fc_diagnose_empty_src "${FC_SRC}${FC_SUB_PATH}"
  # grep -v 无输出时退出码为 1 ⇒ 必须 `|| true`，否则会把已写好的候选清单当成失败处理
  { comm -23 <(sort -u "$FC_WORK/src.lsf") <(sort -u "$FC_WORK/dst.lsf") || true; } > "$FC_CAND" 2>/dev/null
  _fc_log "  缺失（源端有·目标端无）: $(grep -c . "$FC_CAND" || true) 个"
  # 注: "marker 已记账（alternative 形态落盘）"的排除放在**逐文件**阶段做 —— 那需要
  # 先解析出叶子单元才能读到对应的 marker（任务根 marker 在生产里并不用于叶子文件）
else
  _fc_log "🔍 list 模式: 列举源端 ${FC_SRC}${FC_SUB_PATH} 以定位清单中的文件..."
  _fc_list_remote "${FC_SRC}${FC_SUB_PATH}" "$FC_WORK/src.lsf" "源端候选池"
  [ -s "$FC_WORK/src.lsf" ] || _fc_diagnose_empty_src "${FC_SRC}${FC_SUB_PATH}"
  # 末尾补换行: `while read` 对"最后一行没有换行符"会**丢掉该行**（经典坑），
  # 用户粘贴的清单通常没有尾换行 ⇒ 不补就会静默漏掉最后一条
  printf '%s\n' "${FIXCHECK_FILES:-}" > "$FC_WORK/wanted.txt"
  if ! grep -q . "$FC_WORK/wanted.txt" 2>/dev/null; then
    _fc_log "❌ list 模式必须提供 FIXCHECK_FILES（每行一个文件名或密文名后缀）"
    exit 2
  fi
  while IFS= read -r want || [ -n "$want" ]; do
    [ -n "$want" ] || continue
    # 匹配规则: basename 等于条目，或相对路径包含条目（支持只给密文名后缀片段）
    _hit_any=0
    while IFS= read -r rel || [ -n "$rel" ]; do
      [ -n "$rel" ] || continue
      case "$rel" in
        "$want"|*/"$want") printf '%s\n' "$rel" >> "$FC_CAND"; _hit_any=1 ;;
        *"$want"*)         printf '%s\n' "$rel" >> "$FC_CAND"; _hit_any=1 ;;
      esac
    done < "$FC_WORK/src.lsf"
    # 未命中的条目必须显式报出来（否则清单里拼错的条目会被**静默丢弃**，
    # 跑完看到"全部 fixed"会误以为都验过了）
    [ "$_hit_any" = "1" ] || _fc_verdict not_found "" "$want" "" "清单条目在源端未匹配到任何文件"
  done < "$FC_WORK/wanted.txt"
  # 去重保序（同一文件被多个条目命中）
  if [ -s "$FC_CAND" ]; then
    awk '!seen[$0]++' "$FC_CAND" > "$FC_CAND.u" && mv "$FC_CAND.u" "$FC_CAND"
  fi
fi

# 两种模式的列举都是"相对 FIXCHECK_SUBDIR"的 ⇒ 补回子路径前缀，统一成"相对任务根"
FC_REL_PREFIX=""
[ -n "$FC_SUB_PATH" ] && FC_REL_PREFIX="${FC_SUB_PATH#/}/"
FC_TOTAL=$(grep -c . "$FC_CAND" 2>/dev/null || true)
[[ "$FC_TOTAL" =~ ^[0-9]+$ ]] || FC_TOTAL=0
_fc_log "  候选命中: ${FC_TOTAL} 个（上限 ${FIXCHECK_MAX}）"
if [ "$FC_TOTAL" -eq 0 ]; then
  _fc_log "⚠️ 没有命中任何候选文件 —— 检查 FIXCHECK_TASK / FIXCHECK_SUBDIR / 条目拼写"
fi
[ "$FC_TOTAL" -gt "$FIXCHECK_MAX" ] && _fc_log "  ↳ 超出上限，本次只处理前 ${FIXCHECK_MAX} 个（其余下次再跑）"

# ============================================================
# 4. 叶子同步单元解析（见文件头「★ 叶子同步单元」）
# ============================================================
FC_STATE_LIST=""
_fc_state_list() {
  [ -n "$FC_STATE_LIST" ] && return 0
  FC_STATE_LIST="$FC_WORK/state.lsf"
  rclone lsf "${SYNC_STATE_DIR:-onedrive:/logs/sync_state}" --files-only --retries 1 \
    --timeout "$(_fc_timeout_arg)" > "$FC_STATE_LIST" 2>/dev/null || : > "$FC_STATE_LIST"
}
_fc_resolve_leaf() {  # <rel 相对任务根> → 设置 FC_LEAF_TASK/DST/SRC/REL/MARKER/DIR
  local rel="$1" dir d
  dir="$(dirname "$rel")"; [ "$dir" = "." ] && dir=""
  # 默认 = **文件所在最深目录**那一级单元（生产 auto-split 会一路分到"无子目录"那层）。
  # 三者必须同时按这一级算: dest/task 加一层、rel 去掉这一层前缀 ——
  # 只改其中一个会让源路径被拼重复（实测踩过: `.../kate-bloom/1024j-.../kate-bloom/x.mp4`）。
  FC_LEAF_DIR="$dir"
  FC_LEAF_TASK="${FC_TASK}${dir:+_${dir//\//_}}"
  FC_LEAF_DST="${FC_DST}${dir:+/$dir}"
  FC_LEAF_REL="${rel#"$dir"/}"
  FC_LEAF_MARKER="$(get_marker_path "$FC_LEAF_TASK" "$FC_LEAF_DST")"

  # 目录层级: 最深 → 任务根
  local -a levels=()
  d="$dir"
  while [ -n "$d" ]; do
    levels+=("$d")
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
  done
  levels+=("")

  _fc_state_list
  local cand lt ld mn
  for cand in "${levels[@]}"; do
    lt="${FC_TASK}${cand:+_${cand//\//_}}"
    ld="${FC_DST}${cand:+/$cand}"
    mn="$(basename "$(get_marker_path "$lt" "$ld")")"
    if grep -qxF "$mn" "$FC_STATE_LIST" 2>/dev/null; then
      FC_LEAF_TASK="$lt"; FC_LEAF_DST="$ld"; FC_LEAF_DIR="$cand"
      FC_LEAF_REL="${rel#"$cand"/}"
      FC_LEAF_MARKER="$(get_marker_path "$lt" "$ld")"
      _fc_log "  🧭 叶子单元（按已有 marker 反查）: ${ld} · marker ${mn} · 单元内相对路径 ${FC_LEAF_REL}"
      return 0
    fi
  done
  # 没有任何现成 marker（该单元首次处理）⇒ 用最深目录: 生产 auto-split 会一路分到
  # "无子目录"那一层，即文件所在目录本身就是叶子
  _fc_log "  🧭 叶子单元（无现成 marker，按最深目录推定）: ${FC_LEAF_DST} · 单元内相对路径 ${FC_LEAF_REL}"
  return 0
}
_fc_leaf_src() { printf '%s' "${FC_SRC}${FC_LEAF_DIR:+/$FC_LEAF_DIR}"; }
# 叶子单元内的相对路径 → 相对任务根的路径（VERDICT 行统一用后者: 用户在清单里给的是
# 任务根口径的名字，行内口径不一致会让 grep 对不上）
_fc_full_rel() {  # <leaf_dest> <leaf_rel>
  local d="${1#${FC_DST}}"; d="${d#/}"
  printf '%s' "${d:+$d/}$2"
}

# ============================================================
# 5. 黑名单重置（能力上限口径；作用于**叶子 marker**）
# ============================================================
_fc_reset_blacklist() {  # <叶子单元内的相对路径>
  local rel="$1" cur merged
  unset "FIX_METHOD_BLACKLIST[$rel]" 2>/dev/null || true
  [ "$FIXCHECK_RESET_BLACKLIST" = "1" ] || return 0
  cur=$(rclone cat "$FC_LEAF_MARKER" 2>/dev/null) || return 0
  printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1 || return 0
  printf '%s' "$cur" | jq -e --arg o "$rel" '.fix_blacklist[$o]' >/dev/null 2>&1 || return 0
  # 只删该文件那一条，其余黑名单保留（代码库无现成函数；写法与
  # sync_marker.sh marker_remove_fix_entry 的 del(.fix_blacklist[$o]) 同款）
  merged=$(printf '%s' "$cur" | jq -c --arg o "$rel" 'del(.fix_blacklist[$o])') || return 0
  _marker_write "$merged" "$FC_LEAF_MARKER" >/dev/null 2>&1 || return 0
  _fc_log "  ♻ 已清除叶子 marker 中该文件的历史黑名单（能力上限口径）"
}

# ============================================================
# 6. 逐文件跑生产同款修复管线
# ============================================================
_fc_try_file() {  # <rel 相对任务根>
  local rel="$1"
  _fc_resolve_leaf "$rel"
  local leaf_src leaf_rel
  leaf_src="$(_fc_leaf_src)"
  leaf_rel="$FC_LEAF_REL"
  local src_full="${leaf_src}/${leaf_rel}" dst_full="${FC_LEAF_DST}/${leaf_rel}"
  local src_bytes dst_bytes

  src_bytes=$(rclone size --json "$src_full" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  [[ "$src_bytes" =~ ^[0-9]+$ ]] || src_bytes=0
  if [ "$src_bytes" -le 0 ]; then
    _fc_verdict not_found "" "$rel" "" "源端不存在或为 0 字节"
    return 1
  fi

  # marker 已记账 ⇒ 文件已由 alternative 形态落盘（生产用 --filter-from 排除它们），
  # 不需要也不应该重传（重传 = 造幽灵文件）
  local mk_json
  mk_json=$(rclone cat "$FC_LEAF_MARKER" 2>/dev/null) || mk_json=""
  if printf '%s' "$mk_json" | jq -e --arg o "$leaf_rel" \
       '[.fixed_files[]? | select(.original == $o)] | length > 0' >/dev/null 2>&1; then
    _fc_verdict already_ok "" "$rel" "" "marker 已记账（文件以替代形态落盘）"
    return 0
  fi

  # 幂等: 目标端原路径已在（且非空）⇒ 不需要修
  dst_bytes=$(rclone size --json "$dst_full" 2>/dev/null | jq -r '.bytes // 0' 2>/dev/null || echo 0)
  [[ "$dst_bytes" =~ ^[0-9]+$ ]] || dst_bytes=0
  if [ "$dst_bytes" -gt 0 ]; then
    _fc_verdict already_ok "" "$rel" "" "目标端原路径已存在（${dst_bytes}B）"
    return 0
  fi

  _fc_reset_blacklist "$leaf_rel"
  _FIX_NAMELEN_CONTENT=0
  _fix_event ATTEMPT "$leaf_rel" 2>/dev/null || true
  _fc_log "▶ 尝试修复 ${rel}（$(format_bytes "$src_bytes")）· 叶子单元 ${FC_LEAF_DST}"
  try_fix_failed_file "$leaf_src" "$FC_LEAF_DST" "$FC_LEAF_TASK" "$leaf_rel" "$FC_FIXLOG" || true

  if [ "$TRY_FIX_STATUS" = "success" ]; then
    # 先入待复核清单（**先验后写**，与生产的"先写后删"不同，见头部说明）
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$FC_LEAF_DST" "$TRY_FIX_ORIGINAL" "$TRY_FIX_ALTERNATIVE" "$TRY_FIX_METHOD" "$TRY_FIX_RESTORE" \
      "$(format_bytes "$src_bytes")" "$src_bytes" "${TRY_FIX_METHOD_ID:-}" "${TRY_FIX_MD5:-}" >> "$FC_FIXLIST"
    _fc_log "  ✅ 修复成功（待真值复核）· $(_fix_method_short "${TRY_FIX_METHOD_ID:-}") · ${TRY_FIX_ALTERNATIVE}"
    return 0
  fi

  _fix_event_fail "$leaf_rel" "${TRY_FIX_MESSAGE:-}" 2>/dev/null || true
  _fc_verdict failed "${TRY_FIX_METHOD_ID:-}" "$rel" "" "${TRY_FIX_MESSAGE:-未知原因}"
  return 1
}

FC_IDX=0
while IFS= read -r _rel || [ -n "$_rel" ]; do
  [ -n "$_rel" ] || continue
  FC_IDX=$((FC_IDX + 1))
  [ "$FC_IDX" -gt "$FIXCHECK_MAX" ] && break
  _fc_try_file "${FC_REL_PREFIX}${_rel}" || true
done < "$FC_CAND"

# ============================================================
# 7. 真值复核（一次重启 + 按叶子单元分组复核；口径同 _sync_persist_verify_and_retry）
# ============================================================
# 每个叶子单元一个 state 快照（同生产 incr_state 口径）；写 marker 时按叶子取
declare -A FC_LEAF_STATE=()
_fc_leaf_state() {  # <marker> <src> <dst> → stdout: state 文件路径
  local mp="$1" sp="$2" dp="$3" sf base
  if [ -n "${FC_LEAF_STATE[$mp]:-}" ]; then printf '%s' "${FC_LEAF_STATE[$mp]}"; return 0; fi
  sf="$FC_WORK/state_$(printf '%s' "$mp" | md5sum | cut -c1-8).json"
  base=$(rclone cat "$mp" 2>/dev/null) || base=""
  if ! printf '%s' "$base" | jq -e 'type == "object"' >/dev/null 2>&1; then
    base=$(jq -cn --arg sp "$sp" --arg dp "$dp" '{source_path:$sp, dest_path:$dp}')
  fi
  printf '%s' "$base" > "$sf"
  FC_LEAF_STATE[$mp]="$sf"
  printf '%s' "$sf"
}
_fc_write_marker() {  # <leaf_dest> <orig> <alt> <method> <restore> <size_human> <size_bytes> <mid> <md5>
  local ld="$1" mp sp sf
  # 叶子 marker 与叶子源路径都由分组阶段按**叶子单元**算出（见 FC_LEAF_MARKER_OF /
  # FC_LEAF_SRC_OF）—— 不能在这里现推: task_name 是逐层 `${task}_${subdir//\//_}` 拼出来的
  mp="${FC_LEAF_MARKER_OF[$ld]:-}"
  sp="${FC_LEAF_SRC_OF[$ld]:-}"
  if [ -z "$mp" ] || [ -z "$sp" ]; then
    _fc_log "  ⚠️ 叶子 marker/源路径未解析（${ld}）⇒ 跳过记账（文件已修但未进 marker，下轮可能重传）"
    return 0
  fi
  sf="$(_fc_leaf_state "$mp" "$sp" "$ld")"
  _persist_fix_entry_now "$mp" "$sf" "$sp" "$ld" \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" 2>&1 | tee -a "$FC_LOG" || true
}

if [ -s "$FC_FIXLIST" ]; then
  # 叶子 dest → 该组的复核清单（alt|bytes|orig|method|mid）
  declare -A FC_GROUP_LIST=()
  declare -A FC_LEAF_MARKER_OF=()
  declare -A FC_LEAF_SRC_OF=()
  while IFS='|' read -r _ld _o _a _m _r _sh _sb _mid _md5 || [ -n "$_ld" ]; do
    [ -n "$_a" ] || continue
    [ -n "${FC_GROUP_LIST[$_ld]:-}" ] || FC_GROUP_LIST[$_ld]="$FC_WORK/verify_$(printf '%s' "$_ld" | md5sum | cut -c1-8).txt"
    printf '%s|%s|%s|%s|%s\n' "$_a" "${_sb:-0}" "$_o" "$_m" "$_mid" >> "${FC_GROUP_LIST[$_ld]}"
    # 叶子 marker 由 (叶子 task_name, 叶子 dest) 决定；叶子 task_name 按生产规则
    # `${task}_${subdir//\//_}` 逐层拼（task_engine.sh:885/1208），叶子源路径同理由 dest 反推
    if [ -z "${FC_LEAF_MARKER_OF[$_ld]:-}" ]; then
      _ldir="${_ld#${FC_DST}}"; _ldir="${_ldir#/}"
      FC_LEAF_MARKER_OF[$_ld]="$(get_marker_path "${FC_TASK}${_ldir:+_${_ldir//\//_}}" "$_ld")"
      FC_LEAF_SRC_OF[$_ld]="${FC_SRC}${_ldir:+/${_ldir}}"
    fi
  done < "$FC_FIXLIST"

  FC_VERIFY_N=0
  for _ld in "${!FC_GROUP_LIST[@]}"; do
    _n=$(grep -c . "${FC_GROUP_LIST[$_ld]}" 2>/dev/null || true)
    [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    FC_VERIFY_N=$((FC_VERIFY_N + _n))
  done

  if [ "$FC_VERIFY_N" -gt 0 ] && [ "$FIXCHECK_TRUTH_RESTART" = "1" ] && command -v docker >/dev/null 2>&1; then
    _fc_log ""
    _fc_log "=== 真值复核: 重启容器取后端真值（${FC_VERIFY_N} 个条目 · ${#FC_GROUP_LIST[@]} 个叶子单元）==="
    # 重启前的"最后检查"快照（刷新缓存 + 记录大小），同生产 1036-1056
    _fc_token="$(_get_openlist_token 2>/dev/null || true)"
    _fc_ol_path="/${FC_DST#openlist:}"
    if [ -n "$_fc_token" ]; then
      curl -s -X POST "http://127.0.0.1:5244/api/fs/refresh" \
        -H "Authorization: $_fc_token" -H "Content-Type: application/json" \
        -d "$(jq -cn --arg p "$_fc_ol_path" '{path:$p, recursive:true}')" >/dev/null 2>&1 || true
      sleep 10
    fi
    if _sync_restart_for_verify "$FC_LOG" "$_fc_ol_path"; then
      declare -A FC_FAILED_SET=()
      for _ld in "${!FC_GROUP_LIST[@]}"; do
        _persist_verify_entries "$_ld" "${FC_GROUP_LIST[$_ld]}" 0 "$FC_LOG"
        _fc_log "  叶子 ${_ld}: 复核 ${PERSIST_IDX} · 通过 ${PERSIST_OK} · 失败 ${PERSIST_FAIL}"
        for _bad in ${PERSIST_FAILED_ORIGS[@]+"${PERSIST_FAILED_ORIGS[@]}"}; do
          [ -n "$_bad" ] && FC_FAILED_SET["${_ld}|${_bad}"]=1
        done
      done
      while IFS='|' read -r _ld _o _a _m _r _sh _sb _mid _md5 || [ -n "$_ld" ]; do
        [ -n "$_a" ] || continue
        if [ -n "${FC_FAILED_SET["${_ld}|${_o}"]:-}" ]; then
          _fc_verdict fake_success "$_mid" "$(_fc_full_rel "$_ld" "$_o")" "$_a" "重启容器后替代路径不可见（PUT 假成功，未落盘）"
        else
          _fc_write_marker "$_ld" "$_o" "$_a" "$_m" "$_r" "$_sh" "$_sb" "$_mid" "$_md5"
          _fc_verdict fixed "$_mid" "$(_fc_full_rel "$_ld" "$_o")" "$_a" "真值复核通过（重启后仍可见），已写 marker"
        fi
      done < "$FC_FIXLIST"
    else
      _fc_log "  ⚠️ 容器重启复核不可用 ⇒ 以下条目**未经真值复核**（仅缓存口径，结论可能偏乐观）"
      while IFS='|' read -r _ld _o _a _m _r _sh _sb _mid _md5 || [ -n "$_ld" ]; do
        [ -n "$_a" ] || continue
        _fc_write_marker "$_ld" "$_o" "$_a" "$_m" "$_r" "$_sh" "$_sb" "$_mid" "$_md5"
        _fc_verdict fixed "$_mid" "$(_fc_full_rel "$_ld" "$_o")" "$_a" "⚠️ 未经真值复核（容器重启不可用，仅缓存口径）"
      done < "$FC_FIXLIST"
    fi
  else
    _fc_log "⚠️ 跳过真值复核（FIXCHECK_TRUTH_RESTART=${FIXCHECK_TRUTH_RESTART} 或 docker 不可用）⇒ 结论仅缓存口径"
    while IFS='|' read -r _ld _o _a _m _r _sh _sb _mid _md5 || [ -n "$_ld" ]; do
      [ -n "$_a" ] || continue
      _fc_write_marker "$_ld" "$_o" "$_a" "$_m" "$_r" "$_sh" "$_sb" "$_mid" "$_md5"
      _fc_verdict fixed "$_mid" "$(_fc_full_rel "$_ld" "$_o")" "$_a" "⚠️ 未经真值复核（已按要求跳过）"
    done < "$FC_FIXLIST"
  fi
fi

# ============================================================
# 8. 汇总 + 退出码
# ============================================================
_fc_log ""
_fc_log "=== 修复能力验证汇总（任务 ${FIXCHECK_TASK} · 模式 ${FIXCHECK_MODE}）==="
_fc_log "  fixed（真值复核通过·已写 marker）: ${FC_COUNT_FIXED}"
_fc_log "  already_ok（原路径已在/已记账）  : ${FC_COUNT_ALREADY}"
_fc_log "  fake_success（假成功·未落盘）    : ${FC_COUNT_FAKE}"
_fc_log "  failed（方法耗尽/其他失败）      : ${FC_COUNT_FAILED}"
_fc_log "  not_found（清单对不上源端）      : ${FC_COUNT_NOTFOUND}"
_fc_log "  结论行文件: ${FC_VERDICTS}"
if [ "$FC_COUNT_FAILED" -gt 0 ] || [ "$FC_COUNT_FAKE" -gt 0 ]; then
  _fc_log "  ↳ 存在修不好的文件 —— 逐条看上面的 VERDICT 行（failed 行第 6 段是失败原因）"
fi

if [ "$FC_COUNT_NOTFOUND" -gt 0 ]; then
  exit 2
elif [ "$FC_COUNT_FAILED" -gt 0 ] || [ "$FC_COUNT_FAKE" -gt 0 ]; then
  exit 1
else
  exit 0
fi
