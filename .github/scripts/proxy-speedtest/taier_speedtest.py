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
    tg_footer_line,
    tg_format_elapsed,
    update_gist,
    TG_SEP,
)
from speedtest_gitee import (
    MIHOMO,
    MIHOMO_CONFIG,
    MIHOMO_LOG,
    build_mihomo_config,
    build_source_mapping,
    collect_provider_snapshot,
    ensure_local_mihomo,
    switch_proxy,
    wait_mihomo,
)

# ---------------------------------------------------------------------------
# 配置（全部可经环境变量覆盖）
# ---------------------------------------------------------------------------
TAIER_REPO = (os.environ.get('TAIER_REPO') or 'MiaM1ku/taierspeedtest').strip() or 'MiaM1ku/taierspeedtest'
TAIER_RELEASE_API = f'https://api.github.com/repos/{TAIER_REPO}/releases/latest'
TAIER = HOME_RUNTIME / 'taierspeedtest'
TAIER_LOG = HOME_RUNTIME / 'taier_speedtest.log'
RESULT_JSON = HOME_RUNTIME / 'taier_speedtest_result.json'

CONFIG = {
    # 测速点：单个点即可（每点 = 一次完整上下行），多点会成倍拉长单节点耗时
    'TAIER_POINTS': (os.environ.get('TAIER_POINTS', '') or '广东联通').strip(),
    # 默认 single = 单连接：与 proxy-speedtest 系列的单流口径可比，也更贴近日常
    # 单流体验；multi（下 8 + 上 4 连接）看节点带宽上限，both 两者对照
    'TAIER_MODE': (os.environ.get('TAIER_MODE', '') or 'single').strip(),
    # 上游二进制把 --duration 硬钳制在 5-13（main.go），>13 会被压到 13
    'TAIER_DURATION': min(max(int(os.environ.get('TAIER_DURATION', '10') or 10), 5), 13),
    # 0 = 不限（默认）；节点多时整体耗时 ≈ 节点数 × (2×duration + 5)s
    'TAIER_MAX_NODES': int(os.environ.get('TAIER_MAX_NODES', '0') or 0),
    'TAIER_TIMEOUT': int(os.environ.get('TAIER_TIMEOUT', '120') or 120),
    'TAIER_SWITCH_SETTLE': float(os.environ.get('TAIER_SWITCH_SETTLE_SECONDS', '1.5') or 1.5),
    # 每节点是否出结果图（上传图床）：默认关，避免 N 个节点刷 N 张图
    'TAIER_IMAGE': (os.environ.get('TAIER_IMAGE', '0').strip().lower() in ('1', 'true', 'yes', 'on')),
    # 默认不测 IPv6：TUN 下客户端会误判 v6 可用而把单节点耗时翻倍，且多数节点无 v6
    'TAIER_NO_IPV6': (os.environ.get('TAIER_NO_IPV6', '1').strip().lower() not in ('0', 'false', 'no', 'off')),
}

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
# 泰尔控制服务器（引擎 fetchClient 的降级链，原样照抄）
_TAIER_CTRL_SERVERS = [
    'https://dlcv2.cnspeedtest.cn:8443',
    'http://dlc.duoweisoft.com:8096',
    'http://dlcv2.duoweisoft.com:8088',
]
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

    版式由三件套统一的 build_target_network_section 渲染（单测速点 = 4 行 KV 树）；
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


def build_telegram_lines(results, meta, direct_ip, bypass_hits, gist_res, bundle, gist_error=''):
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
    # 标题状态随结论降级（规范 §4 状态 emoji 语义）：0 成功 / 命中「疑似未走代理」→ ⚠️，
    # 不再恒 ✅（此前 ✅ 标题下写着 ⚠️ 疑似未走代理，与 rc=1 的失败判定自相矛盾）
    _title_emoji = '⚠️' if (not ok_results or bypass_hits) else '✅'
    lines = [
        f'<b>{_title_emoji} 泰尔三网测速</b>',
        sep,
        f"🕒 起止：{esc(meta['started_text'])} ~ {esc(meta['ended_text'])} · 耗时 {esc(meta['duration_text'])}",
        f"📊 节点：共 {len(results)} 个 · 成功 {len(ok_results)} 个",
        f"📍 测速点：{esc(meta['points'])} · 模式：{esc(meta['mode_label'])}",
        f"🧪 引擎：<code>taierspeedtest {esc(VERSION['taier'] or 'latest')}</code>",
        '',
    ]
    # 测速点（泰尔服务器）的网络归属：按测速点参数复刻引擎 match 协议定位服务器，
    # 再查其 IP 归属（IP/ISP/ASN/位置）；已在 stop_mihomo_tun() 之后调用（直连视角）
    lines.extend(taier_target_network_lines(meta['points'], direct_ip))
    lines.append('')
    if top:
        # 三件套统一：TOP 条目复用共享的 build_node_metric_prefix（↑上传 · ↓下载 · 延迟ms，
        # 单位「兆」），不再手拼 Mbps —— 此前只有 taier 一处两种单位/分隔符（规范 §1 禁止自造）。
        # 引擎原始值 Mbps → 共享层单位 MiB/s（÷8.388608），与订阅导出口径一致
        _top_mode = 'push-only' if bundle.get('metric', 'upload') == 'upload' else 'download'
        has_up = any((r.get('up') or 0) > 0 for r in top)
        legend = '↑上传 · ↓下载 · 延迟ms' if has_up else '↓下载 · 延迟ms'
        # 标题点出排序依据（= 订阅判定指标），避免读者按 ↓ 数值读不出顺序
        sort_hint = f' · 按{esc(metric_label)}' if metric_label else ''
        lines.append(f'🏆 <b>最快节点 · {len(top)}{sort_hint}</b> · {legend}')
        for idx, r in enumerate(top, 1):
            connector = '└─' if idx == len(top) else '├─'
            prefix = build_node_metric_prefix({
                'upload_mibs': (r.get('up') or 0) / 8.388608,
                'download_mibs': (r.get('down') or 0) / 8.388608,
                'latency_ms': _rtt_to_ms(r.get('rtt')),
            }, _top_mode, order='up_first')
            item = f'  {connector} <code>{esc(r.get("name", ""))}</code>'
            if prefix:
                item += f' · {esc(prefix)}'
            lines.append(item)
        lines.append('')
    else:
        lines.append('⚠️ <b>没有节点测速成功</b>')
        lines.append('')

    if bypass_hits:
        lines.append('⚠️ <b>疑似未走代理</b>')
        lines.append(f"  └─ <b>{bypass_hits} 个节点的出口 IP 与 runner 直连出口（<code>{esc(direct_ip)}</code>）相同，"
                     'TUN 进程规则可能未生效，结果不可信</b>')
        lines.append('')

    failed = [r for r in results if not r.get('ok')]
    if failed:
        lines.append(f'❌ <b>失败 · {len(failed)}</b>')
        _failed_entries = []
        for r in failed[:5]:
            # 原始异常串属机器值 → <code>（标签语义表第 3 类；此前用  与元数据撞语义）
            _failed_entries.append(
                f"<code>{esc(r.get('name', ''))}</code> · <code>{esc((r.get('error') or '-')[:80])}</code>")
        if len(failed) > 5:
            # 折叠行并入条目流，末条 └─ 由下面的循环统一决定（禁双 └─；规范 §2.3）
            _failed_entries.append(f'还有 {len(failed) - 5} 条…')
        for _i, _l in enumerate(_failed_entries, 1):
            _c = '└─' if _i == len(_failed_entries) else '├─'
            lines.append(f'  {_c} {_l}')
        lines.append('')

    lines.append('📦 <b>订阅 · Gist</b>')
    if gist_res and gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        raw_url = ((gist_res.get('yaml') or {}).get('raw_url') or '').strip()
        gist_lines = [f'✅ <b>已{action}，达标 {qualified_count} 个</b> · 阈值 ≥{min_megabit}兆（按{esc(metric_label)}）']
        if gist_res.get('created'):
            gist_lines.append('⚠️ 请把 Gist id 回填到 Secrets <code>PROXY_SPEEDTEST_TAIER_GIST_ID</code>，避免每轮新建')
        if raw_url:
            gist_lines.append(f'🔗 <a href="{esc(raw_url)}">订阅源 YAML</a>')
        for _i, _l in enumerate(gist_lines):
            _c = '└─' if _i == len(gist_lines) - 1 else '├─'
            lines.append(f'  {_c} {_l}')
    elif gist_res:
        lines.append(f"  └─ ⚠️ <b>上传失败</b>：<code>{esc(gist_res.get('reason', ''))}</code>")
    elif gist_error:
        # 上传阶段抛异常（HTTP 4xx 等）≠ 没有达标节点，文案必须区分
        lines.append(f'  └─ ⚠️ <b>上传失败</b>：<code>{esc(gist_error[:120])}</code>')
    else:
        lines.append(f'  └─ ⚠️ <b>达标不足 {min_nodes} 个</b> · 阈值 ≥{min_megabit}兆（按{esc(metric_label)}）· 未更新订阅')
    # 统一收尾区（收尾区与正文间固定**一个**空行）：此前连写两个 append('') 变双空行
    lines.append('')
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    return lines


def notify_failure(env, reason):
    # 先撤 TUN 再发——auto-route 劫持下连 TG API 都可能送不出去。
    # stop_mihomo_tun 可重复调用，main() finally 的二次收尾安全幂等。
    try:
        stop_mihomo_tun()
    except Exception:
        pass
    # 标题直接带原因（reason 形如「环境准备失败：…」，取全角冒号前的阶段名）
    _head = str(reason).split('：')[0].splitlines()[0][:40].strip() or '未知原因'
    lines = [
        f'❌ <b>泰尔三网测速异常退出 · {html.escape(_head)}</b>',
        TG_SEP,
        # reason 含原始异常串（机器值）→ <code>；与 cdn/gitee 的「原因/错误」同口径（裁决 8）
        f'原因：<code>{html.escape(str(reason))}</code>',
        '',
    ]
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    try:
        send_telegram(env, '\n'.join(lines))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))


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
    msg = (f'⛔ <b>泰尔三网测速异常终止</b>\n{TG_SEP}\n'
           f'⚠️ 脚本被中断：收到 <code>{sig_name}</code>，本轮测速未正常完成。')
    footer = tg_footer_line()
    if footer:
        msg += f'\n\n{footer}'
    try:
        send_telegram(merged_env(), msg)
    except Exception:
        pass
    raise SystemExit(128 + int(signum))


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def _run():
    started_at = datetime.now()
    log_progress('taier_speedtest_started', started_at=started_at.isoformat(), config={
        'points': CONFIG['TAIER_POINTS'],
        'mode': CONFIG['TAIER_MODE'],
        'duration': CONFIG['TAIER_DURATION'],
        'max_nodes': CONFIG['TAIER_MAX_NODES'],
    })
    env = merged_env()

    try:
        ensure_local_taier()
        start_mihomo_tun(env)
    except Exception as e:
        log_progress('bootstrap_failed', error=str(e))
        notify_failure(env, f'环境准备失败：{e}')
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
        _, alive_items = collect_provider_snapshot(source_mapping)
    except Exception as e:
        log_progress('snapshot_failed', error=str(e))
        notify_failure(env, f'节点快照失败：{e}')
        return 1

    max_nodes = CONFIG['TAIER_MAX_NODES']
    if max_nodes and max_nodes > 0:
        alive_items = alive_items[:max_nodes]
    log_progress('nodes_collected', count=len(alive_items))

    results = []
    bypass_hits = 0
    for item in alive_items:
        name = str(item.get('name') or '')
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
    # 达标策略（阈值 / 判定指标 / 最少节点数）与三件套共用，见 resolve_subscription_policy：
    # 默认按上行判定，达标不足 min_nodes 时自动改用下行（反之亦然）。
    gist_res = None
    gist_error = ''
    gist_results = [{
        'name': r.get('name', ''),
        'source_entry': r.get('source_entry') or {},
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
        'results': results,
    }
    try:
        RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception as e:
        log_progress('report_write_failed', error=str(e))

    try:
        # 长消息分片发送（失败列表 + Gist 段容易超 4000 字符，单发会被整条拒收）
        tg_res = send_telegram_chunked(env, '\n'.join(build_telegram_lines(
            results, meta, direct_ip, bypass_hits, gist_res, bundle, gist_error)))
        # 发送层不写 stderr（python 侧靠返回值），失败原因必须回传日志（规范 §5）
        log_progress('telegram_send_finished', sent=bool(tg_res.get('sent')),
                     reason=tg_res.get('reason', ''))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    log_progress('taier_speedtest_done', node_count=len(results), bypass_hits=bypass_hits,
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
        # 未捕获异常兜底：标题带原因摘要（gitee 同款）
        try:
            notify_failure(merged_env(), f'未捕获异常：{e}')
        except Exception:
            pass
        return 1
    finally:
        try:
            stop_mihomo_tun()
        except Exception:
            pass


if __name__ == '__main__':
    raise SystemExit(main())
