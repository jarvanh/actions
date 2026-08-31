#!/usr/bin/env bash
# 进度通知"阶段区"排版回归测试（用户反馈实录的一屏）:
#   📁 源端 280.790 GiB          ← 与任务分组头 "📁 onedrive:0 · 280.790 GiB" 重复
#   ├─ ⏭️ archive · 477.281 MiB  ← 与 "└─ wopan176Crypt/0" 同列，看着像目标端的
#                                  同级兄弟，而非挂在 "▸ 📊 子目录" 之下
#   ▸ 📦 文件批次拆分：15 批 ...  ← 排在统计行之后，而非挂在正在跑的子目录下
#   ▸ 📊 批次：1/15 | ✅0 ❌0     ← 只有批次序号，看不出在跑什么、跑了多少
# 契约（渲染器 _progress_render 与生产方 _render_subdir_phase_tree 各自一半）:
#   L1 子目录树不再输出 "📁 源端 X" 首行（源端大小分组头已给出）
#   L2 树型块: 统计行是表头，排在树行之前；树行再缩进 2 格
#   L3 标签型块（全部行以 "▸" 开头）: 标签排在统计行之前，两者同列、无连接符
#   L4 下一层表头对齐本层树行文本列 —— 视觉上挂在 🔄 活动行（已置尾）之下
#   L5 深层 detail 落到本层 note 行（挂在统计行下），不再被静默丢弃
#   L6 progress_scope_init 连 note 槽位一起清理，子任务收尾不留残影
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "✅ $1"
  else
    FAIL=$((FAIL + 1)); echo "❌ $1 (期望 [$3] 实际 [$2])"
  fi
}

# ---------- 加载被测模块（部分 source: 只依赖 utils + telegram 排版助手）----------
source "$SCRIPT_DIR/../utils.sh"
source "$SCRIPT_DIR/../telegram.sh"
source "$SCRIPT_DIR/../task_engine.sh"
source "$SCRIPT_DIR/../sync_progress.sh"

# 状态文件重定向到临时目录（模块顶层写死 /tmp，source 后覆盖）
PROGRESS_TASKS_FILE="$WORK_DIR/tasks.tsv"
PROGRESS_START_FILE="$WORK_DIR/start"
PROGRESS_FINALIZED_FILE="$WORK_DIR/finalized"
PROGRESS_FIXED_FILE="$WORK_DIR/fixed"
PROGRESS_MSG_ID_FILE="$WORK_DIR/msgid"
PROGRESS_CURRENT_FILE="$WORK_DIR/current"
PROGRESS_LAST_UPDATE_FILE="$WORK_DIR/last_update"
# 阶段槽位路径默认也是 /tmp（_progress_slot_* 生成），重指向临时目录，
# 免得测试之间互相污染真实 /tmp
_progress_slot_rows()  { printf '%s/rows.%d'  "$WORK_DIR" "$1"; }
_progress_slot_stats() { printf '%s/stats.%d' "$WORK_DIR" "$1"; }
_progress_slot_note()  { printf '%s/note.%d'  "$WORK_DIR" "$1"; }

# telegram 发送 mock（只需 message_id 落盘，不发真实请求）
_tg_ensure_bottom_message() { printf '%s\n' "$1" > "$WORK_DIR/last_msg"; echo "mock-id"; }

# 取渲染结果里匹配某关键字的整行（保留行首缩进）
line_of() { grep -F -- "$1" "$WORK_DIR/last_msg" | head -1; }

# ---------- L1: 子目录树无 "📁 源端" 首行 ----------
declare -A subdir_status_map=() subdir_size_map=()
subdirs=$'archive\n照片\nj-1024j-视频-pornhub-favorites'
subdir_size_map[archive]=500400000
subdir_size_map[照片]=19250000000000
subdir_size_map[j-1024j-视频-pornhub-favorites]=281700000000000
subdir_status_map[archive]=skipped
subdir_status_map[照片]=synced
subdir_status_map[j-1024j-视频-pornhub-favorites]=syncing
TREE=$(_render_subdir_phase_tree)
chk "L1a 首行是第一个子目录（不再有 📁 源端 表头行）" \
  "$(printf '%s' "$TREE" | head -1)" "⏭️ archive · $(format_bytes 500400000)"
chk "L1b 行数 = 子目录数（3）" "$(printf '%s\n' "$TREE" | grep -c .)" "3"
chk "L1c 末行为 🔄 活动子目录" \
  "$(printf '%s' "$TREE" | tail -1)" \
  "🔄 j-1024j-视频-pornhub-favorites · $(format_bytes 281700000000000)"

# ---------- 装配场景: 父层子目录树 + 子层文件批次 ----------
TASK_SUBDIR_STATS='▸ 📊 子目录：2/3 完成 | ✅1 ⏭️1 ⏳1 ⚠️0 ❌0'
BATCH_LABEL='▸ 📦 文件批次拆分：共 15 批 · 1367 个文件（当前第 1 批 · 105 个文件）'
BATCH_STATS='▸ 📊 批次：1/15 | ✅0 ❌0 · 📄 105/1367 文件 · 📤 12.345 GiB'
BATCH_DETAIL='批次 1 巩固: 重启容器校验落盘真值'

progress_init
progress_register_task task0_wopan176Crypt "onedrive:0 → openlist:wopan176Crypt/0" "280.790 GiB"
progress_task_begin task0_wopan176Crypt >/dev/null
SYNC_AUTO_SPLIT_DEPTH=0
PROGRESS_PHASE_INFO="$TREE"
PROGRESS_STATS="$TASK_SUBDIR_STATS"
progress_update_force "" "$PROGRESS_STATS" >/dev/null
SYNC_AUTO_SPLIT_DEPTH=1
PROGRESS_PHASE_INFO="$BATCH_LABEL"
PROGRESS_STATS="$BATCH_STATS"
# 清掉节流时间戳: 上一步是 force 刷新（force 只豁免深度 0），紧接着的深层
# 更新会被 2s 节流吞掉，消息不刷新则下面的断言读到的是上一屏
rm -f "$PROGRESS_LAST_UPDATE_FILE"
progress_update "$BATCH_DETAIL" >/dev/null

# ---------- L2: 树型块 —— 统计行（表头）在前，树行缩进 2 格 ----------
chk "L2a 统计行缩进 5 格、位于树行之前" \
  "$(line_of '子目录：')" "     ${TASK_SUBDIR_STATS}"
chk "L2b 首个树行缩进 7 格（统计行 +2）并带 ├─ 连接符" \
  "$(line_of 'archive')" "       ├─ ⏭️ archive · $(format_bytes 500400000)"

# ---------- L3: 标签型块 —— 标签在前、与统计行同列、无连接符 ----------
# 批次块在深度 1，表头缩进 = 5*1+5 = 10 格（L4 断言它正对本层树行文本列）
chk "L3a 批次标签挂树形连接符（code 等宽）" \
  "$(line_of '文件批次拆分')" "          <code>└─ ${BATCH_LABEL#▸ }</code>"
chk "L3b 批次统计行（code 等宽，缩进 14 格）" \
  "$(line_of '批次：1/15')" "              <code>${BATCH_STATS}</code>"
# 标签型与树型的"统计行 vs 阶段行"先后相反，是本契约的关键
N_LABEL=$(grep -n -F -- '文件批次拆分' "$WORK_DIR/last_msg" | head -1 | cut -d: -f1)
N_BATCH_STATS=$(grep -n -F -- '批次：1/15' "$WORK_DIR/last_msg" | head -1 | cut -d: -f1)
chk "L3c 标签型: 标签行排在统计行之前" \
  "$([ "$N_LABEL" -lt "$N_BATCH_STATS" ] && echo yes || echo no)" "yes"
N_SUBDIR_STATS=$(grep -n -F -- '子目录：' "$WORK_DIR/last_msg" | head -1 | cut -d: -f1)
N_TREE=$(grep -n -F -- 'archive' "$WORK_DIR/last_msg" | head -1 | cut -d: -f1)
chk "L2c 树型: 统计行排在树行之前" \
  "$([ "$N_SUBDIR_STATS" -lt "$N_TREE" ] && echo yes || echo no)" "yes"

# ---------- L4: 下一层表头对齐本层树行文本列（挂在 🔄 行下）----------
# 树行 "       └─ 🔄 ..." 文本列 = 7 + len("└─ ") = 11
# 下一层表头缩进 10 格 + "▸" 占 1 列 → 同样落在第 11 列
ACT_ROW=$(line_of 'j-1024j')
ACT_LABEL=$(line_of '文件批次拆分')
chk "L4a 树行是最后一条（🔄 已置尾，深层块才挂得住）" \
  "$(printf '%s' "$ACT_ROW" | grep -c '└─ 🔄')" "1"
chk "L4b 标签行带 code 树干前缀（层级归属可见）" \
  "$(printf '%s' "$ACT_LABEL" | grep -c '<code>└─ ')" "1"

# ---------- L5: 深层 detail 落到本层 note 行 ----------
chk "L5a 深层 detail 渲染为 note 行（code 等宽）" \
  "$(line_of '巩固')" "              <code>· ${BATCH_DETAIL}</code>"
chk "L5b 深层 detail 不污染任务行（任务行无 detail）" \
  "$(line_of 'wopan176Crypt/0')" "  └─ wopan176Crypt/0"

# ---------- L6: 子任务收尾清更深槽位（含 note）----------
progress_scope_init 1
chk "L6a 清完 rows" "$([ -f "$(_progress_slot_rows 1)" ] && echo yes || echo no)" "no"
chk "L6b 清完 stats" "$([ -f "$(_progress_slot_stats 1)" ] && echo yes || echo no)" "no"
chk "L6c 清完 note" "$([ -f "$(_progress_slot_note 1)" ] && echo yes || echo no)" "no"
chk "L6d 父层槽位不受影响" "$([ -f "$(_progress_slot_rows 0)" ] && echo yes || echo no)" "yes"

# ---------- L7: 深度 0 扁平批次面板（2026-08-30 用户反馈实录）----------
# 场景: 任务根直接文件批次拆分（无子目录树），批次面板整体落在深度 0。
# 旧行为: ① 标签行用 └─ 与目标端行同级同形，层次混淆; ② rt 线程「传输中」写
# 任务行 detail，黏在目标端行尾; ③ 统计行尾部带 ⏱ xfer，与 note 重复。
# 契约:
#   L7a d0 标签行无树连接符（▸ 前导），不再与目标端行 └─ 同级同形
#   L7b d0 统计行缩进 9 格（标签 5 格 + 4）
#   L7c 目标端行无 detail 黏连
#   L7d 传输中独立成行（统计行下、历史之前），历史非空时用 ├─ 连接
#   L7e 线程 stats 不带 ⏱ xfer 尾
#   L7f 线程停止时清 note 槽（防过期传输中残留到巩固阶段）
PROGRESS_RT_PID_FILE="$WORK_DIR/rt_pid"
PROGRESS_RT_STOP_FILE="$WORK_DIR/rt_stop"
PROGRESS_RT_EXIT_FILE="$WORK_DIR/rt_exit"
PROGRESS_LOCK_FILE="$WORK_DIR/refresh.lock"
PROGRESS_SENT_IDS_LOG="$WORK_DIR/sent_ids"

progress_init
progress_register_task task0_wopan175 "onedrive:0/j-1024j → openlist:wopan175/0/j-1024j" "262.401 GiB"
progress_task_begin task0_wopan175 >/dev/null
SYNC_AUTO_SPLIT_DEPTH=0
PROGRESS_PHASE_INFO="$BATCH_LABEL"
PROGRESS_STATS="$BATCH_STATS"
progress_update_force "" "" >/dev/null

chk "L7a d0 标签行无树连接符、保留 ▸ 前导（5 格缩进）" \
  "$(line_of '文件批次拆分')" "     <code>▸ ${BATCH_LABEL#▸ }</code>"
chk "L7b d0 统计行缩进 9 格" \
  "$(line_of '批次：1/15')" "         <code>${BATCH_STATS}</code>"
chk "L7c 目标端行无 detail 黏连" \
  "$(line_of 'wopan175/0')" "  └─ wopan175/0/j-1024j"

# rt 线程实时状态 → note 行（直写 d0 note 槽，不碰任务行）
rm -f "$PROGRESS_LAST_UPDATE_FILE"
progress_transfer_tick "传输中: 2.469 GiB / 4.976 GiB" "" >/dev/null
chk "L7d-1 传输中独立成行（统计行下、└─ 连接）" \
  "$(line_of '传输中')" "         <code>· 传输中: 2.469 GiB / 4.976 GiB</code>"

_progress_batch_history_add 47 "❌ 批次 47：共 21 个文件，成功 0 · 失败 22"
rm -f "$PROGRESS_LAST_UPDATE_FILE"
progress_transfer_tick "传输中: 2.469 GiB / 4.976 GiB" "" >/dev/null
chk "L7d-2 历史非空时 note 用 ├─ 连接" \
  "$(line_of '传输中')" "         <code>· 传输中: 2.469 GiB / 4.976 GiB</code>"
chk "L7d-3 批次历史在 note 之后渲染（缩进在 code 内，渲染器既有行为）" \
  "$(line_of '批次 47')" "<code>         └─ ❌ 批次 47：共 21 个文件，成功 0 · 失败 22</code>"

# 线程实体行为: note 直写 + stats 无 ⏱ + 停止清理
printf 'Transferred: 2.469 GiB / 4.976 GiB, ETA 3m\n' > "$WORK_DIR/batch_l7.log"
PROGRESS_RT_INTERVAL=1
_start_batch_progress_thread "$WORK_DIR/batch_l7.log"
_rt_pid=$(cat "$PROGRESS_RT_PID_FILE")
sleep 2.5
chk "L7e-1 线程传输中写入 note 槽" \
  "$(grep -c '传输中' "$(_progress_slot_note 0)" 2>/dev/null || true)" "1"
chk "L7e-2 线程 stats 不带 ⏱ xfer 尾" \
  "$(grep -c '⏱' "$(_progress_slot_stats 0)" 2>/dev/null || true)" "0"
_stop_batch_progress_thread
chk "L7f 线程停止后 note 槽已清（防过期残留）" \
  "$([ -f "$(_progress_slot_note 0)" ] && echo 残留 || echo 已清)" "已清"
chk "L7g 线程已退出且 pid 文件已清" \
  "$(kill -0 "$_rt_pid" 2>/dev/null || [ -f "$PROGRESS_RT_PID_FILE" ] && echo 未清 || echo 已清)" "已清"

# ---------- L8: 深层 note 写入清除浅层 note（去重，2026-08-31 用户反馈）----------
# 多层 auto-split 时祖先层的"排序中/统计中"注记在深层开工后已过期；
# 深层 note 写入即清浅层 → 任意时刻只显示最深一条过程注记
rm -f "$PROGRESS_LAST_UPDATE_FILE"
SYNC_AUTO_SPLIT_DEPTH=1
progress_task_update "正在按子目录大小排序..." >/dev/null
chk "L8a d1 note 落槽" "$([ -f "$(_progress_slot_note 1)" ] && echo yes || echo no)" "yes"
rm -f "$PROGRESS_LAST_UPDATE_FILE"
SYNC_AUTO_SPLIT_DEPTH=2
progress_task_update "📂 子目录拆分（depth=3，正在统计各子目录大小...）" >/dev/null
chk "L8b d2 note 落槽" "$([ -f "$(_progress_slot_note 2)" ] && echo yes || echo no)" "yes"
chk "L8c 深层写入清除浅层 note（d1 已清）" "$([ -f "$(_progress_slot_note 1)" ] && echo 残留 || echo 已清)" "已清"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
