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

跑法：python .github/scripts/proxy-speedtest/tests/test_resolve_gist_raw_url.py
退出码 0 = 全部通过。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []

RAW = ('https://gist.githubusercontent.com/jarvanh/'
       'fed0982fad16e10134d9ae587f7b57b4/raw/4d25dd9f96da58ef1e6f16e75b26d1/'
       'proxy_speedtest_gistnodes_providers.yaml')
FILENAME = 'proxy_speedtest_gistnodes_providers.yaml'
GIST_ID = 'fed0982fad16e10134d9ae587f7b57b4'


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
