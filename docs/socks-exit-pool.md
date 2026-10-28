# SOCKS5 出口节点池（socks-exit-pool）

> 代码：`.github/scripts/socks-exit/build_socks_exit.py`
> 入口：`.github/workflows/socks-exit-pool.yml`

## 它解决什么问题

免费订阅源（234.qzz.io/fsllistyaml）里的 SOCKS5 节点可以当 edgetunnel 的出口：
节点 path 写成 `/socks5://host:port`（全局形），Worker 到目标站的流量改走这台 SOCKS5，
YouTube 判区跟着出口 IP 走（2026-10-28 实测：JP 出口 → GL=JP）。

但免费源按小时换血（实测 1 小时后 27 个节点只剩 2 个），手钉进 KV 必死。
这条流水线做的事：定时抓源 → 逐节点测活 + 判区 → 重新生成节点 → 发布到独立私有 Gist 文件。
客户端把 Gist raw URL 挂成订阅，每次拉到的都是当下可用的节点。

## 设计决策（均来自 2026-10-28 实测）

| 决策 | 依据 |
|---|---|
| 只收 socks5 段 | http/https 存活 1/7，且唯一存活者被 Google 判 US，无定区价值；vmess/vless/anytls 是入口协议，Worker 不吃 |
| 测活含 YouTube 判区，取不到 GL 直接丢弃 | 定区是这条管道唯一目的，GL 取不到 = 没用 |
| 同一出口 IP 只留最快一条 | 源常把同一台机器拆成多条，重复节点无意义 |
| 产物写独立 Gist 文件 socks-exit.yaml | subs-check 每 5 分钟同步 all.yaml，同文件会互相覆盖 |
| 全失败时不产出文件、Gist 保留上一版 | 避免客户端订阅瞬间清零 |
| 节点 `udp: false` | `_worker.js` 的 socks5Connect 只做 TCP 转发，标 true 会诱使客户端先试 QUIC、超时才回退 TCP |
| cron `*/15` | 源按小时漂，15 分钟足够跟上；仓库约定不用 `*/5`（防限流，见 self-retrigger.md 的频率取舍） |

## 产物与消费

- Gist：`secrets.SOCKS_EXIT_GIST_ID`，文件 `socks-exit.yaml`，节点名 `socks-exit|<GL>|<延迟>s`
- 节点入口 = edgetunnel 主域 + 主 UUID（与 all.yaml 同一入口），出口参数在 path 里；
  某条 socks5 死了只是那一条节点不可用，主线（US ProxyIP 池）不受影响
- 客户端（Egern / Clash 系）把 raw URL 挂为订阅即可

## 运维

- 手动触发：workflow_dispatch
- secrets：`SOCKS_EXIT_GIST_ID`（私有 Gist id）、`EDGETUNNEL_HOST` / `EDGETUNNEL_UUID`（入口）、`PAT`（写 Gist）
- 换源：环境变量 `SOCKS_SOURCE_URL` 覆盖默认 qzz 源；`MAX_NODES`（默认 15）、`PROBE_WORKERS`（默认 8）调节产出
- 源节点多为无认证公网代理：只适合跑 YouTube 等不敏感流量，不要把聊天/账号类流量指过去
