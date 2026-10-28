#!/usr/bin/env python3
# ===== 共享脚本：subs-check 节点 × 免费源 SOCKS5 出口 → 组合订阅 =====
# v3（2026-10-28 主人第三次反馈定稿）：
#   - 基座节点 = subs-check 的 all.yaml（原样保留：名字含测速/IP风险/流媒体解锁标签，入口为 edgetunnel 优选IP）
#   - 组合节点 = 每个基座节点 × 每个验证通过的 SOCKS5 出口：
#       入口沿用该基座节点（优选IP/端口/TLS/Host 头全部不动），仅 ws path 换成 /socks5://<出口>
#       名字 = 基座名 + |YT-<实测判区>|<延迟>s（与 subs-check 自身 YT- 标签同语义：经此节点 YouTube 判到的地区）
#   - 出口只收 socks5（http/https 实测存活 1/7 且判区不可控，主人明确剔除）
#   - 全失败（无可用出口）时不产出文件 → workflow 保留上一版 Gist，避免客户端订阅清零
#
# 用法：python3 build_socks_exit.py --out out
# 环境变量：SUBS_CHECK_GIST_ID（subs-check 产物 gist，必需）、SOCKS_EXIT 来源可选：
#   SOCKS_SOURCE_URL（默认 qzz 源）、MAX_EXITS（默认 20）、PROBE_WORKERS（默认 8）
import argparse
import copy
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
    """跑 curl，异常一律当空串：测活阶段任何失败都等价于「这个出口不可用」。"""
    try:
        res = subprocess.run(['curl'] + args, capture_output=True, text=True, timeout=timeout)
        return res.stdout or ''
    except Exception:
        return ''


def fetch_text(url, timeout=40):
    req = urllib.request.Request(url, headers={'User-Agent': UA_SUB})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', 'ignore')


def socks_addr(node):
    """返回带认证的 host:port；认证信息做 URL 编码（Worker 侧获取SOCKS5账号 会 decodeURIComponent）。"""
    user, pwd = node.get('username'), node.get('password')
    if user and pwd:
        cred = f"{urllib.parse.quote(str(user), safe='')}:{urllib.parse.quote(str(pwd), safe='')}@"
    else:
        cred = ''
    return f"{cred}{node['server']}:{node['port']}", bool(cred)


def probe(node):
    """SOCKS5 出口测活：CF trace 拿出口 IP → YouTube 首页拿实测判区；任一环节失败即弃。"""
    addr, _ = socks_addr(node)
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
        return None                  # 判区拿不到 = 对定区管道无价值
    try:
        latency = float(t_total)
    except ValueError:
        latency = 99.0
    return {
        'name': node.get('name', ''),
        'addr': addr,
        'gl': m.group(1),
        'ip': exit_ip,
        'colo': kv.get('colo', ''),
        'loc': kv.get('loc', ''),
        'latency': latency,
    }


def build_exit_node(base, live):
    """组合节点：完整继承基座节点（入口 优选IP/端口/TLS/Host 头不变），仅换 path 出口。

    udp 置 false：_worker.js 的 socks5Connect 只做 TCP 转发，标 true 会诱使客户端
    先试 QUIC、超时才回退 TCP，首屏反而变慢。
    """
    node = copy.deepcopy(base)
    node['udp'] = False
    ws = dict(node.get('ws-opts') or {})
    ws['path'] = f"/socks5://{live['addr']}"
    node['ws-opts'] = ws
    return node


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='out', help='输出目录')
    args = ap.parse_args()

    subs_gist = (os.environ.get('SUBS_CHECK_GIST_ID') or '').strip()
    if not subs_gist:
        log('::error::缺少 SUBS_CHECK_GIST_ID（subs-check 产物 gist）')
        return 2

    # ---- 1) 基座：subs-check all.yaml ----
    subs_url = f'https://gist.githubusercontent.com/jarvanh/{subs_gist}/raw/all.yaml'
    try:
        base_proxies = (yaml.safe_load(fetch_text(subs_url)) or {}).get('proxies') or []
    except Exception as e:
        log(f'::warning::subs-check all.yaml 拉取失败（保留上一版 Gist）：{e}')
        return 0
    if not base_proxies:
        log('::warning::subs-check all.yaml 无节点（保留上一版 Gist）')
        return 0
    log(f'基座：subs-check all.yaml {len(base_proxies)} 个节点（全部原样保留）')

    # ---- 2) 出口：qzz 源 socks5 测活 + 判区 ----
    source = (os.environ.get('SOCKS_SOURCE_URL') or DEFAULT_SOURCE).strip()
    max_exits = int(os.environ.get('MAX_EXITS') or 20)
    workers = int(os.environ.get('PROBE_WORKERS') or 8)
    try:
        qzz = (yaml.safe_load(fetch_text(source)) or {}).get('proxies') or []
    except Exception as e:
        log(f'::warning::出口源抓取失败（保留上一版 Gist）：{e}')
        return 0
    cands = [p for p in qzz if p.get('type') == 'socks5' and p.get('server') and p.get('port')]
    log(f'出口候选：qzz 源 socks5 {len(cands)} 个（http/https 已按要求剔除）')

    live = []
    if cands:
        with ThreadPoolExecutor(max_workers=min(workers, len(cands))) as ex:
            for node, res in zip(cands, ex.map(probe, cands)):
                tag = f"{node.get('name', '?')[:34]:<34} {node['server']}:{node['port']}"
                if res:
                    live.append(res)
                    log(f"  ✅ {tag} → {res['ip']} {res['colo']}/{res['loc']} GL={res['gl']} {res['latency']:.2f}s")
                else:
                    log(f'  ❌ {tag}')

    # 按代理地址去重（同一 host:port 只留最快一条）
    live.sort(key=lambda x: x['latency'])
    seen, picked = set(), []
    for item in live:
        if item['addr'] in seen:
            continue
        seen.add(item['addr'])
        picked.append(item)
        if len(picked) >= max_exits:
            break

    if not picked:
        log('::warning::本轮无可用 SOCKS5 出口（保留上一版 Gist）')
        return 0
    dist = {}
    for x in picked:
        dist[x['gl']] = dist.get(x['gl'], 0) + 1
    log(f'验证通过出口 {len(picked)} 个；判区分布 {dist}')

    # ---- 3) 组合：每个基座节点 × 每个出口（入口不动，仅换 path） ----
    used = {p.get('name') for p in base_proxies}
    out_nodes = []
    for base in base_proxies:
        out_nodes.append(base)                      # 原节点原样
        ws = base.get('ws-opts')
        if not ws or base.get('network') not in (None, 'ws'):
            continue                                # 非 ws 形态承载不了 path 出口
        for live_item in picked:
            node = build_exit_node(base, live_item)
            name = f"{base['name']}|YT-{live_item['gl']}|{live_item['latency']:.2f}s"
            n = 1
            while name in used:
                n += 1
                name = f"{base['name']}|YT-{live_item['gl']}|{live_item['latency']:.2f}s#{n}"
            used.add(name)
            node['name'] = name
            out_nodes.append(node)

    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(args.out, 'socks-exit.yaml')
    with open(out_path, 'w', encoding='utf-8') as f:
        yaml.safe_dump({'proxies': out_nodes}, f, allow_unicode=True, sort_keys=False)
    log(f'已写出 {out_path}：原节点 {len(base_proxies)} + 组合节点 {len(out_nodes) - len(base_proxies)} = {len(out_nodes)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
