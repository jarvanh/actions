#!/bin/bash
# 一键还原 —— 「保留备份副本」+「出账规则」行为验证（真文件操作 shim，不联网、不碰真远端）
#
# 背景（2026-09-26 用户三项拍板）:
#   1. 「还原的时候，目标端的备份副本应该保留」—— 原实现用 moveto，搬走即删副本。
#      副本消失的代价: 短哈希不可逆、副本是唯一内容载体，且下次预演会把它判成
#      「备份缺失」，把"已还原"伪装成"数据丢了"。改为 copyto 后副本保留。
#   2. 「已还原/已失效的条目要自动清理」+「源端在→才出账；源端不在→保留并告警」。
#   3. 「62 份原路径已存在」—— 同名同大小判已还原出账；大小不符则 SKIP 不覆盖。
#   4. 出账是**不可逆**动作（删 marker 条目 + 短哈希不可逆）⇒ 判"副本不存在"必须
#      **双判据**（列列举 + 直读 stat）: 只信列列举的话，一次列表假阴就会删掉
#      "其实还在"的副本记录。测试用 LSF_OMIT_* 注入假阴，C11/C12 锁住。
#
# 为什么必须**真文件操作**而不是纯判据 mock:
#   本改动改的是「落盘行为」（副本到底还在不在、原路径到底有没有被覆盖），
#   纯 mock 只能断言"调用了哪个命令"，测不出"文件真实状态"——而"副本消失"这个
#   病灶恰恰是**命令返回成功但副本人间蒸发**，只有比对真实文件系统才能抓到。
#   ⚠️ 本测试的 rclone shim 在**真实文件系统**上执行 cp/cat/写盘（不是假装），
#   所以它能验"副本保留"与"不覆盖"，这是纯 mock 做不到的。
#
# ⚠️ 安全约束（用户硬约束: 绝对不能修改源端任何文件）:
#   - 源端/目标端/marker 全部指向 mktemp -d 沙箱，无任何真远端引用
#   - 全测结束比对源端 md5 清单，任何变化直接 FAIL
#   - 记录所有写子命令，出现 moveto/move 即 FAIL（锁"副本必保留"）
#
# 用法: bash test_restore_keep_copy_ledger.sh
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

SANDBOX="$(mktemp -d /tmp/restore_keepcopy_XXXXXX)"
if [ -n "${KEEP_SANDBOX:-}" ]; then
  echo "KEEP_SANDBOX: $SANDBOX"
else
  trap 'rm -rf "$SANDBOX"' EXIT
fi

SRC="$SANDBOX/src"      # 假「源端」
DST="$SANDBOX/dst"      # 假「目标端」
STATE="$SANDBOX/state"  # 假 marker 目录
mkdir -p "$SRC/a" "$SRC/b" "$DST/deadbeef" "$DST/af00d000" "$DST/a" "$DST/d" "$DST/e" "$DST/f" "$DST/gone3" "$STATE"

# ── 场景数据 ───────────────────────────────────────────────
# 条目1: 副本在 → 走 copyto，期望原路径出现 **且副本仍在**
printf 'PAYLOAD-1' > "$DST/deadbeef/s1.mp4"
S1_BYTES=$(wc -c <"$DST/deadbeef/s1.mp4" | tr -d ' ')
# 条目2: 副本没了 + 源端在 → 失效出账
printf 'SRC-2'     > "$SRC/b/orig2.mp4"
# 条目3: 副本没了 + 源端也没 → 保留告警
# 条目4: 原路径已存在且同大小 → 判已还原出账（不复制）
printf 'PAYLOAD-4' > "$DST/af00d000/s4.mp4"
printf 'PAYLOAD-4' > "$DST/d/orig4.mp4"       # 落点已有同名同大小
S4_BYTES=$(wc -c <"$DST/af00d000/s4.mp4" | tr -d ' ')
# 条目5: 原路径已存在但大小不符 → SKIP 不覆盖
printf 'PAYLOAD-5-LONGER' > "$DST/e/orig5.mp4"
printf 'S5'               > "$DST/a/s5.mp4"
# 条目6: 副本**实际在**，但列列举对该目录假阴（见下方 LSF_OMIT_* 抑制）→ 不得误判失效
printf 'PAYLOAD-6' > "$DST/gone3/s6.mp4"
S6_BYTES=$(wc -c <"$DST/gone3/s6.mp4" | tr -d ' ')

cat > "$STATE/task0_x.json" <<EOF
{
  "task_name": "task0",
  "source_path": "$SRC",
  "dest_path": "$DST",
  "fixed_files": [
    {"original":"a/orig1.mp4","alternative":"deadbeef/s1.mp4","method":"方法2·短名直传","size_bytes":$S1_BYTES},
    {"original":"b/orig2.mp4","alternative":"gone/s2.mp4","method":"方法2·短名直传","size_bytes":5},
    {"original":"c/orig3.mp4","alternative":"gone/s3.mp4","method":"方法2·短名直传","size_bytes":5},
    {"original":"d/orig4.mp4","alternative":"af00d000/s4.mp4","method":"方法2·短名直传","size_bytes":$S4_BYTES},
    {"original":"e/orig5.mp4","alternative":"a/s5.mp4","method":"方法2·短名直传","size_bytes":2},
    {"original":"f/orig6.mp4","alternative":"gone3/s6.mp4","method":"方法2·短名直传","size_bytes":$S6_BYTES}
  ]
}
EOF

# ── 源端只读护栏快照 ────────────────────────────────────────
SRC_BEFORE="$(cd "$SRC" && find . -type f -exec md5sum {} \; | sort)"

# ── rclone shim: 在真实文件系统上执行（路径即本地路径） ──────
export SYNC_STATE_DIR="$STATE"
export RCLONE_RETRY_FLAGS=""   # 占位，下面重建
WRITE_LOG="$SANDBOX/writes.log"; : > "$WRITE_LOG"
SEND_CAPTURE="$SANDBOX/msg.txt"

rclone() {
  # 记账写命令（含 moveto，用于断言"副本必保留"= 不得出现搬移）
  case "$1" in
    copy*|move*|sync|delete*|rcat|mkdir) echo "$*" >> "$WRITE_LOG" ;;
  esac
  # 取第一个非 flag 参数作路径（flag 在末位，真 rclone 形态）
  local sub="$1"; shift
  local paths=()
  local a
  for a in "$@"; do
    case "$a" in --*) ;; *) paths+=("$a") ;; esac
  done
  case "$sub" in
    lsf)
      local d="${paths[0]}"
      (cd "$d" 2>/dev/null && ls -p 2>/dev/null | grep -v '/$') \
        | { if [ -n "${LSF_OMIT_DIR:-}" ] && [ "$d" = "${LSF_OMIT_DIR}" ]; then
              grep -vxF "${LSF_OMIT_NAME:-}"
            else cat; fi; } || true
      ;;
    lsjson)
      local f="${paths[0]}"
      if [ -f "$f" ]; then
        printf '[{"Size":%s}]\n' "$(wc -c <"$f" | tr -d ' ')"
      else
        printf '[]\n'
      fi
      ;;
    cat)  cat "${paths[0]}" 2>/dev/null ;;
    size) printf '{"bytes":%s}\n' "$(wc -c <"${paths[0]}" 2>/dev/null | tr -d ' ')" ;;
    copyto|moveto)
      # 真复刻"文件→文件"语义: moveto 是真搬（删源），copyto 是复制（留源）
      mkdir -p "$(dirname "${paths[1]}")"
      cp "${paths[0]}" "${paths[1]}" 2>/dev/null || return 1
      if [ "$sub" = "moveto" ]; then rm -f "${paths[0]}"; fi
      return 0
      ;;
    rcat)
      mkdir -p "$(dirname "${paths[0]}")"
      cat > "${paths[0]}"
      ;;
    *) return 0 ;;
  esac
}
export -f rclone

# 通知桩（不联网）
send_telegram_message() { printf '%s\n' "$1" > "$SEND_CAPTURE"; }
export -f send_telegram_message 2>/dev/null || true

source "$REPO_ROOT/.github/scripts/telegram/tg_notify.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/rclone_flags.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/sync_marker.sh" 2>/dev/null || true
source "$REPO_ROOT/.github/scripts/openlist/file_restore.sh"
RCLONE_RETRY_FLAGS=(--retries 1)
# ⚠️ SYNC_STATE_DIR 必须在 source 之后设置: sync_marker.sh 会把它赋成生产默认值
#   （onedrive:/logs/sync_state），若在 source 前 export 会被直接覆盖 ⇒ 找不到 marker
#   而"空跑通过"，是最隐蔽的假绿形态。
SYNC_STATE_DIR="$STATE"

# 覆盖为自定义桩（source 可能把上面那行盖掉）
send_telegram_message() { printf '%s\n' "$1" > "$SEND_CAPTURE"; }

# 列列举假阴注入: 对 gone3 目录，lsf 假装看不到 s6.mp4（文件实际在盘上）。
#   用于验证「出账必须双判据」——只信列列举就会把"副本其实还在"当失效删记录，
#   而直读 stat（lsjson）不受此抑制，故真实现应改走正常还原（C11/C12 锁住）。
LSF_OMIT_DIR="$DST/gone3"
LSF_OMIT_NAME="s6.mp4"

restore_fixed_files all > "$SANDBOX/out.log" 2>&1 || true

# ────────────────────────────────────────────────────────────
# 断言
# ────────────────────────────────────────────────────────────

# C1: 副本保留（核心）—— 条目1 的替代文件在还原后必须仍在
[ -f "$DST/deadbeef/s1.mp4" ] \
  && ok "C1 还原后目标端备份副本仍在（未 moveto 搬走）" \
  || bad "C1 备份副本消失了（仍在使用搬移语义）"

# C2: 原路径真的出现了文件，且内容与副本一致（真复制）
if [ -f "$DST/a/orig1.mp4" ]; then
  if cmp -s "$DST/a/orig1.mp4" "$DST/deadbeef/s1.mp4"; then
    ok "C2 原路径落盘且内容与副本一致"
  else
    bad "C2 原路径内容与副本不一致"
  fi
else
  bad "C2 原路径未落盘"
fi

# C3: 零 moveto —— 全程不得出现搬移命令
if grep -q '^moveto' "$WRITE_LOG" 2>/dev/null; then
  bad "C3 出现 moveto 调用（副本会被搬走）"
else
  ok "C3 全程无 moveto（保留语义生效）"
fi

# C4: 已失效且源端在 → 出账
if ! grep -q 'b/orig2.mp4' "$STATE/task0_x.json"; then
  ok "C4 失效且源端在 → 条目已出账"
else
  bad "C4 失效条目未出账（源端在却保留）"
fi

# C5: 失效且源端不在 → 保留（不得出账）
if grep -q 'c/orig3.mp4' "$STATE/task0_x.json"; then
  ok "C5 两端均无 → 条目保留未出账"
else
  bad "C5 两端均无的条目被出账（真风险线索被抹掉）"
fi

# C6: 原路径已存在且同大小 → 出账
if ! grep -q 'd/orig4.mp4' "$STATE/task0_x.json"; then
  ok "C6 原路径同名同大小 → 判已还原出账"
else
  bad "C6 同名同大小条目未出账"
fi

# C7: 原路径大小不符 → SKIP 且保留条目
if grep -q 'e/orig5.mp4' "$STATE/task0_x.json"; then
  ok "C7 原路径大小不符 → 条目保留"
else
  bad "C7 大小不符条目被误出账"
fi

# C8: SKIP 分支绝不覆盖已有文件（内容仍是用户原始的）
if cmp -s <(printf 'PAYLOAD-5-LONGER') "$DST/e/orig5.mp4"; then
  ok "C8 大小不符时未覆盖原路径（原内容完好）"
else
  bad "C8 原路径被覆盖（不可逆损毁风险）"
fi

# C9: 源端零改动（硬约束）
SRC_AFTER="$(cd "$SRC" && find . -type f -exec md5sum {} \; | sort)"
[ "$SRC_BEFORE" = "$SRC_AFTER" ] \
  && ok "C9 源端零改动" \
  || bad "C9 源端被修改（违反硬约束）"

# C10: 通知里体现了新增口径
if grep -q '已失效出账' "$SEND_CAPTURE" 2>/dev/null; then
  ok "C10 汇总通知含「已失效出账」计数"
else
  bad "C10 汇总通知未体现失效出账口径"
fi

# C11: 列列举假阴（副本其实在）不得误判失效 —— 必须仍走还原，原路径落盘且内容一致。
#   反向验证: 把 file_restore.sh 出账判据退回"只信列列举"，C11 立刻转红
#   （副本会被当失效出账、原路径永远不出现）。
if [ -f "$DST/f/orig6.mp4" ] && cmp -s "$DST/f/orig6.mp4" "$DST/gone3/s6.mp4"; then
  ok "C11 列列举假阴时未误判失效（双判据生效，原路径已还原）"
else
  bad "C11 列列举假阴被当成副本不存在（误出账，唯一线索被删）"
fi

# C12: 假阴场景**确实走了 copyto 还原**（而非直接判失效 continue 跳过）。
#   这条有区分力: 退回"只信列列举"时该 copyto 根本不会发生 ⇒ C11/C12 同时转红。
if grep -qE '^copyto .*gone3/s6\.mp4.*f/orig6\.mp4' "$WRITE_LOG" 2>/dev/null; then
  ok "C12 假阴场景走了 copyto 还原（副本保留，未被误判跳过）"
else
  bad "C12 未发生 copyto（副本被判失效跳过）"
fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0