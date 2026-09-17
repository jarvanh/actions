#!/usr/bin/env bash
# 验证「账号池为空」与「启动失败」两条路径（确保端口真的空闲）
set -uo pipefail
T=/workspace/.wbtest
rm -rf "$T"; mkdir -p "$T/bin" "$T/github/.github/scripts/telegram" "$T/dropbox/self-hosted/workbuddy-gateway/logs"
cp /workspace/.github/scripts/telegram/tg_notify.sh "$T/github/.github/scripts/telegram/tg_notify.sh"
python3 - "$T/github/.github/scripts/telegram/tg_notify.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('send_tg() {\n  local text="$1"',
              'send_tg() {\n  local text="$1"\n  printf \'=====SEND=====\\n%s\\n=====END=====\\n\' "$text" >> /workspace/.wbtest/notify.out; return 0')
open(p, 'w').write(s)
PY
# 变体 A：能监听但账号池为空
cat > "$T/fakebin_empty" <<'INNER'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "serve" ] && MODE=serve; done
[ "${MODE:-}" = "serve" ] || exit 0
echo "   账号池:        0 个账号 (有效 0, 失效 0)"
exec python3 - <<'PY'
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', 8318), H).serve_forever()
PY
INNER
# 变体 B：启动即退出（不监听）
cat > "$T/fakebin_dead" <<'INNER'
#!/usr/bin/env bash
echo "警告: 未检测到有效凭据"
echo "请先执行: workbuddy-gateway login 扫码登录"
exit 1
INNER
chmod 755 "$T/fakebin_empty" "$T/fakebin_dead"
cat > "$T/bin/curl" <<'INNER'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *api.github.com*) echo '{"tag_name": "v1.2.3"}'; exit 0;; esac; done
for a in "$@"; do case "$a" in *workbuddy-gateway/releases/*)
  out=""; prev=""
  for b in "$@"; do [ "$prev" = "-o" ] && out="$b"; prev="$b"; done
  [ -n "$out" ] && { cp "${WB_FAKEBIN:-/workspace/.wbtest/fakebin_empty}" "$out"; exit 0; };;
esac; done
exec /usr/bin/curl "$@"
INNER
chmod 755 "$T/bin/curl"
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open('/workspace/.github/workflows/openclaw.yml'))
steps = {s.get('id'): s for s in doc['jobs']['build']['steps']}
open('/workspace/.wbtest/start.sh','w').write(steps['run_workbuddy']['run'])
PY
sed -i 's|WB_DIR="/dropbox/self-hosted/workbuddy-gateway"|WB_DIR="/workspace/.wbtest/dropbox/self-hosted/workbuddy-gateway"|' "$T/start.sh"
sed -i 's|for i in $(seq 1 60); do|for i in $(seq 1 4); do|' "$T/start.sh"

export PATH="$T/bin:$PATH"
export GITHUB_WORKSPACE="$T/github"
export TELEGRAM_BOT_TOKEN=fake TELEGRAM_CHAT_ID=fake
export TG_RUN_URL="https://github.com/x/y/actions/runs/1" TG_RUN_STARTED_AT=""

free_port() {
  for _ in 1 2 3 4 5; do
    pid=$(ss -ltnp 2>/dev/null | awk '/:8318/ {match($0,/pid=([0-9]+)/,m); if(m[1]!="") print m[1]}' | head -n 1)
    [ -z "$pid" ] && break
    kill -9 "$pid" 2>/dev/null || true; sleep 1
  done
  pkill -9 -f fakebin_empty 2>/dev/null || true; pkill -9 -f fakebin_dead 2>/dev/null || true
  sleep 1
}

echo "########## E：账号池为空 ##########"
free_port
: > "$T/notify.out"
export WB_FAKEBIN="$T/fakebin_empty"
bash "$T/start.sh" 2>&1 | tail -4
echo "--- notify ---"; cat "$T/notify.out"

echo; echo "########## F：进程启动后立即退出 ##########"
free_port
rm -f "$T/dropbox/self-hosted/workbuddy-gateway/.installed-version"
: > "$T/notify.out"
export WB_FAKEBIN="$T/fakebin_dead"
bash "$T/start.sh" 2>&1 | tail -4
echo "--- notify ---"; cat "$T/notify.out"

free_port
echo; echo "########## 完成 ##########"
