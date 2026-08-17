#!/usr/bin/env python3
"""独立代理节点测速脚本（延迟 + 下载速度 + 可选 Gitee 上行）。

复用 scheduler.py 的 mihomo 内核启动 / 节点快照 / 节点切换能力，新增：
  - latency_probe   : 经代理对目标 URL 做 TCP/HTTP 计时（延迟）
  - download_speedtest: 经 mixed-port 代理 curl 拉取测速点，换算 MiB/s
  - optional gitee push: 可选上行测速（复用 gitee 思路，独立实现）
  - build_html_report: 生成自包含、可交互 HTML 可视化报告

设计原则：
  - 不修改 scheduler.py，仅以 `from scheduler import ...` 复用已验证的纯函数/低副作用函数。
  - 节点逐节点**串行**测试（共享同一 mihomo 内核，切换后等待 settle）。
  - 自定义参数全部通过环境变量控制（见 CONFIG 区块）。
"""
import json
import os
import pathlib
import statistics
import subprocess
import tempfile
import time
import urllib.request
from datetime import datetime

import yaml

# ----------------------------------------------------------------------------
# 复用 scheduler.py 的已验证能力（import 期仅会创建 ~/proxy-speedtest 目录）
# ----------------------------------------------------------------------------
from scheduler import (
    MIHOMO_MIXED_PORT,
    MIHOMO_API,
    HOME_RUNTIME,
    collect_provider_snapshot,
    switch_proxy,
    build_proxy_env,
    ensure_mihomo_running,
    log_progress,
    _redact_value,
    merged_env,
    parse_sub_urls,
)

# ----------------------------------------------------------------------------
# 配置（全部可通过环境变量覆盖）
# ----------------------------------------------------------------------------
DEFAULT_LATENCY_TARGETS = [
    'https://www.gstatic.com/generate_204',
    'https://www.baidu.com',
]
DEFAULT_DOWNLOAD_URLS = [
    'https://mirrors.cloud.tencent.com/archlinux/iso/latest/sha256sums.txt',
    'https://download.geonode.com/test/10mb.bin',
]
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
    'PROXY_SPEEDTEST_CONNECTIONS':
        int(os.environ.get('PROXY_SPEEDTEST_CONNECTIONS', '1')),  # curl 单节点内并行连接数（默认串行单连接）
    # 节点切换
    'PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS':
        float(os.environ.get('PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS', '1.5')),
    'PROXY_SPEEDTEST_MAX_NODES':
        int(os.environ.get('PROXY_SPEEDTEST_MAX_NODES', '0')),  # 0=不限
    # 可选 Gitee 上行
    'PROXY_SPEEDTEST_ENABLE_PUSH':
        (os.environ.get('PROXY_SPEEDTEST_ENABLE_PUSH', '0').strip().lower() in ('1', 'true', 'yes', 'on')),
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
    for t in targets:
        t = t.strip()
        if not t:
            continue
        for _ in range(max(1, samples)):
            try:
                req = urllib.request.Request(t, headers={'User-Agent': 'Mozilla/5.0', 'Cache-Control': 'no-cache'})
                t0 = time.perf_counter()
                with urllib.request.urlopen(req, timeout=timeout, proxies={'http': proxy_env.get('HTTP_PROXY'),
                                                                           'https': proxy_env.get('HTTPS_PROXY')}) as r:
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
# 下载测速：curl 经 mixed-port 代理拉取测速点，按耗时换算 MiB/s
# ----------------------------------------------------------------------------
def download_speedtest(urls, proxy_env, timeout=30.0, size_hint_mib=10, connections=1, max_duration=0.0):
    """经代理 curl 拉取测速点，返回 {ok, mibps, bytes, seconds, error}。

    优先使用足够大的固定文件以满足 size_hint_mib；若 max_duration>0，则限制单节点
    下载时长（用 --max-time 结合 --range 实现近似持续窗口）。
    """
    proxy = f'http://127.0.0.1:{MIHOMO_MIXED_PORT}'
    best = None
    last_error = ''
    for u in urls:
        u = u.strip()
        if not u:
            continue
        # 若指定了持续时长，按 range 分块拉取，模拟持续下载窗口
        curl_range = None
        curl_max_time = timeout
        if max_duration and max_duration > 0:
            # 10 MiB 窗口近似（保守估算，避免单次拉取过早结束）
            range_end = int(max_duration * 1.5 * max(size_hint_mib, 1) * 1024 * 1024)
            curl_range = f'0-{range_end}'
            curl_max_time = max_duration + 5
        cmd = [
            'curl', '-sS', '-x', proxy, '-o', '/dev/null',
            '-w', '%{time_total},%{size_download}',
            '--connect-timeout', str(int(timeout)),
            '--max-time', str(int(curl_max_time)),
        ]
        if curl_range:
            cmd += ['-r', curl_range]
        if connections and connections > 1:
            cmd += ['--parallel', '-Z']
        cmd += ['-A', 'Mozilla/5.0', u]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=int(curl_max_time) + 10)
            if out.returncode != 0:
                last_error = out.stderr.strip() or f'curl exit {out.returncode}'
                continue
            total_s_str, size_str = (out.stdout.strip().split(',') + ['0', '0'])[:2]
            total_s = float(total_s_str or '0')
            size_bytes = int(size_str or '0')
            if total_s <= 0 or size_bytes <= 0:
                last_error = 'empty download'
                continue
            mibps = size_bytes / 1024 / 1024 / total_s
            cand = {'ok': True, 'mibps': round(mibps, 2), 'bytes': size_bytes,
                    'seconds': round(total_s, 2), 'error': None}
            if best is None or cand['mibps'] > best['mibps']:
                best = cand
        except Exception as e:
            last_error = str(e)
    if best is None:
        return {'ok': False, 'mibps': None, 'bytes': 0, 'seconds': None, 'error': last_error}
    return best


# ----------------------------------------------------------------------------
# 可选 Gitee 上行测速（独立实现，避免耦合 scheduler 的 git 细节）
# ----------------------------------------------------------------------------
def gitee_push_speedtest(env, size_mib, push_timeout, branch):
    """向 Gitee 私有仓库 push 一个固定大小文件，按耗时换算上行 MiB/s。"""
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
    local_env = dict(env)
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
def speedtest_single_node(item, proxy_env, cfg):
    name = item.get('name', '')
    log_progress('node_test_start', name=name, type=item.get('type', ''))
    result = {
        'name': name,
        'type': item.get('type', ''),
        'provider': item.get('provider', ''),
        'latency': latency_probe(cfg['PROXY_SPEEDTEST_LATENCY_TARGETS'], proxy_env,
                                 cfg['PROXY_SPEEDTEST_LATENCY_SAMPLES'], cfg['PROXY_SPEEDTEST_LATENCY_TIMEOUT']),
        'download': download_speedtest(cfg['PROXY_SPEEDTEST_DOWNLOAD_URLS'], proxy_env,
                                       cfg['PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT'], cfg['PROXY_SPEEDTEST_SIZE_MIB'],
                                       cfg['PROXY_SPEEDTEST_CONNECTIONS'], cfg['PROXY_SPEEDTEST_DOWNLOAD_DURATION']),
    }
    if cfg['PROXY_SPEEDTEST_ENABLE_PUSH']:
        result['upload'] = gitee_push_speedtest(cfg, cfg['PROXY_SPEEDTEST_SIZE_MIB'],
                                                cfg['PROXY_SPEEDTEST_PUSH_TIMEOUT'], cfg['PROXY_SPEEDTEST_GITEE_BRANCH'])
    else:
        result['upload'] = {'ok': False, 'mibps': None, 'error': 'disabled'}
    result['ok'] = bool(result['latency']['ok'] or result['download']['ok'])
    log_progress('node_test_done', name=name, latency_ms=result['latency'].get('median_ms'),
                 download_mibps=result['download'].get('mibps'))
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

    try:
        _, alive_items = collect_provider_snapshot()
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
                            'upload': {'ok': False, 'error': 'disabled'}})
            continue
        results.append(speedtest_single_node(item, proxy_env, CONFIG))

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

    log_progress('speedtest_done', node_count=len(results),
                 json_path=str(RESULT_JSON), html_path=str(RESULT_HTML))
    return 0


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


if __name__ == '__main__':
    import sys
    sys.exit(main())
