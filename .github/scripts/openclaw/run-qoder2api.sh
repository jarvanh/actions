#!/usr/bin/env bash
# openclaw 工作流「Run qoder2api-hub container」步骤本体（2026-10-30 原样搬移自
# yml，零逻辑改动）。外置背景：workflow 文件 2026-10-29（f08b15f）起突破
# GitHub workflow 500KB（=512,000 字节）上限 —— 同款模式给 yml 减重。
# 与 yml 薄包装的接口：
#   入口 env（步骤 env 注入）：TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TG_RUN_URL
#   文件依赖：$HOME/ts.env（Tailscale 步骤落盘，看板入口两行用）
#   消费方：/dropbox/self-hosted/qoder2api/（数据直写 Dropbox）
# 本步骤无 P5b 后台结构（行内执行）；体内自带 set -euo pipefail。
# 调用方用 `bash -eo pipefail`（= GitHub run: 默认语义）。

set -euo pipefail
# 通知真源在 step 顶层 source 一次（对齐 trae2api 段注释）
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"
# TS_FQDN 由 Tailscale 步骤写入 ts.env，step 间不共享 env，需显式加载
# （对齐 autoclaw 段写法）；缺失时看板入口两行整体跳过，不影响网关本身。
[ -f "$HOME/ts.env" ] && . "$HOME/ts.env" || true

QODER_DATA=/dropbox/self-hosted/qoder2api
QODER_PORT="8790"
# 动态解析**本仓库（fork）**最新 release tag：禁止固定 pin，否则每 5 分钟 workflow
# 会把已部署的新版本重建回旧版（2026-10-26 实测 1.7.6 被 1.7.3 覆盖）。
# 2026-10-28 改指 jarvanh fork：上游无 push 权限，110 停放 + 流式真实状态码
# 两处根治只在 fork 里；每日 09:00 同步自动化会把上游新提交合进 fork 再发版，
# 所以「fork 最新 release」仍等于「上游最新 + 本地根治」，不违背不 pin 的约束。
QODER_TAG="$(gh api repos/jarvanh/qoder2api-hub/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//')"
if [ -z "$QODER_TAG" ]; then
  QODER_TAG="$(git ls-remote --tags --refs https://github.com/jarvanh/qoder2api-hub.git 2>/dev/null | awk -F/ '{print $3}' | sed 's/^v//' | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
fi
if [ -z "$QODER_TAG" ]; then
  echo "::error::无法解析 qoder2api-hub 最新 release tag"
  exit 1
fi
QODER_IMAGE="ghcr.io/jarvanh/qoder2api-hub:${QODER_TAG}"

# 通知版式对齐 trae_notify / wb_notify：标题 + 结论/版本/更新/接口/鉴权 +
# 数据目录 + 原始输出。用法: qoder_notify <标题> <结论> <版本> <更新> <原因> <原始输出> <就绪态>
# 第 7 参 = 服务就绪态，取 "1" 才补「接口 / 看板 / API Key」三行（失败时服务
# 已不在，展示指向已停进程的地址会误导读者，与 wb_notify 同口径）。
qoder_notify() {
  QODER_NOTIFY_OK=0
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    local _msg=""
    tg_add_title _msg "$1"
    tg_add_kv _msg "结论" "$2"
    tg_add_path _msg "数据目录" "$QODER_DATA"
    [ -n "$3" ] && tg_add_path _msg "版本" "$3"
    [ -n "$4" ] && tg_add_kv _msg "更新" "$4"
    if [ "${7:-0}" = "1" ]; then
      tg_add_path _msg "接口" "http://127.0.0.1:${QODER_PORT}/v1"
      # 看板入口 + 面板密码（与看板 admin_entries 统一走 https 8447）：
      # ts.env 由 Tailscale 步骤在本 step 之前写出；缺失时两行整体跳过。
      if [ -n "${TS_FQDN:-}" ]; then
        tg_add_path _msg "看板" "https://${TS_FQDN}:8447/"
        local _qp="$(cat "$QODER_DATA/.panel-password" 2>/dev/null || true)"
        tg_add_path _msg "看板密码" "${_qp:-未取到}"
      fi
      # 明文 API Key（对齐 wb/trae 展示口径）
      tg_add_path _msg "API Key" "$(read_qoder_key | grep . || echo 未取到)"
    fi
    [ -n "$5" ] && tg_add_kv _msg "原因" "$5"
    if [ -n "$6" ]; then
      tg_add_pre _msg "$(tg_tail_safe "$6" 1200)"
    fi
    tg_add_footer _msg
    if send_tg "$_msg" alert; then
      QODER_NOTIFY_OK=1
    else
      echo "::warning::TG 通知发送失败（不影响任务）"
    fi
  else
    echo "⚠️ Telegram secrets missing, skip qoder2api notification."
  fi
}

# 明文 API Key 读取 helper（面板管理 Key 优先、回落 launcher Key —— 与
# 网关侧 api_key_override 取值顺序一致）；多调用点共用，避免两处写歪。
read_qoder_key() {
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print((d.get("api_key") or d.get("launcher_key") or "") if d.get("api_key_set") else (d.get("launcher_key") or ""))' "$QODER_DATA/accounts/settings.json" 2>/dev/null || true
}

echo "1. Bootstrap credentials (idempotent, Dropbox 为准)..."
mkdir -p "$QODER_DATA/accounts" "$QODER_DATA/usage"
if [ ! -s "$QODER_DATA/accounts/settings.json" ]; then
  # 首启凭据：launcher Key（qd- 前缀，同上游 ensure_launcher_key 形态）+
  # 面板密码随机生成；PBKDF2 摘要预写 settings.json（120000 轮与上游一致）。
  # 单行 python3 -c：YAML 块标量内多行 heredoc 体必须顶格才合法，会破坏
  # 块缩进（omniroute 的 heredoc+sed 先例是给数据文件用的）；凭据生成逻辑
  # 短小，一行写完最稳，且与 qoder_settings.py _digest 逐字段对齐。
  QODER_KEY="qd-$(openssl rand -hex 24)"
  QODER_PANEL_PW="$(openssl rand -base64 18)"
  python3 -c 'import json,sys,secrets,hashlib,pathlib; p,k,w=sys.argv[1],sys.argv[2],sys.argv[3]; s=secrets.token_hex(16); d=hashlib.pbkdf2_hmac("sha256",w.encode(),bytes.fromhex(s),120000).hex(); pathlib.Path(p).write_text(json.dumps({"launcher_key":k,"panel_password_salt":s,"panel_password_rounds":120000,"panel_password_hash":d,"panel_password_default":False},indent=2),encoding="utf-8")' \
    "$QODER_DATA/accounts/settings.json" "$QODER_KEY" "$QODER_PANEL_PW"
  # 面板密码明文单独落一份（fuse 权限位恒 666，边界在 Dropbox 账号侧；
  # 仅首次生成时写，便于从数据目录找回；看板内改密后此文件即过期）
  printf '%s\n' "$QODER_PANEL_PW" > "$QODER_DATA/.panel-password"
  echo "   凭据已生成（launcher Key qd-… + 面板密码 → .panel-password）"
fi

echo "2. Pull image & start container..."
# 拉取失败不硬退：沿用本地旧镜像先保住服务可用性（digest 仍如实入账；
# inspect 也兜 || true —— set -e 下命令替换失败会直接终止整 step）
docker pull -q "$QODER_IMAGE" || echo "⚠️ 镜像拉取失败，沿用本地镜像"
QODER_IMG_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$QODER_IMAGE" 2>/dev/null | awk -F'@' '{print substr($2,1,19)}' || true)"
QODER_VERSION="${QODER_TAG} @ ${QODER_IMG_DIGEST:-digest未知}"
# 幂等接管：清掉同名旧容器（可能来自上一轮或手工部署），再由本轮接管。
# 启动失败必须出声（continue-on-error 会吞掉非零退出，TG 是唯一可见通道）。
docker rm -f qoder2api >/dev/null 2>&1 || true
if ! docker run -d --name qoder2api \
  --restart unless-stopped \
  --network omniroute_default \
  -p ${QODER_PORT}:8790 \
  -e HOST=0.0.0.0 -e PORT=8790 -e TZ=Asia/Shanghai \
  -v "$QODER_DATA/accounts:/app/accounts" \
  -v "$QODER_DATA/usage:/app/usage" \
  "$QODER_IMAGE"; then
  qoder_notify "❌ qoder2api-hub 启动失败" "docker run 失败" \
    "$QODER_VERSION" "" "镜像缺失或端口/挂载冲突（详见运行日志）" \
    "$(docker logs --tail 40 qoder2api 2>&1 || true)" 0
  exit 1
fi

echo "3. Health check..."
_code=""
for i in $(seq 1 60); do
  _code=$(curl -s --connect-timeout 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${QODER_PORT}/ping" || true)
  if [ "$_code" = "200" ]; then
    echo "✅ [qoder2api] ${QODER_PORT} 已就绪 (HTTP 200)"
    break
  fi
  echo "⏳ [qoder2api] 等待中... ${i}/60"
  sleep 2
done
if [ "${_code:-}" != "200" ]; then
  echo "❌ qoder2api 未在 120 秒内就绪" >&2
  qoder_notify "❌ qoder2api-hub 启动失败" \
    "未就绪 · 120 秒健康检查超时" \
    "$QODER_VERSION" "" "镜像拉取或启动失败（详见运行日志）" \
    "$(docker logs --tail 60 qoder2api 2>&1 || true)" 0
  exit 1
fi

echo "4. Auth self-check..."
_qk="$(read_qoder_key)"
_mk="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${_qk}" "http://127.0.0.1:${QODER_PORT}/v1/models" || true)"
_mn="$(curl -s -H "Authorization: Bearer ${_qk}" "http://127.0.0.1:${QODER_PORT}/v1/models" 2>/dev/null | jq -r '(.data | length) // 0' 2>/dev/null || echo 0)"
echo "   /v1/models 带鉴权: HTTP ${_mk} · 官方模型 ${_mn} 个（双区动态清单）"

echo "5. Account pool snapshot..."
# 账号池即 accounts/ 下除 settings.json / active_realm.json 外的 *.json
# （与网关 AccountPool.load() 的过滤口径一致）
_accs="$(find "$QODER_DATA/accounts" -maxdepth 1 -name '*.json' ! -name 'settings.json' ! -name 'active_realm.json' 2>/dev/null | wc -l | tr -d ' ')"

echo "6. Version ledger & notification..."
# 更新判定用镜像 digest（浮动 tag 1.6 下 tag 恒定，digest 才是真实版本指纹）。
# 记录写在健康通过之后 —— 未就绪的轮次不落账，下轮仍报「更新」（对齐 trae2api）。
QODER_VER_FILE="$QODER_DATA/.installed-version"
QODER_LOCAL_VER="$(head -n 1 "$QODER_VER_FILE" 2>/dev/null || true)"
if [ -n "$QODER_LOCAL_VER" ] && [ "$QODER_LOCAL_VER" = "$QODER_IMG_DIGEST" ]; then
  QODER_UPDATE="已在 ${QODER_VERSION} · 镜像层缓存复用"
elif [ -n "$QODER_LOCAL_VER" ]; then
  QODER_UPDATE="从 ${QODER_LOCAL_VER} 更新到 ${QODER_IMG_DIGEST}"
else
  QODER_UPDATE="首次部署 ${QODER_VERSION}"
fi
_title="🟢 qoder2api-hub 已就绪"
_conclusion="已就绪 · 官方模型 ${_mn} 个"
[ "${_accs:-0}" -gt 0 ] && _conclusion="${_conclusion} · 账号 ${_accs}（看板 OAuth 可添加）"
[ "${_accs:-0}" -eq 0 ] && _conclusion="${_conclusion} · 账号池空（看板「+ 添加账号 (OAuth)」入池）"
# 账号池签到状态（2026-10-27 主人要求「都加上」）：读账号文件 lastCheckin
# （容器 TZ=Asia/Shanghai 墙钟串）比对北京日界，今日增量取 lastCreditsDelta
# 合计。jq 解析失败或无账号池时整段省略，不编 0。
if [ "${_accs:-0}" -gt 0 ]; then
  _qd_ck="$(jq -rs --arg d "$(TZ=Asia/Shanghai date +%F)" '
    [ .[] | select(.uid != null and .enabled != null) ] as $a
    | [ $a[] | select(((.lastCheckin // "")[0:10]) == $d) ] as $s
    | if ($a | length) == 0 then ""
      else ("\($s | length)/\($a | length)") +
           (if ([ $s[] | (.lastCreditsDelta // 0) ] | add // 0) > 0
            then " · 今日 +\([ $s[] | (.lastCreditsDelta // 0) ] | add)"
            else "" end) end
  ' "$QODER_DATA"/accounts/*.json 2>/dev/null || true)"
  [ -n "$_qd_ck" ] && _conclusion="${_conclusion} · 签到 ${_qd_ck}"
fi
qoder_notify "$_title" "$_conclusion" "$QODER_VERSION" "$QODER_UPDATE" "" "" 1
# 发送成功才落版本标记：失败时下轮仍报更新，不丢「从 X 更新到 Y」。
if [ "${QODER_NOTIFY_OK:-0}" = "1" ] && [ -n "$QODER_IMG_DIGEST" ]; then
  printf '%s\n' "$QODER_IMG_DIGEST" > "$QODER_VER_FILE"
fi
