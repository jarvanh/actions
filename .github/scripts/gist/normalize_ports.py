#!/usr/bin/env python3
"""把 Gist 里 YAML 订阅的「字符串端口」改回整数（幂等，只改这一种写法）。

背景（2026-10-25）：subs-check 容器生成的 all.yaml 会把端口序列化成 `port: "443"`。
Egern 要求 port 为 integer，整条节点 decode 失败，报错位置回退到节点第一个键
（表现为「位于第 2 行第 7 列」这种看起来像 YAML 语法错的假报错）。
容器自身的序列化改不了，所以在它上传之后做一次定点修正：
只动行首 `port: "数字"` / `port: '数字'`，其余字节原样保留；没有可改内容就不 PATCH。
"""
import json
import os
import re
import sys
import urllib.request

import yaml

API = 'https://api.github.com/gists/{gid}'
PORT_RE = re.compile(r'(?m)^(\s*(?:-\s*)?port:\s*)([\'"])(\d+)\2[ \t]*$')


def _request(url, token, method='GET', payload=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': f'Bearer {token}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'gist-port-normalize',
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode('utf-8'))


def main():
    token = (os.environ.get('GH_TOKEN') or '').strip()
    gid = (os.environ.get('GIST_ID') or '').strip()
    filename = (os.environ.get('FILENAME') or 'all.yaml').strip()
    if not token or not gid:
        print('缺少 GH_TOKEN 或 GIST_ID，跳过')
        return 0

    gist = _request(API.format(gid=gid), token)
    entry = (gist.get('files') or {}).get(filename) or {}
    content = entry.get('content') or ''
    if not content:
        print(f'{filename} 内容为空或被截断，跳过')
        return 0

    fixed, count = PORT_RE.subn(lambda m: f'{m.group(1)}{m.group(3)}', content)
    if count == 0:
        print(f'{filename} 没有字符串端口，无需改动')
        return 0

    # 改完必须仍然是合法 YAML，且 proxies 的端口全是整数，否则不推
    doc = yaml.safe_load(fixed)
    proxies = (doc or {}).get('proxies') or []
    bad = [p.get('name') for p in proxies if not isinstance(p.get('port'), int)]
    if bad:
        print(f'仍有 {len(bad)} 个非整数端口，放弃推送：{bad[:3]}')
        return 1

    _request(API.format(gid=gid), token, 'PATCH', {'files': {filename: {'content': fixed}}})
    print(f'{filename} 已修正 {count} 处端口，共 {len(proxies)} 个节点')
    return 0


if __name__ == '__main__':
    sys.exit(main())
