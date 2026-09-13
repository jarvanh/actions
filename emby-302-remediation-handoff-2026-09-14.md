# emby 302 修复 — 实施交接（2026-09-14，Phase 1→3 已落地）

> 本文件是给下一个 AI/人接手的进度快照。计划真源 `emby-302-remediation-plan-2026-09-13.md`，
> 实现约定 `AGENTS.md`、通知规范 `docs/telegram-notify.md`、域文档 `docs/emby.md`。

## 一句话状态

Phase 1 / 2 / 3 全部落地、已提交并 push main、各跑过验证轮验收；Phase 4 只做了「测量侧准备」，
**用户实验部分（计划 4.2 / 4.3）等用户本人做**。已派发常规 270min 轮（`34790305626`）恢复服务
并重启自续接力链。

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

1. **等最终常规轮 `34790305626` 收尾**，确认三点：
   - 归档出现 `dir_cache 装载：N 条`（新增的独立行，直接证据）
   - 总时长 < 5h30m 且常规 270min 轮**跳过全量打包**（`备份结果: 增量完成` 无「全量」）
   - 收尾通知存活（send telegram notification = success）
2. **观察 2~3 轮**：轮换空档（上一对 13m30s，≤20min 达标）、`dirs_cached` 持续 ≥20k。
3. **Phase 4 用户实验**（计划 4.2 / 4.3）：**等用户本人做**，不要代做。
   - 4.1 `[起播]` 出画探针已在代码里，且归档链路已修好，真实播放后会落 playlog.log。
   - 用户实验后按计划汇总「点播放→出画面」各段实测。
4. 若 4.3 想继续调并发：`EMBY_PREFETCH_PAR`（默认 8）与 `MAX_DIRS` 用 Variables 调，
   盯 `/stats` 的 `graph.err`（当前 12/1126 ≈ 1%，无 429 风暴）。

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
