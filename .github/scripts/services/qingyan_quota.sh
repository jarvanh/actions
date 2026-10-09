#!/usr/bin/env bash
# qingyan-proxy 积分采集（供 Telegram 通知的「💳 积分」分节消费）
#
# 位置：.github/scripts/services/qingyan_quota.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 的 qingyan-proxy 步骤（采集）与收尾步骤（落盘）
#
# 为什么单独成脚本：通知里要显示「余额 + 本轮消耗 + 今日累计消耗」，后者必须跨
# workflow 轮次累计（每轮 ~5.75h，runner 本地盘不保）。采集逻辑与通知版式解耦，
# 状态落在 STATE_DIR（由 workflow 指向数据目录），随 deploy push 回推 Dropbox。
#
# 为什么鉴权走 proxy.py 而不是手拼请求头：签名头（X-Sign/X-Timestamp/X-Nonce）
# 的算法与刷新轮换逻辑都在服务同款 proxy.py 里（qingyan_deploy 拉下来的运行
# 目录），直接 import 复用，永不与主服务漂移；401 时走同一套轮换式 refresh，
# 新票写回状态文件，服务进程靠 mtime 缓存失效自动跟上。
#
# 为什么 member_info 用 agentmore 域 + mac/2.0.5 平台头（glm2api 时代实测，2026-09-27）：
#   - member_info 的 left_score 是真实扣费计数：agent 通道单次短消息扣 94~95 分，
#     chat 通道连打 6 次扣 0；
#   - 结算有几秒延迟（同轮内立刻读可能读到不变），故采集点放在自检之后；
#   - 两个接口同名但差 100 倍（整数 vs 两位小数字符串），统一取 member-api 的整数。
#   这组平台头是 member-api 的实测可用组合，与主服务 chat 域的 pc/1.7.x 口径不同，
#   照抄实测值不赌。
#
# 用法：
#   qingyan_quota.sh fetch            # 查当前余额 + 最近到期，输出 TSV：
#                                     #   余额<TAB>规则<TAB>最近到期时间<TAB>24h内将过期
#   qingyan_quota.sh delta <当前余额> [最近到期] [24h将过期]
#                                     # 与上次快照比，输出 TSV：本轮消耗<TAB>今日累计<TAB>今日日期
#                                     # 后两参可选（2026-10-09 加）：把 fetch 拿到的到期信息
#                                     # 一并落进快照，供 quota-board 读「总积分 / 即将过期」
set -u

# 2026-10-06 起 qingyan 全面跑在 Dropbox 上（代码/数据/凭据/日志），**不存在
# /tmp 运行副本**。三个默认值一律指向 Dropbox 真源，不再回退到 /tmp。
DATA_ROOT="/dropbox/self-hosted/qingyan-proxy"
STATE_DIR="${QINGYAN_STATE_DIR:-$DATA_ROOT/data}"
SNAP="$STATE_DIR/quota-snapshot"
ENV_FILE="${QINGYAN_ENV_FILE:-$DATA_ROOT/env.sh}"
# 积分采集只需 import proxy 复用其签名/刷新逻辑，故指向 Dropbox 代码真源
APP_DIR="${QINGYAN_APP_DIR:-$DATA_ROOT/app}"

log() { printf '[qingyan-quota] %s\n' "$*"; }

# 整数口径（member-api，真值两位小数 ×100）→ 真值积分。
#
# ⚠️ 背景（2026-10-06 实测）：member-api 的 left_score 与积分流水 score_record
# 的 score **同名但差 100 倍**（前者整数、后者两位小数）。此前统一取 member-api
# 的整数值却**没在展示前还原**，于是通知里「今日已消耗 167342」—— 而流水里
# 今日实际消耗是 1673.42，整整放大 100 倍。旁证：规则写「免费用户登录赠送
# 200 积分/天」，按未还原值算余额 729544 够领 3647 天，还原成 7295.44 才约
# 36 天量，后者才合理。
# 旧快照无小数点 → 判为旧整数口径，÷100 迁移；已有小数点的按真值原样返回。
_qy_to_real() {
  local v="${1:-}"
  [ -z "$v" ] && { printf '0'; return 0; }
  case "$v" in
    *.*) printf '%s' "$v" ;;
    *) awk -v x="$v" 'BEGIN{printf "%.2f", x/100}' ;;
  esac
}

# 取当前积分余额。失败时输出空串 + 非 0 退出，由调用方决定降级
# （通知里少一节，不阻断服务）。
cmd_fetch() {
  # 代码真源在 Dropbox app 目录（见文件头 APP_DIR 注释）
  [ -s "$APP_DIR/proxy.py" ] || { log "❌ Dropbox app 目录缺 proxy.py：$APP_DIR"; return 1; }
  # 传给下面的 python（heredoc 是 <<'PY' 不展开 shell 变量，改由环境传递）
  export QINGYAN_APP_DIR="$APP_DIR"
  # proxy.py 按环境变量定位凭证状态文件（文件模式），先 source env.sh（600）
  # 把 QINGYAN_CRED_FILE / QINGYAN_REFRESH_TOKEN 等灌进来
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE" 2>/dev/null || { log "❌ 无法读取 $ENV_FILE"; return 1; }
  set +a

  local out
  out="$(/usr/bin/python3 - <<'PY' 2>/dev/null
import json, os, sys, time, urllib.request, urllib.error, uuid
# 代码真源在 Dropbox app 目录（由 shell 经 QINGYAN_APP_DIR 传入）
sys.path.insert(0, os.environ.get("QINGYAN_APP_DIR") or "/dropbox/self-hosted/qingyan-proxy/app")
import proxy

MEMBER_URL = "https://agentmore.chatglm.cn/chatglm/member-api/member/member_info"
REC_URL = "https://chatglm.cn/chatglm/member-api/member/score_record"


def _headers(token):
    # agentmore 域实测组合：mac / 2.0.5 / 随机 32 位 hex 设备号（见文件头注释）
    H = proxy.base_headers(f"Bearer {token}")
    H["X-Device-Id"] = uuid.uuid4().hex
    H["X-App-Platform"] = "mac"
    H["X-App-Version"] = "2.0.5"
    H["Origin"] = "https://agentmore.chatglm.cn"
    H["Referer"] = "https://agentmore.chatglm.cn/"
    return H


def _member(token):
    with urllib.request.urlopen(
            urllib.request.Request(MEMBER_URL, headers=_headers(token)), timeout=25) as r:
        return json.loads(r.read().decode("utf-8", "ignore"))["result"]


try:
    d = None
    H = None
    access = (proxy.read_credentials() or {}).get("token") or ""
    if access:
        try:
            H = _headers(access)
            with urllib.request.urlopen(
                    urllib.request.Request(MEMBER_URL, headers=H), timeout=25) as r:
                d = json.loads(r.read().decode("utf-8", "ignore"))["result"]
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise
            d = None
    if d is None:
        # 无 access token（首轮只有种子）或已 401：轮换新票后重试。
        # proxy.refresh_access_token 会把新票写回状态文件（轮换式，旧票作废）。
        new_access = proxy.refresh_access_token(proxy.read_credentials(force=True))
        if not new_access:
            raise RuntimeError("refresh token 不可用，拿不到 access token")
        H = _headers(new_access)
        with urllib.request.urlopen(
                urllib.request.Request(MEMBER_URL, headers=H), timeout=25) as r:
            d = json.loads(r.read().decode("utf-8", "ignore"))["result"]

    # 过期时间只在积分流水里（余额接口没有）：翻到 has_more=false 才准。
    # 实测两类有效期：登录赠送约 24h、任务奖励一年；消耗记录 expired_at=0 不计。
    soonest = 0
    soonest_amt = 0.0
    soon_24h = 0.0
    now = time.time()
    for page in range(1, 11):
        rec = f"{REC_URL}?page={page}&page_size=50"
        try:
            with urllib.request.urlopen(urllib.request.Request(rec, headers=H), timeout=25) as rr:
                rd = json.loads(rr.read().decode("utf-8", "ignore"))["result"]
        except Exception:
            break
        items = rd.get("list") or []
        for it in items:
            try:
                amt = float(it.get("score") or 0)
            except (TypeError, ValueError):
                continue
            exp = int(it.get("expired_at") or 0)
            if amt <= 0 or exp <= 0:
                continue
            if exp > 1e10:
                exp = exp // 1000
            delta = exp - now
            if delta <= 0:
                continue
            if delta <= 86400:
                soon_24h += amt
            if soonest == 0 or exp < soonest:
                soonest = exp
                soonest_amt = amt
        if not rd.get("has_more") or not items:
            break

    print(json.dumps({
        "score": d.get("left_score"),
        "rule": d.get("score_rule", ""),
        "soonest": soonest,
        "soonest_amt": round(soonest_amt),
        "soon_24h": round(soon_24h),
    }))
except Exception as e:
    print(json.dumps({"error": str(e)[:200]}))
PY
)" || true

  score="$(printf '%s' "$out" | jq -r '.score // empty' 2>/dev/null || true)"
  # 还原成真值积分（见 _qy_to_real 注释：member-api 是整数口径 ×100）。
  # 在此统一转换，下游（通知展示 / 快照累计）全部按真值走，避免各消费方
  # 各自记得除以 100 —— 漏一处就重现「今日已消耗 167342」。
  [ -n "$score" ] && score="$(_qy_to_real "$score")"
  rule="$(printf '%s' "$out" | jq -r '.rule // empty' 2>/dev/null || true)"
  soonest="$(printf '%s' "$out" | jq -r '.soonest // 0' 2>/dev/null || true)"
  soonest_amt="$(printf '%s' "$out" | jq -r '.soonest_amt // 0' 2>/dev/null || true)"
  soon_24h="$(printf '%s' "$out" | jq -r '.soon_24h // 0' 2>/dev/null || true)"
  # 最近到期时间：0 表示没有带有效期的入账。
  # 时间格式化两个分支：ubuntu runner 有 GNU date -d；本机 macOS 只有
  # date -r（秒级）。两者都试，都失败才退成 "-"。
  if [ -n "$soonest" ] && [ "$soonest" -gt 0 ] 2>/dev/null; then
    soonest_fmt="$(date -d "@${soonest}" '+%m-%d %H:%M' 2>/dev/null \
                || date -r "${soonest}" '+%m-%d %H:%M' 2>/dev/null \
                || echo "-")"
  else
    soonest_fmt="-"
  fi
  if [ -z "$score" ]; then
    log "❌ 查积分失败：$(printf '%s' "$out" | head -c 150)"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$rule" "$soonest_fmt" "$soonest_amt" "$soon_24h"
  return 0
}

# 与上次快照比较，算本轮消耗与今日累计；跨日自动清零。
cmd_delta() {
  local cur="${1:-}"
  local soonest_in="${2:-}"
  local soon_24h_in="${3:-}"
  [ -n "$cur" ] || { log "用法: $0 delta <当前余额> [最近到期] [24h将过期]"; return 1; }
  mkdir -p "$STATE_DIR" 2>/dev/null || true

  local today prev_score prev_date round_delta day_total
  today="$(date +%F)"
  prev_score="$(grep -m1 '^score=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
  prev_date="$(grep -m1 '^date=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
  # 旧快照迁移：历史文件存的是整数口径，统一还原成真值再参与计算，
  # 否则本轮会把已有累计再放大 100 倍。
  prev_score="$(_qy_to_real "$prev_score")"

  if [ -z "$prev_score" ] || [ "$prev_score" = "0" ] || [ "$prev_score" = "0.00" ]; then
    round_delta="0"; day_total="0"
  else
    # 余额下降 = 消耗；余额上升（每日登录赠送）不计为负消耗，按 0 处理。
    # 真值带两位小数，故用 awk 浮点，不能用 $(( ))（bash 整数运算会报错）。
    round_delta="$(awk -v a="$prev_score" -v b="$cur" 'BEGIN{d=a-b; if (d<0) d=0; printf "%.2f", d}')"
    if [ "$prev_date" = "$today" ]; then
      day_total="$round_delta"
    else
      day_total="0"   # 跨日：本轮即今日首笔
    fi
  fi

  # 累计今日消耗：把本轮增量累加到快照里的今日累计
  local prev_day_total=0
  if [ "$prev_date" = "$today" ]; then
    prev_day_total="$(grep -m1 '^day_total=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
    prev_day_total="$(_qy_to_real "$prev_day_total")"
    [ -z "$prev_day_total" ] && prev_day_total="0"
  fi
  day_total="$(awk -v a="$prev_day_total" -v b="$round_delta" 'BEGIN{printf "%.2f", a+b}')"

  # 到期信息落盘（2026-10-09 加）：快照此前只落 date/score/day_total，
  # 到期时间压根没存 —— quota-board 就算想显示「即将过期」也没有数据源。
  # 取本次 fetch 的新值；未传则沿用快照旧值，避免单轮漏传就把已有信息清空。
  local prev_soonest prev_soon_24h
  prev_soonest="$(grep -m1 '^soonest=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
  prev_soon_24h="$(grep -m1 '^soon_24h=' "$SNAP" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$soonest_in" ] && prev_soonest="$soonest_in"
  [ -n "$soon_24h_in" ] && prev_soon_24h="$soon_24h_in"

  umask 077
  {
    printf 'date=%s\n' "$today"
    printf 'score=%s\n' "$cur"
    printf 'day_total=%s\n' "$day_total"
    printf 'soonest=%s\n' "${prev_soonest:--}"
    printf 'soon_24h=%s\n' "${prev_soon_24h:-0}"
  } > "$SNAP" 2>/dev/null || true

  printf '%s\t%s\t%s\n' "$round_delta" "$day_total" "$today"
  return 0
}

case "${1:-}" in
  fetch) cmd_fetch ;;
  delta) cmd_delta "${2:-}" "${3:-}" "${4:-}" ;;
  *) echo "用法: $0 {fetch|delta <当前余额> [最近到期] [24h将过期]}"; exit 1 ;;
esac
