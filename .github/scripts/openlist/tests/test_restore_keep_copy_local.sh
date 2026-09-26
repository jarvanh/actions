#!/bin/bash
# 一键还原 —— 本机**真文件操作**隔离测试（备份副本保留 / 出账规则 / 原路径已存在）
#
# 为什么单独开这一套:
#   2026-09-26 用户拍板三项语义变更，全都是"会不会动到数据"的性质，mock 测不出来:
#     ① 还原从 moveto 改 copyto —— **备份副本必须保留**（原实现搬走即删副本，
#        导致下轮预演把"已还原"误判成"备份缺失"）
#     ② 已失效条目自动出账 —— **源端在才出账**；两端皆空保留并告警（出账=抹掉唯一线索）
#     ③ 原路径已存在 —— **同名且同大小才判已还原**；大小不符 SKIP，一个字节都不动
#   ①②③ 都要求真的"把文件放过去/不放过去"，纯 mock 只锁分支不锁落点 ⇒ 本测试用
#   **真文件系统**当远端（rclone shim 映射到沙箱目录，copyto 真的 cp 文件），
#   断言的是磁盘上的实际结果与文件内容。
#
# ⚠️ 安全约束（用户硬约束: 绝对不碰源端任务文件）:
#   - 全程 mktemp -d 沙箱，远端前缀 openlist:/onedrive: 一律映射到沙箱子目录
#   - **只碰本地沙箱路径**: shim 对任何非沙箱路径直接 return 1（见 _in_sandbox 护栏）
#   - 造一个"源端"目录，**跑完全测后逐字节比对 md5 清单**，任何变化直接 FAIL
#   - 结束 trap 清理
#
# 用法: bash test_restore_keep_copy_local.sh   （需 jq；无 rclone 二进制亦可，
#       本测试自带 shim，真文件操作由 shim 落到沙箱文件系统）
set -u
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: 无 jq，整件跳过"
  exit 0
fi

# 排版助手 + 依赖（file_restore.sh 依赖 utils/telegram/sync_marker/rclone_flags）
source "$REPO_ROOT/.github/scripts/telegram/tg_notify.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/sync_marker.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/file_restore.sh"
: "${RCLONE_RETRY_FLAGS:=()}"
if [ "${#RCLONE_RETRY_FLAGS[@]}" -eq 0 ]; then
  RCLONE_RETRY_FLAGS=(--retries 3 --low-level-retries 5 --contimeout 30s)
fi

SANDBOX="$(mktemp -d /tmp/restore_keepcopy_XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# 沙箱布局: 远端前缀 → 本地目录（真文件系统）
SRC_SIM="$SANDBOX/src_sim"     # 源端模拟（只读护栏对象）
DST_SIM="$SANDBOX/dst_sim"     # 目标端模拟
STATE="$SANDBOX/state"         # SYNC_STATE_DIR
mkdir -p "$SRC_SIM" "$DST_SIM" "$STATE"

# ────────────────────────────────────────────────────────────
# rclone shim: 真文件操作，但只在沙箱内
# ────────────────────────────────────────────────────────────
# 护栏: **先规范化再判前缀**（防 `..` 逃逸）。
#   ⚠️ 不能只做字符串前缀匹配: `openlist:/../../../etc` 拼接后仍是
#   "$SANDBOX/..." 前缀，能骗过裸前缀判断 ⇒ 护栏形同虚设（场景 7b 抓的就是这个）。
_in_sandbox() {
  local rp
  rp=$(realpath -m "$1" 2>/dev/null) || return 1
  [ -n "$rp" ] || return 1
  case "$rp" in
    "$SANDBOX"/*|"$SANDBOX") return 0 ;;
    *) return 1 ;;
  esac
}

# 远端前缀 → 沙箱路径映射
_map_path() {
  local p="$1"
  case "$p" in
    openlist:*) echo "$DST_SIM/${p#openlist:}" ;;
    onedrive:*) echo "$SRC_SIM/${p#onedrive:}" ;;
    *)         echo "$p" ;;
  esac
}

rclone() {
  local sub="$1"
  # 位置参数中提取路径与末位目标（rclone 的形态: <sub> <src> <dst> [flags...]）
  case "$sub" in
    lsf)
      local p; p=$(_map_path "$2")
      _in_sandbox "$p" || return 1
      [ -d "$p" ] || return 1
      (cd "$p" && find . -maxdepth 1 -type f -printf '%f\n' | sort)
      ;;
    lsjson)
      local p; p=$(_map_path "$2")
      _in_sandbox "$p" || return 1
      if [ -f "$p" ]; then
        local sz; sz=$(wc -c <"$p" | tr -d ' ')
        printf '[{"Path":"%s","Size":%s,"IsDir":false}]\n' "${p##*/}" "$sz"
      else
        echo "[]"
      fi
      ;;
    moveto)
      # 真移动文件（**旧语义**，保留仅为反向验证用: 退回 moveto 时副本应消失）
      local s d
      s=$(_map_path "$2"); d=$(_map_path "$3")
      _in_sandbox "$s" || return 1
      _in_sandbox "$d" || return 1
      [ -f "$s" ] || return 1
      mkdir -p "$(dirname "$d")" || return 1
      mv "$s" "$d" 2>/dev/null || return 1
      ;;
    copyto)
      # 真复制文件到目标路径（保留副本 = 不删源）
      local s d
      s=$(_map_path "$2"); d=$(_map_path "$3")
      _in_sandbox "$s" || return 1
      _in_sandbox "$d" || return 1
      [ -f "$s" ] || return 1
      mkdir -p "$(dirname "$d")" || return 1
      cp "$s" "$d" 2>/dev/null || return 1
      ;;
    cat)
      local p; p=$(_map_path "$2")
      _in_sandbox "$p" || return 1
      [ -f "$p" ] || return 1
      cat "$p"
      ;;
    rcat)
      # _marker_write 用: stdin → marker 文件（真写盘，用于验证出账）
      local p; d=$(_map_path "$2")
      _in_sandbox "$d" || return 1
      mkdir -p "$(dirname "$d")" || return 1
      cat > "$d"
      ;;
    size)  echo '{"bytes":0}' ;;
    *)     return 1 ;;
  esac
}
export -f rclone _map_path _in_sandbox 2>/dev/null || true
export SANDBOX SRC_SIM DST_SIM

# 源端 fixture 全部先造好（场景 1 用 video 原文件.mp4；场景 4 依赖"源端仍在"、
# 场景 5 依赖"源端不在"）—— 基线必须取在它们之后，否则比对必然假红
printf 'SRC-1' > "$SRC_SIM/video 原文件.mp4"
printf 'SRC-4' > "$SRC_SIM/gone_but_src.mp4"
SRC_BEFORE="$(cd "$SRC_SIM" && find . -type f -exec md5sum {} \; | sort)"

# ────────────────────────────────────────────────────────────
# 场景 1: 备份副本必须保留（copyto 而非 moveto）
# ────────────────────────────────────────────────────────────
mkdir -p "$DST_SIM/deadbeef"
printf 'CONTENT-1' > "$DST_SIM/deadbeef/a1b2c3d4.mp4"   # 替代文件（短哈希名）
st=$(_restore_one_entry "$DST_SIM" "video 原文件.mp4" "deadbeef/a1b2c3d4.mp4" "方法2·短名直传" "$SANDBOX/tmp" "" "")
[ "${st%%:*}" = "OK" ] \
  && ok "1a 还原成功返回 OK" || bad "1a 期望 OK，实际: $st"
[ -f "$DST_SIM/video 原文件.mp4" ] \
  && ok "1b 原路径已生成文件" || bad "1b 原路径文件不存在"
[ -f "$DST_SIM/deadbeef/a1b2c3d4.mp4" ] \
  && ok "1c ★备份副本保留（copyto 未搬走源）" || bad "1c 备份副本被删除了，仍按 moveto 语义"
[ "$(cat "$DST_SIM/video 原文件.mp4" 2>/dev/null)" = "CONTENT-1" ] \
  && ok "1d 还原产物内容与副本一致" || bad "1d 还原产物内容不符"

# ────────────────────────────────────────────────────────────
# 场景 2: 原路径已存在 + 同大小 ⇒ 判定已还原（且不覆盖）
# ────────────────────────────────────────────────────────────
mkdir -p "$DST_SIM/h2"
printf 'SAMEBYTES' > "$DST_SIM/h2/aaa.mp4"        # 副本
printf 'ORIGINALX' > "$DST_SIM/existing.mp4"      # 原路径已存在，9 字节，与 marker 记录一致
st=$(_restore_one_entry "$DST_SIM" "existing.mp4" "h2/aaa.mp4" "方法2·短名直传" "$SANDBOX/tmp" "" "9")
case "$st" in
  OK*) ok "2a 原路径已存在且同大小 ⇒ 判定已还原（OK）" ;;
  *)   bad "2a 期望 OK，实际: $st" ;;
esac
[ "$(cat "$DST_SIM/existing.mp4")" = "ORIGINALX" ] \
  && ok "2b ★未覆盖原路径已有文件（内容保持原样）" || bad "2b 原路径文件被覆盖了"

# ────────────────────────────────────────────────────────────
# 场景 3: 原路径已存在但大小不符 ⇒ SKIP，一个字节都不动
# ────────────────────────────────────────────────────────────
printf 'DIFFERENT-LONGER' > "$DST_SIM/differ.mp4"   # 16 字节
st=$(_restore_one_entry "$DST_SIM" "differ.mp4" "h2/aaa.mp4" "方法2·短名直传" "$SANDBOX/tmp" "" "9")
case "$st" in
  SKIP*) ok "3a 大小不符 ⇒ SKIP（不覆盖）" ;;
  *)     bad "3a 期望 SKIP，实际: $st" ;;
esac
[ "$(cat "$DST_SIM/differ.mp4")" = "DIFFERENT-LONGER" ] \
  && ok "3b ★大小不符时原路径未被改动" || bad "3b 原路径被覆盖，风险行为"

# 场景 3c: 未记录大小（expect_bytes 空）⇒ 也必须 SKIP，不得按 0 判等
st=$(_restore_one_entry "$DST_SIM" "differ.mp4" "h2/aaa.mp4" "方法2·短名直传" "$SANDBOX/tmp" "" "")
case "$st" in
  SKIP*) ok "3c 未记录大小 ⇒ 保守 SKIP（不按 0 判等）" ;;
  *)     bad "3c 期望 SKIP，实际: $st" ;;
esac

# ────────────────────────────────────────────────────────────
# 场景 4: 已失效条目出账 —— 源端在 ⇒ 出账
# ────────────────────────────────────────────────────────────
# 构造 marker: 一条副本已不存在、源端仍在（fixture 已在基线前造好）
cat > "$STATE/task0_x.json" <<'JSON'
{"dest_path":"openlist:","source_path":"onedrive:","fixed_files":[
 {"original":"gone_but_src.mp4","alternative":"nope/zzz.mp4","method":"方法2·短名直传","size_bytes":5}
],"fixed_count":1,"fixed_bytes":5}
JSON
SYNC_STATE_DIR="$STATE" restore_fixed_files "task0" >"$SANDBOX/out4.txt" 2>&1
after=$(jq -r '(.fixed_files // []) | length' "$STATE/task0_x.json" 2>/dev/null)
[ "$after" = "0" ] \
  && ok "4a ★源端仍在 ⇒ 已失效条目出账（fixed_files 清零）" || bad "4a 期望出账后 0 条，实际 $after"
grep -q "判定已失效，出账" "$SANDBOX/out4.txt" \
  && ok "4b 出账日志可追溯" || bad "4b 缺少出账日志"

# ────────────────────────────────────────────────────────────
# 场景 5: 已失效条目 —— 源端也不在 ⇒ 保留并告警（绝不出行）
# ────────────────────────────────────────────────────────────
cat > "$STATE/task1_x.json" <<'JSON'
{"dest_path":"openlist:","source_path":"onedrive:","fixed_files":[
 {"original":"both_gone.mp4","alternative":"nope/yyy.mp4","method":"方法2·短名直传","size_bytes":5}
],"fixed_count":1,"fixed_bytes":5}
JSON
SYNC_STATE_DIR="$STATE" restore_fixed_files "task1" >"$SANDBOX/out5.txt" 2>&1
after=$(jq -r '(.fixed_files // []) | length' "$STATE/task1_x.json" 2>/dev/null)
[ "$after" = "1" ] \
  && ok "5a ★两端皆无 ⇒ 条目保留未出账" || bad "5a 期望保留 1 条，实际 $after"
grep -q "保留条目并告警" "$SANDBOX/out5.txt" \
  && ok "5b 两端皆无有告警日志" || bad "5b 缺少告警日志"

# ────────────────────────────────────────────────────────────
# 场景 6: 源端只读护栏 —— 全程不得改动源端任何文件
# ────────────────────────────────────────────────────────────
SRC_AFTER="$(cd "$SRC_SIM" && find . -type f -exec md5sum {} \; | sort)"
if [ "$SRC_BEFORE" = "$SRC_AFTER" ]; then
  ok "6 ★源端零改动（所有文件 md5 与跑前一致）"
else
  bad "6 源端被改动了！"
  diff <(printf '%s\n' "$SRC_BEFORE") <(printf '%s\n' "$SRC_AFTER") | head -5
fi

# ────────────────────────────────────────────────────────────
# 场景 7: shim 护栏 —— 沙箱外路径一律拒绝（防误触生产）
# ────────────────────────────────────────────────────────────
_in_sandbox "/etc/passwd" && bad "7a 沙箱外路径被判为允许" || ok "7a 沙箱外路径被护栏拒绝"
# 7b: 越界远端路径（../ 逃逸出沙箱）必须被 _in_sandbox 拒掉 —— 直接测护栏本身，
#     不能用 && 串 rclone 的返回（rclone 无匹配时返回空但 exit 0，短路会让断言恒真）
esc=$("$SANDBOX/../etc" 2>/dev/null; true)
rclone lsf "openlist:/../../../etc" >/dev/null 2>&1
rc_out=$?
[ "$rc_out" -ne 0 ] && ok "7b 越界远端路径被 shim 拒绝（exit≠0）" \
  || bad "7b 越界路径未被拒绝（rc=0），护栏失效"

echo
echo "===== 结果: PASS=$PASS FAIL=$FAIL SKIP=$SKIP ====="
[ "$FAIL" -eq 0 ]
