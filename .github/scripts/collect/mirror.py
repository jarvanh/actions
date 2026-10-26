#!/usr/bin/env python3
"""把外部 crawler 产出的完整 Clash 配置，转成 Egern 能吃的「纯 proxies」镜像。

背景（2026-10-26）：collect 那份 clash.yaml 是完整配置（port/mode/rules + 84 个
flow 风格节点），Egern 报「位于第 8 行第 6 列」——位置正好是第一个节点的第一个键，
但文件本身在 libyaml/js-yaml/PyYAML 下都合法，端口也已经是整数。判断是 Egern 对
「完整配置 + flow 风格映射」的兼容问题，所以这里只保留 proxies，并改写成块状 YAML。

输出：collect.yaml（只有 proxies，块状，端口整数）
"""
import argparse
import os
import sys
import urllib.request

import yaml

SRC = 'https://gist.githubusercontent.com/jarvanh/4213093bf20bdc74232a676d28574dd2/raw/clash.yaml'


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 collect-mirror'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', 'ignore')


def normalize(proxy):
    out = dict(proxy)
    if isinstance(out.get('port'), str) and out['port'].strip().isdigit():
        out['port'] = int(out['port'].strip())
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='out')
    ap.add_argument('--src', default=SRC)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    doc = yaml.safe_load(fetch(args.src)) or {}
    proxies = [normalize(p) for p in (doc.get('proxies') or []) if isinstance(p, dict)]
    if not proxies:
        print('源里没有 proxies，放弃', file=sys.stderr)
        return 1

    text = yaml.safe_dump({'proxies': proxies}, allow_unicode=True, sort_keys=False, width=1000)
    path = os.path.join(args.out, 'collect.yaml')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)

    # 自检：写出的文件必须能解析，且端口全是整数
    back = yaml.safe_load(text) or {}
    bad = [p.get('name') for p in (back.get('proxies') or []) if not isinstance(p.get('port'), int)]
    if bad:
        print(f'仍有 {len(bad)} 个非整数端口，放弃：{bad[:3]}', file=sys.stderr)
        return 1
    print(f'collect.yaml: {len(proxies)} 个节点，{len(text)} 字节')
    return 0


if __name__ == '__main__':
    sys.exit(main())
