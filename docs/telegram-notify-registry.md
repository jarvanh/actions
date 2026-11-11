# Telegram 通知台账（域级出口与档位）

> 本文件是**台账，不是规范**。版式规则、构件用法、发送层硬约束都在
> [`telegram-notify.md`](telegram-notify.md)（引用写「规范 · 主题名」）。
>
> **本文件只回答两件事**：哪一类通知从哪个入口发出、走什么档位。
> **逐条通知清单不在这里**——标题字面量、所在函数、调用点都会随实现漂移，手工抄一遍
> 必然失真（实测一轮核对里 73 行有 12 行偏差）。需要「现在到底有哪些通知」时现场枚举：
>
> ```bash
> bash skills/telegram-notify-audit/scripts/list_notify.sh          # 全部发送点 + 标题 + 档位
> bash skills/telegram-notify-audit/scripts/list_notify.sh openlist # 只看某个域
> ```
>
> 行号不写进本文件（会漂），定位用文件名 + 函数名 / 标题字面量搜。
>
> 更新时机：某个域换了发送出口、或档位判定规则变了才动这里。新增 / 改名 / 下线单条
> 通知**不需要**改本文件。

---

## 1. 域 → 出口 → 档位

| 域 | 发送出口 | 覆盖范围 | 档位规则 |
|---|---|---|---|
| OpenList 同步 | `.github/scripts/openlist/`（`load_all.sh` 注入真源；`telegram.sh` 的 `send_telegram_message` 统一出口） | 任务预览、进度面板、同步结果、跳过、源端异常、存储账号失效、修复/还原/灾难恢复、趋势、分卷、演练 | 结果与流水**普通**；源端大小异常减小 / 存储账号失效 / 落盘校验降级 / 灾难恢复 **alert**；进度面板与 `sendDocument` 直连主 bot，不参与路由 |
| Telegram 频道视频 | `.github/scripts/tg-channel/`（`sync_to_tg.sh` 等） | 频道同步汇总、单文件级失败、去重、残留清理、频道清理、媒体 caption | 全**普通**；caption 不走 sendMessage 发送层 |
| 备份与任务结果 | workflow 内联（`github_backup_all.yml`、`self-hosted_backup.yml`、`icloud-photos-downloader.yml`、`pixivutil2.yml`、`ph-dl.yml`、`p.yml`） | 备份四态、iCloud 三态、Pixiv 五态、ph-dl 损坏与收藏夹同步、vaultwarden 恢复失败 | 备份成功**普通**，异常 / 失败 / 中断 **alert**；iCloud **全普通**；ph-dl 结果与损坏**普通**、整轮崩溃兜底 **alert**；Pixiv 失败与未运行 **alert**，其余普通 |
| OpenClaw Runner | `.github/workflows/openclaw.yml` + `.github/scripts/openclaw/run-*.sh` | 入口与凭据、自愈、归档、配额预检、keepalive、接力、AI 网关部署 | **alert**，例外四条**普通**：keepalive 收尾预警、新 run 已启动、AI 网关用量报告、交接进度（准备/就绪/已交出/已上线/完成，见 `.github/scripts/handoff/handoff-notify.sh`） |
| AI 网关（workbuddy / trae2api / zcode2api / qingyan / autoclaw / qoder2api） | `.github/scripts/openclaw/run-*.sh` | 就绪 / 降级 / 鉴权失败 / 风控停用 / 停服 | **alert**；`⏭️ qingyan-proxy 已跳过` **普通** |
| Emby | `.github/workflows/emby.yml` | 服务启停、直链回退、播放通知 | 启停与回退 **alert**；播放 **普通** |
| 测速三套 | `.github/scripts/proxy-speedtest/speedtest_common.py` | CDN / Gitee / 泰尔三网主报告、异常退出与终止兜底 | 主报告**普通**；❌ 异常退出 / ⛔ 异常终止 **alert** |
| 保活接力熔断 | `.github/scripts/lib/self_retrigger.sh` | `🧯 保活接力已熔断` | **alert** |
| 本机常驻服务（仓库外） | `board.py`、`gateway-watchdog.py`、`health/system_health.sh` | 数据源失联、网关异常/恢复、系统健康故障/恢复 | 故障 **alert**；恢复**普通** |
| 媒体 caption | `tg_send_video.py`、`sync_notify.sh` 的 `sendDocument` | 随视频发出的三行说明 | 不走档位（不经 sendMessage） |

> **内嵌通知与兜底的现状**：`ph-dl` 的崩溃兜底、`emby` 的 OpenList 凭据通知已拆成独立
> `always()` step；其余内嵌通知（emby 启动/播放、openclaw 配额预检、tg-channel 汇总、
> openlist 修复步）按规范 · 接线的判据**有意不拆**，别当成缺陷重复登记。

> **接力告警的覆盖面**：只有 7 个 workflow（`HomeAssistant`、`jellyfin`、`ql`、
> `sub-store`、`teslamate`、`tailscale-windows`、`p.yml`）走共享接力
> `self_retrigger.sh`，因此能发 `🧯 保活接力已熔断`。`emby.yml` 与 `openlist.yml`
> 是各自手写的接力，**没有熔断告警**——改这两处接力时要自己补失败兜底。

## 2. 不发通知的 workflow

- **完全零通知**：`cfip-pool.yml`、`delete-workflow-runs.yml`、`eshop.yml`、
  `openlist-debug.yml`、`openlist-marker-cleanup.yml`、`socks-exit-pool.yml`、
  `subs-check.yml`、`tests.yml`。要补的话照结果通知形态（规范 · 结果通知），并把
  `TG_RUN_URL` 接上。
- **自身不发、但 run 级会发**：`proxy-speedtest-gistnodes.yml`——经 `workflow_call` +
  `secrets: inherit` 调三套测速，由被调 workflow 发主报告与异常兜底。统计「有通知的
  run」时要算上。
- **已知死配置**：`openlist-diag.yml` 与 `openlist-fix-check.yml` 在 job 级注入了
  `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`，但两个 workflow 及其调用的脚本一次都没有
  发送。保留注入是为了将来想接通知时能找到接在哪，**别把它们算进「有通知的 workflow」**。
- **纯保活、无业务通知**：`HomeAssistant.yml`、`jellyfin.yml`、`ql.yml`、
  `sub-store.yml`、`teslamate.yml`（只有 🧯 熔断告警这一条链路）。
  `p.yml`、`tailscale-windows.yml`、`emby.yml`、`openlist.yml` 另有业务通知。

## 3. 档位判定与凭据

- **默认普通档**：`send_tg "$msg"` 不传 tier → @FuckSaberBot。
- **重要档**：`send_tg "$msg" alert` / `send_tg_chunked "$msg" alert` /
  `send_telegram_message "$msg" HTML alert` / `send_telegram(env, text, 'alert')`
  → @SaberFuckBot。承载「告警 + 信息」（备份失败、归档告警、网关启动失败、入口凭据、
  服务启停、模型倍率、灾难恢复等）。
- 档位由**调用点显式声明**，发送层不按标题匹配。
- alert 档**无回落**：`_ALERT` 凭据缺失即发送失败并在日志留痕；调用点**不要**加
  `if [ -n "$..._ALERT" ]` 之类的静默守卫（规范 · 接线）。
- 进度面板、`sendDocument` / `sendVideo` 直连主 bot，不参与档位路由。
- bot 分工的唯一口径见规范 · 全库 bot 分工。

## 4. 域字段口径在哪

各域的字段级约定（哪些字段等宽、排序、冷却怎么写、数据源是哪个接口）跟着实现走，
放在对应的域文档里，不占台账版面：

| 域 | 文档 |
|---|---|
| workbuddy-gateway / trae2api / zcode2api / AI 网关用量报告 | [`openclaw.md`](openclaw.md)「九、通知字段口径」 |
| Emby 起播等待 | [`emby.md`](emby.md)「起播等待」 |
| 测速三套 | [`proxy-speedtest-taier.md`](proxy-speedtest-taier.md) 等 |
| 保活接力 | [`self-retrigger.md`](self-retrigger.md) |