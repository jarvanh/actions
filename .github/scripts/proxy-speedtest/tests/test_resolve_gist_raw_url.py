#!/usr/bin/env python3
"""`speedtest_common.resolve_gist_raw_url` 的离线自检。

为什么需要它：这个函数是「gistnodes 抓到的节点真的被拿去测速」这条链的**唯一取数口**，
它出过一次真实事故（run 34956069334）：

  * job output 里带 gist id ⇒ GitHub 的 secret 扫描把 `sub_url` / `gist_html_url` /
    `gist_id` 三个 output 全丢了（`Skip output 'X' since it may contain secret.`），
    下游拿到空值就 fallback 到仓库 secret。
  * 结果是订阅源退回了用户自己的机场订阅、测速结果写进另一个泰尔 Gist，
    而整轮**零报错**——只有人去比对节点来源才看得出来。

这个函数的坏法同样隐蔽：**失败时返回空串**，调用方（Resolve source subscription 步骤）
会 `exit 1`——好一点；但若哪天有人把空串当成「没配 gist、走 passthrough」，
就又变回静默走错源。所以这里把「取到 / 取不到」的两条路都钉住：

  * 取到：文件名命中时返回 raw_url，且**只发一次** API 请求（不要顺带打别的接口）。
  * 取不到：文件名不在 gist 里 / gist id 为空 / 文件名为空 / token 为空 / API 报错，
    五种都返回空串，且**不抛异常**（抛出去会把整轮步骤带崩）。
  * 文件名匹配是**精确**的：前缀相同但不同名（如 `..._providers.yaml.bak`）不算命中，
    否则会拿错文件。

第 9–11 组守**下一环** `speedtest_gitee.fetch_text`。它接在 resolve 之后（拿到 raw URL
就去取正文），同样出过一次真实事故（2026-09-16 run 35042828032）：

  * 发布的订阅是好的（`gist_nodes_published nodes: 14124 bytes: 4829159`，手工 curl
    同一 URL 得到 `http=200` 且 14124 个节点），但 runner 上取文途中被
    `gist.githubusercontent.com` 掐断了 TLS：
    `subscription_fetch_skipped error: [SSL: UNEXPECTED_EOF_WHILE_READING]`。
  * `build_source_mapping` 对 fetch 异常一律 `subscription_fetch_skipped` + `continue`，
    于是**一次抖动 = 整份订阅静默消失** ⇒ `nodes_collected: 0`，而 job 照样报成功。
  * 原先 `fetch_text` **没有任何重试**。现在钉住三件事：抖动要能自愈、真故障要抛
    （不能吞成空串再被当成「没节点」）、健康路径只请求一次（重试不许拖慢正常情况）。

第 13 组守**发布端**的 gist id 回填。事故形态（2026-09-16，taier 订阅链接 404）：

  * `create_gist` 只把新 id 写进 `$GITHUB_ENV`——那东西**只活当前 job**；跨轮持久的
    唯一载体是仓库 secret，而 secret 从来没人去写。
  * 于是下一轮仍从已失效的旧 id 起手 ⇒ 再次 404 ⇒ 再次新建 ⇒ 「每轮一个新 gist、
    旧链接全部 404」，且代码只会打印一句「请把 Gist id 回填到 Secrets」的告警，
    没人盯着通知就永远发现不了。
  * 这里钉住：新建必须回填、404→新建 那条路也要回填、**写别人的 Gist 时不许回填**
    （编排层/手动 gist_id 场景）、回填失败只记日志不影响本轮发布。

跑法：python .github/scripts/proxy-speedtest/tests/test_resolve_gist_raw_url.py
退出码 0 = 全部通过。
"""
import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import urllib.error

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []

RAW = ('https://gist.githubusercontent.com/jarvanh/'
       'fed0982fad16e10134d9ae587f7b57b4/raw/4d25dd9f96da58ef1e6f16e75b26d1/'
       'proxy_speedtest_gistnodes_providers.yaml')
FILENAME = 'proxy_speedtest_gistnodes_providers.yaml'
GIST_ID = 'fed0982fad16e10134d9ae587f7b57b4'
NEW_GIST_ID = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def main():
    import speedtest_common as C

    calls = []
    events = []
    orig_request = C.github_api_request
    orig_log = C.log_progress

    def fake_request(url, token, payload=None, method='GET', timeout=60):
        calls.append({'url': url, 'token': token, 'timeout': timeout})
        if 'boom' in url:
            raise RuntimeError('network down (模拟)')
        return {'files': {FILENAME: {'raw_url': RAW},
                          'other.yaml': {'raw_url': 'https://example.invalid/other'}}}

    C.github_api_request = fake_request
    C.log_progress = lambda stage, **kw: events.append(dict(stage=stage, **kw))

    try:
        print('== 1. 命中：返回 raw_url，且只问一次 API ==')
        calls.clear()
        url = C.resolve_gist_raw_url(GIST_ID, FILENAME, 'ghp_fake')
        check(url == RAW, f'拿到 raw_url（实际 {url!r}）')
        check(len(calls) == 1, f'只发一次 API 请求（实际 {len(calls)}）')
        check(calls[0]['url'] == f'https://api.github.com/gists/{GIST_ID}',
              f'请求的是该 gist（实际 {calls[0]["url"]}）')

        print('== 2. raw_url 里的 commit sha 是保留的（不退回省略写法）==')
        check('/raw/4d25dd9f96da58ef1e6f16e75b26d1/' in url,
              'raw URL 保留 commit sha 段（省略写法会缓存、不保证是最新写入）')

        print('== 3. 取不到：五种输入都返回空串且不抛异常 ==')
        cases = [
            ('文件名不在 gist 里', GIST_ID, 'nope.yaml', 'ghp_fake'),
            ('gist id 为空', '', FILENAME, 'ghp_fake'),
            ('gist id 只有空白', '   ', FILENAME, 'ghp_fake'),
            ('文件名为空', GIST_ID, '', 'ghp_fake'),
            ('token 为空', GIST_ID, FILENAME, ''),
            ('token 只有空白', GIST_ID, FILENAME, '   '),
            ('API 抛异常', f'{GIST_ID}-boom', FILENAME, 'ghp_fake'),
        ]
        for label, gid, fname, tok in cases:
            try:
                got = C.resolve_gist_raw_url(gid, fname, tok)
                check(got == '', f'{label} ⇒ 空串（实际 {got!r}）')
            except Exception as e:
                check(False, f'{label} ⇒ 不该抛异常，却抛了 {type(e).__name__}: {e}')

        print('== 4. 秒退：空入参不发请求（省掉一次必然失败的 API 调用）==')
        calls.clear()
        C.resolve_gist_raw_url('', FILENAME, 'ghp_fake')
        C.resolve_gist_raw_url(GIST_ID, FILENAME, '')
        check(calls == [], f'空 gist id / 空 token 都不发请求（实际 {len(calls)} 次）')

        print('== 5. 文件名是精确匹配，不是前缀匹配 ==')
        calls.clear()
        got = C.resolve_gist_raw_url(GIST_ID, FILENAME + '.bak', 'ghp_fake')
        check(got == '', f'前缀相同的 .bak 不算命中（实际 {got!r}）')

        print('== 6. 取不到时留下可定位的日志（含 gist id 与可用文件名）==')
        events.clear()
        C.resolve_gist_raw_url(GIST_ID, 'nope.yaml', 'ghp_fake')
        miss = [e for e in events if e['stage'] == 'gist_raw_url_resolve_missing']
        check(len(miss) == 1, f'恰好记一条 resolve_missing（实际 {len(miss)}）')
        check(miss and miss[0].get('gist_id') == GIST_ID, '日志里带 gist id')
        check(miss and FILENAME in (miss[0].get('available') or []),
              '日志里列出 gist 内可用文件名，便于比对拼写')

        print('== 7. API 失败时单独记一条，不和「文件不存在」混淆 ==')
        events.clear()
        C.resolve_gist_raw_url(f'{GIST_ID}-boom', FILENAME, 'ghp_fake')
        failed = [e for e in events if e['stage'] == 'gist_raw_url_resolve_failed']
        check(len(failed) == 1, f'记一条 resolve_failed（实际 {len(failed)}）')
        check(not [e for e in events if e['stage'] == 'gist_raw_url_resolve_missing'],
              '不误报成「文件缺失」——否则会去查文件名而不是查网络/权限')

        print('== 8. token 原样透传给 API 层（不在本函数里丢掉鉴权）==')
        calls.clear()
        C.resolve_gist_raw_url(GIST_ID, FILENAME, 'ghp_specific_token')
        check(calls and calls[0]['token'] == 'ghp_specific_token',
              f'token 透传（实际 {calls[0]["token"] if calls else None!r}）')
    finally:
        C.github_api_request = orig_request
        C.log_progress = orig_log

    import speedtest_gitee as G

    class _Resp:
        def __init__(self, body):
            self.body = body

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return self.body

    orig_urlopen = G.urllib.request.urlopen
    orig_sleep = G.time.sleep
    orig_glog = G.log_progress
    sleeps = []
    git_events = []
    G.time.sleep = lambda s: sleeps.append(s)
    G.log_progress = lambda stage, **kw: git_events.append(dict(stage=stage, **kw))
    try:
        print('== 9. 抖动要能自愈：前 2 次 SSL EOF、第 3 次成功 ⇒ 必须返回正文 ==')
        state = {'n': 0}

        def flaky(req, timeout=None):
            state['n'] += 1
            if state['n'] < 3:
                raise OSError('[SSL: UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol')
            return _Resp(b'proxies:\n  - name: a\n')

        G.urllib.request.urlopen = flaky
        sleeps.clear()
        git_events.clear()
        out = G.fetch_text('https://example.invalid/flaky')
        check('proxies:' in out, f'抖动后仍拿到正文（实际 {out[:20]!r}）')
        check(state['n'] == 3, f'恰好请求 3 次（实际 {state["n"]}）')
        check(len(sleeps) == 2, f'失败之间退避 2 次（实际 {len(sleeps)}）')
        check(all(s >= 0 for s in sleeps) and sleeps == sorted(sleeps),
              f'退避是递增的指数曲线（实际 {[round(s, 2) for s in sleeps]}）')
        retry_events = [e for e in git_events if e['stage'] == 'subscription_fetch_retry']
        check(len(retry_events) == 2, f'每次失败记一条 fetch_retry（实际 {len(retry_events)}）')
        check(retry_events and 'UNEXPECTED_EOF' in str(retry_events[0].get('error', '')),
              '重试日志里带上真实错误，便于区分「抖动」与「真故障」')

        print('== 10. 真故障要抛：重试耗尽必须抛异常，不能吞成空串 ==')
        state['n'] = 0

        def dead(req, timeout=None):
            state['n'] += 1
            raise OSError(f'boom-{state["n"]}')

        G.urllib.request.urlopen = dead
        sleeps.clear()
        try:
            G.fetch_text('https://example.invalid/dead')
            check(False, '重试耗尽却没抛异常（会静默退化成「零节点且不报错」）')
        except OSError as e:
            check('boom-' in str(e), f'抛出的是最后一次的真实错误（实际 {e}）')
        check(state['n'] == G.DEFAULT_FETCH_RETRIES,
              f'恰好尝试 DEFAULT_FETCH_RETRIES 次（实际 {state["n"]} / {G.DEFAULT_FETCH_RETRIES}）')

        print('== 11. 健康路径只请求一次（重试不许拖慢正常情况）==')
        state['n'] = 0
        def healthy(req, timeout=None):
            state['n'] += 1
            return _Resp(b'ok\n')

        G.urllib.request.urlopen = healthy
        sleeps.clear()
        out = G.fetch_text('https://example.invalid/ok')
        check(out == 'ok\n', f'正文原样返回（实际 {out!r}）')
        check(state['n'] == 1, f'只请求一次（实际 {state["n"]}）')
        check(sleeps == [], f'成功路径不引入任何等待（实际 {len(sleeps)} 次）')
    finally:
        G.urllib.request.urlopen = orig_urlopen
        G.time.sleep = orig_sleep
        G.log_progress = orig_glog

    print('== 12. CLI 出口把结果打在哨兵行上（workflow 用 $( ) 取值，日志不得污染）==')
    orig_common_log = C.log_progress
    orig_api = C.github_api_request
    try:
        # 12a. 失败路径：函数会 log_progress 一行 JSON，但哨兵行必须是空值行
        C.log_progress = lambda stage, **kw: print(
            json.dumps({'kind': 'progress', 'stage': stage, **kw}), flush=True)
        C.github_api_request = lambda *a, **k: (_ for _ in ()).throw(
            RuntimeError('HTTP Error 404: Not Found'))
        buf = io.StringIO()
        os.environ['SOURCE_GIST_ID'] = 'deadbeef'
        os.environ['SOURCE_GIST_FILENAME'] = FILENAME
        os.environ['GH_TOKEN'] = 'ghp_fake'
        with contextlib.redirect_stdout(buf):
            C.resolve_gist_raw_url_cli()
        lines = buf.getvalue().splitlines()
        marked = [l for l in lines if l.startswith(C.GIST_RAW_URL_MARKER)]
        check(len(marked) == 1, f'恰好一行带哨兵（实际 {len(marked)}，总 {len(lines)} 行）')
        check(marked == [C.GIST_RAW_URL_MARKER],
              f'失败时哨兵行是「哨兵 + 空串」（实际 {marked!r}）')
        check(len(lines) > 1, '确实还有别的日志行——证明这个用例真的在测「日志掺进 stdout」')
        check(all(not l.startswith('http') for l in lines),
              'stdout 上没有任何以 http 开头的裸行（否则 $( ) 的判空仍会失效）')

        # 12b. 成功路径：哨兵行带上完整 URL，且它是唯一可取到的值
        C.github_api_request = lambda *a, **k: {'files': {FILENAME: {'raw_url': RAW}}}
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            C.resolve_gist_raw_url_cli()
        lines = buf.getvalue().splitlines()
        marked = [l for l in lines if l.startswith(C.GIST_RAW_URL_MARKER)]
        check(marked == [C.GIST_RAW_URL_MARKER + RAW],
              f'成功时哨兵行 = 哨兵 + raw_url（实际 {marked!r}）')
        check(len(lines) == 1, f'成功且无失败日志时只有一行（实际 {len(lines)} 行）')
    finally:
        C.log_progress = orig_common_log
        C.github_api_request = orig_api
        for k in ('SOURCE_GIST_ID', 'SOURCE_GIST_FILENAME', 'GH_TOKEN'):
            os.environ.pop(k, None)

    print('== 13. gist 新建后自动回填 secret（治「每轮新建 ⇒ 旧链接 404」自续循环）==')
    orig_request13 = C.github_api_request
    orig_log13 = C.log_progress
    orig_run = C.subprocess.run
    orig_env_path = C.ENV_PATH
    events13 = []
    gh_calls = []
    tmp_env = pathlib.Path(tempfile.mkdtemp()) / 'env'
    C.ENV_PATH = tmp_env
    C.log_progress = lambda stage, **kw: events13.append(dict(stage=stage, **kw))

    def created_request(url, token, payload=None, method='GET', timeout=60):
        return {'id': NEW_GIST_ID, 'html_url': 'https://gist.github.com/x',
                'files': {C.GIST_DEFAULT_FILENAME: {'raw_url': RAW}}}

    class _Proc:
        def __init__(self, rc, err=''):
            self.returncode = rc
            self.stderr = err
            self.stdout = ''

    def gh_ok(cmd, **kw):
        gh_calls.append(list(cmd))
        return _Proc(0)

    def gh_fail(cmd, **kw):
        gh_calls.append(list(cmd))
        return _Proc(1, 'HTTP 403: Resource not accessible')

    def _set(**over):
        for k in ('GITHUB_REPOSITORY', 'PROXY_SPEEDTEST_GIST_SECRET_NAME'):
            os.environ.pop(k, None)
        for k, v in over.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def _run(**over):
        events13.clear()
        gh_calls.clear()
        _set(**over)
        return C.create_gist({'GH_TOKEN': 'ghp_fake'}, 'proxies:\n  - name: a\n')

    try:
        C.github_api_request = created_request
        C.subprocess.run = gh_ok

        # 13a. 正常回填：gh 命令参数必须完整（repo + secret 名 + 新建出来的 id）
        res = _run(GITHUB_REPOSITORY='jarvanh/actions',
                   PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        check(res.get('id') == NEW_GIST_ID, f'create_gist 正常返回新 id（实际 {res.get("id")!r}）')
        check(len(gh_calls) == 1, f'恰好调用一次 gh secret set（实际 {len(gh_calls)}）')
        cmd = gh_calls[0] if gh_calls else []
        check(cmd[:3] == ['gh', 'secret', 'set'], f'调的是 gh secret set（实际 {cmd[:3]}）')
        check('PROXY_SPEEDTEST_TAIER_GIST_ID' in cmd, f'写入的是指定的 secret 名（实际 {cmd}）')
        check(NEW_GIST_ID in cmd, f'写入的是新建出来的 gist id（实际 {cmd}）')
        check('--repo' in cmd and 'jarvanh/actions' in cmd, f'带 --repo（实际 {cmd}）')
        backed = [e for e in events13 if e['stage'] == 'gist_secret_backfilled']
        check(len(backed) == 1 and backed[0].get('gist_id') == NEW_GIST_ID,
              f'记一条 gist_secret_backfilled（实际 {len(backed)}）')
        check(tmp_env.exists() and f'PROXY_SPEEDTEST_GIST_ID={NEW_GIST_ID}' in tmp_env.read_text(),
              '新 id 同时写进 env 文件（本轮下游步骤要用）')

        # 13b. 护栏：编排层/手动 gist_id 时 secret 名为空 ⇒ 不许碰别人的 secret
        res = _run(GITHUB_REPOSITORY='jarvanh/actions', PROXY_SPEEDTEST_GIST_SECRET_NAME='')
        check(res.get('ok') is True, '没配 secret 名时 create_gist 依旧成功（回填只是优化）')
        check(gh_calls == [], f'secret 名为空 ⇒ 一次 gh 都不许调（实际 {len(gh_calls)} 次）')
        skip = [e for e in events13 if e['stage'] == 'gist_secret_backfill_skipped']
        check(len(skip) == 1, f'记一条 backfill_skipped 便于排查（实际 {len(skip)}）')

        # 13c. 护栏：非 Actions 环境（无 GITHUB_REPOSITORY）也不许瞎调 gh
        res = _run(GITHUB_REPOSITORY=None,
                   PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        check(gh_calls == [] and res.get('ok') is True,
              f'缺 GITHUB_REPOSITORY ⇒ 跳过回填且不影响发布（实际 {len(gh_calls)} 次）')

        # 13d. gh 失败（权限不足/没登录）⇒ 只记日志，不能把整轮订阅发布判失败
        C.subprocess.run = gh_fail
        res = _run(GITHUB_REPOSITORY='jarvanh/actions',
                   PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        check(res.get('ok') is True, 'gh 回填失败不影响本轮订阅发布（否则每轮都白跑）')
        failed = [e for e in events13 if e['stage'] == 'gist_secret_backfill_failed']
        check(len(failed) == 1 and '403' in str(failed[0].get('error', '')),
              f'失败要记日志并带上 gh 的真实报错（实际 {failed}）')

        # 13e. 幂等：重复写同一个值无害（每轮都写一次，不能因为「已存在」报错）
        # 注意: 这里不能走 _run（它每次都会清空计数），直接连调两次只清一次计数
        C.subprocess.run = gh_ok
        events13.clear()
        gh_calls.clear()
        _set(GITHUB_REPOSITORY='jarvanh/actions',
             PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        C.create_gist({'GH_TOKEN': 'ghp_fake'}, 'proxies:\n  - name: a\n')
        C.create_gist({'GH_TOKEN': 'ghp_fake'}, 'proxies:\n  - name: a\n')
        check(len(gh_calls) == 2 and all(c[-1] == NEW_GIST_ID for c in gh_calls),
              f'连续两轮都写同一个值，不报错（实际 {len(gh_calls)} 次）')

        # 13f. update_gist 撞上 404 —— 真失效（重试仍 404 且 GET 读不到）⇒ 新建并回填
        events13.clear()
        gh_calls.clear()
        _set(GITHUB_REPOSITORY='jarvanh/actions',
             PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')

        def patch_404(url, token, payload=None, method='GET', timeout=60):
            if method == 'PATCH':
                raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
            if method == 'POST':
                return {'id': NEW_GIST_ID, 'html_url': 'https://gist.github.com/x',
                        'files': {C.GIST_DEFAULT_FILENAME: {'raw_url': RAW}}}
            # GET 也 404 ⇒ id 确实死了
            raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)

        C.github_api_request = patch_404
        res = C.update_gist({'GH_TOKEN': 'ghp_fake',
                             'PROXY_SPEEDTEST_GIST_ID': 'deadbeef'}, 'proxies:\n  - name: a\n')
        check(res.get('created') is True, f'真失效时 404 转新建（实际 created={res.get("created")}）')
        check(len(gh_calls) == 1 and NEW_GIST_ID in gh_calls[0],
              f'404→新建 这条路径也要回填，否则循环不断（实际 {gh_calls}）')
        recreated = [e for e in events13 if e['stage'] == 'gist_patch_404_recreate']
        check(len(recreated) == 1, f'记一条 404_recreate（实际 {len(recreated)}）')
        check(len([e for e in events13 if e['stage'] == 'gist_patch_404_retry']) == 1,
              '真失效也要先重试一次再判死（不能见 404 就新建）')

        # 13g. 回归 2026-09-17 事故：PATCH 瞬时 404 但 GET 可见 ⇒ 必须复用、绝不许新建
        #      （原实现制造了孤儿 gist 279597be，页面上一模一样的两个文件）
        events13.clear()
        gh_calls.clear()
        _set(GITHUB_REPOSITORY='jarvanh/actions',
             PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        LIVE_ID = 'livegist'

        def patch_flaky_404(url, token, payload=None, method='GET', timeout=60):
            if method == 'PATCH':
                raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
            # GET 能读到 ⇒ id 活着，404 是抖的
            return {'id': LIVE_ID, 'files': {C.GIST_DEFAULT_FILENAME: {'raw_url': RAW}}}

        C.github_api_request = patch_flaky_404
        try:
            C.update_gist({'GH_TOKEN': 'ghp_fake',
                           'PROXY_SPEEDTEST_GIST_ID': LIVE_ID}, 'proxies:\n  - name: a\n')
            check(False, 'PATCH 404 但 GET 可见 ⇒ 必须抛错（暴露出来），不许静默新建')
        except urllib.error.HTTPError as ex:
            check('拒绝新建' in str(ex), f'抛出的错误要说明拒绝新建的原因（实际 {ex}）')
        check(gh_calls == [], f'抖动导致的 404 绝不许回填 secret（实际 {gh_calls}）')
        check(not [e for e in events13 if e['stage'] == 'gist_patch_404_recreate'],
              '抖动路径不许记 404_recreate（记了就是又新建了）')
        check(len([e for e in events13 if e['stage'] == 'gist_patch_404_retry']) == 1,
              '抖动路径也要记录先重试过')

        # 13h. 重试即成功（真·瞬时抖动）⇒ 正常返回，created=False，不新建
        events13.clear()
        gh_calls.clear()
        _set(GITHUB_REPOSITORY='jarvanh/actions',
             PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')
        calls18 = {'n': 0}

        def patch_once_404(url, token, payload=None, method='GET', timeout=60):
            if method == 'PATCH':
                calls18['n'] += 1
                if calls18['n'] == 1:
                    raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
                return {'id': LIVE_ID, 'html_url': 'https://gist.github.com/x',
                        'files': {C.GIST_DEFAULT_FILENAME: {'raw_url': RAW}}}
            return {'id': LIVE_ID, 'files': {C.GIST_DEFAULT_FILENAME: {'raw_url': RAW}}}

        C.github_api_request = patch_once_404
        res = C.update_gist({'GH_TOKEN': 'ghp_fake',
                             'PROXY_SPEEDTEST_GIST_ID': LIVE_ID}, 'proxies:\n  - name: a\n')
        check(res.get('ok') is True and res.get('created') is False,
              f'重试成功即复用，created 必须为 False（实际 {res.get("created")}）')
        check(calls18['n'] == 2, f'恰好 PATCH 两次（首败 + 重试，实际 {calls18["n"]}）')
        check(gh_calls == [], '复用路径不许回填 secret')
        check(len([e for e in events13 if e['stage'] == 'gist_patch_404_recovered']) == 1,
              f'记一条 404_recovered（实际 {len([e for e in events13 if e["stage"] == "gist_patch_404_recovered"])}）')

        # 13i. 重试拿到非 404 的错（如 500/403）⇒ 原样抛，不降级成新建
        events13.clear()
        gh_calls.clear()
        _set(GITHUB_REPOSITORY='jarvanh/actions',
             PROXY_SPEEDTEST_GIST_SECRET_NAME='PROXY_SPEEDTEST_TAIER_GIST_ID')

        calls19 = {'n': 0}

        def patch_then_500(url, token, payload=None, method='GET', timeout=60):
            if method == 'PATCH':
                calls19['n'] += 1
                if calls19['n'] == 1:
                    raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
                raise urllib.error.HTTPError(url, 500, 'Server Error', {}, None)
            return {'id': LIVE_ID, 'files': {}}

        C.github_api_request = patch_then_500
        try:
            C.update_gist({'GH_TOKEN': 'ghp_fake',
                           'PROXY_SPEEDTEST_GIST_ID': LIVE_ID}, 'proxies:\n  - name: a\n')
            check(False, '重试拿到 500 ⇒ 必须原样抛出，不许吞掉')
        except urllib.error.HTTPError as ex:
            check(ex.code == 500, f'抛出的应是重试遇到的那个错（实际 {ex.code}）')
        check(gh_calls == [], '非 404 的错误路径不许回填 secret（那是别人的 gist）')
    finally:
        C.github_api_request = orig_request13
        C.log_progress = orig_log13
        C.subprocess.run = orig_run
        C.ENV_PATH = orig_env_path
        for k in ('GITHUB_REPOSITORY', 'PROXY_SPEEDTEST_GIST_SECRET_NAME'):
            os.environ.pop(k, None)

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
