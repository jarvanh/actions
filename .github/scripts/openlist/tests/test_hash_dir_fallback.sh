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
#   缓存、目录切换与黑名单重置、根目录文件跳过、开关、以及还原元数据分类。
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
source "$_REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null
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
    lsf) cat "$DST_FILES_FILE" 2>/dev/null ;;
    mkdir|lsd) return 0 ;;                                # 目录创建/复核恒成功
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
  : > "$DST_FILES_FILE"
  RESTART_CALLS=0
  RESTART_OK=1
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

# ===== 场景5: 目标端根目录的文件无目录可换 → 不切换 =====
reset_state
WRITABLE_DIR=""                  # 全拒
run_fix "options.xml"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "5a 根目录文件修复失败（预期）" || bad "5a: 不该成功"
grep -q "无目录可换" "$FIX_LOG" && ok "5b 根目录文件跳过目录切换" || bad "5b: 未跳过（根目录无目录可换）"
! grep -q "🔀 目录级兜底" "$FIX_LOG" && ok "5c 未创建无谓的短哈希目录" || bad "5c: 根目录文件不该建短哈希目录"

# ===== 场景6: 短哈希目录同样不可写 → 收尾消息准确 =====
reset_state
WRITABLE_DIR=""                  # 全拒
run_fix "$REL"
[ "$TRY_FIX_STATUS" = "failed" ] && ok "6a 短哈希目录也不可写 → 整体失败" || bad "6a: 不该成功"
printf '%s' "$TRY_FIX_MESSAGE" | grep -q "目标目录不可写" && ok "6b 失败原因点明是目录不可写" || bad "6b: msg=${TRY_FIX_MESSAGE}"
grep -q "短哈希目录同样不可写" "$FIX_LOG" && ok "6c 日志记录切换后仍不可写" || bad "6c: 无对应日志"

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

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
