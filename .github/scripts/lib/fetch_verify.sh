#!/usr/bin/env bash
# 下载远端脚本/资产到指定路径，并用仓库内 pin 的 SHA256 校验；失败即退出，不执行。
#
# 安全整改（ACT4 同类）：用于把「curl ... | bash」改成「先下载落盘 → 校验 → 再执行」。
# 用法: fetch_verify.sh <url> <pin-file> <asset-name> <dest>
#   pin-file 每行形如 "<sha256>  <asset-name>"；asset-name 用于在同一 pin 文件里
#   区分多个资产（例如 checksums.txt 风格的清单）。
# 升级流程：审阅上游变化 → 更新对应 pin 文件 → 随代码提交。
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "用法: $0 <url> <pin-file> <asset-name> <dest>" >&2
  exit 2
fi
URL="$1"
PIN_FILE="$2"
ASSET_NAME="$3"
DEST="$4"

if [ ! -r "$PIN_FILE" ]; then
  echo "::error::校验和文件缺失: $PIN_FILE" >&2
  exit 1
fi
EXPECTED="$(awk -v n="$ASSET_NAME" '$2 == n {print $1}' "$PIN_FILE" | head -n 1)"
if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "::error::${PIN_FILE} 中未找到 ${ASSET_NAME} 的有效 SHA256，拒绝下载/执行" >&2
  exit 1
fi

DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"
TMP="${DEST}.part.$$"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "下载并校验: $URL"
if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --retry-delay 5 \
    --connect-timeout 30 --max-time 300 -o "$TMP" "$URL"; then
  echo "::error::下载失败: $URL" >&2
  exit 1
fi
ACTUAL="$(sha256sum "$TMP" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "::error::SHA256 校验失败（期望 $EXPECTED，实际 $ACTUAL）: $URL" >&2
  echo "::error::上游内容已变化。请审阅后更新 $PIN_FILE 再重试；本轮拒绝执行。" >&2
  exit 1
fi
chmod 700 "$TMP"
mv -f "$TMP" "$DEST"
echo "✅ SHA256 校验通过: $DEST"
