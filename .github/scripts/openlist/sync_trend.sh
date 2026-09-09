#!/bin/bash
# ===== OpenList 同步工具 — 跨 run 传输趋势（P0 可见化）=====
# 回答"照现在的速度，还要多久传完"。此前该问题没有数据支撑:
#   每轮 run 实际净传多少、全量还剩多少、速率趋势如何，全部散落在
#   单次 Telegram 消息里且跨 run 不可比（2026-09-08 评估: 实测有效吞吐
#   ~40KiB/s 量级，但"剩余量"从未被测量过，无法判断全量收敛时间）。
#
# 机制:
#   - 预览 pass 结束后，同步 step 调 trend_capture_remaining 把全量
#     "未传量"（PREVIEW_PENDING_MAP 合计）落本地文件
#     （skip_preview=true 时该文件不存在 = 本轮剩余未知，历史样本兜底）
#   - 每次实际传输完成后，_sync_task_finalize / 最终完整同步尾部调
#     trend_record_transferred 把净传字节追加到本地日志
#     （只记"本调用内 sync_with_logging 真正跑过"的路径，子目录聚合/
#     预览/跳过不计，各项相加即本轮真实净传，无重复计数）
#   - 收尾 step（always()，被取消的 run 也执行）调 trend_record_and_notify:
#     追加 {时间戳, run_id, 触发, 历时, 净传, 剩余} 到
#     onedrive:/logs/sync_state/trend.jsonl 并回传（随收尾既有的
#     sync_state → dropbox 镜像自动获得外置副本），
#     然后发送 "📈 同步趋势" 通知（近 N 轮净传速率 + 剩余 + 预计清零）
#
# 并发口径: trend.jsonl 的读-改-写依赖 workflow 级 concurrency 单例
# （openlist-singleton）；下载彻底失败时放弃回传只发通知（宁丢一条样本，
# 不覆盖历史——与 sync_marker 的"避免过期副本覆盖远端"同一原则）。
# 依赖: utils.sh (format_bytes), telegram.sh (send_telegram_message),
#       tg_notify.sh (tg_add_*), rclone, python3
# 加载位置: load_all.sh L3 层（先于 task_preview/task_engine 引用其文件路径）

TREND_FILE="onedrive:/logs/sync_state/trend.jsonl"
TREND_MAX_ENTRIES="60"          # jsonl 最多保留条数（防无限增长）
TREND_SUMMARY_ROUNDS="5"        # 速率计算取最近 N 轮
TREND_REMAINING_FILE="/tmp/ol_trend_remaining.txt"
TREND_TRANSFERRED_LOG="/tmp/ol_trend_transferred.log"
TREND_START_TS_FILE="/tmp/ol_trend_start_ts"

# 同步 step 开始时调用（收尾算历时用）
trend_capture_start() {
  date +%s > "$TREND_START_TS_FILE" 2>/dev/null || true
}

# 每次实际传输完成后调用（bytes；并行 worker 单行 echo 追加，O_APPEND 原子）
trend_record_transferred() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 0
  [ "$1" -gt 0 ] || return 0
  echo "$1" >> "$TREND_TRANSFERRED_LOG" 2>/dev/null || true
}

# 预览 pass 结束后调用: 全量未传量 = PREVIEW_PENDING_MAP 各对 bytes 合计
# （与预览通知"合计预估待同步"同口径，零额外列举）
trend_capture_remaining() {
  local _sum=0 _v
  if declare -p PREVIEW_PENDING_MAP >/dev/null 2>&1; then
    for _v in "${PREVIEW_PENDING_MAP[@]}"; do
      [[ "$_v" =~ ^[0-9]+ ]] && _sum=$((_sum + ${_v%% *}))
    done
  fi
  echo "$_sum" > "$TREND_REMAINING_FILE" 2>/dev/null || true
}

# 收尾时调用: 记录本次 run 并发送趋势通知
# 用法: trend_record_and_notify <run_id> <trigger>
trend_record_and_notify() {
  local run_id="${1:-unknown}" trigger="${2:-manual}"
  local _start_ts _now _duration _transferred=0 _remaining=""

  _start_ts=$(cat "$TREND_START_TS_FILE" 2>/dev/null || echo 0)
  [[ "$_start_ts" =~ ^[0-9]+$ ]] || _start_ts=0
  _now=$(date +%s)
  _duration=$((_now - _start_ts))
  [ "$_duration" -lt 0 ] && _duration=0

  if [ -f "$TREND_TRANSFERRED_LOG" ]; then
    _transferred=$(awk '{s+=$1} END{printf "%d", s+0}' "$TREND_TRANSFERRED_LOG" 2>/dev/null || echo 0)
  fi
  [[ "$_transferred" =~ ^[0-9]+$ ]] || _transferred=0

  if [ -f "$TREND_REMAINING_FILE" ]; then
    _remaining=$(head -1 "$TREND_REMAINING_FILE" 2>/dev/null)
  fi
  [[ "$_remaining" =~ ^[0-9]+$ ]] || _remaining=""

  # 读-改-写 trend.jsonl。三种情形分开处理:
  #   a) 远端不存在（首次启用）→ 全新创建，直接上传
  #   b) 远端存在且读取成功 → 追加后回传
  #   c) 远端存在但读取失败（网络抖动，重试一次后仍失败）→ 放弃回传只发
  #      通知（宁丢一条样本，不用 1 条记录覆盖历史——与 sync_marker 的
  #      "避免过期副本覆盖远端"同一原则）
  # lsf 本身失败（网络不可达）按"存在"处理走保护路径
  local _local="/tmp/ol_trend.jsonl" _dl_ok=0 _remote_exists=0 _lsf_out
  if _lsf_out=$(rclone lsf "$(dirname "$TREND_FILE")" 2>/dev/null); then
    echo "$_lsf_out" | grep -qxF "$(basename "$TREND_FILE")" && _remote_exists=1
  else
    _remote_exists=1
  fi
  if [ "$_remote_exists" = "1" ]; then
    rclone cat "$TREND_FILE" > "$_local" 2>/dev/null && _dl_ok=1
    if [ "$_dl_ok" = "0" ]; then
      : > "$_local"
      sleep 3
      rclone cat "$TREND_FILE" > "$_local" 2>/dev/null && _dl_ok=1
    fi
  else
    : > "$_local"
  fi

  printf '{"ts":"%s","run_id":"%s","trigger":"%s","duration_s":%d,"transferred_bytes":%d,"remaining_bytes":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_id" "$trigger" "$_duration" "$_transferred" \
    "${_remaining:-null}" >> "$_local"

  # 回传保护: 远端存在但读取彻底失败 → 宁可丢弃本次样本，也不让 copyto
  # 用本地残缺内容覆盖远端全部历史（情形 c）
  if [ "$_remote_exists" = "1" ] && [ "$_dl_ok" = "0" ]; then
    echo "⚠️ trend.jsonl 下载失败，跳过回传（防历史覆盖），仅发通知"
    _trend_send_summary "$_local"
    return 0
  fi
  tail -n "$TREND_MAX_ENTRIES" "$_local" > "$_local.t" 2>/dev/null && mv "$_local.t" "$_local"
  rclone copyto "$_local" "$TREND_FILE" 2>/dev/null \
    || echo "⚠️ trend.jsonl 回传失败（趋势通知仍按已下载数据展示）"
  _trend_send_summary "$_local"
}

_trend_fmt_duration() {
  local s="${1:-0}" h m
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

_trend_send_summary() {
  local _local="$1" _py_out
  _py_out=$(python3 - "$_local" "$TREND_SUMMARY_ROUNDS" <<'PYEOF' 2>/dev/null
import json, sys, datetime
path, rounds = sys.argv[1], int(sys.argv[2])
entries = []
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
except Exception:
    pass

def ts(e):
    try:
        return datetime.datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0

entries.sort(key=ts)
recent = entries[-rounds:] if entries else []
tot_tr = sum(e.get("transferred_bytes") or 0 for e in recent)
tot_du = sum(e.get("duration_s") or 0 for e in recent)
rate = (tot_tr / tot_du * 3600.0) if tot_du > 0 else 0.0
rem = None
for e in reversed(entries):
    if e.get("remaining_bytes") is not None:
        rem = int(e["remaining_bytes"])
        break
eta = (rem / rate) if (rem is not None and rate > 0) else None
cur = entries[-1] if entries else {}
print("rounds=%d" % len(recent))
print("this_transferred=%d" % (cur.get("transferred_bytes") or 0))
print("this_duration=%d" % (cur.get("duration_s") or 0))
print("rate_per_hour=%.1f" % rate)
print("remaining=%s" % (rem if rem is not None else ""))
print("eta_hours=%s" % (("%.1f" % eta) if eta is not None else ""))
print("history=%d" % len(entries))
PYEOF
) || _py_out=""

  local _rounds=0 _this_tr=0 _this_du=0 _rate=0 _rem="" _eta="" _hist=0 _k _v
  while IFS='=' read -r _k _v; do
    case "$_k" in
      rounds)           _rounds=$_v ;;
      this_transferred) _this_tr=$_v ;;
      this_duration)    _this_du=$_v ;;
      rate_per_hour)    _rate=$_v ;;
      remaining)        _rem=$_v ;;
      eta_hours)        _eta=$_v ;;
      history)          _hist=$_v ;;
    esac
  done <<< "$_py_out"
  [[ "$_rounds" =~ ^[0-9]+$ ]] || _rounds=0
  [[ "$_rate" =~ ^[0-9.]+$ ]] || _rate=0

  local msg=""
  tg_add_title msg "📈 同步趋势"
  tg_add_section msg "本轮"
  tg_add_kv msg "净传 / 历时" "$(format_bytes "$_this_tr") / $(_trend_fmt_duration "$_this_du")"
  if [ "$_rounds" -gt 1 ]; then
    tg_add_section msg "近 ${_rounds} 轮"
    tg_add_kv msg "平均净传速率" "$(format_bytes "${_rate%.*}")/h"
    if [ -n "$_rem" ]; then
      tg_add_kv msg "剩余未传" "$(format_bytes "$_rem")"
      if [ -n "$_eta" ]; then
        tg_add_kv msg "预计清零" "约 ${_eta} 小时（按近 ${_rounds} 轮速率，含跳过等待）"
      fi
    else
      tg_add_block msg "剩余未传未知（近期 run 未启用预览，无法估算清零时间）"
    fi
  fi
  tg_add_footer msg
  send_telegram_message "$msg"
}
