# gist 抓节点 → Sub-Store 去重 → 选一套测速（proxy-speedtest-gistnodes）

> 代码：`.github/scripts/proxy-speedtest/gist_nodes.py`
> 入口：`.github/workflows/proxy-speedtest-gistnodes.yml`
> 自检：`.github/scripts/proxy-speedtest/tests/test_gist_nodes_substore.py`

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
   到头、或翻满 `GIST_NODES_MAX_PAGES`（默认 40，安全上限）。
   **为什么要交织而不是先搜完再取**：搜索结果前排混着大量噪声 Gist（正文是 JSON 统计，
   只因含 `ss://` 字样被搜到），它们产出 0 个订阅文件；只有取文后数真订阅才知道够没够，
   固定「先搜 N 个 Gist」的配额要么拿不满、要么白搜一堆。
   关键词「到头」有两个判据：正常返回却一块都没有（翻到末页），或整页全部超龄
   （排序是 `s=updated` 降序，这一页都旧了，后面只会更旧）。**被限流不算到头**；
2. **取文**：GitHub API `GET /gists/{id}` 拿各文件 `raw_url` 再取正文（并发 8 路；
   匿名 60 次/h 会被限流，故带 `PAT`）；
3. **过滤**：只放行「像订阅」的文件——含协议 scheme（`ss://` 等）或 Clash 的 `proxies:` 段，
   或整段 base64 且解出来含 scheme。README / XML plist / 数据 JSON 挡在外面（实测一批
   10 个 Gist 的 50 个文件里只有 16 个是订阅），省下投喂配额与解析时间；
4. **投喂**：每个文件建成一个 Sub-Store **本地内容订阅**（`POST /api/subs`，`source: 'local'`）；
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
7. **发布**：YAML 写进本工作流专属 Gist（`update_gist`），raw URL 作为 `sub_urls` 传给
   选定的测速工作流（`workflow_call` + `secrets: inherit`）。

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
据此分四层应对：

| 层 | 机制 | 作用 |
|---|---|---|
| 1 | `SearchPacer`：页间间隔从 `GIST_NODES_PAGE_DELAY`（默认 3 秒）起，**每被限流一次翻倍**，成功一次折半回落，封顶 `GIST_NODES_PACING_CEILING`（默认 60 秒） | 被限时自动慢下来、恢复后自动提速；跨轮共用同一个实例（限流按出口 IP，是全局状态） |
| 2 | 单页重试 `GIST_NODES_RETRIES`（默认 4）次，退避 `GIST_NODES_BACKOFF_BASE` 指数增长（5/10/20/40 秒）+ 抖动 | 随机限流下重试命中率很高 |
| 3 | **补一轮**：本批被限流跳过的页，批末立刻再试一次 | 调用方下一轮会把 `page_from` 翻过去，不补这一页的结果就永远丢了 |
| 4 | 两轮都失败的页记进 `gist_nodes_search_page_dropped` | 不静默丢：日志能看出丢了哪几页 |

**`Retry-After` 只记不用**：429 响应确实带这个头，但实测值**恒为 `3600`**，而紧接着的
下一个请求就 200——它是静态默认值，不是真实建议。照它睡 1 小时会让 job 直接超时，
所以退避一律走自己的指数曲线，头里的值只打进日志（`retry_after` 字段）作诊断。

**并发。** 编排自己有 workflow 级 `proxy-speedtest-gistnodes-singleton`；被复用的测速工作流沿用它们
各自的 job 级 singleton。**不要**在 caller job 上再加被调工作流的同名 group——GitHub 文档明确警告
caller 与 called 用同一个 group 值会互相影响：`cancel-in-progress: true` 时会把 caller 取消；
`false` 时 caller 持着 group 等被调 job、被调 job 又在等同一个 group，互等到超时。

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
| `GIST_NODES_SORT` | `updated` | 搜索排序 |
| `GIST_NODES_MAX_AGE_HOURS` | `24` | 只收最近 N 小时内更新过的 Gist（`0` = 不限） |
| `GIST_NODES_MAX_SUBS` | `0` | 最多投喂多少个订阅（`0` = 不限） |
| `GIST_NODES_MAX_TOTAL_MB` | `0` | 投喂内容总量上限（`0` = 不限） |
| `GIST_NODES_MAX_FILE_MB` | `2` | 单个文件超过则跳过（工程保护，不是配额） |
| `GIST_NODES_MAX_NODES` | `0` | 最终订阅保留多少节点（`0` = 不限） |
| `GIST_NODES_TIMEOUT` | `30` | 单次 HTTP 超时（秒） |
| `GIST_NODES_RETRIES` | `4` | 单页搜索失败（含 429）时的重试次数 |
| `GIST_NODES_BACKOFF_BASE` | `5` | 重试退避基数（秒），按 5/10/20/40 指数增长 + 抖动 |
| `GIST_NODES_PAGE_DELAY` | `3` | 搜索页翻页的**基础**间隔（秒，另加 0–1 秒随机抖动；`0` = 不间隔） |
| `GIST_NODES_PACING_CEILING` | `60` | 被限流时间隔自动拉长的上限（秒） |
| `GIST_NODES_WORKERS` | `8` | 并发取 Gist 的线程数 |
| `SUB_STORE_BACKEND_URL` | `http://127.0.0.1:3001` | Sub-Store 后端地址 |
| `SUB_STORE_TIMEOUT` | `300` | 调用 Sub-Store 的超时（秒） |
| `SUB_STORE_COLLECTION` | `gist-nodes` | 组合订阅名前缀 |
| `GIST_NODES_DRY_RUN` | `0` | `1` = 只抓取不发布（本地验证用） |

dispatch 入参 `queries` / `max_nodes` / `test_nodes` / `target_subs` / `max_age_hours`
分别覆盖对应项。

## 失败语义

单个 Gist、单个订阅失败只跳过它（统计进日志）；以下情况直接 exit 1：搜索页一个 Gist 都解析不出来、
没有文件像订阅、Sub-Store 不可达、投喂全部失败、产出的不是 YAML、产出零节点、发布 Gist 失败。
**与其让下游拿空订阅跑一轮 45 分钟测速，不如就地失败。**

## 运维与排查

| 现象 | 看哪里 |
|---|---|
| 抓取阶段失败 | 日志里 `gist_nodes_*` 结构化行；`gist_nodes_search_empty` = 某关键词整页没解析出结果 |
| 搜索页 429 | `gist_nodes_search_rate_limited`（含 `retry_after` 字段，只作诊断）/ `gist_nodes_search_deferred_total`（本批被限流跳过的页数 + `recovered` 补回来几个）/ `gist_nodes_search_page_dropped`（两轮都没捞回来，会列出 `ss://#3` 这样的具体页）。`gist_nodes_gather_round` 每轮打一次 `page_delay`，能直接看出节流器把间隔拉到了多少。**它是「一轮能抓多少」的主要瓶颈**——`GIST_NODES_TARGET_SUBS` 是目标不是保证 |
| 某个关键词没产出 | `gist_nodes_search_stale_stop` = 整页超龄（该关键词到头）；`gist_nodes_search_empty` 已不再单独打点，末页由 `gist_nodes_gather_round` 的 `active` 计数下降体现 |
| 去重没生效 | `gist_nodes_dedupe_no_effect`（解析数 ≥ 去重后数）。Sub-Store 对**未知算子只记日志不报错**，先查 `process` 里的算子名拼写 |
| 节点数比预期少 | 先看 `non_sub_files`（判据挡掉了多少）与 `over_quota`（配额挡掉了多少），再看限量 |
| 候选 Gist 太少 | 看 `gist_nodes_search_age_filtered`（时间窗口挡掉多少）与 `gist_nodes_search_stale_stop`（哪个关键词翻到整页超龄）。窗口设太窄时前几页就被判超龄 |
| Sub-Store 侧到底做了什么 | artifact `gist-nodes-<run_id>/sub-store.log`（容器日志尾巴 200 行）与 `nodes.json`（含处理链、计数） |
| 容器起不来 | 该步骤会直接 `docker logs` 打出来；镜像 `xream/sub-store:http-meta`，端口显式指定 3001（镜像默认没设该 env） |

## 自检

```bash
python .github/scripts/proxy-speedtest/tests/test_gist_nodes_substore.py
```

用本地假 Sub-Store 跑通「投喂 → 组合 → 取回 → 发布」并做负向验证（409 / 非 YAML / 不可达必须失败）、
边界验证（`MAX_NODES=0` 不出现限量算子；`MAX_AGE_HOURS=0` 不过滤）、判据验证（明文、base64 放行，
XML plist、数据 JSON 挡掉）与时间窗口验证（超龄挡掉、整页超龄即停止翻页、配额按关键词均分）。
真实容器只在 runner 上起，本地改完靠它兜底；退出码 0 = 全过。
