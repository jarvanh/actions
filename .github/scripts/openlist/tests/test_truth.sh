#!/bin/bash
# truth-check（传输后重启取后端真值）——逻辑验证（mock docker/curl/rclone/timeout）
# 历史分支（crypt-vs-raw 计数对比）已删除: 两视图共享同一被污染的 OpenList
# 缓存，对比恒等、检测力为零（run 31951008332 实锤），本测试同步改为验证:
#   1. 有传输 → 重启容器 → 假成功数 = 重启前后计数差 → 放行给 diff
#   2. 无传输 → 不重启、不计数，直接放行
#   3. 非 openlist: 目标 → 直接跳过（openlist: 挂载通用，不再限定 wopan176Crypt）
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LOGF=/tmp/test_truth_log.txt; : > "$LOGF"

# --- 定位仓库根目录（tests/ 向上四级）---
_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

# --- 先 source 被测代码（sed 截取含全部被测函数的区段）---
source "$_REPO_ROOT/.github/scripts/openlist/utils.sh" 2>/dev/null
# 注意: macOS 自带 bash 3.2 的 source <(...（进程替换）不生效，先落临时文件
_SYNC_EXCERPT=$(mktemp /tmp/test_truth_sync.XXXXXX)
sed -n '1,400p' "$_REPO_ROOT/.github/scripts/openlist/sync.sh" > "$_SYNC_EXCERPT"
source "$_SYNC_EXCERPT" 2>/dev/null || true
rm -f "$_SYNC_EXCERPT"

# --- mocks（必须在 source 之后定义，否则被脚本内同名函数覆盖）---
docker() {
  case "$1 $2" in
    "ps --format") echo openlist ;;
    "restart openlist") touch /tmp/docker_restarted; echo openlist ;;
    *) return 0 ;;
  esac
}
# 真实调用形如 `sudo docker ps ...`，mock 需剥掉首参 docker 再转发，
# 否则 docker mock 收到 $1=docker 匹配不到 "ps --format" → 空输出 → grep 失败
sudo() { [ "${1:-}" = docker ] && shift; docker "$@"; }
timeout() { shift; "$@"; }          # 剥掉时长参数，直接执行（函数 mock 可见）
sleep() { :; }                      # 跳过等待（驱动初始化 60s 等），测试秒回
# CURL_MODE 控制 /api/admin/storage/load_all 响应: ok={"code":200} / fail=401;
# /api/storage/list 恒返回数据（真实环境该 API 可用，方法3 兜底才成立）
CURL_MODE=fail
curl() {
  case "$*" in
    *storage/load_all*) [ "$CURL_MODE" = ok ] && echo '{"code":200,"message":"success"}' || echo '{"code":401,"message":"permission denied"}' ;;
    *storage/list*)  echo '{"code":200,"data":{"content":[]}}' ;;
    *ping*)          : ;;
  esac
  return 0
}
_get_openlist_token() { echo fake-token; }
_raw_remote_for() { echo "openlist:wopan176"; }
_refresh_ol_cache_fast() { :; }
# 计数器必须落文件: rclone size 在命令替换（子 shell）里执行，
# 内存变量 SIZE_CALLS++ 回不到父 shell，pre/post 两次都会读到同值
rclone() {
  case "$1" in
    size)
      local n
      n=$(cat /tmp/size_calls 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > /tmp/size_calls
      if [ "$n" -le 1 ]; then echo '{"count":1413,"bytes":999}'
      else echo '{"count":1394,"bytes":999}'; fi
      ;;
    *) return 0 ;;
  esac
}
echo 0 > /tmp/size_calls

# --- 场景1: 本轮有传输 → 重启 + 检测假成功 ---
LAST_ATTEMPT_LOG=/tmp/test_last_attempt.log
printf 'INFO : a.mp3: Copied (new)\nINFO : b.mp3: Copied (new)\n' > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
FAKE_SUCCESS_COUNT=0
_openlist_truth_check "openlist:wopan176Crypt/backup" "$LOGF"
rc=$?
[ -f /tmp/docker_restarted ] && ok "1a 有传输 → 容器被重启" || bad "1a: 容器未重启"
[ "$FAKE_SUCCESS_COUNT" = "19" ] && ok "1b 假成功数 = 1413-1394 = 19" || bad "1b: [$FAKE_SUCCESS_COUNT]"
[ "$rc" = "0" ] && ok "1c 返回 0（放行给 diff）" || bad "1c: rc=$rc"
grep -q "已暴露为缺失" "$LOGF" && ok "1d 日志提示已暴露为缺失" || bad "1d"

# --- 场景2: 本轮无传输 → 不重启不计数，直接放行 ---
: > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
echo 10 > /tmp/size_calls
_openlist_truth_check "openlist:wopan176Crypt/backup" "$LOGF"
rc=$?
[ ! -f /tmp/docker_restarted ] && ok "2a 无传输 → 不重启" || bad "2a: 不该重启却重启了"
grep -q "本轮无传输" "$LOGF" && ok "2b 走了无传输放行路径" || bad "2b: $(tail -3 "$LOGF")"
[ "$rc" = "0" ] && ok "2c 返回 0" || bad "2c: rc=$rc"
[ "$(cat /tmp/size_calls)" = "10" ] && ok "2d 未调用 rclone size（不计数）" || bad "2d: size 被调用 $(cat /tmp/size_calls) 次"

# --- 场景3: 非 openlist: 目标 → 直接返回（openlist: 挂载通用后的跳过口径）---
_openlist_truth_check "onedrive:backup" "$LOGF" && ok "3 非 openlist: 目标跳过" || bad "3"

# --- 场景4: _refresh_ol_drivers — load_all 失败 → 重启容器 ---
#   4a 首次: 重启容器、置全局标记、返回 0
#   4b 同轮第二次: 不再重启（标记生效），退回方法3 storage 重载
#   4c load_all 成功: 不重启直接返回 0
CURL_MODE=fail
_OL_DRIVER_RESTART_DONE=0
rm -f /tmp/docker_restarted
: > "$LOGF"
_refresh_ol_drivers "$LOGF"
rc=$?
[ "$rc" = "0" ] && ok "4a-1 load_all 失败 → 重启后返回 0" || bad "4a-1: rc=$rc"
[ -f /tmp/docker_restarted ] && ok "4a-2 容器被重启" || bad "4a-2: 容器未重启"
[ "$_OL_DRIVER_RESTART_DONE" = "1" ] && ok "4a-3 重启标记已置位" || bad "4a-3: [$_OL_DRIVER_RESTART_DONE]"
grep -q "驱动已完整重初始化" "$LOGF" && ok "4a-4 日志注明方法2 重启" || bad "4a-4"

rm -f /tmp/docker_restarted
: > "$LOGF"
_refresh_ol_drivers "$LOGF"
rc=$?
[ "$rc" = "0" ] && ok "4b-1 同轮二次失败 → 方法3 兜底返回 0" || bad "4b-1: rc=$rc"
[ ! -f /tmp/docker_restarted ] && ok "4b-2 标记生效不再重启" || bad "4b-2: 不该重启却重启了"
grep -q "退回方法3" "$LOGF" && ok "4b-3 走了方法3 兜底" || bad "4b-3"

CURL_MODE=ok
rm -f /tmp/docker_restarted
: > "$LOGF"
_refresh_ol_drivers "$LOGF"
rc=$?
[ "$rc" = "0" ] && ok "4c-1 load_all 成功返回 0" || bad "4c-1: rc=$rc"
[ ! -f /tmp/docker_restarted ] && ok "4c-2 无需重启" || bad "4c-2: 不该重启却重启了"
grep -q "storage/load_all 驱动已重建" "$LOGF" && ok "4c-3 日志注明方法1 load_all" || bad "4c-3: $(tail -3 "$LOGF")"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$LOGF" "$LAST_ATTEMPT_LOG" /tmp/docker_restarted /tmp/size_calls
[ $FAIL -eq 0 ]
