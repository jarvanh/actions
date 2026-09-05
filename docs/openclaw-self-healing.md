# OpenClaw 自愈机制设计与操作手册

> 适用范围：`jarvanh/actions` 仓库 `.github/workflows/openclaw.yml`
> 配套阅读：本仓库工作流源码。本文描述当前生效的全部自愈行为与操作流程。

## 一、设计目标

1. **主状态包永远可用**：`openclaw.tar.gz` 只由健康运行写入，任何时刻恢复它都能得到一个可启动的状态。
2. **启动失败自动分层处置**：修复 → 降级 → 成对回滚，逐层升级，无需人工介入。
3. **失败现场可追溯**：损坏现场与失败状态独立留档，不污染健康数据。
4. **降级有代价控制**：只有确认必要后才清空状态库，且被清数据保留可恢复副本。

## 二、运行链路

```
安装 OpenClaw（install.sh，跟踪 latest）
        │
        ▼
恢复主状态包 openclaw.tar.gz（永远 = 最后一次健康状态）
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

### 机制②：修复动作显式化

- 所有 `doctor --fix` 调用均记录退出码：`openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"`。
- doctor 的失败原因会进入失败通知的关键日志摘要。

### 机制③：存储三区（主包 / 失败隔离 / 快照池）

| 路径（Dropbox `self-hosted/` 下） | 内容 | 写入者 | 保留 |
|---|---|---|---|
| `openclaw.tar.gz` | 主状态包，**永远是最后一次健康状态** | 仅健康运行 | 永久覆盖更新 |
| `failed/openclaw-failed-<UTC时间>.tar.gz` | 失败运行现场 | 仅失败运行 | 最新 2 份 |
| `snapshots/openclaw-<UTC日期-时分>-v<版本>.tar.gz` | 版本化健康快照 | 仅健康运行 | 最新 3 份 |

- 快照文件名内嵌版本号（`v<版本>` = 实际通过健康检查的二进制），可按版本检索。
- 失败运行不覆盖主包、不进快照池；归档循环（每 20 分钟）与最终归档写入同一份 failed 文件。

### 机制④：回退与降级守卫

- 启动失败后自动安装 known-good 版本（`~/.openclaw/openclaw-known-good-version`，每次成功启动自动更新），并以**回退版本**再次 validate。
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

### 排障入口

- 失败通知（🚨 OpenClaw 自愈失败）：FAIL_STAGE、当前/回退/采纳版本、DOCTOR_EXIT、关键错误摘要
  （`<pre>` 等宽块）、Tailscale SSH 入口。
- 启动通知（🟢 OpenClaw Runner SSH 入口）：SSH 入口、AI 网关后端（CliRelay / CLIProxyAPI + 回退原因）、
  RustDesk 直连地址、SFTP 文件管理入口、出口 IP/ISP/ASN。
- 全部通知为全库统一 HTML 版式（规范唯一真源见 [`telegram-notify.md`](telegram-notify.md)：
  emoji 标题 + ━━━ 分隔线 + 统一收尾行 `⏱ 已运行 X · 🔗 运行日志`），
  HTML 解析失败自动退化纯文本重发。
- 运行中日志：`/tmp/run-openclaw-step.log`（经 Tailscale SSH 可见）。
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
| **CliRelay（主用）** | docker compose 全栈：`cli-proxy-api` 主容器 + postgres + redis + init + updater（镜像 `ghcr.io/kittors/clirelay:latest`） | 8317 | `/tmp/local_CliRelay`（auths + config.yaml + .env + compose + sql/） | `dropbox:self-hosted/CliRelay.tar.gz` |
| **CLIProxyAPI（回退）** | 单容器 `eceasy/cli-proxy-api:latest` | 8317 | `/tmp/local_CLIPProxyAPI`（config.yaml + auth-dir + stats.json） | `dropbox:self-hosted/CLIProxyAPI.tar.gz`（附带 clirelay auths 双保险） |

两后端共用 8317 端口 → cloudflared `ai-api` 命名隧道（→ 127.0.0.1:8317）无需按后端切换。

### 启动链路

```
恢复 CliRelay.tar.gz（缺失/无效 → 从 CLIProxyAPI 数据 bootstrap 迁移）
    → compose up postgres → 等待 healthy → psql 导入 sql/*.sql（ON_ERROR_STOP=1）
    → compose up 全栈 → 8317 健康检查（120×2s）
        ├─ 就绪 → ACTIVE_BACKEND=clirelay
        └─ 失败 → compose logs + down -v → 记录 FALLBACK_REASON
                   → 恢复/复用 /tmp/local_CLIPProxyAPI → docker run cliproxyapi
                   → 8317 健康检查（120×2s）
                       ├─ 就绪 → ACTIVE_BACKEND=cliproxyapi
                       └─ 失败 → docker logs + exit 1（进入失败通知链路）
```

- 当前生效后端与回退原因写入 `/tmp/active-ai-backend.env`，供归档循环分支与启动通知读取。
- CliRelay 数据准备失败（归档缺失/校验失败/bootstrap 失败）不会终止步骤，直接走回退路径。

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
| 远程桌面（tailnet 内） | RustDesk 直连 `openclaw.…ts.net:21118` | 配置键 `direct-server='Y'` + `direct-access-port='21118'`（写入持久化 RustDesk2.toml），点对点不经中继 |
| 远程桌面（任意网络） | RustDesk ID + 密码 | 走官方 ID/中继服务器；ID 每轮变化，以 Telegram 报告推送为准 |

- `ts.env` 字段：`TS_HOST`（MagicDNS 短名）/ `TS_FQDN`（完整域名，RustDesk 直连用）/ `TS_IP` / `RUN_URL`。
- AI 网关管理地址：`https://ai-api.${VD}.eu.org/manage`（cloudflared 命名隧道，与后端无关）。
