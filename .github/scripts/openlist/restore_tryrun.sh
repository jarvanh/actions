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
#   存在性给两套判据: 列列举（目录清单）+ **直读**（lsjson 全路径 stat）；两者分歧时
#   以直读为准（§0 纪律: 只以列列举为准会把成功判成失败，见 _tryr_stat_exists 注释）。
#
# 零写入是**结构性**保证，不是"小心一点"（2026-09-19 教训: 靠自觉的只读约束迟早被
#   下一个加功能的人破坏）: 本模块所有远端调用一律经 _tryr_rclone_read()，
#   白名单只放行 ls/lsd/lsf/lsl/lsjson/cat/size/version，命中 copy/copyto/move/
#   moveto/sync/delete/deletefile/purge/rcat/mkdir 等**一律拒绝执行**。
#   ⇒ 谁往本文件里加写命令都会被护栏当场挡下（test_restore_tryrun.sh 场景 4/5 锁住）。
#
# 用法: restore_try_run [task_name|all]   （task_name = marker 文件名前缀，同生产 restore_task）
#   环境变量:
#   TRYRUN_WITHIN_DAYS=N  只预演**最近 N 天**产生的 marker。0/空 = 全量（默认）。
#       ⚠️ 为什么需要这个口径: 还原失败的条目会**留在 marker 里不删**，marker 因此
#       只增不减；攒了几周后全量预演里绝大多数是**早已失效的旧记录**（对应文件在
#       目标端早就不在了），把"备份缺失"数抬得很高却不是当前问题。按时间窗筛才能
#       看出"最近这几轮到底有没有真缺"。
#   TRYRUN_SINCE=<UTC 时间下界，如 2026-09-19T11:03:00 或 2026-09-19>
#       只预演**该时刻之后**产生的 marker。为什么需要**绝对**下界而不是只靠
#       WITHIN_DAYS: 判定"新旧 marker 是否兼容"要看**语义变更提交**的那个时间点
#       （最近一次改写 marker 语义的是 e90118e，2026-09-19T11:03:00Z，move→moveto），
#       而"最近 3 天"是相对天数，会把该时刻**之前**的旧语义 marker 一起放进来
#       ⇒ 结论样本不纯。绝对下界才能切出"全都是新语义写的"这一批。
#       与 WITHIN_DAYS 同时给时取**更严**（两个下界都满足才放行）。
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

# UTC 日期时间 → epoch（纯 bash 算术，零 fork、跨平台）
# ⚠️ 为什么自己算而不用 `date -d`: 两处硬约束 ——
#   1) 本库回归套件已登记 macOS 的 date 无 -d（marker_skip_guards 等 2 项环境假红即由此起）；
#   2) bash 的 `printf '%(%s)T'` **只接受 epoch、不接受日期字符串**（实测 "2026-09-19T03:00:00"
#      报 invalid number），所以它只能做反向格式化、不能当解析器。
#   故按 Howard Hinnant 的 days_from_civil 算法用整数运算实现，且**按 UTC 解释**
#   （rclone lsl 的时间戳是 UTC 口径），不受 runner 本机时区影响。
# 用法: _tryr_epoch_utc "YYYY-MM-DD" "HH:MM:SS"
_tryr_epoch_utc() {
  local y=$((10#${1:0:4})) mo=$((10#${1:5:2})) d=$((10#${1:8:2}))
  local h=$((10#${2:0:2})) mi=$((10#${2:3:2})) s=$((10#${2:6:2}))
  # 前导 0 必须经 10# interpret（否则 08/09 被当八进制直接报错）
  [ "$mo" -le 2 ] && y=$((y - 1))
  local era=$(( (y >= 0 ? y : y - 399) / 400 ))
  local yoe=$(( y - era * 400 ))
  local doy=$(( (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  local doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  echo $(( (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + s ))
}

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

# 预演侧的存在性判定: 走**目录清单缓存**，不做"每次一条 lsf"
# 为什么: 生产 _dst_file_exists 每次列举一个目录（1 次 rclone 进程）。逐条核对时
#   4500 条 ≈ 9000 次远端列举 —— run 35474941314 实测仅"纯推导不带核对"就 26 分钟，
#   再叠上万次列举必然撞 timeout。故按目录缓存清单（同一目录下的条目共享一次列举）。
# ⚠️ 仍受 OpenList 列表缓存延迟影响（§0 2026-09-18: 新建文件首次可见约 10s）。
#   对**预演**可接受：预演是"看会怎么走"，不是"判成败"；真跑的判据在生产侧。
#   ⇒ "缺失"必须再经 _tryr_stat_exists() 直读复核才进结论（见该处注释）。
#   清单匹配用 bash 自身的前后换行包裹比较，**不用 `printf | grep -qxF`**:
#   grep -q 一命中就退出 → 管道断裂，每条 2 次 ⇒ 4674 条上万次 "printf: write error:
#   Broken pipe"（run 35476841345 实测: 光刷这些错误就把核对模式拖过 36 分钟、撞 40 分钟
#   timeout 被取消）。fork 才是这里的时间账，远端列举次数是次要项。
# 用法: _tryr_exists <full_remote_path>
declare -gA _TRYR_DIR_CACHE=()
_tryr_exists() {
  local full="$1" d b listing
  # 用 bash 参数展开剥目录/文件名，不用 dirname/basename —— 每条 2 次 fork × 4674 条
  # 又是一万次进程创建（同上: fork 才是核对模式的时间账）
  d="${full%/*}"; b="${full##*/}"
  [ "$d" = "$full" ] && d=""
  if [ -z "${_TRYR_DIR_CACHE[$d]+x}" ]; then
    listing=$(_tryr_rclone_read lsf "$d" --files-only --retries 1 --low-level-retries 2 \
      --timeout 2m 2>/dev/null)
    _TRYR_DIR_CACHE[$d]="$listing"
  fi
  # 前后换行包裹后做子串匹配 —— 等价于 grep -qxF 但零 fork
  [[ $'\n'"${_TRYR_DIR_CACHE[$d]}"$'\n' == *$'\n'"$b"$'\n'* ]]
}

# ⚠️ 直读判据（独立于上面的列列举）: 按**全路径 stat**，返回码即"在不在"。
# 为什么必须两套判据并存（§0 2026-09-18 教训）: 以"列列举里有没有"判"文件在不在"，
#   会把**成功判成失败** —— 列举取空/被限流/缓存滞后时，目录下**所有**条目一起变
#   "缺失"，而直读是逐文件 stat，不依赖目录清单。故结论分歧时以**直读为准**。
#   形状诊断: 若某目录下同时存在"存在"和"缺失"，那是逐文件的差异（真缺/改名）；
#   若**整目录一律缺失**，那是清单取空，直读复核必然翻案（run 35482750267 实测
#   167 个缺失目录 **0 个混合** ⇒ 高度指向清单取空，故必须复核才敢下结论）。
# 用法: _tryr_stat_exists <full_remote_path>
declare -gA _TRYR_STAT_CACHE=()
_tryr_stat_exists() {
  local full="$1"
  [ -n "${_TRYR_STAT_CACHE[$full]:-}" ] && return "${_TRYR_STAT_CACHE[$full]}"
  local rc=0
  _tryr_rclone_read lsjson "$full" --retries 1 --timeout 2m >/dev/null 2>&1 || rc=$?
  _TRYR_STAT_CACHE[$full]="$rc"
  return "$rc"
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

# 源端根可读性探测（与上面目标端同构，2026-09-20 V5 续新增）
# 为什么必须有: _tryr_stat_exists 对"远端不可达"和"文件真不在"**都返回非 0**，
#   不先判可读性就会把"源端连不上"谎报成"源端没有这个文件" —— 那正是 Q3 的结论，
#   谎报不得。每个 src 只探一次（缓存）。
# 用法: _tryr_src_readable <src>
declare -gA _TRYR_SRC_READABLE=()
_tryr_src_readable() {
  local src="$1"
  [ -n "${_TRYR_SRC_READABLE[$src]:-}" ] && return "${_TRYR_SRC_READABLE[$src]}"
  local rc=0
  _tryr_rclone_read lsf "$src" --dirs-only --retries 1 --low-level-retries 2 \
    --timeout 2m >/dev/null 2>&1 || rc=$?
  _TRYR_SRC_READABLE[$src]="$rc"
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
      # ⚠️ 「原路径不存在」同样要直读复核（2026-09-20，run 35502528927 驱动）:
      #   此前只给"备份缺失"加了直读复核，原路径仍**纯靠列列举** ⇒ 与 fix-check 的
      #   递归列举同刻互相矛盾（fix-check 说 529/529 都在，这边说原路径不存在）。
      #   两边都是"列表"，而列表有缓存延迟（§0: 新建首次可见 ~10s，等 15s 仍可能不可见）
      #   ⇒ 不一致时必须有一个**非列表**判据才能定案。原路径是"真跑的落点"，
      #   判错会直接导致"该还原的判成不用还原"，风险不比备份侧低。
      _tryr_exists "$orig_full" && oe="已存在" || oe="不存在"
      if [ "$oe" = "不存在" ] && _tryr_stat_exists "$orig_full"; then
        oe="已存在（直读复核翻案）"
        TRYRUN_ORIG_FLIPPED=$((TRYRUN_ORIG_FLIPPED + 1))
      fi
      [ "$oe" = "不存在" ] && TRYRUN_ORIG_RECHECK_TOTAL=$((TRYRUN_ORIG_RECHECK_TOTAL + 1))
      be="（无需替代文件）"
    else
      if [ "$kind" = "split" ]; then
        # 分卷只核对首卷: 首卷在即视为备份在（真跑时缺任一卷会在合卷阶段失败）
        _tryr_exists "$backup" && be="存在（首卷）" || be="缺失"
      else
        _tryr_exists "$backup" && be="存在" || be="缺失"
      fi
      # 列列举判"缺失" → 再走一次**直读**复核（纪律见 _tryr_stat_exists 注释）:
      # 只复核判缺失的那些（判"存在"是列列举命中的，无假阴性风险），代价可控。
      if [ "$be" = "缺失" ]; then
        if _tryr_stat_exists "$backup"; then
          be="存在（直读复核翻案）"
          [ "$kind" = "split" ] && be="存在（首卷·直读复核翻案）"
          TRYRUN_RECHECK_FLIPPED=$((TRYRUN_RECHECK_FLIPPED + 1))
        fi
        TRYRUN_RECHECK_TOTAL=$((TRYRUN_RECHECK_TOTAL + 1))
      fi
      # 同上面的备份侧: 原路径同样只复核"列列举判不存在"的那些
      _tryr_exists "$orig_full" && oe="已存在" || oe="不存在"
      if [ "$oe" = "不存在" ]; then
        if _tryr_stat_exists "$orig_full"; then
          oe="已存在（直读复核翻案）"
          TRYRUN_ORIG_FLIPPED=$((TRYRUN_ORIG_FLIPPED + 1))
        fi
        TRYRUN_ORIG_RECHECK_TOTAL=$((TRYRUN_ORIG_RECHECK_TOTAL + 1))
      fi
    fi
  fi

  # ④ 源端原路径**直读核对**（2026-09-20 V5 续，直接服务 Q3「能否还原回原路径源文件」）:
  #   marker 的 original 是"还原落点"的唯一依据；若**源端根本没有这个原路径**，
  #   说明 marker 记的落点已失效（源端被改过 / 当初就记错），真跑会把文件还原到
  #   一个"源端不存在"的路径上 —— 这是 Q3 的失败形态，必须能看见。
  #   判据用直读（lsjson）而非列列举: 源端是 OneDrive，§14 已实测其 `lsl` 可能返回
  #   0 行，列表类判据在本远端上不可信。源端不可读时标"未核对"，不谎报"不存在"。
  local se="-"
  # 只对**备份判缺失**的条目核源端: 它们才是"真跑会 FAIL"的那批，也是 Q3 要定案的
  #   那批；对全部 300 条逐条直读源端既慢又无必要（备份在的手里有货，落点失不失效
  #   不影响"能不能还原"）。源端可读性先判，不可读 ⇒ 标"未核对"，绝不谎报"不在"。
  if [ "${TRYRUN_CHECK_EXISTS:-1}" = "1" ] && [ -n "$src_full" ] \
     && [ "$be" = "缺失" ]; then
    if ! _tryr_src_readable "$src"; then
      se="未核对（源端不可读）"
    elif _tryr_stat_exists "$src_full"; then
      se="在"
    else
      se="不在"
      TRYRUN_SRC_MISSING=$((TRYRUN_SRC_MISSING + 1))
      TRYRUN_SRC_MISSING_LIST+="${orig}"$'\n'
    fi
    TRYRUN_SRC_CHECKED=$((TRYRUN_SRC_CHECKED + 1))
  fi

  _tryr_log "  [${idx}] ${orig}"
  _tryr_log "      ① 备份文件（目标端现存）      : ${backup}"
  _tryr_log "      ② marker 记录的原文件         : ${orig_full}"
  _tryr_log "      ③ 实际执行还原的完整路径      : ${exec_path}"
  _tryr_log "      ④ 源端原路径（灾难恢复口径）  : ${src_full:-（marker 无 source_path）}"
  _tryr_log "      分类: ${kind} · 备份: ${be} · 原路径: ${oe} · 源端: ${se}"
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
  # kind=noop 没有替代文件，本来就不存在"备份缺失"，不计入缺失统计
  # "存在（…直读复核翻案）"也算存在 —— 直读是更可靠的判据，不因字面值差异漏计
  case "$kind" in
    noop) ;;
    *) case "$be" in 存在*) TRYRUN_PRESENT=$((TRYRUN_PRESENT + 1)) ;; esac ;;
  esac
  case "$be" in
    缺失) TRYRUN_MISSING=$((TRYRUN_MISSING + 1)); TRYRUN_MISSING_LIST+="${orig}"$'\n'
          # 记下"备份所在目录"，供汇总段的父目录实况探针用（去重在汇总段做）
          TRYRUN_MISSING_DIRS+="${backup%/*}"$'\n'
          # 顺带记"该备份目录对应的源端同层": 目标端 <dest>/<orig目录上级> 对应
          #   源端 <src>/<同相对路径>；探针要用它打源端形状做对照（V5 矛盾: fix-check
          #   报两侧 529/529 差集 0，本探针却看不到 蓝白碗 —— 需两侧形状同屏才判得了）
          if [ -n "$src" ]; then
            # orig=蓝白碗/x.jpg ⇒ orig%/*=蓝白碗 ⇒ 再取一次上级才是"与备份目录同层的源端目录"
            local _src_dir="${src}/${orig%/*}"; _src_dir="${_src_dir%/*}"
            _TRYR_SRC_OF_MDIR["${backup%/*}"]="$_src_dir"
          fi ;;
    存在（*直读复核翻案）) TRYRUN_FLIPPED_LIST+="${backup}"$'\n' ;;
  esac
  # 翻案后的字面值是"已存在（直读复核翻案）"，不能只判"已存在"——那样翻案件会被漏计
  case "$oe" in 已存在*) TRYRUN_ORIG_EXISTS=$((TRYRUN_ORIG_EXISTS + 1)) ;; esac
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
  TRYRUN_PRESENT=0; TRYRUN_ORIG_EXISTS=0
  TRYRUN_RECHECK_TOTAL=0; TRYRUN_RECHECK_FLIPPED=0; TRYRUN_FLIPPED_LIST=""
  # 原路径侧的直读复核计数（与备份侧对称: 两条判据各自记，别混成一个数）
  TRYRUN_ORIG_RECHECK_TOTAL=0; TRYRUN_ORIG_FLIPPED=0
  TRYRUN_UNVERIFIED=0; TRYRUN_UNVERIFIED_DESTS=""
  TRYRUN_MISSING_DIRS=""
  TRYRUN_SRC_CHECKED=0; TRYRUN_SRC_MISSING=0; TRYRUN_SRC_MISSING_LIST=""
  # 备份缺失目录 → 源端同层目录（供结构探针打两侧形状对照）
  declare -gA _TRYR_SRC_OF_MDIR=()
  _TRYR_SRC_READABLE=()
  declare -gA TRYRUN_KIND_COUNT=()
  _TRYR_DST_READABLE=()
  _TRYR_DIR_CACHE=()
  _TRYR_STAT_CACHE=()
  TRYRUN_ENTRY_LIST=""

  # 日志写入用 >> 重定向而不是 `| tee -a`: 每条 7 行 × 4500+ 条 = 3 万次 fork，
  # 实测把本该秒级的预演拖到 26 分钟（run 35474941314），而 check_exists=是 要在此基础上
  # 再加逐条 lsf，必然撞 timeout。人类看的 stdout 由入口末尾统一 cat 出来，不逐行 tee。
  _tryr_log() { printf '%s\n' "$*" >> "$TRYRUN_LOG"; }

  # 时间下界的**原始入参**先声明（头部日志要用，故必须早于下面的解析）
  local since_raw="${TRYRUN_SINCE:-}"
  local since_epoch=0

  _tryr_log "=== 一键还原 try run（只读预演）==="
  _tryr_log "  任务过滤=${task_filter} · marker 目录=${SYNC_STATE_DIR}"
  _tryr_log "  时间窗=最近 ${TRYRUN_WITHIN_DAYS:-0} 天 · 绝对下界=${since_raw:-（无）}（0/空 = 全量）"
  _tryr_log "  存在性核对=${TRYRUN_CHECK_EXISTS:-1}（0=纯 marker 推导，不访问目标端）"
  _tryr_log "  报告: ${TRYRUN_LOG} / ${tsv}"
  _tryr_log ""

  # 时间窗（0/空 = 全量）。
  #
  # 时间源优先级（run 35489237518 实测定下来的）:
  #   **1) marker 自带的 last_success**（UTC，写 marker 时落盘，见 sync_marker.sh:498）
  #   **2) 远端 ModTime**（一次 lsl 取全目录后本地比较，绝不逐个 lsl —— 几百次往返
  #      和逐条 lsf 是同一类风暴）
  #   为什么 1 优先: OneDrive 的 `rclone lsl` **返回 0 行**（该后端不吐 ModTime 列表），
  #   纯按 ModTime 实现 ⇒ 生产上 422 个 marker 全被判"无时间戳"，条目 0（run
  #   35488836925）。而 last_success 是 marker 内容自带的，**零额外往返**（cat 本来
  #   就要读全文），且与"这个 marker 是哪一轮产生的"语义完全一致。
  #
  # ⚠️ 两条纪律（都是真踩出来的）:
  #   1) lsl 的名字要按**基名**匹配: lsf 给基名、lsl 给从远端根算起的完整相对路径。
  #   2) **"整体取不到"必须与"个别没有"区分开**: 混为一谈会把"时间窗机制失效"
  #      静默翻译成"条目 0 / 缺失 0"，看着像"最近 3 天没缺"，实际是**根本没测**
  #      （§0: 判据静默失败 ⇒ 错误结论）。故一个时间戳都解析不出来时**回落全量
  #      并大声告警**，绝不产出"空结论"。
  local within_days="${TRYRUN_WITHIN_DAYS:-0}"
  local cutoff=0
  local ts_parsed=0 ts_fallback=0
  if [[ "$within_days" =~ ^[0-9]+$ ]] && [ "$within_days" -gt 0 ]; then
    # 同样不用 date +%s（见下方时间戳解析处的说明）
    cutoff=$(( $(printf '%(%s)T' -1) - within_days * 86400 ))
  fi
  # TRYRUN_SINCE: **绝对**时间下界（"只看某次语义变更之后写的 marker"）。
  #   两个下界同时给时取**更严**者 —— 否则"最近 3 天"会把语义变更前的旧 marker
  #   也放进来，样本不纯、结论不可比（§15.2）。
  #   解析失败必须**大声报错并回落**，绝不静默忽略: 静默忽略 = 用户以为按某个
  #   时间点筛了，实际是全量（§0 判据静默失败 ⇒ 错误结论）。
  #   （解析失败会在此处告警并回落；具体格式见文件头 TRYRUN_SINCE 说明）
  if [ -n "$since_raw" ]; then
    local sd="${since_raw%%T*}"; st="${since_raw#*T}"
    [ "$st" = "$since_raw" ] && st="00:00:00"
    st="${st%%.*}"; st="${st%%+*}"; st="${st%Z}"
    if [[ "$sd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
       && [[ "$st" =~ ^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
      [[ "$st" =~ ^[0-9]{2}:[0-9]{2}$ ]] && st="${st}:00"
      since_epoch=$(_tryr_epoch_utc "$sd" "$st")
      [ "$since_epoch" -gt "$cutoff" ] && cutoff="$since_epoch"
    else
      _tryr_log "  ❌ TRYRUN_SINCE 无法解析（${since_raw}）: 需 YYYY-MM-DD 或 " \
                "YYYY-MM-DDTHH:MM:SS ⇒ 本次**不看时间窗**（宁可全量，也不假装筛过）"
    fi
  fi
  # 兜底时间源: lsl 的 ModTime（last_success 缺失时才用）
  declare -gA _TRYR_MARKER_TS=()
  if [ "$cutoff" -gt 0 ]; then
    local ts_lines=0 lsl_line fts fname fdate ftime
    local lsl_file="${TRYRUN_WORK}/tryrun_lsl.txt"
    _tryr_rclone_read lsl "$SYNC_STATE_DIR" --files-only --retries 2 >"$lsl_file" 2>/dev/null
    while IFS= read -r lsl_line; do
      [ -z "$lsl_line" ] && continue
      ts_lines=$((ts_lines + 1))
      # 取后三字段: 日期、时间、路径（文件名可能含空格，故按行尾取而非 cut 固定列）
      fdate=$(printf '%s' "$lsl_line" | awk '{print $(NF-2)}')
      ftime=$(printf '%s' "$lsl_line" | awk '{print $(NF-1)}')
      fname=$(printf '%s' "$lsl_line" | awk '{print $NF}')
      [ -z "$fdate" ] || [ -z "$fname" ] && continue
      fname="${fname##*/}"        # 基名: lsl 给的是完整相对路径，lsf 给的是基名
      ftime="${ftime%%.*}"        # 去掉小数秒
      ftime="${ftime%%+*}"        # 去掉可能的时区后缀
      [[ "$fdate" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
      [[ "$ftime" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || continue
      fts=$(_tryr_epoch_utc "$fdate" "$ftime")
      [ -n "$fts" ] || continue
      _TRYR_MARKER_TS["$fname"]="$fts"
    done < "$lsl_file"
  fi

  local markers
  markers=$(_tryr_rclone_read lsf "$SYNC_STATE_DIR" --files-only --retries 2 2>/dev/null | sort)
  if [ -z "$markers" ]; then
    _tryr_log "❌ 未列举到任何 marker（${SYNC_STATE_DIR}）—— 检查 rclone 配置与远端路径"
    return 2
  fi

  # ---- 阶段一: 逐 marker 读全文 + 解析时间戳（只 cat 一次，结果缓存在内存）----
  # 为什么要先全量读完再筛: "时间窗机制是否整体失效"只有读完后才知道，而知道了
  #   还必须能**立刻用缓存重跑全量**（否则就得再 cat 一遍 422 个 marker，几十分钟）。
  local m task marker_path json dest src count idx mts mts_date mts_time mts_epoch
  local scanned=0 skipped_old=0 skipped_nots=0
  # m=marker 名 → 拼成 "epoch\tjson" 存数组（marker 里含中文/空格，故按行读取）
  local -a _mk_names=()
  local -A _mk_epoch=() _mk_json=()
  for m in $markers; do
    [[ "$m" == *.json ]] || continue
    task="${m%%_*}"
    if [ "$task_filter" != "all" ] && [ "$task" != "$task_filter" ]; then
      continue
    fi
    marker_path="${SYNC_STATE_DIR}/${m}"
    json=$(_tryr_rclone_read cat "$marker_path" --retries 2 2>/dev/null) || continue
    [ -z "$json" ] && continue
    _mk_names+=("$m"); _mk_json["$m"]="$json"
    [ "$cutoff" -eq 0 ] && continue
    # 时间源: ① marker 自带的 last_success（UTC，见上）；② 兜底 lsl 的 ModTime
    mts=$(printf '%s' "$json" | jq -r '.last_success // empty' 2>/dev/null)
    if [ -n "$mts" ]; then
      mts="${mts%%.*}"; mts="${mts%%+*}"; mts="${mts%Z}"
      mts_date="${mts%%T*}"; mts_time="${mts#*T}"
      if [[ "$mts_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
         && [[ "$mts_time" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        _mk_epoch["$m"]=$(_tryr_epoch_utc "$mts_date" "$mts_time")
      fi
    elif [ -n "${_TRYR_MARKER_TS[$m]:-}" ]; then
      _mk_epoch["$m"]="${_TRYR_MARKER_TS[$m]}"
    fi
  done

  # ---- 阶段一·半: 机制是否整体失效 ⇒ 决定要不要回落全量 ----
  if [ "$cutoff" -gt 0 ]; then
    local n_with=0
    for m in "${_mk_names[@]}"; do
      [ -n "${_mk_epoch[$m]:-}" ] && n_with=$((n_with + 1))
    done
    # 一个时间戳都解析不出来 = 时间窗根本没生效 ⇒ 回落全量并大声告警，
    # 绝不用"条目 0"冒充"最近没缺"（§0: 判据静默失败 ⇒ 错误结论）
    if [ "$n_with" -eq 0 ]; then
      ts_fallback=1
      cutoff=0; within_days=0
      _tryr_log "  ❌ 时间窗未生效: ${#_mk_names[@]} 个 marker 里 0 个取到时间 ⇒ " \
                "**回落全量**（不能用'条目 0'冒充'最近没缺'）。" \
                "（last_success 缺失 + lsl 无 ModTime，多为后端不支持）"
    fi
  fi

  # ---- 阶段二: 按窗筛 + 预演（用的是缓存的 json，不重复下载）----
  for m in "${_mk_names[@]}"; do
    json="${_mk_json[$m]}"
    if [ "$cutoff" -gt 0 ]; then
      scanned=$((scanned + 1))
      mts_epoch="${_mk_epoch[$m]:-}"
      # 取不到时间戳的**按旧的处理还是新的处理**是个取舍 —— 取不到意味着我们无法
      # 证明它新，放进来就等于"时间窗失效"，故跳过并明示（测试锁住）。
      if [ -z "$mts_epoch" ]; then
        skipped_nots=$((skipped_nots + 1)); continue
      fi
      if [ "$mts_epoch" -lt "$cutoff" ]; then
        skipped_old=$((skipped_old + 1)); continue
      fi
    fi
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
  # 跳过数必须明示: 否则"筛完缺失变少了"会被误读成"问题消失了"，实际只是样本变小了
  if [ "$cutoff" -gt 0 ]; then
    # 生效下界要**连时间点一起**写明: "最近 3 天"是相对的，读报告的人无法据此
    # 判断"这批是不是都在某次语义变更之后写的"，而这正是结论可不可比的关键（§15.2）
    _tryr_log "  ⏱️ 时间窗=最近 ${within_days} 天 · 绝对下界 ${since_raw:-（无）}" \
              "（生效下界 $(printf '%(%Y-%m-%d %H:%M:%S)T' "$cutoff") UTC）: " \
              "扫描 marker ${scanned} 个 · 跳过超窗 ${skipped_old} 个 · 跳过无时间戳 ${skipped_nots} 个"
  fi
  if [ "$ts_fallback" -eq 1 ]; then
    # 时间窗没生效这件事本身必须进结论: 否则读者会以为"最近 3 天零缺失"
    _tryr_log "  ❌ 时间窗**未生效**（lsl 取不到 ModTime）⇒ 本次为**全量**预演，" \
              "结论覆盖全部 marker，不可当作'最近 ${TRYRUN_WITHIN_DAYS} 天'的口径"
  fi
  for k in "${!TRYRUN_KIND_COUNT[@]}"; do
    _tryr_log "  ${k}: ${TRYRUN_KIND_COUNT[$k]} 条"
  done
  if [ "$TRYRUN_MISSING" -gt 0 ]; then
    _tryr_log "  ⚠️ 备份缺失清单（真跑会 FAIL: 替代文件可能已不存在）:"
    printf '%s' "$TRYRUN_MISSING_LIST" | while IFS= read -r l; do [ -n "$l" ] && _tryr_log "     - ${l}"; done
  fi
  if [ "$TRYRUN_RECHECK_TOTAL" -gt 0 ]; then
    # 直读复核结论单独成段: 它是"777 到底是真缺还是清单取空"的唯一判据
    _tryr_log "  🔍 直读复核: 对列列举判缺失的 ${TRYRUN_RECHECK_TOTAL} 条逐条 lsjson stat，" \
              "翻案 ${TRYRUN_RECHECK_FLIPPED} 条（列列举判缺、直读判定在 ⇒ 清单取空/滞后，" \
              "以直读为准）"
    if [ "$TRYRUN_RECHECK_FLIPPED" -gt 0 ]; then
      printf '%s' "$TRYRUN_FLIPPED_LIST" | while IFS= read -r l; do [ -n "$l" ] && _tryr_log "     ↳ 实为存在: ${l}"; done
    fi
  fi
  # 原路径侧的复核**单独成行**（不与备份侧合并计数）: 两者判的是不同的东西
  #   （备份在不在 / 落点是否已占），混成一个数就无法判断"哪一侧的列表不可信"
  if [ "$TRYRUN_ORIG_RECHECK_TOTAL" -gt 0 ]; then
    _tryr_log "  🔍 直读复核（原路径）: 对列列举判不存在的 ${TRYRUN_ORIG_RECHECK_TOTAL} 条逐条 lsjson stat，" \
              "翻案 ${TRYRUN_ORIG_FLIPPED} 条（翻案 ⇒ 原路径其实已被占，真跑前须先处理）"
  fi
  # ---- 缺失目录的结构探针（只读，2026-09-20 V5 驱动）----
  # 为什么需要它: "备份文件不在"有两种截然不同的成因，只报"缺失"分不开 ——
  #   (a) 短哈希目录本身没建成（替代路径的父目录都没出现 ⇒ 修复根本没落盘）；
  #   (b) 目录建成了、但文件没进去（或进去又被清 ⇒ 与后端落盘/清理有关）。
  # 判法: 对缺失目录的**父目录**做一次 lsd（只读，已在白名单内），把真实子目录名
  #   打出来 —— 期望的替代目录名（如 6c73a635）在不在里面，一眼可判。
  # 成本: 每个去重后的父目录 1 次远端调用，与逐条 stat 相比可忽略。
  if [ -n "$TRYRUN_MISSING_DIRS" ]; then
    _tryr_log "  🗂️ 缺失目录结构探针（只读 lsd，看替代目录到底建没建）:"
    printf '%s' "$TRYRUN_MISSING_DIRS" | sort -u | while IFS= read -r md; do
      [ -z "$md" ] && continue
      parent="${md%/*}"; [ "$parent" = "$md" ] && parent="$md"
      want="${md##*/}"
      # 用 lsf --dirs-only（每行一个目录名）而不是 lsd: lsd 的输出是"多列 + 名字在
      # 末列"，目录名带空格时 $NF 只取得到最后一段（这里的目录名正是中文短名，必须整取）
      subs=$(_tryr_rclone_read lsf "$parent" --dirs-only --retries 1 --timeout 2m 2>/dev/null \
             | sed 's#/$##' | tr '\n' ' ')
      # 源端同层形状对照（V5 矛盾驱动）: fix-check 曾报"源 529 / 目标 529 / 差集 0"，
      #   与本探针"目标端没有蓝白碗"看着冲突。差集 0 只要求**相对路径字符串**相同，
      #   不说明形状 ⇒ 把源端同层子目录一并打出，两侧形状是否一致才能一眼看清。
      #   映射用的是"替代目录 → 源端同层"表（逐 marker 循环里记，见 _tryr_plan_one）
      ssubs=""
      sp="${_TRYR_SRC_OF_MDIR[$md]:-}"
      [ -n "$sp" ] && ssubs=$(_tryr_rclone_read lsf "$sp" --dirs-only --retries 1 \
                              --timeout 2m 2>/dev/null | sed 's#/$##' | tr '\n' ' ')
      if [ -z "$subs" ]; then
        _tryr_log "     - ${parent}: （列举无输出/不可读 ⇒ 无法判，需另取判据）"
      else
        local shape="替代目录 ${want} **在**"
        case " $subs " in *" $want "*) ;; *) shape="替代目录 ${want} **不在**" ;; esac
        if [ -n "$ssubs" ]; then
          _tryr_log "     - ${parent}: ${shape}（目标端子目录: ${subs}｜源端同层: ${ssubs}）"
        elif [ -n "$sp" ]; then
          _tryr_log "     - ${parent}: ${shape}（目标端子目录: ${subs}｜源端同层: 列举无输出）"
        else
          _tryr_log "     - ${parent}: ${shape}（子目录: ${subs})"
        fi
        # 目录建成了却判"文件缺失"时，还得看它**里面有什么**（紧随父目录行，成对易读）:
        #   全空 ⇒ 文件压根没落；装着别的文件 ⇒ 落盘了但名字/路径对不上（修法完全不同）
        if [ "${_TRYR_DIR_CACHE[$md]+x}" ]; then
          local inner="${_TRYR_DIR_CACHE[$md]}"
          if [ -z "$inner" ]; then
            _tryr_log "        ↳ ${md}: **空目录**（文件压根没落）"
          else
            _tryr_log "        ↳ ${md}: 非空，内含 $(printf '%s' "$inner" | grep -c .) 个条目" \
                      "⇒ 落盘了但名字对不上: $(printf '%s' "$inner" | head -5 | tr '\n' ' ')"
          fi
        fi
      fi
    done
  fi
  if [ "$TRYRUN_SRC_CHECKED" -gt 0 ]; then
    # Q3 专用段: 备份缺失的这批，"源端还有没有这个原路径"决定 marker 的落点是否失效
    _tryr_log "  🎯 源端原路径核对（Q3: 只核备份缺失的那批）: 核 ${TRYRUN_SRC_CHECKED} 条，" \
              "源端**不在** ${TRYRUN_SRC_MISSING} 条（不在 ⇒ marker 记的落点已失效，" \
              "真跑会把文件还原到一个源端并不存在的路径上）"
    if [ "$TRYRUN_SRC_MISSING" -gt 0 ]; then
      printf '%s' "$TRYRUN_SRC_MISSING_LIST" | sort -u | head -10 | while IFS= read -r l; do
        [ -n "$l" ] && _tryr_log "     - ${l}"
      done
    fi
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
    # 时间窗必须进通知: 不看它，"缺失 30"和"缺失 777"会被当成同一个问题的两种结论，
    # 实际只是样本从 5194 缩到了最近 3 天
    if [ "$cutoff" -gt 0 ]; then
      # 生效下界要连时刻一起给: "最近 3 天"是相对的，看通知的人无法据此判断
      # "这批是不是都在某次语义变更之后写的"，而这正是结论可不可比的关键（§15.2）
      tg_add_kv msg "时间窗" "最近 ${within_days} 天 · 下界 $(printf '%(%Y-%m-%d %H:%M:%S)T' "$cutoff") UTC（跳过超窗 ${skipped_old} 个 marker）"
      [ -n "$since_raw" ] && tg_add_kv msg "绝对下界" "${since_raw}"
    fi
    [ "$ts_fallback" -eq 1 ] && tg_add_kv msg "时间窗" "❌ 未生效（取不到 ModTime）⇒ 回落全量"
    tg_add_kv msg "预演条目" "${total} 个"
    local kinds="" k
    for k in $(printf '%s\n' "${!TRYRUN_KIND_COUNT[@]}" | sort); do
      kinds+="${k} ${TRYRUN_KIND_COUNT[$k]} · "
    done
    [ -n "$kinds" ] && tg_add_kv msg "分类" "${kinds% · }"
    tg_add_kv msg "备份缺失" "${TRYRUN_MISSING} 个"
    [ "$TRYRUN_UNVERIFIED" -gt 0 ] && tg_add_kv msg "存在性未核对" "${TRYRUN_UNVERIFIED} 个"
    if [ "${TRYRUN_CHECK_EXISTS:-1}" = "1" ] && [ "$total" -gt 0 ]; then
      # 核对模式下这几个占比才是"真跑会发生什么"的摘要，比列文件名有用
      tg_add_kv msg "备份在" "${TRYRUN_PRESENT} 个"
      tg_add_kv msg "原路径已存在" "${TRYRUN_ORIG_EXISTS} 个"
    fi
    # ⚠️ 通知**只发摘要**，不列条目清单: 4684 条全塞进去会被切成 97 个分片，
    #   Telegram 限速下光发送就要 5 分钟，把整轮拖过 40 分钟 timeout 被取消
    #   （run 35478771033 实测: 预演本身跑完了，死在发通知上）。
    #   三条完整路径属于"要看再取"的细节 → 交给 artifact（tryrun.tsv）+ run 日志。
    #   条目数只作为一行 kv 呈现，不做树形清单。
    if [ "$TRYRUN_RECHECK_TOTAL" -gt 0 ]; then
      # 直读复核对"备份缺失"这个结论本身定性: 翻案多 ⇒ 列列举不可信，缺失数是虚高
      tg_add_kv msg "直读复核" "${TRYRUN_RECHECK_TOTAL} 条中翻案 ${TRYRUN_RECHECK_FLIPPED} 条"
    fi
    [ "$TRYRUN_ORIG_RECHECK_TOTAL" -gt 0 ] && tg_add_kv msg "直读复核（原路径）" \
      "${TRYRUN_ORIG_RECHECK_TOTAL} 条中翻案 ${TRYRUN_ORIG_FLIPPED} 条"
    [ "$TRYRUN_SRC_CHECKED" -gt 0 ] && tg_add_kv msg "源端原路径（Q3）" \
      "${TRYRUN_SRC_CHECKED} 条中源端不在 ${TRYRUN_SRC_MISSING} 条"
    if [ "$TRYRUN_MISSING" -gt 0 ]; then
      # 缺失清单同样限量（8 条）—— 它才是真跑会 FAIL 的部分，但 777 条全列依旧会爆
      tg_add_section msg "⚠️ 备份缺失 · ${TRYRUN_MISSING}"
      tg_add_block msg "$(tree_fold "$TRYRUN_MISSING_LIST" 8)"
      tg_add_note msg "目标端找不到替代文件，真跑会判 FAIL（条目保留在 marker，不会丢）"
    fi
    tg_add_note msg "三条完整路径（① 备份 / ② marker 原文件 / ③ 实际落点）见 artifact tryrun.tsv 与 run 日志。"
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
TRYRUN_PRESENT=0
TRYRUN_ORIG_EXISTS=0
TRYRUN_UNVERIFIED=0
TRYRUN_MISSING_LIST=""
TRYRUN_UNVERIFIED_DESTS=""
TRYRUN_ENTRY_LIST=""
TRYRUN_RECHECK_TOTAL=0
TRYRUN_RECHECK_FLIPPED=0
TRYRUN_FLIPPED_LIST=""
TRYRUN_ORIG_RECHECK_TOTAL=0
TRYRUN_ORIG_FLIPPED=0
TRYRUN_SRC_CHECKED=0
TRYRUN_SRC_MISSING=0
TRYRUN_SRC_MISSING_LIST=""
