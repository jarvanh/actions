set -uo pipefail

# workbuddy-gateway（CangShui/workbuddy-gateway）：纯 Go 单二进制的本地 AI 代理网关，
# 数据（凭据 workbuddy*.json、状态/日志）全部落在自托管目录 /dropbox/self-hosted/workbuddy-gateway，
# 与 OpenClaw 主包同宿主、随 Dropbox 跨轮持久化。
WB_DIR="/workspace/.wbtest/dropbox/self-hosted/workbuddy-gateway"
WB_BIN="$WB_DIR/workbuddy-gateway"
WB_RELEASE_BASE="https://github.com/CangShui/workbuddy-gateway/releases/latest/download"
WB_VER_FILE="$WB_DIR/.installed-version"
WB_META="/tmp/run-workbuddy-meta.env"
WB_LOG="$WB_DIR/logs/serve.log"
: > "$WB_META"

wb_notify() {
  # 用法: wb_notify <标题> <结论> <版本> <更新说明> <原因> <原始输出>
  # 版式（docs/telegram-notify.md 2.5 告警 / 4.7）：标题带状态 emoji 且与结论一致；
  # 结论/更新说明/原因是人写的自然语言 → 裸文本 kv，版本/路径是机器值 → <code>，
  # 原始输出 → <pre>（正文最后一块，其后只跟收尾区）。空值整行跳过。
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"
    local _msg=""
    tg_add_title _msg "$1"
    tg_add_kv _msg "结论" "$2"
    [ -n "$3" ] && tg_add_path _msg "版本" "$3"
    [ -n "$4" ] && tg_add_kv _msg "更新" "$4"
    [ -n "$5" ] && tg_add_kv _msg "原因" "$5"
    tg_add_path _msg "数据目录" "$WB_DIR"
    if [ -n "$6" ]; then
      tg_add_section _msg "🧾 原始输出"
      tg_add_pre _msg "$(printf '%s' "$6" | tail -c 1200)"
    fi
    tg_add_footer _msg
    send_tg "$_msg" || echo "::warning::TG 通知发送失败（不影响任务）"
  else
    echo "⚠️ Telegram secrets missing, skip workbuddy-gateway notification."
  fi
}

mkdir -p "$WB_DIR" "$WB_DIR/logs"

# ---------- 1. 检查更新：比对 GitHub Releases 的 latest 版本号与本地记录 ----------
# GitHub API 匿名限流（60 次/小时/出口 IP）对每轮一次足够；失败时按"保持现状"处理，
# 不因查版本失败而少启一个服务。
echo "1. Checking workbuddy-gateway release..."
WB_REMOTE_VER=""
_release_json="$(curl -fsSL --max-time 20 \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/CangShui/workbuddy-gateway/releases/latest 2>/dev/null || true)"
if [ -n "$_release_json" ]; then
  WB_REMOTE_VER="$(printf '%s' "$_release_json" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
    | sed 's/.*"\([^"]*\)"$/\1/' || true)"
fi
WB_LOCAL_VER="$(head -n 1 "$WB_VER_FILE" 2>/dev/null || true)"

# WB_STATE = 部署结论（是否发生了更新），WB_REASON = 只在异常/降级时给的原因，
# WB_UPDATE = 更新说明（「已在最新版」这类正常结论不写进「原因」，避免
# 「原因：已在最新版」这种把正常状态说成故障的写法）。
WB_STATE=""
WB_REASON=""
WB_UPDATE=""
if [ -n "$WB_REMOTE_VER" ] && [ "$WB_REMOTE_VER" = "$WB_LOCAL_VER" ] && [ -x "$WB_BIN" ]; then
  WB_STATE="已就绪"
  WB_UPDATE="已在最新版 ${WB_LOCAL_VER} · 跳过下载"
  echo "✅ 本地已是最新版（${WB_LOCAL_VER}），跳过下载"
else
  if [ -n "$WB_REMOTE_VER" ]; then
    echo "⬇️ 发现新版本 ${WB_REMOTE_VER}（本地 ${WB_LOCAL_VER:-未安装}），开始下载..."
  else
    echo "⚠️ 无法读取 release 版本（GitHub API 不可达或限流），按当前可用版本部署"
  fi
  # 下载到临时文件再原子替换：中途失败不会留下半个二进制
  WB_TMP_BIN="$WB_DIR/.workbuddy-gateway.new"
  if curl -fsSL --max-time 300 -o "$WB_TMP_BIN" "$WB_RELEASE_BASE/workbuddy-gateway-linux-amd64"; then
    chmod 755 "$WB_TMP_BIN"
    if [ -s "$WB_TMP_BIN" ]; then
      mv -f "$WB_TMP_BIN" "$WB_BIN"
      if [ -n "$WB_REMOTE_VER" ]; then
        printf '%s\n' "$WB_REMOTE_VER" > "$WB_VER_FILE"
        if [ -n "$WB_LOCAL_VER" ]; then
          WB_STATE="已更新"
          WB_UPDATE="从 ${WB_LOCAL_VER} 更新到 ${WB_REMOTE_VER}"
        else
          WB_STATE="已安装"
          WB_UPDATE="首次安装 ${WB_REMOTE_VER}"
        fi
      else
        WB_STATE="已就绪"
        WB_REASON="版本号查询失败（GitHub API 不可达或限流），以现有二进制运行"
      fi
    else
      WB_STATE="下载失败"
      WB_REASON="下载产物为空"
    fi
  else
    rm -f "$WB_TMP_BIN" 2>/dev/null || true
    WB_STATE="下载失败"
    WB_REASON="GitHub Releases 下载失败"
  fi
  rm -f "$WB_TMP_BIN" 2>/dev/null || true
fi

WB_VER="$(head -n 1 "$WB_VER_FILE" 2>/dev/null || true)"
echo "WB_STATE=${WB_STATE:-未知}" >> "$WB_META"
echo "WB_VERSION=${WB_VER}" >> "$WB_META"
printf 'WB_UPDATE=%s\n' "$WB_UPDATE" >> "$WB_META"
printf 'WB_REASON=%s\n' "$WB_REASON" >> "$WB_META"

# ---------- 2. 启动 serve ----------
# 绑 8318 而非 8317：8317 已被 CliRelay/CLIProxyAPI 占用（OpenClaw 主 AI 网关），
# workbuddy-gateway 是并列的第二个本地网关，独立端口便于排查与收尾停止。
WB_PORT="8318"
WB_API="http://127.0.0.1:${WB_PORT}"
echo "2. Starting workbuddy-gateway serve on ${WB_PORT}..."
pkill -f "$WB_BIN serve" 2>/dev/null || true
sleep 1
# serve 的工作目录必须是数据目录：凭据靠"自动发现当前目录下 workbuddy*.json"入池，
# 状态文件 workbuddy-status.json 与 logs/ 也都写在同目录，随 Dropbox 持久化。
# 凭据文件由用户另行放入该目录（二维码登录需人工扫码，workflow 内无法完成）。
(
  cd "$WB_DIR" || exit 1
  nohup "$WB_BIN" serve -addr 127.0.0.1 -port "$WB_PORT" \
    > "$WB_LOG" 2>&1 &
  echo $! > /tmp/workbuddy-serve.pid
)

# 健康检查：GET /health 返回任意 HTTP 响应码即视为已监听。
# 就绪后再校验进程是否还在：进程若已崩，端口可能短暂由 TIME_WAIT/旧进程占用，
# 只看 HTTP 会把「刚起来就退出」判成成功（凭据缺失时网关会打警告并退出）。
WB_READY=0
WB_API_DEAD=0
for i in $(seq 1 4); do
  _code="$(curl -s --connect-timeout 2 -o /dev/null -w '%{http_code}' "${WB_API}/health" || true)"
  if [ -n "$_code" ] && [ "$_code" -ge 100 ] && [ "$_code" -lt 600 ]; then
    WB_READY=1
    echo "✅ [workbuddy-gateway] ${WB_PORT} 已就绪 (HTTP ${_code})"
    break
  fi
  # 进程已不在（二进制缺失 / 启动即退出）→ 早退，不再空等满 120 秒
  if ! pgrep -f "$WB_BIN serve" >/dev/null 2>&1; then
    WB_API_DEAD=1
    echo "❌ [workbuddy-gateway] serve 进程已退出，停止等待"
    break
  fi
  echo "⏳ [workbuddy-gateway] 等待中... ${i}/60"
  sleep 2
done

WB_ACCOUNTS=""
WB_STATUS_RAW="$(grep -a '账号池' "$WB_LOG" 2>/dev/null | tail -n 1 || true)"
if [ -n "$WB_STATUS_RAW" ]; then
  WB_ACCOUNTS="$(printf '%s' "$WB_STATUS_RAW" | sed 's/.*账号池[:：][[:space:]]*//' || true)"
fi
echo "WB_READY=${WB_READY}" >> "$WB_META"
printf 'WB_ACCOUNTS=%s\n' "$WB_ACCOUNTS" >> "$WB_META"

if [ "$WB_READY" = "1" ]; then
  if [ -n "$WB_ACCOUNTS" ]; then
    wb_notify "🟢 workbuddy-gateway 已就绪" "$WB_ACCOUNTS" "$WB_VER" "$WB_UPDATE" "$WB_REASON" ""
  else
    # 网关自己起来了、但账号池为空：多半是数据目录里还没有 workbuddy*.json
    # （二维码登录只能人工做），如实标注为可用性问题，不假装就绪。
    wb_notify "⚠️ workbuddy-gateway 已启动 · 无可用账号" \
      "账号池为空 · 需人工扫码登录" "$WB_VER" "$WB_UPDATE" "$WB_REASON" ""
  fi
else
  WB_TAIL="$(tail -c 1200 "$WB_LOG" 2>/dev/null || true)"
  if [ "$WB_API_DEAD" = "1" ]; then
    _wb_fail_reason="serve 进程启动后立即退出（多为二进制缺失或凭据/参数错误）"
    echo "❌ workbuddy-gateway serve 进程启动后立即退出" >&2
  else
    _wb_fail_reason="serve 未在 120 秒内监听 ${WB_PORT}"
    echo "❌ workbuddy-gateway 未能在 120 秒内监听 ${WB_PORT}" >&2
  fi
  wb_notify "❌ workbuddy-gateway 启动失败" "未监听 ${WB_PORT} · 退出码 1" "$WB_VER" \
    "$WB_UPDATE" "$WB_REASON ${_wb_fail_reason}" "$WB_TAIL"
fi
