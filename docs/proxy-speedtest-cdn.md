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

调度：UTC 03/09/15/21（北京 11/17/23/05），与 gitee（02/08/14/20）、taier（04/10/16/22）错峰。

## 功能与链路

对订阅 `PROXY_SPEEDTEST_SUB_URLS` 的每个可用节点串行执行（共享 mihomo 内核，切换后 settle）：

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
| `PROXY_SPEEDTEST_NPMMIRROR_ENABLED` | 1 | 是否合并 npmmirror 最新版测速点 |
| `PROXY_SPEEDTEST_GIST_FILENAME` / `_DESCRIPTION` | 见 workflow | Gist 文件名/描述（三套区分） |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），三套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；达标数 < 最少节点数时自动改用另一指标 |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |

订阅导出策略（阈值/判定指标/最少节点数，含双向回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三套共用)。

## Telegram 通知

| 标题 | 触发 |
|---|---|
| `✅ CDN 测速完成` | 正常完成（TOP5 + 订阅 Gist 状态） |
| `⛔ CDN 测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），handler 兜底 |
| `❌ CDN 测速异常退出 · <原因>` | mihomo 启动失败 / 节点快照失败（`write_termination`）或未捕获异常，标题带原因首行 |

## 兜底行为（与 gitee/taier 对齐）

- SIGTERM/SIGINT → `⛔` 通知后退出（run 被取消/超时也留痕）；
- mihomo 启动失败 / 节点快照失败 → `write_termination` 发 `❌ … · <原因>` 并写失败报告；
- 未捕获异常 → `__main__` catch-all 发 `❌ … · <异常摘要>`（正文含错误详情）。

本工作流 mihomo **不开 TUN**（流量走 mixed-port 代理），退出无需撤路由。
