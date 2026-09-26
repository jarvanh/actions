#!/usr/bin/env python3
"""订阅判定指标回退的自检（`speedtest_common.resolve_subscription_metric`）。

为什么单独一个文件：这条判据决定「订阅里最终有几个节点」，而它出过一次真实事故——
run 34859505000 里 19 个测过的节点**下行全部达标**，订阅里却**只有 1 个节点**。

**事故根因**：回退条件原来是「主指标达标数 < `min_nodes`」，而 `min_nodes` 默认 1
⇒ 只要主指标有 1 个达标就**永不回退**。`min_nodes` 的本意是「不足则不上传订阅」，
它不该同时充当「是否换指标」的门槛（详见 speedtest_common 里的注释）。

现在的判据：**主指标达标数 < 回退门槛**（`PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES`，
默认 3）**且另一指标更多**时才改判另一指标。门槛单列、与 `min_nodes` 彻底脱钩
（2026-09-17 从倍率制改回计数制并按此解耦）。

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


def node(up_mbps, down_mbps, with_proxy=True):
    """按 taier 的单位换算构造一条结果：Mbps / 8.388608 = MiB/s（与 taier_speedtest 一致）。"""
    return {'name': 'n', 'source_entry': {'proxy': {'type': 'vless'}} if with_proxy else {},
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
    check(pol['metric_fallback_min_nodes'] == 3,
          f"默认回退门槛 3（实际 {pol['metric_fallback_min_nodes']}）")

    m, q, fb = C.resolve_subscription_metric(results, pol)
    check(m == 'download', f'上行只有 1 个达标（< 3）⇒ 回退到 download（实际 {m}）')
    check(q == 19, f'回退后达标 19 个，而不是 1 个（实际 {q}）')
    check(fb is True, '标记为已回退（fallback=True）')
    bundle = C.build_subscription_bundle(results, pol)
    check(bundle['qualified'] == 19 and bool(bundle['text']),
          f'订阅文本按 19 个节点生成（实际 {bundle["qualified"]}）')

    print('== 2. 反向：主指标达标数 ≥ 门槛 ⇒ 维持配置的主指标 ==')
    up_good = [node(50, 5) for _ in range(10)]
    m2, q2, fb2 = C.resolve_subscription_metric(up_good, pol)
    check((m2, fb2) == ('upload', False), f'上行 10（≥ 3）/ 下行 0 ⇒ 维持 upload（实际 {m2}/{fb2}）')
    check(q2 == 10, f'达标数取主指标（实际 {q2}）')

    print('== 3. 门槛之上即使另一指标更多也不换（尊重配置的主指标）==')
    close = [node(50, 5)] * 3 + [node(1, 50)] * 10
    m3, q3, fb3 = C.resolve_subscription_metric(close, pol)
    check((m3, fb3) == ('upload', False),
          f'上行 3（= 门槛，未「小于」）/ 下行 10 ⇒ 维持 upload（实际 {m3}/{fb3}）')
    check(q3 == 3, f'达标数仍是主指标的 3（实际 {q3}）')
    pol1 = dict(pol, metric_fallback_min_nodes=4)
    m5, _q5, fb5 = C.resolve_subscription_metric(close, pol1)
    check((m5, fb5) == ('download', True),
          f'门槛提到 4 后 3 < 4 ⇒ 回退 download（实际 {m5}）')

    print('== 3b. 门槛达标但另一指标更少 ⇒ 绝不回退（换了反而更差）==')
    fewer = [node(50, 5)] * 2 + [node(1, 50)] * 1
    pol2 = dict(pol, metric_fallback_min_nodes=5)
    m7, q7, fb7 = C.resolve_subscription_metric(fewer, pol2)
    check((m7, fb7) == ('upload', False),
          f'上行 2 < 5 但下行只有 1 ⇒ 维持 upload（实际 {m7}/{fb7}）')
    check(q7 == 2, f'达标数取主指标（实际 {q7}）')

    print('== 4. 全不达标 ⇒ 不上传（min_nodes 仍守着「不足不上传」）==')
    zero = [node(0, 0)] * 5
    m4, q4, fb4 = C.resolve_subscription_metric(zero, pol)
    check(q4 == 0, f'达标 0（实际 {q4}）')
    check(C.build_subscription_bundle(zero, pol)['text'] == '', '订阅文本为空 ⇒ 跳过上传')
    check(fb4 is False, '无达标时不做无意义的回退')

    print('== 5. min_nodes 回归本意：只管「传不传」，不管「换不换」==')
    # min_nodes=5 时：达标 3 个 < 5 ⇒ 不上传；回退判据仍只看门槛（默认 3，3 不小于 3）⇒ 维持 upload
    pol5 = dict(pol, min_nodes=5)
    b5 = C.build_subscription_bundle(close, pol5)
    check(b5['text'] == '', f'达标 3 < min_nodes 5 ⇒ 不上传（实际 {b5["qualified"]}）')
    m6, q6, _ = C.resolve_subscription_metric(close, pol5)
    check(m6 == 'upload', 'min_nodes 提高不改变回退判据（仍是 upload）')

    print('== 6. 配置健壮性 ==')
    for raw, want in (('abc', 3), ('', 3), ('0', 1), ('-3', 1), ('7', 7)):
        p = C.resolve_subscription_policy({'PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES': raw})
        check(p['metric_fallback_min_nodes'] == want,
              f'门槛 {raw!r} → {want}（实际 {p["metric_fallback_min_nodes"]}）')

    print('== 7. 可导出配置回落 proxy_obj（run 35116972319：206 个达标节点被判 0）==')
    # 编排轮形态：节点由 gistnodes 经 provider 直接喂进来，source_mapping 只有 4 条 ⇒
    # source_entry 匹配不上为空，配置全在 proxy_obj 里。旧实现只认 source_entry.proxy
    # ⇒ 206 个实测有速度的节点（最高 245 Mbps）全被判「无可用配置」⇒ 达标 0 ⇒ 不上传。
    # ⚠️ 但兜底**不是「什么都能收」**——proxy_obj 有两种来路，只有真配置能导出，
    # 见第 10 组与 speedtest_common.is_exportable_proxy。
    def orch_node(up_mbps, down_mbps, has_proxy_obj=True):
        return {'name': 'n', 'source_entry': {},
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

    print('== 8. source_entry.proxy 优先于 proxy_obj（前者是更权威的来源）==')
    both = {'name': 'n',
            'source_entry': {'proxy': {'type': 'trojan', 'server': 'from-entry.com', 'port': 443}},
            'proxy_obj': {'type': 'vless', 'server': 'from-obj.com', 'port': 80},
            'upload_mibs': 20.0 / 8.388608, 'download_mibs': 20.0 / 8.388608}
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
                    'upload_mibs': 50.0 / 8.388608, 'download_mibs': 50.0 / 8.388608}
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
