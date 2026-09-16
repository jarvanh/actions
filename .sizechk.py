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
wd = home / 'sizechk'
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


for size in (2000, 1200, 800, 500, 300, 150, 47):
    nodes = [rn(i) for i in range(size)]
    nodes[size // 2] = rn(size // 2, 'zzzzzzzz')
    af._trial_batch_config([('one', nodes)], wd)
    p = wd / 'trial-one.yaml'
    raw = p.stat().st_size
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    try:
        af._start_mihomo(wait_timeout=30)
    except Exception as e:
        print(f'{size:5d} 个 文件={raw/1024:8.1f}KB  启动失败 {e}')
        continue
    text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
    errs = [l for l in text.splitlines() if 'initial proxy provider' in l]
    fatal = [l for l in text.splitlines() if 'level=fatal' in l]
    loaded = -1
    try:
        import urllib.request
        with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/providers/proxies', timeout=10) as r:
            data = yaml.safe_load(r.read().decode('utf-8', 'ignore')) or {}
        loaded = len(((data.get('providers') or {}).get('trial-one') or {}).get('proxies') or [])
    except Exception as e:
        loaded = f'查询失败 {e}'
    print(f'{size:5d} 个 文件={raw/1024:8.1f}KB  装到={loaded}  错误行={len(errs)}  fatal={len(fatal)}')
    if fatal:
        print(f'        {fatal[0][:170]}')
    if errs:
        print(f'        {errs[0][:170]}')
