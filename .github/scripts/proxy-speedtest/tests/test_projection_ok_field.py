#!/usr/bin/env python3
"""投影层必须把 `ok` 带给订阅判定（2026-10-18 修的六天白跑回归）。

事故：commit 8ada680（2026-10-12）在共享层 `count_qualified_nodes` / 导出循环加了
`ok=True` 过滤（修「可用 0 个却导出 24 个达标节点」）。但**两个调用方**把测速结果
投影成判定层形状时**没有投影 ok 字段**：

  - `taier_speedtest.py`（三网测速）：`gist_results` 内联构造漏 `ok`
  - `speedtest.py`（镜像站口径）：同病

`item.get('ok', False)` 于是恒读 False ⇒ **每个节点都判不达标** ⇒ 每轮
`subscription_policy qualified=0` + `gist_skipped`，订阅永远不更新，而**整轮零报错**、
job 照旧 success。taier 轮每 4 小时一轮，自 10-12 03:39 到 10-18 白跑六天。

实例 run 39109181078（2026-10-18 08:45）：23 个节点里 8 个上行达标（最高 134.22 Mbps）、
10+ 个下行达标，日志仍 `qualified=0`。只有 `speedtest_gitee.py` 传的是 `ok_results`
（先过滤再进），幸免。

为什么这个测试必须 import 真实模块而不是复刻口径：坏法太隐蔽——投影**漏字段**在
语法、类型、运行期都毫无异常，只有把「真实投影 → 真实判定链」串起来跑才看得见。
两个 `to_gist_result_row` 都从这里钉。

跑法：`python .github/scripts/proxy-speedtest/tests/test_projection_ok_field.py`
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


def main():
    import speedtest_common as C
    import taier_speedtest as T
    import speedtest as S

    pol = C.resolve_subscription_policy({})
    # 显式 min_nodes=1 的策略：下面几组验的是「投影有没有漏 ok」这条回归线，与「最少传几个」
    # 无关（新默认 10 的守卫由 test_subscription_metric.py 钉）。不足 10 个成功节点的一轮，
    # 用默认 pol 时 text 为空是正确行为，不该让这组断言来验证。
    pol_min1 = dict(pol, min_nodes=1)
    proxy = {'type': 'ss', 'server': 'hk.example.com', 'port': 443}

    # ── 1. 字段存在性：投影结果必须带 'ok'（坏的写法连键都没有，看不出异常）──
    print('== 1. 两个投影函数都必须带 ok 字段 ==')
    taier_row = T.to_gist_result_row({
        'name': 'HK-01', 'ok': True, 'up': 134.22, 'down': 13.78, 'rtt': '1072ms',
        'source_entry': {'proxy': proxy}, 'proxy_obj': {},
    })
    check('ok' in taier_row, f"taier 投影含 'ok' 键（实际 {sorted(taier_row)}）")
    check(taier_row['ok'] is True, f"taier 投影 ok=True 透传（实际 {taier_row['ok']!r}）")

    speedtest_row = S.to_gist_result_row({
        'name': 'HK-01', 'ok': True,
        'download': {'ok': True, 'mibps': 13.78 / 8.388608},
        'upload': {'ok': True, 'mibps': 134.22 / 8.388608},
        'latency': {'ok': True, 'median_ms': 1072},
        'source_entry': {'proxy': proxy}, 'mode': 'push-only',
    })
    check('ok' in speedtest_row, f"speedtest 投影含 'ok' 键（实际 {sorted(speedtest_row)}）")
    check(speedtest_row['ok'] is True, f"speedtest 投影 ok=True 透传（实际 {speedtest_row['ok']!r}）")

    # ── 2. 端到端：真实投影 → 真实判定链，成功节点必须进订阅 ──
    print('== 2. 端到端：跑出速度的节点必须 qualified>0、订阅文本非空 ==')
    # 复刻 run 39109181078 的成功节点（8 个上行 ≥10Mbps + 若干下行达标）
    taier_rows = [T.to_gist_result_row({
        'name': f'HK-{i:02d}', 'ok': True, 'rtt': '1072ms',
        'up': up, 'down': down,
        'source_entry': {'proxy': dict(proxy, name=f'HK-{i:02d}')},
        'proxy_obj': {},
    }) for i, (up, down) in enumerate([
        (134.22, 13.78), (134.22, 9.96), (134.22, 13.82), (134.22, 15.51),
        (130.02, 9.96), (69.66, 9.96), (99.68, 15.61), (67.11, 14.06),
    ], 1)]
    bundle = C.build_subscription_bundle(taier_rows, pol)
    check(bundle['qualified'] == 8,
          f'taier：8 个上行达标节点全部计入（实际 {bundle["qualified"]}）')
    check(bundle['min_nodes'] == 10,
          f'taier：默认最少节点数 10（实际 {bundle["min_nodes"]}）')
    check(not (bundle['text'] or '').strip(),
          'taier：默认阈值下 8 < 10 ⇒ 不更新订阅（2026-10-19 新守卫生效）')
    bundle_p1 = C.build_subscription_bundle(taier_rows, pol_min1)
    check(bool((bundle_p1['text'] or '').strip()),
          'taier：min_nodes=1 时订阅文本非空（不会再有 qualified=0/gist_skipped）')

    ss_rows = [S.to_gist_result_row({
        'name': f'MI-{i:02d}', 'ok': True, 'mode': 'push-only',
        'source_entry': {'proxy': dict(proxy, name=f'MI-{i:02d}')},
        'download': {'ok': True, 'mibps': down / 8.388608},
        'upload': {'ok': True, 'mibps': up / 8.388608},
        'latency': {'ok': True, 'median_ms': 80},
    }) for i, (up, down) in enumerate([(120.0, 50.0), (95.0, 60.0), (60.0, 40.0)], 1)]
    bundle2 = C.build_subscription_bundle(ss_rows, pol)
    check(bundle2['qualified'] == 3,
          f'speedtest：3 个上行达标节点全部计入（实际 {bundle2["qualified"]}）')
    check(bundle2['text'].count('name:') == 0,
          'speedtest：默认阈值下 3 < 10 ⇒ 不导出（新守卫）')
    bundle2_p1 = C.build_subscription_bundle(ss_rows, pol_min1)
    check(bool((bundle2_p1['text'] or '').strip()), 'speedtest：订阅文本非空')

    # ── 3. 反向：失败/default 节点仍必须被挡住（ok=False 不得进订阅）──
    print('== 3. 反向：失败节点不得进订阅（10-12 修的口径不能被投影环节绕开）==')
    failed = [T.to_gist_result_row({
        'name': f'FAIL-{i}', 'ok': False, 'up': 100.0, 'down': 100.0, 'rtt': '120ms',
        'source_entry': {'proxy': dict(proxy, name=f'FAIL-{i}')}, 'proxy_obj': {},
    }) for i in range(5)]
    check(C.count_qualified_nodes(failed, 'upload', 10) == 0,
          'taier：ok=False 的节点不计达标（速度再高也不行）')
    b3 = C.build_subscription_bundle(failed, pol)
    check(b3['qualified'] == 0 and not (b3['text'] or '').strip(),
          f'taier：全失败一轮不产出订阅（实际 qualified={b3["qualified"]}）')

    failed_ss = [S.to_gist_result_row({
        'name': f'FAIL-{i}', 'ok': False, 'mode': 'download',
        'source_entry': {'proxy': dict(proxy, name=f'FAIL-{i}')},
        'download': {'ok': False, 'mibps': None},
        'upload': {'ok': False, 'mibps': None},
        'latency': {'ok': False, 'median_ms': None},
    }) for i in range(5)]
    check(C.count_qualified_nodes(failed_ss, 'download', 10) == 0,
          'speedtest：ok=False 的节点不计达标')

    # ── 4. 混合轮：只有成功节点进订阅（这次事故的另一面：订阅内容是可信的）──
    print('== 4. 混合轮：失败 + 成功 ⇒ 只有成功节点进订阅 ==')
    mixed = failed[:4] + [T.to_gist_result_row({
        'name': 'OK-1', 'ok': True, 'up': 120.0, 'down': 50.0, 'rtt': '300ms',
        'source_entry': {'proxy': dict(proxy, name='OK-1')}, 'proxy_obj': {},
    })]
    b4 = C.build_subscription_bundle(mixed, pol)
    check(b4['qualified'] == 1, f'混合轮达标 1 个（实际 {b4["qualified"]}）')
    check(b4['text'].count('name:') == 0,
          f'默认阈值下 1 < 10 ⇒ 不导出（实际 {b4["text"].count("name:")}）')
    b4_p1 = C.build_subscription_bundle(mixed, pol_min1)
    check(b4_p1['text'].count('name:') == 1,
          f'min_nodes=1 时导出 YAML 只含 1 个成功节点（实际 {b4_p1["text"].count("name:")}）')

    # ── 5. 病根钉死：漏 ok 字段的投影必须让判定归零（证明这道闸真的有效）──
    print('== 5. 病根回归：漏 ok 的旧写法会让判定归零 ==')
    legacy_projection = [{k: v for k, v in row.items() if k != 'ok'} for row in taier_rows]
    b5 = C.build_subscription_bundle(legacy_projection, pol)
    check(b5['qualified'] == 0,
          f'漏 ok 字段 ⇒ 8 个达标节点被判 0（实际 {b5["qualified"]}）—— 这次事故的口径')
    check(T.to_gist_result_row({'name': 'x', 'ok': False, 'up': 50, 'down': 50})['ok'] is False,
          'ok=False 同样透传（不是恒 True 的假修）')

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
