#!/usr/bin/env bash
# 安装 cloudflared：固定版本 + SHA256 校验通过后才 dpkg -i。
#
# 安全整改（ACT9a）：
#   · 仓库根目录曾提交 19.9MB 的 cloudflared-linux-amd64.deb（二进制入库，
#     无法审计、无版本记录）—— 已 git rm，改由本脚本按固定版本下载。
#   · 原 workflow 均为 `wget .../releases/latest/download/... && sudo dpkg -i`
#     —— 浮动 latest + 零校验，供应链上任一环节被替换都会以 root 安装。
#   · 现在版本与 SHA256 都是仓库内常量；校验失败/下载失败一律拒绝安装。
#
# 升级步骤（人工）：
#   1. 从 https://github.com/cloudflare/cloudflared/releases 选定新版本
#   2. 用 GitHub Release 资产的 digest（sha256）或自行 sha256sum 得到校验值
#   3. 同时更新下面的 CLOUDFLARED_VERSION 与 CLOUDFLARED_DEB_SHA256
set -euo pipefail

CLOUDFLARED_VERSION="2026.10.7"
# 来源：GitHub Release v2026.10.7 资产 cloudflared-linux-amd64.deb 的 digest
CLOUDFLARED_DEB_SHA256="70b1a1e0f46033ffc8d90b406e554044ba6cbf2e4360295ef1163aed31e09393"
DEB="/tmp/cloudflared-${CLOUDFLARED_VERSION}-linux-amd64.deb"
URL="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64.deb"

cleanup() { rm -f "$DEB"; }
trap cleanup EXIT

echo "安装 cloudflared ${CLOUDFLARED_VERSION}（SHA256 校验）..."
_ok=0
for _try in 1 2 3; do
  if curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 5 \
      --connect-timeout 30 --max-time 300 -o "$DEB" "$URL"; then
    _ok=1
    break
  fi
  echo "::warning::cloudflared .deb 下载失败（第 ${_try}/3 次）" >&2
  [ "$_try" -lt 3 ] && sleep $((_try * 10))
done
if [ "$_ok" -ne 1 ] || [ ! -s "$DEB" ]; then
  echo "::error::cloudflared .deb 下载失败，拒绝安装（不会回退到未校验来源）" >&2
  exit 1
fi

if ! printf '%s  %s\n' "$CLOUDFLARED_DEB_SHA256" "$DEB" | sha256sum -c - >/dev/null 2>&1; then
  _actual="$(sha256sum "$DEB" | awk '{print $1}')"
  echo "::error::cloudflared .deb SHA256 校验失败（期望 ${CLOUDFLARED_DEB_SHA256}，实际 ${_actual}）" >&2
  exit 1
fi
echo "✅ cloudflared .deb SHA256 校验通过"

sudo dpkg -i "$DEB"
cloudflared --version 2>/dev/null | sed -n '1p' || true
