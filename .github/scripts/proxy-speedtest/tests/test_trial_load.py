#!/usr/bin/env python3
"""`trial_load` 的离线自检：发布前把「mihomo 装不上」的节点**精确**摘掉。

为什么需要它：mihomo 对 provider 是**全有或全无**——片里一个节点解析失败，整个 provider
的 `proxies` 就是 `[]`。它出过一次真实事故：2026-09-15 那份 13210 个节点的订阅里有一个
`short-id` 让 mihomo 报 `invalid REALITY short ID`，于是**整份订阅在下游归零**
（`provider_snapshot_collected total: 0` → `nodes_collected: 0`），整轮零产出且不报错。
健康检查那一层的分片只能把损失压到「一片 200 个」，不能消除。

所以发布前试装一遍，坏节点二分定位到单个、只摘它。它的坏法都很隐蔽，固化成断言：

  * **判据反了**：把「mihomo 起不来」当成「这批节点有问题」⇒ 凭一次故障误删好节点；
  * **不收敛**：二分在两个节点上无限对折（没有「块内 ≤ N 个就整块摘掉」的出口）；
  * **误伤**：摘掉整个坏块而不是块内那一个坏节点（用户明确要求精确到单个节点）；
  * **全好时乱剔**：没坏节点却剔掉了东西（判据恒真）；
  * **摘光了不兜底**：判据失效导致全剔 ⇒ 零节点发布，比不排雷糟得多。

这里的假 mihomo 不是 HTTP 服务，而是**行为模型**：`_start_mihomo` 被换成一个检查
「当前写进 trial.yaml 的节点集合里有没有被标记为坏的」，有就**在日志里写一行** mihomo
真实格式的报错（本层就是靠读日志判定的）、并让它「起不来」；没有就正常返回。这恰好复刻
真实行为——坏节点让 provider 初始化失败，而 `wait_mihomo` 只等控制器就绪。

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
    """

    def __init__(self, af, workdir):
        self.af = af
        self.workdir = workdir
        self.bad = set()
        self.unreachable_bad = set()
        self.broken = False
        self.starts = 0
        self.installs = []  # 每次试装时的节点名列表，供断言调用次数与内容

    def start(self, wait_timeout=None):
        self.starts += 1
        if self.broken:
            raise RuntimeError('mihomo refused to start')
        text = ''
        path = self.workdir / self.af.TRIAL_FILE_NAME
        loaded = []
        if path.exists():
            loaded = (yaml.safe_load(path.read_text(encoding='utf-8')) or {}).get('proxies') or []
        names = [p.get('name') for p in loaded]
        self.installs.append(names)
        # 复刻真实日志格式：坏节点让 provider 初始化失败，出结论后跳过该 provider。
        for idx, name in enumerate(names):
            if name in self.bad or (name in self.unreachable_bad and len(names) > 1):
                text = (f'level=error msg="initial proxy provider trial error: '
                        f'proxy {idx} error: invalid REALITY short ID"\n')
                break
        self.af.MIHOMO_LOG.write_text(text, encoding='utf-8')
        if text:
            # provider 装不上时 mihomo 仍会起控制器（这正是判据能成立的原因），
            # 但这里为了逼调用方**只靠日志**判定，照样让它「就绪」。
            return {'version': 'fake'}
        return {'version': 'fake'}


def run_trial(af, proxies, workdir, bad=(), unreachable_bad=(), broken=False, **kw):
    """跑一次 trial_load，返回 (保留的节点, 报告, 事件列表, 假 mihomo 状态)。

    `_safe_home_dir` 也被换掉：本自检验的是**试装语义**，不是路径守卫（那在
    test_alive_filter.py 里有专测）。不换掉的话所有 workdir 都会被改落到 `/root/...`，
    临时目录里的断言全落空——而且这是本机跑才有的现象，很容易被误读成实现坏了。

    `bisect_floor` 默认压到 2：实现里那个 8 是给生产环境的折中（多找几轮 vs 多摘几个），
    而本自检要断言的是**定位精度**——用 floor=1 才能验「精确到单个节点」这条主判据。
    floor 本身的语义另有专门用例（第 4 组）。
    """
    kw.setdefault('bisect_floor', 1)
    saved = (af._start_mihomo, af.log_progress, af._safe_home_dir,
             af.ensure_local_mihomo, af.MIHOMO_LOG)
    events = []
    fake = FakeMihomo(af, workdir)
    fake.bad = set(bad)
    fake.unreachable_bad = set(unreachable_bad)
    fake.broken = broken
    af._start_mihomo = fake.start
    af.log_progress = lambda stage, **fields: events.append(dict(fields, stage=stage))
    af.ensure_local_mihomo = lambda: 'fake'
    af.MIHOMO_LOG = workdir / 'mihomo.log'
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
         af.ensure_local_mihomo, af.MIHOMO_LOG) = saved
    return kept, report, events, fake


def names_of(proxies):
    return [p['name'] for p in proxies]


def main():
    import alive_filter as af

    tmp = pathlib.Path(tempfile.mkdtemp(prefix='trial-load-test-'))
    try:
        print('== 1. 全好时一个都不剔（判据不得恒真）==')
        allnodes = nodes([f'n{i}' for i in range(20)])
        kept, rep, _, fake = run_trial(af, allnodes, tmp / 't1', max_nodes_per_batch=20)
        check(names_of(kept) == names_of(allnodes),
              f'20 个全好 ⇒ 原样保留（实际剔了 {rep["removed"]} 个）')
        check(rep['removed'] == 0 and rep['skipped'] is False,
              f'报告如实：removed=0 且未 skipped（实际 {rep["removed"]}/{rep["skipped"]}）')
        check(fake.starts == 1, f'全好只试装 1 次（实际 {fake.starts}）——多起就是白烧')

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
        # 「有它参与才装不上」的坏法会让探针二分在最后几个节点上打转，必须有个出口
        # 收敛。用 floor=3 直接验这个出口的边界：块缩到 3 还装不上 ⇒ 摘这 3 个。
        allnodes = nodes([f'n{i}' for i in range(12)])
        kept, rep, _, _ = run_trial(af, allnodes, tmp / 't4',
                                    unreachable_bad=['n7'], max_nodes_per_batch=12,
                                    bisect_floor=3)
        check(rep['skipped'] is False, '没有卡死、也没有 fail-open')
        check(rep['removed'] >= 1, f'至少摘掉一个（实际 {rep["removed"]}）')
        check(rep['rounds'] <= 40,
              f'收敛在有限轮内（实际 {rep["rounds"]} 轮）——无限对折就是没兜底')
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
        # 前三块各 1 次试装；第三块 1 次整块 + 二分若干。远小于「逐节点 40 次」。
        check(fake.starts < 20,
              f'没有退化成逐节点试装（实际 {fake.starts} 次）')

        print('== 6. fail-open：mihomo 起不来 ⇒ 原样放行全部、一个都不剔 ==')
        allnodes = nodes([f'n{i}' for i in range(8)])
        kept, rep, ev, _ = run_trial(af, allnodes, tmp / 't6', broken=True,
                                     max_nodes_per_batch=8)
        check(rep['skipped'] is True and rep['skip_reason'] == 'all_batches_unresolved',
              f'起不来 ⇒ skipped（实际 {rep.get("skip_reason")}）')
        check(names_of(kept) == names_of(allnodes),
              '原样放行全部——起不来绝不是「节点有问题」的证据')
        check(rep['removed'] == 0, '一个都不剔')
        check(any(e['stage'] == 'trial_load_skipped' for e in ev),
              f'打了 skipped 日志（实际 {[e["stage"] for e in ev]}）')

        print('== 7. 日志里没有 provider 失败特征时，不得当成「节点有问题」==')
        # mihomo 起得来但日志干净（既没报错也没有 provider 记录）——归因不了，
        # 必须当自己故障 fail-open，而不是「没报错就是好的」更不是「全剔」。
        saved = af.MIHOMO_LOG
        allnodes = nodes(['a', 'b'])
        try:
            af.MIHOMO_LOG = tmp / 't7' / 'mihomo.log'
            af.MIHOMO_LOG.parent.mkdir(parents=True, exist_ok=True)

            def start_no_log(wait_timeout=None):
                af.MIHOMO_LOG.write_text('', encoding='utf-8')
                return {'version': 'fake'}

            saved_start = af._start_mihomo
            af._start_mihomo = start_no_log
            kept, rep = af.trial_load(allnodes, workdir=tmp / 't7', max_nodes_per_batch=2)
            af._start_mihomo = saved_start
        finally:
            af.MIHOMO_LOG = saved
        check(names_of(kept) == ['a', 'b'],
              f'日志干净 ⇒ 原样保留（实际 {names_of(kept)}）——不得凭「没报错」剔节点')

        print('== 8. 边界：空输入不炸、也不必起 mihomo ==')
        started = []
        saved_start = af._start_mihomo
        af._start_mihomo = lambda *a, **k: started.append(1)
        try:
            kept, rep = af.trial_load([], workdir=tmp / 't8')
        finally:
            af._start_mihomo = saved_start
        check(kept == [] and rep['total'] == 0, '空输入返回空')
        check(started == [], '空输入不起 mihomo')

        print('== 9. 写进 provider 的必须是这批节点的全量（不是「已判好」的子集）==')
        # 与过滤层同一原则：若只喂「已知好」的节点，就等于用结论当输入，循环论证，
        # 而且永远发现不了「有它参与才装不上」的坏节点。
        allnodes = nodes([f'n{i}' for i in range(4)])
        _, _, _, fake = run_trial(af, allnodes, tmp / 't9', max_nodes_per_batch=4)
        check(fake.installs[0] == ['n0', 'n1', 'n2', 'n3'],
              f'第一次试装就是全量 4 个（实际 {fake.installs[0]}）')

        print('== 10. provider 文件必须落在 mihomo home 内（越界会误删好节点）==')
        # 落 home 外 ⇒ mihomo level=fatal 秒退 ⇒ 「装不上」⇒ 判据失效、误删好节点。
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

        print('== 11. 试装配置与下游逐字一致（lazy/expected-status/health url）==')
        cfg_path = af.MIHOMO_CONFIG
        saved_cfg = af.MIHOMO_CONFIG
        saved_home = tmp / 't11'
        saved_home.mkdir(parents=True, exist_ok=True)
        af.MIHOMO_CONFIG = saved_home / 'config.yaml'
        try:
            allnodes = nodes(['a'])
            run_trial(af, allnodes, saved_home, max_nodes_per_batch=1)
            cfg = yaml.safe_load((saved_home / 'config.yaml').read_text(encoding='utf-8')) or {}
        finally:
            af.MIHOMO_CONFIG = saved_cfg
        providers = cfg.get('proxy-providers') or {}
        check(list(providers) == ['trial'],
              f'只有一个试装 provider（实际 {list(providers)}）')
        hc = (providers.get('trial') or {}).get('health-check') or {}
        check(hc.get('lazy') is False, 'lazy 必须 false（与下游/过滤层逐字一致）')
        check(hc.get('expected-status') == 204,
              f'expected-status=204（实际 {hc.get("expected-status")}）')
        check(hc.get('url') == af.DEFAULT_HEALTHCHECK_URL,
              f'健康检查目标与下游同值（实际 {hc.get("url")}）')
        path_in_cfg = (providers.get('trial') or {}).get('path') or ''
        check(path_in_cfg.endswith('trial.yaml'),
              f'provider 指向 trial.yaml（实际 {path_in_cfg}）')

    finally:
        pass

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
