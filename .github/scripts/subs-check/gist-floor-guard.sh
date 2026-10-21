#!/usr/bin/env bash
# subs-check 的「Gist 订阅节点数下限」闸门。
#
# 为什么需要它：subs-check 原生没有「至少 N 个节点才上传」的开关（已核对上游源码
# beck-8/subs-check）。
#   - success-limit 是**上限**（凑够 N 个成功节点就停流水线），方向相反
#   - success-rate   只打 Warn 日志，不拦保存
#   - save.go 只在 0 节点时跳过保存，1~9 个照样推 Gist
# 而 config.yaml 里现存的 keep-success-proxies 是**已废弃键**，当前版本根本不读它。
#
# 所以这里在容器外部做「事后校正」，语义 = 对外订阅永远不少于 FLOOR 个节点：
#   读 Gist 当前内容 → 节点数 >= FLOOR：存一份 last-good 快照，什么都不做
#   节点数 <  FLOOR  ：把 last-good 快照 PATCH 回 Gist（本轮的降级结果被覆盖掉）
# 自愈性：回滚后 Gist 内容即快照（>= FLOOR），下一轮探测自然无事可做；等 subs-check
# 下一轮再写回低节点数结果时，闸门会再顶一次，等价于「不合格不上线」。
#
# 用法（subs-check.yml 保活步骤里循环调用，也可手动跑一次）：
#   gist-floor-guard.sh once     # 单次检查+必要时回滚
#   gist-floor-guard.sh loop     # 常驻循环（默认每 5 分钟一次，直到被 kill）
#
# 可调环境变量（默认即生产口径）：
#   GIST_MIN_NODES      下限节点数，默认 10
#   GIST_GUARD_CONFIG   config.yaml 路径，取 github-token / github-gist-id
#   GIST_GUARD_STATE    快照存放目录
#   GIST_MAX_AGE_HOURS  快照最大可用年龄（小时），超龄不再回滚，默认 48
#   GIST_GUARD_INTERVAL loop 的间隔秒数，默认 300
#   GIST_GUARD_DRYRUN=1 只打印决策，不写 Gist
set -uo pipefail

FLOOR="${GIST_MIN_NODES:-10}"
CFG="${GIST_GUARD_CONFIG:-/dropbox/self-hosted/subs-check/config/config.yaml}"
STATE_DIR="${GIST_GUARD_STATE:-/dropbox/self-hosted/subs-check/gist-floor-guard}"
MAX_AGE_H="${GIST_MAX_AGE_HOURS:-48}"
INTERVAL="${GIST_GUARD_INTERVAL:-300}"
GOOD="$STATE_DIR/gist_last_good.yaml"
API_BASE="${GIST_API_BASE:-https://api.github.com}"

# 日志只在「有动作」时 workflow 保活循环调用，stdout 会进 Actions 日志，
# 常态必须安静，否则 350 分钟的 run 会被无意义刷屏。
say() { printf '[gist-floor-guard] %s\n' "$*"; }

cfg_pick() { # cfg_pick <key>
  [ -f "$CFG" ] || return 1
  sed -n "s/^$1:[[:space:]]*//p" "$CFG" | head -1 | sed -e 's/^"//' -e "s/^'//" -e 's/"[[:space:]]*$//' -e 's/[[:space:]]#.*$//'
}

# 数 proxies: 块里的节点条数。只计「缩进等于第一条列表项」的行，避开 alpn / 嵌套列表误计。
# 必须兼容三种排版（判式写错会让自己写回的快照被认成 0 节点，已实测踩到）：
#   Go yaml.v3   → `proxies:` + 四空格 + `- name: x`（生产 gist 当前格式）
#   py yaml 默认 → `proxies:` + 零缩进 + `- client-fingerprint: x`（本脚本回写快照格式）
#   嵌套列表     → 块内更深缩进的 `- h3`（靠「缩进须等于首项」排除）
count_nodes() {
  awk '
    !inblk && /^proxies:[[:space:]]*$/ { inblk=1; next }
    inblk && /^[^[:space:]#-]/ { inblk=0 }   # 零缩进的列表项不能算「块结束」
    inblk && /^ *-( |$)/ {
      ind = match($0, /-/) - 1           # 破折号所在列 = 列表项缩进
      if (itemind == "") { itemind = ind; n++ }
      else if (ind == itemind) n++
    }
    END { print n+0 }
  ' "$1"
}

gist_fetch() { # -> 把 Gist 的 all.yaml 内容写到 $1；成功返回 0
  local out="$2"
  local resp code
  resp="$(mktemp)"
  code="$(curl -sS -o "$resp" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: subs-check-gist-floor-guard" \
    "$API_BASE/gists/$GIST_ID" 2>/dev/null)" || { rm -f "$resp"; return 1; }
  if [ "$code" != "200" ]; then say "读取 Gist 失败 HTTP $code"; rm -f "$resp"; return 1; fi
  # API 返回 JSON，用 python3（GHA ubuntu runner 自带）取 files['all.yaml'].content
  python3 - "$resp" "$out" <<'PY' || { rm -f "$resp"; return 1; }
import json,sys
data=json.load(open(sys.argv[1],encoding='utf-8'))
files=data.get('files') or {}
f=files.get('all.yaml') or next(iter(files.values()), {})
open(sys.argv[2],'w',encoding='utf-8').write(f.get('content') or '')
PY
  rm -f "$resp"
  return 0
}

gist_patch() { # gist_patch <file>
  local body
  body="$(mktemp)"
  python3 - "$1" "$body" <<'PY' || { rm -f "$body"; return 1; }
import json,sys
content=open(sys.argv[1],encoding='utf-8').read()
json.dump({"files":{"all.yaml":{"content":content}}},open(sys.argv[2],'w',encoding='utf-8'))
PY
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -H "User-Agent: subs-check-gist-floor-guard" \
    --data-binary "@$body" \
    "$API_BASE/gists/$GIST_ID" 2>/dev/null)"
  rm -f "$body"
  [ "$code" = "200" ] || { say "回滚 Gist 失败 HTTP $code"; return 1; }
  return 0
}

snapshot_age_ok() {
  local st
  st="$(stat -c %Y "$GOOD" 2>/dev/null)" || return 1
  [ $(( $(date +%s) - st )) -le $(( MAX_AGE_H * 3600 )) ]
}

check_once() {
  TOKEN="${GIST_GUARD_TOKEN:-$(cfg_pick github-token || true)}"
  GIST_ID="${GIST_GUARD_GIST_ID:-$(cfg_pick github-gist-id || true)}"
  if [ -z "${TOKEN:-}" ] || [ -z "${GIST_ID:-}" ]; then
    say "缺少 github-token / github-gist-id（配置路径 $CFG），跳过本轮"
    return 0
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null || true

  local cur
  cur="$(mktemp)"
  if ! gist_fetch "$GIST_ID" "$cur"; then rm -f "$cur"; return 0; fi
  local n
  n="$(count_nodes "$cur")"

  if [ "$n" -ge "$FLOOR" ]; then
    # 达标：把当前内容落成快照，供下一轮不合格时兜底
    if cp -f "$cur" "$GOOD" 2>/dev/null; then
      : # 常态静默
    else
      say "写 last-good 快照失败（$GOOD），不影响订阅"
    fi
    rm -f "$cur"; return 0
  fi

  say "Gist 当前 $n 个节点，低于下限 $FLOOR"

  if [ ! -f "$GOOD" ]; then
    say "没有 last-good 快照可回滚，保留当前结果（首个达标轮次后会开始兜底）"
    rm -f "$cur"; return 0
  fi
  local gn
  gn="$(count_nodes "$GOOD")"
  if [ "$gn" -lt "$FLOOR" ]; then
    say "last-good 也只有 $gn 个节点，同样不达标，放弃回滚"
    rm -f "$cur"; return 0
  fi
  if ! snapshot_age_ok; then
    say "last-good（$gn 节点）已超过 ${MAX_AGE_H}h，太旧不回滚"
    rm -f "$cur"; return 0
  fi

  if [ "${GIST_GUARD_DRYRUN:-0}" = "1" ]; then
    say "[dry] 将回滚 Gist 到 last-good（$gn 节点）"
    rm -f "$cur"; return 0
  fi

  if gist_patch "$GOOD"; then
    say "已回滚：Gist 恢复为 last-good 的 $gn 个节点（本轮 subs-check 产出 $n 个，不合格不上线）"
  fi
  rm -f "$cur"
}

case "${1:-once}" in
  once) check_once ;;
  loop)
    while :; do
      check_once
      sleep "$INTERVAL"
    done
    ;;
  *) echo "用法: $0 [once|loop]" >&2; exit 2 ;;
esac
