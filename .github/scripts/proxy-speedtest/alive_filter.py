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


def _start_mihomo():
    """起一个全新的 mihomo（先收掉同命令行的旧进程，与 taier 的 TUN 版本同一手法）。

    **不要在这里清理 `shard-*.yaml`**：调用方是「先写分片、再起 mihomo」，任何按
    `shard-*.yaml` 通配的删除都会把刚写好的输入删掉，mihomo 随即报一片
    `no such file or directory` 而让整层 fail-open（实测 2026-09-15 加清理时就是这个症状）。
    分片本来每轮全量重写，不存在需要清理的残留。
    """
    import os
    import signal
    import subprocess

    ensure_local_mihomo()

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
            except OSError as e:
                log_progress('alive_filter_terminate_skipped', pid=pid, error=str(e))
    except Exception as e:
        log_progress('alive_filter_process_scan_failed', error=str(e))

    with MIHOMO_LOG.open('a', encoding='utf-8') as lf:
        subprocess.Popen([str(MIHOMO), '-d', str(MIHOMO_CONFIG.parent), '-f', str(MIHOMO_CONFIG)],
                         stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    return wait_mihomo(timeout=60)


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
