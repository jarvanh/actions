# gist 抓节点 → Sub-Store 去重 → 选一套测速（proxy-speedtest-gistnodes）

> 代码：`.github/scripts/proxy-speedtest/gist_nodes.py`（健康检查过滤：`alive_filter.py`）
> 入口：`.github/workflows/proxy-speedtest-gistnodes.yml`
> 自检：`.github/scripts/proxy-speedtest/tests/test_gist_nodes_substore.py`
> 　　　`.github/scripts/proxy-speedtest/tests/test_alive_filter.py`（过滤层专测）

## 定位

三套测速（[gitee](proxy-speedtest-gitee.md) / [cdn](proxy-speedtest-cdn.md) / [taier](proxy-speedtest-taier.md)）
原本只吃仓库 secret `PROXY_SPEEDTEST_SUB_URLS` 里的固定订阅源。本工作流给它们**换一个节点来源**：
从 `gist.github.com` 搜索公开节点订阅，去重后产出 mihomo YAML，再交给选定的那套测速。

它自己**不测速、也不发自己的通知**——测速、达标筛选、结果订阅上传 Gist、Telegram 通知全部由
被复用的那套完成。**通知只有一条**（就是被调测速工作流发的那条），但标题会带上来源标签
`gist 节点 · <引擎>测速`，读者能分辨这一轮是谁触发的；标签来自 `PROXY_SPEEDTEST_LABEL`，
不传时标题与定时轮完全一致（规范 · 3.1 允许标题带区分词，见
[telegram-notify.md](telegram-notify.md)）。
**为什么不自己再发一条**：同一轮会出现两条通知，且抓取统计与被调 job 的测速结果分属两个
job，gistnodes 侧拿不到测速结果。抓取情况走 job 摘要与 artifact。

## 引擎选择（环境变量）

| 来源 | 值 | 说明 |
|---|---|---|
| 仓库 Variable `PROXY_SPEEDTEST_ENGINE` | `taier` / `gitee` / `cdn` | 定时运行的默认值 |
| `workflow_dispatch` 入参 `engine` | 同上，另有 `(用仓库 Variable)` | 单次运行覆盖 |

两处都没设 = `taier`。解析在 `Resolve engine` 步骤里做，值经 env 传入而不是拼进脚本
（Variable 是仓库可写值，拼字符串会被引号破坏语法）。

## 链路

1. **搜索 + 取文交织**：每轮对每个关键词翻 `GIST_NODES_PAGES_PER_ROUND` 页（默认 2），
   解析服务端渲染的 `.gist-snippet` 块拿 owner / gist id / 最后活跃时间，只保留最近
   `GIST_NODES_MAX_AGE_HOURS` 小时（默认 24）内更新过的；取文并数出「像订阅」的文件，
   不够 `GIST_NODES_TARGET_SUBS`（默认 100）就继续下一轮，直到凑够、或所有关键词都
   到头、或翻满 `GIST_NODES_MAX_PAGES`（默认 40，安全上限）、或撞上下面两条收口。
   **为什么要交织而不是先搜完再取**：搜索结果前排混着大量噪声 Gist（正文是 JSON 统计，
   只因含 `ss://` 字样被搜到），它们产出 0 个订阅文件；只有取文后数真订阅才知道够没够，
   固定「先搜 N 个 Gist」的配额要么拿不满、要么白搜一堆。
   关键词「到头」有两个判据：正常返回却一块都没有（翻到末页），或整页全部超龄
   （排序是 `s=updated` 降序，这一页都旧了，后面只会更旧）。**被限流不算到头**。
   **另有两条收口，保证一轮不会拖垮 job**：`GIST_NODES_BUDGET_SECONDS`（默认 900 =
   15 分钟）的墙钟预算到点即停；`GIST_NODES_NO_PROGRESS_ROUNDS`（默认 4）轮订阅文件数
   零增长即停。两者都只意味着「抓到的比目标少」，会拿已抓到的文件继续走完 Sub-Store
   产出与发布——**不是失败**（见「失败语义」）；
2. **取文**：GitHub API `GET /gists/{id}` 拿各文件 `raw_url` 再取正文（并发 8 路；
   匿名 60 次/h 会被限流，故带 `PAT`）；
3. **过滤**：只放行「像订阅」的文件——含协议 scheme（`ss://` 等）或 Clash 的 `proxies:` 段，
   或整段 base64 且解出来含 scheme。README / XML plist / 数据 JSON 挡在外面（实测一批
   10 个 Gist 的 50 个文件里只有 16 个是订阅），省下投喂配额与解析时间；
4. **投喂**：每个文件建成一个 Sub-Store **本地内容订阅**（`POST /api/subs`，`source: 'local'`）。
   若开启跨轮累积（`GIST_NODES_CARRYOVER`，默认开），**上一轮发布到本 Gist 的那份订阅**也作为
   一路输入，排在所有抓到的文件**之前**、名字固定 `<名>-000`（理由见「为什么跨轮累积」）；
5. **去重**：建两个组合订阅（`POST /api/collections`）——
   `<名>-raw` 不带处理链（作为「解析后有多少」的参照），`<名>` 带处理链：
   | 顺序 | 算子 | 作用 |
   |---|---|---|
   | 1 | `Useless Filter` | 清掉「剩余流量/到期时间」这类信息节点与非 ASCII 凭据 |
   | 2 | `Handle Duplicate Operator`（`action: delete`） | 按 `field` 组合去重 |
   | 3 | `Handle Duplicate Operator`（`action: rename`） | 重名节点加后缀，保证名字唯一 |
   | 4 | `Script Operator` | `proxies.slice(0, N)` 限量（仅当 `GIST_NODES_MAX_NODES > 0`） |
6. **取回**：`GET /download/collection/<名>/ClashMeta` 拿 mihomo YAML；同时取 `<名>-raw` 的
   `JSON` 只用来数节点，得到「解析后 N → 去重后 M」这个可核对口径；
7. **健康检查**（`GIST_NODES_ALIVE_FILTER`，默认开）：在发布**之前**起一个本地 mihomo
   （独立端口 19090 / 17892，与测速共用同一份内核二进制与配置语义），把去重后的节点切成
   **分片 provider**（每片 `FILTER_SHARD_SIZE` = 200 个，`shard-NNNN.yaml`）载入、
   `lazy: false` 全量探测，只保留判活的节点再发布。详见下面「为什么发布前必须自己先测活」；
8. **发布**：YAML 写进本工作流专属 Gist（`update_gist`），raw URL 作为 `sub_urls` 传给
   选定的测速工作流（`workflow_call` + `secrets: inherit`）。

## 为什么发布前必须自己先测活

下游三套测速拿到这份 Gist 当订阅源后，会各自起 mihomo、按 provider **非惰性**健康检查
所有节点。节点上万时那一步根本跑不完。实测 2026-09-15 run 34928929882：

| 证据 | 值 |
|---|---|
| 本工作流发布 | `gist_nodes_published bytes: 4278592`（12635 个节点，raw 匿名可读、`yaml.safe_load` 也是 12635） |
| 泰尔侧认到的节点 | `source_mapping_built entries: 14` |
| 从开跑到 mihomo 配好 | `taier_speedtest_started 04:44:05.25` → `mihomo_tun_config_built 04:44:07.75` = **1.67 秒** |

1.67 秒不可能下完 4.27MB、载入 12635 个节点、再给每个节点跑完一轮健康检查。也就是说
**瓶颈是规模，不是下载 / 鉴权 / TUN**：下游读快照时只看到最先出结论的一小撮节点。

（附带排除掉的两个猜测：「TUN 破坏健康检查」不成立——不带 TUN 的 gitee 定时轮同样只认到
13 个；而泰尔那轮反而拿到 53 个，比 gitee / cdn 都多。「secret Gist 需要鉴权」也不成立
——匿名请求带 User-Agent 即 200。）

所以把规模压在上游：这里先筛一遍，下游 Gist 里就是几百个活节点，它自己的健康检查能在
秒级完成。

**为什么 `lazy: false` 必须是这个值**（这一层自己生成的那份 config）：`lazy: true` 的
provider 只在被显式请求时才探活，`/providers/proxies` 里所有节点的 `alive` 会**一直缺失**，
这一层就永远等不到结论、只能 fail-open 放行全部——等于白跑。

**为什么必须分片，不能只建一个 provider。** mihomo 对 provider 是「全有或全无」：片里
只要有一个节点解析失败，整个 provider 的 `proxies` 就变成 `[]`。这不是理论风险——2026-09-15
首次实跑（run 34949717315）发布的那份 13620 节点里，proxy 11 就是 `invalid REALITY short
ID`，单 provider 方案下**整层过滤归零**。切 200 一片后，实测坏片只剩 3/69（`shard-0040` /
`shard-0038` / `shard-0015`），其余照常判活。

坏片的节点在快照里**根本不出现**，于是按名字匹配不上 → 归入 `unmatched` → **保留**。
这与「只丢明确死结论」是同一原则：查不到结论 ≠ 判死。

**为什么 provider 文件必须写在当前用户的 home 内。** mihomo 拒绝加载 home 之外的 provider
文件，报 `path is not subpath of home directory or SAFE_PATHS`，而且是 `level=fatal` ——
**进程直接退出、控制器根本不监听**。同一次 run 就是因为本层把 provider 写进了
`GIST_NODES_WORKDIR`（= 仓库工作区，在 home 外），于是 `wait_mihomo` 空等 60 秒、报成
`mihomo_start_failed: Connection refused`，真因（配置被拒）被完全掩盖。

两处加固：`_safe_home_dir` 不信任调用方传进来的路径、越界就改落 home 内并打
`alive_filter_workdir_relocated`；`_dump_mihomo_log` 在**任何** fail-open 时把 mihomo 日志
尾部吐进 progress 流——否则这类「进程静默退出」的真因只能靠猜。

**降级方向是「放行全部」，不是「失败」**：mihomo 起不来、预算耗尽、API 报错一律原样
发布全部节点并记 `alive_filter_skipped`。这一层存在的意义是把规模压下去，它自己故障时
退回到「不做过滤」正是过滤引入之前的既有行为——那当然可能重演 12635 个节点，但比
**零节点发布**（下游连测都没得测）好得多。同理，若**全部节点都判死**，脚本会记
`alive_filter_all_dead_fallback` 并原样发布：全死极可能是探测目标本身不可达，把
「目标挂了」错读成「节点都死了」不该导致零产出。

判据上只有「mihomo 给出明确死结论」才丢节点；**查不到结论的（重名、被改名、还没探完）
一律保留**——过滤只该丢明确判死的，不该丢「说不清」的。

## 过滤相关环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `GIST_NODES_ALIVE_FILTER` | `1` | `0` = 关掉过滤，原样发布（回退到引入过滤之前的行为） |
| `GIST_NODES_ALIVE_BUDGET_SECONDS` | `600` | 过滤阶段墙钟预算；到点未跑完 → 原样发布全部 |
| `GIST_NODES_ALIVE_TIMEOUT` | `120` | 单次读 `/providers/proxies` 的超时（上界由上面的预算兜） |
| `PROXY_SPEEDTEST_HEALTHCHECK_URL` | `https://www.gstatic.com/generate_204` | 探测目标。**必须与下游测速同值**，否则这里判活、下游判死 |

## 为什么这么设计

**为什么去重与格式转换交给 Sub-Store，而不是在脚本里做。** 节点链接 → 各内核配置对象的
还原规则（每种协议的字段、TLS/传输层语义、去重判据）是 Sub-Store 的领域知识；脚本只负责
搬运——搜索、取文、投喂、取回。这样既不必在仓库里养一份容易过时的协议实现，产物也与
Sub-Store 网页端手工导出的完全同源。

**为什么临时起一个容器，而不是复用 `sub-store.yml` 那套。** 那套是给网页端用的常驻服务：
绑隧道、单宿主、靠「隧道已有连接就 exit 0 让位」保证不重复。本工作流只需要一个本机 HTTP
接口，所以 `docker run` 起一个用完即删的实例，只发布到 `127.0.0.1`，不碰隧道也不碰它的数据卷。
订阅名固定（`gist-nodes-001`…），若撞名会拿到 409 并明确报「容器不是全新的」——这是刻意的：
每轮都必须是干净容器，否则上一轮的订阅会混进结果。

**为什么限量必须存在。** 下游 mihomo 的 provider 配的是**非 lazy 健康检查**：订阅里有多少
节点，启动时就探多少个。gist 抓来的聚合列表去重后常有几千个，会让每轮测速多花几分钟做无谓
探测，而引擎实际只测 `test_nodes` 个。限量用 Script Operator 而不是在脚本里截断 YAML，
是为了让产出保持完全由 Sub-Store 生成。

**为什么去重字段不含 `name`。** 同一个节点在不同 Gist 里名字几乎必然不同，带上名字就等于
不去重。字段取 `type/server/port/`凭据`/`传输层特征`——同机同端口同凭据但传输层不同视为
不同节点（保守，宁可少去重也不误删）。

**为什么经 Gist 中转、而不是把节点塞进入参。** 节点列表几十到几百 KB，`workflow_call` /
`workflow_dispatch` 的入参不适合承载大文本；raw URL 是一个短字符串，下游 `fetch_text` 直接
GET 即可（secret Gist 的 raw URL 无需鉴权——不可猜的 URL 本身就是凭据，已实测匿名 200）。

**为什么用 `workflow_call` 而不是 `gh workflow run` 另起一轮。** 单轮内串起来跑，日志/耗时/
失败原因都在同一个 run 里；另起一轮还要 PAT 具备 Actions 写权限，且抓取结果与测速轮次会脱钩。

**为什么要卡「最近 24 小时」这个窗口。** Gist 搜索命中的很多是早已停更的旧订阅，里面的节点
多半已经失效，测一轮纯属浪费。但窗口**挡不住**另一类噪声：搜索结果按 updated 排序时，前排会被
一批「每分钟都在更新的统计/日志 Gist」占满——实测排在最前的几个正文是 `arminta_stats.json`、
`sla_data.json` 这种，只因为碰巧含 `ss://` 字样就被搜到，而且它们更新最勤、永远排在最前。
这类噪声靠第 3 步的订阅判据挡掉，时间窗口对它无效。

**调度为什么是每天 4 次、京 08/12/16/20。** 刻意避开三套测速的定时轮（gitee 京
05/09/13/17、cdn 06/10/14/18、taier 07/11/15/19）：本工作流抓完节点会**直接调用**其中
一套来测速，撞点会互相抢节点带宽、读数彼此污染。仍只排在北京 05:00–20:00：夜间 runner
排队 + 出口拥塞会让测速读数失真。

**怎么扛搜索页 429。** 先纠正一个容易想错的前提：搜索页的 429 **不是「封禁一段时间」，
而是「当前窗口内按请求随机拒」**——实测连打 12 次得到 `429,200,200,429,429,200,...`，
同一个 URL 上一秒被拒、下一秒就成功。它同时也是**唯一**的发现入口
（`github.com/search?type=gists` 是登录墙，带 token 请求搜索页也没有特殊配额）。
据此分五层应对：

| 层 | 机制 | 作用 |
|---|---|---|
| 1 | `SearchPacer`：页间间隔从 `GIST_NODES_PAGE_DELAY`（默认 3 秒）起，**每被限流一次翻倍**，成功一次折半回落，封顶 `GIST_NODES_PACING_CEILING`（默认 60 秒） | 被限时自动慢下来、恢复后自动提速；跨轮共用同一个实例（限流按出口 IP，是全局状态） |
| 2 | 单页重试 `GIST_NODES_RETRIES`（默认 4）次，退避 `GIST_NODES_BACKOFF_BASE` 指数增长（5/10/20/40 秒）+ 抖动 | 随机限流下重试命中率很高 |
| 3 | **补一轮**：本批被限流跳过的页，批末立刻再试一次 | 调用方下一轮会把 `page_from` 翻过去，不补这一页的结果就永远丢了 |
| 4 | 两轮都失败的页记进 `gist_nodes_search_page_dropped` | 不静默丢：日志能看出丢了哪几页 |
| 5 | **批内熔断** `GIST_NODES_MAX_CONSECUTIVE_LIMITED`（默认 3）：同一批里连续这么多页都是 429，就中止本批剩余页、**并跳过「补一轮」** | 限流按出口 IP、是全局状态，连续多页全中说明正处在窗口期，此时再打就是撞同一堵墙。这一层是纯止血：实测某批 10 页全中，单批吃掉 **988 秒**（16.5 分钟，占 job 预算一半），其中约 850 秒花在重试退避与「补一轮」里那个被封顶到 60 秒的节流等待上 |

**`Retry-After` 只记不用**：429 响应确实带这个头，但实测值**恒为 `3600`**，而紧接着的
下一个请求就 200——它是静态默认值，不是真实建议。照它睡 1 小时会让 job 直接超时，
所以退避一律走自己的指数曲线，头里的值只打进日志（`retry_after` 字段）作诊断。

**为什么每个阶段都要有自己的墙钟预算，而 `timeout-minutes` 只是最后兜底。** 四段各有一个
预算，都显著小于 job 的 30 分钟：

| 段 | 预算 | 到点怎么办 |
|---|---|---|
| 抓取 | `GIST_NODES_BUDGET_SECONDS`（默认 900 秒） | 停翻页，拿已抓到的文件继续走产出 |
| Sub-Store 投喂 | `SUB_STORE_BUDGET_SECONDS` 的**一半**（默认 150 秒） | 停投喂，拿已投喂的继续走产出 |
| Sub-Store 产出 | 同上的**另一半**（默认 150 秒） | exit 1（建组合/取回省掉就没有产物） |
| 健康检查 | `GIST_NODES_ALIVE_BUDGET_SECONDS`（默认 600 秒） | 原样发布全部节点（过滤层是降级手段，不该让下游零节点） |

于是最坏 `0.4（检出）+ 15（抓取）+ 5（Sub-Store）+ 10（健康检查）≈ 30.4 分钟` —— **已经贴着
`timeout-minutes: 30`**，改任何一个都要回头看这两个数字（顺带：健康检查段只在
`GIST_NODES_ALIVE_FILTER=1` 时才占时间）。

**两个阶段的实测值**（`gist_nodes_gather_stop` / `gist_nodes_substore_phase`，2026-09-14
run 34834036756 —— 这条链路第一次跑通）：抓取 **323.4 秒**，由「连续零增长」提前收口，
900 秒预算没用满；Sub-Store 段 **5.8 秒**（60 个订阅投喂 + 2 次建组合 + 2 次取回，预算
300 秒）⇒ 目前是 **50 倍余量**。**暂不收紧**：只有一个样本，而压小它的代价是把「合法但慢」
误判成失败——这条链路此前连一次成功记录都没有，样本会随轮次自然积累。下次调这两个数字以
这两个日志字段为准，别拍脑袋。

**为什么不能只靠 `timeout-minutes`**：它是 GitHub 的**硬取消**，被取消时整个 job 的工作全废
——抓取到的几十个订阅文件、Sub-Store 已投喂的订阅、以及下游三个测速 job（全部 `skipped`）。
2026-09-14 有三次运行就是这么废掉的（34800369606 / 34808992495 / 34827324756，都是抓取阶段
空转到 30 分钟被取消；最后一次的 `page_from=17` 那一轮单独吃掉 1250 秒）。所以天花板只当
兜底，真正的收口放在每个阶段的预算里，并且**优先降级、其次才失败**。

顺带一个教训：`timeout-minutes: 30` 当初是按「20 不够」反推的量级估计，**没有任何一次成功的
分段耗时做支撑**（这条链路当时还没跑完整过）。「无界的阶段 + 拍出来的天花板」这个组合必然撞车
——所以给阶段加预算的同时，也让脚本把每段的真实耗时打进日志（`gist_nodes_gather_stop` 的
`elapsed` / `gist_nodes_substore_phase` 的 `elapsed`），下次调这几个数字就有依据了。

**并发。** 编排自己有 workflow 级 `proxy-speedtest-gistnodes-singleton`；被复用的测速工作流沿用它们
各自的 job 级 singleton。**不要**在 caller job 上再加被调工作流的同名 group——GitHub 文档明确警告
caller 与 called 用同一个 group 值会互相影响：`cancel-in-progress: true` 时会把 caller 取消；
`false` 时 caller 持着 group 等被调 job、被调 job 又在等同一个 group，互等到超时。

**为什么跨轮累积。** 抓到的订阅只在当轮有效：Gist 里的搜索结果是别人维护的，一轮抓到的
几十个文件下一轮未必还落在时间窗口里；若某一轮恰好抓得少（被限流、预算到点），**被测节点集合
就会凭空缩水**——而上一轮明明已经产出了一份去重好的 `providers.yaml`。所以默认把**上一轮发布到
本 Gist 的那份订阅**也当一路输入喂回 Sub-Store，与当轮抓到的文件一起参与去重与取回。

几条约束是刻意的：

- **累积排在所有抓到的文件之前**（名字固定 `<名>-000`）。投喂有预算、可能被截断
  （`gist_nodes_push_budget_stop`），排在前面才能保证「最该在的那份」不被截掉。
- **必须在发布之前取**。`update_gist` 会覆盖同一个文件，取晚了拿到的是**本轮**的产物，
  累积就退化成「原样再喂一遍」。
- **走 `raw_url` 而不是 Gist API 的 `files[..].content`**：后者对大于 1MB 的文件会**截断**
  并置 `truncated: true`，而这份订阅现在就有 1.07MB。截断的 YAML 要么解析失败、要么静默少一批节点。
- **超上限整段跳过**（`GIST_NODES_CARRYOVER_MAX_MB`，默认 8MB）。宁可这一轮不累积，也不能把
  截断过的 YAML 当完整订阅喂进去——那会让「累积」变成悄悄丢节点。
- **任何失败都只跳过、不失败**（首次运行本来就没有这个文件）。累积是增益项，不能因为它把整轮拖垮。

## 环境变量

### secrets

| 名字 | 用途 |
|---|---|
| `PAT` | GitHub API 认证（拉 Gist 正文）+ Gist 写入（默认 `GITHUB_TOKEN` 无 gist 作用域） |
| `PROXY_SPEEDTEST_GISTNODES_GIST_ID` | 本工作流专属 Gist 的 id。留空则首次运行自动新建，job 摘要给链接，拿到 id 后回填 |
| 其余 | 由被复用的测速工作流自己读（`PROXY_SPEEDTEST_SUB_URLS` 会被 `sub_urls` 覆盖） |

Gist 分工：`gitee` / `cdn` / `taier` 三套各自的 Gist 只装**它们定时轮**的测速结果；
本工作流专属的那个 Gist 装**这一轮 gist 抓取的全部产物**，靠文件名区分，互不覆盖：

| 文件 | 谁写 | 内容 |
|---|---|---|
| `proxy_speedtest_gistnodes_providers.yaml` | 本工作流 | 抓来 + 去重后的**源节点**订阅（作为 `sub_urls` 传给被调测速工作流） |
| `proxy_speedtest_gistnodes_result_<引擎>.yaml` | 被调测速工作流 | 该轮**达标节点**的测速结果订阅 |

被调工作流怎么写进别人的 Gist：三套的 `workflow_call` 都有 `gist_id` / `gist_filename` /
`gist_description` / `label` 四个入参，本工作流在 `with:` 里传本 Gist 的 id（来自
`fetch-nodes` 的 `gist_id` output）。留空时它们照旧写自己的 secret 指向的 Gist——
所以**三套测速的定时轮完全不受影响**，仍吃仓库 secret `PROXY_SPEEDTEST_SUB_URLS`
里的固定订阅源、仍写各自的 Gist。

### 可调参数（均有默认值）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GIST_NODES_QUERIES` | `ss://,vless://,vmess://,trojan://,hysteria2://,tuic://` | 搜索关键词 |
| `GIST_NODES_TARGET_SUBS` | `100` | 目标：凑够多少个「像订阅」的文件（`0` = 不限） |
| `GIST_NODES_MAX_PAGES` | `40` | 每个关键词最多翻几页（安全上限） |
| `GIST_NODES_PAGES_PER_ROUND` | `2` | 每轮每个关键词翻几页 |
| `GIST_NODES_BUDGET_SECONDS` | `900` | 抓取阶段的**墙钟预算**（秒，`0` = 不限）。到点收摊、拿已抓到的文件继续产出。**与 job 的 `timeout-minutes`（30 分钟）成对**，改一个要回头看另一个 |
| `GIST_NODES_NO_PROGRESS_ROUNDS` | `4` | 连续多少轮订阅文件数零增长就收摊（`0` = 不限） |
| `GIST_NODES_MAX_CONSECUTIVE_LIMITED` | `3` | 同一批连续多少页被限流就熔断本批、并跳过「补一轮」（`0` = 不限） |
| `GIST_NODES_SORT` | `updated` | 搜索排序 |
| `GIST_NODES_MAX_AGE_HOURS` | `24` | 只收最近 N 小时内更新过的 Gist（`0` = 不限） |
| `GIST_NODES_MAX_SUBS` | `0` | 最多投喂多少个订阅（`0` = 不限） |
| `GIST_NODES_MAX_TOTAL_MB` | `0` | 投喂内容总量上限（`0` = 不限） |
| `GIST_NODES_MAX_FILE_MB` | `2` | 单个文件超过则跳过（工程保护，不是配额） |
| `GIST_NODES_MAX_NODES` | `0` | 最终订阅保留多少节点（`0` = 不限） |
| `GIST_NODES_CARRYOVER` | `1` | 是否把**上一轮发布到本 Gist 的订阅**也当一路输入喂回 Sub-Store。首次运行还没有这个文件时自动跳过 |
| `GIST_NODES_CARRYOVER_MAX_MB` | `8` | 累积订阅的大小上限（MB）。超了整段跳过并记日志——宁可这一轮不累积，也不把**截断过的** YAML 当完整订阅喂进去。**与容器的 `SUB_STORE_BODY_JSON_LIMIT`（16mb）成对**：投喂是「整份正文塞进 JSON」，把它抬过 ~14 就会撞 413 |
| `GIST_NODES_TIMEOUT` | `30` | 单次 HTTP 超时（秒） |
| `GIST_NODES_RETRIES` | `4` | 单页搜索失败（含 429）时的重试次数 |
| `GIST_NODES_BACKOFF_BASE` | `5` | 重试退避基数（秒），按 5/10/20/40 指数增长 + 抖动 |
| `GIST_NODES_PAGE_DELAY` | `3` | 搜索页翻页的**基础**间隔（秒，另加 0–1 秒随机抖动；`0` = 不间隔） |
| `GIST_NODES_PACING_CEILING` | `60` | 被限流时间隔自动拉长的上限（秒） |
| `GIST_NODES_WORKERS` | `8` | 并发取 Gist 的线程数 |
| `SUB_STORE_BACKEND_URL` | `http://127.0.0.1:3000` | Sub-Store **后端 API** 地址。是 **3000** 不是 3001：镜像 `xream/sub-store:http-meta` 的默认布局是「后端 3000 / 前端 http-meta 3001」，指到 3001 会打到前端上并拿到 Express 的 404 `Cannot GET /api/subs` |
| `SUB_STORE_TIMEOUT` | `300` | **单次**调用 Sub-Store 的超时（秒）。**刻意保持不动**：没有真实的 Sub-Store 分段耗时，压小它只会误杀「合法但慢」的取回；这一段的总时长由下面那行负责 |
| `SUB_STORE_BUDGET_SECONDS` | `300` | 整个 Sub-Store 阶段的**墙钟预算**（秒，`0` = 不限）。一半给投喂、一半留给产出 |
| `SUB_STORE_COLLECTION` | `gist-nodes` | 组合订阅名前缀 |
| `GIST_NODES_ALIVE_FILTER` | `1` | 发布前是否先做健康检查、只发布活节点（见「为什么发布前必须自己先测活」） |
| `GIST_NODES_ALIVE_BUDGET_SECONDS` | `600` | 健康检查阶段的**墙钟预算**（秒，`0` = 不限）。到点未跑完 → 原样发布全部 |
| `GIST_NODES_ALIVE_TIMEOUT` | `120` | 单次读 `/providers/proxies` 的超时（秒）。上界由上面的预算兜 |
| `GIST_NODES_DRY_RUN` | `0` | `1` = 只抓取不发布（本地验证用）。**dry-run 会同时关掉健康检查**（那要另下几十 MB 的 mihomo 再占 10 分钟，与「本地快速验证」相悖）；想单独验过滤用 `GIST_NODES_ALIVE_FILTER=1` |

dispatch 入参 `queries` / `max_nodes` / `test_nodes` / `target_subs` / `max_age_hours`
分别覆盖对应项。

## 失败语义

单个 Gist、单个订阅失败只跳过它（统计进日志）；以下情况直接 exit 1：搜索页一个 Gist 都解析不出来、
没有文件像订阅、Sub-Store 不可达、投喂全部失败、产出的不是 YAML、产出零节点、发布 Gist 失败。
**与其让下游拿空订阅白跑一轮长测速（几小时起），不如就地失败。**

**但「到点收摊」不是失败。** 墙钟预算耗尽（`gist_nodes_gather_stop` 的 `reason=budget`）
或连续多轮零增长（`reason=stall`）都只是「抓到的比目标少」，仍会拿已有的文件走完
Sub-Store 产出与发布。为什么必须把这两者分开：job 超时是 GitHub **硬取消**，被取消时
连已经抓到的几十个订阅文件也一起作废、下游三个测速 job 全 `skipped`，一次运行白跑；
宁可少几个节点，也不要整轮报废。

**Sub-Store 阶段的降级方向相反，要分两段看**（`SUB_STORE_BUDGET_SECONDS`）：

| 段 | 预算耗尽时 | 为什么 |
|---|---|---|
| 投喂（逐个 `POST /api/subs`） | **停投喂，拿已投喂的继续走产出**（退出码 0） | 少几个订阅文件只是少几个节点，日志 `gist_nodes_push_budget_stop` 会给出截断计数 |
| 建组合 / 取回（各一次调用） | **就地 exit 1** | 这两步省掉就完全没有产物，失败是对的——同下面「不如就地失败」 |

不给产出留额度的话，投喂（全段唯一无界的部分）能把预算吃光，然后卡在建组合上 →
「投喂成功却产不出订阅」，比少投喂几个更糟。所以预算**一半给投喂、一半留给产出**。

## 运维与排查

| 现象 | 看哪里 |
|---|---|
| 抓取阶段失败 | 日志里 `gist_nodes_*` 结构化行；`gist_nodes_search_empty` = 某关键词整页没解析出结果 |
| Sub-Store 阶段到点 | `gist_nodes_substore_phase`（本段耗时 / 预算 / 投喂数，**这一段以前完全没有耗时数据**）/ `gist_nodes_push_budget_stop`（投喂被截断：`pushed` 已投喂数 + `remaining` 没投的数量）。退出码 1 且 `gist_nodes_failed` 的文案含「预算」= 产出段（建组合/取回）预算耗尽，不是后端故障 |
| 没凑够目标就收摊 | `gist_nodes_gather_stop`（`reason=budget` = 墙钟预算耗尽；`reason=stall` = 连续多轮零增长）。**这是正常收尾，不是故障**——`GIST_NODES_TARGET_SUBS` 是目标不是保证；先看 `gist_nodes_sources` 的 `stop_reason` / `rounds` / `elapsed` / `files` |
| 一整批页被跳过 | `gist_nodes_search_batch_aborted`（连续 N 页被限流触发熔断，本批剩余页一个都不打）/ `gist_nodes_search_deferred_skipped`（`reason=batch_aborted` = 熔断不补一轮，`reason=budget` = 预算到点不补）。见到它们说明那一轮正处在限流窗口里，别当成抓取失败 |
| 搜索页 429 | `gist_nodes_search_rate_limited`（含 `retry_after` 字段，只作诊断）/ `gist_nodes_search_deferred_total`（本批被限流跳过的页数 + `recovered` 补回来几个）/ `gist_nodes_search_page_dropped`（两轮都没捞回来，会列出 `ss://#3` 这样的具体页）。`gist_nodes_gather_round` 每轮打一次 `page_delay`，能直接看出节流器把间隔拉到了多少。**它是「一轮能抓多少」的主要瓶颈**——`GIST_NODES_TARGET_SUBS` 是目标不是保证 |
| 某个关键词没产出 | `gist_nodes_search_stale_stop` = 整页超龄（该关键词到头）；`gist_nodes_search_empty` 已不再单独打点，末页由 `gist_nodes_gather_round` 的 `active` 计数下降体现 |
| 去重没生效 | `gist_nodes_dedupe_no_effect`（解析数 ≥ 去重后数）。Sub-Store 对**未知算子只记日志不报错**，先查 `process` 里的算子名拼写 |
| 节点数比预期少 | 先看 `non_sub_files`（判据挡掉了多少）与 `over_quota`（配额挡掉了多少），再看限量 |
| 候选 Gist 太少 | 看 `gist_nodes_search_age_filtered`（时间窗口挡掉多少）与 `gist_nodes_search_stale_stop`（哪个关键词翻到整页超龄）。窗口设太窄时前几页就被判超龄 |
| 累积没生效 | `gist_nodes_carryover`（取到了，带 `bytes` / `filename`）/ `gist_nodes_carryover_skipped`（带 `reason`：`missing_gist_id_or_filename` 缺 env、`gist_probe_failed` Gist 探测失败、`no_previous_file` 上一轮还没发布过、`fetch_failed` 取文失败、`oversize` 超 `GIST_NODES_CARRYOVER_MAX_MB`、`empty` 正文为空）。**首次运行必然是 `no_previous_file`，不是故障**；`nodes.json` 的 `substore.carryover` 也记了 `enabled` / `used` / `bytes` / `max_bytes` |
| Sub-Store 侧到底做了什么 | artifact `gist-nodes-<run_id>/sub-store.log`（容器日志尾巴 200 行）与 `nodes.json`（含处理链、计数） |
| 容器起不来 | 该步骤会直接 `docker ps -a` / `docker port` / `docker logs` 打出来。镜像 `xream/sub-store:http-meta` 的默认布局是「后端 3000 / 前端 http-meta 3001」，我们只发布后端 3000、**不设** `SUB_STORE_BACKEND_API_PORT`/`_HOST`（设成 3001 会让后端去抢前端已占的端口，`EADDRINUSE` 起来就死）。该步骤另外**要设** `SUB_STORE_BODY_JSON_LIMIT=16mb` 与 `SUB_STORE_FRONTEND_BACKEND_PATH=/`，理由见下面两行 |
| 投喂时成片 `HTTP 413 PayloadTooLargeError` | 撞了 Sub-Store 的请求体上限，即 `SUB_STORE_BODY_JSON_LIMIT`——**默认只有 `1mb`**（见 `backend/src/vendor/express.js`），workflow 里已抬到 `16mb`。就绪探测还会核对容器日志里的 `[BACKEND] body JSON limit: 16mb`，对不上直接失败（env 名来自第三方镜像，被改名只会静默退回 1mb，而 413 只记进 `subs_failed` 计数、job 照样「成功」）。若只是个别订阅 413：看 `gist_nodes_sub_failed` 是哪几个（`gist-nodes-000` 就是累积那份） |
| 取回组合时 `HTTP 500 … 必须设置 SUB_STORE_FRONTEND_BACKEND_PATH` | 组合里带了 Script Operator（限量算子，**仅当 `GIST_NODES_MAX_NODES > 0` 才生成**）而容器没设 `SUB_STORE_FRONTEND_BACKEND_PATH`——Node 下的硬前置，见 `backend/src/core/proxy-utils/index.js` 的 `loadScriptItem`。只在本机回环上跑、不对外暴露，直接设 `/`。⚠️ `GIST_NODES_MAX_NODES=0` 的轮次根本不生成脚本算子，**所以这条路径很容易被漏测**（2026-09-14 run 34840068571 带 `max_nodes=100` 才炸出来） |
| 就绪探测失败（`HTTP 000` 或非 200） | 探测要求 `GET /api/subs` **恰好 200**，判据与脚本一致（早先用 `curl -fsS`，302 也算通过 ⇒ 探测绿了脚本红）。`000` = 连不上（容器没起来），`404` = 端口指到了前端 |

## 自检

```bash
python .github/scripts/proxy-speedtest/tests/test_gist_nodes_substore.py
python .github/scripts/proxy-speedtest/tests/test_alive_filter.py
```

**`test_gist_nodes_substore.py`** 用本地假 Sub-Store 跑通「投喂 → 组合 → 取回 → 发布」并做负向验证
（409 / 非 YAML / 不可达必须失败）、边界验证（`MAX_NODES=0` 不出现限量算子；`MAX_AGE_HOURS=0` 不过滤）、
判据验证（明文、base64 放行，XML plist、数据 JSON 挡掉）、时间窗口验证（超龄挡掉、整页超龄即停止翻页）
与**抓取收口验证**（墙钟预算 / 零增长 / 批内熔断各自生效；三者都配了「关闭该收口 → 一路翻满
`GIST_NODES_MAX_PAGES`」的负向对照，否则判据恒真也看不出来）与 **Sub-Store 阶段预算验证**
（投喂预算耗尽 → 截断投喂但仍产出、退出码 0；产出预算耗尽 → 退出码 1 且失败文案指向预算；两者各配
负向对照）与**跨轮累积验证**（累积以 `-000` 先投喂并进组合、`files_found` 含它而 `files_gathered`
只算抓到的；负向对照：关掉累积 / 上一轮没文件时都不多投喂；并直接调真实的 `fetch_carryover` 覆盖
成功与五条跳过分支，含「正文正好等于上限必须放行、多 1 字节必须挡下」的大小边界）。
真实容器只在 runner 上起，本地改完靠它兜底；退出码 0 = 全过。
**它不覆盖健康检查过滤**（要另下几十 MB 的 mihomo 并等一个 10 分钟预算），那些轮次统一用
`GIST_NODES_ALIVE_FILTER=0` 关掉——顺带也证明这个开关真的能关掉过滤。

**`test_alive_filter.py`** 用假 mihomo 专测过滤层的隐蔽坏法：判据反了（把「还没出结论」
当「死」，静默丢掉一大半活节点）、fail-open 失效（起不来/超时/API 报错时抛异常 ⇒ 零节点发布）、
全判死没兜底、稳定判据过早（mihomo 刚起来就 break ⇒ 等于没过滤）。覆盖：只丢明确判死的、
没结论的保留、结论不增长即收尾、冷启动宽限、三种 fail-open 各自的 `skip_reason`、
全判死如实上报（让 `gist_nodes` 的 `all_dead` 回退能触发）、空输入不启动 mihomo、
`AUTO`/`default` 不算数、写进 provider 的必须是**过滤前**的全量且 `lazy: false`、
**坏片不影响好片**（整片加载失败时那片节点按 `unmatched` 保留）、
**fail-open 时必须吐出 mihomo 日志真因**、以及
**workdir 越界改落 home 内**（这条是首次实跑翻车后补的回归）。
