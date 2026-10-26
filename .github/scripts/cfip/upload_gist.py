#!/usr/bin/env python3
"""把 cfip 池文件推到 secret gist（有变化才写，避免无意义提交）。

env:
  GH_TOKEN  有 gist 权限的 token
  GIST_ID   目标 gist（仓库变量 CFIP_GIST_ID）
  OUT_DIR   池文件目录（默认 out）
"""
import json
import os
import sys
import urllib.request

API = 'https://api.github.com/gists/{gid}'


def request(url, token, method='GET', payload=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'Authorization': f'Bearer ***}',
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'cfip-pool',
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode('utf-8'))


def main():
    token = ***'GH_TOKEN') or '').strip()
    gid = (os.environ.get('GIST_ID') or '').strip()
    out_dir = (os.environ.get('OUT_DIR') or 'out').strip()
    if not token or not gid:
        print('缺少 GH_TOKEN 或 GIST_ID，跳过上传')
        return 0

    files = {}
    for name in sorted(os.listdir(out_dir)):
        if not name.startswith('cfip-') or not name.endswith('.txt'):
            continue
        with open(os.path.join(out_dir, name), encoding='utf-8') as f:
            files[name] = {'content': f.read()}
    if not files:
        print('没有可上传的池文件')
        return 1

    current = request(API.format(gid=gid), token)
    existing = current.get('files') or {}
    changed = {name: payload for name, payload in files.items()
               if (existing.get(name) or {}).get('content') != payload['content']}
    if not changed:
        print('池内容无变化，跳过写入')
        return 0

    request(API.format(gid=gid), token, 'PATCH', {'files': changed})
    print(f'已更新 {len(changed)} 个文件：' + ', '.join(sorted(changed)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
