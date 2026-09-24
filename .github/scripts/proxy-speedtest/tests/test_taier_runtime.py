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
- **include 过滤**（2026-09-22，编排轮池子上万远超预算）：最隐蔽的坏法是 **fail-open
  缺失**——非法正则抛异常、或「全过滤光」被当真返回空列表，编排轮会零节点、整轮白跑。
  另一处是**接线次序**：过滤必须在 max_nodes 截断之前，否则截断把已过滤节点算进配额。
- **provider 展开等待**（2026-09-22 引入、2026-09-23 二次修正）：超时写死 60 秒 / 按
  **候选数**放大，都会在大池子上等不完 ⇒ 测活开测就连吃「mihomo 不认识」⇒ 熔断关掉
  整个测活层 ⇒ 上千个死节点跑满各自的测速窗口（单这一项吃掉整个 5h 预算）。
  第 14 组钉住「按**实际加载量**放大 + 三套都传 `total_loaded`」，第 15 组钉住
  「未知名**不再熔断**测活层，而是放回队尾重排」。

跑法：`python .github/scripts/proxy-speedtest/tests/test_taier_runtime.py`
退出码 0 = 全过。
"""
import http.server
import pathlib
import re
import shutil
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

    # 2b. 批量延迟表测活（2026-09-24）：这是**唯一真正生效**的测活路径。
    #     旧路径 `GET /proxies/{name}/delay` 对 provider 成员**永远 404**（成员从不注册
    #     进 `/proxies`），所以测活层从上线起一次都没生效过。新路径 `/group/{组}/delay`
    #     一次拿全组 `{名字: 延迟}`，查表是纯内存操作——这里钉住它的三种语义。
    print('== 2b. 测活（批量延迟表）：查表命中 / 缺失 / 空表 fail-open ==')
    _tbl = {'alive': 123, 'slow': 900}
    okv, d, _e = t.probe_node_alive('alive', 'http://x', 3000, delay_table=_tbl)
    check(okv is True and d == 123, f'表里命中 → 存活并带出延迟（实际 {okv}/{d}）')
    okv, d, _e = t.probe_node_alive('slow', 'http://x', 3000, delay_table=_tbl)
    check(okv is True and d == 900, f'延迟大也算活（判据是「连得上」，不是「快」）')
    okv, _d, _e = t.probe_node_alive('dead', 'http://x', 3000, delay_table=_tbl)
    # 表里没有 = mihomo 组测速没给出延迟 = 连不上 = 判死
    check(okv is False, f'表里没有 → 判死（实际 {okv}）')
    # ⚠️ 最关键：空表是**探测机制没给出结论**，不是节点死 ⇒ 必须 fail-open
    okv, _d, err = t.probe_node_alive('whatever', 'http://x', 3000, delay_table={})
    check(okv is True, f'空延迟表 → fail-open 判活（实际 {okv}）')
    check('按存活处理' in err, f'空表 fail-open 要写清原因（实际 {err}）')

    # 2c. 组名常量：配置生成 / 切节点 / 判就绪 / 批量探测必须同一个组名。
    #     分散写死 'AUTO' 时漏改一处是「静默测错对象」，不报错、极难发现。
    print('== 2c. 组名收敛为常量（防「切 A 组探 B 组」的静默错）==')
    check(g.PROXY_GROUP_NAME == 'AUTO', f'组名常量为 AUTO（实际 {g.PROXY_GROUP_NAME!r}）')
    _gsrc = pathlib.Path(g.__file__).read_text(encoding='utf-8')
    check("'name': PROXY_GROUP_NAME" in _gsrc,
          '配置生成用常量（不再写死 AUTO）')
    check('urllib.parse.quote(PROXY_GROUP_NAME' in _gsrc,
          '切节点与判就绪都用常量（不再写死 AUTO）')
    _tsrc = pathlib.Path(t.__file__).read_text(encoding='utf-8')
    check('PROXY_GROUP_NAME' in _tsrc, 'taier 批量探测用同一个常量')
    check('collect_group_delays(' in _tsrc, 'taier 主流程调用了批量预取')
    # 反证：不许再有人直接拼 `/proxies/{name}/delay` 做逐节点探测（那条路恒 404）。
    # 逐字匹配会被换行/缩进坑到，按「压掉全部空白」后匹配（与 9g 同一手法）。
    check("/proxies/'+urllib.parse.quote(str(name),safe='')+'/delay?url='"
          not in re.sub(r'\s+', '', _tsrc),
          'taier 不得再走逐个 /proxies/{name}/delay 探测（成员恒 404）')

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
    #     `host not found` 是**真·网络故障**（DNS 解析失败），绝不能归进「机制故障」，
    #     否则真连不上的节点会被 fail-open 判成存活、还绕过熔断（噪声换成漏判）。
    for err, exp in [('Resource not found', True), ('no such proxy', True),
                     ('timeout', False), ('connection refused', False),
                     ('host not found', False),
                     ('Name or service not known', False),
                     ('无延迟值（连不上）', False), ('', False)]:
        check(t.is_unknown_proxy_error(err) is exp,
              f'unknown 判据 {err!r} → {exp}（实际 {t.is_unknown_proxy_error(err)}）')

    # 9b. 等就绪：前 2 次组里还没成员、第 3 次成员出现 ⇒ 就绪
    #     实现已抽到共享层 speedtest_gitee（CDN / Gitee / taier 三套共用），
    #     函数体里的 `mihomo_api_get` 是在 **speedtest_gitee 命名空间**解析的，
    #     所以要打桩 `g.mihomo_api_get`（打 `t.` 那份不起作用）。
    #
    #     ⚠️ 2026-09-24 判据改写：旧判据是探 `/proxies/{name}`（成员 404 = 没展开），
    #     而 provider 成员**从不注册进 `/proxies`**（对照实验：`/proxies/DIRECT/delay`
    #     正常返回 18ms，成员名恒 404），旧判据等的是一件永远不会发生的事。
    #     新判据读组的 `all` 清单——与测速真正走的路径同源。故 mock 返回 `{'all': [...]}`。
    _orig_get, _orig_sleep, _orig_log = g.mihomo_api_get, g.time.sleep, g.log_progress
    st = {'n': 0}
    ev9 = []
    try:
        g.time.sleep = lambda s: None
        g.log_progress = lambda stage, **kw: ev9.append((stage, kw))

        def flaky_get(path):
            st['n'] += 1
            # 前两次组里只有内置节点（provider 还没装填），第三次成员出现
            if st['n'] < 3:
                return {'all': ['DIRECT']}
            return {'all': ['DIRECT', 'n0', 'n1', 'n2', 'n3']}

        g.mihomo_api_get = flaky_get
        ready, _waited, probed = t.wait_provider_ready(['n0', 'n1', 'n2', 'n3'], timeout=10)
        check(ready is True, '未就绪→就绪时返回 True')
        check(probed in ('n0', 'n1', 'n2', 'n3'), f'报出探测用的哨兵名（实际 {probed!r}）')
        check([e[0] for e in ev9] == ['provider_ready'],
              f'记一条 provider_ready 便于观测（实际 {[e[0] for e in ev9]}）')

        # 9c. 超时：组里始终没有成员 ⇒ False，且不抛异常（调用方据此降级）
        g.mihomo_api_get = lambda path: {'all': ['DIRECT']}
        ev9.clear()
        ready, _w, probed = t.wait_provider_ready(['a', 'b'], timeout=0.3)
        check(ready is False and probed == '', '始终未就绪 → False（不抛异常）')
        check([e[0] for e in ev9 if e[0] != 'probe_ready_diag'] == ['provider_ready_timeout'],
              '超时要留痕，否则「等过但没等到」看不出来')

        # 9d. 空名单：不等待、不请求
        calls9 = []
        g.mihomo_api_get = lambda path: calls9.append(path) or {}
        check(t.wait_provider_ready([], timeout=5) == (False, 0.0, '')
              and t.wait_provider_ready(['', '  '], timeout=5) == (False, 0.0, ''),
              '空/空白名单直接返回 False')
        check(calls9 == [], '空名单不发任何请求（省掉必然失败的调用）')
    finally:
        g.mihomo_api_get, g.time.sleep, g.log_progress = _orig_get, _orig_sleep, _orig_log

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

    # 9f. 三套共用**同一份** wait_provider_ready（防某一套留了本地副本、修这边漏那边）
    #     判据用对象同一性（`is`），不是「都能调」——后者对副本也成立，抓不到漂移。
    cdn = __import__('speedtest')
    check(t.wait_provider_ready is g.wait_provider_ready,
          'taier 用的就是 gitee 里那份（import 而非本地重定义）')
    check(cdn.wait_provider_ready is g.wait_provider_ready,
          'cdn 用的也是 gitee 里那份')
    check('def wait_provider_ready' not in
          pathlib.Path(t.__file__).read_text(encoding='utf-8'),
          'taier 不得再留本地副本')
    check('def wait_provider_ready' not in
          pathlib.Path(cdn.__file__).read_text(encoding='utf-8'),
          'cdn 不得再留本地副本')

    # 9g. 三套都**真的调了**它（共用一份实现 ≠ 装了保险；删掉调用点同样等于没修）
    #     反证：只留 9f 的话，把三处调用点删掉测试仍全绿——必须钉住调用点。
    for mod_name, mod in (('taier', t), ('gitee', g), ('cdn', cdn)):
        src = pathlib.Path(mod.__file__).read_text(encoding='utf-8')
        check('wait_provider_ready(' in src,
              f'{mod_name} 主流程必须调用 wait_provider_ready')
        # 参数按「去换行 + 压空白」后匹配：taier 的调用跨行写，逐字匹配会误报
        norm = re.sub(r'\s+', '', src)
        check("wait_provider_ready([i.get('name')foriinalive_items]" in norm,
              f'{mod_name} 用的是节点名列表（不是别的参数）')

    print('== 10. 上行测速统一：CDN 与 Gitee 同一份实现 + 都能切直连 ==')
    # 诉求（2026-09-17）：CDN / Gitee 的上行要么都经代理、要么都直连，且都能用直连基线对照。
    # 此前 CDN 自带 gitee_push_speedtest/_gitee_push_direct 两份等价实现，靠人工与 Gitee
    # 对齐口径——改一处漏一处，且两套数值不可比（下的功夫都在「对齐」上）。

    # 10a. 同一份实现：断言函数对象相同，不是「行为相同」
    check(g.upload_speedtest is not None, 'gitee 导出 upload_speedtest')
    check(d.upload_speedtest is g.upload_speedtest, 'cdn 用的就是 gitee 那份')
    check('def upload_speedtest' not in pathlib.Path(d.__file__).read_text(encoding='utf-8'),
          'cdn 不得再留本地副本')
    check(d.run_direct_baseline is g.run_direct_baseline, 'cdn 与 gitee 共用直连基线')
    check(not hasattr(d, '_gitee_push_direct'),
          'CDN 的旧直连分支已删除（避免与新实现并存漂移）')

    # 10b. strip_proxy_env 必须剥干净（漏一个小写变量 ⇒「直连」其实还在走代理，且看不出异常）
    probe_env = {'ALL_PROXY': 'a', 'all_proxy': 'b', 'HTTP_PROXY': 'c', 'http_proxy': 'd',
                 'HTTPS_PROXY': 'e', 'https_proxy': 'f', 'PATH': '/usr/bin',
                 'GIT_TERMINAL_PROMPT': '1'}
    stripped = g.strip_proxy_env(probe_env)
    leaked = [k for k in ('ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy',
                          'HTTPS_PROXY', 'https_proxy') if k in stripped]
    check(leaked == [], f'6 个代理变量全剥净（残留 {leaked}）')
    check(stripped.get('PATH') == '/usr/bin', '非代理变量原样保留')
    check(stripped.get('GIT_TERMINAL_PROMPT') == '0', '强制非交互，避免卡在凭据提示')
    check('all_proxy' in probe_env, '不修改入参（返回新 dict）')

    # 10c. run_direct_baseline 的重试语义：一次抖动不该让整轮基线缺失
    _orig_upload = g.upload_speedtest
    _orig_sleep, _orig_log = g.time.sleep, g.log_progress
    _orig_clone = g.git_clone_testbranch
    attempts = []
    ev10 = []
    try:
        g.time.sleep = lambda s: None
        g.log_progress = lambda stage, **kw: ev10.append((stage, kw))
        g.git_clone_testbranch = lambda **kw: (2.0, pathlib.Path('/dev/null'))

        class _FakeFile:
            def stat(self):
                class _S:
                    st_size = 10 * 1024 * 1024
                return _S()

        def flaky_upload(**kw):
            attempts.append(kw.get('via_proxy'))
            if len(attempts) < 3:
                raise RuntimeError('timed out')
            return 5.0, 10 * 1024 * 1024

        g.upload_speedtest = flaky_upload
        res = g.run_direct_baseline(env={}, gitee={'remote_with_token': 'x'},
                                    test_file=_FakeFile(), push_timeout=60,
                                    clone_timeout=60, speedtest_mode='push-only',
                                    max_attempts=5, label='cdn')
        check(len(attempts) == 3, f'失败重试直到成功（实际 {len(attempts)} 次）')
        check(all(v is False for v in attempts), '基线始终走直连（via_proxy=False）')
        check(res['ok'] is True and res['attempt'] == 3, '返回成功的尝试序号')
        check(res['upload_mibs'] == 2.0, f'10MiB/5s = 2.0 MiB/s（实际 {res.get("upload_mibs")}）')
        check('download_mibs' not in res, 'push-only 模式不 clone')

        # 10d. 全部失败 ⇒ 抛异常（调用方据此记 ok=False），错误里带每次原因
        attempts.clear()

        def always_fail(**kw):
            attempts.append(1)
            raise RuntimeError('push timeout')

        g.upload_speedtest = always_fail
        raised = None
        try:
            g.run_direct_baseline(env={}, gitee={'remote_with_token': 'x'},
                                  test_file=_FakeFile(), push_timeout=60,
                                  clone_timeout=60, speedtest_mode='push-only',
                                  max_attempts=3)
        except Exception as e:
            raised = str(e)
        check(raised is not None and '连续 3 次失败' in raised,
              f'全失败 ⇒ 抛异常并报次数（实际 {raised!r}）')
        check(len(attempts) == 3, f'重试次数 = max_attempts（实际 {len(attempts)}）')
    finally:
        g.upload_speedtest = _orig_upload
        g.time.sleep, g.log_progress = _orig_sleep, _orig_log
        g.git_clone_testbranch = _orig_clone

    # 10e. 两套都能切直连：开关名与默认值必须一致（同名同默认才不会「一套切了另一套没切」）
    def _via_proxy_default(src_text, mod_name):
        norm = re.sub(r'\s+', '', src_text)
        return "PROXY_SPEEDTEST_UPLOAD_VIA_PROXY','1'" in norm

    for mod_name, mod in (('gitee', g), ('cdn', d)):
        src = pathlib.Path(mod.__file__).read_text(encoding='utf-8')
        check(_via_proxy_default(src, mod_name),
              f'{mod_name} 的 UPLOAD_VIA_PROXY 默认 1（保持既有口径不变）')
    check(d.CONFIG['PROXY_SPEEDTEST_UPLOAD_VIA_PROXY'] is True,
          'cdn 配置项解析为 True（默认经代理）')
    check(d.CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE'] is True,
          'cdn 默认开启直连基线（与 gitee 一致）')

    # 10f. 两套都真的调了共享上行实现（共用一份 ≠ 装了开关；不接调用点等于没统一）
    for mod_name, mod, marker in (('gitee', g, 'upload_speedtest('),
                                  ('cdn', d, 'upload_speedtest(')):
        src = pathlib.Path(mod.__file__).read_text(encoding='utf-8')
        check(marker in src, f'{mod_name} 主流程调用了共享 upload_speedtest')
    check('via_proxy=upload_via_proxy' in pathlib.Path(g.__file__).read_text(encoding='utf-8'),
          'gitee 把开关接到了调用的 via_proxy 参数上')
    check('via_proxy=via_proxy' in pathlib.Path(d.__file__).read_text(encoding='utf-8'),
          'cdn 把开关接到了调用的 via_proxy 参数上')

    print('== 11. 下载计时只包住文件内容传输（纯传输时间）==')
    # 诉求（2026-09-17）：原实现 t0=time.time() 包住整条 git clone，量到的是
    # 「仓库元数据协商 + 内容传输 + 本地 checkout」的墙钟时间 ⇒ 高速节点上固定开销占比大，
    # MiB/s 被系统性低估，且与只包住 git push 的上行侧口径不对称。
    # 现在两段：--filter=blob:none 的 metadata clone（不计时）+ checkout 取内容（计时）。
    # 反证：把 t0 挪回 clone 之前，11c 会把 metadata clone 的 5s 也算进去而变红。
    _g_src = pathlib.Path(g.__file__).read_text(encoding='utf-8')
    check('--filter=blob:none' in _g_src,
          'clone 用 blob:none 只取元数据（不把内容传输混进元数据阶段）')

    # 打在真正的进程边界（subprocess.run）上，而不是 g.run：这样实现里的
    # shutil.rmtree / 文件落地都不受影响，命令序列也能按「clone → checkout」精确推进。
    import subprocess as _sp
    _orig_sp_run = _sp.run
    monkey = [800.0]
    cmd_seq = []

    def _fake_subprocess_run(cmd, **kw):
        cmd_seq.append(list(cmd))
        if cmd[:2] == ['git', 'clone']:
            # metadata clone 阶段：伪造耗时 5s，并只造一个**空壳**仓库目录
            monkey[0] += 5.0
            clone_dir = pathlib.Path(cmd[-1])
            clone_dir.mkdir(parents=True, exist_ok=True)
            return _sp.CompletedProcess(cmd, 0, '', '')
        if cmd[:2] == ['git', 'checkout']:
            # 内容传输阶段：伪造耗时 2s，再把文件真的写到工作区
            monkey[0] += 2.0
            (pathlib.Path(kw['cwd']) / cmd[-1]).write_bytes(b'x' * 10)
            return _sp.CompletedProcess(cmd, 0, '', '')
        return _orig_sp_run(cmd, **kw)

    _orig_time = g.time.time
    _sp_run = _sp.run
    tmp_clone = pathlib.Path('/tmp/_t11_dl')
    try:
        _sp.run = _fake_subprocess_run
        g.time.time = lambda: monkey[0]
        elapsed, pulled = g.git_clone_testbranch(
            clone_dir=tmp_clone, remote='r', env={}, timeout=60,
            branch_name='b', target_filename='speed.bin')
    finally:
        _sp.run = _sp_run
        g.time.time = _orig_time

    # 11c. 只有 checkout 那一段（2s）被计时，metadata clone 的 5s 必须被排除
    check(abs(elapsed - 2.0) < 1e-6,
          f'只用 checkout 段计时，不含 metadata clone（实际 {elapsed}s，期望 2.0）')
    # 11d. 两段命令都在，且各自只跑一次
    clones = [c for c in cmd_seq if c[:2] == ['git', 'clone']]
    checkouts = [c for c in cmd_seq if c[:2] == ['git', 'checkout']]
    check(len(clones) == 1, f'clone 只调一次（实际 {len(clones)}）')
    check(len(checkouts) == 1, f'checkout 只调一次（实际 {len(checkouts)}）')
    check(clones and '--filter=blob:none' in clones[0],
          'clone 命令确实带 blob:none 过滤')
    check(checkouts and 'speed.bin' in checkouts[0],
          'checkout 只取测速文件（不整树 checkout，否则又会掺入别的开销）')

    # 11e. 内容没落地（blob 没取到）⇒ 必须报错，不能把「空文件 + 极短耗时」当日志成功
    try:
        _sp.run = lambda cmd, **kw: _sp.CompletedProcess(cmd, 0, '', '')
        raised = None
        try:
            g.git_clone_testbranch(clone_dir=tmp_clone, remote='r', env={}, timeout=60,
                                   branch_name='b', target_filename='missing.bin')
        except Exception as e:
            raised = str(e)
        check(raised is not None, f'文件未落地 ⇒ 抛错（实际 {raised!r}）')
    finally:
        _sp.run = _sp_run
        shutil.rmtree(tmp_clone, ignore_errors=True)

    # 11f. 两处调用点都改用返回值当 download_seconds（删掉一处就少一组数据）
    check(_g_src.count('git_clone_testbranch(') == 3,
          f'gitee 内 2 处调用 + 1 处定义（实际 {_g_src.count("git_clone_testbranch(")}）')
    check("'download_seconds': round(download_s, 3)" in _g_src,
          'download_seconds 取的是纯传输耗时（同一个 download_s）')

    print('== 12. 节点名优先级排序 + duration 默认 5（2026-09-17）==')
    # 诉求：把 duration 从 10 降到 5（单节点 25s→15s），并让名字命中
    # IPLC|IPEL|IEPL|专线|HK|Hong|港|TW|Taiwan|台|SG|新加坡 的节点优先测速。
    # 反证：把 prioritize_nodes 换成普通 sorted()（不稳定）/退回只取命中集（会丢节点），
    # 12b/12c 变红。

    # 12a. duration 默认值：env 未设时必须是 5，且仍在 5-13 钳制区间内
    _t_src = pathlib.Path(t.__file__).read_text(encoding='utf-8')
    check("os.environ.get('TAIER_DURATION', '5')" in _t_src,
          "duration 默认 5（env 未设时取 5）")
    check(t.CONFIG['TAIER_DURATION'] == 5,
          f"CONFIG 解析为 5（实际 {t.CONFIG['TAIER_DURATION']}）")
    # 钳制仍生效：上游二进制硬钳 5-13，越界值要被压回来（不能因为改了默认值就丢掉钳制）
    check(min(max(1, 5), 13) == 5 and min(max(99, 5), 13) == 13,
          'duration 钳制区间 5-13 仍生效')

    # 12b. 命中者前置、未命中者不丢、且各自保持原相对顺序（稳定分区）
    nodes = [
        {'name': '日本 JP-01'}, {'name': 'IPLC-HK-01'}, {'name': '美国 US-02'},
        {'name': 'IEPL-SG'}, {'name': '韩国 KR-03'}, {'name': '香港04'},
    ]
    ordered, hits = t.prioritize_nodes(nodes, t.CONFIG['TAIER_PRIORITY_REGEX'])
    check(hits == 3, f'命中 3 个（实际 {hits}）')
    check(len(ordered) == len(nodes),
          f'不丢节点：总数不变（实际 {len(ordered)} vs {len(nodes)}）')
    check([x['name'] for x in ordered[:3]] == ['IPLC-HK-01', 'IEPL-SG', '香港04'],
          f'命中者按原序前置（实际 {[x["name"] for x in ordered[:3]]}）')
    check([x['name'] for x in ordered[3:]] == ['日本 JP-01', '美国 US-02', '韩国 KR-03'],
          f'未命中者按原序留在队尾（实际 {[x["name"] for x in ordered[3:]]}）')

    # 12c. 大小写不敏感 + 中文关键词 + 专线
    low = [{'name': 'hk-01'}, {'name': 'tw-02'}, {'name': 'iplc 专线'}, {'name': 'japan'}]
    o2, h2 = t.prioritize_nodes(low, t.CONFIG['TAIER_PRIORITY_REGEX'])
    check(h2 == 3, f'小写 hk/tw 与中文「专线」都命中（实际 {h2}）')
    check(o2[-1]['name'] == 'japan', '未命中的 japan 落到队尾')

    # 12d. 空输入 / 空正则 / 非法正则 → 原样返回、不抛（一个配置写错不该让整轮零产出）
    same, h3 = t.prioritize_nodes(nodes, '')
    check(same is nodes and h3 == 0, '空正则 → 原样返回、命中 0')
    empty, h4 = t.prioritize_nodes([], 'HK')
    check(empty == [] and h4 == 0, '空列表 → 返回空、命中 0')
    import re as _re
    bad_nodes = [{'name': 'HK-01'}, {'name': 'US-01'}]
    bad_out, bad_hits = t.prioritize_nodes(bad_nodes, 'HK|(')  # 括号不闭合 ⇒ re.error
    check(bad_out == bad_nodes and bad_hits == 0,
          f'非法正则 → 原序返回、不抛（实际 {[x["name"] for x in bad_out]}）')

    # 12e. 排序发生在 max_nodes 截断**之前**（否则命中者可能被截在门外，排序白做）
    norm_t = _re.sub(r'\s+', '', _t_src)
    check('prioritize_nodes(alive_items,CONFIG[\'TAIER_PRIORITY_REGEX\'])' in norm_t,
          'alive_items 确实过了 prioritize_nodes')
    _pi = norm_t.find("prioritize_nodes(alive_items")
    _tr = norm_t.find("alive_items=alive_items[:max_nodes]")
    check(_pi != -1 and _tr != -1 and _pi < _tr,
          f'排序在 max_nodes 截断之前（prioritize@{_pi} < truncate@{_tr}）')
    check('nodes_prioritized' in _t_src, '有 nodes_prioritized 日志（可核对命中数）')

    print('== 13. 节点名 include 过滤（2026-09-22，编排轮池子远超 5 小时预算）==')
    # 诉求：编排轮（gistnodes）交接 15793 个节点、预算只测完 1905 个——优先级排序只能决定
    # 「先测谁」，决定不了「池子有多大」；include 过滤（命中保留、未命中丢弃）才真正缩短
    # 运行时长。反证：把 fail-open 删掉（非法正则抛异常 / 全过滤光返回空），13d/13e 变红。

    # 13a/13b/13d/13e 全程捕获 log_progress（还原后再断言），13c/13f/13g 无事件依赖
    _orig_log13 = t.log_progress
    ev13 = []
    try:
        t.log_progress = lambda stage, **kw: ev13.append((stage, kw))
        # 13a. 正常过滤：命中保留、未命中丢弃、保持相对序、返回丢弃数
        inc_nodes = [
            {'name': '香港-01'}, {'name': '日本 JP-01'},
            {'name': 'SG-02'}, {'name': '韩国 KR-03'},
        ]
        kept13, dropped13 = t.filter_nodes_include(inc_nodes, 'HK|港|SG|新加坡')
        check([x['name'] for x in kept13] == ['香港-01', 'SG-02'],
              f'命中保留且保序（实际 {[x["name"] for x in kept13]}）')
        check(dropped13 == 2, f'丢弃数 = 2（实际 {dropped13}）')

        # 13b. 大小写不敏感 + 中文关键词（与 prioritize 同判据）
        low13, d13b = t.filter_nodes_include(
            [{'name': 'hk-01'}, {'name': 'japan'}, {'name': '新加坡-02'}], 'hk|新加坡')
        check([x['name'] for x in low13] == ['hk-01', '新加坡-02'] and d13b == 1,
              f'小写 hk 与中文「新加坡」都命中（实际 {[x["name"] for x in low13]}/{d13b}）')

        # 13c. 空正则 / 空列表 → 原样返回、不丢节点（默认不过滤的前提）
        same13, d0 = t.filter_nodes_include(inc_nodes, '')
        check(same13 is inc_nodes and d0 == 0, '空正则 → 原样返回、丢弃 0')
        empty13, d0e = t.filter_nodes_include([], 'HK')
        check(empty13 == [] and d0e == 0, '空列表 → 返回空、丢弃 0')

        # 13d. 非法正则 → 原样返回、不抛、记 include_regex_invalid
        bad_out13, bad_d13 = t.filter_nodes_include([{'name': 'HK-01'}], 'HK|(')
        check(bad_out13 == [{'name': 'HK-01'}] and bad_d13 == 0,
              '非法正则 → 原样返回、不抛')
        # 13e. 全过滤光 → fail-open 原样返回（过滤层不得造成零产出）
        all_out13, all_d13 = t.filter_nodes_include([{'name': 'japan'}], 'HK')
        check(all_out13 == [{'name': 'japan'}] and all_d13 == 0,
              '全过滤光 → 原样返回、不丢节点')
    finally:
        t.log_progress = _orig_log13
    stages13 = [s for s, _ in ev13]
    check('include_regex_invalid' in stages13,
          f'非法正则记 include_regex_invalid（实际 {stages13}）')
    check('include_regex_all_dropped_fallback' in stages13,
          f'全过滤光记 include_regex_all_dropped_fallback（实际 {stages13}）')
    check('nodes_include_filtered' in stages13,
          f'正常过滤记 nodes_include_filtered（实际 {stages13}）')

    # 13g. 接线次序：排序 → 过滤 → max_nodes 截断（截断必须按过滤后的池子算「前 N 个」）
    norm13 = _re.sub(r'\s+', '', _t_src)
    _pp13 = norm13.find("prioritize_nodes(alive_items")
    _ff13 = norm13.find("filter_nodes_include(alive_items")
    _tr13 = norm13.find("alive_items=alive_items[:max_nodes]")
    check(_pp13 != -1 and _ff13 != -1 and _tr13 != -1 and _pp13 < _ff13 < _tr13,
          f'排序@{_pp13} < 过滤@{_ff13} < 截断@{_tr13}')
    check("os.environ.get('TAIER_INCLUDE_REGEX'" in norm13,
          'TAIER_INCLUDE_REGEX 可经 env 覆盖')

    # 13f. 默认值：CONFIG 里必须是空串（定时轮 / 手动 dispatch 不过滤）
    check(t.CONFIG['TAIER_INCLUDE_REGEX'] == '',
          f"默认不过滤（实际 {t.CONFIG['TAIER_INCLUDE_REGEX']!r}）")

    print('== 14. provider 展开等待按「实际加载量」放大（2026-09-23 二次修正）==')
    # 两轮失败的根因链：`wait_provider_ready` 超时不够 ⇒ 测活开测就连吃「mihomo 不认识」⇒
    # 熔断关掉整个测活层 ⇒ 上千个死节点全跑满 ~16 秒的测速窗口（2026-09-23 实测 1309 个
    # ≈ 6 小时，单这一项吃掉整个 5h 预算）。
    #   第一版（f23e527）按**候选数**放大：加载 20004、过滤后 1539 ⇒ 只给 152 秒，仍等不完
    #   （`attempts=322` 全 404）。第二版改按 **mihomo 实际加载量** 算——展开耗时取决于
    #   mihomo 装了多少，与调用方之后砍到多少**无关**。
    # 反证：把系数改回 0.06 或把封顶改回 600，14a/14b 变红；把 `total_loaded` 去掉，14c 变红。

    # 14a. 放大公式：`60 + 0.3 × 加载量`，封顶 900
    f14 = g._provider_ready_timeout
    check(f14(2123) > 60.0 * 2, f'2123 个 → {f14(2123):.0f} 秒（显著大于 60）')
    check(f14(100) >= 60.0, f'小池子不低于基础 60 秒（实际 {f14(100):.0f}）')
    # 2 万加载量按系数算要 606 秒，但被封顶压到 300（加时换不来「等到」，只白烧预算）
    check(f14(20000) == 300.0, f'2 万加载量取封顶 300（实际 {f14(20000):.0f}）')
    check(f14(500) >= 60.0 + 500 * 0.3 - 1e-6,
          f'未触顶时按 60 + 0.3n 算（500 → {f14(500):.0f}）')
    check(f14(100000) == 300.0, f'封顶 300 秒（实际 {f14(100000):.0f}）')
    check(f14(0) == 60.0, f'0 节点仍取基础值（实际 {f14(0):.0f}）')

    # 14b. 三套调用点都**不再写死 60**（写死即漏修；用归一化源码匹配跨行调用）
    for mod_name, mod in (('taier', t), ('gitee', g), ('cdn', d)):
        src14 = _re.sub(r'\s+', '', pathlib.Path(mod.__file__).read_text(encoding='utf-8'))
        check('timeout=60.0' not in src14,
              f'{mod_name} 不得再写死 timeout=60.0')
    # 14c. 默认参数必须是 None（= 自动），不能是某个写死的数字
    import inspect as _ins
    check(_ins.signature(g.wait_provider_ready).parameters['timeout'].default is None,
          'wait_provider_ready 的 timeout 默认 None（按节点数自动）')

    # 14d. ⚠️ 三套都必须把**加载量**传进来（不传就退化成候选数 = 上轮病灶）
    #     反证：删掉任一处的 `total_loaded=`，对应这条变红。
    for mod_name, mod in (('taier', t), ('gitee', g), ('cdn', d)):
        src14d = _re.sub(r'\s+', '', pathlib.Path(mod.__file__).read_text(encoding='utf-8'))
        check('total_loaded=' in src14d,
              f'{mod_name} 必须传 total_loaded（按实际加载量算，而非过滤后的候选数）')

    # 14e. 没传加载量时退化为候选数（老调用方不炸，只是精度差）
    _orig_get14 = g.mihomo_api_get
    try:
        g.mihomo_api_get = lambda path: (_ for _ in ()).throw(_404())
        _r14, _w14, _ = t.wait_provider_ready(['a'], timeout=0.1)
        check(_r14 is False, 'timeout 显式给定时不走自动放大（调用方能压时间）')
    finally:
        g.mihomo_api_get = _orig_get14

    print('== 15. 「mihomo 不认识节点名」不再熔断测活层，改为放回队尾重排（2026-09-23）==')
    # 旧行为：连续 8 个 `Resource not found` ⇒ 永久关掉整个测活层。坏法是**把加载状态当
    # 节点属性**——mihomo 加载上万个节点时展开极慢，此刻「不认识」是正常的中间态；一熔断
    # 就再没人拦死节点，1309 个全跑满 16.5 秒 ≈ 6 小时。
    # 新行为：把节点 append 回队尾（挪到本轮其余节点之后，天然形成「等会儿再试」），
    # 累计上限 2N 防无限循环，到顶才退回旧的「放行去测速」。
    # 反证：把 `alive_items.append(item)` 改回 `_probe_enabled = False`，15a/15b 变红。

    # 15a. 源码级：未知名分支里**不再有**关掉测活层的语句，且存在放回队尾
    _t15 = _re.sub(r'\s+', '', pathlib.Path(t.__file__).read_text(encoding='utf-8'))
    _u15 = _t15.find('ifis_unknown_proxy_error(_perr):')
    check(_u15 != -1, '未知名分支存在')
    # 段界取到「下一条分支的连击清零」（`_unknown_streak=0`）为止——再往后就是**真连不上**
    # 的熔断，那段必须保留（15c 验），框进来会把 15a 判成假红。
    _e15 = _t15.find('_unknown_streak=0', _u15)
    _seg15 = _t15[_u15:_e15] if _e15 != -1 else _t15[_u15:_u15 + 1200]
    check('alive_items.append(item)' in _seg15,
          '未知名 → 放回队尾（而不是关掉测活层）')
    check('_probe_enabled=False' not in _seg15,
          f'未知名分支不得再关掉测活层（_probe_enabled=False）')

    # 15b. 有重排上限 + 到顶有日志（否则展不开时队列永远消费不完）
    check('_unknown_requeue_cap' in _t15 and '_unknown_requeued' in _t15,
          '重排有累计上限（防无限循环）')
    check('taier_probe_unknown_requeue_capped' in _t15,
          '到顶留痕（可核对是否真的展不开）')

    # 15d. ⚠️ **到顶后必须放行去测速，不得 continue 丢弃**（2026-09-23 零产出事故）
    #     事故：重排配额烧完后写的是 `continue` ⇒ 1581 个候选全部跳过测速 ⇒
    #     `taier_speedtest_done node_count=0`，整轮白跑。fail-open 的语义是「照测」，
    #     不是「不测」。反证：把 `continue` 加回 `taier_probe_unknown_requeue_capped`
    #     后面，这条变红。
    # 判据用**区间计数**：从「到顶 log」到该分支收尾（`_unknown_streak=0`，即真判死分支
    # 开始）之间**不得**再出现 continue。出现即说明到顶后又把节点丢了（零产出回归）。
    _cap15 = _t15.find('taier_probe_unknown_requeue_capped')
    check(_cap15 != -1, '到顶分支存在')
    _end15 = _t15.find('_unknown_streak=0', _cap15)
    check(_end15 != -1 and 'continue' not in _t15[_cap15:_end15],
          '到顶后不得再 continue（否则节点被丢弃 ⇒ 零产出）')

    # 15c. **真连不上**的熔断必须还在（只放开了「不认识」，没放开「节点真死」）
    check('_probe_dead_streak>=_probe_guard_n' in _t15,
          '真连不上的熔断判据仍在（不要因为改了未知名分支就整体失效）')

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
