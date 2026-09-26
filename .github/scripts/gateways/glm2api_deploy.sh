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
# 用法：
#   glm2api_deploy.sh prepare   # 拉代码 + venv + 写 .env（幂等）
#   glm2api_deploy.sh selftest  # 端到端自检：glm-5.3 与 glm-5.3-flash 各发一条
#   glm2api_deploy.sh status    # 端口存活 + 模型列表
set -u

RUN_DIR="/tmp/local_glm2api"
REPO="${GLM2API_REPO:-https://github.com/XxxXTeam/glm2api.git}"
PORT="${GLM2API_PORT:-8320}"
LOG_DIR="$RUN_DIR/logs"
LOG="$LOG_DIR/glm2api.log"
ENV_FILE="$RUN_DIR/.env"

log() { printf '[glm2api] %s\n' "$*"; }
die() { log "❌ $*"; exit 1; }

# ── prepare：让运行目录达到「可被 systemd 拉起」的状态 ────────────────────────
cmd_prepare() {
  [ -n "${GLM_REFRESH_TOKEN:-}" ] || die "未注入 GLM_REFRESH_TOKEN 环境变量（仓库 Secrets），拒绝部署游客态服务"

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
      mkdir -p "$RUN_DIR" || die "无法创建运行目录 $RUN_DIR"
    fi
    git clone --depth 1 "$REPO" "$RUN_DIR" || die "拉取代码失败"
  fi

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
HOST=127.0.0.1
PORT=${PORT}
LOG_LEVEL=INFO
DEBUG_DUMP_ALL=false
GLM_DELETE_CONVERSATION=true
GLM_PLATFORM=mac
GLM_REFRESH_TOKEN=${GLM_REFRESH_TOKEN}
EOF
  chmod 600 "$ENV_FILE" || true
  # 源码是 src/ 布局，main.py 直接跑会 ModuleNotFoundError；
  # 用 PYTHONPATH 指到 src，省掉一次 pip install（无网络依赖、启动更快）
  printf 'PYTHONPATH=%s/src\n' "$RUN_DIR" > "$RUN_DIR/env.sh"
  chmod 600 "$RUN_DIR/env.sh" || true
  log "✅ 运行目录就绪（$RUN_DIR，端口 $PORT）"
}

# 端口存活：/v1 未设 SERVER_API_KEYS 时无需鉴权，直接取 HTTP 码判断
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
cmd_selftest() {
  local out model ok=0
  for model in glm-5.3 glm-5.3-flash; do
    out="$(curl -sS --max-time 120 -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
      -H 'content-type: application/json' \
      -d "{\"model\":\"${model}\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"回复 ok 即可\"}]}" 2>&1)"
    if printf '%s' "$out" | jq -e '.choices[0].message.content | length > 0' >/dev/null 2>&1; then
      log "✅ ${model} 自检通过"
      ok=$((ok + 1))
    else
      log "❌ ${model} 自检失败：$(printf '%s' "$out" | head -c 200)"
    fi
  done
  [ "$ok" -eq 2 ] || return 1
  return 0
}

case "${1:-}" in
  prepare)  cmd_prepare ;;
  status)   cmd_status ;;
  selftest) cmd_selftest ;;
  *) echo "用法: $0 {prepare|status|selftest}"; exit 1 ;;
esac
