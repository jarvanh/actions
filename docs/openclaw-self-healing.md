# OpenClaw 自愈机制设计与操作手册

> 适用范围：`jarvanh/actions` 仓库 `.github/workflows/openclaw.yml`
> 背景：2026-08-31 故障复盘（见仓库提交历史与本地复盘文档）。当次故障中三层既有防线（doctor 自动修复、版本回退、last-known-good 恢复）全部失效，本套自愈机制针对每个失效面做了结构性补强。

## 一、总览

启动链路现在是：

```
安装 OpenClaw（install.sh，跟踪 latest）
        │
        ▼
恢复 ~/.openclaw（Dropbox 状态包）
        │
        ▼
┌── 机制①：config validate 预检门 ──┐
│  通过 → doctor --fix → 网关启动     │
│  失败 → 跳过 doctor 和网关启动      │
│         （状态零改动，保住回退能力）│
└───────────────────────────────────┘
        │
        ▼
健康检查（180s）
  ├─ 成功 → 记录 known-good 版本 → 正常运行 → 归档时打版本化快照（机制③）
  └─ 失败 → 机制④：回退 known-good 版本
              ├─ 回退版本 config validate 失败 → 先 doctor 试修复检（机制②）
              │    └─ 仍失败 → 状态库自动移位（机制④，不限 schema 冲突）→ doctor 初始化
              └─ 网关重启 → 健康检查
                   └─ 仍失败 → 机制⑤：自动快照回滚（状态+版本成对恢复）
                        └─ 仍失败 → 通知 + 归档 + 触发下一轮
```

## 二、机制详解

### 机制①：升级预检门（config validate fail-fast）

- **位置**：`Run OpenClaw` 步骤内，`fix_openclaw_permissions` 之后、`doctor --fix` 之前。
- **动作**：运行 `openclaw config validate`。通过 → 照常跑 doctor、启动网关；**不通过 → 先尝试 `doctor --fix` 修复并复检**（doctor 能剥除未知键并迁移官方废弃路径，修好则直接以当前版本启动，无需回退）；**复检仍不通过 → 跳过网关启动**，进入 known-good 回退分支。
- **为什么不禁止 doctor**：8-31 复盘时曾禁掉 doctor（它做状态库单向迁移，会让旧版回退失效）。引入机制④/⑤后该风险已被兜住：迁移过的库由降级守卫自动移位（机制④），最坏情况由快照成对回滚恢复（机制⑤）——"先试修、再回退"优于"直接放弃修复"。
- **失败时的行为**：输出 validate 详情（进步骤日志与失败通知），`FAIL_STAGE=config_validate`，随后自动安装 known-good 版本重试。known-good 版本写在状态包的 `~/.openclaw/openclaw-known-good-version`（每次成功启动后自动更新）。
- **边界**：`config validate` 是只读检查，不写状态；即使它自身崩溃（例如数据库 schema 更新）也不会污染任何东西。

### 机制②：修复动作显式化

- `openclaw doctor --fix` 的退出码不再被静默吞掉：`openclaw doctor --fix || echo "DOCTOR_EXIT=$? (non-fatal, continuing)"`。
- doctor 的失败原因（如 `Legacy exec approvals exist ...`）会进入失败通知的关键日志摘要（通知步骤的 grep 模式包含 doctor/fallback/invalid 等）。
- 教训来源：8-31 故障中 doctor 实际是**异常中断**（exec-approvals 抛出 `ExecApprovalsMigrationRequiredError`），`|| true` 让它看起来"跑过了"。

### 机制③：版本化状态快照

- **触发条件**：仅在**健康启动**的运行周期结束时打快照（判断依据：meta 文件含 `RECORDED_SUCCESSFUL_OPENCLAW_VERSION=`），每个健康周期一份。失败运行只更新常规 `openclaw.tar.gz`，**坏状态永远不会进快照池**。
- **位置与命名**：`dropbox:self-hosted/snapshots/openclaw-<UTC日期>-<时分>-v<版本>.tar.gz`（日期在前保证按名排序即按时间排序）。
- **保留策略**：最新 3 份（≈ 覆盖近 18 小时的健康点，约 5.6GB），超出自动删除；随状态增长线性上涨。
- **内容**：与 `openclaw.tar.gz` 完全一致的完整 `~/.openclaw` 状态包（配置、状态库、会话、工作区）。

**从快照恢复（手动 SOP）**：

```bash
# 1. 列出可用快照
rclone lsf dropbox:self-hosted/snapshots/ --files-only

# 2. 下载目标快照并解包查看
rclone copyto "dropbox:self-hosted/snapshots/<快照名>.tar.gz" /tmp/restore.tar.gz
mkdir -p /tmp/restore && tar -xzf /tmp/restore.tar.gz -C /tmp/restore

# 3. 两种恢复方式：
#    a) 整包回滚（推荐，配合下方的版本固定）：
#       在下一次 Run 的恢复阶段之前，把它上传为常规状态包：
rclone copyto /tmp/restore.tar.gz dropbox:self-hosted/openclaw.tar.gz
#    b) 只取某个文件（如 openclaw.json）：
tar -xzf /tmp/restore.tar.gz -C /tmp/restore .openclaw/openclaw.json
```

> 注意：整包回滚后，状态对应的 OpenClaw 版本要与之匹配（快照名里的 `v<版本>` 就是它）。若当前安装的版本比快照新且拒绝该配置，可临时 `npm i -g openclaw@<快照版本>` 或直接让预检门把流程导向 known-good 回退。

### 机制④：降级预案（回退版本与状态/配置不兼容时自动清理启动面）

- **触发条件**：回退分支中，`openclaw config validate`（以回退版本运行）失败——**不限于 schema 冲突**：配置不兼容、状态库 schema 过新、状态库损坏等任何“回退版本与当前状态/配置不兼容”的情形都触发。
- **动作（分层）**：先用回退版本的 `doctor --fix` 尝试修复并复检（纯配置问题在此解决，状态库不动）；仍失败 → 把 `~/.openclaw/state/openclaw.sqlite*`（含 -wal/-shm）整体移位为 `*.state-bak-<时间戳>`，让回退版本以全新状态库启动，再跑一次 doctor 完成初始化。
- **代价**：仅当需要移位状态库时丢会话索引（对话从新开始），工作区文件、配置不受影响；配置若能被 doctor 修复则保留，不能则由快照回滚（机制⑤）兑底。
- **升回新版时**：新版会重建/迁移自己的状态库；如需找回旧会话，把 `*.state-bak-*` 改回原名即可（schema 本来就是新版写的）。
- **为什么是移位不是删除**：保留可恢复性，代价只是几十 MB 磁盘。

### 机制⑤ 自动快照回滚（最后防线，状态+版本成对恢复）

- **触发条件**：known-good 版本回退并重启后仍未通过健康检查——即"回退二进制也救不回来"，问题大概率在状态本身（8-31 的故障形态）。
- **动作**：从快照池里找**回退目标版本自己写下的最新快照**（文件名含 `-v<版本>.tar.gz`，版本与状态天然兼容），下载后：停掉网关（取消 systemd 自动重启循环）→ 把损坏状态整体移位为 `~/.openclaw.broken-bak-<时间戳>` → 解包快照到原位 → 权限修复 → 网关重启 → 健康检查。成功则记录 known-good 并继续归档流程。
- **失败路径**：无匹配快照 / 下载失败 / 解包失败（自动还原现场）/ 回滚后仍不健康——均走原有失败流程（通知 + 归档 + 下一轮），损坏现场永远保留在 `~/.openclaw.broken-bak-*` 供人工分析。
- **版本不匹配兑底**：池里没有 known-good 版本的快照时（如快照上传失败导致的双置失败），改为**信任快照池**：取池里最新快照，从文件名解析版本并安装该版本，再成对恢复——池里每一份都是验证可用的健康对，比可能过期的 known-good 文件更可信。
- **前置条件**：快照池非空（首个快照在引入本机制后的第一个健康周期结束时产生）。此前快照池为空时本机制自动跳过，不影响原流程。
- **边界**：仅按版本匹配回退，不做"跨版本猜快照"；解包失败会自动还原现场，不会把状态弄丢。

## 三、标准操作流程（SOP）

### 升级（当前为隐式升级，需人工观察）

当前安装步骤仍跟踪 latest（锁版本方案已评估、暂未采纳）。新版本发布后：

1. 下一轮运行自动装新版。
2. **预检门先跑**：配置不兼容 → 不碰状态，自动回退 known-good，通知里会有 `Config invalid for current version` + 详情。此时线上一直稳定运行在旧版本上，**不存在"升级失败即宕机"**。
3. 兼容 → 正常启动，known-good 自动更新为新版本。
4. 若 doctor 迁移了配置，之后的运行不再有 Legacy 警告。

### 回退

- **自动回退**（无需人工）：任何"新版本读不了旧配置"的情形，预检门会直接把流程导向 known-good 版本。
- **手动回退**（新版本已成功启动过，想主动回退）：
  1. `npm i -g openclaw@<目标版本>`（在 tmate 会话里，或改工作流安装行临时 dispatch）；
  2. 若报 `uses newer schema version`：`mv ~/.openclaw/state/openclaw.sqlite{,.newer-schema-bak-$(date +%s)}`（含 -wal/-shm），同 机制④；
  3. `openclaw gateway restart`；健康后 known-good 文件会在下次成功启动时自动回写。
- **整包回滚**：按 机制③ 的快照恢复 SOP。

### 排障入口

- 失败通知包含：失败阶段（FAIL_STAGE）、当前/回退版本、DOCTOR_EXIT、关键错误日志摘要、tmate 链接。
- 手动核查：`gh run view --job <job_id> --repo jarvanh/actions`（结束后可拉 `--log`）。
- 单轮运行日志：`/tmp/run-openclaw-step.log`（keep-alive 期间通过 tmate 可见）。

## 四、已知边界（自愈救不了的场景）

1. **配置被外部改成新旧版本都不认的形态**：预检门会拒绝启动并回退，但若 known-good 版本也不认，需要人工修配置（本次事故的 jq 手术即此类）。
2. **Dropbox 不可用**：状态恢复和快照都依赖 Dropbox 挂载；挂载失败时本轮没有历史状态可用（首次启动形态）。
3. **需要语义决策的迁移**（如 agent roster 归属）：doctor 与恢复机制都会拒绝代做决定，必须人工显式声明。
4. **会话状态的单向迁移**：降级必然丢会话索引（设计如此，换可用性）；升级回新版本可恢复。

## 五、变更记录

- 2026-09-01：引入 机制①②③④；移除应急 jq 修复步骤与 legacy 清理步骤（状态已干净，日常迁移交还 doctor）。
- 2026-08-31：故障复盘，确认 doctor 异常中断 / 回退状态单向升级 / last-known-good 语义跳过三个失效面。
