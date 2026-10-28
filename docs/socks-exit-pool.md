# 出口节点池（socks-exit-pool）

> 代码：`.github/scripts/socks-exit/build_socks_exit.py`
> 入口：`.github/workflows/socks-exit-pool.yml`

## 它解决什么问题

免费订阅源（234.qzz.io/fsllistyaml）里的 SOCKS5 / HTTP 节点可以当 edgetunnel 的出口：
节点 path 写成 `/socks5://host:port`、`/https://host:port`（全局形），Worker 到目标站的流量改走这台代理，
YouTube 判区跟着出口 IP 走（2026-10-28 实测：JP 出口 → GL=JP，HK → GL=HK，SG → GL=SG）。

但免费源按小时换血（实测 1 小时后 27 个节点只剩 2 个），手钉进 KV 必死。
这条流水线做的事：定时抓源 → 逐节点测活 + 判区 → 重新生成节点 → 发布到独立私有 Gist 文件。
客户端把 Gist raw URL 挂成订阅，每次拉到的都是当下可用的节点。

## 产物组成（2026-10-28 主人两次反馈后定稿）

产物 = **源的全部原节点** + **每个验证通过的出口各一条节点**：

1. **原节点全量原样保留**：名字、协议、认证字段一概不动。它们是可直连的第三方代理
   （不是 Worker 入口，无法承载 path 级出口切换），本身有使用价值，删掉等于丢掉源的全部信息。
2. **出口节点**：入口用 edgetunnel 主域 + 主 UUID，出口参数写在 path 里；
   名字 = `原节点名|YT-<地区>|<延迟>s`，例如 `HK-Hong Kong-23812620-stmd|YT-HK|0.89s`。
   原名里的地区/城市/节点 ID 全部保留，YouTube 地区与实测延迟追加在尾部。
3. **出口段覆盖 socks5 + http + https**：只收 socks5 时池子只有 2~4 条（socks5 段本身就这么小），
   把 http/https 也纳入后产出显著变大。`http` 节点若带 `tls: true`，先按 HTTPS 代理试、再退明文。

## 设计决策（均来自实测）

| 决策 | 依据 |
|---|---|
| 测活含 YouTube 判区，取不到 GL 直接丢弃 | 定区是这条管道唯一目的，GL 取不到 = 没用 |
| 去重按「代理地址」（scheme + host:port） | 主人要求「所有验证后的出口」都在列；不同源节点即便出口 IP 相同也各自保留 |
| 产物写独立 Gist 文件 socks-exit.yaml | subs-check 每 5 分钟同步 all.yaml，同文件会互相覆盖 |
| 全失败时不产出文件、Gist 保留上一版 | 避免客户端订阅瞬间清零 |
| 节点 `udp: false` | `_worker.js` 的 socks5Connect/httpConnect 只做 TCP 转发，标 true 会诱使客户端先试 QUIC、超时才回退 TCP |
| cron `*/15` | 源按小时漂，15 分钟足够跟上；仓库约定不用 `*/5`（防限流，见 self-retrigger.md 的频率取舍） |
| path 里的凭据做 URL 编码 | `_worker.js` 第 6176 行对 pathname 做 decodeURIComponent，编码后 `@ : /` 不会破坏 path 结构 |

## 产物与消费

- Gist：`secrets.SOCKS_EXIT_GIST_ID`，文件 `socks-exit.yaml`
- 出口节点的失效隔离：某条代理死了只是那一条不可用，客户端健康检查自动切走；
  主线（US ProxyIP 池节点）完全不受影响
- 客户端（Egern / Clash 系）把 raw URL 挂为订阅即可

## 运维

- 手动触发：workflow_dispatch
- secrets：`SOCKS_EXIT_GIST_ID`（私有 Gist id）、`EDGETUNNEL_HOST` / `EDGETUNNEL_UUID`（入口）、`PAT`（写 Gist）
- 换源：环境变量 `SOCKS_SOURCE_URL` 覆盖默认 qzz 源；`MAX_EXITS`（默认 20）、`PROBE_WORKERS`（默认 8）调节产出
- 源节点多为无认证公网代理：只适合跑 YouTube 等不敏感流量，不要把聊天/账号类流量指过去
