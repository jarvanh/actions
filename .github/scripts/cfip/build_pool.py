#!/usr/bin/env python3
"""构建 Cloudflare 优选 IP 池：镜像 881288 + 公共源 + 自扫（CloudflareSpeedTest）。

为什么要自己做（2026-10-26）：proxyip.881288.xyz 的 D1 免费额度超限时会把错误文本
混进列表，订阅侧拿到非 IP 行就整段解析失败（10-21 因此被禁用，节点随之变少）。
这里统一做「抓取 → 逐行校验 → 去重 → 合并自扫结果 → 输出稳定文件」，坏行一律丢弃。

输出（写到 --out 目录）：
  cfip-all.txt     全部合并，`ip:port`
  cfip-<REGION>.txt 按地区镜像，保持 881288 的 `ip:port#地区 ~ 延迟` 格式
  cfip-cfst.txt    自扫结果，`ip:port#cfst 速度`
  cfip-extra.txt   公共源合并（IPDB / cf-speed-dns / uouin / wetest），`ip:port#来源 线路`
"""
import argparse
import csv
import os
import re
import sys
import urllib.request

REGIONS = ['HK', 'TW', 'KR', 'JP', 'SG', 'US']
REGION_URL = 'https://proxyip.881288.xyz/api/txt/{region}'
EXTRA_SOURCES = {
    'ipdb-bestcf': 'https://ipdb.api.030101.xyz/?type=bestcf',
    'ipdb-bestproxy': 'https://ipdb.api.030101.xyz/?type=bestproxy',
    # cf-speed-dns（CloudflareSpeedTest 每 5 分钟推送优选）：整行逗号分隔，parse_lines 已兼容
    'cf-speed-dns': 'https://ip.164746.xyz/ipTop.html',
}
IP_PORT = re.compile(r'^(\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5})(?:#(.*))?$')
IP_ONLY = re.compile(r'^(\d{1,3}(?:\.\d{1,3}){3})$')
DEFAULT_PORT = '443'
MAX_PER_FILE = 300


def fetch(url, timeout=20):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 cfip-pool'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', 'ignore')


def parse_lines(text, default_port=DEFAULT_PORT):
    """只保留合法行：`ip:port[#备注]` 或纯 `ip`；错误文本/HTML/空行全部丢弃。"""
    out = []
    # 按换行和逗号一起切：cf-speed-dns 的 ipTop.html 是整行逗号分隔（104.18.41.86,104.18.35.81）
    for raw in re.split(r'[\r\n,]+', text):
        line = raw.strip()
        if not line:
            continue
        m = IP_PORT.match(line)
        if m:
            ip, port, note = m.group(1), m.group(2), (m.group(3) or '').strip()
            if 0 < int(port) < 65536:
                out.append((ip, port, note))
            continue
        m = IP_ONLY.match(line)
        if m:
            out.append((m.group(1), default_port, ''))
    return out


def parse_uouin_html(html):
    """麒麟检测 api.uouin.com/cloudflare.html：表格行 = 序号|线路|IP|丢包|延迟。

    只收「前一格是 电信/联通/移动、本格是 IPv4」的行，页面文档区的示例 IP 不会混入。
    """
    rows = []
    for tr in re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.S):
        cells = [re.sub(r'<[^>]+>', '', c).strip()
                 for c in re.findall(r'<t[dh][^>]*>(.*?)</t[dh]>', tr, re.S)]
        for i in range(1, len(cells)):
            if IP_ONLY.match(cells[i]) and re.search(r'电信|联通|移动', cells[i - 1]):
                rows.append((cells[i], cells[i - 1]))
    return rows


def parse_wetest_html(html):
    """微测网 address_v4.html：数据行 = 线路名称|IP|大小|速度|延迟|数据中心|更新时间。"""
    rows = []
    for tr in re.findall(r'<tr[^>]*>(.*?)</tr>', html, re.S):
        cells = [re.sub(r'<[^>]+>', '', c).strip()
                 for c in re.findall(r'<td[^>]*>(.*?)</td>', tr, re.S)]
        if len(cells) >= 2 and IP_ONLY.match(cells[1]):
            rows.append((cells[1], cells[0]))
    return rows


# 这两站没有纯文本 API，页面表格结构实测稳定（2026-10-28），用解析器抽取 <tr> 行
HTML_SOURCES = {
    'uouin': ('https://api.uouin.com/cloudflare.html', parse_uouin_html),
    'wetest': ('https://www.wetest.vip/page/cloudflare/address_v4.html', parse_wetest_html),
}


def read_cfst(path):
    """读 CloudflareSpeedTest 的 result.csv，返回 [(ip, speed, latency)]。

    排序：有下载速度的按速度降序在前，没速度的按延迟升序在后。
    为什么允许 speed=0：GitHub runner 在 Azure，CF 的下载测速端点经常限速/不可达，
    这一列会全是 0.00；此时仍可用延迟筛出「能连通」的 IP，不要让整份自扫结果作废。
    """
    if not path or not os.path.exists(path):
        return []
    rows = []
    with open(path, encoding='utf-8-sig', newline='') as f:
        reader = csv.reader(f)
        next(reader, None)
        for row in reader:
            if len(row) < 6:
                continue
            ip = row[0].strip()
            try:
                loss = float(row[3])
                latency = float(row[4])
                speed = float(row[5])
            except ValueError:
                continue
            if loss < 1.0 and latency > 0:
                rows.append((ip, speed, latency))
    rows.sort(key=lambda r: (r[1] > 0, r[1] if r[1] > 0 else -r[2]), reverse=True)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='out')
    ap.add_argument('--cfst', default='')
    ap.add_argument('--cfst-label', default='cfst')
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    regions = {}
    failed = []
    for region in REGIONS:
        try:
            items = parse_lines(fetch(REGION_URL.format(region=region)))
            regions[region] = items
            print(f'{region}: {len(items)} 条')
        except Exception as exc:  # 单源失败不影响整体
            regions[region] = []
            failed.append(f'{region}: {exc}')
            print(f'{region}: 抓取失败 {exc}', file=sys.stderr)

    extras = {}
    extra_tagged = []  # (ip, port, 来源备注) → cfip-extra.txt，KV ADD.txt 直接引用该文件
    for name, url in EXTRA_SOURCES.items():
        try:
            extras[name] = parse_lines(fetch(url))
            extra_tagged.extend((ip, port, note or name) for ip, port, note in extras[name])
            print(f'{name}: {len(extras[name])} 条')
        except Exception as exc:
            extras[name] = []
            failed.append(f'{name}: {exc}')
            print(f'{name}: 抓取失败 {exc}', file=sys.stderr)

    for name, (url, parser) in HTML_SOURCES.items():
        try:
            items, seen_html = [], set()
            for ip, isp in parser(fetch(url)):
                if ip in seen_html:
                    continue
                seen_html.add(ip)
                items.append((ip, DEFAULT_PORT, f'{name} {isp}'))
            extras[name] = items
            extra_tagged.extend(items)
            print(f'{name}: {len(items)} 条')
        except Exception as exc:
            extras[name] = []
            failed.append(f'{name}: {exc}')
            print(f'{name}: 抓取失败 {exc}', file=sys.stderr)

    cfst = read_cfst(args.cfst)
    if cfst:
        print(f'cfst: {len(cfst)} 个可用 IP')

    # 地区文件：保持 881288 原格式，便于直接替换
    for region, items in regions.items():
        seen, lines = set(), []
        for ip, port, note in items:
            if ip in seen:
                continue
            seen.add(ip)
            lines.append(f'{ip}:{port}#{note}' if note else f'{ip}:{port}')
        if not lines:
            # 源站临时失败时**不写空文件**，避免把 gist 里上一轮的好内容覆盖掉
            print(f'{region}: 本轮无有效行，保留上一轮内容', file=sys.stderr)
            continue
        with open(os.path.join(args.out, f'cfip-{region}.txt'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines[:MAX_PER_FILE]) + '\n')

    # 自扫文件
    label = (args.cfst_label or 'cfst').strip() or 'cfst'
    with open(os.path.join(args.out, 'cfip-cfst.txt'), 'w', encoding='utf-8') as f:
        # 有速度的排前面（按速度降序），没速度的按延迟升序；标签标明在哪台机器测的
        lines = [f'{ip}:{DEFAULT_PORT}#{label} {speed:.2f}MB/s' if speed > 0 else f'{ip}:{DEFAULT_PORT}#{label} {latency:.0f}ms'
                 for ip, speed, latency in cfst[:MAX_PER_FILE]]
        f.write('\n'.join(lines) + ('\n' if lines else ''))

    # 公共源合并文件：带来源备注，供 KV ADD.txt 引用（cfip-all.txt 是全量去重视图，不带备注）
    seen_extra, extra_lines = set(), []
    for ip, port, note in extra_tagged:
        if ip in seen_extra:
            continue
        seen_extra.add(ip)
        extra_lines.append(f'{ip}:{port}#{note}' if note else f'{ip}:{port}')
    with open(os.path.join(args.out, 'cfip-extra.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(extra_lines[:MAX_PER_FILE]) + ('\n' if extra_lines else ''))

    # 合并文件：地区优先，其次公共源，最后自扫
    merged, seen = [], set()
    for items in regions.values():
        for ip, port, _ in items:
            if ip not in seen:
                seen.add(ip)
                merged.append(f'{ip}:{port}')
    for items in extras.values():
        for ip, port, _ in items:
            if ip not in seen:
                seen.add(ip)
                merged.append(f'{ip}:{port}')
    for ip, _speed, _lat in cfst:
        if ip not in seen:
            seen.add(ip)
            merged.append(f'{ip}:{DEFAULT_PORT}')
    with open(os.path.join(args.out, 'cfip-all.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(merged[:MAX_PER_FILE]) + ('\n' if merged else ''))

    print(f'合并后 {len(merged)} 条（上限 {MAX_PER_FILE}）')
    if failed:
        print('部分源失败：' + '; '.join(failed), file=sys.stderr)
    return 0 if merged else 1


if __name__ == '__main__':
    sys.exit(main())
