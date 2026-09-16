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

orig = af._trial_batch_config


def patched(items, workdir):
    cfg = orig(items, workdir)[0]
    cfg['external-controller'] = f'127.0.0.1:{PORT}'
    cfg['port'], cfg['socks-port'], cfg['mixed-port'] = free_port(), free_port(), free_port()
    af.MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                                encoding='utf-8')
    return cfg, {}


af._trial_batch_config = patched


def rn(i, sid=None):
    return {'name': f'node-{i:03d}', 'type': 'vless', 'server': '1.2.3.4', 'port': 443 + i,
            'uuid': 'bf000d23-0752-40b4-affe-68f7707a9661', 'tls': True, 'network': 'tcp',
            'servername': 'example.com',
            'reality-opts': {'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
                             'short-id': sid or '0123456789abcdef'},
            'client-fingerprint': 'chrome', 'flow': 'xtls-rprx-vision'}


allok = True
print('真机 mihomo 二进制验收（前两轮都是被真机打回来的，只信真机）')

print('== 1. 全好 40 个，连跑 2 轮（验「第一次之后还判不判得出来」）==')
nodes = [rn(i) for i in range(40)]
for r in range(2):
    kept, rep = af.trial_load(nodes, workdir=home / 'lv1')
    ok = rep['removed'] == 0 and len(kept) == 40 and rep['skipped'] is False
    allok &= ok
    print(f'  第{r+1}轮 kept={len(kept)} removed={rep["removed"]} batches={rep["batches"]} '
          f'probes={rep["probes"]} elapsed={rep["elapsed_seconds"]}s  {"OK" if ok else "!!不符"}')

print('== 2. 3 个坏节点在 40 个里，连跑 3 轮（验精确命中 + 不误伤）==')
nodes = [rn(i) for i in range(40)]
for i in (7, 22, 35):
    nodes[i] = rn(i, 'zzzzzzzz')
expect = {'node-007', 'node-022', 'node-035'}
for r in range(3):
    kept, rep = af.trial_load(nodes, workdir=home / 'lv2')
    got = set(rep['removed_names'])
    ok = got == expect and len(kept) == 37
    allok &= ok
    print(f'  第{r+1}轮 kept={len(kept)} removed={rep["removed"]} {sorted(got)} '
          f'batches={rep["batches"]} probes={rep["probes"]} elapsed={rep["elapsed_seconds"]}s '
          f'{"OK" if ok else "!! 期望 " + str(sorted(expect))}')

print('== 3. 真实规模：2000 个节点、8 个坏节点（这是上一版漏剔的形态）==')
nodes = [rn(i) for i in range(2000)]
bad_idx = {11, 233, 700, 701, 1100, 1500, 1998, 1999}
for i in bad_idx:
    nodes[i] = rn(i, 'zzzzzzzz')
expect = {f'node-{i:03d}' for i in bad_idx}
t0 = time.monotonic()
kept, rep = af.trial_load(nodes, workdir=home / 'lv3')
got = set(rep['removed_names'])
ok = got == expect
allok &= ok
print(f'  kept={len(kept)} removed={rep["removed"]} batches={rep["batches"]} '
      f'bad={rep["bad_batches"]} probes={rep["probes"]} elapsed={rep["elapsed_seconds"]}s '
      f'(墙钟 {time.monotonic() - t0:.1f}s) budget_stopped={rep["budget_stopped"]}')
print(f'  多剔={sorted(got - expect)}  漏剔={sorted(expect - got)}  {"OK" if ok else "!!不符"}')

print()
print('全部真机验收通过' if allok else '存在不符预期的项')
sys.exit(0 if allok else 1)
