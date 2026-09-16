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
import json
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
# 试装用的 provider 名/文件名前缀。**每轮全量重写、不需要清理**（同分片），且
# **绝不能按通配符删这里**：调用方是先写文件、再起 mihomo，删掉输入会让 mihomo
# 报一片 `no such file or directory` 而让整层 fail-open。
# 名字只用「前缀 + 数字键」（见 `_trial_isolate` 的 key_of），避免节点名里的特殊字符
# 变成非法文件名；键必须唯一，否则同名的 provider 会互相覆盖、判定结果串位。
TRIAL_FILE_PREFIX = 'trial-'
TRIAL_PROVIDER_PREFIX = 'trial-'

# ---------------------------------------------------------------------------
# 【试装的体积上限：20KB —— 本层最重要的一个实测数字】
# ---------------------------------------------------------------------------
# **mihomo 对 provider 文件有一个约 20KB 的体积上限，超了就静默装到 0 个、且一条日志
# 都不打。** 2026-09-16 实测（真机二进制，非沙箱替身）：
#
#     一份 config 里 1 个 provider 文件     6.3KB  → 正常装载
#     一份 config 里 2 个 provider 文件    12.6KB  → 正常装载
#     一份 config 里 3 个 provider 文件    18.9KB  → 正常装载、坏节点照常报错
#     一份 config 里 4 个 provider 文件    25.2KB  → **全静默归零**
#
#     单文件二分（坏节点在中间，固定 60 行只把名字撑长）：
#       60 行 × 名长   10  ⇒ 18.9KB → 正确报 `proxy 30 error`
#       60 行 × 名长  200  ⇒ 30.0KB → 静默归零
#     单文件按节点数二分：n=62（20.3KB）报错，n=63 起静默归零。
#
# 三条结论（推翻了本层原来的 `TRIAL_MAX_NODES_PER_BATCH = 2000` 做法）：
#
#   1. 上限看的是**字节数**，与节点数、行数都无关——60 行固定、只加长名字就会越过它。
#      所以按「节点数」限流是错的量纲：2000 个实战节点 ≈ 627KB，是上限的 31 倍。
#   2. 上限作用在**一份 config 里所有 provider 文件的体积之和**上，不是单文件。
#      因此批量判定必须同时管住「单文件大小」和「同批总量」。
#   3. 归零是**静默**的：没有 `error`、没有 `fatal`。而本层原来的判据是「日志里没有
#      provider 错误特征 ⇒ 都装得上」——在超限时会被整批误判成「全都好」。
#      这是 fail-open 的静默失效（实测 2000 个/批时 8 个坏节点一个都没剔出来），
#      比误删严重得多，所以判据必须加一条**正面证据**（见 `_trial_probe` 的 loaded 校验）。
TRIAL_MAX_BYTES_PER_FILE = 16 * 1024
# 一份 config 里所有试装 provider 文件的体积之和上限。取 16KB：距实测的 20KB 临界留
# 4KB 余量（节点 YAML 的实际行宽随字段多少浮动，不能贴着临界跑）。三份 16KB 是越界的，
# 所以「同层几个区间一起判」时按这个总量来分批，而不是无脑塞进一份 config。
TRIAL_MAX_BYTES_TOTAL = 16 * 1024
# `base64` 换算的参考行宽，仅在估算时用（真实大小以写盘后的文件为准）。
B64_LINE_WIDTH = 120
# 一次试装最多塞多少个节点——**只作为「单文件」的额外护栏**，真正的约束是上面两个
# 字节数（见那段注释：按节点数限流是错的量纲）。留着它是为了让二进制搜索有个上界。
TRIAL_MAX_NODES_PER_BATCH = 2000
# 二分细到「块内还剩几个就不再往下钻、整块摘掉」的门槛。取 1：**一直钻到单个节点**。
#
# 这里原来取 8，理由是「继续二分要多起几次 mihomo」——那个理由在**批量判定之后已经不
# 成立了**：每层不管有多少个区间都只跑一次探针（见 `_trial_isolate`），所以往下钻一层的
# 成本是「一次探针」，与区间数无关。而 floor=8 的代价是实打实的误伤：块内 8 个里只有
# 1 个坏节点时会连带摘掉它周围的 7 个邻居（实测 2026-09-16 真机：2000 个节点、8 个坏
# 节点，floor=8 下多剔了 37 个好节点，形态就是每个坏节点前后各带 2-3 个邻居）。
#
# 取 1 之后唯一的例外是 `len(cur) == 1` 那个分支：那个节点自己就装不上、又已经切到底了，
# 只能摘它——这是「单节点装不上」的正常出口，不是兜底。
TRIAL_BISECT_FLOOR = 1
# 一个坏块最多试装多少次。**必须是有限的**：区间队列的做法下，一个块里节点全坏时
# 队列会一路切到单节点，试装次数约为 2·块内节点数。
#
# floor 从 8 降到 1 之后这个上限要跟着抬：块内 183 个（= 16KB 装箱后的一块）全坏时
# 最坏需要 ~366 轮。取 2000 能容下「一整块全坏」这个病态形态而不误判成「归因失败」，
# 同时仍是有限值——顶到上限即归为「归因失败」，由调用方 fail-open，绝不无限循环。
# 代价可控：撞上限只在病态轮次发生，正常轮次（几个坏节点）十几轮就结束。
TRIAL_MAX_ISOLATE_ROUNDS = 2000
# 等「上一个 mihomo 让出控制器端口」的宽限。实测 mihomo 收 SIGTERM 后要 ~10 秒才真正退出，
# 但端口通常几百毫秒就放手（它先关监听再收尾）——盯端口而不是盯进程，就是为了别白等那 10 秒。
# 这个上限只是兜底：超了就往下走，真有问题会在 `wait_mihomo` 里报出来。
TRIAL_TERMINATE_GRACE_SECONDS = 3.0
# 每轮试装重起 mihomo 的等待上限。单轮就绪远快于 60（那是过滤层的保守值），
# 折中取 30：异常时少空等，正常时绰绰有余。
TRIAL_WAIT_TIMEOUT = 30
# mihomo 日志里「provider 初始化失败」的特征串。用于把「节点被 mihomo 判非法」
# 与「进程根本没起来 / 别的原因 fatal」分开——后者绝不能当成分辨出坏节点。
TRIAL_ERROR_MARKERS = ('initial proxy provider', 'error: proxy')
# 「某个 provider 开始初始化」的行前缀。**这是本层读日志的正确姿势的支点**：
# mihomo 逐个初始化 provider（日志顺序：`Start initial provider <名>` → 紧接着该
# provider 的 `initial proxy provider <名> error: ...`），所以「每个 provider 的
# `Start initial provider` 都已在日志里」== 「每个 provider 的结论都已落盘」。
# 只等「日志里出现 error」是错的（好的 provider 永远没有 error，会等到超时）。
TRIAL_START_MARKER = 'Start initial provider '
# 等「所有 provider 的初始化结论落盘」的上限。正常情况下 mihomo 初始化 2000 个节点
# 的 provider 也就几百毫秒，所以这里平时是「一有就返回」，只在病态时兜底。
TRIAL_CONCLUSION_TIMEOUT = 20.0
# 热重载：改完 provider 文件后让 mihomo 重新装载，**不再冷启动进程**。
#
# 为什么这是本层的成本关键（2026-09-16 实测）：单次判定拆开量之后，「启动」恒为
# **3.01 秒**且与节点数完全无关（20/100/300 个节点都是 3.07-3.08 秒），而等日志
# 0.05 秒、读 `/providers/proxies` 0.04-0.26 秒。那 3 秒全花在 `_start_mihomo` 里
# 「等上一个 mihomo 让出控制器端口」——它收 SIGTERM 后要 ~10 秒才真正退出，宽限
# 3 秒必然等满。而 `trial_load` 一次运行要判几十上百次，3 秒 × 100 = 5 分钟纯浪费
# （实测 2000 节点 / 8 坏节点跑一轮 255 秒，其中 ~190 秒是这个）。
#
# 换成热重载后同一件事 0.03 秒（实测 8 次循环：改文件 → `PUT /configs?force=true`
# → 重读日志，**100 倍**），且证据两条都仍然成立：坏 provider 照旧打
# `initial proxy provider <名> error: ...`、`/providers/proxies` 照旧给出实到节点数。
#
# 用法是「第一次冷启动、之后每次热重载」：热重载要求进程已经在跑，所以不能省掉冷启动。
TRIAL_HOT_RELOAD = True

# 整个试装阶段的墙钟预算。**必须有**（实测 2026-09-15 run 34989917789 就是没它出的
# 事故）：单次试装的成本是「重起一次 mihomo + wait_mihomo 轮询」≈ 11 秒，与节点多少
# 关系不大（已实测：把健康检查关掉也还是 11 秒，所以这不是探测耗时，是进程冷启动）。
# 而一个坏块的二分要触及 O(m·log n) 个区间 —— 那轮 2000 个节点的块里有 24 个坏节点，
# 单块就要 ~500 次试装 ≈ 90 分钟。7 个块下去，job 撞上 timeout-minutes 被 GitHub
# **硬取消**：已抓到的 65 个订阅、已投喂的 Sub-Store、下游三个测速 job（全 skipped）
# 一起报废 —— 这正是本仓库「宁可降级也不被硬取消」那条原则要防的形态。
#
# 取 1500 秒（25 分钟）：把「尽量排完」优先于「早点收手」。理由与上下界：
#
#   * 批量判定后每层只需一次启动（~1.2 秒），全好时 7 块 ≈ 10 秒；实测那轮 14166 个
#     节点、7 个坏块（每块 16-48 个坏节点）按批量算法估 ≈ 200 次启动 ≈ 4 分钟；
#   * 极端轮次（上千个坏节点）才可能吃满，此时降级为「已摘的照摘、未测块原样放行」；
#   * 上界由 job 的 timeout-minutes 反推：检出 0.5 + Sub-Store 起容器 0.5 + 抓取预算
#     900s(15min) + Sub-Store 段 300s(5min) + 健康检查 600s(10min) + 试装 1500s(25min)
#     ≈ 56.5 分钟，所以 job 必须抬到 70 分钟（见 workflow 里的成对注释）。
#
# 到点的降级方向是「停止排雷」——**已摘的照摘、还没测的块原样放行**，让下游去扛那部分
# 坏节点，而不是让整轮变成零产出。
DEFAULT_TRIAL_BUDGET_SECONDS = 1500


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


def _trial_node_bytes(node):
    """估一个节点写成 YAML 后占多少字节（用于切块，不要求精确）。

    为什么不数「节点个数」：mihomo 的上限是**字节数**（见 `TRIAL_MAX_BYTES_PER_FILE`
    上方那段实测），节点名字长的和字段多的节点能差好几倍。这里直接把它 dump 一遍量长度，
    比任何按行宽的经验公式都准，代价只有序列化本身。
    """
    try:
        return len(yaml.safe_dump([node], allow_unicode=True, sort_keys=False).encode('utf-8'))
    except Exception:
        # 序列化不了（畸形结构）⇒ 给一个偏大的估值，让它单独成块、不与别人挤在一起。
        return TRIAL_MAX_BYTES_PER_FILE


def _trial_reload_config(timeout=15):
    """让**已经在跑的** mihomo 重新读一遍 config（provider 文件已改），返回是否成功。

    `PUT /configs?force=true` 是 mihomo 的热重载接口（实测 204）。它会按新 config 重建
    provider，于是：
      * 坏的 provider 照旧打 `initial proxy provider <名> error: ...`（与冷启动同一形态）；
      * `/providers/proxies` 的实到节点数也照旧刷新。
    两条证据都还在，所以判定逻辑不用改，只是**换掉了那 3 秒冷启动**（见 `TRIAL_HOT_RELOAD`）。

    **必须带 `force=true`**：不带的话 mihomo 在 config 路径没变时会跳过重载，改了 provider
    文件也不生效——那会静默沿用上一轮的结论，看起来就像「判定结果不跟着数据走」。
    """
    body = json.dumps({'path': str(MIHOMO_CONFIG)}).encode('utf-8')
    req = urllib.request.Request(MIHOMO_API + '/configs?force=true', data=body,
                                 headers={'Content-Type': 'application/json'}, method='PUT')
    try:
        with _no_proxy_opener().open(req, timeout=timeout) as r:
            return 200 <= int(r.status) < 300
    except Exception as e:
        log_progress('trial_load_reload_failed', error=str(e))
        return False


def _trial_provider_counts(opener, timeout=10):
    """读一次 `/providers/proxies`，返回 `{provider 名: 实际装到的节点数}`。读不到返回 None。

    **这是试装层的「正面证据」**，不是可有可无的锦上添花：光看「日志里有没有 provider
    错误」会漏掉一整类失败——mihomo 遇到 provider 文件超过约 20KB 时**静默装到 0 个、
    不写任何 error/fatal**（见 `TRIAL_MAX_BYTES_PER_FILE`）。那种情况下「没有错误」被
    读成「全都装得上」，坏节点会被整批放过。所以判定要多一条：**这个 provider 到底装到
    几个节点**——装到 0 个必须与「全好」区分开，装到一部分也要与「整块都在」对上。
    """
    try:
        with _no_proxy_opener().open(MIHOMO_API + '/providers/proxies', timeout=timeout) as r:
            data = yaml.safe_load(r.read().decode('utf-8', 'ignore')) or {}
    except Exception:
        return None
    out = {}
    for name, info in (data.get('providers') or {}).items():
        if not str(name).startswith(TRIAL_PROVIDER_PREFIX):
            continue
        out[str(name)] = len((info or {}).get('proxies') or [])
    return out


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


def _controller_port():
    """从当前 config 里取 external-controller 的端口号；取不到返回 None。

    为什么不写死 19090：`filter_alive` / `trial_load` 生成的 config 里就是这个值，
    但自检会把它换到空闲端口（沙箱里 19090 被僵尸监听占着），写死等于让自检验不到
    真实路径。
    """
    try:
        cfg = yaml.safe_load(MIHOMO_CONFIG.read_text(encoding='utf-8')) or {}
    except Exception:
        return None
    addr = str(cfg.get('external-controller') or '')
    if ':' not in addr:
        return None
    try:
        return int(addr.rsplit(':', 1)[1])
    except ValueError:
        return None


def _port_free(port, host='127.0.0.1'):
    """这个 TCP 端口现在能不能 bind（= 上一个 mihomo 已经放手）。"""
    import socket
    s = socket.socket()
    try:
        s.bind((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


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

    # **必须等旧进程让出端口**：只发 SIGTERM 不管的话，下一次 Popen 会和它抢 19090
    # 控制器端口，新进程报 `External controller listen error: bind: address already
    # in use` 后**静默不监听**，`wait_mihomo` 只能等到超时。试装层要反复起停，这个
    # 竞态会稳定复现（沙箱实测 test_gist_nodes_substore 里空转了 30 秒 × N 次）。
    #
    # 判据用「**端口能不能 bind**」而不是「进程还在不在」：mihomo 收 SIGTERM 后要
    # ~10 秒才真正退出，盯着进程就只能白等满 10 秒——试装层每次探测都调这里，那 10 秒
    # 直接变成「每次试装 11 秒」的全部成本（实测：1 个节点 1.24 秒、40 个节点 11.03 秒，
    # 而日志显示控制器其实 0.5 秒内就绪）。盯端口则是「它一放手就走」，通常 <0.5 秒。
    #
    # 超时上限仍保留：万一端口被别的进程长期占着（同机并行跑别的测速 job），这里不该
    # 死等——真正的失败会在下面 Popen 之后由 `wait_mihomo` 报出来。
    # **只有「端口是我们刚杀掉的那个进程占的」才值得等**：`_port_free` 判 False 也可能是
    # 端口本来就被别的进程占着（同机并行跑别的测速 job、或沙箱里的残留监听）。那种情况下
    # 等多久都没用，白等 10 秒 × 每次探测 = 把「每次试装 1 秒」变成 11 秒（实测踩过）。
    # 判据：先看端口是否已在监听——**一开始就不可用**说明不是我们的进程占的，直接走。
    if killed:
        port = _controller_port()
        if port is None or not _port_free(port):
            deadline = time.monotonic() + TRIAL_TERMINATE_GRACE_SECONDS
            while time.monotonic() < deadline:
                if _port_free(port):
                    break
                time.sleep(0.05)

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
def _trial_batch_config(items, workdir):
    """生成「一批 provider」的试装配置：`items` 是 `[(key, nodes), ...]`。

    **为什么要批**：单次试装的成本几乎全是 mihomo 冷启动（实测 ~1.2 秒，与 provider
    里是 1 个还是 2000 个节点无关），而一个坏块的二分要判定成百上千个区间。逐区间各起
    一次进程 ⇒ 「区间数 × 1.2 秒」，那才是 2026-09-15 run 34989917789 把 job 拖到
    `timeout-minutes` 被硬取消的真正原因。

    mihomo 允许一份 config 里放多个 file provider，且**每个 provider 各自初始化、各自
    报错**（实测：三个 provider 里两个含坏节点，日志两条 `initial proxy provider <名>
    error: ...`，好的那个干净）。所以一次启动就能同时判定几十个区间，并按 provider 名
    精确归属——总成本从「区间数 × 1.2s」降到「批数 × 1.2s」。

    **但「一批」的大小由字节数决定，不由区间数决定**（`TRIAL_MAX_BYTES_TOTAL` 那段
    实测）：一份 config 里所有 provider 文件加起来超过约 20KB，mihomo 会把它们**静默
    装到 0 个且不报错**。调用方已经按字节切好（见 `trial_load` 的分批与 `_trial_isolate`
    的同层分批），这里只负责写盘并回报**实际字节数**，供上层核对。

    **健康检查关掉**（`enable: False`）：判据是「provider 能不能被解析装载」，那发生在
    配置装载阶段，与探活无关（实测关掉后非法 `short-id` 照旧报错）。开着的话每次启动都
    要等一轮全量探测，白白把 1.2 秒变成 11 秒。这与下游的 `lazy: false` 不冲突——下游
    该探的还是会探，本层只是不靠它做判定。
    """
    providers = {}
    written = {}
    for key, nodes in items:
        path = workdir / f'{TRIAL_FILE_PREFIX}{key}.yaml'
        path.write_text(yaml.safe_dump({'proxies': list(nodes)}, allow_unicode=True,
                                       sort_keys=False), encoding='utf-8')
        written[key] = path.stat().st_size
        providers[f'{TRIAL_PROVIDER_PREFIX}{key}'] = {
            'type': 'file',
            'path': str(path),
            'health-check': {'enable': False},
        }
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
                'use': list(providers),
                'proxies': ['DIRECT'],
            }
        ],
        'proxy-providers': providers,
        'rules': ['MATCH,AUTO'],
    }
    MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False),
                             encoding='utf-8')
    return cfg, written


def _read_trial_log_after_init(provider_names, timeout=TRIAL_CONCLUSION_TIMEOUT):
    """等「所有 provider 的初始化结论」落盘，返回 `(日志全文, 是否全部落盘)`。

    **为什么不能拿到 `/version` 就立刻读日志**（2026-09-16 实测踩的坑）：`wait_mihomo`
    等的是控制器，而 mihomo 是「控制器先监听、再逐个初始化 provider」。实测时间线：

        0.093s  RESTful API listening
        0.143s  Start initial provider trial-probe
        0.143s  Start initial compatible provider AUTO / default
        0.143s  initial proxy provider trial-probe error: ... invalid REALITY short ID

    即 `wait_mihomo` 0.093 秒返回时，错误行还没写（晚 50ms）。于是同一份坏数据，
    **第一次探针能读到错误、第二次起读到的是一片空白**——看起来就像「坏节点消失了」，
    实则是竞态（实测：第 1 次 failed={'probe'}，第 2/3 次 failed=set()）。

    正确姿势是等一个**确定性**的标志，而不是睡一个猜出来的时长：mihomo 为每个 provider
    都先写一行 `Start initial provider <名>`（好的坏的都有），所以「每个 provider 的
    Start 行都出现过」等价于「每个 provider 的结论都已落盘」。

    判据用「行数够不够」而不是「名字齐不齐」：provider 名可能互相包含（`trial-0` 是
    `trial-0x1` 的前缀），按名字匹配会数错，按 `Start initial provider ` 前缀计数则不会。

    `ok=False`（超时）由调用方当「归因不完整」处理：**宁可整块放行，也不能拿半份日志
    去删节点**——半份日志会漏掉后半截的坏 provider，表现为「误判成装得上」。
    """
    want = len(provider_names)
    deadline = time.monotonic() + max(0.0, float(timeout or 0))
    text = ''
    while True:
        try:
            text = MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore')
        except Exception:
            text = ''
        if sum(1 for line in text.splitlines()
               if line.startswith(TRIAL_START_MARKER) is False
               and TRIAL_START_MARKER in line) >= want:
            return text, True
        if time.monotonic() >= deadline:
            return text, False
        time.sleep(0.05)


def _trial_probe(items, workdir, opener=None, hot=False):
    """一次启动判定一批区间，返回 `(装载失败的 key 集合, 归因是否可信, 真因, 启动次数)`。

    `items` 是 `[(key, nodes), ...]`，`key` 必须是安全的文件名字符（调用方负责）。
    `hot=True` 时走**热重载**（进程已在跑，只让 mihomo 重读 config）而不是冷启动——
    见 `TRIAL_HOT_RELOAD`：冷启动固定 3 秒、热重载 0.03 秒，判定证据两者完全相同。

    判据是**两条证据交叉**，缺一不可——只靠其中任何一条都会静默出错：

      * **反证：日志里的 `initial proxy provider <名> error: ...`**（按 provider 名归到
        key）。这条能给出「谁是坏的」，但**给不出「谁是好的」**；
      * **正证：`/providers/proxies` 里这个 provider 实际装到几个节点**。这条能给出
        「它到底被装载了没有」——`装到 0 个` 与「日志干净」必须区分开。
        只靠反证的后果实测过：mihomo 在 provider 文件超约 20KB 时**静默装到 0 个、不写
        任何 error**（见 `TRIAL_MAX_BYTES_PER_FILE`），于是「日志干净」=「全都好」
        ⇒ 整批坏节点被放过（run 实测 2000 个/批时 8 个坏节点一个都没剔出来）。

    所以返回的 `trusted` 含义是「**这批的结论可信**」，它要求：
      1. mihomo 在跑（冷启动成功 / 热重载成功）；
      2. 每个 provider 的初始化结论都已落盘（`_read_trial_log_after_init`）；
      3. **每个 provider 的实到节点数与它应有的节点数一致**（全到 = 好；0 = 装载失败；
         只到一部分 = 也按「装载失败」处理——那说明 provider 被截断了，不能当成好）。
    任何一条不满足 ⇒ `trusted=False`，调用方原样放行整批（宁可下游去扛坏节点，
    也不能拿半份证据删节点，更不能把「没装载」读成「装得好」）。
    """
    _cfg, written = _trial_batch_config(items, workdir)
    PROBE_COUNTER['n'] = PROBE_COUNTER.get('n', 0) + 1
    names = [f'{TRIAL_PROVIDER_PREFIX}{key}' for key, _nodes in items]
    # **清空日志必须在装载之前**：mihomo 的结论行是在装载**过程中**写的，装载之后清会把
    # 本批的结论一起抹掉 ⇒ 永远等不到结论、20 秒超时、整批不可信（实测踩过）。
    #
    # 那「上一批的旧行被刷进来」怎么办？靠 `_read_trial_log_after_init` 去重解决：它只数
    # `Start initial provider ` 行，而**清空会截断文件**，上一批的 Start 行随之消失；
    # 万一 mihomo 的缓冲把旧行写回来了，那次判定会因为「本批的 Start 行数对不上」而
    # 走不可信分支（原样放行），不会误删节点——**宁可少排雷，不可误删**。
    try:
        MIHOMO_LOG.write_text('', encoding='utf-8')
    except Exception as e:
        log_progress('trial_load_log_truncate_failed', error=str(e))
    if hot:
        # 热重载失败 ⇒ 退回冷启动，而不是把这一批判成不可信：重载失败可能是 mihomo
        # 已经不在了（上一批崩了），冷启动能救回来。
        if not _trial_reload_config():
            hot = False
    if not hot:
        try:
            _start_mihomo(wait_timeout=TRIAL_WAIT_TIMEOUT)
        except Exception as e:
            # 起不来 ≠ 节点有问题。归因不可信，由调用方原样放行。
            log_progress('trial_load_start_failed', error=str(e))
            return set(), False, '', 1
        starts = 1
    else:
        starts = 0
    return _trial_judge(items, names, written, opener, starts=starts)


def _trial_judge(items, names, written, opener, starts):
    """读日志 + 读实到节点数，交叉出「哪些区间装不上」。冷启动与热重载共用这一段。

    拆出来是因为热重载与冷启动**只差怎么让 mihomo 装载**，判定部分必须完全一致——
    否则热重载路径会悄悄少一条证据，而那种差异在真机上极难发现。
    """
    text, complete = _read_trial_log_after_init(names)
    if not complete:
        # 日志没读全（初始化比预期慢 / 进程中途挂了）：归因不可信，原样放行。
        log_progress('trial_load_log_incomplete', providers=len(names),
                     seen=sum(1 for line in text.splitlines() if TRIAL_START_MARKER in line),
                     note='provider 初始化结论未全部落盘，本批归因不可信')
        return set(), False, '', starts

    failed_keys = set()
    first_error = ''
    for line in text.splitlines():
        if not any(marker in line for marker in TRIAL_ERROR_MARKERS):
            continue
        for key, _nodes in items:
            if f'provider {TRIAL_PROVIDER_PREFIX}{key} ' in line:
                failed_keys.add(key)
                if not first_error:
                    first_error = line.strip()
                break

    # 写盘的体积自己先核一遍：越界的话下面的正证会恰好是「静默归零」，那是量纲出错的
    # 信号（不是节点坏），必须打出来，否则又会变成一桩无解之谜。
    total_bytes = sum(written.values())
    if total_bytes > TRIAL_MAX_BYTES_TOTAL or any(
            b > TRIAL_MAX_BYTES_PER_FILE for b in written.values()):
        log_progress('trial_load_batch_oversize', providers=len(items),
                     total_bytes=total_bytes, limit=TRIAL_MAX_BYTES_TOTAL,
                     biggest=max(written.values()) if written else 0,
                     note='本批试装文件超体积上限，mihomo 会静默归零，归因不可信')

    counts = _trial_provider_counts(opener) if opener is not None else None
    if counts is None and opener is None:
        counts = _trial_provider_counts(_no_proxy_opener())
    if counts is None:
        log_progress('trial_load_counts_unavailable',
                     note='读不到 provider 实到节点数，缺正证 ⇒ 本批归因不可信')
        return set(), False, '', starts
    for key, nodes in items:
        pname = f'{TRIAL_PROVIDER_PREFIX}{key}'
        got = counts.get(pname)
        if got is None:
            # provider 在 API 里都没有 ⇒ 它没被装载。这**不是**「装得上」。
            failed_keys.add(key)
            if not first_error:
                first_error = f'{pname} 未出现在 /providers/proxies（未被装载，体积可能越界）'
            continue
        if got != len(nodes):
            # 到得不全（含 0）⇒ 这个 provider 被截断/归零，不能当成好。
            failed_keys.add(key)
            if not first_error:
                first_error = (f'{pname} 只装到 {got}/{len(nodes)} 个节点'
                               f'（文件 {written.get(key, 0)} 字节）')
    return failed_keys, True, first_error, starts


# 本轮的探针计数。**在 `_trial_probe` 源头打点**，不靠调用方各自的 `used`/`counter` 累加：
# 那两处口径不一（冷启动 `used=1`、热重载 `used=0`），曾经让报告里写 40 而真实跑了 79，
# 摘要数字失真。放在这里只有一处维护点，且冷/热一律按「一次探针」计。
PROBE_COUNTER = {'n': 0}


def _trial_split_batches(chunks, key_of):
    """把这一层的所有区间按**字节总量**分组成若干份 config，返回 `[[(key, 区间), ...], ...]`。

    **为什么不能一层一份 config**：批量判定的上限是「一份 config 里所有 provider 文件的
    体积之和 ≈ 20KB」（见 `TRIAL_MAX_BYTES_PER_FILE` 那段实测）。二分到第 5 层就是 32 个
    区间，每个几十 KB ⇒ 总量轻松越过上限 ⇒ mihomo 全部静默归零 ⇒ 这一层所有区间都被
    判成「装不上」⇒ **整层一起被摘掉**（实测复现：40 个节点里 3 个坏节点，结果剔了 15 个）。

    所以按字节装箱：装满 `TRIAL_MAX_BYTES_TOTAL` 就开下一份。坏节点集中的层分到的份数少，
    散开时份数多，但**每份都保证在阈值内**——这是「宁可多起几次进程，也不能让整批归零」
    的取舍（归零不是慢，是错）。
    """
    sizes = {}
    for idx, cur in enumerate(chunks):
        sizes[idx] = sum(_trial_node_bytes(p) for p in cur)
    batches = []
    cur_batch = []
    cur_bytes = 0
    for idx in range(len(chunks)):
        one = sizes[idx]
        # 单个区间就超上限（节点多）时也得自成一份，交给上层继续二分——绝不合并。
        if cur_batch and cur_bytes + one > TRIAL_MAX_BYTES_TOTAL:
            batches.append(cur_batch)
            cur_batch, cur_bytes = [], 0
        cur_batch.append((key_of(idx), chunks[idx]))
        cur_bytes += one
    if cur_batch:
        batches.append(cur_batch)
    return batches


def _trial_isolate(chunk, key_of, workdir, bisect_floor=TRIAL_BISECT_FLOOR,
                   deadline=None, counter=None):
    """把一个**已知装不上**的块摘到「剩下的能装上」为止，返回 `(done, removed, first_error)`。

    与逐区间版的关键差别：**同一层的区间按字节装箱后批量判定**。每轮把当前所有「待查
    区间」按 `TRIAL_MAX_BYTES_TOTAL` 打成若干份 config，每份一次启动得到「这份里哪些区间
    装不上」，然后只对装不上的那些继续对半切。于是：

      * 坏节点只有 1 个时，每层只有 1 个区间装不上 ⇒ 每层 1 次启动、O(log n) 层；
      * 坏节点有 m 个且均匀分布时，第 k 层最多 2^k 个坏区间，总启动次数 ≈ Σ min(2^k, m)
        —— 即 O(m + log n)，而不是逐区间版的 O(m·log n)。

    **一份 config 装不下整层是对的**（见 `_trial_split_batches`）：多起几次进程换「每份
    都在体积阈值内」，因为越界的代价不是慢，是把整层误判成全坏、一起摘掉。

    `key_of(chunk)` 由调用方给：它要把一个区间映射成**稳定的、安全的**文件/ provider 名。
    之所以要稳定：同一份 config 里两个 provider 不能重名，而每轮切半会产生新区间，
    所以 key 里带上「这一轮的第几个区间」——内容相同但位置不同本来就是不同区间。

    `deadline` 到点时立刻返回，**已摘到的名字照带回去**（调用方按「摘了一些、没摘完」处理）。
    """
    removed = []
    removed_names = set()
    pending = [list(chunk)]
    first_error = ''
    while pending:
        if deadline is not None and should_stop_for_budget(deadline):
            return False, removed, first_error
        if counter is not None and counter.get('rounds', 0) >= TRIAL_MAX_ISOLATE_ROUNDS:
            return False, removed, first_error
        grouped = _trial_split_batches(pending, key_of)
        # 这一层各份的判定结果：key -> 是否装不上。key 在同一层里唯一（key_of 带位置）。
        layer_failed = set()
        for items in grouped:
            if deadline is not None and should_stop_for_budget(deadline):
                return False, removed, first_error
            if counter is not None and counter.get('rounds', 0) >= TRIAL_MAX_ISOLATE_ROUNDS:
                return False, removed, first_error
            # 热重载：进程已经在跑（调用方第一关冷启动过），这里只让它重读 config。
            failed_keys, trusted, err, _ = _trial_probe(items, workdir,
                                                        hot=TRIAL_HOT_RELOAD)
            if counter is not None:
                counter['rounds'] = counter.get('rounds', 0) + 1
            if not trusted:
                # 这一份归因不了 ⇒ 整层归因不了（不能只放行这一份，那会让别的份的
                # 结论建立在不完整的分层上）。调用方按「没摘完」处理。
                return False, removed, first_error
            if err and not first_error:
                first_error = err
            layer_failed |= failed_keys
        nxt = []
        for idx, cur in enumerate(pending):
            if key_of(idx) not in layer_failed:
                # 这个区间装得上：里面没有坏节点，丢掉它（这是正常的收敛出口）。
                continue
            if len(cur) <= bisect_floor or len(cur) == 1:
                # 切到底了：这个（或这 floor 个）节点自己装不上，只能摘掉它。
                # floor=1 时这就是「单个坏节点」的正常出口：块里只剩它一个还被判失败。
                for i, p in enumerate(cur):
                    name = str((p or {}).get('name') or f'#{i}')
                    if name in removed_names:
                        continue
                    removed.append(name)
                    removed_names.add(name)
                continue
            mid = len(cur) // 2
            nxt.append(cur[:mid])
            nxt.append(cur[mid:])
        pending = nxt
    return True, removed, first_error


def trial_load(proxies, workdir=None, max_nodes_per_batch=TRIAL_MAX_NODES_PER_BATCH,
               bisect_floor=TRIAL_BISECT_FLOOR,
               budget_seconds=DEFAULT_TRIAL_BUDGET_SECONDS):
    """把 `proxies` 交给本机 mihomo 试装，返回 `(保留的节点, 报告 dict)`。

    为什么需要它：mihomo 对 provider 是**全有或全无**——片里一个节点解析失败（实测
    2026-09-15：`invalid REALITY short ID`），整个 provider 的 `proxies` 就是 `[]`。
    过滤层的分片只把损失压到 1/片数，坏节点多起来下游照样会大幅缩水。这一层在发布前
    把「装不上」的节点拎出来摘掉，**其余原样保留**——不是整片丢。

    粒度：二分定位到单个节点（复杂形态才退化成摘掉一小块 ≤ `bisect_floor` 个）。
    先切块**只定位坏块**，再对坏块二分。

    **切块的量纲是字节，不是节点数**（`TRIAL_MAX_BYTES_PER_FILE` 那段实测）。原来的
    `max_nodes_per_batch=2000` 是错的量纲：2000 个实战节点 ≈ 627KB，是 mihomo 上限
    （约 20KB）的 31 倍 ⇒ 每块都静默归零 ⇒ 被判成「全都装得上」⇒ 坏节点一个都不剔。
    现在按 `TRIAL_MAX_BYTES_TOTAL` 装箱；`max_nodes_per_batch` 只作为上界护栏。

    **成本模型（这是设计的关键，被实测教训过）**：单次试装的耗时几乎全是 mihomo 冷启动
    （~1.2 秒，与 provider 内节点数无关，也与健康检查开不开无关——关掉它只是省掉那一轮
    探测的等待）。所以本层**一次启动同时判定一批区间**（见 `_trial_batch_config`），
    把总成本从「区间数 × 1.2s」压到「批数 × 1.2s」。
    2026-09-15 run 34989917789 就是逐区间各起一次进程，7 个块里只跑完 4 个就撞上
    `timeout-minutes` 被 GitHub **硬取消**，下游三个测速 job 全 skipped —— 已抓到的
    65 个订阅、已投喂的 Sub-Store 一起报废。

    **墙钟预算（`budget_seconds`）**：即使批量判定，坏节点极多的轮次仍可能吃满预算。
    到点的降级方向是**停止排雷**：已经摘掉的名字照摘，剩下还没测的块**原样放行**
    （记 `trial_load_budget_stop`）。这比「跳过整层」好——已排掉的那部分是实打实的收益；
    也比「继续排」好——继续排会撞硬取消，连已抓到的订阅一起报废。

    四条硬约束（都踩过）：

      * **provider 文件必须写在 home 内**，否则 mihomo `level=fatal` 直接退出，
        「装不上」会被误读成「节点非法」而**误删好节点**。这里同样过 `_safe_home_dir`。
      * **判据必须排除「自己故障」**：mihomo 起不来时归因不可信，原样放行全部。
        宁可下游去扛坏节点，也不能凭一次起不来的日志删节点。
      * **判据必须带正面证据**：不能只看「日志里没有错误」——超体积时 mihomo 静默归零、
        一条错都不写，那会被读成「全都好」。见 `_trial_probe` 的实到节点数校验。
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
        'probes': 0,
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
    # 按字节装箱切块：每块的所有节点 dump 出来不超过 TRIAL_MAX_BYTES_TOTAL。
    # 单块里若第一个节点自己就超，也让它自成一块（交给二分继续切）。
    batches = []
    cur, cur_bytes = [], 0
    for p in proxies:
        nb = _trial_node_bytes(p)
        if cur and (cur_bytes + nb > TRIAL_MAX_BYTES_TOTAL or len(cur) >= batch_size):
            batches.append(cur)
            cur, cur_bytes = [], 0
        cur.append(p)
        cur_bytes += nb
    if cur:
        batches.append(cur)
    removed_set = set()
    done_batches = 0
    bad = 0
    failed = 0
    first_error = ''
    budget_stopped = False
    # 是否已经有一个在跑的试装进程可供热重载。**整轮只冷启动一次**：冷启动固定 3.01 秒
    # （等旧进程让出端口），热重载 0.03 秒，而一輪要判几十上百次——每次都冷启动的话
    # 2000 节点那轮光启动就烧掉 40×3 = 120 秒（实测 133.6s 里有 ~120s 是这个）。
    # 第一发冷启动之后，后面全部走热重载。
    warm = False
    # 探针计数以源头打点为准（见 `PROBE_COUNTER`）：冷启动与热重载在这里都只算「一次探针」，
    # 不再让调用方各自累加 `used` / `counter['rounds']`——那两个口径不一，会让摘要数字失真。
    PROBE_COUNTER['n'] = 0
    deadline = speedtest_budget_deadline(budget_seconds)
    try:
        for b_idx, chunk in enumerate(batches):
            if not chunk:
                continue
            if should_stop_for_budget(deadline):
                budget_stopped = True
                break
            # 第一关：整块一起装。装得上就是最好情况——一次探针敲定一整块。
            key = f'b{b_idx:04d}'
            failed_keys, trusted, err, used = _trial_probe([(key, chunk)], workdir,
                                                           hot=warm and TRIAL_HOT_RELOAD)
            warm = warm or TRIAL_HOT_RELOAD
            done_batches += 1
            if not trusted:
                # 归因不可信（mihomo 起不来）：这一块原样放行，继续跑其余的块。
                failed += 1
                if not first_error:
                    first_error = err or 'mihomo 起不来'
                log_progress('trial_load_batch_unresolved', start=b_idx * batch_size,
                             size=len(chunk), error=first_error)
                continue
            if key not in failed_keys:
                continue
            # 这一块装不上：批量二分定位真正的坏节点。
            bad += 1
            counter = {'rounds': 0}

            def key_of(idx, _b=b_idx):
                # 稳定且安全：同一批里不同区间不同 key（同 key 的 provider 会互相覆盖）。
                # 名字里只留数字，避免节点名带来的特殊字符问题。
                return f'{_b:04d}x{idx:04d}'

            done, removed, err = _trial_isolate(chunk, key_of, workdir,
                                                bisect_floor=bisect_floor,
                                                deadline=deadline, counter=counter)
            removed_set.update(removed)
            if err and not first_error:
                first_error = err
            if not done and not removed:
                # 一个都没摘出来且归因不了：这一块没法分辨，记进 failed 让摘要如实反映。
                failed += 1
                log_progress('trial_load_batch_unresolved', start=b_idx * batch_size,
                             size=len(chunk), error=err or 'mihomo 二分途中无法归因')
            else:
                log_progress('trial_load_batch_isolated', start=b_idx * batch_size,
                             size=len(chunk), removed=len(removed),
                             probes=counter['rounds'])
            if should_stop_for_budget(deadline):
                budget_stopped = True
                break
    except Exception as e:
        return give_up('trial_load_error', f'试装过程中异常：{e}')

    if failed and failed == done_batches and done_batches:
        return give_up('all_batches_unresolved', first_error or 'mihomo 无法完成任何一次试装')

    kept = [p for p in proxies
            if str((p or {}).get('name') or '') not in removed_set]
    # 只按名字摘节点，名字缺失/重复的不会被摘掉——如实反映在报告里，免得读者以为
    # 「removed 数」就等于「订阅少了多少」。
    dropped = total - len(kept)
    report.update({
        'kept': len(kept),
        'removed': dropped,
        'removed_names': sorted(removed_set)[:200],
        'batches': done_batches,
        'bad_batches': bad,
        'probes': PROBE_COUNTER.get('n', 0),
        'batches_failed': failed,
        'budget_stopped': budget_stopped,
        'first_error': first_error,
        'elapsed_seconds': round(time.monotonic() - started, 1),
    })
    if budget_stopped:
        # 到点停止排雷：已摘的照摘、没测到的块原样放行。**不是 skipped**——排雷确实
        # 做了，只是没做完；摘要要如实说「没排完」，而不是说「没排」。
        log_progress('trial_load_budget_stop', batches=done_batches, bad_batches=bad,
                     removed=dropped, elapsed=report['elapsed_seconds'],
                     budget=budget_seconds,
                     note='预算到点，未测的块原样放行（不是整层 skipped）')
    log_progress('trial_load_done', total=total, kept=len(kept), removed=dropped,
                 batches=done_batches, bad_batches=bad, probes=report['probes'],
                 failed=failed, budget_stopped=budget_stopped,
                 elapsed=report['elapsed_seconds'])
    if dropped:
        log_progress('trial_load_removed_samples', count=dropped,
                     samples=report['removed_names'][:20])
    return kept, report
