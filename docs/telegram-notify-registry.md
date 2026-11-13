# Telegram 通知台账（域级出口与档位）

> 本文件只回答两件事：**哪一类通知从哪个入口发出、走什么档位**。
> 版式规则在 [`telegram-notify.md`](telegram-notify.md)（引用写「规范 · 主题名」）。
>
> **不登记逐条通知**——标题字面量、所在函数、调用点都会随实现漂移，手工抄一遍必然
> 失真。需要「现在到底有哪些通知」时现场枚举：
>
> ```bash
> bash skills/telegram-notify-audit/scripts/list_notify.sh          # 全部发送点 + 标题 + 档位
> bash skills/telegram-notify-audit/scripts/list_notify.sh openlist # 只看某个域
> ```
>
> 更新时机：某个域换了发送出口、或档位判定规则变了。新增 / 改名 / 下线单条通知
> **不需要改本文件**。行号不写（会漂），定位用文件名 + 函数名 / 标题字面量搜。

---

## 1. 域 → 出口 → 档位

| 域 | 发送出口 | 典型种类（示例，非穷举） | 档位规则 |
|---|---|---|---|
| OpenList 同步 | `.github/scripts/openlist/`（`load_all.sh` 注入真源；`telegram.sh` 的 `send_telegram_message` 统一出口） | 任务预览、进度面板、同步结果、跳过、源端异常、存储账号失效、修复 / 还原 / 灾难恢复、趋势、分卷、演练、落盘校验降级 | 结果与流水**普通**；源端大小异常、存储账号失效、落盘校验降级、灾难恢复 **alert**；进度面板与 `sendDocument` 直连主 bot，不参与路由 |
| Telegram 频道视频 | `.github/scripts/tg-channel/` | 同步汇总、单文件级失败、去重、残留清理、频道清理、媒体 caption | 全**普通**；视频 caption 走 Telethon 上传、错误日志走 `sendDocument`，不经 sendMessage 发送层 |
| 备份与任务结果 | workflow 内联（`github_backup_all.yml`、`self-hosted_backup.yml`、`notion-backup.yml`、`icloud-photos-downloader.yml`、`pixivutil2.yml`、`ph-dl.yml`、`p.yml`） | 备份成功 / 异常 / 失败 / 中断、Notion 备份结果、iCloud 结果、Pixiv 结果、ph-dl 损坏与收藏夹同步、vaultwarden 恢复失败 | 失败 / 异常 / 中断 **alert**；Notion 成功**普通**、失败 / 中断 **alert**；iCloud **全普通**；ph-dl 结果与损坏**普通**、整轮崩溃兜底 **alert**；Pixiv 失败与未运行 **alert**，其余普通 |
| OpenClaw Runner | `.github/workflows/openclaw.yml` + `.github/scripts/openclaw/run-*.sh` | 入口与凭据、自愈、归档、配额预检、keepalive、接力、AI 网关部署 | **alert**。例外走**普通**：keepalive T-15 收尾预告、新 run 已启动、AI 网关用量报告、交接进度五态（`handoff-notify.sh`）、**最终归档汇总（非全败时；全败仍 alert）**。T-2 停机预警仍 alert |
| AI 网关（workbuddy / trae2api / zcode2api / qingyan / autoclaw / qoder2api） | `.github/scripts/openclaw/run-*.sh` | 就绪 / 降级 / 鉴权失败 / 风控停用与解除 / 空库兜底 / 未就绪 / 停服 | **alert**；`⏭️ qingyan-proxy 已跳过` **普通** |
| Windows 入口 | `.github/workflows/rdp.yml`、`tailscale-windows.yml` | RDP 入口、SSH + RDP + 出口网络 | **alert** |
| Emby | `.github/workflows/emby.yml` | 服务启停、直链回退、OpenList 凭据、播放通知 | 启停 / 回退 / 凭据 **alert**；播放 **普通** |
| 测速三套 | `.github/scripts/proxy-speedtest/` | CDN / Gitee / 泰尔三网主报告、异常退出与终止兜底 | 主报告**普通**；❌ 异常退出 / ⛔ 异常终止 **alert** |
| 保活接力熔断 | `.github/scripts/lib/self_retrigger.sh` | `🧯 保活接力已熔断` | **alert** |
| 本机常驻服务 | `.github/scripts/health/system_health.sh`（在仓库内）；`board.py`、`gateway-watchdog.py`（在宿主机 `/dropbox/self-hosted/quota-board/`，不在仓库） | 数据源失联、网关异常 / 恢复、系统健康故障 / 恢复 | 故障 **alert**；恢复**普通** |
| 媒体 | `tg_send_video.py`（视频 caption）、`sync_notify.sh` 的 `sendDocument`（错误日志附件） | caption / 附件说明 | 不走档位（不经 sendMessage） |

> **内嵌通知与兜底的现状**：`ph-dl` 的崩溃兜底、`emby` 的 OpenList 凭据通知已拆成
> 独立 `always()` step；其余内嵌通知（emby 启动 / 播放、openclaw 配额预检、
> tg-channel 汇总、openlist 修复步）按规范 · 接线的判据**有意不拆**，别当成缺陷。

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
  `secrets: inherit` 调三套测速，由被调 workflow 发主报告与异常兜底。
- **只上传、不发业务通知**：`upload-video-to-tg.yml`（频道媒体上传链，caption 见
  规范 · 媒体 caption）。
- **已知死配置**：`openlist-diag.yml` 与 `openlist-fix-check.yml` 在 job 级注入了
  `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`，但两者及其调用的脚本一次都没有发送。
  保留注入是为了将来想接通知时能找到接在哪，**别把它们算进「有通知的 workflow」**。
- **纯保活、无业务通知**：`HomeAssistant.yml`、`jellyfin.yml`、`ql.yml`、
  `sub-store.yml`、`teslamate.yml`（只有 🧯 熔断告警这一条链路）。
  `p.yml`、`tailscale-windows.yml`、`rdp.yml`、`emby.yml`、`openlist.yml` 另有业务通知。

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

各域的字段级约定（哪些字段等宽、排序、冷却怎么写、数据源是哪个接口）跟着实现走。
**只写非显然、且写错会出事的约定**；逐条标题与字段枚举交给 `list_notify.sh <域>`
与代码注释：

| 域 | 文档 |
|---|---|
| workbuddy-gateway / trae2api / zcode2api / AI 网关用量报告 | [`openclaw.md`](openclaw.md)「九、通知口径」 |
| Emby 起播等待 | [`emby.md`](emby.md)「起播等待」 |
| 测速三套 | [`proxy-speedtest-taier.md`](proxy-speedtest-taier.md) 等 |
| 保活接力 | [`self-retrigger.md`](self-retrigger.md) |
