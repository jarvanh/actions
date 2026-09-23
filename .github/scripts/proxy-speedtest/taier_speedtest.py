#!/usr/bin/env python3
"""订阅节点三网测速（引擎 MiaM1ku/taierspeedtest，链路 mihomo TUN 透明代理）。

与 speedtest.py 同属「订阅节点测速」域：复用 speedtest_common.py 共享层（订阅导出策略 /
通知排版 / 测速点归属查询 / Telegram 发送 / Gist 上传）与 speedtest_gitee.py 的 mihomo 内核 /
订阅供应商 / 节点快照 / 节点切换；测速引擎换成泰尔测速（全球网测，
协议还原自 com.cnspeedtest.globalspeed），拿到的是「订阅节点 → 国内电信/联通/移动
测速点」的延迟与单/多线程上下行带宽。

为什么必须开 TUN：taierspeedtest 是原生 TCP/ICMP 客户端，既没有 --proxy 参数，
Go 的 net.Dialer 又直接发系统调用（proxychains 这类 LD_PRELOAD 方案对它无效），
只能靠 mihomo TUN 把该进程的流量透明接入代理节点。为不误伤 runner 自身网络：

    rules: ['PROCESS-NAME,taierspeedtest,AUTO', 'MATCH,DIRECT']

即只有测速进程走代理、其余流量（含 GitHub runner 自己的心跳/日志）直连；再用
「测速看到的出口 IP == runner 直连出口 IP」校验规则是否真的生效——规则失灵或 TUN
起不来时会静默直连、整轮结果失真，这个校验必须存在（bypass 命中即判失败）。

设计原则（与 speedtest.py 一致）：
  - 共享能力一律 import 复用：纯共享层来自 speedtest_common，mihomo/订阅源来自
    speedtest_gitee（不改它们的既有行为）
  - 节点串行测试（共享同一 mihomo 内核，切换后 settle）
  - 参数全部经环境变量控制
  - 兜底对齐 gitee：SIGTERM/SIGINT → ⛔ 通知；未捕获异常/阶段失败 → ❌ 通知
    （所有失败路径均先撤 TUN 再发——notify_failure 内部先调幂等的 stop_mihomo_tun）
"""
import html
import json
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime

import yaml

# ---------------------------------------------------------------------------
# 复用 speedtest_gitee.py 的已验证能力（import 期会创建 ~/proxy-speedtest 及其 providers/、
# source-snapshots/ 子目录）
# ---------------------------------------------------------------------------
from speedtest_common import (
    HOME_RUNTIME,
    build_node_metric_prefix,
    build_subscription_bundle,
    build_target_network_section,
    fetch_ip_network_info,
    log_progress,
    merged_env,
    resolve_host_ipv4,
    resolve_subscription_policy,
    send_telegram,
    send_telegram_chunked,
    # 到点收摊判据由共享层提供（四套测速同一份实现，避免各写一遍后漂移）
    should_stop_for_budget,
    speedtest_budget_deadline,
    tg_entry, tg_entry_codes,
    tg_footer_line,
    tg_format_elapsed,
    tg_pre_block,
    update_gist,
    TG_SEP,
)
from speedtest_gitee import (
    MIHOMO,
    MIHOMO_API,
    MIHOMO_CONFIG,
    MIHOMO_LOG,
    build_mihomo_config,
    build_source_mapping,
    collect_provider_snapshot,
    ensure_local_mihomo,
    switch_proxy,
    wait_mihomo,
    # 开测前等 provider 展开（四套共用；见 speedtest_gitee.wait_provider_ready）
    wait_provider_ready,
)

# ---------------------------------------------------------------------------
# 配置（全部可经环境变量覆盖）
# ---------------------------------------------------------------------------
TAIER_REPO = (os.environ.get('TAIER_REPO') or 'MiaM1ku/taierspeedtest').strip() or 'MiaM1ku/taierspeedtest'
TAIER_RELEASE_API = f'https://api.github.com/repos/{TAIER_REPO}/releases/latest'
TAIER = HOME_RUNTIME / 'taierspeedtest'
TAIER_LOG = HOME_RUNTIME / 'taier_speedtest.log'
RESULT_JSON = HOME_RUNTIME / 'taier_speedtest_result.json'

# 泰尔控制服务器（引擎 fetchClient 的降级链，原样照抄）。
# ⚠️ 位置必须在 CONFIG 之前：CONFIG 里的测活默认 URL 引用了它，而 CONFIG 是**导入时**求值的，
# 定义在后面会直接 NameError（pyflakes F821 能抓到，`py_compile` 抓不到）。
_TAIER_CTRL_SERVERS = [
    'https://dlcv2.cnspeedtest.cn:8443',
    'http://dlc.duoweisoft.com:8096',
    'http://dlcv2.duoweisoft.com:8088',
]

CONFIG = {
    # 测速点：单个点即可（每点 = 一次完整上下行），多点会成倍拉长单节点耗时
    'TAIER_POINTS': (os.environ.get('TAIER_POINTS', '') or '广东联通').strip(),
    # 默认 single = 单连接：与 proxy-speedtest 系列的单流口径可比，也更贴近日常
    # 单流体验；multi（下 8 + 上 4 连接）看节点带宽上限，both 两者对照
    'TAIER_MODE': (os.environ.get('TAIER_MODE', '') or 'single').strip(),
    # 上游二进制把 --duration 硬钳制在 5-13（main.go），>13 会被压到 13。
    # 默认 5（2026-09-17 从 10 下调）：节点数远超 5 小时预算（8326 个 ÷ 19.6s ≈ 45 小时），
    # 单节点成本 2×duration+5 里 duration 是最大且唯一可调的杠杆——10→5 把单节点从
    # ≈25 秒压到 ≈15 秒，同等预算能覆盖的节点数从 ~900 提到 ~1500（约 +67%）。
    # 代价是每方向采样窗口减半、读数更抖；配合下面的「优先测速」把窗口留给值得的节点。
    'TAIER_DURATION': min(max(int(os.environ.get('TAIER_DURATION', '5') or 5), 5), 13),
    # 0 = 不限（默认）；节点多时整体耗时 ≈ 节点数 × (2×duration + 5)s
    'TAIER_MAX_NODES': int(os.environ.get('TAIER_MAX_NODES', '0') or 0),
    # 节点名优先级正则（不区分大小写）：命中者**排到队首先测**，其余按原序追加。
    # 为什么需要它：节点数远超预算时，测速顺序 = 谁进订阅名单的顺序，原序是 provider 的
    # 声明序（与质量无关），等于把宝贵的测速窗口随机撒给几千个节点。专线/常见优质地区
    # （IPLC/IEPL 专线、HK/TW/SG 低延迟区）命中率高得多，让它们先测，预算耗尽时至少
    # 订阅里留下的是这些。**只排序、不丢弃**：未命中的节点仍在队尾照常参与（测得到就测）。
    'TAIER_PRIORITY_REGEX': ((os.environ.get('TAIER_PRIORITY_REGEX', '') or '').strip()
                             or 'IPLC|IPEL|IEPL|专线|HK|Hong|港|TW|Taiwan|台|SG|新加坡'),
    # 节点名 include 正则（不区分大小写）：命中者**保留**、未命中者**丢弃**——与上面的
    # 优先级正则（只排序、不丢弃）互补。为什么需要它：排序只能决定「先测谁」，决定不了
    # 「池子有多大」；编排轮（proxy-speedtest-gistnodes）交接的池子上万（2026-09-22 实测
    # 15793 个，5 小时预算只测完 1905 个），只有把池子压到预算内每轮才收得了摊。
    # 留空 = 不过滤（默认）：定时轮吃的是用户自己的机场订阅，不该被正则砍；只有编排轮
    # 经 workflow_call 入参显式传入。两条 fail-open 见 filter_nodes_include。
    'TAIER_INCLUDE_REGEX': (os.environ.get('TAIER_INCLUDE_REGEX', '') or '').strip(),
    # 墙钟预算（秒，0 = 不限）。**必须显著小于 job 的 timeout-minutes（默认 360 分钟）**，
    # 留出前置准备（mihomo 下载 / TUN）与收尾（通知 / Gist 上传）的余量：默认 5 小时。
    # 为什么需要它：测速逐节点串行、每节点 ≈ 25 秒，而订阅里可能有几千个节点
    # （proxy-speedtest-gistnodes 2026-09-14 那轮交接 3284 个 ≈ 22.8 小时），
    # 撞 GitHub 的**硬取消**会把整轮工作全废；到点收摊则能拿已测节点出订阅。
    'TAIER_BUDGET_SECONDS': int(os.environ.get('TAIER_BUDGET_SECONDS', '18000') or 0),
    # 测速前先测活：死节点别再烧掉一整个测速窗口（≈25 秒）。探测目标默认是**泰尔自己的
    # 控制面**（`_TAIER_CTRL_SERVERS[0]`）——测的是「这个节点到底能不能跑泰尔」，而不是
    # 泛泛的连通性；探测 URL 可覆盖。判死只认 mihomo 的明确结论，机制出错一律 fail-open
    # （见 probe_node_alive）。
    #
    # ⚠️ **默认开启（2026-09-15 改回）**：曾因 run 34859505000 里 27 个节点**全部**探测失败
    # （mihomo 的 `Resource not found`——不是「连不上」，而是探测请求里的节点名在 mihomo 里
    # 找不到，多半是重名去重/改名）而临时默认关闭，避免误杀。既然要的是「死节点别占窗口」，
    # 就该默认开：误杀风险由**熔断**（开头连续 8 个未通过且无一成功即关掉探测）与
    # **fail-open**（机制出错按存活处理）双重兜住，代价可控——真要规避误杀可设
    # `TAIER_ALIVE_PROBE=0` 显式关闭。
    #
    # 这一层现在是**唯一的准入关口**：`collect_provider_snapshot` 已不再按 provider 的
    # `alive` 预筛（那条路在订阅大时会把节点收成 0 个，见其 docstring），收集来的节点
    # 全量进循环，由这里逐个判「值不值得烧 25 秒」。
    'TAIER_ALIVE_PROBE': (os.environ.get('TAIER_ALIVE_PROBE', '1').strip().lower()
                          not in ('0', 'false', 'no', 'off')),
    'TAIER_ALIVE_PROBE_URL': ((os.environ.get('TAIER_ALIVE_PROBE_URL', '') or '').strip()
                              or _TAIER_CTRL_SERVERS[0]),
    'TAIER_ALIVE_PROBE_TIMEOUT_MS': int(os.environ.get('TAIER_ALIVE_PROBE_TIMEOUT_MS', '3000') or 3000),
    'TAIER_TIMEOUT': int(os.environ.get('TAIER_TIMEOUT', '120') or 120),
    'TAIER_SWITCH_SETTLE': float(os.environ.get('TAIER_SWITCH_SETTLE_SECONDS', '1.5') or 1.5),
    # 每节点是否出结果图（上传图床）：默认关，避免 N 个节点刷 N 张图
    'TAIER_IMAGE': (os.environ.get('TAIER_IMAGE', '0').strip().lower() in ('1', 'true', 'yes', 'on')),
    # 默认不测 IPv6：TUN 下客户端会误判 v6 可用而把单节点耗时翻倍，且多数节点无 v6
    'TAIER_NO_IPV6': (os.environ.get('TAIER_NO_IPV6', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
}

# `should_stop_for_budget` 由 speedtest_common 提供（四套测速共用一份判据），见文件头 import。

def probe_node_alive(name, url, timeout_ms):
    """经 mihomo 的 `GET /proxies/{name}/delay` 测活：连得通才去跑那 25 秒的测速。

    返回 `(alive, delay_ms, error)`。

    ⚠️ **只能对节点名探测，不能对组名探测。** mihomo 的 `/proxies/{name}/delay` 里
    `name` 必须是**节点（proxy）**的名字——测速时真正承载流量的是 `AUTO` 这个 select 组，
    当前指向谁由 `switch_proxy` 决定，但 `AUTO` 本身不是节点，对它探测只会拿到
    `Resource not found`（2026-09-15 实测：编排轮 8/8 全失败即此形态）。测活必须用
    `name`，与 `switch_proxy(name, ...)` 保持同一个标识。

    ⚠️ **只有 mihomo 明确判「连不上」才算死；探测机制本身出错一律 fail-open（按存活处理）。**
    为什么：探测挂了（mihomo API 抖动、URL 配错、本机超时）若被当成「节点死了」，整轮会
    **一个节点都不测**——那比在死节点上多花 25 秒糟得多。宁可多烧时间，也不能零产出。
    """
    path = ('/proxies/' + urllib.parse.quote(str(name), safe='')
            + '/delay?url=' + urllib.parse.quote(str(url), safe='')
            + '&timeout=' + str(max(1, int(timeout_ms))))
    # ⚠️ 必须走**绕过代理**的 opener：mihomo API 是本机回环（127.0.0.1），而 `urlopen` 会
    # 尊重环境里的 HTTP_PROXY —— 不少机器（含 macOS 开系统代理时）连 127.0.0.1 都被送进
    # 代理，于是拿到的是代理的错误页。那会被下面的分支当成「mihomo 判死」，进而整轮
    # 一个节点都不测。本机回环永远不该经代理。
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        # 外层超时给「mihomo 自己的超时 + 余量」：短了会在 mihomo 给结论前就断开
        with opener.open(MIHOMO_API + path,
                         timeout=max(10.0, timeout_ms / 1000.0 + 10)) as r:
            data = json.loads(r.read().decode('utf-8', 'ignore') or '{}')
    except urllib.error.HTTPError as e:
        # mihomo 对连不上的节点返回 4xx/5xx 并带 {"message": "..."}——这是它给出的**判死**结论
        try:
            raw = e.read().decode('utf-8', 'ignore')
        except Exception:
            raw = ''
        try:
            msg = (json.loads(raw) or {}).get('message') or raw
        except Exception:
            msg = raw
        return False, None, (str(msg)[:200] or f'HTTP {e.code}')
    except Exception as e:
        # 探测机制不可用 → fail-open
        return True, None, f'探测不可用（按存活处理）：{e}'
    delay = data.get('delay')
    if isinstance(delay, int) and delay > 0:
        return True, delay, ''
    return False, None, str(data.get('message') or '无延迟值（连不上）')[:200]


def is_unknown_proxy_error(err):
    """判断探测失败是不是「mihomo 不认识这个节点名」——与「节点真的连不上」区分开。

    为什么必须分开（2026-09-16 run 35116972319，8 条 `Resource not found`）：
    那 8 条**每两次间隔恒为 ~18.7 毫秒**（`.016`→`.035`→`.053`→…→`.147`）。真去连节点
    不可能这么快——探测超时是 3000ms，而这是**本地 HTTP 的往返耗时**，说明 mihomo
    **压根没发起连接**，只是在 `/proxies/{name}` 里找不到这个名字。

    原因是 **provider 惰性展开**：`collect_provider_snapshot` 从 `/providers/proxies`
    读到的是**声明清单**（8326 个名字），但那一刻这些节点**还没注册进 `/proxies/{name}`
    路由表**。日志时序可证——读快照（`16:13:31.996`）后 **20 毫秒**就开始探测，
    而第一个测速结果要到 `16:13:48.712`（16 秒后）才出现，那时 provider 早就绪了。

    所以这类错误**不能当成「节点死了」**：它不是节点的属性，是 mihomo 的加载状态。

    **判据只认「这个节点名不存在」的措辞，不要放宽成 `'not found'` 子串**：那样会把
    `host not found` / `URL not found`（真·网络故障）一并吞成「机制故障 → fail-open」，
    于是真连不上的节点被判成存活、还绕过熔断，噪声换成了漏判。mihomo 的实际文案是
    `Resource not found`（`/proxies/{name}` 查不到），不同版本偶有 `no such proxy`。
    """
    text = str(err or '').strip().lower()
    if not text:
        return False
    # 先挡掉真·网络故障：DNS 解析失败也含 "not found"，但它是节点问题、不是加载状态
    if 'host not found' in text or 'name or service not known' in text:
        return False
    return 'resource not found' in text or 'no such proxy' in text


def prioritize_nodes(items: list, pattern: str):
    """把节点名命中 `pattern` 的排到队首，其余保持原相对顺序。返回 `(排序后列表, 命中数)`。

    **只重排、不丢弃**：未命中的节点仍在队尾，预算够就照测。这样「优先」是软保证——
    命中节点先拿到测速窗口，但不会因为不命中就被排除出订阅候选。

    **必须是稳定分区而不是排序**：命中集与未命中集内部都保持 provider 的原序，
    否则同一份订阅每轮的测速顺序会漂移，历史对照数据就失去可比性。

    `pattern` 非法（正则语法错）时**原样返回、不抛**——一个配置写错不该让整轮零产出，
    与测活层的 fail-open 同一原则。
    """
    if not items or not pattern:
        return items, 0
    try:
        rx = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        log_progress('priority_regex_invalid', pattern=pattern, error=str(e))
        return items, 0
    hit = [x for x in items if rx.search(str(x.get('name') or ''))]
    miss = [x for x in items if not rx.search(str(x.get('name') or ''))]
    return hit + miss, len(hit)


def filter_nodes_include(items: list, pattern: str):
    """把节点名未命中 `pattern` 的**丢弃**，只留命中者。返回 `(保留列表, 丢弃数)`。

    与 `prioritize_nodes`（只排序、不丢弃）互补：排序决定「先测谁」，过滤决定
    「池子有多大」。编排轮节点数远超预算时，只有后者真正缩短运行时长。

    两条 fail-open（与测活层同一原则——过滤层故障不得造成零产出）：

    - `pattern` 非法（正则语法错）→ 原样返回并记 `include_regex_invalid`，不抛；
    - 过滤后一个不剩 → 原样返回并记 `include_regex_all_dropped_fallback`。
      全不剩更可能是**正则词表与当轮节点命名完全错位**，而不是「节点真的一万个都不要」；
      拿它当真会让整轮零节点，比不过滤糟得多。

    命中判据与 prioritize 同款：`re.IGNORECASE` + 只看 `name`；保留集内保持原相对序
    （调用方把它放在 prioritize 之后，命中者前置的顺序不会被破坏）。
    """
    if not items or not pattern:
        return items, 0
    try:
        rx = re.compile(pattern, re.IGNORECASE)
    except re.error as e:
        log_progress('include_regex_invalid', pattern=pattern, error=str(e))
        return items, 0
    kept = [x for x in items if rx.search(str(x.get('name') or ''))]
    if not kept:
        log_progress('include_regex_all_dropped_fallback', total=len(items), pattern=pattern)
        return items, 0
    dropped = len(items) - len(kept)
    log_progress('nodes_include_filtered', before=len(items), kept=len(kept),
                 dropped=dropped, pattern=pattern)
    return kept, dropped


def _revive_probe_failed(results, alive_items, retry_queue):
    """把「待定判死」的节点撤销判死、放回测速队列，并返回撤销的条数。

    撤销是**原地**改 `results`（删除伪造的失败条目）与 `alive_items`（追加回队列）。
    用可变对象传参，避免在循环里对局部名字做多重赋值。

    为什么必须撤销：熔断判定「这是探测机制故障」之后，那些节点从未被真正探测过，
    不该在通知里以「测活未通过」出现——读者会去排查一批其实正常的节点。
    """
    if not retry_queue:
        return 0
    names = {str(x.get('name') or '') for x in retry_queue}
    results[:] = [r for r in results
                  if not (r.get('probe_failed') and str(r.get('name') or '') in names)]
    revived = [i for i in alive_items if str(i.get('name') or '') in names]
    alive_items.extend(revived)
    n = len(retry_queue)
    retry_queue.clear()
    return n


MODE_LABELS = {'single': '只测单线程', 'multi': '只测多线程', 'both': '单线程 + 多线程对照'}
ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
VERSION = {'taier': '', 'mihomo': ''}


# ---------------------------------------------------------------------------
# 客户端 / 内核准备
# ---------------------------------------------------------------------------
def _github_json(url: str):
    """取 GitHub API JSON；共享出口 IP 匿名限流时用 GITHUB_TOKEN / GH_TOKEN 兜底。"""
    headers = {'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'}
    token = (os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN') or '').strip()
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def ensure_local_taier():
    """下载 taierspeedtest 最新 Release 二进制（固定文件名，供 PROCESS-NAME 规则匹配）。"""
    if TAIER.exists() and os.access(TAIER, os.X_OK):
        return TAIER
    arch = 'arm64' if os.uname().machine in ('aarch64', 'arm64') else 'amd64'
    asset = f'taierspeedtest-linux-{arch}'
    data = _github_json(TAIER_RELEASE_API)
    VERSION['taier'] = str(data.get('tag_name') or '')
    url = ''
    for a in data.get('assets') or []:
        if a.get('name') == asset:
            url = str(a.get('browser_download_url') or '')
    if not url:
        raise RuntimeError(f'{asset} not found in {TAIER_REPO} latest release')
    with urllib.request.urlopen(url, timeout=180) as r, TAIER.open('wb') as f:
        shutil.copyfileobj(r, f)
    os.chmod(TAIER, 0o755)
    log_progress('taier_downloaded', tag=VERSION['taier'], asset=asset, path=str(TAIER))
    return TAIER


def _sudo_prefix():
    """TUN（创建网卡 + auto-route 改路由）需要 CAP_NET_ADMIN，非 root 时借 sudo。"""
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        return []
    return ['sudo', '-n']


def _kill_stale_mihomo():
    try:
        out = subprocess.run(['pgrep', '-af', f'{MIHOMO} -d'], text=True,
                             capture_output=True, timeout=10)
    except Exception as e:
        log_progress('mihomo_process_scan_failed', error=str(e))
        return
    for raw in (out.stdout or '').splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            pid = int(line.split(None, 1)[0])
        except ValueError:
            continue
        if pid == os.getpid():
            continue
        try:
            os.kill(pid, 15)
        except Exception:
            # root 起的进程普通用户无权 kill
            subprocess.run(_sudo_prefix() + ['kill', '-TERM', str(pid)],
                           capture_output=True, timeout=10)


def build_tun_config(env):
    """在 speedtest_gitee 的原配置上开 TUN + 进程级分流（不改动原函数）。

    只改 4 处：
      mode: rule        → global 模式会忽略 rules，必须切回 rule
      tun.enable/auto-route/auto-detect-interface → 透明接管（需 CAP_NET_ADMIN）
      PROCESS-NAME 规则 → 仅测速进程走 AUTO（即当前节点）
      MATCH,DIRECT      → 其余流量直连，避免把 runner 自身流量也拖进节点
    """
    cfg, raw_proxy_map = build_mihomo_config(env)
    cfg['mode'] = 'rule'
    cfg['tun'] = {
        'enable': True,
        'stack': 'mixed',
        'auto-route': True,
        'auto-detect-interface': True,
    }
    # TUN 起来后 DNS 会被 mihomo 劫持：默认递归解析器（国内 DNS）在 Azure runner 上
    # 经常不通，会让 runner 自己（日志/状态回传）与测速客户端一起解析失败。
    # 显式指定可达的公共递归解析器 + respect-rules=false（DNS 不走规则，直接解析）。
    cfg['dns'] = {
        'enable': True,
        'respect-rules': False,
        'nameserver': ['1.1.1.1', '8.8.8.8'],
    }
    cfg['rules'] = [f'PROCESS-NAME,{TAIER.name},AUTO', 'MATCH,DIRECT']
    MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                             encoding='utf-8')
    log_progress('mihomo_tun_config_built', mode=cfg['mode'], rules=cfg['rules'])
    return raw_proxy_map


def start_mihomo_tun(env):
    ensure_local_mihomo()
    raw_proxy_map = build_tun_config(env)
    _kill_stale_mihomo()
    time.sleep(1)
    cmd = _sudo_prefix() + [str(MIHOMO), '-d', str(HOME_RUNTIME), '-f', str(MIHOMO_CONFIG)]
    with MIHOMO_LOG.open('a', encoding='utf-8') as lf:
        subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    info = wait_mihomo(timeout=40)
    try:
        VERSION['mihomo'] = str((info or {}).get('version') or '')
    except Exception:
        pass
    return raw_proxy_map


def stop_mihomo_tun():
    """收尾必须关掉 mihomo（可重复调用）。

    TUN 的 auto-route 会接管整机的出向路由：脚本退出后若内核还活着，runner 自己
    的日志/状态回传也会被劫持，表现为「所有 step 已完成但 run 永远 in_progress、
    连 cancel 都执行不了」，只能等 job 超时。mihomo 正常退出时会撤掉路由表，
    所以这里 kill 即可；workflow 里另有一个 always() 兜底步骤。
    """
    _kill_stale_mihomo()
    time.sleep(2)
    log_progress('mihomo_tun_stopped')


def direct_egress_ip():
    """runner 直连出口 IP：用于校验「测速流量真的进了代理节点」。"""
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://myip.ipip.net'):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=8) as r:
                text = r.read().decode('utf-8', 'ignore')
            m = re.search(r'(?:\d{1,3}\.){3}\d{1,3}', text)
            if m:
                return m.group(0)
        except Exception:
            continue
    return ''


# ---------------------------------------------------------------------------
# 测速执行与解析
# ---------------------------------------------------------------------------
def run_taier(points: str, mode: str, duration: int, timeout: int, with_image: bool):
    cmd = [str(TAIER), '--points', points, '--mode', mode, '--duration', str(duration)]
    if not with_image:
        cmd.append('--no-image')
    if CONFIG['TAIER_NO_IPV6']:
        cmd.append('--no-ipv6')
    try:
        p = subprocess.run(cmd, text=True, capture_output=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout or '', p.stderr or ''
    except subprocess.TimeoutExpired:
        return 124, '', f'timeout after {timeout}s'


def _mbps(value):
    m = re.match(r'^([0-9]+(?:\.[0-9]+)?)', str(value or ''))
    return float(m.group(1)) if m else 0.0


def _rtt_to_ms(rtt):
    m = re.match(r'^([0-9]+(?:\.[0-9]+)?)', str(rtt or ''))
    return float(m.group(1)) if m else 0


def parse_taier_output(text: str):
    """解析 stdout → 出口 IP/位置、首行结果（延迟/上行/下行）、原始表格。

    说明：stdout 非 TTY 时颜色已关，但「出口」「结果图」两行是硬编码 ANSI 常量
    （不经过 useColor），必须先剥转义再解析。
    """
    clean = ANSI_RE.sub('', text or '')
    out = {'exit_ip': '', 'exit_loc': '', 'region': '', 'rtt': '', 'up': 0.0, 'down': 0.0,
           'image': '', 'table': ''}
    m = re.search(r'^\s*出口\s+(\S+)\s*(.*)$', clean, re.M)
    if m:
        out['exit_ip'] = m.group(1).strip()
        out['exit_loc'] = re.sub(r'\s+', ' ', m.group(2) or '').strip()
    m = re.search(r'^结果图\s+(\S+)\s*$', clean, re.M)
    if m:
        out['image'] = m.group(1).strip()

    rows = []
    started = False
    for line in clean.splitlines():
        if not started:
            if '延迟' in line:
                started = True
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith('结果图'):
            continue
        rows.append(line.rstrip())
    out['table'] = '\n'.join(rows).strip()

    for line in rows:
        parts = line.split()
        if len(parts) == 6:  # both: 区域 延迟 单↑ 单↓ 多↑ 多↓
            region, rtt, _su, _sd, mu, md = parts
            up, down = mu, md
        elif len(parts) == 4:  # single / multi: 区域 延迟 ↑ ↓
            region, rtt, up, down = parts
        else:
            continue
        out.update({'region': region, 'rtt': rtt, 'up': _mbps(up), 'down': _mbps(down)})
        break
    return out


# ---------------------------------------------------------------------------
# 通知（全库统一 HTML 版式；动态内容一律 escape）
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 测速点定位（复刻 taierspeedtest 的 match 协议，protocol.go/main.go）
# ---------------------------------------------------------------------------
_TAIER_PKG = 'com.cnspeedtest.globalspeed'
_TAIER_UA_DALVIK = 'Dalvik/2.1.0 (Linux; U; Android 14; NE2210 Build/TP1A.220624.014)'
# 省 → 省会城市（main.go provinceCity，match API 的 city 参数用）
_TAIER_PROVINCE_CITY = {
    '北京': '北京', '天津': '天津', '上海': '上海', '重庆': '重庆',
    '河北': '石家庄', '山西': '太原', '内蒙古': '呼和浩特',
    '辽宁': '沈阳', '吉林': '长春', '黑龙江': '哈尔滨',
    '江苏': '南京', '浙江': '杭州', '安徽': '合肥', '福建': '福州',
    '江西': '南昌', '山东': '济南', '河南': '郑州', '湖北': '武汉',
    '湖南': '长沙', '广东': '广州', '广西': '南宁', '海南': '海口',
    '四川': '成都', '贵州': '贵阳', '云南': '昆明', '西藏': '拉萨',
    '陕西': '西安', '甘肃': '兰州', '青海': '西宁', '宁夏': '银川',
    '新疆': '乌鲁木齐',
}
# 计划单列市（main.go extraCity）：城市名 → (省, 市)
_TAIER_EXTRA_CITY = {
    '深圳': ('广东', '深圳'), '苏州': ('江苏', '苏州'), '宁波': ('浙江', '宁波'),
    '青岛': ('山东', '青岛'), '厦门': ('福建', '厦门'), '东莞': ('广东', '东莞'),
    '无锡': ('江苏', '无锡'), '佛山': ('广东', '佛山'),
}
_TAIER_ISPS = ('电信', '联通', '移动')


def parse_taier_points(points):
    """'广东联通' / '武汉电信' → (省, 市, 运营商)；解析失败返回 (None, None, None)。

    口径与引擎 parsePoints/resolveLocation 一致：去运营商后缀 → 先查计划单列市、
    再查省份（city 取省会）。
    """
    s = str(points or '').strip()
    oper = ''
    for name in _TAIER_ISPS:
        if s.endswith(name):
            oper = name
            s = s[:-len(name)].strip()
            break
    if not s:
        return (None, None, None)
    if s in _TAIER_EXTRA_CITY:
        prov, city = _TAIER_EXTRA_CITY[s]
    elif s in _TAIER_PROVINCE_CITY:
        prov, city = s, _TAIER_PROVINCE_CITY[s]
    else:
        # 城市名（省会）反查省份（引擎 resolveLocation 第三分支，如「武汉电信」）
        for p, cty in _TAIER_PROVINCE_CITY.items():
            if cty == s:
                prov, city = p, s
                break
        else:
            return (None, None, None)
    return (prov, city, oper)


def match_taier_server(prov, city, oper, client_ip, timeout=10):
    """调泰尔控制服务器 mobilematch_many.php 定位测速服务器（复刻 matchServers）。

    按 省/市/运营商 显式过滤；选服务器按引擎 pickServer 口径：优先 hostname 含
    运营商名的，否则取列表第一个。失败返回 None，不抛异常。
    """
    v = urllib.parse.urlencode({
        'ip': client_ip or '', 'network': '4', 'province': prov, 'city': city,
        'wifioper': oper, 'mobileoperid': '', 'ipv6': '0',
        'model': 'Android', 'pkg': _TAIER_PKG,
    })
    for base in _TAIER_CTRL_SERVERS:
        try:
            req = urllib.request.Request(
                base + '/dataServer/mobilematch_many.php?' + v,
                headers={'User-Agent': _TAIER_UA_DALVIK})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                arr = json.load(r)
            if not isinstance(arr, list) or not arr:
                continue
            for s in arr:
                if oper and oper in str(s.get('hostname') or ''):
                    return s
            return arr[0]
        except Exception as e:
            log_progress('taier_match_server_failed', base=base, error=str(e))
            continue
    return None


def taier_target_network_lines(points, client_ip):
    """「📍 测速点网络」KV 树块：泰尔测速服务器（IP:port · 主机名）+ 其 IP 归属。

    版式由四套统一的 build_target_network_section 渲染（单测速点 = 4 行 KV 树）；
    本函数只负责泰尔特有的一步——按省/市/运营商 match 协议定位测速服务器。
    match / 归属查询失败逐级降级为「归属获取失败」，不抛异常、不阻塞通知。
    须在 stop_mihomo_tun() 之后调用（此时为 runner 直连出口视角）。
    """
    prov, city, oper = parse_taier_points(points)
    server = ''
    label = ''
    info = None
    if prov:
        srv = match_taier_server(prov, city, oper, client_ip)
        if srv:
            ip = str(srv.get('hostip') or '')
            port = str(srv.get('port') or '')
            label = str(srv.get('hostname') or '').strip()
            if ip:
                server = f'{ip}:{port}' if port else ip
                info = fetch_ip_network_info(ip)
    if not server:
        # 降级提示保留旧口径：省 · 市 · 运营商（或原始测速点参数）
        label = label or ' · '.join(x for x in (prov, city, oper) if x) or str(points or '')
    return build_target_network_section([(server, label, info)])


def build_telegram_lines(results, meta, direct_ip, bypass_hits, gist_res, bundle, gist_error='',
                         aborted_due_to_runtime=False, runtime_abort_reason='',
                         collected_total=0):
    def esc(s):
        return html.escape(str(s))
    # 订阅策略（阈值 / 实际采用的判定指标 / 达标数 / 最少节点数）
    bundle = bundle or {}
    qualified_count = bundle.get('qualified', 0)
    min_megabit = bundle.get('min_megabit', 0)
    min_nodes = bundle.get('min_nodes', 1)
    metric_label = bundle.get('metric_label', '')

    sep = TG_SEP
    ok_results = [r for r in results if r.get('ok') and not r.get('bypass')]
    # TOP 排序与订阅判定同口径：按实际采用的判定指标排序（默认上传），
    # 否则会出现「按上传达标导出、却按下行排 TOP」的自相矛盾展示
    top_sort_key = 'up' if bundle.get('metric', 'upload') == 'upload' else 'down'
    top = sorted(ok_results, key=lambda r: r.get(top_sort_key) or 0.0, reverse=True)[:5]
    # 标题状态随结论降级（规范 · 状态图标语义）：0 成功 / 命中「疑似未走代理」→ ⚠️，
    # 不再恒 ✅（此前 ✅ 标题下写着 ⚠️ 疑似未走代理，与 rc=1 的失败判定自相矛盾）
    # 来源标签（PROXY_SPEEDTEST_LABEL）：编排层 proxy-speedtest-gistnodes 调用时传
    # 「gist 节点」，标题变成「gist 节点 · 泰尔三网测速」。同一套测速会被定时轮和 gist 抓取轮
    # 分别触发，标题不区分的话读者分不清通知来自哪一轮（规范 · 3.1 允许标题带区分词）。
    # ⚠️ 这一行是 2026-09-14 补的：上面的注释与下面的 f-string 早就在了，**赋值行却漏了**，
    # 于是标题一渲染就 `NameError: name '_title_emoji' is not defined`，整条通知发不出去
    # （`telegram_send_failed`，而 job 照样「成功」——通知失败不改 exit code，所以静默了）。
    # 判据与注释、规范（规范 · 3.x 测速三套：0 成功 / 疑似未走代理降级 ⚠️）一致。
    _title_emoji = '⚠️' if (not ok_results or bypass_hits or aborted_due_to_runtime) else '✅'
    _label = (merged_env().get('PROXY_SPEEDTEST_LABEL') or '').strip()
    _title_prefix = f'{_label} · ' if _label else ''
    lines = [
        f'{_title_emoji} {_title_prefix}泰尔三网测速',
        sep,
        f"🕒 起止：{esc(meta['started_text'])} ~ {esc(meta['ended_text'])} · 耗时 {esc(meta['duration_text'])}",
        # 计数口径与 cdn/gitee 统一用「可用」（成功=功能可用，含节点连接成功但速度偏低）
        f"📊 节点：共 {len(results)} 个 · 可用 {len(ok_results)} 个",
        # 到点收摊 / 运行中中止：**不是失败**（退出码仍 0），但必须说清，否则读者会以为
        # 「只测了这么几个」是订阅本身的问题（规范 · 2.7 测速三套）
        *([f'⚠️ 本轮已中止：{esc(runtime_abort_reason)}'] if aborted_due_to_runtime else []),
        # 取值行口径（规范 · 取值行口径）：测速点与模式都取自引擎参数（机器返回值），整行同为等宽
        # 不用 📍：紧随其后的「📍 测速点网络」分节（共享层）已占用该 emoji，
        # 同一条通知两个 📍 会让读者以为是同一块的两个小组
        f"🎯 测速点：{tg_entry(meta['points'])} · 模式：{tg_entry(meta['mode_label'])}",
        f"🧪 引擎：{tg_entry('taierspeedtest ' + (VERSION['taier'] or 'latest'))}",
        '',
    ]
    # 测速点（泰尔服务器）的网络归属：按测速点参数复刻引擎 match 协议定位服务器，
    # 再查其 IP 归属（IP/ISP/ASN/位置）；已在 stop_mihomo_tun() 之后调用（直连视角）
    lines.extend(taier_target_network_lines(meta['points'], direct_ip))
    lines.append('')
    if top:
        # 四套统一：TOP 条目复用共享的 build_node_metric_prefix（↑上传 · ↓下载 · 延迟ms，
        # 单位「兆」），不再手拼 Mbps —— 此前只有 taier 一处两种单位/分隔符（规范 · 入口与凭据 统一优先于个性）。
        # 引擎原始值 Mbps → 共享层单位 MiB/s（÷8.388608），与订阅导出口径一致
        _top_mode = 'push-only' if bundle.get('metric', 'upload') == 'upload' else 'download'
        has_up = any((r.get('up') or 0) > 0 for r in top)
        legend = '↑上传 · ↓下载 · 延迟ms' if has_up else '↓下载 · 延迟ms'
        # 标题点出排序依据（= 订阅判定指标），避免读者按 ↓ 数值读不出顺序
        sort_hint = f' · 按{esc(metric_label)}' if metric_label else ''
        lines.append(f'🏆 最快节点 · {len(top)}{sort_hint} · {legend}')
        for idx, r in enumerate(top, 1):
            connector = '└─' if idx == len(top) else '├─'
            prefix = build_node_metric_prefix({
                'upload_mibs': (r.get('up') or 0) / 8.388608,
                'download_mibs': (r.get('down') or 0) / 8.388608,
                'latency_ms': _rtt_to_ms(r.get('rtt')),
            }, _top_mode, order='up_first')
            # 条目行统一走共享的 tg_entry（主体 + 元数据，转义与分隔符一致）
            lines.append(f'<code>  {connector} </code>' + tg_entry(r.get("name", ""), prefix))
        lines.append('')
    else:
        lines.append('⚠️ 没有节点测速成功')
        lines.append('')

    if bypass_hits:
        lines.append('⚠️ 疑似未走代理')
        lines.append(f"<code>  └─ </code>{bypass_hits} 个节点的出口 IP 与 runner 直连出口（{tg_entry(direct_ip)}）相同，"
                     'TUN 进程规则可能未生效，结果不可信')
        lines.append('')

    failed = [r for r in results if not r.get('ok')]
    # 测活探测失败单独成节：它不是「节点失败」，而是「探测机制没跑通」。
    # 混进 ❌ 失败清单会让读者以为这些节点是坏的（2026-09-16 run 35116972319 的
    # 8 条 Resource not found 就是这么被误读的：实测它们根本没被真正探测过）。
    probe_failed = [r for r in failed if r.get('probe_failed')]
    failed = [r for r in failed if not r.get('probe_failed')]
    if probe_failed:
        lines.append(f'⚠️ 测活探测异常 · {len(probe_failed)}')
        lines.append(f'<code>  └─ </code>探测接口本轮不可用（{tg_entry((probe_failed[0].get("error") or "").split("：")[-1][:60])}），'
                     '这些节点未真正探测，不计入失败')
        lines.append('')
    if failed:
        lines.append(f'❌ 失败 · {len(failed)}')
        _failed_entries = []
        # 折叠上限取全库默认 8（规范 · 折叠规则；此前本域用 5，与 tree_fold 默认值不一致）
        for r in failed[:8]:
            # 并列双机器值（节点名 · 原始异常串）走 tg_entry_codes（规范 · 条目与树形）
            _failed_entries.append(
                tg_entry_codes(r.get('name', ''), (r.get('error') or '-')[:80]))
        if len(failed) > 8:
            # 折叠行并入条目流，末条 └─ 由下面的循环统一决定（禁双 └─；规范 · 折叠规则）
            _failed_entries.append(f'还有 {len(failed) - 8} 条…')
        for _i, _l in enumerate(_failed_entries, 1):
            _c = '└─' if _i == len(_failed_entries) else '├─'
            lines.append(f'<code>  {_c} </code>{_l}')
        lines.append('')

    lines.append('📦 订阅 · Gist')
    if gist_res and gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        raw_url = ((gist_res.get('yaml') or {}).get('raw_url') or '').strip()
        # 措辞与 cdn / gitee 统一为「达标 N 个节点 · ≥X兆」（此前本处多「阈值」二字、少「节点」二字）
        gist_lines = [f'✅ 已{action}，达标 {qualified_count} 个节点 · ≥{min_megabit}兆（按{esc(metric_label)}）']
        if gist_res.get('created'):
            gist_lines.append(f'⚠️ 请把 Gist id 回填到 Secrets {tg_entry("PROXY_SPEEDTEST_TAIER_GIST_ID")}，避免每轮新建')
        if raw_url:
            gist_lines.append(f'🔗 <a href="{esc(raw_url)}">订阅源 YAML</a>')
        for _i, _l in enumerate(gist_lines):
            _c = '└─' if _i == len(gist_lines) - 1 else '├─'
            lines.append(f'<code>  {_c} </code>{_l}')
    elif gist_res:
        lines.append(f"<code>  └─ </code>⚠️ 上传失败：{tg_entry(gist_res.get('reason', ''))}")
    elif gist_error:
        # 上传阶段抛异常（HTTP 4xx 等）≠ 没有达标节点，文案必须区分
        lines.append(f'<code>  └─ </code>⚠️ 上传失败：{tg_entry(gist_error[:120])}')
    else:
        # ⚠️ 「没上传」有三种完全不同的原因，混成一句会误导（2026-09-16 run 35116972319：
        # 206 个节点实测有速度、最高 245 Mbps，却报「达标不足 1 个」，读者只会去怀疑节点）。
        # 按真因分文案，并交代「测了多少 / 共多少」——否则预算内只测了 919/8326 会被
        # 读成「8326 个都不达标」。
        _tested_n = len([r for r in results if not r.get('probe_failed')])
        _scope = ''
        if aborted_due_to_runtime and collected_total > len(results):
            _scope = f'（预算内仅测完 {_tested_n}/{collected_total} 个）'
        # 判据是「有没有可导出配置」，不是「有没有速度」：节点慢（0.5 兆）但有配置 ⇒
        # 那是真的达标不足；节点快（245 兆）却两者皆空 ⇒ 才是实现层丢配置。
        _no_config = [r for r in results
                      if not ((r.get('source_entry') or {}).get('proxy') or r.get('proxy_obj'))]
        _measured = [r for r in results
                     if (r.get('up') or 0) > 0 or (r.get('down') or 0) > 0]
        if qualified_count <= 0 and _measured and _no_config and len(_no_config) >= len(_measured):
            lines.append(f'<code>  └─ </code>⚠️ 未更新订阅：本有节点测出速度，但缺少可导出配置'
                         f'（达标判定按{esc(metric_label)} ≥{min_megabit}兆）')
        else:
            lines.append(f'<code>  └─ </code>⚠️ 达标不足 {min_nodes} 个 · 阈值 ≥{min_megabit}兆'
                         f'（按{esc(metric_label)}）· 未更新订阅{esc(_scope)}')
    # 统一收尾区（收尾区与正文间固定**一个**空行）：此前连写两个 append('') 变双空行
    lines.append('')
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    return lines


def notify_best_effort(stage: str, msg: str):
    """兜底分支（异常退出/信号终止/未捕获异常）的统一发送。

    python 发送层不写 stderr、只靠返回值报错，调用方必须把失败原因记进日志，
    否则 400 解析失败/429 限流会表现为「通知静默消失」（规范 · 发送层）。
    此前这些分支直接 `send_telegram(...)` 后 `except: pass`，返回值被丢弃。

    签名与 cdn / gitee 两套保持一致：`(stage, msg)`，env 内部取 merged_env()。
    此前本文件多一个前置 env 参数，调用点随之出现 `notify_best_effort(env, ...)`
    与 `notify_best_effort(merged_env(), ...)` 两种写法（2026-09-12 收敛）。
    """
    try:
        res = send_telegram(merged_env(), msg)
        log_progress(stage, sent=bool(res.get('sent')), reason=res.get('reason', ''))
    except Exception as e:
        log_progress(f'{stage}_failed', error=str(e))


def notify_failure(reason):
    # 先撤 TUN 再发——auto-route 劫持下连 TG API 都可能送不出去。
    # stop_mihomo_tun 可重复调用，main() finally 的二次收尾安全幂等。
    try:
        stop_mihomo_tun()
    except Exception:
        pass
    # 标题直接带原因（reason 形如「环境准备失败：…」，取全角冒号前的阶段名）
    _head = str(reason).split('：')[0].splitlines()[0][:40].strip() or '未知原因'
    lines = [
        f'❌ 泰尔三网测速异常退出 · {html.escape(_head)}',
        TG_SEP,
        # reason 含原始异常串（机器值）→ <code>；与 cdn/gitee 的「原因/错误」同口径
        # （规范 · 取值行口径）
        f'原因：{tg_entry(reason)}',
        '',
    ]
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    notify_best_effort('abort_notify', '\n'.join(lines))


_TERM_NOTICE_SENT = False


def handle_termination_signal(signum, frame):
    """SIGTERM/SIGINT 兜底：run 被取消/超时也发通知（与 speedtest_gitee 同款）。

    必须先撤 TUN 再发——auto-route 劫持下连 TG API 都可能送不出去。
    """
    global _TERM_NOTICE_SENT
    if _TERM_NOTICE_SENT:
        raise SystemExit(128 + int(signum))
    _TERM_NOTICE_SENT = True
    try:
        stop_mihomo_tun()
    except Exception:
        pass
    sig_name = signal.Signals(signum).name if signum else f'SIGNAL-{signum}'
    msg = (f'⛔ 泰尔三网测速异常终止\n{TG_SEP}\n'
           f'⚠️ 脚本被中断：收到 {tg_entry(sig_name)}，本轮测速未正常完成。')
    footer = tg_footer_line()
    if footer:
        msg += f'\n\n{footer}'
    notify_best_effort('termination_notify', msg)
    raise SystemExit(128 + int(signum))


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def _run():
    started_at = datetime.now()
    # 预算从**进程启动**起算（不是从节点循环起算）：job 的 timeout-minutes 也把前置准备
    # （mihomo 下载 / TUN / 节点快照）算在内，从启动起算才能保证「到点」一定早于硬取消。
    _budget_seconds = CONFIG['TAIER_BUDGET_SECONDS']
    _budget_deadline = speedtest_budget_deadline(_budget_seconds)
    log_progress('taier_speedtest_started', started_at=started_at.isoformat(), config={
        'points': CONFIG['TAIER_POINTS'],
        'mode': CONFIG['TAIER_MODE'],
        'duration': CONFIG['TAIER_DURATION'],
        'max_nodes': CONFIG['TAIER_MAX_NODES'],
        'budget_seconds': _budget_seconds,
    })
    env = merged_env()

    try:
        ensure_local_taier()
        start_mihomo_tun(env)
    except Exception as e:
        log_progress('bootstrap_failed', error=str(e))
        notify_failure(f'环境准备失败：{e}')
        return 1

    direct_ip = direct_egress_ip()
    log_progress('direct_egress_resolved', ip=direct_ip)

    # 订阅源映射：解析每个节点的原始配置（share_link / proxy YAML），供订阅导出使用
    try:
        source_mapping = build_source_mapping(env)
        log_progress('source_mapping_built',
                     entries=len(source_mapping.get('exact_proxy') or {}) +
                             len(source_mapping.get('exact_raw') or {}))
    except Exception as e:
        log_progress('source_mapping_failed', error=str(e))
        source_mapping = {}

    try:
        provider_snapshot, alive_items = collect_provider_snapshot(source_mapping)
    except Exception as e:
        log_progress('snapshot_failed', error=str(e))
        notify_failure(f'节点快照失败：{e}')
        return 1
    # mihomo **实际加载**的节点数（provider 里的原始条目数）。展开要多久看的是这个数，
    # 不是下面过滤后剩多少——按候选数算等待上限会严重低估（2026-09-23 实测：加载 20004、
    # 过滤后 1539，按 1539 只给 152 秒，等不完）。
    _loaded_total = sum(int(v.get('total') or 0) for v in (provider_snapshot or {}).values())

    # 优先级排序必须在 **max_nodes 截断之前**：否则截断先按 provider 原序砍掉了尾巴，
    # 命中优先级的节点可能根本不在「前 N 个」里，排序就白做了。
    alive_items, priority_hits = prioritize_nodes(alive_items, CONFIG['TAIER_PRIORITY_REGEX'])
    log_progress('nodes_prioritized', total=len(alive_items), hits=priority_hits,
                 pattern=CONFIG['TAIER_PRIORITY_REGEX'])

    # include 过滤同样必须在 max_nodes 截断之前：截断要按过滤后的最终池子算「前 N 个」，
    # 先截会把已被过滤的节点算进配额。过滤保相对序，prioritize 的「命中者前置」不受影响。
    if CONFIG['TAIER_INCLUDE_REGEX']:
        alive_items, _include_dropped = filter_nodes_include(
            alive_items, CONFIG['TAIER_INCLUDE_REGEX'])

    max_nodes = CONFIG['TAIER_MAX_NODES']
    if max_nodes and max_nodes > 0:
        alive_items = alive_items[:max_nodes]
    log_progress('nodes_collected', count=len(alive_items))

    # ⚠️ 开测之前先等 provider 真正展开（治 `Resource not found` 误报的根因）。
    # 读 `/providers/proxies` 拿到的是**声明清单**，不等于节点已进 `/proxies/{name}`
    # 路由表；不等就探会在头几个节点上拿到本地 404（实测间隔仅 ~18.7 毫秒，根本不是
    # 3000ms 超时），进而误判为死、触发熔断。见 wait_provider_ready 的说明。
    # 超时**不写死**、且按 **mihomo 实际加载量** 算（不是过滤后的候选数）：写死 60 秒在
    # 2123 个节点上等不完（实测 60 秒 / 138 次探测全 404）；按候选数算同样不够——
    # 2026-09-23 加载 20004、过滤后 1539，按 1539 只给 152 秒仍等不完（322 次全 404）。
    # 等不完 ⇒ 测活一开就熔断 ⇒ 死节点全跑满 16.5 秒的测速窗口（本轮 1309 个 ≈ 6h）。
    _prov_ready, _prov_waited, _ = wait_provider_ready(
        [i.get('name') for i in alive_items], total_loaded=_loaded_total,
        provider_names=list((provider_snapshot or {}).keys()))

    results = []
    bypass_hits = 0
    # 「到点收摊」与「运行中中止」共用这一对标志：通知降 ⚠️ + 正文补一行，但**都不算失败**
    # （退出码仍 0），拿已测节点照常出订阅（规范 · 2.7 测速三套）
    aborted_due_to_runtime = False
    runtime_abort_reason = ''
    # 测活的熔断：开头连续这么多个都没通过、且一个成功的都没有 ⇒ 更可能是**探测目标本身
    # 不可达**（控制面挂了 / URL 配错），而不是这些节点恰好都死了。继续判死会让整轮零产出。
    _probe_guard_n = 8
    # ⚠️ 展开等待**超时**（等满上限仍全 404）⇒ 节点名在 `/proxies` 里查不到，继续测活
    # 只会让每个节点各吃一次 `Resource not found`（2026-09-23 实测 4743 次，纯空转）。
    # 此处直接关掉测活、全量放行去测速——与熔断同一口径，但早得多、且不误伤判死判据。
    # 注意只关「等不到」这一种；展开成功（`_prov_ready`）时测活照常开。
    _probe_enabled = CONFIG['TAIER_ALIVE_PROBE'] and _prov_ready
    if CONFIG['TAIER_ALIVE_PROBE'] and not _prov_ready:
        log_progress('taier_probe_disabled', waited=round(_prov_waited, 3),
                     total=len(alive_items),
                     reason='provider 展开等待超时，节点名不可探，全量放行去测速')
    _probe_alive = 0
    _probe_dead = 0
    _probe_dead_streak = 0
    # 「mihomo 不认识这个节点名」的连续计数：与 `_probe_dead_streak` 分开，
    # 因为二者语义完全不同——前者是 provider 加载状态，后者才是节点真的连不上。
    _unknown_streak = 0
    # 「不认识节点名」时把节点放回队尾重排的**累计上限**：防止 provider 始终展不开时
    # 无限重排（那样队列永远消费不完）。取「候选数 × 2」——给展开留两轮完整的机会；
    # 到顶后退回旧行为（放行去测速，由测速那步自然失败），不再无休止重排。
    _unknown_requeued = 0
    _unknown_requeue_cap = max(1, len(alive_items)) * 2
    # 探测失败**待定**的节点：熔断时它们是「机制故障的受害者」，不是「节点死了」——
    # 必须撤销判死、放回测速队列，否则通知里会出现 N 条伪造的「测活未通过」。
    # 见 2026-09-16 run 35116972319：8 条 Resource not found 塞在 0.13 秒内，
    # 是 mihomo 控制面调用失败，节点本身没被真正探测过。
    _probe_retry_queue = []
    for item in alive_items:
        # 判据放在**开下一个节点之前**：单节点 ≈ 25 秒，所以超发最多一个节点
        if should_stop_for_budget(_budget_deadline):
            aborted_due_to_runtime = True
            runtime_abort_reason = (f'到点收摊：预算 {tg_format_elapsed(_budget_seconds)}，'
                                    f'已测 {len(results)}/{len(alive_items)} 个节点')
            log_progress('taier_budget_stop', tested=len(results), total=len(alive_items),
                         budget_seconds=_budget_seconds)
            break
        name = str(item.get('name') or '')
        # 先测活，再测速：死节点不再占用一整个测速窗口（≈25 秒/个）
        # ⚠️ 探测用 `name`（节点名），不是 AUTO 组名——组名会让 mihomo 回 `Resource not found`，
        # 判死全部节点（2026-09-15 实测）。切节点与探测必须同一个标识，见 probe_node_alive。
        if _probe_enabled:
            _alive, _delay, _perr = probe_node_alive(
                name, CONFIG['TAIER_ALIVE_PROBE_URL'], CONFIG['TAIER_ALIVE_PROBE_TIMEOUT_MS'])
            if _alive:
                _probe_alive += 1
                _probe_dead_streak = 0
                # 探测恢复正常 ⇒ 之前待定的节点是同一次机制故障的误伤，放回队列重测
                if _probe_retry_queue:
                    log_progress('taier_probe_retry_restored', count=len(_probe_retry_queue))
                    alive_items = alive_items + _probe_retry_queue
                    _probe_retry_queue = []
            else:
                # ⚠️ 「mihomo 不认识这个节点名」≠「节点连不上」（见 is_unknown_proxy_error）：
                # 前者是 provider 加载状态，拿它判死会污染熔断判据、并制造假失败条目。
                # 这类直接**放行去测速**（fail-open 同义）：真连不上时测速那一步自然会失败，
                # 代价只是一个 25 秒窗口，比误杀一批好节点划算得多。
                if is_unknown_proxy_error(_perr):
                    _unknown_streak += 1
                    log_progress('taier_node_probe_unknown', name=name, error=_perr,
                                 consecutive=_unknown_streak)
                    # ⚠️ 「连着多个都不认识」**不再关掉整个测活层**，而是把节点放回队尾
                    # 重新排队。为什么必须改：mihomo 加载上万个节点时展开极慢，此刻「不认识」
                    # 是**加载状态**而非节点属性；旧逻辑一熔断就永久关掉测活 ⇒ 上千个死节点
                    # 再没人拦、全跑满 ~16 秒的测速窗口（2026-09-23 实测 1309 个 ≈ 6 小时，
                    # 单这一项吃掉整个 5 小时预算）。改成重排队后，展开一旦完成，这些节点会
                    # 被测活以 ~0.1 秒/个 拦下。
                    #
                    # 用「放回队尾」而不是原地重试：队列是逐个消费的，放回队尾等于让本轮
                    # 其余节点先走，天然形成「等一会儿再试」，不需要额外的 sleep。
                    # 上限 `_unknown_requeue_cap` 防止展开始终不完成时无限循环（到顶后
                    # 才退回旧的「放行去测速」，由测速那一步自然失败——fail-open 同义）。
                    if _unknown_requeued < _unknown_requeue_cap:
                        _unknown_requeued += 1
                        alive_items.append(item)
                        continue
                    # 到顶：确实展不开。**必须放行去测速**（fail-open 同义），不判死、
                    # 不计入判死判据。⚠️ 2026-09-23 教训：这里曾写成 `continue` 直接丢弃，
                    # 于是 1581 个候选全部跳过测速 ⇒ `node_count=0` 整轮零产出。重排是
                    # 「晚点再试」，试不出来就要按老办法照测，绝不能变成「不测」。
                    log_progress('taier_probe_unknown_requeue_capped',
                                 requeued=_unknown_requeued, cap=_unknown_requeue_cap)
                    # 落到下面共用测速路径（此处**不得**跳过，否则节点被丢弃）
                _unknown_streak = 0
                _probe_dead_streak += 1
                _probe_dead += 1
                log_progress('taier_node_probe_failed', name=name, error=_perr,
                             url=CONFIG['TAIER_ALIVE_PROBE_URL'])
                if _probe_dead_streak >= _probe_guard_n and _probe_alive == 0:
                    _probe_enabled = False
                    log_progress('taier_probe_disabled', consecutive_dead=_probe_dead_streak,
                                 url=CONFIG['TAIER_ALIVE_PROBE_URL'],
                                 revived=len(_probe_retry_queue),
                                 reason='开头连续多个均未通过且无一成功，怀疑探测目标不可达')
                    _probe_dead -= _revive_probe_failed(results, alive_items, _probe_retry_queue)
                    _probe_retry_queue = []
                else:
                    # 未熔断 ⇒ 真判死；但先挂进待定队列，熔断时可整体撤销
                    _probe_retry_queue.append(item)
                    results.append({
                        'name': name,
                        'type': item.get('type', ''),
                        'source_entry': item.get('source_entry', {}) or {},
                        'proxy_obj': item.get('proxy_obj', {}) or {},
                        'mode': 'download',
                        'ok': False,
                        'probe_failed': True,
                        'error': f'测活未通过：{_perr}',
                    })
                    continue
        try:
            switch_proxy(name, CONFIG['TAIER_SWITCH_SETTLE'])
        except Exception as e:
            log_progress('switch_failed', name=name, error=str(e))
            results.append({'name': name, 'ok': False, 'error': f'切换失败：{e}'})
            continue

        rc, out, err = run_taier(CONFIG['TAIER_POINTS'], CONFIG['TAIER_MODE'],
                                 CONFIG['TAIER_DURATION'], CONFIG['TAIER_TIMEOUT'],
                                 CONFIG['TAIER_IMAGE'])
        parsed = parse_taier_output(out)
        # 有 region 但上下行全 0（表格里全是 "-"）= 节点连不上测速点，不能算成功
        has_speed = parsed['up'] > 0 or parsed['down'] > 0
        row = {
            'name': name,
            'type': item.get('type', ''),
            'source_entry': item.get('source_entry', {}) or {},
            # 从 provider 快照带出的完整配置：source_entry 匹配不上时的唯一可用来源，
            # 订阅导出与达标判定都要它（见 gist_results 处的说明）
            'proxy_obj': item.get('proxy_obj', {}) or {},
            'mode': 'download',
            'ok': rc == 0 and bool(parsed['region']) and has_speed,
            'exit_ip': parsed['exit_ip'],
            'exit_loc': parsed['exit_loc'],
            'region': parsed['region'],
            'rtt': parsed['rtt'],
            'up': round(parsed['up'], 2),
            'down': round(parsed['down'], 2),
            'image': parsed['image'],
            'rc': rc,
        }
        # 出口 IP 与 runner 直连出口相同 ⇒ 流量没进节点（TUN 未生效 / 进程规则未命中）
        row['bypass'] = bool(direct_ip and parsed['exit_ip'] and parsed['exit_ip'] == direct_ip)
        if row['bypass']:
            bypass_hits += 1
        if not row['ok']:
            if parsed['region'] and not has_speed:
                row['error'] = f"连不上测速点 {parsed['region']}（延迟/上下行全空）"
            else:
                tail = (err or out or '').strip().splitlines()
                row['error'] = (tail[-1][:200] if tail else f'rc={rc}（无输出）')
        results.append(row)
        log_progress('taier_node_done', name=name, rc=rc, region=row['region'],
                     rtt=row['rtt'], up=row['up'], down=row['down'],
                     exit_ip=row['exit_ip'], bypass=row['bypass'])
        try:
            with TAIER_LOG.open('a', encoding='utf-8') as lf:
                lf.write(f'===== {name} (rc={rc}) =====\n{ANSI_RE.sub("", out)}\n')
        except Exception:
            pass
        # 诊断：表格与 stderr 尾部进 step 日志（不含出口 IP —— 公开仓库日志勿泄漏节点出口）
        if parsed['table'] or rc != 0:
            print(f'--- taier[{name}] rc={rc} ---')
            if parsed['table']:
                print(parsed['table'])
            err_tail = (err or '').strip().splitlines()[-3:]
            if err_tail:
                print('stderr: ' + ' | '.join(err_tail))

    # 先关 TUN 再发通知：通知走的是 runner 自身网络，必须在路由恢复之后
    stop_mihomo_tun()

    # 订阅导出到本工作流专属 Gist（secret: PROXY_SPEEDTEST_TAIER_GIST_ID）——
    # 三个测速工作流各用各的 Gist，互不覆盖。taier 数值是 Mbps，导出字段是 MiB/s（÷8.388608），
    # 阈值/前缀沿用 speedtest_gitee 的 ×8 折算，展示值与 Mbps 基本一致。
    # 达标策略（阈值 / 判定指标 / 最少节点数）与四套共用，见 resolve_subscription_policy：
    # 默认按上行判定；上行达标数 < 回退门槛（默认 3）且下行更多时自动改用下行。
    gist_res = None
    gist_error = ''
    gist_results = [{
        'name': r.get('name', ''),
        'source_entry': r.get('source_entry') or {},
        # proxy_obj 必须带上：编排轮（gistnodes 交 8326 个节点）里 source_entry 匹配不上
        # 订阅 source_mapping（只有 4 条），配置全在 proxy_obj 里。丢了它 ⇒ 有速度的节点
        # 也被判「无可用配置」⇒ 达标 0 ⇒ 订阅不上传（2026-09-16 run 35116972319）。
        # 见 speedtest_common.node_proxy_config 的说明。
        'proxy_obj': r.get('proxy_obj') or {},
        'mode': 'download',
        'download_mibs': (r.get('down') or 0) / 8.388608,
        'upload_mibs': (r.get('up') or 0) / 8.388608,
        'latency_ms': _rtt_to_ms(r.get('rtt')),
    } for r in results]
    bundle = build_subscription_bundle(gist_results, resolve_subscription_policy(env))
    log_progress('subscription_policy', metric=bundle['metric'], qualified=bundle['qualified'],
                 min_megabit=bundle['min_megabit'], min_nodes=bundle['min_nodes'],
                 fallback=bundle['fallback'])
    if (bundle['text'] or '').strip():
        try:
            gist_res = update_gist(env, bundle['text'])
            log_progress('gist_uploaded', ok=gist_res.get('ok'),
                         action='新建' if gist_res.get('created') else '更新',
                         qualified=bundle['qualified'], metric=bundle['metric'])
        except Exception as e:
            # 上传抛异常时 gist_res 仍是 None，必须单独记住原因，否则通知会误报
            # 「达标不足」（达标与否是 text 是否为空，与上传是否成功无关）
            gist_error = str(e)
            log_progress('gist_upload_failed', error=gist_error)
    else:
        log_progress('gist_skipped', reason='qualified nodes < min_nodes',
                     qualified=bundle['qualified'], min_nodes=bundle['min_nodes'],
                     metric=bundle['metric'])

    ended_at = datetime.now()
    duration_text = tg_format_elapsed((ended_at - started_at).total_seconds())
    meta = {
        'started_text': started_at.isoformat()[:19].replace('T', ' '),
        'ended_text': ended_at.isoformat()[:19].replace('T', ' '),
        'duration_text': duration_text,
        'points': CONFIG['TAIER_POINTS'],
        'mode_label': MODE_LABELS.get(CONFIG['TAIER_MODE'], CONFIG['TAIER_MODE']),
    }
    summary = {
        'ok': bypass_hits == 0,
        'started_at': started_at.isoformat(),
        'ended_at': ended_at.isoformat(),
        'direct_egress_ip': direct_ip,
        'bypass_hits': bypass_hits,
        'node_count': len(results),
        'aborted_due_to_runtime': aborted_due_to_runtime,
        'runtime_abort_reason': runtime_abort_reason,
        'results': results,
    }
    try:
        RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception as e:
        log_progress('report_write_failed', error=str(e))

    try:
        # 长消息分片发送（失败列表 + Gist 段容易超 4000 字符，单发会被整条拒收）
        tg_res = send_telegram_chunked(env, '\n'.join(build_telegram_lines(
            results, meta, direct_ip, bypass_hits, gist_res, bundle, gist_error,
            aborted_due_to_runtime=aborted_due_to_runtime,
            runtime_abort_reason=runtime_abort_reason,
            collected_total=len(alive_items))))
        # 发送层不写 stderr（python 侧靠返回值），失败原因必须回传日志（规范 · 发送层）
        log_progress('telegram_send_finished', sent=bool(tg_res.get('sent')),
                     reason=tg_res.get('reason', ''))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    # ⚠️ probe_dead 必须是**真正探测过**的计数，不能用 `len(results) - probe_alive`——
    # 那会把「熔断后压根没探测」的节点也算成「探测判死」（run 34859505000 里 27 个节点
    # 只探测了 8 个，日志却报 probe_dead=27，误导事后分析）。探测关闭时两者都该是 0。
    log_progress('taier_speedtest_done', node_count=len(results), bypass_hits=bypass_hits,
                 aborted_due_to_runtime=aborted_due_to_runtime,
                 probe_alive=_probe_alive, probe_dead=_probe_dead,
                 json_path=str(RESULT_JSON))
    # 全部节点都命中 bypass ⇒ 结果不可信，判失败便于在 Actions 上看见
    return 1 if (bypass_hits and bypass_hits >= max(1, len(results))) else 0


def main():
    # TUN 必须收尾：异常/提前 return 也要撤掉路由，否则 runner 无法回传状态
    signal.signal(signal.SIGTERM, handle_termination_signal)
    signal.signal(signal.SIGINT, handle_termination_signal)
    try:
        return _run()
    except Exception as e:
        # 未捕获异常兜底：标题带阶段摘要，正文留完整异常（含类型名，与 cdn 同口径）。
        # 这里不再包 `try: … except Exception: pass`——notify_failure 内部已走
        # notify_best_effort，发送结果会记进 log_progress；外层再吞一次等于
        # 429 限流 / 400 解析失败时完全没有痕迹（规范 · 发送层点名的反模式，
        # 2026-09-12 收敛：cdn 与 gitee 早已是这个形态）。
        notify_failure(f'未捕获异常：{type(e).__name__}: {e}')
        return 1
    finally:
        try:
            stop_mihomo_tun()
        except Exception:
            pass


if __name__ == '__main__':
    raise SystemExit(main())
