# Speedtest 官方测速点（proxy-speedtest-ookla）

> 代码：`.github/scripts/proxy-speedtest/speedtest_ookla.py`
> 入口：`.github/workflows/proxy-speedtest-ookla.yml`

## 四件套总览

仓库代理测速四套**按测速点命名**，口径互不可比（单流 vs 多连接 vs 官方自适应测量）：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | `speedtest_gitee.py` | [gitee](proxy-speedtest-gitee.md) |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | `speedtest.py` | [cdn](proxy-speedtest-cdn.md) |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | `taier_speedtest.py` + mihomo TUN | [taier](proxy-speedtest-taier.md) |
| `proxy-speedtest-ookla` | Speedtest 官方测速点（按节点出口就近，可显式锁编号） | speedtest CLI 延迟 + 上下行 | 本文 | — |

调度：UTC 05/11/17/23（北京 13/19/01/07），与 gitee（02/08/14/20）、cdn（03/09/15/21）、
taier（04/10/16/22）错峰。

## 功能与链路

对订阅 `PROXY_SPEEDTEST_SUB_URLS` 的每个可用节点串行执行：

1. 准备 Ookla 官方 `speedtest` CLI（见下节），并开 mihomo **TUN 模式**：`tun.enable + auto-route`
   接管整机出向，规则 `['PROCESS-NAME,speedtest,AUTO', 'MATCH,DIRECT']`——**只有测速进程走
   当前节点**，runner 自己的心跳/日志直连；
2. 经 API 切换 AUTO 组到该节点并 settle（`OOKLA_SWITCH_SETTLE_SECONDS`）；
3. 运行 speedtest CLI 一次完整测量（延迟 + 下行 + 上行，官方自适应连接数），
   `--format=json` 取结构化结果；
4. 解析：`download.bandwidth` / `upload.bandwidth`（byte/s）÷ 1048576 → MiB/s，
   展示口径「兆」= MiB/s × 8；延迟取 `ping.latency`（已是 ms）；
5. **未走代理校验**：`interface.externalIp` 与 runner 直连出口 IP 比对（见下节）；
6. 全部节点完成 → 撤销 TUN → Telegram 推 `✅ Ookla 测速`（TOP5 + 订阅 Gist 状态），
   达标节点订阅导出到本工作流专属 Gist，结果 JSON 落盘 `~/proxy-speedtest/ookla_speedtest_result.json`。

## 引擎准备

- workflow 用 **Ookla 官方 apt 源**（packagecloud 的 `ookla/speedtest-cli`）安装，二进制名固定为
  `speedtest`（PROCESS-NAME 规则即按它匹配）。**注意**：Ookla 的该源只发布到 `jammy` 发行线
  （2022-08 后未更新），官方 `script.deb.sh` 按 runner 发行版选 dist，在 ubuntu-24.04 上会报
  「Unable to locate package speedtest」→ workflow 里显式钉住 `jammy` 借用该源；apt 仍失败时
  回退官方 tarball（`install.speedtest.net`）；
- 脚本侧按 `OOKLA_BIN` → `which speedtest` → `OOKLA_CLI_URL` 现场下载官方 tgz 的顺序定位，
  仍找不到则带说明报错退出；
- **不要用 Debian/Ubuntu 的 `speedtest-cli` 包**（sivel 的 Python 第三方实现）：输出结构与口径
  都不同，脚本只认 `speedtest`，混用会静默产出错误数据；
- 非交互环境必须显式带 `--accept-license --accept-gdpr`，否则首跑会卡在许可确认；
- 默认追加 `--progress=no` 关掉进度条（避免它混进 stdout 破坏 JSON 解析）：若某个 CLI 版本
  不接受该写法，首次失败会自动去掉该参数重试（日志 `ookla_progress_flag_unsupported`）。

## 为什么必须 mihomo TUN

Ookla 官方 CLI **没有 `--proxy` 参数**，既不能走 HTTP/SOCKS 代理，也不是能靠 `LD_PRELOAD`
接管的动态链接程序，只有 TUN 能把该进程流量透明接入节点。开 TUN 需要 `CAP_NET_ADMIN`，
非 root 时脚本自动 `sudo -n` 启动 mihomo（kill 陈旧进程同理）。

TUN 起来后 DNS 会被 mihomo 劫持，必须显式给可达的公共解析器
（`dns.nameserver: [1.1.1.1, 8.8.8.8]` + `respect-rules: false`）——默认国内递归 DNS
在 Azure runner 上不通，会导致被代理程序秒失败。

## 测速点怎么选（默认动态就近）

Ookla 的服务器列表**按请求方出口 IP 就近返回**——GitHub runner（Azure 出口）看不到中国大陆
节点，境外出口节点看到的也只有本地列表（2026-09-11 诊断实测：节点出口在新加坡时列表 10 条
全是新加坡、CN=0；`--server-id` 指定不在列表里的编号必然 NoServersException）。也就是说
「广州联通」这类 CN 编号对绝大多数节点**机制上不可见**，写死编号只会整轮空跑（历史事故：
33 节点全失败却报 success）。

- **默认（推荐）**：`OOKLA_SERVER_ID` 留空，每个节点用自己出口可见列表里最近的测速点，
  通知头部显示 `📍 测速点：按节点出口就近 · N 个`；
- **显式锁编号**：只在该编号出现在该节点可见列表里时才锁定，用于同口径横评（前提是各节点
  出口同地区）；指定的编号不在可见列表时，通知会标注「指定测速点不在节点可见列表」，
  **绝不静默换口径**；
- **偏好关键词**：`OOKLA_SERVER_PREFER` 在节点可见列表内按 name/location/country 匹配，
  命不中就就近。别放 CN 关键词——境外出口的可见列表里没有 CN 测速点，永远命不中；
- 编号参考自社区维护的国内测速点清单（如 `reizhi/speedtest-cn-server-list`、
  `spiritLHLS/speedtest.net-CN-ID`），**Ookla 侧会随运营调整失效**（`SERVER_LABELS` 仅作
  展示，不参与选点）。

## 未走代理校验（必须有）

每节点比对「CLI 结果 `interface.externalIp`」与 runner 直连出口 IP（`api.ipify.org` 等）：

- **不同** → 流量确实走了节点 ✓
- **相同** → TUN 未生效 / `PROCESS-NAME` 规则未命中 → 通知里 `⚠️ 疑似未走代理` 告警；
  全部节点命中时 job 返回 1（否则会**静默直连**、整轮数据失真）

## 环境变量

### secrets

| secret | 用途 |
|---|---|
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（四套共用） |
| `PROXY_SPEEDTEST_OOKLA_GIST_ID` | 本工作流专属订阅 Gist 的 id；留空首跑自动新建（TG 给链接），回填避免每轮新建 |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |

### 可调参数（均有默认值）

| env | 默认 | 说明 |
|---|---|---|
| `OOKLA_SERVER_ID` | 空 | 显式测速点编号（逗号分隔多候选）；**仅当编号在该节点可见列表里才锁定**，境外出口拿不到 CN 测速点，留空 = 按节点出口就近动态选点（见上节） |
| `OOKLA_SERVER_PREFER` | 空 | 动态选点偏好关键词（仅在节点可见列表内匹配，命不中就近；CN 关键词在境外出口永远命不中） |
| `OOKLA_SERVER_LABEL` | 空 | 通知里测速点标签覆盖（留空按内置编号表 / CLI 返回自动生成） |
| `OOKLA_MAX_NODES` | `0` | 最多测几个节点，0 = 不限 |
| `OOKLA_TIMEOUT` | `120` | 单节点子进程超时秒 |
| `OOKLA_SWITCH_SETTLE_SECONDS` | `1.5` | 切节点后等待 |
| `OOKLA_BIN` | 空 | 显式指定 CLI 路径（优先级最高） |
| `OOKLA_CLI_URL` | 空 | 系统无 speedtest 时现场下载的官方 tgz 地址 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），四套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；达标数 < 最少节点数时自动改用另一指标 |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |

订阅导出策略（阈值/判定指标/最少节点数，含双向回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略四套共用)。

### Gist 文件名/描述（四套区分）

`PROXY_SPEEDTEST_GIST_FILENAME` = `proxy_speedtest_ookla_subscription.yaml`、
`PROXY_SPEEDTEST_GIST_DESCRIPTION` = `proxy speedtest subscription (ookla 按节点出口就近)`。
导出字段单位是 MiB/s（与另三套一致），节点名前缀「↑xx兆 | ↓xx兆 | xxms」。

## Telegram 通知

| 标题 | 触发 |
|---|---|
| `✅/⚠️ Ookla 测速` | 正常完成（含 TOP5、测速点网络、订阅 Gist 状态）；0 成功或命中「疑似未走代理」降级 ⚠️ |
| `⛔ Ookla 测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），handler **先撤 TUN 再发** |
| `❌ Ookla 测速异常退出 · <原因>` | 环境准备失败 / 节点快照失败 / 未捕获异常，标题取原因冒号前的阶段名 |

节点数与 TOP5 口径：`ok` = CLI rc=0 且有测速点信息且上下行不全为 0；出口 IP 与直连相同的
节点不计入「可用」。

## 运维与排查

| 现象 | 原因 / 处置 |
|---|---|
| 通知出现 `⚠️ 疑似未走代理` | TUN 没起来或 `PROCESS-NAME` 规则未命中（规则名取 CLI 真实 basename）；查 `mihomo.log` 与 `/dev/net/tun`；结果不可信，整轮判失败 |
| 全部节点 rc=2 `ConfigurationError`，但测速点列表能拉到 | speedtest.net 对节点出口 IP 风控（2026-09-11 诊断实测：经节点访问 `www.speedtest.net` → 403、`api.speedtest.net` → 429）；代码侧无解，换时段/换出口，或改用 taier/gitee 口径交叉验证 |
| 通知出现「指定测速点不在节点可见列表」 | 显式编号对该节点出口不可见（列表按出口 IP 就近返回），已按预期兜底就近；要同口径横评需换出口同地区的节点组 |
| 节点全部「拉不到测速点列表」 | 节点到控制面不可达（引擎级问题，连续命中会熔断停止整轮）；检查节点可用性与 mihomo DNS 配置 |
| 延迟明显高于同区 | 测速点按节点出口就近返回，出口在境外时测速点也在境外；延迟反映「节点 → 测速点」，不是「你家 → 节点」 |
| **run 卡在 in_progress、取消也无效** | TUN 未撤（历史事故）：脚本退出前必须 `stop_mihomo_tun()`；workflow 里有 `always()` 兜底步骤 `pkill "mihomo -d"` |
| CLI 首跑失败并提示许可 | 调用必须带 `--accept-license --accept-gdpr`（脚本已固定带上） |

## 已知风险

- **speedtest.net 会风控机房/代理 IP**：经节点出口访问控制面可能被 403/429（2026-09-11
  实测），此时整轮 `ConfigurationError`、拿不到任何数据；是否被风控取决于出口 IP 与时段，
  本项目无法缓解——测不出数不代表节点不可用，用 gitee/taier 口径交叉验证。
- **测速点可用性会变**：可见列表由 Ookla 按出口 IP 实时决定，任何具体编号（含 CN 清单里的）
  随时可能失效；动态就近不依赖单个编号，天然免疫此类失效。
- **结果会写入 speedtest.net 公开结果页**：官方 CLI 默认把测量结果持久化到其公开结果页
  （`result.url`，不含账号凭据）。介意公开的话需自行评估是否使用本引擎。
- **许可**：Ookla 官方 CLI 的许可对再分发 / 商业化集成有限制，个人与内部自动化使用可接受；
  纳入其他项目前请确认条款。
