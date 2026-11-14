# OpenClaw Runner：自愈机制 · 常驻服务 · 远程入口

> 适用范围：`jarvanh/actions` 仓库 `.github/workflows/openclaw.yml`
> 配套阅读：本仓库工作流源码。本文描述当前生效的自愈行为、常驻服务与操作流程。

## 零、运行概览

| 项 | 值 |
|---|---|
| 触发 | 定时 `cron: "*/5 * * * *"` + `workflow_dispatch`（手动） |
| 并发 | 动态并发组（2026-11-10 Phase 1）：serving 主轮独占 `openclaw-serve`；交接继任轮用 `openclaw-handoff-<run_id>` 专属键与旧轮**合法并存**；cron 兜底轮启动时经 `handoff/guard.sh` 自检，发现并存 run 即自我取消让位 |
| 单轮时长 | `Keep alive` 死线 = 360 − 收尾预算 26 − 安全余量 8 = **326 分钟**（job 起点起算）；结束前 15 分钟推送「即将进入最终归档」预警、前 2 分钟推送停机倒计时 |
| 自我接力 | 双通道（2026-11-10 Phase 1）：主路径 = 死线前 T-12min 由 `handoff/tick.sh` 触发**交接继任者**（warm standby），继任者接管成功后旧轮 `Trigger next` 跳过；兜底 = 继任者未就绪/交接失败时沿用末尾 `Trigger next OpenClaw run` 传统接力 |
| 权限 | `contents: read` + `actions: write`（自我触发需要） |

### warm-standby 交接（Phase 1，2026-11-10）

目的：把每轮 6h 交班的下线时长从实测 466s 压到 ~2-3min，**数据零丢失**为硬约束。
协议真源：`.github/scripts/handoff/protocol.sh`（标记 schema、状态机、防双服三件套都在文件头注释里）。

```
旧轮(serving)                          继任轮(openclaw-next, T-12min 被触发)
  │ Keep alive T-12min: tick.sh 触发  ──→  启动段照常：基座恢复(≤20min 前周期包)
  │ T-4min: 看门狗，未 ready 则取消继任者      → new.json=ready
  │ 死线 T0: 停网关 → sqlite checkpoint
  │          → 停本机隧道 → rsync 只读源
  │          → old.json=handing_over   ──→  等到交出：rsync 增量直传(~/.openclaw ∥ ~/.zcode)
  │                                        → 主 state 库 quick_check → rsync_done
  │                                        → 起网关 → new.json=serving
  │ 等 serving(≤15min) ←──────────────────┘
  ├─ 成功: old.json=handoff_done → 最终归档降级为纯备份(移出关键路径) → 跳过 Trigger next
  └─ 失败: old.json=handoff_aborted → 传统收尾(归档+Trigger next)，继任者自我取消
```

- **零丢失边界**：停机瞬间 = 网关 stop；rsync 在停机后进行，停机前写入全部随增量到达
  继任者。rsync 失败/超时 → 传统收尾兜底（归档里也全有），任何分支不丢窗口。
- **继任者的上游/AI 网关**：各数据恢复脚本无条件从 Dropbox 归档拉取，故等
  `old.json=archives_done`（旧轮最终归档上传完，`gate.sh` 阻塞）才起服务 ——
  模型通道 T0+6~10min 恢复（与旧版整条黑 ~8min 持平），网关/UI/Tailscale 先亮。
- **归档循环**：继任者同样等 archives_done 才启动（防两台 VM 并发写同一个云包）。
- **交接轮的最终归档 = 灾备备份**：交出后旧轮继续把冻结态打包上传（实测 ~9min）。
  通知标题必须与「本轮结束」区分：交接轮写明「交接后备份」，并附一句
  「服务已在继任者上运行……不阻塞任何用户」；传统轮才是最终归档。
- **交接进度通知**：`.github/scripts/handoff/handoff-notify.sh` 在五个阶段各发一条
  普通档通知；标题只写阶段，kv 说明服务是否可用与预计 / 已用时间。
  逐条标题用 `list_notify.sh handoff` 现场枚举。聊天入口恢复只代表 18789 `/health=200`，
  不代表模型通道；run id 均可点击。无凭据或发送失败一律静默，不影响交接。
- **可观测性**：Phase 0 埋点在每轮收尾日志输出 `[phase0]` 段（增量字节/文件数/直连评估），
  用于校准 rsync 增量交接的实际收益。

### 手动交接与三个开关（2026-11-11）

生产上要「按需」测交接、或按需回退传统路径时用，不必等死线、也不必回滚代码。
三个开关的**分工**：先决定这一轮「是否参与交接」，再决定「现在就开始」还是「到点再说」。

#### ① 立即交接（`/tmp/openclaw-handoff-request`）

```bash
ssh runner@openclaw 'touch /tmp/openclaw-handoff-request'
# 已在机器上：touch /tmp/openclaw-handoff-request
```

必须落在**正在服务的那台 VM**（持有 Tailscale 名 `openclaw`、跑着 `Keep alive` 的那一轮）；
写到别的机器上完全没有效果。默认路径可用 `HANDOFF_FORCE_FILE` 覆盖（测试隔离用）。

前置条件（缺一项就静默不生效，这是最常见的「点了没反应」原因）：

| 条件 | 检查 |
|---|---|
| 仓库变量 `OPENCLAW_HANDOFF=1` | `gh variable list -R jarvanh/actions`（`tick.sh` 开头直接 `exit 0`） |
| 当前轮的 `tick.sh` 支持该开关（≥ `e220414`） | 老 run 不认识这个文件 |
| 没有上一次交接的残留 | `ls /tmp/openclaw-handoff/successor-run-id`；有则**不会再派发** |
| runner 上 `gh` 可 dispatch | `tick.sh` 用 `gh workflow run -f handoff_of=<本轮 id>` |

执行链（每一步都可在 `Keep alive` 日志里看到）：

| 步骤 | 位置 | 行为 |
|---|---|---|
| 轮询 | `Keep alive` 每 15s 调 `tick.sh` | ≤15s 内发现开关 |
| 派发继任者 | `tick.sh` §1 | `gh workflow run openclaw.yml --ref main -f handoff_of=<本轮 id> -f ai_backend=<当前后端>` |
| 武装 | 同上 | 写 `successor-run-id` / `enabled`，发「准备中（手动）」通知 |
| 等 ready | `tick.sh` §4 | 继任者 `new.json=ready` 后写 `/tmp/openclaw-restart-request`，删除开关文件 |
| 提前收尾 | `Keep alive` | 看到 restart-request → 退出循环 |
| 交出 | `cutover.sh` | checkpoint → 停看门狗（timer+**service**）→ 落 `switching` 标记 → 停全部服务/隧道 → rsync → `handing_over` → 等 `serving` |
| 接管 | 继任者 `takeover.sh` | rsync 增量 → 校验 → 起服务 → `serving` |

**为什么不能一触即交**：`cutover.sh` 只给继任者 5 分钟的 `ready` 等待，而基座恢复要 2-3 分钟
（实测），硬提前会超时退化成传统收尾、白停一次。所以是「先派发 → 等 ready → 再交出」两段式。

实测（2026-11-11 五次）：

| 指标 | 范围 |
|---|---|
| 触发 → 继任者派发 | 5-20s |
| 触发 → 交出（cutoff） | ~3min |
| **聊天下线**（cutoff → serving） | **197-238s** |
| AI 网关恢复（cutoff → OmniRoute 就绪） | 182s（`OPENCLAW_AI_EARLY=1` 时常早于聊天） |
| **整体可用**（cutoff → 8/8） | **252-296s** |

每个交接阶段各发一条通知（普通档）；run id 均为可点链接，手动交接会明确催促停写。

取消与回退：

| 时机 | 操作 | 结果 |
|---|---|---|
| 开关刚写入、未被轮询 | `rm -f /tmp/openclaw-handoff-request` | 什么都不会发生 |
| 继任者已派发、未 ready | `gh run cancel <继任者 id>` | 下一轮 tick 检测到已终止 → 解除武装，正常保活 |
| 继任者 `aborted` | 自动 | 删除开关、保持正常保活（不交接） |
| cutover 失败 | 自动 `abort_handoff` | 旧轮拉起服务、清 `switching` 标记、走传统收尾 |

清理残留（手动/自动交接中断后）：
```bash
ssh runner@openclaw 'rm -f /tmp/openclaw-handoff/{successor-run-id,enabled,ready-ok}'
```

#### ② 传统提前收尾（`/tmp/openclaw-restart-request`）

```bash
ssh runner@openclaw 'touch /tmp/openclaw-restart-request'
```

不派发继任者，直接进入收尾（停服 → 归档 → Trigger next）。最终归档完整，
但恢复要靠下一轮冷启动（约 9-10 分钟）。最坏丢 ≤20min 增量；主包因
「临时对象 + 尺寸校验 + 原子改名」不会被半截包覆盖。

#### ③ 启动方式（`startup_mode`）

手动运行 workflow 时选择：

| 值 | 语义 |
|---|---|
| `auto`（默认） | 跟随仓库变量 `OPENCLAW_HANDOFF` |
| `handoff` | 强制按交接模式（即使变量被关掉，定点验证用） |
| `traditional` | 强制传统：本轮不派发继任者、不交出 |

与 `handoff_of` 的分工：`startup_mode` 决定「本轮是否参与交接」，`handoff_of` 决定「本轮是不是继任者」。

#### 网页端 Cancel 会怎样（实测对照）

`Trigger next` 要求 `steps.keepalive.conclusion == 'success'`，**cancel 时该步是 `cancelled`**
→ 不会自己派下一轮；下一轮只能来自 cron（`*/5`），是普通 serve 轮 → **传统冷启动**
（若取消时继任者已武装，它会因旧轮 `cancelled` 而 `abort_takeover` 自我取消）。

2026-11-11 16:18 实测（提交 cancel 那次）：

| 口径 | 时长 |
|---|---|
| 提交 cancel → 旧 job 真正结束 | 240s（宽限期内收尾步骤**未执行**） |
| job 结束 → 下一轮 cron 起跑 | 367s（`*/5` 调度；guard 空转一轮再加 5min） |
| job 结束 → 聊天恢复 | 535s ≈ 8.9min |
| job 结束 → 8/8 全就绪 | 591s ≈ 9.8min |
| **从点 Cancel 到 8/8** | **831s ≈ 13.8min** |

| 方式 | 服务停 → 聊天 | 服务停 → 8/8 | 最终归档 | 数据风险 |
|---|---|---|---|---|
| 网页 Cancel | **8.9min** | 9.8min | 大概率不执行 | 最坏丢 ≤20min |
| 立即交接 | **3.5min** | 4.2min | 完整 | 零丢失 |
| 传统提前收尾 | 8.9min | 9.8min | 完整 | 零丢失 |

结论：要重启生产，**立即交接在每一项上都优于 Cancel**；Cancel 的停机窗口约为其 3 倍。

#### 时间口径：「数据冻结」不是「最终归档」

- **数据冻结** = 收尾里「2.5 停 OpenClaw 网关」那一刻，此后写入不进最终快照（会丢）。
  实测：死线（Keep alive 退出）→ 停网关只差 **7s**；正常轮前面还要停 rsstt，最坏 ~70s。
  `deadline.sh` 落 `FREEZE_DELAY_SECONDS=10`（取实测下界，宁早勿晚）。
- **最终归档上传完成**比冻结晚约 **4 分钟**（实测冻结 20:01:13 / 上传完成 20:05:08）——
  旧看板把这一行叫「最终归档」会误导。
- 看板现在两行：
  - `数据冻结`：倒计时到冻结时刻（= job 起点 + 326min + 10s），剩余 <60min 转红。
  - `最近归档`：主包 mtime + `（交接时）`/`（周期）`；判定窗口 = cutoff 起 30 分钟内。

#### 切换窗口内看门狗静默

cutover 在停服务**之前**落 `/tmp/openclaw-handoff/switching`：
`system_health.sh` 见到标记直接静默退出，`gateway-watchdog.py` 见到则返回空不探测。
原因：只停 timer 拦不住**已在跑的 oneshot** —— 2026-11-11 21:22 交接瞬间曾误报
「18789 未监听 + 7/8」。abort 回退时删除该标记（服务会被拉起）。

2026-11-14 补第二道闸：**发送前复检**。开头的检查只能挡住「标记已存在时才开跑」的
轮次；已开跑的那一轮常常在 cutover 停服之后才探完，于是照常发出（实测 05:30
`ai-api 公网链路 530` 误报）。现在两套看门狗在真正 `send` 前再读一次标记，
命中就整轮静默、不写状态（新 VM 会接管后续告警）。`--force`（health）与
`--dry-run`（gateway）是人工验证口，不受抑制。


### 步骤顺序

| 步骤 | 作用 | 落点 / 端口 |
|---|---|---|
| Setup Node.js（`current`）+ checkout | 运行时基础 | — |
| rclone-install / rclone-config | 挂载 Dropbox 的前提 | — |
| Prefetch cold artifacts（后台并行） | 把与本轮状态无关的大块下载丢到后台：主包 `openclaw.tar.gz`（9.3GB / 实测 54s）+ 三个固定 tag 的网关镜像（omniroute 35.7s、rss-to-telegram ~20s、qoder2api-hub），与挂载 / Tailscale / 装 OpenClaw / 解包重叠。产物先写 `.part` 再 mv、`rc` 文件最后落，消费方读不到半截；**纯增益**，预取失败或没跑完，消费方按原路自己下载 | `/tmp/openclaw-prefetch/` |
| Mount Dropbox | `rclone mount dropbox: /dropbox`（**runner 身份挂载**：root 挂载会在 token 刷新时把 conf 改成 root:600，导致后续上传 EACCES）；VFS 上限 2G、`--attr-timeout 1m`、`--poll-interval 0` | `/dropbox`，日志 `/opt/logs/rclone-dropbox.log` |
| Install OpenClaw | `install.sh --no-onboard` → 恢复 `~/.openclaw`（等 prefetch 收尾 → **单趟**解包 + 盘上判据）→ `npm i -g clawhub` | `~/.openclaw` |
| Restore skill symlink for proactivity | proactivity 真实状态落 `~/.openclaw/workspace/skills-data/proactivity`，`~/proactivity` 只是兼容软链 | — |
| Setup / Enable Tailscale | ephemeral 节点、固定主机名 `openclaw`、开启 SSH 与 Exit Node | `ssh runner@openclaw` |
| Prepare runtime env | 生成 `~/runtime-env.sh` 并设为 `BASH_ENV`：加载 `~/.openclaw/.env`、继承 runner add_path、本地化 gh/git 认证 | — |
| Install / Run Cloudflared Tunnel | 命名隧道 `oc`（`ai-api` 在网关步骤起） | `oc.<VD>.eu.org`→18789 |
| Run rss-to-telegram container | `rongronggg9/rss-to-telegram:latest`，启动门禁 = 独立 bot secret `TELEGRAM_BOT_TOKEN_RSS_SB_BOT`（未配置则跳过启动，本轮不产生数据、最终归档也跳过上传） | 数据 `/tmp/local_rsstt`（config + data） |
| Run AI API gateway | OmniRoute 单后端（回退链：CliRelay → CLIProxyAPI） | 20128 → 隧道 `ai-api` |
| Run workbuddy-gateway | 先查 GitHub Releases 决定是否更新二进制，再 `serve`（见第八节） | 8318（仅本机） |
| Run OpenClaw | 自愈主流程（本文第三、四章） | 18789 |
| Start background archive loop | 每 20 分钟归档 `~/.openclaw` + AI 网关数据（`flock` 防重入） | Dropbox |
| Keep alive → Stop OpenClaw and Final Archive → Notify OpenClaw final archive result → Trigger next OpenClaw run | 收尾与自我接力 | — |

> rss-to-telegram 带一层自愈：登录被 `AuthKeyDuplicatedError` 判废时删掉 `bot.session*` 重启一次并立即归档。
> Sub-Store 不在本 workflow 内运行（2026-09-13 移除）：本 workflow 无任何步骤消费它，原先只是借这台 runner 当第二宿主；服务由 `sub-store.yml` 单宿主提供。

## 一、设计目标

1. **主状态包永远可用**：`openclaw.tar.gz` 只由健康运行写入，任何时刻恢复它都能得到一个可启动的状态。
2. **启动失败自动分层处置**：修复 → 降级，逐层升级，无需人工介入。
3. **失败现场可追溯**：失败诊断（日志摘要）进失败通知，不污染健康数据；
   失败状态不再上传云端（2026-10-11 起），本地现场随 runner 回收。
4. **降级有代价控制**：只有确认必要后才清空状态库，且被清数据保留可恢复副本。

## 二、运行链路

```
前置（零章）：Node → checkout → rclone 挂载 /dropbox → 安装 OpenClaw（install.sh --no-onboard）
        │
        ▼
恢复主状态包 openclaw.tar.gz（永远 = 最后一次健康状态；
缺失或校验失败 → 回退为目录同步 dropbox:self-hosted/openclaw）
        │
        ▼
┌── 机制① 预检门（机制② doctor 显式退出码）──────────────┐
│  config validate（当前版本）                              │
│    ├─ 通过 → doctor --fix → 网关启动                      │
│    └─ 失败 → doctor --fix 修复 → 复检                     │
│             ├─ 通过 → 网关启动                            │
│             └─ 仍失败 → 跳过网关启动，进入回退             │
└─────────────────────────────────────────────────────────┘
        │
        ▼
健康检查（180s）
  ├─ 成功 → 记录 known-good → 覆盖主包
  │
  └─ 失败 → 机制④ 回退 known-good 版本
              │
              ├─ 回退版 config validate
              │    ├─ 通过 → doctor --fix → 网关重启 → 健康检查
              │    └─ 失败 → doctor --fix 修复 → 复检
              │              ├─ 通过 → 网关重启 → 健康检查
              │              └─ 仍失败 → 状态库移位（干净启动面）
              │                         → doctor --fix → 网关重启 → 健康检查
              │
              └─ 健康检查仍失败 → 失败通知（含诊断）+ 触发下一轮
```

## 三、五层机制

### 机制①：预检门（config validate）

- 网关启动前，以**当前安装版本**运行 `openclaw config validate`。
- **通过**：运行 `doctor --fix`（迁移官方废弃路径、剥除未知键），然后启动网关。
- **失败**：先运行 `doctor --fix` 尝试修复并**复检**；修复成功则照常启动，仍失败则跳过网关启动、进入回退。
- doctor 在预检门内最多运行一次（`DOCTOR_RAN` 标记防重复）。
- 两次 validate 的错误详情均写入步骤日志与失败通知。
- 启动动作固定为 `openclaw gateway install --force` + `openclaw gateway restart`，任一失败即本阶段失败。
- 阶段标记 `FAIL_STAGE` 依次写入 `/tmp/run-openclaw-meta.env`：
  `preflight_doctor` → `config_validate` → `initial_start` → `fallback_reinstall`，
  失败通知里映射为中文：预检修复 / 配置校验 / 首次启动 / 回退重装。

### 机制②：修复动作显式化

- 所有 `doctor --fix` 调用均记录退出码：`openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"`。
- doctor 的失败原因会进入失败通知的关键日志摘要。

### 健康检查判据（`wait_for_openclaw_health`）

默认 180 秒、每 5 秒一轮，判据是**端口 + HTTP** 双条件：

1. `18789` 处于 LISTEN（`sudo lsof -Pi :18789 -sTCP:LISTEN`）；
2. `http://127.0.0.1:18789/health` 返回 200。

只 LISTEN 未 200 时，若 journal 已出现 `[gateway] ready` 则继续宽限等待；超时判失败，
随后 `dump_openclaw_diagnostics` 打印 systemd status、journal（近 10 分钟）与
`/tmp/openclaw/openclaw-*.log` 最新两个文件的尾部 80 行。

### 机制③：主包单区

只有 `openclaw.tar.gz` 一个对象，平铺在 `self-hosted/` 根目录，与同层的
`rsstt.tar.gz` / `zcode.tar.gz` / `OmniRoute.tar.gz` 等归档风格一致。

| 路径（Dropbox `self-hosted/` 下） | 内容 | 写入者 | 保留 |
|---|---|---|---|
| `openclaw.tar.gz` | 主状态包，**永远是最后一次健康状态** | 仅健康运行 | 永久覆盖更新 |

- **打包前必须真的把网关停下来**（2026-10-21 修复）：`openclaw gateway stop` 在非交互
  shell 下会**拒绝执行**（提示 “…or re-run with --force…”），而收尾步骤原先写的是
  `openclaw gateway stop || echo "already stopped or command failed."` —— 失败被 `||` 吃成
  静默，这条停止命令**从来没有生效过**：60s 轮询只是干等满 60 秒（run 39515245551 实证
  05:00:44 拒绝 → 05:01:45 才走下一步），最终归档全程对着仍在写盘的 `~/.openclaw` 打包。
  现在用 `timeout 60 openclaw gateway stop --force`（`--force` 正是 CLI 给非交互 shell 的
  显式确认），把等待结果落成 `GW_DOWN` 断言：60s 内没退 → `systemctl --user stop --no-block`
  再等 120s → 仍在则 `systemctl --user kill -s KILL` 等 10s → 全链失败打 `::warning::`，
  让「对着活树打包」变成可见事件而不是静默常态。
  > 升级必须走 systemctl 而不是 pkill：单元是 `Restart=always` / `RestartSec=5`，直接杀进程
  > 会被拉回来；显式 stop 作业内的结束不算崩溃，不触发重启。`TimeoutStopSec=330`，所以
  > 同步 `systemctl stop` 会把下线时长交给最坏情况 —— 用 `--no-block` + 自带轮询封顶。
  > 停止与否**不影响上传门**：`HEALTHY_RUN` 读的是 `/tmp/run-openclaw-meta.env` 里启动时
  > 记录的 `RECORDED_SUCCESSFUL_OPENCLAW_VERSION=` 标记，不是实时健康探针。
- 版本化快照与失败现场包（`openclaw-failed-*`）均已于 2026-10-11 移除（主人拍板，省配额）：
  前者是主包的服务端副本（主包坏它也坏），后者保存的是**坏状态**，两者兜底价值都很有限，
  却各自常驻一份 4.2GB+ 云端空间。
- 失败/不健康运行**不归档不上传**：主包保持最后健康状态；本地故障状态随 runner 回收，
  故障诊断由失败通知（含日志摘要）承载。
- **保留清理必须按前缀过滤后再排序删除**：本区与 rsstt/zcode 等归档同处根目录，
  直接 `lsf | tail` 会把别人的包删掉。
- 除这三区外，最终归档还上传 `dropbox:self-hosted/rsstt.tar.gz`（rss-to-telegram 数据）
  与 AI 网关归档（见第六节）。
- rsstt 归档带空数据保护：数据目录内只有占位 `.keep`（本轮容器没起来）时不打包、不上传，
  只发一条「归档跳过」告警——空包上传会用几百字节的 tar 覆盖掉云端正常归档。
- **派生副本 7 天自动清理（2026-10-21）**：归档脚本在 rsync 暂存**之前**剪两类只增不减的
  派生物 —— `backups/` 下的顶层时间戳条目、以及全树 `*.bak`（状态库迁移与 doctor 留下的
  同名副本，单个 agent 库 0.5–0.8GB）。判龄只认 `mtime +7`，不解析目录名：`backups/` 下
  命名格式不止一种（`YYYYMMDD-HHMM` / `YYYYMMDD-HHMM-tag` / `YYMM-DDHHMM`），按名字剪必漏。
  剪在打包之前才有意义：这两类原先会被打进主包、下一轮原样还原回来，等于自我放大
  （实测 4.69GB + 1.55GB，约占包体四成，且每跑一次 doctor 再加 ~130MB）。
  清理是增益、不拦归档：计数与字节只在真剪到东西时打一行 `openclaw_pruned_derived_copies`。
  天数可用 `OPENCLAW_PRUNE_DAYS` 覆盖，默认 7。
- **完整性校验（取代缩水保护）**：打包前校验关键文件必须存在且非空 —— 主包是
  `.openclaw/openclaw.json`，zcode 是 `.zcode/cli/db/db.sqlite`（会话正文）、
  `.zcode/v2/tasks-index.sqlite`（侧栏列表）与 `.zcode/server/zcode-server.cjs`（服务端 bundle）。
  缺失即判「状态不全」，以退出码 4 中止本次归档、不覆盖云端（判据在归档脚本内，周期与最终归档共用）。
  早先的判据是「新包不足云端现有包 60% 则拒绝覆盖」（缩水保护），已废止：体积本就不是
  「状态全不全」的判据，且以云端现有包为基准会被主动瘦身永久卡死 —— 排除调试转储后
  新包永远小于旧包，主包就此冻结、每 20 分钟重复一次告警（2026-09-12）。
- **zcode 归档的入包口径**：`~/.zcode` 下 `cli/`、`v2/`、`server/` 三棵子树整体入包。
  只排除真正的垃圾：`cli/log`（遥测日志）、`server/asset-cache/staging`（下载暂存，恒空）、
  `*.lock` / `*.pid`（进程锁，跨机还原无意义）。压缩后约 137MB。
  > **`cli/plugins/cache` 不排除** —— 名字像缓存，实为插件的**运行位置**（skill / 命令 / 脚本
  > 都从那里加载，如 `plugins/cache/zcode-plugins-official/browser-use/.../skills/`）；
  > ZCode 自己的存储分类表也把 `cli/plugins` 归 `runtimes`（不可清理）。
  > **`server/` 入包**是为了省掉每轮约 326MB 的重新下载；其中 `asset-cache/`（163MB）与
  > 顶层运行时内容重复（264/274 文件 sha256 一致），但它是安装器的「已下载」标记所在，
  > 删掉会触发重新下载 —— 与省下载的目的相反，故一并保留。
  > 早先的版本把 `cli/rollout`、`cli/exec` 当「调试转储」排除，等于切掉会话内容；同时漏掉
  > 整个 `v2/`（侧栏列表）与 `server/`。这是 2026-09-18「备份不齐全、会话仍丢」的根因。
- **`server/` 还原是条件性的**：仅当本地 `~/.zcode/server` **除 install.json/run 外无部署**时才从包内铺开。
  本地已有说明本轮已部署（且可能比包内新），覆盖等于把新版本降级成旧版本。
  2026-11-01 起还原前移到 Tailscale 接入之前（见下条），正常轮次还原时本地必然只有
  Seed identity 写的 install.json → 包内 `server/` 直接铺开，客户端接入零等待；
  「本地已有部署则保留」的判据仅在本步被重跑/手动触发时生效。
- **设备身份 `installationId` 先于客户端接入固定（2026-10-30）**：客户端「认设备」用的是
  server 上报的 `serverId`，真源是 `~/.zcode/server/install.json` 的 `installationId`
  （`host_id = remote:server:<installationId>`，侧栏任务全部 keyed 到它），hostname 只影响
  显示名。临时 runner 每轮重建时，`server/` 由客户端连接时部署并随机生成 `install.json`；
  若数据还原晚于客户端接入，在那里回钉历史 id 会造成同一轮内身份「先新后旧」→
  客户端弹「连接目标的身份已变化，是否作为新设备」。
  根治做法：历史 id 随仓库保存（`.github/scripts/openclaw/zcode-server-identity.json`），
  job 最前面、Tailscale 起来之前就铺好 `install.json`；客户端部署走
  `ensureServerInstallOwnership()` 的 `EEXIST → validate` 分支沿用该 id。
  还原步骤里的回钉降级为兜底（仅 seed 失效时才真正改盘）。
- **ZCode 数据还原先于 Tailscale 接入（2026-11-01，主人拍板）**：B2（2026-10-29）曾把还原
  后置到网关健康之后，实测两种事故形态：① 客户端经 Tailscale 先连上空数据 server、
  还原步骤随后 `rm -rf + cp -a` 把运行中服务脚下的库整个换掉，3.17.1 迁移时序被搅乱、
  projects 注册表清空 → 全量 `project.not-found`；② 有毒库（projects 空表）被归档循环
  传上云后，下一轮冷启动还原毒库复发同错。根治：`Restore ZCode data (先于 Tailscale 接入)`
  步骤移到 Seed identity 之后、所有 Tailscale 步骤之前，rclone-install/config 一并前移；
  还原后 server 首次打开的就是最终数据，不存在脚下换库。zcode.tar.gz 因此退出 Prefetch
  （消费方已前移，Prefetch 收口等待反而拉长接入前延迟），改同步下载。原位置只剩
  `Install auxiliary CLIs`（clawhub），护栏不变。
  > 客户端此前若已按别的身份确认过「作为新设备」，修复后首次连接可能仍需确认一次；
  > 此后 id 恒定，不再复发。
- **SQLite 取一致性快照**：`db.sqlite` 与 `tasks-index.sqlite` 用 `sqlite3 .backup` 从活库
  导出自包含单文件，随后丢掉 `-wal`/`-shm`。WAL 模式下数据可能全在 `-wal` 里 ——
  实测 `tasks-index.sqlite` 主文件仅 4KB、连 `tasks` 表都没有，3 行数据全在 716KB 的 `-wal` 中，
  单独拿走主文件会得到一个空库。`sqlite3` 不可用时退回 rsync 三文件副本（同样可用）。
- **还原后打印行数**：还原步骤末尾用 `sqlite3` 打印 `tasks-index` 与 `session` 的行数 ——
  只报「文件存在」无法区分空库与有库，行数是「还原是否真的成功」最直接的证据。
- **体积骤降只记录、不拦截**：新包不足云端 60% 时仅在日志留一行
  `ℹ️ 体积较云端下降超 40%`，照常覆盖。保留「包为什么变小了」的可追溯性，
  但不再拿它当拦截判据。
- **归档结果汇总**：各归档分支边归档边把结果（对象 / 结论 / 字节 / 备注）写进
  `/tmp/openclaw-final-archive-results.tsv`；最终归档结束后由
  独立步骤 `Notify OpenClaw final archive result` 渲染成一条通知。之所以不在归档步骤
  内直接发：该步骤多处 `exit 1`（预检失败 / 磁盘不足），写在末尾的通知会随之被跳过。
  临时包成功上传后即被删除，所以大小只能当场记、不能事后反推。

### 机制④：回退与降级守卫

- 回退版本由 `resolve_fallback_openclaw_version` 两级解析，来源写进 meta 的 `FALLBACK_VERSION_SOURCE`：
  ① `~/.openclaw/openclaw-known-good-version`（每次成功启动自动更新）→ `known_good_file`；
  ② `~/.openclaw/openclaw.json` 的 `.meta.lastTouchedVersion` → `meta_lastTouchedVersion`；
  两者都取不到则直接失败（`No fallback OpenClaw version found`）。
- 装好回退版本后，以**回退版本**再次 validate。
- validate 通过：`doctor --fix` → 网关重启 → 健康检查。
- validate 失败：先 `doctor --fix` 修复并复检；**仍失败** → 将 `~/.openclaw/state/openclaw.sqlite*`（含 -wal/-shm）整体移位为 `*.state-bak-<时间戳>`，让回退版本以全新状态库启动，再运行一次 doctor 完成初始化。
- 移位只发生在确认必要时；被移位的库是新版格式数据，升级回新版后改回原名可找回旧会话。

> **机制⑤（快照成对回滚）已于 2026-10-11 移除**（主人拍板）：快照是主包的服务端副本，
> 主包坏它也坏，兜底价值≈0。回退重装失败即通知人工介入，现场保留分析。

## 四、标准操作流程

### 升级（隐式跟踪 latest）

1. 新版本发布后，下一轮运行自动安装。
2. 预检门先验证：配置兼容 → 直接以新版运行；不兼容 → doctor 试修 → 仍不行则自动回退 known-good 版本，通知中含两次 validate 详情。
3. 稳定运行在新版本后，known-good 自动随之更新。

### 手动回退到指定版本

```bash
npm i -g openclaw@<目标版本>
# 若报 uses newer schema version：
mv ~/.openclaw/state/openclaw.sqlite{,.state-bak-$(date +%s)}   # 含 -wal/-shm
openclaw gateway restart
```

### 通知

通知种类与标题不在这里登记——用脚本现场枚举：

```bash
bash skills/telegram-notify-audit/scripts/list_notify.sh openclaw
```

版式见 [`telegram-notify.md`](telegram-notify.md)，档位见台账「OpenClaw Runner」行。
只记几条非显然、写错会出事的约定：

- **端口**：workbuddy-gateway 通知里的 `8318` 是实际绑定端口（上游默认 8317，与本仓库
  AI 网关撞车，启动显式 `-port 8318` 覆盖），不要写成上游默认值。
- **API Key**：等宽回显 `AI_GATEWAY_API_KEY`，取不到写「未取到」；`workbuddy*.json`
  的**内容**（真实 Access / Refresh Token）绝不上通知，`workbuddy-status.json` 是状态
  快照、不算凭据。
- **账号池 TSV 每一列都不许为空**（空值填 `-`）：制表符属 IFS 空白，中段空列会整体
  左移，曾把冷却数渲染成模型名（`免费模型 1 · 2`）。列序见 `run-workbuddy.sh` 注释。
- **数据源**：额度 / 状态 / 冷却取 `workbuddy-status.json`（jq）；免费模型**名单**走上游
  模型目录接口（不读 `modelStates`）。`quotaKnown=false` 写「额度未获取」而不是 0。
  冷却给绝对恢复时刻，账号级与模型级两层都给。
- **归档短名**：`obj_label` 把包名映射成中文短名；没有映射的（CliRelay / CLIProxyAPI /
  aigateway）原样显示文件名。
- **keepalive 两条**：T-15 是 `ℹ️ … 进入收尾`（普通档，预告，服务仍在线）；T-2 是
  `⛔ … 停机`（alert 档，请停手）。两条都是计划内，不是故障。
- **最终归档汇总**：标题按严重度 `❌ 全败 > ⚠️ 部分失败 > ✅ 完成`；档位全败 alert、
  其余普通。注意「全部跳过」目前会落到 ✅（实现待修）。
- **交接**：五态（准备中 / 继任者已就绪 / 已交出 / 聊天入口已恢复 / 交接完成），普通档；
  文案以 `handoff-notify.sh` 为准。

### 排障入口

- 运行中日志：`/tmp/run-openclaw-step.log`（`Run OpenClaw` 步骤 stdout/stderr 全量 tee，经 Tailscale SSH 可见）。
- 阶段与版本元数据：`/tmp/run-openclaw-meta.env`（`FAIL_STAGE` / `CURRENT_OPENCLAW_VERSION` /
  `FALLBACK_TARGET_VERSION` / `FALLBACK_VERSION_SOURCE` / `RECORDED_SUCCESSFUL_OPENCLAW_VERSION` / 各段耗时）。
- 归档循环日志：`/tmp/openclaw-archive-loop.log`；AI 网关生效后端：`/tmp/active-ai-backend.env`。
- 结束后拉日志：`gh run view --job <job_id> --repo jarvanh/actions --log`。

## 五、已知边界

| 场景 | 行为 |
|---|---|
| 配置被外部改成新旧版本都不认 | doctor --fix 尝试修复；失败则回退重装，仍失败需人工修复配置 |
| 云端主包结构/配置坏（空壳、截断、配置语义坏、secrets 解析不了） | 恢复侧判据（体积 ≥50MB / 解包后盘上有 `openclaw.json` / `config validate` 通过 / `secrets audit` unresolved=0）任一不过即自动 revision 回退：逐个历史版本（上限 100）验到第一个能过的为止；全部不可用才失败通知人工。四道判据在**同一趟解包**后读盘上文件（2026-10-21 去重：旧实现同一个包解三趟，白烧 ~180s CPU+IO） |
| 需要语义决策的迁移（agent roster 归属等） | doctor 与恢复机制拒绝代做决定，需人工显式声明 |
| 降级/状态库移位 | 会话索引丢失（工作区与配置不受影响）；`*.state-bak-*` / `*.broken-bak-*` 保留可恢复 |
| Dropbox 挂载失败 | 本轮以首次启动形态运行，不恢复历史状态 |

## 六、AI API 网关：OmniRoute 单后端 + 两级回退

> 对应步骤：「Run AI API gateway (backend: ${{ inputs.ai_backend }})」。
> 2026-10-11 迁移：CliRelay（compose 全栈）/ CLIProxyAPI（单容器回退）→ **OmniRoute 单后端**，
> 旧两后端降级为「自动回退链的第 2/3 级」，只在 OmniRoute 起不来时才上岗。

### 三后端降级链

| 后端 | 形态 | 宿主端口 | 数据目录 / 卷 | 归档 |
|---|---|---|---|---|
| **OmniRoute（主用）** | 单容器 `diegosouzapw/omniroute:3.8.51`，compose 部署（容器名 `omniroute`）；`extra_hosts: host.docker.internal:host-gateway` 回连本机上游（workbuddy 8318 / zcode2api 8319 / qingyan 8320 / trae 7864） | 20128 | 部署目录 `/home/runner/omniroute`（compose + `.env`）+ 命名卷 `omniroute_omniroute-data`（`/app/data`：`storage.sqlite` 渠道/入站 key/combo + `server.env` 加密根钥） | `dropbox:self-hosted/OmniRoute.tar.gz` |
| **CliRelay（回退 1）** | docker compose 全栈（项目名 `clirelay`）：`cli-proxy-api` 主容器 + postgres + redis + init + updater；compose 文件来自归档，bootstrap 时从上游 raw 下载（`kittors/CliRelay/main/docker-compose.yml`，镜像 `ghcr.io/kittors/clirelay:latest`） | 20128（容器内 8317） | `/tmp/local_CliRelay`（auths + config.yaml + .env + compose + sql/） | `dropbox:self-hosted/CliRelay.tar.gz` |
| **CLIProxyAPI（回退 2）** | 单容器 `eceasy/cli-proxy-api:latest` | 20128（容器内 8317） | `/tmp/local_CLIPProxyAPI`（config.yaml + auth-dir + stats.json） | `dropbox:self-hosted/CLIProxyAPI.tar.gz`（附带 clirelay auths 双保险） |

**三后端共用宿主 `127.0.0.1:20128`** —— OpenClaw 客户端（`openclaw.json`，随主包归档
持久化）硬编码指向 `127.0.0.1:20128/v1`，`ai-api` 隧道也是固定地址模式指向 20128
（`tunnels.conf`），因此**降级不换端口、不改客户端、不重建隧道**。CliRelay/CLIProxyAPI
官方容器原生端口 8317，回退路径用 `docker run` 侧 `-p 127.0.0.1:20128:8317` 改绑，
容器内仍是 8317，凭据/配置零改动。

`workflow_dispatch` 可用 `ai_backend` 手动指定（`auto` / `omniroute` / `clirelay` /
`cliproxyapi`）：**pinned 模式只跑指定后端，失败即失败、不降级**，便于定点验证单个后端；
`auto`（默认 / 定时触发）走完整降级链。

### 长上下文阈值调参（2026-10-12）

**现象**：OmniRoute 侧刷屏 `[503] runner-autoclaw/zai_glm-5.3-flash: provider — Provider
openai-compatible-chat-conn:99d395d6 circuit breaker is open (HTTP 503) (reset after 7s/11s)`。

**根因**：不是 autoclaw-proxy 挂了（短请求全 200、上游流式正常），而是「**慢被读成坏**」——
runner-autoclaw 承接 40 万 token 级上下文，实测 96 万字符请求 **61s**、常规长请求 **25~27s**
（proxy 日志 + 亲手压测两组数据）；而 OmniRoute 默认首事件 readiness 80s、provider 级失败计数
**DEGRADED=7 / OPEN=15**。几次慢请求 + 几次客户端 abort 就够把整条 provider 打进冷却。
日志里的反证很直接：`08:33:21 succeeded (26042ms)` 之后 **2 秒**断路器又 OPEN——单次是成功的，
触发的是 provider 级累积计数，不是单次超时。

**二次调参（同日 11:04，第一轮没治好）**：第一轮只调了 SSE readiness，漏了**更前置的
direct response-start 闸**（`OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS`，默认 30s）——它发生在
等响应头阶段，比任何 SSE 判据都早。日志坐证：`Direct response-start timeout (30000ms) on
pooled dispatcher ... host.docker.internal:8318` ×11，而 autoclaw 自身 3~4s 就 200
（11:04:15 succeeded → 11:04:41 被拒，中间没有任何 autoclaw 请求）——**熔断是沿 combo
从 workbuddy(8318) 传染过来的**，8318 的长上下文实测 24~85s 才出响应头。
→ 补两个：`OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS` 30s→**150s**、
`OMNIROUTE_DIRECT_RESPONSE_RETRY_TIMEOUT_MS` 10min→**600000**（不变，显式声明）。

**调参**（数值全部按实测延迟量级给，不拍脑袋；与早年 CliRelay 时代同口径——那次也是放宽）：

| 变量 | 默认 | 改为 | 理由 |
|---|---|---|---|
| `OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS` | 30s | **150s** | 等响应头比 SSE 更前置；实测 85s |
| `STREAM_READINESS_TIMEOUT_MS` | 80s | **600s** | step-5-preview 深度思考首字 p90 虽仅 21s，但实测 max 207s、同体量有 111s 成功先例；150s 会误杀长尾慢请求 |
| `STREAM_READINESS_MAX_TIMEOUT_MS` | 180s | **900s** | 大/重请求自适应上限，与 AGENT_GOAL 900s 对齐 |
| `OMNIROUTE_AGENT_GOAL_READINESS_MAX_TIMEOUT_MS` | 600s | **900s** | `/goal` agent 长跑 |
| `FETCH_TIMEOUT_MS` | 600s | **900s** | 上游总超时（长上下文+换号重试） |
| `STREAM_IDLE_TIMEOUT_MS` | 600s | **900s** | 流式静默上限 |
| `OMNIROUTE_CIRCUIT_BREAKER_API_KEY_THRESHOLD` | 12 | **30** | 连续失败阈值 |
| `OMNIROUTE_CIRCUIT_BREAKER_API_KEY_RESET_MS` | 30s | **60s** | 半开试探要跑完长请求 |
| `OMNIROUTE_PROVIDER_BREAKER_API_KEY_FAILURE_THRESHOLD` | 15 | **60** | 30min 窗口内失败才冷却 provider |
| `OMNIROUTE_PROVIDER_BREAKER_API_KEY_DEGRADATION_THRESHOLD` | 7 | **20** | 降级门槛 |
| `OMNIROUTE_PROVIDER_BREAKER_API_KEY_COOLDOWN_MS` | 600s | **180s** | 真故障时也较快恢复 |
| `OMNIROUTE_PROVIDER_BREAKER_API_KEY_MAX_BACKOFF_MULTIPLIER` | 4 | **2** | 退避倍率 |

> **排查方法论**（下次再遇到先做这三步）：① 看熔断前 30s 有没有**别的** provider 超时
> （`DIRECT_HEADERS` / `ProxyFetch` 字样）——combo 型会话会跨 provider 传染；② 对比
> "succeeded 之后多久又 OPEN"，若中间没有目标 provider 的请求，就是被牵连不是本体坏；
> ③ 直接从容器内 `node -e fetch(...)` 复现上游真实延迟，拿数据再调参，别默认值改默认值。

### 与 CliRelay 阈值的对齐（2026-10-12 复核）

CliRelay（回退后端）的口径是「**慢就等，绝不判死**」——`main-api-read-timeout-seconds: 1800`
（30 分钟）、**没有 provider 熔断器**（失败即透出）、流式 keep-alive 15s、首字节前可重试 1 次
（`streaming.bootstrap-retries: 1`）。

OmniRoute 有熔断器（CliRelay 没有），所以对齐策略 = **总超时口径对齐 + 熔断阈值放到足够宽
（别把慢判成坏）+ 缺失项补齐**：

| 项 | CliRelay | OmniRoute 现值 | 对齐 |
|---|---|---|---|
| 总读取/请求超时 | `main-api-read-timeout-seconds: 1800` | `REQUEST_TIMEOUT_MS` / `FETCH_TIMEOUT_MS` / `STREAM_IDLE_TIMEOUT_MS` / `STREAM_ACTIVE_TIMEOUT_MS` **四者均 1800s** | ✅ |
| 等响应头 | 同 read（1800） | `OMNIROUTE_DIRECT_HEADERS_TIMEOUT_MS=150s` | ✅（覆盖实测 85s） |
| SSE readiness | 同 read（1800） | 150s / 自适应 420s | ✅（覆盖实测 61s、85s） |
| 流式静默 | keep-alive 15s 主动续命 | `STREAM_IDLE_TIMEOUT_MS=1800s` | ✅ 已对齐（被动等待，够宽） |
| 流式总寿命 | 同 read（1800） | `STREAM_ACTIVE_TIMEOUT_MS=1800s` | ✅（原默认 1260000=21min，短 9min 会砍长任务 → 已补） |
| 首字节前重试 | `bootstrap-retries: 1` | 等价位 `OMNIROUTE_DIRECT_RESPONSE_RETRY_TIMEOUT_MS=600000` | ✅ 语义一致（30s 响应头超时→换新 socket 重试），无需额外开关 |
| provider 熔断 | **无此概念** | 阈值 30 / 60，冷却 3min | **有意放宽而非取消**（见下） |

> `STREAM_ACTIVE_TIMEOUT_MS` 是最后一处缺口：镜像默认 1260000（21min）比 CliRelay 的 1800s
> 短 9 分钟，长任务跑到第 21 分钟会被砍断。已显式设 1800s。
> 熔断**不取消**：CliRelay 没有熔断器所以无所谓；OmniRoute 有，若也去掉，"真死的 provider"
> 会让每个请求挂满 30 分钟。策略是阈值宽到慢请求打不到，同时保留对真故障的响应。

「首字节前重试」OmniRoute 无直接对应项，其等价位是 `OMNIROUTE_DIRECT_RESPONSE_RETRY_TIMEOUT_MS`
（600000，已显式声明）+ 熔断半开试探；不做强行对齐——CliRelay 没有熔断，给了重试也不会
把 provider 打进冷却，语义不同。

**三处必须同源**（少一处就会在特定路径上退回默认值、故障复发）：
1. 生产 compose `/home/runner/omniroute/docker-compose.yml`（`environment:` 块）；
2. workflow 的 compose heredoc（`restore_omniroute_data` 恢复路径）；
3. workflow 的 `bootstrap_omniroute()` 的 `docker run` 分支（归档缺失冷启动路径）。

> ⚠️ 2026-10-12 补记：改动只落在 (1)(2) 时，(3) 还是默认阈值——归档一失效就退回旧行为。
> 本轮已补齐。**验证口径**：DR 恢复后 `docker exec omniroute env | grep STREAM_READINESS`
> 应看到 `150000`，bootstrap 路径同理。

**归档同步**：`create-omniroute-archive.sh` 从 `/home/runner/omniroute` 直接取 compose，
所以重打归档即带新阈值；归档校验要看**包内** compose 参数条数（11 条），只看上传成功不算数。


### 启动链路

```
restore_omniroute_data()   ← Dropbox OmniRoute.tar.gz（缺失/无效 → bootstrap 空库 + alert 告警）
    → start_omniroute()    ← compose up（有 compose）或 docker run（纯 bootstrap）
    → /healthz 健康检查（150×2s，判据为任意 HTTP 响应码）
        ├─ 就绪 → ACTIVE_BACKEND=omniroute
        └─ 失败 → docker logs → docker rm -f omniroute → 记录 FALLBACK_REASON
                   → restore_clirelay_data → start_clirelay → 健康检查（120×2s）
                       ├─ 就绪 → ACTIVE_BACKEND=clirelay
                       └─ 失败 → compose logs + down -v → restore_cliproxyapi_data
                                 → start_cliproxyapi → 健康检查（120×2s）
                                       ├─ 就绪 → ACTIVE_BACKEND=cliproxyapi
                                       └─ 失败 → docker logs + exit 1（进入失败通知链路）
```

- 当前生效后端与回退原因写入 `/tmp/active-ai-backend.env`，供归档循环分支与启动通知读取。
- 数据准备失败不终止步骤（bootstrap 全新部署兜底，与旧 CliRelay 同口径）。
- 就绪后起 `ai-api` 命名隧道：`tunnels.sh ensure ai-api`（systemd 托管，固定地址模式
  → `127.0.0.1:20128`）；脚本缺失时回落 `nohup cloudflared tunnel run --url http://127.0.0.1:20128 ai-api`。
- ⚠️ **P0 加固（2026-10-11）**：归档明明存在却没恢复成 = 数据事故信号，必须炸响 ——
  `OMNIROUTE_ARCHIVE_SEEN=1` 且恢复失败即 `send_tg "$msg" alert`。当天事故正是此形态：
  cleanup 误删解包目录 → 恒报「缺少 docker-compose.yml/.env」→ 静默 bootstrap 空库上岗，
  全靠归档脚本 1MB 体积门才没让空库覆盖云端好包。

### 归档（按生效后端三选一）

「生效后端的数据才进对应归档」—— 防止降级态把 OmniRoute 空库刷进好包。
20 分钟后台归档循环与最终归档（Stop OpenClaw and Final Archive）均按 `ACTIVE_BACKEND` 分支。

- **OmniRoute（`/tmp/create-omniroute-archive.sh`）**：
  1. **SQLite 在线一致性快照**：容器在跑时 `docker exec omniroute` 调 better-sqlite3
     `.backup()` 产出 `storage-backup.sqlite`，落在同一数据卷内（失败非致命，活库三件套兜底）。
     > 容器内**没有 sqlite3 CLI**，只有 better-sqlite3（node 模块）—— 看板读用量也是这条路径。
     > 2026-11-07：备份/tar/pigz 三处突发一律 `nice -n 19 ionice -c3` 低优先级启动
     > （空闲零损耗、忙时让路），避免归档周期把 4 核机 load1 顶过 100%。
  2. **数据卷快照**：helper 容器（root）`tar czf /stage/data.tar.gz -C /data .` 整卷打包
     `/app/data`。镜像偶发启动慢导致单次失败（实测约 1/4 概率），**重试 4 次、指数退避
     20/40/60s** —— 失败多发生在 openclaw 8GB 主包上传窗口（IO/内存争抢），短间隔会连撞。
  3. 打进包：`docker-compose.yml` + `.env`（`chmod 600`）+ `data.tar.gz`；产物 `chmod 644`
     让 runner 身份的 rclone 读得到。
  4. 体积门 `MIN_SIZE=1MB`：空包 / 过小 / `tar -tzf` 失败一律 exit 非 0，**不覆盖云端好包**。
- **回退态（clirelay / cliproxyapi）**：沿用 `create-clirelay-archive.sh` /
  `create-cliproxyapi-archive.sh`（2026-10-11 从 `dcf418e` 父版本原样移植，逻辑不变）。
  - CliRelay 的统计/用量数据**没有独立文件，全在 `sql/*.sql` 里**（运行时主库是 PostgreSQL），
    故脚本会把归档内容清单（含每份文件大小）打进日志，判断「统计在不在包里」直接读日志。
  - pg_dump **必须先落临时文件、成功后再 `mv` 覆盖**，且输出过小（<200B）时同样不覆盖。
    > 旧实现直接重定向到 `clirelay-latest.sql`：shell 在 pg_dump 启动前就已截断旧 SQL，
    > 中途失败时磁盘上剩半截 dump、旧的好 SQL 已毁，日志却说「保留旧 SQL 继续」。
    > 半截 dump 仍能过体积校验并上传 → 下轮 `psql -v ON_ERROR_STOP=1` 导入失败 →
    > `start_clirelay` 返回 1 → 回退 CLIProxyAPI → 回退后 postgres 不启动、归档切去
    > CLIProxyAPI 脚本，**`CliRelay.tar.gz` 从此不再刷新，永久锁死在回退态**。一次瞬时
    > dump 失败即可触发（2026-09-19 修复）。
  - 临时 dump 文件放在部署目录根（不在 `sql/` 内）：`sql/` 整个目录会被打进包，
    失败残留混进去就污染了归档。

### 恢复链路（下轮 run）

`OmniRoute.tar.gz` 存在且含 `docker-compose.yml`/`.env` → 解压到 `/home/runner/omniroute`
→ 卷内 `data.tar.gz` 由 helper 容器解包进 `omniroute_omniroute-data`
→ **`storage-backup.sqlite` 优先 `mv` 成 `storage.sqlite`**（活库文件可能撕裂，只作兜底），
并删掉 `-wal`/`-shm` → `compose up -d`。归档探测失败会重试 3 次再定性，防止 rclone 瞬时
失败被误判成「无归档」而静默 bootstrap 空库（比恢复失败更危险 —— 连告警都立不起来）。

> `server.env`（`STORAGE_ENCRYPTION_KEY`）与 `storage.sqlite` **必须同代**，否则存量 key
> 解不开 —— 二者出自同一份归档，天然同代。

### 凭据体系（OmniRoute）

| 凭据 | 来源 | 作用域 |
|---|---|---|
| **面板登录 / admin API** | 部署目录 `.env` 的 `INITIAL_PASSWORD`（bootstrap 时 `openssl rand -base64 18` 生成，文件 `chmod 600`；**改密后 `INITIAL_PASSWORD` 仍有效**） | 打容器 IP 的 `/api/auth/login`；排障改渠道 `isActive` 走 `PATCH /api/providers/{connectionId}` |
| **JWT / API Key 签名** | `.env` 的 `JWT_SECRET` / `API_KEY_SECRET`（bootstrap 随机生成） | 会话与入站 key 签名，随归档持久化 |

- ⚠️ `PUT /api/provider-nodes/{id}` 会**静默丢弃** connections 数组（改连接状态无效），
  改 `isActive` 必须用 `PATCH /api/providers/{connectionId}`。
- ⚠️ 回退到 CliRelay / CLIProxyAPI 时是**另一套凭据**（面板 `CLIRELAY_ADMIN_PASSWORD`
  + 管理 API `config.yaml` 的 `remote-management.secret-key`，二者已统一为同一值）。
  降级态极少出现，需要时按旧口径处理：面板密码须满足复杂度规则（≥12 字符 + 大小写 +
  非字母数字），不合规会被 `clirelay-init` 替换；Dropbox 的 `CLIProxyAPI.tar.gz` 内
  config.yaml 的 secret-key 与之保持同步，保证回退后管理 API 密钥不回到旧值。

### clirelay-updater 版本提示（仅回退态会遇到）

- updater 跟踪 **main 分支最新 commit**（`CLIRELAY_UPDATE_CHANNEL=main`），而
  `ghcr.io/kittors/clirelay:latest` 镜像由上游 CI 构建——纯文档类 commit 可能跳过镜像构建，
  导致镜像落后于 main HEAD，**刚部署也可能提示「可用新版本 main-xxxxxx」**，属正常现象。
- updater 挂载 docker.sock（更新时主容器会短暂重启）；无状态文件（`.clirelay-updater-status.json`）
  表示尚未执行过更新。若不需要自动更新，可从 compose 移除 `clirelay-updater` 服务后重新归档。
## 七、远程访问入口（Tailscale）

Runner 每轮通过 Tailscale 加入 tailnet（ephemeral，`--hostname=openclaw` 固定 MagicDNS 名）：

| 入口 | 地址 | 说明 |
|---|---|---|
| SSH | `ssh runner@openclaw`（或 `@<TS_IP>`） | Tailscale SSH，`ts.env` 轮询等待名字收敛后才写入，避免主机名漂移 |
| 文件管理 | `sftp://runner@openclaw/` | Tailscale SSH 自带 SFTP，Finder ⌘K 原生挂载，零额外服务 |
| 远程桌面 | `openclaw.…ts.net:21118` | 本 workflow **不再部署 RustDesk**：该地址由 `TS_FQDN` 拼端口后随 runner 就绪通知推送，供 tailnet 内已装 RustDesk 的客户端点对点直连（不经中继）；无官方 ID/中继入口 |

- 节点属性：ephemeral、`tag:ci`，job 结束自动移除。`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET`
  任一缺失时 Tailscale 段整体跳过，只打一行告警（此时没有 SSH 入口）。
- `ts.env` 字段：`TS_HOST`（MagicDNS 短名）/ `TS_FQDN`（完整域名）/ `TS_IP` / `RUN_URL`。
  `--hostname` 重命名有传播延迟，步骤会轮询最多 15 次等待名字收敛为 `openclaw.*`，避免地址每轮漂移。
- AI 网关管理地址：`https://ai-api.${VD}.eu.org/manage`（cloudflared 命名隧道，与后端无关）。

### 出口节点（Exit Node）

runner 以 `tailscale set --ssh --hostname=openclaw --advertise-exit-node` 广播出口能力，
前置由步骤写入 `net.ipv4.ip_forward=1` 与 `net.ipv6.conf.all.forwarding=1`。
**广播 ≠ 生效**，路由需要批准（ephemeral 节点每轮都变）：

| 方式 | 做法 |
|---|---|
| 管理页手动 | `login.tailscale.com/admin/machines` → `openclaw` → Edit route settings → 勾选 `0.0.0.0/0`、`::/0`（每轮重批） |
| ACL 自动批准（推荐） | ACL 的 `autoApprovers.routes` 加 `"0.0.0.0/0": ["tag:ci"]`、`"::/0": ["tag:ci"]` |
| Tailscale API | `POST /api/v2/device/{device_id}/routes`，body `{"routes":["0.0.0.0/0","::/0"]}`（需 `TS_API_KEY`，节点 id 每轮变化） |

## 八、workbuddy-gateway（本机 AI 代理网关，独立于 OpenClaw 主网关）

> 对应步骤：「Run workbuddy-gateway (check update first, then serve)」与收尾的 `3b. Stopping workbuddy-gateway`。
> 上游：[`CangShui/workbuddy-gateway`](https://github.com/CangShui/workbuddy-gateway)（纯 Go 单二进制，
> 基于腾讯 CodeBuddy 协议的 OpenAI 兼容本地代理）。

### 数据落点

**运行整体落本地盘，Dropbox 只做持久化存放**（与 OpenClaw / OmniRoute 同口径）：

| 路径 | 内容 |
|---|---|
| `/tmp/local_workbuddy/workbuddy-gateway` | 二进制（**本地盘**，每轮按 GitHub Releases 的 `latest` 按需下载） |
| `/dropbox/self-hosted/workbuddy-gateway/` | **运行目录**（`serve` 的 cwd）。2026-10-06 起**数据直写 Dropbox**，不再有 `/tmp/local_workbuddy/data/` 运行副本（该目录已废弃、每轮不再创建） |
| `/dropbox/self-hosted/workbuddy-gateway/workbuddy*.json` | 凭据文件（**需人工 `login` 扫码生成**，见下）——Dropbox 侧为唯一真源，**运行期每 5 分钟同步进运行目录（带删除）** |
| `/dropbox/self-hosted/workbuddy-gateway/.installed-version` | 已安装版本号（用于比对是否需要更新） |
| `/dropbox/self-hosted/workbuddy-gateway/workbuddy-status.json` | 账号池状态快照（serve 写进运行目录，停止时回推） |
| `/dropbox/self-hosted/workbuddy-gateway/logs/` | 历轮 serve 日志留档（**只回推本轮新写的 `serve.log`**） |

> **两处刻意分离，各修一次线上故障**：
> 1. **二进制不能放 Dropbox**：`/dropbox` 是 rclone FUSE 挂载点，文件权限由
>    `--file-perms` 合成（默认 `0644`），`chmod +x` 在挂载点上是空操作 —— 从挂载点执行
>    一律 `nohup: failed to run command ...: Permission denied`（run 35177995322）。
> 2. **工作目录也不能直接用 Dropbox**：`serve` 会在 cwd 下高频读写 `logs/` 与
>    `workbuddy-status.json`，在 `--vfs-cache-mode full` 的挂载点上会卡住/被 runner 清理，
>    表现为「进程 2 秒内退出且 `serve.log` 为空」（run 35185511971）。
>
> 因此把整个运行目录挪到本地盘，靠 `rclone` 在 run 边界搬运数据（启动第 0 步拉、收尾 3b-1 推），
> 另有一个每 5 分钟的循环把 Dropbox 上的凭据同步进运行目录（见下文「凭据的周期同步」）。

### 启动链路

```
0. rclone copy dropbox:self-hosted/workbuddy-gateway → 本地运行目录（排除 logs/**、*.new；拉不到按空账号池启动）
查 GitHub Releases latest tag（匿名 API，每轮一次；失败则按现有二进制运行）
    ├─ 版本一致且二进制可执行 → 跳过下载
    └─ 否则下载 workbuddy-gateway-linux-amd64 到本地盘临时文件 → chmod 755 → 原子 mv 替换
→ pkill 掉上一轮可能残留的 serve → cd 到本地运行目录后 nohup 执行本地盘二进制 serve -addr 127.0.0.1 -port 8318
→ /health 探活（60×2s）
    ├─ 就绪且日志里账号池非空 → 🟢 已就绪
    ├─ 就绪但账号池为空       → ⚠️ 已启动 · 无可用账号（需人工扫码登录）
    ├─ 进程已退出             → ❌ 启动失败（提前结束等待，不空等满 120 秒）
    └─ 120 秒未监听           → ❌ 启动失败（附日志尾部 1200 字节）
→ 【仅首轮】逐凭据 GET {Base}/v2/enterprises/personal/models 取免费模型名 → 🟢/⚠️/❌ 通知
```

- **免费模型名取自上游「模型目录」接口，不靠探测**：`GET {Base}/v2/enterprises/personal/models`
  一次性返回全量模型的 `credits` 与促销，**只读、不耗额度、无回环限制**。
  国内站 Base `https://copilot.tencent.com`、国际站 Base `https://www.workbuddy.ai`，
  站点由凭据文件的 `edition` 决定，故**逐账号**各请求一次。
  免费判据照上游 `siteKnownFree`：倍率能解析出、且生效倍率为 0、且促销未过期。
  **只在首轮取**（结果不写回快照，纯展示）。
  任一账号取不到目录（超时/非 200/JSON 无 `models`）即整段降级为「免费模型 N」计数，
  绝不编造名字；取到但清单为空则如实写「免费模型 0」。
  > 早前版本用 serve 自带的 `POST /admin/probe` 逐账号 × 逐模型真实请求探测，
  > 实测 44 模型 × 4 账号耗时 **634 秒**，超过 serve 的 `WriteTimeout: 300s`
  > 而必然被截断，且真实消耗额度、可能触发限流冷却。已废弃。
  > 也不读快照 `modelStates` —— 它只在模型被真实请求过时才有键，默认 `unknown`，
  > 光读快照拿不到名字。

- **端口 8318**：20128 是 OpenClaw 主 AI 网关（OmniRoute）的宿主端口，
  二者并列互不干扰；本步骤**不**为本服务起 cloudflared 隧道，仅本机可达。
- **执行与工作目录都在本地盘**：`serve` 的**工作目录**必须是数据目录 —— 它靠
  「读取当前目录下所有 `workbuddy*.json`」组建账号池，状态文件与 `logs/` 也写在同目录。
  因此启动前先把 Dropbox 数据 `rclone copy` 成本地运行目录，再 `cd` 进去执行本地盘二进制：
  既拿到凭据，又避开在 FUSE 挂载点上高频写小文件。
- **凭据只能人工准备，但放进 Dropbox 后约 5 分钟自动生效**：`login` 是终端内嵌二维码扫码
  （或浏览器内完成登录），workflow 内无法完成。把凭据文件放到 **Dropbox** 的
  `self-hosted/workbuddy-gateway/` 即可 —— 运行期的每 5 分钟同步循环（带删除，删掉即退出池）
  会把它反映到运行目录，serve 再热加载（每 5 秒扫描 cwd），无需等下一轮；增删改凭据都免重启。
- 更新失败（查询或下载失败）**不阻塞启动**：沿用现有二进制起服务，原因写进通知的「原因」行。
- 失败原因按日志尾部区分「二进制不可执行 / 无有效凭据 / 其他启动即退」，
  不一律写成「凭据或参数错误」，便于照着通知直接定位。

### 停止（收尾）

`workbuddy-gateway` 是**宿主进程而非容器**，不会随 job 结束自动退出，故收尾步骤显式停止：

```
kill $(cat /tmp/workbuddy-serve.pid)  →  pkill -f "<bin> serve" 兜底
→ 轮询 30 秒等优雅退出（写完状态快照）
→ 仍未退出则 pkill -9
→ 复检残留：无残留发 ⛔ 已停止；仍有残留发 ⚠️ 已停止 · 进程残留
→ rclone copy 本地运行目录 → dropbox:self-hosted/workbuddy-gateway（回推状态快照与本轮日志）
```

运行目录在本地盘、每轮重建，所以停止后必须**回推**一次，否则状态快照与本轮 `serve.log`
随 runner 销毁。回推用 `rclone copy`（单向、只增不删）而非 `sync` —— 保留 Dropbox 上的
历轮日志；回推失败只发 ⚠️ 提示，不影响停止结论。归档循环与最终归档只覆盖 OpenClaw 主包、
AI 网关与 rsstt，不涉及本服务。

### 凭据的周期同步（每 5 分钟）

`serve` 只扫描**自己的 cwd**，且启动后只认当时那份快照 —— 你在运行期往 Dropbox 新增或删除凭据，
serve 根本看不到，最快也要等下一轮（≈5.7 小时）。为此在「Start background archive loop」里
额外起一个常驻循环（`/tmp/workbuddy-cred-sync.sh`，日志 `/tmp/workbuddy-cred-sync.log`）：

```
每 300 秒 → rclone sync dropbox:self-hosted/workbuddy-gateway → 本地运行目录
           --filter '- workbuddy-status.json'     排除 serve 自建的状态快照
           --filter '+ workbuddy*.json'           凭据：唯一进入同步的文件
           --filter '- **'                        其余一律排除（二进制、模型缓存、logs/ 等）
```

- **Dropbox 是凭据的唯一真源，带删除**：你在 Dropbox 删掉某个 `workbuddy*.json`，
  下一 tick 本地同步移除，账号随之退出池；改（覆盖）同理。
- **必须显式排除 `workbuddy-status.json`**：`workbuddy*.json` 这个 glob 会把它一起匹配进来
  ——它正是 serve 运行期高频重写的状态快照，`sync --delete` 会在每轮把它删掉
  （已用真机 rclone 反证：不加这条排除规则，该文件确实每轮被 `Deleted`）。
- **用 `--filter` 而非 `--include` + `--exclude`**：rclone 官方明确警告混用 include/exclude
  结果不可预期，`--filter` 按序求值（首个命中即定）才是确定的。
- **同步完即生效，无需重启**：serve 每 5 秒扫描 cwd 热加载凭据。所以「你改 Dropbox」到
  「本地生效」最坏约 5 分钟（循环周期）+ 5 秒（serve 扫描），通知里的账号池构成下一轮会体现。
- **用 per-file 锁，不共用归档锁**：本循环周期短，与每 20 分钟的归档抢同一把锁会互相拖慢。
- **失败不发通知**：抢不到锁跳过本轮、rclone 失败只记日志 —— 你随时可以重试，下一 tick 就同步，
  且收尾 3b 仍会把运行目录整体回推。
- **拉起循环后立即同步跑一次探针**（`--- initial workbuddy credential sync probe ---`）：
  后台循环的 stdout 只进 `/tmp/workbuddy-cred-sync.log`（在 runner 上，随轮次销毁），
  而收尾打印只在**跑满一整轮**时才执行 —— 被取消的轮次收尾步骤会被跳过，等于看不到任何证据。
  探针把同参数的 sync 结果直接打进 step 日志，任何轮次都留证：
  `Checks: N/N` 即纳入同步的凭据数，`✅ probe ok` 表示连上 Dropbox 且成功。
- **收尾会打印循环日志尾部**（`--- workbuddy-cred-sync.log tail ---`）与运行目录下的
  `workbuddy*.json` 清单，用来确认这段时间里同步是否真的在发生。
  （⚠️ `workbuddy-cred-sync` 已于 2026-10-06 停用移除，凭据不再需要双向同步 ——
   见 `services.sh` 同款注释；此处仅作历史背景保留。）

### 排障入口

- 本轮实时日志：`/dropbox/self-hosted/workbuddy-gateway/logs/serve.log`（unit 的 `StandardOutput` 直写挂账点，不再回推）。
- 账号池状态：`/dropbox/self-hosted/workbuddy-gateway/workbuddy-status.json`，或 `workbuddy-gateway monitor` 前台刷新。
  想看某账号某个模型到底免费还是收费：直接 `curl` 上游模型目录接口
  （`GET {Base}/v2/enterprises/personal/models`，带凭据文件里的 `accessToken`），
  看该模型的 `credits` 与 `modelPromotions` —— 口径与通知里的免费名单一致，且不耗额度。
  快照 `accounts[].modelStates` 只在模型被真实请求过时才有键（默认 `unknown`），
  只适合查「实际用过的」模型。
- 凭据同步日志：`/tmp/workbuddy-cred-sync.log`（每轮成功/跳过/失败各一行）。
- 本步骤元数据：`/tmp/run-workbuddy-meta.env`（`WB_STATE` / `WB_VERSION` / `WB_UPDATE` /
  `WB_REASON` / `WB_READY` / `WB_ACCOUNTS`）。
- 失败时日志尾部会**同时打到 stdout**（`--- serve.log tail (1200B) ---`），
  不必重跑一轮就能在 CI 日志里看到真实报错；`<pre>` 只进 Telegram。
- `Permission denied` 又出现时，先确认二进制路径不在 `/dropbox` 下
  （`ls -l /tmp/local_workbuddy/workbuddy-gateway`），挂载点上永远执行不了。
- 日志为空且进程秒退时，先确认 `cd` 的是本地运行目录而非 `/dropbox/...`。

> 说明：OpenClaw 主网关（OmniRoute `:20128` → cloudflared `ai-api` 隧道）见第六节；
> 本节服务是**并列的第二网关**，对外入口与归档一律互不涉及。

## 九、通知口径

版式规则见 [`telegram-notify.md`](telegram-notify.md)；档位见台账。**逐条标题不在这里**
（用 `list_notify.sh openclaw` 现场枚举）。下面只记非显然、写错会出事的约定。

### 9.1 workbuddy-gateway（`run-workbuddy.sh`）

- **接口** `http://127.0.0.1:8318/v1`（显式 `-port 8318`；上游默认 8317 与本仓库 AI
  网关撞车）。**API Key** 等宽回显 `AI_GATEWAY_API_KEY`，取不到写「未取到」，绝不编造。
- **绝不回显 `workbuddy*.json` 内容**（真实 Token）；`workbuddy-status.json` 是状态快照。
- **账号池 TSV 每列都填**（空值 `-`）：连续制表符会被 `read` 折叠，中段空列整体左移 —
  实测把冷却数当模型名渲染成 `免费模型 1 · <code>2</code>`。jq 侧填 `-`，渲染侧先还原
  空串再按「非空才并入」。列序：判定标记、凭据文件、站点、状态、账号级冷却、额度、
  免费模型名、模型冷却、Token 过期。
- **数据源**：状态 / 额度 / 冷却取 `workbuddy-status.json`（jq，键名由上游 Go 结构体
  json tag 固定）；免费模型名单走上游模型目录接口
  `GET {Base}/v2/enterprises/personal/models`（国内站 `copilot.tencent.com` / 国际站
  `www.workbuddy.ai`，按 `edition` 逐账号请求，只读不耗额度；判据：生效倍率 0 且促销
  未过期）。**不读 `modelStates`**（只含已实测模型），也不用 `POST /admin/probe`
  （逐模型真实请求，会超时且耗额度）。
- `quotaKnown=false` 写「额度未获取」，不显示 0（0 会与「额度耗尽」混淆）。
- **冷却给绝对时刻、两层都给**：账号级 `cooldownUntil`（仅 `state=cooldown` 时，
  `冷却 YYYY-MM-DD HH:MM`）；模型级取 `modelStates[].cooldownUntil` 最小值
  （`模型冷却 N · 最早 HH:MM 恢复`）。`cooldownMsg` 不进通知。
- **排序**：站点（国内站前）→ D 账号 → 131→156→175→176 → 其他原序（与看板
  `sortAccounts` 同规则）。`nickname` / `uid` 不进通知。
- serve 每 3 秒重写快照，jq 读到半截即失败：本轮账号池整段跳过，不发半条、也不据此
  判服务未就绪。
- **签到**：积分真源是 `POST {Origin}/v2/billing/meter/checkin-activity-status`
  （只读幂等），查询失败不编造。国际站无签到活动：启动步发最小活跃请求，429 落 defer
  文件并显示「活跃待重试 · 限流 HH:MM 后自动重试」。
- **就绪通知每轮都发**（接力轮也发；`/tmp` 标记文件仍写但不用于静默）。

### 9.2 trae2api（`run-trae2api.sh`）

- 版式与 workbuddy 同源，差异在数据来源：版本写 **Release tag**（取 fork Release 静态
  二进制，非源码构建）；账号池来自批量签到输出。
- `🩺 签到健康 · N`（N 是账号数）：条目主体是自然语言，走 `tg_add_entry_text`；全健康
  整段跳过。备注含上次成功日期、连续失败、设备换代、退避重试。
- 「🧾 原始输出」非空才渲染（容器日志 / 签到 stderr 尾部，1200 字节）。
- 模型倍率分节按规范 · 分节计数；数据源与 workbuddy 的独立第二条通知不同。
- 「用量 + 流水」走 `board.py usage-ledger <gateway> 12`，空输出静默跳过。

### 9.3 zcode2api（`run-zcode2api.sh`）

- **自检必须真发消息**：判据是上游返回助手 `content` 块（GLM 是思考模型，只回
  `thinking` 时按 text 判会误报）；healthz / 模型列表通不算。
- **Plan 通道降级如实报**：主探 `glm-5.3-flash` 全败后探 `bigmodel/GLM-5.3`；能通 =
  服务健康、仅 Plan 降级 → 🟡，且**降级轮每轮必报、不静默**。
- **中间态分类**：`quota` / `unavailable` → 🟡「全部通道额度耗尽」；`channel` → 🟡
  「回退通道已关闭」；`auth` → 🟠「鉴权失败」；❌ 只留给真正的启动失败。
- 失败态**不给**「接口 / 鉴权 / 模型」三行（服务已不在，指向已停进程会误导）。
- 账号池条目 `名称 · 通道 · 状态`，子行额度 / 有效期（东八区）/ 套餐 / 最近错误；
  数据源 admin API 脱敏视图，采集失败只少一节、不改结论。
- API Key 用独立 secret `ZCODE_GATEWAY_API_KEY`（与 workbuddy 分家）；取不到写「未取到」。

### 9.4 资产段（口径真源在看板）

`📅 资产 · 签到与有效期` 是就绪通知的内嵌段，数据源 `board.py assets <src>` CLI——口径
真源在看板，通知只引用。`run-qingyan.sh` 走同一 CLI 的 TSV 分支。看板改口径后跑
规范 · 资产段桥接冒烟。

### 9.5 AI 网关用量报告

`openclaw.yml` 的 `Notify AI gateway usage report`（普通档）：标题与内容来自
`board.py usage-report`，仓库内无标题字面量。
