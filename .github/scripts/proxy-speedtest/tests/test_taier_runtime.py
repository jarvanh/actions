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
  另有一类更隐蔽的：**mihomo 的 provider 是惰性展开的**——`/providers/proxies` 给的是
  声明清单，节点尚未注册进 `/proxies/{name}` 时探测会拿到 `Resource not found`
  （本地 404，实测间隔 ~18.7ms，远小于 3000ms 超时）。run 35116972319 里这被误判成
  「前 8 个节点都死了」并触发熔断。第 9 组钉住两件事：开测前 `wait_provider_ready()`
  等展开、以及 `is_unknown_proxy_error()` 把这类错误与「真连不上」分开（fail-open 放行）。
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


def _parse_alive_probe(raw):
    """按脚本同一口径解析测活开关：只有 0/false/no/off 才算关。

    真源是 `taier_speedtest.CONFIG['TAIER_ALIVE_PROBE']` 里那行黑名单判断；这里复刻一份
    是为了能验「显式关闭」——CONFIG 是导入时求值的，改不了 env 重算。
    """
    return raw.strip().lower() not in ('0', 'false', 'no', 'off')


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
        # 组名（AUTO）不是节点：mihomo 回 404 `Resource not found`，会被当成「判死」。
        # 2026-09-15 编排轮就是这么把 8/8 节点全跳过、整轮零产出的——探测必须传节点名。
        okv, _d, err = t.probe_node_alive('AUTO', 'http://x', 3000)
        check(okv is False and 'not found' in err.lower(),
              f'对 AUTO 组名探测 → mihomo 回 not found（反证必须用节点名，实际 {okv}/{err}）')

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
    # 测活**默认开启**（2026-09-15 改回）：目的就是「死节点别占掉 25 秒窗口」。
    # run 34859505000 曾出现 27 个节点全部误杀（节点名在 mihomo 里对不上），
    # 但那条路径由熔断（连续 8 个未通过即关探测）与 fail-open 兜住，不值得为此默认牺牲收益。
    check(t.CONFIG['TAIER_ALIVE_PROBE'] is True, '默认开启测活（省下死节点的 25 秒窗口）')
    check('cnspeedtest' in t.CONFIG['TAIER_ALIVE_PROBE_URL'],
          f"默认探测目标对准泰尔控制面（实际 {t.CONFIG['TAIER_ALIVE_PROBE_URL']}）")
    # 显式关闭仍须生效（误杀现场要能一键退回纯测速）
    check(_parse_alive_probe('0') is False, 'TAIER_ALIVE_PROBE=0 可显式关闭')
    check(_parse_alive_probe('off') is False, 'TAIER_ALIVE_PROBE=off 可显式关闭')

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

    print('== 7. 测活探测失败不得混进「❌ 失败」（与节点故障区分）==')
    # 2026-09-16 编排轮 35116972319：8 条 `Resource not found` 全挤在 0.13 秒内，
    # 是 mihomo 控制面调用失败、节点根本没被真正探测过。旧实现把它们塞进 ❌ 失败清单，
    # 读者只会以为 8 个节点是坏的。现在必须单独成节、且明确说「不计入失败」。
    probe_dead = [{'ok': False, 'bypass': False, 'up': 0.0, 'down': 0.0, 'name': f'p{i}',
                   'probe_failed': True, 'error': '测活未通过：Resource not found'}
                  for i in range(8)]
    real_dead = [{'ok': False, 'bypass': False, 'up': 0.0, 'down': 0.0, 'name': f'd{i}',
                  'error': '连不上测速点 广东联通（延迟/上下行全空）'} for i in range(3)]
    mixed = render(probe_dead + real_dead)
    joined = '\n'.join(str(x) for x in mixed)
    check('⚠️ 测活探测异常 · 8' in joined, f'探测失败单独成节（实际标题缺失）')
    check('不计入失败' in joined, '明确交代「不计入失败」')
    check('❌ 失败 · 3' in joined,
          f'❌ 失败只数真正的失败（实际应为 3，即 {[x for x in mixed if "❌ 失败" in str(x)]}）')
    check(not any('Resource not found' in str(x) and str(x).strip().startswith('├─')
                  for x in mixed), '误报条目不再出现在树形清单里')

    # 负向对照：没有探测失败时，不得凭空出现该分节
    only_real = render(real_dead)
    check(not any('测活探测异常' in str(x) for x in only_real),
          '无探测失败 → 不出现该分节（负向对照）')

    print('== 8. 「未更新订阅」按真因分文案（不把实现故障说成节点不达标）==')
    # 同样来自 run 35116972319：206 个节点实测有速度（最高 245 Mbps）却报「达标不足」。
    # 三种真因必须分开：真达标不足 / 有速度但缺可导出配置 / 达标不足+到点收摊（带范围）。
    cfg = {'proxy': {'type': 'vless', 'server': 'x.com'}}

    def sub_line(results, ctotal=0, aborted=False, rsn=''):
        ls = t.build_telegram_lines(results, meta, '1.2.3.4', 0, None, {}, {},
                                    aborted_due_to_runtime=aborted,
                                    runtime_abort_reason=rsn, collected_total=ctotal)
        return [str(x) for x in ls if '未更新订阅' in str(x)][0]

    slow_ok = [{'ok': True, 'bypass': False, 'up': 0.5, 'down': 0.5, 'name': f's{i}',
                'source_entry': cfg, 'proxy_obj': {}} for i in range(10)]
    check('达标不足' in sub_line(slow_ok), '慢但有配置 ⇒ 报「达标不足」（真·节点不行）')

    fast_noconf = [{'ok': True, 'bypass': False, 'up': 245.24, 'down': 130.53, 'name': f'c{i}',
                    'source_entry': {}, 'proxy_obj': {}} for i in range(10)]
    l2 = sub_line(fast_noconf)
    check('缺少可导出配置' in l2, f'快但无配置 ⇒ 报「缺少可导出配置」（实现层问题，实际 {l2}）')
    check('达标不足' not in l2, '这条不得再写「达标不足」误导读者去怀疑节点')

    l3 = sub_line(slow_ok, ctotal=8326, aborted=True,
                  rsn='到点收摊：预算 5 小时 0 分，已测 10/8326 个节点')
    check('预算内仅测完 10/8326' in l3, f'到点收摊时交代「测了多少/共多少」（实际 {l3}）')
    check('未达' not in l3 or '达标不足' in l3, '中止范围是补充说明，不改变原结论')

    print('== 9. provider 惰性展开：等就绪 + 404 不判死（方案 C，run 35116972319 根因）==')
    # 事故取证：那 8 条 `Resource not found` 每两次间隔恒为 ~18.7ms（`.016`→`.147`），
    # 远小于 3000ms 的探测超时 ⇒ 是本地 HTTP 往返，mihomo 压根没连节点、只是
    # `/proxies/{name}` 里查不到名字。根因是读 `/providers/proxies`（声明清单）后
    # 仅 20ms 就开始探测，而节点尚未注册进路由表（16 秒后第一个测速结果才出现）。
    import urllib.error

    class _404(urllib.error.HTTPError):
        def __init__(self):
            super().__init__('u', 404, 'Not Found', {}, None)

    # 9a. 判据：认「不认识这个名字」，不认「连不上」
    for err, exp in [('Resource not found', True), ('no such proxy', True),
                     ('timeout', False), ('connection refused', False),
                     ('无延迟值（连不上）', False), ('', False)]:
        check(t.is_unknown_proxy_error(err) is exp,
              f'unknown 判据 {err!r} → {exp}（实际 {t.is_unknown_proxy_error(err)}）')

    # 9b. 等就绪：前 2 次 404、第 3 次查到 ⇒ 就绪
    _orig_get, _orig_sleep, _orig_log = t.mihomo_api_get, t.time.sleep, t.log_progress
    st = {'n': 0}
    ev9 = []
    try:
        t.time.sleep = lambda s: None
        t.log_progress = lambda stage, **kw: ev9.append((stage, kw))

        def flaky_get(path):
            st['n'] += 1
            if st['n'] < 3:
                raise _404()
            return {'name': 'n0'}

        t.mihomo_api_get = flaky_get
        ready, _waited, probed = t.wait_provider_ready(['n0', 'n1', 'n2', 'n3'], timeout=10)
        check(ready is True, '未就绪→就绪时返回 True')
        check(probed in ('n0', 'n1', 'n2', 'n3'), f'报出探测用的哨兵名（实际 {probed!r}）')
        check([e[0] for e in ev9] == ['taier_provider_ready'],
              f'记一条 provider_ready 便于观测（实际 {[e[0] for e in ev9]}）')

        # 9c. 超时：始终 404 ⇒ False，且不抛异常（调用方据此降级）
        t.mihomo_api_get = lambda path: (_ for _ in ()).throw(_404())
        ev9.clear()
        ready, _w, probed = t.wait_provider_ready(['a', 'b'], timeout=0.3)
        check(ready is False and probed == '', '始终未就绪 → False（不抛异常）')
        check([e[0] for e in ev9] == ['taier_provider_ready_timeout'],
              '超时要留痕，否则「等过但没等到」看不出来')

        # 9d. 空名单：不等待、不请求
        calls9 = []
        t.mihomo_api_get = lambda path: calls9.append(path) or {}
        check(t.wait_provider_ready([], timeout=5) == (False, 0.0, '')
              and t.wait_provider_ready(['', '  '], timeout=5) == (False, 0.0, ''),
              '空/空白名单直接返回 False')
        check(calls9 == [], '空名单不发任何请求（省掉必然失败的调用）')
    finally:
        t.mihomo_api_get, t.time.sleep, t.log_progress = _orig_get, _orig_sleep, _orig_log

    # 9e. 撤销判死：原地改 results / alive_items，返回条数
    r9 = [{'name': 'p0', 'probe_failed': True, 'ok': False},
          {'name': 'p1', 'probe_failed': True, 'ok': False},
          {'name': 'real', 'ok': False}]
    a9 = [{'name': 'p0'}, {'name': 'p1'}, {'name': 'other'}]
    q9 = [{'name': 'p0'}, {'name': 'p1'}]
    n9 = t._revive_probe_failed(r9, a9, q9)
    check(n9 == 2, f'返回撤销条数（实际 {n9}）')
    check([x['name'] for x in r9] == ['real'],
          f'伪造的「测活未通过」条目被摘掉、真失败保留（实际 {[x["name"] for x in r9]}）')
    check([x['name'] for x in a9] == ['p0', 'p1', 'other', 'p0', 'p1'],
          f'撤销的节点回到测速队列（实际 {[x["name"] for x in a9]}）')
    check(q9 == [], '队列清空（避免下一轮重复撤销）')
    check(t._revive_probe_failed(r9, a9, []) == 0, '空队列 → 返回 0、不改动')

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
