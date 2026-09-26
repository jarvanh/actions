#!/usr/bin/env python3
"""`speedtest_gitee.build_source_mapping` 的离线自检：链接列表与 Clash YAML **都要认**。

为什么需要它：这个函数是「节点 → 可导出配置」的**唯一取数口**。导出订阅只认
`source_entry.proxy`（以及它下面的 `proxy_obj` 兜底），而 `source_entry` 有没有值全看这里。
它出过一次真实事故（2026-09-26 编排轮）：

  * 源订阅是 Sub-Store 产出的 Clash YAML（118055 行、8470 个节点），其中**有 3 行**节点名
    里嵌着带 `#片段` 的 URL（如 `name: '[VLESS] [free18#002] 电报群：https://t.me/vvkj11 - 94ms'`）。
  * 旧实现把「扫描到过像链接的行」当成「这是一份链接列表，不是 YAML」⇒ 直接 `continue`
    跳过整段 YAML 解析。于是 `source_mapping_built entries: 6`——而那 3 行各自贡献
    `exact_raw` + `exact_proxy` 两条，正好 6。
  * 8470 个节点里 8464 个拿不到 `source_entry`，导出时退回 mihomo `/providers/proxies`
    的**运行时对象**（只有 name/type/udp/uot/mptcp/smux/interface/routing-mark/
    dialer-proxy/extra/provider-name，**没有 server/port/凭据**）⇒ 客户端（Egern）加载报错，
    而整轮日志一路正常、订阅照样「✅ 已更新」。

所以这里钉住两件事，缺一不可：

  * **YAML 订阅里混进像链接的行，仍必须解析出全部节点**（复刻上面那 3 行）；
  * **纯链接列表仍走链接分支**（不能因为顺手放开了 YAML 分支就把链接列表的解析弄丢）。

跑法：python .github/scripts/proxy-speedtest/tests/test_source_mapping_branches.py
退出码 0 = 全部通过。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []

# 复刻 2026-09-26 编排轮源订阅里的那一行：行内既有 `://` 又有 `#片段`，
# `urlparse(line).fragment` 非空 ⇒ 旧实现据此认定「这是链接列表」。
STRAY_LINE = "name: '[VLESS] [free18#002] 电报群：https://t.me/vvkj11 - 94ms'"

YAML_SUB = f"""proxies:
- {STRAY_LINE}
  type: vless
  server: stray.example.com
  port: 443
  uuid: 11111111-2222-3333-4444-555555555555
- name: hk-plain-1
  type: trojan
  server: hk1.example.com
  port: 443
  password: pass1
- name: hk-plain-2
  type: trojan
  server: hk2.example.com
  port: 443
  password: pass2
"""

LINK_SUB = (
    'vless://11111111-2222-3333-4444-555555555555@link1.example.com:443'
    '?security=tls&type=ws#link-node-1\n'
    'trojan://pass2@link2.example.com:443?security=tls#link-node-2\n'
)

# 让「误扫出来的碎片」与「真节点名」撞车：`#dup-name` 的 frag 恰好是一个真节点名。
# 这组守**顺序**——真配置必须先占位，否则真节点会被碎片条目挤掉。
SHADOW_SUB = """proxies:
- name: 'x https://t.me/abc#dup-name'
  type: vless
  server: stray2.example.com
  port: 443
  uuid: 11111111-2222-3333-4444-555555555555
- name: dup-name
  type: trojan
  server: real.example.com
  port: 443
  password: pass3
"""


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def entries_count(mapping):
    """与生产日志 `source_mapping_built entries` 同一算法（exact_proxy + exact_raw）。"""
    return len(mapping.get('exact_proxy') or {}) + len(mapping.get('exact_raw') or {})


def main():
    import speedtest_common as C
    import speedtest_gitee as G

    orig_fetch = G.fetch_text
    orig_urls = G.parse_sub_urls
    orig_log = G.log_progress
    payload = {'text': YAML_SUB}
    events = []
    G.parse_sub_urls = lambda env: ['https://example.invalid/sub']
    G.fetch_text = lambda url, *a, **kw: payload['text']
    # 只记录、**不静音**：解析失败会走 `subscription_yaml_parse_skipped`，把日志吞掉就正好
    # 掩盖了本测试要守的那类静默失效（第一版夹具 YAML 缩进写错时就是这么被藏住的）。
    G.log_progress = lambda stage, **kw: events.append(dict(stage=stage, **kw))
    try:
        print('== 1. Clash YAML 里混进「像链接且带 #片段」的行，仍必须解析出整份节点 ==')
        # 事故判据：旧实现的 entries 恰好 = 6（3 行 × 2 个映射），与节点数无关
        m = G.build_source_mapping({})
        n = entries_count(m)
        check(n >= 3, f'不应退化成「只认出像链接的那几行」（实际 entries={n}）')
        exact_proxy = m.get('exact_proxy') or {}
        for name in ('hk-plain-1', 'hk-plain-2'):
            check(name in exact_proxy, f'YAML 节点 {name} 进了 exact_proxy')

        print('== 2. 这些节点必须带**可导出配置**（事故里它们是空壳，客户端加载报错）==')
        check([e['stage'] for e in events if e['stage'].startswith('subscription_')] == [],
              '取文与 YAML 解析都没有走降级分支（实际 '
              f'{[e for e in events if e["stage"].startswith("subscription_")]}）')
        for name in ('hk-plain-1', 'hk-plain-2'):
            proxy = (exact_proxy.get(name) or {}).get('proxy') or {}
            check(C.is_exportable_proxy(proxy) and proxy.get('server', '').startswith('hk'),
                  f'{name} 的 source_entry.proxy 有 server/port（实际 {proxy.get("server")}:{proxy.get("port")}）')
        # 端到端：导出层取到的配置必须能写进订阅，而不是空壳
        item = {'name': 'hk-plain-1', 'source_entry': exact_proxy.get('hk-plain-1') or {},
                'upload_mibs': 20.0 / 8.388608, 'download_mibs': 20.0 / 8.388608}
        check(C.node_proxy_config(item).get('server') == 'hk1.example.com',
              '导出层从 source_entry 取到真配置（不是 mihomo 运行时对象的空壳）')

        print('== 3. 纯链接列表仍走链接分支（放开 YAML 分支不等于丢掉链接解析）==')
        payload['text'] = LINK_SUB
        m2 = G.build_source_mapping({})
        exact_raw = m2.get('exact_raw') or {}
        check('link-node-1' in exact_raw and 'link-node-2' in exact_raw,
              f'两条链接按 name 片段入表（实际 {sorted(exact_raw)}）')
        proxied = {k: v for k, v in (m2.get('exact_proxy') or {}).items()
                   if (v.get('proxy') or {}).get('server')}
        check(sorted(proxied) == ['link-node-1', 'link-node-2'],
              f'链接还原成可导出配置（实际 {sorted(proxied)}）')
        check(C.is_exportable_proxy((proxied.get('link-node-1') or {}).get('proxy') or {}),
              '链接节点的配置同样过 is_exportable_proxy')
        check(entries_count(m2) == 4, f'两条链接 ⇒ entries=4（实际 {entries_count(m2)}）')

        print('== 4. 链接列表里没有 proxies: 时不该去解析 YAML（保持原意、别白烧时间）==')
        check('proxies:' not in LINK_SUB, '第 3 组的正文确实不含 proxies:（对照组设计正确）')

        print('== 5. 碎片条目不许挤掉真节点：YAML 必须先占位 ==')
        payload['text'] = SHADOW_SUB
        m3 = G.build_source_mapping({})
        entry = (m3.get('exact_proxy') or {}).get('dup-name') or {}
        check((entry.get('proxy') or {}).get('server') == 'real.example.com',
              f'撞车时真节点配置胜出（实际 {(entry.get("proxy") or {}).get("server")}）')
        check(C.is_exportable_proxy(entry.get('proxy') or {}),
              '撞车后该节点仍可导出（没被还原不出配置的碎片顶掉）')
        stray_name = 'x https://t.me/abc#dup-name'
        check(C.is_exportable_proxy(((m3.get('exact_proxy') or {}).get(stray_name) or {}).get('proxy') or {}),
              '带 URL 的节点名本身也是可导出的（它以真名入表，不是以 frag 入表）')
    finally:
        G.fetch_text = orig_fetch
        G.parse_sub_urls = orig_urls
        G.log_progress = orig_log

    print()
    if FAILURES:
        print(f'FAILED: {len(FAILURES)} 项未通过')
        for f in FAILURES:
            print(f'  - {f}')
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())