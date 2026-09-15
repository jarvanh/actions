# CDN 测速（proxy-speedtest-cdn）

> 代码：`.github/scripts/proxy-speedtest/speedtest.py`
> 入口：`.github/workflows/proxy-speedtest-cdn.yml`

## 三件套总览

仓库代理测速三套**按测速点命名**，口径互不可比：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | `speedtest_gitee.py` | [gitee](proxy-speedtest-gitee.md) |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | 本文 | — |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | `taier_speedtest.py` + mihomo TUN | [taier](proxy-speedtest-taier.md) |

调度：UTC 22/02/06/10（北京 06/10/14/18），与 gitee（UTC 21/01/05/09 → 京 05/09/13/17）、taier（UTC 23/03/07/11 → 京 07/11/15/19）各错开 1 小时；三套都只排在北京时间 05:00–21:00（夜间 runner 排队 + 出口拥塞会让读数失真）。

## 功能与链路

对订阅 `PROXY_SPEEDTEST_SUB_URLS` 里 provider 解析出的**每个节点**串行执行（共享 mihomo 内核，
切换后 settle）。不按健康检查 `alive` 预筛——那个判据在订阅大时会读到一个结论都还没有的快照，
把节点收成 0 个，见 [gitee 文档 · 为什么节点收集不等健康检查](proxy-speedtest-gitee.md#为什么节点收集不等健康检查)：

1. **延迟** `latency_probe`（实现在 `speedtest_common.py`，与 gitee 的 gitee.com 延迟探测共用）：
   经代理对 `baidu.com` / `taobao.com` 做 HTTP 完整请求计时，多次采样取中位数
   （反映"打开网页"的真实握手+响应体验）；
2. **下载** `download_speedtest`：经 mixed-port（`127.0.0.1:17892`）**单连接** curl Range
   拉取国内测速点，按耗时换算 MiB/s，多 URL 串行取最优；
3. **上行**（`PROXY_SPEEDTEST_ENABLE_PUSH=1` 时）：复用 gitee 的「经 mihomo 代理 git push」
   方案，单流上传测速文件到 Gitee 私有仓库；
4. 每节点结果写 JSON/HTML，全部完成后 Telegram 推 `✅ CDN 测速完成`（TOP5），
   达标节点订阅导出到本工作流专属 Gist。

### 下载测速点自动发现（规避版本号失效）

不写死具体文件版本，运行时自动解析：

1. 滚动 ISO 索引目录（腾讯云 `mirrors.cloud.tencent.com`、清华 TUNA 的
   `centos/{8,9}-stream/isos/x86_64/`）自动发现 `*-latest-*.iso` 软链；
2. npmmirror 的 dist-tags 实时解析最新 node 版本，拼出 `node-vX-win-x64.zip` 直链；
3. 全部失败时回落写死的 latest 软链兜底（`DEFAULT_DOWNLOAD_URLS`）。

需要固定测速点时显式设 `PROXY_SPEEDTEST_DOWNLOAD_URLS`（逗号分隔）。

## 产出与隐私

- **HTML 报告**（`~/proxy-speedtest/speedtest_report.html`）：自包含可交互图表，
  **含节点完整凭据（server/uuid/订阅地址），仅写运行机本地，绝不入库/外发**；
- **Gist 订阅**：达标节点的原始 proxy 配置整理成 mihomo YAML，节点名前缀
  `↓xx兆 | ↑xx兆 | xxms`，发到本工作流专属 Gist；
- JSON 汇总：`~/proxy-speedtest/speedtest_result.json`。

## 环境变量

### secrets

| secret | 用途 |
|---|---|
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（三套共用） |
| `PROXY_SPEEDTEST_CDN_GIST_ID` | 本工作流专属订阅 Gist 的 id；留空首跑自动新建（TG 给链接），回填避免每轮新建 |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `GITEE_PRIVATE_TOKEN` | 上行测速 push 用（`ENABLE_PUSH=1` 时必需） |
| `PROXY_SPEEDTEST_GITEE_OWNER` | Gitee 私有仓库属主 |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |

被 `proxy-speedtest-gistnodes` 当子流程调用时，结果 Gist 与通知标题可被入参覆盖：
`gist_id` / `gist_filename` / `gist_description` 把结果写进调用方的 Gist，
`label` 给通知标题加来源前缀（如 `✅ gist 节点 · CDN 测速完成`）。
四个入参留空时行为与定时轮完全一致（写本工作流 Gist、标题不带前缀）。

### 可调参数（节选，均可在 workflow env 覆盖）

| env | 默认 | 说明 |
|---|---|---|
| `PROXY_SPEEDTEST_LATENCY_TARGETS` | baidu,taobao | 延迟探测目标 |
| `PROXY_SPEEDTEST_LATENCY_SAMPLES` / `_TIMEOUT` | 4 / 8 | 采样次数 / 单次超时 |
| `PROXY_SPEEDTEST_SIZE_MIB` | 10 | 单次下载字节数（Range 精确拉取） |
| `PROXY_SPEEDTEST_DOWNLOAD_TIMEOUT` / `_DURATION` | 30 / 0 | 单 URL 超时 / 单节点总时长上限 |
| `PROXY_SPEEDTEST_ENABLE_PUSH` | 1（workflow 注入） | 是否测经代理上行 |
| `PROXY_SPEEDTEST_UPLOAD_VIA_PROXY` | 1 | 1=经代理（节点上行）；0=直连（家庭宽带上行） |
| `PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS` | 1.5 | 切节点后等待 |
| `PROXY_SPEEDTEST_MAX_NODES` | 0 | 0 = 不限 |
| `PROXY_SPEEDTEST_BUDGET_SECONDS` | `18000` | **墙钟预算**（秒，`0` = 不限），从进程启动起算。到点不再开下一个节点，拿已测节点照常出订阅（退出码 0）。**与 job 的 `timeout-minutes` 成对**：默认 5 小时 < 360 分钟。workflow 里写死，不接仓库 Variables |
| `PROXY_SPEEDTEST_NPMMIRROR_ENABLED` | 1 | 是否合并 npmmirror 最新版测速点 |
| `PROXY_SPEEDTEST_GIST_FILENAME` / `_DESCRIPTION` | 见 workflow | Gist 文件名/描述（三套区分） |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），三套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；另一指标达标数明显更多时自动改用另一指标（倍率见下） |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |
| `PROXY_SPEEDTEST_METRIC_FALLBACK_RATIO` | 1.5 | 回退倍率：另一指标达标数 ≥ 主指标 × 该值才切换 |

订阅导出策略（阈值/判定指标/最少节点数，含回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三套共用)。

## Telegram 通知

| 标题 | 触发 |
|---|---|
| `✅ CDN 测速完成` | 正常完成（TOP5 + 订阅 Gist 状态） |
| `⚠️ CDN 测速完成` | 0 可用节点，或**到点收摊**（预算用完、本轮没测完） |
| `⛔ CDN 测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），handler 兜底 |
| `❌ CDN 测速异常退出 · <原因>` | mihomo 启动失败 / 节点快照失败（`write_termination`）或未捕获异常，标题带原因首行 |

### 墙钟预算（到点收摊，与 gitee / taier 共用同一判据）

`PROXY_SPEEDTEST_BUDGET_SECONDS`（默认 5 小时）在每个节点**开始之前**检查一次
（`speedtest_common.should_stop_for_budget`）；超预算就 `break`，**退出码仍 0**，照常出报告、
导订阅、发通知。目的是不撞 job 的 360 分钟**硬取消**（那会整轮工作全废、下游全 `skipped`、
订阅来不及提交 Gist）。起算点是**进程启动**，与 `timeout-minutes` 的口径一致。

收摊时通知标题降 `⚠️`，并在「📊 节点」行**紧跟**一行
`⚠️ 本轮已中止：到点收摊：预算 <时长>，已测 N/M 个节点`；`RESULT_JSON` 里对应
`aborted_due_to_runtime` / `runtime_abort_reason`。细则见
[gitee 文档 · 墙钟预算](proxy-speedtest-gitee.md#墙钟预算到点收摊三套共用)。

## 兜底行为（与 gitee/taier 对齐）

- SIGTERM/SIGINT → `⛔` 通知后退出（run 被取消/超时也留痕）；
- mihomo 启动失败 / 节点快照失败 → `write_termination` 发 `❌ … · <原因>` 并写失败报告；
- 未捕获异常 → `__main__` catch-all 发 `❌ … · <异常摘要>`（正文含错误详情）。

本工作流 mihomo **不开 TUN**（流量走 mixed-port 代理），退出无需撤路由。
