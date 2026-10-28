#!/usr/bin/env python3
# ===== 共享脚本：qzz.io 免费订阅 → 「原节点全保留 + SOCKS5/HTTP 出口节点」 =====
# 为什么这么设计（2026-10-28 主人两次反馈）：
#   1. 「这样只剩 2 个节点了」——只收 socks5 时池子太小（源里 socks5 段常只有 2-4 个），
#      所以 http/https 段也纳入验证：机制上 /https:// 与 /http:// 同样是 edgetunnel 的全局出口形。
#   2. 「把原节点名包含的信息都去掉了」——源节点名自带地区/城市/节点 ID（如
#      HK-Hong Kong-23812620-stmd），这些信息必须保留；出口节点在原名后追加 YT 地区与延迟。
#   3. 原订阅节点一律原样保留：它们是可直连的第三方代理，不能承载 path 级出口切换
#      （那不是 Worker 入口），但本身有使用价值，且删掉就等于丢掉源的全部信息。
#
# 用法：python3 build_socks_exit.py --out out
# 环境变量：EDGETUNNEL_HOST / EDGETUNNEL_UUID（必需）
# 可选：SOCKS_SOURCE_URL、MAX_EXITS（默认 20）、PROBE_WORKERS（默认 8）
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
EXIT_TYPES = ('socks5', 'http', 'https')


def log(msg):
    print(msg, flush=True)


def curl(args, timeout):
    """跑 curl，异常一律当空串：测活阶段任何失败都等价于「这个节点不可用」。"""
    try:
        res = subprocess.run(['curl'] + args, capture_output=True, text=True, timeout=timeout)
        return res.stdout or ''
    except Exception:
        return ''


def fetch_subscription(url):
    req = urllib.request.Request(url, headers={'User-Agent': UA_SUB})
    with urllib.request.urlopen(req, timeout=40) as resp:
        return resp.read().decode('utf-8', 'ignore')


def exit_candidates(proxies):
    return [p for p in proxies if p.get('type') in EXIT_TYPES and p.get('server') and p.get('port')]


def socks_addr(node):
    """返回带认证的 host:port；认证信息做 URL 编码，避免 @ : / 破坏 path 结构。"""
    user, pwd = node.get('username'), node.get('password')
    if user and pwd:
        cred = f"{urllib.parse.quote(str(user), safe='')}:{urllib.parse.quote(str(pwd), safe='')}@"
    else:
        cred = ''
    return f"{cred}{node['server']}:{node['port']}", bool(cred)


def probe(node):
    """按协议选 curl 代理形态逐个试，存活后取 YouTube 判区；判区拿不到即丢弃。"""
    addr, has_auth = socks_addr(node)
    typ = node.get('type')
    if typ == 'socks5':
        schemes = ['socks5']
    elif node.get('tls'):
        schemes = ['https', 'http']      # 源里 http 节点多为 tls=true 的 HTTPS 代理
    else:
        schemes = ['http', 'https']

    for scheme in schemes:
        if scheme == 'socks5':
            px = ['--socks5-hostname', addr]
        else:
            px = ['-x', f'{scheme}://{addr}']
        trace = curl(['-s', '-m', '10'] + px + ['-w', '|%{time_total}|%{http_code}', CF_TRACE], 16)
        body, _, tail = trace.rpartition('|')
        code = tail
        body, _, t_total = body.rpartition('|')
        if code != '200':
            continue
        kv = dict(line.split('=', 1) for line in body.splitlines() if '=' in line)
        exit_ip = kv.get('ip')
        if not exit_ip:
            continue
        html = curl(['-s', '-m', '20'] + px + ['--compressed', '-A', UA_BROWSER, YT_HOME], 26)
        m = re.search(r'"GL":"([A-Z]{2})"', html or '')
        if not m:
            return None                  # 定区拿不到 = 对这条管道无价值
        try:
            latency = float(t_total)
        except ValueError:
            latency = 99.0
        return {
            'name': node.get('name', ''),
            'addr': addr,
            'scheme': scheme,
            'auth': has_auth,
            'gl': m.group(1),
            'ip': exit_ip,
            'colo': kv.get('colo', ''),
            'loc': kv.get('loc', ''),
            'latency': latency,
        }
    return None


def build_exit_node(live, entry_host, entry_uuid):
    """出口节点：path 用全局形（/socks5://、/https://、/http://），名字保留原节点名 + YT 地区。

    udp 置 false：_worker.js 的 socks5Connect/httpConnect 只做 TCP 转发，
    标 true 会让客户端先试 QUIC、超时才回退 TCP，首屏更慢。
    """
    return {
        'name': f"{live['name']}|YT-{live['gl']}|{live['latency']:.2f}s",
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
            'path': f"/{live['scheme']}://{live['addr']}",
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
    max_exits = int(os.environ.get('MAX_EXITS') or 20)
    workers = int(os.environ.get('PROBE_WORKERS') or 8)

    log(f'抓取订阅源：{source}')
    try:
        text = fetch_subscription(source)
        data = yaml.safe_load(text) or {}
    except Exception as e:
        log(f'::warning::订阅抓取失败（保留上一版 Gist）：{e}')
        return 0

    proxies = data.get('proxies') or []
    if not proxies:
        log('::warning::源里没有节点（保留上一版 Gist）')
        return 0

    cands = exit_candidates(proxies)
    log(f'源节点 {len(proxies)} 个（全部原样保留）；可作出口的 socks5/http/https：{len(cands)} 个')

    live = []
    if cands:
        with ThreadPoolExecutor(max_workers=min(workers, len(cands))) as ex:
            for node, res in zip(cands, ex.map(probe, cands)):
                tag = f"{node.get('name', '?')[:34]:<34} {node['type']:<6}{node['server']}:{node['port']}"
                if res:
                    live.append(res)
                    log(f"  ✅ {tag} → {res['ip']} {res['colo']}/{res['loc']} GL={res['gl']} {res['latency']:.2f}s")
                else:
                    log(f'  ❌ {tag}')

    # 按代理地址去重（scheme+addr 相同才算同一条）：主人要求「所有验证后的出口」都在列，
    # 不同源节点即使出口 IP 相同也各自保留——名字、path 不同，客户端可自行取舍
    live.sort(key=lambda x: x['latency'])
    seen, picked = set(), []
    for item in live:
        key = (item['scheme'], item['addr'])
        if key in seen:
            continue
        seen.add(key)
        picked.append(item)
        if len(picked) >= max_exits:
            break

    out_nodes = list(proxies)                    # ① 原订阅节点全量原样保留（名字信息不丢）
    used = {p.get('name') for p in out_nodes}    # ② 每个验证出口一条，名字继承源节点；撞名加序号
    for x in picked:
        node = build_exit_node(x, entry_host, entry_uuid)
        base, n = node['name'], 1
        while node['name'] in used:
            n += 1
            node['name'] = f'{base}|{n}'
        used.add(node['name'])
        out_nodes.append(node)

    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, 'socks-exit.yaml')
    with open(out_path, 'w', encoding='utf-8') as f:
        yaml.safe_dump({'proxies': out_nodes}, f, allow_unicode=True, sort_keys=False)

    dist = {}
    for x in picked:
        dist[x['gl']] = dist.get(x['gl'], 0) + 1
    log(f'存活出口 {len(live)} 个，按地址去重后 {len(picked)} 个；判区分布 {dist}')
    log(f'已写出 {out_path}：原节点 {len(proxies)} + 出口节点 {len(picked)} = {len(out_nodes)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
