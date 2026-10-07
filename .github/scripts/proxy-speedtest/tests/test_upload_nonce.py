#!/usr/bin/env python3
"""`upload nonce` 自检：每次 push 必须真传全量内容（2026-10-07 新增）。

为什么单独一个文件：这是「↑ 上传值」假象的守门测试。2026-10-07 实测发现
一轮内 118 个节点 push **同一份缓存文件**（`ensure_test_file` 每轮 VM 只
urandom 一次并按大小缓存）⇒ git 内容寻址去重后，第 2 个节点起每次只传
**128 字节**的 commit 对象 ⇒ 「10MiB ÷ push 耗时」量到的只是 TLS 握手 +
认证 + 协商的固定开销（实测 1.6~3.6s，与延迟强相关、与带宽无关）。

**事故影响**：38 个节点的 ↑ 值全挤在 2.77~6.08 MiB/s（22~49 兆），完全失去
分辨力；更糟的是订阅判定用 `SPEED_METRIC=upload`，等于**按握手延迟排序**，
而不是按带宽排序。

**本地复现证据**（2026-10-07，本地 bare 仓库对照实验）：
    无 nonce：10.00 MiB → 129 B → 128 B   （后两次被去重）
    有 nonce：10.00 MiB → 10.00 MiB → 10.00 MiB

本测试钉住三件事：
  1. push 前确实注入了 nonce（源码级 + 行为级）
  2. 连续两次 push，远端每次都新增约 10MiB（行为级，用本地 bare 仓库实测）
  3. nonce 只改工作区副本 —— 源缓存文件的 sha256 与大小必须不变
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


def main():
    print('== 1. 源码级：push 前调用了 nonce 注入 ==')
    src = pathlib.Path(g.__file__).read_text(encoding='utf-8')
    # 判据放在 `_do_push` 内部且位于 git add 之前：注入必须在 add 之前，
    # 否则 add 进去的还是旧 blob，白注入。
    idx_add = src.find("['git', 'add', target_filename]")
    idx_nonce = src.find('_inject_upload_nonce(repo_dir / target_filename)')
    check(idx_nonce > 0, '源码中存在 _inject_upload_nonce 调用')
    check(idx_nonce > 0 and idx_add > 0 and idx_nonce < idx_add,
          'nonce 注入在 git add 之前（否则 add 的仍是旧 blob）')

    # 注入失败必须硬失败：静默跳过会让假数据混进真数据里无从分辨
    fn_start = src.find('def _inject_upload_nonce')
    fn_body = src[fn_start:fn_start + 1400] if fn_start >= 0 else ''
    check('raise RuntimeError' in fn_body,
          'nonce 注入失败时硬失败（不静默跳过，避免真假数据混杂）')

    print('== 2. 行为级：连续两次 push，远端每次都新增约 10MiB ==')
    work = pathlib.Path('/tmp/_nonce_behavior')
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    size = 2 * 1024 * 1024  # 2MiB 足够验证「是否被去重」，跑得快
    cache = work / 'cache.bin'
    cache.write_bytes(os.urandom(size))
    cache_sha_before = hashlib.sha256(cache.read_bytes()).hexdigest()
    cache_size_before = cache.stat().st_size

    env = {k: v for k, v in os.environ.items()
           if k.lower() not in ('all_proxy', 'http_proxy', 'https_proxy')}
    env.update({'GIT_TERMINAL_PROMPT': '0',
                'GIT_AUTHOR_NAME': 'Javis', 'GIT_AUTHOR_EMAIL': 'j@bot.ai',
                'GIT_COMMITTER_NAME': 'Javis', 'GIT_COMMITTER_EMAIL': 'j@bot.ai'})

    def git(args, cwd, timeout=120):
        try:
            return subprocess.run(['git'] + args, cwd=str(cwd), capture_output=True,
                                  text=True, env=env, timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, -1, '', 'TIMEOUT')

    def bare_size(d):
        return sum(f.stat().st_size for f in d.rglob('*') if f.is_file())

    # --- 2a. 对照：不注入 nonce，第二次 push 应被去重（只传几百字节）---
    bare_off = work / 'remote_off.git'
    subprocess.run(['git', 'init', '--bare', '-b', 'master', str(bare_off)],
                   capture_output=True, env=env)
    deltas_off = []
    for i in (1, 2):
        rd = work / ('off%d' % i)
        rd.mkdir(parents=True, exist_ok=True)
        git(['init', '-b', 'master'], rd)
        git(['config', 'user.name', 'Javis'], rd)
        git(['config', 'user.email', 'j@bot.ai'], rd)
        git(['remote', 'add', 'origin', str(bare_off)], rd)
        shutil.copy2(cache, rd / 'proxy_speedtest.bin')
        git(['add', 'proxy_speedtest.bin'], rd)
        git(['commit', '-m', 't'], rd)
        before = bare_size(bare_off)
        p = git(['push', '-f', 'origin', 'HEAD:refs/heads/master'], rd)
        if p.returncode != 0:
            deltas_off.append(None)
        else:
            deltas_off.append(bare_size(bare_off) - before)
    check(deltas_off[0] and deltas_off[0] > size * 0.9,
          f'对照组第 1 次 push 真传全量（实际 {deltas_off[0]} B）')
    # 反证：不注入 nonce 时第二次被去重 —— 这正是旧实现的病根，钉住它
    check(deltas_off[1] is not None and deltas_off[1] < size * 0.1,
          f'对照组第 2 次 push 被 git 去重（实际 {deltas_off[1]} B —— 旧实现的病根）')

    # --- 2b. 注入 nonce：两次都应真传 ---
    bare_on = work / 'remote_on.git'
    subprocess.run(['git', 'init', '--bare', '-b', 'master', str(bare_on)],
                   capture_output=True, env=env)
    deltas_on = []
    blobs = []
    for i in (1, 2):
        rd = work / ('on%d' % i)
        rd.mkdir(parents=True, exist_ok=True)
        git(['init', '-b', 'master'], rd)
        git(['config', 'user.name', 'Javis'], rd)
        git(['config', 'user.email', 'j@bot.ai'], rd)
        git(['remote', 'add', 'origin', str(bare_on)], rd)
        shutil.copy2(cache, rd / 'proxy_speedtest.bin')
        g._inject_upload_nonce(rd / 'proxy_speedtest.bin')   # ← 被测行为
        blobs.append(git(['hash-object', str(rd / 'proxy_speedtest.bin')], rd).stdout.strip())
        git(['add', 'proxy_speedtest.bin'], rd)
        git(['commit', '-m', 't'], rd)
        before = bare_size(bare_on)
        p = git(['push', '-f', 'origin', 'HEAD:refs/heads/master'], rd)
        if p.returncode != 0:
            deltas_on.append(None)
        else:
            deltas_on.append(bare_size(bare_on) - before)

    check(all(d and d > size * 0.9 for d in deltas_on),
          f'注入 nonce 后两次 push 都真传全量（实际 {deltas_on}）')
    check(len(set(blobs)) == 2, '两次 push 的 blob 哈希不同（去重被绕过）')

    print('== 3. nonce 只改副本：源缓存文件不被污染 ==')
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
