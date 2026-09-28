#!/usr/bin/env bash
# glm2api 部署脚本（清言 chatglm.cn 反代 → OpenAI 兼容 API，端口 8320）
#
# 位置：.github/scripts/gateways/glm2api_deploy.sh（随仓库 checkout 分发）
# 调用：openclaw.yml 的 "Run glm2api (ChatGLM 反代)" 步骤；托管由 gateways.sh 负责
#
# 为什么独立成脚本而不是内联进 workflow：
#   准备（拉代码 / 建 venv / 写凭据 / 写 .env）与托管（systemd 单元）是两件事，
#   内联会把 openclaw.yml（已 4600+ 行）再撑长；且与 gateways.sh 的分工一致：
#   本脚本只保证「运行目录就绪 + 单元可启动」，进程生命周期交给 systemd。
#
# 凭据口径（重要）：
#   GLM_REFRESH_TOKEN 只从环境变量注入（由 workflow step 从仓库 Secrets 取），
#   脚本绝不把它写进仓库、绝不回显到日志或通知；落盘只有运行目录的 .env（600）。
#   未注入时脚本以非零退出并给出明确原因——没有该凭据服务只能跑游客模式，
#   拿不到账号积分，不如显式失败（与 gateways.sh 的密钥缺失同口径）。
#
# 持久化口径（2026-09-28 改，对齐 workbuddy-gateway）：
#   Dropbox 专属目录   $GLM2API_DATA_REMOTE（默认 dropbox:self-hosted/glm2api）
#        ↔ 本地数据目录 $DATA_DIR（默认 /tmp/local_glm2api/data）
#   起前 pull（拉）、停后 push（推），与 workbuddy 的 WB_DIR ↔ WB_RUN_DIR 同构。
#   为什么只同步 data/ 而不是整个运行目录：运行目录是 git 仓库 + venv，
#   整目录对拷会拿 Dropbox 上的旧代码覆盖当轮刚打的 patch，且 venv 的
#   .venv/bin/python 是软链、放挂载点执行会因 rclone 合成权限(0644) 报
#   Permission denied（workbuddy 二进制同理）。代码/venv/.env 每轮重建，
#   只有服务产出的状态数据需要跨轮留存（当前就是积分快照 quota-snapshot）。
#
# 用法：
#   glm2api_deploy.sh prepare   # 拉代码 + venv + 写 .env（幂等）
#   glm2api_deploy.sh pull      # 从 Dropbox 拉回持久数据（起服务前）
#   glm2api_deploy.sh push      # 回推持久数据 + 日志 + systemd 单元到 Dropbox（收尾）
#   glm2api_deploy.sh selftest  # 端到端自检：glm-5.3 与 glm-5.3-flash 各发一条
#   glm2api_deploy.sh status    # 端口存活 + 模型列表
set -u

RUN_DIR="/tmp/local_glm2api"
REPO="${GLM2API_REPO:-https://github.com/XxxXTeam/glm2api.git}"
PORT="${GLM2API_PORT:-8320}"
LOG_DIR="$RUN_DIR/logs"
LOG="$LOG_DIR/glm2api.log"
ENV_FILE="$RUN_DIR/.env"
# 持久数据目录（本地侧）。运行期状态都落这里，随 pull/push 与 Dropbox 对齐。
DATA_DIR="${GLM2API_DATA_DIR:-$RUN_DIR/data}"
# Dropbox 侧远端（rclone remote 形式）。空=不同步（本地单轮跑）。
DATA_REMOTE="${GLM2API_DATA_REMOTE:-}"
# 迁移兜底：改造前的旧快照独立文件。新位置为空时从它取一次，取到即用。
LEGACY_SNAP_REMOTE="${GLM2API_LEGACY_QUOTA_ARCHIVE:-dropbox:self-hosted/glm2api-quota-snapshot}"
UNIT_SRC="${HOME}/.config/systemd/user/glm2api.service"

log() { printf '[glm2api] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# ── prepare：让运行目录达到「可被 systemd 拉起」的状态 ────────────────────────
cmd_prepare() {
  [ -n "${GLM_REFRESH_TOKEN:-}" ] || die "未注入 GLM_REFRESH_TOKEN 环境变量（仓库 Secrets），拒绝部署游客态服务"
  # 网关鉴权：本网关专属 key（与 8318/8319 各自独立的口径一致，不共用
  # AI_GATEWAY_API_KEY）。监听已改 0.0.0.0，缺 key 等于把清言账号裸奔在
  # 同机所有网卡上，不如显式失败（与 gateways.sh 的密钥缺失同口径）。
  [ -n "${GLM2API_GATEWAY_KEY:-}" ] || die "未注入 GLM2API_GATEWAY_KEY 环境变量（仓库 Secrets），拒绝起无鉴权服务"

  mkdir -p "$RUN_DIR" "$LOG_DIR" || die "无法创建运行目录 $RUN_DIR"

  # 代码：首次 clone，后续 fetch+reset 到 origin 默认分支。
  # 用 ls-remote 判默认分支，避免硬编码 main/master 在新仓库上失效。
  # 目录已存在但非 git 仓库时先清空：runner 上 /tmp 可能被上一轮残留的半截
  # 副本占住（clone 中断、归档解包等），git clone 会因「目录非空」直接失败。
  if [ -d "$RUN_DIR/.git" ]; then
    log "更新代码（fetch + reset 到远端默认分支）"
    (cd "$RUN_DIR" && git fetch --depth 1 origin >/dev/null 2>&1 \
      && git reset --hard "origin/$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)" >/dev/null 2>&1) \
      || log "⚠️ 代码更新失败，沿用现有副本"
  else
    log "拉取代码：$REPO"
    mkdir -p "$RUN_DIR" || die "无法创建运行目录 $RUN_DIR"
    if [ -n "$(ls -A "$RUN_DIR" 2>/dev/null)" ]; then
      log "⚠️ 运行目录非空且不是 git 仓库，清空后重新拉取"
      rm -rf "$RUN_DIR" || die "清空运行目录失败"
    fi
    git clone --depth 1 "$REPO" "$RUN_DIR" || die "拉取代码失败"
  fi

  # 日志目录在 clone/清空之后必须重建：上面的 rm -rf 与 git clone 都会抹掉它，
  # 而单元的 StandardOutput=append:<LOG> 在目录不存在时进程直接以
  # status=209/STDOUT 退出（systemd 无法打开日志文件）→ 触发 Restart=always
  # 崩溃循环。首轮部署必踩（实测 2026-09-27），故这里幂等补建。
  mkdir -p "$LOG_DIR" || die "无法创建日志目录 $LOG_DIR"

  # 持久数据目录：quota.sh 的快照就写这里（GLM2API_STATE_DIR 与本值同源，
  # 见 workflow 的传参）。必须在 unit 启动前存在，否则快照写盘失败。
  mkdir -p "$DATA_DIR" || die "无法创建数据目录 $DATA_DIR"

  # 本地补丁：selected_model / platform=mac / deep_thinking。
  # 上游（XxxXTeam/glm2api）尚未合入这些改动，故每轮从本仓库的 patch 目录覆盖；
  # patch 目录缺失时不阻断（跑上游原版，模型选择退化为默认 Flash）。
  local patch_dir="${GLM2API_PATCH_DIR:-}"
  if [ -n "$patch_dir" ] && [ -d "$patch_dir" ]; then
    log "应用本地补丁：$patch_dir"
    cp -a "$patch_dir/." "$RUN_DIR/" || log "⚠️ 补丁应用失败，沿用上游原版"
  else
    log "ℹ️ 未指定补丁目录，使用上游原版（模型选择退化为默认 Flash）"
  fi

  # venv：glm2api 零第三方依赖，建 venv 只为隔离 site-packages；
  # 实测 3.12/3.13 均可运行（纯标准库），不强求 3.14。
  if [ ! -x "$RUN_DIR/.venv/bin/python" ]; then
    log "创建虚拟环境"
    python3 -m venv "$RUN_DIR/.venv" || die "创建 venv 失败"
  fi

  # .env：凭据 + 服务参数。600 落盘，凭据不进仓库。
  # PYTHONPATH 一并写进 .env 会被服务忽略（它不读 .env 之外的键），故单独
  # 落在运行目录的 env.sh 供单元 EnvironmentFile 读取。
  umask 077
  cat > "$ENV_FILE" <<EOF
# 监听 0.0.0.0：与 8317/8318/8319 同口径（同机其它反代都对外网卡开放），
# 便于容器/局域网客户端接入。安全边界由 SERVER_API_KEYS 承担，不再靠回环地址。
HOST=0.0.0.0
PORT=${PORT}
LOG_LEVEL=INFO
DEBUG_DUMP_ALL=false
GLM_DELETE_CONVERSATION=true
GLM_PLATFORM=mac
# 鉴权：只校验 POST（/v1/chat/completions、/v1/responses、/v1/images），
# /health 与 /v1/models 为公开路由，故存活探测不受影响（见 cmd_status）。
# 支持 Bearer 与 x-api-key 两种头（server.py _authorize）。
SERVER_API_KEYS=${GLM2API_GATEWAY_KEY}
# 并发槽位：上游实测 8 并发无压力（直连 8 路全部 ~2s 返回），
# 默认 3 会让突发请求排队、队列超时后连接被重置。
GLM_MAX_CONCURRENCY=${GLM2API_MAX_CONCURRENCY:-8}
GLM_REFRESH_TOKEN=${GLM_REFRESH_TOKEN}
EOF
  chmod 600 "$ENV_FILE" || true
  # 源码是 src/ 布局，main.py 直接跑会 ModuleNotFoundError；
  # 用 PYTHONPATH 指到 src，省掉一次 pip install（无网络依赖、启动更快）
  printf 'PYTHONPATH=%s/src\n' "$RUN_DIR" > "$RUN_DIR/env.sh"
  chmod 600 "$RUN_DIR/env.sh" || true
  log "✅ 运行目录就绪（$RUN_DIR，端口 $PORT）"
}

# ── pull：起服务前把 Dropbox 上的持久数据拉进本地 data/ ────────────────────
# rclone copy 单向拉取、不删本地多余文件；远端为空是首轮正常情况，不判失败。
cmd_pull() {
  [ -n "$DATA_REMOTE" ] || { log "ℹ️ 未指定 GLM2API_DATA_REMOTE，跳过数据拉取"; return 0; }
  command -v rclone >/dev/null 2>&1 || { log "⚠️ rclone 不可用，跳过数据拉取"; return 0; }
  mkdir -p "$DATA_DIR" || return 1

  log "拉取持久数据：$DATA_REMOTE → $DATA_DIR"
  # 这里**不能**在失败时 return：远端目录尚未创建（首次改造轮次）时 rclone copy
  # 会以「目录不存在」报错，若提前返回就会连下面的旧快照迁移一起跳过，
  # 直接把「今日累计」清零。故只记警告，流程继续往下走。
  rclone copy "$DATA_REMOTE" "$DATA_DIR" \
    --exclude 'logs/**' --exclude 'systemd/**' --exclude '*.new' \
    --retries 5 --low-level-retries 10 --timeout 1m --contimeout 15s 2>/dev/null \
    || log "⚠️ 数据拉取失败/远端为空，按首轮空数据启动（今日累计将从 0 起算）"

  # 迁移兜底：改造前快照是独立的 dropbox:self-hosted/glm2api-quota-snapshot。
  # 新目录里还没有快照时取一次，避免改造当轮把「今日累计」清零。
  if [ ! -s "$DATA_DIR/quota-snapshot" ] && [ -n "$LEGACY_SNAP_REMOTE" ]; then
    if rclone copyto "$LEGACY_SNAP_REMOTE" "$DATA_DIR/quota-snapshot" \
         --retries 3 --low-level-retries 5 --timeout 30s --contimeout 10s 2>/dev/null; then
      log "✅ 已从旧位置迁移积分快照（$LEGACY_SNAP_REMOTE）"
    else
      log "ℹ️ 旧位置无积分快照，按首轮处理"
    fi
  fi
  log "✅ 数据拉取完成"
}

# ── push：收尾把本地 data/ + 日志 + systemd 单元回推 Dropbox ──────────────
# 只 copy 不 sync：远端的历史内容不该被本轮删掉（与 workbuddy 收尾同口径）。
# 失败不阻断收尾通知——下一轮 pull 不到最多是累计从 0 起，不能因此卡住 job。
cmd_push() {
  [ -n "$DATA_REMOTE" ] || { log "ℹ️ 未指定 GLM2API_DATA_REMOTE，跳过数据回推"; return 0; }
  command -v rclone >/dev/null 2>&1 || { log "⚠️ rclone 不可用，跳过数据回推"; return 0; }
  [ -d "$DATA_DIR" ] || { log "ℹ️ 数据目录不存在，跳过回推"; return 0; }

  log "回持久数据：$DATA_DIR → $DATA_REMOTE"
  rclone copy "$DATA_DIR" "$DATA_REMOTE" \
    --exclude '*.new' \
    --retries 5 --low-level-retries 10 --timeout 1m --contimeout 15s 2>/dev/null \
    || log "⚠️ 数据回推失败（下轮累计将从 0 起）"

  # 日志：服务日志在 RUN_DIR/logs（单元 StandardOutput 指这儿），不在 data/ 下，
  # 单独带一份上去便于事后回看。体积很小（纯 INFO 行），全量 copy 无压力。
  if [ -d "$LOG_DIR" ]; then
    rclone copy "$LOG_DIR" "$DATA_REMOTE/logs" \
      --retries 3 --low-level-retries 5 --timeout 1m --contimeout 15s 2>/dev/null \
      || log "⚠️ 日志回推失败（不影响数据）"
  fi

  # systemd 单元真源：~/.config 不在持久化白名单，runner 重置会丢。
  # 存一份到 Dropbox，重置后可按此恢复（与 workbuddy-gateway/systemd/ 同口径）。
  if [ -s "$UNIT_SRC" ]; then
    rclone copyto "$UNIT_SRC" "$DATA_REMOTE/systemd/glm2api.service" \
      --retries 3 --low-level-retries 5 --timeout 30s --contimeout 10s 2>/dev/null \
      || log "⚠️ 单元回推失败（不影响数据）"
  fi
  log "✅ 数据回推完成"
}

# 端口存活：/health 是公开路由（鉴权只作用于 POST：server.py 的 do_POST →
# _authorize，GET 分支不走鉴权），故即便设了 SERVER_API_KEYS 也能免 key 探测。
cmd_status() {
  local code
  code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    log "✅ 服务已监听 ${PORT}（HTTP ${code}）"
    return 0
  fi
  log "⛔ 服务未监听 ${PORT}"
  return 1
}

# 端到端自检：两个模型各发一条，判据是返回了助手内容。
# 只验「有内容」不比对文本：模型回复内容不稳定，比对文本会 flaky。
# 默认只自检不扣积分的 chat 通道（glm-5.3 / glm-5.3-flash）。
# agent 通道（glm-5.3-flash-agent）会真实扣分，默认**不自检**，只有显式
# GLM2API_SELFTEST_AGENT=1 才纳入 —— 每 5 分钟一轮的常驻服务不该默认烧分。
cmd_selftest() {
  local out model ok=0 total=0
  local models="glm-5.3 glm-5.3-flash"
  # 鉴权：POST 受 SERVER_API_KEYS 保护，自检也必须带 key —— 否则拿到 401 会被
  # 误判成「服务没起来」（与 zcode2api 不能用 curl -f 判存活同款坑）。
  # key 现取运行目录 .env（600），不进日志、不进通知。
  local api_key=""
  api_key="$(grep -m1 '^SERVER_API_KEYS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  if [ "${GLM2API_SELFTEST_AGENT:-0}" = "1" ]; then
    models="${models} glm-5.3-flash-agent"
  fi
  for model in $models; do
    total=$((total + 1))
    out="$(curl -sS --max-time 120 -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
      -H 'content-type: application/json' \
      -H "Authorization: Bearer ${api_key}" \
      -d "{\"model\":\"${model}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"回复 ok 即可\"}]}" 2>&1)"
    if printf '%s' "$out" | jq -e '.choices[0].message.content | length > 0' >/dev/null 2>&1; then
      log "✅ ${model} 自检通过"
      ok=$((ok + 1))
    else
      log "❌ ${model} 自检失败：$(printf '%s' "$out" | head -c 200)"
    fi
  done
  [ "$ok" -eq "$total" ] || return 1
  return 0
}

case "${1:-}" in
  prepare)  cmd_prepare ;;
  pull)     cmd_pull ;;
  push)     cmd_push ;;
  status)   cmd_status ;;
  selftest) cmd_selftest ;;
  *) echo "用法: $0 {prepare|pull|push|status|selftest}"; exit 1 ;;
esac
