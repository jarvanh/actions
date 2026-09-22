# emby.yml 修复与调优实施计划

- 日期：2026-09-13
- 输入：三份评估报告（已归档至 `docs/reports/`：`emby-302-startup-latency-ds4.1-…` / `emby-302-playback-latency-review-hy4-…` / `emby-302-playback-glm-f-…-report-2026-09-13.md`），全部基于 HEAD=216a9b8（main=5c01d32，emby.yml 自此未再改动）
- 本计划已对当前 main 逐条复核报告结论，复核修正处见 §0.2；行号以 main=5c01d32 为准
- 执行前提：读 `AGENTS.md`、`docs/emby.md`；改通知相关必读 `docs/telegram-notify.md`

---

## 0. 审核结论

### 0.1 三方独立收敛、且经复核确认仍在 main 上的缺陷

| 级别 | 缺陷 | 位置 | 三方一致性 |
|---|---|---|---|
| P0 | 自续触发步骤 exit 127（漏 source `run_elapsed.sh`）→ 接力断 + playlog/ge2o 等归档全丢 | `emby.yml:2454`（只 source `lib.sh`）→ `:2467` 调用即崩 | 三方一致；git diff 复核：216a9b8 给该步骤引入了 `run_elapsed_seconds` 调用却只在 backup 步骤（`:2244`）补了 source |
| P0 | 收尾通知步骤 `bash -e` 静默 exit 1（WW 解析赋值无兜底） | `emby.yml:2385/2386` | 三方一致；触发条件 = wallwarm.log 无「共 N 次图片请求」结束行（wallwarmer 在干活且 `WW_MAX_MIN=300` > 保留 270min 时必然如此） |
| P1 | warm-state.json 字段序每轮翻转（「宽度 得分」喂给期望「得分 宽度」的 `persist_state`）→ 海报预热用得分当宽度 | `emby.yml:1935`（契约在 `:1920`，BASE 来源 `:1876`） | 三方一致，本机复现确认 |
| P1 | dir_cache 每轮清零，覆盖率 ~32%（26,360/83,464 文件，400/1,837 目录），冷解析 1.75s vs 热 0.29s | `odlink.py:287`（纯进程内 dict，无持久化） | hy4+glm-f 一致 |
| P1 | 增量备份含 metadata imagecache（2823 文件/1038MB）→ install 25–47min、轮换空档 25–48min（每天 1.7–3.2h 不可用） | `emby.yml:2034-2035`（rsync 只排 cache/logs/transcoding-temp/data/*.db*） | 三方一致 |
| P2 | ge2o.log 归档纯 tail，被 watchdog 探针占满 | `emby.yml:2229`（tail 80）、`:2517`（tail 60） | 三方一致（odlink.log 已修，ge2o.log 漏） |

### 0.2 本次复核对报告的修正与补充

1. **`:2387`（WW_TOP）不是必死点**（修正 glm-f）：其管道末位是 `tr`（恒返回 0），`set -e` 下不会致死。真正死点只有 `:2385/:2386`（末位 grep）。修法不受影响：三处都加兜底。
2. **`:2386` 的「兜底」在 `set -e` 下不可达**（修正 hy4 的机制表述，结论一致）：`:2385` 先死，永远轮不到 2386。这种 `A=$(…grep) || A=$(…grep)` 写法在 `bash -e` 下是反模式，重写时应消除。
3. **hy4「恢复 `--transfers` 8→16」已完成**：`:539`（恢复侧）与 `:2047`（备份侧）均已是 16，无需再改。
4. **在跑轮与排队轮都是旧代码**：34743972517（in_progress）收尾将复现 P0-1 exit 127；34758364512（pending，schedule 钉死 216a9b8）也是旧代码。push 修复后必须让新 dispatch 把它顶掉（concurrency 无 cancel-in-progress，新 pending 自动替换旧 pending）。
5. 三方一致的服务端结论：起播 10 秒里服务器可解释部分仅 0.4–1.5s（热）/2.3s（冷）；PlaybackInfo 预热空转（冷 23–30ms 已地板）；加大 WU_PI_ITEMS 与头尾预热都不要做。

---

## 1. Phase 1 — 止血：接力链 + 收尾通知 + 观测（纯 emby.yml，~15 行 diff）

| # | 改法 | 位置 |
|---|---|---|
| 1.1 | 补 `source "$GITHUB_WORKSPACE/.github/scripts/lib/run_elapsed.sh"`（与 `:2244` 同款） | `:2454` 之后 |
| 1.2 | WW 解析重写为 `set -e` 安全形式：`WW_N=$(grep … \|\| true)` 或 `if grep …; then` 结构；三处（2385/2386/2387）都处理，并顺带扫描该步骤内其余无兜底的 `VAR=$(…\|grep)` 赋值 | `:2385-2388` |
| 1.3 | `persist_state` 喂参换序：`persist_state "$(printf '%s\n' "$BASE" \| awk 'NF>=2 {print $2, $1}')"`（BASE 在 `:1894-1897` 仍是「宽度 得分」序，仅在喂入处换序） | `:1935` |
| 1.4 | ge2o.log 归档照 odlink.log 做法：过滤 `127.0.0.1` 自探针行后 grep 保留客户端请求/慢请求行再 tail | `:2229`、`:2517` |
| 1.5 | `WW_MAX_MIN` 默认 300 → 与保留时长对齐（建议 240，或由 `EMBY_RUN_MINUTES` 推导减 30），保证 wallwarmer 能打出结束行 | `:1864` |
| 1.6 | Sessions 轮询 `-m 8` → `-m 20` + 首败重试一次 + 恢复时打印「已恢复」行（Phase 4 direct A/B 依赖） | 轮询处（搜 `Sessions 查询失败`） |

**push 前本地验证**：
- `bash -n`（提取 step 脚本）；`bash -e` 最小复现修复后不再死、WW_SUMMARY 能取到进度行；
- 用 rclone 拉线上 `warm-state.json` 副本跑 `:1876→1935` 段，确认换序后 scores 首元素为整数宽度（342 级）。

**提交**：2 个 commit —— `fix(emby): 补自续触发缺失的 run_elapsed source 与收尾通知 set -e 兜底`；`fix(emby): 修 warm-state 字段翻转并过滤 ge2o 归档探针`。

## 2. Phase 2 — 可用性：轮换空档 25–48min → 目标 ≤20min

| # | 改法 | 说明 |
|---|---|---|
| 2.1 | 增量备份 rsync 加 `--exclude '**/imagecache/'` | `:2034-2035`；先核对 Emby 实际目录深度使 exclude pattern 命中 |
| 2.2 | **一次性远端清理**：`rclone delete onedrive:backup/emby/live --include '**/imagecache/**'` | 不做则恢复侧仍拉旧文件，速度不降；清理前后 `rclone size` 留证 |
| 2.3 | 图片缓存（/mnt/emby-cache，全量包载体，占 install 15.6min）二选一：a) 仓库变量 `EMBY_CACHE_RESTORE=0` 零代码跳过（首轮海报冷读，wallwarmer 烤回）；b) 后台异步补齐（install 不等图，服务先起） | 先试 a，痛感明显再做 b |
| 2.4 | 红线：保留时长 + 备份耗时 < 5h30m（GitHub 6h 硬上限，含 TERM 风险） | 任何时长调整都过这道闸 |

**验收**：增量恢复文件数 2823 → <300；install ≤15min；上轮结束→隧道就绪 ≤20min；TG 通知正常。

## 3. Phase 3 — 性能：dir_cache 覆盖（服务端唯一 >1s 的单项）

| # | 改法 | 说明 |
|---|---|---|
| 3.1 | 目录回填并发化 + `EMBY_PREFETCH_MAX_DIRS` 400→800→1837 渐进（仓库 Variables） | 串行 2.6s/个 → 16 并发全量约 10min；盯 odlink /stats 的 graph.err 与 429 |
| 3.2 | `odlink.py` dir_cache 跨 run 持久化：dump（SIGTERM handler + 每 10min 定时）到 `/var/lib/emby/odlink-dir-cache.json`（自动随增量备份上云）；启动 load（schema 版本 + 损坏降级冷启动）；**失效钩子**：resolve/取链失败删条目重走冷解析（防跨轮 stale 路径）；条目上限防膨胀 | 先读 `odlink.py:287/360-450/477-510`；验收 = 次轮启动 dirs_cached >20k 而非从 0 爬 |
| 3.3 | 字幕预热扩到 warm-state `recent` 条目（对 recent 触发字幕流请求），收益 0.5–1.0s 仅首次 | warmup 直链预热段 `:1610-1690` 附近 |
| 3.4 | 明确不做：加大 `WU_PI_ITEMS`（冷 23–30ms 已地板）、加大头尾预热（302 下视频不过挂载） | 三方报告一致 |

## 4. Phase 4 — 测量闭环：10 秒归因（决定是否存在 Phase 5）

1. Phase 1 上线后等真实播放 → `playlog.log` 的 `[起播] item=N 客户端出画 +Xs`（三方报告共同缺的数字）。
2. **用户人工对照（AI 不可替代）**：同一客户端/网络直接打开通知里 `▶ 打开直链`：秒开 → 问题在播放器；也慢 → 客户端→微软 CDN 代理路由，仓库无解；直链秒开但 Emby 10s → 额外往返，按起播等待树逐项消。
3. 可选 direct A/B：`gh workflow run emby.yml -f playback_mode=direct`（视频流经 runner，需用户知情同意；避开开头 ~110s 盲区，依赖 1.6 修复）。

---

## 5. 部署编排（AI 执行手册）

- 全库无 push/PR 触发器：push 不影响在跑服务；emby.yml 手测带 `-f playback_mode=302`。
- `concurrency: emby-singleton`（`:137`，无 cancel-in-progress）：在跑轮不会被新 dispatch 打断；**新 pending 自动顶掉旧 pending**。
- 标准上线流：本地验证 → commit → `git fetch` + rebase → push → `gh workflow run emby.yml --ref main`（顶掉旧代码 pending 轮）→ 等在跑轮自然结束 → 新轮监控。
- 一轮验证：`gh api repos/jarvanh/actions/actions/runs/<id>/jobs` 看 4 个收尾 step（backup/archive/notify/自续触发）全绿；`gh run view --log` 核对 playlog、ge2o 归档段内容。
- 判「run 为什么不动」看 job `startedAt` 而非 run 创建时间；取消非即时（2–4min）。
- 回滚：单阶段 revert + 重新 dispatch；odlink.py 改动必须可降级（无文件/损坏 = 现状冷启动）。

## 6. 验收总表

| 阶段 | 验收（连续两轮达标才算过） |
|---|---|
| P1 | 4 个收尾 step 全绿；TG 收到收尾通知且含海报预热统计；playlog.log/ge2o.log 归档可读（ge2o 段无 127.0.0.1 探针刷屏）；warm-state scores 首元素为整数宽度 |
| P2 | install ≤15min；轮换空档 ≤20min；增量文件数 <300；远端 live/ 无 imagecache |
| P3 | 次轮启动 dirs_cached >20k；真实播放的起播等待树「取直链」<0.5s |
| P4 | ≥1 条 `[起播]` 读数 + 归因结论落文档 |

## 7. 停止条件（必须停下问用户，不得自行决定）

1. Phase 4.2/4.3：需要用户人工播放/浏览器实验或 direct 模式授权。
2. 任何要改 Telegram 通知版式/文案的改动（`docs/telegram-notify.md` 硬约束，需走 send/audit skill 流程）。
3. 要改 cron 频率或 `EMBY_RUN_MINUTES` 默认值。
4. 报告预测与实测不符、或发现计划未覆盖的新问题：记录现象，不擅自扩大改动面。
5. 同一阶段连续两轮验证不过：revert 该阶段，汇报后等指示。

## 8. 给 AI 的执行指令模板（新会话直接粘贴）

```
按仓库根 emby-302-remediation-plan-2026-09-13.md 全权实施，从 Phase 1 开始逐阶段推进到 Phase 3；Phase 4 只做测量侧准备，用户实验部分向我汇报后等我做。

授权范围：
- 修改 .github/workflows/emby.yml 与 .github/scripts/emby302/*，按 AGENTS.md 规范提交并 push main
- 自行 dispatch / cancel emby.yml 运行、拉运行日志与 jobs API、多轮观察迭代
- 用 gh api 设置仓库 Variables（如 EMBY_CACHE_RESTORE、EMBY_PREFETCH_MAX_DIRS）
- rclone 直读/清理 onedrive:backup/emby/live（Phase 2.2 的 imagecache 清理）

硬约束：
- 保留时长 + 备份耗时 < 5h30m；不动 cron 频率
- 不改 Telegram 通知版式与文案（docs/telegram-notify.md）
- 每阶段独立 commit（type(scope): 中文描述 + - 正文列表），可独立 revert
- odlink.py 改动必须带降级路径（load 失败 = 现状冷启动）
- push 前 git fetch + rebase（main 有并行推送）
- 计划 §7 停止条件触发时必须停下问我

节奏：每阶段「本地验证 → push → 部署编排（§5）→ 完整一轮 run 验收（§6）」通过后再进下一阶段；一轮不过可修一轮，连续两轮不过 → revert 该阶段、记录、停。

完成后输出总结：各阶段前后实测对比（install 时长、轮换空档、dirs_cached、收尾 step 结论、通知存活）。
```

使用说明：建议至少分两次下发——先只发 Phase 1（止血，今晚在跑轮自然结束后新代码即接上），验证通过后再发 Phase 2+3（改动面更大）。也可一次放行 Phase 1–3，AI 会按 §5 编排逐段验证。

## 9. 风险与回滚

| 风险 | 缓解 |
|---|---|
| 排除 imagecache 后首轮缩略图按需重建（首次请求变慢） | 仅影响首轮首访；originals 仍在 metadata 备份内，重建不丢数据 |
| dir_cache 跨轮 stale（用户改了 OneDrive 目录结构） | 失效钩子：取链失败删条目重走冷解析；上限条数 |
| 回填并发 16 触发 Graph 限流 | 渐进 400→800→1837，盯 /stats graph.err 与 429 |
| 2.4a 关闭图片缓存恢复后海报墙冷读痛感 | 先观察一轮 wallwarmer 烤回速度，不行转 2.4b 异步补齐 |
| 任何阶段引入新崩溃 | 单阶段 revert + 重新 dispatch；在跑服务不受 push 影响 |

## 10. 数据出处

- 三份报告的全部实测（报告内已列）；本计划的行号与代码状态 = main 5c01d32（2026-09-13 复核）
- 运行状态复核时间：2026-09-13 深夜（+08），34743972517 in_progress / 34758364512 pending

