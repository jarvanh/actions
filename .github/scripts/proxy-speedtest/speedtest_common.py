#!/usr/bin/env python3
"""proxy-speedtest 三件套共享层（与具体测速引擎无关的公共能力）。

背景：`speedtest_gitee.py` 名字里带 gitee，却长期兼任三件套共享引擎，共享代码越堆越多后
「共享函数挂在 gitee 专项引擎名下」已经名不副实（2026-09-08 用户指出）。本模块承接共享层，
`speedtest_gitee.py` 只保留引擎特有部分（mihomo 生命周期、订阅源解析、Gitee 仓库/push 测速、
运行摘要与 gitee 工作流主流程），按需 import 本模块、不做兼容再导出。

内容分区：
  - 运行时目录 / env 文件读写 / 合并环境（merged_env）/ 进度日志（log_progress，输出前脱敏）
  - 订阅导出策略：阈值 / 判定指标（upload|download）/ 最少节点数（resolve_subscription_policy
    → build_subscription_bundle，双向回退见 resolve_subscription_metric）
  - 速度单位换算、节点名指标前缀、达标订阅 YAML 构建
  - 测速点 IP 归属查询（ipwho.is）与三件套统一的「📍 测速点网络」KV 树分节渲染
  - Telegram 发送层（统一 HTML 版式 + 429 重试 + 长消息分片）与统一收尾行
  - GitHub Gist 订阅上传（update_gist：旧文件名删除探测 + 422 去删除项兜底重试）

依赖方向：speedtest_common ← speedtest_gitee / speedtest / taier_speedtest（单向，禁止反向）。
"""
import html
import json
import os
import pathlib
import re
import socket
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

import yaml

# ---------------------------------------------------------------------------
# 运行时目录与 env 文件
# ---------------------------------------------------------------------------
HOME_RUNTIME = pathlib.Path(os.path.expanduser('~/proxy-speedtest'))
HOME_RUNTIME.mkdir(parents=True, exist_ok=True)
PROVIDERS_DIR = HOME_RUNTIME / 'providers'
PROVIDERS_DIR.mkdir(parents=True, exist_ok=True)
SOURCE_SNAPSHOT_DIR = HOME_RUNTIME / 'source-snapshots'
SOURCE_SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
ENV_PATH = pathlib.Path(os.environ.get('PROXY_SPEEDTEST_ENV_PATH', os.path.expanduser('~/.openclaw/.env')))


def load_env_file(path: pathlib.Path):
    env = {}
    if path.exists():
        for raw in path.read_text(encoding='utf-8').splitlines():
            line = raw.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip()
    return env


def set_env_value(path: pathlib.Path, key: str, value: str):
    lines = []
    found = False
    if path.exists():
        for raw in path.read_text(encoding='utf-8').splitlines():
            stripped = raw.strip()
            if stripped.startswith(f'{key}='):
                lines.append(f'{key}={value}')
                found = True
            else:
                lines.append(raw)
    if not found:
        lines.append(f'{key}={value}')
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + '.tmp')
    tmp_path.write_text('\n'.join(lines).rstrip('\n') + '\n', encoding='utf-8')
    tmp_path.replace(path)


def merged_env():
    env = dict(os.environ)
    env.update(load_env_file(ENV_PATH))
    return env


def deep_copy_json(value):
    """仅用于由 JSON 兼容类型组成的数据结构深拷贝。"""
    return json.loads(json.dumps(value, ensure_ascii=False))


# ---------------------------------------------------------------------------
# 进度日志（输出前对敏感字段自动脱敏）
# ---------------------------------------------------------------------------
# 敏感字段名（小写匹配），值会被自动脱敏
# 注意：仅对「子串匹配会产生误伤」的字段放这里做模糊匹配
_SENSITIVE_KEYS = frozenset({
    'server', 'share_link', 'source_url', 'url', 'password', 'uuid',
    'cipher', 'subscription', 'subscription_url', 'proxy_url',
    'host', 'address', 'remote_public', 'ip', 'ip_city_text',
    'paths', 'path',
})

# 精确匹配的敏感 key（节点身份 / 订阅来源 / 代理原始配置 / 仓库属主等，
# 用精确匹配避免误伤 provider_count、hostname 等无害字段）
_SENSITIVE_EXACT_KEYS = frozenset({
    'name', 'provider', 'type', 'node_type', 'owner',
    'proxy_obj', 'source_entry', 'source_id', 'share_link_match',
    'id', 'raw_url', 'html_url',
})

# 带 userinfo 凭据的 URL（如 https://owner:TOKEN@gitee.com/...），
# 常出现在 git 报错回显中，统一替换为 https://***@
_CRED_URL_RE = re.compile(r'https?://[^/@\s:]+:[^/@\s]+@')

_REDACTED = '***'


def _scrub_cred_urls(text: str) -> str:
    """清除字符串中带凭据的 URL（git 报错会回显 remote_with_token）。"""
    return _CRED_URL_RE.sub('https://***@', text)


def _redact_value(key: str, value):
    """对敏感字段的值进行脱敏，递归处理嵌套 dict/list；普通字符串清除凭据 URL。"""
    kl = key.lower()
    # 精确匹配敏感 key
    if kl in _SENSITIVE_KEYS or kl in _SENSITIVE_EXACT_KEYS:
        return _REDACTED
    # 模糊匹配
    for sk in _SENSITIVE_KEYS:
        if sk in kl:
            return _REDACTED
    if isinstance(value, dict):
        return {k: _redact_value(k, v) for k, v in value.items()}
    if isinstance(value, list):
        return [_redact_value(key, v) for v in value]
    if isinstance(value, str):
        return _scrub_cred_urls(value)
    return value


def log_progress(stage: str, **kwargs):
    payload = {
        'kind': 'progress',
        'stage': stage,
        'time': datetime.now().isoformat(),
    }
    for k, v in kwargs.items():
        payload[k] = _redact_value(k, v)
    print(json.dumps(payload, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------------------
# 速度单位与节点名指标前缀
# ---------------------------------------------------------------------------
DEFAULT_MIN_MEGABIT = 10
# 订阅导出策略默认值（全部可经 env / 仓库 Variables 覆盖，见 resolve_subscription_policy）：
#   阈值（兆） / 判定指标（upload|download） / 上传订阅的最少节点数
DEFAULT_MIN_NODES = 1
DEFAULT_SPEED_METRIC = 'upload'
# 判定指标 → build_mihomo_yaml_text 的 speedtest_mode（push-only = 按上行判定）
METRIC_MODES = {'upload': 'push-only', 'download': 'download'}
METRIC_LABELS = {'upload': '上传', 'download': '下载'}


def _mibs_to_megabits(mibs):
    if isinstance(mibs, (int, float)) and float(mibs) > 0:
        return max(1, int(round(float(mibs) * 8)))
    return 0


def get_item_megabits(item: dict, speedtest_mode: str):
    value = item.get('upload_mibs') if speedtest_mode == 'push-only' else item.get('download_mibs')
    if not isinstance(value, (int, float)) or value <= 0:
        return 0
    return max(1, int(round(float(value) * 8)))


def build_node_metric_prefix(item: dict, speedtest_mode: str, order: str = 'down_first'):
    """生成节点名前的简短指标前缀：主速度（兆）+ 附加指标（另一方向 ↓/↑ 兆、延迟 ms）。

    附加字段缺失时自动省略——如 gitee push-only 模式无下载/延迟数据，保持原「42兆 |」不变；
    出现两项及以上指标时主速度补方向箭头，便于区分上传/下载；主指标缺失时退化为仅展示可用指标。
    order: 指标顺序——'down_first'（默认）= ↓主速度在前，用于订阅节点命名（保持既有格式）；
           'up_first' = ↑上传在前，对齐泰尔引擎列序，用于通知 TOP5 条目。
           上传未测出（0/缺失）时两种顺序下 ↑ 项都自动整项省略。
    """
    push_mode = speedtest_mode == 'push-only'
    upload_mbps = _mibs_to_megabits(item.get('upload_mibs'))
    download_mbps = _mibs_to_megabits(item.get('download_mibs'))
    primary = get_item_megabits(item, speedtest_mode)
    latency_ms = item.get('latency_ms')
    has_latency = isinstance(latency_ms, (int, float)) and latency_ms > 0
    parts = []
    if primary > 0:
        secondary = download_mbps if push_mode else upload_mbps
        labeled = secondary > 0 or has_latency
        if push_mode:
            parts.append(f'↑{primary}兆' if labeled else f'{primary}兆')
            if download_mbps > 0:
                parts.append(f'↓{download_mbps}兆')
        elif order == 'up_first' and upload_mbps > 0:
            parts.append(f'↑{upload_mbps}兆')
            parts.append(f'↓{primary}兆' if labeled else f'{primary}兆')
        else:
            parts.append(f'↓{primary}兆' if labeled else f'{primary}兆')
            if upload_mbps > 0:
                parts.append(f'↑{upload_mbps}兆')
    elif push_mode and download_mbps > 0:
        parts.append(f'↓{download_mbps}兆')
    elif not push_mode and upload_mbps > 0:
        parts.append(f'↑{upload_mbps}兆')
    if has_latency:
        parts.append(f'{latency_ms:.0f}ms')
    return ' '.join(parts)


# ---------------------------------------------------------------------------
# 订阅导出策略（阈值 / 判定指标 / 最少节点数，双向回退）
# ---------------------------------------------------------------------------
def _env_int(env, key: str, default, minimum=0):
    raw = str((env or {}).get(key, '') or '').strip()
    try:
        value = int(raw)
    except (TypeError, ValueError):
        value = int(default)
    return max(minimum, value)


def resolve_subscription_policy(env=None):
    """订阅导出策略（三件套共用，全部经 env 覆盖，workflow 里接仓库 Variables）：

      PROXY_SPEEDTEST_MIN_MEGABIT   达标阈值（兆），默认 10
      PROXY_SPEEDTEST_SPEED_METRIC  判定指标：upload（默认，按上行）/ download（按下行）
      PROXY_SPEEDTEST_MIN_NODES     上传订阅的最少节点数，默认 1

    非法值一律退回默认值（不因配置写错而静默改变口径）。
    """
    env = env if env is not None else merged_env()
    metric = str(env.get('PROXY_SPEEDTEST_SPEED_METRIC') or '').strip().lower()
    if metric not in METRIC_MODES:
        metric = DEFAULT_SPEED_METRIC
    return {
        'min_megabit': _env_int(env, 'PROXY_SPEEDTEST_MIN_MEGABIT', DEFAULT_MIN_MEGABIT, 0),
        'min_nodes': _env_int(env, 'PROXY_SPEEDTEST_MIN_NODES', DEFAULT_MIN_NODES, 1),
        'metric': metric,
    }


def count_qualified_nodes(results: list, metric: str, min_megabit):
    """按指定指标统计达标节点数（须同时有原始配置 source_entry.proxy，否则导不进订阅）。"""
    mode = METRIC_MODES.get(metric, METRIC_MODES[DEFAULT_SPEED_METRIC])
    return sum(
        1 for item in results
        if get_item_megabits(item, mode) >= int(min_megabit)
        and (item.get('source_entry') or {}).get('proxy')
    )


def resolve_subscription_metric(results: list, policy: dict):
    """判定指标选择：主指标达标数 < 最少节点数时改用另一指标（双向对称）。

    例：默认按 upload 判定，达标 0 个（<min_nodes）→ 改用 download 判定；反之若配置
    metric=download 而下行达标不足，则改用 upload。另一指标也不更多时维持主指标
    （最终仍不足 min_nodes 就不上传订阅）。
    """
    metric = policy.get('metric') or DEFAULT_SPEED_METRIC
    other = 'download' if metric == 'upload' else 'upload'
    min_megabit = policy.get('min_megabit', DEFAULT_MIN_MEGABIT)
    min_nodes = policy.get('min_nodes', DEFAULT_MIN_NODES)
    primary = count_qualified_nodes(results, metric, min_megabit)
    if primary >= min_nodes:
        return metric, primary, False
    secondary = count_qualified_nodes(results, other, min_megabit)
    if secondary > primary:
        log_progress('subscription_metric_fallback', from_metric=metric, to_metric=other,
                     primary=primary, secondary=secondary, min_nodes=min_nodes)
        return other, secondary, True
    return metric, primary, False


def build_subscription_bundle(results: list, policy: dict):
    """按策略一次性算出「订阅文本 + 判定指标 + 达标数」，供上传与通知共用。

    text 为空 = 达标节点不足 min_nodes（不上传订阅），调用方据此跳过 update_gist。
    """
    min_megabit = policy.get('min_megabit', DEFAULT_MIN_MEGABIT)
    min_nodes = policy.get('min_nodes', DEFAULT_MIN_NODES)
    metric, qualified, fallback = resolve_subscription_metric(results, policy)
    text = ''
    if qualified >= min_nodes:
        text = build_subscription_yaml_text(
            results, min_megabit, mode=METRIC_MODES.get(metric, METRIC_MODES[DEFAULT_SPEED_METRIC]))
    return {
        'text': text,
        'metric': metric,
        'metric_label': METRIC_LABELS.get(metric, metric),
        'metric_mode': METRIC_MODES.get(metric, METRIC_MODES[DEFAULT_SPEED_METRIC]),
        'qualified': qualified,
        'fallback': fallback,
        'min_megabit': min_megabit,
        'min_nodes': min_nodes,
    }


# ---------------------------------------------------------------------------
# 达标订阅 YAML 构建
# ---------------------------------------------------------------------------
def build_mihomo_yaml_text(results: list, speedtest_mode: str, min_megabit: int = DEFAULT_MIN_MEGABIT):
    proxies = []
    for item in results:
        if get_item_megabits(item, speedtest_mode) < int(min_megabit):
            continue
        source_entry = item.get('source_entry') or {}
        proxy = deep_copy_json(source_entry.get('proxy') or {})
        if not proxy:
            log_progress('subscription_yaml_source_missing', name=item.get('name', ''), share_link_match=item.get('share_link_match', ''), source_id=item.get('source_id', ''))
            continue
        name = str(proxy.get('name') or item.get('name') or '').strip()
        prefix = build_node_metric_prefix(item, speedtest_mode)
        if prefix:
            name = f"{prefix} | {name}"
        proxy['name'] = name
        proxies.append(proxy)
    if not proxies:
        return ''
    return yaml.safe_dump({'proxies': proxies}, allow_unicode=True, sort_keys=False)


def build_subscription_yaml_text(results: list, min_megabit: int = DEFAULT_MIN_MEGABIT, mode: str = ''):
    """根据测速结果生成最终导出的 YAML 订阅文本。

    mode 为空时沿用结果自带的 mode（各脚本按自己测速口径写入）；显式传入则按策略
    判定指标导出（见 resolve_subscription_policy / build_subscription_bundle）。
    """
    if not results:
        return ''
    speedtest_mode = str(mode or results[0].get('mode') or 'push-only')
    return build_mihomo_yaml_text(results, speedtest_mode, min_megabit=min_megabit)


def build_share_link_text(results: list, min_megabit: int = DEFAULT_MIN_MEGABIT, mode: str = ''):
    return build_subscription_yaml_text(results, min_megabit=min_megabit, mode=mode)


# ---------------------------------------------------------------------------
# 经代理的 HTTP 延迟探测（cdn 延迟目标 / gitee.com 握手体验，口径一致）
# ---------------------------------------------------------------------------
def latency_probe(targets, proxy_env, samples=4, timeout=8.0):
    """经代理测量一组目标的延迟（HTTP GET 计时，读首字节），返回
    {ok, min_ms, median_ms, samples, error}。全部失败时 ok=False（调用方降级，不抛异常）。"""
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


# ---------------------------------------------------------------------------
# 测速点 IP 归属查询与「📍 测速点网络」统一分节
# ---------------------------------------------------------------------------
def resolve_host_ipv4(target, timeout=5):
    """域名或 IP → IPv4 字符串；解析失败返回 ''。

    直连 DNS（不经代理、不经 mihomo）：测速点是固定的国内站点，直连解析结果
    即可代表其服务侧归属；传 IP 时原样返回。
    """
    t = str(target or '').strip()
    if not t:
        return ''
    host = t
    if '://' in t:
        host = urllib.parse.urlparse(t).hostname or ''
    host = host.split(':')[0].strip('[]').strip()
    if not host:
        return ''
    if re.match(r'^(?:\d{1,3}\.){3}\d{1,3}$', host):
        return host
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        return infos[0][4][0] if infos else ''
    except Exception:
        return ''


def fetch_ip_network_info(ip, timeout=10):
    """查单个 IP 的网络归属（ISP/ASN/位置），数据源 https://ipwho.is/<ip>。

    与 openclaw.yml / tailscale-windows.yml「🌐 出口网络」同源同款（同一 API）。
    显式禁用环境代理；失败返回 None（调用方降级），不抛异常。
    """
    if not ip:
        return None
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        req = urllib.request.Request(f'https://ipwho.is/{ip}',
                                     headers={'User-Agent': 'Mozilla/5.0'})
        with opener.open(req, timeout=timeout) as r:
            geo = json.load(r)
        if not geo.get('ip'):
            return None
        conn = geo.get('connection') or {}
        asn_line = f"AS{conn['asn']}" if conn.get('asn') else '未知'
        if conn.get('org'):
            asn_line += f" · {conn['org']}"
        loc_parts = [str(x) for x in (geo.get('city'), geo.get('region'), geo.get('country_code')) if x]
        return {
            'ip': str(geo['ip']),
            'isp': str(conn.get('isp') or '未知'),
            'asn': asn_line,
            'loc': ', '.join(loc_parts) if loc_parts else '未知',
        }
    except Exception as e:
        log_progress('target_network_lookup_failed', ip=ip, error=str(e))
        return None


def network_cells(info):
    """归属 dict → (isp, asn, loc) 文本；info=None 或缺项逐项降级「未知」。"""
    if not info:
        return ('未知', '未知', '未知')
    return (info.get('isp') or '未知', info.get('asn') or '未知', info.get('loc') or '未知')


def build_target_network_section(targets):
    """三件套统一的「📍 测速点网络」分节（KV 树版式，2026-09-08 用户拍板）。

    targets 为 [(server, label, info)] 列表：
      server = 测速服务器标识（taier=「ip:port」，cdn/gitee=解析出的 IP；空 = 定位失败）
      label  = 补充标识（taier=服务器主机名，cdn/gitee=测速点域名；可空）
      info   = fetch_ip_network_info() 的归属 dict（None = 查询失败，逐项降级「未知」）

    单测速点（与泰尔版式逐字一致）：
        📍 测速点网络
          ├─ 测速服务器：<server> · <label>
          ├─ ISP：…
          ├─ ASN：…
          └─ 位置：…
    多测速点：每个测速点前加 `[N] <label>` 定位行，测速服务器行只放 server。
    server 为空 → 该块降级为「归属获取失败（label）」。
    """
    esc = lambda s: html.escape(str(s))  # noqa: E731
    targets = list(targets or [])
    if not targets:
        targets = [('', '', None)]
    count_hint = f' · {len(targets)}' if len(targets) > 1 else ''
    lines = [f'📍 测速点网络{count_hint}']
    for idx, (server, label, info) in enumerate(targets, 1):
        server = str(server or '').strip()
        label = str(label or '').strip()
        multi = len(targets) > 1
        if not server:
            fallback = f'（{esc(label)}）' if label else ''
            # 中文原因 → （语义表：条目主体非文件值不得裸文本）
            lines.append(f'  └─ 归属获取失败{fallback}')
            continue
        if multi:
            lines.append(f'[{idx}] <code>{esc(label or server)}</code>')
            lines.append(f'  ├─ 测速服务器：<code>{esc(server)}</code>')
        elif label:
            lines.append(f'  ├─ 测速服务器：<code>{esc(server)}</code> · <code>{esc(label)}</code>')
        else:
            lines.append(f'  ├─ 测速服务器：<code>{esc(server)}</code>')
        isp, asn, loc = network_cells(info)
        lines += [
            f'  ├─ ISP：{esc(isp)}',
            f'  ├─ ASN：<code>{esc(asn)}</code>',
            f'  └─ 位置：{esc(loc)}',
        ]
    return lines


# ---------------------------------------------------------------------------
# Telegram 发送层（统一 HTML 版式；400 不退化，429 重试）
# ---------------------------------------------------------------------------
def send_telegram(env, text):
    """发送 Telegram 消息（统一 HTML parse_mode；429 自动重试，其余失败直接返回
    {'sent': False, ...} 并带上响应体）。文本应使用全库统一 HTML 版式（emoji 标题 + ━━━
    分隔线 + /<code>/ + 统一收尾行）；动态内容一律经 tg_* 助手转义。"""
    bot = env.get('TELEGRAM_BOT_TOKEN') or env.get('TG_BOT_TOKEN')
    chat = env.get('TELEGRAM_CHAT_ID') or env.get('TG_CHAT_ID')
    if not bot or not chat:
        return {'sent': False, 'reason': 'missing TELEGRAM_BOT_TOKEN/TG_BOT_TOKEN or TELEGRAM_CHAT_ID'}

    def _post(data):
        # 429 限流按 retry_after 完整等待重试（规范 §5，与 tg_notify.sh 同语义：5 次尝试）
        for _attempt in range(5):
            payload = urllib.parse.urlencode(data).encode()
            req = urllib.request.Request(f'https://api.telegram.org/bot{bot}/sendMessage',
                                         data=payload, method='POST')
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                body = e.read().decode('utf-8', 'replace')
                if e.code == 429:
                    m = re.search(r'"retry_after":(\d+)', body)
                    time.sleep(int(m.group(1)) if m else 5)
                    continue
                raise HTTPErrorWithBody(e, body)
        raise RuntimeError('telegram 429 retry exhausted')

    class HTTPErrorWithBody(urllib.error.HTTPError):
        # 保留响应体供外层输出错误信息
        def __init__(self, e, body):
            super().__init__(e.url, e.code, e.msg, e.hdrs, e.fp)
            self.body_text = body

    # 不退化纯文本重发：HTML 解析失败时消息本就没发出去，退化只会把版式 bug 藏起来
    data = {'chat_id': chat, 'disable_web_page_preview': 'true',
            'parse_mode': 'HTML', 'text': text}
    try:
        res = _post(data)
    except urllib.error.HTTPError as e:
        body = getattr(e, 'body_text', None)
        if body is None:
            body = e.read().decode('utf-8', 'replace')
        return {'sent': False, 'reason': body[:200]}
    if res.get('ok'):
        return {'sent': True, 'response': res}
    return {'sent': False, 'response': res}


# 统一分隔线（18 个全角横线）：与 bash 真源 telegram/tg_notify.sh 的 TG_SEP 同值。
# python 侧此前 10 处各写 '━' * 18，改版式要逐处改；三件套一律 import 本常量
TG_SEP = '━' * 18

TG_CHUNK_SIZE = 4000


def send_telegram_chunked(env, text):
    """长消息按 4000 字符分片发送（规范 §5：断在换行处，不切 UTF-8 多字节字符，
    与 tg_notify.sh send_tg_chunked 同语义）；短消息直接走 send_telegram。"""
    if not text:
        return {'sent': True}
    if len(text) <= TG_CHUNK_SIZE:
        return send_telegram(env, text)
    chunks = []
    i, n = 0, len(text)
    while i < n:
        end = min(i + TG_CHUNK_SIZE, n)
        if end < n:
            last_nl = text.rfind('\n', i, end)
            if last_nl > i + TG_CHUNK_SIZE // 2:
                end = last_nl + 1
        chunks.append(text[i:end])
        i = end
    results = []
    for idx, chunk in enumerate(chunks):
        results.append(send_telegram(env, chunk))
        if idx < len(chunks) - 1:
            time.sleep(2)
    return {'sent': all(r.get('sent') for r in results),
            'chunks': len(chunks), 'results': results}


def tg_format_elapsed(seconds):
    """已运行时长的中文三段式（与 tg_add_footer 同源同形态，勿再自造 40s/5h57m）。

    规则: >=1h → "X 小时 Y 分"；>=1min → "X 分钟"；否则 → "X 秒"
    注意与 format_duration 分工: 后者是「耗时」的紧凑写法，用于正文；
    本函数用于收尾区，必须与全库通知的 tg_add_footer 逐字一致。
    """
    total = int(max(0, round(seconds)))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f'{h} 小时 {m} 分'
    if m:
        return f'{m} 分钟'
    return f'{s} 秒'


def tg_entry(subject, *meta, code: bool = True):
    """条目行构造器（与 bash 真源 tg_entry 同语义，2026-09-10 新增）。

    消灭语义表 #4/#5 的"手写"：条目主体 + 元数据统一 " · " 分隔、统一转义、
    顺序固定。code=True 用于机器值主体（文件名/路径/ID/命令），False 用于
    文字主体（节点名以外的短语）。
    输出: "<code>主体</code> · 元数据 · 元数据"（不含换行，由调用方拼接）
    """
    out = f'<code>{html.escape(str(subject))}</code>' if code else html.escape(str(subject))
    for m in meta:
        if m not in (None, ''):
            out += f' · {html.escape(str(m))}'
    return out


def _tg_entry2(sep: str, a, b, *meta) -> str:
    out = f'<code>{html.escape(str(a))}</code>'
    if b not in (None, ''):
        out += f'{sep}<code>{html.escape(str(b))}</code>'
    for m in meta:
        if m not in (None, ''):
            out += f' · {html.escape(str(m))}'
    return out


def tg_entry_pair(a, b=None, *meta) -> str:
    """双机器值条目（语义表 #10）："<code>A</code> → <code>B</code> · 元数据"。

    → 表达替换/映射关系（原名 → 替代名），不可写成 " · "；第二主体为空时自动省略。
    """
    return _tg_entry2(' → ', a, b, *meta)


def tg_entry_codes(a, b=None, *meta) -> str:
    """并列双机器值条目（语义表 #10）："<code>A</code> · <code>B</code> · 元数据"。

    无主次关系（如节点名 · 原始异常串），与 tg_entry 的区别是第二个值也是机器值。
    """
    return _tg_entry2(' · ', a, b, *meta)


def tg_pre_block(text: str) -> str:
    """多行块（日志/命令/异常栈）：统一 <pre> 包裹 + 转义（与 bash tg_add_pre 同义）。"""
    return f'<pre>{html.escape(str(text))}</pre>'


def tg_footer_line():
    """全库唯一收尾行: "⏱ 已运行 X · 🔗 <a>运行日志</a>"

    与 tg_add_footer（telegram/tg_notify.sh）同形态、同降级链:
      无 TG_RUN_STARTED_AT → 兜底 /proc/1 启动时刻（hosted runner PID 1 随 job
      启动，误差秒级——GitHub 平台已于 2026-09-05 移除 github.run_started_at 上下文）；
      仍取不到 → 不显示时长；无 TG_RUN_URL → 整行跳过
    时长 = run 已运行时长，非测速耗时
    """
    line = ''
    elapsed = 0.0
    started_at = os.environ.get('TG_RUN_STARTED_AT', '')
    if started_at:
        try:
            st = datetime.fromisoformat(str(started_at).replace('Z', '+00:00'))
            if st.tzinfo is None:
                elapsed = (datetime.now() - st).total_seconds()
            else:
                elapsed = (datetime.now(st.tzinfo) - st).total_seconds()
        except Exception:
            elapsed = 0.0
    if elapsed <= 0:
        try:
            elapsed = max(0.0, time.time() - int(os.stat('/proc/1').st_mtime))
        except Exception:
            elapsed = 0.0
    if elapsed > 0:
        line = f'⏱ 已运行 {html.escape(tg_format_elapsed(elapsed))}'
    run_url = os.environ.get('TG_RUN_URL', '')
    if run_url:
        if line:
            line += ' · '
        line += f'🔗 <a href="{html.escape(run_url)}">运行日志</a>'
    return line


# ---------------------------------------------------------------------------
# GitHub Gist 订阅上传
# ---------------------------------------------------------------------------
def _http_error_with_body(e):
    """把 HTTPError 的响应体并进异常文本——只有状态码看不到 GitHub 的报错原因。

    Gist 422 之类的失败，光看 `HTTP Error 422: Unprocessable Entity` 完全无法定位
    （真实原因在 body 的 errors[].field 里），这里把 body 截断附到 msg 上。
    """
    body = ''
    try:
        body = (e.read() or b'').decode('utf-8', 'ignore').strip()
    except Exception:
        body = ''
    msg = str(e.reason or '')
    if body:
        msg = f'{msg} | {body[:300]}'
    return urllib.error.HTTPError(e.url, e.code, msg, e.headers, e.fp)


def github_api_request(url: str, token: str, payload=None, method='GET', timeout=60):
    data = None
    headers = {
        'Authorization': f'token {token}',
        'User-Agent': 'Mozilla/5.0',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
    }
    if payload is not None:
        data = json.dumps(payload).encode()
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # 保留 HTTPError 类型（调用方按 e.code 分流），但带上响应体便于定位
        raise _http_error_with_body(e) from None


GIST_DEFAULT_FILENAME = 'proxy_speedtest_subscription.yaml'
GIST_DEFAULT_DESCRIPTION = 'proxy speedtest subscription result'


def _gist_identity(env):
    """Gist 文件名/描述，允许各测速工作流经 env 覆盖（三件套各用各的 Gist，便于区分）。"""
    filename = (env.get('PROXY_SPEEDTEST_GIST_FILENAME') or '').strip() or GIST_DEFAULT_FILENAME
    description = (env.get('PROXY_SPEEDTEST_GIST_DESCRIPTION') or '').strip() or GIST_DEFAULT_DESCRIPTION
    return filename, description


def create_gist(env, yaml_text=''):
    token = env.get('GH_TOKEN')
    yaml_filename, description = _gist_identity(env)
    if not token:
        return {'ok': False, 'reason': 'missing GH_TOKEN'}
    if not (yaml_text or '').strip():
        return {'ok': False, 'reason': 'empty subscription text'}
    payload = {
        'description': description,
        'public': False,
        'files': {
            yaml_filename: {'content': yaml_text},
        },
    }
    res = github_api_request('https://api.github.com/gists', token, payload=payload, method='POST')
    files = res.get('files') or {}
    yaml_raw_url = ''
    if isinstance(files, dict):
        yaml_raw_url = ((files.get(yaml_filename) or {}).get('raw_url') or '').strip()
    gist_id = (res.get('id') or '').strip()
    if gist_id:
        env['PROXY_SPEEDTEST_GIST_ID'] = gist_id
        set_env_value(ENV_PATH, 'PROXY_SPEEDTEST_GIST_ID', gist_id)
    return {
        'ok': True,
        'id': gist_id,
        'html_url': res.get('html_url'),
        'yaml': {'filename': yaml_filename, 'raw_url': yaml_raw_url},
        'created': True,
    }


def gist_has_file(env, gist_id, filename, token=''):
    """目标 Gist 里是否已存在 filename（查询失败一律返回 False，即「当它不存在」）。

    用于「旧文件名是否还需要删」的判定：见 update_gist 的说明。
    """
    token = token or env.get('GH_TOKEN')
    if not (token and gist_id and filename):
        return False
    try:
        res = github_api_request(f'https://api.github.com/gists/{gist_id}', token)
    except Exception as e:
        log_progress('gist_probe_failed', gist_id=gist_id, error=str(e))
        return False
    return filename in ((res or {}).get('files') or {})


def _patch_gist(gist_id, token, payload):
    return github_api_request(
        f'https://api.github.com/gists/{gist_id}', token, payload=payload, method='PATCH')


def update_gist(env, yaml_text=''):
    token = env.get('GH_TOKEN')
    gist_id = env.get('PROXY_SPEEDTEST_GIST_ID', '').strip()
    yaml_filename, description = _gist_identity(env)
    if not token:
        return {'ok': False, 'reason': 'missing GH_TOKEN'}
    if not (yaml_text or '').strip():
        return {'ok': False, 'reason': 'empty subscription text'}
    if not gist_id:
        return create_gist(env, yaml_text)
    files_payload = {}
    # 文件名变更：旧文件必须显式置 null 才会被删除，否则新旧并存分不清。
    # 但旧文件一旦已被删掉（迁移后的第二轮起），再发 null 会让 GitHub 认为 files
    # 里没有任何有效文件 → 422 Validation Failed / missing_field: files，整轮订阅
    # 上传失败（三件套曾因此连续多轮「无达标节点」）。故只在旧文件确实存在时发删除项。
    if yaml_filename != GIST_DEFAULT_FILENAME and gist_has_file(env, gist_id, GIST_DEFAULT_FILENAME, token):
        files_payload[GIST_DEFAULT_FILENAME] = None
    files_payload[yaml_filename] = {'content': yaml_text}
    payload = {
        'description': description,
        'public': False,
        'files': files_payload,
    }
    try:
        res = _patch_gist(gist_id, token, payload)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return create_gist(env, yaml_text)
        if e.code == 422 and GIST_DEFAULT_FILENAME in files_payload and files_payload[GIST_DEFAULT_FILENAME] is None:
            # 兜底：删除项引发 422（旧文件其实已不存在 / API 口径变动）→ 去掉删除项重试一次
            log_progress('gist_patch_retry_without_delete', gist_id=gist_id, error=str(e))
            files_payload.pop(GIST_DEFAULT_FILENAME, None)
            payload['files'] = files_payload
            res = _patch_gist(gist_id, token, payload)
        else:
            raise
    files = res.get('files') or {}
    yaml_raw_url = ''
    if isinstance(files, dict):
        yaml_raw_url = ((files.get(yaml_filename) or {}).get('raw_url') or '').strip()
    return {
        'ok': True,
        'id': res.get('id'),
        'html_url': res.get('html_url'),
        'yaml': {'filename': yaml_filename, 'raw_url': yaml_raw_url},
        'created': False,
    }
