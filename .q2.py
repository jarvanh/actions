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
wd = home / 'q2'
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


print('=== 多 provider 同处一份 config 时，体积阈值是按「单个 provider」还是「总量」？===')
print('每个 provider 放 20 个节点（约 6.6KB，单看远在阈值内），全好，只数收尾的 provider 数')
for count in (1, 2, 3, 4, 6, 8):
    items = []
    for k in range(count):
        items.append((f'p{k:02d}', [rn(1000 * k + i) for i in range(20)]))
    af._trial_batch_config(items, wd)
    total_bytes = sum((wd / f'trial-p{k:02d}.yaml').stat().st_size for k in range(count))
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    try:
        af._start_mihomo(wait_timeout=30)
    except Exception as e:
        print(f'  {count:2d} 个 provider 总 {total_bytes/1024:7.1f}KB  启动失败 {e}')
        continue
    import urllib.request
    with urllib.request.urlopen(f'http://127.0.0.1:{PORT}/providers/proxies', timeout=10) as r:
        data = yaml.safe_load(r.read().decode('utf-8', 'ignore')) or {}
    got = {}
    for name, info in (data.get('providers') or {}).items():
        if name.startswith('trial-'):
            got[name] = len((info or {}).get('proxies') or [])
    empty = [n for n, c in got.items() if c == 0]
    print(f'  {count:2d} 个 provider 总 {total_bytes/1024:7.1f}KB  '
          f'装到的 provider 数={len(got)}  空的={len(empty)} {sorted(empty)}')

print()
print('=== 反证：单个 provider 只放 20 个（6.6KB）时，坏节点能否报出来 ===')
for count in (1, 2, 3):
    items = []
    for k in range(count):
        chunk = [rn(1000 * k + i) for i in range(20)]
        if k == 0:
            chunk[5] = rn(5, 'zzzzzzzz')
        items.append((f'p{k:02d}', chunk))
    af._trial_batch_config(items, wd)
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    af._start_mihomo(wait_timeout=30)
    text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
    errs = [l for l in text.splitlines() if 'initial proxy provider' in l]
    print(f'  {count} 个 provider（共 {count * 20} 个节点）: 错误行={len(errs)} '
          f'{[e.split("provider ")[1][:14] for e in errs]}')
