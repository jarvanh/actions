#!/bin/bash
# 单同步对公平份额 + 到点交棒状态（2026-11-10 加）
#
# 背景（run 42706236473，sync step 全程 322min，以日志为准）:
#   21 个同步对只启动了 2 个，两者各自卡在停滞的传输上 —— 471.476 MiB 的流跑了
#   56min；12.323 GiB 的流 26min 只推进 17 MiB；全轮 29% 的进度样本是 0 B/s。
#   双双吃满预算被硬顶放弃 ⇒「本轮 0 个完成」、游标只前进 1 位。按每轮 2 个对
#   推算，轮转一圈约 11 轮 ≈ 3 天 —— 这是"同步完不成"的真实根因。
#   （**不是**修复重试: 该轮修复只占 7 次进入 / 22 次方法尝试 ≈ 20-30min。）
#
# 这套断言锁的就是修复后的不变量:
#   A. 份额 = min(剩余可用预算, max(下限, 剩余可用预算 / 尚需对数))
#   B. 份额到期 ⇒ sync_budget_stop 立刻为真（该对不再开新单元，交棒给下一个对）
#   C. 在途单元不得超过份额终点（否则 20min 份额会被单个大文件吃穿，形同虚设）
#   D. 到点交棒的对，状态必须是 truncated —— 不能冒充 synced（未跑完），
#      也不能冒充 failed（不是后端故障）
#   E. 未注入预算锚点（调试/还原/本机）必须完全无约束，行为与改动前一致
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- mocks: task_engine.sh 顶层只定义常量/函数，但被 source 时可能走到通知/趋势
#     的辅助函数，故先给最小 mock 面（手法同 test_sync_trend_budget.sh）---
format_bytes() { echo "$1"; }
send_telegram_message() { return 0; }
tg_add_title()   { :; }
tg_add_section() { :; }
tg_add_kv()      { :; }
tg_add_block()   { :; }
tg_add_footer()  { :; }
rclone() { return 0; }

source "$_REPO_ROOT/.github/scripts/openlist/sync_trend.sh" 2>/dev/null
source "$_REPO_ROOT/.github/scripts/openlist/task_engine.sh" 2>/dev/null

# 固定被测常量，避免被环境/默认值漂移影响
OPENLIST_BATCH_TAIL_RESERVE=2700
OPENLIST_SYNC_BUDGET_SECONDS=19200
OPENLIST_SYNC_MIN_SLICE_SECONDS=600
OPENLIST_PAIR_MIN_SLICE_SECONDS=1200

# ================= A. 份额数学 =================
unset OPENLIST_SYNC_DEADLINE_EPOCH
[ -z "$(_pair_share_seconds 21)" ] \
  && ok "A1 无预算锚点 → 份额为空（不加约束，调试/还原行为不变）" \
  || bad "A1 无锚点却给出份额 [$(OPENLIST_SYNC_DEADLINE_EPOCH=x _pair_share_seconds 21)]"

# 轮初: 预算 19000s，尾部预留 2700 ⇒ 可用 ≈16300
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))
_v=$(_pair_share_seconds 21)
[ "$_v" = "1200" ] \
  && ok "A2 21 对轮初: 16300/21=776 → 抬到下限 1200（一个对至少能跑预览+实传）" \
  || bad "A2 期望1200 实得 [${_v:-空}]"
_v=$(_pair_share_seconds 2)
[ "$_v" -gt 7000 ] && [ "$_v" -lt 8200 ] \
  && ok "A3 只剩 2 对: 各分一半（≈8100s，慢对可放开跑，无人被饿）" \
  || bad "A3 期望≈8100 实得 [${_v:-空}]"
_v=$(_pair_share_seconds 1)
_u=$(_budget_slice_seconds)
[ "$_v" = "$_u" ] \
  && ok "A4 只剩 1 对: 份额=全部可用预算（不再高于预算）" \
  || bad "A4 期望 ${_u} 实得 [${_v:-空}]"
# 非法/退化入参按 1 对处理（不能除零、不能返回空而放宽约束）
for _bad_in in 0 "" abc -5; do
  _v=$(_pair_share_seconds "$_bad_in")
  [ -n "$_v" ] && [ "$_v" -gt 0 ] \
    && ok "A5 非法对数 '${_bad_in}' → 按 1 对处理（${_v}s，不倒挂/不除零）" \
    || bad "A5 非法对数 '${_bad_in}' 返回 [${_v:-空}]"
done
# 轮末: 可用预算已小于下限 ⇒ 必须取可用预算，绝不能凭空造出超过预算的份额
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 800 ))
_u=$(_budget_slice_seconds)
_v=$(_pair_share_seconds 5)
[ "$_v" = "$_u" ] \
  && ok "A6 轮末(可用 ${_u}s < 下限 1200) → 份额取可用预算，不越过预算" \
  || bad "A6 期望 ${_u} 实得 [${_v:-空}]"
# 大批量: 下限会过度承诺，但份额本身不得高于可用预算
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))
_v=$(_pair_share_seconds 40)
_u=$(_budget_slice_seconds)
[ "$_v" -le "$_u" ] \
  && ok "A7 40 对: 份额(${_v}s) ≤ 可用预算(${_u}s)" \
  || bad "A7 份额 ${_v} 超过可用预算 ${_u}"

# ================= B. 份额到期 = 立即不再开新工作片 =================
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))   # 全局预算很充足
unset OPENLIST_PAIR_DEADLINE_EPOCH
if sync_budget_stop; then bad "B1 无份额约束且预算充足却判停"; else ok "B1 无份额约束 → 预算充足不停"; fi
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 1800 ))    # 份额还剩 30min
if sync_budget_stop; then bad "B2 份额还剩 30min 却判停"; else ok "B2 份额还剩 30min → 不停（在自己份额内继续干）"; fi
# 边界: 份额剩余 < 一个最小片(600s) ⇒ 不再开新单元（与全局预算同一口径）
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 600 ))
if sync_budget_stop; then ok "B2b 份额剩 600s（= 最小片）→ 判停，不再开新单元"; else bad "B2b 份额只剩 600s 却仍开新单元"; fi
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) - 1 ))       # 份额到期
if sync_budget_stop; then ok "B3 份额到期 → 立即判停（交棒给下一个对，不再开新单元）"; else bad "B3 份额到期却继续干"; fi
OPENLIST_PAIR_DEADLINE_EPOCH="garbage"
if sync_budget_stop; then bad "B4 份额值非法却判停"; else ok "B4 份额值非法 → 忽略该约束（不误停）"; fi
unset OPENLIST_PAIR_DEADLINE_EPOCH

# ================= C. 在途单元被夹到份额终点 =================
# 这条是 A 的"落地保证": 没有它，20min 份额会被单个大文件吃穿（实测 471MiB/56min）
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 300 ))
_v=$(_budget_slice_seconds)
[ "$_v" -gt 240 ] && [ "$_v" -le 310 ] \
  && ok "C1 份额剩 300s → 单元上限被夹到 ≈300s（不是全局的 16300s）" \
  || bad "C1 期望≈300 实得 [${_v:-空}]"
_v=$(_slice_cap_seconds)
[ "$_v" -gt 240 ] && [ "$_v" -le 310 ] \
  && ok "C2 _slice_cap_seconds 同样被夹（批次/子目录两条传输路径同口径）" \
  || bad "C2 期望≈300 实得 [${_v:-空}]"
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) - 100 ))
_v=$(_budget_slice_seconds)
[ "$_v" = "60" ] \
  && ok "C3 份额已过点 → 兜底 60s（不出现 0/负数 timeout）" \
  || bad "C3 期望60 实得 [${_v:-空}]"
# 份额比全局预算更**远**时，由全局预算决定（份额只是上界，不是放大系数）
OPENLIST_PAIR_DEADLINE_EPOCH=$(( OPENLIST_SYNC_DEADLINE_EPOCH + 5000 ))
_v=$(_budget_slice_seconds)
_u=$(( OPENLIST_SYNC_DEADLINE_EPOCH - $(date +%s) - OPENLIST_BATCH_TAIL_RESERVE ))
[ "$_v" -gt 15500 ] && [ "$_v" -le "$_u" ] \
  && ok "C4 份额比全局更远 → 仍按全局预算给（${_v}s），份额不放大" \
  || bad "C4 期望≈${_u} 实得 [${_v:-空}]"
unset OPENLIST_PAIR_DEADLINE_EPOCH OPENLIST_SYNC_DEADLINE_EPOCH

# ================= D. 到点交棒的状态判定 =================
_st() { _pair_status_from_flags; }
SYNC_SKIPPED=0 SYNC_FAILED=0 SYNC_PARTIAL=0 SYNC_TIME_EXHAUSTED=0
[ "$(_st)" = "synced" ] && ok "D1 全绿 → synced" || bad "D1 期望 synced 实得 $(_st)"
SYNC_TIME_EXHAUSTED=1
[ "$(_st)" = "truncated" ] \
  && ok "D2 到点交棒且无失败 → truncated（绝不冒充 synced）" \
  || bad "D2 期望 truncated 实得 $(_st)"
SYNC_FAILED=1
[ "$(_st)" = "failed" ] && ok "D3 真失败优先于交棒 → failed" || bad "D3 期望 failed 实得 $(_st)"
SYNC_PARTIAL=1
[ "$(_st)" = "partial" ] && ok "D4 部分失败 → partial" || bad "D4 期望 partial 实得 $(_st)"
SYNC_SKIPPED=1
[ "$(_st)" = "skipped" ] && ok "D5 skipped 最高优先" || bad "D5 期望 skipped 实得 $(_st)"
SYNC_SKIPPED=0 SYNC_FAILED=0 SYNC_PARTIAL=0 SYNC_TIME_EXHAUSTED=0
[ "$(_st)" = "synced" ] && ok "D6 复位后回到 synced（无粘滞状态）" || bad "D6 复位后实得 $(_st)"

# ================= E. 串行/调试路径零影响 =================
# OPENLIST_PAIR_DEADLINE_EPOCH 只在并行 worker 子 shell 里导出；父进程与串行
# 路径读不到 ⇒ 未注入时 sync_budget_stop/_budget_slice_seconds 行为必须与旧版一致
unset OPENLIST_PAIR_DEADLINE_EPOCH OPENLIST_SYNC_DEADLINE_EPOCH
if sync_budget_stop; then bad "E1 双锚点皆无却判停（会破坏调试/还原模式）"; else ok "E1 双锚点皆无 → 不干预（调试/还原/本机不变）"; fi
[ -z "$(_budget_slice_seconds)" ] \
  && ok "E2 双锚点皆无 → 不给 timeout 包装（行为与改动前一致）" \
  || bad "E2 无锚点却给出 [${_v:-空}]"

# ================= F. 尺度区分（否则同步彻底停死）=================
# 这是实现时踩到的真陷阱: 批次闸要"够 2h 片长"、子目录闸要"够 25% 全局修复
#   预留(默认 4800s)"。若把 ~20min 的份额终点直接喂进去，两闸**恒真** ⇒
#   每个对连一个批次、一个子目录都开不起来，反而比改动前更糟。
#   故份额生效时，各闸一律退到最小片当预留量。
OPENLIST_SYNC_BUDGET_SECONDS=19200
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 19000 ))      # 全局还剩 ~5h
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 1200 ))       # 本对份额 20min
if _pair_share_binding; then ok "F1 份额比全局更近 → 判定为生效约束"; else bad "F1 未识别出份额为生效约束"; fi
if _batch_budget_stop; then bad "F2 20min 份额下批次闸恒真（一个批次都开不起来 = 同步停死）"; else ok "F2 20min 份额仍可开批次（不套用 2h 片长）"; fi
if _subdir_budget_stop; then bad "F3 20min 份额下子目录闸恒真（一个子目录都开不起来）"; else ok "F3 20min 份额仍可开子目录（不套用 25% 修复预留）"; fi
# 份额只剩 5min（< 最小片）⇒ 两闸都应判停（不再开新单元）
OPENLIST_PAIR_DEADLINE_EPOCH=$(( $(date +%s) + 300 ))
if _batch_budget_stop; then ok "F4 份额剩 5min → 批次闸判停"; else bad "F4 份额剩 5min 仍开批次"; fi
if _subdir_budget_stop; then ok "F5 份额剩 5min → 子目录闸判停"; else bad "F5 份额剩 5min 仍开子目录"; fi
# 无份额时，两闸必须回到原尺度（不得因本次改动放宽全局约束）
unset OPENLIST_PAIR_DEADLINE_EPOCH
if _pair_share_binding; then bad "F6 无份额却判为生效"; else ok "F6 无份额 → 不生效"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 10800 ))      # 剩 3h：够 2h 片 → 可开批
if _batch_budget_stop; then bad "F7 无份额且剩 3h 却不开批次（原尺度被放宽/收紧？）"; else ok "F7 无份额: 剩 3h → 仍可开批次（原尺度不变）"; fi
OPENLIST_SYNC_DEADLINE_EPOCH=$(( $(date +%s) + 5400 ))       # 剩 90min < 2h 片 → 停
if _batch_budget_stop; then ok "F8 无份额: 剩 90min → 不开新批次（原尺度不变）"; else bad "F8 无份额: 剩 90min 却开批次"; fi
unset OPENLIST_SYNC_DEADLINE_EPOCH OPENLIST_PAIR_DEADLINE_EPOCH

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
