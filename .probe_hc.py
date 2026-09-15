"""验证：试装配置关掉健康检查后，非法 short-id 还会不会被 mihomo 报成 provider 错误。

若能，就能把每次试装从 ~11 秒降到 ~1 秒（省掉一轮全量探测），且不损失判据。
"""
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
af.MIHOMO_API = f'http://127.0.0.1:{PORT}'
g.MIHOMO_API = f'http://127.0.0.1:{PORT}'

HOME = af.MIHOMO_CONFIG.parent


def real_node(i, short_id=None):
    return {
        'name': f'node-{i:03d}', 'type': 'vless', 'server': '1.2.3.4', 'port': 443 + i,
        'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': True, 'network': 'tcp',
        'servername': 'example.com',
        'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                         'short-id': short_id or '0123456789abcdef'},
        'client-fingerprint': 'chrome', 'flow': 'xtls-rprx-vision',
    }


def build_cfg(path, health):
    cfg = {
        'port': free_port(), 'socks-port': free_port(), 'mixed-port': free_port(),
        'allow-lan': False, 'mode': 'global', 'log-level': 'info',
        'external-controller': f'127.0.0.1:{PORT}', 'secret': '',
        'proxy-groups': [{'name': 'AUTO', 'type': 'select',
                          'use': ['trial'], 'proxies': ['DIRECT']}],
        'proxy-providers': {'trial': {'type': 'file', 'path': str(path),
                                      'health-check': health}},
        'rules': ['MATCH,AUTO'],
    }
    af.MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                                encoding='utf-8')
    return cfg


def install(nodes, health, label):
    wd = HOME / f'probe-{label}'
    wd.mkdir(parents=True, exist_ok=True)
    path = wd / 'trial.yaml'
    path.write_text(yaml.safe_dump({'proxies': nodes}, allow_unicode=True,
                                   sort_keys=False), encoding='utf-8')
    build_cfg(path, health)
    try:
        af.MIHOMO_LOG.write_text('', encoding='utf-8')
    except Exception:
        pass
    t0 = time.monotonic()
    af._start_mihomo(wait_timeout=30)
    dt = time.monotonic() - t0
    text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
    err = ''
    for line in text.splitlines():
        if 'initial proxy provider' in line or 'error: proxy' in line:
            err = line.strip()
            break
    return dt, err


HC_ON = {'enable': True, 'url': 'https://www.gstatic.com/generate_204',
         'interval': 86400, 'timeout': 5000, 'lazy': False, 'expected-status': 204}
HC_OFF = {'enable': False}

nodes_bad = [real_node(i) for i in range(6)]
nodes_bad[3] = real_node(3, short_id='zzzzzzzz')
nodes_good = [real_node(i) for i in range(6)]

print('=== A. 健康检查 ON（当前实现）===')
t, e = install(nodes_bad, HC_ON, 'on-bad')
print(f'  坏节点: {t:.1f}s  err={"有" if e else "无"}')
print(f'    {e[:110]}')
t2, e2 = install(nodes_good, HC_ON, 'on-good')
print(f'  好节点: {t2:.1f}s  err={"有" if e2 else "无"}')

print('\n=== B. 健康检查 OFF（候选优化）===')
t3, e3 = install(nodes_bad, HC_OFF, 'off-bad')
print(f'  坏节点: {t3:.1f}s  err={"有" if e3 else "无"}')
print(f'    {e3[:110]}')
t4, e4 = install(nodes_good, HC_OFF, 'off-good')
print(f'  好节点: {t4:.1f}s  err={"有" if e4 else "无"}')

print('\n=== 结论 ===')
ok = bool(e3) and not e4
print(f'  关掉健康检查后判据仍成立（坏的报错、好的不报）: {ok}')
if ok:
    print(f'  单次试装提速: {t2:.1f}s -> {t4:.1f}s')
