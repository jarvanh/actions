import pathlib
import socket
import sys
import time

sys.path.insert(0, '/workspace/.github/scripts/proxy-speedtest')
import alive_filter as af  # noqa: E402
import speedtest_gitee as g  # noqa: E402
import yaml  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()
af.MIHOMO_API = g.MIHOMO_API = f'http://127.0.0.1:{PORT}'
home = af.MIHOMO_CONFIG.parent
wd = home / 'multiprobe'
wd.mkdir(parents=True, exist_ok=True)

orig = af._trial_batch_config


def patched(items, workdir):
    cfg = orig(items, workdir)
    cfg['external-controller'] = f'127.0.0.1:{PORT}'
    cfg['port'], cfg['socks-port'], cfg['mixed-port'] = free_port(), free_port(), free_port()
    af.MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                                encoding='utf-8')
    return cfg


af._trial_batch_config = patched


def rn(i, sid=None):
    return {'name': f'node-{i:03d}', 'type': 'vless', 'server': '1.2.3.4', 'port': 443 + i,
            'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': True, 'network': 'tcp',
            'servername': 'example.com',
            'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                             'short-id': sid or '0123456789abcdef'},
            'client-fingerprint': 'chrome', 'flow': 'xtls-rprx-vision'}


# 一份 config 放 3 个 provider：一个全好、一个在第 3 位有坏节点、一个全好
good_a = [rn(i) for i in range(5)]
bad_b = [rn(100 + i) for i in range(5)]
bad_b[3] = rn(103, 'zzzzzzzz')
good_c = [rn(200 + i) for i in range(5)]

items = [('aaa', good_a), ('bbb', bad_b), ('ccc', good_c)]
af._trial_batch_config(items, wd)
af.MIHOMO_LOG.write_text('', encoding='utf-8')
af._start_mihomo(wait_timeout=30)
time.sleep(0.4)
text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
print('===== mihomo 日志全文 =====')
for line in text.splitlines():
    if 'provider' in line or 'error' in line or 'fatal' in line or 'level=warning' in line:
        print(' ', line[:190])

print()
print('===== /providers/proxies 里各 provider 实际装到几个 =====')
import urllib.request
with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/providers/proxies', timeout=10) as r:
    data = yaml.safe_load(r.read().decode('utf-8', 'ignore')) or {}
for name, info in (data.get('providers') or {}).items():
    if name.startswith('trial-'):
        px = (info or {}).get('proxies') or []
        print(f'  {name}: {len(px)} 个 -> {[p.get("name") for p in px]}')
    elif name in ('default', 'AUTO'):
        px = (info or {}).get('proxies') or []
        print(f'  [{name}]: {len(px)} 个')
