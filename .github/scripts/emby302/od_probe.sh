#!/bin/bash
# OneDrive 快捷方式(remoteItem) 只读探测
#
# 目的：判断 302 直链方案是否可行——
#   1) Graph 能否跟随快捷方式（解析 remoteItem → 切到 /drives/{driveId}/items/{id}）
#   2) 跟随后的子目录能否列举
#   3) 目标文件能否返回 @microsoft.graph.downloadUrl（官方预授权直链，约 1 小时有效）
#
# 约束：
#   - 仓库公开，输出一律脱敏：不打印 token、不打印完整直链、driveId/itemId 只显示前 8 位
#   - 纯只读：不写网盘数据、不改变 302 链路行为；任何失败都不阻塞后续步骤
#
# 凭据来源与 OpenList 自动注册同源：rclone.conf 的 [onedrive] 段

set -uo pipefail

RCLONE_CONF="${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}"
PROBE_LOG="${PROBE_LOG:-/opt/logs/odprobe.log}"
GRAPH="https://graph.microsoft.com/v1.0"

mkdir -p "$(dirname "$PROBE_LOG")" 2>/dev/null || true

# 同时输出到 stdout（进 workflow 日志）与探测日志文件
out() { printf '%s\n' "$*" | tee -a "$PROBE_LOG"; }

out "=== OneDrive 快捷方式只读探测 $(date '+%F %T') ==="

# ---------- 1. 取凭据 ----------
SECTION=$(awk '/^\[onedrive\]/{f=1;next} /^\[/{f=0} f' "$RCLONE_CONF" 2>/dev/null || true)
get_kv() {
  printf '%s\n' "$SECTION" | grep -oE "^[[:space:]]*$1[[:space:]]*=.*" | head -1 | sed 's/^[^=]*=[[:space:]]*//'
}
CID=$(get_kv client_id)
CSEC=$(get_kv client_secret)
RTOK=$(get_kv token | jq -r '.refresh_token // empty' 2>/dev/null)

out "凭据提取: client_id 长度=${#CID} client_secret 长度=${#CSEC} refresh_token 长度=${#RTOK}"
if [ -z "$CID" ] || [ -z "$RTOK" ]; then
  out "❌ 未能从 rclone.conf 取到 client_id/refresh_token，探测中止（不阻塞后续步骤）"
  exit 0
fi

# ---------- 2. 换 access_token ----------
TOK_JSON=$(curl -s -m 25 -X POST "https://login.microsoftonline.com/common/oauth2/v2.0/token" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "client_id=$CID" \
  --data-urlencode "client_secret=$CSEC" \
  --data-urlencode "refresh_token=$RTOK" \
  --data-urlencode "scope=Files.Read offline_access")
AT=$(printf '%s' "$TOK_JSON" | jq -r '.access_token // empty' 2>/dev/null)
if [ -z "$AT" ]; then
  out "❌ 换取 access_token 失败: error=$(printf '%s' "$TOK_JSON" | jq -r '.error // "?"' 2>/dev/null) desc=$(printf '%s' "$TOK_JSON" | jq -r '.error_description // ""' 2>/dev/null | head -c 150)"
  exit 0
fi
out "✅ 已获取 access_token（内容不打印）"

# ---------- Graph 请求 helper ----------
# 用法：body=$(gget "$url")，HTTP 码写入 GCODE
GCODE=0
gget() {
  local body
  body=$(curl -s -m 30 -w '\n%{http_code}' \
           -H "Authorization: Bearer $AT" -H 'Accept: application/json' "$1")
  GCODE=$(printf '%s' "$body" | tail -1)
  printf '%s' "$body" | sed '$d'
}

# ---------- 3. 列根目录，识别快捷方式 ----------
ROOT_JSON=$(gget "$GRAPH/me/drive/root/children?\$select=name,id,remoteItem,folder&\$top=100")
out "根目录列举: http=$GCODE"
if [ "$GCODE" != "200" ]; then
  out "❌ 根目录列举失败: $(printf '%s' "$ROOT_JSON" | jq -r '.error.code // .error.message // "无"' 2>/dev/null | head -c 200)"
  exit 0
fi

# OpenList token 仅用于做 A/B 对照（佐证根因），取不到就跳过对照
OL_TOKEN=$(cat /tmp/openlist-token 2>/dev/null || true)

# ---------- 4. 逐个条目探测 ----------
printf '%s' "$ROOT_JSON" | jq -c '.value[]' 2>/dev/null | while read -r item; do
  NAME=$(printf '%s' "$item" | jq -r '.name // "?"')
  IS_SC=$(printf '%s' "$item" | jq -r 'if has("remoteItem") then "yes" else "no" end')
  IS_DIR=$(printf '%s' "$item" | jq -r 'if has("folder") then "dir" else "file" end')

  if [ "$IS_SC" != "yes" ]; then
    if [ "$IS_DIR" = "dir" ]; then
      out "  [$NAME] 普通目录 —— 非快捷方式，跳过"
    else
      out "  [$NAME] 普通文件 —— 非快捷方式，跳过"
    fi
    continue
  fi

  DRIVE=$(printf '%s' "$item" | jq -r '.remoteItem.parentReference.driveId // ""')
  RID=$(printf '%s' "$item" | jq -r '.remoteItem.id // ""')
  out "  [$NAME] 快捷方式 → 目标 drive=${DRIVE:0:8}… item=${RID:0:8}…"

  # 4a. 对照：OpenList 侧同一路径（预期失败，用于佐证"OpenList 解析不了快捷方式"）
  if [ -n "$OL_TOKEN" ]; then
    OLB=$(curl -s -m 15 -X POST http://127.0.0.1:5244/api/fs/get \
            -H "Authorization: $OL_TOKEN" -H 'Content-Type: application/json' \
            -d "{\"path\":\"/onedrive/$NAME\",\"password\":\"\",\"refresh\":false}" 2>/dev/null)
    out "     [对照] OpenList fs/get /onedrive/$NAME → code=$(printf '%s' "$OLB" | jq -r '.code // "?"' 2>/dev/null) msg=$(printf '%s' "$OLB" | jq -r '.message // ""' 2>/dev/null | head -c 100)"
  fi

  # 4b. 跟随快捷方式后列子目录
  CH=$(gget "$GRAPH/drives/$DRIVE/items/$RID/children?\$select=name,id,file,folder&\$top=30")
  if [ "$GCODE" != "200" ]; then
    out "     ❌ 跟随后仍无法列子目录 http=$GCODE $(printf '%s' "$CH" | jq -r '.error.code // ""' 2>/dev/null | head -c 80)"
    continue
  fi
  CNT=$(printf '%s' "$CH" | jq -r '.value | length' 2>/dev/null || echo 0)
  out "     ✅ 跟随后可列子目录: 条目数=$CNT"

  # 4c. 取一个文件样例，验证能否拿到预授权直链
  FID=$(printf '%s' "$CH" | jq -r '.value[] | select(has("file")) | .id' 2>/dev/null | head -1)
  FNAME=$(printf '%s' "$CH" | jq -r '.value[] | select(has("file")) | .name' 2>/dev/null | head -1)
  if [ -z "$FID" ]; then
    out "     ⚠️ 首层没有文件（可能全是子目录），未验证直链"
    continue
  fi
  FB=$(gget "$GRAPH/drives/$DRIVE/items/$FID?\$select=id,name,size,content.downloadUrl")
  DL=$(printf '%s' "$FB" | jq -r '."@microsoft.graph.downloadUrl" // .content.downloadUrl // empty' 2>/dev/null)
  if [ -n "$DL" ]; then
    HOST=$(printf '%s' "$DL" | sed -E 's#https?://([^/]+).*#\1#')
    out "     ✅ 取到预授权直链: 样例=${FNAME:0:28}… host=$HOST 链接长度=${#DL}"
  else
    out "     ❌ 未返回 downloadUrl http=$GCODE $(printf '%s' "$FB" | jq -r '.error.code // ""' 2>/dev/null | head -c 100)"
  fi
done

out "=== 探测结束 ==="
exit 0
