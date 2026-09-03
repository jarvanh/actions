#!/usr/bin/env bash
# rclone 一键引导：安装 + 配置 + 掩码 + 持久化（所有 workflow 统一调用）。
#
# 用法: setup_rclone.sh [install|config]
#   install — 安装 rclone：GitHub Releases 直下最新稳定版 .deb（可用 RCLONE_VERSION
#             覆盖）；版本号解析不到或下载失败，回退 rclone.org 安装脚本（同为最新稳定版）
#   config  — rclone.conf 引导与持久化：
#       1. secret 起步：RCLONE_CONFIG（step env 注入，防文本注入被 bash 展开）写入本地 conf
#       2. 掩码敏感值（::add-mask::）——每次 conf 变更后都重新掩一遍
#       3. 恢复首选 Dropbox：拉取 dropbox:self-hosted/rclone.conf 覆盖本地（持久化副本
#          可能比 secret 新），恢复后校验失败则回退 secret 版
#       4. 有效性检查：至少一个 remote 可用；配置了 dropbox: 时必须能列出其内容
#       5. 同步回 Dropbox：copyto 幂等，内容相同自动跳过——即"有修改才上传"
#   不带参数 = 依次执行 install + config。
#
# workflow 用法（两阶段分步执行，便于日志定位）:
#       - name: rclone-install
#         run: |
#           set -e
#           bash "$GITHUB_WORKSPACE/.github/scripts/rclone/setup_rclone.sh" install
#
#       - name: rclone-config
#         env:
#           RCLONE_CONFIG: ${{ secrets.RCLONE }}
#         run: |
#           set -e
#           bash "$GITHUB_WORKSPACE/.github/scripts/rclone/setup_rclone.sh" config
#
# 注意：RCLONE_CONFIG 是 rclone 自身"配置文件路径"的环境变量，这里只是借同名 env 传正文；
#       脚本入口已把值转存到 RCLONE_CONFIG_CONTENT 并 unset 该变量，切勿在脚本内直接读取。
#
# 为什么必须掩码：GitHub 只自动掩 secret 的完整原文，conf 内单个字段值出现在
# rclone 输出/报错日志中不会命中；且从 Dropbox 恢复的 conf 不是 GitHub secret，
# 其中凭据若无 ::add-mask:: 会完全明文进日志。
# 前置: workflow 需先 actions/checkout（脚本随仓库分发）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HOME}/.config/rclone/rclone.conf"
PERSIST_REMOTE="dropbox:self-hosted/rclone.conf"

# rclone 自身把 RCLONE_CONFIG 当配置文件路径（--config 的环境变量形式）。
# 各 workflow 以同名 env 注入的是 conf 正文，若不先摘掉该环境变量，rclone 会把整段
# 正文当路径去加载 → 实际用的是空配置（listremotes 为空），表现为
# "conf 中无 dropbox remote" + "有效性检查失败"。故先取值再 unset。
RCLONE_CONFIG_CONTENT="${RCLONE_CONFIG:-}"
unset RCLONE_CONFIG

# 掩码 rclone.conf 中的敏感值（::add-mask:: 防止 Actions 日志泄露）。
# 覆盖: 键名含 pass/secret/token/key/credential 的单行键、token = {...} JSON 内的
#       access/refresh/id_token（及 JSON 整体）、PEM 私钥块。
# 不覆盖: 其他多行值——rclone 对这类配置通常引用文件路径而非内联，且 secrets.*
#         注入的完整原文本身已被 GitHub 自动掩码。
mask_conf() {
  python3 - "$CONF" <<'PY'
import json
import re
import sys
from pathlib import Path

SECRET_KEY_RE = re.compile(
    r"(?im)^\s*([a-z0-9_]*?(?:pass|secret|token|key|credential)[a-z0-9_]*?)\s*=\s*(.+?)\s*$"
)
TOKEN_JSON_RE = re.compile(r"(?im)^\s*token\s*=\s*(\{.*\})\s*$")
TOKEN_JSON_FIELDS = ("access_token", "refresh_token", "id_token")
PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
    re.S,
)


def collect_secrets(text):
    secrets = set()

    for match in SECRET_KEY_RE.finditer(text):
        value = match.group(2).strip().strip("'\"")
        if value and not value.startswith("{"):
            secrets.add(value)

    for match in TOKEN_JSON_RE.finditer(text):
        secrets.add(match.group(1).strip())
        try:
            token = json.loads(match.group(1))
        except Exception:
            continue
        for field in TOKEN_JSON_FIELDS:
            value = token.get(field)
            if value:
                secrets.add(str(value))

    for match in PRIVATE_KEY_RE.finditer(text):
        secrets.add(match.group(0))

    return secrets


def main():
    conf_path = Path(sys.argv[1])
    if not conf_path.exists():
        print(f"mask_rclone_config: {conf_path} 不存在，跳过", file=sys.stderr)
        return 0
    try:
        text = conf_path.read_text()
    except OSError as e:
        print(f"mask_rclone_config: 读取 {conf_path} 失败: {e}", file=sys.stderr)
        return 1
    # 长值优先：::add-mask:: 对子串生效，长值先注册可整体掩掉；
    # 多行值（PEM 块）按 GitHub 规范把换行编码为 %0A，否则命令会被换行截断
    for value in sorted(collect_secrets(text), key=len, reverse=True):
        print("::add-mask::" + value.replace("\r", "").replace("\n", "%0A"))
    return 0


sys.exit(main())
PY
}

has_dropbox() {
  rclone listremotes 2>/dev/null | grep -qi '^dropbox:$'
}

# 有效性：至少一个 remote；有 dropbox: 时要求能列出其根目录
check_conf() {
  rclone listremotes >/dev/null 2>&1 || return 1
  rclone listremotes 2>/dev/null | grep -q . || return 1
  if has_dropbox; then
    rclone lsf dropbox: --max-depth 1 >/dev/null 2>&1 || return 1
  fi
  return 0
}

write_secret_conf() {
  local content="$1"
  if [ -z "$content" ]; then
    echo "::error::RCLONE_CONFIG secret 未配置，无法写入 rclone.conf"
    exit 1
  fi
  mkdir -p "$(dirname "$CONF")"
  printf '%s\n' "$content" > "$CONF"
  chmod 600 "$CONF"
}

# 解析 rclone 最新稳定版 tag；解析不到返回非 0，由调用方改走 rclone.org 安装脚本。
# 不走 GitHub API（未鉴权 60 次/小时，共享 runner IP 极易 403），改取 releases/latest 的
# 302 Location，与下载同源且无限流；downloads.rclone.org/version.txt 作次选。
resolve_latest_version() {
  local tag=""
  tag="$(curl -sI --retry 2 --retry-delay 5 --connect-timeout 15 --max-time 60 \
      https://github.com/rclone/rclone/releases/latest 2>/dev/null \
      | tr -d '\r' \
      | awk 'tolower($1)=="location:"{print $2}' \
      | sed -n 's#.*/tag/##p' | tail -n 1 || true)"
  if [ -z "$tag" ]; then
    tag="$(curl -fsSL --retry 2 --retry-delay 5 --connect-timeout 15 --max-time 60 \
        https://downloads.rclone.org/version.txt 2>/dev/null \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  fi
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}

do_install() {
  # 安装 rclone：GitHub Releases 直下 .deb，跟踪最新稳定版（RCLONE_VERSION 可覆盖）
  local rver="${RCLONE_VERSION:-}"
  if [ -z "$rver" ]; then
    rver="$(resolve_latest_version || true)"
  fi

  if [ -n "$rver" ]; then
    echo "目标 rclone 版本: $rver"
    if curl -fsSL --retry 2 --retry-delay 5 --connect-timeout 30 --max-time 300 \
        -o /tmp/rclone.deb \
        "https://github.com/rclone/rclone/releases/download/${rver}/rclone-${rver}-linux-amd64.deb"; then
      sudo dpkg -i /tmp/rclone.deb
      rclone version | head -2
      return 0
    fi
    echo "::warning::GitHub Releases 下载 ${rver} 失败，回退 rclone.org 安装脚本"
  else
    echo "::warning::无法解析 rclone 最新版本号，改用 rclone.org 安装脚本"
  fi

  curl -fsSL https://rclone.org/install.sh | sudo bash
  rclone version | head -2
}

do_config() {
  # 1. secret 起步（本地无 conf 时；正常 runner 每轮都是全新环境）
  if [ ! -s "$CONF" ]; then
    write_secret_conf "$RCLONE_CONFIG_CONTENT"
  fi
  mask_conf

  # 2. 恢复首选 Dropbox：拉取持久化副本覆盖本地，无效则回退
  if has_dropbox; then
    local persisted="/tmp/rclone.conf.persisted.$$"
    if rclone copyto "$PERSIST_REMOTE" "$persisted" 2>/dev/null && [ -s "$persisted" ]; then
      cp "$CONF" "$persisted.fallback"
      mv "$persisted" "$CONF"
      chmod 600 "$CONF"
      if check_conf; then
        echo "已从 $PERSIST_REMOTE 恢复 rclone.conf（校验通过）"
        mask_conf
      else
        echo "::warning::$PERSIST_REMOTE 恢复后校验失败（远端凭据可能已过期），回退 secret 版"
        mv "$persisted.fallback" "$CONF"
        mask_conf
      fi
      rm -f "$persisted.fallback"
    else
      echo "$PERSIST_REMOTE 不存在或拉取失败，使用 secret 版起步"
    fi
  else
    echo "::warning::conf 中无 dropbox remote，跳过持久化恢复/同步（仅使用 secret 版）"
  fi

  # 3. 最终有效性检查：conf 无效则本轮必然失败，尽早报错
  if ! check_conf; then
    echo "::error::rclone.conf 有效性检查失败（remote 不可用）"
    # 排查信息：conf 实际路径 + rclone 原始报错（stderr 平时被 check_conf 吞掉）
    # remote 列表本身不含凭据，conf 内的敏感值已在前面 ::add-mask::，可安全输出
    echo "rclone 实际使用的 conf: $(rclone config file 2>&1 | tail -n 1)"
    echo "--- rclone listremotes ---"
    rclone listremotes 2>&1 || true
    exit 1
  fi

  # 4. 同步回 Dropbox：copyto 幂等，内容相同自动跳过（即"有修改才上传"）
  if has_dropbox; then
    if rclone copyto "$CONF" "$PERSIST_REMOTE"; then
      echo "rclone.conf 已同步到 $PERSIST_REMOTE"
    else
      echo "::warning::rclone.conf 同步到 $PERSIST_REMOTE 失败（不影响本轮运行）"
    fi
  fi
}

case "${1:-}" in
  install) do_install ;;
  config)  do_config ;;
  "")      do_install; do_config ;;
  *) echo "用法: $0 [install|config]" >&2; exit 2 ;;
esac
