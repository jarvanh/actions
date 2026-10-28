# 出口节点池（socks-exit-pool）

> 代码：`.github/scripts/socks-exit/build_socks_exit.py`
> 入口：`.github/workflows/socks-exit-pool.yml`

## 它解决什么问题

让订阅里的每个节点都能按需切换 YouTube 判区：edgetunnel 支持 path 级出口
（`/socks5://host:port` 全局形），Worker 到目标站的流量改走指定 SOCKS5，YT 判区跟着出口 IP 走
（2026-10-28 实测：JP 出口 → GL=JP，HK → GL=HK，SG → GL=SG）。

免费出口源（234.qzz.io）的 SOCKS5 按小时换血（实测 1 小时后 27 个节点只剩 2 个），手钉必死。
这条流水线：定时抓源 → 逐出口测活 + 判区 → 与 subs-check 节点组合 → 发布到独立私有 Gist 文件。

## 产物组成（v3，2026-10-28 主人定稿）

产物 = **subs-check all.yaml 全部原节点** + **每个基座节点 × 每个验证通过的 SOCKS5 出口**的组合节点：

1. **基座**：subs-check 产物 gist 的 `all.yaml`（约 400 个 vless/ws 节点，名字自带
   测速/IP风险/流媒体解锁标签）。原节点**原样保留**，一个不丢。
2. **组合节点**：入口沿用基座节点（优选IP/端口/TLS/Host 头不动，保持测速结论有效），
   仅 ws path 换成 `/socks5://<出口>`；
   名字 = `基座名|YT-<实测判区>|<延迟>s`。基座名里原有的 `YT-US` 等是 subs-check 对
   默认出口（ProxyIP 池）的检测标签；追加的 `|YT-HK|1.11s` 是经该 SOCKS5 出口的**实测判区**，
   两者语义不同、按位置区分。
3. **出口只收 socks5**：http/https 段实测存活 1/7 且判区不可控，主人明确剔除。

## 设计决策（均来自实测）

| 决策 | 依据 |
|---|---|
| 出口测活含 YT 判区，取不到 GL 直接丢弃 | 定区是这条管道唯一目的，GL 取不到 = 没用 |
| 出口按 host:port 去重，只留最快一条 | 同一出口重复组合没有意义 |
| 组合节点 `udp: false` | `_worker.js` 的 socks5Connect 只做 TCP 转发，标 true 会诱使客户端先试 QUIC、超时才回退 TCP |
| 非 ws 基座不参与组合 | path 出口只存在于 ws 传输（all.yaml 里 100% 是 ws，实际全部参与） |
| 产物写独立 Gist 文件 socks-exit.yaml | subs-check 每 5 分钟同步 all.yaml，同文件会互相覆盖 |
| 全失败时不产出文件、Gist 保留上一版 | 避免客户端订阅瞬间清零 |
| cron `*/15` | 源按小时漂，15 分钟足够跟上；仓库约定不用 `*/5`（防限流，见 self-retrigger.md 的频率取舍） |
| path 里的凭据做 URL 编码 | `_worker.js` 第 6176 行对 pathname 做 decodeURIComponent，编码后 `@ : /` 不会破坏 path 结构 |

## 产物与消费

- Gist：`secrets.SOCKS_EXIT_GIST_ID`，文件 `socks-exit.yaml`
- 节点量级：基座 400 × 验证出口 N + 400；出口通常 2~4 个，产物约 1200 节点 / 675KB
- 失效隔离：某条 socks5 死了只是带它的组合节点不可用，客户端健康检查自动切走；
  原节点与主线（US ProxyIP 池）完全不受影响
- 客户端（Egern / Clash 系）把 raw URL 挂为订阅即可，YouTube 规则指到 `|YT-<区>|` 的组合节点

## 运维

- 手动触发：workflow_dispatch
- secrets：`SOCKS_EXIT_GIST_ID`（本管道私有 Gist）、`SUBS_CHECK_GIST_ID`（subs-check 基座 Gist）、`PAT`（写 Gist）
- 换出口源：环境变量 `SOCKS_SOURCE_URL` 覆盖默认 qzz 源；`MAX_EXITS`（默认 20）、`PROBE_WORKERS`（默认 8）调节产出
- 出口多为无认证公网代理：只适合跑 YouTube 等不敏感流量，不要把聊天/账号类流量指过去
