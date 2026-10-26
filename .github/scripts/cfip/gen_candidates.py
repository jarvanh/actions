#!/usr/bin/env python3
"""生成 40 个 Cloudflare 网段候选 IP，供 CloudflareSpeedTest 用 -f 扫描。

为什么不用 CFST 自带的 ip.txt（2026-10-26）：自带列表会随机生成上百个 IP，
每条下载测速在不可达 IP 上要等满 10s 超时，一轮能跑十几分钟。这里固定 5 个
CF 段、每段 8 个，共 40 个，配合 -n 10 把整轮压到 2-3 分钟。
"""
import ipaddress
import random
import sys

RANGES = [
    '104.16.0.0/13',
    '172.64.0.0/13',
    '104.24.0.0/14',
    '162.159.0.0/16',
    '104.28.0.0/14',
]
PER_RANGE = 8


def main():
    ips = set()
    for cidr in RANGES:
        net = ipaddress.ip_network(cidr)
        for _ in range(PER_RANGE):
            ips.add(str(net.network_address + random.randrange(net.num_addresses)))
    print('\n'.join(sorted(ips)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
