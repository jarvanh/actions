#!/bin/bash
# truth-check（传输后重启取后端真值）——逻辑验证（mock docker/curl/rclone/timeout）
# 历史分支（crypt-vs-raw 计数对比）已删除: 两视图共享同一被污染的 OpenList
# 缓存，对比恒等、检测力为零（run 31951008332 实锤），本测试同步改为验证:
#   1. 有传输 → 重启容器 → 假成功数 = 重启前后计数差 → 放行给 diff
#   2. 无传输 → 不重启、不计数，直接放行
#   3. 非 wopan176Crypt 目标 → 直接跳过
set -u
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LOGF=/tmp/test_truth_log.txt; : > "$LOGF"

# --- mocks ---
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
curl() { return 0; }
_get_openlist_token() { echo fake-token; }
_raw_remote_for() { echo "openlist:wopan176"; }
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

source /workspace/.github/scripts/openlist/utils.sh 2>/dev/null
source <(sed -n '1,300p' /workspace/.github/scripts/openlist/sync.sh) 2>/dev/null || true

_refresh_ol_cache_fast() { :; }

# --- 场景1: 本轮有传输 → 重启 + 检测假成功 ---
LAST_ATTEMPT_LOG=/tmp/test_last_attempt.log
printf 'INFO : a.mp3: Copied (new)\nINFO : b.mp3: Copied (new)\n' > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
RAW_CRYPT_GHOST_COUNT=0
_wopan_truth_check "openlist:wopan176Crypt/backup" "$LOGF"
rc=$?
[ -f /tmp/docker_restarted ] && ok "1a 有传输 → 容器被重启" || bad "1a: 容器未重启"
[ "$RAW_CRYPT_GHOST_COUNT" = "19" ] && ok "1b 假成功数 = 1413-1394 = 19" || bad "1b: [$RAW_CRYPT_GHOST_COUNT]"
[ "$rc" = "0" ] && ok "1c 返回 0（放行给 diff）" || bad "1c: rc=$rc"
grep -q "已暴露为缺失" "$LOGF" && ok "1d 日志提示已暴露为缺失" || bad "1d"

# --- 场景2: 本轮无传输 → 不重启不计数，直接放行 ---
: > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
echo 10 > /tmp/size_calls
_wopan_truth_check "openlist:wopan176Crypt/backup" "$LOGF"
rc=$?
[ ! -f /tmp/docker_restarted ] && ok "2a 无传输 → 不重启" || bad "2a: 不该重启却重启了"
grep -q "本轮无传输" "$LOGF" && ok "2b 走了无传输放行路径" || bad "2b: $(tail -3 "$LOGF")"
[ "$rc" = "0" ] && ok "2c 返回 0" || bad "2c: rc=$rc"
[ "$(cat /tmp/size_calls)" = "10" ] && ok "2d 未调用 rclone size（不计数）" || bad "2d: size 被调用 $(cat /tmp/size_calls) 次"

# --- 场景3: 非 wopan176Crypt 目标 → 直接返回 ---
_wopan_truth_check "openlist:aliyundriveCrypt/backup" "$LOGF" && ok "3 非 wopan 目标跳过" || bad "3"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$LOGF" "$LAST_ATTEMPT_LOG" /tmp/docker_restarted /tmp/size_calls
[ $FAIL -eq 0 ]
