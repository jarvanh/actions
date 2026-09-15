# 自续触发接力（长跑 workflow 的交接机制）

> 一句话：**一轮收尾时主动派下一轮**，让服务/任务在轮与轮之间不留空档；cron 只当"接力失败
> 时的兜底网"。共享实现 `.github/scripts/lib/self_retrigger.sh`。

## 1. 零空档到底来自哪里（别搞反）

保活型 workflow（服务型）的交接由**两件事**共同保证，缺一不可：

| 机制 | 何时生效 | 作用 |
|---|---|---|
| **cron 留下的 pending 运行** | 只要 cron 周期 < 单轮时长，队列里就始终躺着一个 pending | 上一轮 job 结束的**瞬间**它接管 → 这就是"零空档"的主要来源 |
| **自续触发（接力）** | 队列**空出来**时（cron 被 GitHub 限流、或兜底周期还没到） | 主动 `gh workflow run` 派下一轮 → 兜住 cron 的失效 |

所以两条设计原则：

- **cron 不能太密**：高频 cron 会被 GitHub 限流（实测 `*/5` 曾 4.5h 零触发），而且每 5 分钟
  造一个被单例挡掉的排队运行，把 run 列表塞满。取 **1h**：兜底延迟 ≤1h，堆的排队也少。
- **接力不能省**：只有 cron 的话，一旦被限流就是"静默失联"（没有告警、没有自愈）。

## 2. 三条判据（共享脚本里固化，顺序固定）

| # | 判据 | 为什么 |
|---|---|---|
| ① | 开关关闭（`SR_ENABLED != true`） | 对应 workflow 的 `self_retrigger` 输入：保留"能停"的能力 |
| ② | 人工取消（`job.status=cancelled` 且 elapsed < 21000s） | 6h 上限触发的取消 elapsed ≈ 21600s，远小于它说明是人手动停的，**不该替他续上** |
| ③ | 队列里已有 `queued/waiting/pending` | 下一轮已经排上了，再派就是叠罗汉（叠罗汉会同时占两个 runner、抢同一份数据） |

三条都不命中才派发。**跳过是健康接力链的常态**，所以每条跳过都必须把原因写进日志
（`⏭️ 未接力（<名>）：<原因>`），不能静默。

## 3. 适用性判定

| 类型 | 特征 | 要不要接力 | 本仓库的成员 |
|---|---|---|---|
| **保活型（服务型）** | 内部长 sleep（数小时）、单例并发、服务需要 24/7 在线 | ✅ 要 | `emby` `openlist` `openclaw` `p` `ql` `sub-store` `teslamate` `HomeAssistant` `jellyfin` `tailscale-windows`（常驻 Windows 远程入口） |
| **周期性任务** | 跑完即结束（备份、下载、签到、测速、清理） | ❌ 不要 | `github_backup_all` `self-hosted_backup` `icloud-photos-downloader` `ph-dl` `pixivutil2` `eshop` `upload-video-to-tg` `delete-workflow-runs` `subs-check` `proxy-speedtest-*`（4 个）`openlist-diag` `rdp` |

判据就一句：**"这个 workflow 的产物是『一直在线』还是『跑完一份东西』"**。周期性任务加接力
= 把它变成常驻，纯烧额度。

## 4. 给一个 workflow 接入（四处改动）

```yaml
# ① 顶部：gh workflow run 需要 actions:write（其余只读）
permissions:
  contents: read
  actions: write

on:
  schedule:
    # ② 兜底触发：1h（不要 */5，理由见 §1）
    - cron: "0 * * * *"
  workflow_dispatch:
    inputs:
      # ③ 保留"能停"的开关（与 emby 同名同义）
      self_retrigger:
        description: "收尾是否自动起下一轮（关掉则本轮结束后静止）"
        type: boolean
        default: true

jobs:
  build:
    steps:
      # ... 业务步骤 ...
      # ④ 收尾：放在**最后一步**（数据已回传完再派下一轮，否则下一轮会读到半份数据）
      - name: 自续触发（下轮接力）
        if: ${{ always() }}
        env:
          GH_TOKEN: ${{ github.token }}
          SR_STATUS: ${{ job.status }}
          SR_ENABLED: ${{ github.event.inputs.self_retrigger || 'true' }}
        run: |
          source "$GITHUB_WORKSPACE/.github/scripts/lib/self_retrigger.sh"
          self_retrigger <本 workflow 文件名>
```

要点：

- `GH_TOKEN` 用内置 `github.token` 即可（配 `permissions: actions: write`），不必额外 PAT
- **必须放在最后一步**：接力跑在数据回传之后
- Windows runner（`tailscale-windows.yml`）要用 `shell: bash` 调同一份脚本（runner 自带 git-bash），
  不要另写 pwsh 版，避免两套语义漂移
- 不改业务逻辑、不改保留时长、**不新增/不修改 Telegram 通知**（`docs/telegram-notify.md` 为真源）

### 共享脚本的其它可用开关

| 环境变量 | 默认 | 用途 |
|---|---|---|
| `SR_ENABLED` | `true` | 总开关（对应 `self_retrigger` 输入） |
| `SR_CANCEL_MIN` | `21000` | 人工取消判定阈值（秒） |
| `SR_ON_FAILURE` | `1` | 失败轮是否接力（纯周期任务设 0） |
| `SR_INPUTS` | 空 | 透传给下一轮的输入，形如 `run_minutes=8&playback_mode=302` |
| `SR_ELAPSED` | 自动 | 本轮已运行秒数（默认调 `run_elapsed_seconds`） |
| `SR_LABEL` | workflow 名 | 日志里的显示名 |

## 5. 怎么验证

1. **交接时间戳**：上一轮 `completed_at` → 下一轮 `created_at`，差值应 ≤1 分钟
2. **日志行**：收尾步骤应出现 `✅ 已触发下一轮接力` 或 `⏭️ 未接力：<原因>`；
   健康链里最常见的是 `⏭️ 未接力：队列里已有 1 个排队运行`
3. **噪音下降**：`gh run list --workflow=<x> --limit 20` 应从"每 5 分钟一条取消"变成
   "每小时一条 + 正常轮次"
4. **无并行**：同一 workflow 任何时刻只应有 1 个 in_progress（靠 `*-singleton` 并发组）

## 6. 平台注意点

- **Windows runner（`tailscale-windows.yml`）**：脚本里用 `gh` 自带的 `--jq`（Go 实现），
  **不要**管道给外部 `jq`——Windows 镜像上没有 jq 二进制，管道版会静默退化成"排队数=0"，
  「已有排队」判据就白设了。该步骤要显式 `shell: bash`（runner 自带 git-bash）。
- **排队判据取不到时是"放行派发"**（fail-open）：保活型服务可用性优先，宁可多派一轮
  （单例并发会把它变成 pending，不会并行），也不因为一次 API 抖动让服务断档。
- **保留时长要留出收尾余量**：`tailscale-windows` 的 keep-alive 从 21000s 收到 19000s——
  原值加上启动会把整轮顶到 `timeout-minutes: 360` 边缘，被超时杀掉时收尾的接力步骤不会执行，链就断了。

## 7. 还没接的

`emby.yml` / `openlist.yml` 早已有内联实现且稳定运行，与新共享脚本语义一致；
可选迁移（单独一轮做，不与其它改动混在一起，降低回归面）。
