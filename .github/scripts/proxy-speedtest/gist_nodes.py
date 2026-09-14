#!/usr/bin/env python3
"""从 gist.github.com 抓公开订阅 → 交给 Sub-Store 去重 → 取回 mihomo YAML → 发布到 Gist。

用途：`proxy-speedtest-gistnodes.yml` 的取节点步骤。三套测速工作流（gitee / cdn / taier）
原本只吃仓库 secret `PROXY_SPEEDTEST_SUB_URLS` 里的固定订阅源；本脚本给出第二条来源：
按关键词搜索 Gist、取「最近更新」（`s=updated`）排序的前若干页，只保留最近
`GIST_NODES_MAX_AGE_HOURS` 小时（默认 24）内更新过的，把命中的订阅正文原样丢进
一个临时 Sub-Store 后端，让 Sub-Store 自己解析 + 去重 + 产出 mihomo（ClashMeta）YAML，
再把这个 YAML 发布到本工作流专属 Gist；编排工作流把 Gist 的 raw URL 当 `sub_urls`
传给选定的测速工作流。

为什么要卡「最近 N 小时」这个窗口：Gist 搜索命中的很多是**早已停更的旧订阅**，
里面的节点多半已经失效，测一轮纯属浪费；卡住窗口就只拿最近还在更新的源。
注意它**挡不住**另一类噪声：搜索结果按 updated 排序时，前排会被一批「每分钟都在
更新的统计/日志 Gist」占满——它们正文是 JSON，只因为碰巧含 `ss://` 字样就被搜到
（实测前 10 个 Gist 的 50 个文件里只有 16 个真是订阅），而且因为它们更新最勤，
永远排在前面。这类噪声靠 `looks_like_subscription` 在取文阶段挡掉，窗口对它无效。

为什么去重与格式转换交给 Sub-Store、而不是在本脚本里做：节点链接 → 各内核配置对象的
还原规则（每种协议的字段、TLS/传输层语义、去重判据）是 Sub-Store 的领域知识，本脚本
只负责「搬运」——搜索、取文、投喂、取回。这样既避免在仓库里养一份容易过时的协议实现，
也让产物与 Sub-Store 网页端手工导出的完全同源。

为什么经 Gist 中转、而不是把节点塞进入参：节点列表几十到几百 KB，workflow_call /
workflow_dispatch 的入参不适合承载大文本；raw URL 是一个短字符串，下游 `fetch_text`
直接 GET 即可（secret Gist 的 raw URL 无需鉴权——不可猜的 URL 本身就是凭据）。

Sub-Store 接口（读 backend/src/restful/*.js 得到，全部是无需鉴权的本机 HTTP）：
  POST /api/subs                            建订阅；本地内容订阅用 {name, source:'local', content}
  POST /api/collections                     建组合订阅 {name, subscriptions:[订阅名...], process:[...]}
  GET  /download/collection/<名>/<target>   产出订阅；target=ClashMeta 即 mihomo YAML
去重与清理都用它的内置算子（名字即 process 里的 type）：
  'Useless Filter'              清掉「剩余流量/到期时间」这类信息节点与非 ASCII 凭据
  'Handle Duplicate Operator'   去重（action=delete 按 field 组合判重）与重名重命名
  'Script Operator'             限量（只在需要限节点数时追加）

环境变量（除 token 外全部可选）：
  GIST_NODES_QUERIES       搜索关键词，逗号分隔（默认 ss://,vless://,vmess://,trojan://,hysteria2://,tuic://）
  GIST_NODES_PAGES         每个关键词翻几页（默认 5，每页 10 条；收够配额即停，通常只翻 2 页）
  GIST_NODES_SORT          搜索排序（默认 updated = 最近更新）
  GIST_NODES_MAX_AGE_HOURS 只收最近 N 小时内更新过的 Gist（默认 24，0 = 不限）
  GIST_NODES_MAX_GISTS     最多解析多少个 Gist（默认 100，名额按关键词均分）
  GIST_NODES_MAX_SUBS      最多投喂多少个订阅（默认 120，一个 Gist 的多个文件各算一个）
  GIST_NODES_MAX_TOTAL_MB  投喂内容总量上限（默认 24 MB）
  GIST_NODES_MAX_FILE_MB   单个 Gist 文件超过多少 MB 跳过（默认 2）
  GIST_NODES_MAX_NODES     最终订阅最多保留多少节点（默认 300，0 = 不限）
  GIST_NODES_TIMEOUT       单次 HTTP 超时秒数（默认 30）
  GIST_NODES_RETRIES       搜索页返回空结果块时的重试次数（默认 3）
  GIST_NODES_PAGE_DELAY    搜索页翻页之间的间隔秒数（默认 2，0 = 不间隔）
  GIST_NODES_WORKERS       并发取 Gist 的线程数（默认 8，1 = 串行）
  GIST_NODES_DRY_RUN       1 = 只抓取不发布（本地验证用）
  GIST_NODES_WORKDIR       产物目录（默认 ~/proxy-speedtest/gist-nodes）
  SUB_STORE_BACKEND_URL    Sub-Store 后端地址（默认 http://127.0.0.1:3001）
  SUB_STORE_TIMEOUT        调用 Sub-Store 的超时秒数（默认 300，全量解析 + 去重耗时较长）
  SUB_STORE_COLLECTION     组合订阅名前缀（默认 gist-nodes）
  GH_TOKEN / GITHUB_TOKEN  GitHub API 认证（缺失时匿名调用，易被限流）
  PROXY_SPEEDTEST_GIST_ID / _FILENAME / _DESCRIPTION
                           发布目标 Gist（复用共享层 update_gist 的既有约定）

输出（写入 $GITHUB_OUTPUT，供编排工作流传给测速工作流）：
  sub_url / count / parsed_count / gists_scanned / gist_html_url / gist_id

失败语义：单个 Gist / 单个订阅失败只跳过它；Sub-Store 不可达、组合订阅产出失败、
或最终一个节点都没有 → exit 1。与其让下游拿空订阅跑一轮 45 分钟测速，不如就地失败。
"""
import base64
import concurrent.futures
import html as html_lib
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import yaml

# 脚本可能经软链被调用：按物理路径定位同目录模块（与仓库内其他脚本同一约定）。
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from speedtest_common import github_api_request, log_progress, merged_env, update_gist  # noqa: E402

SEARCH_URL = 'https://gist.github.com/search'
GIST_API = 'https://api.github.com/gists/{gist_id}'

DEFAULT_QUERIES = 'ss://,vless://,vmess://,trojan://,hysteria2://,tuic://'
DEFAULT_SUB_STORE = 'http://127.0.0.1:3001'
DEFAULT_MAX_AGE_HOURS = 24

# 搜索结果块：服务端渲染的 HTML，每块一个 Gist。
SNIPPET_MARK = '<div class="gist-snippet">'
GIST_LINK_RE = re.compile(r'href="/([A-Za-z0-9_.-]+)/([0-9a-f]{32})"')
UPDATED_RE = re.compile(r'datetime="([0-9T:+\-Z.]+)"')
# 单块截断长度：块里会内联文件预览，取前 40 KB 足够覆盖到 meta 区的链接与时间。
CHUNK_LIMIT = 40000

# 「这文件像不像订阅」的判据：出现任一协议 scheme 或 Clash 的 proxies 段就交给 Sub-Store 试。
# 只判「有没有节点」，不做解析——解析是 Sub-Store 的活，判错了它只会让该订阅报
# 「不含有效节点」并跳过。为什么不用宽松的 '://'：那会把 XML plist、普通文档里
# 的 https:// 全放进来，白白占投喂配额与 Sub-Store 的解析时间（实测 10 个 Gist
# 里有 18 个文件属于这种噪声）。
SUBSCRIPTION_MARKERS = ('ss://', 'ssr://', 'vmess://', 'vless://', 'trojan://',
                        'hysteria://', 'hysteria2://', 'hy2://', 'tuic://',
                        'snell://', 'wireguard://', 'proxies:', 'proxy-providers:')
# base64 订阅的字符集（含 urlsafe 的 -_ 与填充 =），用于「整段是不是 base64」的粗判。
B64_ALPHABET = frozenset('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=-_')

# 去重判据（Handle Duplicate Operator 按这些字段拼 key，缺失字段记 '-'）。
# 刻意不含 name：同一个节点在不同 Gist 里名字几乎必然不同，带上名字就等于不去重。
# 含 type/server/port + 各自凭据字段 + 传输层特征：同机同端口同凭据但传输层不同，
# 视为不同节点（保守，宁可少去重也不误删）。
DEDUPE_FIELDS = ['type', 'server', 'port', 'uuid', 'password', 'cipher',
                 'network', 'path', 'host', 'servername', 'sni', 'plugin']

# 统计口径（贯穿日志与 nodes.json）。键名刻意避开共享层 _redact_value 的敏感子串：
# 'ip' 是模糊匹配项，任何含 skipped 的键名（如 file_skipped）都会被整条打成 ***。
STAT_KEYS = ('gists_scanned', 'gist_errors', 'oversize_files', 'file_errors',
             'files_kept', 'non_sub_files', 'subs_created', 'subs_failed',
             'bytes_pushed', 'over_quota')


def env_str(env, key, default=''):
    return (env.get(key) or '').strip() or default


def env_int(env, key, default):
    raw = (env.get(key) or '').strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        log_progress('gist_nodes_bad_int', key=key, value=raw, fallback=default)
        return default


def http_get(url, token='', timeout=30, max_bytes=0):
    """GET 取文本。

    token 只发给 api.github.com：gist.github.com 是网页端点（带 token 反而可能被
    当成已登录会话走另一条渲染路径），raw 端点则根本不需要认证。
    """
    headers = {
        'User-Agent': 'Mozilla/5.0 (compatible; proxy-speedtest-gistnodes)',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
    }
    if token and url.startswith('https://api.github.com/'):
        headers['Authorization'] = f'token {token}'
        headers['Accept'] = 'application/vnd.github+json'
        headers['X-GitHub-Api-Version'] = '2022-11-28'
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read(max_bytes) if max_bytes > 0 else resp.read()
    return raw.decode('utf-8', 'ignore')


def api_json(url, token, timeout):
    """带 token 时走共享层（统一 UA / API 版本 / 报错带响应体），无 token 时匿名取。"""
    if token:
        return github_api_request(url, token, timeout=timeout)
    return json.loads(http_get(url, timeout=timeout))


# ---------------------------------------------------------------------------
# Sub-Store 后端
# ---------------------------------------------------------------------------
class SubStoreError(RuntimeError):
    pass


def ss_request(base, method, path, payload=None, timeout=60):
    """调 Sub-Store。返回 (status, text)；HTTPError 也把响应体读出来（原因在里面）。"""
    url = base.rstrip('/') + path
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    headers = {'User-Agent': 'proxy-speedtest-gistnodes'}
    if data is not None:
        headers['Content-Type'] = 'application/json'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode('utf-8', 'ignore')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'ignore')
    except Exception as e:
        raise SubStoreError(f'{method} {path} 失败：{e}') from e


def ss_create_sub(base, name, content, timeout):
    """建本地内容订阅。409 = 同名已存在，只可能是复用了非全新容器，直接报错。"""
    status, body = ss_request(base, 'POST', '/api/subs',
                              {'name': name, 'source': 'local', 'content': content}, timeout)
    if status in (200, 201):
        return
    if status == 409:
        raise SubStoreError(
            f'订阅 {name} 已存在：Sub-Store 容器不是全新的（同一容器被跑了两轮？）'
            f'——本流程要求每轮起一个干净容器。响应：{body[:200]}')
    raise SubStoreError(f'创建订阅 {name} 失败：HTTP {status} {body[:200]}')


def ss_create_collection(base, name, subnames, process, timeout):
    status, body = ss_request(base, 'POST', '/api/collections',
                              {'name': name, 'subscriptions': subnames, 'process': process}, timeout)
    if status in (200, 201):
        return
    raise SubStoreError(f'创建组合订阅 {name} 失败：HTTP {status} {body[:200]}')


def ss_download(base, collection, target, timeout):
    path = f'/download/collection/{urllib.parse.quote(collection)}/{target}?noCache=true'
    status, body = ss_request(base, 'GET', path, None, timeout)
    if status != 200:
        raise SubStoreError(f'产出 {collection} ({target}) 失败：HTTP {status} {body[:300]}')
    return body


# ---------------------------------------------------------------------------
# Gist 搜索与取文
# ---------------------------------------------------------------------------
def parse_search_results(body):
    """从搜索页 HTML 抽出候选 Gist。

    按 `.gist-snippet` 切块后只取每块里**第一个** gist 链接：块首就是本块标题链接，
    而尾部会连到下一块/侧栏，取第一个才不会串块。
    """
    out = []
    for chunk in (body or '').split(SNIPPET_MARK)[1:]:
        chunk = chunk[:CHUNK_LIMIT]
        m = GIST_LINK_RE.search(chunk)
        if not m:
            continue
        owner, gist_id = m.group(1), m.group(2)
        u = UPDATED_RE.search(chunk)
        out.append({
            'id': gist_id,
            'owner': owner,
            'updated': u.group(1) if u else '',
            'url': f'https://gist.github.com/{owner}/{gist_id}',
        })
    return out


def is_too_old(updated, now, max_age_hours):
    """按搜索页给出的最后更新时间判超龄。

    解析不出来的（空串 / 格式变了）一律**不算**超龄：宁可多解析一个 Gist，也不要
    因为页面结构变化把整批候选静默判掉——那会让整轮「搜到 0 个」而看不出原因。
    """
    if max_age_hours <= 0 or not updated:
        return False
    try:
        dt = datetime.fromisoformat(updated.replace('Z', '+00:00'))
    except ValueError:
        return False
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (now - dt).total_seconds() > max_age_hours * 3600


def search_gists(queries, pages, sort, timeout, retries=3,
                 max_age_hours=DEFAULT_MAX_AGE_HOURS, per_query_limit=0, page_delay=0):
    """按关键词逐个翻页收集候选 Gist，跨关键词去重（先到先得 = 最近更新优先）。

    每个页面都重试：搜索页会偶发返回不含结果块的降级页面（实测同一 URL 两次请求
    一次 10 块、一次 0 块）。若不重试，这种抖动会被当成「该关键词没有结果」而静默
    丢掉整类节点（实测 ss:// 整条关键词命中 0）。

    三道收口：
      * max_age_hours：丢掉超龄条目；**整页全部超龄就停止该关键词翻页**——排序是
        `s=updated`（降序），这一页都旧了，后面的页只会更旧，继续翻纯属白挨 429。
      * per_query_limit：每个关键词的候选配额（由 max_gists 按关键词数均分），收够
        就停。不均分的话第一个关键词会吃光全部名额，后面几个关键词一个都搜不到。
      * page_delay：页与页之间的固定间隔。搜索页对高频请求会 429（实测连续抓几十页
        就被限死），退避只治已经发生的 429，间隔是从源头降低它发生的概率。
    """
    now = datetime.now(timezone.utc)
    results = []
    seen = set()
    stale_total = 0
    for query in queries:
        hits = 0
        for page in range(1, max(1, pages) + 1):
            found = []
            for attempt in range(1, max(1, retries) + 1):
                qs = urllib.parse.urlencode({'q': query, 's': sort, 'page': page})
                try:
                    found = parse_search_results(http_get(f'{SEARCH_URL}?{qs}', timeout=timeout))
                except Exception as e:
                    found = []
                    log_progress('gist_nodes_search_failed', query=query, page=page,
                                 attempt=attempt, error=str(e))
                if found:
                    break
                if attempt < retries:
                    # 退避给足：搜索页被限流时返回的是 429，短退避重试基本必败
                    # （实测 2s 退避连试三次全 429，整页结果就丢了）。
                    time.sleep(attempt * 5)
            if not found:
                log_progress('gist_nodes_search_empty', query=query, page=page, attempts=retries)
                break
            page_fresh = 0
            page_stale = 0
            for item in found:
                # 配额按条目判，不按页判：一页 10 条而配额只剩 3 个时，只该收 3 个，
                # 否则每翻一页都会超收（3 个关键词 × 超 4 个 = 多解析十几个 Gist）。
                if per_query_limit and hits >= per_query_limit:
                    break
                if item['id'] in seen:
                    continue
                if is_too_old(item['updated'], now, max_age_hours):
                    page_stale += 1
                    continue
                seen.add(item['id'])
                item['query'] = query
                results.append(item)
                hits += 1
                page_fresh += 1
            stale_total += page_stale
            if page_stale and not page_fresh:
                log_progress('gist_nodes_search_stale_stop', query=query, page=page,
                             stale=page_stale, max_age_hours=max_age_hours)
                break
            if per_query_limit and hits >= per_query_limit:
                break
            if page_delay:
                time.sleep(page_delay)
        log_progress('gist_nodes_search_query', query=query, hits=hits)
    if stale_total:
        log_progress('gist_nodes_search_age_filtered', stale=stale_total,
                     max_age_hours=max_age_hours)
    return results


def looks_like_subscription(text):
    """粗判「这文件值不值得占一个投喂名额」。

    两类要放行：明文订阅（链接列表 / Clash YAML，含 scheme 或 proxies 段）与
    base64 订阅（整段编码后看不出 scheme，得解一段才知道）。其余（README、XML
    plist、JSON 数据）挡在外面，省下投喂配额与 Sub-Store 的解析时间。
    """
    lowered = text.lower()
    if any(marker in lowered for marker in SUBSCRIPTION_MARKERS):
        return True
    return looks_like_base64_subscription(text)


def looks_like_base64_subscription(text):
    """整段 base64 且解出来的开头含协议 scheme —— 才算 base64 订阅。

    只解前 64 KB：base64 订阅的头部必然有链接，够判定了，也避免为大文件白解一遍。
    """
    compact = ''.join(text.split())
    if len(compact) < 64:
        return False
    sample = compact[:65536]
    if any(c not in B64_ALPHABET for c in sample):
        return False
    padded = sample + '=' * (-len(sample) % 4)
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            decoded = decoder(padded).decode('utf-8', 'ignore')
        except Exception:
            continue
        if any(marker in decoded.lower() for marker in SUBSCRIPTION_MARKERS):
            return True
    return False


def collect_sources(item, token, timeout, max_file_bytes):
    """取一个 Gist 的所有文件正文，返回 ([(文件名, 正文)], 本块统计)。

    单块失败只跳过该块：搜索结果里混着大量与节点无关的 Gist，任何一个失败都不该
    拖垮整轮。统计随结果一起返回（而不是写共享 dict），因为调用方是并发的。
    """
    stats = dict.fromkeys(STAT_KEYS, 0)
    try:
        data = api_json(GIST_API.format(gist_id=item['id']), token, timeout)
    except Exception as e:
        stats['gist_errors'] = 1
        log_progress('gist_nodes_fetch_failed', gist=item['url'], error=str(e))
        return [], stats
    stats['gists_scanned'] = 1
    hard_cap = (max_file_bytes or 0) + 4096
    files = []
    for name, meta in sorted((data.get('files') or {}).items()):
        if not isinstance(meta, dict):
            continue
        if max_file_bytes and int(meta.get('size') or 0) > max_file_bytes:
            stats['oversize_files'] += 1
            continue
        raw_url = (meta.get('raw_url') or '').strip()
        if not raw_url:
            continue
        try:
            text = http_get(raw_url, timeout=timeout, max_bytes=hard_cap)
        except Exception as e:
            stats['file_errors'] += 1
            log_progress('gist_nodes_raw_failed', gist=item['url'], error=str(e))
            continue
        if not looks_like_subscription(text):
            stats['non_sub_files'] += 1
            continue
        stats['files_kept'] += 1
        files.append((name, text))
    return files, stats


def collect_all(candidates, token, timeout, max_file_bytes, workers):
    """并发取 Gist 正文。

    串行时一个 Gist 约 9 秒（正文动辄几 MB），60 个就要 9 分钟、逼近 job 超时；
    并发 8 路后同样的量级降到 1-2 分钟。结果按提交顺序归并，保证「最近更新的 Gist
    优先」不被并发打乱。
    """
    stats = dict.fromkeys(STAT_KEYS, 0)
    files = []
    if workers <= 1 or len(candidates) <= 1:
        results = (collect_sources(item, token, timeout, max_file_bytes) for item in candidates)
        for part, local in results:
            files.extend(part)
            for k in STAT_KEYS:
                stats[k] += local[k]
        return files, stats
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(collect_sources, item, token, timeout, max_file_bytes)
                   for item in candidates]
        for future in futures:
            try:
                part, local = future.result()
            except Exception as e:
                stats['gist_errors'] += 1
                log_progress('gist_nodes_worker_failed', error=str(e))
                continue
            files.extend(part)
            for k in STAT_KEYS:
                stats[k] += local[k]
    return files, stats


# ---------------------------------------------------------------------------
# Sub-Store 处理链
# ---------------------------------------------------------------------------
def build_process(max_nodes):
    """去重 / 清理 / 限量，全部用 Sub-Store 内置算子（名字即 process 里的 type）。

    顺序有讲究：先 Useless Filter 清掉信息节点，再按字段去重，最后处理重名——
    重命名只对「名字重复」的节点加后缀，放在去重之后剩下的才是真重名（同一节点
    的多次出现已被上一步删掉）。
    """
    process = [
        {'type': 'Useless Filter'},
        {'type': 'Handle Duplicate Operator',
         'args': {'action': 'delete', 'field': DEDUPE_FIELDS}},
        {'type': 'Handle Duplicate Operator', 'args': {'action': 'rename'}},
    ]
    if max_nodes > 0:
        # 限量为什么必须有：下游 mihomo 的 provider 配的是非 lazy 健康检查，订阅里有
        # 多少节点就在启动时探多少个。gist 抓来的聚合列表去重后常有几千个，会让每轮
        # 测速多花几分钟做无谓探测，而引擎实际只测 max_nodes 个。
        # 用 Script Operator 而不是在脚本里截断 YAML：产出保持完全由 Sub-Store 生成。
        # 脚本文本会被 Sub-Store 拼成 `... \n return operator` 再执行，所以必须定义
        # 名为 operator 的函数（见其 processors/index.js 的 createDynamicFunction）。
        process.append({
            'type': 'Script Operator',
            'args': {
                'mode': 'script',
                'content': f'function operator(proxies) {{ return proxies.slice(0, {max_nodes}); }}',
            },
        })
    return process


def push_to_substore(base, files, prefix, max_subs, max_total_bytes, timeout, stats):
    """把抓到的订阅正文逐个建成 Sub-Store 本地订阅，返回订阅名列表。"""
    subnames = []
    for idx, (name, text) in enumerate(files, 1):
        if len(subnames) >= max_subs:
            stats['over_quota'] += 1
            continue
        size = len(text.encode('utf-8'))
        if max_total_bytes and stats['bytes_pushed'] + size > max_total_bytes:
            stats['over_quota'] += 1
            continue
        # 订阅名不能含 '/'（Sub-Store 明确拒绝），故不用 owner/id，只用序号。
        sub_name = f'{prefix}-{idx:03d}'
        try:
            ss_create_sub(base, sub_name, text, timeout)
        except SubStoreError as e:
            stats['subs_failed'] += 1
            log_progress('gist_nodes_sub_failed', sub=sub_name, error=str(e))
            continue
        stats['subs_created'] += 1
        stats['bytes_pushed'] += size
        subnames.append(sub_name)
    return subnames


def write_github_output(pairs):
    path = os.environ.get('GITHUB_OUTPUT', '')
    if not path:
        return
    with open(path, 'a', encoding='utf-8') as f:
        for k, v in pairs.items():
            f.write(f'{k}={v}\n')


def write_step_summary(lines):
    path = os.environ.get('GITHUB_STEP_SUMMARY', '')
    if not path:
        return
    with open(path, 'a', encoding='utf-8') as f:
        f.write('\n'.join(lines).rstrip('\n') + '\n')


def fail(message):
    print(f'ERROR: {message}', file=sys.stderr, flush=True)
    log_progress('gist_nodes_failed', error=message)
    sys.exit(1)


def main():
    env = merged_env()
    token = (env.get('GH_TOKEN') or env.get('GITHUB_TOKEN') or '').strip()
    queries = [q.strip() for q in env_str(env, 'GIST_NODES_QUERIES', DEFAULT_QUERIES).split(',') if q.strip()]
    pages = max(1, env_int(env, 'GIST_NODES_PAGES', 5))
    sort = env_str(env, 'GIST_NODES_SORT', 'updated')
    max_age_hours = max(0, env_int(env, 'GIST_NODES_MAX_AGE_HOURS', DEFAULT_MAX_AGE_HOURS))
    max_gists = max(1, env_int(env, 'GIST_NODES_MAX_GISTS', 100))
    max_subs = max(1, env_int(env, 'GIST_NODES_MAX_SUBS', 120))
    max_total_bytes = max(0, env_int(env, 'GIST_NODES_MAX_TOTAL_MB', 24)) * 1024 * 1024
    max_file_bytes = max(0, env_int(env, 'GIST_NODES_MAX_FILE_MB', 2)) * 1024 * 1024
    max_nodes = max(0, env_int(env, 'GIST_NODES_MAX_NODES', 300))
    timeout = max(5, env_int(env, 'GIST_NODES_TIMEOUT', 30))
    retries = max(1, env_int(env, 'GIST_NODES_RETRIES', 3))
    page_delay = max(0, env_int(env, 'GIST_NODES_PAGE_DELAY', 2))
    workers = max(1, env_int(env, 'GIST_NODES_WORKERS', 8))
    dry_run = env_str(env, 'GIST_NODES_DRY_RUN', '0').lower() not in ('0', 'false', 'no')
    ss_base = env_str(env, 'SUB_STORE_BACKEND_URL', DEFAULT_SUB_STORE)
    ss_timeout = max(10, env_int(env, 'SUB_STORE_TIMEOUT', 300))
    collection = env_str(env, 'SUB_STORE_COLLECTION', 'gist-nodes')
    workdir = pathlib.Path(env_str(
        env, 'GIST_NODES_WORKDIR', str(pathlib.Path.home() / 'proxy-speedtest' / 'gist-nodes')))
    workdir.mkdir(parents=True, exist_ok=True)

    if not queries:
        fail('GIST_NODES_QUERIES 为空：没有关键词就搜不到任何节点')
    if not token:
        log_progress('gist_nodes_no_token', note='匿名调用 GitHub API 限流 60 次/h，可能中途被截断')

    # 候选配额按关键词均分：不均分的话第一个关键词（ss://）会把 max_gists 名额吃光，
    # 后面 vless / vmess / … 一个都轮不到，最后整批节点只来自一个关键词。
    per_query_limit = -(-max_gists // len(queries)) if queries else 0
    candidates = search_gists(queries, pages, sort, timeout, retries,
                              max_age_hours=max_age_hours, per_query_limit=per_query_limit,
                              page_delay=page_delay)
    log_progress('gist_nodes_candidates', count=len(candidates), queries=len(queries),
                 sort=sort, max_age_hours=max_age_hours)
    if not candidates:
        if max_age_hours:
            fail(f'没有解析出任何「最近 {max_age_hours} 小时内更新」的 Gist'
                 f'（窗口太窄，或搜索页结构已变）')
        fail('搜索页一个 Gist 都没解析出来（页面结构可能已变，或网络被拦）')

    files, stats = collect_all(candidates[:max_gists], token, timeout, max_file_bytes, workers)
    log_progress('gist_nodes_sources', **stats, files=len(files))
    if not files:
        fail(f'扫了 {stats["gists_scanned"]} 个 Gist 但没找到任何像订阅的文件')

    # Sub-Store 就绪性：先探一次，把「容器没起来」和「订阅内容有问题」两类失败分开。
    try:
        status, body = ss_request(ss_base, 'GET', '/api/subs', None, min(ss_timeout, 30))
    except SubStoreError as e:
        fail(f'Sub-Store 后端不可达（{ss_base}）：{e}')
    if status != 200:
        fail(f'Sub-Store 后端异常：GET /api/subs → HTTP {status} {body[:200]}')

    subnames = push_to_substore(ss_base, files, collection, max_subs, max_total_bytes, ss_timeout, stats)
    log_progress('gist_nodes_pushed', subs=len(subnames), **{k: stats[k] for k in
                 ('subs_created', 'subs_failed', 'bytes_pushed', 'over_quota')})
    if not subnames:
        fail('没有一个订阅成功投喂进 Sub-Store')

    process = build_process(max_nodes)
    try:
        # 参照组：同样的订阅但不带去重，用来给出「解析后 N → 去重后 M」这个可核对的口径。
        # Sub-Store 对未知算子只记日志、不报错，没有这个参照组就无从判断去重是否真生效。
        ss_create_collection(ss_base, f'{collection}-raw', subnames, [], ss_timeout)
        ss_create_collection(ss_base, collection, subnames, process, ss_timeout)
        yaml_text = ss_download(ss_base, collection, 'ClashMeta', ss_timeout)
        raw_json = ss_download(ss_base, f'{collection}-raw', 'JSON', ss_timeout)
    except SubStoreError as e:
        fail(str(e))

    if 'proxies:' not in yaml_text:
        fail(f'Sub-Store 产出的不是 mihomo YAML，前 300 字：{yaml_text[:300]}')
    try:
        proxies = (yaml.safe_load(yaml_text) or {}).get('proxies') or []
    except Exception as e:
        fail(f'Sub-Store 产出的 YAML 解析失败：{e}')
    if not proxies:
        fail('Sub-Store 产出的订阅里一个节点都没有')
    try:
        parsed_count = len(json.loads(raw_json))
    except Exception:
        parsed_count = 0

    log_progress('gist_nodes_deduped', parsed=parsed_count, deduped=len(proxies),
                 max_nodes=max_nodes, bytes=len(yaml_text.encode('utf-8')))
    if parsed_count and len(proxies) >= parsed_count:
        # 去重没生效通常是 process 里的 type 名写错了（Sub-Store 只记日志、不报错）。
        log_progress('gist_nodes_dedupe_no_effect', parsed=parsed_count, deduped=len(proxies))

    (workdir / 'providers.yaml').write_text(yaml_text, encoding='utf-8')
    (workdir / 'nodes.json').write_text(json.dumps({
        'queries': queries,
        'sort': sort,
        'max_age_hours': max_age_hours,
        'max_gists': max_gists,
        'collection': collection,
        'process': process,
        'stats': stats,
        'parsed_count': parsed_count,
        'node_count': len(proxies),
    }, ensure_ascii=False, indent=2), encoding='utf-8')

    sub_url = ''
    gist_html_url = ''
    gist_id = ''
    if dry_run:
        log_progress('gist_nodes_dry_run', nodes=len(proxies), bytes=len(yaml_text.encode('utf-8')))
    else:
        res = update_gist(env, yaml_text)
        if not res.get('ok'):
            fail(f'发布 Gist 失败：{res.get("reason", "unknown")}')
        sub_url = ((res.get('yaml') or {}).get('raw_url') or '').strip()
        gist_html_url = (res.get('html_url') or '').strip()
        gist_id = (res.get('id') or '').strip()
        if not sub_url:
            fail('Gist 已写入但没有 raw_url，下游拿不到订阅源')
        log_progress('gist_nodes_published', gist_id=gist_id, nodes=len(proxies),
                     created=bool(res.get('created')), bytes=len(yaml_text.encode('utf-8')))

    write_github_output({
        'sub_url': sub_url,
        'count': len(proxies),
        'parsed_count': parsed_count,
        'gists_scanned': stats['gists_scanned'],
        'gist_html_url': gist_html_url,
        'gist_id': gist_id,
    })
    write_step_summary([
        '### gist 节点抓取（Sub-Store 去重）',
        '',
        f'- 关键词：`{", ".join(queries)}`（排序 `{sort}`，每个最多 {pages} 页）',
        f'- 时间窗口：{"最近 " + str(max_age_hours) + " 小时内更新" if max_age_hours else "不限"}；'
        f'候选 Gist：{len(candidates)}，实际解析：{stats["gists_scanned"]}（失败 {stats["gist_errors"]}）',
        f'- 投喂订阅：{stats["subs_created"]} 个（失败 {stats["subs_failed"]}，'
        f'{round(stats["bytes_pushed"] / 1048576, 1)} MB）',
        f'- Sub-Store 解析：{parsed_count} 个节点 → 去重/清理后：**{len(proxies)}**'
        + (f'（限量 {max_nodes}）' if max_nodes else ''),
        f'- 订阅 Gist：{gist_html_url or "(dry-run 未发布)"}',
    ])
    print(f'OK: {len(proxies)} 个节点（解析 {parsed_count}），'
          f'{stats["subs_created"]} 个订阅经 Sub-Store 去重，订阅 raw: {sub_url or "(dry-run)"}')


if __name__ == '__main__':
    main()
