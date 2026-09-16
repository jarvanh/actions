import socket
import subprocess
import sys
import time

sys.path.insert(0, '/workspace/.github/scripts/proxy-speedtest')
import alive_filter as af  # noqa: E402
import yaml  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


home = af.MIHOMO_CONFIG.parent
wd = home / 'cost3'
wd.mkdir(parents=True, exist_ok=True)

cfgs = []
orig = af._trial_batch_config


def patched(items, workdir):
    cfg, written = orig(items, workdir)
    # 每轮换新端口：验「不等旧进程、直接换端口」能不能起来
    p = free_port()
    cfg['external-controller'] = f'127.0.0.1:{p}'
    cfg['port'], cfg['socks-port'], cfg['mixed-port'] = free_port(), free_port(), free_port()
    af.MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                                encoding='utf-8')
    cfgs.append(p)
    af.MIHOMO_API = f'http://127.0.0.1:{p}'
    return cfg, written


af._trial_batch_config = patched


def rn(i):
    return {'name': f'n{i}', 'type': 'ss', 'server': '1.1.1.1', 'port': 443,
            'cipher': 'aes-128-gcm', 'password': 'p'}


nodes = [rn(i) for i in range(40)]

# 关键：把「等端口」那段跳过，看新端口能不能直接起来
orig_start = af._start_mihomo
import os
import signal


def start_no_wait_port(wait_timeout=60):
    af.ensure_local_mihomo()
    try:
        out = subprocess.run(['pgrep', '-af', f'{af.MIHOMO} -d'], text=True,
                             capture_output=True, timeout=10)
        for raw in (out.stdout or '').splitlines():
            line = raw.strip()
            if not line:
                continue
            try:
                pid = int(line.split(None, 1)[0])
            except ValueError:
                continue
            if pid == os.getpid():
                continue
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
    except Exception:
        pass
    # 完全不等端口
    with af.MIHOMO_LOG.open('a', encoding='utf-8') as lf:
        subprocess.Popen([str(af.MIHOMO), '-d', str(af.MIHOMO_CONFIG.parent),
                          '-f', str(af.MIHOMO_CONFIG)],
                         stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    return af.wait_mihomo(timeout=wait_timeout)


af._start_mihomo = start_no_wait_port

for r in range(4):
    t0 = time.monotonic()
    af._trial_batch_config([('one', nodes)], wd)
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    try:
        af._start_mihomo(wait_timeout=30)
        ok = 'OK'
    except Exception as e:
        ok = f'失败 {e}'
    print(f'  第{r+1}轮 新端口={cfgs[-1]} 耗时={time.monotonic() - t0:5.2f}s  {ok}')
