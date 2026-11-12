#!/usr/bin/env python3
"""CDN 测速（proxy-speedtest-cdn）：订阅节点 → 国内 CDN/镜像站 延迟 + 下载 + 可选上行。

仓库代理测速四套之一（按测速点命名）：测速点是「真实公网站点」——延迟目标
baidu/taobao、下载测速点腾讯云/清华 TUNA 镜像 ISO 与 npmmirror 最新 node 包，
与 gitee（Gitee 私有仓库上行专项）、taier（泰尔三网测速服务器）相区分。

复用 speedtest_common.py 共享层（订阅导出策略 / 通知排版 / 归属查询 / Telegram 发送 /
Gist 上传）与 speedtest_gitee.py 的 mihomo 内核启动 / 节点快照 / 节点切换能力，新增：
  - latency_probe      : 经代理对目标 URL 做 HTTP 计时（延迟）
  - resolve_download_urls: 运行时自动发现国内测速点（滚动 ISO 软链 + npmmirror 最新版），规避写死版本号失效
  - download_speedtest : 经 mixed-port 代理 curl Range 拉取测速点，**单流定窗**（默认 8s）计时，
    速度只算传输段（不含 TTFB）换算 MiB/s（2026-11-05 从定长 10MiB 改口径）
  - gitee_push_speedtest: 经代理 git push 到 Gitee 测上行（复用 speedtest_gitee.git_force_push_testfile）
  - build_html_report  : 生成自包含、可交互 HTML 可视化报告
  - 订阅导出 + Gist 上传: 复用 speedtest_common.build_subscription_bundle / build_target_network_section /
    update_gist，把达标节点的原始配置整理成订阅并发布到本工作流专属 Gist
    （secret PROXY_SPEEDTEST_CDN_GIST_ID；文件名/描述经 PROXY_SPEEDTEST_GIST_FILENAME/
    PROXY_SPEEDTEST_GIST_DESCRIPTION 覆盖，四套各自可辨）

设计原则：
  - 共享能力一律 import 复用：纯共享层来自 speedtest_common，mihomo/订阅源来自
    speedtest_gitee（不改它们的既有行为）。
  - 节点逐节点**串行**测试（共享同一 mihomo 内核，切换后等待 settle）。
  - 自定义参数全部通过环境变量控制（见 CONFIG 区块）。
  - 兜底对齐 gitee：SIGTERM/SIGINT → ⛔ 通知；未捕获异常 → ❌ 通知（标题带原因摘要）。
"""
import json
import math
import os
import html
import pathlib
import re
import signal
import statistics
import subprocess
import time
import urllib.request
from datetime import datetime

import yaml

# ----------------------------------------------------------------------------
# 四套共享层（speedtest_common：进度日志/订阅策略/排版/归属查询/TG 发送/Gist 上传）
# 与 gitee 专项引擎（mihomo 生命周期/订阅源/Gitee 仓库/push 测速）。import 期会创建
# ~/proxy-speedtest 及其 providers/、source-snapshots/ 子目录
# ----------------------------------------------------------------------------
from speedtest_common import (
    HOME_RUNTIME,
    build_node_metric_prefix,
    build_subscription_bundle,
    build_target_network_section,
    direct_egress_ip,
    fetch_ip_network_info,
    latency_probe,
    log_progress,
    merged_env,
    resolve_host_ipv4,
    resolve_subscription_policy,
    send_telegram,
    send_telegram_chunked,
    # 到点收摊判据由共享层提供（四套测速同一份实现，避免各写一遍后漂移）
    should_stop_for_budget,
    speedtest_budget_deadline,
    tg_entry,
    tg_entry_codes,
    tg_footer_line,
    tg_format_elapsed,
    tg_format_time_bj,
    tg_pre_block,
    update_gist,
    TG_SEP,
)
from speedtest_gitee import (
    MIHOMO_MIXED_PORT,
    TEST_FILE_NAME,
    build_proxy_env,
    build_source_mapping,
    check_mihomo_runtime,
    collect_provider_snapshot,
    ensure_gitee_remote,
    ensure_mihomo_running,
    ensure_test_file,
    format_duration,
    git_force_push_testfile,
    # 上行测速与 runner 直连基线（与 Gitee 共用同一份实现）
    run_direct_baseline,
    switch_proxy,
    # 开测前等 provider 展开（否则切节点会静默作用于上一个节点）
    wait_provider_ready,
    upload_speedtest,
)

# ----------------------------------------------------------------------------
# 配置（全部可通过环境变量覆盖）
# ----------------------------------------------------------------------------
DEFAULT_LATENCY_TARGETS = [
    'https://www.baidu.com',
    'https://www.taobao.com',
]
# 方案 A：不写死带版本号的具体 ISO（容易随镜像清理而失效），改为：
#  1) 默认从下列「滚动 ISO 索引目录」自动发现当前存在的 *-latest-*/版本目录内 ISO；
#  2) 仅当用户显式设置 PROXY_SPEEDTEST_DOWNLOAD_URLS 时才使用指定 URL（向后兼容）。
# ⚠️ 2026-10-11 清理：CentOS Stream 8/9 已 EOL，各国内镜像站（TUNA/USTC/阿里/华为/BFSU）
# 的 centos-stream isos 目录实测全部 404（曾导致自动发现只剩腾讯云一个源）。换成
# ubuntu-releases 24.04（163/清华双源实测 206 精确 10MiB Range，版本号随 24.04 LTS
# 点版本滚动，目录长期存在）。
DEFAULT_DOWNLOAD_CATALOGS = [
    'https://mirrors.163.com/ubuntu-releases/24.04/',
    'https://mirrors.tuna.tsinghua.edu.cn/ubuntu-releases/24.04/',
    'https://mirrors.cloud.tencent.com/centos/8-stream/isos/x86_64/',
]
# 兜底写死 URL（仅在自动发现全部失败时使用）：腾讯云 Stream-8 latest 软链实测仍在
# （206 精确 10MiB）；ubuntu 用 24.04 当前点版本，若失效由上面的 catalog 发现兜住。
DEFAULT_DOWNLOAD_URLS = [
    'https://mirrors.cloud.tencent.com/centos/8-stream/isos/x86_64/CentOS-Stream-8-x86_64-latest-boot.iso',
    'https://mirrors.163.com/ubuntu-releases/24.04/ubuntu-24.04.4-live-server-amd64.iso',
]
# 国内厂商 CDN 固定软件测速点：npmmirror（淘宝 npm 镜像）不提供 latest 软链，但可通过
# registry 的 dist-tags 实时拿到最新版本号，拼出「最新版」固定直链（几乎不删旧版本，长期可用）。
# 这样既不写死版本号、又保证是软件最新版，作为镜像站 ISO 之外的日常软件下载带宽代表。
NPMMIRROR_LATEST_API = 'https://registry.npmmirror.com/node'
# ⚠️ 路径必须带 v 前缀（v26.11.1/node-v26.11.1-…）：npmmirror 的 binary 索引按
# <version> 原样建目录，而 dist-tags.latest 给的是无 v 的裸版本号——2026-10-11 实测
# 裸版本号路径 404、v 前缀路径 302→cdn 206（曾因此连续 404，该测速点静默失效）。
NPMMIRROR_NODE_ZIP_TPL = 'https://registry.npmmirror.com/-/binary/node/v{version}/node-v{version}-win-x64.zip'
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
    # 下载上限（MiB）：只作**单次 Range 的请求上界**，不是「必须拉满这么多」。定窗测法
    # 到点就截断，所以这个值要显著大于窗口内能传完的量，否则快节点会先撞上界、把
    # 读数压成「定长 / 定窗」的混合口径。
    'PROXY_SPEEDTEST_SIZE_MIB':
        int(os.environ.get('PROXY_SPEEDTEST_SIZE_MIB', '10')),
    # 单次 curl 的硬超时（秒）：窗口 + 握手 + 收尾余量。窗口到点由 --max-time 截断，
    # 这里只是防 curl 卡死（DNS/连接挂起）的最后一道闸。
    'PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT', '30')),
    # 定窗测法的窗口长度（秒，>0 启用）。**这是单 URL 的计时窗口，不是整轮总预算**
    # （旧名 DOWNLOAD_DURATION 的语义其实是「多个 URL 的总预算」，与名字不符，容易
    # 被误开——旧实现下窗口内没拉完 10MiB 会让 curl 退出 25/28 从而整条 URL 被丢弃，
    # 越开越容易全失败）。见 download_speedtest 的说明。
    'PROXY_SPEEDTEST_DOWNLOAD_WINDOW':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_WINDOW', '8')),
    # 定窗测法下「传输了多少字节才算有效样本」的下限（MiB）。低于它说明连接刚建好就断
    # 或对端返回了极小的错误页，测出的「速度」没有意义，不能进最优值。
    'PROXY_SPEEDTEST_DOWNLOAD_MIN_MIB':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_MIN_MIB', '0.5')),
    # **单节点**下载总预算（秒）：多个测速点串行取最优，窗口是单 URL 的上限，
    # 这个是整个节点所有 URL 加起来的上限。没有它，窗口×URL 数会把单节点耗时推到
    # 4×8=32s（比旧口径的 30s 还慢），与「同预算多测节点」的目标相反。
    # 默认 12s：够测 2 个 URL（首个 8s + 次个 4s），单节点上界从 30s 降到 12s。
    'PROXY_SPEEDTEST_DOWNLOAD_TOTAL_SECONDS':
        float(os.environ.get('PROXY_SPEEDTEST_DOWNLOAD_TOTAL_SECONDS', '12')),
    # 节点切换
    'PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS':
        float(os.environ.get('PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS', '1.5')),
    'PROXY_SPEEDTEST_MAX_NODES':
        int(os.environ.get('PROXY_SPEEDTEST_MAX_NODES', '0')),  # 0=不限
    # 墙钟预算（秒，0 = 不限）。**必须显著小于 job 的 timeout-minutes（默认 360 分钟）**，
    # 留出前置准备（mihomo / 节点快照）与收尾（报告 / 通知 / Gist 上传）的余量：默认 5 小时。
    # 为什么需要它：逐节点串行、单节点几十秒，而 gistnodes 一轮可能交接几千个节点；撞
    # GitHub 的**硬取消**会把整轮工作全废且订阅来不及提交，到点收摊则退出码仍 0、
    # 能拿已测节点出订阅（见 should_stop_for_budget）。
    'PROXY_SPEEDTEST_BUDGET_SECONDS':
        int(os.environ.get('PROXY_SPEEDTEST_BUDGET_SECONDS', '18000') or 0),
    # 下载测速点：是否经 npmmirror 自动发现最新版 node 直链（与滚动 ISO 合并）
    'PROXY_SPEEDTEST_NPMMIRROR_ENABLED':
        (os.environ.get('PROXY_SPEEDTEST_NPMMIRROR_ENABLED', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
    # 可选 Gitee 上行
    'PROXY_SPEEDTEST_ENABLE_PUSH':
        (os.environ.get('PROXY_SPEEDTEST_ENABLE_PUSH', '0').strip().lower() in ('1', 'true', 'yes', 'on')),
    # 上行是否经 mihomo 代理（True=反映代理节点上行带宽；False=直连 Gitee 反映 runner 直连出口上行）
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
    # runner 直连基线（**不是**家庭宽带对照，与 Gitee 同名同默认）。默认**开**：有些对照才有意义。
    # 单列开关，因为直连 push 会往 Gitee 仓库推东西，偶发超时较常见，必要时可关掉。
    'PROXY_SPEEDTEST_DIRECT_BASELINE':
        (os.environ.get('PROXY_SPEEDTEST_DIRECT_BASELINE', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
    'PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT':
        int(os.environ.get('PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT', '60')),
    'PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS':
        int(os.environ.get('PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS', '5')),
}

RESULT_JSON = HOME_RUNTIME / 'speedtest_result.json'
RESULT_HTML = HOME_RUNTIME / 'speedtest_report.html'


# ----------------------------------------------------------------------------
# 延迟测量：latency_probe 已抽到 speedtest_common.py（与 gitee 共用，口径一致）
# ----------------------------------------------------------------------------


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
# 下载测速：curl 经 mixed-port 代理拉取测速点，**定窗**计时换算 MiB/s
# ----------------------------------------------------------------------------
# curl 在 `--max-time` 到点截断时的退出码。**计时要收它**：定窗测法就是「拉满窗口
# 然后自己掐断」，掐断是正常路径而不是失败。实测（本地限速 2MiB/s 服务 +
# 100MiB Range + --max-time 2）：`curl: (28) Operation timed out ... with
# 4194304 out of 104857600 bytes received`，退出码 28，但 `-w` 仍照常输出
# `time_total` / `size_download` —— 所以「非零返回码一律丢弃」会把所有慢节点
# 判成失败，正是定窗测法要解决的问题本身。
CURL_EXIT_OPERATION_TIMEOUT = 28
# 定窗测法可接受的返回码：0（在窗口内拉满上界）与 28（窗口到点截断）。
CURL_DOWNLOAD_OK_EXITS = (0, CURL_EXIT_OPERATION_TIMEOUT)


def download_measurement(exit_code, http_code, size_bytes, time_total, time_starttransfer,
                         min_bytes=0, ok_exits=CURL_DOWNLOAD_OK_EXITS):
    """把 curl 的 `-w` 输出判成一个可用样本；不可用返回 `(None, 原因)`。

    拆成纯函数是为了能被自检直接驱动：这里每条判据的坏法都是**静默产出坏数字**
    （把超时当成功、把错误页当测速、把握手当传输），只有边界能被构造时才看得出来。

    判据四条，缺一不可：

      1. `exit_code` 必须在 `ok_exits` 里（定窗默认 `{0, 28}`）。其余（6 DNS、7 连接
         被拒、56 连接被重置、22 HTTP 错误……）都是真失败，不能因为「反正有字节数」
         就收下。
      2. `http_code < 400`。**这条独立于返回码**：curl 不带 `--fail` 时 HTTP 4xx/5xx
         仍然返回 0，`size_download` 就是那几百字节错误页 —— 不挡的话会算出一个
         「每秒几十字节」参与「多 URL 取最优」的候选（通常落选，但一旦所有测速点都
         4xx，它就成了唯一「成功」值）。
      3. 传输字节数 ≥ `min_bytes`。定窗截断下极小样本（刚建连就断）的
         `bytes / 窗口` 没有意义。
      4. 计时取**传输段**，不含 TTFB：`elapsed = time_total - time_starttransfer`。

    **为什么必须扣掉 TTFB**（2026-11-05 实测）：旧口径 `size / time_total` 把握手算进
    了传输。用当轮 cdn 真实日志（253 个同时有延迟与下载的样本）量化：总耗时中位
    3.51s、HTTP 延迟中位 0.84s ⇒ 握手占总耗时中位 **26%**；本地用一个「握手 0.8s +
    回环满速」的服务复现，同样 10MiB 下 `size/time_total` = 12.35 MiB/s 而
    `size/(total-starttransfer)` = 1144 MiB/s（相差 99%）。代理节点延迟本来就是
    0.5~1.7s 量级，这项污染不是小数。
    """
    if exit_code not in ok_exits:
        return None, f'curl exit {exit_code}'
    if http_code and http_code >= 400:
        return None, f'HTTP {http_code}'
    if size_bytes <= 0:
        return None, 'empty download'
    if min_bytes and size_bytes < int(min_bytes):
        return None, f'too few bytes ({size_bytes} < {int(min_bytes)})'
    transfer = float(time_total or 0) - float(time_starttransfer or 0)
    if transfer <= 0:
        # 传输段算不出来（starttransfer 缺失/等于 total）→ 退回总时长，但至少不能为 0。
        transfer = float(time_total or 0)
    if transfer <= 0:
        return None, 'no elapsed time'
    return {'bytes': size_bytes, 'transfer_seconds': round(transfer, 3),
            'total_seconds': round(float(time_total or 0), 3),
            'ttfb_seconds': round(float(time_starttransfer or 0), 3),
            'mibps': round(size_bytes / 1024 / 1024 / transfer, 2),
            'exit_code': exit_code, 'http_code': http_code}, None


def download_speedtest(urls, proxy_env, timeout=30.0, size_hint_mib=10, window_seconds=0.0,
                       min_mib=0.5, total_seconds=0.0):
    """经代理 curl 拉取测速点，**定窗计时**换算 MiB/s，返回
    {ok, mibps, bytes, seconds, ttfb_seconds, total_seconds, error}。

    测法（2026-11-05 从「定长 10MiB」改为「定窗 8 秒」）：
      * Range 请求上界仍由 `size_hint_mib` 给出，但它只是**上界**——窗口到点
        curl 自己掐断，用已传输的真实字节数算速度；
      * 计时取传输段（扣掉 TTFB），见 `download_measurement`；
      * 每个 URL 串行各测一个窗口，取最优。

    **为什么改成定窗**（旧口径的三个硬伤，都在真实日志里量化过）：
      1. 旧实现「10MiB / 30s 超时」等价于要求节点 ≥0.33 MiB/s，慢但可用的节点被
         整条判成失败（当轮 336 个节点里 62 个 download 为 null）。定窗下 8 秒传多少
         算多少，慢节点也有读数。
      2. 旧实现把 TTFB 算进传输段，系统性低估（实测中位 26%，见 `download_measurement`）。
      3. 单节点下载总耗时上界由「30s」降到「`DOWNLOAD_TOTAL_SECONDS`=12s」
         （窗口只约束单个 URL，整节点另有总预算），同预算能多测约 2 倍节点。

    ⚠️ 口径已变，**与 2026-11-05 之前的历史读数不可直接比**：同一条链路在新口径下
    读数会整体上浮（去掉握手 + 慢节点不再为 null）。订阅名里的兆数也会随之变化。

    ⚠️ curl 必须带 `-L`（2026-10-11 修）：npmmirror 的 node zip 直链返回 302 →
    cdn.npmmirror.com，不带 -L 时 size_download=90（就是 302 响应体本身），
    「10MiB ÷ 4s」换算出一个 0.00002 MiB/s 的假值——因取多 URL 最优它永远落选，
    该测速点自上线起从未真正生效。实测带 -L 后 206、size 精确等于请求量。
    """
    # 代理地址：显式传了 proxy_env 就用它（生产传 build_proxy_env 的结果，即同一个
    # mixed-port）；**传空 dict 表示直连**（自检用本地服务端到端跑真 curl）；
    # 完全不传（None）才退回默认 mixed-port。
    if proxy_env is None:
        proxy = f'http://127.0.0.1:{MIHOMO_MIXED_PORT}'
    else:
        proxy = (proxy_env.get('HTTP_PROXY') or proxy_env.get('HTTPS_PROXY') or '').strip()
    cap_bytes = int(size_hint_mib * 1024 * 1024)
    # `window_seconds<=0` 退回**旧定长行为**：要求拉满上界（截断即算失败）。这样文档里
    # 「≤0 退回旧定长」与代码一致，出问题时有一个已知可用的逃生阀。
    fixed_length = not (window_seconds and window_seconds > 0)
    min_bytes = cap_bytes if fixed_length else int(float(min_mib or 0) * 1024 * 1024)
    # **单节点**总预算：窗口只约束单个 URL，不约束整个节点。没有这个上限，窗口×URL 数
    # （默认 8×4=32s）会比旧口径的 30s 还慢，与「同预算多测节点」的目标相反。
    if fixed_length:
        node_budget = timeout          # 旧语义：整节点共 timeout 秒
        per_url_cap = timeout
    else:
        node_budget = total_seconds if total_seconds and total_seconds > 0 else window_seconds
        per_url_cap = window_seconds
    wall_deadline = time.monotonic() + node_budget
    # 定长模式下截断即失败（只认 0）；定窗模式收 0 与 28。
    accepted_exits = (0,) if fixed_length else CURL_DOWNLOAD_OK_EXITS
    best = None
    last_error = ''
    for u in urls:
        u = u.strip()
        if not u:
            continue
        remaining = wall_deadline - time.monotonic()
        if remaining <= 0:
            break
        per_url_seconds = remaining if fixed_length else min(per_url_cap, remaining)
        if per_url_seconds < 1:
            # 剩余不足 1 秒测不出有意义的速度，不如不收（也避免 --max-time 0/负数）
            break
        # **向上取整**：`int()` 截断会把 2.99 秒变成 2 秒，凭空少测 1 秒（实测端到端
        # 3 秒窗口只跑了 2 秒）。curl 的 --max-time 只接受整数秒。
        curl_max_time = max(1, int(math.ceil(per_url_seconds)))
        range_arg = f'0-{cap_bytes - 1}'
        cmd = ['curl', '-sSL', '-o', '/dev/null']
        if proxy:
            cmd += ['-x', proxy]
        cmd += [
            # time_starttransfer = 首字节时间（≈握手+TTFB），用来把传输段切出来
            '-w', '%{http_code},%{time_total},%{time_starttransfer},%{size_download}',
            '--connect-timeout', '10',
            '--max-time', str(curl_max_time),
            '-r', range_arg,
            '-A', 'Mozilla/5.0', u,
        ]
        try:
            # 子进程超时给足余量：curl 自己会按 --max-time 退，这里只兜「curl 卡死」
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=curl_max_time + 15)
            fields = (out.stdout.strip().split(',') + ['0', '0', '0', '0'])[:4]
            try:
                http_code = int(fields[0] or 0)
                time_total = float(fields[1] or 0)
                time_starttransfer = float(fields[2] or 0)
                size_bytes = int(fields[3] or 0)
            except ValueError:
                last_error = f'bad curl write-out: {out.stdout.strip()[:80]}'
                continue
            measured, reason = download_measurement(
                out.returncode, http_code, size_bytes, time_total, time_starttransfer,
                min_bytes=min_bytes, ok_exits=accepted_exits)
            if measured is None:
                last_error = reason
                # 仅对「真失败」附带 curl 自身的错误串，便于区分 DNS/拒连/重置
                if out.returncode not in accepted_exits and out.stderr.strip():
                    last_error = f'{reason}: {out.stderr.strip().splitlines()[-1][:120]}'
                continue
            cand = {'ok': True, 'mibps': measured['mibps'], 'bytes': measured['bytes'],
                    'seconds': measured['transfer_seconds'],
                    'ttfb_seconds': measured['ttfb_seconds'],
                    'total_seconds': measured['total_seconds'], 'error': None}
            if best is None or cand['mibps'] > best['mibps']:
                best = cand
        except Exception as e:
            last_error = str(e)
    if best is None:
        return {'ok': False, 'mibps': None, 'bytes': 0, 'seconds': None, 'error': last_error}
    return best

# ----------------------------------------------------------------------------
# 上行测速（经 mihomo 代理 git push，反映代理节点上行带宽）
#
# 实现已统一到 speedtest_gitee（2026-09-17）：`upload_speedtest` 一份代码同时支持
# 「经代理」与「直连」两种模式，CDN 与 Gitee 都调它。此前 CDN 自带
# `gitee_push_speedtest` / `_gitee_push_direct` 两份等价实现，靠人工与 Gitee 对齐口径，
# 改一处漏一处——现在删掉，避免再次漂移。
# ----------------------------------------------------------------------------


def gitee_push_speedtest(env, size_mib, push_timeout, branch, via_proxy=True):
    """向 Gitee 私有仓库上行一个固定大小文件，按耗时换算上行 MiB/s。

    - via_proxy=True（默认）：经 mihomo 代理 push，**真正反映代理节点的上行带宽**
      （端点位于中国，符合国内测速要求）；
    - via_proxy=False：直连 Gitee，反映 **runner 直连出口上行**（不是家庭宽带）。
    返回 {ok, mibps, bytes, seconds, error}。
    """
    token = env.get('GITEE_PRIVATE_TOKEN', '').strip()
    if not token:
        return {'ok': False, 'mibps': None, 'error': 'missing GITEE_PRIVATE_TOKEN'}
    owner = env.get('PROXY_SPEEDTEST_GITEE_OWNER', '').strip()
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

    try:
        gitee = ensure_gitee_remote(env)
        test_file = ensure_test_file(int(size_mib))
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': f'prepare gitee/ test file failed: {e}'}

    try:
        measured, total = upload_speedtest(
            env=env,
            gitee=gitee,
            test_file=test_file,
            push_timeout=push_timeout,
            branch_name=branch,
            via_proxy=via_proxy,
            repo_dir=HOME_RUNTIME / 'speedtest-upload-repo',
        )
        if not measured or measured <= 0:
            return {'ok': False, 'mibps': None, 'error': 'upload too fast to measure'}
        return {'ok': True, 'mibps': round(total / 1024 / 1024 / measured, 2),
                'bytes': total, 'seconds': round(measured, 2), 'error': None}
    except Exception as e:
        return {'ok': False, 'mibps': None, 'error': str(e)[:200]}


# ----------------------------------------------------------------------------
# 单节点测试编排
# ----------------------------------------------------------------------------
def proxied_egress_ip(proxy_env, timeout=8):
    """经 mihomo mixed-port 查当前节点的出口 IP（bypass 校验用，2026-10-11 新增）。

    与 direct_egress_ip（共享层）同源不同路：这里必须显式走代理 Handler，
    拿到的是「测速流量实际出口」；两值相同 = 节点切换没生效 / 流量没进节点。
    失败返回 ''（调用方跳过该节点校验，不判死）。
    """
    proxy = proxy_env.get('HTTP_PROXY') or proxy_env.get('HTTPS_PROXY')
    if not proxy:
        return ''
    handlers = [urllib.request.ProxyHandler({'http': proxy, 'https': proxy})]
    opener = urllib.request.build_opener(*handlers)
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip'):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with opener.open(req, timeout=timeout) as r:
                text = r.read().decode('utf-8', 'ignore')
            m = re.search(r'(?:\d{1,3}\.){3}\d{1,3}', text)
            if m:
                return m.group(0)
        except Exception:
            continue
    return ''


def speedtest_single_node(item, proxy_env, cfg, download_urls, direct_ip=''):
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
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_WINDOW'],
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_MIN_MIB'],
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_TOTAL_SECONDS']),
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
    # bypass 校验（2026-10-11 对齐 taier）：经代理查当前节点出口 IP，与 runner 直连
    # 出口相同 = 流量没进节点（切换未生效/节点是透明直连），该节点结果不可信判失败。
    # 查询失败（direct_ip 为空或代理探测失败）→ 跳过校验不判死（fail-open，与 taier 一致）。
    result['exit_ip'] = proxied_egress_ip(proxy_env)
    result['bypass'] = bool(direct_ip and result['exit_ip'] and result['exit_ip'] == direct_ip)
    if result['bypass']:
        result['ok'] = False
        result['bypass_reason'] = f"出口 IP 与 runner 直连出口相同（{direct_ip}），测速流量未进节点"
        log_progress('node_bypass_detected', name=name, exit_ip=direct_ip)
    # 注：upload 字段一并输出，便于从日志直接排查上行测速结果（无需解析最终报告）
    log_progress('node_test_done', name=name, latency_ms=result['latency'].get('median_ms'),
                 download_mibps=result['download'].get('mibps'), upload_mibps=result['upload'].get('mibps'),
                 bypass=result['bypass'])
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
  '<div class="chip">'+escapeHtml(r.name)+' '+get(r,'download.mibps')+' MiB/s</div>').join('')
  :'<span class="tip">无可用的下载测速结果</span>';

// 订阅链接（Gist）
const gist=META.subscription_gist;
if(gist && (gist.raw_url||gist.html_url)){
  const box=document.getElementById('gist-box');
  const action=gist.action==='新建'?'（首次新建）':'（已更新）';
  let html='<p class="tip">以下订阅为本次达标节点的可用配置，可直接作为客户端订阅源'+action+'</p>';
  if(gist.raw_url){
    html+='<div style="margin:10px 0;">订阅链接<br/>'+
      '<code style="display:inline-block;max-width:100%;overflow:auto;padding:8px;background:#0e1530;'+
      'border-radius:8px;border:1px solid rgba(255,255,255,.1);">'+escapeHtml(gist.raw_url)+'</code> '+
      '<a href="'+escapeHtml(gist.raw_url)+'" style="color:var(--primary);">打开</a></div>';
  }
  if(gist.html_url){
    html+='<div style="margin:6px 0;">Gist 页面：<a href="'+escapeHtml(gist.html_url)+
      '" style="color:var(--primary);">'+escapeHtml(gist.html_url)+'</a></div>';
  }
  if(gist.id){
    html+='<div class="tip">Gist ID：<code>'+escapeHtml(gist.id)+
      '</code> —— 回填仓库 Secrets 的 PROXY_SPEEDTEST_CDN_GIST_ID 可使后续运行更新同一 Gist 而非新建。</div>';
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
  'curl 拉取国内镜像站/软件源测速点的 MiB/s——单流定窗：每个测速点拉满 '+
  META.download_window+' 秒（上界 '+META.size_mib+'MiB），速度只算传输段'+
  '（已扣掉首字节时间 TTFB，不把握手折进带宽），慢链路传多少算多少。'+
  '节点逐节点串行测量。参数快照：'+
  '<code>window='+META.download_window+'s</code> <code>size_mib='+META.size_mib+'</code> '+
  '<code>latency_samples='+META.latency_samples+
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
    signal.signal(signal.SIGTERM, handle_termination_signal)
    signal.signal(signal.SIGINT, handle_termination_signal)
    started_at = datetime.now().isoformat()
    # 预算从**进程启动**起算（不是从节点循环起算）：job 的 timeout-minutes 也把前置阶段
    # （mihomo 启动 / 订阅抓取 / 节点快照）算在内，从启动起算才能保证「到点」早于硬取消。
    budget_seconds = CONFIG['PROXY_SPEEDTEST_BUDGET_SECONDS']
    budget_deadline = speedtest_budget_deadline(budget_seconds)
    log_progress('speedtest_started', started_at=started_at, config={
        'latency_samples': CONFIG['PROXY_SPEEDTEST_LATENCY_SAMPLES'],
        'size_mib': CONFIG['PROXY_SPEEDTEST_SIZE_MIB'],
        'download_timeout': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'],
        'download_window': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_WINDOW'],
        'push_enabled': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
        'budget_seconds': budget_seconds,
    })
    env = merged_env()
    try:
        ensure_mihomo_running(env)
    except Exception as e:
        log_progress('mihomo_start_failed', error=str(e))
        write_termination(started_at, f'mihomo 启动失败: {e}')
        return 1

    proxy_env = build_proxy_env(env)

    # bypass 校验基线（2026-10-11 对齐 taier）：runner 直连出口 IP。
    # 拿不到（网络抖动/三源全失败）→ 跳过全部节点的 bypass 校验（fail-open），照常测速。
    direct_ip = direct_egress_ip()
    log_progress('direct_egress_resolved', ip=direct_ip)

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
        provider_snapshot, alive_items = collect_provider_snapshot(source_mapping)
    except Exception as e:
        log_progress('snapshot_failed', error=str(e))
        write_termination(started_at, f'节点快照失败: {e}')
        return 1

    max_nodes = CONFIG['PROXY_SPEEDTEST_MAX_NODES']
    if max_nodes and max_nodes > 0:
        alive_items = alive_items[:max_nodes]

    log_progress('nodes_collected', count=len(alive_items), budget_seconds=budget_seconds)
    settle = CONFIG['PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS']
    # ⚠️ 开测之前先等 provider 真正展开。`wait_mihomo()` 只等 `/version`，
    # `/providers/proxies` 给的又是**声明清单**——不等就切，`switch_proxy` 对「组里
    # 还没注册的成员名」**不报错、静默保持原选择**，于是前几个节点测的是上一个节点的
    # 链路，结果静默失真（比报错更隐蔽）。见 speedtest_gitee.wait_provider_ready。
    # 超时不写死、且按 mihomo **实际加载量** 算（见 speedtest_gitee._provider_ready_timeout）。
    wait_provider_ready([i.get('name') for i in alive_items],
                        total_loaded=sum(int(v.get('total') or 0)
                                         for v in (provider_snapshot or {}).values()))
    results = []

    # runner 直连基线（不是家庭宽带对照）：只测代理节点带宽、不知道 runner 直连是多少，就看不出
    # 「节点比直连还慢」。与 Gitee 共用 run_direct_baseline。失败**不打死整轮**——
    # 基线是参考值，不是交付物；拿不到就记 ok=False，主体测速照常。
    direct_baseline = None
    if CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE']:
        log_progress('direct_baseline_started', timeout=CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT'],
                     max_attempts=CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS'])
        try:
            gitee = ensure_gitee_remote(CONFIG)
            baseline_file = ensure_test_file(int(CONFIG['PROXY_SPEEDTEST_SIZE_MIB']))
            direct_baseline = run_direct_baseline(
                env=CONFIG, gitee=gitee, test_file=baseline_file,
                push_timeout=CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT'],
                clone_timeout=CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT'],
                speedtest_mode='push-only' if CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'] else 'download',
                max_attempts=CONFIG['PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS'],
                label='cdn')
            log_progress('direct_baseline_finished', ok=True,
                         upload_mibs=direct_baseline.get('upload_mibs'),
                         download_mibs=direct_baseline.get('download_mibs'))
        except Exception as e:
            direct_baseline = {'ok': False, 'reason': str(e)[:400],
                               'mode': 'download'}
            log_progress('direct_baseline_finished', ok=False, reason=str(e)[:400])

    # 到点收摊状态：非失败（退出码仍 0），但通知里必须说清「本轮没测完」
    aborted_due_to_runtime = False
    runtime_abort_reason = ''
    for index, item in enumerate(alive_items, 1):
        # 判据放在**开下一个节点之前**：单节点几十秒，所以超发最多一个节点
        if should_stop_for_budget(budget_deadline):
            aborted_due_to_runtime = True
            runtime_abort_reason = (f'到点收摊：预算 {tg_format_elapsed(budget_seconds)}，'
                                    f'已测 {len(results)}/{len(alive_items)} 个节点')
            log_progress('speedtest_budget_stop', index=index, total=len(alive_items),
                         tested=len(results), budget_seconds=budget_seconds)
            break
        # ⚠️ mihomo 运行中健康检查（2026-10-11 补，对齐 gitee 同名机制）：mihomo 中途
        # 挂掉后，mixed-port 连接全部被拒，后续每个节点会各烧一遍「延迟×4 全超时 +
        # 下载全失败」的最长失败窗口（单节点 ≈1 分钟），整轮变成纯烧预算的失败流水；
        # 且此时 curl 报错是「connection refused」——与其他下载失败（镜像 404、Range
        # 不支持）混在一起，事后无法区分「节点都不行」与「测量仪挂了」。检测到即
        # 中止本轮（到点收摊语义，退出码仍 0，拿已测节点照常出订阅/通知）。
        runtime_status = check_mihomo_runtime()
        if not runtime_status['ok']:
            aborted_due_to_runtime = True
            runtime_abort_reason = runtime_status['error']
            log_progress('runtime_abort', index=index, total=len(alive_items),
                         reason=runtime_abort_reason)
            break
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
        node_result = speedtest_single_node(item, proxy_env, CONFIG, download_urls,
                                            direct_ip=direct_ip)
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
        'download_window': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_WINDOW'],
        'push': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
    }
    # 测速点域名（按下载 URL 去重提取，运行时解析的镜像站/软件源），
    # 供通知展示「📍 测速点网络」归属信息
    meta['download_hosts'] = []
    for u in download_urls:
        u = str(u or '').strip()
        host = u.split('/')[2] if u.startswith(('http://', 'https://')) and len(u.split('/')) > 2 else u
        if host and host not in meta['download_hosts']:
            meta['download_hosts'].append(host)
    summary = {
        'ok': True,
        'started_at': started_at,
        'ended_at': ended_at,
        'mode': meta['mode'],
        'node_count': len(results),
        'results': results,
        # runner 直连基线：供通知展示「runner 直连 vs 节点」对照（拿不到时 ok=False，不带数字）
        'direct_baseline': direct_baseline,
        # bypass 校验（与 taier 同口径）：命中数与直连出口，供通知展示「疑似未走代理」
        'direct_egress_ip': direct_ip,
        'bypass_hits': sum(1 for r in results if r.get('bypass')),
        # 到点收摊判据（供下游/事后分析区分「测完」与「没测完但不算失败」）
        'aborted_due_to_runtime': aborted_due_to_runtime,
        'runtime_abort_reason': runtime_abort_reason,
    }
    try:
        RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
        RESULT_HTML.write_text(build_html_report(results, meta), encoding='utf-8')
    except Exception as e:
        log_progress('report_write_failed', error=str(e))

    # 隐私防护：报告含节点完整凭据（server/uuid/订阅地址），仅写入运行机本地
    # ~/proxy-speedtest（不进仓库、不进 Actions 日志）。

    # ----------------------------------------------------------------------
    # 订阅导出 + 上传 Gist：复用 speedtest_gitee 的 build_subscription_yaml_text /
    # update_gist，把达标节点整理成可用订阅并发布到 GitHub Gist（私有）。
    # build_subscription_yaml_text 以 download_mibs / upload_mibs（MiB/s）作为
    # 度量、以 source_entry 提供节点原始配置，这里做一次字段适配。
    # ----------------------------------------------------------------------
    gist_res = None
    bundle = None
    try:
        # 投影走模块级 to_gist_result_row（回归测试直接钉这条线上路径）：旧的内联
        # 写法漏投影 ok 字段，线上白跑六天且不报错，见该函数 docstring。
        gist_results = [to_gist_result_row(r) for r in results]
        # 达标策略（阈值 / 判定指标 / 最少节点数）与四套共用，见 resolve_subscription_policy：
        # 默认按上行判定；上行达标数 < 回退门槛（默认 3）且下行更多时自动改用下行。
        bundle = build_subscription_bundle(gist_results, resolve_subscription_policy(env))
        log_progress('subscription_policy', metric=bundle['metric'], qualified=bundle['qualified'],
                     min_megabit=bundle['min_megabit'], min_nodes=bundle['min_nodes'],
                     fallback=bundle['fallback'])
        if (bundle['text'] or '').strip():
            gist_res = update_gist(env, bundle['text'])
            action = '新建' if gist_res.get('created') else '更新'
            print('\n================ 订阅已上传 Gist（%s）================' % action)
            print('订阅链接已写入本地报告与 Telegram 通知，为防隐私泄漏不在日志中输出')
            print('========================================================\n')
            log_progress('gist_uploaded', ok=gist_res.get('ok'), action=action,
                         reason=gist_res.get('reason', ''), metric=bundle['metric'],
                         qualified=bundle['qualified'])
            # 订阅信息补写进本地报告 JSON（RESULT_JSON 二次回写）
            summary['subscription_gist'] = {
                'id': gist_res.get('id'), 'html_url': gist_res.get('html_url'),
                'raw_url': (gist_res.get('yaml') or {}).get('raw_url', ''),
                'action': action, 'min_megabit': bundle['min_megabit'],
                'metric': bundle['metric'], 'min_nodes': bundle['min_nodes'],
            }
            try:
                RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
            except Exception:
                pass
        else:
            log_progress('gist_skipped', reason='qualified nodes < min_nodes',
                         qualified=bundle['qualified'], min_nodes=bundle['min_nodes'],
                         metric=bundle['metric'])
    except Exception as e:
        # gist 上传失败不应中断主流程（报告已生成）。
        # 抛异常时 gist_res 还是 None，若不带回原因，通知会误报「无达标节点」。
        log_progress('gist_upload_failed', error=str(e))
        gist_res = gist_res or {'ok': False, 'reason': str(e)}
    try:
        # 长消息分片发送（多测速点 + TOP5 + Gist 段容易超 4000 字符，单发会被整条拒收）
        tg_res = send_telegram_chunked(env, '\n'.join(build_telegram_lines(
            results, meta=meta, gist_res=gist_res, bundle=bundle,
            aborted_due_to_runtime=aborted_due_to_runtime,
            runtime_abort_reason=runtime_abort_reason,
            direct_ip=direct_ip, bypass_hits=summary.get('bypass_hits', 0))))
        # 发送层不写 stderr（python 侧靠返回值），失败原因必须回传日志，否则
        # 400 解析失败/限流会表现为「通知静默消失」（规范 · 发送层）
        log_progress('telegram_send_finished', sent=bool(tg_res.get('sent')),
                     reason=tg_res.get('reason', ''))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    log_progress('speedtest_done', node_count=len(results),
                 aborted_due_to_runtime=aborted_due_to_runtime,
                 json_path=str(RESULT_JSON), html_path=str(RESULT_HTML))
    return 0


def _result_metric_item(r):
    """把测速结果 r 适配为 build_node_metric_prefix 可用的指标 dict。"""
    return {
        'upload_mibs': (r.get('upload') or {}).get('mibps'),
        'download_mibs': (r.get('download') or {}).get('mibps'),
        'latency_ms': (r.get('latency') or {}).get('median_ms'),
    }


def to_gist_result_row(r):
    """把一条测速结果投影成订阅判定层（speedtest_common）要的形状。

    ⚠️ ok 必须显式投影（2026-10-18 修）：10-12 起共享层 `count_qualified_nodes`
    要求 `ok=True` 才计入达标（8ada680，修「可用 0 个却导出 24 个达标节点」），
    而原内联投影**不带**该字段 ⇒ 每个节点都按 `item.get('ok', False)` 读出
    False ⇒ 整轮「测出了速度却 qualified=0、订阅不上传」且**不报错**。
    实例见 taier_speedtest.to_gist_result_row 的 docstring（run 39109181078：
    8 个上行达标却 qualified=0，10-12~10-18 六天白跑）。本套（镜像站口径）同病同修。
    回归钉在 tests/test_projection_ok_field.py。
    """
    dl = (r.get('download') or {}).get('mibps')
    ul = (r.get('upload') or {}).get('mibps')
    lat = (r.get('latency') or {}).get('median_ms')
    return {
        'name': r.get('name', ''),
        'source_entry': r.get('source_entry') or {},
        'mode': r.get('mode', 'download'),
        'download_mibs': dl if isinstance(dl, (int, float)) else 0,
        'upload_mibs': ul if isinstance(ul, (int, float)) else 0,
        'latency_ms': lat if isinstance(lat, (int, float)) else 0,
        'ok': bool(r.get('ok')),
        # bypass 一并投影（2026-11-10，与 taier 对齐）：共享层据此过滤
        # 「出口 IP == runner 直连」的不可信读数，不依赖上游是否已置 ok=False。
        'bypass': bool(r.get('bypass')),
    }


def build_telegram_lines(results, *, meta, gist_res, bundle=None,
                         aborted_due_to_runtime=False, runtime_abort_reason='',
                         direct_ip='', bypass_hits=0):
    """生成人性化 Telegram 通知（统一 HTML 版式，对齐全库通知模板）：
    emoji 标题 + ━━━ 分隔线 + 键值概览（数值裸文本）+ 树形 TOP5（节点 <code>）+
    订阅状态 + 统一收尾区（⏱ 已运行 · 🔗 运行日志，读 TG_RUN_URL 环境变量）。"""
    def esc(s):
        return html.escape(str(s))

    # 订阅策略（阈值 / 实际采用的判定指标 / 达标数 / 最少节点数）
    bundle = bundle or {}
    qualified_count = bundle.get('qualified', 0)
    min_megabit = bundle.get('min_megabit', 0)
    min_nodes = bundle.get('min_nodes', 1)
    metric_label = bundle.get('metric_label', '')

    push_enabled = bool(meta.get('push'))
    # 判定指标以订阅策略实际采用的为准（默认上行；上行达标不足时会自动落到下行），
    # 未拿到 bundle 时退回「是否启用上行测速」的既有口径 —— TOP 排序与导出口径必须一致
    metric_mode = bundle.get('metric_mode') or ('push-only' if push_enabled else 'download')
    mode = metric_mode
    sort_key = (lambda r: (r.get('upload') or {}).get('mibps') or 0) if metric_mode == 'push-only' \
        else (lambda r: (r.get('download') or {}).get('mibps') or 0)
    ok_results = [r for r in results if r.get('ok')]
    top_results = sorted(ok_results, key=sort_key, reverse=True)

    # 展示时间统一东八区（规范 · 日期与相对时间）；meta 里原值仍是 UTC 机器值，勿改
    started = tg_format_time_bj(meta.get('started_at', ''))
    ended = tg_format_time_bj(meta.get('ended_at', ''))
    try:
        duration_text = tg_format_elapsed(
            (datetime.fromisoformat(meta['ended_at']) - datetime.fromisoformat(meta['started_at'])).total_seconds())
    except Exception:
        duration_text = '-'

    sep = TG_SEP
    # 标题状态随结论降级（规范 · 状态图标语义）：0 可用节点 → ⚠️，不再恒 ✅
    # 来源标签（PROXY_SPEEDTEST_LABEL）：编排层 proxy-speedtest-gistnodes 调用时传
    # 「gist 节点」，标题变成「gist 节点 · CDN 测速完成」。同一套测速会被定时轮和 gist 抓取轮
    # 分别触发，标题不区分的话读者分不清通知来自哪一轮（规范 · 标题与分隔线允许标题带区分词）。
    # ⚠️ 同 taier：注释与 f-string 都在，赋值行漏了 ⇒ 标题渲染即 NameError、通知静默发不出。
    # 判据与注释、规范（规范 · 结果通知：0 可用节点降级 ⚠️）一致。
    _title_emoji = '⚠️' if (not ok_results or aborted_due_to_runtime) else '✅'
    # 全部可用节点都命中 bypass ⇒ 结果不可信，标题同样降 ⚠️（与 taier 规范一致）
    if ok_results and bypass_hits >= len(ok_results):
        _title_emoji = '⚠️'
    _label = (merged_env().get('PROXY_SPEEDTEST_LABEL') or '').strip()
    _title_prefix = f'{esc(_label)} · ' if _label else ''
    lines = [
        f'{_title_emoji} {_title_prefix}CDN 测速完成',
        sep,
        f'🗓 起止：{esc(started)} ~ {esc(ended)}（东八区） · 耗时 {esc(duration_text)}',
        f'📊 节点：共 {len(results)} 个 · 可用 {len(ok_results)} 个',
        # 到点收摊：**不是失败**（退出码仍 0），但必须说清「本轮没测完」，否则读者会
        # 以为拿到的就是全部节点的结论
        *([f'⚠️ 本轮已中止：{esc(runtime_abort_reason)}'] if aborted_due_to_runtime else []),
        '',
    ]
    # 测速点（下载镜像/软件源）的网络归属：域名 → 解析 IP → ipwho.is 查 ISP/ASN/位置；
    # 统一 KV 树版式（build_target_network_section），多域名逐个成块
    hosts = meta.get('download_hosts') or []
    targets = []
    for h in hosts:
        ip = resolve_host_ipv4(h)
        targets.append((ip or '', h, fetch_ip_network_info(ip) if ip else None))
    lines.extend(build_target_network_section(targets))
    lines.append('')
    # 口径行：下载测法（单流定窗 / 只算传输段）写进通知。2026-11-05 从「定长 10MiB」
    # 改为「定窗」后口径与历史读数不可直接比，必须让读者在通知里就看到，而不是只写在
    # 文档里——否则下轮读数整体上浮会被当成「网络变好了」。
    _window = meta.get('download_window')
    if _window:
        lines.append(f"📐 口径：下载单流定窗 {tg_entry(str(_window) + 's')} 上界 "
                     f"{tg_entry(str(meta.get('size_mib')) + 'MiB')} · 只计传输段（不含 TTFB）")
        lines.append('')
    if top_results:
        top = top_results[:5]
        # 名次类分节用 🏆（规范 · 状态图标：禁 ⭐/🥇 自造前缀；名次类计数裸文本）；
        # 指标顺序对齐泰尔引擎列序（↑上传在前）；上传未启用/未测出时条目自动省略
        # ↑ 项（build_node_metric_prefix 内置），图例同步省略
        has_up = any((_result_metric_item(r).get('upload_mibs') or 0) > 0 for r in top)
        legend = '↑上传 · ↓下载 · 延迟ms' if has_up else '↓下载 · 延迟ms'
        # 标题点出排序依据（= 订阅判定指标），避免与列表数值对不上
        sort_hint = f' · 按{esc(metric_label)}' if metric_label else ''
        lines.append(f'🏆 最快节点 · {len(top)}{sort_hint} · {legend}')
        for idx, r in enumerate(top, 1):
            prefix = build_node_metric_prefix(_result_metric_item(r), mode, order='up_first')
            connector = '└─' if idx == len(top) else '├─'
            # 条目不编号，顺序即名次；条目行统一走 tg_entry（主体 + 元数据，见 规范 · 条目与树形）
            lines.append(f'<code>  {connector} </code>' + tg_entry(r.get("name", ""), prefix))
        lines.append('')
    else:
        lines.append('⚠️ 没有节点测速成功')
        lines.append('')

    # bypass 校验命中分节（与 taier 同款）：有可用节点但全部命中 bypass 时降 ⚠️ 的逻辑
    # 放在标题 emoji 处；这里负责正文交代「多少个节点疑似未走代理」
    if bypass_hits:
        lines.append('⚠️ 疑似未走代理')
        lines.append(f"<code>  └─ </code>{bypass_hits} 个节点的出口 IP 与 runner 直连出口"
                     f"（{tg_entry(direct_ip)}）相同，节点切换可能未生效，结果不可信")
        lines.append('')

    # 失败节点明细（与 taier 对齐：原因可见，便于区分拒测/超时/鉴权失败）
    _failed = [r for r in results if not r.get('ok')]
    if _failed:
        lines.append(f'❌ 失败 · {len(_failed)}')
        # 折叠上限取全库默认 8（规范 · 折叠行；此前本域用 5，与 tree_fold 默认值不一致）
        _fe = [tg_entry_codes(r.get('name', ''), (r.get('error') or r.get('reason') or '-')[:80])
               for r in _failed[:8]]
        if len(_failed) > 8:
            _fe.append(f'还有 {len(_failed) - 8} 条…')
        for _i, _l in enumerate(_fe, 1):
            _c = '└─' if _i == len(_fe) else '├─'
            lines.append(f'<code>  {_c} </code>{_l}')
        lines.append('')

    lines.append('📦 订阅 · Gist')
    if gist_res and gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        # 该链接指向 Gist 上的订阅文件（YAML），不是测速报告；
        # HTML 报告只写在运行机本地（含节点凭据，不外传），故无可分享链接。
        raw_url = ((gist_res.get('yaml') or {}).get('raw_url') or '').strip()
        html_url = (gist_res.get('html_url') or '').strip()
        gist_lines = [f'✅ 已{action}，达标 {qualified_count} 个节点 · ≥{min_megabit}兆（按{esc(metric_label)}）']
        if raw_url:
            gist_lines.append(f'🔗 <a href="{esc(raw_url)}">订阅源 YAML</a>')
        elif html_url:
            gist_lines.append(f'🔗 <a href="{esc(html_url)}">Gist 页面</a>')
        for _i, _l in enumerate(gist_lines):
            _c = '└─' if _i == len(gist_lines) - 1 else '├─'
            lines.append(f'<code>  {_c} </code>{_l}')
    elif gist_res:
        lines.append(f"<code>  └─ </code>⚠️ 上传失败：{tg_entry(gist_res.get('reason', ''))}")
    else:
        lines.append(f'<code>  └─ </code>⚠️ 达标不足 {min_nodes} 个 · 阈值 ≥{min_megabit}兆（按{esc(metric_label)}）· 未更新订阅')

    # 统一收尾区（收尾区与正文间固定一个空行；与 tg_add_footer 同形态同降级链）
    # 注: 正文的「耗时 X」是测速自身耗时，收尾区的「已运行 X」是 run 已运行时长，两者语义不同
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
    """
    # 兜底分支（异常退出/信号终止/未捕获异常）=「必须动手」的告警 → alert 档
    # （规范 · 发送层档位判定；python 发送层已支持 tier，无回落，凭据缺失留痕）
    try:
        res = send_telegram(merged_env(), msg, 'alert')
        log_progress(stage, sent=bool(res.get('sent')), reason=res.get('reason', ''))
    except Exception as e:
        log_progress(f'{stage}_failed', error=str(e))


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
            'download_window': CONFIG['PROXY_SPEEDTEST_DOWNLOAD_WINDOW'],
            'push': CONFIG['PROXY_SPEEDTEST_ENABLE_PUSH'],
        }), encoding='utf-8')
    except Exception:
        pass
    log_progress('speedtest_terminated', reason=reason)
    # 标题直接带原因首行（原文截断后再转义，避免切断 HTML 实体）
    _head = str(reason).splitlines()[0][:40].strip() or '未知原因'
    abort_msg = (f'❌ CDN 测速异常退出 · {html.escape(_head)}\n{TG_SEP}\n'
                 f'原因：{tg_entry(reason)}')
    abort_footer = tg_footer_line()
    if abort_footer:
        abort_msg += f'\n\n{abort_footer}'
    notify_best_effort('abort_notify', abort_msg)


def handle_termination_signal(signum, frame):
    """SIGTERM/SIGINT 兜底：run 被取消/超时也发通知（与 speedtest_gitee 同款）。"""
    sig_name = signal.Signals(signum).name if signum else f'SIGNAL-{signum}'
    msg = (f'⛔ CDN 测速异常终止\n{TG_SEP}\n'
           f'⚠️ 脚本被中断：收到 {tg_entry(sig_name)}，本轮测速未正常完成。')
    footer = tg_footer_line()
    if footer:
        msg += f'\n\n{footer}'
    notify_best_effort('termination_notify', msg)
    raise SystemExit(128 + int(signum))


if __name__ == '__main__':
    import sys
    try:
        sys.exit(main())
    except Exception as e:
        # 未捕获异常兜底：标题直接带原因摘要，正文留完整错误（TG 私聊，不进公开日志）
        _head = str(e).splitlines()[0][:60].strip() if str(e).strip() else '未知异常'
        _msg = (f'❌ CDN 测速异常退出 · {html.escape(_head)}\n'
                f'{TG_SEP}\n'
                f'错误：{tg_entry(f"{type(e).__name__}: {e}"[:800])}')
        # 收尾区不可省（规范 · 收尾区）：兜底通知同样要带 ⏱ 已运行 + 运行日志
        _footer = tg_footer_line()
        if _footer:
            _msg += f'\n\n{_footer}'
        notify_best_effort('uncaught_notify', _msg)
        sys.exit(1)
