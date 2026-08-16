#!/bin/bash
# 传输后强制重启取真值——逻辑验证（mock docker/curl/rclone/timeout）
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
curl() { return 0; }
_get_openlist_token() { echo fake-token; }
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
source <(sed -n '1,400p' /workspace/.github/scripts/openlist/sync.sh) 2>/dev/null || true

_ensure_crypt_config() { _CRYPT_ONTHEFLY=":crypt,stub:"; _CRYPT_DNE=true; return 0; }
_raw_count_view_for() { echo ":crypt,stub:"; }
_raw_remote_for() { echo "openlist:wopan176"; }
_refresh_ol_cache_fast() { :; }

# --- 场景1: 本轮有传输 → 重启 + 检测假成功 ---
LAST_ATTEMPT_LOG=/tmp/test_last_attempt.log
printf 'INFO : a.mp3: Copied (new)\nINFO : b.mp3: Copied (new)\n' > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
RAW_CRYPT_GHOST_COUNT=0
_wopan_raw_verify "openlist:wopan176Crypt/backup" "$LOGF"
rc=$?
[ -f /tmp/docker_restarted ] && ok "1a 有传输 → 容器被重启" || bad "1a: 容器未重启"
[ "$RAW_CRYPT_GHOST_COUNT" = "19" ] && ok "1b 假成功数 = 1413-1394 = 19" || bad "1b: [$RAW_CRYPT_GHOST_COUNT]"
[ "$rc" = "0" ] && ok "1c 返回 0（放行给 diff）" || bad "1c: rc=$rc"
grep -q "已暴露为缺失" "$LOGF" && ok "1d 日志提示已暴露为缺失" || bad "1d"

# --- 场景2: 本轮无传输 → 不重启，走计数对比 ---
: > "$LAST_ATTEMPT_LOG"
rm -f /tmp/docker_restarted
echo 10 > /tmp/size_calls
_wopan_raw_verify "openlist:wopan176Crypt/backup" "$LOGF"
[ ! -f /tmp/docker_restarted ] && ok "2a 无传输 → 不重启" || bad "2a: 不该重启却重启了"
grep -q "crypt 文件数: 1394" "$LOGF" && ok "2b 走了计数对比路径" || bad "2b: $(tail -3 "$LOGF")"

# --- 场景3: 非 wopan176Crypt 目标 → 直接返回 ---
_wopan_raw_verify "openlist:aliyundriveCrypt/backup" "$LOGF" && ok "3 非 wopan 目标跳过" || bad "3"

echo "-----"
echo "PASS=$PASS FAIL=$FAIL"
rm -f "$LOGF" "$LAST_ATTEMPT_LOG" /tmp/docker_restarted
[ $FAIL -eq 0 ]
