import pathlib
import socket
import sys
import time

sys.path.insert(0, '/workspace/.github/scripts/proxy-speedtest')
import alive_filter as af  # noqa: E402
import speedtest_gitee as g  # noqa: E402
import yaml  # noqa: E402

PORT = 0


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


PORT = free_port()
af.MIHOMO_API = g.MIHOMO_API = f'http://127.0.0.1:{PORT}'
home = af.MIHOMO_CONFIG.parent
wd = home / 'cost'
wd.mkdir(parents=True, exist_ok=True)

orig = af._trial_batch_config


def patched(items, workdir):
    cfg, written = orig(items, workdir)
    cfg['external-controller'] = f'127.0.0.1:{PORT}'
    cfg['port'], cfg['socks-port'], cfg['mixed-port'] = free_port(), free_port(), free_port()
    af.MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                                encoding='utf-8')
    return cfg, written


af._trial_batch_config = patched


def rn(i, sid=None):
    return {'name': f'node-{i:03d}', 'type': 'vless', 'server': '1.2.3.4', 'port': 443 + i,
            'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': True, 'network': 'tcp',
            'servername': 'example.com',
            'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                             'short-id': sid or '0123456789abcdef'},
            'client-fingerprint': 'chrome', 'flow': 'xtls-rprx-vision'}


print('成本拆解：把「冷启动」和「读 /providers/proxies」分开量（每档 3 次取中位）')
for n in (20, 100, 300, 1000):
    nodes = [rn(i) for i in range(n)]
    cfgs = [(f'k{i:03d}', [nodes[i]]) for i in range(min(8, n))]
    t_start = []
    t_log = []
    t_counts = []
    for _ in range(3):
        af._trial_batch_config([('one', nodes)], wd)
        af.MIHOMO_LOG.write_text('', encoding='utf-8')
        t0 = time.monotonic()
        af._start_mihomo(wait_timeout=30)
        t1 = time.monotonic()
        af._read_trial_log_after_init([f'{af.TRIAL_PROVIDER_PREFIX}one'])
        t2 = time.monotonic()
        c = af._trial_provider_counts(None)
        t3 = time.monotonic()
        t_start.append(t1 - t0)
        t_log.append(t2 - t1)
        t_counts.append(t3 - t2)
    med = lambda xs: sorted(xs)[1]
    print(f'  {n:5d} 个节点: 启动={med(t_start):5.2f}s  等日志={med(t_log):5.2f}s  '
          f'读counts={med(t_counts):5.2f}s  counts 拿到 {c}')
