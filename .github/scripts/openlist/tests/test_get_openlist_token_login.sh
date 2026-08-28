#!/usr/bin/env bash
# _get_openlist_token 动态账密登录单元测试（PATH-stub curl 隔离网络）
# 覆盖契约:
#   T1 成功登录 → stdout 输出 data.token，rc=0
#   T2 密码错误（code≠200 且无 token）→ 重试一次后 rc≠0，stderr 提示检查
#      OPENLIST_ADMIN_PASSWORD，且不回显服务端 message
#   T3 未设置 OPENLIST_ADMIN_PASSWORD → rc≠0 快速失败
#   T4 密码含引号/反斜杠/美元符 → jq 构造体往返无损（假服务端按字段校验）
#   T5 服务端无响应（curl 失败）→ 重试两次后 rc≠0
#   T6 用户名默认 admin，OPENLIST_ADMIN_USER 可覆盖
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

PASS=0
FAIL=0
chk() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    echo "✅ $1"
  else
    FAIL=$((FAIL + 1))
    echo "❌ $1 (期望 [$3] 实际 [$2])"
  fi
}
ok_or() { if [ "$1" = yes ]; then chk "$2" ok ok; else chk "$2" fail ok; fi }
has_substr() { printf '%s' "$2" | grep -qF "$1"; }

# ---------- 抽取被测函数 ----------
sed -n '/^_get_openlist_token()/,/^}/p' "$SCRIPT_DIR/../utils.sh" > extracted.sh
source extracted.sh
export OPENLIST_ADMIN_PASSWORD="${OPENLIST_ADMIN_PASSWORD:-pw123}"

# ---------- 假 curl：按 SCENARIO 输出 canned 响应并记录调用次数 ----------
STUB_BIN="$WORK_DIR/stub"
mkdir -p "$STUB_BIN"
CALL_LOG="$WORK_DIR/curl_calls.log"
cat > "$STUB_BIN/curl.impl" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_CURL_LABEL:-call}" >> "${CALL_LOG:?}"
case "${SCENARIO:-}" in
  success)
    # 服务端视角: 校验收到的请求体字段与场景账号一致才发 token（T4 往返校验）
    want_user="${FAKE_USERNAME:-admin}"
    want_pass="${FAKE_PASSWORD:-pw123}"
    got_user="$(printf '%s' "$CURL_LAST_D" | jq -r '.username // empty' 2>/dev/null || true)"
    got_pass="$(printf '%s' "$CURL_LAST_D" | jq -r '.password // empty' 2>/dev/null || true)"
    if [ "$got_user" != "$want_user" ] || [ "$got_pass" != "$want_pass" ]; then
      echo '{"code":400,"message":"bad request body","data":null}'
      exit 0
    fi
    echo '{"code":200,"message":"success","data":{"token":"JWT_FAKE_OK"}}'
    ;;
  wrongpass)
    echo '{"code":401,"message":"username or password incorrect","data":null}'
    ;;
  noresp)
    exit 28
    ;;
  notjson)
    echo '<html>gateway error</html>'
    ;;
  *)
    echo '{"code":500,"message":"internal error","data":null}'
    ;;
esac
EOF
chmod +x "$STUB_BIN/curl.impl"
# 外层 wrapper: 解析出请求体塞进 CURL_LAST_D 再转调实现
cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
prev=""
CURL_LAST_D=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -d|--data-binary|--data-raw)
      CURL_LAST_D="\$2"; shift 2; continue ;;
  esac
  prev="\$1"; shift
done
export CURL_LAST_D
exec "$STUB_BIN/curl.impl" "\$@"
EOF
chmod +x "$STUB_BIN/curl"
export STUB_DIR_IMPL="$STUB_BIN"
export CALL_LOG
export PATH="$STUB_BIN:$PATH"

run_tok() {
  local err_file="$WORK_DIR/stderr.txt"
  TOKEN_OUT=""
  TOKEN_RC=0
  TOKEN_OUT=$(_get_openlist_token 2>"$err_file") || TOKEN_RC=$?
  ERR_OUT="$(cat "$err_file")"
}

reset_log() { : > "$CALL_LOG"; }

# ---------- T1 成功 ----------
reset_log
SCENARIO=success run_tok
chk "T1 rc=0" "$TOKEN_RC" "0"
chk "T1 输出 token" "$TOKEN_OUT" "JWT_FAKE_OK"

# ---------- T2 密码错误: 重试 2 次、rc=1、提示含变量名且不回显 message ----------
reset_log
SCENARIO=wrongpass run_tok
chk "T2 rc=1" "$TOKEN_RC" "1"
chk "T2 输出为空" "$TOKEN_OUT" ""
chk "T2 重试两次" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "2"
ok_or "$(has_substr OPENLIST_ADMIN_PASSWORD "$ERR_OUT" && echo yes)" "T2 stderr 指明变量名"
if has_substr incorrect "$ERR_OUT"; then
  chk "T2 不回显服务端 message" fail ok
else
  chk "T2 不回显服务端 message" ok ok
fi

# ---------- T3 未设置密码 ----------
reset_log
if (
  unset OPENLIST_ADMIN_PASSWORD
  _get_openlist_token >/dev/null 2>&1
); then
  chk "T3 未设密码时 rc≠0" fail ok
else
  chk "T3 未设密码时 rc≠0" ok ok
fi

# ---------- T4 特殊字符密码往返无损 ----------
reset_log
SPECIAL_PASS='p"@7\$h~`\*(x)'
SCENARIO=success FAKE_PASSWORD="$SPECIAL_PASS" OPENLIST_ADMIN_PASSWORD="$SPECIAL_PASS" run_tok
chk "T4 特殊字符密码仍登录成功" "$TOKEN_RC" "0"
chk "T4 token 正常返回" "$TOKEN_OUT" "JWT_FAKE_OK"

# ---------- T5 服务端无响应重试两次 ----------
reset_log
SCENARIO=noresp run_tok
chk "T5 rc=1" "$TOKEN_RC" "1"
chk "T5 尝试两次" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "2"

# ---------- T6 用户名覆盖 ----------
reset_log
SCENARIO=success FAKE_USERNAME=root OPENLIST_ADMIN_USER=root run_tok
chk "T6 OPENLIST_ADMIN_USER 生效 rc=0" "$TOKEN_RC" "0"
reset_log
SCENARIO=success FAKE_USERNAME=admin run_tok
chk "T6 默认 admin" "$TOKEN_RC" "0"

# ---------- T7 非 JSON 响应不泄漏且 rc=1 ----------
reset_log
SCENARIO=notjson run_tok
chk "T7 非 JSON 响应 rc=1" "$TOKEN_RC" "1"
chk "T7 输出为空" "$TOKEN_OUT" ""

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
