# 泰尔三网测速（proxy-speedtest-taier）

> 代码：`.github/scripts/proxy-speedtest/taier_speedtest.py`
> 入口：`.github/workflows/proxy-speedtest-taier.yml`

## 三件套总览

仓库代理测速三套**按测速点命名**，口径互不可比（单流 vs 多连接 vs 专用测速协议）：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | `speedtest_gitee.py` | [gitee](proxy-speedtest-gitee.md) |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | `speedtest.py` | [cdn](proxy-speedtest-cdn.md) |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | 本文 | — |

调度：UTC 23/03/07/11（北京 07/11/15/19），与 gitee（UTC 21/01/05/09 → 京 05/09/13/17）、cdn（UTC 22/02/06/10 → 京 06/10/14/18）各错开 1 小时；三套都只排在北京时间 05:00–21:00（夜间 runner 排队 + 出口拥塞会让读数失真）。

## 功能与链路

对订阅 `PROXY_SPEEDTEST_SUB_URLS` 里 provider 解析出的**每个节点**串行执行（不按健康检查
`alive` 预筛，逐节点测活才是准入关口，见
[gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)）：

1. 下载 `MiaM1ku/taierspeedtest` 最新 Release 二进制（固定文件名 `~/proxy-speedtest/taierspeedtest`，供进程规则匹配）；
2. mihomo 以 **TUN 模式**启动：`tun.enable + auto-route` 接管整机出向，规则
   `['PROCESS-NAME,taierspeedtest,AUTO', 'MATCH,DIRECT']`——**只有测速进程走当前节点**，
   runner 自己的心跳/日志直连；经 API 切换 AUTO 组到该节点；
3. 运行 taierspeedtest（协议还原自 `com.cnspeedtest.globalspeed`：控制面取出口 IP/定位 →
   按测速点匹配运营商服务器 → 原生 TCP 上下行）；
4. 解析 stdout：出口 IP/位置、延迟、上下行；与 runner 直连出口 IP 比对（**bypass 校验**）；
5. 全部节点完成：Telegram 推 `✅ 泰尔三网测速`（TOP5 ↓↑Mbps + 延迟），达标节点订阅导出到
   本工作流专属 Gist，结果 JSON 落盘 `~/proxy-speedtest/taier_speedtest_result.json`。

## 吞吐与 job 上限

**逐节点串行，且每节点的成本基本固定**（切换节点 → 跑 taierspeedtest → 解析）。脚本自己在
`taier_speedtest.py` 里给了算式：耗时约 `节点数 × (2 × duration + 5)` 秒，默认 `duration=10`
⇒ **25 秒/节点**。也就是说这个 job 的时长**线性取决于订阅里有多少节点**，而
`proxy-speedtest-gistnodes` 一次会交接几千个（2026-09-14 那轮交接 3284 个 ≈ 22.8 小时）。

**所以刻意不给这个 job 设 `timeout-minutes`**，与 gitee / cdn 两套一致（走 GitHub 的 job 默认
360 分钟）。原先写死 45 分钟，等于把「无界的串行测速」交给一个拍出来的天花板，必然撞硬取消：
45 分钟只够约 **108 个节点**，整轮白烧，而且被硬取消时连正常通知都发不出去，只能靠 SIGTERM
兜底那条 `⛔ 泰尔三网测速异常终止`。

⚠️ **不设 ≠ 没有上限**，默认 360 分钟。所以脚本自己有墙钟预算 `TAIER_BUDGET_SECONDS`
（默认 `18000` = 5 小时）：**从进程启动起算**，到点就不再开下一个节点，拿已测节点照常出订阅、
发通知（正文补一行 `⚠️ 本轮已中止：…`、标题降 ⚠️），**退出码仍是 0——到点收摊不是失败**。
留 1 小时余量给前置准备（mihomo 下载 / TUN）与收尾（通知 / Gist 上传），所以
**5 小时 < 360 分钟这个关系不能破：改 job 的 `timeout-minutes` 就要回头看这个预算**
（同 `proxy-speedtest-gistnodes` 那三段预算的规矩）。按 25 秒/节点算，5 小时约能测
**720 个**节点——比原先 45 分钟的 108 个多一个量级，且**每轮都有产出**，不会像硬取消那样整轮白烧。

## 为什么必须 mihomo TUN

taierspeedtest 是原生 TCP/ICMP 客户端：没有 `--proxy` 参数；Go 的 `net.Dialer` 直接发
系统调用，**proxychains 这类 LD_PRELOAD 方案对 Go 静态二进制无效**。只有 TUN 能把该
进程流量透明接入节点。开 TUN 需要 `CAP_NET_ADMIN`，非 root 时脚本自动 `sudo -n` 启动
mihomo（kill 陈旧进程同理）。

TUN 起来后 DNS 会被 mihomo 劫持，必须显式给可达的公共解析器
（`dns.nameserver: [1.1.1.1, 8.8.8.8]` + `respect-rules: false`）——默认国内递归 DNS
在 Azure runner 上不通，会导致被代理程序秒失败。

## bypass 校验（必须有）

每节点比对「测速 stdout 的出口 IP」与 runner 直连出口 IP（`api.ipify.org` 等）：

- **不同** → 流量确实走了节点 ✓
- **相同** → TUN 未生效 / 进程规则未命中 → 通知里 `⚠️ 疑似未走代理` 告警；
  全部节点命中时 job 返回 1（否则会**静默直连**、整轮数据失真）

## 环境变量

### secrets

| secret | 用途 |
|---|---|
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（三套共用） |
| `PROXY_SPEEDTEST_TAIER_GIST_ID` | 本工作流专属订阅 Gist 的 id；留空首跑自动新建（TG 给链接），回填避免每轮新建 |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |

被 `proxy-speedtest-gistnodes` 当子流程调用时，结果 Gist 与通知标题可被入参覆盖：
`gist_id` / `gist_filename` / `gist_description` 把结果写进调用方的 Gist，
`label` 给通知标题加来源前缀（如 `✅ gist 节点 · 泰尔三网测速`）。
四个入参留空时行为与定时轮完全一致（写本工作流 Gist、标题不带前缀）。

### 可调参数（均有默认值）

| env | 默认 | 说明 |
|---|---|---|
| `TAIER_POINTS` | `广东联通` | 测速点（省份/城市+运营商，逗号分隔可多点，耗时成倍） |
| `TAIER_MODE` | `single` | `single`=单连接 / `multi`=下 8+上 4 连接 / `both` 对照 |
| `TAIER_DURATION` | `10` | 每方向秒数；**上游二进制硬钳制 5-13**，>13 被压到 13 |
| `TAIER_MAX_NODES` | `0` | 最多测几个节点，0 = 不限 |
| `TAIER_BUDGET_SECONDS` | `18000` | **墙钟预算**（秒，`0` = 不限），从进程启动起算。到点不再开下一个节点，拿已测节点照常出订阅（退出码 0）。**与 job 的 `timeout-minutes` 成对**：默认 5 小时 < 360 分钟。workflow 里写死，不接仓库 Variables |
| `TAIER_ALIVE_PROBE` | `1` | 测速前先测活（跳过连不上的节点，省下一个 ≈25 秒的测速窗口）。**默认开**：误杀风险由熔断（开头连续 8 个未通过且无一成功即关掉探测）与 fail-open（探测机制出错按存活处理）兜住。run 34859505000 曾 27 个节点全 `Resource not found`（探测用的节点名在 mihomo 里对不上）属已知代价，要规避就 dispatch 选 `alive_probe=off`（或给本工作流传 `alive_probe: off`）；**不接仓库 Variables**。**这是本工作流唯一的准入关口**——节点收集层已不再按 provider 的 `alive` 预筛（见 [gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)），收集来的节点全量进循环 |
| `TAIER_TIMEOUT` | `120` | 单节点子进程超时秒 |
| `TAIER_SWITCH_SETTLE_SECONDS` | `1.5` | 切节点后等待 |
| `TAIER_IMAGE` | `0` | 每节点出结果图（上传图床），默认关避免刷图 |
| `TAIER_NO_IPV6` | `1` | TUN 下客户端易误判 v6 可用导致耗时翻倍，默认关 |
| `TAIER_REPO` | `MiaM1ku/taierspeedtest` | 引擎仓库 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），三套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；另一指标达标数明显更多时自动改用另一指标（倍率见下） |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |
| `PROXY_SPEEDTEST_METRIC_FALLBACK_RATIO` | 1.5 | 回退倍率：另一指标达标数 ≥ 主指标 × 该值才切换 |

订阅导出策略（阈值/判定指标/最少节点数，含回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三套共用)。
注意 taier **上行常测不出**（CDN 类测速点拒绝上传包，引擎渲染 failed → 0），此时上行达标数
远少于下行 ⇒ 自动落到下行判定，通知会显示实际采用的指标。

### Gist 文件名/描述（三套区分）

`PROXY_SPEEDTEST_GIST_FILENAME` = `proxy_speedtest_taier_subscription.yaml`、
`PROXY_SPEEDTEST_GIST_DESCRIPTION` = `proxy speedtest subscription (taier 三网)`。
导出字段单位是 MiB/s，taier 数值为 Mbps，脚本内 ÷8.388608 换算（节点名前缀"↓xx兆"与
真实 Mbps 基本一致）。

## Telegram 通知

| 标题 | 触发 |
|---|---|
| `✅ 泰尔三网测速` | 正常完成（含 TOP5、订阅 Gist 状态、bypass/失败分节） |
| `⛔ 泰尔三网测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），handler **先撤 TUN 再发** |
| `❌ 泰尔三网测速异常退出 · <原因>` | 环境准备失败 / 节点快照失败 / 未捕获异常，标题取原因冒号前的阶段名 |

节点数与 TOP5 口径：`ok` = 客户端 rc=0 且有区域结果且上下行不全为 0；出口 IP 与直连
相同的节点不计入"成功"。

## 运维与排查

| 现象 | 原因 / 处置 |
|---|---|
| `nodes_collected: 0` 但 `source_mapping_built` 有值 | 2026-09-15 run 34969408908 的形态：收集层曾只收 provider 里 `alive` 为真的节点，而 `wait_mihomo` 不等健康检查出结论。现已改为全量收集，见 [gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)；先看 `provider_snapshot_collected` 的 `total` / `collected` 是否相等 |
| 通知出现 `⚠️ 疑似未走代理` | TUN 没起来或 `PROCESS-NAME` 规则未命中；查 `mihomo.log` 与 `/dev/net/tun`；结果不可信，整轮判失败 |
| 节点全部「连不上测速点」 | 控制面 `*.cnspeedtest.cn` 经该节点不可达；换节点或检查 mihomo DNS 配置 |
| **run 卡在 in_progress、取消也无效** | TUN 未撤（历史事故）：脚本退出前必须 `stop_mihomo_tun()`；workflow 里有 `always()` 兜底步骤 `pkill "mihomo -d"` |
| 延迟 1 秒以上 | ICMP 经 TUN 不通，回落 TCP tcping（真实握手往返），属预期 |
| 验证 handler | 运行中途 `gh run cancel`：日志应出现两次 `mihomo_tun_stopped`（handler + finally），TG 收到 ⛔ |

上游 duration 钳制 5-13 秒（`main.go`），需要更长测速只能改上游或自编译。
