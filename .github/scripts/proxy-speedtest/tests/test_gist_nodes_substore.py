#!/usr/bin/env python3
"""gist_nodes.py 的离线自检：用本地假 Sub-Store 跑通「投喂 → 组合 → 取回 YAML → 发布」全链路。

为什么需要它：gist_nodes.py 的正确性有一半取决于 Sub-Store 的 HTTP 契约——接口路径、
订阅/组合的字段名、process 里算子的确切名字（Sub-Store 对未知算子只记日志、不报错，
名字写错会静默不去重）。真实容器只在 GitHub runner 上起，本地改完无从直接验证；
这个假后端把契约固化成断言，改坏了立刻能看出来。

覆盖：
  1. 正向：3 个订阅正文被投喂 → 两个组合订阅（-raw 无 process / 主组合带完整链）→
     取回 YAML → 限量生效 → 上传内容与取回内容一致；
     并核对算子链：两个剔除算子（协议 / Cloudflare 段）都排在去重之前、CF 算子内嵌的
     v4/v6 段表与官方清单逐条一致、判定只读 server 不碰 name/servername；
  2. 负向：投喂遇 409（非全新容器）必须失败退出，且提示指向容器不干净；
  3. 负向：Sub-Store 产出的不是 YAML 必须失败退出；
  4. 边界：GIST_NODES_MAX_NODES=0 时 process 里不应出现限量算子（剔除算子仍在）；
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
12. CF 段表实时拉取（23）：成功 → 用线上表且标 `api`；非 JSON / `success=false` / 列表为空 /
    缺字段 / CIDR 非法 / 网络异常 → 一律回退内置快照且标 `fallback`、绝不冒泡；
    另验算子内嵌的是**传进来的**段表、不是偷偷读常量。
    主流程（1–5）里 `fetch_cf_cidrs` 被 stub 成回退表，保证自检离线且不随线上段表漂移。
13. 控制字符清洗（24）：节点名里混进 C1 控制字符（`U+009F`，实测事故）时仍能解析成功并
    发布干净 YAML；`\t` / `\n` / `\r` 必须保留（删了会破坏 YAML 结构）。反证：把
    `strip_nonprintable` 的调用去掉，24b 立刻变红——这正是 2026-09-24 连续两轮
    编排轮 exit 1 的原貌。

**不覆盖健康检查过滤与试装排雷**：两者都要另起 mihomo（几十 MB 下载 + 每轮几十秒等待），
本机跑只会一路超时。这里统一用 `GIST_NODES_ALIVE_FILTER=0` / `GIST_NODES_TRIAL_LOAD=0`
关掉（过滤语义由 `tests/test_alive_filter.py` 专测，试装由 `tests/test_trial_load.py` 专测）；
顺带也证明了这两个开关真的能关掉。

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


def run_main(gist_nodes, tmpdir, extra_env, carryover_text=None):
    """跑一次 main()，返回 (退出码, 上传到 Gist 的 YAML, nodes.json 内容)。

    四个被替换的模块级函数在退出时**必须还原**：后面的用例（7–11）要直接调真实的
    search_gists 来验时间窗口，mock 留在原地会让它们静默拿到假数据。

    `carryover_text` 是 stub 掉的「上一轮发布到 Gist 的订阅正文」：默认 None = 上一轮还没有
    这个文件（首次运行）。**必须 stub**——真实的 fetch_carryover 会去打 api.github.com，
    本机 .env 里恰好有 PROXY_SPEEDTEST_GIST_ID 时就会真的发请求，自检就不再离线了。

    `fetch_cf_cidrs` 同样 **必须 stub**：真实的它去拉 api.cloudflare.com，自检要离线且
    结果确定；拉了真表反而会让「内嵌哪份段表」随线上变化而漂移。真实拉取逻辑（成功/
    各种失败回退）由用例 23 用假 HTTP 层单独验。
    """
    uploaded = {}

    def fake_update_gist(env, yaml_text=''):
        uploaded['text'] = yaml_text
        return {'ok': True, 'id': 'fakeid', 'html_url': 'https://gist.github.com/fake',
                'yaml': {'filename': 'x.yaml', 'raw_url': 'https://gist.githubusercontent.com/x'}}

    orig = (gist_nodes.search_gists, gist_nodes.collect_all, gist_nodes.update_gist,
            gist_nodes.fetch_carryover, gist_nodes.fetch_cf_cidrs)
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
    gist_nodes.fetch_carryover = lambda env, timeout, max_bytes: carryover_text
    # 固定成内置回退表：断言里比对的就是这份，跑起来与线上段表无关。
    gist_nodes.fetch_cf_cidrs = lambda env, timeout: (
        gist_nodes.CF_IPV4_CIDRS_FALLBACK, gist_nodes.CF_IPV6_CIDRS_FALLBACK, 'fallback')

    env = dict(os.environ)
    env.update({'GIST_NODES_WORKDIR': str(tmpdir), 'GIST_NODES_MAX_NODES': '5',
                # 关掉健康检查过滤与试装排雷：本自检验的是 Sub-Store 那条链路，而这两层
                # 都要另起 mihomo（几十 MB 下载 + 每轮几十秒等待），本机只会一路超时失败。
                # 过滤由 tests/test_alive_filter.py 专测、试装由 tests/test_trial_load.py 专测；
                # 这里只要它们不干扰断言（顺带也证明这两个开关真的能关掉）。
                'GIST_NODES_ALIVE_FILTER': '0', 'GIST_NODES_TRIAL_LOAD': '0',
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
        gist_nodes.search_gists, gist_nodes.collect_all, gist_nodes.update_gist, \
            gist_nodes.fetch_carryover, gist_nodes.fetch_cf_cidrs = orig

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

    `fetch_cf_cidrs` **必须一起 stub**：调用方用 mock 的 http_get 供搜索页并按 URL 数
    「翻到第几页」，而真实的 fetch_cf_cidrs 也打 http_get ⇒ 会被这个 mock 当成一次翻页
    计数，把 `asked_*` 序列多插一项、断言全乱。这里它也不是被测对象（拉取逻辑由用例 23
    专测），固定成回退表即可。

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

    orig = (gist_nodes.collect_all, gist_nodes.update_gist, gist_nodes.fetch_cf_cidrs)
    gist_nodes.collect_all = fake_collect
    gist_nodes.update_gist = fake_update_gist
    gist_nodes.fetch_cf_cidrs = lambda env, timeout: (
        gist_nodes.CF_IPV4_CIDRS_FALLBACK, gist_nodes.CF_IPV6_CIDRS_FALLBACK, 'fallback')

    env = dict(os.environ)
    env.update({'GIST_NODES_WORKDIR': str(tmpdir), 'GIST_NODES_DRY_RUN': '0',
                'GH_TOKEN': 'fake', 'GIST_NODES_PAGE_DELAY': '0',
                # 同 run_main：过滤与试装另测，这里关掉以免拖时间（两者都要起 mihomo）
                'GIST_NODES_ALIVE_FILTER': '0', 'GIST_NODES_TRIAL_LOAD': '0',
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
        gist_nodes.collect_all, gist_nodes.update_gist, gist_nodes.fetch_cf_cidrs = orig
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
        check(types == ['Useless Filter', 'Script Operator', 'Script Operator',
                        'Handle Duplicate Operator', 'Handle Duplicate Operator',
                        'Script Operator'],
              f'主组合算子链正确（实际 {types}）')
        check(main_col.get('subscriptions') == [p['name'] for _, _, p in subs],
              '主组合引用全部订阅名')
        # 两个剔除算子都必须排在去重之前：先剔掉不要的节点，去重才有意义
        check(types.index('Handle Duplicate Operator') == 3,
              '两个剔除算子都排在去重之前（去重从第 4 个算子才开始）')
        excl_op = (main_col.get('process') or [{}])[1]
        excl_js = (excl_op.get('args') or {}).get('content', '')
        check('proxies.filter' in excl_js, f'剔除算子用 filter（实际 {excl_js!r}）')
        check('"http"' in excl_js and '"socks5"' in excl_js,
              f'剔除 http 与 socks5（实际 {excl_js!r}）')
        check('toLowerCase' in excl_js,
              '大小写归一后再比对，避免 HTTP/Http 漏网')
        # CF 剔除算子：判定只看 server，且必须带上官方 v4/v6 段表
        cf_op = (main_col.get('process') or [{}])[2]
        cf_js = (cf_op.get('args') or {}).get('content', '')
        check('function operator' in cf_js,
              'CF 剔除算子定义了名为 operator 的函数（Sub-Store 靠这个名字取函数）')
        check('p.server' in cf_js or 'p && p.server' in cf_js,
              f'CF 判定读 server 字段（实际 {cf_js[:120]!r}）')
        check('servername' not in cf_js and 'name' not in cf_js.replace('function', ''),
              'CF 判定不碰 servername / name（按名筛会误伤，实测 1857 个 CF 节点里仅 64 个名字带 cf）')
        # v4 段在算子里是 [网络地址, 前缀长度] 拆分形式（不是 "x.x.x.x/nn" 字符串），
        # 断言必须照实际格式来，否则判据恒假。
        # **段表在这里写成字面量、不从 gist_nodes 读**：读常量的话断言会自我指涉——
        # 把常量删到只剩一段，测试照样全绿，等于没护栏。这里独立复刻云官方 API 的清单，
        # 常量被改窄/改错就会立刻红。
        OFFICIAL_V4 = ['173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22',
                       '103.31.4.0/22', '141.101.64.0/18', '108.162.192.0/18',
                       '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22',
                       '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13',
                       '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22']
        OFFICIAL_V6 = ['2400:cb00::/32', '2606:4700::/32', '2803:f800::/32',
                       '2405:b500::/32', '2405:8100::/32', '2a06:98c0::/29',
                       '2c0f:f248::/32']
        check(list(gist_nodes.CF_IPV4_CIDRS_FALLBACK) == OFFICIAL_V4,
              f'CF v4 回退段表与官方一致（实际 {list(gist_nodes.CF_IPV4_CIDRS_FALLBACK)}）')
        check(list(gist_nodes.CF_IPV6_CIDRS_FALLBACK) == OFFICIAL_V6,
              f'CF v6 回退段表与官方一致（实际 {list(gist_nodes.CF_IPV6_CIDRS_FALLBACK)}）')
        for cidr in OFFICIAL_V4:
            net, prefix = cidr.split('/')
            check(f'["{net}", {prefix}]' in cf_js, f'CF 算子内嵌官方 v4 段 {cidr}')
        for cidr in OFFICIAL_V6:
            check(f'"{cidr}"' in cf_js, f'CF 算子内嵌官方 v6 段 {cidr}')
        check('proxies.filter' in cf_js, 'CF 剔除算子用 filter')
        delete_op = (main_col.get('process') or [{}])[3]
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
        check(types == ['Useless Filter', 'Script Operator', 'Script Operator',
                        'Handle Duplicate Operator', 'Handle Duplicate Operator'],
              f'MAX_NODES=0 时只有两个剔除算子、无限量算子（实际 {types}）')
        check('slice(0, 0)' not in json.dumps(cols4[0].get('process') or []),
              'MAX_NODES=0 时不许生成 slice 算子')

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
        print('== 20. 跨轮累积：上一轮的订阅以 -000 先投喂，并进组合 ==')
        FakeSubStore.requests.clear()
        prev_yaml = ('proxies:\n'
                     '  - {name: prev, type: ss, server: 9.9.9.9, port: 9,'
                     ' cipher: aes-128-gcm, password: p}\n')
        prev_bytes = len(prev_yaml.encode('utf-8'))
        (code, _, nj20), _ = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': base},
            carryover_text=prev_yaml)
        subs20 = posts('/api/subs')
        first_name = subs20[0][2]['name'] if subs20 else '无'
        check(code == 0, '退出码 0')
        check(len(subs20) == 4, f'3 个抓到的 + 1 个累积 = 4 次投喂（实际 {len(subs20)}）')
        check(subs20 and first_name == 'gist-nodes-000',
              f'累积排在最前面且名字固定 -000（实际 {first_name}）')
        check(subs20 and subs20[0][2]['content'] == prev_yaml, '累积投喂的就是上一轮的正文')
        cols20 = [p for _, _, p in posts('/api/collections') if p['name'] == 'gist-nodes']
        check(len(cols20) == 1 and 'gist-nodes-000' in cols20[0]['subscriptions'],
              '组合订阅里包含累积那一份')
        co20 = nj20['substore']['carryover']
        check(co20['enabled'] is True and co20['used'] is True,
              f'nodes.json 记录累积已启用且取到（实际 {co20}）')
        check(co20['bytes'] == prev_bytes, f'nodes.json 记录累积字节数（实际 {co20["bytes"]}）')
        n_found = nj20['substore']['files_found']
        n_gathered = nj20['substore']['files_gathered']
        check(n_found == 4 and n_gathered == 3,
              f'files_found 含累积、files_gathered 只算抓到的（实际 {n_found}/{n_gathered}）')

        print('== 20b. 负向对照：关掉累积 / 上一轮没有文件 → 都不多投喂 ==')
        FakeSubStore.requests.clear()
        (code, _, nj20b), _ = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir,
            {'SUB_STORE_BACKEND_URL': base, 'GIST_NODES_CARRYOVER': '0'},
            carryover_text=prev_yaml)
        n20b = len(posts('/api/subs'))
        check(code == 0, '退出码 0')
        check(n20b == 3, f'关掉累积 → 只投喂抓到的 3 个（实际 {n20b}）')
        check(nj20b['substore']['carryover']['enabled'] is False, 'nodes.json 记录累积已关掉')
        check(nj20b['substore']['files_found'] == 3, 'files_found 不含累积')

        FakeSubStore.requests.clear()
        (code, _, nj20c), _ = capture_events(
            gist_nodes, run_main, gist_nodes, tmpdir, {'SUB_STORE_BACKEND_URL': base})
        n20c = len(posts('/api/subs'))
        check(code == 0, '退出码 0（取不到累积不算失败）')
        check(n20c == 3, f'首次运行取不到 → 不多投喂（实际 {n20c}）')
        check(nj20c['substore']['carryover']['used'] is False, 'nodes.json 记录 used=False')

        print('== 21. 真 fetch_carryover：成功 + 各跳过分支 + 大小上限边界 ==')
        # 20/20b 必须把 fetch_carryover 整个 stub 掉（真实现会去打 api.github.com），
        # 于是「取到累积」那条日志从没被真代码走过、五条跳过分支也没被覆盖。这里只替换
        # 两个网络原语，让真实现跑起来，逐条验它的跳过原因与大小边界。
        real_api, real_get = gist_nodes.github_api_request, gist_nodes.http_get
        net = {'api': None, 'api_exc': None, 'get': None, 'get_exc': None,
               'api_calls': 0, 'get_calls': 0, 'api_url': ''}

        def fake_api(url, token, payload=None, method='GET', timeout=60):
            net['api_calls'] += 1
            net['api_url'] = url
            if net['api_exc']:
                raise net['api_exc']
            return net['api']

        def fake_get(url, token='', timeout=30, max_bytes=0):
            # 忠实模拟 `resp.read(max_bytes)`：到顶就截断，这样「正好等于上限」与
            # 「超上限」才能被区分开（真实现正是靠多读 1 字节来判的）。
            net['get_calls'] += 1
            net['get_url'] = url
            if net['get_exc']:
                raise net['get_exc']
            body = net['get'] or ''
            return body[:max_bytes] if max_bytes > 0 else body

        def reset_net(api=None, body=None, api_exc=None, get_exc=None):
            net.update({'api': api, 'get': body, 'api_exc': api_exc,
                        'get_exc': get_exc, 'api_calls': 0, 'get_calls': 0})

        def carry_env(**extra):
            env = {'PROXY_SPEEDTEST_GIST_ID': 'a' * 32,
                   'PROXY_SPEEDTEST_GIST_FILENAME': 'providers.yaml',
                   'GH_TOKEN': 'fake'}
            env.update(extra)
            return env

        def run_carry(env, max_bytes=1024):
            return capture_events(gist_nodes, gist_nodes.fetch_carryover, env, 5, max_bytes)

        gist_nodes.github_api_request = fake_api
        gist_nodes.http_get = fake_get
        try:
            raw_url = 'https://gist.githubusercontent.com/u/aaa/raw/hash/providers.yaml'
            ok_files = {'files': {'providers.yaml': {'raw_url': raw_url}}}
            body21 = ('proxies:\n'
                      '  - {name: prev, type: ss, server: 9.9.9.9, port: 9,'
                      ' cipher: aes-128-gcm, password: p}\n')
            nbytes21 = len(body21.encode('utf-8'))

            reset_net(api=ok_files, body=body21)
            got, ev = run_carry(carry_env())
            check(got == body21, '成功：取回上一轮正文')
            check(net['api_calls'] == 1 and net['api_url'].endswith('a' * 32),
                  f'探测打的是 env 里那个 Gist（实际 {net["api_url"]}）')
            check(net['get_url'] == raw_url,
                  '取文走 raw_url（不用大于 1MB 会被截断的 files[].content）')
            ok_log = [e for e in ev if e['stage'] == 'gist_nodes_carryover']
            check(len(ok_log) == 1 and ok_log[0]['bytes'] == nbytes21
                  and ok_log[0]['filename'] == 'providers.yaml',
                  f'成功时打「取到累积」日志并带字节数（实际 {ev}）')

            reset_net(api=ok_files, body=body21)
            got, ev = run_carry(carry_env(PROXY_SPEEDTEST_GIST_FILENAME=''))
            check(got is None and [e.get('reason') for e in ev] == ['missing_gist_id_or_filename'],
                  f'缺 Gist id / 文件名 → 跳过（实际 {ev}）')
            check(net['api_calls'] == 0 and net['get_calls'] == 0,
                  '缺 env 时一次网络都不打')

            reset_net(api={'files': {'other.yaml': {'raw_url': 'https://x/y'}}}, body=body21)
            got, ev = run_carry(carry_env())
            check(got is None and [e.get('reason') for e in ev] == ['no_previous_file'],
                  f'Gist 在但没这个文件 → 跳过（实际 {ev}）')
            check(net['get_calls'] == 0, '没拿到 raw_url 就不去取文')

            reset_net(api_exc=RuntimeError('api 挂了'))
            got, ev = run_carry(carry_env())
            check(got is None and [e.get('reason') for e in ev] == ['gist_probe_failed'],
                  f'Gist 探测抛异常 → 跳过且不冒泡（实际 {ev}）')

            reset_net(api=ok_files, get_exc=RuntimeError('raw 挂了'))
            got, ev = run_carry(carry_env())
            check(got is None and [e.get('reason') for e in ev] == ['fetch_failed'],
                  f'取文抛异常 → 跳过且不冒泡（实际 {ev}）')

            # 上限边界：正好等于上限必须放行（靠多读 1 字节判），多 1 字节必须挡下。
            exact = 'x' * 1024
            reset_net(api=ok_files, body=exact)
            got, ev = run_carry(carry_env())
            check(got == exact and ev and ev[0]['stage'] == 'gist_nodes_carryover',
                  f'正文正好等于上限 → 放行（实际 {ev}）')

            reset_net(api=ok_files, body='x' * 1025)
            got, ev = run_carry(carry_env())
            check(got is None and [e.get('reason') for e in ev] == ['oversize'],
                  f'超上限 1 字节 → 跳过（实际 {ev}）')
            check([e.get('limit_bytes') for e in ev] == [1024], '跳过日志带上限值便于排查')

            reset_net(api=ok_files, body='   \n\n')
            got, ev = run_carry(carry_env())
            check(got is None and [e.get('reason') for e in ev] == ['empty'],
                  f'空白正文 → 跳过（实际 {ev}）')
        finally:
            gist_nodes.github_api_request, gist_nodes.http_get = real_api, real_get

        print('== 22. 试装摘要渲染：字段名必须与 trial_load 的报告键一致 ==')
        # 这里守的是一个**真发生过的崩溃**：`_trial_load_summary_line` 曾引用
        # `report["rounds"]`，而报告里那个字段叫 `probes`（切块/热重载改造时改了名但
        # 漏改这里）⇒ 真机上试装一跑完，摘要渲染就 KeyError、整轮产出报废。
        # 单测 `trial_load` 抓不到它（报告本身是对的），必须拿**真实报告**过一遍渲染。
        # 所以这里不写死字典，而是真的调 `trial_load`（数据全好、不必装任何节点）。
        import alive_filter as af22
        saved_home22 = af22._safe_home_dir
        saved_start22 = af22._start_mihomo
        tmp22 = pathlib.Path(tempfile.mkdtemp(prefix='summary-render-'))
        af22._safe_home_dir = lambda base: (pathlib.Path(base).mkdir(parents=True,
                                                                    exist_ok=True),
                                            pathlib.Path(base))[1]
        af22._start_mihomo = lambda *a, **k: (_ for _ in ()).throw(
            RuntimeError('本用例只验摘要渲染，不需要真起 mihomo'))
        try:
            # 起不来 ⇒ 报告走 skipped 分支，但**字段仍然齐全**；再用一份手工补全的
            # 正常报告覆盖另一条分支（两条分支的键都要对得上）。
            _, rep22 = af22.trial_load([{'name': 'a', 'type': 'ss', 'server': '1.1.1.1',
                                         'port': 443, 'cipher': 'aes-128-gcm',
                                         'password': 'p'}], workdir=tmp22)
        finally:
            af22._safe_home_dir = saved_home22
            af22._start_mihomo = saved_start22
            shutil.rmtree(tmp22, ignore_errors=True)
        # 正常完成分支：用 trial_load 真实产出的键集合，只把值改成「装上了 2 个、剔了 1 个」。
        normal22 = dict(rep22)
        normal22.update({'skipped': False, 'skip_reason': '', 'kept': 2, 'removed': 1,
                         'removed_names': ['bad-one'], 'batches': 3, 'bad_batches': 1,
                         'batches_failed': 0, 'elapsed_seconds': 1.2, 'probes': 7})
        for label, record in (('正常完成', normal22), ('fail-open', rep22), ('未执行', None)):
            try:
                line22 = gist_nodes._trial_load_summary_line(record, 3)
            except KeyError as e:
                check(False, f'{label}分支渲染不能 KeyError（实际缺字段 {e}）')
                continue
            check(isinstance(line22, str) and line22.startswith('- 试装排雷：'),
                  f'{label}分支渲染出摘要行（实际 {line22[:30]!r}）')
        check('7 次' in gist_nodes._trial_load_summary_line(normal22, 3),
              '正常分支要写出探针次数——它取自 report["probes"]')
        check('bad-one' in gist_nodes._trial_load_summary_line(normal22, 3),
              '正常分支要列出被剔节点名')

        print('== 23. CF 段表实时拉取：成功走线上表，任何异常回退内置快照 ==')
        # 用假 http_get 驱动真实的 fetch_cf_cidrs（不打真网络）。
        saved_get = gist_nodes.http_get
        tries = []

        def fake_get(url, token='', timeout=30, max_bytes=0):
            tries.append(url)
            return fake_get.payload

        gist_nodes.http_get = fake_get
        try:
            # 23.1 成功：解析出官方 v4/v6，来源标 api
            fake_get.payload = json.dumps({
                'success': True, 'result': {
                    'etag': 'deadbeef',
                    'ipv4_cidrs': ['203.0.113.0/24', '198.51.100.0/24'],
                    'ipv6_cidrs': ['2001:db8::/32']}})
            v4, v6, src = gist_nodes.fetch_cf_cidrs({}, 5)
            check((v4, v6, src) == (('203.0.113.0/24', '198.51.100.0/24'),
                                    ('2001:db8::/32',), 'api'),
                  f'拉取成功用线上表且标 api（实际 {v4} {v6} {src}）')
            check(tries and tries[-1] == gist_nodes.CF_IPS_API_URL,
                  '打的是官方 ips 端点')

            # 23.2 各种失败都必须回退到内置快照、且不冒泡
            bad_payloads = [
                ('非 JSON', '<html>502 Bad Gateway</html>'),
                ('success=false', json.dumps({'success': False, 'result': {}})),
                ('列表为空', json.dumps({'success': True, 'result': {
                    'ipv4_cidrs': [], 'ipv6_cidrs': []}})),
                ('缺字段', json.dumps({'success': True, 'result': {'ipv4_cidrs': ['1.2.3.0/24']}})),
                ('CIDR 非法', json.dumps({'success': True, 'result': {
                    'ipv4_cidrs': ['999.1.1.0/24'], 'ipv6_cidrs': ['2001:db8::/32']}})),
            ]
            for label, payload in bad_payloads:
                fake_get.payload = payload
                v4b, v6b, srcb = gist_nodes.fetch_cf_cidrs({}, 5)
                check((v4b, v6b, srcb) == (gist_nodes.CF_IPV4_CIDRS_FALLBACK,
                                          gist_nodes.CF_IPV6_CIDRS_FALLBACK, 'fallback'),
                      f'{label} → 回退内置快照且标 fallback')

            # 23.3 抛异常（超时 / DNS 挂了）同样回退，不冒泡
            def boom(url, token='', timeout=30, max_bytes=0):
                raise urllib.error.URLError('DNS 挂了')

            gist_nodes.http_get = boom
            v4c, v6c, srcc = gist_nodes.fetch_cf_cidrs({}, 5)
            check((v4c, v6c, srcc) == (gist_nodes.CF_IPV4_CIDRS_FALLBACK,
                                      gist_nodes.CF_IPV6_CIDRS_FALLBACK, 'fallback'),
                  '网络异常 → 回退内置快照且不冒泡')

            # 23.4 上传的段表真的跟着传进来的段表走（不是偷偷读常量）
            op_custom = gist_nodes._exclude_cf_operator(('203.0.113.0/24',), ())
            check('203.0.113.0' in op_custom['args']['content'] and
                  '104.16.0.0' not in op_custom['args']['content'],
                  '算子内嵌的是传入的段表，不是内置常量')
        finally:
            gist_nodes.http_get = saved_get

        print('== 24. 控制字符清洗：节点名带 C1 控制字符也能解析并发布干净 YAML ==')
        # 事故原型（2026-09-24）：抓取来的节点名里混进 `U+009F`（C1 控制字符 APC），
        # Sub-Store 不校验、原样写进产出 YAML；`yaml.safe_load` 按规范拒绝解析 ⇒
        # 整轮 exit 1、下游三个测速 job 全 skipped，而那个脏节点还在累积文件里 ⇒ 轮轮红。
        # 反证：把 main() 里 `strip_nonprintable` 那两行去掉，24b 立刻变红（实测 2 项）。

        # 24a. 单元层：清洗掉 C1 与 NUL，但**保留** \t \n \r
        dirty = 'a\x9fb\x00c\td\ne\rf'
        clean, removed = gist_nodes.strip_nonprintable(dirty)
        check(removed == 2, f'去掉 2 个控制字符（实际 {removed}）')
        check(clean == 'abc\td\ne\rf', f'\\t \\n \\r 保留（实际 {clean!r}）')
        check(gist_nodes.strip_nonprintable('') == ('', 0), '空串不炸、返回 0')
        check(gist_nodes.strip_nonprintable('干净文本')[1] == 0, '干净文本不去任何字符')

        # 24b. 链路层：假 Sub-Store 返回带脏字符的 YAML → 必须解析成功且发布的是干净 YAML
        _orig_yaml = FakeSubStore.yaml_body
        FakeSubStore.yaml_body = (
            'proxies:\n- name: "\u009f\u009f脏名字"\n  type: vless\n'
            '  server: 1.1.1.1\n  port: 443\n'
            '- name: 正常\n  type: trojan\n  server: 2.2.2.2\n  port: 443\n')
        try:
            code24, uploaded24, _ = run_main(gist_nodes, tmpdir,
                                             {'SUB_STORE_BACKEND_URL': base})
            check(code24 == 0, f'带脏字符的产出不再整轮失败（实际退出码 {code24}）')
            check('\u009f' not in uploaded24, '发布出去的 YAML 里不含控制字符')
            check('正常' in uploaded24 and '脏名字' in uploaded24,
                  '两个节点都保留（清洗只去字符、不丢节点）')
        finally:
            FakeSubStore.yaml_body = _orig_yaml

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
