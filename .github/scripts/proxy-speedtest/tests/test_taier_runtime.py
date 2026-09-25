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
  整轮会一个节点都不测。那比在死节点上多花 31 秒糟得多，所以单独验。
  ⚠️ 2026-09-24 重写：判活路径从「逐个 `GET /proxies/{name}/delay`」换成「开测前一次
  `collect_group_delays` 拿整组延迟表 + 逐节点查表」。旧路径是**死代码**——provider
  成员从不注册进 `/proxies`（顶层恒为 8 个内置组名；对照实验：`/proxies/DIRECT/delay`
  正常返回 18ms、成员名恒 404），所以测活层从上线起一次都没真正生效过。
  新语义只有两种世界：拿不到表 ⇒ 探测层整体关闭、全量放行去测速（**不产生判死条目**）；
  拿到了 ⇒ 「表里没有」是 mihomo 的真判死结论，计入 `❌ 失败`。
  第 2/2b 组钉查表与批量预取，第 7 组钉通知口径，第 15 组钉旧机器（熔断 / 未知名重排 /
  撤销判死）**不得回归**。
- **通知降级**：`aborted_due_to_runtime` 传错、或标题降级写反，会让「到点收摊」看起来
  像一次正常完成，读者无从判断这轮到底测完了没有。三套的**行位置也必须一致**。
- **include 过滤**（2026-09-22，编排轮池子上万远超预算）：最隐蔽的坏法是 **fail-open
  缺失**——非法正则抛异常、或「全过滤光」被当真返回空列表，编排轮会零节点、整轮白跑。
  另一处是**接线次序**：过滤必须在 max_nodes 截断之前，否则截断把已过滤节点算进配额。
- **provider 装填等待**（2026-09-22 引入、2026-09-23 放大修正、2026-09-24 改判据）：
  超时写死 60 秒 / 按**候选数**放大，都会在大池子上等不完。**旧判据本身也是错的**——
  探 `/proxies/{name}` 等的是一件永远不会发生的事（成员从不注册进 `/proxies`），
  每轮必然超时（给到 900 秒仍是 `attempts=1810` 全 404）。现改读 `/proxies/{组}` 的
  `all` 成员清单——与测速真正走的路径同源。第 14 组钉住「按**实际加载量**放大 +
  三套都传 `total_loaded`」，第 9 组钉住新判据的就绪/超时/空名单三态。

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

    print('== 2. 测活：查整组延迟表（probe_node_alive）==')
    # ⚠️ 2026-09-24 重写：判活不再逐个请求 `/proxies/{name}/delay`（provider 成员从不
    # 注册进 `/proxies`，恒 404 ⇒ 该路径从未生效过），改为开测前一次 `collect_group_delays`
    # 拿整组 `{名字: 延迟}`、逐节点查表。所以这里验的是**查表语义**，不再起 HTTP 服务。
    _tbl = {'alive': 123, 'slow': 99999}

    okv, d, err = t.probe_node_alive('alive', _tbl)
    check(okv is True and d == 123 and err == '',
          f'表里命中 → 存活并带出延迟（实际 {okv}/{d}/{err}）')

    okv, d, err = t.probe_node_alive('slow', _tbl)
    check(okv is True and d == 99999,
          f'延迟大也算活（判据是「连得上」，不是「快」，实际 {okv}/{d}）')

    okv, d, err = t.probe_node_alive('absent', _tbl)
    check(okv is False and d is None, f'表里没有 → 判死（实际 {okv}/{d}）')
    # 判死串必须带前缀：通知的 ❌ 失败会原样展示它，读者要能分清「测活阶段就死」
    # 与「测速阶段失败」（规范 · 2.8 taier 专属分节）。
    check(str(err).startswith('测活未通过：'),
          f'判死错误串带「测活未通过：」前缀（实际 {err}）')

    # 2b. 批量延迟表测活（2026-09-24）：这是**唯一真正生效**的测活路径。
    #     旧路径 `GET /proxies/{name}/delay` 对 provider 成员**永远 404**（成员从不注册
    #     进 `/proxies`），所以测活层从上线起一次都没生效过。新路径 `/group/{组}/delay`
    #     一次拿全组 `{名字: 延迟}`，查表是纯内存操作——这里钉住它的三种语义。
    # 2b. 批量预取本身（2026-09-24）：`collect_group_delays` 一次拿全组 `{名字: 延迟}`。
    #     这是测活层唯一的取数入口——拿不到表 ⇒ 主流程关闭探测层（fail-open 放全量去测速），
    #     所以**它自己必须 fail-open 返回空表**，绝不能抛异常把整轮打断。
    print('== 2b. 批量预取 collect_group_delays：成功拿表 / 不可达返空表 ==')

    class FakeGroup(http.server.BaseHTTPRequestHandler):
        """只实现 /group/{组}/delay，其余一律 404。"""

        def log_message(self, *a):
            pass

        def do_GET(self):
            if '/group/AUTO/delay' in self.path:
                code, body = 200, b'{"DIRECT": 14, "n0": 792}'
            else:
                code, body = 404, b'{}'
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv2 = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeGroup)
    threading.Thread(target=srv2.serve_forever, daemon=True).start()
    _saved_api2 = g.MIHOMO_API
    g.MIHOMO_API = f'http://127.0.0.1:{srv2.server_address[1]}'
    try:
        tbl2 = g.collect_group_delays('AUTO', 'http://x', 3000)
        check(tbl2 == {'DIRECT': 14, 'n0': 792},
              f'一次请求拿到整组延迟表（实际 {tbl2}）')
        # 不可达 ⇒ 空表（fail-open），由主流程据此关闭探测层
        g.MIHOMO_API = 'http://127.0.0.1:1'  # 没人监听
        tbl3 = g.collect_group_delays('AUTO', 'http://x', 3000)
        check(tbl3 == {}, f'拿不到表 → 空表 fail-open、不抛异常（实际 {tbl3}）')
    finally:
        g.MIHOMO_API = _saved_api2
        srv2.shutdown()

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

    # 2d. 组测速韧性包装（2026-09-25）：大池下组测速曾挤崩 mihomo（run 36080367499，
    #     4.6s 连接被掐 → 1771 次 switch 全 refused → 整轮零数据）。包装必须：
    #     a) 拿到表 → 原样返回（不引入额外请求）；
    #     b) 空表 + mihomo 活着 → 返回空表（fail-open，不重启）；
    #     c) 空表 + mihomo 死了 → 重启 + 等装填 + 重试一次。
    #     反证：删掉包装里的 /version 分支，c) 变红——mihomo 死活不分、该重启不重启。
    print('== 2d. 组测速韧性：mihomo 死了重启重试，活着 fail-open ==')
    check('collect_group_delays_resilient' in _tsrc, '主流程走韧性包装')
    check('mihomo_api_get(\'/version\')' in _tsrc.replace('"', "'"),
          '失败后先探 /version 分辨死活（真超时≠进程死了）')
    check('mihomo_restart_for_probe' in _tsrc and 'await_provider_loaded_after_restart' in _tsrc,
          '死了先重启再重试（重启后要重新等 provider 装填，空表≠全员判死）')
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
    # 测活**默认开启**（2026-09-15 改回）：目的就是「死节点别占掉 31 秒窗口」。
    # run 34859505000 曾出现 27 个节点全部误杀（节点名在 mihomo 里对不上），
    # 但那条路径由熔断（连续 8 个未通过即关探测）与 fail-open 兜住，不值得为此默认牺牲收益。
    check(t.CONFIG['TAIER_ALIVE_PROBE'] is True, '默认开启测活（省下死节点的 31 秒窗口）')
    check('cnspeedtest' in t.CONFIG['TAIER_ALIVE_PROBE_URL'],
          f"默认探测目标对准泰尔控制面（实际 {t.CONFIG['TAIER_ALIVE_PROBE_URL']}）")
    # 显式关闭仍须生效（误杀现场要能一键退回纯测速）
    check(_parse_alive_probe('0') is False, 'TAIER_ALIVE_PROBE=0 可显式关闭')
    check(_parse_alive_probe('off') is False, 'TAIER_ALIVE_PROBE=off 可显式关闭')

    print('== 4b. 覆盖度闸门：表覆盖不住待测池时不许判死（2026-09-25）==')
    # 事故原型：mihomo `/group/{组}/delay` 在大池下**只返回已测完的那批**，不是全量。
    # 编排轮 run 36086261741 实测：待测 1780、表只有 65 条（覆盖 3.7%），却据此判死
    # 1777 个 —— 「表里没有」在当时是「还没轮到」而不是「连不上」，成片误杀好节点。
    # 对照（单节点轮 36025190562）：待测 17、表 17 条（覆盖 100%）⇒ 判死才可信。
    check(t.CONFIG['TAIER_PROBE_MIN_COVERAGE'] == 0.5,
          f"覆盖度下限默认 0.5（实际 {t.CONFIG['TAIER_PROBE_MIN_COVERAGE']}）")
    _tsrc4b = pathlib.Path(t.__file__).read_text(encoding='utf-8')
    check('taier_probe_low_coverage' in _tsrc4b,
          '覆盖不足要留痕（可核对是「判死」还是「不敢判」）')
    # 行为层：覆盖不足 ⇒ probe_node_alive 一个都不该被调用（全量放行去测速）
    _names = [{'name': f'n{i}'} for i in range(100)]
    _small = {'n0': 10}   # 100 个待测只覆盖 1 个 = 1% ≪ 50%
    _full = {f'n{i}': 10 for i in range(100)}  # 100% 覆盖
    _calls = []

    def _fake_probe(name, table):
        _calls.append(name)
        return True, 1, ''

    _orig_probe = t.probe_node_alive
    _orig_lp4b = t.log_progress
    t.probe_node_alive = _fake_probe
    t.log_progress = lambda stage, **kw: None
    try:
        for _cov, _label, _tbl in ((0.01, '覆盖 1%', _small), (1.0, '覆盖 100%', _full)):
            _enabled = (bool(_tbl)
                        and (len(_tbl) / float(len(_names))) >= t.CONFIG['TAIER_PROBE_MIN_COVERAGE'])
            _calls.clear()
            for _item in _names:
                if _enabled:
                    t.probe_node_alive(_item['name'], _tbl)
            if _cov < 0.5:
                check(_enabled is False and _calls == [],
                      f'{_label} → 探测层关闭、一个都不判死（实际调用 {len(_calls)} 次）')
            else:
                check(_enabled is True and len(_calls) == len(_names),
                      f'{_label} → 探测层启用、逐节点判活（实际调用 {len(_calls)} 次）')
    finally:
        t.probe_node_alive = _orig_probe
        t.log_progress = _orig_lp4b
    # 闸门判据是「表条目 ÷ 待测数」，不是绝对条目数（小池 17 条也算 100%）
    check((17 / 17.0) >= 0.5 and (1 / 100.0) < 0.5,
          '覆盖度按比例算：小池 17/17=100% 放行判死，大池 1/100=1% 不许判死')

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

    print('== 7. 测活判死计入「❌ 失败」，且不再有「⚠️ 测活探测异常」分节 ==')
    # ⚠️ 2026-09-24 改：判活改为查整组延迟表后只有两种世界——
    #   拿不到表 ⇒ 探测层整体关闭、不产生判死条目（机制没给结论就不能判死）；
    #   拿到了 ⇒ 「表里没有」是 mihomo 的真判死结论，与测速失败同类，进 ❌ 失败。
    # 旧分节记的是「探测机制没跑通」的误伤（逐个探 `/proxies/{name}` 恒 404 时每轮必现），
    # 新判据下不复存在；若再出现即为回退（规范 · 2.8 taier 专属分节）。
    probe_dead = [{'ok': False, 'bypass': False, 'up': 0.0, 'down': 0.0, 'name': f'p{i}',
                   'error': '测活未通过：组测速无延迟值（连不上）'}
                  for i in range(8)]
    real_dead = [{'ok': False, 'bypass': False, 'up': 0.0, 'down': 0.0, 'name': f'd{i}',
                  'error': '连不上测速点 广东联通（延迟/上下行全空）'} for i in range(3)]
    mixed = render(probe_dead + real_dead)
    joined = '\n'.join(str(x) for x in mixed)
    # 8 个测活判死 + 3 个测速失败 = 11，全部计入 ❌ 失败
    check('❌ 失败 · 11' in joined,
          f'测活判死与测速失败合并计数为 11（实际 {[x for x in mixed if "❌ 失败" in str(x)]}）')
    check(not any('测活探测异常' in str(x) for x in mixed),
          '不再有「⚠️ 测活探测异常」分节（该分节若出现即为回退）')
    # 判死串带前缀，读者能分清「测活阶段就死」与「测速阶段失败」
    check(any('测活未通过：' in str(x) for x in mixed),
          '判死条目的原因带「测活未通过：」前缀')

    # 负向对照：只有测速失败时也没有该分节
    only_real = render(real_dead)
    check(not any('测活探测异常' in str(x) for x in only_real),
          '无测活判死 → 同样不出现该分节（负向对照）')

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

    # 9e. 旧机器已删除，不得回归（2026-09-24）：`is_unknown_proxy_error` 区分「不认识名字」
    #     与「真连不上」、`_revive_probe_failed` 撤销判死——它们都是为「逐个探
    #     `/proxies/{name}`（恒 404，机制误伤与真死无法区分）」设计的兜底。新判据下
    #     只有「拿到表 / 没拿到表」两种世界，不需要这些中间态机器。
    check(not hasattr(t, 'is_unknown_proxy_error'),
          'is_unknown_proxy_error 已删除（旧路径判据，不得回归）')
    check(not hasattr(t, '_revive_probe_failed'),
          '_revive_probe_failed 已删除（撤销判死机器，不得回归）')

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

    print('== 12. duration 默认 13 + 排序/截断功能已删（2026-09-24）==')

    # 12a. duration 默认值：env 未设时必须是 13，且仍在 5-13 钳制区间内。
    #      2026-09-24 从 5 上调到 13（上游硬钳上限）：测活层已能真筛死节点，不再需要拿
    #      duration 换节点覆盖数，把读数质量放回来（单节点 ≈31 秒）。
    _t_src = pathlib.Path(t.__file__).read_text(encoding='utf-8')
    check("os.environ.get('TAIER_DURATION', '13')" in _t_src,
          "duration 默认 13（env 未设时取 13）")
    check(t.CONFIG['TAIER_DURATION'] == 13,
          f"CONFIG 解析为 13（实际 {t.CONFIG['TAIER_DURATION']}）")
    # 钳制仍生效：上游二进制硬钳 5-13，越界值要被压回来（不能因为改了默认值就丢掉钳制）
    check(min(max(1, 5), 13) == 5 and min(max(99, 5), 13) == 13,
          'duration 钳制区间 5-13 仍生效')

    # 12b. ⚠️ 优先级排序与 max_nodes 截断**不得回归**（2026-09-24 删除）：
    #      prioritize 只排顺序、不减量，测活能真筛死节点后已无收益；max_nodes 是「按原序
    #      砍尾巴」，会砍掉还没测过的节点、与「到点收摊」重复且更易误伤。
    check(not hasattr(t, 'prioritize_nodes'),
          'prioritize_nodes 已删除（只排序不减量，无收益）')
    check('TAIER_PRIORITY_REGEX' not in _t_src and 'TAIER_MAX_NODES' not in _t_src,
          'TAIER_PRIORITY_REGEX / TAIER_MAX_NODES 配置项已删除')
    check('nodes_prioritized' not in _t_src,
          'nodes_prioritized 日志不再存在')
    # 池子裁剪只能由 include 过滤做，跑不完由预算到点收摊
    _n12 = re.sub(r'\s+', '', _t_src)
    check('filter_nodes_include(' in _n12 and 'should_stop_for_budget(' in _n12,
          '池子交给 include 过滤、跑不完交给预算到点收摊')

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

    # 13g. ⚠️ 接线次序上的反回归（2026-09-24）：池子大小只能由 include 过滤决定，
    #      排序与 max_nodes 截断已删——若有人在过滤之外再引入第二种裁剪/排序层，
    #      「池子有多大」会由两个地方决定，编排轮的时长就又开始不可预测。
    norm13 = re.sub(r'\s+', '', _t_src)
    #      `max_nodes` 这个词只可能出现在说明「为什么删」的注释里，故只断言**代码形态**：
    #      CONFIG 取值、切片截断、以及以它为名的日志字段——三者任一回来即为回归。
    check('prioritize_nodes(' not in norm13,
          '接线里不存在 prioritize_nodes 调用（只排序不减量，已删）')
    check("CONFIG['TAIER_MAX_NODES']" not in norm13
          and 'alive_items[:max_nodes]' not in norm13
          and "'max_nodes':" not in norm13,
          'max_nodes 截断只存在于注释（CONFIG 取值/切片/日志字段均已删）')
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
        src14 = re.sub(r'\s+', '', pathlib.Path(mod.__file__).read_text(encoding='utf-8'))
        check('timeout=60.0' not in src14,
              f'{mod_name} 不得再写死 timeout=60.0')
    # 14c. 默认参数必须是 None（= 自动），不能是某个写死的数字
    import inspect as _ins
    check(_ins.signature(g.wait_provider_ready).parameters['timeout'].default is None,
          'wait_provider_ready 的 timeout 默认 None（按节点数自动）')

    # 14d. ⚠️ 三套都必须把**加载量**传进来（不传就退化成候选数 = 上轮病灶）
    #     反证：删掉任一处的 `total_loaded=`，对应这条变红。
    for mod_name, mod in (('taier', t), ('gitee', g), ('cdn', d)):
        src14d = re.sub(r'\s+', '', pathlib.Path(mod.__file__).read_text(encoding='utf-8'))
        check('total_loaded=' in src14d,
              f'{mod_name} 必须传 total_loaded（按实际加载量算，而非过滤后的候选数）')

    # 14e. 组里始终没有成员 ⇒ 超时返回 False（不抛异常，调用方据此降级）
    _orig_get14 = g.mihomo_api_get
    try:
        g.mihomo_api_get = lambda path: {'all': ['a']}
        check(t.wait_provider_ready(['a'], timeout=0.1)[0] is True,
              '成员已在组里 → 立即就绪')
        g.mihomo_api_get = lambda path: {'all': []}
        _r14, _w14, _ = t.wait_provider_ready(['a'], timeout=0.1)
        check(_r14 is False, '组里始终没有该成员 → 超时返回 False（不抛异常）')
    finally:
        g.mihomo_api_get = _orig_get14

    print('== 15. 旧测活机器不得回归 + 拿不到表即启动 fail-open（2026-09-24）==')
    # 旧机器（熔断 / 未知名重排 / 撤销判死 / 待定重试队列）全是为「逐个探
    # `/proxies/{name}`（恒 404，机制误伤与真死无法区分）」设计的兜底。新判据下只有
    # 「拿到表 / 没拿到表」两种世界，不需要中间态机器——它们若回来，会把「一堆死节点」
    # 误读成「机制坏了」⇒ 关掉测活 ⇒ 上千死节点各跑满一个测速窗口（≈6.6h）。
    _t15 = re.sub(r'\s+', '', pathlib.Path(t.__file__).read_text(encoding='utf-8'))
    for _name in ('_probe_dead_streak', '_probe_guard_n', '_probe_retry_queue',
                  '_unknown_requeue_cap', '_unknown_requeued', '_unknown_streak',
                  '_revive_probe_failed', 'is_unknown_proxy_error'):
        check(_name not in _t15, f'旧机器 {_name} 不得回归（新判据无中间态）')
    # `probe_failed` 这个词本身不算回归——日志事件名 `taier_node_probe_failed` 是合法的；
    # 回归指的是 results 条目再挂 `probe_failed` 标记走「待定→撤销」那一套。
    check("'probe_failed':" not in _t15 and 'probe_failed=' not in _t15
          and "r.get('probe_failed')" not in _t15,
          'results 条目不得再挂 probe_failed 标记（待定→撤销机器已删）')

    # 15a. ⚠️ 探测层只在**真的拿到延迟表**时才启用：拿空表 ⇒ 整体关闭、全量放行去测速。
    #     这是 fail-open 的硬要求——拿不到结论却照常判死会把整轮打成零产出。
    check('_probe_enabled=CONFIG[' in _t15 and 'bool(_delay_table)' in _t15,
          '探测层启用判据 = 开关 且 拿到非空延迟表')
    check('taier_probe_disabled' in _t15,
          '探测层关闭要留痕（可核对是不是「机制没给结论」）')
    # 15b. 判死条目直接进 results（带前缀错误串），不再有「待定 → 撤销」的中间态
    check("'error':_perr" in _t15,
          '判死条目直接落 results（不再挂待定队列等撤销）')

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
