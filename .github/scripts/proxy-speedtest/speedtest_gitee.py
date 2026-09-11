#!/usr/bin/env python3
"""Gitee 上下行 + 延迟测速 + 四套共享引擎（proxy-speedtest-gitee）。

仓库代理测速四套按测速点命名，本脚本承担双重角色：
  1. 独立工作流 proxy-speedtest-gitee 的引擎：对订阅的每个可用节点，经 mihomo 代理
     git push 测速文件到 Gitee 私有仓库测上行、clone 拉回测下行、对 gitee.com 做
     HTTP 计时测延迟（both 模式，2026-09-08 起默认，四套指标口径对齐）；
     达标节点订阅导出到本工作流专属 Gist（只上传，不回拉验证——见文件内 gist 收尾说明）。
  2. 四套共享引擎：mihomo 下载/配置/生命周期、订阅拉取解析、节点快照与切换
     均在本文件，speedtest.py（CDN）与 taier_speedtest.py（泰尔三网）以
     `from speedtest_gitee import ...` 复用。与引擎无关的纯共享层（订阅导出策略、
     通知排版、归属查询、Telegram 发送、Gist 上传、进度日志）已于 2026-09-08 抽到
     `speedtest_common.py`——共享代码不再挂在 gitee 专项引擎名下，本文件只按需
     import（无兼容再导出）。顶层的 signal/异常通知只在 main() 里注册，import 复用
     不会误触发。

运行模式（PROXY_SPEEDTEST_MODE，2026-09-08 起默认 both）：
  both       ↑上传（git push）+ ↓下载（clone 拉回）+ gitee.com HTTP 延迟，三项全测
  push-only  只测经代理上行（历史模式，可用 env 退回）
  直连基线（git_direct_speedtest）不受模式影响，作为「家庭宽带上行」对照单独执行

Gist 约定（四套各用各的，互不覆盖）：
  secret PROXY_SPEEDTEST_GIST_ID / PROXY_SPEEDTEST_CDN_GIST_ID / PROXY_SPEEDTEST_TAIER_GIST_ID
  分别注入各 workflow 的 PROXY_SPEEDTEST_GIST_ID env；文件名/描述经
  PROXY_SPEEDTEST_GIST_FILENAME / PROXY_SPEEDTEST_GIST_DESCRIPTION 覆盖。
"""
import base64
import json
import os
import pathlib
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import gzip
import html
from datetime import datetime

import yaml

# 四套共享层（speedtest_common）：只 import 本文件实际用到的共享名，不做兼容再导出。
from speedtest_common import (
    DEFAULT_MIN_MEGABIT, DEFAULT_MIN_NODES, DEFAULT_SPEED_METRIC, HOME_RUNTIME, METRIC_LABELS, PROVIDERS_DIR, SOURCE_SNAPSHOT_DIR,
    _redact_value, _scrub_cred_urls, build_node_metric_prefix, build_subscription_bundle,
    build_target_network_section, deep_copy_json, fetch_ip_network_info,
    get_item_megabits, latency_probe, log_progress, merged_env,
    resolve_host_ipv4, resolve_subscription_policy,
    send_telegram, send_telegram_chunked, tg_entry, tg_entry_codes, tg_footer_line,
    tg_format_elapsed, tg_pre_block, update_gist,
    TG_SEP,
)

RESULT_JSON = HOME_RUNTIME / 'proxy_speedtest_last_result.json'
RESULT_TXT = HOME_RUNTIME / 'proxy_speedtest_last_result.txt'
RESULT_SUBSCRIPTION = HOME_RUNTIME / 'proxy_speedtest_subscription.yaml'
BACKGROUND_LOG = HOME_RUNTIME / 'proxy_speedtest_background.log'
BACKGROUND_PID = HOME_RUNTIME / 'proxy_speedtest_background.pid'
TEST_BRANCH = 'master'
TEST_FILE_NAME = 'proxy_speedtest.bin'
MIHOMO = HOME_RUNTIME / 'mihomo'
MIHOMO_CONFIG = HOME_RUNTIME / 'config.yaml'
MIHOMO_LOG = HOME_RUNTIME / 'mihomo.log'
MIHOMO_API = 'http://127.0.0.1:19090'
MIHOMO_MIXED_PORT = 17892
MIHOMO_RELEASE_API = 'https://api.github.com/repos/MetaCubeX/mihomo/releases/latest'
DEFAULT_HEALTHCHECK_URL = 'https://www.gstatic.com/generate_204'
CURRENT_RUN_STARTED_AT = ''
TERMINATION_NOTICE_SENT = False

class StageError(RuntimeError):
    def __init__(self, stage: str, error: Exception | str):
        self.stage = stage
        self.original_error = error
        super().__init__(f'{stage}: {error}')

def run_stage(stage: str, func, *args, **kwargs):
    try:
        return func(*args, **kwargs)
    except Exception as e:
        raise StageError(stage, e) from e

def write_termination_artifacts(message: str):
    try:
        RESULT_TXT.write_text(message.strip() + '\n', encoding='utf-8')
    except Exception:
        pass
    try:
        payload = {
            'ok': False,
            'terminated': True,
            'started_at': CURRENT_RUN_STARTED_AT,
            'ended_at': datetime.now().isoformat(),
            'reason': message,
        }
        RESULT_JSON.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception:
        pass

def handle_termination_signal(signum, frame):
    global TERMINATION_NOTICE_SENT
    if TERMINATION_NOTICE_SENT:
        raise SystemExit(128 + int(signum))
    TERMINATION_NOTICE_SENT = True
    sig_name = signal.Signals(signum).name if signum else f'SIGNAL-{signum}'
    _sep = TG_SEP
    message = f'⛔ Gitee 测速异常终止\n{_sep}\n⚠️ 脚本被中断：收到 {tg_entry(sig_name)}，本轮测速未正常完成。'
    _footer = tg_footer_line()
    if _footer:
        message += f'\n\n{_footer}'
    write_termination_artifacts(message)
    try:
        env = merged_env()
        send_telegram(env, message)
    except Exception:
        pass
    raise SystemExit(128 + int(signum))

def touch_lock_file():
    """更新锁文件时间戳，防止被心跳机制误判为 stale。"""
    try:
        lock_file = pathlib.Path('/tmp/proxy_speedtest.lock')
        if lock_file.exists():
            lock_file.touch(exist_ok=True)
    except Exception:
        pass

def maybe_detach_self():
    detach_value = os.environ.get('PROXY_SPEEDTEST_DETACH', '').strip().lower()
    if detach_value in ('0', 'false', 'no', 'off'):
        return False
    if os.environ.get('PROXY_SPEEDTEST_DETACHED', '').strip() == '1':
        # 子进程：在这里实际执行锁定，确保持续持有
        try:
            import fcntl
            global _LOCK_FP
            _LOCK_FP = open('/tmp/proxy_speedtest.lock', 'a')
            fcntl.flock(_LOCK_FP, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            sys.exit(0)
        return False

    # 检查是否已有活跃实例
    try:
        import fcntl
        test_fp = open('/tmp/proxy_speedtest.lock', 'a')
        fcntl.flock(test_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(test_fp, fcntl.LOCK_UN)
        test_fp.close()
    except (IOError, OSError):
        print(json.dumps({'ok': False, 'reason': 'already_running_by_lock'}, ensure_ascii=False))
        return True

    env = dict(os.environ)
    env['PROXY_SPEEDTEST_DETACHED'] = '1'
    with BACKGROUND_LOG.open('ab') as lf:
        proc = subprocess.Popen(
            [sys.executable, str(pathlib.Path(__file__).resolve())],
            stdin=subprocess.DEVNULL,
            stdout=lf,
            stderr=subprocess.STDOUT,
            cwd=str(HOME_RUNTIME),
            env=env,
            start_new_session=True,
            close_fds=True,
        )
    BACKGROUND_PID.write_text(str(proc.pid), encoding='utf-8')
    print(json.dumps({
        'ok': True,
        'detached': True,
        'pid': proc.pid,
        'log': str(BACKGROUND_LOG),
        'pidfile': str(BACKGROUND_PID),
    }, ensure_ascii=False))
    return True

def run(cmd, cwd=None, env=None, timeout=600):
    p = subprocess.run(cmd, cwd=cwd, env=env, text=True, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr

def sanitize_name(name: str):
    bad = '<>:"/\\|?*\n\r\t'
    out = ''.join('_' if c in bad else c for c in name)
    return out[:120] or 'node'

def parse_sub_urls(env):
    raw = env.get('PROXY_SPEEDTEST_SUB_URLS', '').strip()
    if not raw:
        raise RuntimeError('missing PROXY_SPEEDTEST_SUB_URLS in ~/.openclaw/.env')
    urls = []
    seen = set()
    for item in raw.split(','):
        s = item.strip()
        if s and s not in seen:
            urls.append(s)
            seen.add(s)
    if not urls:
        raise RuntimeError('PROXY_SPEEDTEST_SUB_URLS is empty after parsing')
    return urls

def fetch_text(url: str):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError:
        return raw.decode('utf-8', 'ignore')

def maybe_decode_base64_subscription(text: str):
    import base64
    stripped = ''.join(text.strip().split())
    if not stripped:
        return ''
    if any(x in stripped for x in ('://', 'proxies:', 'proxy-providers:')):
        return text
    try:
        padded = stripped + '=' * (-len(stripped) % 4)
        decoded = base64.b64decode(padded)
        out = decoded.decode('utf-8', 'ignore')
        if '://' in out:
            return out
    except Exception as e:
        log_progress('subscription_base64_decode_skipped', error=str(e))
    return text

def normalize_node_name(name: str):
    if not name:
        return ''
    text = unicodedata.normalize('NFKC', str(name)).strip()
    text = text.replace('｜', '|').replace('﹒', '.').replace('（', '(').replace('）', ')')
    text = text.lower()
    text = re.sub(r'^[^\w\u4e00-\u9fff]+', '', text)
    text = re.sub(r'\s+', '', text)
    return text

def build_proxy_fingerprint(proxy: dict):
    if not isinstance(proxy, dict):
        return ''
    p = dict(proxy)
    node_type = str(p.get('type') or '').strip().lower()
    server = str(p.get('server') or '').strip().lower()
    port = str(p.get('port') or '').strip()
    uuid = str(p.get('uuid') or '').strip().lower()
    password = str(p.get('password') or '').strip().lower()
    cipher = str(p.get('cipher') or '').strip().lower()
    sni = str(p.get('sni') or p.get('servername') or '').strip().lower()
    host = str(p.get('host') or '').strip().lower()
    path = str(p.get('path') or '').strip()
    network = str(p.get('network') or p.get('net') or p.get('type') or '').strip().lower()
    security = str(p.get('security') or p.get('tls') or '').strip().lower()
    pbk = str(p.get('pbk') or '').strip().lower()
    sid = str(p.get('sid') or '').strip().lower()
    service_name = str(p.get('serviceName') or '').strip().lower()
    plugin = str(p.get('plugin') or '').strip().lower()
    plugin_opts = str(p.get('plugin-opts') or p.get('plugin_opts') or '').strip().lower()
    ws_host = str((((p.get('ws-opts') or {}).get('headers') or {}).get('Host')) or '').strip().lower()
    ws_path = str(((p.get('ws-opts') or {}).get('path')) or '').strip()
    grpc_service = str(((p.get('grpc-opts') or {}).get('grpc-service-name')) or '').strip().lower()
    reality_public_key = str(((p.get('reality-opts') or {}).get('public-key')) or '').strip().lower()
    reality_short_id = str(((p.get('reality-opts') or {}).get('short-id')) or '').strip().lower()
    alpn = str(p.get('alpn') or '').strip().lower()
    auth = str(p.get('auth') or p.get('token') or '').strip().lower()
    obfs = str(p.get('obfs') or '').strip().lower()
    obfs_password = str(p.get('obfs-password') or p.get('obfs_password') or '').strip().lower()
    udp_relay_mode = str(p.get('udp-relay-mode') or p.get('udp_relay_mode') or '').strip().lower()
    congestion_controller = str(p.get('congestion-controller') or p.get('congestion_controller') or '').strip().lower()
    disable_sni = str(p.get('disable-sni') or p.get('disable_sni') or '').strip().lower()
    return '||'.join([
        node_type, server, port, uuid, password, cipher,
        sni, host, path, network, security,
        pbk, sid, service_name, plugin, plugin_opts,
        ws_host, ws_path, grpc_service,
        reality_public_key, reality_short_id,
        alpn, auth, obfs, obfs_password,
        udp_relay_mode, congestion_controller, disable_sni,
    ])

def extract_proxy_from_share_link(share_link: str):
    line = (share_link or '').strip()
    if not line or '://' not in line:
        return {}
    parsed = urllib.parse.urlparse(line)
    scheme = (parsed.scheme or '').lower()
    name = urllib.parse.unquote(parsed.fragment or '').strip()
    query = urllib.parse.parse_qs(parsed.query)

    def q1(key, default=''):
        return query.get(key, [default])[0]

    if scheme == 'vless':
        proxy = {
            'name': name,
            'type': 'vless',
            'server': parsed.hostname or '',
            'port': parsed.port or 443,
            'uuid': urllib.parse.unquote(parsed.username or ''),
            'udp': True,
            'network': q1('type', 'tcp'),
        }
        if q1('security'):
            proxy['security'] = q1('security')
        if q1('sni'):
            proxy['sni'] = q1('sni')
            proxy['servername'] = q1('sni')
        if q1('host'):
            proxy['host'] = q1('host')
        if q1('path'):
            proxy['path'] = q1('path')
        if q1('pbk'):
            proxy['pbk'] = q1('pbk')
            proxy.setdefault('reality-opts', {})['public-key'] = q1('pbk')
        if q1('sid'):
            proxy['sid'] = q1('sid')
            proxy.setdefault('reality-opts', {})['short-id'] = q1('sid')
        if q1('serviceName'):
            proxy['serviceName'] = q1('serviceName')
            proxy['grpc-opts'] = {'grpc-service-name': q1('serviceName')}
        if q1('fp'):
            proxy['fp'] = q1('fp')
            proxy['client-fingerprint'] = q1('fp')
        if q1('flow'):
            proxy['flow'] = q1('flow')
        if q1('host') or q1('path'):
            proxy['ws-opts'] = {}
            if q1('host'):
                proxy['ws-opts']['headers'] = {'Host': q1('host')}
            if q1('path'):
                proxy['ws-opts']['path'] = q1('path')
        return proxy

    if scheme == 'trojan':
        proxy = {
            'name': name,
            'type': 'trojan',
            'server': parsed.hostname or '',
            'port': parsed.port or 443,
            'password': urllib.parse.unquote(parsed.username or ''),
            'udp': True,
            'network': q1('type', 'tcp'),
        }
        if q1('security'):
            proxy['security'] = q1('security')
        if q1('sni'):
            proxy['sni'] = q1('sni')
        if q1('host'):
            proxy['host'] = q1('host')
        if q1('path'):
            proxy['path'] = q1('path')
        if q1('pbk'):
            proxy['pbk'] = q1('pbk')
            proxy.setdefault('reality-opts', {})['public-key'] = q1('pbk')
        if q1('sid'):
            proxy['sid'] = q1('sid')
            proxy.setdefault('reality-opts', {})['short-id'] = q1('sid')
        if q1('serviceName'):
            proxy['serviceName'] = q1('serviceName')
            proxy['grpc-opts'] = {'grpc-service-name': q1('serviceName')}
        if q1('fp'):
            proxy['fp'] = q1('fp')
            proxy['client-fingerprint'] = q1('fp')
        if q1('alpn'):
            proxy['alpn'] = q1('alpn')
        if q1('host') or q1('path'):
            proxy['ws-opts'] = {}
            if q1('host'):
                proxy['ws-opts']['headers'] = {'Host': q1('host')}
            if q1('path'):
                proxy['ws-opts']['path'] = q1('path')
        return proxy

    if scheme in ('hy2', 'hysteria2'):
        proxy = {
            'name': name,
            'type': 'hysteria2',
            'server': parsed.hostname or '',
            'port': parsed.port or 443,
            'password': urllib.parse.unquote(parsed.username or parsed.password or ''),
            'udp': True,
        }
        if q1('sni'):
            proxy['sni'] = q1('sni')
        if q1('alpn'):
            proxy['alpn'] = q1('alpn')
        if q1('obfs'):
            proxy['obfs'] = q1('obfs')
        if q1('obfs-password'):
            proxy['obfs-password'] = q1('obfs-password')
        if q1('auth'):
            proxy['auth'] = q1('auth')
        if q1('up'):
            proxy['up'] = q1('up')
        if q1('down'):
            proxy['down'] = q1('down')
        if q1('insecure'):
            proxy['skip-cert-verify'] = q1('insecure') in ('1', 'true', 'yes')
        return proxy

    if scheme == 'tuic':
        proxy = {
            'name': name,
            'type': 'tuic',
            'server': parsed.hostname or '',
            'port': parsed.port or 443,
            'uuid': urllib.parse.unquote(parsed.username or ''),
            'password': urllib.parse.unquote(parsed.password or ''),
            'udp': True,
        }
        if q1('sni'):
            proxy['sni'] = q1('sni')
        if q1('alpn'):
            proxy['alpn'] = q1('alpn')
        if q1('congestion_controller'):
            proxy['congestion-controller'] = q1('congestion_controller')
        if q1('udp_relay_mode'):
            proxy['udp-relay-mode'] = q1('udp_relay_mode')
        if q1('disable_sni'):
            proxy['disable-sni'] = q1('disable_sni') in ('1', 'true', 'yes')
        if q1('token'):
            proxy['token'] = q1('token')
        return proxy

    if scheme == 'ss':
        proxy = {
            'name': name,
            'type': 'ss',
            'server': parsed.hostname or '',
            'port': parsed.port or 443,
            'udp': True,
        }
        userinfo = ''
        if parsed.username:
            userinfo = parsed.username
        else:
            netloc = parsed.netloc
            if '@' in netloc:
                userinfo = netloc.split('@', 1)[0]
        try:
            padded = userinfo + '=' * (-len(userinfo) % 4)
            decoded = base64.urlsafe_b64decode(padded.encode()).decode('utf-8', 'ignore')
            if ':' in decoded:
                cipher, password = decoded.split(':', 1)
                proxy['cipher'] = cipher
                proxy['password'] = password
        except Exception as e:
            log_progress('ss_userinfo_decode_skipped', error=str(e), name=name, server=proxy.get('server', ''))
        plugin_val = q1('plugin')
        if plugin_val:
            plugin_parts = plugin_val.split(';', 1)
            proxy['plugin'] = plugin_parts[0]
            if len(plugin_parts) > 1:
                proxy['plugin-opts'] = plugin_parts[1]
        return proxy

    if scheme == 'vmess':
        payload = line.split('://', 1)[1]
        try:
            padded = payload + '=' * (-len(payload) % 4)
            raw = base64.b64decode(padded).decode('utf-8', 'ignore')
            obj = json.loads(raw)
            proxy = {
                'name': str(obj.get('ps') or name or '').strip(),
                'type': 'vmess',
                'server': str(obj.get('add') or '').strip(),
                'port': int(str(obj.get('port') or '0') or 0),
                'uuid': str(obj.get('id') or '').strip(),
                'alterId': int(str(obj.get('aid') or '0') or 0),
                'cipher': str(obj.get('scy') or 'auto').strip(),
                'udp': True,
                'network': str(obj.get('net') or 'tcp').strip(),
            }
            if str(obj.get('tls') or '').strip():
                proxy['security'] = 'tls'
            if str(obj.get('host') or '').strip():
                proxy['host'] = str(obj.get('host')).strip()
            if str(obj.get('path') or '').strip():
                proxy['path'] = str(obj.get('path')).strip()
            if str(obj.get('sni') or '').strip():
                proxy['sni'] = str(obj.get('sni')).strip()
                proxy['servername'] = str(obj.get('sni')).strip()
            if proxy.get('host') or proxy.get('path'):
                proxy['ws-opts'] = {}
                if proxy.get('host'):
                    proxy['ws-opts']['headers'] = {'Host': proxy['host']}
                if proxy.get('path'):
                    proxy['ws-opts']['path'] = proxy['path']
            return proxy
        except Exception as e:
            log_progress('vmess_share_link_parse_failed', error=str(e), share_link=line[:300])
            return {}

    return {}

def make_source_entry(source_url: str, name: str, share_link: str = '', proxy=None):
    proxy_copy = deep_copy_json(proxy or {}) if proxy else {}
    normalized_name = normalize_node_name(name)
    fingerprint = build_proxy_fingerprint(proxy_copy)
    source_kind = 'proxy' if proxy_copy else 'share-link'
    source_id = '||'.join([
        str(source_url or '').strip(),
        str(name or '').strip(),
        normalized_name,
        str(share_link or '').strip(),
        fingerprint,
        source_kind,
    ])
    return {
        'source_id': source_id,
        'source_url': source_url,
        'name': name,
        'normalized_name': normalized_name,
        'share_link': share_link,
        'proxy': proxy_copy,
        'fingerprint': fingerprint,
        'source_kind': source_kind,
    }

def build_source_mapping(env):
    exact_mapping = {}
    normalized_mapping = {}
    exact_raw_mapping = {}
    normalized_raw_mapping = {}
    fingerprint_mapping = {}
    exact_proxy_mapping = {}
    normalized_proxy_mapping = {}
    snapshot_meta = []
    for idx, url in enumerate(parse_sub_urls(env), 1):
        try:
            text = maybe_decode_base64_subscription(fetch_text(url))
            snapshot_path = SOURCE_SNAPSHOT_DIR / f'source_{idx:02d}.txt'
            snapshot_path.write_text(text, encoding='utf-8')
            snapshot_meta.append({'index': idx, 'url': url, 'path': str(snapshot_path), 'size': len(text.encode('utf-8'))})
        except Exception as e:
            log_progress('subscription_fetch_skipped', source_url=url, error=str(e))
            continue

        added_raw = False
        for raw in text.splitlines():
            line = raw.strip()
            if not line or '://' not in line or line.startswith('#'):
                continue
            parsed = urllib.parse.urlparse(line)
            frag = urllib.parse.unquote(parsed.fragment or '').strip()
            if not frag:
                continue
            proxy = extract_proxy_from_share_link(line)
            proxy_copy = deep_copy_json(proxy) if proxy else {}
            entry = make_source_entry(url, frag, share_link=line, proxy=proxy_copy)
            if frag not in exact_raw_mapping:
                exact_raw_mapping[frag] = line
            if frag not in exact_proxy_mapping:
                exact_proxy_mapping[frag] = entry
            normalized = entry.get('normalized_name', '')
            if normalized and normalized not in normalized_raw_mapping:
                normalized_raw_mapping[normalized] = line
            if normalized and normalized not in normalized_proxy_mapping:
                normalized_proxy_mapping[normalized] = entry
            fingerprint = entry.get('fingerprint', '')
            if fingerprint and fingerprint not in fingerprint_mapping:
                fingerprint_mapping[fingerprint] = entry
            added_raw = True

        if added_raw:
            continue

        try:
            parsed_yaml = yaml.safe_load(text)
        except Exception as e:
            log_progress('subscription_yaml_parse_skipped', source_url=url, error=str(e))
            parsed_yaml = None
        proxies = []
        if isinstance(parsed_yaml, dict):
            proxies = parsed_yaml.get('proxies') or []
        if isinstance(proxies, list):
            for proxy in proxies:
                if not isinstance(proxy, dict):
                    continue
                name = str(proxy.get('name') or '').strip()
                if not name:
                    continue
                proxy_copy = deep_copy_json(proxy)
                entry = make_source_entry(url, name, share_link='', proxy=proxy_copy)
                if name not in exact_proxy_mapping:
                    exact_proxy_mapping[name] = entry
                normalized = entry.get('normalized_name', '')
                if normalized and normalized not in normalized_proxy_mapping:
                    normalized_proxy_mapping[normalized] = entry
                fingerprint = entry.get('fingerprint', '')
                if fingerprint and fingerprint not in fingerprint_mapping:
                    fingerprint_mapping[fingerprint] = entry

    exact_mapping.update(exact_raw_mapping)
    normalized_mapping.update(normalized_raw_mapping)
    return {
        'exact': exact_mapping,
        'normalized': normalized_mapping,
        'exact_raw': exact_raw_mapping,
        'normalized_raw': normalized_raw_mapping,
        'fingerprint': fingerprint_mapping,
        'exact_proxy': exact_proxy_mapping,
        'normalized_proxy': normalized_proxy_mapping,
        'snapshot_meta': snapshot_meta,
    }

def resolve_source_entry_for_node(name: str, source_mapping, proxy_obj=None):
    source_mapping = source_mapping or {}
    exact_raw_mapping = source_mapping.get('exact_raw') or {}
    normalized_raw_mapping = source_mapping.get('normalized_raw') or {}
    fingerprint_mapping = source_mapping.get('fingerprint') or {}
    exact_proxy_mapping = source_mapping.get('exact_proxy') or {}
    normalized_proxy_mapping = source_mapping.get('normalized_proxy') or {}

    if name in exact_proxy_mapping:
        entry = exact_proxy_mapping[name]
        return entry, 'raw-exact'
    normalized = normalize_node_name(name)
    if normalized and normalized in normalized_proxy_mapping:
        entry = normalized_proxy_mapping[normalized]
        return entry, 'raw-normalized'

    fingerprint = build_proxy_fingerprint(proxy_obj or {})
    if fingerprint and fingerprint in fingerprint_mapping:
        entry = fingerprint_mapping[fingerprint]
        return entry, 'fingerprint'

    if name in exact_raw_mapping:
        share_link = exact_raw_mapping[name]
        proxy = extract_proxy_from_share_link(share_link)
        return make_source_entry('', name, share_link=share_link, proxy=proxy), 'raw-exact'
    if normalized and normalized in normalized_raw_mapping:
        share_link = normalized_raw_mapping[normalized]
        proxy = extract_proxy_from_share_link(share_link)
        return make_source_entry('', name, share_link=share_link, proxy=proxy), 'raw-normalized'
    return {}, ''

def mihomo_api_get(path: str):
    with urllib.request.urlopen(MIHOMO_API + path, timeout=30) as r:
        return json.load(r)

def mihomo_api_put(path: str, payload: dict):
    req = urllib.request.Request(
        MIHOMO_API + path,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='PUT',
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read().decode('utf-8', 'ignore')
    return raw

def wait_mihomo(timeout=40):
    start = time.time()
    last_error = ''
    while time.time() - start < timeout:
        try:
            data = mihomo_api_get('/version')
            if data.get('version'):
                return data
        except Exception as e:
            last_error = str(e)
            time.sleep(1)
    raise RuntimeError(f'mihomo controller not ready: {last_error}')

def resolve_mihomo_download_url():
    headers = {'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'}
    try:
        req = urllib.request.Request(MIHOMO_RELEASE_API, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    except Exception as e:
        # 匿名调用受 runner 共享出口 IP 的 60 次/h 配额限制，失败（限流等）时
        # 回退认证调用：优先 workflow 注入的内置 GITHUB_TOKEN，其次 GH_TOKEN(PAT)
        token = (os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN') or '').strip()
        if not token:
            raise
        log_progress('github_api_anonymous_fallback', reason=str(e))
        req = urllib.request.Request(MIHOMO_RELEASE_API, headers={**headers, 'Authorization': f'Bearer {token}'})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.load(r)
    for asset in data.get('assets', []):
        name = str(asset.get('name') or '')
        if 'linux-amd64-compatible' in name and name.endswith('.gz'):
            return asset.get('browser_download_url')
    raise RuntimeError('mihomo linux-amd64-compatible asset not found in latest release')

def ensure_local_mihomo():
    if MIHOMO.exists() and os.access(MIHOMO, os.X_OK):
        return MIHOMO

    gz_path = HOME_RUNTIME / 'mihomo.gz'
    download_url = resolve_mihomo_download_url()
    with urllib.request.urlopen(download_url, timeout=300) as r, gz_path.open('wb') as f:
        shutil.copyfileobj(r, f)

    with gzip.open(gz_path, 'rb') as src, MIHOMO.open('wb') as dst:
        shutil.copyfileobj(src, dst)
    os.chmod(MIHOMO, 0o755)
    try:
        gz_path.unlink()
    except FileNotFoundError:
        log_progress('mihomo_gz_cleanup_skipped', path=str(gz_path), reason='not_found')
    return MIHOMO

def build_mihomo_config(env):
    health_url = env.get('PROXY_SPEEDTEST_HEALTHCHECK_URL', DEFAULT_HEALTHCHECK_URL).strip() or DEFAULT_HEALTHCHECK_URL
    provider_map = {}
    use_names = []
    provider_source_meta = {}
    for idx, url in enumerate(parse_sub_urls(env), 1):
        name = f'remote-{idx}'
        local_path = PROVIDERS_DIR / f'{name}.yaml'
        text = maybe_decode_base64_subscription(fetch_text(url))
        local_path.write_text(text, encoding='utf-8')
        provider_source_meta[name] = {
            'source_url': url,
            'local_path': str(local_path),
            'size': len(text.encode('utf-8')),
        }
        provider_map[name] = {
            'type': 'file',
            'path': str(local_path),
            'health-check': {
                'enable': True,
                'url': health_url,
                'interval': 86400,
                'timeout': 5000,
                'lazy': False,
                'expected-status': 204,
            },
        }
        use_names.append(name)
    if not provider_map:
        raise RuntimeError('no valid providers built from PROXY_SPEEDTEST_SUB_URLS')
    cfg = {
        'port': 17890,
        'socks-port': 17891,
        'mixed-port': MIHOMO_MIXED_PORT,
        'allow-lan': False,
        'mode': 'global',
        'log-level': env.get('PROXY_SPEEDTEST_MIHOMO_LOG_LEVEL', 'info'),
        'external-controller': '127.0.0.1:19090',
        'secret': '',
        'proxy-groups': [
            {
                'name': 'AUTO',
                'type': 'select',
                'use': use_names,
                'proxies': ['DIRECT'],
            }
        ],
        'proxy-providers': provider_map,
        'rules': ['MATCH,AUTO'],
    }
    MIHOMO_CONFIG.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False), encoding='utf-8')
    return cfg, provider_source_meta

def ensure_mihomo_running(env):
    ensure_local_mihomo()

    for stale in sorted(PROVIDERS_DIR.glob('remote-*.yaml')):
        try:
            stale.unlink()
        except FileNotFoundError:
            log_progress('provider_cache_cleanup_skipped', path=str(stale), reason='not_found')
        except Exception as e:
            log_progress('provider_cache_cleanup_failed', path=str(stale), error=str(e))

    cfg, raw_proxy_map = build_mihomo_config(env)

    try:
        # 更加精准的扫描，只匹配 mihomo -d 启动的内核进程，不匹配脚本本身
        out = subprocess.run(['pgrep', '-af', f'{MIHOMO} -d'], text=True, capture_output=True, timeout=10)
        for raw in (out.stdout or '').splitlines():
            line = raw.strip()
            if not line:
                continue
            pid = int(line.split(None, 1)[0])
            if pid == os.getpid():
                continue
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception as e:
                log_progress('mihomo_process_terminate_skipped', pid=pid, error=str(e))
    except Exception as e:
        log_progress('mihomo_process_scan_failed', error=str(e))

    start = time.time()
    while time.time() - start < 10:
        try:
            data = mihomo_api_get('/version')
            if data.get('version'):
                time.sleep(0.5)
                continue
        except Exception:
            break
        time.sleep(0.5)

    with MIHOMO_LOG.open('a', encoding='utf-8') as lf:
        subprocess.Popen(
            [str(MIHOMO), '-d', str(HOME_RUNTIME), '-f', str(MIHOMO_CONFIG)],
            stdout=lf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    wait_mihomo(timeout=40)
    return raw_proxy_map

def collect_provider_snapshot(source_mapping=None, raw_proxy_map=None):
    data = mihomo_api_get('/providers/proxies')
    providers = {}
    alive_items = []
    seen = set()
    source_mapping = source_mapping or {}
    raw_proxy_map = raw_proxy_map or {}
    for provider_name, info in data.get('providers', {}).items():
        if provider_name in ('AUTO', 'default'):
            continue
        proxies = info.get('proxies', [])
        alive = 0
        dead = 0
        for p in proxies:
            if p.get('alive'):
                alive += 1
                name = p.get('name')
                if name and name not in seen:
                    seen.add(name)
                    fallback_proxy_obj = raw_proxy_map.get(name) or {
                        k: v for k, v in p.items()
                        if k not in ('alive', 'history', 'id', 'tfo', 'xudp')
                    }
                    source_entry, share_link_match = resolve_source_entry_for_node(name, source_mapping, fallback_proxy_obj)
                    share_link = str((source_entry or {}).get('share_link') or '').strip()
                    source_proxy = deep_copy_json((source_entry or {}).get('proxy') or {})
                    proxy_obj = source_proxy or fallback_proxy_obj
                    alive_items.append({
                        'provider': provider_name,
                        'name': name,
                        'type': p.get('type'),
                        'history': p.get('history', []),
                        'share_link': share_link,
                        'share_link_match': share_link_match,
                        'proxy_obj': deep_copy_json(proxy_obj or {}),
                        'source_entry': deep_copy_json(source_entry or {}),
                        'source_id': str((source_entry or {}).get('source_id') or ''),
                    })
            else:
                dead += 1
        providers[provider_name] = {
            'total': len(proxies),
            'alive': alive,
            'dead': dead,
        }
    return providers, alive_items

def build_proxy_env(env):
    local_env = dict(env)
    proxy = f'http://127.0.0.1:{MIHOMO_MIXED_PORT}'
    for k in ['ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']:
        local_env[k] = proxy
    local_env['GIT_TERMINAL_PROMPT'] = '0'
    return local_env

def ensure_gitee_remote(env):
    token = env.get('GITEE_PRIVATE_TOKEN', '').strip()
    if not token:
        raise RuntimeError('missing GITEE_PRIVATE_TOKEN in ~/.openclaw/.env')
    owner = env.get('PROXY_SPEEDTEST_GITEE_OWNER', '').strip()
    repo = env.get('PROXY_SPEEDTEST_GITEE_REPO', 'proxy-speedtest-temp').strip() or 'proxy-speedtest-temp'
    if not owner:
        req = urllib.request.Request(
            'https://gitee.com/api/v5/user',
            headers={'Authorization': 'token ' + token, 'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            owner = json.load(r).get('login', '').strip()
    if not owner:
        raise RuntimeError('failed to resolve Gitee owner')

    body = json.dumps({
        'name': repo,
        'private': True,
        'auto_init': True,
        'description': 'temporary repo for proxy upload/download speed testing',
        'has_issues': False,
        'has_wiki': False,
        'can_comment': False,
    }).encode()
    headers = {
        'Authorization': 'token ' + token,
        'User-Agent': 'Mozilla/5.0',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    }
    req = urllib.request.Request('https://gitee.com/api/v5/user/repos', data=body, headers=headers, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30):
            pass
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8', 'ignore')
        if e.code not in (409, 422) and 'exists' not in raw.lower() and '已经存在' not in raw:
            raise

    remote_with_token = f'https://{owner}:{token}@gitee.com/{owner}/{repo}.git'
    remote_public = f'https://gitee.com/{owner}/{repo}.git'
    return {'owner': owner, 'repo': repo, 'remote_with_token': remote_with_token, 'remote_public': remote_public}

REPO_SIZE_LIMIT_PATTERN = 'size exceeds limit'

def rebuild_gitee_repo(env, gitee: dict):
    """仓库体积超限时，删除并重建仓库。"""
    token = env.get('GITEE_PRIVATE_TOKEN', '').strip()
    owner = gitee['owner']
    repo = gitee['repo']
    headers = {
        'Authorization': 'token ' + token,
        'User-Agent': 'Mozilla/5.0',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
    }
    # 删除仓库
    del_req = urllib.request.Request(
        f'https://gitee.com/api/v5/repos/{owner}/{repo}',
        headers=headers,
        method='DELETE',
    )
    with urllib.request.urlopen(del_req, timeout=30):
        pass
    # 重建仓库
    body = json.dumps({
        'name': repo,
        'private': True,
        'auto_init': True,
        'description': 'temporary repo for proxy upload/download speed testing',
        'has_issues': False,
        'has_wiki': False,
        'can_comment': False,
    }).encode()
    req = urllib.request.Request('https://gitee.com/api/v5/user/repos', data=body, headers=headers, method='POST')
    with urllib.request.urlopen(req, timeout=30):
        pass
    log_progress('repo_auto_rebuilt', owner=owner, repo=repo, reason='size exceeds limit')

def ensure_test_file(size_mib: int):
    path = HOME_RUNTIME / f'gitee_speed_{size_mib}mb.bin'
    wanted = size_mib * 1024 * 1024
    if not path.exists() or path.stat().st_size != wanted:
        with open(path, 'wb') as f:
            f.write(os.urandom(wanted))
    return path

def git_prepare_work_repo(repo_dir: pathlib.Path, remote: str, env, branch_name: str):
    shutil.rmtree(repo_dir, ignore_errors=True)
    code, out, err = run(
        ['git', 'clone', '--depth', '1', '--single-branch', '--branch', branch_name, remote, str(repo_dir)],
        env=env,
        timeout=120,
    )
    if code != 0:
        shutil.rmtree(repo_dir, ignore_errors=True)
        repo_dir.mkdir(parents=True, exist_ok=True)
        steps = [
            ['git', 'init', '-b', branch_name],
            ['git', 'remote', 'add', 'origin', remote],
        ]
        for cmd in steps:
            code2, out2, err2 = run(cmd, cwd=repo_dir, env=env, timeout=60)
            if code2 != 0:
                raise RuntimeError((err2 or out2 or 'git prepare failed')[-400:])
    config_steps = [
        ['git', 'config', 'user.name', 'Javis'],
        ['git', 'config', 'user.email', 'javis@bot.ai'],
    ]
    for cmd in config_steps:
        code, out, err = run(cmd, cwd=repo_dir, env=env, timeout=60)
        if code != 0:
            raise RuntimeError((err or out or 'git config failed')[-400:])

def git_force_push_testfile(repo_dir: pathlib.Path, remote: str, env, file_path: pathlib.Path, commit_message: str, push_timeout: int, branch_name: str, target_filename: str, gitee: dict | None = None):
    """Push 测速文件；若 gitee 传入且 push 因 size exceeds limit 失败，自动重建仓库并重试一次。"""
    def _do_push():
        git_prepare_work_repo(repo_dir, remote, env, branch_name)
        shutil.copy2(file_path, repo_dir / target_filename)
        code, out, err = run(['git', 'add', target_filename], cwd=repo_dir, env=env, timeout=60)
        if code != 0:
            raise RuntimeError((err or out or 'git add failed')[-400:])
        code, out, err = run(['git', 'commit', '--allow-empty', '-m', commit_message], cwd=repo_dir, env=env, timeout=60)
        if code != 0:
            raise RuntimeError((err or out or 'git commit failed')[-400:])
        t0 = time.time()
        code, out, err = run(['git', 'push', '-f', 'origin', f'HEAD:refs/heads/{branch_name}'], cwd=repo_dir, env=env, timeout=push_timeout)
        if code != 0:
            raise RuntimeError((err or out or 'git push failed')[-500:])
        return time.time() - t0

    try:
        return _do_push()
    except RuntimeError as e:
        if gitee is None or REPO_SIZE_LIMIT_PATTERN not in str(e):
            raise
        log_progress('repo_size_limit_detected', owner=gitee['owner'], repo=gitee['repo'])
        rebuild_gitee_repo(env, gitee)
        return _do_push()

def git_clone_testbranch(clone_dir: pathlib.Path, remote: str, env, timeout: int, branch_name: str, target_filename: str):
    shutil.rmtree(clone_dir, ignore_errors=True)
    t0 = time.time()
    code, out, err = run(
        ['git', 'clone', '--depth', '1', '--single-branch', '--branch', branch_name, remote, str(clone_dir)],
        env=env,
        timeout=timeout,
    )
    if code != 0:
        raise RuntimeError((err or out or 'git clone failed')[-500:])
    pulled = clone_dir / target_filename
    if not pulled.exists():
        raise RuntimeError('downloaded test file missing')
    return time.time() - t0, pulled

def switch_proxy(name: str, settle_seconds: float):
    mihomo_api_put(f'/proxies/{urllib.parse.quote("AUTO", safe="")}', {'name': name})
    time.sleep(settle_seconds)

def git_direct_speedtest(env, gitee, test_file: pathlib.Path, push_timeout: int, clone_timeout: int, speedtest_mode: str, max_attempts: int = 5):
    local_env = dict(env)
    for k in ['ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy']:
        local_env.pop(k, None)
    local_env['GIT_TERMINAL_PROMPT'] = '0'
    branch_name = f'{TEST_BRANCH}-direct'
    target_filename = TEST_FILE_NAME
    repo_dir = HOME_RUNTIME / 'upload-direct-baseline'
    clone_dir = HOME_RUNTIME / 'download-direct-baseline'
    attempt_errors = []
    max_attempts = max(1, int(max_attempts))

    for attempt in range(1, max_attempts + 1):
        try:
            log_progress('direct_baseline_attempt_started', attempt=attempt, max_attempts=max_attempts)
            upload_s = git_force_push_testfile(
                repo_dir=repo_dir,
                remote=gitee['remote_with_token'],
                env=local_env,
                file_path=test_file,
                commit_message='speedtest direct baseline',
                push_timeout=push_timeout,
                branch_name=branch_name,
                target_filename=target_filename,
                gitee=gitee,
            )
            size_mib = test_file.stat().st_size / 1024 / 1024
            result = {
                'ok': True,
                'mode': speedtest_mode,
                'branch_name': branch_name,
                'target_filename': target_filename,
                'attempt': attempt,
                'max_attempts': max_attempts,
                'upload_mibs': round(size_mib / upload_s, 2),
                'upload_seconds': round(upload_s, 3),
            }
            if speedtest_mode != 'push-only':
                download_s, pulled = git_clone_testbranch(
                    clone_dir=clone_dir,
                    remote=gitee['remote_with_token'],
                    env=local_env,
                    timeout=clone_timeout,
                    branch_name=branch_name,
                    target_filename=target_filename,
                )
                size_mib = pulled.stat().st_size / 1024 / 1024
                result.update({
                    'download_mibs': round(size_mib / download_s, 2),
                    'download_seconds': round(download_s, 3),
                })
            log_progress('direct_baseline_attempt_finished', attempt=attempt, max_attempts=max_attempts, ok=True)
            return result
        except Exception as e:
            reason = str(e)
            attempt_errors.append(reason)
            log_progress('direct_baseline_attempt_finished', attempt=attempt, max_attempts=max_attempts, ok=False, reason=reason)
            if attempt < max_attempts:
                # 直连 Git push 偶发超时较常见；短暂停顿后重试，避免一次抖动导致整轮基线缺失。
                time.sleep(min(2 * attempt, 10))

    joined_errors = ' | '.join(f'第{i}次: {err}' for i, err in enumerate(attempt_errors, 1))
    raise RuntimeError(f'本机直连基线测速连续 {max_attempts} 次失败: {joined_errors[-1500:]}')

def speedtest_single_item(env, gitee, item: dict, test_file: pathlib.Path, push_timeout: int, clone_timeout: int, switch_settle_seconds: float, speedtest_mode: str):
    name = item['name']
    local_env = build_proxy_env(env)
    branch_name = TEST_BRANCH
    target_filename = TEST_FILE_NAME
    switch_proxy(name, switch_settle_seconds)

    # 延迟：经代理对 gitee.com 做 HTTP 计时（与 cdn 的 latency_probe 同口径，共享实现）。
    # 失败只降级（prefix/图例自动省略 ms 项），不影响该节点 push/clone 计成功。
    latency = latency_probe(
        ['https://gitee.com'], local_env,
        samples=int(env.get('PROXY_SPEEDTEST_LATENCY_SAMPLES', '4') or 4),
        timeout=float(env.get('PROXY_SPEEDTEST_LATENCY_TIMEOUT', '8') or 8),
    )
    log_progress('latency_probe_finished', name=name, ok=latency.get('ok'),
                 median_ms=latency.get('median_ms'), error=latency.get('error'))

    repo_dir = HOME_RUNTIME / f'upload-{sanitize_name(name)}'
    clone_dir = HOME_RUNTIME / f'download-{sanitize_name(name)}'
    upload_s = git_force_push_testfile(
        repo_dir=repo_dir,
        remote=gitee['remote_with_token'],
        env=local_env,
        file_path=test_file,
        commit_message=f'speedtest {sanitize_name(name)}',
        push_timeout=push_timeout,
        branch_name=branch_name,
        target_filename=target_filename,
        gitee=gitee,
    )
    size_mib = test_file.stat().st_size / 1024 / 1024
    result = {
        'name': name,
        'provider': item['provider'],
        'type': item.get('type'),
        'share_link': item.get('share_link', ''),
        'share_link_match': item.get('share_link_match', ''),
        'proxy_obj': deep_copy_json(item.get('proxy_obj') or {}),
        'ok': True,
        'branch_name': branch_name,
        'target_filename': target_filename,
        'mode': speedtest_mode,
        'latency': latency,
        'latency_ms': latency.get('median_ms') if latency.get('ok') else None,
        'upload_mibs': round(size_mib / upload_s, 2),
        'upload_seconds': round(upload_s, 3),
    }
    if speedtest_mode != 'push-only':
        download_s, pulled = git_clone_testbranch(
            clone_dir=clone_dir,
            remote=gitee['remote_with_token'],
            env=local_env,
            timeout=clone_timeout,
            branch_name=branch_name,
            target_filename=target_filename,
        )
        size_mib = pulled.stat().st_size / 1024 / 1024
        result.update({
            'download_mibs': round(size_mib / download_s, 2),
            'download_seconds': round(download_s, 3),
        })
    return result

def resolve_push_target_info(remote_url: str):
    parsed = urllib.parse.urlparse(remote_url)
    host = parsed.hostname or 'gitee.com'
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    scheme = parsed.scheme or 'https'
    addresses = []
    errors = []
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        seen = set()
        for family, socktype, proto, canonname, sockaddr in infos:
            ip = sockaddr[0]
            if ip not in seen:
                seen.add(ip)
                addresses.append(ip)
    except Exception as e:
        errors.append(str(e))
    return {
        'host': host,
        'port': port,
        'scheme': scheme,
        'addresses': addresses,
        'address_count': len(addresses),
        'error': '; '.join(errors) if errors else '',
    }

def lookup_ip_city(ip: str):
    providers = [
        {
            'url': f'https://ipapi.co/{ip}/json/',
            'extract': lambda d: ' / '.join([x for x in [
                (d.get('country_name') or '').strip(),
                (d.get('region') or '').strip(),
                (d.get('city') or '').strip(),
            ] if x]),
        },
        {
            'url': f'https://ipwho.is/{ip}',
            'extract': lambda d: ' / '.join([x for x in [
                (d.get('country') or '').strip(),
                (d.get('region') or '').strip(),
                (d.get('city') or '').strip(),
            ] if x]),
        },
        {
            'url': f'https://ipinfo.io/{ip}/json',
            'extract': lambda d: ' / '.join([x for x in [
                (d.get('country') or '').strip(),
                (d.get('region') or '').strip(),
                (d.get('city') or '').strip(),
            ] if x]),
        },
    ]
    last_error = ''
    for provider in providers:
        try:
            req = urllib.request.Request(provider['url'], headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=10) as r:
                data = json.load(r)
            text = provider['extract'](data).strip()
            if text:
                return text
        except Exception as e:
            last_error = str(e)
            continue
    raise RuntimeError(last_error or 'ip city lookup failed')

def build_push_ip_city_text(addresses):
    items = []
    for ip in addresses[:8]:
        try:
            items.append(f'{ip} ({lookup_ip_city(ip)})')
        except Exception:
            items.append(f'{ip} (查询失败)')
    return '；'.join(items)

def check_mihomo_runtime():
    errors = []
    try:
        mihomo_api_get('/version')
    except Exception as e:
        errors.append(f'controller unavailable: {e}')
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(1.5)
    try:
        s.connect(('127.0.0.1', MIHOMO_MIXED_PORT))
    except Exception as e:
        errors.append(f'mixed-port unavailable: {e}')
    finally:
        try:
            s.close()
        except Exception as e:
            log_progress('mihomo_runtime_socket_close_failed', error=str(e))
    return {'ok': not errors, 'error': '; '.join(errors)}

def format_duration(seconds: float):
    total = int(round(seconds))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f'{h}h {m}m {s}s'
    if m:
        return f'{m}m {s}s'
    return f'{s}s'

def build_run_summary(*, started_at, ended_at, elapsed_seconds, duration_text, aborted_due_to_runtime, runtime_abort_reason, direct_baseline, size_mib, speedtest_mode, snapshot_meta, provider_snapshot, gitee, push_target_info, total_probe_count, alive_probe_count, speed_results, ok_results, failed_results, ok_results_by_download, subscription_text):
    return {
        'time': ended_at,
        'started_at': started_at,
        'ended_at': ended_at,
        'duration_seconds': round(elapsed_seconds, 2),
        'duration_text': duration_text,
        'aborted_due_to_runtime': aborted_due_to_runtime,
        'runtime_abort_reason': runtime_abort_reason,
        'plan': {
            'direct_baseline': direct_baseline,
            'stages': ['direct-git-baseline', 'mihomo-provider-healthcheck', f'{size_mib}MB-gitee-{speedtest_mode}-speedtest', 'gist-update', 'gist-verify', 'telegram-notify'],
            'mixed_port': MIHOMO_MIXED_PORT,
            'test_branch': TEST_BRANCH,
            'test_file_name': TEST_FILE_NAME,
            'runtime_dir': str(HOME_RUNTIME),
        },
        'source_snapshots': snapshot_meta,
        'mihomo': {
            'api': MIHOMO_API,
            'binary': str(MIHOMO),
            'config': str(MIHOMO_CONFIG),
            'log': str(MIHOMO_LOG),
            'providers': provider_snapshot,
        },
        'gitee': {
            **gitee,
            'push_target': push_target_info,
        },
        'probe_total_count': total_probe_count,
        'probe_alive_count': alive_probe_count,
        'speedtest_attempted_count': len(speed_results),
        'speedtest_success_count': len(ok_results),
        'speedtest_failed_count': len(failed_results),
        'results': speed_results,
        'sorted_success': ok_results_by_download,
        'subscription_text': subscription_text,
        'gist': {'ok': False, 'reason': 'not-run-yet'},
    }

def build_summary_lines(*, started_at, ended_at, duration_text, alive_probe_count, ok_results, speed_results, speedtest_mode, aborted_due_to_runtime, runtime_abort_reason, ok_results_by_download, metric_label=''):
    """生成人性化 Telegram 通知，版式对齐 speedtest.build_telegram_lines。

    2026-09-08 起 TOP 节点条目与四套统一为三项指标（↑上传 · ↓下载 · 延迟ms，
    build_node_metric_prefix 渲染，未测出的指标整项省略）。
    Push 目标 / 直连基线等诊断信息保留在 RESULT_JSON，不再进通知。
    """
    started_text = str(started_at)[:19].replace('T', ' ')
    ended_text = str(ended_at)[:19].replace('T', ' ')
    # 通知行耗时用中文三段式（与全库时长格式统一，勿出现 5h57m）；
    # RESULT_JSON 的 duration_text 保持紧凑格式不变
    try:
        duration_cn = tg_format_elapsed(
            (datetime.fromisoformat(str(ended_at)[:19]) - datetime.fromisoformat(str(started_at)[:19])).total_seconds())
    except Exception:
        # 兜底不能回退到 duration_text（紧凑英文格式 5h57m，规范 4.3 节 禁进通知）
        duration_cn = '-'
    # 统一 HTML 版式（对齐 speedtest.build_telegram_lines / 全库通知模板）：
    # emoji 标题 + ━━━ 分隔线 + 键值概览（数值裸文本）+ 树形 TOP5（节点 <code>）+ 统一收尾区
    sep = TG_SEP
    esc = lambda s: html.escape(str(s))
    # 标题状态随结论降级（规范 8.2 节 状态图标语义）：0 节点测速成功 / 本轮中止 → ⚠️，
    # 不再恒 ✅（此前「✅ 完成」下面写着「⚠️ 没有节点测速成功」，自相矛盾）
    _title_emoji = '⚠️' if (aborted_due_to_runtime or not ok_results_by_download) else '✅'
    summary_lines = [
        f'{_title_emoji} Gitee 测速完成',
        sep,
        f'🕒 起止：{esc(started_text)} ~ {esc(ended_text)} · 耗时 {esc(duration_cn)}',
        f'📊 节点：共 {len(speed_results)} 个 · 可用 {len(ok_results)} 个',
        '',
    ]
    # 测速点（Gitee push 目标）的网络归属：域名解析 IP 后查 ISP/ASN/位置
    gitee_ip = resolve_host_ipv4('gitee.com')
    gitee_info = fetch_ip_network_info(gitee_ip) if gitee_ip else None
    summary_lines.extend(build_target_network_section([(gitee_ip or '', 'gitee.com', gitee_info)]))
    summary_lines.append('')
    if aborted_due_to_runtime:
        summary_lines.append(f'⚠️ 本轮已中止：{esc(runtime_abort_reason)}')
        summary_lines.append('')
    if ok_results_by_download:
        top = ok_results_by_download[:5]
        # 四套统一三项指标（↑上传 · ↓下载 · 延迟ms）：条目复用共享的
        # build_node_metric_prefix（↑在前对齐泰尔列序），未测出的指标整项省略，
        # 图例按 TOP 内实际存在的指标拼，避免误导
        has_up = any(get_item_megabits(it, 'push-only') > 0 for it in top)
        has_down = speedtest_mode != 'push-only' and any(
            get_item_megabits(it, speedtest_mode) > 0 for it in top)
        has_lat = any(isinstance(it.get('latency_ms'), (int, float)) and it['latency_ms'] > 0
                      for it in top)
        legend = ' · '.join(part for part, on in (
            ('↑上传', has_up), ('↓下载', has_down), ('延迟ms', has_lat)) if on) or '速度'
        # TOP 已按订阅判定指标排序（见 ok_results_by_download），标题同步点出排序依据
        sort_hint = f' · 按{html.escape(metric_label)}' if metric_label else ''
        summary_lines.append(f"🏆 最快节点 · {len(top)}{sort_hint} · {legend}")
        for idx, item in enumerate(top, 1):
            prefix = build_node_metric_prefix(item, speedtest_mode, order='up_first') or '-'
            connector = '└─' if idx == len(top) else '├─'
            # 条目行统一走共享的 tg_entry（主体 + 元数据，转义与分隔符一致）
            summary_lines.append(f'  {connector} ' + tg_entry(item['name'], prefix))
        summary_lines.append('')
    elif alive_probe_count > 0:
        summary_lines.append('⚠️ 没有节点测速成功')
        summary_lines.append('  └─ 有节点通过 provider 健康检查，但正式 Gitee 推送/拉取测速全部失败')
        summary_lines.append('')
    else:
        summary_lines.append('⚠️ 没有节点通过 provider 健康检查')
        summary_lines.append('')
    # 失败节点明细（与 taier 对齐：原因可见，便于区分拒测/超时/鉴权失败）
    _failed = [r for r in speed_results if not r.get('ok')]
    if _failed:
        summary_lines.append(f'❌ 失败 · {len(_failed)}')
        _fe = [tg_entry_codes(r.get('name', ''), (r.get('error') or r.get('reason') or '-')[:80])
               for r in _failed[:5]]
        if len(_failed) > 5:
            _fe.append(f'还有 {len(_failed) - 5} 条…')
        for _i, _l in enumerate(_fe, 1):
            _c = '└─' if _i == len(_fe) else '├─'
            summary_lines.append(f'  {_c} {_l}')
        summary_lines.append('')
    # 收尾区不在这里追加：finalize_gist_and_notify 还会在正文末尾补「📦 订阅 · Gist」段，
    # 收尾行必须位于所有正文之后（规范 4.9 节），统一由 finalize 在最后追加
    return summary_lines

def update_summary_artifacts(summary):
    RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    log_progress('result_json_written', path=str(RESULT_JSON))

def finalize_gist_and_notify(env, summary, summary_lines, subscription_text, bundle):
    # 订阅策略 bundle：阈值 / 实际采用的判定指标 / 达标数 / 最少节点数
    qualified_count = (bundle or {}).get('qualified', 0)
    min_megabit = (bundle or {}).get('min_megabit', DEFAULT_MIN_MEGABIT)
    min_nodes = (bundle or {}).get('min_nodes', DEFAULT_MIN_NODES)
    metric_label = (bundle or {}).get('metric_label', METRIC_LABELS[DEFAULT_SPEED_METRIC])
    # summary_lines 已是统一 HTML 版式；文本报告落盘去标签保留纯可读性
    _plain = re.sub(r'<[^>]+>', '', '\n'.join(summary_lines))
    RESULT_TXT.write_text(_plain + '\n', encoding='utf-8')
    log_progress('result_txt_written', path=str(RESULT_TXT))
    log_progress('gist_update_started')
    try:
        gist_res = update_gist(env, subscription_text)
    except Exception as e:
        gist_res = {'ok': False, 'reason': str(e)}
    log_progress('gist_update_finished', ok=bool(gist_res.get('ok')), reason=gist_res.get('reason', ''), html_url=gist_res.get('html_url', ''))
    summary['gist'] = gist_res
    try:
        RESULT_JSON.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception as e:
        log_progress('result_json_write_failed', path=str(RESULT_JSON), error=str(e))

    # 2026-09-10：不再对上传的订阅做「回拉 + 第二 mihomo 抽样验证」。
    # 理由：抽检通过与否并不比本轮刚跑过的 push/clone 指标更有信息量，却要额外
    # 拉 raw + 起第二个内核（成本高）；失败时（如 raw 端 400）只会在每轮通知挂一行
    # 误导性的 ⚠️（抽样未开始也显示成 0/0「一个都不通」）。而「导出的 YAML 可解析」
    # 在导出端已由 build_mihomo_yaml_text 保证（proxies 为空直接不上传）。
    summary_lines.append('📦 订阅 · Gist')
    if gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        html_url = gist_res.get('html_url') or ''
        gist_lines = [f'✅ 已{action}，达标 {qualified_count} 个节点 · ≥{min_megabit}兆（按{html.escape(metric_label)}）']
        if html_url:
            gist_lines.append(f'🔗 <a href="{html.escape(html_url)}">订阅源 YAML</a>')
        for _i, _l in enumerate(gist_lines):
            _c = '└─' if _i == len(gist_lines) - 1 else '├─'
            summary_lines.append(f'  {_c} {_l}')
    elif (gist_res.get('reason') or '').startswith('empty subscription'):
        summary_lines.append(f'  └─ ⚠️ 达标不足 {min_nodes} 个 · 阈值 ≥{min_megabit}兆（按{html.escape(metric_label)}）· 未更新订阅')
    else:
        summary_lines.append(f"  └─ ⚠️ 上传失败：{tg_entry(gist_res.get('reason', ''))}")
    # 统一收尾区（收尾区与正文间固定一个空行；与 tg_add_footer 同形态同降级链）
    # 必须在所有正文段之后追加（「📦 订阅 · Gist」是正文的最后一段）——此前在
    # build_summary_lines 里加，被此段挤到正文中间，消息末尾反而没有收尾行（规范 4.9 节）
    summary_lines.append('')
    footer = tg_footer_line()
    if footer:
        summary_lines.append(footer)
    try:
        # summary_lines 已是统一 HTML 版式；文本报告落盘去标签保留纯可读性
        _plain = re.sub(r'<[^>]+>', '', '\n'.join(summary_lines))
        RESULT_TXT.write_text(_plain + '\n', encoding='utf-8')
    except Exception as e:
        log_progress('result_txt_rewrite_failed', path=str(RESULT_TXT), error=str(e))

    log_progress('telegram_send_started')
    try:
        tg_res = send_telegram_chunked(env, '\n'.join(summary_lines))
    except Exception as e:
        tg_res = {'ok': False, 'reason': str(e)}
    log_progress('telegram_send_finished', sent=bool(tg_res.get('sent')), reason=tg_res.get('reason', ''))
    # 日志收尾输出走统一脱敏：gist 链接/ID 属于凭据级敏感信息，不进 Actions 日志
    print(json.dumps(_redact_value('final', {
        'gist': {k: gist_res.get(k) for k in ('ok', 'created', 'reason')},
        'telegram': {k: tg_res.get(k) for k in ('sent', 'reason')},
        'probe_total_count': summary.get('probe_total_count', 0),
        'probe_alive_count': summary.get('probe_alive_count', 0),
        'speedtest_attempted_count': summary.get('speedtest_attempted_count', 0),
        'speedtest_success_count': summary.get('speedtest_success_count', 0),
        'speedtest_failed_count': summary.get('speedtest_failed_count', 0),
        'duration_text': summary.get('duration_text', ''),
        'result_json': str(RESULT_JSON),
        'result_txt': str(RESULT_TXT),
        'result_subscription': str(RESULT_SUBSCRIPTION),
    }), ensure_ascii=False))

def main():
    if maybe_detach_self():
        return
    global CURRENT_RUN_STARTED_AT
    signal.signal(signal.SIGTERM, handle_termination_signal)
    signal.signal(signal.SIGINT, handle_termination_signal)
    started_ts = time.time()
    started_at = datetime.now().isoformat()
    CURRENT_RUN_STARTED_AT = started_at
    log_progress('start', runtime_dir=str(HOME_RUNTIME), result_json=str(RESULT_JSON), result_txt=str(RESULT_TXT))
    env = merged_env()
    log_progress('env_loaded')
    source_mapping = run_stage('订阅源拉取/解析', build_source_mapping, env)
    snapshot_meta = source_mapping.get('snapshot_meta') or []
    if snapshot_meta:
        log_progress('source_snapshot_saved', count=len(snapshot_meta), paths=[x.get('path') for x in snapshot_meta])
    log_progress(
        'subscription_mapping_ready',
        mapped_count=(len(source_mapping.get('exact_raw') or {}) + len(source_mapping.get('normalized_raw') or {})),
        raw_exact_count=len(source_mapping.get('exact_raw') or {}),
        raw_normalized_count=len(source_mapping.get('normalized_raw') or {}),
        exact_count=len(source_mapping.get('exact') or {}),
        normalized_count=len(source_mapping.get('normalized') or {}),
    )
    raw_proxy_map = run_stage('mihomo 启动/配置', ensure_mihomo_running, env)
    log_progress('mihomo_ready', api=MIHOMO_API, mixed_port=MIHOMO_MIXED_PORT)
    provider_snapshot, alive_items = run_stage('provider 健康检查', collect_provider_snapshot, source_mapping=source_mapping, raw_proxy_map=raw_proxy_map)
    log_progress('provider_snapshot_ready', provider_count=len(provider_snapshot), alive_count=len(alive_items))
    gitee = run_stage('Gitee 仓库准备', ensure_gitee_remote, env)
    log_progress('gitee_ready', owner=gitee['owner'], repo=gitee['repo'], remote_public=gitee['remote_public'])
    push_target_info = run_stage('Gitee 目标解析', resolve_push_target_info, gitee['remote_public'])
    push_target_city_text = build_push_ip_city_text(push_target_info['addresses']) if push_target_info['addresses'] else ''
    log_progress('push_target_resolved', host=push_target_info['host'], port=push_target_info['port'], address_count=push_target_info['address_count'], ip_city_text=push_target_city_text)

    size_mib = int(env.get('PROXY_SPEEDTEST_SIZE_MIB', env.get('PROXY_SPEEDTEST_GITEE_SIZE_MIB', '10')))
    clone_timeout = int(env.get('PROXY_SPEEDTEST_CLONE_TIMEOUT', '30'))
    push_timeout = int(env.get('PROXY_SPEEDTEST_PUSH_TIMEOUT', '30'))
    direct_baseline_timeout = int(env.get('PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT', '60'))
    direct_baseline_max_attempts = int(env.get('PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS', '5'))
    max_nodes = int(env.get('PROXY_SPEEDTEST_MAX_NODES', '0'))
    switch_settle_seconds = float(env.get('PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS', '1.5'))
    # 默认 both = 上行 + clone 下行 + 延迟（2026-09-08 用户拍板：四套指标口径对齐）；
    # push-only = 只测上行（历史模式，可用 env 退回）
    speedtest_mode = (env.get('PROXY_SPEEDTEST_MODE', 'both') or 'both').strip().lower()

    if max_nodes > 0:
        alive_items = alive_items[:max_nodes]

    log_progress('speedtest_plan_ready', speedtest_mode=speedtest_mode, size_mib=size_mib, push_timeout=push_timeout, clone_timeout=clone_timeout, direct_baseline_timeout=direct_baseline_timeout, direct_baseline_max_attempts=direct_baseline_max_attempts, total_nodes=len(alive_items))
    test_file = run_stage('测速文件准备', ensure_test_file, size_mib)
    log_progress('test_file_ready', path=str(test_file), size_mib=size_mib)
    direct_baseline = None
    log_progress('direct_baseline_started', speedtest_mode=speedtest_mode, timeout=direct_baseline_timeout, max_attempts=direct_baseline_max_attempts)
    try:
        direct_baseline = git_direct_speedtest(
            env=env,
            gitee=gitee,
            test_file=test_file,
            push_timeout=direct_baseline_timeout,
            clone_timeout=direct_baseline_timeout,
            speedtest_mode=speedtest_mode,
            max_attempts=direct_baseline_max_attempts,
        )
        log_progress(
            'direct_baseline_finished',
            ok=True,
            upload_mibs=direct_baseline.get('upload_mibs'),
            download_mibs=direct_baseline.get('download_mibs'),
            upload_seconds=direct_baseline.get('upload_seconds'),
            download_seconds=direct_baseline.get('download_seconds'),
        )
    except Exception as e:
        direct_baseline = {'ok': False, 'reason': str(e), 'mode': speedtest_mode}
        log_progress('direct_baseline_finished', ok=False, reason=str(e))
    speed_results = []
    aborted_due_to_runtime = False
    runtime_abort_reason = ''
    repo_rebuilt = False
    ok_pushes = 0

    def _enrich_result(r, index, item):
        r['index'] = index
        r['share_link'] = item.get('share_link', '')
        r['share_link_match'] = item.get('share_link_match', '')
        r['source_entry'] = deep_copy_json(item.get('source_entry') or {})
        r['source_id'] = item.get('source_id', '')
        return r

    for index, item in enumerate(alive_items, 1):
        touch_lock_file()
        runtime_status = check_mihomo_runtime()
        if not runtime_status['ok']:
            aborted_due_to_runtime = True
            runtime_abort_reason = runtime_status['error']
            log_progress('runtime_abort', index=index, total=len(alive_items), reason=runtime_abort_reason)
            break
        log_progress('node_start', index=index, total=len(alive_items), name=item['name'], provider=item['provider'], node_type=item.get('type'))
        try:
            result = _enrich_result(speedtest_single_item(
                env=env,
                gitee=gitee,
                item=item,
                test_file=test_file,
                push_timeout=push_timeout,
                clone_timeout=clone_timeout,
                switch_settle_seconds=switch_settle_seconds,
                speedtest_mode=speedtest_mode,
            ), index, item)
        except Exception as e:
            err_text = str(e)
            result = None
            # 本轮首个 push/clone 就超时或被拒（Gitee 仓库超限/被回收时，git 常表现为
            # 挂起超时而非明确报错，直连基线会同步失败）→ 重建仓库后重试该节点一次；
            # 每轮最多重建一次，避免个别慢节点误触发反复删库。
            if not repo_rebuilt and ok_pushes == 0 and (
                    'timed out' in err_text or REPO_SIZE_LIMIT_PATTERN in err_text
                    or 'could not read Username' in err_text):
                log_progress('repo_rebuild_on_push_timeout', node=item.get('name', ''), error=err_text[:200])
                repo_rebuilt = True
                try:
                    rebuild_gitee_repo(env, gitee)
                    result = _enrich_result(speedtest_single_item(
                        env=env,
                        gitee=gitee,
                        item=item,
                        test_file=test_file,
                        push_timeout=push_timeout,
                        clone_timeout=clone_timeout,
                        switch_settle_seconds=switch_settle_seconds,
                        speedtest_mode=speedtest_mode,
                    ), index, item)
                except Exception as e2:
                    err_text = f'{err_text} | rebuild retry: {str(e2)[:300]}'
            if result is None:
                result = {
                    'index': index,
                    'name': item['name'],
                    'provider': item['provider'],
                    'type': item.get('type'),
                    'share_link': item.get('share_link', ''),
                    'share_link_match': item.get('share_link_match', ''),
                    'source_entry': deep_copy_json(item.get('source_entry') or {}),
                    'source_id': item.get('source_id', ''),
                    'ok': False,
                    'error': err_text,
                }
                if ('127.0.0.1' in err_text and f'port {MIHOMO_MIXED_PORT}' in err_text and ("Couldn't connect to server" in err_text or 'Connection refused' in err_text)) or '<urlopen error [Errno 111] Connection refused>' in err_text:
                    aborted_due_to_runtime = True
                    runtime_abort_reason = err_text
        speed_results.append(result)
        if result.get('ok'):
            ok_pushes += 1
        log_progress('node_done', index=index, total=len(alive_items), name=item['name'], ok=bool(result.get('ok')), error=result.get('error', ''), upload_mibs=result.get('upload_mibs'), download_mibs=result.get('download_mibs'))
        # 日志只输出脱敏摘要：节点名/分享链接/原始代理配置/订阅来源一律打码，防止 Actions 日志泄漏
        print(json.dumps(_redact_value('result', result), ensure_ascii=False), flush=True)
        if aborted_due_to_runtime:
            log_progress('runtime_abort', index=index, total=len(alive_items), reason=runtime_abort_reason)
            break

    total_probe_count = sum(v['total'] for v in provider_snapshot.values())
    alive_probe_count = sum(v['alive'] for v in provider_snapshot.values())
    ok_results = [x for x in speed_results if x.get('ok')]
    failed_results = [x for x in speed_results if not x.get('ok')]
    # 订阅导出策略：阈值/判定指标/最少节点数（env 覆盖；判定指标默认 upload，
    # 达标不足 min_nodes 时自动改用 download，反之亦然 —— 见 resolve_subscription_metric）
    policy = resolve_subscription_policy(env)
    bundle = build_subscription_bundle(ok_results, policy)
    min_megabit = policy['min_megabit']
    # TOP 排序与订阅判定同口径（按实际采用的指标排序，避免「按上行导出却按下行排 TOP」）
    ok_results_by_download = sorted(
        ok_results,
        key=lambda x: x.get('upload_mibs', 0) if bundle['metric_mode'] == 'push-only' else x.get('download_mibs', 0),
        reverse=True,
    )
    subscription_text = bundle['text']
    try:
        RESULT_SUBSCRIPTION.write_text(subscription_text, encoding='utf-8')
    except Exception as e:
        log_progress('result_subscription_write_failed', path=str(RESULT_SUBSCRIPTION), error=str(e))
    log_progress(
        'summary_ready',
        attempted=len(speed_results),
        success=len(ok_results),
        failed=len(failed_results),
        subscription_lines=len([x for x in subscription_text.splitlines() if x.strip()]),
        subscription_path=str(RESULT_SUBSCRIPTION),
    )

    elapsed_seconds = time.time() - started_ts
    ended_at = datetime.now().isoformat()
    duration_text = format_duration(elapsed_seconds)
    summary = build_run_summary(
        started_at=started_at,
        ended_at=ended_at,
        elapsed_seconds=elapsed_seconds,
        duration_text=duration_text,
        aborted_due_to_runtime=aborted_due_to_runtime,
        runtime_abort_reason=runtime_abort_reason,
        direct_baseline=direct_baseline,
        size_mib=size_mib,
        speedtest_mode=speedtest_mode,
        snapshot_meta=snapshot_meta,
        provider_snapshot=provider_snapshot,
        gitee=gitee,
        push_target_info=push_target_info,
        total_probe_count=total_probe_count,
        alive_probe_count=alive_probe_count,
        speed_results=speed_results,
        ok_results=ok_results,
        failed_results=failed_results,
        ok_results_by_download=ok_results_by_download,
        subscription_text=subscription_text,
    )
    run_stage('结果落盘', update_summary_artifacts, summary)
    summary_lines = build_summary_lines(
        started_at=started_at,
        ended_at=ended_at,
        duration_text=duration_text,
        alive_probe_count=alive_probe_count,
        ok_results=ok_results,
        speed_results=speed_results,
        speedtest_mode=speedtest_mode,
        aborted_due_to_runtime=aborted_due_to_runtime,
        runtime_abort_reason=runtime_abort_reason,
        ok_results_by_download=ok_results_by_download,
        metric_label=bundle['metric_label'],
    )
    run_stage('Gist 更新/通知', finalize_gist_and_notify, env, summary, summary_lines, subscription_text, bundle)

def scrub_secrets(text: str, env=None) -> str:
    """从任意文本中清除已知凭据：带凭据的 URL、订阅地址、各类 Token。"""
    scrubbed = _scrub_cred_urls(text)
    try:
        if env is None:
            env = merged_env()
        candidates = []
        for key in ('PROXY_SPEEDTEST_SUB_URLS', 'GITEE_PRIVATE_TOKEN', 'GH_TOKEN',
                    'TELEGRAM_BOT_TOKEN', 'PROXY_SPEEDTEST_GIST_ID'):
            raw = str(env.get(key, '') or '').strip()
            if raw:
                candidates.extend(x.strip() for x in raw.split(',') if x.strip())
        for secret in candidates:
            scrubbed = scrubbed.replace(secret, '***')
    except Exception:
        pass
    return scrubbed

if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        err_text = scrub_secrets(str(e))
        stage = e.stage if isinstance(e, StageError) else '未标记阶段'
        print(json.dumps({'ok': False, 'stage': stage, 'error': err_text}, ensure_ascii=False))
        try:
            env = merged_env()
            # 统一 HTML 版式（emoji + 短语标题（无加粗）/分隔线/全角冒号 kv/统一收尾区）；
            # 异常文本含 <>& 时未转义会触发 400 整条丢失（不退化，2026-09-06 拍板），必须 html.escape
            _sep = TG_SEP
            _msg = (f'❌ Gitee 测速异常退出 · {html.escape(str(stage))}\n{_sep}\n'
                    f'错误：{tg_entry(err_text[:800])}')
            _footer = tg_footer_line()
            if _footer:
                _msg += f'\n\n{_footer}'
            send_telegram_chunked(env, _msg)
        except Exception:
            pass
        sys.exit(1)
