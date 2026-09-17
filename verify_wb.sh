#!/usr/bin/env bash
# 自包含验证 workbuddy-gateway 两个步骤（不依赖 /workspace/.wbtest 里的任何东西）
set -uo pipefail
T=/workspace/.wbtest
rm -rf "$T"; mkdir -p "$T/bin" "$T/github/.github/scripts/telegram" "$T/dropbox/self-hosted/workbuddy-gateway/logs"
cp /workspace/.github/scripts/telegram/tg_notify.sh "$T/github/.github/scripts/telegram/tg_notify.sh"
python3 - "$T/github/.github/scripts/telegram/tg_notify.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('send_tg() {\n  local text="$1"',
              'send_tg() {\n  local text="$1"\n  printf \'=====SEND=====\\n%s\\n=====END=====\\n\' "$text" >> /workspace/.wbtest/notify.out; return 0')
open(p, 'w').write(s)
PY
cat > "$T/fakebin" <<'INNER'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "serve" ] && MODE=serve; done
[ "${MODE:-}" = "serve" ] || { echo "unknown"; exit 0; }
echo "   账号池:        2 个账号 (有效 2, 失效 0)"
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
chmod 755 "$T/fakebin"
cat > "$T/bin/curl" <<'INNER'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *api.github.com*) echo '{"tag_name": "v1.2.3"}'; exit 0;; esac; done
for a in "$@"; do case "$a" in *workbuddy-gateway/releases/*)
  out=""; prev=""
  for b in "$@"; do [ "$prev" = "-o" ] && out="$b"; prev="$b"; done
  [ -n "$out" ] && { cp /workspace/.wbtest/fakebin "$out"; exit 0; };;
esac; done
exec /usr/bin/curl "$@"
INNER
chmod 755 "$T/bin/curl"
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open('/workspace/.github/workflows/openclaw.yml'))
steps = {s.get('id'): s for s in doc['jobs']['build']['steps']}
open('/workspace/.wbtest/start.sh','w').write(steps['run_workbuddy']['run'])
stopsrc = steps['final_archive']['run']
a = stopsrc.index('echo "3b. Stopping workbuddy-gateway..."')
b = stopsrc.index('# 用法与版式同 send_telegram_alert')
open('/workspace/.wbtest/stop.sh','w').write('set -uo pipefail\n' + stopsrc[a:b])
PY
sed -i 's|WB_DIR="/dropbox/self-hosted/workbuddy-gateway"|WB_DIR="/workspace/.wbtest/dropbox/self-hosted/workbuddy-gateway"|' \
    "$T/start.sh" "$T/stop.sh"
sed -i 's|for i in $(seq 1 60); do|for i in $(seq 1 15); do|' "$T/start.sh"

export PATH="$T/bin:$PATH"
export GITHUB_WORKSPACE="$T/github"
export TELEGRAM_BOT_TOKEN=fake TELEGRAM_CHAT_ID=fake
export TG_RUN_URL="https://github.com/x/y/actions/runs/1" TG_RUN_STARTED_AT=""

pkill -9 -f "fakebin serve" 2>/dev/null || true; sleep 1
: > "$T/notify.out"

echo "########## A：首次安装 ##########"
bash "$T/start.sh" 2>&1 | tail -6
echo "rc=$?"; echo "--- meta ---"; cat /tmp/run-workbuddy-meta.env
echo "--- notify ---"; cat "$T/notify.out"

echo; echo "########## B：再次运行（已在最新版） ##########"
: > "$T/notify.out"
pkill -9 -f "fakebin serve" 2>/dev/null || true; sleep 1
bash "$T/start.sh" 2>&1 | tail -4
echo "--- notify ---"; cat "$T/notify.out"

echo; echo "########## C：收尾停止 ##########"
: > "$T/notify.out"
bash "$T/stop.sh" 2>&1 | tail -4
echo "--- 残留 ---"; pgrep -af "fakebin serve" || echo "(已退出)"
echo "--- notify ---"; cat "$T/notify.out"

echo; echo "########## D：启动失败路径（无可用二进制 + 端口无人听） ##########"
: > "$T/notify.out"
rm -f "$T/dropbox/self-hosted/workbuddy-gateway/workbuddy-gateway"
rm -f "$T/dropbox/self-hosted/workbuddy-gateway/.installed-version"
# 让 release 下载也失败：用 PATH 里没有伪造分支的 curl
cat > "$T/bin/curl" <<'INNER'
#!/usr/bin/env bash
exec /usr/bin/curl "$@"
INNER
pkill -9 -f "fakebin serve" 2>/dev/null || true; sleep 1
bash "$T/start.sh" 2>&1 | tail -4
echo "--- notify ---"; cat "$T/notify.out"

pkill -9 -f "fakebin serve" 2>/dev/null || true
pkill -9 -f "socketserver" 2>/dev/null || true
echo; echo "########## 完成 ##########"
