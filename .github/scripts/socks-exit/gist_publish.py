#!/usr/bin/env python3
# ===== 共享脚本：socks-exit.yaml → 私有 Gist 发布器 =====
# 为什么不用 bash + jq（run 40636213832 的教训）：
#   v3 产物 675KB，`jq -n --arg c "$(cat f)"` 把整个文件内容放进命令行参数，
#   撞 Linux 单参数上限（MAX_ARG_STRLEN≈128KB）→ `/usr/bin/jq: Argument list too long`。
#   本脚本全程走文件/内存流：GET 比较 → PATCH 单文件，不经任何命令行大参数。
#
# 用法：python3 gist_publish.py out/socks-exit.yaml
# 环境变量：GIST_ID（目标 gist）、GH_TOKEN（写权限）
# 语义：内容未变化跳过写入；产物缺失/为空按「保留上一版」处理（exit 0，不报错）。
import json
import os
import sys
import urllib.request

import yaml


def main():
    if len(sys.argv) != 2:
        print('用法: gist_publish.py <socks-exit.yaml 路径>')
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        print('::warning::本轮未产出节点，保留上一版 Gist')
        return 0
    n = len((yaml.safe_load(open(path, encoding='utf-8')) or {}).get('proxies') or [])
    if n < 1:
        print('::warning::本轮 0 个可用节点，保留上一版 Gist')
        return 0

    gist_id = (os.environ.get('GIST_ID') or '').strip()
    token = (os.environ.get('GH_TOKEN') or '').strip()
    if not gist_id or not token:
        print('::error::缺少 GIST_ID / GH_TOKEN')
        return 2

    def api(method, payload=None):
        req = urllib.request.Request(
            f'https://api.github.com/gists/{gist_id}',
            data=json.dumps(payload).encode() if payload is not None else None,
            method=method,
            headers={'Authorization': f'Bearer {token}',
                     'Accept': 'application/vnd.github+json',
                     'User-Agent': 'socks-exit-pool'})
        return json.loads(urllib.request.urlopen(req, timeout=60).read() or b'{}')

    try:
        cur = (api('GET').get('files') or {}).get('socks-exit.yaml', {}).get('content') or ''
    except Exception as e:
        print(f'::warning::gist 读取失败，按「有变化」处理：{e}')
        cur = ''
    new = open(path, encoding='utf-8').read()
    if cur == new:
        print('内容未变化，跳过写入')
        return 0
    api('PATCH', {'files': {'socks-exit.yaml': {'content': new}}})
    print(f'已更新 socks-exit.yaml（{n} 个节点）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
