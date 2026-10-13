#!/bin/bash
# 存储账号失效巡检与告警（openlist_storage_check.sh）单元测试
#
# 背景: 网盘登录态失效历来只在同步进行中才暴露（预检/8005），三类判据都只让单个
# 同步对跳过、不发通知，读者拿不到"现在哪些存储坏了"的完整清单。OpenList 把驱动
# Init 失败原因持久化进 x_storages.status（internal/op/storage.go: Init 失败 →
# SetStatus(err.Error()) 并 MustSaveDriverStorage 写库），故开跑前读一次
# /api/admin/storage/list 就是全量真值。
#
# 判据（只认持久化的驱动健康度，不猜）:
#   status=="work" → 健康 / =="" → 未初始化，跳过 / ="disabled" 或 disabled=true
#   → 人工停用，跳过 / 其余 → 驱动 Init 失败 = 账号失效，告警
#
# 覆盖:
#   T1  全健康 → 不发通知
#   T2  失效（8005 / refresh token 过期两种真实形态）→ 发 alert 档告警，
#       含挂载名、驱动、错误原文（<pre>）、受影响同步对（含 Crypt 派生）
#   T3  disabled=true + status="disabled" → 静默
#   T4  status 空串 → 静默（未初始化/未落库，不冤枉）
#   T5  管理面 token 拿不到 → 不误报、返回 0、不发送
#   T6  storage/list 空清单 → 不误报、不发送
#   T7  storage/list 非 JSON → 不误报、不发送
#   T8  同一批失效 → 冷却期内不重发
#   T9  新的挂载进入失效 → 即使冷却中也发（读者必须立刻知道）
#   T10 续报时 first_seen 保持（"已持续多久"才准）；恢复后条目自动销账
#   T11 Crypt 派生: 底层 baidupan 坏 → baidupanCrypt 全部同步对被映射
#   T12 告警 HTML 转义: 错误原文含 < > & ' 不会触发 Telegram 400
#   T13 OPENLIST_STORAGE_ALERT=0 → 只打日志不发通知
#   T14 恒返回 0（fire-and-forget，不阻断同步 step）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); echo "✅ $1"
  else
    FAIL=$((FAIL + 1)); echo "❌ $1 (期望 [$3] 实际 [$2])"
  fi
}
ok_or() { if [ "$1" = yes ]; then chk "$2" ok ok; else chk "$2" fail ok; fi; }
has_substr() { printf '%s' "$2" | grep -qF -- "$1"; }

# ---------- 顶层 source 被测模块（规范 · 函数体不 source 真源）----------
# 与生产接线完全一致: 走 load_all.sh 统一入口。单独 source 三个文件会让
# tg_* 排版助手 / SYNC_STATE_DIR / SYNC_TASK_REGISTRY 全部缺席（它们分别在
# L0/L3/L6 层），函数体一调 tg_add_title 就是 command not found → set -e
# 直接把测试脚本静默掐死在第一条告警用例上（2026-10-13 实测踩到）。
# 真源只在这里加载一次，之后本测试对 send_telegram_message / rclone 的覆写
# 才会对被测函数生效（函数体内再 source 会被还原成真发，见通知规范 4.4）。
source "$_REPO_ROOT/.github/scripts/openlist/load_all.sh"

# ---------- fixtures ----------
STUB_BIN="$WORK_DIR/stub"
mkdir -p "$STUB_BIN"
NOTIFY_LOG="$WORK_DIR/notify.log"
: > "$NOTIFY_LOG"

# 生产形态的同步对注册表（含 Crypt 派生链路）
SYNC_TASK_REGISTRY=(
  "task0|onedrive:0|openlist:wopan176Crypt/0|task0|--auto-split"
  "task1|onedrive:1|openlist:baidupanCrypt/1|task1|--auto-split"
  "task2|onedrive:2|openlist:aliyundriveCrypt/2|task2|--auto-split"
)

mk_resp_all_ok() {
  cat >"$WORK_DIR/resp.json" <<'EOF'
{"code":200,"message":"success","data":{"content":[
 {"mount_path":"/wopan176","driver":"Wopan","status":"work","disabled":false},
 {"mount_path":"/wopan176Crypt","driver":"Crypt","status":"work","disabled":false}
],"total":2}}
EOF
}
mk_resp() {
  cat >"$WORK_DIR/resp.json" <<'EOF'
{"code":200,"message":"success","data":{"content":[
 {"mount_path":"/wopan176","driver":"Wopan","status":"work","disabled":false},
 {"mount_path":"/wopan176Crypt","driver":"Crypt","status":"work","disabled":false},
 {"mount_path":"/baidupan","driver":"BaiduPan","status":"rsp_code:8005 login failed","disabled":false},
 {"mount_path":"/baidupanCrypt","driver":"Crypt","status":"work","disabled":false},
 {"mount_path":"/aliyundrive","driver":"AliyundriveOpen","status":"[115] refresh token expired","disabled":false},
 {"mount_path":"/aliyundriveCrypt","driver":"Crypt","status":"work","disabled":false}
],"total":6}}
EOF
}
mk_resp_disabled_only() {
  cat >"$WORK_DIR/resp.json" <<'EOF'
{"code":200,"data":{"content":[
 {"mount_path":"/x","driver":"OneDrive","status":"disabled","disabled":true}
],"total":1}}
EOF
}
mk_resp_empty_status() {
  cat >"$WORK_DIR/resp.json" <<'EOF'
{"code":200,"data":{"content":[
 {"mount_path":"/y","driver":"Quark","status":"","disabled":false},
 {"mount_path":"/wopan176","driver":"Wopan","status":"work","disabled":false}
],"total":2}}
EOF
}
# 只有一个失效存储（baidupan）—— T8「冷却期内同批不重发」专用。
# ⚠️ 不能用 mk_resp（它含 baidupan + aliyundrive 两个）: 账里只记 baidupan 时
# aliyundrive 会被判成「新失效挂载」而绕过冷却必发，测的就不是冷却本身了
# （2026-10-13 第一版就这么假红过，是夹具问题不是代码问题）。
mk_resp_single_broken() {
  cat >"$WORK_DIR/resp.json" <<'EOF'
{"code":200,"message":"success","data":{"content":[
 {"mount_path":"/wopan176","driver":"Wopan","status":"work","disabled":false},
 {"mount_path":"/wopan176Crypt","driver":"Crypt","status":"work","disabled":false},
 {"mount_path":"/baidupan","driver":"BaiduPan","status":"rsp_code:8005 login failed","disabled":false},
 {"mount_path":"/baidupanCrypt","driver":"Crypt","status":"work","disabled":false}
],"total":4}}
EOF
}

# ---------- mock 1: _get_openlist_token ----------
_get_openlist_token() { [ "${TOKEN_MODE:-ok}" = ok ] && printf 'JWT_FAKE'; return 0; }

# ---------- mock 2: curl（PATH-stub）----------
# CURL_MODE: ok | all_ok | disabled | empty_list | bad_json
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
mode="${CURL_MODE:-ok}"
case "$mode" in
  all_ok)     cat "$WORK_DIR/resp.json" ;;
  disabled)   cat "$WORK_DIR/resp.json" ;;
  empty_list) echo '{"code":200,"data":{"content":[],"total":0}}' ;;
  bad_json)   echo '<html>502 gateway error</html>' ;;
  *)          cat "$WORK_DIR/resp.json" ;;
esac
EOF
chmod +x "$STUB_BIN/curl"
# ⚠️ stub 通过 PATH 被 exec，**读不到测试 shell 的未导出变量** —— 必须显式导出。
# 2026-10-13 实测踩到: `CURL_MODE=empty_list check_...` 这种前缀赋值只在函数执行
# 期间改 shell 变量、**不会传给子进程**，stub 里 CURL_MODE 仍为空 → 走 default
# 分支读上一轮残留的 resp.json → T6/T7/T8 全部假红（测的是残留夹具，不是被测逻辑）。
# 因此用例开关一律走 use_case（赋值 + 导出）。
export WORK_DIR
export PATH="$STUB_BIN:$PATH"

use_case() {
  CURL_MODE="$1"
  TOKEN_MODE="${2:-ok}"
  export CURL_MODE TOKEN_MODE
}

# 通知正文读取（断言一律基于内容，不基于文件名——后者会把 grep 目标
# 变成路径字符串，导致所有内容断言假红）
notify_txt() { cat "$NOTIFY_LOG" 2>/dev/null || true; }
# ⚠️ 不能写成 `grep -c ... || echo 0`: grep 在零匹配时返回 1 **但仍打印 0**，
# set -e 下经 $() 捕获会得到 "0\n0" 两个值，chk 的相等比较必然假红
# （2026-10-13 实测踩到: 5 个"未发送"用例全红而实际行为正确）。
notify_count() {
  local n
  n=$(grep -c 'TIER=' "$NOTIFY_LOG" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ---------- mock 3: rclone（本地文件模拟 SYNC_STATE_DIR）----------
rclone() {
  case "$1" in
    cat) cat "$2" 2>/dev/null || return 1 ;;
    rcat) cat > "$2" 2>/dev/null || return 1 ;;
    *) return 0 ;;
  esac
}

# ---------- mock 4: send_telegram_message（记录 tier 与消息体）----------
send_telegram_message() {
  local text="$1" _pm="${2:-HTML}" tier="${3:-}"
  { printf 'TIER=%s\n' "${tier:-<none>}"; printf '%s' "$text"; } >> "$NOTIFY_LOG"
  return 0
}

reset_notify() { : > "$NOTIFY_LOG"; }
reset_state()  { rm -f "$WORK_DIR/storage_alert.json"; SYNC_STATE_DIR="$WORK_DIR"; }

# ================= T1 全健康 =================
reset_state; reset_notify; mk_resp_all_ok; use_case all_ok
check_openlist_storage_health
chk "T1a 全健康 → 未发送通知" "$(notify_count)" "0"
chk "T1b 全健康 → 未生成状态文件" "$([ -e "$WORK_DIR/storage_alert.json" ] && echo yes || echo no)" "no"

# ================= T2 失效 → 告警 =================
reset_state; reset_notify; mk_resp; use_case ok
check_openlist_storage_health >/dev/null 2>&1
chk "T2a 失效 → 发送 1 条" "$(notify_count)" "1"
ok_or "$(has_substr 'TIER=alert' "$(notify_txt)" && echo yes)" "T2b 走 alert 档（@SaberFuckBot，需人工介入）"
ok_or "$(has_substr '🚨 存储账号失效 · 2' "$(notify_txt)" && echo yes)" "T2c 标题带失效计数"
ok_or "$(has_substr '/baidupan' "$(notify_txt)" && echo yes)" "T2d 列失效挂载 baidupan"
ok_or "$(has_substr '/aliyundrive' "$(notify_txt)" && echo yes)" "T2e 列失效挂载 aliyundrive"
ok_or "$(has_substr 'BaiduPan' "$(notify_txt)" && echo yes)" "T2f 带驱动名"
ok_or "$(has_substr 'rsp_code:8005 login failed' "$(notify_txt)" && echo yes)" "T2g 原始错误原文进 <pre>"
ok_or "$(has_substr '[115] refresh token expired' "$(notify_txt)" && echo yes)" "T2h 两种真实失效形态都收录"
ok_or "$(has_substr 'first_seen' "$(cat "$WORK_DIR/storage_alert.json" 2>/dev/null)" && echo yes)" "T2i 落账含 first_seen"
ok_or "$(has_substr '/baidupan' "$(cat "$WORK_DIR/storage_alert.json" 2>/dev/null)" && echo yes)" "T2j 状态文件按挂载记账"

# ================= T3 disabled + status=disabled → 静默 =================
reset_state; reset_notify; mk_resp_disabled_only; use_case disabled
check_openlist_storage_health >/dev/null 2>&1
chk "T3a 人工停用 → 不发送" "$(notify_count)" "0"
chk "T3b 人工停用 → 不落账" "$([ -e "$WORK_DIR/storage_alert.json" ] && echo yes || echo no)" "no"

# ================= T4 status 空串 → 静默 =================
reset_state; reset_notify; mk_resp_empty_status; use_case disabled
check_openlist_storage_health >/dev/null 2>&1
chk "T4a status 空串 → 不发送" "$(notify_count)" "0"

# ================= T5 token 拿不到 → 不误报 =================
reset_state; reset_notify; mk_resp; use_case ok fail
check_openlist_storage_health >/dev/null 2>&1
chk "T5a token 失败 → 不发送（不误报账号失效）" "$(notify_count)" "0"
chk "T5b token 失败 → 不落账" "$([ -e "$WORK_DIR/storage_alert.json" ] && echo yes || echo no)" "no"

# ================= T6 空清单 → 不误报 =================
reset_state; reset_notify; use_case empty_list
check_openlist_storage_health >/dev/null 2>&1
chk "T6a 空清单 → 不发送" "$(notify_count)" "0"

# ================= T7 非 JSON → 不误报 =================
reset_state; reset_notify; use_case bad_json
check_openlist_storage_health >/dev/null 2>&1
chk "T7a 非 JSON → 不发送" "$(notify_count)" "0"

# ================= T8 冷却期内不重发 =================
# 只保留 baidupan 一个失效存储（与账内条目同批），notified_at=刚刚
reset_state; reset_notify; mk_resp_single_broken
NOW=$(date +%s)
python3 - "$WORK_DIR/storage_alert.json" "$NOW" <<'PY'
import json, sys
p, now = sys.argv[1], int(sys.argv[2])
json.dump({"/baidupan": {"driver": "BaiduPan", "status": "rsp_code:8005 login failed",
                         "first_seen": now - 1800, "last_seen": now,
                         "notified_at": now}},
          open(p, "w"), indent=2)
PY
use_case ok
check_openlist_storage_health >/dev/null 2>&1
chk "T8a 冷却期内同批失效 → 不重发" "$(notify_count)" "0"

# ================= T9 新挂载进入失效 → 冷却中也发 =================
# 账里只有 /baidupan（T8 建的），此刻把响应换成含 /aliyundrive 的失效集
# ⇒ aliyundrive 是「历史账里没有的新失效挂载」，必须立刻发（读者不能等 6h 才发现）
mk_resp
use_case ok
check_openlist_storage_health >/dev/null 2>&1
chk "T9a 新失效挂载 → 冷却中也发" "$(notify_count)" "1"
ok_or "$(has_substr '/aliyundrive' "$(notify_txt)" && echo yes)" "T9b 新失效挂载出现在告警里"
ok_or "$(has_substr '已持续' "$(notify_txt)" && echo yes)" "T9c 有历史账 → 告警带已持续时长"

# ================= T10 first_seen 保持 + 恢复销账 =================
FS_AFTER=$(jq -r '.["/baidupan"].first_seen // 0' "$WORK_DIR/storage_alert.json" 2>/dev/null || echo 0)
chk "T10a 续报后 first_seen 未被改写" "$FS_AFTER" "$(( NOW - 1800 ))"
reset_notify; mk_resp_all_ok; use_case all_ok
check_openlist_storage_health >/dev/null 2>&1
ok_or "$(jq -e 'length == 0' "$WORK_DIR/storage_alert.json" >/dev/null 2>&1 && echo yes)" "T10b 恢复后状态文件清空（自动销账）"
chk "T10c 恢复 → 不发通知" "$(notify_count)" "0"

# ================= T11 / T12: 受影响同步对（Crypt 派生）+ HTML 转义 =================
reset_state; reset_notify; mk_resp
python3 - "$WORK_DIR/resp.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# 让 baidupan 的错误串带 HTML 敏感字符 + 换行，验证进 <pre> 前已转义、
# 且换行被归一成单空格（否则行式 TSV 会串行）
for c in d["data"]["content"]:
    if c["mount_path"] == "/baidupan":
        c["status"] = 'rsp_code:8005\nlogin failed <a&b> "x"'
json.dump(d, open(p, "w"), indent=2)
PY
use_case ok
check_openlist_storage_health >/dev/null 2>&1
ok_or "$(has_substr 'task1' "$(notify_txt)" && echo yes)" "T11a Crypt 派生: baidupan 坏 → task1（走 baidupanCrypt）被列出"
ok_or "$(has_substr 'openlist:baidupanCrypt/1' "$(notify_txt)" && echo yes)" "T11b 派生路径同步对完整列出"
ok_or "$([ "$(printf '%s\n' "$_SS_BROKEN_TSV" | grep -c .)" = "2" ] && echo yes)" "T11c status 内换行已归一：TSV 仍为 2 行（2 个失效存储，未串行）"
ok_or "$(has_substr '&lt;a&amp;b&gt;' "$(notify_txt)" && echo yes)" "T12a 错误原文 < > & 已转义（不会 Telegram 400）"
ok_or "$(has_substr '"x"' "$(notify_txt)" && echo yes)" "T12b 双引号原样保留（HTML 文本节点无需转义，不误伤原文）"
ok_or "$(! printf '%s' "$(notify_txt)" | grep -q 'login failed <[a-z]' && echo yes)" "T12c 通知内不存在裸 <tag>（不会被 Telegram 当成标签）"

# ================= T13 OPENLIST_STORAGE_ALERT=0 → 只打日志 =================
reset_state; reset_notify; mk_resp
OPENLIST_STORAGE_ALERT=0
export OPENLIST_STORAGE_ALERT
check_openlist_storage_health >/dev/null 2>&1
chk "T13a 开关关闭 → 不发送" "$(notify_count)" "0"
chk "T13b 开关关闭 → 仍落账（恢复后能销账）" "$([ -s "$WORK_DIR/storage_alert.json" ] && echo yes || echo no)" "yes"
unset OPENLIST_STORAGE_ALERT

# ================= T14 恒返回 0（fire-and-forget）=================
reset_state; use_case bad_json
check_openlist_storage_health >/dev/null 2>&1
chk "T14a 巡检失败也返回 0" "$?" "0"
reset_state; mk_resp; use_case ok
check_openlist_storage_health >/dev/null 2>&1
chk "T14b 巡检成功返回 0" "$?" "0"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
