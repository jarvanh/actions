#!/usr/bin/env python3
"""alive_filter.py 的离线自检：用假 mihomo 驱动健康检查过滤，验「只丢明确判死的」。

为什么需要它：这一层是「发布前把 12635 个节点压成几百个」的关口，它的坏法都很隐蔽——

  * **判据反了**：把「还没出结论」当成「死」，于是把一大半活节点丢掉，下游拿到一个
    比不过滤还小的订阅，而且没有任何报错（只是少了）。
  * **fail-open 失效**：mihomo 起不来 / 超时 / API 报错时若抛出异常，整个 gistnodes
    步骤失败——那是**零节点发布**，比不过滤糟得多。
  * **全判死没兜底**：探测目标本身不可达时（所有节点都「死」），若照样发布空订阅，
    下游一个节点都测不了。
  * **稳定判据过早**：mihomo 刚起来、第一轮还没探出结论时就 break，等于没过滤。

这些在真实 runner 上要么看不出来（静默少节点）、要么代价极高（整轮白跑），所以固化
成断言。假 mihomo 实现三个路由：`/version`（就绪探活）、`/providers/proxies`（结论）。

跑法：python .github/scripts/proxy-speedtest/tests/test_alive_filter.py
退出码 0 = 全部通过。
"""
import http.server
import json
import pathlib
import sys
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


class FakeMihomo(http.server.BaseHTTPRequestHandler):
    """假 mihomo：按 `plan` 逐次返回不同的 /providers/proxies 快照。

    `plan` 是「每次读快照时该返回什么」的序列，用尽后一直返回最后一个 —— 这样既能模拟
    「一开始一个结论都没有、随后陆续出结论」，也能模拟「卡住不动」（稳定判据该收尾）。
    """

    plan = []
    calls = 0
    version_ok = True
    snapshot_status = 200

    def log_message(self, *a):
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/version':
            if not FakeMihomo.version_ok:
                return self._send(500, {'message': 'boom'})
            return self._send(200, {'version': 'fake-1.0'})
        if self.path.startswith('/providers/proxies'):
            if FakeMihomo.snapshot_status != 200:
                return self._send(FakeMihomo.snapshot_status, {'message': 'boom'})
            idx = min(FakeMihomo.calls, len(FakeMihomo.plan) - 1)
            FakeMihomo.calls += 1
            return self._send(200, FakeMihomo.plan[idx])
        return self._send(404, {'message': 'not found'})


def providers_payload(states, extra_unloaded=0):
    """造一份 /providers/proxies 响应：`states` 是 {名字: alive 值 or None}。

    `alive=None` 表示 mihomo 还没给这个节点结论（字段缺失），这是与 `alive=False`
    **必须区分**的两种状态——前者要保留，后者才能丢。
    """
    proxies = []
    for name, alive in states.items():
        item = {'name': name, 'type': 'ss', 'server': '1.1.1.1', 'port': 443}
        if alive is not None:
            item['alive'] = alive
        proxies.append(item)
    return {'providers': {'alive-filter': {'name': 'alive-filter',
                                           'proxies': proxies,
                                           'updatedAt': 'now'},
                          'AUTO': {'name': 'AUTO', 'proxies': []}}}


def start_server():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeMihomo)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def nodes(names):
    return [{'name': n, 'type': 'ss', 'server': '1.1.1.1', 'port': 443, 'cipher': 'aes-128-gcm',
             'password': 'p'} for n in names]


def run_filter(af, base, proxies, plan, tmpdir, health_env=True, **kw):
    """跑一次 filter_alive，返回 (活节点, 报告, 事件列表)。

    mihomo 的启动被整体 stub 掉（`_start_mihomo` 换空实现）：本自检验的是**过滤语义**，
    不是下载二进制/起进程那套（那套在 taier/gitee 的自检里已覆盖，且需要真实内核）。

    `health_env=False` 时不注入 `PROXY_SPEEDTEST_HEALTHCHECK_URL` —— 用于验「env 缺失时
    落到与下游同一个默认目标」。默认注入是为了让绝大多数用例有一个可断言的已知值。
    """
    events = []
    saved = (af._start_mihomo, af.MIHOMO_API, af.log_progress)
    af._start_mihomo = lambda: {'version': 'fake'}
    af.MIHOMO_API = base
    af.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
    FakeMihomo.plan = plan
    FakeMihomo.calls = 0
    FakeMihomo.version_ok = True
    FakeMihomo.snapshot_status = 200
    env = {'PROXY_SPEEDTEST_HEALTHCHECK_URL': 'http://hc/'} if health_env else {}
    try:
        alive, report = af.filter_alive(env, proxies, workdir=tmpdir, **kw)
    finally:
        af._start_mihomo, af.MIHOMO_API, af.log_progress = saved
    return alive, report, events


def main():
    # 本机若开着系统代理，urllib 会把 127.0.0.1 也送进代理 —— 见 test_gist_nodes_substore
    # 里同一段注释。这里全程只连本机假 mihomo。
    import urllib.request
    urllib.request.install_opener(
        urllib.request.build_opener(urllib.request.ProxyHandler({})))

    import tempfile
    import alive_filter as af
    import speedtest_gitee as g

    server, base = start_server()
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix='alive-filter-test-'))
    try:
        print('== 1. 正向：只保留判活的，明确判死的丢掉，没结论的保留 ==')
        proxies = nodes(['a', 'b', 'c', 'd'])
        # 一次就全部出结论：a/c 活、b 死、d 还没结论（alive 缺失）
        plan = [providers_payload({'a': True, 'b': False, 'c': True, 'd': None})]
        alive, rep, _ = run_filter(af, base, proxies, plan, tmpdir,
                                   budget_seconds=30)
        names = [p['name'] for p in alive]
        check(names == ['a', 'c', 'd'],
              f'活的 + 没结论的保留，死的丢掉（实际 {names}）')
        check(rep['alive'] == 3 and rep['dead'] == 1,
              f'报告计数正确（实际 alive={rep["alive"]} dead={rep["dead"]}）')
        check(rep['unmatched'] == 1, f'没结论的记进 unmatched（实际 {rep["unmatched"]}）')
        check(rep['skipped'] is False, '正常完成不算 skipped')
        check(rep['healthcheck_url'] == 'http://hc/', '健康检查目标透传进报告')

        print('== 2. 边界：必须与下游用同一个健康检查目标（否则这里判活、下游判死）==')
        # env 里给的优先；env 没给才落到与 speedtest_gitee 同一个 DEFAULT_HEALTHCHECK_URL。
        alive, rep, _ = run_filter(af, base, nodes(['a']),
                                   [providers_payload({'a': True})], tmpdir,
                                   health_env=False, budget_seconds=30)
        check(rep['healthcheck_url'] == g.DEFAULT_HEALTHCHECK_URL,
              f'env 缺失时落到下游同一默认目标（实际 {rep["healthcheck_url"]}）')
        alive, rep, _ = run_filter(af, base, nodes(['a']),
                                   [providers_payload({'a': True})], tmpdir,
                                   budget_seconds=30)
        check(rep['healthcheck_url'] == 'http://hc/',
              f'env 给了就用 env 的（实际 {rep["healthcheck_url"]}）')

        print('== 3. 稳定判据：结论不再增长就收尾（不等「全部出结论」）==')
        # 第 1 次读：1 个结论；第 2..n 次：仍是 1 个（其余节点一直没结论）。
        # 靠稳定轮数收尾，否则会一直等到预算耗尽 → fail-open 放行全部，过滤白做。
        stuck = providers_payload({'a': True, 'b': None, 'c': None})
        alive, rep, _ = run_filter(af, base, nodes(['a', 'b', 'c']), [stuck], tmpdir,
                                   budget_seconds=60)
        check(rep['skipped'] is False, f'稳定判据收尾而非 fail-open（实际 {rep}）')
        check(rep['alive'] == 3, f'卡住的节点按「没结论」保留（实际 {rep["alive"]}）')
        check(rep['dead'] == 0, '一个都没判死')

        print('== 4. 冷启动宽限：第一轮一个结论都没有时不得立刻收尾 ==')
        # 第 1 次读：0 个结论；之后才出结论。若没有宽限 + 稳定判据，
        # 会在第一轮就 break，把「还没开始探」误判成「探完了」。
        plan = [providers_payload({'a': None, 'b': None}),
                providers_payload({'a': True, 'b': False}),
                providers_payload({'a': True, 'b': False})]
        alive, rep, _ = run_filter(af, base, nodes(['a', 'b']), plan, tmpdir,
                                   budget_seconds=60)
        check([p['name'] for p in alive] == ['a'],
              f'等到真结论才收尾，死节点被丢掉（实际 {[p["name"] for p in alive]}）')
        check(rep['dead'] == 1, f'实际判死 1 个（实际 {rep["dead"]}）')

        print('== 5. fail-open：预算耗尽 → 原样放行全部并记 skipped ==')
        # 预算 0 = 不限，改用极小预算 + 慢快照更可控：这里直接让快照永远是「0 结论」，
        # 于是只能靠预算退出。budget_seconds=1 会在第一轮后到点。
        never = providers_payload({'a': None, 'b': None})
        alive, rep, ev = run_filter(af, base, nodes(['a', 'b']), [never], tmpdir,
                                    budget_seconds=1)
        check(rep['skipped'] is True, f'预算耗尽 → skipped（实际 {rep}）')
        check(rep['skip_reason'] == 'budget_exhausted',
              f'原因写明 budget_exhausted（实际 {rep["skip_reason"]}）')
        check([p['name'] for p in alive] == ['a', 'b'], '原样放行全部（不是空订阅）')
        check([e['stage'] for e in ev] == ['alive_filter_skipped'],
              f'打了 skipped 日志（实际 {[e["stage"] for e in ev]}）')

        print('== 6. fail-open：mihomo 起不来 → 原样放行全部 ==')

        def boom():
            raise RuntimeError('cannot start')

        saved_start = af._start_mihomo
        af._start_mihomo = boom
        FakeMihomo.plan = [providers_payload({'a': True})]
        FakeMihomo.calls = 0
        events = []
        saved_log = af.log_progress
        af.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
        af.MIHOMO_API = base
        try:
            alive, rep = af.filter_alive({}, nodes(['a', 'b']), workdir=tmpdir, budget_seconds=30)
        finally:
            af._start_mihomo = saved_start
            af.log_progress = saved_log
        check(rep['skipped'] is True and rep['skip_reason'] == 'mihomo_start_failed',
              f'起不来 → skipped/mihomo_start_failed（实际 {rep}）')
        check([p['name'] for p in alive] == ['a', 'b'], '起不来时原样放行全部')

        print('== 7. fail-open：API 报错 → 原样放行全部 ==')
        FakeMihomo.snapshot_status = 500
        alive, rep, _ = run_filter(af, base, nodes(['a']), [providers_payload({'a': True})],
                                   tmpdir, budget_seconds=30)
        check(rep['skipped'] is True and rep['skip_reason'] == 'snapshot_failed',
              f'API 500 → skipped/snapshot_failed（实际 {rep}）')
        check(len(alive) == 1, 'API 报错时原样放行全部')
        FakeMihomo.snapshot_status = 200

        print('== 8. 全判死时报告如实（调用方据此触发「不过滤」回退）==')
        # filter_alive 本身不决定回退（那是 gist_nodes 的事），但它必须**如实**
        # 报出「0 活」——若这里悄悄放行全部，gist_nodes 的 all_dead 兜底就永远不触发。
        plan = [providers_payload({'a': False, 'b': False})]
        alive, rep, _ = run_filter(af, base, nodes(['a', 'b']), plan, tmpdir, budget_seconds=30)
        check(alive == [], f'全部判死 → 返回空（实际 {[p["name"] for p in alive]}）')
        check(rep['alive'] == 0 and rep['dead'] == 2 and rep['skipped'] is False,
              f'如实报告全死、而不是静默放行（实际 {rep}）')

        print('== 9. 边界：空输入不炸、也不必起 mihomo ==')
        started = []
        saved_start = af._start_mihomo
        af._start_mihomo = lambda: started.append(1)
        try:
            alive, rep = af.filter_alive({}, [], workdir=tmpdir, budget_seconds=30)
        finally:
            af._start_mihomo = saved_start
        check(alive == [] and rep['total'] == 0, '空输入返回空')
        check(started == [], '空输入不启动 mihomo（省掉一次几十 MB 下载）')

        print('== 10. 排除项：AUTO / default 这类非节点 provider 不进结论集 ==')
        payload = {'providers': {'alive-filter': {'proxies': [
            {'name': 'a', 'alive': True}]},
            'AUTO': {'proxies': [{'name': 'AUTO', 'alive': True}]},
            'default': {'proxies': [{'name': 'default', 'alive': False}]}}}
        alive, rep, _ = run_filter(af, base, nodes(['a']), [payload], tmpdir, budget_seconds=30)
        check([p['name'] for p in alive] == ['a'], f'只认自建 provider（实际 {[p["name"] for p in alive]}）')
        check(rep['dead'] == 0, 'AUTO/default 的结论不算数（否则会误判死）')

        print('== 11. 过滤后产出的 YAML 可被 mihomo 再读回（格式不得被破坏）==')
        import yaml
        out = tmpdir / 'alive-filter' / 'alive-filter-proxies.yaml'
        check(out.exists(), f'写了 provider 用的 YAML（{out}）')
        loaded = (yaml.safe_load(out.read_text(encoding='utf-8')) or {}).get('proxies') or []
        check(len(loaded) == 4, f'写进去的是**过滤前**的全量（实际 {len(loaded)}）')
        check(all('name' in p and 'server' in p for p in loaded), '节点字段完整')
        cfg = yaml.safe_load(af.MIHOMO_CONFIG.read_text(encoding='utf-8')) or {}
        hc = ((cfg.get('proxy-providers') or {}).get('alive-filter') or {}).get('health-check') or {}
        check(hc.get('lazy') is False,
              'lazy 必须 false（true 的话 alive 永远缺失，本层永远等不到结论）')
        check(hc.get('expected-status') == 204, f'expected-status=204（实际 {hc.get("expected-status")}）')
        check(hc.get('url') == 'http://hc/' or hc.get('url') == g.DEFAULT_HEALTHCHECK_URL,
              f'健康检查目标写进配置（实际 {hc.get("url")}）')

    finally:
        server.shutdown()

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
