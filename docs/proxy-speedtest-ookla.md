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
| `proxy-speedtest-ookla` | Speedtest 官方测速点（默认广东广州 · 联通 5G） | speedtest CLI 延迟 + 上下行 | 本文 | — |

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
  `speedtest`（PROCESS-NAME 规则即按它匹配）；
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

## 为什么必须显式指定测速点编号

Ookla 的服务器列表**按请求方出口 IP 的远近排序**，GitHub runner（Azure 出口）视角根本看不到
中国大陆节点：把「广州联通」交给自动就近选择，必然落到境外节点，测速点口径失真。因此一律用
`--server-id=<id>` 显式锁定。

- 默认：`26678` = 广东广州 · 联通 5G；
- 编号来源是社区维护的国内测速点清单（如 `reizhi/speedtest-cn-server-list`、
  `spiritLHLS/speedtest.net-CN-ID`），**Ookla 侧会随运营调整失效**，故支持多候选：
  `OOKLA_SERVER_ID=26678,4870,24447` 逗号分隔，按序尝试；
- **顺延只在 CLI 明确报「测速点找不到/连不上」时发生**（节点自身故障不消耗候选）；
  一旦顺延，通知会多一行 `<code>首选 id</code> → <code>实际 id</code> · 首选测速点不可用，已顺延`，
  **绝不静默换点**；
- 每个节点的测速点由本轮锁定值决定，通知头部 `📍 测速点` 显示本轮实际命中的编号与标签。

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
| `OOKLA_SERVER_ID` | `26678` | Speedtest 测速点编号，逗号分隔多候选（见上节顺延规则） |
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
`PROXY_SPEEDTEST_GIST_DESCRIPTION` = `proxy speedtest subscription (ookla 广州联通)`。
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
| 节点全部「连不上测速点」 | 节点到控制面 `www.speedtest.net` 或测速点本身不可达；换节点或检查 mihomo DNS 配置 |
| 通知出现「首选测速点不可用，已顺延」 | 默认编号已失效，顺延到了候选；建议把 `OOKLA_SERVER_ID` 改成实际可用的编号（或直接从 Variables 覆盖） |
| 延迟明显高于同城 | 测速点在广州、节点出口在境外，属正常；要测同城需换广州本地节点 |
| **run 卡在 in_progress、取消也无效** | TUN 未撤（历史事故）：脚本退出前必须 `stop_mihomo_tun()`；workflow 里有 `always()` 兜底步骤 `pkill "mihomo -d"` |
| CLI 首跑失败并提示许可 | 调用必须带 `--accept-license --accept-gdpr`（脚本已固定带上） |

## 已知风险

- **测速点可用性会变**：广州联通是否仍有 Ookla 服务器不由本项目控制，默认编号来自社区清单；
  顺延与显式覆盖是缓解手段，不是保证。
- **结果会写入 speedtest.net 公开结果页**：官方 CLI 默认把测量结果持久化到其公开结果页
  （`result.url`，不含账号凭据）。介意公开的话需自行评估是否使用本引擎。
- **许可**：Ookla 官方 CLI 的许可对再分发 / 商业化集成有限制，个人与内部自动化使用可接受；
  纳入其他项目前请确认条款。
