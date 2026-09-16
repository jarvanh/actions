import pathlib
import socket
import sys

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
wd = home / 'threshold'
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


def probe(nodes):
    af._trial_batch_config([('one', nodes)], wd)
    raw = (wd / 'trial-one.yaml').stat().st_size
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    try:
        af._start_mihomo(wait_timeout=30)
    except Exception as e:
        return raw, 'start-fail', 0, str(e)
    text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
    errs = [l for l in text.splitlines() if 'initial proxy provider' in l]
    try:
        import urllib.request
        with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/providers/proxies', timeout=10) as r:
            data = yaml.safe_load(r.read().decode('utf-8', 'ignore')) or {}
        loaded = len(((data.get('providers') or {}).get('trial-one') or {}).get('proxies') or [])
    except Exception as e:
        loaded = f'?{e}'
    return raw, loaded, len(errs), (errs[0][:110] if errs else '')


print('=== A. 二分找体积阈值（坏节点固定在中间）===')
lo, hi = 47, 150
while lo + 1 < hi:
    mid = (lo + hi) // 2
    nodes = [rn(i) for i in range(mid)]
    nodes[mid // 2] = rn(mid // 2, 'zzzzzzzz')
    raw, loaded, nerr, msg = probe(nodes)
    mark = 'OK报错' if nerr else ('静默0' if loaded == 0 else f'装到{loaded}')
    print(f'  n={mid:4d} file={raw/1024:7.1f}KB  {mark}')
    if nerr:
        lo = mid
    else:
        hi = mid
print(f'  => 能正常报错的最大 n={lo}，开始静默的 n={hi}')

print()
print('=== B. 是「行数」还是「字节数」？把节点名撑长，行数不变、字节翻倍 ===')
for name_len in (10, 200, 600, 2000):
    n = 60
    nodes = [rn(i) for i in range(n)]
    for p in nodes:
        p['name'] = p['name'].ljust(name_len, 'x')
    nodes[30] = dict(nodes[30], **{'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0', 'short-id': 'zzzzzzzz'}})
    raw, loaded, nerr, msg = probe(nodes)
    print(f'  60 行 × 名长 {name_len:5d} => file={raw/1024:8.1f}KB  装到={loaded} 错误行={nerr}')
