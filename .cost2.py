import socket
import subprocess
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
wd = home / 'cost2'
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


def rn(i):
    return {'name': f'n{i}', 'type': 'ss', 'server': '1.1.1.1', 'port': 443,
            'cipher': 'aes-128-gcm', 'password': 'p'}


# 给 _start_mihomo 内部分段计时：靠包装 ensure / pgrep / kill / 等端口 / wait_mihomo
t_ensure = t_scan = t_waitport = t_waitm = 0.0

orig_ensure = af.ensure_local_mihomo
orig_wait = af.wait_mihomo
orig_kill = af.os.kill if hasattr(af, 'os') else None


def timed_ensure():
    global t_ensure
    t0 = time.monotonic()
    r = orig_ensure()
    t_ensure += time.monotonic() - t0
    return r


def timed_wait(timeout=60):
    global t_waitm
    t0 = time.monotonic()
    r = orig_wait(timeout=timeout)
    t_waitm += time.monotonic() - t0
    return r


af.ensure_local_mihomo = timed_ensure
af.wait_mihomo = timed_wait

saved_run = subprocess.run
saved_popen = subprocess.Popen


def timed_run(*a, **k):
    global t_scan
    t0 = time.monotonic()
    r = saved_run(*a, **k)
    t_scan += time.monotonic() - t0
    return r


def timed_popen(*a, **k):
    global t_scan
    t0 = time.monotonic()
    r = saved_popen(*a, **k)
    t_scan += time.monotonic() - t0
    return r


subprocess.run = timed_run
subprocess.Popen = timed_popen

nodes = [rn(i) for i in range(40)]
for r in range(4):
    t_ensure = t_scan = t_waitport = t_waitm = 0.0
    t0 = time.monotonic()
    af._trial_batch_config([('one', nodes)], wd)
    af.MIHOMO_LOG.write_text('', encoding='utf-8')
    t_a = time.monotonic()
    af._start_mihomo(wait_timeout=30)
    total = time.monotonic() - t0
    print(f'第{r+1}轮 总={total:5.2f}s | ensure={t_ensure:5.2f} pgrep/popen={t_scan:5.2f} '
          f'wait_mihomo={t_waitm:5.2f} | 未解释={total - t_ensure - t_scan - t_waitm:5.2f}s')
