# emby 302 修复 — 实施交接（2026-09-14，Phase 1→3 已落地）

> 本文件是给下一个 AI/人接手的进度快照。计划真源 `emby-302-remediation-plan-2026-09-13.md`，
> 实现约定 `AGENTS.md`、通知规范 `docs/telegram-notify.md`、域文档 `docs/emby.md`。

## 一句话状态

Phase 1 / 2 / 3 全部落地、已提交并 push main；**P1/P2/P3 全部判据已 ✓**（「验收定稿」表内 9 行全绿，
最后三项——红线时长、dir_cache 装载直接证据、远端 imagecache——于 2026-09-14 05:50 UTC 补齐）。
**Phase 4 只剩用户实验**（计划 4.2 / 4.3），**等用户本人做**，操作清单见
`emby-302-phase4-user-checklist-2026-09-14.md`；`[起播]` 探针与归档链路已就绪，用户播一次即可取数。

在跑 / 排队：

| run | 代码 | 形态 | 作用 |
|---|---|---|---|
| `34810198024` | `fd4161a` | 自续接力轮 | 由上轮 `已触发下一轮接力` 自动派发，链条已回到常态 |
| ~~`34790305626`~~ | `dd7c045` | 270min 常规 | ✅ 已收尾：4h45m、全量跳过、4 step 全绿 |
| ~~`34800728970`~~ | `fd4161a` | 30min 短轮 | ✅ 已收尾：装载行 + 落盘守卫均验证通过 |

稳态轮换空档（自动接力，不含人工 dispatch 间隔）实测 **约 11 分钟**（上一对：上轮 job 结束 → 下轮
`run cloudflared` 就绪 = 11m 上下），远好于目标 ≤20min（修复前 25–48min）。

## 提交清单（每个可独立 revert）

| commit | 内容 |
|---|---|
| `227ac62` `239ee8a` | Phase 1：补自续触发 `run_elapsed` source（P0，exit127→success）、WW 解析 set -e 死点、`WW_MAX_MIN` 改 `EMBY_RUN_MINUTES-30`、warm-state 字段序、ge2o 归档去 127.0.0.1 探针、Sessions 轮询加固 |
| `6382fae` | Phase 1 补修：ge2o 归档排空时只报计数，不回退纯 tail |
| `06cc0df` | Phase 2：增量备份排除 `metadata/library` + 收紧全量打包时间闸门（ETA 2400→2700s、BUDGET 20400→19200s） |
| `8d7b6fd` | Phase 3：odlink `dir_cache` 跨 run 持久化（落盘/装载/失效钩子/上限/降级） |
| `7c5815a` | Phase 3：目录回填并发化（`xargs -P`）+ recent 记 id + 内封字幕预热 |
| `0eef148` `dd7c045` | 归档单独展示 dir_cache 装载/落盘行 + docs 补上限取舍 |

## 实测对比（before 216a9b8 → after）

| 指标 | before | after | 证据轮 |
|---|---|---|---|
| install emby | 24m52s（另一轮 36m53s） | **9m40s / 8m58s** | 34780741841 / 34784557144 |
| 其中增量恢复 | 17~22min | **3m11s** | 同上 |
| 增量快照 | 2823 文件 / 1038MB | **157 文件 / 160MB**（+dir_cache 后 158/170MB） | 同上 |
| 收尾增量备份耗时 | ~60s | **7s / 10s** | 同上 |
| 备份 step 总耗时 | 43m10s（含全量 42min） | 常规轮跳过全量（闸门）；短轮 31min | — |
| 整轮总时长 | 5h39m（**超 5h30m 红线**） | 常规轮预计 ~5h10m，待最终轮确认 | — |
| dir_cache 启动覆盖率 | 每轮从 0 爬（26,360 文件） | **43,925**，且跨轮装载生效 | 34784557144 / 34787290391 |
| 收尾 4 step | 自续触发 exit 127 | 全 success | 34772405420 等 |
| warm-state scores | 字段翻转（得分/宽度错位） | `[[342,3.2],[630,2.2]…]` 整数宽度 | 34772405420 |

### dir_cache 装载生效的间接证据（Run C 34787290391）

归档里 `dir_cache 装载` 行当时被海量 `段数=` 挤到 tail 窗口外（已修，见 dd7c045），
但三项数据指向装载成功：

- `fast_path` 0 vs 上轮 162 —— 目录已整路径命中缓存，不再走路径寻址
- `graph.ok` 951 vs 上轮 1114 —— Graph 调用变少
- `dirs_cached` 恒 43,925 —— 800 目录回填没有新增条目（全已命中）
- 远端 `onedrive:backup/emby/live/odlink-dir-cache.json` 存在（10MB）

## 验收定稿（2026-09-14 上午，全部回溯自已完成轮，未新跑轮次）

**方法论**：验收瓶颈是「每个判据等一轮 4.8h 且串行」，但 P1/P2/P3 的判据都能从**已完成轮**取到，
四条取数通道：① 轮换空档 ← `jobs` API 的 `started_at`/`completed_at`（+ 下一轮 `install emby` 时长）；
② `dirs_cached` ← 归档里的 odlink `/stats` JSON；③ 增量文件数 ← 归档里的 `快照: N 文件`；
④ 全量闸门 ← 归档里的 `备份结果:` 行。

| 判据 | 目标 | 实测 | 结论 |
|---|---|---|---|
| install emby | ≤15min | 9.0 / 9.7 / 11.2 / 13.7 min | ✓ |
| 增量快照文件数 | <300 | 157 / 158 / 158 | ✓ |
| 轮换空档（job 级 / 含 install） | ≤20min | 3.6/0.1/0.0/3.1 → 12.6 / 11.2 / 16.8 min | ✓ |
| dirs_cached | 连续 ≥20k | 26,367 / 43,925 / 43,925 | ✓ |
| 收尾 4 step | 全绿 | 已完成轮全 success | ✓ |
| 远端 live/ 无 imagecache | 无 | 文件数已为 0；967 个**空目录**残留已 `rclone rmdirs` 清掉，现 0 | ✓ |
| 总时长 <5h30m | 是 | `34790305626`（270min 轮）= **4h45m24s** | ✓ |
| dir_cache 装载（直接证据） | 出现装载行 | `34800728970`：`dir_cache 装载：43925 条（上限 50000）` | ✓ |
| 落盘守卫（`8acfc6f`） | 未装载前不落盘 | `34800728970`：`dir_cache 落盘跳过：尚未装载上轮缓存…` | ✓ |

**算空档的坑**：中间夹 cancelled 轮会把朴素差值算成假空档（`34780741841` → `34772405420`
算出 64min，其实是人工调试 dispatch 的间隔，不是稳态）。必须把 cancelled 轮一起排进时间线。

**保留**：那三个「观察轮」实际都是 30 分钟调试轮（日志里 `本轮保留 30 分钟`），不是 270min 常态轮。
所以轮换空档、`dirs_cached` 的结论可用，但**红线时长只能靠 270min 轮**。

### 新发现：P2「远端 live/ 无 imagecache」——已结案（是空目录，不是残留文件）

`rclone lsf --dirs-only -R --max-depth 3 onedrive:backup/emby/live/metadata/library | grep -c imagecache`
= **967**。根因：实现排除的是**整个 `metadata/library/`**（`emby.yml:2103` 恢复侧
`--exclude 'metadata/library/'`、`:2139` 快照侧 `--exclude 'metadata/library/**'`），比计划 2.1
写的 `**/imagecache/` 宽得多；排除生效后远端旧内容不会被 `rclone copy` 删除（copy 不删远端）。

**核实结论（2026-09-14）**：`rclone lsf -R --files-only …/metadata` = 15 个文件，全部在
`collections/` 与 `people/` 下，`metadata/library/` 下**文件数 0**；967 个是 `rclone delete`
留下的**空目录**（OneDrive 不随文件删除回收目录）。已执行
`rclone rmdirs onedrive:backup/emby/live/metadata/library --leave-root` → 现 0 个。
live 总量 158 对象 / 170MB 未变（空目录不计文件数）。

两个连带影响：
- 计划 §9 风险表「originals 仍在 metadata 备份内」的说法**已不成立**（poster/fanart 原件也不在备份里）
- 好消息：恢复侧同样排除 → 不拉旧文件，install 提速不受影响

## 关键路径/机制备忘（接手必读）

- **图片真实路径是 `metadata/library/**`**（计划里写的 `imagecache` 在真实数据里是
  `metadata/library/<x>/<hash>/imagecache/poster.jpg` 的子层）。排除整目录即可。
- **dir_cache 落盘闭环**：odlink 每 10min + 退出前写 `/tmp/odlink-dir-cache.json`
  → `emby_incbak.sh` 在 chown 之后拷进快照 → 随 live 上云 → 下轮恢复到
  `/var/lib/emby/odlink-dir-cache.json` → **首次解析时**装载（odlink 比 install 先启动）。
- **变量现状**：`EMBY_PREFETCH_MAX_DIRS=800` 已设（400→800）；`EMBY_FULL_BACKUP` 已删（恢复默认 auto）。
- **dir_cache 上限 5 万条**（`ODLINK_DIR_CACHE_MAX`）：800 目录 ≈ 4.4 万条/10MB。
  继续上调 `MAX_DIRS` 前先评估上限与上传体积（见 docs/emby.md §4.5 注）。

## 待办 / 后续

1. ~~等 `34790305626` 收尾（约 12:23）~~ → **已完成**：270min 轮总时长 **4h45m24s**（<5h30m），
   `备份结果: 增量完成 · 全量跳过（预算不足）`，备份 step 仅 40s，收尾 4 step 全绿。
   闸门算式：`LEFT = EMBY_JOB_BUDGET(19200) - ELAPSED - ETA(2700)`，即 ELAPSED ≥16500s（275min）才跳过；
   实测 270min 轮 ELAPSED=285min 才跳过，**余量只有 10min**——将来若把保留时长上调到 280min 以上，
   必须同步上调 `EMBY_JOB_BUDGET`，否则全量打包会被误跳过（好在这只是图片缓存不刷新，无数据风险）。
2. ~~观察 2~3 轮~~ → **已用回溯定稿，见上「验收定稿」**，不必再等轮次。
3. ~~等 `34800728970`（30min 短轮，`fd4161a`）收尾（约 13:05）~~ → **已完成**：
   - `dir_cache 装载：43925 条（上限 50000）` ✓（`fd4161a` 拆行的直接验收）
   - 守卫生效：`dir_cache 落盘跳过：尚未装载上轮缓存（备份恢复未完成），不用不完整快照覆盖云端` ✓，
     装载后恢复每 10 分钟正常落盘
4. **Phase 4 用户实验**（计划 4.2 / 4.3）：**等用户本人做**，不要代做。操作清单已交给用户：
   `emby-302-phase4-user-checklist-2026-09-14.md`。用户回贴播放通知后，从 run 日志读
   playlog.log 的 `[起播] item=N 客户端出画 +Xs` 做归因。
5. 若 4.3 想继续调并发：`EMBY_PREFETCH_PAR`（默认 8）与 `MAX_DIRS` 用 Variables 调，
   盯 `/stats` 的 `graph.err`（当前 12/1126 ≈ 1%，无 429 风暴）。
6. **低优先待办**：远端 `metadata/library` 下 967 个 imagecache 目录要不要清（计划 2.2 的收尾）；
   以及是否把 `--exclude 'metadata/library/'` 收窄回 `**/imagecache/`（收窄则 originals 重新进备份）。

## 新发现：dir_cache 首轮落盘会用「只有 8 条」的快照覆盖云端缓存（2026-09-14 08:20 观察，**待用户决策**）

**现象（实测，run 34790305626）**：远端 `onedrive:backup/emby/live/odlink-dir-cache.json`
在 **07:55:33 → 08:20:53（25m20s）** 期间只有 **797 字节 / 8 条**（正好是 8 个顶层
快捷方式，`updated=07:49:39`），之后才恢复成 **10,055,924 字节 / 43,925 条**
（`updated=08:19:39`）。即：上一轮累积的 4.4 万条缓存，每轮开头都会被一份「只装了
bootstrap 快捷方式」的小文件覆盖约 25 分钟。

**根因（已在本地用 odlink.py 复现）**：落盘是**无条件定时**的，装载是**惰性**的
（只有 `resolve()` 会调 `_ensure_dir_cache()`），而 odlink（step 10）比 install emby
（step 11）先启动：

| 时刻 | 事件 |
|---|---|
| T+0 | odlink 启动；`bootstrap()` 把 8 个快捷方式**直接写进** `dir_cache`（不经 resolve） |
| T+600 | `dump_loop` 第一次落盘 → 写出 8 条（此刻 `/var/lib/emby` 还没恢复，无从装载） |
| T+840 | install emby 把 10MB 缓存恢复到 `/var/lib/emby/odlink-dir-cache.json` |
| T+845 | 回填的 `/api/fs/list` 走 `resolve()` → 装载 43,925 条（**内存里是对的**） |
| T+960 | `emby_incbak.snapshot()` 无条件用 `/tmp/odlink-dir-cache.json` 覆盖 STAGE → 8 条上云 |

本地复现（造 43,925 条 in.json，bootstrap 后未 resolve 直接落盘）：写出 **8 条**；
先 `_ensure_dir_cache()` 再落盘：写出 **43,925 条**。

**影响**：正常运行轮会在第 2 次快照（T+25min）后自愈；但在这个 25 分钟窗口内
若轮次被取消 / runner 被 TERM / 轮次短于 ~20min（收尾 `once` 会拷走那份 8 条文件），
**累积缓存即永久丢失**，下一轮回到 0 冷启动。本仓库取消/顶轮很常见（09-13 一天 4 次）。

**未决**：`dir_cache 装载：N 条`（dd7c045 新增的独立行）要到本轮归档才能看到，
目前只能确认「第 1 次落盘早于装载」这一事实；装载是否真的生效仍待核对。

**建议修法（未实施，等用户拍板）**：

1. `odlink.py`：`dump_dir_cache()` 在 `_dir_loaded == False` 时**直接跳过落盘**
   （还没装载过 = 内存里一定不完整，宁可让云端留着上一轮那份）。
   注意**不能**改成「先调 `_ensure_dir_cache()` 再落盘」——那会在 T+600 就把
   `_dir_loaded` 置真（当时文件还没恢复），反而把后面的真装载永久挡掉。
2. `emby.yml` 快照侧加固：拷进 STAGE 前比较条目数，只在新快照 ≥ 已恢复那份时才覆盖。

## 验证命令（给下一个 AI）

```bash
# 完整日志可读（修正旧记忆：非 admin 也能读；in_progress 要等结束）
gh run view <run_id> --log

# step 状态/起止
gh api repos/jarvanh/actions/actions/runs/<id>/jobs \
  -q '.jobs[] | .steps[] | select(.number>=21) | "\(.number) \(.name) | \(.status) \(.conclusion)"'

# 远端备份体积
rclone size onedrive:backup/emby/live --fast-list
rclone lsf onedrive:backup/emby/live --fast-list

# 手动跑一轮（短轮调试）
gh workflow run emby.yml --ref main -f run_minutes=30 -f self_retrigger=false -f playback_mode=302
```

## 坑（本 session 踩过的）

- **pending 轮会被新 dispatch/cron 顶掉**：要掌控节奏就 `-f self_retrigger=false`，
  且别在有 cron 临近时 dispatch（cron `0 2,8,14,20` UTC 会延迟触发）。
- 无 push/PR 触发器，push 不触发运行；判断分支产出只看 `workflow_dispatch`。
- `gh api` 建/改/删变量：变量不存在时 PATCH 会 404，先 POST；删用 `-X DELETE`。
- 通知版式/文案一个标点都不能动（`docs/telegram-notify.md` 是真源，本次全程未触碰）。

## 停止条件（计划 §7）

未触发。当前无需停下询问用户；下一 AI 按上面「待办」继续即可。
