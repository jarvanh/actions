#!/usr/bin/env python3
"""`collect_provider_snapshot` 的离线自检：节点收集**不拿 alive 当准入判据**。

为什么需要它：这个函数决定「下游到底测哪些节点」。它出过一次真实事故——
2026-09-15 run 34969408908，gistnodes 交接了 13346 个活节点，taier 侧却
`nodes_collected count: 0`，整轮零产出且**没有任何报错**。

**事故根因**：provider 配的是非惰性健康检查，而 `wait_mihomo` 只等控制器
`/version` 就绪、**不等健康检查跑完**。订阅一大，读快照时 `alive` 一个都还没
置位；原实现只收 `alive` 为真的节点，于是「全量收集」退化成「收集到 0 个」。

所以现在的判据是：**provider 解析出来的节点全量收下**，`alive` 只作为附加信息
带出。真正决定某个节点值不值得测的是**逐节点**那一步（taier 的
`probe_node_alive`、gitee/cdn 的实测成败），那才是准的判据。

坏法都很隐蔽（静默少数或归零），所以固化成断言：

  * **健康检查一个结论都没有时仍要全量收集**（恢复事故形态：必须不为 0）；
  * 部分出结论时也不能只收「活」的——没收到的那些只是「还没探完」；
  * 明确判死的（`alive: false`）也要收：那是上游的事，本层不做准入；
  * `alive` 字段要原样带出（供日志/摘要），不能因为不收就丢掉；
  * mihomo 内置 provider（`AUTO` / `default`）必须忽略，否则组名会被当节点；
  * 跨 provider 重名要去重，且 provider 统计（total/alive/dead）要如实。

跑法：python .github/scripts/proxy-speedtest/tests/test_collect_provider_snapshot.py
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
    """只实现 `/providers/proxies`，按 `payload` 原样返回。"""

    payload = {}
    status = 200

    def log_message(self, *a):
        pass

    def _send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.startswith('/providers/proxies'):
            if FakeMihomo.status != 200:
                return self._send(FakeMihomo.status, {'message': 'boom'})
            return self._send(200, FakeMihomo.payload)
        return self._send(404, {'message': 'not found'})


def start_server():
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FakeMihomo)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_address[1]}'


def node(name, alive=None):
    """alive=None 表示 mihomo 还没给结论（字段缺失），必须与 alive=False 区分。"""
    item = {'name': name, 'type': 'ss', 'server': '1.1.1.1', 'port': 443}
    if alive is not None:
        item['alive'] = alive
    return item


def payload(providers):
    return {'providers': providers}


def main():
    import speedtest_gitee as G

    server, api = start_server()
    G.MIHOMO_API = api
    try:
        print('== 1. 事故形态：健康检查一个结论都没有，仍必须全量收集 ==')
        # 复刻 run 34969408908：13346 个节点但 alive 字段一个都没置位
        FakeMihomo.payload = payload({
            'remote-1': {'name': 'remote-1', 'proxies': [node(f'n{i}') for i in range(50)]},
            'AUTO': {'name': 'AUTO', 'proxies': []},
            'default': {'name': 'default', 'proxies': []},
        })
        snap, items = G.collect_provider_snapshot()
        check(len(items) == 50, f'无结论时收集到全部 50 个（实际 {len(items)}）——为 0 就是事故复现')
        check(all('alive' not in it or it['alive'] is False for it in items),
              '这些节点 alive 标记为假（还没出结论不等于活）')
        check(snap['remote-1'] == {'total': 50, 'alive': 0, 'dead': 50},
              f'provider 统计如实（实际 {snap.get("remote-1")}）')

        print('== 2. 部分出结论时，不能只收判活的那些 ==')
        FakeMihomo.payload = payload({
            'remote-1': {'name': 'remote-1', 'proxies': [
                node('a', True), node('b', False), node('c')]},
        })
        snap, items = G.collect_provider_snapshot()
        names = sorted(it['name'] for it in items)
        check(names == ['a', 'b', 'c'], f'三个全收（实际 {names}）——只收 a 就会静默少节点')
        check(snap['remote-1'] == {'total': 3, 'alive': 1, 'dead': 2},
              f'统计仍按 alive 如实计（实际 {snap["remote-1"]}）')

        print('== 3. alive 状态原样带出，不被收集逻辑吞掉 ==')
        by_name = {it['name']: it for it in items}
        check(by_name['a']['alive'] is True, 'a 带出 alive=True')
        check(by_name['b']['alive'] is False, 'b 带出 alive=False')
        check(by_name['c']['alive'] is False, 'c 无字段时归一为 False（不谎报为活）')

        print('== 4. 内置 provider（AUTO/default）必须忽略 ==')
        names = [it['name'] for it in items]
        check('AUTO' not in names and 'default' not in names,
              f'组名没被当节点收进来（实际 {names}）')

        print('== 5. 跨 provider 重名去重 ==')
        FakeMihomo.payload = payload({
            'remote-1': {'name': 'remote-1', 'proxies': [node('dup'), node('x')]},
            'remote-2': {'name': 'remote-2', 'proxies': [node('dup'), node('y')]},
        })
        snap, items = G.collect_provider_snapshot()
        names = sorted(it['name'] for it in items)
        check(names == ['dup', 'x', 'y'], f'重名只留一个（实际 {names}）')
        check(len(snap) == 2, f'两个 provider 都统计（实际 {len(snap)}）')

        print('== 6. 节点字段齐全（下游切换/测速/导出都要用）==')
        FakeMihomo.payload = payload({
            'remote-1': {'name': 'remote-1', 'proxies': [node('a', True), node('b', False)]},
        })
        snap, items = G.collect_provider_snapshot()
        it = items[0]
        for key in ('provider', 'name', 'type', 'alive', 'share_link', 'proxy_obj', 'source_entry'):
            check(key in it, f'字段 {key} 存在')
        check(it['provider'] == 'remote-1', 'provider 归属正确')
        check('alive' not in it['proxy_obj'] and 'history' not in it['proxy_obj'],
              'proxy_obj 已剔除 alive/history（切节点时不能带这些运行时字段）')

        print('== 7. 空订阅不报错、返回空列表 ==')
        FakeMihomo.payload = payload({})
        snap, items = G.collect_provider_snapshot()
        check((snap, items) == ({}, []), f'空 inputs 返回空（实际 {snap}/{items}）')

        print('== 8. API 报错要抛出（让调用方走既有失败路径，不静默零节点）==')
        FakeMihomo.status = 500
        threw = False
        try:
            G.collect_provider_snapshot()
        except Exception:
            threw = True
        finally:
            FakeMihomo.status = 200
        check(threw, 'API 500 时抛异常，而不是「安静地收集到 0 个」')
    finally:
        server.shutdown()
        server.server_close()

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
