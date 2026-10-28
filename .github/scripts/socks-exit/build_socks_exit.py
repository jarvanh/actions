#!/usr/bin/env python3
# ===== 共享脚本：qzz.io 免费订阅 → edgetunnel SOCKS5 出口节点 =====
# 为什么要有它（2026-10-28 实测结论）：
#   - 免费 SOCKS5 源节点寿命按小时计（实测 1 小时后 27 节点只剩 2 个，socks5 段 0/4 存续），
#     手钉进 KV 必死；但 edgetunnel 支持 path 级出口（/socks5://host:port 为全局形），
#     所以改成「每次重新测活 + 重新生成节点」，客户端每次拉订阅拿到的都是当下可用的。
#   - 只收 socks5：同日实测 http/https 段存活 1/7，且唯一存活者（HK IPv6）被 Google 判 US，
#     没有定区价值；vmess/vless/anytls 是入口协议，Worker 不吃，故一并排除。
#   - 只留取得到 GL 的节点：定区是这条管道的唯一目的，GL 取不到的节点等于没用。
#   - 全失败时不产出文件、由 workflow 保留上一版 Gist：避免客户端订阅瞬间清零。
#
# 用法：python3 build_socks_exit.py --out out
# 环境变量：EDGETUNNEL_HOST / EDGETUNNEL_UUID（必需，缺失即报错退出）
# 可选：SOCKS_SOURCE_URL（默认 qzz 源）、MAX_NODES（默认 15）、PROBE_WORKERS（默认 8）
import argparse
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

import yaml

UA_SUB = 'clash-verge/1.6.6'
UA_BROWSER = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36')
CF_TRACE = 'https://www.cloudflare.com/cdn-cgi/trace'
YT_HOME = 'https://www.youtube.com/'
DEFAULT_SOURCE = 'https://234.qzz.io/fsllistyaml'


def log(msg):
    print(msg, flush=True)


def curl(args, timeout):
    """跑 curl，失败一律当空串：测活阶段任何异常都等价于「这个节点不可用」。"""
    try:
        res = subprocess.run(['curl'] + args, capture_output=True, text=True, timeout=timeout)
        return res.stdout or ''
    except Exception:
        return ''


def fetch_subscription(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA_SUB})
    with urllib.request.urlopen(req, timeout=40) as resp:
        return resp.read().decode('utf-8', 'ignore')


def socks5_candidates(text):
    data = yaml.safe_load(text) or {}
    out = []
    for p in data.get('proxies') or []:
        if p.get('type') != 'socks5' or not p.get('server') or not p.get('port'):
            continue
        out.append(p)
    return out


def socks_addr(node):
    """返回 (host:port, 是否带认证)；认证信息按 URL 编码，避免 @ : / 破坏 path 结构。"""
    host, port = node['server'], node['port']
    user, pwd = node.get('username'), node.get('password')
    if user and pwd:
        cred = f"{urllib.parse.quote(str(user), safe='')}:{urllib.parse.quote(str(pwd), safe='')}@"
    else:
        cred = ''
    return f'{cred}{host}:{port}', bool(cred)


def probe(node):
    """存活 + 出口 + 判区一次跑完；YT 判区只对已存活的节点做，省时间。"""
    addr, has_auth = socks_addr(node)
    trace = curl(['-s', '-m', '10', '--socks5-hostname', addr,
                  '-w', '|%{time_total}|%{http_code}', CF_TRACE], 16)
    body, _, tail = trace.rpartition('|')
    code = tail
    body, _, t_total = body.rpartition('|')
    if code != '200':
        return None
    kv = dict(line.split('=', 1) for line in body.splitlines() if '=' in line)
    exit_ip = kv.get('ip')
    if not exit_ip:
        return None
    html = curl(['-s', '-m', '20', '--socks5-hostname', addr, '--compressed',
                 '-A', UA_BROWSER, YT_HOME], 26)
    m = re.search(r'"GL":"([A-Z]{2})"', html or '')
    if not m:
        return None          # 判区拿不到 = 对定区无价值，直接丢弃
    try:
        latency = float(t_total)
    except ValueError:
        latency = 99.0
    return {
        'name': node.get('name', ''),
        'addr': addr,
        'auth': has_auth,
        'gl': m.group(1),
        'ip': exit_ip,
        'colo': kv.get('colo', ''),
        'loc': kv.get('loc', ''),
        'latency': latency,
    }


def build_node(live, entry_host, entry_uuid):
    """按 edgetunnel 的 path 出口语法生成节点：/socks5://host:port 即全局 SOCKS5。

    udp 置 false：_worker.js 的 socks5Connect 只做 TCP 转发，UDP 包过不去；
    标 true 会让客户端先尝试 QUIC、超时后才回退 TCP，首屏反而变慢。
    """
    label = f"socks-exit|{live['gl']}|{live['latency']:.2f}s"
    return {
        'name': label,
        'type': 'vless',
        'server': entry_host,
        'port': 443,
        'uuid': entry_uuid,
        'network': 'ws',
        'tls': True,
        'servername': entry_host,
        'udp': False,
        'encryption': 'none',
        'client-fingerprint': 'chrome',
        'skip-cert-verify': False,
        'ws-opts': {
            'path': f"/socks5://{live['addr']}",
            'headers': {
                'Host': entry_host,
                'User-Agent': UA_BROWSER,
            },
        },
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='out', help='输出目录')
    args = ap.parse_args()

    entry_host = (os.environ.get('EDGETUNNEL_HOST') or '').strip()
    entry_uuid = (os.environ.get('EDGETUNNEL_UUID') or '').strip()
    if not entry_host or not entry_uuid:
        log('::error::缺少 EDGETUNNEL_HOST / EDGETUNNEL_UUID')
        return 2

    source = (os.environ.get('SOCKS_SOURCE_URL') or DEFAULT_SOURCE).strip()
    max_nodes = int(os.environ.get('MAX_NODES') or 15)
    workers = int(os.environ.get('PROBE_WORKERS') or 8)

    log(f'抓取订阅源：{source}')
    try:
        text = fetch_subscription(source)
    except Exception as e:
        log(f'::warning::订阅抓取失败（保留上一版 Gist）：{e}')
        return 0

    cands = socks5_candidates(text)
    log(f'订阅内 socks5 候选：{len(cands)} 个（其余协议按 2026-10-28 实测结论排除）')
    if not cands:
        log('::warning::本轮没有 socks5 候选，保留上一版 Gist')
        return 0

    log(f'开始测活（{min(workers, len(cands))} 并发，逐个验证 CF trace + YouTube 判区）')
    live = []
    with ThreadPoolExecutor(max_workers=min(workers, len(cands))) as ex:
        for node, res in zip(cands, ex.map(probe, cands)):
            tag = f"{node.get('name', '?')[:30]:<30} {node['server']}:{node['port']}"
            if res:
                live.append(res)
                log(f"  ✅ {tag} → {res['ip']} {res['colo']}/{res['loc']} GL={res['gl']} {res['latency']:.2f}s")
            else:
                log(f'  ❌ {tag}')

    # 同一出口 IP 只留最快的一个：源站常把同一台机器拆成多条，重复节点对客户端无意义
    live.sort(key=lambda x: x['latency'])
    seen, picked = set(), []
    for item in live:
        if item['ip'] in seen:
            continue
        seen.add(item['ip'])
        picked.append(item)
        if len(picked) >= max_nodes:
            break

    log(f'存活 {len(live)} 个，去重后取 {len(picked)} 个（上限 {max_nodes}）')
    if not picked:
        log('::warning::本轮无可用节点，保留上一版 Gist')
        return 0

    nodes = [build_node(x, entry_host, entry_uuid) for x in picked]
    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, 'socks-exit.yaml')
    with open(out_path, 'w', encoding='utf-8') as f:
        yaml.safe_dump({'proxies': nodes}, f, allow_unicode=True, sort_keys=False)
    log(f'已写出 {out_path}（{len(nodes)} 节点）')

    dist = {}
    for x in picked:
        dist[x['gl']] = dist.get(x['gl'], 0) + 1
    log(f'判区分布：{dist}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
