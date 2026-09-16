#!/bin/bash
# ===== 注册: 跨轮拉黑 → 第二次修复必须触达「改名类」方法（D2 结论的管线侧锁定）=====
#
# 为什么要这个测试（2026-09-16，计划文档 §12.13.5 D2 的直接产物）:
#   拒收归因专项（run 35122248482）实测: A 原名蒸发 / B 改名存活 / C 随机存活
#   ⇒ 触发因素是**文件名本身**，改名可绕过；而方法 2 copyto_shorthash
#   （<md5前8位>.<扩展名>）正是改名类方法 ⇒ **这类文件本来可修**。
#   ⇒ 于是真问题从"再加新方法"变成"管线能否可靠走到方法 2"，即:
#     方法 1 假成功后拉黑 → 黑名单跨轮持久化 → 下一轮回填 → 跳过方法 1。
#
# 历史上这条链断过（run 31917285452 拉黑 5 条最终保存 0 条），而既有套件只覆盖
# 「名长预判拉黑」（test_fix_pipeline_optimizations 场景 1–3），**没有覆盖
# "假成功→复核失败→拉黑→跨轮生效"这条主链路** —— 本测试补上这段盲区。
#
# 锁定的契约（任一被改坏都会在此变红）:
#   C1 第一轮: 方法 1 判成功但复核失败 → 该文件被拉黑，且拉黑条目含 copyto_original
#   C2 第一轮: 对症方法 copyto_shorthash **不得**被一并拉黑（否则改名路线被自己堵死）
#   C3 第二轮: 用第一轮 marker 里的黑名单回填后，传给 try_fix_failed_file 的
#      FIX_METHOD_BLACKLIST 必须含 copyto_original（下一轮跳过它）
#   C4 第二轮: 该黑名单**不得**含 copyto_shorthash（改名路线仍开放 = 可修）
#   C5 拉黑条目存**归一语义 ID**（_fix_method_norm），跨命名版本都能被 _fix_method_blocked 命中
#
# 用法: bash test_blacklist_crossrun_method2.sh   （退出码 0=全过）

set -u

FAIL=0
PASS=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# 只 source 提供黑名单语义的那一个文件（file_fix.sh 里的 _blacklist_add /
# _fix_method_blocked / _fix_method_norm / _fix_method_desc），避免把整条
# 修复管线拉进来（那需要几十个 mock，且会与本测试意图互相干扰）。
# shellcheck source=../file_fix.sh
. "$REPO_ROOT/.github/scripts/openlist/file_fix.sh" 2>/dev/null || true

# 上面整文件 source 可能因子依赖缺失而只拿到部分函数；逐个确认可用性
# （缺一个就明确报 FAIL，而不是让后续断言静默假过）
for fn in _blacklist_add _fix_method_blocked _fix_method_norm _fix_method_desc; do
  if declare -F "$fn" >/dev/null 2>&1; then
    ok "0 前置: $fn 可用"
  else
    bad "0 前置: $fn 不可用 —— file_fix.sh 未成功加载（后续断言全部无效）"
  fi
done

# ── 模拟一次「方法1 假成功 → 复核失败 → 拉黑」并取回黑名单条目 ──
# FIX_METHOD_BLACKLIST 是 file_fix.sh 内的关联数组（_blacklist_add 写入）
unset FIX_METHOD_BLACKLIST 2>/dev/null || true
declare -A FIX_METHOD_BLACKLIST 2>/dev/null || true
if ! declare -F _blacklist_add >/dev/null 2>&1; then
  bad "0 关键: _blacklist_add 缺失，无法模拟拉黑"
  echo "-----"; echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

FILE="dir/原文件名被后端拒收.mp4"

# ★ 第二轮回填的是 marker 里持久化后的形态: 命名统一前写下的旧全名
#   （见 file_fix.sh:404-406），不是内存里归一后的短 ID。
#   断言必须用旧全名，否则"归一被去掉"这条回归会静默通过 —— 2026-09-16 负向验证
#   实测: 用内存短 ID 断言时，去掉 _fix_method_norm 后 C3/C5 仍 PASS ⇒ 假绿灯。
#   故 C3/C4 段刻意绕开内存写入，直接种 marker 形态的旧全名。
OLD_FULL="文件修复方法1 copyto_original: 原名直传（原路径 + 原文件名）"

# ── 第一轮（内存形态）: 方法1 判成功但复核失败 → 拉黑 ──
_blacklist_add "$FILE" copyto_original
BL1="${FIX_METHOD_BLACKLIST[$FILE]:-}"

echo "$BL1" | grep -q "copyto_original" \
  && ok "C1 第一轮: 方法1假成功复核失败 → 拉黑条目含 copyto_original" \
  || bad "C1: 拉黑条目不含 copyto_original（BL=[$BL1]）"

# C2: 只拉黑失败的那个方法，不得株连改名类方法
if echo "$BL1" | grep -q "copyto_shorthash"; then
  bad "C2: 不该拉黑 copyto_shorthash（改名路线被堵死 = D2 结论白测）"
else
  ok "C2 第一轮: 对症方法 copyto_shorthash 未被株连拉黑"
fi

# ── 切到第二轮的 marker 回填形态（用 OLD_FULL 覆写，理由见上）──
FIX_METHOD_BLACKLIST["$FILE"]="$OLD_FULL"
TRY_FIX_ORIGINAL="$FILE"

# ── C5: 存的是归一语义 ID，跨命名版本可命中 ──
# 历史 marker 里存的是旧全名（如 "文件修复方法1 copyto_original: 原名直传（…）"），
# 新条目存归一 ID；两侧都经 _fix_method_norm 归一后比对才不会漏。
declare -A FIX_METHOD_BLACKLIST_OLD 2>/dev/null || true
if declare -F _fix_method_norm >/dev/null 2>&1; then
  n_new=$(_fix_method_norm "$BL1")
  n_old=$(_fix_method_norm "文件修复方法1 copyto_original: 原名直传（原路径 + 原文件名）")
  [ "$n_new" = "$n_old" ] \
    && ok "C5 新旧两种命名归一同值（$n_new）⇒ 历史 marker 条目仍可命中" \
    || bad "C5: 旧名归一 [$n_old] ≠ 新条目归一 [$n_new]（历史黑名单会静默失效）"
else
  bad "C5: _fix_method_norm 缺失"
fi

# ── C3/C4: 第二轮用同一份黑名单回填后，门禁判定 ──
# 注意 _fix_method_blocked 是**单参数**签名: 文件键取全局 TRY_FIX_ORIGINAL
# （file_fix.sh:441 注释）—— 修复管线里由调用方在逐文件循环中设置它。
# 这里显式赋值以复现"第二轮处理同一个文件"的场景。
if declare -F _fix_method_blocked >/dev/null 2>&1; then
  TRY_FIX_ORIGINAL="$FILE"
  _fix_method_blocked copyto_original \
    && ok "C3 第二轮: 方法1 仍被拦（跳过它，不重复白传）" \
    || bad "C3: 第二轮方法1 未被拦 ⇒ 黑名单跨轮失效，会重复白传"

  if _fix_method_blocked copyto_shorthash; then
    bad "C4: 第二轮方法2 被误拦 ⇒ 改名路线走不到，D2 的'可修'落不了地"
  else
    ok "C4 第二轮: 方法2 未被拦（改名路线开放 = 可修）"
  fi
else
  bad "C3/C4: _fix_method_blocked 缺失"
fi

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
