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
     只跳过本页、不放弃整个关键词（实测限流是短窗口突发型，隔几秒就恢复）。

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
import urllib.error
import urllib.parse
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
            name = self.path.split('/download/collection/', 1)[1].split('/', 1)[0]
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
            if FakeSubStore.subs_status != 200:
                return self._json(FakeSubStore.subs_status, {'error': 'duplicate'})
            return self._json(200, {'name': payload.get('name')})
        if self.path == '/api/collections':
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
          'url': 'https://gist.github.com/o1/' + 'a' * 32}], set(queries))
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
        got, exhausted = gist_nodes.search_gists(['ss://'], 1, 'updated', 30, retries=1,
                                                 max_age_hours=24, page_delay=0)
        check(len(got) == 2, f'24h 窗口内只留 2 个（实际 {len(got)}）')
        check({g['id'] for g in got} == {hexid(1), hexid(3)}, '留下的正是两个新鲜的')
        check(exhausted == set(), '整页有新鲜条目 → 关键词不算到头')

        print('== 8. 边界：MAX_AGE_HOURS=0 时不过滤 ==')
        got0, _ = gist_nodes.search_gists(['ss://'], 1, 'updated', 30, retries=1,
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
        got_stale, exhausted_stale = gist_nodes.search_gists(
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
        got_e, exhausted_e = gist_nodes.search_gists(['ss://'], 4, 'updated', 30, retries=1,
                                                     max_age_hours=24, page_delay=0)
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

        print('== 12. 429 只跳过本页，不放弃整个关键词 ==')
        asked_rl = []

        def rate_limited_first_page(url, **kw):
            asked_rl.append(page_number(url))
            if page_number(url) == 1:
                raise urllib.error.HTTPError(url, 429, 'Too Many Requests', {}, None)
            return make_search_page([('o2', hexid(2), fresh_1h)])

        real_sleep = gist_nodes.time.sleep
        gist_nodes.http_get = rate_limited_first_page
        try:
            gist_nodes.time.sleep = lambda sec: None
            got_rl, exhausted_rl = gist_nodes.search_gists(
                ['ss://'], 2, 'updated', 30, retries=2, max_age_hours=24, page_delay=0)
        finally:
            gist_nodes.time.sleep = real_sleep
        check(len(got_rl) == 1, f'第 1 页被限流后，第 2 页仍取到 1 个（实际 {len(got_rl)}）')
        check(asked_rl == [1, 1, 2], f'第 1 页重试 2 次后跳过、继续第 2 页（实际 {asked_rl}）')
        check(exhausted_rl == set(), '被限流不算「到头」（否则整类节点会被静默丢掉）')
        gist_nodes.http_get = real_http_get
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
