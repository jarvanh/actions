#!/usr/bin/env python3
"""把 subs-check 容器产出的 all.yaml 做成「端口整数」的稳定镜像。

背景（2026-10-26）：容器每 2 小时重写一次 gist，端口又被序列化成 `port: "443"`，
Egern 要求 integer，于是每隔一段时间就报「位于第 2 行第 7 列」。
后处理脚本（gist-port-normalize）虽然每 30 分钟修一次，但容器一写就又坏，
存在空窗期。这里改成：Egern 只引用本镜像，容器怎么写都不影响。

输出：all.yaml（只把行首带引号的数字端口改成整数，其余字节原样保留）
"""
import argparse
import os
import re
import sys
import urllib.request

import yaml

SRC = 'https://gist.githubusercontent.com/jarvanh/6d7b7e99861455b9e3b48f9e3016f69d/raw/all.yaml'
PORT_RE = re.compile(r'(?m)^(\s*(?:-\s*)?port:\s*)([\'"])(\d+)\2[ \t]*$')


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 all-mirror'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', 'ignore')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='out')
    ap.add_argument('--src', default=SRC)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    raw = fetch(args.src)
    fixed, count = PORT_RE.subn(lambda m: f'{m.group(1)}{m.group(3)}', raw)

    doc = yaml.safe_load(fixed) or {}
    proxies = doc.get('proxies') or []
    if not proxies:
        print('源里没有 proxies，放弃', file=sys.stderr)
        return 1
    bad = [p.get('name') for p in proxies if not isinstance(p.get('port'), int)]
    if bad:
        print(f'仍有 {len(bad)} 个非整数端口，放弃：{bad[:3]}', file=sys.stderr)
        return 1

    path = os.path.join(args.out, 'all.yaml')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(fixed)
    print(f'all.yaml: {len(proxies)} 个节点，修正 {count} 处端口，{len(fixed)} 字节')
    return 0


if __name__ == '__main__':
    sys.exit(main())
