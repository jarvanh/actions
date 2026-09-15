#!/usr/bin/env python3
"""用本地 mihomo 对一批节点做健康检查，只回传「活」的那些（供 gistnodes 发布前过滤）。

背景（为什么需要这一层）：`proxy-speedtest-gistnodes` 把 Sub-Store 去重后的订阅发布到 Gist，
下游三套测速再把它当 `sub_urls` 吃进去。实测 2026-09-15 run 34928929882：Gist 里确实有
12635 个节点（raw URL 匿名可读、`yaml.safe_load` 也是 12635 个），但泰尔那轮只拿到
`source_mapping_built entries: 14`；时间线上 `mihomo_tun_config_built` 距开跑只有 1.67 秒
——**physically 不可能**在那点时间里下完 4.27MB、载入 12635 个节点并做完一轮非惰性健康检查。
也就是说瓶颈不在下载、不在鉴权、不在 TUN，而在**规模**：`lazy: false` 的 provider 健康检查
压根没跑完，下游读快照时只看到最先出结论的一小撮。

所以这一层负责把规模在上游压下去：发布前先自己起一个 mihomo（独立端口，绝不碰 19090 ——
分片 runner 上可能同时有别的测速 job 在用），把节点当**若干分片 provider** 载入，等它们
都得出过结论（`alive` 非空）再过滤，只把活节点交回去发布。这样下游 Gist 里就是几百个活
节点，它们自己的健康检查能在秒级完成。

**为什么必须分片、不能只建一个 provider**（实测 2026-09-15 run 34949717315 的真实数据）：
野路节点里总有畸形的（那份 13620 节点里 proxy 11 就报 `invalid REALITY short ID`），而
mihomo 对 provider 是「全有或全无」——一个节点解析失败，整个 provider 的 `proxies` 直接
是 `[]`。单 provider 等于「一个坏节点废掉整层过滤」。分片后坏节点只污染它所在那一小片。

**为什么工作目录必须落在当前用户的 home 内**：mihomo 拒绝加载 home 之外的 provider 文件
（`path is not subpath of home directory or SAFE_PATHS` 是 `level=fatal`，进程直接退出、
控制器根本不监听）。同一次 run 就是因为本层把 provider 写进了 `GIST_NODES_WORKDIR`（仓库
工作区，在 home 外）⇒ mihomo 秒退 ⇒ `wait_mihomo` 空等 60 秒 ⇒ 报成
`mihomo_start_failed: Connection refused`，把「配置被拒」误读成「端口不通」。
`_safe_home_dir` 负责把路径钉回 home，`_dump_mihomo_log` 负责在失败时把真因吐出来。

为什么复用 `speedtest_gitee.py` 而不是重写：mihomo 的下载/解压/启动/等待就绪已经是那套里
验过的代码，健康检查语义（`expected-status: 204`、`lazy: false`）也必须与下游**逐字一致**
——两处各写一份，迟早会漂。本模块只加「等检查跑完 + 读结论 + 按结论过滤」这三件事。

为什么 `lazy: false` 必须是这个值：`lazy: true` 的 provider 只在被显式请求时才探活，
`/providers/proxies` 里所有节点的 `alive` 会一直缺失，这一层就永远等不到结论、只能
fail-open 放行全部——等于白跑。注意这与下游各测速工作流的配置**无关**：这是本模块自己
临时生成的那份 config。

fail-open 的边界（与 `taier_speedtest.probe_node_alive` 同一原则）：只有「检查确实跑完了、
并有明确死结论」才丢节点。mihomo 起不来、超时到点仍有节点没出结论、API 报错——一律原样
放行全部并打 `alive_filter_skipped`，宁可让下游去扛大规模，也不能因为本层故障把整轮变成
零节点发布。

---

本模块还负责第二件事：**发布前的试装排雷**（`trial_load`）。过滤只解决「节点活不活」，
不解决「节点能不能被 mihomo 装上」——而后者会**整片废掉订阅**：mihomo 对 provider 是
「全有或全无」，片里有一个解析不了的节点，整个 provider 的 `proxies` 就是 `[]`。分片只能
把损失压到 1/片数，不能消除；只要坏节点够多，下游照样可能拿到远小于发布的节点数。

所以发布前先自己把这份 YAML 完整喂给 mihomo 试装一遍：装得上就直接发；装不上就**二分**
定位到具体是哪几个节点（而不是整片丢掉），只摘掉它们。判据、代价与 fail-open 边界见
`trial_load` 的 docstring。
"""
import pathlib
import sys
import time
import urllib.request

import yaml

# 脚本可能经软链被调用：按物理路径定位同目录模块（与仓库内其他脚本同一约定）。
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from speedtest_common import (  # noqa: E402
    log_progress,
    should_stop_for_budget,
    speedtest_budget_deadline,
)
from speedtest_gitee import (  # noqa: E402
    DEFAULT_HEALTHCHECK_URL,
    MIHOMO,
    MIHOMO_API,
    MIHOMO_CONFIG,
    MIHOMO_LOG,
    MIHOMO_MIXED_PORT,
    ensure_local_mihomo,
    wait_mihomo,
)

DEFAULT_FILTER_BUDGET_SECONDS = 600
DEFAULT_FILTER_POLL_SECONDS = 2.0
# 结论稳定判据：连续这么多轮「已出结论的节点数」不再变化就认为检查停了。
# 为什么不用「全部出结论」当唯一出口：mihomo 对连不上的节点也会写出 `alive: false`
# （那是死结论，不是「没结论」），所以正常会全部有值；但个别节点可能卡在超时边缘，
# 这时靠稳定判据收尾，比死等都到齐更稳。
DEFAULT_FILTER_STABLE_ROUNDS = 3
# 单次 `/providers/proxies` 的请求超时。这个响应是「每个节点一条记录」，12635 个节点时
# 体积可观；给足余量，别把它误判成「mihomo 挂了」而 fail-open。
SNAPSHOT_TIMEOUT_SECONDS = 120
# 健康检查请求的冷启动宽限：mihomo 起来后第一轮探测要建连，太早读会看到「一个结论都没有」。
COLD_START_GRACE_SECONDS = 5.0

# 每个分片 provider 装多少节点。**必须分片**，不能把所有节点塞进一个 provider：
# 野路节点里总有畸形的（实测 run 34949717315 的真实数据：proxy 11 报
# `invalid REALITY short ID`），而 mihomo 对 provider 是「全有或全无」——一个节点解析
# 失败，整个 provider 的 proxies 就是 `[]`（沙箱已复现，容器里 13620 个节点全丢）。
# 分片后坏节点只污染它所在那一小片，其余照常探活。
#
# 取 200：片数够多（万级节点 ≈ 50 片）才能把单片污染的损失压到 1/50 以下，同时片内节点数
# 又足够让每片的健康检查并发有意义（片太小则进程内 provider 数量激增、启动变慢）。
FILTER_SHARD_SIZE = 200
# 分片 provider 的名字前缀，`_snapshot` 用它把所有分片认回来。**必须与分片文件名
# （`shard-NNNN.yaml` ⇒ provider 名 `shard-NNNN`）严格一致**：写成别的值会让
# `_snapshot` 过滤掉全部 provider，表现为「loaded=0、所有节点都查不到结论」——
# 不报错、不 fail-open，只是静默变成一个纯摆设（实测踩过）。
SHARD_PREFIX = 'shard-'

# ---------------------------------------------------------------------------
# 试装（trial_load）：发布前排掉「mihomo 装不上」的节点
# ---------------------------------------------------------------------------
# 试装 provider 的固定文件名与 provider 名。**每轮全量重写、不需要清理**（同分片），
# 且**绝不能按通配符删这里**：调用方是先写文件、再起 mihomo，删掉输入会让 mihomo
# 报一片 `no such file or directory` 而让整层 fail-open。
TRIAL_FILE_NAME = 'trial.yaml'
TRIAL_PROVIDER_NAME = 'trial'

# 单个节点占一行 base64 的换算（明文 ≈ 3/4 行宽）。**不能按明文长度估**：mihomo
# 装 provider 时对 `proxies` 整段做 base64 解压再解析，超过 3MB 直接报
# `proxy 0 error: ... larger than 2.99MB, maybe base64 encoded` —— 那个形态与「真坏节点」
# 一模一样，会把整块误判成坏块、白跑一轮二分。每行按 120 估（实际行宽由节点名长度决定，
# 往往更短），则 2000 个 ≈ 180KB，距 3MB 有 16 倍余量，且留在 `TRIAL_MAX_NODES_PER_BATCH`。
B64_LINE_WIDTH = 120
# 一次试装最多塞多少个节点。超过就切块——切块**不引入误报**（上面那个上限是解码后的
# 字节数，不是节点数），代价只是多起几次 mihomo；而块内节点少还让二分更省。
TRIAL_MAX_NODES_PER_BATCH = 2000
# 二分细到「块内还剩几个就不再往下钻、整块摘掉」的门槛。取 8：块内 8 个全坏才丢 8 个，
# 而继续二分的代价是 num_rounds 次 mihomo 起停。另外，**单节点装不上时二分必须收敛**：
# 靠 `_trial_isolate` 里「坏了还要按二分丢一半」那条分支，最坏会走到这里兜底。
TRIAL_BISECT_FLOOR = 8
# 一个坏块最多试装多少次。**必须是有限的**：区间队列的做法下，一个块里节点全坏时
# 队列会一路切到 floor，试装次数约为 2·(块内节点数/floor)。全坏是极端情况（那样直接
# 摘光就好，本来也不指望精确定位），但上限仍要足够大才不至于把「全坏」误判成「归因失败」
# 而 fail-open。取 400：正常形态（1-2 个坏节点、块 2000 个）在 ~30 次内结束，
# 400 能容下「块内 2000 个里有几十个坏节点」，同时把病态形态挡在有限次内。
# 顶到上限即归为「归因失败」，由调用方 fail-open，绝不无限循环。
TRIAL_MAX_ISOLATE_ROUNDS = 400
# 每轮试装重起 mihomo 的等待上限。单轮就绪远快于 60（那是过滤层的保守值），
# 折中取 30：异常时少空等，正常时绰绰有余。
TRIAL_WAIT_TIMEOUT = 30
# mihomo 日志里「provider 初始化失败」的特征串。用于把「节点被 mihomo 判非法」
# 与「进程根本没起来 / 别的原因 fatal」分开——后者绝不能当成分辨出坏节点。
TRIAL_ERROR_MARKERS = ('initial proxy provider', 'error: proxy')

# 整个试装阶段的墙钟预算。**必须有**（实测 2026-09-15 run 34989917789 就是没它出的
# 事故）：单次试装的成本是「重起一次 mihomo + wait_mihomo 轮询」≈ 11 秒，与节点多少
# 关系不大（已实测：把健康检查关掉也还是 11 秒，所以这不是探测耗时，是进程冷启动）。
# 而一个坏块的二分要触及 O(m·log n) 个区间 —— 那轮 2000 个节点的块里有 24 个坏节点，
# 单块就要 ~500 次试装 ≈ 90 分钟。7 个块下去，job 撞上 timeout-minutes 被 GitHub
# **硬取消**：已抓到的 65 个订阅、已投喂的 Sub-Store、下游三个测速 job（全 skipped）
# 一起报废 —— 这正是本仓库「宁可降级也不被硬取消」那条原则要防的形态。
#
# 取 420 秒：够正常的轮次走完（全好时 7 块只需 7 次试装 ≈ 80 秒；即使有一两个块带了
# 几个坏节点也够）。到点的降级方向是「停止排雷」——**已摘的照摘、还没测的块原样放行**，
# 让下游去扛那部分坏节点，而不是让整轮变成零产出。
DEFAULT_TRIAL_BUDGET_SECONDS = 420


def _safe_home_dir(base):
    """把一个目录钉到 mihomo 的 home 之内。

    **mihomo 会拒绝加载 home 之外的 provider 文件**（`path is not subpath of home
    directory or SAFE_PATHS`，`level=fatal` 直接退出，连控制器都不监听）。实测 2026-09-15
    run 34949717315：本层把 provider 写进了 `GIST_NODES_WORKDIR`（= 仓库工作区），正好在
    home 外 ⇒ mihomo 起不来 ⇒ `wait_mihomo` 空等 60 秒 ⇒ 整层 fail-open。

    所以这里不信任调用方传进来的路径：只要它不在 home 内，就改落到 home 下的同名子目录，
    并打一条日志说明为什么换了地方（否则「文件明明写了、mihomo 说找不到」会成为无解之谜）。
    """
    home = MIHOMO_CONFIG.parent.resolve()
    base = pathlib.Path(base or (home / 'alive-filter'))
    try:
        base.resolve().relative_to(home)
        return base
    except ValueError:
        relocated = home / (base.name or 'alive-filter')
        log_progress('alive_filter_workdir_relocated', requested=str(base),
                     relocated=str(relocated), home=str(home),
                     note='mihomo 拒绝加载 home 之外的 provider 文件，已改到 home 内')
        return relocated


def _build_filter_config(env, shard_paths, health_url, workdir):
    """生成「多个分片 provider + 全节点健康检查」的 mihomo 配置。

    不复用 `build_mihomo_config`：那个按 `PROXY_SPEEDTEST_SUB_URLS` 逐个远端订阅建
    provider（要走网络、且 provider 数量不可控），而这里的数据**已经在本地**（Sub-Store
    刚产出的 YAML），只需要若干 `type: file` 的 provider 指过去。

    为什么是「若干」而不是一个：见 `FILTER_SHARD_SIZE` 上方注释——单 provider 遇到一个
    畸形节点就整体归零。
    """
    cfg = {
        'port': 17890,
        'socks-port': 17891,
        'mixed-port': MIHOMO_MIXED_PORT,
        'allow-lan': False,
        # global 模式省掉规则匹配，健康检查本来就与规则无关；与 speedtest_gitee 同值，
        # 免得「同一份节点在两处表现不同」这种无从排查的差异。
        'mode': 'global',
        'log-level': env.get('PROXY_SPEEDTEST_MIHOMO_LOG_LEVEL', 'info'),
        'external-controller': '127.0.0.1:19090',
        'secret': '',
        'proxy-groups': [
            {
                'name': 'AUTO',
                'type': 'select',
                'use': [p.stem for p in shard_paths],
                'proxies': ['DIRECT'],
            }
        ],
        'proxy-providers': {
            p.stem: {
                'type': 'file',
                'path': str(p),
                'health-check': {
                    'enable': True,
                    'url': health_url,
                    'interval': 86400,
                    'timeout': 5000,
                    # 必须 false：true 的话所有节点的 alive 会一直缺失，本层永远等不到结论
                    'lazy': False,
                    'expected-status': 204,
                },
            }
            for p in shard_paths
        },
        'rules': ['MATCH,AUTO'],
    }
    MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                             encoding='utf-8')
    return cfg


def _no_proxy_opener():
    """绕过代理的 opener：mihomo API 是本机回环，而 `urlopen` 会尊重 `HTTP_PROXY`。

    不少机器（含 macOS 开系统代理时）连 127.0.0.1 都被送进代理，拿到的是代理的错误页——
    那会被下面的分支当成「mihomo 不可用」，进而整层 fail-open 形同虚设。
    """
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _snapshot(opener, timeout):
    """读一次 `/providers/proxies`，返回 (provider 内节点列表, 每个 provider 的计数)。

    只看本层建的分片 provider（`SHARD_PREFIX` 打头）：mihomo 自带的 `default` /
    `AUTO` / `DIRECT` 这些兼容 provider 里也有节点（实测 `default` 里塞着几个内置条目），
    混进来会污染「多少节点出了结论」的计数。
    """
    with opener.open(MIHOMO_API + '/providers/proxies', timeout=timeout) as r:
        data = r.read().decode('utf-8', 'ignore')
    parsed = yaml.safe_load(data) or {}
    proxies = []
    counts = {}
    for name, info in (parsed.get('providers') or {}).items():
        if not str(name).startswith(SHARD_PREFIX):
            continue
        items = (info or {}).get('proxies') or []
        proxies.extend(items)
        counts[name] = len(items)
    return proxies, counts


def _dump_mihomo_log(tail=1500):
    """把 mihomo 日志尾部吐进 progress 流。

    为什么必须打：mihomo 起不来的**唯一线索就在这里**（SAFE_PATHS 越界、provider 解析
    失败都是 `level=fatal` 写进日志、进程随后静默退出）。实测 2026-09-15 run
    34949717315 就是因为只记了 `wait_mihomo` 的 `Connection refused`，把「配置被拒」
    误读成「端口不通」，白绕一大圈。
    """
    try:
        if not MIHOMO_LOG.exists():
            log_progress('alive_filter_mihomo_log', note='mihomo 日志不存在')
            return
        text = MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
        log_progress('alive_filter_mihomo_log', tail=text[-tail:])
    except Exception as e:
        log_progress('alive_filter_mihomo_log_read_failed', error=str(e))


def _start_mihomo(wait_timeout=60):
    """起一个全新的 mihomo（先收掉同命令行的旧进程，与 taier 的 TUN 版本同一手法）。

    `wait_timeout` 由调用方给：过滤层用 60（万级节点、几十个分片 provider，建 provider
    本身就要时间），试装层用 `TRIAL_WAIT_TIMEOUT`（单 provider、且要反复起停，异常时
    少空等比多等更值）。

    **不要在这里清理 `shard-*.yaml` / `trial.yaml`**：调用方是「先写输入、再起 mihomo」，
    任何按通配符的删除都会把刚写好的输入删掉，mihomo 随即报一片
    `no such file or directory` 而让整层 fail-open（实测 2026-09-15 加清理时就是这个症状）。
    这些文件本来每轮全量重写，不存在需要清理的残留。
    """
    import os
    import signal
    import subprocess

    ensure_local_mihomo()

    killed = []
    try:
        out = subprocess.run(['pgrep', '-af', f'{MIHOMO} -d'], text=True,
                             capture_output=True, timeout=10)
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
                os.kill(pid, signal.SIGTERM)
                killed.append(pid)
            except OSError as e:
                log_progress('alive_filter_terminate_skipped', pid=pid, error=str(e))
    except Exception as e:
        log_progress('alive_filter_process_scan_failed', error=str(e))

    # **必须等旧进程真的退出**：只发 SIGTERM 不等的话，下一次 Popen 会和它抢
    # 19090 控制器端口，新进程报 `External controller listen error: bind: address
    # already in use` 后**静默不监听**，`wait_mihomo` 只能等到超时——而试装层要反复
    # 起停几十次，这个竞态会稳定复现（沙箱实测 test_gist_nodes_substore 里就是这么
    # 空转了 30 秒 × N 次）。等待上限 10 秒，超时了也继续（进程可能已经退出但未被
    # reaped，真正的判据是端口能不能 bind，交给下面的 Popen 去发现）。
    if killed:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            still = []
            for pid in killed:
                try:
                    os.kill(pid, 0)
                    still.append(pid)
                except OSError:
                    continue
            if not still:
                break
            time.sleep(0.2)

    with MIHOMO_LOG.open('a', encoding='utf-8') as lf:
        subprocess.Popen([str(MIHOMO), '-d', str(MIHOMO_CONFIG.parent), '-f', str(MIHOMO_CONFIG)],
                         stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    return wait_mihomo(timeout=wait_timeout)


def filter_alive(env, proxies, budget_seconds=DEFAULT_FILTER_BUDGET_SECONDS,
                 workdir=None, health_url='', snapshot_timeout=SNAPSHOT_TIMEOUT_SECONDS):
    """把 `proxies` 过一遍本地 mihomo 健康检查，返回 (活节点列表, 报告 dict)。

    只要拿到**明确死结论**就丢；任何机制性故障（起不来、超时、API 报错）一律 fail-open
    原样返回全部，并在报告的 `skipped` / `skip_reason` 里写明——调用方据此决定日志与摘要
    措辞，不需要自己再判一遍。
    """
    total = len(proxies)
    health_url = (health_url or env.get('PROXY_SPEEDTEST_HEALTHCHECK_URL')
                  or DEFAULT_HEALTHCHECK_URL).strip() or DEFAULT_HEALTHCHECK_URL
    # 目录钉在 home 内：mihomo 会拒绝加载 home 外的 provider 文件（见 `_safe_home_dir`）。
    workdir = _safe_home_dir(workdir or (MIHOMO_CONFIG.parent / 'alive-filter'))
    workdir.mkdir(parents=True, exist_ok=True)

    report = {
        'enabled': True,
        'total': total,
        'alive': total,
        'dead': 0,
        'concluded': 0,
        'shards': 0,
        'shards_failed': 0,
        'elapsed_seconds': 0.0,
        'budget_seconds': budget_seconds,
        'healthcheck_url': health_url,
        'skipped': False,
        'skip_reason': '',
    }

    def give_up(reason, note):
        report.update({'alive': total, 'dead': 0, 'skipped': True, 'skip_reason': reason,
                       'elapsed_seconds': round(time.monotonic() - started, 1)})
        log_progress('alive_filter_skipped', reason=reason, note=note, total=total,
                     shards=report['shards'])
        _dump_mihomo_log()
        return list(proxies), report

    if total == 0:
        return [], report

    started = time.monotonic()

    shard_paths = []
    for idx in range(0, total, FILTER_SHARD_SIZE):
        shard_paths.append(workdir / f'shard-{idx // FILTER_SHARD_SIZE:04d}.yaml')
    report['shards'] = len(shard_paths)
    for path, start in zip(shard_paths, range(0, total, FILTER_SHARD_SIZE)):
        chunk = proxies[start:start + FILTER_SHARD_SIZE]
        path.write_text(yaml.safe_dump({'proxies': chunk}, allow_unicode=True, sort_keys=False),
                        encoding='utf-8')

    try:
        _build_filter_config(env, shard_paths, health_url, workdir)
    except Exception as e:
        return give_up('config_build_failed', f'生成过滤用 mihomo 配置失败：{e}')

    try:
        _start_mihomo()
    except Exception as e:
        return give_up('mihomo_start_failed', f'mihomo 起不来：{e}')

    deadline = speedtest_budget_deadline(budget_seconds)
    opener = _no_proxy_opener()
    last_count = -1
    stable_rounds = 0
    concluded = 0
    items = []
    try:
        while True:
            if should_stop_for_budget(deadline):
                return give_up('budget_exhausted',
                               f'预算 {budget_seconds} 秒内健康检查没跑完'
                               f'（已出结论 {concluded}/{total}）')
            try:
                items, counts = _snapshot(opener, snapshot_timeout)
            except Exception as e:
                return give_up('snapshot_failed', f'读 /providers/proxies 失败：{e}')
            concluded = sum(1 for p in items if p.get('alive') is not None)
            loaded = sum(counts.values())
            # 分片后 loaded 可能**小于** total：某个分片整个加载失败（坏节点），它那片的
            # 节点不会出现在快照里。这种片算「查不到结论」，下面按名字匹配不到就保留，
            # 不当作判死——与「只丢明确死结论」的原则一致。
            if concluded == loaded and concluded > 0:
                break
            if concluded == last_count:
                stable_rounds += 1
                # 冷启动宽限：mihomo 刚起来时第一轮可能一个结论都没出，
                # 别把「还没开始探」误判成「探完了且全是死」。
                # 宽限时长按片数放大：片多时 mihomo 建 provider 本身就要时间。
                grace = COLD_START_GRACE_SECONDS + 0.5 * len(shard_paths)
                if stable_rounds >= DEFAULT_FILTER_STABLE_ROUNDS \
                        and time.monotonic() - started >= grace:
                    break
            else:
                stable_rounds = 0
            last_count = concluded
            time.sleep(DEFAULT_FILTER_POLL_SECONDS)
    except Exception as e:
        return give_up('poll_failed', f'健康检查轮询异常：{e}')

    by_name = {}
    for p in items:
        name = str(p.get('name') or '')
        if name:
            by_name[name] = p

    alive_bodies = []
    dead_names = []
    unmatched = []
    for idx, proxy in enumerate(proxies):
        name = str((proxy or {}).get('name') or '')
        state = by_name.get(name)
        if state is None:
            # 名字对不上：可能重名被 mihomo 改名，也可能所在分片整片没加载进来。
            # 这类一律**保留**——过滤只该丢「明确判死」的，不该丢「查不到结论」的。
            unmatched.append(name or f'#{idx}')
            alive_bodies.append(proxy)
        elif state.get('alive') is None:
            unmatched.append(name)
            alive_bodies.append(proxy)
        elif state.get('alive'):
            alive_bodies.append(proxy)
        else:
            dead_names.append(name)

    report.update({
        'alive': len(alive_bodies),
        'dead': len(dead_names),
        'concluded': concluded,
        'unmatched': len(unmatched),
        'elapsed_seconds': round(time.monotonic() - started, 1),
    })
    log_progress('alive_filter_done', total=total, alive=report['alive'],
                 dead=report['dead'], concluded=concluded, unmatched=report['unmatched'],
                 shards=len(shard_paths), elapsed=report['elapsed_seconds'],
                 budget=budget_seconds, url=health_url)
    if report['unmatched']:
        # 大量 unmatched 通常意味着某些分片没加载进来（畸形节点），值得单独留意。
        log_progress('alive_filter_unmatched_note', unmatched=report['unmatched'],
                     loaded=sum(1 for _ in items),
                     note='查不到结论的节点一律保留（含整片加载失败的）')
    if dead_names:
        # 只打前若干条样例：死节点可能上千，全打会把日志冲垮。
        log_progress('alive_filter_dead_samples', count=len(dead_names),
                     samples=dead_names[:20])
    return alive_bodies, report


# ---------------------------------------------------------------------------
# 试装（trial_load）
# ---------------------------------------------------------------------------
def _trial_load_config(path):
    """生成「一个 file provider + 全量健康检查」的试装配置。

    与 `_build_filter_config` 的差别只有两点，都是有意的：

    1. provider 名/文件名固定（`trial`），不是按序号分片——这里要的是**一个** provider
       来当判据：装得上 = 这批节点全部合法。
    2. 健康检查开着是为了与下游**逐字一致**（下游也是 `lazy: false` + `expected-status:
       204`），但本层**从不读结论**：装不装得上在配置解析那一刻就已决定，`/version` 一
       就绪即可判定（见 `trial_load`）。开着也让「同一份节点在这里能装、在下游也能装」
       这个等价关系成立。
    """
    cfg = {
        'port': 17890,
        'socks-port': 17891,
        'mixed-port': MIHOMO_MIXED_PORT,
        'allow-lan': False,
        'mode': 'global',
        'log-level': 'info',
        'external-controller': '127.0.0.1:19090',
        'secret': '',
        'proxy-groups': [
            {
                'name': 'AUTO',
                'type': 'select',
                'use': [TRIAL_PROVIDER_NAME],
                'proxies': ['DIRECT'],
            }
        ],
        'proxy-providers': {
            TRIAL_PROVIDER_NAME: {
                'type': 'file',
                'path': str(path),
                'health-check': {
                    'enable': True,
                    'url': DEFAULT_HEALTHCHECK_URL,
                    'interval': 86400,
                    'timeout': 5000,
                    'lazy': False,
                    'expected-status': 204,
                },
            }
        },
        'rules': ['MATCH,AUTO'],
    }
    MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                             encoding='utf-8')
    return cfg


def _trial_install(proxies, workdir):
    """把 `proxies` 整批写成一个 file provider，起 mihomo 试装。

    返回 `(ok, err)`：`ok=True` = 装机成功；`ok=False, err=''` = 装机失败且**无法归因**
    （mihomo 没起来、日志里没有 provider 失败特征）——调用方必须把它当「自己故障」而
    不是「这批节点有问题」；`ok=False, err=真因` = mihomo 明确拒绝了这份 provider。

    **判定时机是「控制器就绪」而不是「健康检查跑完」**：provider 的解析发生在配置装载
    阶段，装不上时 mihomo 写 `level=error … error: proxy N error: …` 然后跳过该 provider
    继续起控制器。所以 `wait_mihomo` 一返回就能下结论——**不必**为每次试装再花一轮探活
    （那是 2000 个节点 × 每块一轮，会吃掉整个预算）。
    """
    path = workdir / TRIAL_FILE_NAME
    path.write_text(yaml.safe_dump({'proxies': list(proxies)}, allow_unicode=True,
                                   sort_keys=False), encoding='utf-8')
    _trial_load_config(path)
    try:
        MIHOMO_LOG.write_text('', encoding='utf-8')
    except Exception as e:
        log_progress('trial_load_log_truncate_failed', error=str(e))
    try:
        _start_mihomo(wait_timeout=TRIAL_WAIT_TIMEOUT)
    except Exception as e:
        # 起不来 ≠ 节点有问题：归因失败（err=''），由调用方决定整层 fail-open。
        log_progress('trial_load_start_failed', error=str(e))
        return False, ''
    try:
        text = MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
    except Exception as e:
        log_progress('trial_load_log_read_failed', error=str(e))
        return False, ''
    for line in text.splitlines():
        if any(marker in line for marker in TRIAL_ERROR_MARKERS):
            return False, line.strip()
    return True, ''


def _trial_isolate(chunk, workdir, bisect_floor=TRIAL_BISECT_FLOOR, deadline=None):
    """把一个**已知装不上**的块摘到「剩下的能装上」为止，返回 `(done, removed, rounds)`。

    返回 `done=False` = 归因失败（mihomo 起不来 / 报错对不上 provider），调用方据此把
    这块排除在外并继续跑其余块——绝不因此整层 fail-open。

    做法：维护一个**还没查清的区间队列**，每轮取一个区间试装。

      * 装得上 ⇒ 这个区间没有问题，丢掉它；
      * 装不上且区间内 ≤ `bisect_floor` 个 ⇒ 整块摘掉（兜底出口）；
      * 装不上且区间更大 ⇒ 对半切开，**两半都入队**（还不知道坏在哪半）。

    为什么「两半都入队」而不是只追一支：只追一支就必须在摘掉一个坏节点后回头复验原区间，
    而「有它参与才装不上」这类坏法会反复触发同一条探针链——实测那版顶到轮数上限、
    一个节点都摘不出来。两半都入队没有这个问题：每个区间**只试装一次**就被替换成它的两半，
    区间总数与节点数同阶，坏节点 m 个时总试装 O(m·log n + n/floor)，且**必然终止**。

    「装不上且更大 ⇒ 切两半」是**无损**的：两半合起来就是原区间，不会漏掉任何节点，只是把
    「坏在哪里」继续往下问。所以不需要「父子复验」那套状态。

    与「逐节点判定」的关键差别（也是它便宜的原因）：这里**只摘能证明是坏的**。全好时一个
    都不摘；只有 1 个坏节点时摘它一个，不整片丢。
    """
    removed = []
    removed_names = set()
    rounds = 0
    pending = [list(chunk)]
    while pending:
        # 墙钟预算优先于轮数上限：到点就把**已摘到的名字**带回去（外层会保留这部分收益），
        # 而不是当成「归因失败」把整块作废。返回 done=False 但 removed 非空，调用方按
        # 「摘到了一些、没摘完」处理，绝不当失败。
        if deadline is not None and should_stop_for_budget(deadline):
            return False, removed, rounds
        if rounds >= TRIAL_MAX_ISOLATE_ROUNDS:
            # 顶到上限：归为「归因失败」，由调用方 fail-open，绝不无限循环。
            return False, removed, rounds
        cur = pending.pop()
        if not cur:
            continue
        if all(str((p or {}).get('name') or '') in removed_names for p in cur):
            continue
        ok, err = _trial_install(cur, workdir)
        rounds += 1
        if ok:
            continue
        if not err:
            return False, removed, rounds
        if len(cur) <= bisect_floor or len(cur) == 1:
            # 兜底出口：无法再往下钻，整块摘掉（见 docstring）。
            for i, p in enumerate(cur):
                name = str((p or {}).get('name') or f'#{i}')
                if name in removed_names:
                    continue
                removed.append(name)
                removed_names.add(name)
            continue
        mid = len(cur) // 2
        pending.append(cur[:mid])
        pending.append(cur[mid:])
    return True, removed, rounds


def trial_load(proxies, workdir=None, max_nodes_per_batch=TRIAL_MAX_NODES_PER_BATCH,
               bisect_floor=TRIAL_BISECT_FLOOR,
               budget_seconds=DEFAULT_TRIAL_BUDGET_SECONDS):
    # 下面这段 docstring 里讲预算
    """把 `proxies` 交给本机 mihomo 试装，返回 `(保留的节点, 报告 dict)`。

    为什么需要它：mihomo 对 provider 是**全有或全无**——片里一个节点解析失败（实测
    2026-09-15：`invalid REALITY short ID`），整个 provider 的 `proxies` 就是 `[]`。
    过滤层的分片只把损失压到 1/片数，坏节点多起来下游照样会大幅缩水。这一层在发布前
    把「装不上」的节点拎出来摘掉，**其余原样保留**——不是整片丢。

    粒度与代价：二分定位到单个节点（复杂节点图才退化成摘掉一小块 ≤ `bisect_floor`
    个）。代价是每次试装都要重起一次 mihomo（内核已在本地，不必重新下载；一次就绪
    通常几秒）。所以先按 `max_nodes_per_batch` 切块**只定位坏块**，再对坏块二分——
    全好时总代价只有「块数」那么几次。

    两条硬约束（都踩过）：

      * **provider 文件必须写在 home 内**，否则 mihomo `level=fatal` 直接退出，
        「装不上」会被误读成「节点非法」而**误删好节点**。这里同样过 `_safe_home_dir`。
      * **判据必须排除「自己故障」**：mihomo 起不来、日志里没有 provider 失败特征时
        返回 `skipped`，原样放行全部。宁可下游去扛坏节点，也不能凭一次起不来的日志删节点。

    **墙钟预算（`budget_seconds`）**：每次试装都要重起一次 mihomo（≈11 秒，实测关掉健康
    检查也一样，那是进程冷启动而不是探测耗时），而一个坏块的二分要触及 O(m·log n) 个区间。
    两者一乘就能轻易吃掉整个 job —— 2026-09-15 run 34989917789 就因为没有它而撞上
    `timeout-minutes` 被**硬取消**，下游三个测速 job 全 skipped。
    到点的降级方向是**停止排雷**：已经摘掉的名字照摘，剩下还没测的块**原样放行**
    （记 `trial_load_budget_stop`）。这比「跳过整层」好——已经排掉的那部分是实打实的收益；
    也比「继续排」好——继续排会撞硬取消，连已抓到的订阅一起报废。

    三条硬约束（都踩过）：

      * **provider 文件必须写在 home 内**，否则 mihomo `level=fatal` 直接退出，
        「装不上」会被误读成「节点非法」而**误删好节点**。这里同样过 `_safe_home_dir`。
      * **判据必须排除「自己故障」**：mihomo 起不来、日志里没有 provider 失败特征时
        返回 `skipped`，原样放行全部。宁可下游去扛坏节点，也不能凭一次起不来的日志删节点。
      * **必须有墙钟预算**（见上）。

    与 `filter_alive` 同一降级原则：这一层故障**不失败**，只是退回「少排一点雷」。
    """
    total = len(proxies)
    report = {
        'enabled': True,
        'total': total,
        'kept': total,
        'removed': 0,
        'removed_names': [],
        'batches': 0,
        'bad_batches': 0,
        'rounds': 0,
        'elapsed_seconds': 0.0,
        'batches_failed': 0,
        'budget_seconds': budget_seconds,
        'budget_stopped': False,
        'skipped': False,
        'skip_reason': '',
        'first_error': '',
    }
    started = time.monotonic()
    if total == 0:
        return [], report
    workdir = _safe_home_dir(workdir or (MIHOMO_CONFIG.parent / 'trial-load'))
    workdir.mkdir(parents=True, exist_ok=True)

    def give_up(reason, note):
        report.update({'kept': total, 'removed': 0, 'removed_names': [], 'skipped': True,
                       'skip_reason': reason,
                       'elapsed_seconds': round(time.monotonic() - started, 1)})
        log_progress('trial_load_skipped', reason=reason, note=note, total=total)
        _dump_mihomo_log()
        return list(proxies), report

    try:
        ensure_local_mihomo()
    except Exception as e:
        return give_up('mihomo_ensure_failed', f'准备 mihomo 内核失败：{e}')
    batch_size = max(1, min(int(max_nodes_per_batch or total), TRIAL_MAX_NODES_PER_BATCH))
    removed_set = set()
    batches = 0
    bad = 0
    rounds = 0
    failed = 0
    first_error = ''
    budget_stopped = False
    deadline = speedtest_budget_deadline(budget_seconds)
    try:
        for start in range(0, total, batch_size):
            chunk = proxies[start:start + batch_size]
            if not chunk:
                continue
            batches += 1
            # 进块之前先看预算。放在这里（而不是只在块结束时看）才能拦住「上一个块把
            # 预算吃光、下一个块还要再起一次 mihomo」——那是 11 秒 × 剩余块数的白烧。
            if should_stop_for_budget(deadline):
                budget_stopped = True
                break
            # 先试装。装得上就是最好情况——**不记进 bad_batches**，也不进二分。
            ok, err = _trial_install(chunk, workdir)
            rounds += 1
            if ok or not err:
                # ok=True：这一块干净；ok=False 且 err=''：归因不了（mihomo 起不来等），
                # 同样不能当坏块——见 `_trial_install` 的返回约定。
                if not ok:
                    failed += 1
                    if not first_error:
                        first_error = err or 'mihomo 起不来'
                    log_progress('trial_load_batch_unresolved', start=start,
                                 size=len(chunk), error=err)
                continue
            # 装机失败且 mihomo 明确指向 provider：二分定位并摘掉真正的坏节点。
            bad += 1
            # 二分是唯一可能失控的地方，它自己也要看预算：到点就带着已摘到的名字返回，
            # 剩下的交由外层「原样放行」——而不是把它算成失败。
            done, removed, used = _trial_isolate(chunk, workdir, bisect_floor=bisect_floor,
                                                 deadline=deadline)
            rounds += used
            removed_set.update(removed)
            if not should_stop_for_budget(deadline):
                log_progress('trial_load_batch_isolated', start=start, size=len(chunk),
                             removed=len(removed))
            if not done and not removed:
                # 一个都没摘出来且归因不了：这一块没法分辨，记进 failed 让摘要如实反映。
                failed += 1
                if not first_error:
                    first_error = 'mihomo 二分途中无法归因'
                log_progress('trial_load_batch_unresolved', start=start, size=len(chunk),
                             error=first_error)
            if should_stop_for_budget(deadline):
                budget_stopped = True
                break
    except Exception as e:
        return give_up('trial_load_error', f'试装过程中异常：{e}')

    kept = [p for p in proxies
            if str((p or {}).get('name') or '') not in removed_set]
    # 只按名字摘节点，名字缺失/重复的不会被摘掉——如实反映在报告里，免得读者以为
    # 「removed 数」就等于「订阅少了多少」。
    dropped = total - len(kept)
    report.update({
        'kept': len(kept),
        'removed': dropped,
        'removed_names': sorted(removed_set)[:200],
        'batches': batches,
        'bad_batches': bad,
        'rounds': rounds,
        'batches_failed': failed,
        'budget_stopped': budget_stopped,
        'first_error': first_error,
        'elapsed_seconds': round(time.monotonic() - started, 1),
    })
    if budget_stopped:
        # 到点停止排雷：已摘的照摘、没测到的块原样放行。**不是 skipped**——排雷确实
        # 做了，只是没做完；摘要要如实说「没排完」，而不是说「没排」。
        log_progress('trial_load_budget_stop', batches=batches, bad_batches=bad,
                     removed=dropped, elapsed=report['elapsed_seconds'],
                     budget=budget_seconds,
                     note='预算到点，未测的块原样放行（不是整层 skipped）')
    log_progress('trial_load_done', total=total, kept=len(kept), removed=dropped,
                 batches=batches, bad_batches=bad, rounds=rounds, failed=failed,
                 budget_stopped=budget_stopped, elapsed=report['elapsed_seconds'])
    if dropped:
        log_progress('trial_load_removed_samples', count=dropped,
                     samples=report['removed_names'][:20])
    return kept, report

