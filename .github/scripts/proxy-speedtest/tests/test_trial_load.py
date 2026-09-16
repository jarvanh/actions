#!/usr/bin/env python3
"""`trial_load` 的离线自检：发布前把「mihomo 装不上」的节点**精确**摘掉。

为什么需要它：mihomo 对 provider 是**全有或全无**——片里一个节点解析失败，整个 provider
的 `proxies` 就是 `[]`。它出过一次真实事故：2026-09-15 那份 13210 个节点的订阅里有一个
`short-id` 让 mihomo 报 `invalid REALITY short ID`，于是**整份订阅在下游归零**
（`provider_snapshot_collected total: 0` → `nodes_collected: 0`），整轮零产出且不报错。
健康检查那一层的分片只能把损失压到「一片 200 个」，不能消除。

它还出过第二次事故（run 34989917789）：逻辑对、但**成本设计错**——逐区间各起一次 mihomo
（每次 ~1.2 秒冷启动），一个坏块的二分要几百次启动 ⇒ 7 块只跑完 4 块就撞上 job 的
`timeout-minutes` 被硬取消，下游三个测速 job 全 skipped。所以现在改成**一次启动判定一批
区间**（每个区间一个 provider，mihomo 各自报错、可按 provider 名归属）。

坏法都很隐蔽，固化成断言：

  * **判据反了**：把「mihomo 起不来」当「这批节点有问题」⇒ 凭一次故障误删好节点；
  * **「没报错」被误判成「归因不了」**：全都装得上时日志里一条 provider 错误都没有，
    若把「无错误」当成「读不到结论」就会整层 fail-open、白跑；
  * **不收敛**：块内 ≤ floor 个还装不上时没有「整块摘掉」的出口；
  * **误伤**：摘掉整个坏块而不是块内那一个坏节点（用户要求精确到单个节点）；
  * **全好时乱剔**：判据恒真；
  * **没预算**：坏节点多时无限跑，拖到 job 硬取消（第二次事故的形态）；
  * **批内串位**：同一批里两个区间用了同一个 provider 名，判定结果会互相覆盖。

这里的假 mihomo 是**行为模型**而不是 HTTP 服务：它读当前 config 里的全部 provider，
对每个 provider 检查其节点里有没有被标记为坏的，有就**在日志里写一行 mihomo 真实格式的
报错**（带该 provider 的名字）——本层就是靠读日志判定的。这恰好复刻真实行为：坏节点让
provider 初始化失败，而 `wait_mihomo` 只等控制器就绪。

跑法：python .github/scripts/proxy-speedtest/tests/test_trial_load.py
退出码 0 = 全部通过。
"""
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import yaml  # noqa: E402

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


def nodes(names):
    return [{'name': n, 'type': 'ss', 'server': '1.1.1.1', 'port': 443,
             'cipher': 'aes-128-gcm', 'password': 'p'} for n in names]


class FakeMihomo:
    """mihomo 的行为模型（不是 HTTP 服务）。

    `bad` 是**坏节点的名字集合**；`unreachable_bad` 是「单独装得上、但有它参与就装不上」
    的那类坏节点（本层对它们只能退化成整块摘掉）。`broken` = mihomo 本身起不来
    （用来验 fail-open）。

    **同时建模了体积上限**（`volume_model=True`）：真机实测一份 config 里所有 provider
    文件加起来超过约 20KB 时，mihomo 会把它们**静默装到 0 个、不写任何 error**
    （见 `TRIAL_MAX_BYTES_PER_FILE` 那段）。这正是本条链路上最隐蔽的失败形态——
    「没有报错」被读成「全都好」。假实现必须能复现它，否则回归守不住。
    """

    def __init__(self, af, workdir):
        self.af = af
        self.workdir = workdir
        self.bad = set()
        self.unreachable_bad = set()
        self.broken = False
        self.starts = 0
        self.providers_seen = []  # 每次启动时的 {provider 名: 节点名列表}
        self.loaded_counts = []  # 每次启动时「实际装到几个」：{provider 名: 数量}
        # 延迟写日志（秒）：模拟真实 mihomo「控制器先就绪、provider 随后才初始化完」。
        # 真机实测 `wait_mihomo` 0.093 秒就返回，而错误行在 0.143 秒才写——只差 50ms，
        # 但足以让第一次之后的探针全都读到空日志（见第 14 组）。
        self.log_delay = 0.0
        # 是否模拟「总量超限 ⇒ 全部静默归零」。真机阈值约 20KB；用例里压到很小的值，
        # 以便用小数据量触发（同 `bisect_floor` 的处理方式）。
        self.volume_model = True
        self.volume_limit = 20 * 1024

    def start(self, wait_timeout=None):
        self.starts += 1
        return self._load()

    def _load(self):
        """按当前 config 重算结论（冷启动与热重载共用这段，只差是否计入 `starts`）。"""
        if self.broken:
            raise RuntimeError('mihomo refused to start')
        cfg = yaml.safe_load(self.af.MIHOMO_CONFIG.read_text(encoding='utf-8')) or {}
        providers = cfg.get('proxy-providers') or {}
        # 先量总量：越界时 mihomo 对**所有** provider 静默归零，且一条 error/fatal 都不打。
        total_bytes = 0
        for pconf in providers.values():
            path = pathlib.Path(pconf.get('path') or '')
            if path.exists():
                total_bytes += path.stat().st_size
        oversize = self.volume_model and total_bytes > self.volume_limit
        seen = {}
        counts = {}
        lines = []
        for pname, pconf in providers.items():
            # 真机为**每个** provider（好的坏的）都先写一行 `Start initial provider <名>`，
            # 紧接着才是坏 provider 的 error 行。实现靠「Start 行齐了」判断结论已落盘。
            lines.append(f'level=info msg="Start initial provider {pname}"')
            path = pathlib.Path(pconf.get('path') or '')
            loaded = []
            if path.exists() and not oversize:
                loaded = (yaml.safe_load(path.read_text(encoding='utf-8')) or {}).get('proxies') or []
            names = [p.get('name') for p in loaded]
            seen[pname] = [p.get('name') for p in
                           ((yaml.safe_load(path.read_text(encoding='utf-8')) or {}).get('proxies') or [])
                           ] if path.exists() else []
            counts[pname] = len(names)
            for idx, name in enumerate(names):
                if name in self.bad or (name in self.unreachable_bad and len(names) > 1):
                    lines.append(f'level=error msg="initial proxy provider {pname} error: '
                                 f'proxy {idx} error: invalid REALITY short ID"')
                    break
        body = '\n'.join(lines) + ('\n' if lines else '')
        self.counts_override = counts

        def write():
            self.af.MIHOMO_LOG.write_text(body, encoding='utf-8')

        if self.log_delay > 0:
            import threading
            threading.Timer(self.log_delay, write).start()
        else:
            write()
        self.providers_seen.append(seen)
        return {'version': 'fake'}


def run_trial(af, proxies, workdir, bad=(), unreachable_bad=(), broken=False, **kw):
    """跑一次 trial_load，返回 (保留的节点, 报告, 事件列表, 假 mihomo 状态)。

    `_safe_home_dir` 也被换掉：本自检验的是**试装语义**，不是路径守卫（那在
    test_alive_filter.py 里有专测）。不换掉的话所有 workdir 都会被改落到 `/root/...`，
    临时目录里的断言全落空——而且这是本机跑才有的现象，很容易被误读成实现坏了。

    `bisect_floor` 默认压到 1：实现里那个 8 是给生产环境的折中（多跑几轮 vs 多摘几个），
    而本自检要断言的是**定位精度**——用 floor=1 才能验「精确到单个节点」这条主判据。
    floor 本身的语义另有专门用例（第 4 组）。
    """
    kw.setdefault('bisect_floor', 1)
    saved = (af._start_mihomo, af.log_progress, af._safe_home_dir,
             af.ensure_local_mihomo, af.MIHOMO_LOG, af._trial_provider_counts,
             af._trial_reload_config)
    events = []
    fake = FakeMihomo(af, workdir)
    fake.bad = set(bad)
    fake.unreachable_bad = set(unreachable_bad)
    fake.broken = broken
    af._start_mihomo = fake.start
    af.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
    af.ensure_local_mihomo = lambda: 'fake'
    af.MIHOMO_LOG = workdir / 'mihomo.log'
    # 「正证」由假 mihomo 提供：它按同一套体积模型算出每个 provider 实到几个节点。
    af._trial_provider_counts = lambda opener=None, timeout=10: dict(
        getattr(fake, 'counts_override', {}))
    # 热重载也由假实现承接：真机上是 `PUT /configs?force=true` 让进程重读 config，
    # 假实现里等价于「按当前 config 重算一遍结论」。**必须给这个桩**，否则热重载一律
    # 失败、每次都退回冷启动，`fake.starts` 就测不出「只冷启动一次」（第 17 组会假红）。
    def fake_reload(timeout=15):
        fake.reloads += 1
        fake._load()
        return True

    fake.reloads = 0
    af._trial_reload_config = fake_reload
    workdir.mkdir(parents=True, exist_ok=True)

    def keep_dir(base):
        p = pathlib.Path(base)
        p.mkdir(parents=True, exist_ok=True)
        return p

    af._safe_home_dir = keep_dir
    try:
        kept, report = af.trial_load(proxies, workdir=workdir, **kw)
    finally:
        (af._start_mihomo, af.log_progress, af._safe_home_dir,
         af.ensure_local_mihomo, af.MIHOMO_LOG, af._trial_provider_counts,
         af._trial_reload_config) = saved
    return kept, report, events, fake


def names_of(proxies):
    return [p['name'] for p in proxies]


def main():
    import alive_filter as af

    tmp = pathlib.Path(tempfile.mkdtemp(prefix='trial-load-test-'))
    print('== 1. 全好时一个都不剔（判据不得恒真，也不得把「无报错」当归因失败）==')
    # 「一条 provider 错误都没有」= 全都装得上，这是**正常的好结果**。若把它当成
    # 「读不到结论」就会整层 fail-open（removed=0 但 skipped=True），等于白跑。
    allnodes = nodes([f'n{i}' for i in range(20)])
    kept, rep, _, fake = run_trial(af, allnodes, tmp / 't1', max_nodes_per_batch=20)
    check(names_of(kept) == names_of(allnodes),
          f'20 个全好 ⇒ 原样保留（实际剔了 {rep["removed"]} 个）')
    check(rep['removed'] == 0 and rep['skipped'] is False,
          f'报告如实：removed=0 且未 skipped（实际 {rep["removed"]}/{rep["skipped"]}）')
    check(fake.starts == 1, f'全好只启动 1 次（实际 {fake.starts}）——多起就是白烧')

    print('== 2. 单个坏节点：精确到它、其余全留 ==')
    allnodes = nodes([f'n{i}' for i in range(20)])
    kept, rep, ev, fake = run_trial(af, allnodes, tmp / 't2', bad=['n13'],
                                    max_nodes_per_batch=20)
    check('n13' not in names_of(kept), '坏节点被摘掉')
    check(names_of(kept) == [n for n in names_of(allnodes) if n != 'n13'],
          f'其余 19 个原样保留（实际 {len(kept)} 个）——多剔就是误伤')
    check(rep['removed'] == 1 and rep['removed_names'] == ['n13'],
          f'报告带出被剔的名字（实际 {rep["removed_names"]}）')
    check(rep['skipped'] is False, '这是正常完成，不是 skipped')
    check(any(e['stage'] == 'trial_load_removed_samples' for e in ev),
          f'打了剔除样例日志（实际 {[e["stage"] for e in ev]}）')

    print('== 3. 多个坏节点同块：全部挑出来，不整块丢 ==')
    allnodes = nodes([f'n{i}' for i in range(16)])
    kept, rep, _, _ = run_trial(af, allnodes, tmp / 't3',
                                bad=['n2', 'n5', 'n11'], max_nodes_per_batch=16)
    check(sorted(rep['removed_names']) == ['n11', 'n2', 'n5'],
          f'三个坏节点都挑出来（实际 {rep["removed_names"]}）')
    check(len(kept) == 13, f'其余 13 个保留（实际 {len(kept)}）')

    print('== 4. 兜底出口：块内 ≤ floor 个还装不上时整块摘掉（不得无限对折）==')
    # 「有它参与才装不上」的坏法会让二分在最后几个节点上打转，必须有个出口收敛。
    allnodes = nodes([f'n{i}' for i in range(12)])
    kept, rep, _, _ = run_trial(af, allnodes, tmp / 't4',
                                unreachable_bad=['n7'], max_nodes_per_batch=12,
                                bisect_floor=3)
    check(rep['skipped'] is False, '没有卡死、也没有 fail-open')
    check(rep['removed'] >= 1, f'至少摘掉一个（实际 {rep["removed"]}）')
    check(rep['probes'] <= 40,
          f'收敛在有限次试装内（实际 {rep["probes"]} 次）——无限对折就是没兜底')
    check(len(kept) + rep['removed'] == len(allnodes), '保留数 + 剔除数 = 输入数')

    print('== 5. 切块：坏节点只污染它所在那块 ==')
    # 40 个节点切成 4 块（每块 10）。n25 在第三块：只有第三块会进二分，前两块一次过。
    allnodes = nodes([f'n{i}' for i in range(40)])
    kept, rep, _, fake = run_trial(af, allnodes, tmp / 't5', bad=['n25'],
                                   max_nodes_per_batch=10)
    check(rep['batches'] == 4, f'切成 4 块（实际 {rep["batches"]}）')
    check(rep['bad_batches'] == 1, f'只有 1 块有问题（实际 {rep["bad_batches"]}）')
    check(rep['removed_names'] == ['n25'], f'精确到 n25（实际 {rep["removed_names"]}）')
    check(len(kept) == 39, f'其余 39 个保留（实际 {len(kept)}）')
    check(fake.starts < 20,
          f'没有退化成逐区间启动（实际 {fake.starts} 次）')

    print('== 6. 批量判定：一次启动里各区间各占一个 provider，名字不串位 ==')
    # 这是把成本从「区间数 × 冷启动」压到「层数 × 冷启动」的关键，也是最容易写错的
    # 地方——同层的两个区间若用了同一个 provider 名，判定结果会互相覆盖。
    allnodes = nodes([f'n{i}' for i in range(64)])
    kept, rep, _, fake = run_trial(af, allnodes, tmp / 't6',
                                   bad=['n3', 'n40'], max_nodes_per_batch=64,
                                   bisect_floor=1)
    check(sorted(rep['removed_names']) == ['n3', 'n40'],
          f'两个坏节点都精确摘掉（实际 {rep["removed_names"]}）')
    # 至少有一层是「一份 config 里放了不只一个 provider」——否则就是逐区间版。
    widest = max((len(p) for p in fake.providers_seen), default=0)
    check(widest > 1, f'有同一层同时判定多个 provider（实际最多 {widest} 个）')
    check(fake.starts < 40,
          f'启动次数远小于「逐区间」（实际 {fake.starts} 次，逐区间需 ~2·log2(64)·…）')

    print('== 7. fail-open：mihomo 起不来 ⇒ 原样放行全部、一个都不剔 ==')
    allnodes = nodes([f'n{i}' for i in range(8)])
    kept, rep, ev, _ = run_trial(af, allnodes, tmp / 't7', broken=True,
                                 max_nodes_per_batch=8)
    check(rep['skipped'] is True and rep['skip_reason'] == 'all_batches_unresolved',
          f'起不来 ⇒ skipped（实际 {rep.get("skip_reason")}）')
    check(names_of(kept) == names_of(allnodes),
          '原样放行全部——起不来绝不是「节点有问题」的证据')
    check(rep['removed'] == 0, '一个都不剔')
    check(any(e['stage'] == 'trial_load_skipped' for e in ev),
          f'打了 skipped 日志（实际 {[e["stage"] for e in ev]}）')

    print('== 8. 墙钟预算：到点停止排雷，已摘的照摘、未测的块原样放行 ==')
    # 第二次事故（run 34989917789）的形态：逻辑对、但成本失控撞 job 硬取消。
    #
    # ⚠️ 不能用 0 / 负数当预算：`speedtest_budget_deadline` 按设计把非正数归一为「不限」
    # （与 `should_stop_for_budget` 同一口径），那样恒不触发，用例会假过。
    # 所以给一个**极小但正**的预算 + 足够多的块：前几块跑完，后面的必然到点。
    # 每块都要真起一次 mihomo（假实现），所以块数够多就能稳定越界。
    def slow_start(wait_timeout=None):
        # 让每次「启动」都吃掉一点时间，模拟真实的冷启动 —— 否则纯 Python 的假实现
        # 快到预算永远追不上（本用例曾在 4 块时假失败过）。
        import time as _t
        _t.sleep(0.05)
        return fake_big.start(wait_timeout)

    allnodes = nodes([f'n{i}' for i in range(600)])
    saved_start = af._start_mihomo
    events8 = []
    fake_big = FakeMihomo(af, tmp / 't8')
    fake_big.bad = {'n5'}
    # 这组靠「每块都真起一次」来耗预算，块要小：假实现的体积模型会给每块算总量，
    # 块小 ⇒ 不会因为超限而整块归零（否则归因失败会提前收手、走不到 budget_stop）。
    fake_big.volume_limit = 10 ** 9
    af._start_mihomo = slow_start
    saved_log = af.log_progress
    af.log_progress = lambda stage, **fields: events8.append(dict(fields, stage=stage))
    saved_home = af._safe_home_dir
    af._safe_home_dir = lambda base: (pathlib.Path(base).mkdir(parents=True, exist_ok=True),
                                      pathlib.Path(base))[1]
    (tmp / 't8').mkdir(parents=True, exist_ok=True)
    saved_log_path = af.MIHOMO_LOG
    af.MIHOMO_LOG = tmp / 't8' / 'mihomo.log'
    saved_counts = af._trial_provider_counts
    af._trial_provider_counts = lambda opener=None, timeout=10: dict(
        getattr(fake_big, 'counts_override', {}))
    try:
        kept, rep = af.trial_load(allnodes, workdir=tmp / 't8',
                                  max_nodes_per_batch=10, budget_seconds=1)
    finally:
        af._start_mihomo = saved_start
        af.log_progress = saved_log
        af._safe_home_dir = saved_home
        af.MIHOMO_LOG = saved_log_path
        af._trial_provider_counts = saved_counts
    check(rep['budget_stopped'] is True,
          f'到点必须记 budget_stopped（实际 {rep["budget_stopped"]}）')
    check(any(e['stage'] == 'trial_load_budget_stop' for e in events8),
          f'打了 budget_stop 日志（实际 {[e["stage"] for e in events8]}）')
    check(rep['skipped'] is False,
          '到点**不是** skipped——排雷做了，只是没做完（措辞要如实）')
    check(len(kept) + rep['removed'] == len(allnodes), '保留数 + 剔除数 = 输入数（没漏没重）')
    check(rep['batches'] < 60, f'确实中途停了、没跑完全部 60 块（实际 {rep["batches"]}）')

    print('== 9. 预算负向对照：给足预算时必须真把坏节点摘掉 ==')
    allnodes = nodes([f'n{i}' for i in range(40)])
    kept, rep, _, _ = run_trial(af, allnodes, tmp / 't9', bad=['n5'],
                                max_nodes_per_batch=10, budget_seconds=1)
    check(rep['budget_stopped'] is False, '预算不限时不该记 budget_stopped')
    check(rep['removed_names'] == ['n5'],
          f'给足预算就精确摘掉（实际 {rep["removed_names"]}）——否则「到点降级」是假的')

    print('== 10. 边界：空输入不炸、也不必起 mihomo ==')
    started = []
    saved_start = af._start_mihomo
    af._start_mihomo = lambda *a, **k: started.append(1)
    try:
        kept, rep = af.trial_load([], workdir=tmp / 't10')
    finally:
        af._start_mihomo = saved_start
    check(kept == [] and rep['total'] == 0, '空输入返回空')
    check(started == [], '空输入不起 mihomo')

    print('== 11. 写进 provider 的必须是这批节点的全量（不是「已判好」的子集）==')
    # 与过滤层同一原则：若只喂「已知好」的节点，就等于用结论当输入，循环论证，
    # 而且永远发现不了「有它参与才装不上」的坏节点。
    allnodes = nodes([f'n{i}' for i in range(4)])
    _, _, _, fake = run_trial(af, allnodes, tmp / 't11', max_nodes_per_batch=4)
    first_seen = fake.providers_seen[0] if fake.providers_seen else {}
    all_names = [n for names in first_seen.values() for n in names]
    check(sorted(all_names) == ['n0', 'n1', 'n2', 'n3'],
          f'第一次试装就是全量 4 个（实际 {sorted(all_names)}）')

    print('== 12. provider 文件必须落在 mihomo home 内（越界会误删好节点）==')
    home = pathlib.Path(tempfile.mkdtemp(prefix='tl-home-'))
    outside = pathlib.Path(tempfile.mkdtemp(prefix='tl-outside-')) / 'trial-load'
    saved_cfg = af.MIHOMO_CONFIG
    af.MIHOMO_CONFIG = home / 'config.yaml'
    try:
        events = []
        saved_log = af.log_progress
        af.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
        try:
            got = af._safe_home_dir(outside)
        finally:
            af.log_progress = saved_log
        check(home in got.parents or got.parent == home,
              f'home 外的工作目录被改落 home 内（实际 {got}）')
        check(any(e['stage'] == 'alive_filter_workdir_relocated' for e in events),
              '换地方时打日志说明原因')
    finally:
        af.MIHOMO_CONFIG = saved_cfg

    print('== 13. 试装 provider 关掉健康检查（判据不靠它，开着只是白等一轮探测）==')
    saved_cfg = af.MIHOMO_CONFIG
    probe_home = tmp / 't13'
    probe_home.mkdir(parents=True, exist_ok=True)
    af.MIHOMO_CONFIG = probe_home / 'config.yaml'
    try:
        run_trial(af, nodes(['a']), probe_home, max_nodes_per_batch=1)
        cfg = yaml.safe_load((probe_home / 'config.yaml').read_text(encoding='utf-8')) or {}
    finally:
        af.MIHOMO_CONFIG = saved_cfg
    providers = cfg.get('proxy-providers') or {}
    check(len(providers) >= 1, f'配置里有 provider（实际 {list(providers)}）')
    hcs = [(p or {}).get('health-check') or {} for p in providers.values()]
    check(all(h.get('enable') is False for h in hcs),
          f'健康检查必须关（实际 {[h.get("enable") for h in hcs]}）——开着每次启动多等一轮探测')
    paths = [str((p or {}).get('path') or '') for p in providers.values()]
    check(all(p.endswith('.yaml') for p in paths), f'provider 指向 .yaml（实际 {paths}）')

    print('== 14. 日志竞态：provider 结论晚于控制器就绪时，必须等齐再读（不得误判成装得上）==')
    # 真机踩过的坑（2026-09-16）：mihomo 先让控制器监听、再逐个初始化 provider。
    # 实测 0.093s 控制器就绪、0.143s 才写错误行，`wait_mihomo` 拿到 `/version` 就返回
    # ⇒ 第一次探针读到错误、**第二次起读到空白** ⇒ 坏节点「消失」、整层白跑。
    # 这里把写日志推迟到控制器就绪之后（假实现里即 start 返回之后），复现同一时序：
    # 若实现不等结论落盘，第 2 次探针必然看到 failed=set()。
    allnodes = nodes([f'n{i}' for i in range(8)])
    (tmp / 't14').mkdir(parents=True, exist_ok=True)
    base = FakeMihomo(af, tmp / 't14b')
    base.bad = {'n5'}
    base.log_delay = 0.15
    saved_start = af._start_mihomo
    saved_counts = af._trial_provider_counts
    af._start_mihomo = base.start
    af._trial_provider_counts = lambda opener=None, timeout=10: dict(
        getattr(base, 'counts_override', {}))
    try:
        first = af._trial_probe([('late', allnodes)], tmp / 't14')
        # 第二次针对同一批再探一次：这才是回归真正暴露的地方。
        second = af._trial_probe([('late', allnodes)], tmp / 't14')
    finally:
        af._start_mihomo = saved_start
        af._trial_provider_counts = saved_counts
    check(first[0] == {'late'} and first[1] is True,
          f'第 1 次探针就归到坏区间（实际 {first[0]}/{first[1]}）')
    check(second[0] == {'late'} and second[1] is True,
          f'第 2 次探针同样归到坏区间（实际 {second[0]}/{second[1]}）'
          f'——不等结论落盘就会退化成「全都装得上」')

    print('== 15. 体积超限：mihomo 静默归零时不得读成「全都装得上」（本轮真正的病根）==')
    # 真机实测：一份 config 里 provider 文件加起来超过约 20KB，mihomo 把**所有** provider
    # 静默装到 0 个，不写任何 error/fatal。旧判据「日志里没有 provider 错误 ⇒ 都装得上」
    # 在这种情况会把整批坏节点放过（实测 2000 个/批时 8 个坏节点一个都没剔出来）。
    # 这里把假 mihomo 的阈值压小，逼出同一个形态。
    allnodes = nodes([f'n{i}' for i in range(200)])
    (tmp / 't15').mkdir(parents=True, exist_ok=True)
    vol = FakeMihomo(af, tmp / 't15')
    vol.bad = {'n7', 'n120'}
    vol.volume_limit = 2000  # 200 个节点远大于它 ⇒ 必然整批归零
    saved_start = af._start_mihomo
    saved_counts = af._trial_provider_counts
    af._start_mihomo = vol.start
    af._trial_provider_counts = lambda opener=None, timeout=10: dict(
        getattr(vol, 'counts_override', {}))
    try:
        failed, trusted, err, _ = af._trial_probe([('oversize', allnodes)], tmp / 't15')
    finally:
        af._start_mihomo = saved_start
        af._trial_provider_counts = saved_counts
    check('oversize' in failed,
          f'「装到 0 个」必须判成装不上（实际 failed={failed}）——读成好就是整批漏剔')
    check(trusted is True, '这是可信的归因（正证拿到了），不是「归因不了」')
    check('0/' in err or '未出现' in err,
          f'真因要能说清是「装到几个」（实际 {err[:80]!r}）——否则又是无解之谜')

    print('== 16. 但体积必须靠「切块」提前避免，不能靠这条兜底 ==')
    # 归因对了不代表能定位：整批归零时每个区间都「装不上」，二分只会一路切到 floor 全摘。
    # 所以正向要求是——正常流程里**根本不该出现超限的批**。假 mihomo 的阈值就用真机那个
    # 量级（20KB），于是「出现了 trial_load_batch_oversize」= 切块没管住体积。
    allnodes = nodes([f'n{i}' for i in range(300)])
    kept, rep, ev, _ = run_trial(af, allnodes, tmp / 't16', bad=['n9'])
    oversize_events = [e for e in ev if e['stage'] == 'trial_load_batch_oversize']
    check(rep['skipped'] is False and rep['removed_names'] == ['n9'],
          f'300 个节点、1 个坏节点要能精确摘掉（实际 {rep["removed_names"]}/{rep["skipped"]}）')
    check(oversize_events == [],
          f'正常流程里不该出现超限批（实际 {len(oversize_events)} 次）——切块没生效')
    check(rep['batches'] > 1,
          f'300 个节点必须被切成多块（实际 {rep["batches"]} 块）——按字节切块的直接证据')

    print('== 17. 热重载：整轮只冷启动一次，之后不得再起进程 ==')
    # 冷启动固定 3.01 秒（等旧进程让出端口），热重载 0.03 秒，而一轮要判几十上百次。
    # 这条用例守的是「别退回每次冷启动」：300 个节点切多块 + 一个坏块的二分，
    # 探针次数远多于 1，但 `fake.starts`（= 真起进程的次数）必须只有 1。
    allnodes = nodes([f'n{i}' for i in range(300)])
    probe_calls = []
    saved_probe = af._trial_probe

    def counting_probe(items, workdir, opener=None, hot=False):
        probe_calls.append(hot)
        return saved_probe(items, workdir, opener=opener, hot=hot)

    af._trial_probe = counting_probe
    try:
        kept, rep, ev17, fake17 = run_trial(af, allnodes, tmp / 't17', bad=['n9'])
    finally:
        af._trial_probe = saved_probe
    check(fake17.starts == 1,
          f'整轮只冷启动 1 次（实际 {fake17.starts} 次）——每次探针都起进程就退回 3 秒/次')
    check(fake17.reloads == len(probe_calls) - 1,
          f'除第一发外每次探针都走热重载（热重载 {fake17.reloads} 次 / 探针 '
          f'{len(probe_calls)} 次）——按 3 秒/次算这就是几十秒的差别')
    check(len(probe_calls) > 1,
          f'确实跑了多次探针（实际 {len(probe_calls)} 次）——只跑 1 次说明用例没覆盖二分')
    check(probe_calls[0] is False and all(h is True for h in probe_calls[1:]),
          f'第 1 发冷启动、其余全热重载（实际 {probe_calls}）')
    check(rep['probes'] == len(probe_calls),
          f'报告 probes 与真实探针数一致（报告 {rep["probes"]} / 真实 {len(probe_calls)}）'
          f'——口径不一致会让摘要数字失真')
    check(rep['removed_names'] == ['n9'],
          f'热重载路径的判定结果与冷启动一致（实际 {rep["removed_names"]}）')

    print('== 18. 热重载失败要退回冷启动，不能把整批判成「不可信」 ==')
    # 热重载要求进程还在跑。若它挂了（重载返回失败），正确反应是冷启动救回来，
    # 而不是整批 fail-open——后者会让「mihomo 崩了一次」变成「整轮不排雷」。
    reload_calls = []
    saved_reload = af._trial_reload_config
    saved_start = af._start_mihomo
    fake18 = FakeMihomo(af, tmp / 't18')
    fake18.bad = {'n9'}
    started = []
    # 第一次冷启动成功、后续热重载一律失败 ⇒ 必须靠冷启动继续完成二分。
    af._start_mihomo = lambda *a, **k: (started.append(1), fake18.start(*a, **k))[1]
    af._trial_reload_config = lambda timeout=15: (reload_calls.append(1), False)[1]
    saved_counts = af._trial_provider_counts
    af._trial_provider_counts = lambda opener=None, timeout=10: dict(
        getattr(fake18, 'counts_override', {}))
    try:
        kept, rep = af.trial_load(allnodes, workdir=tmp / 't18')
    finally:
        af._trial_reload_config = saved_reload
        af._start_mihomo = saved_start
        af._trial_provider_counts = saved_counts
    check(reload_calls and len(reload_calls) > 1,
          f'确实走了热重载路径（实际 {len(reload_calls)} 次）')
    check(rep['skipped'] is False,
          f'重载全失败也要靠冷启动跑完（实际 skipped={rep["skipped"]}）')
    check(rep['removed_names'] == ['n9'],
          f'结果仍然精确（实际 {rep["removed_names"]}）——退回冷启动不能丢判定')

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
