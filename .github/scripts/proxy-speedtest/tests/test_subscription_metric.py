#!/usr/bin/env python3
"""订阅判定指标回退的自检（`speedtest_common.resolve_subscription_metric`）。

为什么单独一个文件：这条判据决定「订阅里最终有几个节点」，而它出过一次真实事故——
run 34859505000 里 19 个测过的节点**下行全部达标**，订阅里却**只有 1 个节点**。

**事故根因**：回退条件原来是「主指标达标数 < `min_nodes`」，而 `min_nodes` 默认 1
⇒ 只要主指标有 1 个达标就**永不回退**。`min_nodes` 的本意是「不足则不上传订阅」，
它不该同时充当「是否换指标」的门槛（详见 speedtest_common 里的注释）。

现在的判据只问一件事：**另一指标是不是明显更好**（`secondary > primary` 且
`secondary >= ceil(primary × ratio)`，ratio 默认 1.5）。

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
    check(pol['metric_fallback_ratio'] == 1.5, f"默认回退倍率 1.5（实际 {pol['metric_fallback_ratio']}）")

    m, q, fb = C.resolve_subscription_metric(results, pol)
    check(m == 'download', f'上行只有 1 个达标 → 回退到 download（实际 {m}）')
    check(q == 19, f'回退后达标 19 个，而不是 1 个（实际 {q}）')
    check(fb is True, '标记为已回退（fallback=True）')
    bundle = C.build_subscription_bundle(results, pol)
    check(bundle['qualified'] == 19 and bool(bundle['text']),
          f'订阅文本按 19 个节点生成（实际 {bundle["qualified"]}）')

    print('== 2. 反向：主指标明显更好时不回退 ==')
    up_good = [node(50, 5) for _ in range(10)]
    m2, q2, fb2 = C.resolve_subscription_metric(up_good, pol)
    check((m2, fb2) == ('upload', False), f'上行 10 / 下行 0 ⇒ 维持 upload（实际 {m2}/{fb2}）')
    check(q2 == 10, f'达标数取主指标（实际 {q2}）')

    print('== 3. 差距不大时尊重配置的主指标（ratio=1.5）==')
    close = [node(50, 5)] * 3 + [node(1, 50)] * 4
    m3, q3, fb3 = C.resolve_subscription_metric(close, pol)
    check((m3, fb3) == ('upload', False), f'3 vs 4 未达 1.5 倍 ⇒ 维持 upload（实际 {m3}/{fb3}）')
    pol1 = dict(pol, metric_fallback_ratio=1.0)
    m5, _q5, fb5 = C.resolve_subscription_metric(close, pol1)
    check((m5, fb5) == ('download', True), f'ratio=1（更多就换）⇒ 回退 download（实际 {m5}）')

    print('== 4. 全不达标 ⇒ 不上传（min_nodes 仍守着「不足不上传」）==')
    zero = [node(0, 0)] * 5
    m4, q4, fb4 = C.resolve_subscription_metric(zero, pol)
    check(q4 == 0, f'达标 0（实际 {q4}）')
    check(C.build_subscription_bundle(zero, pol)['text'] == '', '订阅文本为空 ⇒ 跳过上传')
    check(fb4 is False, '无达标时不做无意义的回退')

    print('== 5. min_nodes 回归本意：只管「传不传」，不管「换不换」==')
    # min_nodes=5 时：达标 3 个 < 5 ⇒ 不上传；但回退与否仍由倍率决定，与 min_nodes 无关
    pol5 = dict(pol, min_nodes=5)
    b5 = C.build_subscription_bundle(close, pol5)
    check(b5['text'] == '', f'达标 3 < min_nodes 5 ⇒ 不上传（实际 {b5["qualified"]}）')
    m6, q6, _ = C.resolve_subscription_metric(close, pol5)
    check(m6 == 'upload', 'min_nodes 提高不改变回退判据（仍是 upload）')

    print('== 6. 配置健壮性 ==')
    for raw in ('abc', '', '0', '-3', 'nan', 'inf'):
        p = C.resolve_subscription_policy({'PROXY_SPEEDTEST_METRIC_FALLBACK_RATIO': raw})
        check(p['metric_fallback_ratio'] >= 1.0,
              f'非法倍率 {raw!r} → 退回且不小于 1（实际 {p["metric_fallback_ratio"]}）')

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
