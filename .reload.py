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
wd = home / 'reload'
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


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(path):
    with opener.open(f'http://127.0.0.1:{PORT}{path}', timeout=10) as r:
        return r.read().decode('utf-8', 'ignore')


def put(path):
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}{path}', method='PUT')
    with opener.open(req, timeout=10) as r:
        return r.status


good = [rn(i) for i in range(6)]
bad = [rn(100 + i) for i in range(6)]
bad[2] = rn(102, 'zzzzzzzz')

af._trial_batch_config([('one', good)], wd)
af.MIHOMO_LOG.write_text('', encoding='utf-8')
af._start_mihomo(wait_timeout=30)
af._read_trial_log_after_init(['trial-one'])
print('初始（全好）:', af._trial_provider_counts(None))

# 直接把坏数据覆盖到同一个 provider 文件，然后探 reload 接口
p = wd / 'trial-one.yaml'
p.write_text(yaml.safe_dump({'proxies': bad}, allow_unicode=True, sort_keys=False),
             encoding='utf-8')
t0 = time.monotonic()
try:
    st = put('/providers/proxies/trial-one')
    print(f'PUT /providers/proxies/trial-one -> {st}  耗时 {time.monotonic() - t0:.3f}s')
except Exception as e:
    print(f'PUT 失败: {e}')
    # 试其它形态
    for path in ('/providers/proxies/trial-one/healthcheck', '/providers/proxies'):
        try:
            st = put(path)
            print(f'  PUT {path} -> {st}')
        except Exception as e2:
            print(f'  PUT {path} 失败: {e2}')
time.sleep(0.3)
print('reload 后:', af._trial_provider_counts(None))
text = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
errs = [l for l in text.splitlines() if 'initial proxy provider' in l]
print('错误行:', len(errs), errs[0][:120] if errs else '')
print('API 形态:', json.dumps(list((yaml.safe_load(get('/providers/proxies')) or
                                   {}).get('providers', {}).keys()), ensure_ascii=False))

print()
print('=== PUT 失败后日志全文 ===')
text2 = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
for line in text2.splitlines()[-12:]:
    print(' ', line[:180])
print()
print('=== 探 reload 的其它形态 ===')
for path, method in (('/providers/proxies/trial-one', 'PUT'),
                     ('/providers/proxies/trial-one', 'GET'),
                     ('/configs?force=true', 'PUT')):
    try:
        req = urllib.request.Request(f'http://127.0.0.1:{PORT}{path}', method=method)
        if method == 'PUT' and 'configs' in path:
            req.data = json.dumps({'path': str(af.MIHOMO_CONFIG)}).encode()
            req.add_header('Content-Type', 'application/json')
        with opener.open(req, timeout=10) as r:
            print(f'  {method} {path} -> {r.status}')
    except Exception as e:
        print(f'  {method} {path} -> {e}')
time.sleep(0.4)
print('configs reload 后:', af._trial_provider_counts(None))
text3 = af.MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
errs3 = [l for l in text3.splitlines() if 'initial proxy provider' in l]
print('错误行:', len(errs3), errs3[0][:130] if errs3 else '')
