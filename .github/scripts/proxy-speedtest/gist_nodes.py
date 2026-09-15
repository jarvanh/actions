#!/usr/bin/env python3
"""从 gist.github.com 抓公开订阅 → 交给 Sub-Store 去重 → 取回 mihomo YAML → 发布到 Gist。

用途：`proxy-speedtest-gistnodes.yml` 的取节点步骤。三套测速工作流（gitee / cdn / taier）
原本只吃仓库 secret `PROXY_SPEEDTEST_SUB_URLS` 里的固定订阅源；本脚本给出第二条来源：
按关键词搜索 Gist、取「最近更新」（`s=updated`）排序的前若干页，只保留最近
`GIST_NODES_MAX_AGE_HOURS` 小时（默认 24）内更新过的，把命中的订阅正文原样丢进
一个临时 Sub-Store 后端，让 Sub-Store 自己解析 + 去重 + 产出 mihomo（ClashMeta）YAML，
再把这个 YAML 发布到本工作流专属 Gist；被调测速工作流拿 gist id **自己现取** raw URL
当订阅源（为什么不经 job output 传：见下面「输出」一节的警告）。

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

**发布前必须过一轮健康检查（见 alive_filter.py），只发布活节点。** 为什么这步不能省：
下游三套测速拿这份 Gist 当订阅源后，会各自起 mihomo、按 provider **非惰性**健康检查所有
节点。实测 2026-09-15 run 34928929882：这里发布了 12635 个节点（raw 匿名可读、
`yaml.safe_load` 也是 12635 个），但泰尔那轮只认到 `source_mapping_built entries: 14`——
从开跑到 mihomo 配好只有 1.67 秒，根本来不及下完 4.27MB 并给 12635 个节点逐一出结论，
于是下游读到的是一个「才刚探了几个」的快照。**瓶颈是规模，不是下载/鉴权/TUN。**
在这里先筛一遍，下游拿到的就是几百个活节点，它自己的健康检查能在秒级完成。

---

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
  GIST_NODES_TARGET_SUBS   目标：凑够多少个「像订阅」的文件（默认 100，0 = 不限）
  GIST_NODES_MAX_PAGES     每个关键词最多翻几页（默认 40；安全上限，正常靠凑够目标或
                           整页超龄提前停）
  GIST_NODES_PAGES_PER_ROUND 每轮每个关键词翻几页（默认 2）
  GIST_NODES_BUDGET_SECONDS 抓取阶段的墙钟预算（默认 900 = 15 分钟；0 = 不限）。**必须
                           显著小于 job 的 timeout-minutes**：到点就收摊，带着已经抓到
                           的文件继续走 Sub-Store 产出，而不是等 GitHub 硬取消把整轮
                           （含下游测速）一起废掉
  GIST_NODES_NO_PROGRESS_ROUNDS 连续多少轮「订阅文件数零增长」就收摊（默认 4；0 = 不限）
  GIST_NODES_MAX_CONSECUTIVE_LIMITED 同一批里连续多少页被限流就熔断本批、且跳过补一轮
                           （默认 3；0 = 不限）。限流是按出口 IP 的全局状态，连续多页全中
                           说明正处在限流窗口里，这时再打（尤其批末的「补一轮」）纯属白烧
                           时间——实测一轮 988 秒里约 850 秒花在这里
  GIST_NODES_SORT          搜索排序（默认 updated = 最近更新）
  GIST_NODES_MAX_AGE_HOURS 只收最近 N 小时内更新过的 Gist（默认 24，0 = 不限）
  GIST_NODES_MAX_SUBS      最多投喂多少个订阅（默认 0 = 不限）
  GIST_NODES_MAX_TOTAL_MB  投喂内容总量上限（默认 0 = 不限）
  GIST_NODES_MAX_FILE_MB   单个 Gist 文件超过多少 MB 跳过（默认 2；工程保护，不是配额）
  GIST_NODES_CARRYOVER     1 = 把**上一轮发布到本工作流专属 Gist 的订阅**也当一路输入喂回
                           Sub-Store（默认 1）。抓取段的池子每轮都在重算：上一轮捞到、这一轮
                           掉出搜索窗口的节点会直接消失。带上它，去重后就是「历史 ∪ 本轮」。
                           首次运行还没有这个文件，自动跳过
  GIST_NODES_CARRYOVER_MAX_MB 累积订阅的大小上限（默认 8）。超了整段跳过并记日志——宁可
                           不累积，也不能把**截断过的** YAML 当完整订阅喂进去
  GIST_NODES_MAX_NODES     最终订阅最多保留多少节点（默认 0 = 不限）
  GIST_NODES_TIMEOUT       单次 HTTP 超时秒数（默认 30）
  GIST_NODES_RETRIES       单页搜索失败（含 429）时的重试次数（默认 4）
  GIST_NODES_BACKOFF_BASE  重试退避基数秒数（默认 5，按 5/10/20/40 指数增长 + 抖动）
  GIST_NODES_PAGE_DELAY    搜索页翻页之间的基础间隔秒数（默认 3，0 = 不间隔）
  GIST_NODES_PACING_CEILING 被限流时间隔自动拉长的上限（默认 60 秒；间隔从 PAGE_DELAY
                           起按被限流次数翻倍，成功后折半回落）
  GIST_NODES_WORKERS       并发取 Gist 的线程数（默认 8，1 = 串行）
  GIST_NODES_DRY_RUN       1 = 只抓取不发布（本地验证用）
  GIST_NODES_WORKDIR       产物目录（默认 ~/proxy-speedtest/gist-nodes）
  SUB_STORE_BACKEND_URL    Sub-Store **后端 API** 地址（默认 http://127.0.0.1:3000）。
                           注意是 3000：镜像是「后端 3000 / 前端 3001」，指到 3001 会
                           打到前端上并得到 404，详见 DEFAULT_SUB_STORE 处的注释
  SUB_STORE_TIMEOUT        单次调用 Sub-Store 的超时秒数（默认 300，全量解析 + 去重耗时
                           较长）。**刻意保持不动**：我们没有真实的 Sub-Store 分段耗时，
                           压小它只会误杀「合法但慢」的取回；「这一段最多能拖多久」由
                           下面的阶段预算负责
  SUB_STORE_BUDGET_SECONDS 整个 Sub-Store 阶段的墙钟预算（默认 300 = 5 分钟；0 = 不限）。
                           **没有它这一段就是无界的**：投喂是逐个 POST（订阅多时几十次）、
                           建组合与取回各一次，全是「单次超时」而没有聚合预算，最坏情况能
                           冲出 job 的 timeout-minutes —— 而且这次是在**抓取已经完成之后**
                           被硬取消，损失比抓取段超时更大。预算一半给投喂、一半留给产出
  SUB_STORE_COLLECTION     组合订阅名前缀（默认 gist-nodes）
  GIST_NODES_ALIVE_FILTER  1 = 发布前先起本地 mihomo 做一轮健康检查，只发布活节点
                           （默认 1）。见文件头「发布前必须过一轮健康检查」
  GIST_NODES_ALIVE_BUDGET_SECONDS
                           健康检查阶段的墙钟预算（默认 600 = 10 分钟；0 = 不限）。
                           到点仍未跑完 → **原样发布全部**并记 `alive_filter_skipped`：
                           这一层是降级手段，它自己故障不该把整轮变成零节点
  GIST_NODES_ALIVE_TIMEOUT 单次读 /providers/proxies 的超时秒数（默认 120）——上面那个
                           budget 才是本阶段的墙钟上界，这个只管单次请求
  GIST_NODES_TRIAL_LOAD   1 = 发布前把这份 YAML 交给本机 mihomo **试装一遍**，把
                           「mihomo 装不上」的节点二分定位并摘掉（默认 1）。见文件头
                           「发布前还要试装排雷」——这一层与健康检查是两件事
  PROXY_SPEEDTEST_HEALTHCHECK_URL
                           健康检查目标（默认 https://www.gstatic.com/generate_204）。
                           **必须与下游测速的同一变量一致**，否则这里判活、下游判死
  GH_TOKEN / GITHUB_TOKEN  GitHub API 认证（缺失时匿名调用，易被限流）
  PROXY_SPEEDTEST_GIST_ID / _FILENAME / _DESCRIPTION
                           发布目标 Gist（复用共享层 update_gist 的既有约定）

输出（写入 ${GITHUB_OUTPUT}，供编排工作流传给测速工作流）：
  sub_url / count / parsed_count / deduped_count / alive_count / gists_scanned /
  gist_html_url / gist_id

  ⚠️ `sub_url` / `gist_html_url` / `gist_id` 的实际值里含 gist id，而
  `PROXY_SPEEDTEST_GISTNODES_GIST_ID` 正是一个**注册过的 secret**（其值就是这个 id）——
  GitHub 见到 output 里出现与已注册 secret 相同的字符串，会**把整个 output 丢掉**并留
  `Skip output 'X' since it may contain secret.`。所以这三个 output 名义上存在、实际恒为空，
  下游拿到空值就会 fallback 到仓库 secret（实测 run 34956069334：订阅源退回用户自己的机场、
  结果写进另一个泰尔测速的 Gist）。
  编排工作流因此**不读这三个 output**，改为传布尔开关 `use_gistnodes_source` /
  `result_gist_id_from_gistnodes`，由被调工作流从自己的 secrets 取 gist id 并调
  `speedtest_common.resolve_gist_raw_url()` 现取 raw URL（见 proxy-speedtest-gistnodes.yml
  的「接线」注释与 docs/proxy-speedtest-gistnodes.md）；
  这里保留写入只是给需要就地观察的场景留个痕。

失败语义：单个 Gist / 单个订阅失败只跳过它；Sub-Store 不可达、组合订阅产出失败、
或最终一个节点都没有 → exit 1。与其让下游拿空订阅跑一轮 45 分钟测速，不如就地失败。

**「到点收摊」不是失败**：墙钟预算耗尽、或连续多轮零增长而主动停止翻页，都只是
「抓到的比目标少」，仍会拿已有的文件走完 Sub-Store 产出与发布。区分这两者的理由：
job 超时是 GitHub 硬取消，被取消时连已经抓到的几十个订阅文件也一起作废、下游三个
测速 job 全 skipped——一次运行白跑。宁可少几个节点，也不要整轮报废。

Sub-Store 阶段同理，但**降级方向相反**：投喂预算耗尽可以停投喂、拿已投喂的继续产出
（少几个订阅文件而已）；而建组合 / 取回预算耗尽就只能 exit 1——那两个步骤省掉就没有
产物了，此时失败是对的（同「与其让下游拿空订阅跑一轮测速，不如就地失败」）。

健康检查阶段同样是「降级不失败」，但降级方向是**放行全部**：这一层存在的意义是把规模
压下去，它自己起不来 / 跑不完时，退回到「不做过滤」正是过滤开启之前的既有行为——下游
当然可能重演 12635 个节点那种事，但那比**零节点发布**好得多（后者让下游连测都没得测）。

## 发布前还要试装排雷（与健康检查是两件事）

健康检查筛的是「节点活不活」，试装筛的是「**能不能被 mihomo 装进 provider**」。后者更
致命，因为 mihomo 对 provider 是「全有或全无」：片里一个节点解析失败，整个 provider 的
`proxies` 直接是 `[]`。实测 2026-09-15：那份 13210 个节点的订阅里有一个 `short-id` 让
mihomo 报 `invalid REALITY short ID`，于是**整份订阅在下游归零**——`provider_snapshot_
collected providers: 1, total: 0`、`nodes_collected: 0`，整轮零产出且不报错。

健康检查那一层的分片只是把这类损失压到「一片（200 个）」，不能消除；坏节点多起来下游
照样大幅缩水。所以发布前把这份 YAML 完整喂给本机 mihomo 试装一遍：装得上直接发；装不上
就**二分**定位到具体节点，只摘掉它，其余全留（`GIST_NODES_TRIAL_LOAD=1`，默认开）。
代价是几次 mihomo 起停（内核已在本地，不必重新下载），换来的是下游拿到的订阅**必定装得上**。

同一条降级原则：试装层自己起不来 / 日志里读不出「provider 被拒」时，原样发布并记
`trial_load_skipped`——宁可下游去扛坏节点，也不能凭一次起不来的日志误删好节点。
"""
import base64
import concurrent.futures
import html as html_lib
import json
import os
import pathlib
import random
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
# 健康检查过滤独立成模块：它要 mihomo 的启动/等待/配置语义（与下游三套测速**同一份实现**，
# 见 alive_filter.py 文件头的「为什么复用 speedtest_gitee」）。gist_nodes 本身不需要 mihomo。
from alive_filter import (  # noqa: E402
    DEFAULT_FILTER_BUDGET_SECONDS,
    SNAPSHOT_TIMEOUT_SECONDS,
    filter_alive,
    trial_load,
)

SEARCH_URL = 'https://gist.github.com/search'
GIST_API = 'https://api.github.com/gists/{gist_id}'

DEFAULT_QUERIES = 'ss://,vless://,vmess://,trojan://,hysteria2://,tuic://'
# Sub-Store **后端 API** 的地址，3000 而不是 3001。镜像 `xream/sub-store:http-meta` 的默认
# 布局是「后端 3000 / 前端 http-meta 3001」（容器启动日志：`[BACKEND] listening on :::3000`
# + `[FRONTEND] :::3001`）。指到 3001 等于打到前端上，`GET /api/subs` 会拿到 Express 的
# 404 `Cannot GET /api/subs` —— 2026-09-14 run 34831792493 就栽在这（那是抓取段收口修好
# 之后，这条链路**第一次**真正走到 Sub-Store 段）。
DEFAULT_SUB_STORE = 'http://127.0.0.1:3000'
# 单次调用超时。**刻意保持 300 不动**：我们没有任何一次真实的 Sub-Store 分段耗时
# （这条链路至今没跑完整过），压小它只是把「合法但慢」的取回误杀成失败，而「一次调用
# 最多能拖多久」这个上界已经由下面的阶段预算兜住了。留着大值反而更好：取回的解析工作
# 本来就集中在两次 download 上，允许单次调用吃掉剩余额度，比强行均分更容易跑成。
DEFAULT_SUB_STORE_TIMEOUT = 300
# Sub-Store 阶段的墙钟预算。为什么要它：投喂是**逐个** POST（订阅多时几十次），
# 建组合与取回各一次，全是单次超时、没有聚合预算 —— 这一段在没有它的时候是无界的，
# 最坏情况能冲出 job 的 timeout-minutes。而那时抓取已经完成，被硬取消的损失比抓取段
# 超时更大（几十个订阅全白喂）。300 秒的一半给投喂、一半留给产出；加上检出 0.4 分钟
# + 抓取预算 15 分钟 ≈ 20.4 分钟，稳在 30 分钟以内。
DEFAULT_SUB_STORE_BUDGET_SECONDS = 300
DEFAULT_MAX_AGE_HOURS = 24
DEFAULT_TARGET_SUBS = 100
DEFAULT_MAX_PAGES = 40
# 抓取阶段的墙钟预算（秒）。为什么是 900：job 的 timeout-minutes 是 30 分钟，扣掉
# 检出/装依赖约 1 分钟、Sub-Store 投喂+解析+发布最坏几分钟，留 15 分钟给抓取比较稳。
# 这个数字与 workflow 里的 timeout-minutes 是**成对**的，改一个要回头看另一个。
DEFAULT_BUDGET_SECONDS = 900
# 连续多少轮「订阅文件数零增长」就收摊。为什么不是「一轮零增长就停」：深层页返回的
# 常是已经见过的 Gist（fresh=0 且 stale=0，既不算「到头」也没产出），而下一轮仍可能
# 有收获；但实测连续十几轮零增长是常态，所以 4 轮（= 每个关键词又白翻 8 页）足够
# 判定「这个搜索面已经挖干了」。
DEFAULT_NO_PROGRESS_ROUNDS = 4
# 同一批里连续多少页被限流就熔断本批、并跳过批末的「补一轮」。为什么需要它：429 的
# 重试成本是 35 秒/页（5/10/20 指数退避）+ 补一轮再来一遍，而节流器的额外间隔会被
# 顶到封顶值，补一轮的每页还要先等一次 60 秒。实测某一批 10 个页全中，单批吃掉 988 秒
# （16.5 分钟，占 job 预算一半）。连续 3 页全中已经足够说明是限流窗口而不是随机命中。
DEFAULT_MAX_CONSECUTIVE_LIMITED = 3

# 跨轮累积：把上一轮发布到本工作流专属 Gist 的订阅（就是上一轮的 providers.yaml）也当一路
# 输入喂回 Sub-Store。为什么要它：抓取段的池子**每轮都在重算**，上一轮捞到、这一轮掉出
# 「最近 N 小时更新」窗口或搜索排名的节点会直接消失——累积让去重后的结果是「历史 ∪ 本轮」。
# 依据：Sub-Store 的输入格式明确支持 `Clash Proxies YAML` / `mihomo(Clash.Meta) Compatible`，
# 所以上一轮产出的 clash YAML 可以直接当本地订阅内容回喂，不需要转成 URI。
DEFAULT_CARRYOVER = 1
# 累积订阅的大小上限。为什么要单独一个上限而不是复用 MAX_FILE_MB：那个默认 2MB 是给
# 搜索到的单个 Gist 文件用的，而累积文件会**随轮次长大**（本轮已 1.07MB），拿 2MB 当界
# 等于给它埋了个会静默到点的天花板。超限时整段跳过并打日志，绝不截断后喂进去。
DEFAULT_CARRYOVER_MAX_MB = 8

# 抓取阶段的收口原因 → 人话。写进 job 摘要，也方便按 gist_nodes_gather_stop 排查。
STOP_REASON_NOTES = {
    'target': '凑够目标',
    'budget': '墙钟预算耗尽，停止翻页，拿已抓到的文件继续产出',
    'stall': '连续多轮零增长，判定搜索面已挖干',
    'active': '所有关键词都到头（翻到末页或整页超龄）',
    'pages': '翻满 GIST_NODES_MAX_PAGES 上限',
}

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


class SearchPacer:
    """页间节流器：被限流就慢下来，连续成功再逐步提速。

    为什么不能只靠固定间隔：搜索页的 429 是**按请求随机触发**的 —— 实测连打 12 次得到
    `429,200,200,429,429,200,...`（同一个 URL 上一秒被拒、下一秒就成功），说明它不是
    「封禁一段时间」而是「当前窗口内按概率拒」。固定间隔适应不了这种状态：被限时仍按
    原节奏打，只会持续踩限流。Pacer 把「连续被限」翻译成「间隔翻倍」，成功后再折半回落。
    """

    def __init__(self, base=0.0, ceiling=60.0):
        self.base = base
        self.ceiling = ceiling
        self.extra = 0.0

    @property
    def delay(self):
        return self.base + self.extra

    def penalty(self):
        """被限流一次：额外间隔从 base 起翻倍，封顶 ceiling。返回新间隔。"""
        self.extra = min(self.ceiling, self.base if self.extra <= 0 else self.extra * 2)
        return self.delay

    def relief(self):
        """成功一次：额外间隔折半回落（掉到 0.1 秒以下就归零）。返回新间隔。"""
        self.extra = self.extra / 2 if self.extra > 0.1 else 0.0
        return self.delay

    def wait(self, jitter=1.0):
        """按当前间隔等待（另加随机抖动）。返回实际等待秒数。"""
        delay = self.delay
        if delay > 0:
            time.sleep(delay + random.uniform(0, jitter))
        return delay


def fetch_search_page(query, page, sort, timeout, retries, backoff_base, pacer=None):
    """取一页搜索结果，返回 (items, status)。

    status 三态，调用方据此决定「继续翻下一页」还是「这个关键词到头了」：
      ok           解析到结果块；
      empty        正常返回但一块都没有 —— 该关键词翻到末页了；
      rate_limited 重试用尽仍是 429。限流是按请求随机的，所以这不该判成「关键词到头」；
                   调用方会先把本页记下来，等一轮再补。

    **`Retry-After` 只记不用**：429 响应确实带这个头，但实测值恒为 `3600`，而紧接着的
    下一个请求就 200 —— 它是个静态默认值，不是真实建议。照它睡 1 小时会让 job 直接超时，
    所以退避一律走我们自己的指数曲线，把头里的值打进日志只作诊断。
    """
    status = 'empty'
    for attempt in range(1, max(1, retries) + 1):
        qs = urllib.parse.urlencode({'q': query, 's': sort, 'page': page})
        try:
            body = http_get(f'{SEARCH_URL}?{qs}', timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                status = 'rate_limited'
                hint = ''
                try:
                    hint = (e.headers.get('Retry-After') or '').strip()
                except Exception:
                    hint = ''
                log_progress('gist_nodes_search_rate_limited', query=query, page=page,
                             attempt=attempt, retries=retries, retry_after=hint)
                if pacer is not None:
                    pacer.penalty()
            else:
                log_progress('gist_nodes_search_failed', query=query, page=page,
                             attempt=attempt, error=str(e))
            if attempt < retries:
                # 指数退避 + 抖动。抖动是必要的：固定节奏的多页请求会踩在同一个限流窗口上，
                # 实测「2 秒固定间隔」连翻十几页必被限，「指数 + 抖动」能自己错开。
                time.sleep(backoff_base * (2 ** (attempt - 1)) + random.uniform(0, 1.5))
            continue
        except Exception as e:
            log_progress('gist_nodes_search_failed', query=query, page=page,
                         attempt=attempt, error=str(e))
            if attempt < retries:
                time.sleep(backoff_base * (2 ** (attempt - 1)) + random.uniform(0, 1.5))
            continue
        if pacer is not None:
            pacer.relief()
        items = parse_search_results(body)
        return items, ('ok' if items else 'empty')
    return [], status


def search_gists(queries, pages, sort, timeout, retries=3,
                 max_age_hours=DEFAULT_MAX_AGE_HOURS, page_from=1,
                 page_delay=0, backoff_base=5, seen=None, pacer=None,
                 deadline=None,
                 max_consecutive_limited=DEFAULT_MAX_CONSECUTIVE_LIMITED):
    """翻 `[page_from, page_from+pages)` 这几页，返回 (candidates, exhausted, dropped)。

    exhausted = 该关键词已经到头（正常返回却没有任何结果块，或整页全部超龄）。
    被限流不算到头 —— 限流是按请求随机的，所以本批内先补一轮，仍失败才记进 dropped。

    五道收口：
      * max_age_hours：丢掉超龄条目；**整页全部超龄就停止该关键词翻页**——排序是
        `s=updated`（降序），这一页都旧了，后面的页只会更旧，继续翻纯属白挨 429。
      * pacer / page_delay：页与页之间的间隔，被限流时由 pacer 自动拉长、成功后回落。
      * 补一轮：本批被限流跳过的页立刻重试一次，只有两轮都失败的才进 dropped。
      * **批内熔断** `max_consecutive_limited`：连续这么多页都是 429 就中止本批的
        剩余页，**并且跳过补一轮**。判据是「限流按出口 IP，是全局状态」——连续多页
        全中就不是随机命中而是窗口期，此时立刻再打（补一轮）恰好撞同一堵墙，而它的
        成本极高（每页 35 秒退避 + 一次封顶 60 秒的节流等待）。熔断只记日志、不把这
        些页塞进 dropped：dropped 的含义仍是「认真试过两轮还是失败」。
      * **deadline**：墙钟预算，页与页之间、关键词与关键词之间都查一次。到点就停，
        已拿到的结果照常返回——预算耗尽不该变成「这一轮白跑」。

    `seen` 跨轮传入，保证同一个 Gist 不会被两轮重复解析。
    """
    now = datetime.now(timezone.utc)
    results = []
    exhausted = set()
    seen = seen if seen is not None else set()
    # 不传 pacer 时按 page_delay 就地造一个（page_delay=0 → 间隔恒 0，等于不等）。
    if pacer is None:
        pacer = SearchPacer(base=page_delay, ceiling=page_delay * 8)
    stale_total = 0
    skipped = []
    consecutive_limited = 0
    aborted = False

    def expired():
        """墙钟预算是否已耗尽。deadline=None（不限）时恒 False。"""
        return bool(deadline) and time.monotonic() >= deadline

    def scan(query, page):
        """取一页并过滤，返回 (fresh 数, stale 数, status)；fresh 已并入 results。"""
        items, status = fetch_search_page(query, page, sort, timeout, retries,
                                          backoff_base, pacer)
        if status != 'ok':
            return 0, 0, status
        fresh = stale = 0
        for item in items:
            if item['id'] in seen:
                continue
            if is_too_old(item['updated'], now, max_age_hours):
                stale += 1
                continue
            seen.add(item['id'])
            item['query'] = query
            results.append(item)
            fresh += 1
        return fresh, stale, status

    for query in queries:
        if aborted or expired():
            break
        for page in range(page_from, page_from + max(1, pages)):
            if expired():
                break
            fresh, stale, status = scan(query, page)
            if status == 'empty':
                exhausted.add(query)
                break
            if status == 'rate_limited':
                skipped.append((query, page))
                consecutive_limited += 1
                if (max_consecutive_limited
                        and consecutive_limited >= max_consecutive_limited):
                    # 本批剩下的页一个都不打了：限流是出口 IP 的全局状态，不是按页的。
                    aborted = True
                    log_progress('gist_nodes_search_batch_aborted', query=query, page=page,
                                 consecutive=consecutive_limited, limited=len(skipped))
                    break
                continue
            consecutive_limited = 0
            stale_total += stale
            if stale and not fresh:
                log_progress('gist_nodes_search_stale_stop', query=query, page=page,
                             stale=stale, max_age_hours=max_age_hours)
                exhausted.add(query)
                break
            pacer.wait()

    # 补一轮：本批被限流跳过的页再试一次。
    # 为什么必须有这一轮：429 是按请求随机的（同一 URL 上一秒被拒、下一秒就成功），
    # 隔一会儿再打命中率很高；而调用方下一轮会把 page_from 翻过去，不补的话这一页的
    # 10 条结果就永远丢了 —— 实测那种「跳过就算了」的写法每轮会静默丢几页。
    # **熔断后不补**：刚刚才连着 3 页全中，说明正处在限流窗口里，立刻重打就是撞同一
    # 堵墙（节流器的额外间隔此时已被顶到封顶，补一轮的每页还要先白等一次）。
    dropped = []
    if aborted:
        log_progress('gist_nodes_search_deferred_skipped', pages=len(skipped),
                     reason='batch_aborted')
    else:
        for idx, (query, page) in enumerate(skipped):
            if expired():
                log_progress('gist_nodes_search_deferred_skipped', pages=len(skipped) - idx,
                             reason='budget')
                break
            pacer.wait()
            fresh, stale, status = scan(query, page)
            if status == 'rate_limited':
                dropped.append((query, page))
                continue
            if status == 'empty':
                exhausted.add(query)
                continue
            stale_total += stale

    if stale_total:
        log_progress('gist_nodes_search_age_filtered', stale=stale_total,
                     max_age_hours=max_age_hours)
    if skipped and not aborted:
        # 字段名避开 'skipped'：共享层 log_progress 的 _redact_value 按**子串**匹配敏感名，
        # 'ip' 是其中之一，任何含 'skipped' 的键都会被整条打成 ***（实测踩过）。
        log_progress('gist_nodes_search_deferred_total', deferred=len(skipped),
                     recovered=len(skipped) - len(dropped))
    if dropped:
        log_progress('gist_nodes_search_page_dropped', pages=len(dropped),
                     targets=[f'{q}#{pg}' for q, pg in dropped])
    return results, exhausted, dropped


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


def fetch_carryover(env, timeout, max_bytes):
    """取**上一轮**发布到本工作流专属 Gist 的订阅正文（就是上一轮的 providers.yaml）。

    返回正文文本或 None。**任何失败都只记日志、返回 None**：累积是增益项，拿不到就当没有，
    绝不能因为它把整轮拖垮——首次运行本来就没有这个文件，Gist 探测失败也只该影响累积。

    为什么用 `raw_url` 而不是 Gist API 里的 `files[..].content`：后者对大于 1MB 的文件会
    **截断**并置 `truncated: true`，而我们的订阅现在就有 1.07MB。宁可多一次请求，也不要拿
    半个 YAML 去喂 Sub-Store（截断的 YAML 要么解析失败，要么静默少一批节点）。
    """
    gist_id = env_str(env, 'PROXY_SPEEDTEST_GIST_ID', '')
    filename = env_str(env, 'PROXY_SPEEDTEST_GIST_FILENAME', '')
    if not (gist_id and filename):
        log_progress('gist_nodes_carryover_skipped', reason='missing_gist_id_or_filename')
        return None
    try:
        res = github_api_request(GIST_API.format(gist_id=gist_id), env.get('GH_TOKEN', ''),
                                 timeout=timeout)
    except Exception as e:
        log_progress('gist_nodes_carryover_skipped', reason='gist_probe_failed', error=str(e))
        return None
    meta = ((res or {}).get('files') or {}).get(filename) or {}
    raw_url = (meta.get('raw_url') or '').strip()
    if not raw_url:
        log_progress('gist_nodes_carryover_skipped', reason='no_previous_file', filename=filename)
        return None
    # 多读 1 字节：read(N) 到顶就返回 N 字节，拿返回值与上限比即可判断有没有被截断。
    # 少了这个 +1，正好等于上限的文件会被误判成超限。
    try:
        text = http_get(raw_url, timeout=timeout, max_bytes=max_bytes + 1)
    except Exception as e:
        log_progress('gist_nodes_carryover_skipped', reason='fetch_failed', error=str(e))
        return None
    size = len(text.encode('utf-8'))
    if size > max_bytes:
        log_progress('gist_nodes_carryover_skipped', reason='oversize',
                     bytes=size, limit_bytes=max_bytes)
        return None
    if not text.strip():
        log_progress('gist_nodes_carryover_skipped', reason='empty')
        return None
    log_progress('gist_nodes_carryover', bytes=size, filename=filename)
    return text


def push_to_substore(base, files, prefix, max_subs, max_total_bytes, timeout, stats,
                     deadline=None, carryover=None):
    """把抓到的订阅正文逐个建成 Sub-Store 本地订阅，返回订阅名列表。

    `deadline` 是这一段自己的墙钟截止点（不是整个 Sub-Store 阶段的）：到点就**停止投喂**、
    把已投喂的返回给调用方继续走产出。为什么投喂可以半途而废而建组合/取回不行：少几个
    订阅文件只是少几个节点，而建组合/取回省掉就完全没有产物了（见模块头的失败语义）。

    单次调用的超时也被剩余额度夹住（`min(timeout, 剩余)`），否则最后一个 POST 还能在
    到点之后再拖满一整个 `timeout`，「到点」就成了空话。

    `carryover`（上一轮的订阅正文）**排在最前面**、名字固定 `{prefix}-000`：万一预算被
    截断，先保住的是跨轮累积的那一份——它是唯一无法从本轮的搜索结果里补回来的东西。
    """
    queue = []
    if carryover:
        queue.append((f'{prefix}-000', carryover))
    # 订阅名不能含 '/'（Sub-Store 明确拒绝），故不用 owner/id，只用序号。
    queue.extend((f'{prefix}-{i:03d}', text) for i, (_name, text) in enumerate(files, 1))

    subnames = []
    for idx, (sub_name, text) in enumerate(queue, 1):
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                log_progress('gist_nodes_push_budget_stop', pushed=len(subnames),
                             remaining=len(queue) - idx + 1)
                break
            call_timeout = max(1, min(timeout, left))
        else:
            call_timeout = timeout
        if max_subs and len(subnames) >= max_subs:
            stats['over_quota'] += 1
            continue
        size = len(text.encode('utf-8'))
        if max_total_bytes and stats['bytes_pushed'] + size > max_total_bytes:
            stats['over_quota'] += 1
            continue
        try:
            ss_create_sub(base, sub_name, text, call_timeout)
        except SubStoreError as e:
            stats['subs_failed'] += 1
            log_progress('gist_nodes_sub_failed', sub=sub_name, error=str(e))
            continue
        stats['subs_created'] += 1
        stats['bytes_pushed'] += size
        subnames.append(sub_name)
    return subnames


def _alive_filter_summary_line(report, deduped_count):
    """把健康检查结果写成人话摘要行。

    关掉过滤时 `report` 为 None：这时**不写「0 个通过」之类的行**，而是明写「未测活」——
    否则读者会把「没做这件事」误读成「做了但一个都没活」。
    """
    if not report:
        return '- 健康检查：未执行（`GIST_NODES_ALIVE_FILTER=0`，原样发布全部节点）'
    if report.get('skipped'):
        return (f'- 健康检查：**未完成，原样发布全部 {deduped_count} 个节点**'
                f'（`{report.get("skip_reason", "")}`）—— 过滤层故障不该让下游零节点可用')
    line = (f'- 健康检查：{deduped_count} → **{report["alive"]}** 个活节点'
            f'（判死 {report["dead"]}，耗时 {report["elapsed_seconds"]} 秒 / 预算 '
            f'{report["budget_seconds"] or "不限"} 秒，目标 `{report["healthcheck_url"]}`）')
    if report.get('unmatched'):
        line += (f'；另有 {report["unmatched"]} 个查不到结论（重名或被改名）**保留**')
    return line


def _trial_load_summary_line(report, published_count):
    """把试装结果写成人话摘要行。

    关掉试装时 `report` 为 None：**不写「剔除 0 个」**，而是明写「未执行」——否则读者
    会把「没做这件事」误读成「做了但一个坏节点都没有」。
    """
    if not report:
        return ('- 试装排雷：未执行（`GIST_NODES_TRIAL_LOAD=0`），'
                '未剔除任何「mihomo 装不上」的节点')
    if report.get('skipped'):
        return (f'- 试装排雷：**未完成，原样发布全部 {published_count} 个节点**'
                f'（`{report.get("skip_reason", "")}`）'
                f'{"，真因：" + report["first_error"] if report.get("first_error") else ""}'
                '—— 排雷层故障不该让下游零节点可用')
    line = (f'- 试装排雷：装得上 **{report["kept"]}** 个，剔除 '
            f'**{report["removed"]}** 个 mihomo 装不上的节点'
            f'（{report["batches"]} 块中 {report["bad_batches"]} 块有问题，'
            f'共试装 {report["rounds"]} 次 / {report["elapsed_seconds"]} 秒）')
    if report.get('batches_failed'):
        line += (f'；另有 {report["batches_failed"]} 块**分辨失败**（未剔除其中任何节点）')
    if report.get('removed_names'):
        shown = '、'.join(f'`{n}`' for n in report['removed_names'][:10])
        line += f'\n  - 被剔除的节点：{shown}'
        if report['removed'] > len(report['removed_names'][:10]):
            line += f' 等 {report["removed"]} 个'
    return line


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
    sort = env_str(env, 'GIST_NODES_SORT', 'updated')
    max_age_hours = max(0, env_int(env, 'GIST_NODES_MAX_AGE_HOURS', DEFAULT_MAX_AGE_HOURS))
    target_subs = max(0, env_int(env, 'GIST_NODES_TARGET_SUBS', DEFAULT_TARGET_SUBS))
    max_pages = max(1, env_int(env, 'GIST_NODES_MAX_PAGES', DEFAULT_MAX_PAGES))
    pages_per_round = max(1, env_int(env, 'GIST_NODES_PAGES_PER_ROUND', 2))
    budget = max(0, env_int(env, 'GIST_NODES_BUDGET_SECONDS', DEFAULT_BUDGET_SECONDS))
    no_progress_limit = max(0, env_int(env, 'GIST_NODES_NO_PROGRESS_ROUNDS',
                                       DEFAULT_NO_PROGRESS_ROUNDS))
    max_consecutive_limited = max(0, env_int(env, 'GIST_NODES_MAX_CONSECUTIVE_LIMITED',
                                             DEFAULT_MAX_CONSECUTIVE_LIMITED))
    max_subs = max(0, env_int(env, 'GIST_NODES_MAX_SUBS', 0))
    max_total_bytes = max(0, env_int(env, 'GIST_NODES_MAX_TOTAL_MB', 0)) * 1024 * 1024
    max_file_bytes = max(0, env_int(env, 'GIST_NODES_MAX_FILE_MB', 2)) * 1024 * 1024
    max_nodes = max(0, env_int(env, 'GIST_NODES_MAX_NODES', 0))
    timeout = max(5, env_int(env, 'GIST_NODES_TIMEOUT', 30))
    retries = max(1, env_int(env, 'GIST_NODES_RETRIES', 4))
    page_delay = max(0, env_int(env, 'GIST_NODES_PAGE_DELAY', 3))
    backoff_base = max(1, env_int(env, 'GIST_NODES_BACKOFF_BASE', 5))
    pacing_ceiling = max(0, env_int(env, 'GIST_NODES_PACING_CEILING', 60))
    workers = max(1, env_int(env, 'GIST_NODES_WORKERS', 8))
    dry_run = env_str(env, 'GIST_NODES_DRY_RUN', '0').lower() not in ('0', 'false', 'no')
    ss_base = env_str(env, 'SUB_STORE_BACKEND_URL', DEFAULT_SUB_STORE)
    ss_timeout = max(10, env_int(env, 'SUB_STORE_TIMEOUT', DEFAULT_SUB_STORE_TIMEOUT))
    ss_budget = max(0, env_int(env, 'SUB_STORE_BUDGET_SECONDS', DEFAULT_SUB_STORE_BUDGET_SECONDS))
    collection = env_str(env, 'SUB_STORE_COLLECTION', 'gist-nodes')
    carryover_on = env_str(env, 'GIST_NODES_CARRYOVER',
                           str(DEFAULT_CARRYOVER)).lower() not in ('0', 'false', 'no')
    carryover_max_bytes = max(0, env_int(env, 'GIST_NODES_CARRYOVER_MAX_MB',
                                         DEFAULT_CARRYOVER_MAX_MB)) * 1024 * 1024
    alive_on = env_str(env, 'GIST_NODES_ALIVE_FILTER', '1').lower() not in ('0', 'false', 'no')
    alive_budget = max(0, env_int(env, 'GIST_NODES_ALIVE_BUDGET_SECONDS',
                                  DEFAULT_FILTER_BUDGET_SECONDS))
    alive_timeout = max(10, env_int(env, 'GIST_NODES_ALIVE_TIMEOUT', SNAPSHOT_TIMEOUT_SECONDS))
    trial_on = env_str(env, 'GIST_NODES_TRIAL_LOAD', '1').lower() not in ('0', 'false', 'no')
    # 显式传给过滤层而不是让它自己从 env 读：env 里有没有这个键、值合不合法，
    # 由这里一处决定，过滤层只认参数字符串（空串 = 用它的默认目标）。
    health_url_override = env_str(env, 'PROXY_SPEEDTEST_HEALTHCHECK_URL', '')
    workdir = pathlib.Path(env_str(
        env, 'GIST_NODES_WORKDIR', str(pathlib.Path.home() / 'proxy-speedtest' / 'gist-nodes')))
    workdir.mkdir(parents=True, exist_ok=True)

    if not queries:
        fail('GIST_NODES_QUERIES 为空：没有关键词就搜不到任何节点')
    if not token:
        log_progress('gist_nodes_no_token', note='匿名调用 GitHub API 限流 60 次/h，可能中途被截断')

    # 边搜边取：搜索与取文交织，直到凑够 target_subs 个「像订阅」的文件。
    # 为什么不先搜完再取：一轮能翻多少页受 429 限制，而搜索结果前排混着大量噪声 Gist
    # （正文是 JSON 统计，只因为含 ss:// 字样被搜到），它们产出 0 个订阅文件。固定
    # 「先搜 N 个 Gist」的配额要么拿不满、要么白搜一堆；只有取文后数真订阅才知道够没够。
    # 每轮每个关键词翻 pages_per_round 页（轮转，保证各协议都有机会），取文后不够就
    # 继续下一轮；整页超龄或翻到末页的关键词退出轮转。
    #
    # 四个出口，前三个都是「收摊但不算失败」——继续拿已抓到的文件走完 Sub-Store：
    #   target  凑够目标（正常收工）
    #   budget  墙钟预算耗尽。**必须有**：只有「凑够」和「翻满 max_pages」两个出口时，
    #           池子不够大的轮次会一路空翻到撞上 job 的 timeout-minutes，而 GitHub 超时
    #           是硬取消 —— 已经抓到的几十个文件一起作废，下游三个测速 job 全 skipped
    #   stall   连续 no_progress_limit 轮文件数零增长（深层页返回的全是见过的 Gist）
    #   active / pages  所有关键词到头 / 翻满 max_pages（正常收工）
    active = list(queries)
    seen_ids = set()
    files = []
    stats = dict.fromkeys(STAT_KEYS, 0)
    candidates_total = 0
    dropped_total = 0
    # 跨轮共用一个 pacer：限流状态是全局的（按出口 IP），不该每轮从零开始学。
    pacer = SearchPacer(base=page_delay, ceiling=pacing_ceiling)
    page_from = 1
    rounds = 0
    no_progress = 0
    stop_reason = ''
    gather_started = time.monotonic()
    deadline = (gather_started + budget) if budget else None
    while active and page_from <= max_pages:
        if deadline and time.monotonic() >= deadline:
            stop_reason = 'budget'
            break
        rounds += 1
        cands, exhausted, dropped = search_gists(
            active, pages_per_round, sort, timeout, retries, max_age_hours,
            page_from=page_from, page_delay=page_delay, backoff_base=backoff_base,
            seen=seen_ids, pacer=pacer, deadline=deadline,
            max_consecutive_limited=max_consecutive_limited)
        active = [q for q in active if q not in exhausted]
        candidates_total += len(cands)
        dropped_total += len(dropped)
        grew = 0
        if cands:
            new_files, local = collect_all(cands, token, timeout, max_file_bytes, workers)
            grew = len(new_files)
            files.extend(new_files)
            for k in STAT_KEYS:
                stats[k] += local[k]
        log_progress('gist_nodes_gather_round', page_from=page_from, active=len(active),
                     candidates=len(cands), files=len(files), target=target_subs,
                     page_delay=round(pacer.delay, 1), dropped=dropped_total)
        if target_subs and len(files) >= target_subs:
            stop_reason = 'target'
            break
        no_progress = 0 if grew else no_progress + 1
        if no_progress_limit and no_progress >= no_progress_limit:
            stop_reason = 'stall'
            break
        page_from += pages_per_round

    gather_elapsed = round(time.monotonic() - gather_started, 1)
    if not stop_reason:
        stop_reason = 'active' if not active else 'pages'
    if stop_reason in ('budget', 'stall'):
        log_progress('gist_nodes_gather_stop', reason=stop_reason, rounds=rounds,
                     elapsed=gather_elapsed, files=len(files), target=target_subs,
                     no_progress=no_progress, page_from=page_from, budget=budget)
    log_progress('gist_nodes_sources', **stats, files=len(files),
                 candidates=candidates_total, target=target_subs,
                 dropped_pages=dropped_total, final_page_delay=round(pacer.delay, 1),
                 rounds=rounds, elapsed=gather_elapsed, stop_reason=stop_reason)
    if not candidates_total:
        if max_age_hours:
            fail(f'没有解析出任何「最近 {max_age_hours} 小时内更新」的 Gist'
                 f'（窗口太窄，或搜索页结构已变）')
        fail('搜索页一个 Gist 都没解析出来（页面结构可能已变，或网络被拦）')
    if not files:
        fail(f'扫了 {stats["gists_scanned"]} 个 Gist 但没找到任何像订阅的文件')

    # Sub-Store 阶段：整段有个墙钟预算（ss_budget），并且**一半留给产出**。
    # 为什么必须给产出留额度：投喂是逐个 POST、订阅多时几十次，是全段唯一无界的部分；
    # 不给它设上限，它能把整段预算吃光，然后建组合/取回拿不到时间 —— 投喂成功却产不出
    # 订阅，等于白跑一轮，比少投喂几个订阅糟得多。
    ss_started = time.monotonic()
    ss_deadline = (ss_started + ss_budget) if ss_budget else None
    push_deadline = (ss_started + ss_budget / 2) if ss_budget else None

    def ss_call_timeout(label):
        """单次调用超时 = min(单次上限, 剩余预算)。预算已耗尽 → 直接失败。

        为什么耗尽要失败而不是「再等一会」：这里已经是「产出」步骤，等下去就是撞 job 的
        timeout-minutes，而被硬取消时连已投喂的订阅也一起废掉——不如就地失败，日志清楚。
        """
        if ss_deadline is None:
            return ss_timeout
        left = ss_deadline - time.monotonic()
        if left <= 0:
            fail(f'Sub-Store 阶段预算（{ss_budget} 秒）耗尽，放弃「{label}」：'
                 '继续等会撞 job 的 timeout-minutes，被硬取消时连已投喂的订阅也一起废掉')
        return max(1, min(ss_timeout, left))

    # Sub-Store 就绪性：先探一次，把「容器没起来」和「订阅内容有问题」两类失败分开。
    try:
        status, body = ss_request(ss_base, 'GET', '/api/subs', None,
                                  min(ss_call_timeout('就绪探活'), 30))
    except SubStoreError as e:
        fail(f'Sub-Store 后端不可达（{ss_base}）：{e}')
    if status != 200:
        fail(f'Sub-Store 后端异常：GET /api/subs → HTTP {status} {body[:200]}')

    # 跨轮累积：把上一轮发布到本工作流专属 Gist 的订阅也当一路输入喂给 Sub-Store。
    # **必须在发布之前取**——发布之后 Gist 里就是本轮产物了，再读就成了自己喂自己。
    # 顺序上先取、再投喂：这样即便后面投喂/产出失败，日志里也已经留下了「取到没取到」。
    carryover = None
    if carryover_on and not dry_run:
        carryover = fetch_carryover(env, timeout, carryover_max_bytes)
    elif carryover_on:
        log_progress('gist_nodes_carryover_skipped', reason='dry_run')

    subnames = push_to_substore(ss_base, files, collection, max_subs, max_total_bytes,
                                ss_timeout, stats, deadline=push_deadline,
                                carryover=carryover)
    log_progress('gist_nodes_pushed', subs=len(subnames),
                 files=len(files) + (1 if carryover else 0),
                 carryover=bool(carryover),
                 **{k: stats[k] for k in
                    ('subs_created', 'subs_failed', 'bytes_pushed', 'over_quota')})
    if not subnames:
        fail('没有一个订阅成功投喂进 Sub-Store')

    process = build_process(max_nodes)
    try:
        # 参照组：同样的订阅但不带去重，用来给出「解析后 N → 去重后 M」这个可核对的口径。
        # Sub-Store 对未知算子只记日志、不报错，没有这个参照组就无从判断去重是否真生效。
        ss_create_collection(ss_base, f'{collection}-raw', subnames, [],
                             ss_call_timeout('建 -raw 参照组'))
        ss_create_collection(ss_base, collection, subnames, process,
                             ss_call_timeout('建主组合'))
        yaml_text = ss_download(ss_base, collection, 'ClashMeta',
                                ss_call_timeout('取回 ClashMeta YAML'))
        raw_json = ss_download(ss_base, f'{collection}-raw', 'JSON',
                               ss_call_timeout('取回参照组 JSON'))
    except SubStoreError as e:
        fail(str(e))

    ss_elapsed = round(time.monotonic() - ss_started, 1)
    log_progress('gist_nodes_substore_phase', elapsed=ss_elapsed, budget=ss_budget,
                 per_call_timeout=ss_timeout, subs=len(subnames), files=len(files))

    if 'proxies:' not in yaml_text:
        fail(f'Sub-Store 产出的不是 mihomo YAML，前 300 字：{yaml_text[:300]}')
    try:
        proxies = (yaml.safe_load(yaml_text) or {}).get('proxies') or []
    except Exception as e:
        fail(f'Sub-Store 产出的 YAML 解析失败：{e}')
    if not proxies:
        fail('Sub-Store 产出的订阅里一个节点都没有')
    # 原样留一份：过滤后的 YAML 若被判「不该动」就要回退到它，而 `yaml.safe_dump`
    # 与原文本不可能逐字相同（注释、引号风格、键序都变了）。见下面 `proxies is all_proxies`。
    all_proxies = proxies
    original_yaml_text = yaml_text
    try:
        parsed_count = len(json.loads(raw_json))
    except Exception:
        parsed_count = 0

    if dry_run:
        # dry-run 的真实用途是「验 Sub-Store 那条链路」（见 GIST_NODES_DRY_RUN 注释），
        # 而健康检查与试装都要另起 mihomo（几十 MB 下载 + 反复起停），与「本地快速验证」
        # 相悖。想在这里也验它们，就单独用 GIST_NODES_ALIVE_FILTER=1 / GIST_NODES_TRIAL_LOAD=1。
        alive_on = False
        trial_on = False

    deduped_count = len(proxies)
    log_progress('gist_nodes_deduped', parsed=parsed_count, deduped=deduped_count,
                 max_nodes=max_nodes, bytes=len(yaml_text.encode('utf-8')))
    if parsed_count and deduped_count >= parsed_count:
        # 去重没生效通常是 process 里的 type 名写错了（Sub-Store 只记日志、不报错）。
        log_progress('gist_nodes_dedupe_no_effect', parsed=parsed_count, deduped=deduped_count)

    # 发布前过一轮健康检查：下游三套测速会拿这份订阅各自起 mihomo 做非惰性健康检查，
    # 节点上万时那一步根本跑不完（下游只认到十来个节点，见文件头）。这里先筛。
    alive_report = None
    if alive_on:
        proxies, alive_report = filter_alive(
            env, proxies, budget_seconds=alive_budget,
            workdir=workdir / 'alive-filter', health_url=health_url_override,
            snapshot_timeout=alive_timeout)
        if not proxies:
            # 全判死极可能是探测目标不可达（把「目标挂了」错读成「节点都死了」），
            # 零节点发布会让下游一个都测不了——比不过滤糟得多，所以退回不过滤。
            log_progress('alive_filter_all_dead_fallback', deduped=deduped_count,
                         note='全部判死，怀疑探测目标不可达，原样发布不过滤')
            proxies = all_proxies
            alive_report = dict(alive_report or {}, skipped=True,
                                skip_reason='all_dead', alive=deduped_count, dead=0)

    # 试装排雷：把「mihomo 装不上」的节点摘掉再发布。
    # 与健康检查是两件事——上面筛「活不活」，这里筛「能不能被装进 provider」。后者更致命：
    # mihomo 对 provider 是「全有或全无」，一个解析失败的节点就让整片的 `proxies` 变 `[]`。
    # 注意它**放在健康检查之后**：过滤已经把节点压到几百个，试装只需一两次 mihomo 起停；
    # 而且只对「值得发布」的节点做二分，不会为已经要丢的节点白费一轮。
    trial_report = None
    if trial_on and proxies:
        proxies, trial_report = trial_load(proxies, workdir=workdir / 'trial-load')
        if not proxies and trial_report.get('removed'):
            # 摘光了极可能是判据本身出了问题（比如 mihomo 内核换了报错格式），
            # 零节点发布比发布未排雷的订阅糟得多，退回不排雷。
            log_progress('trial_load_all_removed_fallback', removed=trial_report['removed'],
                         note='试装把全部节点判成坏节点，怀疑判据失效，原样发布不排雷')
            proxies = all_proxies if alive_report is None else list(
                p for p in all_proxies
                if str((p or {}).get('name') or '') not in set(trial_report['removed_names']))
            if alive_report is not None:
                alive_report = dict(alive_report, alive=len(proxies))
            trial_report = dict(trial_report, skipped=True, skip_reason='all_removed',
                                removed=0, removed_names=[], kept=len(proxies))

    if proxies is all_proxies:
        yaml_text = original_yaml_text
    else:
        yaml_text = yaml.safe_dump({'proxies': proxies}, allow_unicode=True, sort_keys=False)

    (workdir / 'providers.yaml').write_text(yaml_text, encoding='utf-8')
    (workdir / 'nodes.json').write_text(json.dumps({
        'queries': queries,
        'sort': sort,
        'max_age_hours': max_age_hours,
        'target_subs': target_subs,
        'max_pages': max_pages,
        'gather': {'rounds': rounds, 'elapsed_seconds': gather_elapsed,
                   'stop_reason': stop_reason, 'budget_seconds': budget,
                   'no_progress_rounds': no_progress_limit,
                   'max_consecutive_limited': max_consecutive_limited},
        'substore': {'elapsed_seconds': ss_elapsed, 'budget_seconds': ss_budget,
                     'per_call_timeout_seconds': ss_timeout, 'subs_pushed': len(subnames),
                     'files_found': len(files) + (1 if carryover else 0),
                     'files_gathered': len(files),
                     'carryover': {'enabled': carryover_on,
                                   'used': bool(carryover),
                                   'bytes': len(carryover.encode('utf-8')) if carryover else 0,
                                   'max_bytes': carryover_max_bytes}},
        'collection': collection,
        'process': process,
        'stats': stats,
        'parsed_count': parsed_count,
        'deduped_count': deduped_count,
        'node_count': len(proxies),
        'alive_filter': alive_report,
        'trial_load': trial_report,
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
        'deduped_count': deduped_count,
        'alive_count': len(proxies) if alive_report else '',
        'gists_scanned': stats['gists_scanned'],
        'gist_html_url': gist_html_url,
        'gist_id': gist_id,
    })
    write_step_summary([
        '### gist 节点抓取（Sub-Store 去重）',
        '',
        f'- 关键词：`{", ".join(queries)}`（排序 `{sort}`，每个最多翻 {max_pages} 页）',
        f'- 时间窗口：{"最近 " + str(max_age_hours) + " 小时内更新" if max_age_hours else "不限"}；'
        f'候选 Gist：{candidates_total}，实际解析：{stats["gists_scanned"]}（失败 {stats["gist_errors"]}）',
        f'- 真订阅：目标 {target_subs or "不限"}，实际拿到 **{len(files)}** 个订阅文件',
        f'- 抓取收口：`{stop_reason}`（{rounds} 轮 / {gather_elapsed} 秒'
        + (f'，预算 {budget} 秒' if budget else '，预算不限') + '）'
        + ('' if stop_reason == 'target' else ' —— 未凑够目标是正常的：'
           f'`{STOP_REASON_NOTES.get(stop_reason, stop_reason)}`'),
        f'- 投喂订阅：{stats["subs_created"]} 个（失败 {stats["subs_failed"]}，'
        f'{round(stats["bytes_pushed"] / 1048576, 1)} MB）'
        f'，Sub-Store 阶段耗时 {ss_elapsed} 秒 / 预算 {ss_budget or "不限"} 秒',
        f'- Sub-Store 解析：{parsed_count} 个节点 → 去重/清理后：**{deduped_count}**'
        + (f'（限量 {max_nodes}）' if max_nodes else ''),
        _alive_filter_summary_line(alive_report, deduped_count),
        _trial_load_summary_line(trial_report, len(proxies)),
        f'- 订阅 Gist：{gist_html_url or "(dry-run 未发布)"}',
    ])
    print(f'OK: {len(proxies)} 个节点（解析 {parsed_count}）'
          + (f'（去重 {deduped_count} → 测活 {len(proxies)}）' if alive_report else '')
          + (f'（试装剔除 {trial_report["removed"]}）'
             if trial_report and trial_report.get('removed') else '')
          + f'，{stats["subs_created"]} 个订阅经 Sub-Store 去重，'
          f'订阅 raw: {sub_url or "(dry-run)"}')


if __name__ == '__main__':
    main()
