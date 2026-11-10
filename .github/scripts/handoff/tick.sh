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

# ── 1. 触发继任者（T-12min，一次性）──
if [ ! -f "$SID_FILE" ] && [ "$REMAIN" -gt 0 ] && [ "$REMAIN" -le "$TRIGGER_AT" ]; then
  _backend="$(grep -E '^ACTIVE_BACKEND=' /tmp/active-ai-backend.env 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
  _backend="${_backend//[^a-z]/}"
  _backend="${_backend:-auto}"
  _t0=$(date +%s)
  echo "[handoff-tick] T-${REMAIN}s：触发继任者（handoff_of=$GITHUB_RUN_ID ai_backend=$_backend）"
  if gh workflow run "${HANDOFF_WORKFLOW:-openclaw.yml}" --repo "${GITHUB_REPOSITORY}" --ref "${GITHUB_REF_NAME:-main}" \
      -f handoff_of="$GITHUB_RUN_ID" -f ai_backend="$_backend" 2>/dev/null; then
    # 拿新 run id：workflow_dispatch 里 createdAt 晚于触发瞬间、且非本 run 的最新一个。
    # 手动 dispatch 撞车的概率 = 用户恰在这 2s 内手动跑（可忽略），createdAt 过滤兜一层。
    _sid=""
    for _i in $(seq 1 30); do
      _sid="$(gh run list --repo "${GITHUB_REPOSITORY}" --workflow "${HANDOFF_WORKFLOW:-openclaw.yml}" \
        --json databaseId,event,createdAt --jq \
        "[.[] | select(.event==\"workflow_dispatch\" and .databaseId != ${GITHUB_RUN_ID} and .createdAt >= \"$(date -u -d "@$_t0" '+%Y-%m-%dT%H:%M:%SZ')\")] | sort_by(.createdAt) | reverse | .[0].databaseId" 2>/dev/null | head -n 1 || true)"
      case "${_sid:-}" in ''|*[!0-9]*) _sid="" ;; *) break ;; esac
      sleep 2
    done
    if [ -n "$_sid" ]; then
      echo "$_sid" > "$SID_FILE"
      : > "$ENABLED"
      echo "[handoff-tick] ✅ 交接已武装：继任者 run=$_sid（T-4min 前须 ready，否则被看门狗取消）"
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
exit 0
