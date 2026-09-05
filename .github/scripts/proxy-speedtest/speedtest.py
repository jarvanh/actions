#!/usr/bin/env python3
"""独立代理节点测速脚本（延迟 + 下载速度 + 经代理上行速度）。

复用 speedtest_gitee.py 的 mihomo 内核启动 / 节点快照 / 节点切换能力，新增：
  - latency_probe      : 经代理对目标 URL 做 HTTP 计时（延迟）
  - resolve_download_urls: 运行时自动发现国内测速点（滚动 ISO 软链 + npmmirror 最新版），规避写死版本号失效
  - download_speedtest : 经 mixed-port 代理 curl Range 拉取测速点，换算 MiB/s
  - gitee_push_speedtest: 经代理 git push 到 Gitee 测上行（复用 speedtest_gitee.git_force_push_testfile）
  - build_html_report  : 生成自包含、可交互 HTML 可视化报告
  - 订阅导出 + Gist 上传: 复用 speedtest_gitee.build_source_mapping / build_subscription_yaml_text /
    update_gist，把达标节点的原始配置整理成订阅并发布到 GitHub 私有 Gist

设计原则：
  - 不修改 speedtest_gitee.py，仅以 `from speedtest_gitee import ...` 复用已验证的纯函数/低副作用函数。
  - 节点逐节点**串行**测试（共享同一 mihomo 内核，切换后等待 settle）。
  - 自定义参数全部通过环境变量控制（见 CONFIG 区块）。
"""
import json
import os
import html
import pathlib
import re
import statistics
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime

import yaml

# ----------------------------------------------------------------------------
# 复用 speedtest_gitee.py 的已验证能力（import 期仅会创建 ~/proxy-speedtest 目录）
# ----------------------------------------------------------------------------
from speedtest_gitee import (
    MIHOMO_MIXED_PORT,
    HOME_RUNTIME,
    collect_provider_snapshot,
    switch_proxy,
    build_proxy_env,
    ensure_mihomo_running,
    log_progress,
    merged_env,
    ensure_gitee_remote,
    ensure_test_file,
    git_force_push_testfile,
    send_telegram,
    format_duration,
    TEST_FILE_NAME,
    # 订阅导出 + Gist 上传（复刻 speedtest_gitee 的订阅发布能力）
    build_source_mapping,
    build_subscription_yaml_text,
    build_node_metric_prefix,
    update_gist,
    get_item_megabits,
    DEFAULT_MIN_MEGABIT,
)

# ----------------------------------------------------------------------------
# 配置（全部可通过环境变量覆盖）
# ----------------------------------------------------------------------------
DEFAULT_LATENCY_TARGETS = [
    'https://www.baidu.com',
    'https://www.taobao.com',
]
# 方案 A：不写死带版本号的具体 ISO（容易随镜像清理而失效），改为：
#  1) 默认从下列「滚动 ISO 索引目录」自动发现当前存在的 *-latest-*.iso 软链；
#  2) 仅当用户显式设置 PROXY_SPEEDTEST_DOWNLOAD_URLS 时才使用指定 URL（向后兼容）。
# 这些目录长期稳定，内部 ISO 版本会轮换，但 *-latest-* 软链始终指向最新可用文件，
# 脚本每次运行自动取该软链，彻底规避版本号失效问题。
DEFAULT_DOWNLOAD_CATALOGS = [
    'https://mirrors.cloud.tencent.com/centos/8-stream/isos/x86_64/',
    'https://mirrors.cloud.tencent.com/centos/9-stream/isos/x86_64/',
    'https://mirrors.tuna.tsinghua.edu.cn/centos/8-stream/isos/x86_64/',
]
# 兜底写死 URL（仅在自动发现全部失败时使用），同样选用滚动 latest 软链。
DEFAULT_DOWNLOAD_URLS = [
    'https://mirrors.cloud.tencent.com/centos/8-stream/isos/x86_64/CentOS-Stream-8-x86_64-latest-boot.iso',
    'https://mirrors.cloud.tencent.com/centos/9-stream/isos/x86_64/CentOS-Stream-9-x86_64-latest-boot.iso',
]
# 国内厂商 CDN 固定软件测速点：npmmirror（淘宝 npm 镜像）不提供 latest 软链，但可通过
# registry 的 dist-tags 实时拿到最新版本号，拼出「最新版」固定直链（几乎不删旧版本，长期可用）。
# 这样既不写死版本号、又保证是软件最新版，作为镜像站 ISO 之外的日常软件下载带宽代表。
NPMMIRROR_LATEST_API = 'https://registry.npmmirror.com/node'
NPMMIRROR_NODE_ZIP_TPL = 'https://registry.npmmirror.com/-/binary/node/{version}/node-{version}-win-x64.zip'
DEFAULT_GITEE_BRANCH = 'master'

CONFIG = {
    # 延迟探测
    'PROXY_SPEEDTEST_LATENCY_TARGETS':
        (os.environ.get('PROXY_SPEEDTEST_LATENCY_TARGETS', '') or ','.join(DEFAULT_LATENCY_TARGETS)).split(','),
    'PROXY_SPEEDTEST_LATENCY_SAMPLES':
        int(os.environ.get('PROXY_SPEEDTEST_LATENCY_SAMPLES', '4')),
    'PROXY_SPEEDTEST_LATENCY_TIMEOUT':
        float(os.environ.get('PROXY_SPEEDTEST_LATENCY_TIMEOUT', '8')),
    # 下载测速
    'PROXY_SPEEDTEST_DOWNLOAD_URLS':
        (os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_URLS', '') or ','.join(DEFAULT_DOWNLOAD_URLS)).split(','),
    'PROXY_SPEEDTEST_SIZE_MIB':
        int(os.environ.get('PROXY_SPEEDTEST_SIZE_MIB', '10')),
    'PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT', '30')),
    'PROXY_SPEEDTEST_DOWNLOAD_DURATION':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_DURATION', '0')),  # 0=用 SIZE_MIB/timeout 约束
    # 节点切换
    'PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS':
        float(os.environ.get('PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS', '1.5')),
    'PROXY_SPEEDTEST_MAX_NODES':
        int(os.environ.get('PROXY_SPEEDTEST_MAX_NODES', '0')),  # 0=不限
    # 下载测速点：是否经 npmmirror 自动发现最新版 node 直链（与滚动 ISO 合并）
    'PROXY_SPEEDTEST_NPMMIRROR_ENABLED':
        (os.environ.get('PROXY_SPEEDTEST_NPMMIRROR_ENABLED', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
    # 可选 Gitee 上行
    'PROXY_SPEEDTEST_ENABLE_PUSH':
        (os.environ.get('PROXY_SPEEDTEST_ENABLE_PUSH', '0').strip().lower() in ('1', 'true', 'yes', 'on')),
    # 上行是否经 mihomo 代理（True=反映代理节点上行带宽；False=直连 Gitee 反映家庭宽带上行）
    'PROXY_SPEEDTEST_UPLOAD_VIA_PROXY':
        (os.environ.get('PROXY_SPEEDTEST_UPLOAD_VIA_PROXY', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
    'PROXY_SPEEDTEST_PUSH_TIMEOUT':
        int(os.environ.get('PROXY_SPEEDTEST_PUSH_TIMEOUT', '30')),
    'GITEE_PRIVATE_TOKEN':
        os.environ.get('GITEE_PRIVATE_TOKEN', '').strip(),
    'PROXY_SPEEDTEST_GITEE_OWNER':
        os.environ.get('PROXY_SPEEDTEST_GITEE_OWNER', '').strip(),
    'PROXY_SPEEDTEST_GITEE_REPO':
        os.environ.get('PROXY_SPEEDTEST_GITEE_REPO', 'proxy-speedtest-temp').strip() or 'proxy-speedtest-temp',
    'PROXY_SPEEDTEST_GITEE_BRANCH':
        os.environ.get('PROXY_SPEEDTEST_GITEE_BRANCH', DEFAULT_GITEE_BRANCH).strip() or DEFAULT_GITEE_BRANCH,
}

RESULT_JSON = HOME_RUNTIME / 'speedtest_result.json'
RESULT_HTML = HOME_RUNTIME / 'speedtest_report.html'


# ----------------------------------------------------------------------------
# 延迟测量：经代理对目标做 HTTP GET，记录分段耗时，取 min/median
# ----------------------------------------------------------------------------
def latency_probe(targets, proxy_env, samples=4, timeout=8.0):
    """经代理测量一组目标的延迟，返回 {ok, min_ms, median_ms, samples, error}。"""
    measurements = []
    last_error = ''
    proxy = proxy_env.get('HTTP_PROXY') or proxy_env.get('HTTPS_PROXY')
    handlers = [urllib.request.ProxyHandler({'http': proxy, 'https': proxy})] if proxy else []
    opener = urllib.request.build_opener(*handlers)
    for t in targets:
        t = t.strip()
        if not t:
            continue
        for _ in range(max(1, samples)):
            try:
                req = urllib.request.Request(t, headers={'User-Agent': 'Mozilla/5.0', 'Cache-Control': 'no-cache'})
                t0 = time.perf_counter()
                with opener.open(req, timeout=timeout) as r:
                    r.read(1)
                elapsed_ms = (time.perf_counter() - t0) * 1000.0
                measurements.append(round(elapsed_ms, 1))
            except Exception as e:
                last_error = f'{t}: {e}'
                measurements.append(None)
    valid = [m for m in measurements if m is not None]
    if not valid:
        return {'ok': False, 'min_ms': None, 'median_ms': None, 'samples': len(measurements), 'error': last_error}
    return {
        'ok': True,
        'min_ms': round(min(valid), 1),
        'median_ms': round(statistics.median(valid), 1),
        'samples': len(measurements),
        'error': None,
    }


# ----------------------------------------------------------------------------
# 下载测速点自动发现（方案 A：国内滚动目录，避免写死版本号 ISO 失效）
# ----------------------------------------------------------------------------
_ISO_RE = re.compile(r'href="([^"]+\.iso)"', re.IGNORECASE)


def _resolve_npmmirror_node_zip(opener):
    """经代理查询 npmmirror 最新 node 版本，拼出最新版 win-x64 zip 直链。

    返回 URL 字符串；失败返回 None（不影响主测速点）。
    """
    try:
        req = urllib.request.Request(
            NPMMIRROR_LATEST_API,
            headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'},
        )
        with opener.open(req, timeout=15) as r:
            data = json.loads(r.read().decode('utf-8', 'ignore'))
        version = data.get('dist-tags', {}).get('latest')
        if not version:
            return None
        return NPMMIRROR_NODE_ZIP_TPL.format(version=version)
    except Exception:
        return None


def resolve_download_urls(proxy_env, catalogs, fallback_urls, enable_npmmirror=True):
    """组合两类国内测速点，全部「不写死版本号、运行时自动取最新」：

    1. 滚动 ISO：逐个抓取 catalogs 索引页，正则提取 .iso，优先选 *-latest-*/stream 软链；
    2. 国内厂商 CDN 固定软件：npmmirror 最新版 node 安装包（通过 dist-tags 实时解析版本号）。
    - 用户若显式设置 PROXY_SPEEDTEST_DOWNLOAD_URLS，main 会跳过本函数（向后兼容）。
    - ISO 全部发现失败则回退 fallback_urls；npmmirror 失败仅跳过该项，不阻断。
    返回 (urls, source_description)。
    """
    proxy = proxy_env.get('HTTP_PROXY') or proxy_env.get('HTTPS_PROXY')
    handlers = [urllib.request.ProxyHandler({'http': proxy, 'https': proxy})] if proxy else []
    opener = urllib.request.build_opener(*handlers)
    found = []
    sources = []
    for base in catalogs:
        base = base.strip()
        if not base:
            continue
        index_url = base if base.endswith('/') else base + '/'
        try:
            req = urllib.request.Request(
                index_url,
                headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'text/html,*/*'},
            )
            with opener.open(req, timeout=15) as r:
                html = r.read().decode('utf-8', 'ignore')
        except Exception:
            continue
        links = ['/'.join([base.rstrip('/'), m.group(1)]) for m in _ISO_RE.finditer(html)]
        if not links:
            continue
        latest = [l for l in links if 'latest' in l.lower() or 'stream' in l.lower()]
        if latest:
            chosen = sorted(latest)[-1]
        else:
            def ver_key(u):
                nums = re.findall(r'(\d+)', u)
                return [int(n) for n in nums] + [0] * 4
            chosen = sorted(links, key=ver_key)[-1]
        found.append(chosen)
    if found:
        sources.append('rolling ISO catalogs')
    else:
        found = list(fallback_urls)
        sources.append('fallback ISO')

    if enable_npmmirror:
        npm_url = _resolve_npmmirror_node_zip(opener)
        if npm_url:
            found.append(npm_url)
            sources.append('npmmirror latest node')
    return found, ' + '.join(sources)


# ----------------------------------------------------------------------------
# 下载测速：curl 经 mixed-port 代理拉取测速点，按耗时换算 MiB/s
# ----------------------------------------------------------------------------
def download_speedtest(urls, proxy_env, timeout=30.0, size_hint_mib=10, max_duration=0.0):
    """经代理 curl 拉取测速点，返回 {ok, mibps, bytes, seconds, error}。

    对每个测速 URL 优先用 HTTP Range 单次精确拉取 size_hint_mib 字节（避免重复连接
    开销、速度读数更准）；若目标不支持 Range（返回整文件），则按实际下载字节与耗时
    换算速度。若指定 max_duration>0 则限制单节点总时长（多个 URL 串行取最优）。
    """
    proxy = f'http://127.0.0.1:{MIHOMO_MIXED_PORT}'
    target_bytes = int(size_hint_mib * 1024 * 1024)
    wall_deadline = time.monotonic() + (max_duration if max_duration and max_duration > 0 else timeout)
    best = None
    last_error = ''
    for u in urls:
        u = u.strip()
        if not u:
            continue
        remaining = int(wall_deadline - time.monotonic())
        if remaining <= 0:
            break
        range_arg = f'0-{target_bytes - 1}'
        cmd = [
            'curl', '-sS', '-x', proxy, '-o', '/dev/null',
            '-w', '%{time_total},%{size_download}',
            '--connect-timeout', '10',
            '--max-time', str(min(remaining, timeout)),
            '-r', range_arg,
            '-A', 'Mozilla/5.0', u,
        ]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=min(remaining, timeout) + 10)
            if out.returncode != 0:
                last_error = out.stderr.strip() or f'curl exit {out.returncode}'
                continue
            parts = (out.stdout.strip().split(',') + ['0', '0'])[:2]
            dur = float(parts[0] or '0')
            sz = int(parts[1] or '0')
            if dur <= 0 or sz <= 0:
                last_error = 'empty download'
                continue
            mibps = sz / 1024 / 1024 / dur
            cand = {'ok': True, 'mibps': round(mibps, 2), 'bytes': sz,
                    'seconds': round(dur, 2), 'error': None}
            if best is None or cand['mibps'] > best['mibps']:
                best = cand
        except Exception as e:
            last_error = str(e)
    if best is None:
        return {'ok': False, 'mibps': None, 'bytes': 0, 'seconds': None, 'error': last_error}
    return best


# ----------------------------------------------------------------------------
# 可选 Gitee 上行测速（经 mihomo 代理 git push，反映代理节点上行带宽）
# ----------------------------------------------------------------------------


def gitee_push_speedtest(env, size_mib, push_timeout, branch, via_proxy=True):
    """向 Gitee 私有仓库上行一个固定大小文件，按耗时换算上行 MiB/s。

    - via_proxy=True（默认）：复用 speedtest_gitee 的「经代理 git push」方案，
      携带 mihomo 混合端口代理环境变量调用 git push，**真正反映代理节点的
      上行带宽**（端点位于中国，符合国内测速要求）。
    - via_proxy=False（向后兼容）：直连 Gitee 用 git push（已剥离代理变量），
      反映家庭宽带直连上行。
    返回 {ok, mibps, bytes, seconds, error}。
    """
    token = env.get('GITEE_PRIVATE_TOKEN', '').strip()
    if not token:
        return {'ok': False, 'mibps': None, 'error': 'missing GITEE_PRIVATE_TOKEN'}
    owner = env.get('PROXY_SPEEDTEST_GITEE_OWNER', '').strip()
    repo = env.get('PROXY_SPEEDTEST_GITEE_REPO', 'proxy-speedtest-temp').strip()
    if not owner:
        try:
            req = urllib.request.Request(
                'https://gitee.com/api/v5/user',
                headers={'Authorization': 'token ' + token, 'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'},
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                owner = json.load(r).get('login', '').strip()
        except Exception as e:
            return {'ok': False, 'mibps': None, 'error': f'resolve gitee owner failed: {e}'}
    if not owner:
        return {'ok': False, 'mibps': None, 'error': 'failed to resolve Gitee owner'}

    if not via_proxy:
        return _gitee_push_direct(env, token, owner, repo, size_mib, push_timeout, branch)

    # 经代理上行：复用 speedtest_gitee 的「经代理 git push」方案——
    # 携带 mihomo 代理环境变量调用 git push，真正反映代理节点的上行带宽。
    try:
        gitee = ensure_gitee_remote(env)
        test_file = ensure_test_file(int(size_mib))
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': f'prepare gitee/ test file failed: {e}'}

    # 注意：env 实为 CONFIG（含 PROXY_SPEEDTEST_DOWNLOAD_URLS 等 list 字段），
    # 直接作为 subprocess 的 env 会因非 str 值触发异常。构造干净环境：仅保留 str
    # 值并覆盖代理变量，确保 git 经 mihomo 代理上行。
    local_env = {k: v for k, v in build_proxy_env(env).items() if isinstance(v, str)}
    local_env['GIT_TERMINAL_PROMPT'] = '0'
    repo_dir = HOME_RUNTIME / 'speedtest-upload-repo'
    total = test_file.stat().st_size
    try:
        t0 = time.perf_counter()
        dur = git_force_push_testfile(
            repo_dir=repo_dir,
            remote=gitee['remote_with_token'],
            env=local_env,
            file_path=test_file,
            commit_message='proxy-speedtest upload benchmark',
            push_timeout=push_timeout,
            branch_name=branch,
            target_filename=TEST_FILE_NAME,
            gitee=gitee,
        )
        dt = time.perf_counter() - t0
        # git_force_push_testfile 返回其内置 time.time() 计时，取两者中较稳者
        measured = dur if dur and dur > 0 else dt
        if measured <= 0:
            return {'ok': False, 'mibps': None, 'error': 'upload too fast to measure'}
        mibps = total / 1024 / 1024 / measured
        return {'ok': True, 'mibps': round(mibps, 2), 'bytes': total,
                'seconds': round(measured, 2), 'error': None}
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': str(e)[:200]}


def _gitee_push_direct(env, token, owner, repo, size_mib, push_timeout, branch):
    """直连分支（via_proxy=False）：直连 Gitee 用 git push（反映家庭宽带直连上行）。

    已剥离代理变量，且同样过滤非 str 的环境值，避免 subprocess 因 list 值报错。
    """
    remote_with_token = f'https://oauth2:{token}@gitee.com/{owner}/{repo}.git'
    work = HOME_RUNTIME / 'speedtest-upload-tmp'
    work.mkdir(parents=True, exist_ok=True)
    test_file = work / 'speedtest.bin'
    total = int(size_mib * 1024 * 1024)
    try:
        with test_file.open('wb') as f:
            f.write(os.urandom(min(total, 8 * 1024 * 1024)))
            remaining = total - min(total, 8 * 1024 * 1024)
            while remaining > 0:
                chunk = min(remaining, 8 * 1024 * 1024)
                f.write(os.urandom(chunk))
                remaining -= chunk
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': f'create test file failed: {e}'}
    local_env = {k: v for k, v in env.items() if isinstance(v, str)}
    for k in ['ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']:
        local_env.pop(k, None)
    local_env['GIT_TERMINAL_PROMPT'] = '0'
    try:
        subprocess.run(['git', '-C', str(work), 'init', '-q'], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'config', 'user.email', 'speedtest@local'], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'config', 'user.name', 'speedtest'], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'remote', 'remove', 'origin'], env=local_env, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'remote', 'add', 'origin', remote_with_token], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'checkout', '-B', branch], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'add', '-A'], env=local_env, check=True, capture_output=True, timeout=60)
        subprocess.run(['git', '-C', str(work), 'commit', '-q', '-m', 'speedtest upload'], env=local_env, check=True, capture_output=True, timeout=60)
        t0 = time.perf_counter()
        p = subprocess.run(['git', '-C', str(work), 'push', '-f', 'origin', branch], env=local_env, capture_output=True, timeout=push_timeout + 30)
        dt = time.perf_counter() - t0
        if p.returncode != 0:
            return {'ok': False, 'mibps': None, 'error': (p.stderr or p.stdout).decode('utf-8', 'ignore').strip()[:200]}
        if dt <= 0:
            return {'ok': False, 'mibps': None, 'error': 'push too fast to measure'}
        return {'ok': True, 'mibps': round(size_mib / dt, 2), 'error': None}
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': str(e)[:200]}
    finally:
        try:
            subprocess.run(['git', '-C', str(work), 'push', '-f', 'origin', ':refs/heads/' + branch],
                           env=local_env, capture_output=True, timeout=push_timeout + 30)
        except Exception:
            pass


# ----------------------------------------------------------------------------
# 单节点测试编排
# ----------------------------------------------------------------------------
def speedtest_single_node(item, proxy_env, cfg, download_urls):
    name = item.get('name', '')
    log_progress('node_test_start', name=name, type=item.get('type', ''))
    result = {
        'name': name,
        'type': item.get('type', ''),
        'provider': item.get('provider', ''),
        'latency': latency_probe(cfg['PROXY_SPEEDTEST_LATENCY_TARGETS'], proxy_env,
                                 cfg['PROXY_SPEEDTEST_LATENCY_SAMPLES'], cfg['PROXY_SPEEDTEST_LATENCY_TIMEOUT']),
        'download': download_speedtest(download_urls, proxy_env,
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'], cfg['PROXY_SPEEDTEST_SIZE_MIB'],
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_DURATION']),
    }
    if cfg['PROXY_SPEEDTEST_ENABLE_PUSH']:
        via_proxy = cfg['PROXY_SPEEDTEST_UPLOAD_VIA_PROXY']
        result['upload'] = gitee_push_speedtest(cfg, cfg['PROXY_SPEEDTEST_SIZE_MIB'],
                                                cfg['PROXY_SPEEDTEST_PUSH_TIMEOUT'],
                                                cfg['PROXY_SPEEDTEST_GITEE_BRANCH'],
                                                via_proxy=via_proxy)
    else:
        result['upload'] = {'ok': False, 'mibps': None, 'error': 'disabled'}
    result['ok'] = bool(result['latency']['ok'] or result['download']['ok'])
    # 注：upload 字段一并输出，便于从日志直接排查上行测速结果（无需解析最终报告）
    log_progress('node_test_done', name=name, latency_ms=result['latency'].get('median_ms'),
                 download_mibps=result['download'].get('mibps'), upload_mibps=result['upload'].get('mibps'))
    return result


# ----------------------------------------------------------------------------
# HTML 报告生成（自包含、可交互、纯静态）
# ----------------------------------------------------------------------------
def build_html_report(results, meta):
    """生成 self-contained HTML 字符串，内联数据 + Canvas 图表 + 排序/筛选 JS。"""
    # 转义 </ 防止节点名中的 </script> 破坏页面（HTML 注入防护）
    data_json = json.dumps(results, ensure_ascii=False).replace('</', '<\\/')
    meta_json = json.dumps(meta, ensure_ascii=False).replace('</', '<\\/')

    total = len(results)
    success = sum(1 for r in results if r.get('ok'))
    latencies = [r['latency'].get('median_ms') for r in results if r.get('latency', {}).get('ok')]
    downloads = [r['download'].get('mibps') for r in results if r.get('download', {}).get('ok')]
    avg_latency = round(statistics.mean(latencies), 1) if latencies else None
    avg_download = round(statistics.mean(downloads), 2) if downloads else None

    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>代理节点测速报告</title>
<style>
:root{
  --bg:#0B1020; --panel:#141B2E; --primary:#4F8CFF; --text:#E5E7EB; --muted:#9CA3AF;
  --ok:#34D399; --warn:#FBBF24; --fail:#F87171;
}
*{box-sizing:border-box;}
body{margin:0;background:linear-gradient(160deg,#0B1020,#0d1530 60%,#0B1020);color:var(--text);
  font-family:'PingFang SC',system-ui,-apple-system,'Segoe UI',sans-serif;font-size:13px;line-height:1.5;}
.wrap{max-width:1100px;margin:0 auto;padding:28px 20px 60px;}
header h1{font-size:22px;font-weight:700;margin:0 0 4px;}
header .sub{color:var(--muted);font-size:13px;}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:14px;margin:22px 0;}
.card{background:rgba(20,27,46,.72);backdrop-filter:blur(10px);border:1px solid rgba(79,140,255,.18);
  border-radius:14px;padding:16px 18px;box-shadow:0 8px 30px rgba(0,0,0,.35);}
.card .k{color:var(--muted);font-size:12px;}
.card .v{font-size:22px;font-weight:700;margin-top:6px;}
.card .v small{font-size:13px;font-weight:500;color:var(--muted);}
.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:14px 0 18px;}
.controls input,.controls select{background:#0e1530;border:1px solid rgba(255,255,255,.1);color:var(--text);
  border-radius:9px;padding:8px 10px;font-size:13px;outline:none;}
.controls input:focus,.controls select:focus{border-color:var(--primary);}
.section{background:rgba(20,27,46,.72);backdrop-filter:blur(10px);border:1px solid rgba(79,140,255,.14);
  border-radius:14px;padding:18px;margin-bottom:20px;box-shadow:0 8px 30px rgba(0,0,0,.3);}
.section h2{font-size:15px;font-weight:600;margin:0 0 14px;}
table{width:100%;border-collapse:collapse;font-size:13px;}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid rgba(255,255,255,.06);cursor:pointer;white-space:nowrap;}
th{color:var(--muted);font-weight:600;user-select:none;position:sticky;top:0;background:#10182f;}
th:hover{color:var(--primary);}
tbody tr:hover{background:rgba(79,140,255,.08);}
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11px;font-weight:600;}
.badge.ok{background:rgba(52,211,153,.15);color:var(--ok);}
.badge.fail{background:rgba(248,113,113,.15);color:var(--fail);}
.badge.warn{background:rgba(251,191,36,.15);color:var(--warn);}
.charts{display:grid;grid-template-columns:1fr 1fr;gap:18px;}
@media(max-width:760px){.charts{grid-template-columns:1fr;}}
canvas{max-width:100%;}
.tip{font-size:12px;color:var(--muted);margin-top:8px;}
.top5{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:6px;}
.chip{background:rgba(79,140,255,.12);border:1px solid rgba(79,140,255,.25);border-radius:10px;
  padding:8px 12px;font-size:12px;transition:transform .15s ease;}
.chip:hover{transform:translateY(-2px);}
.chip b{color:var(--primary);}
footer{color:var(--muted);font-size:12px;margin-top:26px;border-top:1px solid rgba(255,255,255,.07);padding-top:16px;}
code{background:#0e1530;padding:1px 6px;border-radius:5px;color:#cbd5e1;}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>代理节点测速报告</h1>
  <div class="sub" id="meta-sub"></div>
</header>

<div class="cards" id="cards"></div>

<div class="section" id="gist-section" style="display:none;">
  <h2>可用节点订阅（GitHub Gist）</h2>
  <div id="gist-box"></div>
</div>

<div class="section">
  <h2>TOP 5 最快节点</h2>
  <div class="top5" id="top5"></div>
</div>

<div class="controls">
  <input id="search" placeholder="搜索节点名…" style="min-width:200px;"/>
  <select id="f-provider"><option value="">全部供应商</option></select>
  <select id="f-type"><option value="">全部类型</option></select>
  <select id="f-status">
    <option value="">全部状态</option>
    <option value="ok">可用</option>
    <option value="fail">不可用</option>
  </select>
</div>

<div class="section">
  <h2>节点成绩表（点击表头排序）</h2>
  <div style="overflow-x:auto;">
  <table id="tbl">
    <thead><tr>
      <th data-k="name">节点</th>
      <th data-k="type">类型</th>
      <th data-k="provider">供应商</th>
      <th data-k="latency.min_ms">延迟(min)</th>
      <th data-k="latency.median_ms">延迟(median)</th>
      <th data-k="download.mibps">下载(MiB/s)</th>
      <th data-k="upload.mibps">上行(MiB/s)</th>
      <th data-k="status">状态</th>
    </tr></thead>
    <tbody></tbody>
  </table>
  </div>
  <div class="tip">提示：表头点击切换升/降序；筛选框与搜索框实时过滤下方图表。</div>
</div>

<div class="section">
  <div class="charts">
    <div>
      <h2>延迟分布（ms）</h2>
      <canvas id="latChart" height="260"></canvas>
    </div>
    <div>
      <h2>下载速度对比（MiB/s）</h2>
      <canvas id="dlChart" height="260"></canvas>
    </div>
  </div>
</div>

<footer id="footer"></footer>
</div>

<script>
const RESULTS = __DATA__;
const META = __META__;

function get(r,k){return k.split('.').reduce((o,p)=> (o==null?o:o[p]), r);}
function statusOf(r){return r.ok?'ok':'fail';}
function colorOf(v){return v==null?'var(--fail)':(v<150?'var(--ok)':(v<400?'var(--warn)':'var(--fail)'));}

// 概览卡片
const total=RESULTS.length;
const succ=RESULTS.filter(r=>r.ok).length;
const lats=RESULTS.map(r=>get(r,'latency.median_ms')).filter(x=>x!=null);
const dls=RESULTS.map(r=>get(r,'download.mibps')).filter(x=>x!=null);
const avgL=lats.length?Math.round(lats.reduce((a,b)=>a+b,0)/lats.length):null;
const avgD=dls.length?Math.round(dls.reduce((a,b)=>a+b,0)*100)/100:null;
const cards=[
  {k:'节点总数',v:total},
  {k:'可用节点',v:succ+' <small>/ '+total+'</small>'},
  {k:'平均延迟',v:avgL==null?'—':avgL+' <small>ms</small>'},
  {k:'平均下载',v:avgD==null?'—':avgD+' <small>MiB/s</small>'},
  {k:'测速时间',v:META.started_at?META.started_at.slice(11,19):'—'},
];
document.getElementById('cards').innerHTML=cards.map(c=>
  '<div class="card"><div class="k">'+c.k+'</div><div class="v">'+c.v+'</div></div>').join('');
document.getElementById('meta-sub').textContent=
  '开始：'+(META.started_at||'—')+'   结束：'+(META.ended_at||'—')+'   模式：'+(META.mode||'延迟+下载');

// TOP5
const top5=RESULTS.filter(r=>get(r,'download.mibps')!=null)
  .sort((a,b)=>get(b,'download.mibps')-get(a,'download.mibps')).slice(0,5);
document.getElementById('top5').innerHTML=top5.length?top5.map(r=>
  '<div class="chip">'+escapeHtml(r.name)+' <b>'+get(r,'download.mibps')+'</b> MiB/s</div>').join('')
  :'<span class="tip">无可用的下载测速结果</span>';

// 订阅链接（Gist）
const gist=META.subscription_gist;
if(gist && (gist.raw_url||gist.html_url)){
  const box=document.getElementById('gist-box');
  const action=gist.action==='新建'?'（首次新建）':'（已更新）';
  let html='<p class="tip">以下订阅为本次达标节点的可用配置，可直接作为客户端订阅源'+action+'</p>';
  if(gist.raw_url){
    html+='<div style="margin:10px 0;"><b>订阅链接</b><br/>'+
      '<code style="display:inline-block;max-width:100%;overflow:auto;padding:8px;background:#0e1530;'+
      'border-radius:8px;border:1px solid rgba(255,255,255,.1);">'+escapeHtml(gist.raw_url)+'</code> '+
      '<a href="'+escapeHtml(gist.raw_url)+'" style="color:var(--primary);">打开</a></div>';
  }
  if(gist.html_url){
    html+='<div style="margin:6px 0;"><b>Gist 页面</b>：<a href="'+escapeHtml(gist.html_url)+
      '" style="color:var(--primary);">'+escapeHtml(gist.html_url)+'</a></div>';
  }
  if(gist.id){
    html+='<div class="tip">Gist ID：<code>'+escapeHtml(gist.id)+
      '</code> —— 回填仓库 Secrets 的 PROXY_SPEEDTEST_GIST_ID 可使后续运行更新同一 Gist 而非新建。</div>';
  }
  box.innerHTML=html;
  document.getElementById('gist-section').style.display='block';
}

// 筛选下拉填充
const provs=[...new Set(RESULTS.map(r=>r.provider).filter(Boolean))].sort();
const types=[...new Set(RESULTS.map(r=>r.type).filter(Boolean))].sort();
document.getElementById('f-provider').insertAdjacentHTML('beforeend',provs.map(p=>'<option>'+escapeHtml(p)+'</option>').join(''));
document.getElementById('f-type').insertAdjacentHTML('beforeend',types.map(t=>'<option>'+escapeHtml(t)+'</option>').join(''));

let sortKey='download.mibps', sortAsc=false;
function escapeHtml(s){return String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));}

function filtered(){
  const q=document.getElementById('search').value.trim().toLowerCase();
  const fp=document.getElementById('f-provider').value;
  const ft=document.getElementById('f-type').value;
  const fs=document.getElementById('f-status').value;
  return RESULTS.filter(r=>{
    if(q && !r.name.toLowerCase().includes(q)) return false;
    if(fp && r.provider!==fp) return false;
    if(ft && r.type!==ft) return false;
    if(fs && statusOf(r)!==fs) return false;
    return true;
  });
}
function renderTable(){
  let rows=filtered().slice();
  rows.sort((a,b)=>{
    let x=get(a,sortKey), y=get(b,sortKey);
    if(x==null) x=sortAsc?Infinity:-Infinity;
    if(y==null) y=sortAsc?Infinity:-Infinity;
    return sortAsc?(x>y?1:x<y?-1:0):(x<y?1:x>y?-1:0);
  });
  const tb=document.querySelector('#tbl tbody');
  tb.innerHTML=rows.map(r=>{
    const st=statusOf(r);
    const dn=get(r,'download.mibps'), up=get(r,'upload.mibps');
    const lm=get(r,'latency.min_ms'), md=get(r,'latency.median_ms');
    return '<tr>'+
      '<td>'+escapeHtml(r.name)+'</td>'+
      '<td>'+escapeHtml(r.type)+'</td>'+
      '<td>'+escapeHtml(r.provider)+'</td>'+
      '<td>'+(lm==null?'—':lm)+'</td>'+
      '<td>'+(md==null?'—':md)+'</td>'+
      '<td>'+(dn==null?'—':dn)+'</td>'+
      '<td>'+(up==null?'—':up)+'</td>'+
      '<td><span class="badge '+st+'">'+(st==='ok'?'可用':'不可用')+'</span></td>'+
    '</tr>';
  }).join('') || '<tr><td colspan="8" class="tip">无匹配节点</td></tr>';
  drawCharts(rows);
}
document.querySelectorAll('#tbl th').forEach(th=>{
  th.addEventListener('click',()=>{
    const k=th.dataset.k;
    if(sortKey===k) sortAsc=!sortAsc; else {sortKey=k; sortAsc=false;}
    renderTable();
  });
});
['search','f-provider','f-type','f-status'].forEach(id=>
  document.getElementById(id).addEventListener('input',renderTable));

// Canvas 图表（原生绘制，无外部依赖）
function drawLatency(rows){
  const c=document.getElementById('latChart'); const ctx=c.getContext('2d');
  const W=c.width=c.clientWidth||420, H=260; ctx.clearRect(0,0,W,H);
  const data=rows.map(r=>({n:r.name,v:get(r,'latency.median_ms')})).filter(d=>d.v!=null);
  if(!data.length){ctx.fillStyle='#9CA3AF';ctx.fillText('无延迟数据',12,20);return;}
  const max=Math.max(...data.map(d=>d.v)); const n=data.length;
  const bw=Math.max(4,W/n-6); const gap=(W-bw*n)/Math.max(1,n);
  data.forEach((d,i)=>{
    const x=i*(bw+gap), h=(d.v/max)*(H-40);
    ctx.fillStyle=colorOf(d.v);
    ctx.fillRect(x,H-h-20,bw,h);
    ctx.fillStyle='#9CA3AF';ctx.font='9px sans-serif';
    ctx.save();ctx.translate(x+bw/2,H-6);ctx.rotate(-Math.PI/4);ctx.fillText(String(d.v),0,0);ctx.restore();
  });
}
function drawDownload(rows){
  const c=document.getElementById('dlChart'); const ctx=c.getContext('2d');
  const W=c.width=c.clientWidth||420, H=260; ctx.clearRect(0,0,W,H);
  let data=rows.map(r=>({n:r.name,v:get(r,'download.mibps')})).filter(d=>d.v!=null);
  data.sort((a,b)=>b.v-a.v);
  if(!data.length){ctx.fillStyle='#9CA3AF';ctx.fillText('无下载数据',12,20);return;}
  const max=Math.max(...data.map(d=>d.v)); const n=data.length;
  const bh=Math.max(8,(H-20)/n-8);
  data.forEach((d,i)=>{
    const y=i*(bh+8)+12, w=(d.v/max)*(W-90);
    ctx.fillStyle=i<3?'#4F8CFF':'#2f5fa8';
    ctx.fillRect(80,y,w,bh);
    ctx.fillStyle='#E5E7EB';ctx.font='10px sans-serif';
    ctx.fillText(d.n.length>12?d.n.slice(0,12)+'…':d.n,4,y+bh-2);
    ctx.fillStyle='#9CA3AF';ctx.fillText(String(d.v),80+w+4,y+bh-2);
  });
}
function drawCharts(rows){drawLatency(rows);drawDownload(rows);}

document.getElementById('footer').innerHTML=
  '测速方法：延迟为经代理对目标 URL 的 HTTP 响应计时（多次取中位数）；下载速度为经 mihomo 代理 '+
  'curl 拉取国内/国际测速点的 MiB/s。节点逐节点串行测量。参数快照：'+
  '<code>size_mib='+META.size_mib+'</code> <code>latency_samples='+META.latency_samples+
  '</code> <code>download_timeout='+META.download_timeout+'s</code> <code>push='+(META.push?'on':'off')+'</code>。'+
  '数据仅供网络质量参考。';

renderTable();
</script>
</body>
</html>
""".replace('__DATA__', data_json).replace('__META__', meta_json)


# ----------------------------------------------------------------------------
# 主流程：复用 mihomo 启动 / 节点快照 / 节点切换，串行测速
# ----------------------------------------------------------------------------
def main():
    started_at = datetime.now().isoformat()
    log_progress('speedtest_started', started_at=started_at, config={
        'latency_samples': CONFIG['PROXY_SPEEDTEST_LATENCY_SAMPLES'],
        'size_mib': CONFIG['PROXY_SPEEDTEST_SIZE_MIB'],
        'download_timeout': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'],
        'push_enabled': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
    })
    env = merged_env()
    try:
        ensure_mihomo_running(env)
    except Exception as e:
        log_progress('mihomo_start_failed', error=str(e))
        write_termination(started_at, f'mihomo 启动失败: {e}')
        return 1

    proxy_env = build_proxy_env(env)

    # 构建订阅源映射：抓取 PROXY_SPEEDTEST_SUBSCRIPTION_URLS 指向的订阅，解析出每个节点的
    # 原始配置（share_link / proxy YAML），供后续导出 gist 订阅使用。无订阅源时跳过（gist
    # 上传会产出空订阅，仍安全返回）。
    try:
        source_mapping = build_source_mapping(env)
        log_progress('source_mapping_built',
                     entries=len(source_mapping.get('exact_proxy') or {}) +
                             len(source_mapping.get('exact_raw') or {}))
    except Exception as e:
        log_progress('source_mapping_failed', error=str(e))
        source_mapping = {}

    # 方案 A：下载测速点解析。仅当用户未显式设置 PROXY_SPEEDTEST_DOWNLOAD_URLS 时，
    # 才从国内滚动目录自动发现 *-latest-*.iso，并合并 npmmirror 最新版 node 直链，
    # 两者均不写死版本号、运行时自动取最新，规避失效。
    if os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_URLS', '').strip():
        download_urls = CONFIG['PROXY_SPEEDTEST_DOWNLOAD_URLS']
        download_source = 'explicit env'
    else:
        download_urls, download_source = resolve_download_urls(
            proxy_env, DEFAULT_DOWNLOAD_CATALOGS, DEFAULT_DOWNLOAD_URLS,
            enable_npmmirror=CONFIG['PROXY_SPEEDTEST_NPMMIRROR_ENABLED'])
    log_progress('download_targets_resolved', count=len(download_urls), source=download_source,
                 urls=download_urls[:4])
    # 注意：仅用独立变量保存 list 型 URL，切勿写回 CONFIG——CONFIG 后续会作为
    # subprocess 的 env 基底（经 build_proxy_env 处理），若混入 list 值会在 git
    # push 时触发 "expected str ... not list"。保持 CONFIG 字段类型稳定。

    try:
        _, alive_items = collect_provider_snapshot(source_mapping)
    except Exception as e:
        log_progress('snapshot_failed', error=str(e))
        write_termination(started_at, f'节点快照失败: {e}')
        return 1

    max_nodes = CONFIG['PROXY_SPEEDTEST_MAX_NODES']
    if max_nodes and max_nodes > 0:
        alive_items = alive_items[:max_nodes]

    log_progress('nodes_collected', count=len(alive_items))
    settle = CONFIG['PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS']
    results = []
    for item in alive_items:
        name = item.get('name', '')
        try:
            switch_proxy(name, settle)
        except Exception as e:
            log_progress('switch_failed', name=name, error=str(e))
            results.append({'name': name, 'type': item.get('type', ''), 'provider': item.get('provider', ''),
                            'ok': False, 'latency': {'ok': False, 'error': f'switch failed: {e}'},
                            'download': {'ok': False, 'error': 'switch failed'},
                            'upload': {'ok': False, 'error': 'disabled'},
                            'source_entry': {}, 'mode': 'download'})
            continue
        node_result = speedtest_single_node(item, proxy_env, CONFIG, download_urls)
        # 挂载该节点的原始订阅配置，供后续导出 gist 订阅；mode 决定 gist 排序度量
        # （开启上行测速时用 upload_mibs，否则用 download_mibs）。
        node_result['source_entry'] = item.get('source_entry', {}) or {}
        node_result['mode'] = 'push-only' if CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'] else 'download'
        results.append(node_result)

    ended_at = datetime.now().isoformat()
    meta = {
        'started_at': started_at,
        'ended_at': ended_at,
        'mode': '延迟+下载' + ('+上行' if CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'] else ''),
        'size_mib': CONFIG['PROXY_SPEEDTEST_SIZE_MIB'],
        'latency_samples': CONFIG['PROXY_SPEEDTEST_LATENCY_SAMPLES'],
        'download_timeout': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'],
        'push': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
    }
    summary = {
        'ok': True,
        'started_at': started_at,
        'ended_at': ended_at,
        'mode': meta['mode'],
        'node_count': len(results),
        'results': results,
    }
    try:
        RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
        RESULT_HTML.write_text(build_html_report(results, meta), encoding='utf-8')
    except Exception as e:
        log_progress('report_write_failed', error=str(e))

    # 隐私防护：报告含节点完整凭据（server/uuid/订阅地址），仅写入运行机本地临时目录，
    # 不再写入仓库（仓库为公开仓库，历史提交曾泄漏敏感信息，已彻底清除）。

    # ----------------------------------------------------------------------
    # 订阅导出 + 上传 Gist：复用 speedtest_gitee 的 build_subscription_yaml_text /
    # update_gist，把达标节点整理成可用订阅并发布到 GitHub Gist（私有）。
    # build_subscription_yaml_text 以 download_mibs / upload_mibs（MiB/s）作为
    # 度量、以 source_entry 提供节点原始配置，这里做一次字段适配。
    # ----------------------------------------------------------------------
    try:
        gist_results = []
        for r in results:
            dl = (r.get('download') or {}).get('mibps')
            ul = (r.get('upload') or {}).get('mibps')
            lat = (r.get('latency') or {}).get('median_ms')
            gist_results.append({
                'name': r.get('name', ''),
                'source_entry': r.get('source_entry') or {},
                'mode': r.get('mode', 'download'),
                'download_mibs': dl if isinstance(dl, (int, float)) else 0,
                'upload_mibs': ul if isinstance(ul, (int, float)) else 0,
                'latency_ms': lat if isinstance(lat, (int, float)) else 0,
            })
        yaml_text = build_subscription_yaml_text(gist_results, DEFAULT_MIN_MEGABIT)
        gist_res = None
        qualified_count = 0
        if (yaml_text or '').strip():
            gist_res = update_gist(env, yaml_text)
            action = '新建' if gist_res.get('created') else '更新'
            print('\n================ 订阅已上传 Gist（%s）================' % action)
            print('订阅链接已写入本地报告与 Telegram 通知，为防隐私泄漏不在日志中输出')
            print('========================================================\n')
            log_progress('gist_uploaded', ok=gist_res.get('ok'), action=action,
                         reason=gist_res.get('reason', ''))
            # 订阅信息记录进本地报告 JSON（原代码引用了未定义的 report_data，已修复）
            summary['subscription_gist'] = {
                'id': gist_res.get('id'), 'html_url': gist_res.get('html_url'),
                'raw_url': (gist_res.get('yaml') or {}).get('raw_url', ''),
                'action': action, 'min_megabit': DEFAULT_MIN_MEGABIT,
            }
            try:
                RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
            except Exception:
                pass
        else:
            log_progress('gist_skipped', reason='empty subscription (no node met min speed)')
        # 达标节点数（与订阅导出同一阈值）
        sort_mode = 'push-only' if CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'] else 'download'
        qualified_count = sum(
            1 for g in gist_results
            if get_item_megabits(g, sort_mode) >= DEFAULT_MIN_MEGABIT and (g.get('source_entry') or {}).get('proxy')
        )
    except Exception as e:
        # gist 上传失败不应中断主流程（报告已生成）
        log_progress('gist_upload_failed', error=str(e))
    try:
        send_telegram(env, '\n'.join(build_telegram_lines(
            results, meta=meta, gist_res=gist_res, qualified_count=qualified_count)))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    log_progress('speedtest_done', node_count=len(results),
                 json_path=str(RESULT_JSON), html_path=str(RESULT_HTML))
    return 0


def _result_metric_item(r):
    """把测速结果 r 适配为 build_node_metric_prefix 可用的指标 dict。"""
    return {
        'upload_mibs': (r.get('upload') or {}).get('mibps'),
        'download_mibs': (r.get('download') or {}).get('mibps'),
        'latency_ms': (r.get('latency') or {}).get('median_ms'),
    }


def build_telegram_lines(results, *, meta, gist_res, qualified_count):
    """生成人性化 Telegram 通知（统一 HTML 版式，对齐全库通知模板）：
    emoji 标题 + ━━━ 分隔线 + 键值概览（数值 <b>）+ 树形 TOP5（节点 <code>）+
    订阅状态 + 统一收尾区（⏱ 已运行 · 🔗 运行日志，读 TG_RUN_URL 环境变量）。"""
    def esc(s):
        return html.escape(str(s))

    push_enabled = bool(meta.get('push'))
    mode = 'push-only' if push_enabled else 'download'
    sort_key = (lambda r: (r.get('upload') or {}).get('mibps') or 0) if push_enabled \
        else (lambda r: (r.get('download') or {}).get('mibps') or 0)
    ok_results = [r for r in results if r.get('ok')]
    top_results = sorted(ok_results, key=sort_key, reverse=True)

    started = str(meta.get('started_at', ''))[:19].replace('T', ' ')
    ended = str(meta.get('ended_at', ''))[:19].replace('T', ' ')
    try:
        duration_text = format_duration(
            (datetime.fromisoformat(meta['ended_at']) - datetime.fromisoformat(meta['started_at'])).total_seconds())
    except Exception:
        duration_text = '-'

    sep = '━' * 18
    lines = [
        '📈 <b>代理节点测速完成</b>',
        sep,
        f'🕒 {esc(started)} ~ {esc(ended)}（耗时 {esc(duration_text)}）',
        f'📊 节点：共 <b>{len(results)}</b> 个 · 可用 <b>{len(ok_results)}</b> 个',
        '',
    ]
    if top_results:
        best = top_results[0]
        lines.append(f"🏆 最快节点：<b>{esc(best.get('name', ''))}</b>")
        lines.append('')
        lines.append('🥇 <b>TOP 5</b>（↓下载 · ↑上传 · 延迟ms）')
        top = top_results[:5]
        for idx, r in enumerate(top, 1):
            prefix = build_node_metric_prefix(_result_metric_item(r), mode)
            connector = '└─' if idx == len(top) else '├─'
            item = f'{connector} {idx}. <code>{esc(r.get("name", ""))}</code>'
            if prefix:
                item += f' · <i>{esc(prefix)}</i>'
            lines.append(item)
        lines.append('')
    else:
        lines.append('⚠️ 没有节点测速成功')
        lines.append('')

    lines.append('📦 <b>订阅（Gist）</b>')
    if gist_res and gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        # 该链接指向 Gist 上的订阅文件（YAML），不是测速报告；
        # HTML 报告只写在运行机本地（含节点凭据，不外传），故无可分享链接。
        raw_url = ((gist_res.get('yaml') or {}).get('raw_url') or '').strip()
        html_url = (gist_res.get('html_url') or '').strip()
        lines.append(f'  └─ ✅ 已{action}，达标 <b>{qualified_count}</b> 个节点（≥{DEFAULT_MIN_MEGABIT}兆）')
        if raw_url:
            lines.append(f'  └─ 🔗 <a href="{esc(raw_url)}">订阅源（YAML）</a>')
        elif html_url:
            lines.append(f'  └─ 🔗 <a href="{esc(html_url)}">Gist 页面</a>')
    elif gist_res:
        lines.append(f"  └─ ⚠️ 上传失败: {esc(gist_res.get('reason', ''))}")
    else:
        lines.append(f'  └─ ⚠️ 无达标节点（阈值 ≥{DEFAULT_MIN_MEGABIT}兆），未更新订阅')

    # 统一收尾区（收尾区与正文间固定一个空行）
    lines.append('')
    tg_run_url = os.environ.get('TG_RUN_URL', '')
    footer = ''
    if tg_run_url:
        footer = f'⏱ 已运行 <b>{esc(duration_text)}</b> · 🔗 <a href="{esc(tg_run_url)}">运行日志</a>'
    elif duration_text != '-':
        footer = f'⏱ 已运行 <b>{esc(duration_text)}</b>'
    if footer:
        lines.append(footer)
    return lines


def write_termination(started_at, reason):
    payload = {
        'ok': False,
        'started_at': started_at,
        'ended_at': datetime.now().isoformat(),
        'reason': reason,
    }
    try:
        RESULT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding='utf-8')
        RESULT_HTML.write_text(build_html_report([], {
            'started_at': started_at, 'ended_at': payload['ended_at'], 'mode': '失败',
            'size_mib': CONFIG['PROXY_SPEEDTEST_SIZE_MIB'],
            'latency_samples': CONFIG['PROXY_SPEEDTEST_LATENCY_SAMPLES'],
            'download_timeout': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'],
            'push': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
        }), encoding='utf-8')
    except Exception:
        pass
    log_progress('speedtest_terminated', reason=reason)
    try:
        abort_msg = (f'📈 <b>代理节点测速异常终止</b>\n{"━" * 18}\n'
                     f'⚠️ {html.escape(str(reason))}')
        abort_footer = ''
        tg_run_url = os.environ.get('TG_RUN_URL', '')
        if tg_run_url:
            abort_footer = f'\n\n⏱ 🔗 <a href="{html.escape(tg_run_url)}">运行日志</a>'
        send_telegram(merged_env(), abort_msg + abort_footer)
    except Exception:
        pass


if __name__ == '__main__':
    import sys
    sys.exit(main())
