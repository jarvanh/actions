#!/usr/bin/env python3
"""gist_nodes.py 的离线自检：用本地假 Sub-Store 跑通「投喂 → 组合 → 取回 YAML → 发布」全链路。

为什么需要它：gist_nodes.py 的正确性有一半取决于 Sub-Store 的 HTTP 契约——接口路径、
订阅/组合的字段名、process 里算子的确切名字（Sub-Store 对未知算子只记日志、不报错，
名字写错会静默不去重）。真实容器只在 GitHub runner 上起，本地改完无从直接验证；
这个假后端把契约固化成断言，改坏了立刻能看出来。

覆盖：
  1. 正向：3 个订阅正文被投喂 → 两个组合订阅（-raw 无 process / 主组合带完整链）→
     取回 YAML → 限量生效 → 上传内容与取回内容一致；
  2. 负向：投喂遇 409（非全新容器）必须失败退出，且提示指向容器不干净；
  3. 负向：Sub-Store 产出的不是 YAML 必须失败退出；
  4. 边界：GIST_NODES_MAX_NODES=0 时 process 里不应出现限量算子；
  5. 负向：Sub-Store 不可达必须失败退出；
  6. 判据：明文链接 / Clash YAML / base64 订阅放行，XML plist / 数据 JSON 挡掉；
  7. 时间窗口：超龄 Gist 被挡掉、MAX_AGE_HOURS=0 时不过滤、整页超龄即停止翻页、
     时间戳缺失或异常时不算超龄；
  8. 搜索收口：整页超龄 / 翻到末页 → 该关键词判为「到头」退出轮转；被限流（429）
     不算到头（限流是按请求随机的）；
  9. 429 抗性：本批内「补一轮」把被限流的页捞回来、两轮都失败才记进 dropped；
     节流器被限流翻倍 / 成功折半 / 封顶 / base=0 时不引入等待。
 10. 抓取收口（15–17，用真实 search_gists 驱动主循环）：
     * 墙钟预算到点收摊，仍拿已抓到的文件走完产出（退出码 0，不是失败）；
     * 连续 N 轮文件数零增长即停；
     * 同一批连续 3 页被限流就熔断本批、且不补一轮。
     三者都配了「关闭该收口 → 一路翻满 max_pages」的负向对照，否则判据恒真也看不出来。
 11. Sub-Store 阶段预算（18–19）：投喂预算耗尽 → 截断投喂、仍用已投喂的产出（退出码 0，
     组合只引用已投喂的）；产出预算耗尽 → 就地失败（退出码 1，省掉建组合/取回就没有产物）。
     两者方向相反，各配负向对照。

跑法：python .github/scripts/proxy-speedtest/tests/test_gist_nodes_substore.py
退出码 0 = 全部通过。
"""
import http.server
import json
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT_DIR = HERE.parent
sys.path.insert(0, str(SCRIPT_DIR))

YAML_BODY = 'proxies:\n- name: a\n  type: vless\n  server: 1.1.1.1\n  port: 443\n- name: b\n  type: trojan\n  server: 2.2.2.2\n  port: 443\n'
RAW_NODES = [{'name': 'a'}, {'name': 'b'}, {'name': 'a'}]  # 解析后 3 个，去重后 2 个

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


class FakeSubStore(http.server.BaseHTTPRequestHandler):
    """只实现 gist_nodes.py 用到的那几个路由，并把收到的请求记下来供断言。"""

    requests = []
    subs_status = 200
    yaml_status = 200
    yaml_body = YAML_BODY
    # 分段模拟耗时（秒）。为什么要按路由分开：投喂是**逐个** POST，而建组合/取回各一次，
    # 两者要能独立变慢才能分别验「投喂预算耗尽可降级」与「产出预算耗尽必须失败」。
    subs_delay = 0.0
    collection_delay = 0.0
    download_delay = 0.0

    def log_message(self, *args):  # 静音
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, status, text):
        body = text.encode()
        self.send_response(status)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        FakeSubStore.requests.append(('GET', self.path, None))
        if self.path.startswith('/api/subs'):
            return self._json(200, [])
        if '/download/collection/' in self.path:
            if FakeSubStore.download_delay:
                time.sleep(FakeSubStore.download_delay)
            target = self.path.split('/')[-1].split('?')[0]
            if target == 'ClashMeta':
                if FakeSubStore.yaml_status != 200:
                    return self._text(FakeSubStore.yaml_status, 'boom')
                return self._text(200, FakeSubStore.yaml_body)
            return self._json(200, RAW_NODES)
        return self._text(404, 'not found')

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        payload = json.loads(self.rfile.read(length).decode() or '{}')
        FakeSubStore.requests.append(('POST', self.path, payload))
        if self.path == '/api/subs':
            if FakeSubStore.subs_delay:
                time.sleep(FakeSubStore.subs_delay)
            if FakeSubStore.subs_status != 200:
                return self._json(FakeSubStore.subs_status, {'error': 'duplicate'})
            return self._json(200, {'name': payload.get('name')})
        if self.path == '/api/collections':
            if FakeSubStore.collection_delay:
                time.sleep(FakeSubStore.collection_delay)
            return self._json(200, {'name': payload.get('name')})
        return self._text(404, 'not found')


def start_server():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeSubStore)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def run_main(gist_nodes, tmpdir, extra_env):
    """跑一次 main()，返回 (退出码, 上传到 Gist 的 YAML, nodes.json 内容)。

    三个被替换的模块级函数在退出时**必须还原**：后面的用例（7–11）要直接调真实的
    search_gists 来验时间窗口，mock 留在原地会让它们静默拿到假数据。
    """
    uploaded = {}

    def fake_update_gist(env, yaml_text=''):
        uploaded['text'] = yaml_text
        return {'ok': True, 'id': 'fakeid', 'html_url': 'https://gist.github.com/fake',
                'yaml': {'filename': 'x.yaml', 'raw_url': 'https://gist.githubusercontent.com/x'}}

    orig = (gist_nodes.search_gists, gist_nodes.collect_all, gist_nodes.update_gist)
    # 第一轮就给 1 个候选，并把**传入的所有关键词**都标成「到头」——否则主循环会
    # 一轮轮翻下去（每轮都重复投喂同样的 3 个订阅），把「投喂 3 个」的断言冲掉。
    gist_nodes.search_gists = lambda queries, *a, **k: (
        [{'id': 'a' * 32, 'owner': 'o1', 'updated': '',
          'url': 'https://gist.github.com/o1/' + 'a' * 32}], set(queries), [])
    gist_nodes.collect_all = lambda *a, **k: (
        [('f1', 'ss://x@1.1.1.1:1#a'), ('f2', 'vless://y@2.2.2.2:2#b'), ('f3', 'trojan://z@3.3.3.3:3#c')],
        dict.fromkeys(gist_nodes.STAT_KEYS, 0) | {'gists_scanned': 1, 'files_kept': 3},
    )
    gist_nodes.update_gist = fake_update_gist

    env = dict(os.environ)
    env.update({'GIST_NODES_WORKDIR': str(tmpdir), 'GIST_NODES_MAX_NODES': '5',
                'GIST_NODES_DRY_RUN': '0', 'GH_TOKEN': 'fake'})
    env.update(extra_env)
    saved = dict(os.environ)
    os.environ.update(env)
    try:
        gist_nodes.main()
        code = 0
    except SystemExit as e:
        code = e.code or 0
    finally:
        os.environ.clear()
        os.environ.update(saved)
        gist_nodes.search_gists, gist_nodes.collect_all, gist_nodes.update_gist = orig

    nodes_json = {}
    path = tmpdir / 'nodes.json'
    if path.exists():
        nodes_json = json.loads(path.read_text(encoding='utf-8'))
    return code, uploaded.get('text', ''), nodes_json


def run_main_real_search(gist_nodes, tmpdir, extra_env):
    """跑一次 main()，但**保留真实的 search_gists**（页面由调用方 mock 的 http_get 供）。

    用途：15–17 验的是主循环的收口逻辑（墙钟预算 / 无进展 / 批内熔断），它长在 main()
    里、又依赖真实的 search_gists 才能被驱动，所以不能像 run_main 那样把 search_gists
    换成假实现——那等于把被测对象本身 mock 掉了。这里只换 collect_all（把候选 Gist 直接
    折算成订阅文件，不真的取文）与 update_gist（不真的发布）。

    返回 (退出码, 上传的 YAML, 真实搜索页请求次数由调用方的 mock 记录)。
    """
    uploaded = {}

    def fake_update_gist(env, yaml_text=''):
        uploaded['text'] = yaml_text
        return {'ok': True, 'id': 'fakeid', 'html_url': 'https://gist.github.com/fake',
                'yaml': {'filename': 'x.yaml', 'raw_url': 'https://gist.githubusercontent.com/x'}}

    def fake_collect(cands, *a, **k):
        n = len(cands)
        return ([('f%d-%d' % (len(cands), i), 'ss://x@1.1.1.1:1#n') for i in range(n)],
                dict.fromkeys(gist_nodes.STAT_KEYS, 0) | {'gists_scanned': n, 'files_kept': n})

    orig = (gist_nodes.collect_all, gist_nodes.update_gist)
    gist_nodes.collect_all = fake_collect
    gist_nodes.update_gist = fake_update_gist

    env = dict(os.environ)
    env.update({'GIST_NODES_WORKDIR': str(tmpdir), 'GIST_NODES_DRY_RUN': '0',
                'GH_TOKEN': 'fake', 'GIST_NODES_PAGE_DELAY': '0',
                'GIST_NODES_MAX_NODES': '0', 'GIST_NODES_QUERIES': 'ss://'})
    env.update(extra_env)
    saved = dict(os.environ)
    os.environ.update(env)
    try:
        gist_nodes.main()
        code = 0
    except SystemExit as e:
        code = e.code or 0
    finally:
        os.environ.clear()
        os.environ.update(saved)
        gist_nodes.collect_all, gist_nodes.update_gist = orig
    return code, uploaded.get('text', '')


def capture_events(gist_nodes, fn, *args, **kwargs):
    """跑 fn，返回 (fn 的返回值, 本次记录到的 log_progress 事件列表)。

    为什么需要它：Sub-Store 预算耗尽走的是 `fail()` → `sys.exit(1)`，光看退出码分不清
    「预算耗尽」和「后端 500」；截断投喂则是**静默降级**（退出码还是 0），只能靠日志点
    （`gist_nodes_push_budget_stop` 的截断计数、`gist_nodes_failed` 的 error 文案）来断言。
    """
    events = []
    orig = gist_nodes.log_progress
    gist_nodes.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
    try:
        return fn(*args, **kwargs), events
    finally:
        gist_nodes.log_progress = orig


def posts(kind):
    return [r for r in FakeSubStore.requests if r[0] == 'POST' and r[1] == kind]


def make_search_page(items):
    """拼一个最小可解析的搜索页：每块含 gist 链接 + relative-time 的 datetime。

    只保留 parse_search_results 真正依赖的三样东西——`.gist-snippet` 分块标记、
    32 位 hex 的 gist 链接、datetime 属性；不复制 GitHub 的真实 DOM。
    """
    blocks = []
    for owner, gist_id, updated in items:
        blocks.append(
            f'<div class="gist-snippet">'
            f'<a href="/{owner}/{gist_id}">{owner}/{gist_id[:8]}</a>'
            f'<relative-time datetime="{updated}">x</relative-time>'
            f'</div>')
    return '<html><body>' + ''.join(blocks) + '</body></html>'


def iso_hours_ago(hours):
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime('%Y-%m-%dT%H:%M:%SZ')


def page_number(url):
    return int(urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get('page', ['1'])[0])


def hexid(n):
    return f'{n:032x}'


def main():
    # 本机若开着系统代理（macOS 常见），urllib 会把 127.0.0.1 **也**送进代理 ——
    # `proxy_bypass('127.0.0.1')` 返回 False，只有 `localhost` 被豁免，而假后端是用
    # `127.0.0.1:<port>` 连的，于是连接被代理拒掉（RemoteDisconnected），整套自检
    # 会在第一步就假失败。这里显式禁用代理：本测试全程只连本机假后端，不需要外网。
    urllib.request.install_opener(
        urllib.request.build_opener(urllib.request.ProxyHandler({})))

    import gist_nodes

    server, base = start_server()
    tmpdir = pathlib.Path(tempfile.mkdtemp(prefix='gist-nodes-test-'))
    try:
        print('== 1. 正向：投喂 → 组合 → 取回 → 发布 ==')
        code, uploaded, nodes = run_main(gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': base})
        check(code == 0, '退出码 0')
        subs = posts('/api/subs')
        check(len(subs) == 3, f'投喂 3 个订阅（实际 {len(subs)}）')
        check(all(p['source'] == 'local' and p.get('content') for _, _, p in subs),
              '每个订阅都是 source=local + content')
        check(all('/' not in p['name'] for _, _, p in subs), '订阅名不含 /（Sub-Store 会拒绝）')
        cols = posts('/api/collections')
        check(len(cols) == 2, f'建 2 个组合订阅（实际 {len(cols)}）')
        by_name = {p['name']: p for _, _, p in cols}
        check(by_name.get('gist-nodes-raw', {}).get('process') == [], '-raw 参照组不带 process')
        main_col = by_name.get('gist-nodes') or {}
        types = [p.get('type') for p in main_col.get('process') or []]
        check(types == ['Useless Filter', 'Handle Duplicate Operator',
                        'Handle Duplicate Operator', 'Script Operator'],
              f'主组合算子链正确（实际 {types}）')
        check(main_col.get('subscriptions') == [p['name'] for _, _, p in subs],
              '主组合引用全部订阅名')
        delete_op = (main_col.get('process') or [{}])[1]
        check('server' in (delete_op.get('args') or {}).get('field', []),
              '去重字段包含 server（按节点身份判重，不是按名字）')
        check('name' not in (delete_op.get('args') or {}).get('field', []),
              '去重字段不含 name（含名字等于不去重）')
        script_op = (main_col.get('process') or [{}])[-1]
        check('slice(0, 5)' in (script_op.get('args') or {}).get('content', ''),
              '限量算子按 GIST_NODES_MAX_NODES 生成')
        check(uploaded == YAML_BODY, '上传到 Gist 的就是 Sub-Store 取回的 YAML')
        check(nodes.get('parsed_count') == len(RAW_NODES) and nodes.get('node_count') == 2,
              f'nodes.json 记录解析/去重计数（{nodes.get("parsed_count")} → {nodes.get("node_count")}）')

        print('== 2. 负向：投喂遇 409（非全新容器）必须失败 ==')
        FakeSubStore.requests.clear()
        FakeSubStore.subs_status = 409
        code, _, _ = run_main(gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': base})
        check(code == 1, '退出码 1')
        check(len(posts('/api/collections')) == 0, '失败时不再建组合订阅')
        FakeSubStore.subs_status = 200

        print('== 3. 负向：Sub-Store 产出的不是 YAML 必须失败 ==')
        FakeSubStore.requests.clear()
        FakeSubStore.yaml_body = '{"error":"something"}'
        code, _, _ = run_main(gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': base})
        check(code == 1, '退出码 1')
        FakeSubStore.yaml_body = YAML_BODY

        print('== 4. 边界：MAX_NODES=0 时不出现限量算子 ==')
        FakeSubStore.requests.clear()
        code, _, _ = run_main(gist_nodes, tmpdir,
                              {'SUB_STORE_BACKEND_URL': base, 'GIST_NODES_MAX_NODES': '0'})
        check(code == 0, '退出码 0')
        cols4 = [p for _, _, p in posts('/api/collections') if p['name'] == 'gist-nodes']
        check(len(cols4) == 1, f'主组合只建了一次（实际 {len(cols4)}）')
        types = [t.get('type') for t in (cols4[0].get('process') or [])]
        check('Script Operator' not in types, f'无限量算子（实际 {types}）')

        print('== 5. 负向：Sub-Store 不可达必须失败 ==')
        code, _, _ = run_main(gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': 'http://127.0.0.1:1'})
        check(code == 1, '退出码 1')

        print('== 6. 订阅判据：明文 / base64 放行，噪声挡掉 ==')
        import base64
        sub_text = '\n'.join(['trojan://p@1.1.1.1:443#n1',
                              'vless://11111111-2222-3333-4444-555555555555@2.2.2.2:443#n2'])
        check(gist_nodes.looks_like_subscription(sub_text), '明文链接列表放行')
        check(gist_nodes.looks_like_subscription('proxies:\n- {name: a, type: ss}'), 'Clash YAML 放行')
        check(gist_nodes.looks_like_subscription(base64.b64encode(sub_text.encode()).decode()),
              'base64 订阅放行（解一段能看出 scheme）')
        check(not gist_nodes.looks_like_subscription('<?xml version="1.0"?>\n<plist><dict>'
                                                    '<key>Program</key><string>http://x/y</string>'
                                                    '</dict></plist>'),
              'XML plist 挡掉（旧判据 :// 会放进来）')
        check(not gist_nodes.looks_like_subscription('{"a": 1, "url": "https://example.com/x"}'),
              '普通 JSON 挡掉')
        check(not gist_nodes.looks_like_subscription('hello'), '短文本挡掉')
        check(not gist_nodes.looks_like_subscription(base64.b64encode(b'{"a": 1}' * 40).decode()),
              'base64 的普通数据挡掉（解出来没有 scheme）')

        print('== 7. 时间窗口：超龄 Gist 必须被挡掉 ==')
        real_http_get = gist_nodes.http_get
        fresh_1h, fresh_23h, stale_30h = iso_hours_ago(1), iso_hours_ago(23), iso_hours_ago(30)
        mixed = make_search_page([('o1', hexid(1), fresh_1h),
                                  ('o2', hexid(2), stale_30h),
                                  ('o3', hexid(3), fresh_23h)])
        gist_nodes.http_get = lambda url, **kw: mixed
        got, exhausted, _ = gist_nodes.search_gists(['ss://'], 1, 'updated', 30, retries=1,
                                                    max_age_hours=24, page_delay=0)
        check(len(got) == 2, f'24h 窗口内只留 2 个（实际 {len(got)}）')
        check({g['id'] for g in got} == {hexid(1), hexid(3)}, '留下的正是两个新鲜的')
        check(exhausted == set(), '整页有新鲜条目 → 关键词不算到头')

        print('== 8. 边界：MAX_AGE_HOURS=0 时不过滤 ==')
        got0, _, _ = gist_nodes.search_gists(['ss://'], 1, 'updated', 30, retries=1,
                                             max_age_hours=0, page_delay=0)
        check(len(got0) == 3, f'0 = 不限，三个全留（实际 {len(got0)}）')

        print('== 9. 整页超龄即停止翻页（不再白挨 429）==')
        seen_pages = []

        def stale_then_fresh(url, **kw):
            seen_pages.append(page_number(url))
            if page_number(url) == 1:
                return make_search_page([('o1', hexid(1), stale_30h), ('o2', hexid(2), stale_30h)])
            return make_search_page([('o3', hexid(3), fresh_1h)])

        gist_nodes.http_get = stale_then_fresh
        got_stale, exhausted_stale, _ = gist_nodes.search_gists(
            ['ss://'], 5, 'updated', 30, retries=1, max_age_hours=24, page_delay=0)
        check(got_stale == [], '整页超龄时一个候选都不留')
        check(seen_pages == [1], f'第 1 页全超龄后不再翻第 2 页（实际翻页 {seen_pages}）')
        check(exhausted_stale == {'ss://'}, '整页超龄的关键词被判为到头')

        print('== 10. 翻到末页（正常返回但没有结果块）判为到头 ==')
        asked = []

        def empty_from_second(url, **kw):
            asked.append(page_number(url))
            if page_number(url) == 1:
                return make_search_page([('o1', hexid(1), fresh_1h)])
            return '<html><body>no results</body></html>'

        gist_nodes.http_get = empty_from_second
        got_e, exhausted_e, _ = gist_nodes.search_gists(['ss://'], 4, 'updated', 30,
                                                        retries=1, max_age_hours=24, page_delay=0)
        check(len(got_e) == 1, f'第 1 页拿到 1 个（实际 {len(got_e)}）')
        check(asked == [1, 2], f'第 2 页无结果块即停、不白翻 3-4 页（实际翻页 {asked}）')
        check(exhausted_e == {'ss://'}, '到头的关键词被标记出来')

        print('== 11. 判据细节：时间戳缺失/异常一律不算超龄 ==')
        now_utc = datetime.now(timezone.utc)
        check(gist_nodes.is_too_old('', now_utc, 24) is False,
              '空时间戳放行（页面结构变化时别整批判掉）')
        check(gist_nodes.is_too_old('not-a-time', now_utc, 24) is False, '解析不了的时间戳放行')
        check(gist_nodes.is_too_old(stale_30h, now_utc, 24) is True, '30 小时前 = 超龄')
        check(gist_nodes.is_too_old(stale_30h, now_utc, 0) is False, '窗口为 0 = 不限')

        print('== 12. 429：本批内补一轮，把被限流的页捞回来 ==')
        real_sleep = gist_nodes.time.sleep
        asked_rl = []

        def flaky_first_page(url, **kw):
            n = page_number(url)
            asked_rl.append(n)
            if n == 1:
                # 前 2 次（= retries）被限流，第 3 次（补一轮）成功
                if asked_rl.count(1) <= 2:
                    raise urllib.error.HTTPError(url, 429, 'Too Many Requests', {}, None)
                return make_search_page([('o1', hexid(1), fresh_1h)])
            return '<html><body>no results</body></html>'

        gist_nodes.http_get = flaky_first_page
        try:
            gist_nodes.time.sleep = lambda sec: None
            got_rl, exhausted_rl, dropped_rl = gist_nodes.search_gists(
                ['ss://'], 2, 'updated', 30, retries=2, max_age_hours=24, page_delay=0)
        finally:
            gist_nodes.time.sleep = real_sleep
        check(len(got_rl) == 1, f'补一轮把被限流的页捞回来了（实际 {len(got_rl)}）')
        check(dropped_rl == [], f'捞回来就不该记进 dropped（实际 {dropped_rl}）')
        check(exhausted_rl == {'ss://'}, '第 2 页无结果块 → 该关键词到头')
        check(asked_rl.count(1) == 3, f'第 1 页共请求 3 次（2 次失败 + 1 次补中）（实际 {asked_rl}）')

        print('== 13. 两轮都被限流的页才记进 dropped（不静默丢）==')
        always = []

        def always_limited(url, **kw):
            always.append(page_number(url))
            raise urllib.error.HTTPError(url, 429, 'Too Many Requests', {}, None)

        gist_nodes.http_get = always_limited
        try:
            gist_nodes.time.sleep = lambda sec: None
            got_x, _, dropped_x = gist_nodes.search_gists(
                ['ss://'], 1, 'updated', 30, retries=2, max_age_hours=24, page_delay=0)
        finally:
            gist_nodes.time.sleep = real_sleep
        check(got_x == [], '两轮都被限流 → 没有候选')
        check(dropped_x == [('ss://', 1)], f'该页记进 dropped（实际 {dropped_x}）')
        check(len(always) == 4, f'本批 2 次 + 补一轮 2 次 = 4 次请求（实际 {len(always)}）')
        gist_nodes.http_get = real_http_get

        print('== 14. 节流器：被限流翻倍、成功折半、封顶 ==')
        pc = gist_nodes.SearchPacer(base=3, ceiling=20)
        check(pc.delay == 3, f'初始 = base（{pc.delay}）')
        pc.penalty()
        check(pc.delay == 6, f'被限 1 次 → 6（{pc.delay}）')
        pc.penalty()
        check(pc.delay == 9, f'被限 2 次 → 9（{pc.delay}）')
        pc.penalty()
        pc.penalty()
        check(pc.delay == 23, f'额外间隔封顶 20 → 23（{pc.delay}）')
        pc.relief()
        check(pc.delay == 13, f'成功一次折半 → 13（{pc.delay}）')
        for _ in range(8):
            pc.relief()
        check(pc.delay == 3, f'连续成功回落到 base（{pc.delay}）')
        pc0 = gist_nodes.SearchPacer(base=0, ceiling=0)
        pc0.penalty()
        check(pc0.delay == 0, f'base=0 时不引入等待（{pc0.delay}）')

        # ---- 15–17：主循环的三个收口。用真实 search_gists 驱动，页面由 mock 的
        # http_get 供；断言落在「翻到第几页」「请求了几次」上——那是收口是否真的
        # 生效的直接证据，比对耗时断言稳（不受机器快慢影响）。
        print('== 15. 墙钟预算：到点收摊，但拿已抓到的文件走完产出 ==')
        base_env = {'SUB_STORE_BACKEND_URL': base, 'GIST_NODES_MAX_PAGES': '40',
                    'GIST_NODES_MAX_AGE_HOURS': '24'}
        asked_budget = []

        def slow_pages(url, **kw):
            n = page_number(url)
            asked_budget.append(n)
            time.sleep(1.2)  # 每页 1.2 秒 > 预算 1 秒 → 第 2 页起必然已过期
            return make_search_page([('o%d' % n, hexid(n), fresh_1h)])

        gist_nodes.http_get = slow_pages
        code, uploaded = run_main_real_search(
            gist_nodes, tmpdir, base_env | {'GIST_NODES_BUDGET_SECONDS': '1'})
        check(code == 0, '退出码 0（预算耗尽 ≠ 失败）')
        check(asked_budget == [1], f'预算 1 秒只翻到第 1 页就收摊（实际 {asked_budget}）')
        check(uploaded == YAML_BODY, '仍拿已抓到的文件走完了 Sub-Store 产出与发布')

        print('== 15b. 负向对照：预算不限时必须一路翻满 max_pages ==')
        asked_free = []

        def fast_pages(url, **kw):
            n = page_number(url)
            asked_free.append(n)
            return make_search_page([('o%d' % n, hexid(n), fresh_1h)])

        gist_nodes.http_get = fast_pages
        code, _ = run_main_real_search(
            gist_nodes, tmpdir, base_env | {'GIST_NODES_BUDGET_SECONDS': '0'})
        check(code == 0, '退出码 0')
        check(asked_free == list(range(1, 41)),
              f'预算 0 = 不限，翻满 40 页（实际 {len(asked_free)} 页）')

        print('== 16. 连续 N 轮零增长即收摊（深层页只剩见过的 Gist）==')
        asked_stall = []

        def dup_deep(url, **kw):
            n = page_number(url)
            asked_stall.append(n)
            if n <= 2:
                return make_search_page([('o1', hexid(1), fresh_1h), ('o2', hexid(2), fresh_1h)])
            return make_search_page([('o1', hexid(1), fresh_1h)])  # 老面孔，seen 会滤掉

        gist_nodes.http_get = dup_deep
        code, _ = run_main_real_search(
            gist_nodes, tmpdir, base_env | {'GIST_NODES_BUDGET_SECONDS': '0',
                                            'GIST_NODES_NO_PROGRESS_ROUNDS': '4'})
        check(code == 0, '退出码 0')
        check(asked_stall == list(range(1, 11)),
              f'零增长满 4 轮即停（第 5 轮 page_from=9 → 最远第 10 页；实际 {asked_stall}）')

        print('== 16b. 负向对照：关闭该收口时必须一路翻满 max_pages ==')
        asked_stall2 = []

        def dup_deep2(url, **kw):
            n = page_number(url)
            asked_stall2.append(n)
            if n <= 2:
                return make_search_page([('o1', hexid(1), fresh_1h), ('o2', hexid(2), fresh_1h)])
            return make_search_page([('o1', hexid(1), fresh_1h)])

        gist_nodes.http_get = dup_deep2
        code, _ = run_main_real_search(
            gist_nodes, tmpdir, base_env | {'GIST_NODES_BUDGET_SECONDS': '0',
                                            'GIST_NODES_NO_PROGRESS_ROUNDS': '0'})
        check(code == 0, '退出码 0')
        check(max(asked_stall2) == 40, f'零增长收口关闭后翻满 40 页（实际最远 {max(asked_stall2)}）')

        print('== 17. 批内熔断：连续 3 页被限流就中止本批且不补一轮 ==')
        # 必须两个关键词：pages_per_round=2 时单关键词一批只有 2 页，连续计数到不了 3。
        two_q_env = {'SUB_STORE_BACKEND_URL': base, 'GIST_NODES_MAX_PAGES': '40',
                     'GIST_NODES_MAX_AGE_HOURS': '24', 'GIST_NODES_BUDGET_SECONDS': '0',
                     'GIST_NODES_NO_PROGRESS_ROUNDS': '4', 'GIST_NODES_QUERIES': 'ss://,vless://'}
        qid = {'ss://': 1, 'vless://': 2}
        reqs = []

        def limited_deep(url, **kw):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            q = qs.get('q', [''])[0]
            n = int(qs.get('page', ['1'])[0])
            reqs.append((q, n))
            if n <= 2:
                return make_search_page([('o', hexid(qid[q] * 10 + n), fresh_1h)])
            raise urllib.error.HTTPError(url, 429, 'Too Many Requests', {}, None)

        gist_nodes.http_get = limited_deep
        try:
            gist_nodes.time.sleep = lambda sec: None  # 退避是 5/10/20 秒，不能真等
            code, _ = run_main_real_search(gist_nodes, tmpdir, two_q_env)
        finally:
            gist_nodes.time.sleep = real_sleep
        check(code == 0, '退出码 0')
        check(('vless://', 4) not in reqs,
              f'熔断后本批剩余页一个都不打（vless:// 第 4 页被跳过；实际请求 {sorted(set(reqs))[:6]}…）')
        check(reqs.count(('ss://', 3)) == 4,
              f'只跑满 4 次重试、没有补一轮（否则是 8 次；实际 {reqs.count(("ss://", 3))}）')

        print('== 17b. 负向对照：关闭熔断时会补一轮（请求数翻倍）==')
        reqs2 = []

        def limited_deep2(url, **kw):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            q = qs.get('q', [''])[0]
            n = int(qs.get('page', ['1'])[0])
            reqs2.append((q, n))
            if n <= 2:
                return make_search_page([('o', hexid(qid[q] * 10 + n), fresh_1h)])
            raise urllib.error.HTTPError(url, 429, 'Too Many Requests', {}, None)

        gist_nodes.http_get = limited_deep2
        try:
            gist_nodes.time.sleep = lambda sec: None
            code, _ = run_main_real_search(
                gist_nodes, tmpdir, two_q_env | {'GIST_NODES_MAX_CONSECUTIVE_LIMITED': '0'})
        finally:
            gist_nodes.time.sleep = real_sleep
        check(code == 0, '退出码 0')
        check(reqs2.count(('vless://', 4)) == 8,
              f'熔断关闭 → 该页被请求 4（本批）+ 4（补一轮）次（实际 {reqs2.count(("vless://", 4))}）')
        gist_nodes.http_get = real_http_get

        # ---- 18–19：Sub-Store 阶段的预算。投喂可降级（少几个订阅），产出必须失败
        # （省掉就没有产物）。两者方向相反，所以要分别验，且各自配负向对照。
        print('== 18. Sub-Store 投喂预算耗尽 → 截断投喂，仍用已投喂的产出 ==')
        FakeSubStore.requests.clear()
        FakeSubStore.subs_delay = 0.6
        (code, _, _), ev18 = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir,
            {'SUB_STORE_BACKEND_URL': base, 'SUB_STORE_BUDGET_SECONDS': '2'})
        FakeSubStore.subs_delay = 0.0
        stops18 = [e for e in ev18 if e['stage'] == 'gist_nodes_push_budget_stop']
        check(code == 0, '退出码 0（投喂被截断 ≠ 失败）')
        check(len(stops18) == 1 and 1 <= stops18[0]['pushed'] <= 2,
              f'投喂被预算截断（实际 {stops18[0] if stops18 else "未触发"}）')
        subs18 = posts('/api/subs')
        check(len(subs18) == (stops18[0]['pushed'] if stops18 else -1),
              f'POST /api/subs 次数 = 截断时已投喂数（实际 {len(subs18)}）')
        cols18 = [p for _, _, p in posts('/api/collections') if p['name'] == 'gist-nodes']
        check(len(cols18) == 1
              and cols18[0]['subscriptions'] == [p['name'] for _, _, p in subs18],
              '组合订阅只引用已投喂的那几个 —— 截断之后仍然产出了订阅')

        print('== 18b. 负向对照：预算 0 = 不限时必须全部投喂 ==')
        FakeSubStore.requests.clear()
        FakeSubStore.subs_delay = 0.6
        (code, _, _), ev18b = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir,
            {'SUB_STORE_BACKEND_URL': base, 'SUB_STORE_BUDGET_SECONDS': '0'})
        FakeSubStore.subs_delay = 0.0
        check(code == 0, '退出码 0')
        check(len(posts('/api/subs')) == 3,
              f'预算不限 → 3 个全投喂（实际 {len(posts("/api/subs"))}）')
        check(not [e for e in ev18b if e['stage'] == 'gist_nodes_push_budget_stop'],
              '预算不限时不该出现截断日志')

        print('== 19. Sub-Store 产出预算耗尽 → 就地失败，不硬等到 job 超时 ==')
        FakeSubStore.requests.clear()
        FakeSubStore.collection_delay = 0.6
        (code, _, _), ev19 = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir,
            {'SUB_STORE_BACKEND_URL': base, 'SUB_STORE_BUDGET_SECONDS': '1'})
        FakeSubStore.collection_delay = 0.0
        check(code == 1, '退出码 1（建组合/取回省掉就没有产物，失败是对的）')
        errs19 = [e.get('error', '') for e in ev19 if e['stage'] == 'gist_nodes_failed']
        check(any('预算' in str(e) for e in errs19),
              f'失败原因指向预算耗尽（实际 {errs19}）')
        check(len(posts('/api/subs')) == 3, '失败发生在投喂之后（投喂段不受产出预算影响）')
    finally:
        server.shutdown()
        shutil.rmtree(tmpdir, ignore_errors=True)

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
