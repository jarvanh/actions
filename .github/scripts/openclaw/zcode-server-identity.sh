#!/usr/bin/env bash
# ZCode server 设备身份（installationId）固定器。
#
# 用法: zcode-server-identity.sh install
#
# 背景（2026-10-30 事故）：客户端「认设备」用的是 server 上报的 serverId，
# 真源是 ~/.zcode/server/install.json 的 installationId（server-core 里
# `serverId = resolveCoreServerId() ?? hostname()`，侧栏任务 keyed 到
# host_id = remote:server:<installationId>）。hostname 只影响显示名。
#
# 临时 runner 每轮重建：客户端连上来时先部署一份新 server，install.json 由
# ensureServerInstallOwnership() 随机生成；若之后（还原步骤）再回钉历史 id，
# 同一轮内身份「先新后旧」→ 客户端弹「连接目标的身份已变化，是否作为新设备」。
#
# 所以主身份随仓库保存（zcode-server-identity.json，公开 UUID 非凭据），
# 在 job 最前面、Tailscale 尚未接入时由本脚本铺好 install.json；客户端部署走
# ensureServerInstallOwnership() 的 EEXIST → validate 分支，沿用该 id。
# 还原步骤在合并包内 server/ 之后再次调用本脚本，保证两个字段恒为仓库值
# （包内 install.json 的 installedAt 会随上一轮浮动，一并覆盖掉）。
set -euo pipefail

sub="${1:-install}"
[ "$sub" = "install" ] || { echo "用法: $0 install" >&2; exit 2; }

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
idf="${GITHUB_WORKSPACE:-$root_dir}/.github/scripts/openclaw/zcode-server-identity.json"

if [ ! -f "$idf" ]; then
  echo "::warning::缺少 $idf，跳过身份固定（本轮客户端可能仍弹一次新设备确认）"
  exit 0
fi

want_id="$(jq -r '.installationId // empty' "$idf")"
want_at="$(jq -r '.installedAt // empty' "$idf")"
if [ -z "$want_id" ] || [ -z "$want_at" ]; then
  echo "::warning::$idf 缺 installationId/installedAt，跳过身份固定"
  exit 0
fi

root="$HOME/.zcode/server"
mkdir -p -m 700 "$root"
canonical="$(realpath "$root")"
inst="$root/install.json"

if [ -f "$inst" ]; then
  cur_id="$(jq -r '.installationId // empty' "$inst" 2>/dev/null || true)"
  cur_at="$(jq -r '.installedAt // empty' "$inst" 2>/dev/null || true)"
  if [ "$cur_id" = "$want_id" ] && [ "$cur_at" = "$want_at" ]; then
    echo "✅ install.json 已是主身份 ${want_id}，无需改动"
    exit 0
  fi
  echo "⚠️ install.json 现为 ${cur_id:-<不可解析>}，覆盖为仓库主身份 ${want_id}"
fi

tmp="$inst.seed.$$"
jq -n --arg id "$want_id" --arg root "$canonical" --argjson at "$want_at" \
  '{product:"zcode-server",schemaVersion:1,canonicalServerRoot:$root,installationId:$id,installedAt:$at}' \
  > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$inst"
echo "✅ 已固定 installationId=${want_id}（canonicalServerRoot=${canonical}）"
