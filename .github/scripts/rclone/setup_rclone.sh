#!/usr/bin/env bash
# rclone 一键引导：安装 + 配置 + 掩码 + 持久化（所有 workflow 统一调用）。
#
# 用法: setup_rclone.sh [install|config]
#   install — 安装 rclone：GitHub Releases 直下固定版本 .deb，失败回退 rclone.org 安装脚本
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
# 为什么必须掩码：GitHub 只自动掩 secret 的完整原文，conf 内单个字段值出现在
# rclone 输出/报错日志中不会命中；且从 Dropbox 恢复的 conf 不是 GitHub secret，
# 其中凭据若无 ::add-mask:: 会完全明文进日志。
# 前置: workflow 需先 actions/checkout（脚本随仓库分发）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${HOME}/.config/rclone/rclone.conf"
PERSIST_REMOTE="dropbox:self-hosted/rclone.conf"

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
  if [ -z "${RCLONE_CONFIG:-}" ]; then
    echo "::error::RCLONE_CONFIG secret 未配置，无法写入 rclone.conf"
    exit 1
  fi
  mkdir -p "$(dirname "$CONF")"
  printf '%s\n' "$RCLONE_CONFIG" > "$CONF"
  chmod 600 "$CONF"
}

do_install() {
  # 安装 rclone：GitHub Releases 直下 .deb，失败回退 rclone.org 安装脚本
  local rver=v1.71.2
  if curl -fsSL --retry 2 --retry-delay 5 --connect-timeout 30 --max-time 300 \
      -o /tmp/rclone.deb \
      "https://github.com/rclone/rclone/releases/download/${rver}/rclone-${rver}-linux-amd64.deb"; then
    sudo dpkg -i /tmp/rclone.deb
  else
    echo "GitHub Releases 下载失败，回退 rclone.org 安装脚本"
    curl -fsSL https://rclone.org/install.sh | sudo bash
  fi
  rclone version | head -2
}

do_config() {
  # 1. secret 起步（本地无 conf 时；正常 runner 每轮都是全新环境）
  if [ ! -s "$CONF" ]; then
    write_secret_conf
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
