#!/bin/bash
# 目录可写性预检 + 短哈希目录兜底 —— 逻辑验证
#
# 背景: 4 种文件修复方法原本全在"Step 1 定下的那一个目录"里轮换，而 Step 1 的
#   base64URL 编码目录只在"目录创建失败"时降级。目录已存在（同目录其余文件
#   都同步成功）但写入被拒时 mkdir/lsd 双双返回 0 → used_base64_dir=0，
#   于是没有任何一条路径会换目录: 目录名过长 / 敏感词 / 整条加密路径超后端
#   上限这类根因永远无法自愈，且每个顽固文件都要在同一条死路上白付一遍
#   "整文件下载 + 4 次上传/打包"的代价（backup 的 options.xml 即此形态）。
#
# 两段式应对:
#   1. 预检（_fix_probe_dir_writable）: 跑方法之前先用几字节探针给目录定性。
#      判据只能是"重启容器后探针仍可见"——PUT 假成功在缓存里与真文件无异
#      （run 31951008332 实锤），缓存口径的"看得到"和"看不到"都不作数：
#      目录本身若是假成功创建的，重启后连目录带探针一起消失。
#   2. 切换（_fix_switch_to_hash_dir）: 判定不可写 → 折叠成 8 位 md5 短哈希
#      目录，连整文件下载都省掉；预检通过但 4 方法仍全败时再兜底切一次。
#
# 本测试覆盖: 预检先于下载、重启后真值口径定论、假成功目录、重启预算与结论
#   缓存、目录切换与黑名单重置、**根目录文件折叠到「根下短哈希子目录」**（2026-09-16
#   放开，此前是直接放弃）、开关、以及还原元数据分类。
set -u
# 探针可见性重试只留 1 次: 本测试没有 _ol_refresh_path_cache（openlist_driver.sh
# 未 source），兜底等待会把十余个"不可写目录"场景各拖慢数秒 → 套件从秒级变分钟级
OPENLIST_PROBE_READ_RETRY=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null
# 排版助手 + 发送层的唯一真源（openlist 侧已不再自带副本，2026-09-06 收敛）
source "$_REPO_ROOT/.github/scripts/telegram/tg_notify.sh"
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null

WORK="/tmp/hashdir_test_dir"
rm -rf "$WORK"; mkdir -p "$WORK"
# try_fix_failed_file 用相对路径建临时目录，必须切进临时目录避免污染工作区
cd "$WORK"
trap 'cd / && rm -rf "$WORK"' EXIT

# --- mocks ---
# macOS 无 md5sum（md5 -q 等价），补一个让测试跨平台可跑
if ! command -v md5sum >/dev/null 2>&1; then
  md5sum() { md5 -q "$1"; }
fi
_get_openlist_token() { echo fake-token; }
jq() { echo '{}'; }
7z() { :; }                       # 不分卷: 让方法3/4 自然失败，聚焦目录问题
_rebuild_raw_baseline() { return 0; }   # 预检重启后的基准重建（被测代码会调）

DEST="openlist:wopan176Crypt/backup"
REL_DIR="Emby Backup - 2021-11-18 08.40.36 - Auto/library/gd - j - 社交"
REL="${REL_DIR}/options.xml"
HASH=$(printf '%s' "$REL_DIR" | md5sum | cut -c1-8)

# 目标端可写目录白名单（真成功写入）
WRITABLE_DIR=""
# 假成功: 写入返回 0 且缓存里可见，但重启后随缓存一起消失
FAKE_WRITE=0
# 只有探针能写进的目录（模拟"目录能落几字节，写不进真实文件"）
PROBE_ONLY=0
# 目标端文件清单用文件维护: 被测代码的 rclone 调用全在管道里（... | _cmd_log），
# 跑在子 shell，shell 变量累加不会写回父 shell
DST_FILES_FILE="$WORK/dst_files.txt"
: > "$DST_FILES_FILE"
# mkdir 目标记录（场景5 断言"根目录折叠"落点用）
MKDIR_LOG="$WORK/mkdir_targets.txt"
: > "$MKDIR_LOG"
LSF_COUNT_FILE="$WORK/lsf_calls.count"
: > "$LSF_COUNT_FILE"
LSF_HIDE_FIRST=0                 # 前 N 次 lsf 读空（列表缓存延迟模拟）
RESTART_CALLS=0
RESTART_OK=1
CLEAR_ON_RESTART=0               # 下一次重启时清掉清单（模拟假成功条目消失）

rclone() {
  case "$1" in
    copyto)
      local dst="$3" bn
      bn="$(basename "$dst")"
      case "$dst" in
        openlist:*)
          if [ -n "$WRITABLE_DIR" ] && [[ "$dst" == *"/${WRITABLE_DIR}/"* ]]; then
            printf '%s\n' "$bn" >> "$DST_FILES_FILE"      # 真成功
            return 0
          fi
          if [ "$PROBE_ONLY" = "1" ] && [[ "$bn" == olprobe_* ]]; then
            printf '%s\n' "$bn" >> "$DST_FILES_FILE"      # 探针可写，文件不可写
            return 0
          fi
          if [ "$FAKE_WRITE" = "1" ]; then
            printf '%s\n' "$bn" >> "$DST_FILES_FILE"      # 假成功（重启后消失）
            return 0
          fi
          return 1 ;;
        *) : > "$dst"; return 0 ;;                        # 下载到本地
      esac ;;
    deletefile)
      grep -vxF "$(basename "$3")" "$DST_FILES_FILE" > "${DST_FILES_FILE}.tmp" 2>/dev/null || true
      mv "${DST_FILES_FILE}.tmp" "$DST_FILES_FILE" 2>/dev/null || true
      return 0 ;;
    lsf)
      # LSF_HIDE_FIRST>0: 前 N 次 lsf 读空（模拟 OpenList 对新建目录的列表缓存延迟）。
      # 计数必须落文件: rclone 调用大多在管道里（| grep），子 shell 变量累加不回写。
      if [ "${LSF_HIDE_FIRST:-0}" -gt 0 ]; then
        local _c
        _c=$(cat "$LSF_COUNT_FILE" 2>/dev/null || echo 0)
        _c=$((_c + 1))
        echo "$_c" > "$LSF_COUNT_FILE"
        [ "$_c" -le "$LSF_HIDE_FIRST" ] && return 0
      fi
      cat "$DST_FILES_FILE" 2>/dev/null ;;
    mkdir)
      printf '%s\n' "$2" >> "$MKDIR_LOG"                  # 记录目标: 断言折叠目录的落点
      return 0 ;;
    lsd) return 0 ;;                                      # 目录创建/复核恒成功
    *) return 0 ;;
  esac
}
_restart_openlist_for_truth() {
  RESTART_CALLS=$((RESTART_CALLS + 1))
  if [ "$CLEAR_ON_RESTART" = "1" ]; then
    : > "$DST_FILES_FILE"        # 假成功条目只存在于缓存，重启即消失
    CLEAR_ON_RESTART=0
  fi
  [ "$RESTART_OK" = "1" ]
  return $?
}

FIX_LOG="$WORK/fix.log"

reset_state() {
  FIX_METHOD_BLACKLIST=()
  _DIR_WRITE_CACHE=()
  _DIR_PROBE_RESTARTS=0
  # 后端级熔断状态（每个用例模拟的是"一个健康的后端"，不清会跨用例累积：
  # 前面几个用例故意造的不可写目录会把后端判死，后续用例直接短路）
  _BACKEND_DEAD=()
  _BACKEND_DIR_FAIL_STREAK=()
  # 名长解耦标记（_FIX_NAMELEN_CONTENT）: 不清会跨用例泄漏，把普通失败误当
  # 内容性失败而不计入熔断
  _FIX_NAMELEN_CONTENT=0
  : > "$DST_FILES_FILE"
  : > "$MKDIR_LOG"
  RESTART_CALLS=0
  RESTART_OK=1
  : > "$LSF_COUNT_FILE"
  LSF_HIDE_FIRST=0
  WRITABLE_DIR=""
  FAKE_WRITE=0
  PROBE_ONLY=0
  CLEAR_ON_RESTART=0
}
run_fix() {
  : > "$FIX_LOG"
  try_fix_failed_file "onedrive:backup" "$DEST" "t" "$1" "$FIX_LOG" >/dev/null 2>&1
}

# ===== 场景1: 原目录不可写 → 重启后真值口径定论 → 切短哈希目录成功 =====
reset_state
WRITABLE_DIR="$HASH"
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "success" ] && ok "1a 目录兜底生效，修复成功" || bad "1a: status=${TRY_FIX_STATUS} msg=${TRY_FIX_MESSAGE}"
[ "$TRY_FIX_ALTERNATIVE" = "${HASH}/options.xml" ] && ok "1b 替代路径落在短哈希目录" || bad "1b: alt=${TRY_FIX_ALTERNATIVE}"
printf '%s' "$TRY_FIX_METHOD" | grep -qF "短哈希目录 ${HASH}" && ok "1c 方法文本标注短哈希目录" || bad "1c: method=${TRY_FIX_METHOD}"
printf '%s' "$TRY_FIX_RESTORE" | grep -qF "${REL}" && ok "1d 还原说明含原路径（哈希不可逆，只能靠它归位）" || bad "1d: restore=${TRY_FIX_RESTORE}"
# 原目录一次 + 短哈希目录一次: 两个目录的结论都要重启后才算数
[ "$RESTART_CALLS" -eq 2 ] && ok "1e 两个目录各重启复核 1 次" || bad "1e: 重启 ${RESTART_CALLS} 次"
grep -q "已重启确认" "$FIX_LOG" && ok "1f 结论标注已重启确认" || bad "1f: 结论未经重启确认"
grep -q "跳过原目录的 4 种方法" "$FIX_LOG" && ok "1g 原目录未白跑 4 种方法" || bad "1g: 未在预检阶段切换"
# 预检必须先于下载，否则"省掉整文件下载"的收益不存在
P_LINE=$(grep -n "预检目录可写性" "$FIX_LOG" | head -1 | cut -d: -f1)
D_LINE=$(grep -n "下载源文件" "$FIX_LOG" | head -1 | cut -d: -f1)
[ -n "$P_LINE" ] && [ -n "$D_LINE" ] && [ "$P_LINE" -lt "$D_LINE" ] \
  && ok "1h 预检先于下载（目录定性后才付下载代价）" || bad "1h: probe@${P_LINE:-无} download@${D_LINE:-无}"

# ===== 场景2: 假成功目录 —— 缓存口径看得到，重启后消失 → 必须判不可写 =====
# 这一条是"lsf 复核不可靠"的直接回归: 光看 lsf 会误判为可写，只有重启后
# 的可见性才能暴露"目录本身是假成功创建的"
reset_state
WRITABLE_DIR="$HASH"
FAKE_WRITE=1
CLEAR_ON_RESTART=1
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "success" ] && ok "2a 假成功目录被识别并绕开，修复成功" || bad "2a: status=${TRY_FIX_STATUS} msg=${TRY_FIX_MESSAGE}"
[ "$TRY_FIX_ALTERNATIVE" = "${HASH}/options.xml" ] && ok "2b 落点确实是短哈希目录（未误判原目录可写）" || bad "2b: alt=${TRY_FIX_ALTERNATIVE}"
grep -q "重启后探针消失" "$FIX_LOG" && ok "2c 日志记录重启后探针消失" || bad "2c: 未识别假成功（缓存口径误判为可写）"

# ===== 场景3: 方法全部拉黑 → 换目录后黑名单必须清空 =====
reset_state
WRITABLE_DIR="$HASH"
FIX_METHOD_BLACKLIST["$REL"]="$(
  for m in copyto_original copyto_shorthash zip_split_original zip_split_shorthash; do
    _fix_method_desc "$m"
  done | paste -sd'|' -
)"
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "success" ] && ok "3a 全方法拉黑后目录兜底仍能成功（黑名单已重置）" || bad "3a: 黑名单未清空，兜底被门禁跳过"
grep -q "清空方法黑名单" "$FIX_LOG" && ok "3b 日志记录黑名单清空" || bad "3b: 无清空日志"

# ===== 场景4: 探针能写但真实文件写不进 → 预检判可写，4 方法全败后 Step 5 兜底 =====
# 验证预检的职责边界: 它证明"目录写得进探针"，证明不了"这个文件写得进"
reset_state
WRITABLE_DIR="$HASH"
PROBE_ONLY=1
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "success" ] && ok "4a 预检通过但方法全败 → Step 5 兜底成功" || bad "4a: status=${TRY_FIX_STATUS}"
grep -q "预检目录可写性" "$FIX_LOG" && ok "4b 原目录预检判为可写（探针确实落盘）" || bad "4b: 未走预检"
grep -q "兜底换短哈希目录" "$FIX_LOG" && ok "4c 走了 Step 5 兜底入口（预检通过 ≠ 文件能落盘）" || bad "4c: 未走兜底入口"

# ===== 场景5: 目标端根目录的文件 → 折叠到「根目录下的短哈希子目录」 =====
# 2026-09-16 放开: 此前该情形直接 early return（"无目录可换"），使这类文件只有
#   4 次尝试、且**全在同一路径上**（只换名字/形式、路径不变）—— 若根因在路径本身
#   就数学上必然修不好。实测 run 34959561878 一轮里「无目录可换」150 次记录
#   （失败清单 100 条纯此项 + 50 条「目标目录不可写…无目录可换」），而该轮修复
#   成功 29 / 失败 49 ⇒ 它是**修复失败的主导原因**。根目录无目录名可折，故改为
#   在**目标端根目录下新建**短哈希子目录（dest_path/<hash8>/）。
HASH_ROOT=$(printf '%s' "." | md5sum | cut -c1-8)
reset_state
WRITABLE_DIR=""                  # 全拒: 折叠后仍写不进
run_fix "options.xml"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "5a 根目录文件在全拒时仍失败（预期）" || bad "5a: 不该成功"
grep -qF "目标端根目录折叠为短哈希目录 ${HASH_ROOT}" "$FIX_LOG" \
  && ok "5b 根目录文件也会尝试折叠（不再 early return）" || bad "5b: 未尝试折叠"
grep -qxF "${DEST}/${HASH_ROOT}" "$MKDIR_LOG" \
  && ok "5c 折叠目录建在目标端根下（dest_path/<hash8>）" || bad "5c: mkdir 目标=[$(tr '\n' ' ' < "$MKDIR_LOG")]"
! printf '%s' "$TRY_FIX_MESSAGE" | grep -q "无目录可换" \
  && ok "5d 失败原因不再谎报「无目录可换」（该分支已不存在）" || bad "5d: msg=${TRY_FIX_MESSAGE}"

# 5e~5g: 根下短哈希子目录可写 → 折叠成功，且替代路径与子目录折叠同构
#   （同构是关键: 防删除的 --filter-from 用 `- /<alternative>`，根目录情形天然被覆盖）
reset_state
WRITABLE_DIR="$HASH_ROOT"
run_fix "options.xml"
[ "$TRY_FIX_STATUS" = "success" ] && ok "5e 根目录文件折叠后修复成功" || bad "5e: status=${TRY_FIX_STATUS} msg=${TRY_FIX_MESSAGE}"
[ "$TRY_FIX_ALTERNATIVE" = "${HASH_ROOT}/options.xml" ] \
  && ok "5f 替代路径为 <hash8>/<文件名>（相对 dest_path，与子目录折叠同构）" \
  || bad "5f: alt=${TRY_FIX_ALTERNATIVE}"
printf '%s' "$TRY_FIX_RESTORE" | grep -qF "options.xml" \
  && ok "5g 还原说明含原文件名（哈希不可逆，只能靠它归位）" || bad "5g: restore=${TRY_FIX_RESTORE}"
# 5h: 根目录折叠的哈希源是常量 "." ⇒ 与任何真实子目录名的折叠值无关
[ "$HASH_ROOT" != "$HASH" ] && ok "5h 根目录哈希与子目录哈希不同（不会互相撞车）" || bad "5h: 撞车"

# 5i~5k: **Step 5 兜底那道闸**也必须对根目录放开（与内层闸是同一次改动的两半）
#   原代码在 Step 5 的进入条件里也有 `file_dir_rel != "." && -n` —— 重复且**静默跳过**
#   （连日志都没有），于是根目录文件"4 方法全败"后根本不会试换路径，日志只留一句
#   聚合文案「全部修复方法（1-4）均失败（含短哈希目录兜底）」= 文案与事实相反。
#   实测 run 34940234180 的 5 个顽固文件（子任务根目录、.mp4、200–250MB）全因此
#   从未试过"换路径"这一维。
#   构造: 预检判**可写**（PROBE_ONLY=1 让探针能写）⇒ 不进 Step 2 切换；
#   4 方法全败（真实文件写不进原目录）⇒ 必须由 Step 5 折叠到根下短哈希目录后成功。
reset_state
WRITABLE_DIR="$HASH_ROOT"        # 只有"根下短哈希目录"能真正写进文件
PROBE_ONLY=1                     # 原目录探针可写 ⇒ 预检判可写，Step 2 不切换
run_fix "options.xml"
[ "$TRY_FIX_STATUS" = "success" ] && ok "5i 根目录文件经 Step 5 兜底换目录后成功" || bad "5i: status=${TRY_FIX_STATUS} msg=${TRY_FIX_MESSAGE}"
grep -q "4 种方法全败，兜底换短哈希目录再试一轮" "$FIX_LOG" \
  && ok "5j Step 5 兜底对根目录文件已放开（不再静默跳过）" || bad "5j: 未走 Step 5 兜底"
[ "$TRY_FIX_ALTERNATIVE" = "${HASH_ROOT}/options.xml" ] \
  && ok "5k 兜底后的替代路径仍是 <hash8>/<文件名>" || bad "5k: alt=${TRY_FIX_ALTERNATIVE}"

# ===== 场景6: 短哈希目录同样不可写 → 收尾消息准确 =====
reset_state
WRITABLE_DIR=""                  # 全拒
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "6a 短哈希目录也不可写 → 整体失败" || bad "6a: 不该成功"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "目标目录不可写" && ok "6b 失败原因点明是目录不可写" || bad "6b: msg=${TRY_FIX_MESSAGE}"
grep -q "无法换目录（备用目录也写不进去）" "$FIX_LOG" && ok "6c 日志记录切换后仍不可写" || bad "6c: 无对应日志"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "备用目录也写不进去" \
  && ok "6d 失败原因点明备用目录也写不进去" || bad "6d: msg=${TRY_FIX_MESSAGE}"
# 判定依据要如实（本场景真的重启复核过），不能再是笼统的"未通过可写性预检"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "已复核确认写不进去" \
  && ok "6e 失败原因带真实判定依据" || bad "6e: msg=${TRY_FIX_MESSAGE}"
! printf '%s' "$TRY_FIX_MESSAGE" | grep -qE "熔断|探测|短哈希|哈希目录|base64|rc=|HTTP_CODE" \
  && ok "6f 失败原因不含内部术语（说人话）" || bad "6f: msg=${TRY_FIX_MESSAGE}"

# ===== 场景7: 开关 OPENLIST_HASH_DIR_FALLBACK=0 → 关闭切换 =====
reset_state
WRITABLE_DIR="$HASH"
OPENLIST_HASH_DIR_FALLBACK=0 run_fix "$REL"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "7a 开关关闭 → 不切换（原目录不可写则失败）" || bad "7a: 开关未生效"
! grep -q "🔀 目录级兜底" "$FIX_LOG" && ok "7b 开关关闭时无切换日志" || bad "7b: 开关关闭仍触发切换"
unset OPENLIST_HASH_DIR_FALLBACK

# ===== 场景8: 容器不可重启 → 退回缓存口径，并标注结论不可信 =====
reset_state
WRITABLE_DIR="$HASH"
RESTART_OK=0
run_fix "$REL"
[ "$RESTART_CALLS" -eq 2 ] && ok "8a 两个目录各尝试重启 1 次且均失败" || bad "8a: 重启尝试 ${RESTART_CALLS} 次"
grep -q "容器重启不可用" "$FIX_LOG" && ok "8b 日志记录退回缓存口径" || bad "8b: 无对应日志"
grep -q "未经重启确认" "$FIX_LOG" && ok "8c 结论标注未经重启确认（避免把缓存口径当真值）" || bad "8c: 未标注不可信"
[ "$TRY_FIX_STATUS" = "success" ] && ok "8d 不可判定时不误伤（仍能修复）" || bad "8d: status=${TRY_FIX_STATUS}"

# ===== 场景9: 重启预算耗尽 → 不再重启 =====
reset_state
WRITABLE_DIR="$HASH"
OPENLIST_DIR_PROBE_MAX_RESTART=0 run_fix "$REL"
[ "$RESTART_CALLS" -eq 0 ] && ok "9a 预算为 0 → 不重启" || bad "9a: 重启 ${RESTART_CALLS} 次"
grep -q "重启预算已耗尽" "$FIX_LOG" && ok "9b 日志记录预算耗尽" || bad "9b: 无预算日志"
[ "$TRY_FIX_STATUS" = "success" ] && ok "9c 预算耗尽不误伤（仍能修复）" || bad "9c: status=${TRY_FIX_STATUS}"
unset OPENLIST_DIR_PROBE_MAX_RESTART

# ===== 场景10: 目录结论缓存 —— 同一目录不再重复探测/重启 =====
reset_state
WRITABLE_DIR="$HASH"
run_fix "$REL"
C1=$RESTART_CALLS
run_fix "${REL_DIR}/other.xml"          # 同一目录的另一个文件
[ "$RESTART_CALLS" -eq "$C1" ] && ok "10a 同目录第二个文件未再触发重启（缓存命中）" || bad "10a: 重启 ${C1} → ${RESTART_CALLS}"
grep -q "沿用本轮结论" "$FIX_LOG" && ok "10b 日志记录沿用结论" || bad "10b: 无缓存命中日志"

# ===== 场景11: restore_info.jq 把短哈希目录条目正确分类 =====
# mock 的 jq 不够用，这里需要真 jq 跑分类程序；环境无 jq 则跳过
if [ -n "$(type -P jq 2>/dev/null)" ]; then
  unset -f jq
  printf '%s\n' "${REL}|${HASH}/options.xml|rclone copyto（短哈希目录 ${HASH} + 原文件名）|rclone move x y|2.796 KiB|2863|copyto_original|0123456789abcdef0123456789abcdef" > "$WORK/fix_list.txt"
  KIND=$(jq -R -s --arg sp "onedrive:backup" --arg dp "$DEST" -f \
    "$_REPO_ROOT/.github/scripts/openlist/restore_info.jq" "$WORK/fix_list.txt" 2>/dev/null \
    | jq -r '.[0].restore.kind' 2>/dev/null)
  [ "$KIND" = "hash_dir" ] && ok "11a restore_info.jq 分类为 hash_dir" || bad "11a: kind=${KIND:-空}"
else
  echo "SKIP: 11a restore_info.jq 分类（环境无 jq）"
fi

# ===== 场景12: 后端级写熔断 → 不探测、不重启，且文案不得谎报 =====
# 熔断（_BACKEND_DEAD）是"同一挂载根连续 N 个目录不可写"后的短路：直接判不可写，
# 省掉探测与容器重启。此时下游结论文案若还写「已重启容器复核」，就与上一行日志
# 自相矛盾——线上通知里实锤过（2026-09-12 用户反馈的 Hayley Williams 任务）。
# 根目录文件 + 熔断 = 线上那条通知的完整形态: 原目录没探、短哈希目录也没得换。
reset_state
_BACKEND_DEAD["openlist:wopan176Crypt"]=1
WRITABLE_DIR="$HASH"                 # 熔断下根本不会探，写成可写也不该被采信
run_fix "options.xml"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "12a 熔断下直接失败（未白跑 4 种方法）" || bad "12a: status=${TRY_FIX_STATUS}"
[ "$RESTART_CALLS" -eq 0 ] && ok "12b 熔断不触发容器重启" || bad "12b: 重启 ${RESTART_CALLS} 次"
grep -q "本轮已熔断，直接判不可写: 不探测、不重启" "$FIX_LOG" \
  && ok "12c 日志说明熔断短路" || bad "12c: 无熔断日志"
! grep -q "已重启容器复核" "$FIX_LOG" \
  && ok "12d 不再谎报「已重启容器复核」" || bad "12d: 未重启却写已重启复核"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "存储端本轮整体故障，未试写" \
  && ok "12e 失败原因点明存储端整体故障未试写" || bad "12e: msg=${TRY_FIX_MESSAGE}"
# 12f: 2026-09-16 起**根目录文件也会真去试备用目录** ⇒ 熔断下的文案是
#   "备用目录也写不进去"（与子目录文件完全同口径）；"无目录可换"这一支已随
#   根目录折叠放开而消失（原先根目录文件在这里是"没探过就说不能换"）
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "备用目录也写不进去" \
  && ok "12f 失败原因点明备用目录也写不进去（与子目录同口径）" || bad "12f: msg=${TRY_FIX_MESSAGE}"
! printf '%s' "$TRY_FIX_MESSAGE" | grep -q "均未通过可写性预检" \
  && ok "12g 失败原因不再笼统归为「均未通过可写性预检」" || bad "12g: msg=${TRY_FIX_MESSAGE}"
# 规范 · 说人话: 通知里的失败原因不得出现内部机制术语（日志里可以有）。
# 注意"编码目录"/"已复核确认"是规范认可的人话译法，不算术语
! printf '%s' "$TRY_FIX_MESSAGE" | grep -qE "熔断|探测|短哈希|哈希目录|base64|rc=|HTTP_CODE" \
  && ok "12j 失败原因不含内部术语（说人话）" || bad "12j: msg=${TRY_FIX_MESSAGE}"

# 同后端、非根目录文件: 短哈希目录照建，但其探测同样被熔断短路 → 原因要分得清
reset_state
_BACKEND_DEAD["openlist:wopan176Crypt"]=1
WRITABLE_DIR="$HASH"
run_fix "$REL"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "存储端本轮整体故障，未试写；备用目录也写不进去" \
  && ok "12h 换过目录时原因同时点明两段" || bad "12h: msg=${TRY_FIX_MESSAGE}"
[ "$RESTART_CALLS" -eq 0 ] && ok "12i 换目录后仍未重启" || bad "12i: 重启 ${RESTART_CALLS} 次"

# ===== 场景13: 名长类内容性失败与后端级熔断解耦（F3）=====
# 名长诊断命中"密文名 > 后端已接受最长"时修复管线置 _FIX_NAMELEN_CONTENT=1:
# 这类失败的根因是名字太长，不是后端不收——
#   1) 不短路: 短哈希目录仍要探测（能证明"后端死"的只有"短名也写不进"）
#   2) 不计数: 不进连续失败计数，否则一批超名文件就能把健康后端判死，
#      判死后连短哈希兜底都走不了（run 34752801560: 熔断后短哈希目录全部
#      "未试写"，整轮新落盘 0）
reset_state
_BACKEND_DIR_FAIL_STREAK["openlist:wopan176Crypt"]=2   # 差 1 个到阈值 3
_FIX_NAMELEN_CONTENT=1
run_fix "$REL"
[ -z "${_BACKEND_DEAD[openlist:wopan176Crypt]:-}" ] \
  && ok "13a 名长类失败不计数 → 不判后端死（计数停在 2）" || bad "13a: 后端被超名文件判死"
grep -q "名长类内容性失败，不计入后端熔断连续计数" "$FIX_LOG" \
  && ok "13b 日志记录解耦依据" || bad "13b: 无解耦日志"
[ "$RESTART_CALLS" -ge 1 ] && ok "13c 仍正常探测（未被熔断短路）" || bad "13c: 重启 ${RESTART_CALLS} 次"

# 反例: 同样形态但不带名长标记 → 照常计数并判死（解耦只针对名长类）
reset_state
_BACKEND_DIR_FAIL_STREAK["openlist:wopan176Crypt"]=2
run_fix "$REL"
[ "${_BACKEND_DEAD[openlist:wopan176Crypt]:-0}" = "1" ] \
  && ok "13d 非名长类失败仍照常判死（解耦未泛化）" || bad "13d: 熔断被误关"

# ===== 场景14: 探针可见性读空 → 刷缓存重读（一次读空不得判"不可写"）=====
# OpenList 对新建目录的列表有缓存延迟: 折叠/探针刚写完立刻 lsf 会读空。
# 实测反证（2026-09-14）: run 34779382573 里报"批量折叠零落盘（rc=0）"的短哈希目录
# 5b32587f，事后读到 **18 个文件且可写** —— 折叠其实落盘了，是校验读早了。
reset_state
OPENLIST_PROBE_READ_RETRY=3
printf 'target.txt\n' > "$DST_FILES_FILE"
LSF_HIDE_FIRST=1                       # 第 1 次 lsf 读空，第 2 次可见
_ol_refresh_path_cache() { echo refresh >> "$WORK/refresh_calls"; }
: > "$WORK/refresh_calls"
if _probe_file_visible "openlist:wopan175Crypt/0" "target.txt"; then
  ok "14a 读空→刷缓存重读→第 2 次可见即判可写"
else
  bad "14a 一次读空就被判不可见（假阴性）"
fi
[ "$(grep -c refresh "$WORK/refresh_calls" 2>/dev/null || echo 0)" = "1" ] \
  && ok "14b 读空时确实刷了一次服务端缓存" || bad "14b: 刷缓存 $(grep -c refresh "$WORK/refresh_calls" 2>/dev/null || echo 0) 次"
# 反例: 始终读不到 → 仍须判不可见（重试不能变成"总能通过"）
reset_state
OPENLIST_PROBE_READ_RETRY=3
: > "$DST_FILES_FILE"
unset -f _ol_refresh_path_cache 2>/dev/null || true
if _probe_file_visible "openlist:wopan175Crypt/0" "target.txt"; then
  bad "14c 始终不可见却判可写"
else
  ok "14c 重试后仍不可见 → 判不可见"
fi
OPENLIST_PROBE_READ_RETRY=1

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
