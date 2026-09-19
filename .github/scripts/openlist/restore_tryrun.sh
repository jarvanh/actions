#!/bin/bash
# ===== OpenList 同步工具 — 一键还原 try run（只读预演）=====
#
# 为什么要有它: 一键还原（file_restore.sh 的 restore_fixed_files）是**写操作** ——
#   move 类会用 rclone moveto 在目标端把替代文件真的搬回原路径，分卷类会下载合卷
#   解压再 copyto 回原路径并删除目标端分卷。真跑之前只能"读 marker 脑补"，
#   脑补错了的代价是**目标端文件被搬到错位置**（且短哈希不可逆，搬错就再也回不去）。
#   本模块按与生产**同源**的路径推导（dest_path + alternative/original + 同一个
#   分类函数），把每一条会怎么走算出来并给出完整路径，**一个字节都不写**。
#
# 交付物 —— 每条修复条目给出三条完整路径（文件头下方「三条路径」）:
#   ① 备份文件（目标端现存形态）= <dest_path>/<alternative>
#   ② marker 记录的原文件       = <dest_path>/<original>
#   ③ 实际执行还原的完整路径     = 生产那条命令**真正落地的**完整路径
#   另附 ④ 源端原路径 <source_path>/<original>（灾难恢复口径，便于交叉核对）
#
# 零写入是**结构性**保证，不是"小心一点"（2026-09-19 教训: 靠自觉的只读约束迟早被
#   下一个加功能的人破坏）: 本模块所有远端调用一律经 _tryr_rclone_read()，
#   白名单只放行 ls/lsd/lsf/lsl/lsjson/cat/size/version，命中 copy/copyto/move/
#   moveto/sync/delete/deletefile/purge/rcat/mkdir 等**一律拒绝执行**。
#   ⇒ 谁往本文件里加写命令都会被护栏当场挡下（test_restore_tryrun.sh 场景 4/5 锁住）。
#
# 用法: restore_try_run [task_name|all]   （task_name = marker 文件名前缀，同生产 restore_task）
# 入参（一律 env；workflow 侧禁止 ${{ }} 内插 bash，见 README「注入面」）:
#   TRYRUN_CHECK_EXISTS=1|0  是否做远端存在性核对（1=默认；0=纯 marker 推导，秒级、
#                            且**不需要 OpenList 容器** —— openlist: 远端只有容器内可访问）
#   TRYRUN_WORK=<报告目录，默认 /tmp/restore_tryrun>
#   TRYRUN_SEND_TG=1|0       是否发 Telegram 汇总（默认 1）
# 产物: <work>/tryrun.tsv（机读，TAB 分隔）+ <work>/tryrun.log（人读；也打 stdout）
# 返回: 0 = 正常产出预演（"备份缺失"是**风险结论**、记在报告里，不判失败）
#       2 = 环境/参数问题（marker 目录列举不到等）
#
# 依赖: telegram/tg_notify.sh（排版真源，L0）, telegram.sh（发送）,
#       sync_marker.sh（SYNC_STATE_DIR / get_marker_path）,
#       file_restore.sh（_restore_classify_kind / _dst_file_exists —— 分类与存在性
#       判定必须与生产同源，绝不另写一套判定）

# 只读子命令白名单（见文件头「零写入是结构性保证」）
_TRYR_READ_SUBCMDS=" ls lsd lsf lsl lsjson cat size version "

# 只读 rclone 包装: 写子命令直接拒绝并返回 2，同时留 stderr 痕迹便于排查
# 用法: _tryr_rclone_read <rclone 参数...>
_tryr_rclone_read() {
  local sub="${1:-}"
  if [ -z "$sub" ] || [[ "$_TRYR_READ_SUBCMDS" != *" $sub "* ]]; then
    echo "🛑 try run 护栏: rclone 子命令 '${sub}' 非只读，已拒绝执行（本模块不得写任何数据）" >&2
    return 2
  fi
  rclone "$@"
}

# 目标端根可读性探测（避免把"我没起容器"伪装成"备份全丢了"，见 _tryr_plan_one 注释）
# 判据: 对 dest 做一次 lsf（返回码为准 —— 空目录也可能 rc=0，空结果不算不可读）
# 每个 dest 只探一次（结果缓存，避免 N 条条目打 N 次远端列举）
# 用法: _tryr_dst_readable <dest>
declare -gA _TRYR_DST_READABLE=()
_tryr_dst_readable() {
  local dest="$1"
  [ -n "${_TRYR_DST_READABLE[$dest]:-}" ] && return "${_TRYR_DST_READABLE[$dest]}"
  local rc=0
  _tryr_rclone_read lsf "$dest" --dirs-only --retries 1 --low-level-retries 2 \
    --timeout 2m >/dev/null 2>&1 || rc=$?
  _TRYR_DST_READABLE[$dest]="$rc"
  return "$rc"
}

# 分卷形态的"备份文件"是**一组**卷: 由首卷名推前缀，返回 "<目录>/<前缀>.[0-9][0-9][0-9]"
# 用法: _tryr_split_glob <alt>
_tryr_split_glob() {
  local alt="$1" d p
  d="$(dirname "$alt")"; p="$(basename "$alt")"; p="${p%.*}"
  [ "$d" = "." ] && printf '/%s.[0-9][0-9][0-9]' "$p" || printf '/%s/%s.[0-9][0-9][0-9]' "$d" "$p"
}

# 预演单条: 输出三行（① ② ③）+ 执行形态说明，并把机读行写进 tsv
# 用法: _tryr_plan_one <tsv> <marker名> <dest> <src> <orig> <alt> <method> <序号>
_tryr_plan_one() {
  local tsv="$1" marker="$2" dest="$3" src="$4" orig="$5" alt="$6" method="$7" idx="$8"
  local kind backup orig_full src_full exec_path exec_cmd note
  local dest_note=""
  kind=$(_restore_classify_kind "$method")
  backup="${dest}/${alt}"
  orig_full="${dest}/${orig}"
  src_full=""
  [ -n "$src" ] && src_full="${src}/${orig}"

  if [ "$alt" = "$orig" ]; then
    # 方法1 原路径原名: 生产只做存在性校验，不搬任何东西。
    # 分类单独取 noop —— 它不是"改名类"，不该进备份缺失统计（本来就没有替代文件）
    kind="noop"
    exec_path="${orig_full}"
    exec_cmd="（无需还原: 原路径原文件名，生产仅校验存在）"
  elif [ "$kind" = "move" ]; then
    # 必须 moveto（dst 被 move 当目录 → 会建出以目标文件名命名的目录，见 file_restore.sh）
    exec_path="${orig_full}"
    exec_cmd="rclone moveto \"${backup}\" \"${orig_full}\""
  else
    exec_path="${orig_full}"
    exec_cmd="下载分卷 ${dest}$(_tryr_split_glob "$alt") → cat 合并 → 7z x → rclone copyto <产物> \"${orig_full}\""
  fi

  # 存在性核对（同生产口径 _dst_file_exists，走的是 lsf，只读）
  # ⚠️ 「列不到」≠「文件不在」（2026-09-18 教训: OpenList 对新建目录/文件有列表缓存
  #   延迟，用列表当判据会把成功判成失败）。这里多一层: 目标端根目录**整体不可读**时
  #   （容器没拉起 / openlist: 远端未配置 / 被限流），把核对降级成"未核对"而不是
  #   "缺失" —— 否则整份预演会红成一片，把"我没起容器"伪装成"备份全丢了"。
  local be="-" oe="-"
  if [ "${TRYRUN_CHECK_EXISTS:-1}" = "1" ]; then
    if ! _tryr_dst_readable "$dest"; then
      be="未核对（目标端不可读）"; oe="未核对（目标端不可读）"
      dest_note="⚠️ 目标端 ${dest} 不可读（容器未拉起或远端不可达）⇒ 存在性未核对，请用开启容器的 workflow 轮次复核"
    elif [ "$kind" = "noop" ]; then
      # 原路径原名: 没有替代文件，只核对原路径本身在不在
      _dst_file_exists "$orig_full" && oe="已存在" || oe="不存在"
      be="（无需替代文件）"
    else
      if [ "$kind" = "split" ]; then
        # 分卷只核对首卷: 首卷在即视为备份在（真跑时缺任一卷会在合卷阶段失败）
        _dst_file_exists "$backup" && be="存在（首卷）" || be="缺失"
      else
        _dst_file_exists "$backup" && be="存在" || be="缺失"
      fi
      _dst_file_exists "$orig_full" && oe="已存在" || oe="不存在"
    fi
  fi

  _tryr_log "  [${idx}] ${orig}"
  _tryr_log "      ① 备份文件（目标端现存）      : ${backup}"
  _tryr_log "      ② marker 记录的原文件         : ${orig_full}"
  _tryr_log "      ③ 实际执行还原的完整路径      : ${exec_path}"
  _tryr_log "      ④ 源端原路径（灾难恢复口径）  : ${src_full:-（marker 无 source_path）}"
  _tryr_log "      分类: ${kind} · 备份: ${be} · 原路径: ${oe}"
  _tryr_log "      将执行: ${exec_cmd}"
  if [ "$kind" = "split" ]; then
    _tryr_log "      备份文件全集: ${dest}$(_tryr_split_glob "$alt")"
  fi
  [ -n "$dest_note" ] && _tryr_log "      ${dest_note}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$marker" "$method" "$kind" "$backup" "$orig_full" "$exec_path" "$exec_cmd" \
    "$be" "$oe" "$src_full" >> "$tsv"

  # 统计与清单回传给调用方（bash 无返回值，用约定的全局变量）
  TRYRUN_KIND_COUNT[$kind]=$(( ${TRYRUN_KIND_COUNT[$kind]:-0} + 1 ))
  # kind=noop（原路径原名）没有替代文件，本来就不存在"备份缺失"，不计入缺失统计
  [ "$be" = "缺失" ] && TRYRUN_MISSING=$((TRYRUN_MISSING + 1)) && TRYRUN_MISSING_LIST+="${orig}"$'\n'
  if [ -n "$dest_note" ]; then
    TRYRUN_UNVERIFIED=$((TRYRUN_UNVERIFIED + 1))
    TRYRUN_UNVERIFIED_DESTS+="${dest}"$'\n'
  fi
  # Telegram 汇总只列原文件名（三条完整路径进 run 日志 / artifact: 一次预演动辄上百条，
  # 每条 3 个完整路径塞进通知必然顶到 4000 字符分片边界把收尾区切走）
  TRYRUN_ENTRY_LIST+="${orig}"$'\n'
}

# 一键还原 try run 入口
# 用法: restore_try_run [task_name|all]
restore_try_run() {
  local task_filter="${1:-all}"
  TRYRUN_WORK="${TRYRUN_WORK:-/tmp/restore_tryrun}"
  mkdir -p "$TRYRUN_WORK" 2>/dev/null || { echo "❌ 无法创建报告目录: $TRYRUN_WORK" >&2; return 2; }
  TRYRUN_LOG="$TRYRUN_WORK/tryrun.log"
  local tsv="$TRYRUN_WORK/tryrun.tsv"
  : > "$TRYRUN_LOG"; : > "$tsv"

  local total=0
  TRYRUN_MISSING=0; TRYRUN_MISSING_LIST=""
  TRYRUN_UNVERIFIED=0; TRYRUN_UNVERIFIED_DESTS=""
  declare -gA TRYRUN_KIND_COUNT=()
  _TRYR_DST_READABLE=()
  TRYRUN_ENTRY_LIST=""

  _tryr_log() { printf '%s\n' "$*" | tee -a "$TRYRUN_LOG"; }

  _tryr_log "=== 一键还原 try run（只读预演）==="
  _tryr_log "  任务过滤=${task_filter} · marker 目录=${SYNC_STATE_DIR}"
  _tryr_log "  存在性核对=${TRYRUN_CHECK_EXISTS:-1}（0=纯 marker 推导，不访问目标端）"
  _tryr_log "  报告: ${TRYRUN_LOG} / ${tsv}"
  _tryr_log ""

  local markers
  markers=$(_tryr_rclone_read lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    _tryr_log "❌ 未列举到任何 marker（${SYNC_STATE_DIR}）—— 检查 rclone 配置与远端路径"
    return 2
  fi

  local m task marker_path json dest src count idx
  for m in $markers; do
    [[ "$m" == *.json ]] || continue
    task="${m%%_*}"
    if [ "$task_filter" != "all" ] && [ "$task" != "$task_filter" ]; then
      continue
    fi
    marker_path="${SYNC_STATE_DIR}/${m}"
    json=$(_tryr_rclone_read cat "$marker_path" --retries 2 2>/dev/null) || continue
    dest=$(printf '%s' "$json" | jq -r '.dest_path // empty' 2>/dev/null)
    src=$(printf '%s' "$json" | jq -r '.source_path // empty' 2>/dev/null)
    [ -z "$dest" ] && continue
    count=$(printf '%s' "$json" | jq -r '(.fixed_files // []) | length' 2>/dev/null || echo 0)
    [ "${count:-0}" -eq 0 ] && continue

    _tryr_log "--- marker: ${m} ---"
    _tryr_log "  dest_path=${dest}"
    _tryr_log "  source_path=${src:-（无）}"
    _tryr_log "  待还原条目: ${count} 条"

    idx=0
    while IFS=$'\t' read -r orig alt method fmd5; do
      [ -z "$orig" ] && continue
      [ "$alt" = "null" ] || [ -z "$alt" ] && alt="$orig"
      idx=$((idx + 1)); total=$((total + 1))
      _tryr_plan_one "$tsv" "$m" "$dest" "$src" "$orig" "$alt" "$method" "$idx"
    done < <(printf '%s' "$json" | jq -r '(.fixed_files // [])[] | [.original, .alternative, .method, (.md5 // "")] | @tsv' 2>/dev/null)
  done

  _tryr_log ""
  _tryr_log "=== 预演汇总: 条目 ${total} 条 · 备份缺失 ${TRYRUN_MISSING} 条 · 存在性未核对 ${TRYRUN_UNVERIFIED} 条 ==="
  for k in "${!TRYRUN_KIND_COUNT[@]}"; do
    _tryr_log "  ${k}: ${TRYRUN_KIND_COUNT[$k]} 条"
  done
  if [ "$TRYRUN_MISSING" -gt 0 ]; then
    _tryr_log "  ⚠️ 备份缺失清单（真跑会 FAIL: 替代文件可能已不存在）:"
    printf '%s' "$TRYRUN_MISSING_LIST" | while IFS= read -r l; do [ -n "$l" ] && _tryr_log "     - ${l}"; done
  fi
  if [ "$TRYRUN_UNVERIFIED" -gt 0 ]; then
    _tryr_log "  ⚠️ 存在性未核对（目标端不可读，通常是 OpenList 容器没拉起）:"
    printf '%s' "$TRYRUN_UNVERIFIED_DESTS" | sort -u | while IFS= read -r l; do [ -n "$l" ] && _tryr_log "     - ${l}"; done
    _tryr_log "     ↳ 三条路径本身由 marker 推导，仍然准确；只是'在不在'没核对"
  fi
  _tryr_log "  ✅ 全程只读: 未写入/移动/删除任何源端与目标端数据"

  # ---- Telegram 汇总 ----
  if [ "${TRYRUN_SEND_TG:-1}" = "1" ]; then
    local msg=""
    tg_add_title msg "🧪 一键还原 try run（只读预演）"
    tg_add_kv msg "模式" "只读预演 · 未修改任何数据"
    tg_add_kv msg "任务过滤" "${task_filter}"
    tg_add_kv msg "预演条目" "${total} 个"
    local kinds="" k
    for k in $(printf '%s\n' "${!TRYRUN_KIND_COUNT[@]}" | sort); do
      kinds+="${k} ${TRYRUN_KIND_COUNT[$k]} · "
    done
    [ -n "$kinds" ] && tg_add_kv msg "分类" "${kinds% · }"
    tg_add_kv msg "备份缺失" "${TRYRUN_MISSING} 个"
    [ "$TRYRUN_UNVERIFIED" -gt 0 ] && tg_add_kv msg "存在性未核对" "${TRYRUN_UNVERIFIED} 个"
    if [ "$total" -gt 0 ]; then
      tg_add_section msg "📋 条目 · ${total}"
      tg_add_block msg "$(tree_fold "$TRYRUN_ENTRY_LIST" "$total")"
      tg_add_note msg "完整三条路径见 run 日志 / artifact（tryrun.tsv）；此处只列原文件名"
    fi
    if [ "$TRYRUN_MISSING" -gt 0 ]; then
      tg_add_section msg "⚠️ 备份缺失 · ${TRYRUN_MISSING}"
      tg_add_block msg "$(tree_fold "$TRYRUN_MISSING_LIST" "$TRYRUN_MISSING")"
      tg_add_note msg "目标端找不到替代文件，真跑会判 FAIL（条目保留在 marker，不会丢）"
    fi
    if [ "$TRYRUN_UNVERIFIED" -gt 0 ]; then
      tg_add_note msg "存在性未核对 ${TRYRUN_UNVERIFIED} 条: 目标端不可读（多为容器未拉起），三条路径仍准确但'在不在'未验证"
    fi
    tg_add_note msg "try run 全程只读（lsf/cat/size），源端与目标端均未改动。"
    tg_add_footer msg
    send_telegram_message "$msg"
  fi

  echo "=== try run 完成: 条目=${total} 备份缺失=${TRYRUN_MISSING} 未核对=${TRYRUN_UNVERIFIED}（未写入任何数据）==="
  return 0
}

# 日志函数单独定义（供 _tryr_plan_one 在入口未设置 TRYRUN_LOG 时也能安全调用）
# 注意: 入口会覆盖同名函数以绑定本次的 TRYRUN_LOG；这里只是防"直接调内部函数"时报错
_tryr_log() { printf '%s\n' "$*"; }

# 模块级状态（入口会重置；这里初始化是为了被单独 source 时变量已存在，
# 避免 set -u 下 `_tryr_plan_one` 引用未定义变量直接退出）
declare -gA TRYRUN_KIND_COUNT=()
declare -gA _TRYR_DST_READABLE=()
TRYRUN_MISSING=0
TRYRUN_UNVERIFIED=0
TRYRUN_MISSING_LIST=""
TRYRUN_UNVERIFIED_DESTS=""
TRYRUN_ENTRY_LIST=""
