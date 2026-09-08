# 泰尔三网测速（proxy-speedtest-taier）

> 代码：`.github/scripts/proxy-speedtest/taier_speedtest.py`
> 入口：`.github/workflows/proxy-speedtest-taier.yml`

## 三件套总览

仓库代理测速三件套**按测速点命名**，口径互不可比（单流 vs 多连接 vs 专用测速协议）：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | `speedtest_gitee.py` | [gitee](proxy-speedtest-gitee.md) |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | `speedtest.py` | [cdn](proxy-speedtest-cdn.md) |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | 本文 | — |

调度：UTC 04/10/16/22（北京 12/18/00/06），与 gitee（02/08/14/20）、cdn（03/09/15/21）错峰。

## 功能与链路

对订阅 `PROXY_SPEEDTEST_SUB_URLS` 的每个可用节点串行执行：

1. 下载 `MiaM1ku/taierspeedtest` 最新 Release 二进制（固定文件名 `~/proxy-speedtest/taierspeedtest`，供进程规则匹配）；
2. mihomo 以 **TUN 模式**启动：`tun.enable + auto-route` 接管整机出向，规则
   `['PROCESS-NAME,taierspeedtest,AUTO', 'MATCH,DIRECT']`——**只有测速进程走当前节点**，
   runner 自己的心跳/日志直连；经 API 切换 AUTO 组到该节点；
3. 运行 taierspeedtest（协议还原自 `com.cnspeedtest.globalspeed`：控制面取出口 IP/定位 →
   按测速点匹配运营商服务器 → 原生 TCP 上下行）；
4. 解析 stdout：出口 IP/位置、延迟、上下行；与 runner 直连出口 IP 比对（**bypass 校验**）；
5. 全部节点完成：Telegram 推 `✅ 泰尔三网测速`（TOP5 ↓↑Mbps + 延迟），达标节点订阅导出到
   本工作流专属 Gist，结果 JSON 落盘 `~/proxy-speedtest/taier_speedtest_result.json`。

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
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（三件套共用） |
| `PROXY_SPEEDTEST_TAIER_GIST_ID` | 本工作流专属订阅 Gist 的 id；留空首跑自动新建（TG 给链接），回填避免每轮新建 |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |

### 可调参数（均有默认值）

| env | 默认 | 说明 |
|---|---|---|
| `TAIER_POINTS` | `广东联通` | 测速点（省份/城市+运营商，逗号分隔可多点，耗时成倍） |
| `TAIER_MODE` | `single` | `single`=单连接 / `multi`=下 8+上 4 连接 / `both` 对照 |
| `TAIER_DURATION` | `10` | 每方向秒数；**上游二进制硬钳制 5-13**，>13 被压到 13 |
| `TAIER_MAX_NODES` | `0` | 最多测几个节点，0 = 不限 |
| `TAIER_TIMEOUT` | `120` | 单节点子进程超时秒 |
| `TAIER_SWITCH_SETTLE_SECONDS` | `1.5` | 切节点后等待 |
| `TAIER_IMAGE` | `0` | 每节点出结果图（上传图床），默认关避免刷图 |
| `TAIER_NO_IPV6` | `1` | TUN 下客户端易误判 v6 可用导致耗时翻倍，默认关 |
| `TAIER_REPO` | `MiaM1ku/taierspeedtest` | 引擎仓库 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆），三件套共用 |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；达标数 < 最少节点数时自动改用另一指标 |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传 |

订阅导出策略（阈值/判定指标/最少节点数，含双向回退规则）详见
[gitee 文档 · 订阅导出策略](proxy-speedtest-gitee.md#订阅导出策略三件套共用)。
注意 taier **上行常测不出**（CDN 类测速点拒绝上传包，引擎渲染 failed → 0），默认按上行
判定时通常达标 0 个 → 自动落到下行判定，通知会显示实际采用的指标。

### Gist 文件名/描述（三件套区分）

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
| 通知出现 `⚠️ 疑似未走代理` | TUN 没起来或 `PROCESS-NAME` 规则未命中；查 `mihomo.log` 与 `/dev/net/tun`；结果不可信，整轮判失败 |
| 节点全部「连不上测速点」 | 控制面 `*.cnspeedtest.cn` 经该节点不可达；换节点或检查 mihomo DNS 配置 |
| **run 卡在 in_progress、取消也无效** | TUN 未撤（历史事故）：脚本退出前必须 `stop_mihomo_tun()`；workflow 里有 `always()` 兜底步骤 `pkill "mihomo -d"` |
| 延迟 1 秒以上 | ICMP 经 TUN 不通，回落 TCP tcping（真实握手往返），属预期 |
| 验证 handler | 运行中途 `gh run cancel`：日志应出现两次 `mihomo_tun_stopped`（handler + finally），TG 收到 ⛔ |

上游 duration 钳制 5-13 秒（`main.go`），需要更长测速只能改上游或自编译。
