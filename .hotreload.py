import json
import socket
import sys
import time
import urllib.request

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
wd = home / 'hotreload'
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
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def reload_cfg():
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}/configs?force=true', method='PUT',
                                 data=json.dumps({'path': str(af.MIHOMO_CONFIG)}).encode(),
                                 headers={'Content-Type': 'application/json'})
    with opener.open(req, timeout=15) as r:
        return r.status


def rn(i, sid=None):
    return {'name': f'node-{i:03d}', 'type': 'vless', 'server': '1.2.3.4', 'port': 443 + i,
            'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': True, 'network': 'tcp',
            'servername': 'example.com',
            'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                             'short-id': sid or '0123456789abcdef'},
            'client-fingerprint': 'chrome', 'flow': 'xtls-rprx-vision'}


def probe_hot(key, nodes):
    """改文件 → 热重载 → 读日志错误行 + 读 counts。返回 (错误行里判定的失败集, counts, 耗时)。"""
    (wd / f'trial-{key}.yaml').write_text(
        yaml.safe_dump({'proxies': list(nodes)}, allow_unicode=True, sort_keys=False),
        encoding='utf-8')
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    t0 = time.monotonic()
    reload_cfg()
    text, complete = af._read_trial_log_after_init([f'trial-{key}'],
                                                  timeout=af.TRIAL_CONCLUSION_TIMEOUT)
    counts = af._trial_provider_counts(None)
    return text, counts, complete, time.monotonic() - t0


# 用同一份 config 起一次 mihomo（2 个 provider 槽位反复复用）
af._trial_batch_config([('k0', [rn(i) for i in range(6)])], wd)
af._start_mihomo(wait_timeout=30)
af._read_trial_log_after_init(['trial-k0'])
print('冷启动完成，开始热重载循环（8 次）\n')

for r in range(8):
    n = 6
    nodes = [rn(r * 100 + i) for i in range(n)]
    bad_here = (r % 3 == 0)
    if bad_here:
        nodes[2] = rn(r * 100 + 2, 'zzzzzzzz')
    text, counts, complete, dt = probe_hot('k0', nodes)
    errs = [l for l in text.splitlines() if 'initial proxy provider' in l]
    expected = 0 if not bad_here else 1
    ok = (len(errs) == expected) and counts.get('trial-k0') == (0 if bad_here else n)
    print(f'  第{r+1}次 坏={bad_here} 错误行={len(errs)} counts={counts} complete={complete} '
          f'耗时={dt:5.2f}s  {"OK" if ok else "!! 不符"}')
