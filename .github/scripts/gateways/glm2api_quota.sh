#!/usr/bin/env bash
# glm2api 积分采集（供 Telegram 通知的「💳 积分」分节消费）
#
# 位置：.github/scripts/gateways/glm2api_quota.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 的 glm2api 步骤（采集）与收尾步骤（落盘）
#
# 为什么单独成脚本：通知里要显示「余额 + 本轮消耗 + 今日累计消耗」，后者必须跨
# workflow 轮次累计（每轮 ~5.75h，runner 本地盘不保）。采集逻辑与通知版式解耦，
# 状态落在 STATE_DIR（由 workflow 指向可归档目录），随既有归档流程回推 Dropbox。
#
# 为什么用 left_score 而不是别的字段（2026-09-27 实测）：
#   - member_info 的 left_score 是真实扣费计数：agent 通道单次短消息扣 94~95 分，
#     chat 通道连打 6 次扣 0；
#   - 结算有几秒延迟（同轮内立刻读可能读到不变），故采集点放在自检之后；
#   - 两个接口同名但差 100 倍（整数 vs 两位小数字符串），统一取 member-api 的整数。
#
# 用法：
#   glm2api_quota.sh fetch            # 查当前余额，输出 TSV：余额<TAB>规则<TAB>会员状态
#   glm2api_quota.sh delta <当前余额>  # 与上次快照比，输出 TSV：本轮消耗<TAB>今日累计<TAB>今日日期
set -u

STATE_DIR="${GLM2API_STATE_DIR:-/tmp/local_glm2api}"
SNAP="$STATE_DIR/quota-snapshot"

log() { printf '[glm2api-quota] %s\n' "$*"; }

# 取当前积分余额。走 agentmore 域（与 chat 域同登录态，实测都返回同一份 member 数据）。
# 失败时输出空串 + 非 0 退出，由调用方决定降级（通知里少一节，不阻断服务）。
cmd_fetch() {
  local token code body score rule status
  token="${GLM_REFRESH_TOKEN:-}"
  [ -n "$token" ] || { log "❌ 未注入 GLM_REFRESH_TOKEN，无法查积分"; return 1; }

  # 用 refresh_token 换 access_token，再查 member_info。
  # 走 python 而不是 curl 手拼：签名头（X-Sign/X-Timestamp/X-Nonce）由项目
  # 鉴权模块生成，避免与服务端实现漂移（本地已验证该路径可用）。
  local out
  out="$(cd /tmp/local_glm2api 2>/dev/null && PYTHONPATH=/tmp/local_glm2api/src \
    /tmp/local_glm2api/.venv/bin/python - <<'PY' 2>/dev/null
import json, logging, sys, urllib.request, urllib.error, uuid, os
sys.path.insert(0, "/tmp/local_glm2api/src")
logging.basicConfig(level=logging.CRITICAL)
try:
    from glm2api.config import load_config
    from glm2api.services.glm_auth import GLMAccessTokenManager, build_sign
    cfg = load_config("/tmp/local_glm2api/.env")
    auth = GLMAccessTokenManager(config=cfg, logger=logging.getLogger("q"))
    access = auth.get_access_token_for_account(0)
    ts, nonce, sign = build_sign()
    H = {**auth.get_browser_headers(), "Authorization": f"Bearer {access}",
         "Accept": "application/json", "X-Device-Id": uuid.uuid4().hex,
         "X-App-Platform": "mac", "X-App-Version": "2.0.5",
         "X-Nonce": nonce, "X-Sign": sign, "X-Timestamp": ts,
         "Origin": "https://agentmore.chatglm.cn",
         "Referer": "https://agentmore.chatglm.cn/"}
    url = "https://agentmore.chatglm.cn/chatglm/member-api/member/member_info"
    with urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=25) as r:
        d = json.loads(r.read().decode("utf-8", "ignore"))["result"]
    print(json.dumps({"score": d.get("left_score"), "rule": d.get("score_rule", "")}))
except Exception as e:
    print(json.dumps({"error": str(e)[:200]}))
PY
)" || true

  score="$(printf '%s' "$out" | jq -r '.score // empty' 2>/dev/null || true)"
  rule="$(printf '%s' "$out" | jq -r '.rule // empty' 2>/dev/null || true)"
  if [ -z "$score" ]; then
    log "❌ 查积分失败：$(printf '%s' "$out" | head -c 150)"
    return 1
  fi
  # 会员状态：1 非会员 / 2 有效 / 3 已过期（App 壳 profile-service.js 口径）
  printf '%s\t%s\n' "$score" "$rule"
  return 0
}

# 与上次快照比较，算本轮消耗与今日累计；跨日自动清零。
cmd_delta() {
  local cur="${1:-}"
  [ -n "$cur" ] || { log "用法: $0 delta <当前余额>"; return 1; }
  mkdir -p "$STATE_DIR" 2>/dev/null || true

  local today prev_score prev_date round_delta day_total
  today="$(date +%F)"
  prev_score="$(grep -m1 '^score=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
  prev_date="$(grep -m1 '^date=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"

  if [ -z "$prev_score" ]; then
    round_delta=0; day_total=0
  else
    # 余额下降 = 消耗；余额上升（每日登录赠送）不计为负消耗，按 0 处理
    round_delta=$((prev_score - cur))
    [ "$round_delta" -lt 0 ] && round_delta=0
    if [ "$prev_date" = "$today" ]; then
      day_total=$round_delta
    else
      day_total=0   # 跨日：本轮即今日首笔
    fi
  fi

  # 累计今日消耗：把本轮增量累加到快照里的今日累计
  local prev_day_total=0
  if [ "$prev_date" = "$today" ]; then
    prev_day_total="$(grep -m1 '^day_total=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
    [ -z "$prev_day_total" ] && prev_day_total=0
  fi
  day_total=$((prev_day_total + round_delta))

  umask 077
  {
    printf 'date=%s\n' "$today"
    printf 'score=%s\n' "$cur"
    printf 'day_total=%s\n' "$day_total"
  } > "$SNAP" 2>/dev/null || true

  printf '%s\t%s\t%s\n' "$round_delta" "$day_total" "$today"
  return 0
}

case "${1:-}" in
  fetch) cmd_fetch ;;
  delta) cmd_delta "${2:-}" ;;
  *) echo "用法: $0 {fetch|delta <当前余额>}"; exit 1 ;;
esac
