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
wd = home / 'probepath'
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


print('直接验 _trial_probe 的真实路径（第 1 发冷启动，之后 hot=True）')
allok = True
for r in range(9):
    n = 6
    nodes = [rn(r * 100 + i) for i in range(n)]
    bad_here = (r % 3 == 0)
    if bad_here:
        nodes[2] = rn(r * 100 + 2, 'zzzzzzzz')
    t0 = time.monotonic()
    failed, trusted, err, starts = af._trial_probe([('k0', nodes)], wd, hot=(r > 0))
    dt = time.monotonic() - t0
    ok = (failed == {'k0'}) if bad_here else (failed == set())
    allok &= ok and trusted
    print(f'  第{r+1}次 hot={r > 0} 坏={bad_here} failed={failed if len(failed) < 3 else "{...}"} '
          f'trusted={trusted} starts={starts} 耗时={dt:5.2f}s {"OK" if ok and trusted else "!!不符"}')
    if not ok:
        print(f'      err={err[:120]!r}')

print()
print('全部通过' if allok else '存在不符预期的项')
