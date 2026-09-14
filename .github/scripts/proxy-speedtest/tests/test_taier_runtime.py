#!/usr/bin/env python3
"""四套测速的运行时收口自检：墙钟预算（到点收摊）+ 测活 + 通知降级。

为什么单独一个文件：`test_gist_nodes_substore.py` 覆盖的是 gist 抓取→Sub-Store 那一段，
而这三块长在测速引擎的节点循环里，两边互不相干。

覆盖范围（2026-09-14 扩到四套）：墙钟判据本身（`speedtest_common` 提供，四套共用）、
taier 的测活、以及 **taier / gitee / cdn 三套**通知的降级渲染。

为什么必须被自检（各块的坏法）：

- **墙钟预算**：最典型的是恒真或恒假。恒真 ⇒ 第一个节点之后就收摊（表现为「怎么只测了
  0 个」）；恒假 ⇒ 预算形同虚设（表现为照旧撞 job 的 360 分钟硬取消，整轮工作全废）。
  另外「非正数算不算不限」必须与 `speedtest_budget_deadline()` 同口径，否则同一份配置
  经 deadline 是「不限」、直接传进来却是「立即停」。
- **测活**：最危险的是 **fail-open 写反**——把「探测机制挂了」当成「节点死了」，
  整轮会一个节点都不测。那比在死节点上多花 25 秒糟得多，所以单独验。
- **通知降级**：`aborted_due_to_runtime` 传错、或标题降级写反，会让「到点收摊」看起来
  像一次正常完成，读者无从判断这轮到底测完了没有。三套的**行位置也必须一致**。

跑法：`python .github/scripts/proxy-speedtest/tests/test_taier_runtime.py`
退出码 0 = 全过。
"""
import http.server
import pathlib
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def main():
    import speedtest_common as c
    import speedtest_gitee as g
    import taier_speedtest as t

    print('== 1. 到点收摊判据（should_stop_for_budget）==')
    check(t.should_stop_for_budget(None) is False, '不限（None）→ 永不停')
    check(t.should_stop_for_budget(0) is False, '不限（0）→ 永不停')
    check(t.should_stop_for_budget(100.0, now=99.9) is False, '未到点 → 继续')
    check(t.should_stop_for_budget(100.0, now=100.1) is True, '已过点 → 收摊')
    # 边界：正好到点必须收摊（判据是 >=，不是 >）。写成 > 会让边界附近永远多跑一个节点。
    check(t.should_stop_for_budget(100.0, now=100.0) is True, '正好到点 → 收摊（边界取 >=）')
    # 非正数一律「不限」：必须与 speedtest_budget_deadline() 的归一化同口径。
    # 若这里按 truthy 判，-1 会被当成「已过期」而立刻收摊，同一份配置经 deadline 是
    # 「不限」、直接传进来却是「立即停」——两边不一致就是下一次踩的坑。
    check(t.should_stop_for_budget(-1.0, now=0.0) is False, '负 deadline → 不限（与 deadline 归一化同口径）')
    check(c.speedtest_budget_deadline(-1) is None, '负预算 → deadline 为 None（不限）')
    check(c.speedtest_budget_deadline('abc') is None, '非法预算 → None（不静默变成魔数）')
    check(c.speedtest_budget_deadline(60, now=100.0) == 160.0, 'deadline = now + 预算秒数')
    check(t.should_stop_for_budget(c.speedtest_budget_deadline(0)) is False,
          '两端一致：0 预算经 deadline 后仍为「不限」')

    print('== 2. 测活：先测活再测速（probe_node_alive）==')

    class FakeMihomo(http.server.BaseHTTPRequestHandler):
        """只实现 /proxies/{name}/delay，按节点名返回四种状态。"""

        def log_message(self, *a):
            pass

        def do_GET(self):
            code, body = 200, b'{}'
            if '/proxies/alive/delay' in self.path:
                body = b'{"delay": 123}'
            elif '/proxies/dead/delay' in self.path:
                code, body = 400, b'{"message": "get delay: dial tcp: i/o timeout"}'
            elif '/proxies/nodelay/delay' in self.path:
                body = b'{"message": "no delay"}'
            else:
                code, body = 404, b'{"message": "not found"}'
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeMihomo)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    _saved_api = t.MIHOMO_API
    t.MIHOMO_API = f'http://127.0.0.1:{srv.server_address[1]}'
    try:
        okv, d, err = t.probe_node_alive('alive', 'http://x', 3000)
        check(okv is True and d == 123, f'有 delay → 存活（实际 {okv}/{d}/{err}）')
        okv, _d, err = t.probe_node_alive('dead', 'http://x', 3000)
        check(okv is False and 'timeout' in err, f'mihomo 判连不上 → 死（实际 {okv}/{err}）')
        okv, _d, err = t.probe_node_alive('nodelay', 'http://x', 3000)
        check(okv is False, f'200 但没有 delay → 死（实际 {okv}/{err}）')

        # ⚠️ 最关键的一条：探测机制本身挂了必须**按存活处理**（fail-open）。
        # 判反了会让整轮一个节点都不测——比在死节点上多花 25 秒糟得多。
        t.MIHOMO_API = 'http://127.0.0.1:1'  # 没人监听
        okv, _d, err = t.probe_node_alive('whatever', 'http://x', 3000)
        check(okv is True, f'连不上 mihomo → fail-open 判活（实际 {okv}/{err}）')
        check('按存活处理' in err, f'fail-open 要在原因里写清楚（实际 {err}）')
    finally:
        t.MIHOMO_API = _saved_api
        srv.shutdown()

    print('== 3. 通知：标题降级 + 正文补一行 ==')

    class Meta(dict):
        def __missing__(self, k):
            return '—'

    meta = Meta(started_text='2026-09-14 20:00:00', ended_text='2026-09-14 20:05:00',
                duration_text='5分00秒', points='广东联通', mode_label='只测单线程')
    ok_node = [{'ok': True, 'bypass': False, 'up': 100.0, 'down': 200.0, 'latency': 30}]
    reason = '到点收摊：预算 5小时0分0秒，已测 12/3284 个节点'

    def render(results, **kw):
        return t.build_telegram_lines(results, meta, '1.2.3.4', 0, None, {}, **kw)

    # 负向对照先行：不传标志时必须**没有**中止行、标题是 ✅——否则下面的断言可能恒真
    plain = render(ok_node)
    check(plain[0] == '✅ 泰尔三网测速', f'未中止 → 标题 ✅（实际 {plain[0]}）')
    check(not any('本轮已中止' in str(x) for x in plain),
          '未中止 → 正文不出现「本轮已中止」（负向对照）')

    aborted = render(ok_node, aborted_due_to_runtime=True, runtime_abort_reason=reason)
    check(aborted[0] == '⚠️ 泰尔三网测速',
          f'有可用节点但到点收摊 → 标题降 ⚠️（实际 {aborted[0]}）')
    joined = '\n'.join(str(x) for x in aborted)
    check(f'⚠️ 本轮已中止：{reason}' in joined,
          '正文补一行「⚠️ 本轮已中止：<原因>」且原因原样带入')
    idx_nodes = next((i for i, x in enumerate(aborted) if str(x).startswith('📊 节点')), -1)
    check(idx_nodes >= 0 and '本轮已中止' in str(aborted[idx_nodes + 1]),
          '中止行紧跟「📊 节点」行（先看到测了多少，再看到为什么停）')

    empty = render([])
    check(empty[0] == '⚠️ 泰尔三网测速', f'0 可用节点 → 标题 ⚠️（实际 {empty[0]}）')

    print('== 4. 默认值与 job 上限的关系 ==')
    budget = t.CONFIG['TAIER_BUDGET_SECONDS']
    check(budget == 18000, f'默认预算 18000 秒 = 5 小时（实际 {budget}）')
    # job 不设 timeout-minutes ⇒ GitHub 默认 360 分钟 = 21600 秒。预算必须**显著**小于它：
    # 到点后还要留出订阅导出 / 通知 / Gist 提交的时间，否则「收摊」了也来不及把订阅链接
    # 提交到 Gist —— 那和撞硬取消没区别。
    check(budget < 21600, '预算 < job 默认上限 360 分钟')
    check(21600 - budget >= 3600, '预算与上限之间留够 ≥1 小时（前置准备 + 订阅导出/通知/Gist）')
    # 测活**默认关闭**：run 34859505000 真机验证过，27 个节点全部 `Resource not found`
    # （节点名在 mihomo 里对不上），前 8 个被误杀。在查清名字为什么对不上之前保持关闭。
    check(t.CONFIG['TAIER_ALIVE_PROBE'] is False, '默认关闭测活（真机验证：会误杀活节点）')
    check('cnspeedtest' in t.CONFIG['TAIER_ALIVE_PROBE_URL'],
          f"开启时探测目标默认对准泰尔控制面（实际 {t.CONFIG['TAIER_ALIVE_PROBE_URL']}）")

    print('== 5. 四套共用同一份判据（单一来源，防各写一遍后漂移）==')
    # 用户诉求是「这 4 个测速任务都不触及 360 分钟」，所以三套引擎必须**同一口径**。
    # 断言函数对象相同（不是「行为相同」）：行为相同的两份实现，下一次改一处就会漂。
    import speedtest as d
    check(t.should_stop_for_budget is c.should_stop_for_budget, 'taier 复用共享判据')
    check(g.should_stop_for_budget is c.should_stop_for_budget, 'gitee 复用共享判据')
    check(d.should_stop_for_budget is c.should_stop_for_budget, 'cdn 复用共享判据')
    check(t.speedtest_budget_deadline is c.speedtest_budget_deadline, 'taier 复用共享 deadline')
    check(g.speedtest_budget_deadline is c.speedtest_budget_deadline, 'gitee 复用共享 deadline')
    check(d.speedtest_budget_deadline is c.speedtest_budget_deadline, 'cdn 复用共享 deadline')
    # 默认值也必须来自共享常量（防止某处又写死成别的数）
    check(budget == c.DEFAULT_BUDGET_SECONDS, 'taier 默认值取自共享常量')
    check(d.CONFIG['PROXY_SPEEDTEST_BUDGET_SECONDS'] == c.DEFAULT_BUDGET_SECONDS,
          'cdn 默认值取自共享常量')
    check(c.DEFAULT_BUDGET_SECONDS < 21600 and 21600 - c.DEFAULT_BUDGET_SECONDS >= 3600,
          '共享默认值本身满足「严格小于 360 分钟且留 ≥1 小时」')

    print('== 6. gitee / cdn 通知也降级（三套交付物同一位置）==')
    # 三套通知是同一份交付物：同一条信息「本轮没测完」落在不同位置，会让读者以为看漏了。
    ok_item = {'name': 'n1', 'ok': True, 'download_mibs': 12.0, 'upload_mibs': 0,
               'latency_ms': 100, 'source_entry': {}, 'mode': 'download'}
    gcommon = dict(started_at='2026-09-14T10:00:00', ended_at='2026-09-14T10:05:00',
                   duration_text='5m0s', alive_probe_count=3284, ok_results=[ok_item],
                   speed_results=[ok_item], speedtest_mode='download',
                   ok_results_by_download=[ok_item], metric_label='下载')
    # 负向对照先行：不传标志时不得出现中止行、标题必须 ✅
    g_plain = g.build_summary_lines(aborted_due_to_runtime=False, runtime_abort_reason='', **gcommon)
    check(g_plain[0].startswith('✅'), f'gitee 未中止 → 标题 ✅（实际 {g_plain[0]}）')
    check(not any('本轮已中止' in str(x) for x in g_plain),
          'gitee 未中止 → 无中止行（负向对照）')
    g_ab = g.build_summary_lines(aborted_due_to_runtime=True, runtime_abort_reason=reason, **gcommon)
    check(g_ab[0].startswith('⚠️'), f'gitee 到点收摊 → 标题 ⚠️（实际 {g_ab[0]}）')
    gi = next((i for i, x in enumerate(g_ab) if str(x).startswith('📊 节点')), -1)
    check(gi >= 0 and '本轮已中止' in str(g_ab[gi + 1]),
          'gitee 中止行紧跟「📊 节点」（与 taier / cdn 同位置）')

    c_meta = {'started_at': '2026-09-14T10:00:00', 'ended_at': '2026-09-14T10:05:00',
              'mode': '延迟+下载', 'size_mib': 10, 'latency_samples': 4,
              'download_timeout': 30, 'push': False, 'download_hosts': []}
    c_item = {'name': 'n1', 'ok': True, 'provider': 'p', 'source_entry': {},
              'latency': {'ok': True, 'median_ms': 100}, 'download': {'ok': True, 'mibps': 12.0},
              'upload': {'ok': False, 'mibps': 0}}
    c_bundle = {'qualified': 1, 'min_megabit': 10, 'min_nodes': 1, 'metric': 'upload',
                'metric_mode': 'download', 'metric_label': '下载'}
    c_gist = {'ok': True, 'html_url': 'x', 'yaml': {'raw_url': 'y'}}
    c_plain = d.build_telegram_lines([c_item], meta=c_meta, gist_res=c_gist, bundle=c_bundle)
    check(c_plain[0].startswith('✅'), f'cdn 未中止 → 标题 ✅（实际 {c_plain[0]}）')
    check(not any('本轮已中止' in str(x) for x in c_plain),
          'cdn 未中止 → 无中止行（负向对照）')
    c_ab = d.build_telegram_lines([c_item], meta=c_meta, gist_res=c_gist, bundle=c_bundle,
                                  aborted_due_to_runtime=True, runtime_abort_reason=reason)
    check(c_ab[0].startswith('⚠️'), f'cdn 到点收摊 → 标题 ⚠️（实际 {c_ab[0]}）')
    ci = next((i for i, x in enumerate(c_ab) if str(x).startswith('📊 节点')), -1)
    check(ci >= 0 and '本轮已中止' in str(c_ab[ci + 1]),
          'cdn 中止行紧跟「📊 节点」（与 taier / gitee 同位置）')
    # HTML 转义：原因里的尖括号不得漏进 HTML（通知是 HTML 模式）
    c_esc = d.build_telegram_lines([c_item], meta=c_meta, gist_res=c_gist, bundle=c_bundle,
                                   aborted_due_to_runtime=True, runtime_abort_reason='<b>x</b>')
    check(any('&lt;b&gt;x&lt;/b&gt;' in str(x) for x in c_esc) and
          not any('<b>x</b>' in str(x) for x in c_esc),
          'cdn 中止原因经过 HTML 转义')

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
