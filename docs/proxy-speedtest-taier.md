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

四项测量（测活/延迟/上传/下载）的**四套横向对照表**在
[gitee 文档 · 四项测量口径速查](proxy-speedtest-gitee.md#四项测量口径速查四套对照)。
两处最易误读的：taier 是**唯一真探活的两套之一**（另一套是上游 gistnodes），
且 taier 的「兆」与另外两套的 MiB/s **不是同一把尺子**（换算见该表下方的单位陷阱说明）。

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
`taier_speedtest.py` 里给了算式：耗时约 `节点数 × (2 × duration + 5)` 秒。`duration` 默认
**13**（2026-09-17 从 10 下调到 5、2026-09-24 又上调回 13）⇒ **31 秒/节点**。也就是说这个
job 的时长**线性取决于订阅里有多少节点**，而 `proxy-speedtest-gistnodes` 一次会交接几千个
（实测 2026-09-16 run 35116972319 交接 **8326** 个）。

**所以刻意不给这个 job 设 `timeout-minutes`**，与 gitee / cdn 两套一致（走 GitHub 的 job 默认
360 分钟）。原先写死 45 分钟，等于把「无界的串行测速」交给一个拍出来的天花板，必然撞硬取消：
45 分钟只够约 **108 个节点**，整轮白烧，而且被硬取消时连正常通知都发不出去，只能靠 SIGTERM
兜底那条 `⛔ 泰尔三网测速异常终止`。

⚠️ **不设 ≠ 没有上限**，默认 360 分钟。所以脚本自己有墙钟预算 `TAIER_BUDGET_SECONDS`
（默认 `18000` = 5 小时）：**从进程启动起算**，到点就不再开下一个节点，拿已测节点照常出订阅、
发通知（正文补一行 `⚠️ 本轮已中止：…`、标题降 ⚠️），**退出码仍是 0——到点收摊不是失败**。
留 1 小时余量给前置准备（mihomo 下载 / TUN）与收尾（通知 / Gist 上传），所以
**5 小时 < 360 分钟这个关系不能破：改 job 的 `timeout-minutes` 就要回头看这个预算**
（同 `proxy-speedtest-gistnodes` 那三段预算的规矩）。

**按 31 秒/节点（duration=13）算，5 小时约能测 580 个**；duration=5 时约 1200 个。
但**节点数远超预算**是常态（8326 个 ÷ 31s ≈ 71 小时），所以「池子有多大」比「测多快」更关键——
见下一节。

### 单节点耗时构成与 duration 这笔账

| 环节 | duration=13 | duration=5 | 可压缩性 |
|---|---|---|---|
| `switch_proxy` settle | 1.5s | 1.5s | `TAIER_SWITCH_SETTLE_SECONDS` 可调（调小增加切错风险） |
| 引擎 `--duration` × 2（上/下行各一次） | 26s | **10s** | 上游二进制硬钳 5–13；**这是唯一的大杠杆** |
| 测活探测 | 开测前**一次**批量预取整组延迟表；逐节点查表 ≈0（旧逐节点路径是 ≤3s/个） | 同 | 跳过死节点反而省时间 |
| 进程启动 + 解析 | ~1s | ~1s | 可忽略 |
| **合计** | **≈31s** | **≈15s** | −52% |

⚠️ duration 的取舍是「覆盖节点数」换「单点读数精度」：窗口越短读数越抖（尤其上行，公开节点
上行本就常测不出），但覆盖的节点越多。**2026-09-24 从 5 上调回 13**：测活层已能真筛死节点
（组测速判死，不再需要靠缩短窗口去摊薄死节点的开销），把读数质量放回来；覆盖数的下降由
`TAIER_INCLUDE_REGEX` 收词表 + `TAIER_BUDGET_SECONDS` 到点收摊兜住。

### include 过滤：唯一决定「池子有多大」的一层（2026-09-22）

节点数远超预算时，**没测到的节点等于不存在**。2026-09-22 编排轮（run 35684842162）交接
15793 个节点，5 小时预算只测完 1905 个（单节点 ≈9.5 秒，全测完 ≈41 小时），轮轮撞
`TAIER_BUDGET_SECONDS` 到点收摊。所以靠**真过滤**把池子压进预算：命中保留、未命中**丢弃**。

```python
if CONFIG['TAIER_INCLUDE_REGEX']:
    alive_items, _include_dropped = filter_nodes_include(
        alive_items, CONFIG['TAIER_INCLUDE_REGEX'])
```

三条设计约束：

1. **默认空 = 不过滤**：定时轮 / 手动 dispatch 吃的是用户自己的机场订阅，不该被正则砍；
   只有编排轮经 workflow_call 入参 `include_regex` 显式传入（dispatch 刻意不设同名入参，
   防止误开）。
2. **两条 fail-open**（与测活层同一原则，过滤层不得造成零产出）：正则非法 → 原样放行并记
   `include_regex_invalid`；过滤后一个不剩 → 同样原样放行并记
   `include_regex_all_dropped_fallback`——全不剩更可能是词表与当轮命名完全错位，
   而不是「节点真的一万个都不要」。
3. **池子大小只能由这一层决定**（2026-09-24）：同批删掉的 `prioritize_nodes`
   （`TAIER_PRIORITY_REGEX`）只排顺序不减量、`TAIER_MAX_NODES` 是「按 provider 原序砍尾巴」、
   会砍掉还没测过的节点 —— 两者都与「到点收摊」语义重复且更易误伤。跑不完交给
   `TAIER_BUDGET_SECONDS`。测试 13g 断言两者不得回归。

编排轮传的词表怎么定的，见
[gistnodes 文档 · 编排轮 include 过滤词表](proxy-speedtest-gistnodes.md#编排轮-include-过滤词表2026-09-22)。


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
`label` 给通知标题加来源前缀（如 `✅ gist 节点 · 泰尔三网测速`）；
`include_regex` 传节点名 include 过滤正则（命中保留、未命中丢弃，见上节——
只有编排轮传，定时轮与手动 dispatch 为空 = 不过滤）。
入参留空时行为与定时轮完全一致（写本工作流 Gist、标题不带前缀、不过滤）。

### 可调参数（均有默认值）

| env | 默认 | 说明 |
|---|---|---|
| `TAIER_POINTS` | `广东联通` | 测速点（省份/城市+运营商，逗号分隔可多点，耗时成倍） |
| `TAIER_MODE` | `single` | `single`=单连接 / `multi`=下 8+上 4 连接 / `both` 对照 |
| `TAIER_DURATION` | `13` | 每方向秒数；**上游二进制硬钳制 5-13**，>13 被压到 13、<5 被抬回 5。2026-09-17 从 10 下调到 5（单节点 25s→15s）、**2026-09-24 上调回 13**（单节点 ≈31s）：测活层已能真筛死节点，把读数质量放回来；覆盖数下降由 include 词表与预算到点收摊兜住 |
| `TAIER_INCLUDE_REGEX` | （空） | 节点名 include 过滤正则（不区分大小写），命中**保留**、未命中**丢弃**——**唯一决定「池子有多大」的一层**（见上节）。同批（2026-09-24）删除的 `TAIER_PRIORITY_REGEX`（只排序不减量）与 `TAIER_MAX_NODES`（按原序砍尾巴）不得回归。默认空 = 不过滤；正则非法或过滤后为空 → 原样放行（`include_regex_invalid` / `include_regex_all_dropped_fallback`）。workflow 里不写死，由编排轮经 `include_regex` 入参传入 |
| `TAIER_BUDGET_SECONDS` | `18000` | **墙钟预算**（秒，`0` = 不限），从进程启动起算。到点不再开下一个节点，拿已测节点照常出订阅（退出码 0）。**与 job 的 `timeout-minutes` 成对**：默认 5 小时 < 360 分钟。workflow 里写死，不接仓库 Variables |
| `TAIER_ALIVE_PROBE` | `1` | 测速前先测活（跳过连不上的节点，省下一个 ≈31 秒的测速窗口）。**默认开**：2026-09-24 起改为**开测前一次性批量预取**整组延迟表（`GET /group/AUTO/delay` → `{节点名: 延迟ms}`），逐节点只查这张表；误杀风险由 fail-open 兜住（**拿不到表 ⇒ 探测层整体关闭、全量放行去测速**，日志 `taier_probe_disabled`）。⚠️ 还有一道**覆盖度闸门**（见下一行）：表覆盖不住待测池时同样关闭探测层——2026-09-25 实测大池下表只覆盖 3.7%，「表里没有」是「还没轮到」而不是「连不上」，照判会成片误杀。拿到可信的表时「表里没有该节点」= mihomo 明确判死 ⇒ 计入 `❌ 失败`（错误串带「测活未通过：」前缀）。要规避就 dispatch 选 `alive_probe=off`（或给本工作流传 `alive_probe: off`）；**不接仓库 Variables**。**这是本工作流唯一的准入关口**——节点收集层已不再按 provider 的 `alive` 预筛（见 [gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)），收集来的节点全量进循环 |
| `TAIER_PROBE_MIN_COVERAGE` | `0.5` | **覆盖度下限**（表条目 ÷ 待测节点数）：低于它即关闭探测层、全量放行去测速，日志 `taier_probe_low_coverage`。为什么需要它：mihomo 的组测速在大池下**只返回已测完的那批**，不是全量——单节点轮（待测 17）表 17 条 = 覆盖 100%、判死可信；编排轮（待测 1780）表只有 65 条 = 覆盖 3.7%，据此判死 1777 个里绝大多数是误杀。宁可让死节点各吃一个测速窗口，也不能把活节点整片砍掉 |
| `TAIER_ALIVE_PROBE_URL` | `https://dlcv2.cnspeedtest.cn:8443` | 批量探测的目标 URL，默认取泰尔控制面首地址（`_TAIER_CTRL_SERVERS[0]`）——测的是「这个节点到底能不能跑泰尔」，不是泛泛的连通性 |
| `TAIER_ALIVE_PROBE_TIMEOUT_MS` | `3000` | 组测速的**单节点**超时（ms）；整组并发跑，外层超时按 `timeout/1000+90` 秒再封顶 900 秒 |
| `TAIER_TIMEOUT` | `120` | 单节点子进程超时秒 |
| `TAIER_SWITCH_SETTLE_SECONDS` | `1.5` | 切节点后等待 |
| `TAIER_IMAGE` | `0` | 每节点出结果图（上传图床），默认关避免刷图 |
| `TAIER_NO_IPV6` | `1` | TUN 下客户端易误判 v6 可用导致耗时翻倍，默认关 |
| `TAIER_REPO` | `MiaM1ku/taierspeedtest` | 引擎仓库 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），三套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；主指标达标数 < 回退门槛且另一指标更多时自动改用另一指标（门槛见下） |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |
| `PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES` | 3 | 判定指标回退门槛：主指标达标数 **< 该值** 且另一指标更多才改判。与 `MIN_NODES` 是两回事 |

订阅导出策略（阈值/判定指标/最少节点数，含回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三套共用)。
注意 taier **上行常测不出**（CDN 类测速点拒绝上传包，引擎渲染 failed → 0），此时上行达标数
远少于下行 ⇒ 自动落到下行判定，通知会显示实际采用的指标。

⚠️ **匹配不上 source_mapping 时靠 `proxy_obj` 兜底**（2026-09-17 补）。`source_entry.proxy`
只在节点名匹配上订阅 source_mapping 时才有值；只认它的旧实现实测踩过 run 35116972319：
8326 个节点里 206 个测出了速度（最高上传 245 Mbps），却全被判「无可用配置」⇒ 达标 0
⇒ **订阅不上传**。现在 `gist_results` 会带上 `proxy_obj`，判定与导出都经
`speedtest_common.node_proxy_config` 取「`source_entry.proxy` 优先、缺失回落 `proxy_obj`」。

⚠️ **但兜底只认「真配置」**（2026-09-26 修正）：`proxy_obj` 若是 mihomo `/providers/proxies`
的**运行时对象**（没有 `server`/`port`/凭据），会被 `is_exportable_proxy` 挡掉——那是对的，
写出装不上的订阅比不写更糟（当轮 25 个空壳客户端加载即报错）。同时，
`source_entry` 大片为空的**根因**（`build_source_mapping` 的 YAML 分支被一行看似链接的节点名
整段跳过）已修，这层回落退化为兜底。细节见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三套共用)。

**测活只有两种世界，没有中间态**（2026-09-24 重写）。判活走 mihomo 的**组测速**：开测前
一次 `GET /group/{组}/delay` 拿整组 `{节点名: 延迟ms}`，逐节点只查这张表：

- **拿不到表**（组探测失败 / 等待未就绪）⇒ 探测层**整体关闭**，全量放行去测速
  （日志 `taier_probe_disabled`）。此时**不产生任何判死条目**——机制没给结论就不能判死；
- **拿到表但覆盖不住待测池** ⇒ 同样关闭探测层、全量放行（日志 `taier_probe_low_coverage`，
  带 `entries` / `total` / `coverage`）。判据是「表条目 ÷ 待测节点数 < 0.5」，理由见下；
- **拿到可信的表** ⇒ 「表里没有该节点」是 mihomo 的**明确判死结论**（它对连不上的节点
  **不给延迟**，不是给 0），计入 `❌ 失败`，错误串带「测活未通过：」前缀以便读者分清
  「测活阶段就死」与「测速阶段失败」。版式约定见
  [通知规范 · 2.8 测速三套](telegram-notify.md#28-测速三套githubscriptsproxy-speedtest)。

⚠️ **为什么必须盯覆盖度**（2026-09-25 加闸门）：mihomo 的组测速在大池下**只返回已测完的
那批**，不是全量覆盖。三轮实测：

| 轮次 | 待测 | 表条目 | 覆盖 | 结果 |
|---|---|---|---|---|
| 单节点轮 36025190562 | 17 | 17 | **100%** | 判死 1 个，可信 |
| 编排轮 35984252872 | 200 | 125 | 62.5% | — |
| 编排轮 36086261741 | 1780 | 65 | **3.7%** | 判死 1777 个，**绝大多数是误杀** |

3.7% 覆盖下「表里没有」根本不是「连不上」，而是**还没轮到**——照判就是把好节点成片砍掉
（那轮只因 3 个在表内，就判其余 1777 个全死）。宁可让死节点各吃一个测速窗口，也不能把活
节点整片误杀，所以覆盖不足时退回 fail-open。这与上面「拿到表才判死」是同一条原则的两道闸：
**机制没给可信结论，就不能判死**。

⚠️ **旧路径（`GET /proxies/{name}/delay`）是一次都没生效过的死代码，已删除**。
根因不是「provider 惰性展开」（2026-09-17 的旧结论，已推翻）：对照组实验证明
**provider 成员从不注册进 `/proxies`** —— 顶层恒为 8 个内置组名（AUTO/COMPATIBLE/DIRECT/
GLOBAL/PASS…），同格式请求下 `/proxies/DIRECT/delay` 正常返回 18ms、而成员名 100% 404，
2 个与 2 万个节点两种池子结果一致 ⇒ **端点格式没错，是路由表里根本没有这个名字**。

这次定案靠**对照实验**（只差一个变量：内置组名 vs provider 成员名），而不是继续加等待：
此前所有「展开等待」的加时（60 → 按加载量放大 → 900 秒）都换不来「等到」，只换来白烧预算
（`waited=900.34 attempts=1810` 全 404），因为等的是一件**永远不会发生**的事。

⚠️ 教训（与 openlist 域同源）：**判据的观测方式会与结论耦合错**。旧判据用「`/proxies` 里
有没有」判「装好没」，而这条路径本身不通 ⇒ 成功永远被判成失败。新判据改成
`/proxies/{组}` 的 `all` 成员清单——**与测速真正走的路径同源**（`switch_proxy` 切的就是这个组），
「等到了」才真的代表能测。

**旧机器一并删除，不要回退**（`is_unknown_proxy_error` / `_revive_probe_failed` / 未知名
重排 / 连续 8 个真死熔断）：它们全是为「逐个探 `/proxies/{name}`（恒 404，机制误伤与真死
无法区分）」设计的兜底。新判据下不存在「中途发现机制坏了」的状态，中途熔断只会把
「一堆死节点」误读成「机制坏了」⇒ 关掉测活 ⇒ 上千死节点各跑满一个测速窗口
（1498 × 15.9s ≈ 6.6h，单这一项吃掉整个 5 小时预算）。测试第 15 组钉住这些机器**不得回归**。

### 为什么 CDN / Gitee 也要等 provider 装进组（2026-09-17 补，2026-09-24 改口径）

taier 是**报错**，CDN / Gitee 是**静默失真**，后者更隐蔽。它们不探活、走 `switch_proxy`
切节点，而 `switch_proxy` PUT 的是 **`AUTO` 这个 select 组**、节点名放在 body 里：

```python
mihomo_api_put(f'/proxies/{quote(PROXY_GROUP_NAME)}', {'name': name})
```

`AUTO` 组一定存在，mihomo 对「组里还没注册的成员名」**不报错、静默保持原选择**——于是
provider 未装填完时，前几个节点测的其实是**上一个**节点的链路，而结果照常记成功、照常进
通知，没有任何痕迹。实测两套的窗口（线上日志）：
gitee 读快照 `23:32:05.426` → 首个 `node_start` `23:32:48.907`（43 秒，安全）；
**cdn 读快照 `23:58:30.528` → 首个 `node_test_start` `23:58:32.041`（仅 1.5 秒）**——
正是 taier 出事的那个时间窗量级。这次没炸只是因为 `AUTO` 组静默兜底。

⚠️ 另有一条已存在的隐患：`switch_proxy` 只看 `mihomo_api_put` 是否抛异常；若将来 mihomo
对「组里不存在的成员」改为报错，两套会立刻把整轮记成 `ok: False` ⇒ 通知全是 `❌ 失败`。
`wait_provider_ready` 把窗口关掉后，这条也一并绕过了。

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
| `nodes_collected: 0` 但 `source_mapping_built` 有值 | 2026-09-15 run 34969408908 的形态：收集层曾只收 provider 里 `alive` 为真的节点，而 `wait_mihomo` 不等健康检查出结论。现已改为全量收集，见 [gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)；先看 `provider_snapshot_collected` 的 `total` / `collected` 是否相等。⚠️ `source_mapping_built entries` 是**可导出配置条数**、不是节点数 |
| **订阅能生成、客户端（Egern 等）加载报错** | 2026-09-26 事故形态：写出去的是空壳（只有 `name`/`type`/`udp`，没有 `server`/`port`）。根因是 `source_mapping` 漏掉整份 YAML 订阅 ⇒ `source_entry` 为空 ⇒ 退回 mihomo 运行时对象，见 [gistnodes 文档](proxy-speedtest-gistnodes.md#为什么-source_mapping-会漏掉整份-yaml-订阅)；出口已由 `is_exportable_proxy` 设防 |
| 通知出现 `⚠️ 疑似未走代理` | TUN 没起来或 `PROCESS-NAME` 规则未命中；查 `mihomo.log` 与 `/dev/net/tun`；结果不可信，整轮判失败 |
| 节点全部「连不上测速点」 | 控制面 `*.cnspeedtest.cn` 经该节点不可达；换节点或检查 mihomo DNS 配置 |
| **run 卡在 in_progress、取消也无效** | TUN 未撤（历史事故）：脚本退出前必须 `stop_mihomo_tun()`；workflow 里有 `always()` 兜底步骤 `pkill "mihomo -d"` |
| 延迟 1 秒以上 | ICMP 经 TUN 不通，回落 TCP tcping（真实握手往返），属预期 |
| 验证 handler | 运行中途 `gh run cancel`：日志应出现两次 `mihomo_tun_stopped`（handler + finally），TG 收到 ⛔ |

上游 duration 钳制 5-13 秒（`main.go`），需要更长测速只能改上游或自编译。
