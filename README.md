# actions

自用 GitHub Actions 工作流集合：网盘同步备份、媒体服务器运维、订阅签到、数据备份等，
均通过 `workflow_dispatch` 手动触发。

## 仓库结构

```
.github/
├── workflows/              24 个工作流定义
└── scripts/
    ├── openlist/           OpenList 同步工具 —— 最复杂的子系统，详见下文
    ├── emby302/            Emby 302 直链服务 —— 详见 docs/emby.md
    ├── telegram/           Telegram 通知（tg_notify.sh = 全库发送层真源）
    ├── tg-channel/         Telegram 频道内容管线（同步/上传/去重/清理）
    └── proxy-speedtest/    代理测速脚本（common 共享层 + gitee 上行/下行/延迟 + CDN 延迟/下载 + 泰尔三网 + Speedtest 官方测速点 + gist 抓节点喂 Sub-Store 去重；tests/ 为离线自检）
docs/                       子系统文档
proxy-speedtest/            测速结果数据
```

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/telegram-notify.md`](docs/telegram-notify.md) | **Telegram 通知规范**（全库唯一真源：版式模板、收尾区、禁止事项、检查清单） |
| [`docs/emby.md`](docs/emby.md) | Emby 媒体服务器 + 302 直链子系统（架构、凭据体系、通知、排查手册） |
| [`docs/openclaw.md`](docs/openclaw.md) | OpenClaw Runner：自愈五层机制 + 常驻服务（rss-to-telegram / AI 网关）+ Tailscale 远程入口 |
| [`docs/proxy-speedtest-gitee.md`](docs/proxy-speedtest-gitee.md) / [`-cdn.md`](docs/proxy-speedtest-cdn.md) / [`-taier.md`](docs/proxy-speedtest-taier.md) | 代理测速三套（按测速点命名）：Gitee 上行/下行/延迟 / 国内 CDN 延迟+下载 / 泰尔三网 |
| [`docs/proxy-speedtest-gistnodes.md`](docs/proxy-speedtest-gistnodes.md) | 从 gist 搜索抓节点 → Sub-Store 去重出 mihomo YAML → 选一套测速（引擎由环境变量切换） |
| 下文「OpenList 同步子系统」 | OpenList 同步工具（内联在本文档） |

## 工作流清单

| 工作流 | 用途 |
|---|---|
| `openlist.yml` | OneDrive → OpenList 网盘同步（**本文档重点**） |
| `openlist-diag.yml` | OpenList 后端可写性诊断（独立 concurrency，单次 ~4min；**不搬数据**，见下文「后端可写性诊断」） |
| `openlist-restore-tryrun.yml` | 一键还原 **try run（只读预演）**：逐条给出「备份文件 / marker 原文件 / 实际执行还原」三条完整路径，**不写任何数据**（见下文「一键还原 try run」） |
| `self-hosted_backup.yml` | 自建服务备份到 OneDrive |
| `github_backup_all.yml` | 备份全部 GitHub 仓库到 OneDrive |
| `emby.yml` | Emby 媒体服务器 + 302 直链 —— 详见 [`docs/emby.md`](docs/emby.md) |
| `jellyfin.yml` | 媒体服务器运维 |
| `HomeAssistant.yml` / `rdp.yml` / `openclaw.yml` | 自托管服务 |
| `ql.yml` / `sub-store.yml` / `subs-check.yml` | 签到与订阅管理 |
| `icloud-photos-downloader.yml` / `ph-dl.yml` / `pixivutil2.yml` | 媒体抓取下载 |
| `proxy-speedtest-gitee.yml` / `proxy-speedtest-cdn.yml` / `proxy-speedtest-taier.yml` | 代理测速三套（按测速点命名）：Gitee 上行/下行/延迟 / 国内 CDN 延迟+下载 / 泰尔三网 |
| `proxy-speedtest-gistnodes.yml` | 抓 gist 公开节点 → Sub-Store 去重 → 交给上面三套之一测速（选哪套由 Variable `PROXY_SPEEDTEST_ENGINE` 决定）—— 详见 [`docs/proxy-speedtest-gistnodes.md`](docs/proxy-speedtest-gistnodes.md) |
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
| **rclone** | `rclone_flags.sh` | 53 | rclone 参数单点定义（`RCLONE_*_FLAGS`） |
| | `rclone_query.sh` | 99 | 查询与过滤解析（`size --json`、`check`、exclude 提取） |
| **openlist** | `openlist_api.sh` | 106 | 管理面登录换 token、服务就绪等待 |
| | `openlist_driver.sh` | 841 | 驱动刷新、健康预检、缓存刷新、truth-check |
| | `diag_backend.sh` | 724 | **诊断专用**（不进 `load_all.sh` 加载链）：四组写探针 + 容器日志原始 `rsp_code` dump，由 `openlist-diag.yml` 调用 |
| **sync** | `sync_engine.sh` | 392 | 核心同步引擎（编排 + 423/8005 重试） |
| | `sync_marker.sh` | 1058 | 同步标记持久化（跳过、黑名单、修复清单）+ **marker 打包外置备份**（`backup_sync_state_to_dropbox`） |
| | `sync_notify.sh` | 341 | 同步结果通知构建（统一 Telegram HTML 排版） |
| | `sync_trend.sh` | 242 | 跨 run 传输趋势（P0 可见化：剩余未传/净传速率/预计清零，收尾发「📈 同步趋势」通知） |
| | `sync_progress.sh` | 820 | 全局进度通知系统（含收尾四态标题、多层级阶段区） |
| **file** | `file_split.sh` | 689 | 大文件分割（ffmpeg 关键帧 / 7z 分卷） |
| | `file_fix.sh` | 1705 | 单文件修复的 4 种方法 + 目录可写性三态预检 + 短哈希目录兜底 |
| | `file_fix_pipeline.sh` | 1395 | 修复管线编排（方法轮换 + 增量持久化） |
| | `file_restore.sh` | 655 | 修复文件还原（目标端 → 原路径 / 源端） |
| | `restore_tryrun.sh` | 526 | 一键还原 **try run**（只读预演：三条完整路径推导 + 只读白名单护栏；`restore_try_run`） |
| **task** | `task_preview.sh` | 526 | 任务预览（大小估算、跳过预判、未传量估算） |
| | `task_engine.sh` | 2284 | 任务注册表与编排（分批、轮转、阶段行生产） |
| **基础** | `utils.sh` | 152 | 通用工具（格式化、日志判定；转义/树形渲染已收敛到 `telegram/tg_notify.sh`） |
| | `telegram.sh` | 132 | Telegram 进度面板（`send_telegram_message` + 原地编辑；排版/发送 source 真源） |
| | `load_all.sh` | 61 | 统一加载入口（L0 通知真源 → L6 分层） |

辅助程序：`get_storage_addition.py`（从 db 读存储配置）、
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

按 **L0 → L6** 分层自下而上加载，括号内为主要依赖：

```
L0 通知真源 telegram/tg_notify.sh（跨目录 source，全库唯一实现）
L1 基础     rclone_flags · utils · telegram(进度面板)
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
| **文件修复方法 1-4** | `file_fix.sh` | `copyto_original` / `copyto_shorthash` / `zip_split_original` / `zip_split_shorthash` | 展示层 `方法N·动作·变体`（`_fix_method_short`）；持久化层 `_fix_method_desc` 必须保留 `restore_info.jq` 依赖的分类子串（`分卷切割` / `短哈希文件名`） |
| **驱动刷新方法 1-3** | `openlist_driver.sh` | `storage/load_all` 重载 / 重启容器 / `storage/list` 探测 | 文案带领域词：`驱动刷新方法1` |

两者完全无关。历史教训：旧端点 `/api/driver/update` 恒失败，其失败 **≠ 驱动坏**，
不能当驱动状态信号（run 32749862280 实锤）。

文件修复方法的**黑名单条目存归一语义 ID**（`copyto_original` 等）而非描述文本，
以便命名口径演进后历史 marker 仍能命中（见 `_fix_method_norm`）。

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
`OPENLIST_409_RETRY_ATTEMPTS`（2026-09-17 加，与 423 同款：409/mkParentDir 失败重跑整次 sync）·
`OPENLIST_PERSIST_RETRY_ROUNDS` · `OPENLIST_MISSING_FIX_MAX`(200) ·
`OPENLIST_MAX_SPLIT_ATTEMPTS` · `ROTATION_MAX_CONSECUTIVE_ATTEMPTS`(8)

**409 语义开关**（2026-09-17 加）: `_FIX_MKDIR_409_SEMANTICS`（默认 1=开；0=回退旧行为）。
开启时 mkdir 报 409 会先用 `lsd` 读操作复核目录是否**已存在**，存在即按幂等成功放行 ——
409 在 MKCOL 语义下常见含义就是"资源已存在"，旧行为一律判失败会导致整轮零落盘
（run `35186977864` 实测：2062 次 409、成功率 0%）。
⚠️ **该修复在生产轮从未被触达**：主轮 `35239780581`（含本修复）实跑 5h34m 后 timeout，
放行分支日志 **0 次**，而 `409 Conflict` 仍 1876 次 ⇒ **开关保留但收益未经证实**。
诊断 `35239688191` 也没能在 `wopan175` 上复现 409（与主轮后端不同，不能互相推断）。

⚠️ **「目录可写性预检是误判源」这一归因已被生产轮证伪**（2026-09-18，主轮 `35308273431`）：
按该归因做的三态解耦（`296a3c3`）在真实故障现场 **一次都没触发**
（`exists_but_readonly` = 0 次，`兜底终止` = 2 次）——因为那个短哈希目录
`API mkdir` 报 `HTTP_CODE:200` 但 `lsd` 仍读不到，**目录根本没建出来**，
判 `unwritable` 是**正确**的。⇒ 三态逻辑没错，是它治的病不对：
它治「建得出但写不进」，而生产病是「**兜底目录本身也建不出**」。

🔑 **★★ 当前主攻方向：查清「`API mkdir` 报 200 但目录不落盘」**（2026-09-18）。
这是所有"换目录"兜底（短哈希 / 跳出故障子树）的**共同前提** —— 只要它成立，
换到哪儿都建不出。⚠️ **待解矛盾（未解前不要改修法方向）**：在 `5/` **直属**层新建
4 个无关目录**全部真成功**（`35294896071`/`35295178274`），而在 `5/<深层>/` 新建
**全新名字**的短哈希目录**建不出**（`35308273431`）⇒ 差异疑在**层级/深度**
或**健康窗口**，需一轮按深度分层的同构实验分离这两个变量。
（详见计划文档 §12.14.6）

⚠️ **2026-09-18 定向诊断补充（三轮递进，判决已下）**：
- 探针写失败**确实**只是复现同一条 409 路径（`35289924584` W1）；「后端不可写」被否定
  （已存在目录写入 rc=0）；「绕开隐式 mkParentDir 即可写」也被否定（`--no-check-dest` 仍 409）。
- 失败**定位到故障路径的第二层目录**（`35291770701`）：该层 `mkdir` 回报成功但 `lsd` 查不到
  （**mkdir 假成功**），且其下兄弟目录**全部 409** ⇒ 故障污染整棵子树；与末层文件名无关
  （原样名在隔离处能正常建）。
- ★ **「通用缺陷」已被否定**（`35294896071` / `35295178274`，两轮独立）：在**同一挂载的同一层**
  下新建 **4 个互不相关的顶层目录，全部真成功**（rc=0 · 409=0 · lsd 存在=1）。同一时刻故障
  子树仍一律 409（`35295422027` 与 `35291770701` 逐字同构，可复现）。
- ⚠️ **但上一条与 `35308273431` 的深层失败表面矛盾**（见上"待解矛盾"），**尚未收口**。
⇒ **定性：这是该子树路径局部的坏状态，不是挂载级、不是名字相关。**

🔀 **兜底目录跳出故障子树（方向成立，但已暂停）**：现有短哈希兜底目录落在同一棵坏子树里，
故同样 409。但取证 run `35306329978` 实测该 `dest_path` **自身可写**、故障**未复现**
⇒ 对照无判别力，**暂停改动**（详见计划文档 §12.14.5）。

⚠️ **不要把 `OPENLIST_DRIVER_READY_WAIT` 调短**：生产已盲等 **70s**
（驱动就绪 60s + 路径刷新后 10s），而实测就绪只需约 10s
（`重启后写入: +0s=FAIL() +10s=OK +30s=OK +60s=OK`、`列表可见性: 首次非空=10s`）。
调短会引入新的时序脆弱性。详见计划文档 §12.14.4。

✅ **`note` 语义已分档**（2026-09-18，`296a3c3` 改动 3）：原 `已重启确认` 拆为
`-可写` / `-写入失败` / `-读取失败`；**后端熔断只认 `-写入失败`**（"读取失败"可能只是
重启后列表未就绪；`exists_but_readonly` 更不该计入——它是"建不出目录"而非"后端不可用"）。

同一轮探针的其它结论（用于排除）: 名长 32–128B / 父目录名长 10–60字 / 路径深度 d1–d5 /
覆盖写 / 子目录写 / 大文件 16–256MiB **全部通过**；并发 423 是**父目录 mkdir 竞争**
（已存在目录并发 OK、新目录 `retries3` OK），重试可解；吞吐 4 流 2.06 MiB/s、
出口基准 22.71 MiB/s（瓶颈确在 wopan 侧）。
~~唯一待查新线索: 字符集阶梯里最贴近生产真实文件名的"混合"档 FAIL(405)~~
→ ✅ **已撤回**（2026-09-18 复核）：该档用的是**真实失败名逐字复刻**，本质是 §11.8
已定性的「特定目录名本身写入失败」（该名字搬到全新位置仍 405），**不构成新维度**。
生产兜底路径亦印证方向：`目录级兜底: 根目录折叠为短哈希目录` 之后**仍 409**
⇒ 兜底仍落在同一棵坏子树里。

`OPENLIST_MKDIR_FAIL_STREAK`（默认 3，0=关）: 同一后端**目录层**连续 N 个文件建不出目录
即收手跳过剩余文件（区别于方法层失败，不会误伤健康后端）。

**后端级熔断**（2026-09-12 加，见下方「后端级熔断」）: `OPENLIST_BACKEND_WRITE_PROBE`(1=开启) ·
`OPENLIST_BACKEND_WRITE_PROBE_TIMEOUT`(60s) · `OPENLIST_BACKEND_DEAD_THRESHOLD`(3，同挂载根连续几个目录判不可写即判后端死) ·
`OPENLIST_DIR_PROBE_MAX_RESTART`(3，目录探测的每轮重启预算)

**并发**：`OPENLIST_TRANSFERS`（workflow 输入 `transfers`，**默认 6**——2026-09-15 隔离实测拐点在 12 流）· `OPENLIST_CHECKERS` ·
`OPENLIST_SUBDIR_PARALLEL`（workflow 输入 `subdir_parallel`，**默认 2**；≥2 时顶层 auto-split 子目录并行同步，递归层始终串行）·
`OPENLIST_PAIR_PARALLEL`（workflow 输入 `pair_parallel`，**默认 2**；≥2 时按挂载根分组、跨后端并行同步对，同后端仍串行）·
`OPENLIST_SUBDIR_LIST_PARALLEL`（子目录大小列举并行度，默认 8）·
`OPENLIST_CONTAINER_LOCK`（容器读写锁文件，默认 /tmp/ol_container.lock——传输持共享锁、容器重启持独占锁）

**时间预算（优雅到站）**：`OPENLIST_SYNC_BUDGET_SECONDS`(19200=320min，同步 step 启动锚点) ·
`OPENLIST_SYNC_MIN_SLICE_SECONDS`(600=10min，剩余预算低于此不再开新工作) ·
`OPENLIST_REPAIR_RESERVE_PCT`(25，上限 60；子目录循环预留"预算×此比例"给修复管线尾段——不预留则修复被饿死、长尾不收敛，见计划文档 §12.9) ·
`OPENLIST_SYNC_DEADLINE_EPOCH`（由 workflow 计算，调试/还原模式不设置=不干预）

**开关**：`FORCE_SYNC` · `OPENLIST_SPLIT_ON_SYNC_FAILURE` · `OPENLIST_TASK_ROTATION` ·
`OPENLIST_SKIP_ESTIMATE`（=0 关闭跳过通知的"本次未传"现场估算，只复用预览缓存）·
`OPENLIST_BATCH_CONSOLIDATE` · `OPENLIST_HASH_DIR_FALLBACK`（=0 关闭短哈希目录兜底）·
`OPENLIST_DIR_PROBE_MAX_RESTART`（目录可写性预检的每轮重启预算，默认 3）·
`OPENLIST_DIR_PROBE_TIMEOUT`（预检探针超时，默认 120s）·
`OPENLIST_WRITE_REPROBE_INTERVAL`（F22 写探针周期性重探间隔，默认 1800s；≤0 关闭）·
`OPENLIST_405_FAST_FAIL_MIN`（F10 单批 405 计数阈值，默认 20；=0 关闭）·
`OPENLIST_PREVIEW_LISTING_TIMEOUT`（F17 预览 listing 短超时，默认 240s，**必须带单位**）·
`TASK_PREVIEW_ONLY` / `TASK_REGISTER_ONLY`（由 workflow 设置）

---

## 运行模式

workflow 的 `run_mode` 单选互斥：

| 模式 | 行为 |
|---|---|
| `同步` | 预览（可 `skip_preview` 跳过）→ 全量同步 |
| `调试 · 修复管线测试` | 只跑指定任务的修复管线 |
| `⚠️ 还原 · 修复文件还原为原路径` | `restore_fixed_files`（改名类走 `rclone moveto`：**必须**用 moveto，move 会把 dst 当目录、建出以目标文件名命名的目录） |
| `⚠️ 灾难恢复 · 目标端→源端` | `restore_source_from_target`（非破坏性） |
| `⚠️ 灾难恢复 · 目标端→源端（删除源端多余文件）` | `rebuild_source_from_target`（**破坏性**） |

带 ⚠️ 的三项会改写目标端或回传/删改源端，运行前核对 `restore_task` 任务名。

### 一键还原 try run（只读预演）

真跑「⚠️ 还原」之前先看一眼会怎么走，走 **`openlist-restore-tryrun.yml`**（独立 workflow，
独立 concurrency，**一个字节都不写**）。全量核对（`check_exists=是`）实测约 40 分钟
（4684 条 × 逐条真实远端列举 ≈ 0.48s/条），故 job 上限给到 300 分钟；`check_exists=否` 时
不拉容器、纯 marker 推导，分钟级。逐条给出三条完整路径 + 一条交叉核对路径：

| 字段 | 取值 |
|---|---|
| ① 备份文件（目标端现存形态） | `<dest_path>/<alternative>` |
| ② marker 记录的原文件 | `<dest_path>/<original>` |
| ③ 实际执行还原的完整路径 | move 类 = `rclone moveto` 的 dst（= ②）；分卷类 = 本地合卷解压产物 `copyto` 的 dst（= ②）；`alt==orig` 记为 noop（只校验存在，不搬） |
| ④ 源端原路径（灾难恢复口径） | `<source_path>/<original>` |

另核对「备份文件在不在 / 原路径是否已存在」。零写入是**结构性**保证：预演模块所有远端
调用走只读白名单（只放行 `ls/lsd/lsf/lsl/lsjson/cat/size/version`），写子命令一律拒绝执行
（`test_restore_tryrun.sh` 场景 4/5 锁住）。入参 `check_exists=否` 时只做 marker 推导、
不拉起容器（秒级），三条路径照样准确，仅存在性显示「未核对」——**不会**把"没起容器"
误报成"备份丢了"。

**时间窗（入参 `within_days`）**：`0`/留空 = **全量**（默认）；填 `N` = 只预演**最近 N 天**
产生的 marker。为什么要这个口径：还原失败的条目会**留在 marker 里不删**，marker 只增不减，
攒几周后全量里的绝大多数是早已失效的旧记录，把「备份缺失」数抬得很高却不是当前问题 ⇒ 想看
"最近几轮到底有没有真缺"必须按时间窗筛。**取不到时间戳的 marker 一律跳过并明示**（无法证明
它新 = 不放行），报告与通知各记一行「扫描 N 个 · 跳过超窗 X 个 · 跳过无时间戳 Y 个」——否则
"筛完缺失变少了"会被误读成"问题消失了"，实际只是样本变小了。

时间源: **marker 自带的 `last_success`**（UTC，写 marker 时落盘）为主，远端 ModTime（`lsl`）
兜底 —— 实测 **OneDrive 的 `rclone lsl` 返回 0 行**（该后端不吐 ModTime 列表），只靠 ModTime
会让筛选在生产上整体失效。
⚠️ **一个时间戳都取不到时视为机制失效 ⇒ 回落全量并告警**，绝不产出「条目 0」——那个"零"会被
读成"最近没缺"，实际是根本没测。

---

## 传输趋势与接力

**跨 run 传输趋势（P0 可见化，`sync_trend.sh`）**：回答"照现在的速度还要多久传完"。
预览 pass 后把全量未传量（`PREVIEW_PENDING_MAP` 合计）落盘，每次实际传输累计净传字节
（两个记录点：`_sync_task_finalize` + 最终完整同步尾部，无重复计数），收尾 step（always()，
被取消的 run 也执行）追加 `{时间戳, run_id, 历时, 净传, 剩余}` 到
`onedrive:/logs/sync_state/trend.jsonl` 并发送「📈 同步趋势」通知（近 5 轮净传速率 +
剩余 + 预计清零）。`trend.jsonl` 读改写三情形：远端不存在→创建 / 存在→追加 /
读取失败→放弃回传只发通知（宁丢一条样本，不覆盖历史——同 marker 过期副本防护原则）。
`skip_preview=true` 的 run 剩余量记为未知，趋势速率不受影响。

**优雅到站（P2）**：大任务常态撞 6h runner 上限被硬杀。现在同步 step 启动时设预算锚点
（`OPENLIST_SYNC_BUDGET_SECONDS`=320min），剩余预算不足最小工作片
（`OPENLIST_SYNC_MIN_SLICE_SECONDS`=10min）时不再开新同步对/子目录/最终完整同步，
做完当前即以 **success** 正常收场。跳过最终完整同步时不保存 pair 级成功 marker
（任务确实未完整）。被跳过的子目录 marker 已各自落盘，进度零回退。

**自续触发（P2 接力）**：GitHub 对高频 cron 限流严重（*/5 实测曾 4.5h 零触发），
"常驻队列"假设不成立 → 本轮收场后「自续触发」step 用 GITHUB_TOKEN 立即 dispatch
下一轮（workflow_dispatch 是 GITHUB_TOKEN 可触发新 run 的例外事件，job permissions
含 `actions:write`）。三道护栏：仅同步模式且 `self_retrigger` 开启（默认开）；
人工取消不打架（同步 step 被 cancel 且 job 未到 6h 上限即 <5h50m → 判人工取消不接力）；
已有 queued/waiting 运行不重复触发。schedule cron 降为 `*/30` 只做兜底。

**全量冲刺期推荐**：`session_hold=false` + `self_retrigger=true` → 6h 窗口全部
让给同步，轮与轮之间零空窗；全量收敛后恢复默认。

> 开关读取口径（2026-09-12 修）：`session_hold` / `self_retrigger` **不能**在 `if:` 里写
> `inputs.x != false` —— cron 触发时 `inputs.*` 为空串、GitHub 松比较下 `'' == false` 成立，
> 条件恒为 false，两个 step 在所有定时运行里都是 skipped（run #12613~#12618 实测）。
> 现改为经 env 取默认值 `${{ github.event.inputs.x || 'true' }}`（字符串上下文，未触发时为
> null），再由 bash 字符串比较决定是否执行。

**后端级熔断（2026-09-12 加）**：同步预检原本只有读探针（`lsd` + `refresh=true` 的
API list），读得通但写不进的后端会被整轮放行——run #12616 实测 wopan175 读全正常、
写入恒定 `409 Conflict`，结果一轮 394 次修复全败、769 次「目录不可写」、231 次容器
重启/缓存刷新，5 小时零产出。现在两级拦截：

1. **写探针**（`openlist_driver.sh` `_backend_write_probe`）：按**「后端 × 路径」**分层缓存
   （2026-09-13 改；此前探在挂载根，而"挂载根能写 ≠ 任务子路径能写"，run 34728107625 实锤），
   探针落在**真实任务子路径**上（写几字节 → 刷服务端目录缓存 → 复核可见 → 删除），
   不可写即熔断该后端的全部同步对，把 6h 让给健康后端。
   ⚠️ 缓存键是**同步对路径**（如 `openlist:wopan176Crypt/2`），读取方必须用同一个键——
   曾按"后端根"读，键对不上导致判死信号**静默丢失**、死后端只能靠 8 次轮转上限脱身
   （≈44h）；2026-09-14 修（`sync_engine.sh` 两处读取 + `tests/test_backend_dead_signal.sh` 反向锁死）。
   ⏱ **探针结论有时效（2026-09-19 补，F22）**：探针只在同步**开跑前**跑一次，而「可写」
   结论**只对那一刻有效** —— 实测同一路径单文件顺序写 10 次全过、生产同路径 1034 文件
   全 405（失效随时间/量累积）。批次循环现已按时间（`OPENLIST_WRITE_REPROBE_INTERVAL`，
   默认 30min）`_backend_write_probe_invalidate` 清缓存再探（复用预检里那次探测，不新增次数）。
   🔪 **同时补上止损（F10）**：单批日志 `405 Method Not Allowed` 计数达
   `OPENLIST_405_FAST_FAIL_MIN`（默认 20）即判"该目录本轮写不进"，**先于批次巩固**中止
   剩余批次（历史一个坏目录逐文件烧 115min）。只数 405，**不数 409/423**（那两类重试可自愈）。
   与 F5「后端写入全拒」（后端级、需触碰文件 100% 未落盘）互补：F10 目录级、更早更便宜。
2. **目录连续不可写计数**（`file_fix.sh` `_BACKEND_DEAD`）：开跑后才暴露的后端
   （预检偶发放行）由「同一挂载根连续 N 个目录被**重启确认**判不可写」捕获；判定后该后端
   剩余目录一律直接判不可写 —— 不探测、不重启、不跑 4 种方法。只认「已重启确认」的
   结论，缓存口径（预算耗尽/容器不可重启）不计入，避免误伤健康后端。

> **409 语义修正（2026-09-17，见上方「409 语义开关」）**：上面第 1 条提到的
> 「写入恒定 `409 Conflict`」**怀疑有相当一部分是误判** —— 409 在 MKCOL 语义下
> 常见含义是**资源已存在**（幂等成功），而旧代码一律归为「后端异常」并跳过整轮。
> run `35186977864` 复现同形态（2062 次 409、1088 次 `mkParentDir failed`、
> 成功率 0%、330min 超时），而**用户后台看驱动是正常的** —— 失败点在目录创建层，
> 预检与管理后台都不区分这一层。现已改为「409 先用 `lsd` 复核目录是否已存在，
> 存在即放行」，并给 409 补上与 423 同款的整轮重试、给目录层补上连续失败收手。
> ⚠️ **两点保留**：① 「409=已存在」**尚未被实测证实**（见上方开关段的诊断结论）；
> ② `35186977864` 的日志**现已过期、数值无法复查**，上述计数只作当时形态记录。

被熔断的同步对会让轮转游标**立即后移**（不等 `ROTATION_MAX_CONSECUTIVE_ATTEMPTS` 次），
死后端重试多少次都一样。收尾 step 打印 `本轮修复成效: 成功 X · 缺失 Y · 未修复 Z`，
`Y>0 且 X=0` 时额外输出 🚨 零成功告警 —— `conclusion=success` 不等于有数据落盘。

**删除语义（2026-09-12 改）**：`RCLONE_SYNC_TASK_FLAGS` 已移除 `--delete-before`，
`rclone sync` 退化为只增不减的 copy 语义。原因：上一轮以替代形态修复成功的文件，会被
下一轮的 initial sync 当成「源端没有的多余文件」删除（run #12616：50 个 `Deleted` +
短哈希目录 `f21d720a` 被整个 `Removing directory`），随后 truth-check 又把同一批文件判为
缺失重新修复——修一轮、删一轮，跨轮净进度为零。排除清单是文件级的，目录里混有未记录
文件就会被逐个删空、目录随之消失，保护形同虚设。备份语义下目标端是灾备副本，误删代价
远大于残留。

**吞吐调优（P1）**：`transfers`（**默认 6**）、`subdir_parallel`（**默认 2**）、
`pair_parallel`（**默认 2**）三者相乘即"单后端并发 PUT 数"（6×2=12，正好落在实测拐点；
跨后端那一路由 `pair_parallel` 另开一条挂载的额度）。三者都可按 run 调低：
若某轮出现 `object not found` / 假成功抬升，先降 `transfers` 或 `subdir_parallel` 回 1 观察一轮
"object not found" 率与修复管线触发量。2026-09-14 用户授权「transfers 可根据情况调整」，
但**前置依赖未解**：wopan176 当前驱动登录令牌失效（8005）、写入全拒，此时调 transfers
测不出吞吐差异——先解登录再调。

**后端可写性诊断（2026-09-14 加）**：主 run 单轮 5.5h、且被 `concurrency` 单例串行化，
"换个探针再跑一次"要排到几小时后；更要命的是主 run 日志里后端写失败只呈现为 OpenList
**包装后**的 `405 Method Not Allowed`（驱动层真实错误如 wopan 的 `8005 登录失败` 只落在
**容器日志**里，而容器日志从不进 run 日志）——于是「登录令牌失效」与「路径/名长被拒」
在 run 日志里长得一模一样。`openlist-diag.yml`（`workflow_dispatch`，**独立 concurrency
`openlist-diag`**，绝不与 `openlist-singleton` 互等）只做最小 setup：不装 cloudflared、
不接管隧道、不回传数据库，单次 ~4 分钟，跑四组探针：

1. **短名基线**（1 字节文件，写在真实任务子路径）；
2. **名长阶梯**（32/64/80/100/112/128 B，定位长度阈值）；
3. **覆盖写**（对应 rclone 的 `unchunked simple update`，与"新建文件"是不同代码路径）；
4. **子目录写**（验证"父目录名长连坐"假设）。

并把容器日志里的**原始 `rsp_code`/`rep_desc`** dump 出来。报告随 artifact `ol-diag-report` 上传。

**专项诊断（互斥，优先级从高到低；一次只跑一个，要的是"单一变量"的干净归因）**：
除常规 13 组探针外，`openlist-diag.yml` 还挂了 7 个专项入口，各自独立报告文件：

| 开关 | 脚本 | 回答什么 |
|---|---|---|
| `diag_l2` + `diag_l2_n=e` | `diag_escape_probe.sh` | 「兜底目录**跳出故障子树**是否真的可写」（E1 祖先层阶梯找最深可写层 / E2 同层对照**核心判决项** / E3 跳出层写文件 / E4 还原路径可行性） |
| `diag_l2` + `diag_l2_n=d` | `diag_depth_probe.sh` | **「层级/深度 vs 健康窗口」同构分离**（E1 同深度同形状对照：历史名 `5058f1af` vs 同深度全新名 / E2 沿生产真实故障路径的深度阶梯 / E3 **同轮内复测**历史名 → 窗口漂移自证 / E4 已存在目录可写性 / **E5 兜底落点真写入**：在真实落点 `dest_path/<hash8>` 写文件 + 全路径直读，判「建得出且写得进」vs「写不进」）|
| `diag_l2` | `diag_l2_probe.sh` | 新建顶层目录的 **mkdir 假成功**是通用缺陷还是个例（P1 普遍性矩阵 / P2 延迟落盘 / P3 重试自愈 / P4 已存在目录可写） |
| `diag_dirname` | `diag_dirname_probe.sh` | 「为什么这个特定目录建不出来」（D1 父层递进定位首失败层 / D2 末层名字 4 形态 / D3 同级兄弟） |
| `diag_writeprobe` | `diag_write_probe.sh` | 「探针写失败 == 目录不可写吗」（W1 复现 / W2 显式 API mkdir / W3 绕隐式 mkParentDir / W4 隔离目录） |
| `diag_409` | `diag_409_semantics.sh` | 409 是否等于「已存在」+ 改名回原名会不会蒸发 |
| `reject_src` | `diag_reject.sh` | 按内容拒收 vs 按文件名/状态拒收 |

⚠️ **`diag_escape_probe.sh` / `diag_depth_probe.sh` 的启动开关复用 `diag_l2_n`**
（分别填 `e`/`escape`、`d`/`depth`）：因为 inputs 已达 25 个硬上限（见下坑 1），
无法新增独立开关。其余取值仍按 L2 的"测试目录个数"解析，既有调用方式不变。

⚠️ **三个已踩过的坑（改本 workflow 前必读）**：
1. **`workflow_dispatch` 的 inputs 硬上限是 25 个** —— 超了不是"警告"而是派发直接
   `HTTP 422: you may only define up to 25 inputs`，即"加了开关却根本派不出去"。
   加新开关前先数一遍（当前**恰好 25**，新增必须靠复用既有位，如上面的 `diag_l2_n`）。
2. **不要在 step 级设全局 `DIAG_REPORT`** —— 它会被**所有**专项脚本继承，把专项报告
   统统写进 `report.txt`，而各分支收尾读的是 `<专项>_report.txt`，结果取不到文件
   （日志里表现为 `=========== <专项>报告尾部 =========== (无报告文件)`）⇒ **报告拿不到 =
   该轮白跑**。各脚本本就自带正确默认名，无需外部指定。
3. **专项脚本内的「可见性/存在性」判据必须带等待，且优先用直读** —— OpenList
   对**新建**目录/文件的列表有缓存延迟（实测首次可见 ~10s）。用"列列举里有没有"判
   "在不在"会把**成功误判成失败**（`diag_escape_probe.sh` 的 E4 首次就踩了这个坑：
   不带等待 ⇒ 误报"跨层 move 静默丢文件"；加 15s 等待仍不可见 ⇒ 最后改用
   **目标全路径 `lsjson` stat** 直读才翻案）。⇒ 凡"以列表为准"的判据，都要用一条
   **独立的直读判据**交叉验证。

⚠️ **红线：本 workflow 不得与主轮并行**（同一网盘账号会互相干扰，历史上有过把主轮
"在途等待"拉长致其撞 330min 硬线超时的实例）。派发前必须确认无活动 run。

---

## 安全模型与信任单点

- **管理面凭据**：`OPENLIST_ADMIN_PASSWORD` 只存 secrets，每次现场 `POST /api/auth/login`
  换新鲜 JWT，不在任何文件落盘（历史静态 token 的 401 潜伏故障已由此根除）。
- **rclone.conf 的信任单点（显式决策）**：conf 以 secret 起步、持久化副本在
  `dropbox:self-hosted/rclone.conf`（可能比 secret 新，故恢复时优先取 Dropbox）。
  注意 **rclone obscure 不是加密**——Dropbox 上那份 conf 等于 OneDrive 源端 + 全部目标
  网盘的通行证，且与 `sync_state` marker 镜像同账号可达：该 Dropbox 账号失守 =
  全部云端联动失守。这是接受的设计决策（换取 runner 无状态 + conf 变更自动持久化）；
  爆炸半径的收敛依赖 Dropbox 账号本身的 2FA/密码强度，若需进一步收敛，可把 conf
  副本迁至独立账号或加密存储后再上传。
- **⚠️ marker 是还原链路唯一无法自愈的单点（已外置备份）**：短哈希目录/文件名是
  `md5(相对路径)` 前 8 位，**不可逆** ⇒ marker 的 `original` 字段一丢，短哈希目录里的
  文件就只剩密文名、**自愈不回原路径**。marker 与源端同在 OneDrive，账号级故障会一并
  带走 ⇒ 收尾每轮打包到 `dropbox:self-hosted/openlist/sync_state_backup/`
  （只增不删、保留 30 份、含 `MANIFEST.txt`、两道"拒上传空包"门）。
  **注意既有 `dropbox:sync_state_mirror` 不算备份**：它是 `rclone sync` 镜像，
  删除会传播，挡不住"源端被删"——两者互补、都要留。风险说明与恢复步骤见
  计划文档 §13。
- **注入面**：workflow 的 string/number inputs（`restore_task` / `fix_test_task` /
  `fix_test_max`）一律经 step 级 `env:` 传入 `run:`，不做 `${{ }}` 直接内插 bash
  （GitHub 官方反模式清单）；`watch` 触发有 actor 守卫，公开仓库 star 不触发。

---

## 测试

```bash
cd .github/scripts/openlist
for t in tests/*.sh; do bash "$t"; done
```

25 个测试，覆盖轮转、批次巩固、修复管线优化、修复日志区段头提取、写探针判死信号键口径
与周期性重探（F22：到期/未到期/关闭/脏值）、405 快速失败（F10：阈值边界/409 不误计）、
8005 重试前的写探针短路、
目录可写性预检（含假成功目录）与短哈希目录兜底、预览 diff、跳过窗口的预览
预判与跳过通知"本次未传"（含现场估算与宁缺毋滥分支）、truth-check、
token 登录、marker、marker 打包备份（拒上传空包 / 只增不删 / 保留期 / 隔离性）、
收尾标题四态、进度阶段区排版（子目录树/文件批次的层级
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
| 改通知排版 | 全库统一规范见 `docs/telegram-notify.md`；实现真源：bash `telegram/tg_notify.sh`、pwsh `telegram/tg_notify.ps1`（rdp / tailscale dot-source）、python 复用 `speedtest_common.py`；openlist 侧经 `load_all.sh` L0 层 source 真源，`openlist/telegram.sh` 只留进度面板函数 |
| 改跳过提示（预览"预计跳过"/ 跳过通知"本次未传"） | `task_preview.sh` 的 `add_preview_pair`（pskip 列）· `flush_task_preview`（合计附注）· `_lookup_skipped_pending`（估算入口）+ `sync_marker.sh` 的 `send_sync_skipped` |
| 改进度消息的阶段区（子目录树 / 文件批次的层级、缩进、统计字段） | `sync_progress.sh` 的 `_progress_render` + `task_engine.sh` 的 `_render_subdir_phase_tree` / `_render_batch_stats_line` |
| 改收尾标题四态 | `sync_progress.sh` 的 `_progress_render` 终态分支（中断 / 有文件无法同步 / 带修复完成 / 完全完成，按严重度判定） |
| 加新模块 | 新建 `<领域>_<职责>.sh` + 在 `load_all.sh` 对应层加一行 |
