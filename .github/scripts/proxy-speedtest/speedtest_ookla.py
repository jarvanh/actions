#!/usr/bin/env python3
"""订阅节点 Speedtest 测速（引擎 Ookla 官方 speedtest CLI，链路 mihomo TUN 透明代理）。

与 speedtest.py / taier_speedtest.py 同属「订阅节点测速」域：复用 speedtest_common.py 共享层
（订阅导出策略 / 通知排版 / 测速点归属查询 / Telegram 发送 / Gist 上传）与 speedtest_gitee.py 的
mihomo 内核 / 订阅供应商 / 节点快照 / 节点切换；测速引擎换成 Ookla 官方 Speedtest CLI，
拿到的是「订阅节点 → 指定 Speedtest 测速点（默认广东广州·联通）」的延迟与上下行带宽。

为什么必须开 TUN：Ookla 官方 CLI 没有 --proxy 参数，只能靠 mihomo TUN 把该进程的流量透明
接入代理节点。为不误伤 runner 自身网络：

    rules: ['PROCESS-NAME,<speedtest 二进制名>,AUTO', 'MATCH,DIRECT']

即只有测速进程走代理、其余流量（含 GitHub runner 自己的心跳/日志）直连；再用
「测速看到的出口 IP == runner 直连出口 IP」校验规则是否真的生效——规则失灵或 TUN 起不来时会
静默直连、整轮结果失真，这个校验必须存在（bypass 命中即判失败）。

为什么必须显式指定测速点编号：Ookla 的服务器列表按**请求方出口 IP** 的远近排序，GitHub
runner（Azure 出口）视角根本看不到中国大陆节点（社区清单里的广州联通 26678 在 runner 上
`speedtest -L` 不会出现），自动「就近选择」必然落到境外节点、测速点口径失真。所以一律用
`--server-id=<id>` 显式锁定；候选不可用（服务端报测速点不存在/连不上）时按候选列表顺延，
**顺延结果会在通知里明确标注**，绝不静默换点。

设计原则（与 speedtest.py / taier_speedtest.py 一致）：
  - 共享能力一律 import 复用：纯共享层来自 speedtest_common，mihomo/订阅源来自
    speedtest_gitee（不改它们的既有行为）
  - 节点串行测试（共享同一 mihomo 内核，切换后 settle）
  - 参数全部经环境变量控制
  - 兜底对齐 gitee/taier：SIGTERM/SIGINT → ⛔ 通知；未捕获异常/阶段失败 → ❌ 通知
    （所有失败路径均先撤 TUN 再发——notify_failure 内部先调幂等的 stop_mihomo_tun）
"""
import html
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import tarfile
import time
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
    tg_entry, tg_entry_codes, tg_entry_pair,
    tg_footer_line,
    tg_format_elapsed,
    update_gist,
    TG_SEP,
)
from speedtest_gitee import (
    MIHOMO,
    MIHOMO_CONFIG,
    MIHOMO_LOG,
    MIHOMO_MIXED_PORT,
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
OOKLA_LOG = HOME_RUNTIME / 'ookla_speedtest.log'
RESULT_JSON = HOME_RUNTIME / 'ookla_speedtest_result.json'
# 回退下载（仅在系统里找不到 speedtest CLI 且显式给了 OOKLA_CLI_URL 时使用）：
# 落地文件名固定，供 PROCESS-NAME 进程规则匹配
OOKLA_FALLBACK_BIN = HOME_RUNTIME / 'ookla-speedtest'

# 默认测速点：广东广州 · 联通5G（id 来自社区维护的国内测速点清单
# https://github.com/reizhi/speedtest-cn-server-list ，Ookla 侧会随运营调整失效，
# 故支持多候选顺延 + env 覆盖）
DEFAULT_SERVER_IDS = '26678'
# 已知测速点编号 → 人类可读标签（仅用于通知展示；未收录的编号留空走兜底）
SERVER_LABELS = {
    '26678': '广东广州 · 联通5G',
    '27594': '广东广州 · 电信5G',
    '24447': '上海 · 联通5G',
    '27154': '天津 · 联通5G',
    '4870': '湖南长沙 · 联通5G',
    '5039': '山东济南 · 联通',
    '4863': '陕西西安 · 联通',
    '13704': '江苏南京 · 联通',
    '33995': '浙江杭州 · 联通',
    '5726': '重庆 · 联通',
    '37235': '辽宁沈阳 · 联通',
    '36646': '河南郑州 · 联通5G',
    '4884': '福建福州 · 联通',
    '5485': '湖北武汉 · 联通',
    '5674': '广西南宁 · 联通',
}


def _server_ids():
    raw = (os.environ.get('OOKLA_SERVER_ID', '') or '').strip() or DEFAULT_SERVER_IDS
    ids = [x.strip() for x in raw.replace('，', ',').split(',')]
    return [x for x in ids if x]


CONFIG = {
    # 测速点编号候选（逗号分隔）：首选失败（服务端报不可用）时按序顺延，命中项会在通知标注
    'OOKLA_SERVER_IDS': _server_ids(),
    # 测速点标签覆盖（留空按 SERVER_LABELS / CLI 返回的 location 自动生成）
    'OOKLA_SERVER_LABEL': (os.environ.get('OOKLA_SERVER_LABEL', '') or '').strip(),
    # 0 = 不限（默认）
    'OOKLA_MAX_NODES': int(os.environ.get('OOKLA_MAX_NODES', '0') or 0),
    # 单节点子进程超时（Ookla CLI 一次完整测量含延迟+下行+上行，慢节点可能 60s+）
    'OOKLA_TIMEOUT': int(os.environ.get('OOKLA_TIMEOUT', '120') or 120),
    'OOKLA_SWITCH_SETTLE': float(os.environ.get('OOKLA_SWITCH_SETTLE_SECONDS', '1.5') or 1.5),
}

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
VERSION = {'ookla': '', 'mihomo': ''}

# 运行时解析出的 CLI 路径（ensure_local_ookla 填充）；PROCESS-NAME 规则取它的 basename，
# 与真实进程名严格一致，否则进程规则不命中会静默直连
OOKLA_BIN = ''

# 测速点候选游标（服务端报测速点不可用时顺延）
_SERVER_STATE = {'ids': list(CONFIG['OOKLA_SERVER_IDS']), 'pos': 0}

# CLI 可选参数开关：--progress=no 关掉进度条（避免它混进 stdout 破坏 JSON 解析）。
# 该写法若被某个 CLI 版本拒绝，首次失败后自动去掉并记日志（不让整轮测速白跑）。
_CLI_FLAGS = {'progress': True}

# CLI 报「测速点找不到 / 连不上」的特征（用于区分「测速点坏了」与「节点坏了」）
_SERVER_ERROR_HINTS = (
    'server not found', 'no server', 'server unavailable', 'invalid server',
    'cannot connect to server', 'unable to connect to server', 'failed to connect to server',
    'server selection',
)

# CLI 报「参数不认」的特征（用于 --progress 的自动降级）
_BAD_FLAG_HINTS = ('invalid', 'unknown', 'unexpected', 'possible values', 'unrecognized')

# 诊断模式：OOKLA_DIAGNOSE=1 时只跑探针、结果进 step 日志（不发 TG、不写 Gist、
# 不按失败退出）。用于判定失败形态是「服务器列表整体拉不到（控制面不通）」还是
# 「列表有、只是指定编号已失效」——两者的修法完全不同，不能靠猜。
DIAGNOSE = (os.environ.get('OOKLA_DIAGNOSE', '') or '').strip().lower() in ('1', 'true', 'yes')


def _diag(msg):
    """诊断输出：只进 step 日志。禁止打印节点名 / 出口 IP / 订阅内容。"""
    if DIAGNOSE:
        print(f'[diag] {msg}', flush=True)


# ---------------------------------------------------------------------------
# 客户端 / 内核准备
# ---------------------------------------------------------------------------
def _download_ookla_tgz(url: str):
    """OOKLA_CLI_URL 兜底：下载官方 tgz 并把其中的 speedtest 二进制落到固定文件名。"""
    with urllib.request.urlopen(url, timeout=180) as r, tarfile.open(fileobj=r, mode='r:gz') as tf:
        for member in tf.getmembers():
            if not member.isfile() or pathlib.PurePosixPath(member.name).name != 'speedtest':
                continue
            src = tf.extractfile(member)
            if src is None:
                continue
            with OOKLA_FALLBACK_BIN.open('wb') as f:
                shutil.copyfileobj(src, f)
            OOKLA_FALLBACK_BIN.chmod(0o755)
            log_progress('ookla_downloaded', url=url, path=str(OOKLA_FALLBACK_BIN))
            return str(OOKLA_FALLBACK_BIN)
    raise RuntimeError(f'{url} 中未找到 speedtest 二进制')


def ensure_local_ookla():
    """定位 Ookla 官方 speedtest CLI，返回可执行文件绝对路径。

    优先级：OOKLA_BIN（显式）→ PATH 里的 speedtest（workflow 经 Ookla apt 源安装）
    → OOKLA_CLI_URL 现场下载官方 tgz。

    注意：**不**接受 speedtest-cli（sivel 的 Python 第三方实现）——它的输出结构与
    口径都不同，混用会静默产出错误数据。
    """
    global OOKLA_BIN
    explicit = (os.environ.get('OOKLA_BIN', '') or '').strip()
    if explicit and pathlib.Path(explicit).exists():
        OOKLA_BIN = explicit
    elif shutil.which('speedtest'):
        OOKLA_BIN = shutil.which('speedtest') or ''
    else:
        url = (os.environ.get('OOKLA_CLI_URL', '') or '').strip()
        if not url:
            raise RuntimeError(
                '未找到 Ookla speedtest CLI（PATH 中无 speedtest）；请在工作流里从 Ookla '
                '官方源安装，或设置 OOKLA_CLI_URL / OOKLA_BIN')
        if OOKLA_FALLBACK_BIN.exists():
            OOKLA_BIN = str(OOKLA_FALLBACK_BIN)
        else:
            OOKLA_BIN = _download_ookla_tgz(url)
    VERSION['ookla'] = _ookla_version()
    log_progress('ookla_cli_ready', binary=OOKLA_BIN, version=VERSION['ookla'])
    return OOKLA_BIN


def _ookla_version():
    """`speedtest --version` 首行形如 "Speedtest by Ookla 1.2.0.84 (ea6b6773f) ..."。"""
    try:
        p = subprocess.run([OOKLA_BIN, '--version'], text=True, capture_output=True,
                           timeout=30, stdin=subprocess.DEVNULL)
        head = (p.stdout or p.stderr or '').strip().splitlines()
        first = head[0] if head else ''
        m = re.search(r'(\d+\.\d+\.\d+(?:\.\d+)?)', first)
        return m.group(1) if m else first[:40]
    except Exception:
        return ''


def ookla_process_name():
    return pathlib.Path(OOKLA_BIN).name if OOKLA_BIN else 'speedtest'


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
      PROCESS-NAME 规则 → 仅测速进程走 AUTO（即当前节点）；名字取 CLI 真实 basename
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
    cfg['rules'] = [f'PROCESS-NAME,{ookla_process_name()},AUTO', 'MATCH,DIRECT']
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
def _looks_like_server_error(text):
    low = str(text or '').lower()
    return any(hint in low for hint in _SERVER_ERROR_HINTS)


def parse_ookla_json(stdout: str):
    """从 CLI stdout 提取结果 JSON。

    官方 CLI 在 `--format=json` 下正常只吐一个 JSON 对象，但许可证横幅/日志行仍可能
    混在前面（首跑未落盘许可时），故先按「首个 { 到末个 }」整体尝试，失败再逐行尝试。
    """
    text = ANSI_RE.sub('', stdout or '')
    candidates = []
    start, end = text.find('{'), text.rfind('}')
    if start >= 0 and end > start:
        candidates.append(text[start:end + 1])
    for line in text.splitlines():
        line = line.strip()
        if line.startswith('{') and line not in candidates:
            candidates.append(line)
    for raw in candidates:
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if isinstance(obj, dict):
            return obj
    return None


def _bytes_to_mibs(value):
    try:
        num = float(value)
    except (TypeError, ValueError):
        return 0.0
    return max(0.0, num) / 1048576.0


def parse_ookla_result(obj):
    """结果 JSON → 指标 dict（单位：download_mibs/upload_mibs = MiB/s，latency 已 ms）。"""
    out = {
        'ok': False, 'download_mibs': 0.0, 'upload_mibs': 0.0, 'latency_ms': None,
        'exit_ip': '', 'server': {}, 'error': '',
    }
    if not obj:
        out['error'] = '无 JSON 输出'
        return out
    if str(obj.get('type') or '').lower() == 'error':
        out['error'] = str(obj.get('error') or obj.get('message') or '未知错误')
        return out
    ping = obj.get('ping') or {}
    latency = ping.get('latency')
    out['latency_ms'] = float(latency) if isinstance(latency, (int, float)) else None
    out['download_mibs'] = _bytes_to_mibs((obj.get('download') or {}).get('bandwidth'))
    out['upload_mibs'] = _bytes_to_mibs((obj.get('upload') or {}).get('bandwidth'))
    out['exit_ip'] = str((obj.get('interface') or {}).get('externalIp') or '').strip()
    out['server'] = obj.get('server') or {}
    out['ok'] = bool(out['server']) and (out['download_mibs'] > 0 or out['upload_mibs'] > 0)
    if not out['ok']:
        out['error'] = '测速点未返回有效带宽'
    return out


def _ookla_cmd(server_id):
    """CLI 命令行（许可证/GDPR 必须显式接受，否则首跑会卡在交互确认）。"""
    cmd = [OOKLA_BIN, '--accept-license', '--accept-gdpr', '--format=json',
           f'--server-id={server_id}']
    if _CLI_FLAGS['progress']:
        cmd.insert(3, '--progress=no')
    return cmd


def _exec_ookla(cmd, timeout=None):
    limit = timeout if timeout and timeout > 0 else CONFIG['OOKLA_TIMEOUT']
    try:
        p = subprocess.run(cmd, text=True, capture_output=True,
                           timeout=limit, stdin=subprocess.DEVNULL)
        return p.returncode, p.stdout or '', p.stderr or ''
    except subprocess.TimeoutExpired:
        return 124, '', f'timeout after {limit}s'


def _run_ookla_once(server_id, timeout=None):
    rc, out, err = _exec_ookla(_ookla_cmd(server_id), timeout=timeout)
    # --progress=no 不被当前 CLI 版本接受时，去掉该参数重试一次并永久关闭开关
    low = (err or '').lower()
    if rc != 0 and _CLI_FLAGS['progress'] and 'progress' in low and \
            any(hint in low for hint in _BAD_FLAG_HINTS):
        log_progress('ookla_progress_flag_unsupported', error=(err or '').strip()[-200:])
        _CLI_FLAGS['progress'] = False
        rc, out, err = _exec_ookla(_ookla_cmd(server_id), timeout=timeout)
    return rc, out, err


def run_ookla(name: str):
    """跑一次测速；测速点不可用时顺延候选（返回实际命中的编号）。

    只把「CLI 明确报测速点找不到/连不上」当作测速点问题顺延；节点自身故障（超时、DNS、
    连接被拒等）不会消耗候选，避免把节点问题误判成测速点问题。
    """
    ids = _SERVER_STATE['ids']
    while True:
        sid = ids[_SERVER_STATE['pos']]
        rc, out, err = _run_ookla_once(sid)
        parsed = parse_ookla_result(parse_ookla_json(out))
        if rc == 0 or not _looks_like_server_error(f"{parsed.get('error', '')}\n{err}"):
            return rc, out, err, parsed, sid
        if _SERVER_STATE['pos'] + 1 >= len(ids):
            return rc, out, err, parsed, sid
        nxt = _SERVER_STATE['pos'] + 1
        log_progress('ookla_server_fallback', from_point_id=sid, to_point_id=ids[nxt], name=name)
        _SERVER_STATE['pos'] = nxt


# ---------------------------------------------------------------------------
# 测速点列表（动态选点 / 诊断共用）
# ---------------------------------------------------------------------------
def _parse_server_list(stdout: str):
    """解析 `speedtest -L --format=json` 的输出，返回原始 dict 列表。

    官方 CLI 的列表输出顶层可能是数组，也可能是 {"servers": [...]}，两种都要吃；
    解析不出来一律返回 []（由调用方判「列表拉不到」）。
    """
    text = ANSI_RE.sub('', stdout or '')
    candidates = []
    s, e = text.find('['), text.rfind(']')
    if s >= 0 and e > s:
        candidates.append(text[s:e + 1])
    s2, e2 = text.find('{'), text.rfind('}')
    if s2 >= 0 and e2 > s2:
        candidates.append(text[s2:e2 + 1])
    for raw in candidates:
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if isinstance(obj, list):
            return obj
        if isinstance(obj, dict):
            for key in ('servers', 'data'):
                if isinstance(obj.get(key), list):
                    return obj[key]
    return []


def list_servers(timeout=90):
    """经当前节点列出可用测速点：`speedtest -L`。

    与正式测速走同一条链路（同一个二进制 → 同一个 PROCESS-NAME 规则 → 同一个节点），
    所以这里看到的就是「当前节点出口视角」的测速点列表；runner 直连（Azure 出口）
    视角看不到大陆测速点，不能用直连列表代替。
    """
    cmd = [OOKLA_BIN, '--accept-license', '--accept-gdpr', '--format=json', '-L']
    rc, out, err = _exec_ookla(cmd, timeout=timeout)
    raw = _parse_server_list(out)
    servers = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        servers.append({
            'id': str(item.get('id') or '').strip(),
            'name': str(item.get('name') or '').strip(),
            'location': str(item.get('location') or '').strip(),
            'country': str(item.get('country') or '').strip(),
            'host': str(item.get('host') or '').strip(),
        })
    servers = [s for s in servers if s['id']]
    log_progress('ookla_server_listed', rc=rc, count=len(servers))
    if not servers:
        log_progress('ookla_server_list_empty', rc=rc, error=(err or '').strip()[-200:])
    return servers


# ---------------------------------------------------------------------------
# 诊断探针（OOKLA_DIAGNOSE=1）
# ---------------------------------------------------------------------------
def diagnose_direct_baseline(server_id):
    """TUN 未起时的直连基线：runner 出口 + 指定编号能否拿到结果。"""
    cmd = [OOKLA_BIN, '--accept-license', '--accept-gdpr', '--format=json',
           f'--server-id={server_id}']
    rc, out, err = _exec_ookla(cmd, timeout=60)
    parsed = parse_ookla_result(parse_ookla_json(out))
    _diag(f'direct-baseline rc={rc} ok={parsed["ok"]} error={parsed.get("error", "")[:120]}')
    _diag('direct-baseline stderr: ' + ' | '.join((err or '').strip().splitlines()[-3:]))


def diagnose_control_plane():
    """经 mihomo mixed-port 探 speedtest.net 控制面：判断节点侧是否可达。"""
    proxy = f'http://127.0.0.1:{MIHOMO_MIXED_PORT}'
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({'http': proxy, 'https': proxy}))
    for url in ('https://www.speedtest.net/', 'https://api.speedtest.net/api/v1/servers?limit=1'):
        t0 = time.time()
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with opener.open(req, timeout=20) as r:
                _diag(f'control-plane {url} -> HTTP {r.status} in {time.time() - t0:.1f}s')
        except Exception as e:
            _diag(f'control-plane {url} -> {type(e).__name__}: {str(e)[:120]} '
                  f'({time.time() - t0:.1f}s)')


def diagnose_mihomo_log():
    """mihomo 日志里与 speedtest 相关的行：确认 PROCESS-NAME 规则是否命中。

    debug 级日志会带节点名 / 目标域名，这里只取含 speedtest 的行并截断，
    避免把节点身份打进公开 step 日志。
    """
    try:
        lines = MIHOMO_LOG.read_text(encoding='utf-8', errors='ignore').splitlines()
    except Exception as e:
        _diag(f'mihomo log unreadable: {e}')
        return
    hits = [l for l in lines if 'speedtest' in l.lower()][-20:]
    _diag(f'mihomo log matched(speedtest)={len(hits)}')
    for l in hits:
        _diag('  mihomo: ' + l[-200:])


def diagnose_on_node():
    """切到节点后的完整探针：列表 → 控制面 → 实测一次 → mihomo 日志。"""
    servers = list_servers()
    _diag(f'server-list count={len(servers)}')
    ids = [s['id'] for s in servers]
    _diag(f'server-list contains 26678: {"26678" in ids}')
    for s in servers[:20]:
        _diag('  server: ' + json.dumps(s, ensure_ascii=False))
    cn = [s for s in servers if 'china' in (s['country'] or '').lower() or s['country'] == 'CN']
    _diag(f'server-list CN={len(cn)}: ' + ', '.join(s['id'] for s in cn[:30]))
    diagnose_control_plane()
    sid = _SERVER_STATE['ids'][_SERVER_STATE['pos']]
    rc, out, err = _run_ookla_once(sid, timeout=90)
    parsed = parse_ookla_result(parse_ookla_json(out))
    _diag(f'measure rc={rc} point={sid} ok={parsed["ok"]} '
          f'down={parsed["download_mibs"]:.2f}MiB/s up={parsed["upload_mibs"]:.2f}MiB/s '
          f'latency={parsed["latency_ms"]} error={parsed.get("error", "")[:120]}')
    if not parsed['ok']:
        _diag('measure stderr: ' + ' | '.join((err or '').strip().splitlines()[-3:]))
    diagnose_mihomo_log()


def _latency_ms(value):
    return round(float(value), 1) if isinstance(value, (int, float)) else 0.0


def server_label(server_id, server_info=None):
    if CONFIG['OOKLA_SERVER_LABEL']:
        return CONFIG['OOKLA_SERVER_LABEL']
    if str(server_id) in SERVER_LABELS:
        return SERVER_LABELS[str(server_id)]
    info = server_info or {}
    return ' · '.join(x for x in (str(info.get('location') or ''), str(info.get('name') or '')) if x) \
        or '未标注测速点'


def target_network_lines(server_id, server_info):
    """「📍 测速点网络」KV 树块：Speedtest 测速服务器（IP:port · 主机名）+ 其 IP 归属。

    版式由四套统一的 build_target_network_section 渲染（单测速点 = 4 行 KV 树）；
    归属查询失败逐级降级为「归属获取失败」，不抛异常、不阻塞通知。
    须在 stop_mihomo_tun() 之后调用（此时为 runner 直连出口视角）。
    """
    info = server_info or {}
    ip = str(info.get('ip') or '').strip()
    port = str(info.get('port') or '').strip()
    host = str(info.get('host') or '').strip()
    if not ip and host:
        ip = resolve_host_ipv4(host)
    server = f'{ip}:{port}' if (ip and port) else (ip or host)
    geo = fetch_ip_network_info(ip) if ip else None
    label = host or server_label(server_id, info)
    return build_target_network_section([(server, label, geo)])


# ---------------------------------------------------------------------------
# 通知构建
# ---------------------------------------------------------------------------
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
    # 标题状态随结论降级（规范 第 4 章 状态 emoji 语义）：0 成功 / 命中「疑似未走代理」→ ⚠️
    _title_emoji = '⚠️' if (not ok_results or bypass_hits) else '✅'
    lines = [
        f'{_title_emoji} Ookla 测速',
        sep,
        f"🕒 起止：{esc(meta['started_text'])} ~ {esc(meta['ended_text'])} · 耗时 {esc(meta['duration_text'])}",
        # 计数口径与四套统一用「可用」（成功=功能可用，含节点连接成功但速度偏低）
        f"📊 节点：共 {len(results)} 个 · 可用 {len(ok_results)} 个",
        # 取值行口径（规范 2.3 节）：测速点名与 id 都是机器返回值，整行同为等宽
        f"📍 测速点：{tg_entry(meta['point_label'])} · id {tg_entry(meta['point_id'])}",
        f"🧪 引擎：{tg_entry('speedtest ' + (VERSION['ookla'] or 'latest'))}",
        '',
    ]
    # 首选测速点不可用而顺延：必须显式标注（绝不静默换点）
    first_id = (CONFIG['OOKLA_SERVER_IDS'] or [''])[0]
    if first_id and str(first_id) != str(meta['point_id']):
        lines.append('  └─ ' + tg_entry_pair(first_id, meta['point_id'],
                                             '首选测速点不可用，已顺延'))
        lines.append('')
    # 测速点（Speedtest 服务器）的网络归属：服务器 IP/主机名取自 CLI 结果 JSON；
    # 已在 stop_mihomo_tun() 之后调用（直连视角）
    lines.extend(target_network_lines(meta['point_id'], meta.get('server_info') or {}))
    lines.append('')
    if top:
        # 四套统一：TOP 条目复用共享的 build_node_metric_prefix（↑上传 · ↓下载 · 延迟ms，
        # 单位「兆」）
        _top_mode = 'push-only' if bundle.get('metric', 'upload') == 'upload' else 'download'
        has_up = any((r.get('up') or 0) > 0 for r in top)
        legend = '↑上传 · ↓下载 · 延迟ms' if has_up else '↓下载 · 延迟ms'
        # 标题点出排序依据（= 订阅判定指标），避免读者按 ↓ 数值读不出顺序
        sort_hint = f' · 按{esc(metric_label)}' if metric_label else ''
        lines.append(f'🏆 最快节点 · {len(top)}{sort_hint} · {legend}')
        for idx, r in enumerate(top, 1):
            connector = '└─' if idx == len(top) else '├─'
            prefix = build_node_metric_prefix({
                'upload_mibs': (r.get('up') or 0) / 8.388608,
                'download_mibs': (r.get('down') or 0) / 8.388608,
                'latency_ms': _latency_ms(r.get('rtt')),
            }, _top_mode, order='up_first')
            # 条目行统一走共享的 tg_entry（主体 + 元数据，转义与分隔符一致）
            lines.append(f'  {connector} ' + tg_entry(r.get("name", ""), prefix))
        lines.append('')
    else:
        lines.append('⚠️ 没有节点测速成功')
        lines.append('')

    if bypass_hits:
        lines.append('⚠️ 疑似未走代理')
        lines.append(f"  └─ {bypass_hits} 个节点的出口 IP 与 runner 直连出口（{tg_entry(direct_ip)}）相同，"
                     'TUN 进程规则可能未生效，结果不可信')
        lines.append('')

    failed = [r for r in results if not r.get('ok')]
    if failed:
        lines.append(f'❌ 失败 · {len(failed)}')
        _failed_entries = []
        for r in failed[:5]:
            # 并列双机器值（节点名 · 原始异常串）走 tg_entry_codes（语义表 #10）
            _failed_entries.append(
                tg_entry_codes(r.get('name', ''), (r.get('error') or '-')[:80]))
        if len(failed) > 5:
            # 折叠行并入条目流，末条 └─ 由下面的循环统一决定（禁双 └─；规范 2.3 节）
            _failed_entries.append(f'还有 {len(failed) - 5} 条…')
        for _i, _l in enumerate(_failed_entries, 1):
            _c = '└─' if _i == len(_failed_entries) else '├─'
            lines.append(f'  {_c} {_l}')
        lines.append('')

    lines.append('📦 订阅 · Gist')
    if gist_res and gist_res.get('ok'):
        action = '新建' if gist_res.get('created') else '更新'
        raw_url = ((gist_res.get('yaml') or {}).get('raw_url') or '').strip()
        gist_lines = [f'✅ 已{action}，达标 {qualified_count} 个 · 阈值 ≥{min_megabit}兆（按{esc(metric_label)}）']
        if gist_res.get('created'):
            gist_lines.append(f'⚠️ 请把 Gist id 回填到 Secrets {tg_entry("PROXY_SPEEDTEST_OOKLA_GIST_ID")}，避免每轮新建')
        if raw_url:
            gist_lines.append(f'🔗 <a href="{esc(raw_url)}">订阅源 YAML</a>')
        for _i, _l in enumerate(gist_lines):
            _c = '└─' if _i == len(gist_lines) - 1 else '├─'
            lines.append(f'  {_c} {_l}')
    elif gist_res:
        lines.append(f"  └─ ⚠️ 上传失败：{tg_entry(gist_res.get('reason', ''))}")
    elif gist_error:
        # 上传阶段抛异常（HTTP 4xx 等）≠ 没有达标节点，文案必须区分
        lines.append(f'  └─ ⚠️ 上传失败：{tg_entry(gist_error[:120])}')
    else:
        lines.append(f'  └─ ⚠️ 达标不足 {min_nodes} 个 · 阈值 ≥{min_megabit}兆（按{esc(metric_label)}）· 未更新订阅')
    # 统一收尾区（收尾区与正文间固定**一个**空行）
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
        f'❌ Ookla 测速异常退出 · {html.escape(_head)}',
        TG_SEP,
        # reason 含原始异常串（机器值）→ <code>；与 cdn/gitee 的「原因/错误」同口径
        f'原因：{tg_entry(reason)}',
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
    msg = (f'⛔ Ookla 测速异常终止\n{TG_SEP}\n'
           f'⚠️ 脚本被中断：收到 {tg_entry(sig_name)}，本轮测速未正常完成。')
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
    log_progress('ookla_speedtest_started', started_at=started_at.isoformat(), config={
        'point_ids': CONFIG['OOKLA_SERVER_IDS'],
        'max_nodes': CONFIG['OOKLA_MAX_NODES'],
        'timeout': CONFIG['OOKLA_TIMEOUT'],
    })
    env = merged_env()
    if DIAGNOSE:
        # 诊断要看 mihomo 的规则命中（PROCESS-NAME 是否匹配到测速进程）
        env['PROXY_SPEEDTEST_MIHOMO_LOG_LEVEL'] = 'debug'

    try:
        ensure_local_ookla()
        if DIAGNOSE:
            # 直连基线（TUN 未起）：先确认 runner 自身出口 + 指定编号的可用性
            diagnose_direct_baseline(_SERVER_STATE['ids'][0])
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

    max_nodes = CONFIG['OOKLA_MAX_NODES']
    if max_nodes and max_nodes > 0:
        alive_items = alive_items[:max_nodes]
    log_progress('nodes_collected', count=len(alive_items))

    if DIAGNOSE:
        # 诊断：只在一个节点上跑探针，不写 Gist、不发 TG、不按失败退出
        _diag(f'alive nodes={len(alive_items)}')
        if alive_items:
            try:
                switch_proxy(str(alive_items[0].get('name') or ''), CONFIG['OOKLA_SWITCH_SETTLE'])
            except Exception as e:
                _diag(f'switch failed: {e}')
            try:
                diagnose_on_node()
            except Exception as e:
                _diag(f'diagnose failed: {type(e).__name__}: {str(e)[:200]}')
        stop_mihomo_tun()
        _diag('diagnose done')
        return 0

    results = []
    bypass_hits = 0
    server_info = {}
    for item in alive_items:
        name = str(item.get('name') or '')
        try:
            switch_proxy(name, CONFIG['OOKLA_SWITCH_SETTLE'])
        except Exception as e:
            log_progress('switch_failed', name=name, error=str(e))
            results.append({'name': name, 'ok': False, 'error': f'切换失败：{e}'})
            continue

        rc, out, err, parsed, sid = run_ookla(name)
        if not server_info and parsed.get('server'):
            server_info = parsed['server']
        # 结果 JSON 体积小但含测速点信息；首条落盘供人工核对字段（日志不落出口 IP）
        row = {
            'name': name,
            'type': item.get('type', ''),
            'source_entry': item.get('source_entry', {}) or {},
            'mode': 'download',
            'ok': rc == 0 and parsed['ok'],
            'point_id': sid,
            'exit_ip': parsed['exit_ip'],
            'rtt': _latency_ms(parsed['latency_ms']),
            # 单位与 taier 行字段一致（Mbps 口径），MiB/s × 8.388608 折算；
            # 订阅导出侧再 ÷8.388608 还原 MiB/s
            'up': round(parsed['upload_mibs'] * 8.388608, 2),
            'down': round(parsed['download_mibs'] * 8.388608, 2),
            'rc': rc,
        }
        # 出口 IP 与 runner 直连出口相同 ⇒ 流量没进节点（TUN 未生效 / 进程规则未命中）
        row['bypass'] = bool(direct_ip and parsed['exit_ip'] and parsed['exit_ip'] == direct_ip)
        if row['bypass']:
            bypass_hits += 1
        if not row['ok']:
            if parsed['server'] and not (parsed['download_mibs'] or parsed['upload_mibs']):
                row['error'] = '测速点未返回有效带宽（延迟/上下行全空）'
            else:
                # 诊断优先级：stderr 尾部（CLI 原始报错）> JSON 里的 error 字段 > stdout 尾部
                tail = (err or '').strip().splitlines()
                if tail:
                    row['error'] = tail[-1][:200]
                elif parsed.get('error') and parsed['error'] != '无 JSON 输出':
                    row['error'] = str(parsed['error'])[:200]
                else:
                    out_tail = (out or '').strip().splitlines()
                    row['error'] = out_tail[-1][:200] if out_tail else f'rc={rc}（无输出）'
        results.append(row)
        log_progress('ookla_node_done', name=name, rc=rc, point_id=sid,
                     rtt=row['rtt'], up=row['up'], down=row['down'],
                     exit_ip=row['exit_ip'], bypass=row['bypass'])
        try:
            with OOKLA_LOG.open('a', encoding='utf-8') as lf:
                lf.write(f'===== rc={rc} point={sid} =====\n{ANSI_RE.sub("", out)}\n')
        except Exception:
            pass
        # 诊断：结构化的测速点/错误信息进 step 日志（不含出口 IP —— 公开仓库日志勿泄漏节点出口）
        if not parsed['ok'] or rc != 0:
            print(f'--- ookla rc={rc} point={sid} ---')
            print(json.dumps({'server': parsed.get('server') or {},
                              'error': parsed.get('error') or ''}, ensure_ascii=False))
            err_tail = (err or '').strip().splitlines()[-3:]
            if err_tail:
                print('stderr: ' + ' | '.join(err_tail))

    # 先关 TUN 再发通知：通知走的是 runner 自身网络，必须在路由恢复之后
    stop_mihomo_tun()

    # 订阅导出到本工作流专属 Gist（secret: PROXY_SPEEDTEST_OOKLA_GIST_ID）——
    # 四套测速工作流各用各的 Gist，互不覆盖。
    # 达标策略（阈值 / 判定指标 / 最少节点数）与四套共用，见 resolve_subscription_policy：
    # 默认按上行判定，达标不足 min_nodes 时自动改用下行（反之亦然）。
    gist_res = None
    gist_error = ''
    gist_results = [{
        'name': r.get('name', ''),
        'source_entry': r.get('source_entry') or {},
        'mode': 'download',
        'download_mibs': (r.get('down') or 0) / 8.388608,
        'upload_mibs': (r.get('up') or 0) / 8.388608,
        'latency_ms': _latency_ms(r.get('rtt')),
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
    point_id = _SERVER_STATE['ids'][_SERVER_STATE['pos']]
    meta = {
        'started_text': started_at.isoformat()[:19].replace('T', ' '),
        'ended_text': ended_at.isoformat()[:19].replace('T', ' '),
        'duration_text': duration_text,
        'point_id': point_id,
        'point_label': server_label(point_id, server_info),
        'server_info': server_info,
    }
    summary = {
        'ok': bypass_hits == 0,
        'started_at': started_at.isoformat(),
        'ended_at': ended_at.isoformat(),
        'direct_egress_ip': direct_ip,
        'bypass_hits': bypass_hits,
        'point_id': point_id,
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
        # 发送层不写 stderr（python 侧靠返回值），失败原因必须回传日志（规范 第 5 章）
        log_progress('telegram_send_finished', sent=bool(tg_res.get('sent')),
                     reason=tg_res.get('reason', ''))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    log_progress('ookla_speedtest_done', node_count=len(results), bypass_hits=bypass_hits,
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
