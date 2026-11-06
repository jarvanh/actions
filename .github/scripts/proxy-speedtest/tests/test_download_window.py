#!/usr/bin/env python3
"""CDN 下载测速的**定窗口径**自检（2026-11-05 引入）。

为什么单独一个文件：定窗测法把「失败」和「正常的窗口截断」混在了同一个信号上——
curl 在 `--max-time` 到点时退出码是 28，而 `-w` 仍然照常输出真实的字节数与耗时。
于是这一层有四种**静默**坏法，全都不会报错、只会产出一个看着正常的错数字：

  1. 把 28 当失败 ⇒ 所有慢节点 `download: null`（正是旧定长口径 62/336 个 null 的
     成因之一，改定窗要解决的就是它）；
  2. 把 28 一律当成功 ⇒ DNS 失败/连接被拒/连接重置（6/7/56）只要 curl 吐了字节数
     就被收下，测速结果里混进「几百字节 ÷ 窗口」的假低值；
  3. 不挡 `http_code>=400` ⇒ curl 不带 `--fail` 时 HTTP 4xx 返回码仍是 0，
     `size_download` 就是错误页那几百字节，成了「唯一成功值」；
  4. 计时含 TTFB ⇒ 代理节点 0.5~1.7s 的握手被折进带宽。用当轮 253 个真实样本量化，
     占总耗时中位 26%；本地构造「握手 0.6s + 1MiB/s 传输」复现，旧式 0.80 vs 新式 1.00。

前四条用纯函数直接钉边界（`download_measurement`）；第 6/7 组用**本地限速 HTTP 服务**
端到端跑 `download_speedtest`，确认 `--max-time` 截断路径真的被判定收下、单节点总预算
真的兜得住「窗口 × URL 数」，而不是只在纯函数里成立。

跑法：`python3 .github/scripts/proxy-speedtest/tests/test_download_window.py`
退出码 0 = 全过。
"""
import pathlib
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []


def check(cond, label, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + label + (f'  [{detail}]' if detail and not cond else ''))
    if not cond:
        FAILURES.append(label)


import speedtest as st  # noqa: E402


MIB = 1024 * 1024


def main():
    print('== 1. 定窗截断（exit 28）是正常路径，且速度按传输段算 ==')
    got, err = st.download_measurement(
        exit_code=st.CURL_EXIT_OPERATION_TIMEOUT, http_code=206, size_bytes=4 * MIB,
        time_total=7.8, time_starttransfer=0.8, min_bytes=int(0.5 * MIB))
    check(got is not None, 'exit 28 被收下（窗口到点截断不算失败）', err)
    if got:
        check(abs(got['transfer_seconds'] - 7.0) < 0.01,
              '计时扣掉了 TTFB（7.8 - 0.8 = 7.0）', got['transfer_seconds'])
        check(abs(got['mibps'] - round(4 / 7.0, 2)) < 0.01,
              '速度 = 字节 / 传输段（4MiB / 7.0s）', got['mibps'])
        check(got['exit_code'] == 28 and got['http_code'] == 206, '原始返回码/状态码被保留')

    print('== 2. 真失败的返回码不得被收下 ==')
    for code in (6, 7, 22, 56, 18, 52):
        got, err = st.download_measurement(
            exit_code=code, http_code=200, size_bytes=4 * MIB,
            time_total=7.8, time_starttransfer=0.8)
        check(got is None and f'curl exit {code}' in (err or ''),
              f'curl exit {code} 判失败（即使有字节数）', err)

    print('== 3. HTTP 错误页不得被当成测速 ==')
    got, err = st.download_measurement(
        exit_code=0, http_code=404, size_bytes=90,
        time_total=0.4, time_starttransfer=0.3)
    check(got is None and 'HTTP 404' in (err or ''), 'http_code 404 判失败', err)
    got, err = st.download_measurement(
        exit_code=0, http_code=503, size_bytes=1234,
        time_total=0.4, time_starttransfer=0.1)
    check(got is None and 'HTTP 503' in (err or ''), 'http_code 503 判失败', err)

    print('== 4. 有效样本下限与退化输入 ==')
    got, err = st.download_measurement(
        exit_code=28, http_code=206, size_bytes=int(0.2 * MIB),
        time_total=8.0, time_starttransfer=0.5, min_bytes=int(0.5 * MIB))
    check(got is None and 'too few bytes' in (err or ''),
          '传输字节 < min_bytes 判失败（刚建连就断）', err)
    got, err = st.download_measurement(
        exit_code=0, http_code=200, size_bytes=0,
        time_total=1.0, time_starttransfer=0.1)
    check(got is None and err == 'empty download', '零字节判失败', err)
    got, err = st.download_measurement(
        exit_code=0, http_code=200, size_bytes=2 * MIB,
        time_total=2.0, time_starttransfer=0)
    check(got is not None and abs(got['transfer_seconds'] - 2.0) < 0.01,
          'TTFB 缺失时退回总时长（不除零）', err)
    got, err = st.download_measurement(
        exit_code=0, http_code=200, size_bytes=2 * MIB,
        time_total=0, time_starttransfer=0)
    check(got is None and err == 'no elapsed time', '耗时全 0 判失败', err)

    print('== 5. 定长逃生阀：window<=0 时截断仍算失败 ==')
    got, err = st.download_measurement(
        exit_code=28, http_code=206, size_bytes=4 * MIB,
        time_total=7.8, time_starttransfer=0.8, ok_exits=(0,))
    check(got is None and 'curl exit 28' in (err or ''),
          'ok_exits=(0,) 时 exit 28 判失败（旧定长语义可回退）', err)

    print('== 6. 端到端：本地限速服务 + 真 curl 的定窗截断 ==')
    run_e2e()

    print('== 7. 端到端：单节点总预算兜住「窗口 × URL 数」 ==')
    run_e2e_budget()

    print()
    if FAILURES:
        print(f'❌ {len(FAILURES)} 项失败：')
        for f in FAILURES:
            print('   - ' + f)
        return 1
    print('✅ 全部通过')
    return 0


class _Throttled(BaseHTTPRequestHandler):
    """支持 Range 的限速服务：按 RATE 字节/秒吐数据，让 curl 必然撞上 --max-time。"""
    protocol_version = 'HTTP/1.1'
    RATE = 1 * MIB          # 1 MiB/s
    HEADER_DELAY = 0.6      # 模拟 TLS + 高 RTT 的 TTFB

    def log_message(self, *a):
        pass

    def do_GET(self):
        rng = self.headers.get('Range')
        start, end = 0, 100 * MIB
        if rng and rng.startswith('bytes='):
            a, _, b = rng[len('bytes='):].partition('-')
            try:
                start = int(a)
                if b:
                    end = int(b)
            except ValueError:
                pass
        total = end - start + 1
        # 延迟必须落在**响应头之前**：curl 的 time_starttransfer 是「首字节到达」的
        # 时刻，放在 end_headers() 之后会被算进传输段，测不出「扣 TTFB」这件事。
        time.sleep(self.HEADER_DELAY)
        self.send_response(206 if rng else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(total))
        self.send_header('Accept-Ranges', 'bytes')
        if rng:
            self.send_header('Content-Range', f'bytes {start}-{end}/{end + 1}')
        self.end_headers()
        chunk = 16 * 1024
        sent = 0
        try:
            while sent < total:
                n = min(chunk, total - sent)
                self.wfile.write(b'\0' * n)
                sent += n
                time.sleep(n / self.RATE)
        except (BrokenPipeError, ConnectionResetError):
            pass


def _free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_e2e():
    port = _free_port()
    srv = ThreadingHTTPServer(('127.0.0.1', port), _Throttled)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        url = f'http://127.0.0.1:{port}/f'
        # 3 秒窗口 × 1 MiB/s ≈ 2.4MiB（扣 0.6s TTFB）；10MiB 上界保证一定是窗口截断
        t0 = time.monotonic()
        res = st.download_speedtest([url], {}, timeout=30.0, size_hint_mib=10,
                                    window_seconds=3, min_mib=0.5)
        elapsed = time.monotonic() - t0
        print(f'     实测：ok={res.get("ok")} mibps={res.get("mibps")} '
              f'bytes={res.get("bytes")} seconds={res.get("seconds")} '
              f'ttfb={res.get("ttfb_seconds")} 墙钟={elapsed:.1f}s')
        check(res.get('ok') is True, '端到端：慢链路在定窗下仍拿到读数', res.get('error'))
        if res.get('ok'):
            check(res['bytes'] < 10 * MIB, '端到端：确实被窗口截断（没拉满 10MiB 上界）',
                  f'bytes={res["bytes"]}')
            check(0.65 <= res['mibps'] <= 1.35,
                  f'端到端：读数≈1 MiB/s（实测 {res["mibps"]}）')
            old_style = res['bytes'] / MIB / (res['seconds'] + res['ttfb_seconds'])
            check(res['mibps'] > old_style * 1.15,
                  f'端到端：新口径显著高于旧口径（新 {res["mibps"]} vs 旧 {old_style:.2f}）')
            check(elapsed < 15, f'端到端：没有拖到硬超时（{elapsed:.1f}s < 15s）')
    finally:
        srv.shutdown()
        srv.server_close()


def run_e2e_budget():
    """窗口是**单 URL** 的上限；没有整节点预算的话 N 个 URL 就是 N×窗口。

    这条测试用 3 个 URL × 2s 窗口 × 总预算 3s：正确实现墙钟 ≈3s；**没有整节点预算时
    会是 6s**（3×2），所以这条能真正把「窗口×URL 数」的回归钉住。
    """
    port = _free_port()
    srv = ThreadingHTTPServer(('127.0.0.1', port), _Throttled)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        urls = [f'http://127.0.0.1:{port}/a', f'http://127.0.0.1:{port}/b',
                f'http://127.0.0.1:{port}/c']
        t0 = time.monotonic()
        res = st.download_speedtest(urls, {}, timeout=30.0, size_hint_mib=10,
                                    window_seconds=2, min_mib=0.2, total_seconds=3)
        elapsed = time.monotonic() - t0
        print(f'     实测：ok={res.get("ok")} mibps={res.get("mibps")} '
              f'bytes={res.get("bytes")} 墙钟={elapsed:.1f}s（3 URL × 2s 窗口，总预算 3s）')
        check(res.get('ok') is True, '端到端：多 URL 下仍拿到读数', res.get('error'))
        # 允许 1.5s 的进程/握手余量；若退化成「每 URL 各 2s」会是 6s
        check(elapsed <= 4.5,
              f'端到端：整节点耗时被总预算兜住（{elapsed:.1f}s ≤ 4.5s，无预算会是 6s）')
    finally:
        srv.shutdown()
        srv.server_close()


if __name__ == '__main__':
    sys.exit(main())
