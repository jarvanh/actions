#!/usr/bin/env bash
# keep-alive 轮询钩子（每 15s 调一次）：旧轮侧的交接触发 + 继任者就绪看门狗。
# 用法: tick.sh <距死线剩余秒数>
# 幂等：触发/看门狗各只做一次（状态文件落 /tmp/openclaw-handoff/）。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init

# 总开关（仓库变量 OPENCLAW_HANDOFF=1 才启用；未设 → 纯传统路径）
if [ "${OPENCLAW_HANDOFF:-}" != "1" ]; then
  exit 0
fi

REMAIN="${1:-0}"
case "$REMAIN" in ''|*[!0-9]*) REMAIN=0 ;; esac
TRIGGER_AT=$(( ${HANDOFF_TRIGGER_BEFORE_MIN:-12} * 60 ))
READY_AT=$(( ${HANDOFF_READY_DEADLINE_MIN:-4} * 60 ))
SID_FILE="$HANDOFF_STATE_DIR/successor-run-id"
ENABLED="$HANDOFF_STATE_DIR/enabled"
READY_OK="$HANDOFF_STATE_DIR/ready-ok"

# ── 手动交接开关（2026-11-11）──
# 用法：ssh runner@openclaw 'touch /tmp/openclaw-handoff-request'
# 语义 = 「不等 T-12min，立刻派发继任者；等它 ready 后立即交出」。
# 为什么不能一触即交：继任者要把基座恢复完（~10-12min）才能接流量，提前 cutover
# 只会在 cutover 的 5min 就绪等待里超时 → 退化成传统收尾（白停一次）。
# 与 /tmp/openclaw-restart-request 的区别：那个只提前收尾，不派发继任者。
FORCE_FILE="${HANDOFF_FORCE_FILE:-/tmp/openclaw-handoff-request}"
FORCE=0
if [ -f "$FORCE_FILE" ]; then FORCE=1; fi

# ── 1. 触发继任者（T-12min 或手动请求，一次性）──
if [ ! -f "$SID_FILE" ] && [ "$REMAIN" -gt 0 ] && { [ "$FORCE" = 1 ] || [ "$REMAIN" -le "$TRIGGER_AT" ]; }; then
  _backend="$(grep -E '^ACTIVE_BACKEND=' /tmp/active-ai-backend.env 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
  _backend="${_backend//[^a-z]/}"
  _backend="${_backend:-auto}"
  _t0=$(date +%s)
  if [ "$FORCE" = 1 ]; then
    echo "[handoff-tick] 🖐 手动交接请求：立即派发继任者（不等 T-${TRIGGER_AT}s，剩余 ${REMAIN}s）"
  else
    echo "[handoff-tick] T-${REMAIN}s：触发继任者（handoff_of=$GITHUB_RUN_ID ai_backend=$_backend）"
  fi
  if gh workflow run openclaw.yml --repo "${GITHUB_REPOSITORY}" --ref "${GITHUB_REF_NAME:-main}" \
      -f handoff_of="$GITHUB_RUN_ID" -f ai_backend="$_backend" 2>/dev/null; then
    # 拿新 run id：workflow_dispatch 里 createdAt 晚于触发瞬间、且非本 run 的最新一个。
    # 手动 dispatch 撞车的概率 = 用户恰在这 2s 内手动跑（可忽略），createdAt 过滤兜一层。
    _sid=""
    for _i in $(seq 1 30); do
      _sid="$(gh run list --repo "${GITHUB_REPOSITORY}" --workflow openclaw.yml \
        --json databaseId,event,createdAt --jq \
        "[.[] | select(.event==\"workflow_dispatch\" and .databaseId != ${GITHUB_RUN_ID} and .createdAt >= \"$(date -u -d "@$_t0" '+%Y-%m-%dT%H:%M:%SZ')\")] | sort_by(.createdAt) | reverse | .[0].databaseId" 2>/dev/null | head -n 1 || true)"
      case "${_sid:-}" in ''|*[!0-9]*) _sid="" ;; *) break ;; esac
      sleep 2
    done
    if [ -n "$_sid" ]; then
      echo "$_sid" > "$SID_FILE"
      : > "$ENABLED"
      # 2026-11-11 修：手动交接**不等死线**（继任者 ready 就交出，实测 3 分钟），
      # 不能再给「距死线还剩多少分钟」——那会让人以为还能写 4 小时（实测误导）。
      if [ "$FORCE" = 1 ]; then
        bash "$here/handoff-notify.sh" prepare "old_run=$GITHUB_RUN_ID" "new_run=$_sid" "manual=1" || true
      else
        bash "$here/handoff-notify.sh" prepare "old_run=$GITHUB_RUN_ID" "new_run=$_sid" \
          "eta=$(( REMAIN / 60 ))" || true
      fi
      echo "[handoff-tick] ✅ 交接已武装：继任者 run=$_sid（T-4min 前须 ready，否则被看门狗取消）"
      if [ "$FORCE" = 1 ]; then
        echo "[handoff-tick] 🖐 手动模式：等继任者 ready 后立即请求交出（不做 T-4min 取消）"
      fi
    else
      echo "[handoff-tick] ⚠️ 触发成功但 60s 内拿不到新 run id，交接放弃 → 死线走传统收尾"
    fi
  else
    echo "[handoff-tick] ⚠️ gh workflow run 失败，交接放弃 → 死线走传统收尾"
  fi
fi

# ── 2. 继任者存活监控（已武装期间随时）──
if [ -f "$ENABLED" ] && [ -f "$SID_FILE" ]; then
  _sid="$(cat "$SID_FILE" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$_sid" ] && [ ! -f "$READY_OK" ]; then
    _st="$(handoff_run_status "$_sid")"
    case "$_st" in
      completed|failure|cancelled)
        rm -f "$ENABLED"
        echo "[handoff-tick] ⚠️ 继任者 run=$_sid 已 $_st，交接解除武装 → 死线走传统收尾"
        ;;
    esac
  fi
fi

# ── 3. 就绪看门狗（T-4min，一次性）：没 ready 就取消继任者，保住传统收尾的时长预算 ──
# 手动模式下不需要额外豁免：本条只在 REMAIN ≤ T-4min 时才可能触发，
# 手动交接正常会在 ready 后立刻交出、根本走不到这里；万一继任者卡住，
# 这条反而正是兜底（到死线前 4 分钟仍未 ready → 取消它，走传统收尾）。
if [ -f "$ENABLED" ] && [ -f "$SID_FILE" ] && [ ! -f "$READY_OK" ] && [ "$REMAIN" -gt 0 ] && [ "$REMAIN" -le "$READY_AT" ]; then
  _sid="$(cat "$SID_FILE" 2>/dev/null | tr -dc '0-9')"
  _st="$(handoff_new_state "$_sid")"
  case "$_st" in
    ready|rsync_started|rsync_done|serving)
      : > "$READY_OK"
      echo "[handoff-tick] ✅ 继任者就绪（state=$_st），交接继续"
      ;;
    *)
      gh run cancel "$_sid" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1 || true
      rm -f "$ENABLED"
      echo "[handoff-tick] ⛔ 继任者 T-4min 未就绪（state=${_st:-<无标记>}），已取消 → 死线走传统收尾"
      ;;
  esac
fi

# ── 4. 手动交接：继任者 ready 后请求立即交出 ──
# 不在这里直接 cutover（cutover 属于收尾步骤），而是写 restart-request 让
# Keep alive 退出 → 走正常收尾链路 → cutover.sh 等 serving。
# 继任者 ready 意味着基座已恢复、rsync 即将/已经开始，此时交出最省时。
if [ "$FORCE" = 1 ] && [ -f "$SID_FILE" ]; then
  _sid="$(cat "$SID_FILE" 2>/dev/null | tr -dc '0-9')"
  _st="$(handoff_new_state "$_sid")"
  case "$_st" in
    ready|rsync_started|rsync_done|serving)
      echo "🖐 [handoff-tick] 继任者已 ${_st} → 请求立即交出（写 restart-request）"
      # 与 Keep alive 的 REQUEST_FILE 同一路径；可用 HANDOFF_RESTART_REQUEST 覆盖
      # （测试/多实例隔离 —— 固定写 /tmp 会让测试误触真实轮次的提前收尾）。
      echo "手动交接：继任者 run=${_sid} state=${_st}" \
        > "${HANDOFF_RESTART_REQUEST:-/tmp/openclaw-restart-request}"
      rm -f "$FORCE_FILE"
      # 派发时已发过「准备中（手动）」，此处不再重复发同一条；
      # 真正交出由 cutover.sh 的「已交出」通知承接。
      ;;
    aborted)
      echo "⚠️ [handoff-tick] 手动交接失败：继任者已放弃（state=aborted），解除手动请求 → 保持正常保活"
      rm -f "$FORCE_FILE"
      ;;
    *)
      echo "[handoff-tick] 🖐 手动交接进行中：继任者 state=${_st:-<无标记>}，等 ready…"
      ;;
  esac
fi
exit 0
