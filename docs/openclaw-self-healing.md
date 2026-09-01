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

- 失败通知：FAIL_STAGE、当前/回退/采纳版本、DOCTOR_EXIT、关键错误摘要、tmate 链接。
- 运行中日志：`/tmp/run-openclaw-step.log`（经 tmate 可见）。
- 结束后拉日志：`gh run view --job <job_id> --repo jarvanh/actions --log`。

## 五、已知边界

| 场景 | 行为 |
|---|---|
| 配置被外部改成新旧版本都不认 | 快照池非空时由机制⑤成对恢复；池为空（首次部署窗口）需人工修复配置 |
| 快照池本身不可用（Dropbox 异常） | 依赖 Dropbox 自身版本历史，工作流无法自愈 |
| 需要语义决策的迁移（agent roster 归属等） | doctor 与恢复机制拒绝代做决定，需人工显式声明 |
| 降级/状态库移位 | 会话索引丢失（工作区与配置不受影响）；`*.state-bak-*` / `*.broken-bak-*` 保留可恢复 |
| Dropbox 挂载失败 | 本轮以首次启动形态运行，不恢复历史状态 |
