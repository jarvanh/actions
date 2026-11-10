#!/usr/bin/env python3
"""`upload nonce` + 「push 必须真传全量」自检（2026-10-07 起，2026-11-10 重写判据）。

为什么这个文件必须存在：**上传测速的唯一数据来源就是「这次 push 传了多少字节」**。
只要线上传的不是全量文件，`10MiB ÷ push 耗时` 就不是带宽，而是握手/协商的固定开销。

历史（两次都是同一个病根的不同形态）：
  * 2026-10-07：一轮内所有节点 push 同一份缓存文件 ⇒ 服务端已有该 blob，只传
    128 字节的 commit 对象。修法 = 注入 nonce 改 blob 哈希。
  * 2026-11-10：nonce 只改头 16 字节 ⇒ blob 哈希变了（去重被绕过），但 git 用
    **thin pack + delta**，对远端已有的上一个 blob 做增量，线上仍只传 ~1KB。
    生产实测（run 42589029819 / 42683659942）：报 2~4 MiB/s，实际 ~1.5KB/次。
    修法 = 上传路径不 clone（无 delta base）+ `pack.window/pack.depth=0`。

⚠️ 旧判据为什么抓不到（2026-11-10 实锤）：它量的是**本地 bare 仓库磁盘增长**。
receive-pack 的 `index-pack --fix-thin` 会把 delta 引用的 base 对象**完整补写进**
新 pack，所以磁盘恒增 ~10MiB —— 与线上传了多少字节无关。实测同一次 push：
线上 899 B、远端磁盘 +10,489,191 B。**磁盘增长不能作为「真传」的证据。**

本测试钉住四件事：
  1. 源码级：nonce 注入在 `git add` 之前，且注入失败硬失败；
  2. 生产 `git_prepare_work_repo` 产出**不带远端对象**的仓库（无 delta base），
     且显式配置 `pack.window=0` / `pack.depth=0`；
  3. 行为级：在「远端已有近似 blob」的敌意场景下，默认配置的 thin pack 很小
     （证明判据有牙），套上生产配置后同一个 pack 变成 ≈ 全量；
  4. nonce 只改工作区副本 —— 源缓存文件 sha256 与大小不变。
"""
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

FAILURES = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAILURES.append(label)


import speedtest_gitee as g  # noqa: E402  (需先 sys.path)


BASE_ENV = {k: v for k, v in os.environ.items()
            if k.lower() not in ('all_proxy', 'http_proxy', 'https_proxy',
                                 'http_proxy', 'https_proxy')}
BASE_ENV.update({'GIT_TERMINAL_PROMPT': '0',
                 'GIT_AUTHOR_NAME': 'Javis', 'GIT_AUTHOR_EMAIL': 'j@bot.ai',
                 'GIT_COMMITTER_NAME': 'Javis', 'GIT_COMMITTER_EMAIL': 'j@bot.ai'})


def git(args, cwd, timeout=120, stdin_text=None):
    return subprocess.run(['git'] + args, cwd=str(cwd), capture_output=True,
                          text=True, env=BASE_ENV, timeout=timeout, input=stdin_text)


def git_bytes(args, cwd, stdin_bytes, timeout=120):
    """二进制安全的 git 调用（pack-objects 往 stdout 写 pack，不能按 text 解）。"""
    return subprocess.run(['git'] + args, cwd=str(cwd), capture_output=True,
                          input=stdin_bytes, env=BASE_ENV, timeout=timeout)


def q(repo, *args):
    return git(list(args), repo).stdout.strip()


def main():
    work = pathlib.Path('/tmp/_nonce_behavior')
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    size = 2 * 1024 * 1024  # 2MiB 足够验证「是否被去重/增量」，跑得快
    cache = work / 'cache.bin'
    cache.write_bytes(os.urandom(size))
    cache_sha_before = hashlib.sha256(cache.read_bytes()).hexdigest()
    cache_size_before = cache.stat().st_size

    print('== 1. 源码级：push 前调用了 nonce 注入，且注入在 git add 之前 ==')
    src = pathlib.Path(g.__file__).read_text(encoding='utf-8')
    idx_add = src.find("['git', 'add', target_filename]")
    idx_nonce = src.find('_inject_upload_nonce(repo_dir / target_filename)')
    check(idx_nonce > 0, '源码中存在 _inject_upload_nonce 调用')
    check(idx_nonce > 0 and idx_add > 0 and idx_nonce < idx_add,
          'nonce 注入在 git add 之前（否则 add 的仍是旧 blob）')
    fn_start = src.find('def _inject_upload_nonce')
    fn_body = src[fn_start:fn_start + 1800] if fn_start >= 0 else ''
    check('raise RuntimeError' in fn_body,
          'nonce 注入失败时硬失败（不静默跳过，避免真假数据混杂）')

    # ---- 准备一个「远端已有近似 blob」的 bare 仓库 ----
    bare = work / 'remote.git'
    subprocess.run(['git', 'init', '--bare', '-b', 'master', str(bare)],
                   capture_output=True, env=BASE_ENV)
    seed = work / 'seed'
    seed.mkdir(parents=True, exist_ok=True)
    git(['init', '-b', 'master'], seed)
    shutil.copy2(cache, seed / 'proxy_speedtest.bin')
    git(['add', 'proxy_speedtest.bin'], seed)
    git(['commit', '-m', 'prev-run'], seed)
    git(['push', '-q', str(bare), 'HEAD:refs/heads/master'], seed)

    print('== 2. 生产 git_prepare_work_repo：不带远端对象（无 delta base）+ 禁 delta 配置 ==')
    prod_repo = work / 'prod'
    g.git_prepare_work_repo(prod_repo, str(bare), BASE_ENV, 'master')
    check(q(prod_repo, 'rev-list', '--count', '--all') == '0',
          '工作仓库没有任何提交/对象（init 路径，远端 blob 不构成 delta base）')
    check(q(prod_repo, 'config', '--get', 'pack.window') == '0',
          'pack.window=0（push 侧禁用 delta 窗口）')
    check(q(prod_repo, 'config', '--get', 'pack.depth') == '0',
          'pack.depth=0（禁用 delta 链）')

    print('== 3. 敌意场景：远端已有近似 blob 时，pack 必须仍是全量 ==')
    # 复刻旧布局：clone --depth 1（本地就有远端的上一个 blob），只差 16 字节。
    clone_repo = work / 'clone'
    git(['clone', '-q', '--depth', '1', '--single-branch', '--branch', 'master',
         str(bare), str(clone_repo)], work)
    shutil.copy2(cache, clone_repo / 'proxy_speedtest.bin')
    g._inject_upload_nonce(clone_repo / 'proxy_speedtest.bin')   # ← 被测行为
    git(['add', 'proxy_speedtest.bin'], clone_repo)
    git(['commit', '-m', 'node-push'], clone_repo)
    new_sha = q(clone_repo, 'rev-parse', 'HEAD')
    old_sha = q(clone_repo, 'rev-parse', 'HEAD^')
    revs = f'{new_sha}\n^{old_sha}\n'.encode()
    pack_args = ['pack-objects', '--stdout', '--revs', '--thin', '--delta-base-offset']

    # 3a 默认配置（旧行为）：thin delta → 远小于文件
    default_pack = git_bytes(pack_args, clone_repo, revs).stdout
    check(len(default_pack) < size * 0.1,
          f'默认配置下 thin pack 会被 delta 压到极小（{len(default_pack)} B，旧 bug 的形态）')

    # 3b 套上生产配置：同一个 pack 必须是全量
    git(['config', 'pack.window', '0'], clone_repo)
    git(['config', 'pack.depth', '0'], clone_repo)
    fixed_pack = git_bytes(pack_args, clone_repo, revs).stdout
    check(len(fixed_pack) > size * 0.9,
          f'pack.window/depth=0 后同一 push 变全量（{len(fixed_pack)} B / {size} B）')

    # 3c 生产 init 仓库的 pack 也必须是全量（没有可比对的对象，trivially 真传；
    #    钉住「不得改回 clone 而不带禁 delta 配置」）
    shutil.copy2(cache, prod_repo / 'proxy_speedtest.bin')
    g._inject_upload_nonce(prod_repo / 'proxy_speedtest.bin')
    git(['add', 'proxy_speedtest.bin'], prod_repo)
    git(['commit', '-m', 'node-push'], prod_repo)
    prod_pack = git_bytes(['pack-objects', '--stdout', '--all'], prod_repo, b'').stdout
    check(len(prod_pack) > size * 0.9,
          f'生产仓库的 push pack 为全量（{len(prod_pack)} B / {size} B）')

    print('== 4. nonce 只改副本：源缓存文件不被污染 ==')
    check(hashlib.sha256(cache.read_bytes()).hexdigest() == cache_sha_before,
          '源缓存文件 sha256 未变（nonce 只写工作区副本）')
    check(cache.stat().st_size == cache_size_before,
          '源缓存文件大小未变（覆写不改变长度，字节数换算不受影响）')

    shutil.rmtree(work, ignore_errors=True)

    if FAILURES:
        print(f'FAILED: {len(FAILURES)} 项未通过')
        for f in FAILURES:
            print(f'  - {f}')
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
