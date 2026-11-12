#!/usr/bin/env python3
"""订阅判定指标回退的自检（`speedtest_common.resolve_subscription_metric`）。

为什么单独一个文件：这条判据决定「订阅里最终有几个节点」，而它出过两次真实事故：

1. run 34859505000：19 个节点**下行全部达标**，订阅里却**只有 1 个节点**。
   根因：回退条件曾是「主指标达标数 < `min_nodes`」，而当时 `min_nodes` 默认 1
   ⇒ 主指标有 1 个就永不回退。
2. run 42953380754（2026-11-11）：真实上传修好后 `primary=5`、`secondary` 近 300，
   订阅却静默停更。根因：解耦出的回退门槛（3）落在 `min_nodes`（10）之下，
   形成 [3,10) 盲区——`5 >= 3` 不回退、`5 < 10` 不上传，两条路都不走。

现在的判据（2026-11-12 合并为**单一门槛** `min_nodes`）：
**主指标凑不够（primary < min_nodes）且另一指标能凑够（secondary >= min_nodes）**才改判。
``PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES`` 已不再读取。

第 7–10 组守**另一条更隐蔽的路**——「可导出配置」的取值来源。2026-09-16 的编排轮
`35116972319` 里 206 个节点实测有速度（最高上传 245 Mbps），订阅却判「达标不足 1 个」：
`source_entry.proxy` 只在节点名匹配上订阅 source_mapping 时才有值，而编排轮的 8326 个
节点由 gistnodes 经 provider 直接喂入、source_mapping 只有 4 条 ⇒ 配置全在 `proxy_obj`
里却没人读。现在钉住：`source_entry.proxy` 优先、缺失回落 `proxy_obj`、**两者皆空仍须挡住**
（回落不能变成「什么都算数」：mihomo 运行时对象没有 `server`/`port`，不算可导出配置）。

跑法：`python .github/scripts/proxy-speedtest/tests/test_subscription_metric.py`
退出码 0 = 全过。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def node(up_mbps, down_mbps, with_proxy=True, ok=True):
    """按 taier 的单位换算构造一条结果：Mbps / 8.388608 = MiB/s（与 taier_speedtest 一致）。

    ok=True 是默认：达标判定（2026-10-12 起）要求 ok=True，构造的这些是成功节点。
    """
    return {'name': 'n', 'ok': ok,
            'source_entry': {'proxy': {'type': 'vless'}} if with_proxy else {},
            'upload_mibs': up_mbps / 8.388608, 'download_mibs': down_mbps / 8.388608}


def main():
    import speedtest_common as C

    print('== 1. 事故数据复现（run 34859505000）==')
    # 真实日志：18 个节点 up=0.0，1 个 up=78.21；19 个 down 全部 >= 10 兆
    down = [124.94, 32.74, 23.32, 13.6, 32.34, 41.94, 17.16, 20.94,
            13.76, 16.03, 22.18, 10.72, 25.04, 24.04, 107.53, 15.26, 12.63, 23.96, 143.91]
    up = [0.0] * 18 + [78.21]
    results = [node(u, d) for u, d in zip(up, down)]
    pol = C.resolve_subscription_policy({})

    check(pol['metric'] == 'upload', '默认判定指标是 upload')
    check('metric_fallback_min_nodes' not in pol,
          f"策略里不再有独立回退门槛（实际键：{sorted(pol)}）")
    check(pol['min_nodes'] == 10,
          f'默认最少节点数 10（实际 {pol["min_nodes"]}；2026-10-19 主人定：'
          '源枯竭时 qualified=1 也照旧上传，订阅里只剩一个节点不如不更新）')

    m, q, fb = C.resolve_subscription_metric(results, pol)
    check(m == 'download', f'上行只有 1 个达标（< 10）⇒ 回退到 download（实际 {m}）')
    check(q == 19, f'回退后达标 19 个，而不是 1 个（实际 {q}）')
    check(fb is True, '标记为已回退（fallback=True）')
    bundle = C.build_subscription_bundle(results, pol)
    check(bundle['qualified'] == 19 and bool(bundle['text']),
          f'订阅文本按 19 个节点生成（实际 {bundle["qualified"]}）')

    print('== 2. 反向：主指标够一份订阅 ⇒ 维持配置的主指标 ==')
    up_good = [node(50, 5) for _ in range(10)]
    m2, q2, fb2 = C.resolve_subscription_metric(up_good, pol)
    check((m2, fb2) == ('upload', False), f'上行 10（≥ min_nodes）/ 下行 0 ⇒ 维持 upload（实际 {m2}/{fb2}）')
    check(q2 == 10, f'达标数取主指标（实际 {q2}）')

    print('== 3. 盲区回归（run 42953380754）：primary 落在 (0, min_nodes) 也要能回退 ==')
    # 真实场景：真实上传修好后主指标只有 5 个达标，下行近 300 —— 旧实现（门槛 3）静默停更。
    blind = [node(50, 1)] * 5 + [node(1, 50)] * 50
    m3, q3, fb3 = C.resolve_subscription_metric(blind, pol)
    check((m3, fb3) == ('download', True),
          f'primary=5 < 10 且 secondary=50 ≥ 10 ⇒ 回退 download（实际 {m3}/{fb3}）')
    check(q3 == 50, f'回退后达标 50（实际 {q3}）')
    b3 = C.build_subscription_bundle(blind, pol)
    check(bool(b3['text']) and b3['qualified'] == 50,
          f'盲区场景下订阅必须产出（实际 qualified={b3["qualified"]}, text空={not b3["text"].strip()}）')

    print('== 3b. 两边都不够 ⇒ 不回退、不上传（换指标也改变不了结果）==')
    both_short = [node(50, 1)] * 9 + [node(1, 50)] * 9
    m4, q4, fb4 = C.resolve_subscription_metric(both_short, pol)
    check((m4, fb4) == ('upload', False),
          f'primary=9、secondary=9 均 < 10 ⇒ 维持 upload 且不回退（实际 {m4}/{fb4}）')
    check(q4 == 9 and C.build_subscription_bundle(both_short, pol)['text'] == '',
          '达标 9 < 10 ⇒ 不上传（实际文本非空则说明误回退）')

    print('== 3c. 另一指标能凑够才换：secondary 恰等于 min_nodes 是允许的 ==')
    edge = [node(50, 1)] * 0 + [node(1, 50)] * 10
    m5, q5, fb5 = C.resolve_subscription_metric(edge, pol)
    check((m5, q5, fb5) == ('download', 10, True),
          f'primary=0、secondary=10 = min_nodes ⇒ 回退并上传（实际 {m5}/{q5}/{fb5}）')

    print('== 4. 全不达标 ⇒ 不上传（min_nodes 仍守着「不足不上传」）==')
    zero = [node(0, 0)] * 5
    m6, q6, fb6 = C.resolve_subscription_metric(zero, pol)
    check(q6 == 0, f'达标 0（实际 {q6}）')
    check(C.build_subscription_bundle(zero, pol)['text'] == '', '订阅文本为空 ⇒ 跳过上传')
    check(fb6 is False, '无达标时不做无意义的回退')

    print('== 5. 单一门槛：min_nodes 同时决定「换不换」与「传不传」==')
    # min_nodes=5：primary=3 < 5 且 secondary=10 ≥ 5 ⇒ 回退并上传（旧语义会停更）
    close = [node(50, 5)] * 3 + [node(1, 50)] * 10
    pol5 = dict(pol, min_nodes=5)
    m7, q7, fb7 = C.resolve_subscription_metric(close, pol5)
    check((m7, q7, fb7) == ('download', 10, True),
          f'min_nodes=5 时 primary=3 < 5 且 secondary=10 ≥ 5 ⇒ 回退（实际 {m7}/{q7}/{fb7}）')
    b5 = C.build_subscription_bundle(close, pol5)
    check(bool(b5['text']) and b5['qualified'] == 10,
          f'min_nodes=5 时按 download 上传 10 个（实际 {b5["qualified"]}）')
    # 同一批数据把 min_nodes 抬到 11：primary=3 < 11，secondary=10 < 11 ⇒ 不回退、不上传
    pol11 = dict(pol, min_nodes=11)
    m8, q8, fb8 = C.resolve_subscription_metric(close, pol11)
    check((m8, fb8) == ('upload', False),
          f'min_nodes=11 时 secondary=10 < 11 ⇒ 不回退（实际 {m8}/{fb8}）')

    print('== 6. 配置健壮性：旧回退门槛 env 不再生效 ==')
    p_legacy = C.resolve_subscription_policy({
        'PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES': '99',
        'PROXY_SPEEDTEST_MIN_NODES': '7',
    })
    check('metric_fallback_min_nodes' not in p_legacy,
          '旧配置项不再进入策略字典')
    check(p_legacy['min_nodes'] == 7, f'只认 MIN_NODES（实际 {p_legacy["min_nodes"]}）')
    # 非法 min_nodes 仍按老规矩回默认，不因写错而静默改口径
    for raw, want in (('abc', 10), ('', 10), ('0', 1), ('-3', 1), ('7', 7)):
        p = C.resolve_subscription_policy({'PROXY_SPEEDTEST_MIN_NODES': raw})
        check(p['min_nodes'] == want, f'min_nodes {raw!r} → {want}（实际 {p["min_nodes"]}）')

    print('== 7. 可导出配置回落 proxy_obj（run 35116972319：206 个达标节点被判 0）==')
    # 编排轮形态：节点由 gistnodes 经 provider 直接喂进来，source_mapping 只有 4 条 ⇒
    # source_entry 匹配不上为空，配置全在 proxy_obj 里。旧实现只认 source_entry.proxy
    # ⇒ 206 个实测有速度的节点（最高 245 Mbps）全被判「无可用配置」⇒ 达标 0 ⇒ 不上传。
    # ⚠️ 但兜底**不是「什么都能收」**——proxy_obj 有两种来路，只有真配置能导出，
    # 见第 10 组与 speedtest_common.is_exportable_proxy。
    def orch_node(up_mbps, down_mbps, has_proxy_obj=True, ok=True):
        # ok=True：编排轮这批是**实测有速度**的正常节点（2026-10-12 补 ok 字段——
        # 达标判定要求 ok=True，失败/bypass 节点不得进订阅）
        return {'name': 'n', 'source_entry': {}, 'ok': ok,
                'proxy_obj': {'type': 'vless', 'server': 'x.com', 'port': 443}
                if has_proxy_obj else {},
                'upload_mibs': up_mbps / 8.388608, 'download_mibs': down_mbps / 8.388608}

    orch = [orch_node(245.24, 130.53) for _ in range(206)]
    check(C.count_qualified_nodes(orch, 'upload', 10) == 206,
          f'编排轮 206 个有速度节点全部计入达标（实际 {C.count_qualified_nodes(orch, "upload", 10)}）')
    b7 = C.build_subscription_bundle(orch, pol)
    check(b7['qualified'] == 206 and bool(b7['text']),
          f'订阅文本正常生成（实际 qualified={b7["qualified"]}, text空={not b7["text"].strip()}）')
    check(b7['text'].count('name:') == 206,
          f'导出的 YAML 含 206 个节点（实际 {b7["text"].count("name:")}）')

    print('== 7b. 失败节点（bypass 未走代理/超时/切换失败）不得进订阅（2026-10-12 修）==')
    # 实例：CDN 轮 28 个节点全部 bypass（出口 == runner 直连出口）判定失败，速度字段
    # 与原始配置都还在 ⇒ 旧口径把它们当「达标」导出，订阅段写「✅ 达标 24 个」而
    # 通知标题是「⚠️ 没有节点测速成功」，自相矛盾且订阅内容全是不可信节点。
    failed = [orch_node(100.0, 100.0, ok=False) for _ in range(28)]
    ok_nodes = [orch_node(100.0, 100.0, ok=True) for _ in range(10)]
    mixed = failed + ok_nodes
    check(C.count_qualified_nodes(mixed, 'upload', 10) == 10,
          f'失败节点不计入达标：28 失败 + 10 成功 ⇒ 10（实际 {C.count_qualified_nodes(mixed, "upload", 10)}）')
    b7b = C.build_subscription_bundle(mixed, pol)
    check(b7b['qualified'] == 10,
          f'bundle 达标数 = 10（实际 {b7b["qualified"]}）')
    check(b7b['text'].count('name:') == 10,
          f'导出 YAML 只含 10 个成功节点，28 个失败的一个都不进（实际 {b7b["text"].count("name:")}）')
    # 达标 10 = 默认最少节点数 ⇒ 刚好够上传；少一个（9 个）就按新口径不更新订阅
    #   （2026-10-19 主人定：源枯竭时 qualified=1 也照旧上传，订阅里只剩一个
    #    节点不如不更新——保留上一份多节点订阅更可用）
    short = failed + ok_nodes[:9]
    b7s = C.build_subscription_bundle(short, pol)
    check(b7s['qualified'] == 9 and not b7s['text'].strip(),
          f'达标 9 < 最少节点数 10 ⇒ 不上传订阅（实际 qualified={b7s["qualified"]}, text空={not b7s["text"].strip()}）')
    # 全失败一轮：达标 0 ⇒ min_nodes=1 不足 ⇒ 不上传订阅（text 为空）
    b7c = C.build_subscription_bundle(failed, pol)
    check(b7c['qualified'] == 0 and not b7c['text'].strip(),
          f'全失败一轮不产出订阅（实际 qualified={b7c["qualified"]}, text空={not b7c["text"].strip()}）')

    print('== 7d. bypass 标记优先于 ok —— taier 旧形态（ok 仍 True）（2026-11-10 修）==')
    # taier 曾只挂 `bypass: True` 而不改 `ok`（cdn/gitee 是置 ok=False）。投影层若照抄
    # ok=True，这些「流量其实走了 runner 直连」的读数就会达标进订阅。共享层现在
    # 不看 ok、只看 bypass 也会挡掉（双保险）。
    bypass_rows = [dict(orch_node(100.0, 100.0, ok=True), bypass=True) for _ in range(5)]
    check(C.count_qualified_nodes(bypass_rows, 'upload', 10) == 0,
          f'ok=True 但 bypass=True 不计达标（实际 {C.count_qualified_nodes(bypass_rows, "upload", 10)}）')
    b7d = C.build_subscription_bundle(bypass_rows, dict(pol, min_nodes=1))
    check(b7d['qualified'] == 0 and not b7d['text'].strip(),
          f'bypass 节点不产出订阅（实际 qualified={b7d["qualified"]}, text空={not b7d["text"].strip()}）')

    print('== 8. source_entry.proxy 优先于 proxy_obj（前者是更权威的来源）==')
    both = {'name': 'n',
            'source_entry': {'proxy': {'type': 'trojan', 'server': 'from-entry.com', 'port': 443}},
            'proxy_obj': {'type': 'vless', 'server': 'from-obj.com', 'port': 80},
            'ok': True, 'upload_mibs': 20.0 / 8.388608, 'download_mibs': 20.0 / 8.388608}
    picked = C.node_proxy_config(both)
    check(picked.get('server') == 'from-entry.com',
          f'source_entry 存在时用它（实际 {picked.get("server")}）')
    only_obj = dict(both); only_obj['source_entry'] = {}
    check(C.node_proxy_config(only_obj).get('server') == 'from-obj.com',
          'source_entry 为空时回落到 proxy_obj')
    neither = dict(both); neither['source_entry'] = {}; neither['proxy_obj'] = {}
    check(C.node_proxy_config(neither) == {}, '两者都空 ⇒ 返回空（调用方据此跳过）')

    print('== 9. 反向：两者皆空仍必须判「不可导出」==')
    # 回落不能变成「什么都算数」——配置真的缺失时依然要挡住，否则会导出空壳节点
    empty = [orch_node(50, 50, has_proxy_obj=False) for _ in range(5)]
    check(C.count_qualified_nodes(empty, 'upload', 10) == 0,
          f'无配置的节点不计达标（实际 {C.count_qualified_nodes(empty, "upload", 10)}）')
    check(C.build_subscription_bundle(empty, pol)['text'] == '',
          '无配置 ⇒ 订阅文本为空，不上传空壳')

    print('== 10. 兜底不许收「运行时对象」：没有 server/port 就不是配置 ==')
    # 2026-09-26 编排轮事故：source_entry 匹配不上时，proxy_obj 回落到 mihomo
    # `/providers/proxies` 的运行时对象（只有 name/type/udp/…），用它生成的订阅
    # 客户端（Egern）加载直接报错，而日志一路正常。
    runtime_only = {'name': 'shell', 'source_entry': {},
                    'proxy_obj': {'name': 'shell', 'type': 'Vless', 'udp': True, 'uot': True,
                                  'mptcp': False, 'smux': False, 'interface': '',
                                  'routing-mark': 0, 'dialer-proxy': '', 'extra': {},
                                  'provider-name': 'gist'},
                    'ok': True, 'upload_mibs': 50.0 / 8.388608, 'download_mibs': 50.0 / 8.388608}
    check(C.node_proxy_config(runtime_only) == {}, '运行时对象不算可导出配置（返回空字典）')
    check(C.is_exportable_proxy({'type': 'trojan', 'server': 'a.com', 'port': 443}),
          'server + port 齐全 ⇒ 可导出')
    check(not C.is_exportable_proxy({'type': 'trojan', 'server': 'a.com'}),
          '只有 server、没有 port ⇒ 不可导出')
    check(not C.is_exportable_proxy({'type': 'trojan', 'port': 443}),
          '只有 port、没有 server ⇒ 不可导出')
    check(not C.is_exportable_proxy({}), '空字典不可导出')
    check(C.count_qualified_nodes([runtime_only], 'upload', 10) == 0,
          f'空壳不计达标（实际 {C.count_qualified_nodes([runtime_only], "upload", 10)}）')
    check(C.build_subscription_bundle([runtime_only], pol)['text'] == '',
          '空壳不进订阅文本（宁可判「达标不足」，也不能发布装不上的订阅）')

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
