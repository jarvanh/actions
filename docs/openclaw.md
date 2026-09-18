# OpenClaw Runner：自愈机制 · 常驻服务 · 远程入口

> 适用范围：`jarvanh/actions` 仓库 `.github/workflows/openclaw.yml`
> 配套阅读：本仓库工作流源码。本文描述当前生效的自愈行为、常驻服务与操作流程。

## 零、运行概览

| 项 | 值 |
|---|---|
| 触发 | 定时 `cron: "*/5 * * * *"` + `workflow_dispatch`（手动） |
| 并发 | `concurrency: openclaw-singleton` —— 同时只跑一个 run |
| 单轮时长 | `Keep alive` 340 分钟；结束前 15 分钟推送「即将进入最终归档」预警 |
| 自我接力 | 末尾 `Trigger next OpenClaw run`：`gh workflow run openclaw.yml`（仅 keepalive 成功时触发） |
| 权限 | `contents: read` + `actions: write`（自我触发需要） |

### 步骤顺序

| 步骤 | 作用 | 落点 / 端口 |
|---|---|---|
| Setup Node.js（`current`）+ checkout | 运行时基础 | — |
| rclone-install / rclone-config | 挂载 Dropbox 的前提 | — |
| Mount Dropbox | `rclone mount dropbox: /dropbox`（**runner 身份挂载**：root 挂载会在 token 刷新时把 conf 改成 root:600，导致后续上传 EACCES）；VFS 上限 2G、`--attr-timeout 1m`、`--poll-interval 0` | `/dropbox`，日志 `/opt/logs/rclone-dropbox.log` |
| Install OpenClaw | `install.sh --no-onboard` → 恢复 `~/.openclaw` → `npm i -g @google/gemini-cli clawhub` | `~/.openclaw` |
| Restore skill symlink for proactivity | proactivity 真实状态落 `~/.openclaw/workspace/skills-data/proactivity`，`~/proactivity` 只是兼容软链 | — |
| Setup / Enable Tailscale | ephemeral 节点、固定主机名 `openclaw`、开启 SSH 与 Exit Node | `ssh runner@openclaw` |
| Prepare runtime env | 生成 `~/runtime-env.sh` 并设为 `BASH_ENV`：加载 `~/.openclaw/.env`、继承 runner add_path、本地化 gh/git 认证 | — |
| Install / Run Cloudflared Tunnel | 命名隧道 `oc`（`ai-api` 在网关步骤起） | `oc.<VD>.eu.org`→18789 |
| Run rss-to-telegram container | `rongronggg9/rss-to-telegram:latest`，启动门禁 = 独立 bot secret `TELEGRAM_BOT_TOKEN_RSS_SB_BOT`（未配置则跳过启动，本轮不产生数据、最终归档也跳过上传） | 数据 `/tmp/local_rsstt`（config + data） |
| Run AI API gateway | CliRelay 全栈优先 / CLIProxyAPI 回退 | 8317 → 隧道 `ai-api` |
| Run workbuddy-gateway | 先查 GitHub Releases 决定是否更新二进制，再 `serve`（见第八节） | 8318（仅本机） |
| Run OpenClaw | 自愈主流程（本文第三、四章） | 18789 |
| Start background archive loop | 每 20 分钟归档 `~/.openclaw` + AI 网关数据（`flock` 防重入） | Dropbox |
| Keep alive → Stop OpenClaw and Final Archive → Notify OpenClaw final archive result → Trigger next OpenClaw run | 收尾与自我接力 | — |

> rss-to-telegram 带一层自愈：登录被 `AuthKeyDuplicatedError` 判废时删掉 `bot.session*` 重启一次并立即归档。
> Sub-Store 不在本 workflow 内运行（2026-09-13 移除）：本 workflow 无任何步骤消费它，原先只是借这台 runner 当第二宿主；服务由 `sub-store.yml` 单宿主提供。

## 一、设计目标

1. **主状态包永远可用**：`openclaw.tar.gz` 只由健康运行写入，任何时刻恢复它都能得到一个可启动的状态。
2. **启动失败自动分层处置**：修复 → 降级 → 成对回滚，逐层升级，无需人工介入。
3. **失败现场可追溯**：损坏现场与失败状态独立留档，不污染健康数据。
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
  ├─ 成功 → 记录 known-good → 覆盖主包 → 写版本化快照（机制③）
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
              └─ 健康检查仍失败 → 机制⑤ 快照成对回滚
                    ├─ 成功 → 记录 known-good，恢复正常运行
                    └─ 失败 → 通知 + 失败现场隔离 + 触发下一轮
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
  `preflight_doctor` → `config_validate` → `initial_start` → `fallback_reinstall` → `snapshot_restore`，
  失败通知里映射为中文：预检修复 / 配置校验 / 首次启动 / 回退重装 / 快照回滚。

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

### 机制③：存储三区（主包 / 失败隔离 / 快照池）

| 路径（Dropbox `self-hosted/` 下） | 内容 | 写入者 | 保留 |
|---|---|---|---|
| `openclaw.tar.gz` | 主状态包，**永远是最后一次健康状态** | 仅健康运行 | 永久覆盖更新 |
| `failed/openclaw-failed-<UTC时间>.tar.gz` | 失败运行现场 | 仅失败运行 | 最新 2 份 |
| `snapshots/openclaw-<UTC日期-时分>-v<版本>.tar.gz` | 版本化健康快照 | 仅健康运行 | 最新 3 份 |

- 快照文件名内嵌版本号（`v<版本>` = 实际通过健康检查的二进制），可按版本检索。
- 失败运行不覆盖主包、不进快照池；归档循环（每 20 分钟）与最终归档写入同一份 failed 文件
  （循环把名字写进 `/tmp/failed-archive-name`，最终归档复用它，避免同一轮产生两份）。
- 除这三区外，最终归档还上传 `dropbox:self-hosted/rsstt.tar.gz`（rss-to-telegram 数据）
  与 AI 网关归档（见第六节）。
- rsstt 归档带空数据保护：数据目录内只有占位 `.keep`（本轮容器没起来）时不打包、不上传，
  只发一条「归档跳过」告警——空包上传会用几百字节的 tar 覆盖掉云端正常归档。
- **完整性校验（取代缩水保护）**：打包前校验关键文件必须存在且非空 —— 主包是
  `.openclaw/openclaw.json`，zcode 是 `.zcode/cli/db/db.sqlite`。缺失即判「状态不全」，
  以退出码 4 中止本次归档、不覆盖云端（判据在归档脚本内，周期与最终归档共用）。
  早先的判据是「新包不足云端现有包 60% 则拒绝覆盖」（缩水保护），已废止：体积本就不是
  「状态全不全」的判据，且以云端现有包为基准会被主动瘦身永久卡死 —— 排除调试转储后
  新包永远小于旧包，主包就此冻结、每 20 分钟重复一次告警（2026-09-12）。
- **体积骤降只记录、不拦截**：新包不足云端 60% 时仅在日志留一行
  `ℹ️ 体积较云端下降超 40%`，照常覆盖。保留「包为什么变小了」的可追溯性，
  但不再拿它当拦截判据。
- **归档结果汇总**：各归档分支边归档边把结果（对象 / 结论 / 字节 / 备注）写进
  `/tmp/openclaw-final-archive-results.tsv`，快照名另写一个文件；最终归档结束后由
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

### 机制⑤：快照成对回滚

- **触发**：回退版本重启后仍未通过健康检查——二进制回退已不足，按"状态 + 版本成对"恢复。
- **选快照**：优先取池内**回退目标版本**的最新快照（文件名 `-v<版本>` 精确匹配）；不存在则**采纳池内最新快照**——从文件名解析版本并安装对应二进制（快照池只收健康对，比可能过期的 known-good 文件更可信）。
- **动作**：停止网关（取消 systemd 自动重启循环）→ 当前状态整体移位为 `~/.openclaw.broken-bak-<时间戳>` → 解包快照至 `~/.openclaw` → 修复权限 → 网关重启 → 健康检查 → 记录 known-good。
- **失败路径**：快照池为空、下载失败、解包失败（自动还原现场）、回滚后仍不健康——均转入通知 + 失败现场隔离 + 触发下一轮；`~/.openclaw.broken-bak-*` 永远保留供人工分析。

## 四、标准操作流程

### 升级（隐式跟踪 latest）

1. 新版本发布后，下一轮运行自动安装。
2. 预检门先验证：配置兼容 → 直接以新版运行；不兼容 → doctor 试修 → 仍不行则自动回退 known-good 版本，通知中含两次 validate 详情。
3. 稳定运行在新版本后，known-good 与快照池自动随之更新。

### 手动回退到指定版本

```bash
npm i -g openclaw@<目标版本>
# 若报 uses newer schema version：
mv ~/.openclaw/state/openclaw.sqlite{,.state-bak-$(date +%s)}   # 含 -wal/-shm
openclaw gateway restart
```

### 从快照恢复（手动）

```bash
# 1. 列出快照
rclone lsf dropbox:self-hosted/snapshots/ --files-only

# 2a. 整包回滚：覆盖主包，下一轮运行自动恢复
rclone copyto "dropbox:self-hosted/snapshots/<快照名>.tar.gz" dropbox:self-hosted/openclaw.tar.gz

# 2b. 只取单个文件
rclone copyto "dropbox:self-hosted/snapshots/<快照名>.tar.gz" /tmp/restore.tar.gz
tar -xzf /tmp/restore.tar.gz -C /tmp/restore .openclaw/openclaw.json
```

> 快照名中的 `v<版本>` 是写下该状态的 OpenClaw 版本；整包回滚后如当前安装版本更新且拒绝该配置，预检门会自动导向回退，不会硬启动。

### 通知清单

| 通知 | 时机 | 内容 |
|---|---|---|
| `🟢 OpenClaw Runner 已就绪` | Tailscale SSH 步骤成功且 AI 网关已起 | 按套分节 + 树形条目：🔐 SSH（命令 / 备用 IP / 文件管理）、🖥️ RustDesk（直连 `FQDN:21118`）、🌐 出口网络（出口 IP / ISP / ASN / 位置）、🛰️ 出口节点（状态 / 三种批准方式 / API）、🤖 AI 网关（后端 + 回退原因） |
| `🚨 OpenClaw 自愈失败` | `Run OpenClaw` 步骤失败 | 步骤、Run ID、失败阶段（中文）、当前版本、Fallback + 来源、成功版本记录、三段耗时、SSH 调试入口、🧾 关键日志（`<pre>` 等宽块，最多 2800 字节） |
| `⚠️ 归档告警 · <对象>` | 20 分钟归档循环失败 | 问题（上传失败 / 归档失败 / 目录缺失 / 状态不全）+ 对象名 + Run ID |
| `⚠️ 最终归档告警 · <对象>` | 最终归档失败 | 同上；标题以「最终归档」区分阶段 |
| `✅ / ⚠️ / ❌ OpenClaw 最终归档结果` | 最终归档之后（`Notify OpenClaw final archive result`） | 结果计数（成功 / 失败 / 跳过）+ 合计大小 + 快照名 + 📦 归档明细（每个包一行：结论 + 大小 + 去向）；未产出明细时降级为「⚠️ 最终归档未完成」 |
| `⚠️ OpenClaw 即将进入最终归档` | keepalive 第 325 分钟 | 约 15 分钟后执行 `Stop OpenClaw and Final Archive` |
| `🟢 workbuddy-gateway 已就绪` | **首轮**启动步骤自检通过且账号池非空（接力轮不重复推，见下） | 账号池结论、版本、更新说明、接口地址、鉴权说明、🔑 凭据文件名、💳 逐账号（站点 / 状态 / 冷却时刻 · 额度 · 免费模型具体名称 · 模型冷却 N · 最早恢复 · Token 过期）、数据目录 |
| `⚠️ workbuddy-gateway 已启动 · 无可用账号` | 服务已监听但账号池为空 | 提示需人工扫码登录（`login` 无法在 workflow 内完成） |
| `❌ workbuddy-gateway 启动失败` | 进程启动即退，或 120 秒内未监听 8318 | 失败原因 + 🧾 原始输出（日志尾部 1200 字节） |
| `⛔ / ⚠️ workbuddy-gateway 已停止` | 收尾停止段落执行后 | 版本与数据目录；仍有进程残留时降级 ⚠️ |

> workbuddy 的就绪通知**只在首轮发**。本 workflow 由收尾步骤 `gh workflow run` 接力启动，
> 接力轮会把同一套启动逻辑再跑一遍——同一个服务、同一份账号池，通知内容与上一条完全相同。
> 判据是 `/tmp/workbuddy-serve-run-tag`（每 run 一台新 runner，重启即归零），
> 仅在服务真的起来时写；接力轮只往 CI 日志打一行 `ℹ️ …跳过重复的就绪通知`。
> 判定规则与写法见 [`telegram-notify.md`](telegram-notify.md) 4.4 节。

> 「接口」写 `http://127.0.0.1:8318/v1`。**注意区分两个「默认」**：workbuddy-gateway
> 上游 `-port` 默认值是 **8317**，与 CliRelay/CLIProxyAPI（OpenClaw 主网关）撞车，
> 故本步骤启动时显式传 `-port 8318` 覆盖 —— 通知里的端口是**实际绑定端口**，
> 不是上游默认值。「鉴权」恒写
> **仅回环监听，无需密钥** —— 启动命令不传 `-api-key` 且只绑 `127.0.0.1`，网关不做鉴权；
> 上游该参数默认空、本仓库也从未设置，**不得编造密钥值**。
> 「🔑 凭据」只列 `workbuddy*.json` 的**文件名**（真实 Access/Refresh Token 绝不上通知），
> 且排除 serve 自己写的状态快照 `workbuddy-status.json`。
> 「💳 账号池」的额度/状态/冷却取自 serve 写出的 `workbuddy-status.json`（**jq 解析**），
> **免费模型名单另走上游「模型目录」接口**（不读快照的 `modelStates`，理由见下）。
> 快照键名由上游 Go 结构体 `accountSnapshot` / `statusSnapshot` 的 json tag 固定
> （`path` / `edition` / `state` / `tokenExpiresAt` / `quotaRemaining` / `quotaKnown` /
> `isPaidUser` / `freeModels` / `modelCooldowns` / `modelStates`），比 `status` 子命令
> 给人类看的对齐表格更可靠 —— 后者字段名后跟多个空格、`过期时间` 还独立成行，解析脆且易漏。
> 中文状态名照上游 `monitor` 表格映射；额度格式照上游 `formatQuota`；
> `quotaKnown` 为 false 时写「额度未获取」而非 0（那只是还没查到，不是耗尽）；
> 快照里的 `nickname` / `uid` 不进通知。
> serve 每 3 秒重写该文件，可能读到半截导致 jq 失败 —— 失败即本轮账号池整段跳过。
> **冷却给「什么时候恢复」，账号级与模型级两层都给**：账号级取 `cooldownUntil`
> （只在 `state=cooldown` 时展示，写 `冷却 YYYY-MM-DD HH:MM`）；模型级取
> `modelStates[].cooldownUntil` 的**最小值**（`模型冷却 N · 最早 HH:MM 恢复`）。
> 一律给绝对时刻、不折算「还剩多久」—— 通知是快照，读者看到时相对时长已不准。
> `cooldownMsg` 与 `nickname` / `uid` 一样**不进通知**。
> 字段口径、目录接口与免费判据逐条见 [`telegram-notify.md`](telegram-notify.md) 2.5 节。

> `<对象>` 为归档短名：`OpenClaw 主包` / `ZCode` / `CliRelay` / `CLIProxyAPI` /
> `rss-to-telegram`。此前五类归档共用「OpenClaw 归档告警」一个标题，无法从标题
> 判断是哪个包出问题（看到标题会以为是主包，实际可能是 ZCode）。

全部通知为全库统一 HTML 版式（规范唯一真源见 [`telegram-notify.md`](telegram-notify.md)：
emoji 标题 + ━━━ 分隔线 + 键值/分节区 + 统一收尾行 `⏱ 已运行 X · 🔗 运行日志`），
一律走发送层 `send_tg`：429 按 `retry_after` 重试，**HTML 解析失败直接报错、不重发**。

### 排障入口

- 运行中日志：`/tmp/run-openclaw-step.log`（`Run OpenClaw` 步骤 stdout/stderr 全量 tee，经 Tailscale SSH 可见）。
- 阶段与版本元数据：`/tmp/run-openclaw-meta.env`（`FAIL_STAGE` / `CURRENT_OPENCLAW_VERSION` /
  `FALLBACK_TARGET_VERSION` / `FALLBACK_VERSION_SOURCE` / `RECORDED_SUCCESSFUL_OPENCLAW_VERSION` / 各段耗时）。
- 归档循环日志：`/tmp/openclaw-archive-loop.log`；AI 网关生效后端：`/tmp/active-ai-backend.env`。
- 结束后拉日志：`gh run view --job <job_id> --repo jarvanh/actions --log`。

## 五、已知边界

| 场景 | 行为 |
|---|---|
| 配置被外部改成新旧版本都不认 | 快照池非空时由机制⑤成对恢复；池为空（首次部署窗口）需人工修复配置 |
| 快照池本身不可用（Dropbox 异常） | 依赖 Dropbox 自身版本历史，工作流无法自愈 |
| 需要语义决策的迁移（agent roster 归属等） | doctor 与恢复机制拒绝代做决定，需人工显式声明 |
| 降级/状态库移位 | 会话索引丢失（工作区与配置不受影响）；`*.state-bak-*` / `*.broken-bak-*` 保留可恢复 |
| Dropbox 挂载失败 | 本轮以首次启动形态运行，不恢复历史状态 |

## 六、AI API 网关：CliRelay 全栈优先 + CLIProxyAPI 回退

> 对应步骤：「Run AI API gateway (CliRelay first, fallback CLIProxyAPI)」。

### 双后端策略

| 后端 | 形态 | 端口 | 数据目录 | 归档 |
|---|---|---|---|---|
| **CliRelay（主用）** | docker compose 全栈（项目名 `clirelay`）：`cli-proxy-api` 主容器 + postgres + redis + init + updater；compose 文件来自归档，bootstrap 时从上游 raw 下载（`kittors/CliRelay/main/docker-compose.yml`，镜像 `ghcr.io/kittors/clirelay:latest`） | 8317 | `/tmp/local_CliRelay`（auths + config.yaml + .env + compose + sql/） | `dropbox:self-hosted/CliRelay.tar.gz` |
| **CLIProxyAPI（回退）** | 单容器 `eceasy/cli-proxy-api:latest` | 8317 | `/tmp/local_CLIPProxyAPI`（config.yaml + auth-dir + stats.json） | `dropbox:self-hosted/CLIProxyAPI.tar.gz`（附带 clirelay auths 双保险） |

两后端共用 8317 端口 → cloudflared `ai-api` 命名隧道（→ 127.0.0.1:8317）无需按后端切换。

### 启动链路

```
恢复 CliRelay.tar.gz（缺失/无效 → 从 CLIProxyAPI 数据 bootstrap 迁移）
    → compose up postgres → pg_isready（30×2s）→ psql 导入最新 sql/*.sql（ON_ERROR_STOP=1）
    → compose up 全栈 → 8317 健康检查（120×2s，判据为任意 HTTP 响应码）
        ├─ 就绪 → ACTIVE_BACKEND=clirelay
        └─ 失败 → compose logs + down -v → 记录 FALLBACK_REASON
                   → 恢复/复用 /tmp/local_CLIPProxyAPI → docker run cliproxyapi
                   → 8317 健康检查（120×2s）
                       ├─ 就绪 → ACTIVE_BACKEND=cliproxyapi
                       └─ 失败 → docker logs + exit 1（进入失败通知链路）
```

- 当前生效后端与回退原因写入 `/tmp/active-ai-backend.env`，供归档循环分支与启动通知读取。
- CliRelay 数据准备失败（归档缺失/校验失败/bootstrap 失败）不会终止步骤，直接走回退路径。
- 就绪后重启 `ai-api` 命名隧道：`cloudflared tunnel run --protocol http2 --url http://127.0.0.1:8317 ai-api`。
- 收尾时先 `docker stop clirelay cli-proxy-api cliproxyapi`（compose 主容器名是 `cli-proxy-api`），
  postgres 保留到最终 pg_dump 完成后才 `compose down`。

### 归档双轨

- **主用（clirelay）**：`create-clirelay-archive.sh` —— postgres 运行中 `pg_dump` 刷新
  `sql/clirelay-latest.sql` → tar 打包 `auths/ + config.yaml + .env + docker-compose.yml + sql/`
  （**跳过 postgres-data/ redis-data 原始目录**：Redis 可重建，PG 走 SQL 导入恢复）→ `CliRelay.tar.gz`。
- **回退态（cliproxyapi）**：现有 `create-cliproxyapi-archive.sh` 逻辑不变，
  额外把 `/tmp/local_CliRelay/auths` 打进包内 `clirelay-auths/`（token 双保险，恢复侧忽略未知目录）。
- 20 分钟后台归档循环与最终归档（Stop OpenClaw and Final Archive）均按 `ACTIVE_BACKEND` 分支；
  最终归档顺序：pg_dump（postgres 尚在运行）→ 打包上传 → `compose down`。

### 恢复链路（下轮 run）

`CliRelay.tar.gz` 存在且含 `docker-compose.yml`/`.env` → 解压 → `compose up postgres`
→ `psql -v ON_ERROR_STOP=1 < sql/*.sql` → `compose up` 全栈。PG 数据卷不入包，每轮均为全新库，导入无冲突。

### 凭据体系（两套并存，勿混淆）

| 凭据 | 来源 | 作用域 |
|---|---|---|
| **面板登录**（`/manage/login`） | 用户名 `admin`，密码 = 部署 `.env` 的 `CLIRELAY_ADMIN_PASSWORD`（未预设时由 `clirelay-init` 首启自动生成并回写 `.env`，随归档持久化） | CliRelay 面板（独立账号体系，存 postgres，支持租户/角色/权限） |
| **管理 API**（`/v0/management`，Bearer） | `config.yaml` 的 `remote-management.secret-key`（明文写入后启动时自动哈希） | 管理 API；与 `~/.openclaw/.env` 的 `MANAGEMENT_KEY` 保持一致 |

- 两套密码已统一为同一值；`CLIRELAY_ADMIN_PASSWORD` 若要预设必须满足复杂度规则
  （≥12 字符 + 大小写 + 非字母数字），不合规会被 `clirelay-init` 替换。
- Dropbox 的 `CLIProxyAPI.tar.gz` 内 config.yaml 的 secret-key 也保持同步，
  保证回退恢复后的管理 API 密钥不回退到旧值。
- 统计/用量/审计数据存 postgres（本地 `data/` SQLite 为空），随 pg_dump 进入归档，不丢失。

### clirelay-updater 版本提示（已知现象）

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
| 远程桌面 | `openclaw.…ts.net:21118` | 本 workflow **不再部署 RustDesk**：该地址由 `TS_FQDN` 拼端口后随「🟢 OpenClaw Runner 已就绪」推送，供 tailnet 内已装 RustDesk 的客户端点对点直连（不经中继）；无官方 ID/中继入口 |

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

**运行整体落本地盘，Dropbox 只做持久化存放**（与 OpenClaw / CliRelay 同口径）：

| 路径 | 内容 |
|---|---|
| `/tmp/local_workbuddy/workbuddy-gateway` | 二进制（**本地盘**，每轮按 GitHub Releases 的 `latest` 按需下载） |
| `/tmp/local_workbuddy/data/` | **本轮运行目录**（`serve` 的 cwd），起前从 Dropbox 拉、停后回推 |
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

- **端口 8318**：8317 已被 CliRelay / CLIProxyAPI 占用（OpenClaw 主 AI 网关），
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

### 排障入口

- 本轮实时日志：`/tmp/local_workbuddy/data/logs/serve.log`（停止后回推到 Dropbox 同路径）。
- 账号池状态：运行目录下 `workbuddy-status.json`，或 `workbuddy-gateway monitor` 前台刷新。
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

> 说明：OpenClaw 主网关（CliRelay `:8317` → cloudflared `ai-api` 隧道）见第六节；
> 本节服务是**并列的第二网关**，对外入口与归档一律互不涉及。
