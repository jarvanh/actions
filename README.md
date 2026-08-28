# actions

自用 GitHub Actions 工作流集合：网盘同步备份、媒体服务器运维、订阅签到、数据备份等，
均通过 `workflow_dispatch` 手动触发。

## 仓库结构

```
.github/
├── workflows/              22 个工作流定义
└── scripts/
    ├── openlist/           OpenList 同步工具 —— 最复杂的子系统，详见下文
    ├── telegram/           Telegram 机器人相关脚本
    └── proxy-speedtest/    代理测速脚本
proxy-speedtest/            测速结果数据
```

## 工作流清单

| 工作流 | 用途 |
|---|---|
| `openlist.yml` | OneDrive → OpenList 网盘同步（**本文档重点**） |
| `self-hosted_backup.yml` | 自建服务备份到 OneDrive |
| `github_backup_all.yml` | 备份全部 GitHub 仓库到 OneDrive |
| `emby.yml` / `emby2.yml` / `jellyfin.yml` | 媒体服务器运维 |
| `HomeAssistant.yml` / `rdp.yml` / `openclaw.yml` | 自托管服务 |
| `ql.yml` / `sub-store.yml` / `subs-check.yml` | 签到与订阅管理 |
| `icloud-photos-downloader.yml` / `ph-dl.yml` / `pixivutil2.yml` | 媒体抓取下载 |
| `proxy-speedtest.yml` / `proxy-speedtest-gitee.yml` | 代理测速 |
| `upload-video-to-tg.yml` / `p.yml` / `eshop.yml` / `teslamate.yml` | 杂项 |
| `delete-workflow-runs.yml` | 清理历史运行记录 |

---

# OpenList 同步子系统

> 代码：`.github/scripts/openlist/`　入口：`.github/workflows/openlist.yml`
> 以下为该子系统的完整文档。

`openlist.yml` 工作流的脚本实现：把 OneDrive 源端同步到 OpenList 挂载的多个网盘（crypt 加密后端），
并处理网盘侧的各种故障（假成功、405/8005、名长超限、423 锁等）。

全部为 bash 函数库，由 `load_all.sh` 统一加载；不含可执行入口，入口是 workflow 的 `run_mode`。

---

## 模块划分

文件名采用 `<领域>_<职责>.sh`，按域聚集：

| 域 | 文件 | 行数 | 职责 |
|---|---|---:|---|
| **rclone** | `rclone_flags.sh` | 35 | rclone 参数单点定义（`RCLONE_*_FLAGS`） |
| | `rclone_query.sh` | 126 | 查询与过滤解析（`size --json`、`check`、exclude 提取） |
| **openlist** | `openlist_api.sh` | 89 | 管理面登录换 token、服务就绪等待 |
| | `openlist_driver.sh` | 581 | 驱动刷新、健康预检、缓存刷新、truth-check |
| **sync** | `sync_engine.sh` | 298 | 核心同步引擎（编排 + 423/8005 重试） |
| | `sync_marker.sh` | 877 | 同步标记持久化（跳过、黑名单、修复清单） |
| | `sync_notify.sh` | 328 | 同步结果通知构建（Telegram 排版） |
| | `sync_progress.sh` | 544 | 全局进度通知系统（含收尾四态标题、多层级阶段区） |
| **file** | `file_split.sh` | 666 | 大文件分割（ffmpeg 关键帧 / 7z 分卷） |
| | `file_fix.sh` | 1243 | 单文件修复的 4 种方法 + 目录可写性预检 + 短哈希目录兜底 |
| | `file_fix_pipeline.sh` | 875 | 修复管线编排（方法轮换 + 增量持久化） |
| | `file_restore.sh` | 632 | 修复文件还原（目标端 → 原路径 / 源端） |
| **task** | `task_preview.sh` | 468 | 任务预览（大小估算、跳过预判、未传量估算） |
| | `task_engine.sh` | 1271 | 任务注册表与编排（分批、轮转、阶段行生产） |
| **基础** | `utils.sh` | 176 | 通用工具（转义、格式化、树形渲染） |
| | `telegram.sh` | 146 | Telegram Bot API 封装 |
| | `load_all.sh` | 49 | 统一加载入口（L1→L6 分层） |

辅助程序：`get_storage_addition.py`（从 db 读存储配置）、`mask_rclone_config.py`（脱敏）、
`scan_fix_signatures.py`（marker 丢失时反推修复条目）、`restore_info.jq`（还原方式分类）。

---

## 命名约定

**文件名**：`<领域>_<职责>.sh`，见上表五域。

**函数名**：

| 形式 | 含义 | 例 |
|---|---|---|
| `_xxx` | 内部函数，不跨模块调用 | `_extract_filter_args` |
| `xxx` | 公开 API，可被 workflow 或其他模块调用 | `sync_task`、`flush_task_preview` |
| `tg_xxx` | Telegram 排版助手 | `tg_add_kv`、`tg_add_section` |
| `progress_xxx` | 进度系统公开 API | `progress_task_begin` |

**领域限定词是硬性要求**：存在两套独立的"方法 N"编号体系，函数名与日志文案必须带领域词，
否则无从判断所指（详见下方"易混淆概念"）。

---

## 加载机制

```bash
source "$GITHUB_WORKSPACE/.github/scripts/openlist/load_all.sh"
```

按 **L1 → L6** 分层自下而上加载，括号内为主要依赖：

```
L1 基础     rclone_flags · utils · telegram
L2 适配     rclone_query[utils] · openlist_api
L3 能力     file_fix · file_split · sync_marker · sync_progress
L4 编排     openlist_driver[openlist_api,file_fix] · file_fix_pipeline · sync_notify
L5 引擎     sync_engine
L6 任务     file_restore · task_preview · task_engine
```

> bash 函数在**调用时**才解析，所以顺序不影响正确性；保持分层纯粹为了可读性。
> 但注意：**不要在模块顶层写函数调用**，各文件顶层只允许变量/数组定义。

workflow 会把 `*.sh` `*.py` `*.jq` 拷到 `/tmp` 再 `source /tmp/load_all.sh`
（每个 step 是独立 shell），所以**新增模块文件无需改 workflow**——通配符自动纳入。

---

## 同步主流程

`run_mode=同步` 时，`run_all_tasks` 跑两遍：

```
第一遍（预览 pass，TASK_PREVIEW_ONLY=1 或 TASK_REGISTER_ONLY=1）
  run_all_tasks → sync_task → _preview_register
      → add_preview_pair（累加到 PREVIEW_PAIRS_TSV）
           └─ 顺带预判 --Nd-skip 窗口（pskip 列）+ 把待同步量写入
              PREVIEW_PENDING_MAP，供第二遍的跳过通知复用
  flush_task_preview → 按 task_name 分组，从 TSV 重算统计量 → 发 Telegram

第二遍（真正同步）
  run_all_tasks → sync_task → _sync_task_impl → sync_with_logging
      健康预检 → rclone sync → 重试(423/8005) → truth-check 取后端真值
      → diff 出缺失文件 → 修复管线 → 结果通知
```

预览的统计量是 `flush_task_preview` **从 TSV 重算**的（每个任务局部归零后累加自己那几行），
`PREVIEW_PAIRS_TSV` 是跨任务累加的唯一数据源。

---

## 易混淆概念

### 1. 两套"方法 N"

| 体系 | 位置 | 内容 | 命名要求 |
|---|---|---|---|
| **文件修复方法 1-4** | `file_fix.sh` | `copyto_original` / `copyto_shorthash` / `zip_split_original` / `zip_split_shorthash` | 函数与文案带 `fix`：`_fix_method_desc`、`文件修复方法1` |
| **驱动刷新方法 1-3** | `openlist_driver.sh` | `storage/load_all` 重载 / 重启容器 / `storage/list` 探测 | 文案带领域词：`驱动刷新方法1` |

两者完全无关。历史教训：旧端点 `/api/driver/update` 恒失败，其失败 **≠ 驱动坏**，
不能当驱动状态信号（run 32749862280 实锤）。

### 2. 两个"split"

| | 维度 | 阈值 | 位置 |
|---|---|---|---|
| **文件级分割** | 把单个大文件切成多段 | 4GB（`LARGE_FILE_THRESHOLD_BYTES`） | `file_split.sh` |
| **任务级分批** | 按一级子目录把同步任务拆成子任务递归 | 50GB（`SYNC_SPLIT_THRESHOLD_BYTES`） | `task_engine.sh` 的 `--auto-split` |

`SYNC_SPLIT_*` 是历史命名且属**用户可配环境变量**，为避免既有配置静默失效，未改名；
两者关系在 `file_split.sh` 与 `task_engine.sh` 头部有交叉标注。

### 3. `restore` vs `rebuild`

两个都是"目标端 → 源端"，但：

- `restore_source_from_target` — **非破坏性**：仅把 marker 修复条目回填源端，不删任何文件
- `rebuild_source_from_target` — **破坏性**：先 `rclone sync` 镜像再回填，
  源端多余文件会被删除，最终源端 = 目标端内容

### 4. 预览的"待同步" vs 本次实际传输

两者**不相等**，`--Nd-skip` 是唯一原因：预览 pass 不查 marker（只算差异），
同步 pass 的窗口判断在任何传输之前 —— 命中窗口的同步对整对跳过，一个字节都不传。

因此：

- 预览里命中跳过窗口的同步对会标 `⏭️ 本轮预计跳过`，合计另附
  "预计跳过 X / 预计实际传输 Y"（`add_preview_pair` 的 pskip 列 + `flush_task_preview`）
- 跳过通知带 `📦 本次未传`，给出被跳过的差异量（`send_sync_skipped`）：
  优先复用预览算好的值（`PREVIEW_PENDING_MAP`，预览与同步同 step，零成本），
  auto-split 子任务无独立预览条目时现场估算（`OPENLIST_SKIP_ESTIMATE=0` 关闭），
  任一端列举失败则不展示 —— 宁缺毋滥，避免把虚高全量挂到"未传"上
- `FORCE_SYNC=true` 跳过全部标记检查（`check_sync_marker` / `check_marker_skip_window`），
  预览此时也不会标注"预计跳过"

---

## 任务注册表

单点定义在 `task_engine.sh` 的 `SYNC_TASK_REGISTRY`，格式：

```
"id|源端|目标端|任务名|附加参数"
```

| 字段 | 说明 |
|---|---|
| id | 调试模式选择器，不需要单独调试的任务填 `-` |
| 附加参数 | `--auto-split` 源端超阈值时按子目录分批；`--Nd-skip` N 天内已成功则跳过；`--exclude` 等原样透传 rclone |

例：`"task0|onedrive:0|openlist:wopan176Crypt/0|task0|--auto-split --1d-skip"`

---

## 环境变量

集中定义在 workflow 的 `env:` 块（避免魔数散落脚本）。

**凭据**：`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` / `OPENLIST_ADMIN_PASSWORD`（均来自 secrets）

**阈值（字节）**：`LARGE_FILE_THRESHOLD_BYTES`(4GB) · `SYNC_SPLIT_THRESHOLD_BYTES`(20GB) ·
`OPENLIST_SPLIT_PART_BYTES`(1GB) · `OPENLIST_7Z_VOLUME_SIZE` · `OPENLIST_ERR_LOG_MAX_BYTES`

**超时（秒）**：`OPENLIST_PROBE_TIMEOUT` · `OPENLIST_RCLONE_LISTING_TIMEOUT` ·
`OPENLIST_DOWNLOAD_TIMEOUT` · `OPENLIST_UPLOAD_TIMEOUT` · `OPENLIST_TOKEN_REFRESH_SECS`

**重试与阀门**：`OPENLIST_8005_RETRY_ATTEMPTS` · `OPENLIST_423_RETRY_ATTEMPTS` ·
`OPENLIST_PERSIST_RETRY_ROUNDS` · `OPENLIST_MISSING_FIX_MAX`(200) ·
`OPENLIST_MAX_SPLIT_ATTEMPTS` · `ROTATION_MAX_CONSECUTIVE_ATTEMPTS`(8)

**并发**：`OPENLIST_TRANSFERS` · `OPENLIST_CHECKERS`

**开关**：`FORCE_SYNC` · `OPENLIST_SPLIT_ON_SYNC_FAILURE` · `OPENLIST_TASK_ROTATION` ·
`OPENLIST_SKIP_ESTIMATE`（=0 关闭跳过通知的"本次未传"现场估算，只复用预览缓存）·
`OPENLIST_BATCH_CONSOLIDATE` · `OPENLIST_HASH_DIR_FALLBACK`（=0 关闭短哈希目录兜底）·
`OPENLIST_DIR_PROBE_MAX_RESTART`（目录可写性预检的每轮重启预算，默认 3）·
`OPENLIST_DIR_PROBE_TIMEOUT`（预检探针超时，默认 120s）·
`TASK_PREVIEW_ONLY` / `TASK_REGISTER_ONLY`（由 workflow 设置）

---

## 运行模式

workflow 的 `run_mode` 单选互斥：

| 模式 | 行为 |
|---|---|
| `同步` | 预览（可 `skip_preview` 跳过）→ 全量同步 |
| `调试 · 修复管线测试` | 只跑指定任务的修复管线 |
| `⚠️ 还原 · 修复文件还原为原路径` | `restore_fixed_files` |
| `⚠️ 灾难恢复 · 目标端→源端` | `restore_source_from_target`（非破坏性） |
| `⚠️ 灾难恢复 · 目标端→源端（删除源端多余文件）` | `rebuild_source_from_target`（**破坏性**） |

带 ⚠️ 的三项会改写目标端或回传/删改源端，运行前核对 `restore_task` 任务名。

---

## 测试

```bash
cd .github/scripts/openlist
for t in tests/*.sh; do bash "$t"; done
```

16 个测试、359 个断言，覆盖轮转、批次巩固、修复管线优化、修复日志区段头提取、
目录可写性预检（含假成功目录）与短哈希目录兜底、预览 diff、跳过窗口的预览
预判与跳过通知"本次未传"（含现场估算与宁缺毋滥分支）、truth-check、
token 登录、marker、收尾标题四态、进度阶段区排版（子目录树/文件批次的层级
与缩进）等。均为纯 bash + stub（mock 掉 rclone/curl/docker），无需真实网盘。

**注意两点**：

1. 部分测试采用**部分 source**（只加载被测模块）而非 `load_all.sh`，
   以保证与无关模块零耦合。**新增或移动函数后，若测试报 `command not found`，
   先检查它的 source 清单是否还覆盖该函数所在文件。**
2. `test_fix_pipeline_optimizations.sh` 会在工作区留下 `file_fix_t_*.log`，需手动清理。

---

## 修改指南

| 想改什么 | 改哪里 |
|---|---|
| 增删同步任务 | `task_engine.sh` 的 `SYNC_TASK_REGISTRY` |
| rclone 参数 | `rclone_flags.sh` |
| 调阈值/超时 | workflow 的 `env:` 块（不要写死在脚本里） |
| 加一种文件修复方法 | `file_fix.sh`（实现 + `_try_fix_methods_round` 轮换）+ 同步更新 `文件修复方法N` 文案 |
| 改目录级降级策略 | `file_fix.sh` 的 `_fix_probe_dir_writable`（预检/重启复核）+ `_fix_switch_to_hash_dir`（切换）+ `restore_info.jq` 的目录类分支 |
| 改通知排版 | `sync_notify.sh` / `telegram.sh` |
| 改跳过提示（预览"预计跳过"/ 跳过通知"本次未传"） | `task_preview.sh` 的 `add_preview_pair`（pskip 列）· `flush_task_preview`（合计附注）· `_lookup_skipped_pending`（估算入口）+ `sync_marker.sh` 的 `send_sync_skipped` |
| 改进度消息的阶段区（子目录树 / 文件批次的层级、缩进、统计字段） | `sync_progress.sh` 的 `_progress_render` + `task_engine.sh` 的 `_render_subdir_phase_tree` / `_render_batch_stats_line` |
| 改收尾标题四态 | `sync_progress.sh` 的 `_progress_render` 终态分支（中断 / 有文件无法同步 / 带修复完成 / 完全完成，按严重度判定） |
| 加新模块 | 新建 `<领域>_<职责>.sh` + 在 `load_all.sh` 对应层加一行 |
