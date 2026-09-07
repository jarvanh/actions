#!/usr/bin/env python3
"""订阅节点三网测速（引擎 MiaM1ku/taierspeedtest，链路 mihomo TUN 透明代理）。

与 speedtest.py 同属「订阅节点测速」域：复用 speedtest_gitee.py 的 mihomo 内核 /
订阅供应商 / 节点快照 / 节点切换 / Telegram 发送；测速引擎换成泰尔测速（全球网测，
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
  - 不修改 speedtest_gitee.py，仅 `from speedtest_gitee import ...` 复用已验证能力
  - 节点串行测试（共享同一 mihomo 内核，切换后 settle）
  - 参数全部经环境变量控制
"""
import html
import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from datetime import datetime

import yaml

# ---------------------------------------------------------------------------
# 复用 speedtest_gitee.py 的已验证能力（import 期仅会创建 ~/proxy-speedtest 目录）
# ---------------------------------------------------------------------------
from speedtest_gitee import (
    HOME_RUNTIME,
    MIHOMO,
    MIHOMO_CONFIG,
    MIHOMO_LOG,
    build_mihomo_config,
    collect_provider_snapshot,
    ensure_local_mihomo,
    log_progress,
    merged_env,
    send_telegram,
    switch_proxy,
    tg_footer_line,
    tg_format_elapsed,
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
    'TAIER_POINTS': (os.environ.get('TAIER_POINTS', '') or '北京电信').strip(),
    # multi = 多线程上下行（更贴近代理真实吞吐）；single / both 亦可
    'TAIER_MODE': (os.environ.get('TAIER_MODE', '') or 'multi').strip(),
    'TAIER_DURATION': int(os.environ.get('TAIER_DURATION', '5') or 5),
    'TAIER_MAX_NODES': int(os.environ.get('TAIER_MAX_NODES', '10') or 10),
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
def build_telegram_lines(results, meta, direct_ip, bypass_hits):
    def esc(s):
        return html.escape(str(s))

    sep = '━' * 18
    ok_results = [r for r in results if r.get('ok') and not r.get('bypass')]
    top = sorted(ok_results, key=lambda r: r.get('down') or 0.0, reverse=True)[:5]
    lines = [
        '📶 <b>订阅节点三网测速</b>',
        sep,
        f"🕒 {esc(meta['started_text'])} ~ {esc(meta['ended_text'])} · 耗时 {esc(meta['duration_text'])}",
        f"📊 节点：共 <b>{len(results)}</b> 个 · 成功 <b>{len(ok_results)}</b> 个",
        f"📍 测速点：<b>{esc(meta['points'])}</b> · 模式：<b>{esc(meta['mode_label'])}</b>",
        f"🧪 引擎：<code>taierspeedtest {esc(VERSION['taier'] or 'latest')}</code>",
        '',
    ]
    if top:
        lines.append(f"🏆 最快节点：<b>{esc(top[0].get('name', ''))}</b>")
        lines.append('')
        lines.append('⭐ <b>TOP 5</b> · <i>↓下载 · ↑上传 · 延迟</i>')
        for idx, r in enumerate(top, 1):
            connector = '└─' if idx == len(top) else '├─'
            lines.append(
                f"  {connector} {idx}. <code>{esc(r.get('name', ''))}</code>"
                f" · <i>↓{esc(r.get('down', 0))}Mbps · ↑{esc(r.get('up', 0))}Mbps"
                f" · {esc(r.get('rtt') or '-')}</i>")
        lines.append('')
    else:
        lines.append('⚠️ 没有节点测速成功')
        lines.append('')

    if bypass_hits:
        lines.append('⚠️ <b>疑似未走代理</b>')
        lines.append(f"  └─ {bypass_hits} 个节点的出口 IP 与 runner 直连出口（<code>{esc(direct_ip)}</code>）相同，"
                     'TUN 进程规则可能未生效，结果不可信')
        lines.append('')

    failed = [r for r in results if not r.get('ok')]
    if failed:
        lines.append(f'❌ <b>失败 · {len(failed)}</b>')
        for idx, r in enumerate(failed[:5], 1):
            connector = '└─' if idx == min(len(failed), 5) else '├─'
            lines.append(f"  {connector} <code>{esc(r.get('name', ''))}</code> · <i>{esc((r.get('error') or '-')[:80])}</i>")
        lines.append('')

    lines.append('')
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    return lines


def notify_failure(env, reason):
    lines = [
        '❌ <b>订阅节点三网测速失败</b>',
        '━' * 18,
        f'原因：<b>{html.escape(str(reason))}</b>',
        '',
    ]
    footer = tg_footer_line()
    if footer:
        lines.append(footer)
    try:
        send_telegram(env, '\n'.join(lines))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))


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

    try:
        _, alive_items = collect_provider_snapshot()
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
        row = {
            'name': name,
            'type': item.get('type', ''),
            'ok': rc == 0 and bool(parsed['region']),
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
        send_telegram(env, '\n'.join(build_telegram_lines(results, meta, direct_ip, bypass_hits)))
    except Exception as e:
        log_progress('telegram_send_failed', error=str(e))

    log_progress('taier_speedtest_done', node_count=len(results), bypass_hits=bypass_hits,
                 json_path=str(RESULT_JSON))
    # 全部/大量节点命中 bypass ⇒ 结果不可信，判失败便于在 Actions 上看见
    return 1 if (bypass_hits and bypass_hits >= max(1, len(results))) else 0


def main():
    # TUN 必须收尾：异常/提前 return 也要撤掉路由，否则 runner 无法回传状态
    try:
        return _run()
    finally:
        try:
            stop_mihomo_tun()
        except Exception:
            pass


if __name__ == '__main__':
    raise SystemExit(main())
