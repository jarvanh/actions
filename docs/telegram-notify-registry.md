# Telegram 通知台账（随实现更新的事实清单）

> 本文件是**台账，不是规范**。版式规则、构件用法、发送层硬约束都在
> [`telegram-notify.md`](telegram-notify.md)（引用写「规范 · 主题名」）；
> 这里回答「全库有哪些通知、各在哪、走什么档位」以及「某域通知的字段口径」。
>
> **为什么单独维护**：清单随实现漂移——每加一条通知都要登记，漏登就失真。
> 规范层（版式/发送层）不随实现漂移，两者分开后规范不再因加通知而改动。
> 行号不写进本文件（会漂），定位用文件名 + 函数名 / 标题字面量搜。
>
> 更新时机：新增 / 改名 / 删除通知时同步对应行；档位变化时同时核对 step 是否注入了
> ALERT 凭据。其余时间不动。

---

## 1. 全库通知清单

档位：**普通** = `send_tg "$msg"`（@FuckSaberBot）；**alert** = `send_tg "$msg" alert`
（@SaberFuckBot）。档位由调用点显式传，发送层不按标题匹配（规范 · 发送层要求）。
未特别标注「alert」的一律普通档。

### 1.1 OpenList 同步域（`.github/scripts/openlist/`）

出口统一是 `telegram.sh` 的 `send_telegram_message`（>4000 走 chunked）；进度面板与
sendDocument 直连 API（固定主 bot，不参与档位路由）。

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| 📋 任务预览 · 任务名 | `task_preview.sh` | 预览阶段，每个任务一条 | 普通 |
| 🔄 同步进度 / ✅ 同步全部完成 / ⚠️ 同步完成 / ⏸️ 同步轮次收摊 / ⛔ 同步中断 | `sync_progress.sh` | 进度面板原地刷新（删旧 + 发新）；终态四种标题、五条判定分支（收摊=预算到站下轮接力；中断=未注册任何任务） | 面板直连 |
| ✅ {task} 同步完成 / ⚠️ {task} 部分文件同步失败 / ⚠️ {task} 部分文件已通过其他方式同步 / ⚠️ {task} 同步失败 | `sync_notify.sh` | 同步结束，按结果分四类标题、五条分支（「部分文件同步失败」与「同步失败」内部再分叉） | 普通 |
| 📁 {task} · 错误日志 | `sync_notify.sh` | 同步失败后随 `sendDocument` 附上的日志文件 | 直连 |
| ⏭️ 同步任务跳过 | `sync_marker.sh` | 落在跳过窗口内 | 普通 |
| 🚨 源端大小异常减小 | `sync_marker.sh` | 源端比上次记录缩水超阈值 | alert |
| 🚨 存储账号失效 · N | `openlist_storage_check.sh` | 容器就绪后、同步开跑前巡检：有存储驱动登录态失效即告警，含受影响同步对 | alert |
| ⚠️ 落盘即时校验已降级 | `file_fix_pipeline.sh` | 修复管线落盘后即时校验未通过，防御性告警 | alert |
| 🔧 修复文件一键还原完成 | `file_restore.sh` | 还原 marker 修复条目到原路径 | 普通 |
| 🆘 灾难恢复完成 / 🆘 镜像灾难恢复完成 | `file_restore.sh` | 目标端回填源端（镜像变体会删源端多余文件） | alert |
| 📈 同步趋势 | `sync_trend.sh` | 一轮结束，输出净传速率与 ETA | 普通 |
| ✅ / ❌ 视频分割成功 · 失败 | `file_split.sh` | 单文件 ffmpeg 切割 | 普通 |
| ✅ / ❌ 7z 分卷成功 · 失败 | `file_split.sh` | 非视频大文件分卷 | 普通 |
| 📊 前置大文件处理总结 | `file_split.sh` | 前置大文件批处理结束（仅确有处理量才发） | 普通 |
| 🧪 备份恢复演练完成（只读 · 未改动任何文件） | `restore_tryrun.sh` | 演练收尾（`openlist-restore-tryrun.yml` 触发）：摘要 + 缺失限量 8 条，逐条明细走 tryrun.tsv 附件与运行日志 | 普通 |

> `task_engine.sh` 是 `⏭️ 同步任务跳过` 与 `🚨 源端大小异常减小` 的**触发点**
> （经 `sync_marker.sh` 发出），并构建自动分割统计片段（`🔀 子任务拆分统计` /
> `🔀 文件批次拆分统计`），由 `sync_notify.sh` 嵌进同步结果通知。

### 1.2 Telegram 频道视频管线（`.github/scripts/tg-channel/`）

编排在 `ph-dl.yml`（`CAPTION_PREFIX=ph`）与 `upload-video-to-tg.yml`
（`CAPTION_PREFIX=91`）。

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| 📺 / ⚠️ / ❌ {CAPTION_PREFIX} | `sync_to_tg.sh` | 一轮频道同步结束（全失败 ❌ / 部分失败 ⚠️ / 否则 📺）。标题只有 emoji + 前缀（实际渲染 `📺 ph` / `📺 91`），无「同步汇总」后缀 | 普通 |
| ❌ 获取远端文件列表失败 / ❌ 下载失败 / ⏭️ 损坏视频已标记跳过 / ❌ 处理/上传失败 | `sync_to_tg.sh` | 单文件级失败即时通知 | 普通 |
| 🔍 ph-dl 重复视频检测与去重 | `dedupe_ph_videos.sh` | 发现重复组（按 ID） | 普通 |
| 🔍 {WORKFLOW_LABEL} 重复视频检测与去重 | `dedupe_videos_by_hash.sh` | 发现重复组（按哈希；label 默认 `91-tg`） | 普通 |
| 🧹 ph-dl 清理 yt-dlp 残留文件 | `cleanup_ytdlp_residual.sh` | 清理 `-Frag` / `.ytdl` / `.m3u8`（清理数为 0 不发） | 普通 |
| 🧹 {label} 频道清理完成 | `reset_tg_channel.sh` | 清空频道并删 uploaded/failed 记录 | 普通 |

> 「按 ID / 按哈希」是正文 `重复 ID` / `重复哈希` 的区分，不进标题。

### 1.3 备份与任务结果（workflows 内联）

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| ✅ …备份成功 / ⚠️ …备份状态异常 / ❌ …备份失败 / ⛔ 任务已中断 | `github_backup_all.yml`、`self-hosted_backup.yml` | 备份结束，`if: always()` 四态（cancelled=⛔ 中断，区别于 ❌ 失败） | 成功普通；其余 alert |
| ☁️ / ⛔ / ❌ iCloud 照片下载 | `icloud-photos-downloader.yml` | 独立 `if: always()` step，按 `job.status` 三态 | 普通 |
| ✅ / ⚠️ PixivUtil2 任务完成 / ⚠️ PixivUtil2 未完成 / ❌ PixivUtil2 cookie 已失效 / ❌ PixivUtil2 未运行 | `pixivutil2.yml` | 按退出码分态：1/45=收藏 404/已删除（⚠️）；未知错误 ⚠️（run 仍红）；cookie 失效与启动前中断 ❌ | 失败/未运行 alert |
| 🗑️ ph-dl 新增损坏视频 · N | `ph-dl.yml` | 新下载文件完整性检查失败：已删除并重置下载记录，下轮自动重下 | 普通 |
| ✅ ph 收藏夹同步完成 | `ph-dl.yml` | 收尾恒 ✅——损坏丢弃属「只能接受」终态（明细走 🗑️ 单独通知与 kv；库存累计数只作 kv） | 普通 |

### 1.4 入口与凭据

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| 🟢 OpenClaw Runner 已就绪 | `openclaw.yml` | Tailscale SSH 就绪，推 SSH / RustDesk / 出口网络 / 出口节点 / AI 网关 | alert |
| ⚠️ Tailscale SSH 入口设置失败 | `openclaw.yml` | SSH 入口建立失败（可动手项） | alert |
| 🟢 workbuddy-gateway 已就绪 / ⚠️ 已启动 · 无可用账号 | `run-workbuddy.sh` | 本地代理网关（8318）启动自检后（账号池为空时降级 ⚠️）。字段口径见 3.1 节 | alert |
| 🟢 zcode2api 已就绪 | `run-zcode2api.sh` | 本地 GLM 网关（8319）启动自检后；降级态见 1.5 节 | alert |
| 🟢 qingyan-proxy 已就绪 / ⏭️ 已跳过 / ❌ 启动失败 | `run-qingyan.sh` | 清言反代（8320）端到端自检后；条件不满足跳过 / 60 秒未监听失败 | 就绪/失败 alert；跳过普通 |
| 🟢 autoclaw-proxy 已就绪 / ❌ 启动失败 | `run-autoclaw.sh` | AutoClaw 积分反代（8322）端到端自检后；凭据缺失跳过不起假服务 | alert |
| 🟢 / ⚠️ trae2api 已就绪 / ❌ 部署失败 · 启动失败 | `run-trae2api.sh` | TRAE SOLO 反代（7864）健康检查通过、批量签到后（签到工具失败降级 ⚠️）。字段口径见 3.2 节 | alert |
| 🟢 qoder2api-hub 已就绪 / ❌ 启动失败 | `run-qoder2api.sh` | qoder2api 网关启动自检后 / 部署或自检失败 | alert |
| 🟢 Windows runner 已就绪 | `tailscale-windows.yml`（pwsh 手拼） | Tailscale SSH 就绪，推 SSH / RDP / 出口网络 | alert |
| 🖥️ Windows RDP 已就绪 | `rdp.yml`（pwsh 手拼） | 隧道地址拿到后推 RDP 凭据 | alert |
| 🔐 OpenList 凭据 | `emby.yml` | OpenList 改密后私信凭据（仅真正改密时发） | alert |

凭据通知**没有特殊发送通道**：照样用 `tg_add_*` 构建（密码走机器值口径自动等宽 +
转义）再发。不要为凭据自造「单发不重试」的实现——429/400 都意味着上一条没被
Telegram 收到，放弃重试只会让凭据彻底丢失。

### 1.5 网关降级态与告警

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| 🟡 zcode2api 已就绪（Plan 通道降级 / 全部通道额度耗尽 / 回退通道已关闭） | `run-zcode2api.sh` | 自检失败先分类再选标题：额度耗尽 / 账号池全冷却 / 回退通道关闭 / Plan 通道降级 → 🟡（服务在，等即可，**且不进接力静默、每轮必报**）。完整口径见 3.3 节 | alert |
| 🟠 zcode2api 鉴权失败 | `run-zcode2api.sh` | 网关 Key 或上游鉴权不符（需人工介入） | alert |
| 🔴 zcode2api 账号池风控停用 · 需人工解封 | `run-zcode2api.sh` | 账号池被上游风控停用 | alert |
| 🟢 zcode2api 风控解除 · 账号池恢复 | `run-zcode2api.sh` | 风控解除、账号池恢复可用 | alert |
| ❌ zcode2api 启动失败 | `run-zcode2api.sh` | 部署/依赖失败，或自检两通道（Plan + bigmodel Key）均无有效回答 | alert |
| 🟢 / 🟡 AI 网关已就绪 · {backend} | `run-ai-gateway.sh`（同步路径）、`notify-omniroute-deferred.sh`（OmniRoute 延后路径） | AI 网关（OmniRoute→CliRelay→CLIProxyAPI 降级链）部署收口：主用就绪且容器 healthy 🟢、服务已监听但容器健康检查未过 🟡（等即可）。**OmniRoute 就绪通知延后发送**：后台等首个容器健康结论（上限 5min，超时按现值仍发），healthcheck 保护期内的 `starting` 不再假报 🟡；部署收口/隧道不等待 | alert |
| ⚠️ AI 网关已降级 · {backend} | `run-ai-gateway.sh` | 自动降级（附回退原因） | alert |
| ❌ AI 网关全部未就绪 / ❌ OmniRoute（pinned）未就绪 / ❌ CliRelay（pinned）未就绪 / ❌ CLIProxyAPI（pinned）未就绪 | `run-ai-gateway.sh` | pinned 失败或三后端全败 | alert |
| 🚨 OmniRoute 归档恢复失败 · 空库兜底 | `run-ai-gateway.sh` | Dropbox 归档存在但本轮恢复未走通、已 bootstrap 空库（P0 数据事故信号） | alert |
| 📊 workbuddy-gateway 模型倍率 · 模型数量 N | `run-workbuddy.sh` | 独立第二条通知（非就绪通知分节），自带标题 + `<pre>` 倍率表；发送失败只 `::warning::` 留痕 | alert |
| AI 网关用量报告 | `openclaw.yml`（`board.py usage-report` 生成正文） | 用量报告 step，标题与内容由看板真源给出（仓库内无标题字面量）。口径见 3.6 节 | 普通 |
| ⚠️ ZCode 数据提前恢复失败 / ⚠️ 辅助 CLI 安装失败 | `openclaw.yml` | zcode.tar.gz 下载/校验失败或 rclone 不可用（提前恢复步）；clawhub npm 安装失败 | alert |
| 🚨 vaultwarden 数据恢复失败 | `p.yml` | Dropbox 备份缺 `db.sqlite3`：本轮终止、不启动空库、不回传（防空库覆盖远端好数据） | alert |
| 🚨 Dropbox 挂载失败 | `openclaw.yml`（Mount Dropbox） | 挂载失败先发告警（附日志尾部 1200 字节）再 `exit 1`，不带病跑整轮 | alert |
| 🚨 OpenClaw 自愈失败 | `openclaw.yml` | 主步骤失败，推失败阶段 / 版本 / 关键日志 | alert |
| ⚠️ 归档告警 · {对象} / ⚠️ 最终归档告警 · {对象} | `openclaw.yml` | 周期/最终归档失败（rclone/tar；标题带对象）。两个告警函数分处不同 step、定义无法共享，**改版式时两处一起改** | alert |
| ✅ / ⚠️ / ❌ OpenClaw 最终归档完成 · 部分失败 · 失败 | `openclaw.yml` | 最终归档收尾，按对象汇总（全败 ❌；有失败 ⚠️「完成 · 部分失败」） | 全败 alert；✅/⚠️「完成」普通 |
| ⚠️ OpenClaw 最终归档未完成 | `openclaw.yml` | 没产出明细时的兜底（与上一条同 step） | alert |
| 🚫 Dropbox 配额不足，本轮已中止 | `openclaw.yml` | 归档前置预检：剩余空间低于阈值即中止本轮，不空转刷失败告警 | alert |
| ℹ️ OpenClaw 约 N 分钟后进入收尾 / ⛔ OpenClaw 约 N 分钟后停机 | `openclaw.yml` | keepalive 剩余约 15 分钟时的收尾预警与停机通知（配对） | 收尾普通；停机 alert |
| 🔄 新 run 已启动 | `openclaw.yml` | 接力启动成功、解析到新 run id 后推送新旧 run 链接 | 普通 |
| 🧯 保活接力已熔断 | `lib/self_retrigger.sh` | 连续 N 轮 failure 达阈值后停止自动接力。全部 9 个调用方的接力步都注入了 TG 凭据（含 `_ALERT`），见 1.9 节 | alert |
| ❌ workbuddy-gateway 启动失败 | `run-workbuddy.sh` | serve 启动即退或超时未监听 8318 | alert |
| ⛔ {服务} 已停止 / ⚠️ {服务} 已停止 · 进程残留 | 各 `run-*.sh` / `openclaw.yml` | 收尾停服（仍有进程残留时降级 ⚠️ 并加「进程残留」后缀），与下一轮「已就绪」配对确认生命周期闭环 | alert |
| ⚠️ Emby 直链已回退 | `emby.yml` | 探活连续失败切直连 | alert |
| 📺 / ⚠️ Emby 服务启动 | `emby.yml` | 服务与隧道就绪自检（取链自检未过降级 ⚠️） | alert |
| ✅ / ❌ / ⛔ / ⚠️ Emby 服务停止 | `emby.yml` | 收尾，按 `job.status`（未知状态兜底 ⚠️） | alert |
| 🎬 {片名}（播放通知） | `emby.yml` | 每次播放事件（短时间内去重） | 普通 |

### 1.6 测速三套（`.github/scripts/proxy-speedtest/`）

发送走 `speedtest_common.py` 的 `send_telegram` / `send_telegram_chunked`
（均支持 tier 参数，语义与 bash 真源一致：alert 无回落、凭据缺失留痕）。

| 通知 | 在哪 | 何时发 |
|---|---|---|
| ✅ / ⚠️ {label ·} CDN 测速完成 | `speedtest.py` | 主报告（0 可用节点 / 到点收摊 / bypass 全命中降级） |
| ✅ / ⚠️ {label ·} Gitee 测速完成 | `speedtest_gitee.py` | 主报告（运行中中止 / 0 可用（按下载口径）/ 到点收摊降级） |
| ✅ / ⚠️ {label ·} 泰尔三网测速 | `taier_speedtest.py` | 主报告（0 成功 / 疑似未走代理 / 到点收摊降级） |
| ❌ …测速异常退出 · {原因} / ⛔ …测速异常终止 | 三套各自 | 可控退出、未捕获异常、信号终止兜底（taier 发送前先撤 TUN）；**alert 档**（notify_best_effort / 未捕获 handler 显式传 'alert'） |

- `PROXY_SPEEDTEST_LABEL` 只拼**主报告**标题（`✅ gist 节点 · 泰尔三网测速`）；
  ❌ 异常退出 / ⛔ 异常终止兜底标题**不带** label（形态见规范 · 失败与异常）。
- 三套「到点收摊」降级行位置完全一致：紧跟「📊 节点：共 N 个 · 可用 M 个」的
  **下一行** `⚠️ 本轮已中止：{原因}`。收摊与运行中中止都不是失败，退出码仍 0。
- taier 的「⚠️ 测活探测异常」分节已删除（机制没跑通不产生判死条目）；「表里没有
  该节点」是明确判死，计入 `❌ 失败`、错误串带「测活未通过：」前缀。若该分节再出现
  即为回退。详见 `proxy-speedtest-taier.md`。

### 1.7 媒体 caption（特殊形态）

随视频发出的 caption：**没有标题、分隔线、收尾区**（收尾区唯一固有例外），拼完即随
媒体发出。三行依次为文件名 / 大小 / 修改时间（东八区）；分片场景中间行换
`part N/M (大小)`，仍三行。不走 sendMessage 发送层，但
必须转义并显式 HTML parse_mode，429 重试同口径（最多 5 次）。实现：
`tg_send_video.py`（Telethon）、`sync_notify.sh` sendDocument（重试 5 次）。

> 别与 1.2 的 `CAPTION_PREFIX` 搞混——那是**普通消息**的标题前缀，走发送层。

### 1.8 本机常驻服务告警（看板 / 哨兵）

由本机常驻进程发出（看板主循环 `board.py`、systemd timer 哨兵
`gateway-watchdog.py`、健康看门狗 `health/system_health.sh`），**没有 GitHub run
上下文**，收尾区用 `🕒` 报告时刻（规范 · 收尾区「常驻服务例外」）。

这两个进程**不在本仓库**，实际位于宿主机 `/dropbox/self-hosted/quota-board/`；
仓库内只有对它们的调用/引用（如 `services.sh`、`run-*.sh`），通知内容无法在本仓库
核对。

| 通知 | 在哪 | 何时发 | 档位 |
|---|---|---|---|
| 🚨 网关服务异常 / ✅ 网关服务恢复 | `gateway-watchdog.py` | systemd 单元 / 容器 / 公网链路连续 2 轮异常；恢复边沿发 ✅ | alert |
| ⚠️ {数据源} 数据源失联 | `board.py` `eval_alerts` | 连续 3 轮采集失败（恢复静默销账） | alert |
| 🚨 workbuddy 网关疑似失能 / ✅ workbuddy 网关数据已恢复 | 同上 | 状态快照停更超阈值；恢复边沿发 ✅ | alert |
| 🚨 系统级故障 / ✅ 系统健康恢复 | `health/system_health.sh`（systemd user timer，每 5 分钟） | 挂载 / 隧道 / 看板 / gateway 状态变化时发；异常持续每 6 小时补提醒；恢复边沿发 ✅。启动后 40 分钟内豁免看板/gateway | 故障 alert；恢复普通 |

### 1.9 不发通知的 workflow

- **完全零通知**：`cfip-pool.yml`、`delete-workflow-runs.yml`、`eshop.yml`、
  `openlist-debug.yml`、`openlist-marker-cleanup.yml`、`socks-exit-pool.yml`、
  `subs-check.yml`、`tests.yml`。要补的话照 1.3 备份类的形态（规范 · 结果通知），
  并把 `TG_RUN_URL` 接上。
- **自身不发、但 run 级会发**：`proxy-speedtest-gistnodes.yml`。文件头已声明「通知
  全部由被复用的那套完成」；它经 `workflow_call` + `secrets: inherit` 调三套测速，
  由被调 workflow 发主报告（普通）与异常兜底（alert）。统计「有通知的 run」时要算上。
- **已知死配置**：`openlist-diag.yml` 与 `openlist-fix-check.yml` 在 job 级注入
  `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID`，但两个 workflow 及其调用的
  `diag_*.sh` / `fix_check.sh` 一次都没有发送。当前无发送需求，保留注入不做改动
  （删掉会让将来想接通知的人找不到接在哪），但这两份凭据不产生任何通知，别把它们
  算进「哪些 workflow 在发通知」的清单。
- **保活型 workflow 的接力步**（`HomeAssistant.yml`、`jellyfin.yml`、`ql.yml`、
  `sub-store.yml`、`teslamate.yml`、`tailscale-windows.yml`、`p.yml`、`emby.yml`、
  `openlist.yml`）都 `source self_retrigger.sh`，因此 🧯 熔断告警在任何调用方都能
  真实发出。其中 `HomeAssistant` / `jellyfin` / `ql` / `sub-store` / `teslamate`
  自身不发业务通知；`p.yml`、`tailscale-windows.yml`、`emby.yml`、`openlist.yml`
  另有自己的业务通知（见 1.3–1.5），别把它们并进「纯保活」清单。
- scripts 侧无通知的目录：`socks-exit/`、`cfip/`、`rclone/`、`tailscale/`、
  `tunnels/`、`services/`（✅/❌ 全是 CI/journal 日志行）。

---

## 2. 台账维护判据

- 新增通知 → 对应域表格加一行；改名 → 改标题列；下线 → 删行。
- 档位变化 → 改档位列，并核对 step 是否注入了 ALERT 凭据（规范 · 接线）。
- 本文件与实现冲突时，**以实现为准**并当场修正本文件；规范层冲突才需要动
  `telegram-notify.md`。

---

## 3. 域字段口径

这些口径跟着实现走（改实现先查这里对齐项），放在台账是为了和「在哪」同处一页。

### 3.1 workbuddy-gateway（`run-workbuddy.sh`）

**结论**取自 serve 日志的「账号池」行（`有效 N, 失效 M`）；**接口**是
`http://127.0.0.1:8318/v1`（启动显式传 `-port 8318`——上游默认 8317，OpenClaw 主
AI 网关走 20128 OmniRoute，别把「上游默认」和「本仓库实际绑定」混为一谈）。
**API Key** 一行等宽回显（`tg_add_path`，`AI_GATEWAY_API_KEY`），写「未取到」兜底，
不编造密钥值。「🔑 凭据」分节已移除（凭据文件名与账号池条目名逐字重复，渲染两遍
纯占版面）；`WB_CREDS` 变量保留——签到汇总仍用它算「跳过」数。**绝不回显
`workbuddy*.json` 文件内容**（真实 Access/Refresh Token）；`workbuddy-status.json`
是 serve 写的状态快照，不算凭据。

**账号池**逐账号：`凭据文件 · 站点 · 状态`，子行 = `冷却时刻（仅冷却中） · 额度 ·
免费/付费 · Token 过期 · 模型冷却 N · 最早 HH:MM 恢复` 与
`免费模型 N · <模型名>`（各项非空才并入；免费模型名很多时拆独立子行）。
**排序（2026-10-26 定）**：站点（国内站前）→ D 账号 → 数字账号按 131→156→175→176
升序 → 其他保持原序（与看板 `sortAccounts` 同规则）。

> **数据源**：`workbuddy-status.json` 键名由上游 Go 结构体 json tag 固定
> （`path` / `edition` / `state` / `tokenExpiresAt` / `quotaRemaining` / `quotaKnown` /
> `isPaidUser` / `cooldownUntil` / `cooldownMsg` / `freeModels` / `modelCooldowns` /
> `modelStates`）。`freeModels` 是**降级兜底**计数；正式免费模型**名单**走上游模型
> 目录接口（`GET {Base}/v2/enterprises/personal/models`，国内站
> `copilot.tencent.com` / 国际站 `www.workbuddy.ai`，按账号 `edition` 分别请求，
> 只读不耗额度；免费判据照上游 `siteKnownFree`：生效倍率 0 且促销未过期）。
> `modelStates` **不进通知**（只含已实测模型、口径与目录接口不同）。
> 中文状态名照上游 `monitor` 映射；额度格式照 `formatQuota`；
> **`quotaKnown=false` 不显示额度数字**（写「额度未获取」，显示 0 会与「额度耗尽」混淆）。
> `nickname` / `uid` 不进通知（隐私）。serve 每 3 秒重写该文件、可能读到半截导致
> jq 失败：失败就本轮账号池整段跳过，不发半条、也不据此判服务未就绪。

**冷却两层都要给恢复时刻**：

| 层级 | 快照字段 | 通知写法 |
|---|---|---|
| 账号级 | `cooldownUntil`（秒）+ `cooldownMsg` | 子行 `冷却 YYYY-MM-DD HH:MM`（`state=cooldown` 才写） |
| 模型级 | `modelStates[模型名].cooldownUntil` | 子行 `模型冷却 N · 最早 HH:MM 恢复`（N>0 才写） |

- 时间一律**绝对时刻**不折算「还剩多久」；账号级完整日期时间，模型级只 `HH:MM`
  且取所有冷却中模型里最早的。`cooldownUntil` 为 0/缺失整项跳过（不写「冷却 -」）。
  `cooldownMsg` 不跟进通知（可能上百字符，读者要的是「何时恢复」）。

**每日签到段**：分节 `🗓 每日签到 · N`，条目行 = `凭据 · 站点 · 结果 · 本次 +N ·
累计 N · 连签 N 天`（积分三项仅 `active=true` 且已签时拼接，查询失败绝不编造）；
子行 `Buddy 旅行 +N`（仅日志落过旅行奖励，窗口=今天东八区全天）；段尾 kv
`本轮汇总` 与 `下次签到`（服务定时点，东八区）。签到接口响应体被网关丢弃，积分
真源是活动状态接口 `POST {Origin}/v2/billing/meter/checkin-activity-status`
（只读幂等，`data.active` / `today_checked_in` / `today_credit` / `total_credits` /
`streak_days` / `daily_credit`）。国际站没有签到活动（积分按每日活跃对话发放）：
启动步发最小活跃请求（免费模型 + max_tokens=64 + 客户端特征头），200 且确为对话流
才落当日标记（`活跃 ✓ 已触发`）；429 按响应恢复时刻落 defer 文件，显示
「活跃待重试 · 限流 HH:MM 后自动重试」；**绝不预填到账数字**。汇总行仅状态接口
全覆盖时按展示行重算，有查询失败退回网关日志口径。

**账号池 TSV 的每一列都不许为空：空值一律填哨兵 `-`**。制表符属 `IFS` 空白、连续
制表符折叠成一个，中段空列会整体左移错位（实测把冷却数当成模型名渲染出
`免费模型 1 · <code>2</code>`——编造不存在的模型名）。jq 侧空值填 `-`，渲染侧读入
先还原空串再按「非空才并入」处理。列序：判定标记、凭据文件、站点、状态、账号级
冷却、额度、**免费模型名（第 7 列）**、**模型冷却（第 8 列）**、Token 过期。
**`免费模型 N` 的 N 以名单长度为准**（`freeModels` 是「已实测」数，两者不同），
仅降级拿不到名单时才用快照计数。**免费模型清单属结构性清单，全量展示不折叠**
（规范 · 折叠规则），单个模型名是机器值 → `<code>`。

「数据目录」指 Dropbox 持久数据目录（读者要照着放凭据的地方），不是本轮本地运行
目录。「原因」按日志尾部分流：`Permission denied` → 二进制不可执行；未检测到有效
凭据 → 需人工扫码；其余 → 启动即退。「更新」只在版本变化（或首次安装）时出现，
「已在最新版」不写进「原因」。对象（版本 / 数据目录）机器值 → `<code>`，结论与
原因裸文本，原始日志 `<pre>` 且是正文最后一块。

### 3.2 trae2api（`run-trae2api.sh`）

版式同 workbuddy-gateway（第三个 AI 网关的对齐实现），差异在数据来源：

- **`🩺 签到健康 · N`**（N 是账号数不是失败数）：分节计数后另起说明段点明「N 个
  账号有备注」；条目主体「昵称 · 健康备注」自然语言 → `tg_add_entry_text` 裸文本；
  全健康整段跳过。备注含：上次成功日期、⚠️ 连续失败 N 次、签到设备换代 +1
  （自愈动过手的证据，不加 ⚠️）、⏳ 退避重试中（已退 N 次）。
- 标题：`🟢 trae2api 已就绪` / `⚠️ trae2api 已就绪 · 签到无输出` /
  `❌ trae2api 部署失败`（Release 解析失败 / SHA256SUMS 缺失）/ `❌ trae2api 启动失败`
  （容器健康检查 120 秒未过）。结论以「已就绪」打头、只列非零签到计数
  （`已就绪 · 已签 X · 待签 Y · 失败 Z（共 N）`）。
- 「版本」写本轮部署的 **Release tag**（取 fork Release 静态二进制，非源码构建）；
  「更新」与数据目录记录的上轮 tag 对比，未就绪轮次不落账、下轮仍报。
- 「💳 账号池」来自批量签到输出：条目 `uid · 昵称 · 状态`，子行给未用完积分包里
  最早过期的 3 个（`剩 N 分 · 时刻 过期`）。
- 「🧾 原始输出」非空才渲染：启动失败给容器日志尾部；签到分支给签到工具 stderr
  尾部（均 1200 字节）。正文另有「📊 模型倍率 · N」分节（数据源 `/v1/models` 的
  consumption_rate）——与 workbuddy 的独立第二条通知同名不同体。
- 「用量 + 流水」段（wb_notify 同款）：调 quota-board 的
  `board.py usage-ledger <gateway> 12` CLI，与看板共用渲染与数据源，输出为空静默跳过。

### 3.3 zcode2api（`run-zcode2api.sh`）

本地 GLM 网关（8319，Anthropic + OpenAI 双协议）。代码来自 jarvanh/zcode2api fork，
.env 与账号池数据快照在 Dropbox `self-hosted/zcode2api-data.tar.gz`；
credential_sync.py 每轮对齐凭据，收尾归档回传快照，凭据闭环；仅结构性变更
（增删账号、改 .env）才需手动重传。

- **自检是真发消息**：判据「上游返回了助手内容块」（`content` 数组非空即过——GLM 是
  思考模型，`max_tokens` 小了会只有 `thinking` 块，按 text 判会误报）。healthz/模型
  列表通不算数。
- **Plan 通道降级如实报**：主探 `glm-5.3-flash`（Plan 通道，仅验证码类错误重试
  3 轮）；全败退探 `bigmodel/GLM-5.3`（Key 通道；**网关侧默认关闭**，关闭时退探
  即时 403 channel_disabled）。退探能通 = 服务本体健康、仅 Plan 通道降级 → 🟡，
  **降级轮不进接力静默**（每轮必报）。
- **🟡/🟠 中间态分类**：`quota`（额度耗尽）/`unavailable`（账号池全冷却）→
  `🟡 已就绪 · 全部通道额度耗尽`（结论写明「非启动故障」）；`channel`（回退通道被关）
  → `🟡 已就绪 · 回退通道已关闭`；`auth`（网关 Key / 上游鉴权不符）→
  `🟠 鉴权失败`。红色 ❌ 只留给真正的启动失败。
- **失败态不给「接口 / 鉴权 / 模型」三行**（服务已不在，展示指向已停进程的地址会
  误导）；自检输出与服务日志尾部（各 15 行）进「🧾」分节。
- **💳 账号池分节**：条目行 = `名称 · 通道 · 状态`，子行 = 额度/有效期/套餐 +
  最近错误（有效期取 quota.expires_at、精确到时刻、固定 TZ=Asia/Shanghai）。
  数据源是 admin API 脱敏视图；服务已监听才采集，失败只少一节不改结论。就绪与
  失败通知都带。
- **API Key**：独立 secret `ZCODE_GATEWAY_API_KEY` 注入为 `ZCODE_GATEWAY_KEY`
  （2026-10-05 起与 workbuddy 的 key 分家；qingyan 用 `GLM2API_GATEWAY_KEY`）。
  写「未取到」兜底，不编造密钥值。

### 3.4 Emby 起播等待（`emby.yml` / `docs/emby.md`）

括号说明统一**紧跟被测量的对象、在冒号之前**（`…Emby（预估值）：627 毫秒`）。
`取直链` 行的括号标**本次取链的性质**：`（缓存命中）` / `（冷解析）`；对象本身已有
括号时**并入同一括号、以 ` · ` 分隔**。判据优先取 odlink 的真实缓存命中标记，
取不到按耗时阈值兜底（`EMBY_LINK_HOT_MS`，默认 200 毫秒）；**两者都取不到时省略
标注，不猜**。括号内容自然语言裸文本。取值与兜底规则见 `docs/emby.md`「起播等待」。

### 3.5 资产段（路线 B：口径真源在看板）

`📅 资产 · 签到与有效期` 是就绪通知的内嵌段（`run-{workbuddy,trae2api,zcode2api,
qoder2api,autoclaw}.sh`）：签到汇总 + 时间维度（wb 额度刷新 / zcode 套餐到期 /
trae 即将过期 / autoclaw 今日领取）。数据源 = `board.py assets <src>` CLI——口径
真源在看板，通知只引用，零漂移。`run-qingyan.sh` 走同一 CLI 的 TSV 分支（净额），
不自带分节。看板改口径后跑规范 · 资产段桥接冒烟。

### 3.6 AI 网关用量报告

`openclaw.yml` step `Notify AI gateway usage report`（普通档）：标题与内容来自
`board.py usage-report`，仓库内无标题字面量。普通档发送。
