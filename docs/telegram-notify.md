# Telegram 通知规范（全库唯一真源）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）都在这里找答案。

## 1. 这份文档怎么用

这份文档是**风格指南**，不是军规：绝大多数条目是「建议 + 为什么 + 反例/正例」，
目的是让你在没有先例可循时也能写出和别人风格一致的通知。

只有三处是**硬约束**（不遵守会造成通知丢失或误判失败），改动前请务必读：

| 硬约束 | 位置 | 为什么是硬的 |
|---|---|---|
| 发送层行为（429 重试 / 400 不重发 / 必须转义 / 不得 curl 直发） | [第 6 章 发送层要求](#6-发送层要求) | 不遵守 = 通知静默消失或限流丢消息 |
| 收尾区与接线（`TG_RUN_URL` / `TG_RUN_STARTED_AT`） | [4.9 节 收尾区](#49-收尾区硬要求) | 不遵守 = 通知没有运行日志入口 |
| 回归测试基线（19 套件、`command not found` 归零） | [第 7 章 测试与交付基线](#7-测试与交付基线) | 不遵守 = 无法判断改动有没有破坏既有通知 |

**改动流程建议**：改版式先改这份文档，再同步实现；实现改完跑一遍渲染预览
（[7.3 节 渲染预览](#73-渲染预览强烈建议)）和相关测试。

---

## 2. 设计原则

### 2.1 一条通知要回答三个问题

> **发生了什么 / 影响多大 / 我要做什么**

写通知前先过一遍这三问，比纠结用哪个 emoji 更有价值：

- 发生了什么 → 标题（emoji + 短语）+ 状态 kv
- 影响多大 → 计数与量化（失败 3 个 / 减少 100 GiB / 跳过 12 条）
- 我要做什么 → 复制即用命令块、下一步说明、运行日志链接

### 2.2 视觉层级靠三件套，不靠粗体

| 手段 | 承担的作用 |
|---|---|
| 分隔线（`━━━` 18 条） | 标题锚点 |
| 空行 | 段落/分节边界（只有三处产生，见第 4 章） |
| emoji | 语义与状态的彩色锚点（比粗体更醒目） |
| 等宽 `<code>` | 「这个可以复制」的机器值 |

因此**全库不用 `<b>` 与 `<i>`**：加粗/斜体能提供的区分，上面三件套已经给足；
而且省掉了「哪个位置该加粗」的判断成本（条目主体 vs kv 值的边界很难说清）。
另一个理由：`<i>` 对中文几乎看不出效果，却会让 HTML 变复杂。

### 2.3 只有三处需要标签

| 标签 | 用在哪 |
|---|---|
| `<code>` | 机器值：路径、文件名、命令、密码、IP、ID、端口、原始异常串 |
| `<pre>` | 多行块：日志、复制即用命令、异常栈（保留换行、整块复制） |
| `<a>` | 链接（收尾区运行日志、订阅源等） |

其余一律裸文本——但要**转义**（动态内容里的 `& < >` 会触发 400，见第 6 章）。

**取值行口径（同一分节内必须一致）**：一条取值行（`标签：值`）的值是等宽还是裸文本，
只看一件事——**它是不是机器返回的值**：

| 值的性质 | 口径 | 例 |
|---|---|---|
| 机器返回（IP、ISP、ASN、位置、主机名、域名、版本、ID、端口、路径、文件名、命令、原始异常串） | `<code>` | `位置：<code>Tokyo, JP</code>` |
| 自然语言（原因、状态描述、结论、备注） | 裸文本 | `状态：部分失败` |

判定标准取「来源」而不是「值不值得复制」：一次归属查询返回的 IP / ISP / ASN / 位置
同属一批机器返回值，就该整节同为等宽。若按「ISP 和位置没人会去复制」逐个判断，
同一节就会变成「IP 等宽 → ISP 正体 → ASN 等宽 → 位置正体」的斑马纹，
读者只能理解成版式出了 bug（2026-09-11 用户反馈）。计数、时长、状态这类
人写的结论值本来就裸文本，不受这条影响。

### 2.4 统一优先于个性

同一类信息在不同子系统里形态一致，读者才能跨通知扫读。
因此所有版式都尽量走真源助手（8.1 节），而不是各脚本自己拼字符串。

---

## 3. 通知种类索引

全库约 30 类通知，按子系统分组。表格给出「在哪 / 何时发」，其后给出
**代表性渲染示例**（示例取自实现代码结构，个别为构造示例，已标注）。

### 3.1 OpenList 同步域（`.github/scripts/openlist/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 📋 任务预览 · 任务名 | `task_preview.sh` | 预览阶段，每个任务一条 |
| 🔄 同步进度（刷新）/ ⛔ 同步中断 / ⚠️ 同步完成 / ✅ 同步全部完成 | `sync_progress.sh` | 进度面板原地刷新 + 三种终态 |
| ✅ 同步完成 / ⚠️ 部分文件同步失败 / ⚠️ 部分文件已通过其他方式同步 / ⚠️ 同步失败 | `sync_notify.sh` | 同步结束，按结果分四态 |
| ⏭️ 同步任务跳过 | `sync_marker.sh` | 落在 `--Nd-skip` 窗口内 |
| 🚨 源端大小异常减小 | `sync_marker.sh` | 源端比上次记录缩水超阈值 |
| 🔧 修复文件一键还原完成 | `file_restore.sh` | 还原 marker 修复条目到原路径 |
| 🆘 灾难恢复完成 / 🆘 镜像灾难恢复完成 | `file_restore.sh` | 目标端回填源端 |
| 📈 同步趋势 | `sync_trend.sh` | 一轮结束输出净传速率/ETA |
| ✅ 视频分割成功 / ❌ 视频分割失败 | `file_split.sh` | 单文件 ffmpeg 切割 |
| ✅ 7z 分卷成功 / ❌ 7z 分卷失败 | `file_split.sh` | 非视频大文件分卷 |
| 📊 前置大文件处理总结 | `file_split.sh` | 前置大文件批处理结束 |

**示例：任务预览**

```
📋 任务预览 · backup
━━━━━━━━━━━━━━━━━━
📊 同步对 · 1
📁 onedrive:backup
  └─ <code>aliyundriveCrypt/backup</code> · 源端 36.065 GiB / 1415 文件 · +7.268 GiB / +2 文件

📦 合计预估待同步：33.777 GiB / 43 文件 · 新增 38 · 同名更新 3

⏱ 已运行 22 分钟 · 🔗 运行日志
```

**示例：同步结果（部分失败）**

```
⚠️ task0 部分文件同步失败
━━━━━━━━━━━━━━━━━━
任务：task0
源端：onedrive:0/media
目标：openlist:0/media
源端大小：1.2 TB
目标大小：1.1 TB
状态：部分失败
文件数：源端 1415 / 目标 1412

🚫 排除规则 · 2
  ├─ <code>notion/**</code>
  └─ <code>*.tmp</code>

❌ 无法同步文件 · 2
  ├─ <code>media/大文件A.mkv</code> · 超过 45 GiB，需分割后重传
  └─ <code>media/损坏B.mp4</code> · moov atom 缺失

⏱ 已运行 34 分钟 · 🔗 运行日志
```

**示例：跳过通知（含复制即用命令块）**

```
⏭️ 同步任务跳过
━━━━━━━━━━━━━━━━━━
任务：media
跳过窗口：72 小时内
源端：<code>onedrive:0/media</code>
目标：<code>openlist:0/media</code>

🕒 上次同步
时间：2026-09-07 11:34 UTC · 3 小时前
记录大小：1.2 TB · 3200 文件

🛠️ 复制即用

▸ 强制同步（全量，含本任务）
<pre>gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true</pre>

⏭️ 本次跳过同步，继续执行其他任务

⏱ 已运行 3 分钟 · 🔗 运行日志
```

**示例：进度面板（简化，仅骨架）**

```
🔄 同步进度
━━━━━━━━━━━━━━━━━━
📊 总 12 · 待处理 4 · 进行中 1 · 完成 6 · 跳过 0 · 失败 1

📍 进行中 · 1
  └─ <code>onedrive:media/电影</code> · 3.1 GiB / 12 文件

✅ 已完成 · 2
  ├─ <code>onedrive:media/剧集</code> · 800 MiB / 5 文件
  └─ <code>onedrive:media/音乐</code> · 120 MiB / 30 文件

⏱ 已运行 18 分钟 · 🔗 运行日志
```

**示例：修复文件还原**

```
🔧 修复文件一键还原完成
━━━━━━━━━━━━━━━━━━
修复恢复：2 个
失败：1 个

✅ 已还原 · 2
  ├─ <code>media/视频A.mp4</code>
  └─ <code>media/视频B.mkv</code>

原路径原文件名

❌ 失败清单 · 1
  └─ <code>media/视频C.mp4</code> · 目标端写入被拒

成功条目已从 marker 修复清单移除；失败条目保留，可重试。

⏱ 已运行 5 分钟 · 🔗 运行日志
```

### 3.2 Telegram 频道视频管线（`.github/scripts/tg-channel/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 📺 同步汇总（CAPTION_PREFIX） | `sync_to_tg.sh` | 一轮频道同步结束 |
| ❌ 获取远端文件列表失败 / ❌ 下载失败 / ⏭️ 损坏视频已标记跳过 / ❌ 处理/上传失败 | `sync_to_tg.sh` | 单文件级失败即时通知 |
| 🔍 重复视频检测与去重（按 ID / 按哈希） | `dedupe_ph_videos.sh`、`dedupe_videos_by_hash.sh` | 发现重复组 |
| 🧹 ph-dl 清理 yt-dlp 残留文件 | `cleanup_ytdlp_residual.sh` | 清理 `-Frag/.ytdl/.m3u8` |
| 🧹 频道清理完成 | `reset_tg_channel.sh` | 清空频道 + 删 uploaded/failed json |
| 文件名 · 大小 · 修改时间（媒体 caption） | `transcode_and_send.sh` → `tg_send_video.py` | 每个视频随媒体发送，无标题与分隔线 |

> **两类「caption」别混淆**：本节的 📺 同步汇总（`CAPTION_PREFIX`）是**普通消息**，
> 走 `tg_add_title` + `send_tg`；而 `transcode_and_send.sh` 传给 `tg_send_video.py`
> 的才是**媒体 caption**——随视频发出、不走 sendMessage 发送层（第 6 章的固有例外），
> 但同样**必须转义并显式 HTML parse_mode**，否则文件名里的 `& < >` 会 400、
> markdown 语法字符会被 Telethon 默认解析吃掉。

**示例：频道同步汇总（构造示例，结构取自实现）**

```
📺 91
━━━━━━━━━━━━━━━━━━
视频文件：120 条
库存状态：已上传 118 · 待上传 2
损坏已跳过：1 条
本次处理：2 条
本次成功：2 条
本次失败：0 条

✅ 已上传 · 2
  ├─ <code>video_a.mp4</code> · 上传耗时 12.34 秒
  └─ <code>video_b.mp4</code> · 上传耗时 20.10 秒

⚠️ 跳过/过滤文件 · 1
损坏 · 1
  └─ <code>video_c.mp4</code>

⏱ 已运行 41 分钟 · 🔗 运行日志
```

**示例：重复检测（构造示例）**

```
🔍 91-tg 重复视频检测与去重
━━━━━━━━━━━━━━━━━━
目录：<code>91</code>
重复哈希：3
已删除：2

📋 详情
🔖 哈希 a1b2c3d4e5f6 · 第 1/3 组 · 2 个 · 文件名相同 · 保留 <code>keep.mp4</code>
  ├─ 🗑 删除 <code>dup_old.mp4</code> · 1.2 GB · 2026-09-01

⏱ 已运行 6 分钟 · 🔗 运行日志
```

### 3.3 备份与任务类（workflows 内联）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| ✅ …备份成功 / ⚠️ …状态异常 / ❌ …失败 / ⛔ 任务已中断 | `github_backup_all.yml` | 备份结束，`if: always()` 四态 |
| ✅/⚠️/❌/⛔ Self-Hosted 数据备份（同上四态） | `self-hosted_backup.yml` | 同上 |
| ☁️/❌/⛔ iCloud 照片下载（三态） | `icloud-photos-downloader.yml`（独立 `if: always()` step） | icloudpd 跑完，按 `job.status` 分态 |
| ✅/⚠️/❌ PixivUtil2 任务完成 / 任务失败 | `pixivutil2.yml` | 按 `PU_STATUS` 三态 |
| 🗑️ ph-dl 下载阶段损坏视频 / ✅ ph-dl 下载任务完成 | `ph-dl.yml` | 下载完整性 / 收尾 |

**示例：备份结果（结构取自实现）**

```
✅ GitHub 全仓库备份成功
━━━━━━━━━━━━━━━━━━
日期：2026-09-10
文件：<code>github_repos_latest.tar.gz</code>
文件大小：3.4 GiB

已覆盖旧包

⏱ 已运行 18 分钟 · 🔗 运行日志
```

### 3.4 入口与凭据类

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 🟢 OpenClaw Runner 已就绪 | `openclaw.yml` | Tailscale SSH 就绪，推 SSH/RDP/网络/网关 |
| 🚨 OpenClaw 自愈失败 | `openclaw.yml` | Run OpenClaw 步骤失败，推失败阶段/版本/关键日志 |
| ⚠️ OpenClaw 归档告警 | `openclaw.yml` | 周期归档失败（rclone/tar），按包各一条 |
| ⚠️ OpenClaw 最终归档告警 | `openclaw.yml` | 最终归档失败，版式同上（标题带「最终」区分阶段） |
| ⚠️ OpenClaw 即将进入最终归档 | `openclaw.yml` | keepalive 剩余 15 分钟时预警 |
| 🟢 Windows runner 已就绪 | `tailscale-windows.yml` | 同上（Windows） |
| 🖥️ Windows RDP 已就绪 | `rdp.yml` | ngrok 隧道地址拿到后推 RDP 凭据 |
| 🔐 OpenList 凭据 | `emby.yml` | OpenList 改密后私信凭据 |

**示例：入口通知（构造示例，结构取自 tailscale-windows.yml）**

```
🟢 Windows runner 已就绪
━━━━━━━━━━━━━━━━━━
🔐 SSH · 3
  ├─ 命令：<code>ssh runner@example.ts.net</code>
  ├─ 域名：<code>runner.example.ts.net</code>
  └─ 备用 IP：<code>100.64.0.1</code>

🖥️ RDP · 3
  ├─ 地址：<code>runner.example.ts.net:3389</code>
  ├─ 用户：<code>runner</code>
  └─ 密码：<code>********</code>

🌐 出口网络 · 4
  ├─ 出口 IP：<code>203.0.113.7</code>
  ├─ ISP：<code>Contoso</code>
  ├─ ASN：<code>AS64512 · Contoso</code>
  └─ 位置：<code>Tokyo, JP</code>

有效期：约 6 小时 · 超时自动结束

ℹ️ 域名固定不变 · IP 每次运行会变，仅作备用 · 密码 SSH/RDP 共用

⏱ 已运行 2 分钟 · 🔗 运行日志
```

> 凭据通知**没有特殊发送通道**：照样用 `tg_add_*` 构建（密码走 `tg_add_path`
> 自动等宽 + 转义）再 `send_tg`。不要为凭据自造「单发不重试」的实现——
> 429/400 都意味着上一条没被 Telegram 收到，放弃重试只会让凭据彻底丢失。

**示例：归档告警（结构取自实现）**

```
⚠️ OpenClaw 归档告警
━━━━━━━━━━━━━━━━━━
对象：<code>openclaw.tar.gz</code>
结论：上传失败 · 退出码 2
原因：rclone 上传失败
Run ID：<code>12345678</code>

🧾 原始输出
<pre>2026/09/12 09:00:00 ERROR : Failed to copy: connection reset</pre>

⏱ 已运行 41 分钟 · 🔗 运行日志
```

取值行口径同 2.3 节：对象（包名/标签）是机器返回值 → `<code>`；
结论与原因是人写的自然语言 → 裸文本 kv；rclone/tar 的原始输出 → 单独 `<pre>` 分节。
原始输出取尾部 1200 字节（与 `file_split.sh` 日志摘要同口径）——超长输出会让
`<pre>` 跨 4000 字符分片，标签断开即破版。

> 周期归档（`send_telegram_alert`）与最终归档（`send_archive_alert`）分处两个 step，
> 函数定义无法共享，**改版式时两处要一起改**。二者此前标题完全相同，读者分不清
> 告警来自哪一轮，故最终归档的标题带「最终」。

### 3.5 Emby

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 🎬 片名（播放通知） | `emby.yml` | 每次播放事件（180s 去重） |
| 📺 Emby 服务启动 | `emby.yml` | Emby + cloudflared 就绪自检 |
| ⚠️ Emby 直链已回退 | `emby.yml` | watchdog 连续探活失败切 direct |
| ⛔/❌/✅ Emby 服务停止 | `emby.yml` | 收尾，按 job 状态 |

**示例：播放通知**

```
🎬 五十度灰 (2015)
━━━━━━━━━━━━━━━━━━
规格：电影 · 2 小时 8 分 · 1080p · h264 · 5.5 GB
链路：⚡ 302直连 OneDrive · 直链剩余 40 分钟
客户端：203.0.113.57 · Safari · macOS

⏳ 起播等待 · 4
  ├─ 你 → Cloudflare → Emby（预估值）：27 毫秒
  ├─ Emby → OneDrive 读文件头（走挂载）：0.45 秒
  ├─ Emby → OneDrive 取直链：1.40 秒
  └─ 你 → OneDrive 拉流缓冲 · 这段服务器测不到

▶ 打开直链

⏱ 已运行 38 分钟 · 🔗 运行日志
```

### 3.6 测速三套（`.github/scripts/proxy-speedtest/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| ✅/⚠️ CDN 测速完成 | `speedtest.py` | 主报告（0 可用节点降级 ⚠️） |
| ✅/⚠️ Gitee 测速完成 | `speedtest_gitee.py` | 主报告（中止/0 可用降级） |
| ✅/⚠️ 泰尔三网测速 | `taier_speedtest.py` | 主报告（0 成功/未走代理降级） |
| ❌ …异常退出 / ⛔ …异常终止 | 三套各自 | 异常与信号终止 |

**示例：测速主报告（构造示例）**

```
✅ CDN 测速完成
━━━━━━━━━━━━━━━━━━
🕒 起止：2026-09-10 12:00:00 ~ 2026-09-10 12:20:31 · 耗时 20 分钟
📊 节点：共 12 个 · 可用 9 个

📍 测速点网络 · 2
[1] <code>mirror.example.com</code>
  ├─ 测速服务器：<code>93.184.216.34</code>
  ├─ ISP：<code>Contoso</code>
  ├─ ASN：<code>AS64512</code>
  └─ 位置：<code>Hong Kong, HK</code>

🏆 最快节点 · 5 · 按上传 · ↑上传 · ↓下载 · 延迟ms
  ├─ <code>香港 01</code> · ↑42兆 ↓58兆 35ms
  └─ <code>日本 02</code> · ↑30兆 ↓61兆 52ms

📦 订阅 · Gist
  ├─ ✅ 已更新，达标 9 个节点 · ≥10兆（按上传）
  └─ 🔗 订阅源 YAML

⏱ 已运行 20 分钟 · 🔗 运行日志
```

### 3.7 其它

- `subs-check.yml`：当前**无通知**（如需补，按 3.3 节的备份类形态即可）。
- `upload-video-to-tg.yml`：通知在 `tg-channel/*.sh` 外部脚本，job 级注入了
  `TG_RUN_*`，本身无内联通知。

---

## 4. 版式构件速查

每个构件给出：形态 → 为什么 → 示例 → 助手。

### 4.1 标题

```
{emoji} 标题
━━━━━━━━━━━━━━━━━━
```
- 助手：`tg_add_title`（bash/pwsh：`$TG_SEP` 手拼）
- 建议：emoji + 短语，状态与细节下沉到 kv 行；标题后紧跟分隔线、不空行。

### 4.2 分节

```
{emoji} 分节 · N
```
- 助手：`tg_add_section`（段前自动空行；紧跟分隔线时自动不空行）
- 建议：**分节后跟条目列表时带计数 ` · N`**（读者一眼知道规模）；后面是 kv 行
  或单段说明时可以不带。

### 4.3 kv 行

```
标签：值
```
- 助手：`tg_add_kv`（值自动转义）
- 建议：全角冒号；多个字段用 ` · ` 连（如 `文件数：源端 1415 / 目标 1412`）。
- 一行要塞多个字段时，建议用全角冒号标签打头作锚点（规格：/链路：/客户端：…），
  避免无锚点的裸 ` · ` 串。
- **时长写法（全库统一五层，按量级选，别再自创形态）**：

| # | 形态 | 适用 | 示例 |
|---|---|---|---|
| 1 | `X 小时 Y 分`（分钟**不补零**） | ≥ 1 小时 | `2 小时 8 分`、`1 小时 0 分` |
| 2 | `X 分钟` | ≥ 1 分钟 | `20 分钟`、`45 分钟` |
| 3 | `X.XX 秒`（**两位小数**） | ≥ 1 秒 | `12.34 秒`、`59.00 秒` |
| 4 | `X 毫秒`（整数） | < 1 秒 | `27 毫秒`、`340 毫秒` |
| 5 | `⏱mm:ss`（定宽补零） | 进度面板批次行 | `⏱01:15` |

  - 第 1–4 层是**时长表述**，由三套真源的收尾区实现（`tg_add_footer` /
    `Get-TgFooter` / `tg_footer_line`）与各处耗时复用，三者逐字一致；
  - 第 3 层的两位小数是**固定精度**（整数秒写作 `12.00 秒`）：精度一致才好纵向比较；
  - 第 4 层是子秒的专用形态——不足 1 秒若硬走第 3 层会退化成 `0.00 秒`，所以单列一层；
  - 第 5 层是**面板列字段**（为了计数列竖向对齐），与第 1–4 层不是一套体系，见 5.2 节；
  - 修饰语前置、值里不重复标签语义：`约 15 分钟`（不是「预计…约 15 分钟后执行」）、
    `3 小时内`、`3 小时前`、`直链剩余 40 分钟`。
  - **已知例外**：测速节点指标串（`↑42兆 ↓58兆 35ms`）里的延迟用紧凑 `NNms`——
    属指标字段而非独立时长表述（要和 `↑`/`↓` 等宽并排），不走第 4 层的「毫秒」写法。

### 4.4 机器值

```
路径：<code>/mnt/media/a.mp4</code>
```
- 助手：`tg_add_path`
- 建议：路径/文件名/命令/密码/IP/ID/端口/原始异常串一律等宽——读者能一眼看出
  「这段可以直接复制」。

### 4.5 条目

```
  ├─ <code>video_a.mp4</code> · 1.7 GB · 2160p
  └─ <code>video_b.mp4</code> · 重试修复失败
```
- 助手：`tg_entry`（单行）/ `tg_add_entry`（累积多行）；
  双机器值用 `tg_entry_pair`（`→` 替换关系）或 `tg_entry_codes`（`·` 并列）；
  与 `tree_lines` 组合成树形条目流。
- 建议：条目一律 `├─/└─` 树形（`• ` 平铺不是全库形态，勿引入）；
  元数据用 ` · ` 分隔、放在主体之后。
- 注意：`$(tg_entry …)` 会吃掉尾换行，**累积多行请用 `tg_add_entry`**。

### 4.6 折叠行

```
  └─ 还有 8 条…
```
- 助手：两个，按**输入是裸文本还是已构建条目流**选（选错会造成二次转义）：

  | 助手 | 输入 | 做什么 |
  |---|---|---|
  | `tree_code_fold` | 裸文本（未转义、无标签） | 逐行转义 + 套 `<code>` + 超 max 折叠 |
  | `tree_fold` | 已由 `tg_add_entry` / `tg_entry` 构建的条目流（已转义、已含 `<code>`） | **只**截断 + 加折叠行 |

  对已含 `<code>` 的条目流误用 `tree_code_fold`，会把 `&` 转成 `&amp;amp;`、
  并把 `<code>` 本身转义掉——条目流一律走 `tree_fold`。
- 建议：折叠行并入条目流作末条（由 `tree_lines` 统一决定 `└─`），
  不要单独补一行造成双 `└─`；多组并列时通知内建议最多展示 8 组。
- **折叠与否看清单性质，不只看条数**：

  | 清单性质 | 超 8 条怎么办 | 例 |
  |---|---|---|
  | 流水/日志类（读者只需知道规模，单条价值低） | 折叠为「还有 N 条…」 | 已上传文件、删除的重复文件、排除规则、日志行 |
  | 结构性清单（读者要逐条核对，少一条就漏了结论） | **全量展示，不折叠** | `task_preview` 的同步对、`task_engine` 的子目录/批次统计清单 |

  判据是「折叠掉后半段会不会让读者误判」，不是「列表长不长」。结构性清单若确实很长，
  靠分节计数 ` · N` 交代规模（4.2 节）即可——把「失败了哪些」折叠成「还有 N 条…」
  等于把读者最需要看的部分藏起来。
  （2026-09-12 核对：openlist 域 `file_split` / `sync_marker` / `sync_to_tg` 已上传组
  与 `file_restore` 曾两种口径，已统一收敛到 `tree_fold`；`task_preview` 与
  `task_engine` 属结构性清单，保持不折叠——不是漏改。）

### 4.7 多行块（日志/命令）

```
<pre>gh workflow run openlist.yml -f run_mode=同步</pre>
```
- 助手：`tg_add_pre`（转义 + `<pre>` 包裹）；`tg_add_block` 只用于已含标签的片段
- 建议：日志、异常栈、复制即用命令用 `<pre>`（保留换行、整块复制）；
  不要用它替代行内 `<code>`。

### 4.8 说明段

```
如确认无误，请手动触发 force_sync=true
```
- 助手：`tg_add_note`（段前自动空行）
- 建议：说明、备注、免责声明用独立说明段，与数据区分开。
  注意该助手对整段转义，**段内不能携带 HTML 标签**。

### 4.9 收尾区（硬要求）

```
⏱ 已运行 22 分钟 · 🔗 <a href="…">运行日志</a>
```

**硬要求**：所有通知都要有收尾区（进度面板的每次刷新除外，它在 finalize 时补）。
必须用 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`，不要手拼——
助手已处理空行、降级与链接。

- 时长三段式（三套真源逐字一致）：`≥1h → X 小时 Y 分`（分钟不补零）、`≥1min → X 分钟`、
  否则 `X.XX 秒`（两位小数，见 4.3 节的时长五层）；
  语义是 **run 已运行时长**，不是步骤自身耗时。
- 降级链：`TG_RUN_STARTED_AT` → runner 开机时刻（Linux `/proc/1`、
  Windows `LastBootUpTime`）→ 不显示时长；`TG_RUN_URL` 缺失则整行跳过。
- 附加链接：`tg_add_footer <var> "标签" "URL"` 可追加多个 `· 🔗 <a>`。

**接线（硬要求）**：workflow 必须在 job 或 step 级 env 注入，否则通知没有日志入口：

```yaml
env:
  TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
  TG_RUN_STARTED_AT: ${{ github.run_started_at }}
```

> 注：`github.run_started_at` 已被平台从表达式上下文移除，注入后为空值，
> 时长靠 runner 开机时刻兜底（误差秒级）。注入行保留，属性恢复后可立即生效。

### 4.10 空行的来源

只有这几处会产生空行，其余地方不要手写 `\n\n`：

1. `tg_add_section` 段前
2. `tg_add_note` 段前
3. `tg_add_footer` 前
4. **正文与动作行之间**（如「▶ 打开直链」超链接），由调用方补空行——
   先判断正文是否已有尾换行，避免产出双空行（`emby.yml` 播放通知的同款 case 判断）。
5. **多组列表的组与组之间**（任务预览/进度面板的 `📁 源端` 分组、去重通知的重复组）。
   这是唯一允许「手写」的空行，但**必须带条件**：只在前面已有组时才补
   （`[ "$_gi" -gt 0 ] && _out+=$'\n'`）。首组之前也补一次，分节标题与首组之间就会
   多出一个空行——`task_preview.sh` / `sync_progress.sh` 是正确范例，
   `tg-channel/dedupe_*.sh` 曾漏掉这个条件（2026-09-12 修正）。

分隔线与紧随其后的内容之间不空行。

---

## 5. 各类通知的写法建议

### 5.1 结果通知

建议顺序：标题（状态 emoji）→ 关键 kv（对象/状态/计数）→ 明细分节 → 收尾。
状态与结论下沉到 kv，不要塞进标题；标题只说「谁 + 怎么了」。

### 5.2 进度面板

- 标题：刷新态 `🔄 同步进度`；终态三选一——`⛔ 同步中断` / `⚠️ 同步完成` / `✅ 同步全部完成`
  （没有「失败」独立终态，失败并入 `⚠️ 同步完成` 并在副标题写失败数）。
- 面板的阶段行与批次历史行**整行用 `<code>` 包裹**：这样计数列在各行之间竖向对齐，
  代价是行宽变长（手机上可能折成两行）。这是面板特有的取舍——其它通知不要这样用，
  行内机器值仍按 4.4 节的局部等宽。
- 批次行字段：`✅00 🔧00 ❗33 ⏭️22 ♻️22 ⏱01:15 ⬆️4.79G`（五计数补零），
  最近 6 条滚动。`⏱mm:ss` 为定宽 mm:ss 补零；跑超过 1 小时时 mm 会延伸到 3 位
  （如 `⏱75:20`）——真实值优先于定宽。

### 5.3 列表明细

- 先按状态或原因分组（组头 + 计数），再树形列出条目。
- 流水类清单每组上限 8 条，超出折叠为「还有 N 条…」；结构性清单不受此限
  （性质判据见 4.6 节）。
- 组内还有附属明细时降为二层列表（`│ ` 前缀 + 缩进 2 格的 `├─/└─`）。

### 5.4 凭据与入口通知

按套分节（SSH / RDP / 出口网络），每套内的取值行**整节同为 `标签：<code>值</code>`**
（2.3 节的取值行口径）：出口网络四行的 IP / ISP / ASN / 位置都是同一次查询的机器返回值，
一律等宽；有效期、共用说明是自然语言，走说明段且保持裸文本。

### 5.5 失败与异常

- 中文阶段或原因写清楚；原始异常串用 `<code>`；多行日志用 `<pre>`。
- 英文 token 与错误码建议中文化（`退出码 45` 而不是 `exit=45`）。
- 建议给出下一步动作（复制即用命令或「见运行日志」）。

### 5.6 复制即用命令块

给人**可复制执行的命令**，而不是数据文件路径（marker/JSON 是人读不懂的落盘载体）：

```
🛠️ 复制即用

▸ 强制同步（全量，含本任务）
<pre>gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true</pre>
```

参数值要按实际匹配逻辑核实（如 `restore_task` 按 marker 文件名首个 `_` 前缀匹配，
填完整任务名反而匹配不到）。

### 5.7 常见偏差与改进建议

| 偏差 | 为什么会这样 | 建议改成 | 示例（渲染后） |
|---|---|---|---|
| 手拼 HTML（`msg+="<code>…"`） | pwsh 无助手；bash/python 已全部走助手 | 用 8.1 节的助手：`tg_add_*` / `tg_entry` 家族 / `tg_add_pre`（pwsh 按第 4 章的形态手拼、值经 `Esc-Html`） | `tg_entry "video.mp4" "1.7 GB"` → `<code>video.mp4</code> · 1.7 GB`（再交 `tree_lines` 出 `  ├─ ` 前缀） |
| 分节后跟列表却没计数 | 忘了拼 | 带 ` · N`，规模一眼可见 | `❌ 失败清单 · 3` |
| 条目用 `• ` 平铺 | 沿用了平铺写法 | 改 `├─/└─` 树形 | `  ├─ <code>video_a.mp4</code><br>  └─ <code>video_b.mp4</code>` |
| 长列表全量穷举（流水类） | 怕漏信息 | 分组 + 每组 8 条 + 折叠行；结构性清单不折叠（4.6 节） | `  ├─ <code>video_08.mp4</code><br>  └─ 还有 35 条…` |
| 英文紧凑时长（`5h 57m`） | 脚本内部格式直接输出 | 中文三段式（4.3 节的时长五层） | `⏱ 已运行 5 小时 57 分` |
| 高精度浮点（`2.16068914 秒`） | 原始值直出 | 两位小数（4.3 节的时长五层） | `起播 2.16 秒` |
| ISO 时间戳直出（`2026-09-05T11:34:19Z`） | 原始值直出 | 人性化：UTC + 相对时间（解析失败保留原值） | `上次同步：2026-09-05 11:34 UTC · 15 小时前` |
| 半角冒号 kv（`状态: 成功`） | 手误 | 全角冒号 | `状态：成功` |
| 手拼收尾行 | 不知道有助手 | 一律 `tg_add_footer`（pwsh `Get-TgFooter`） | `⏱ 已运行 22 分钟 · 🔗 运行日志` |
| 已 source 发送层仍 curl 直发 | 想要 message_id 等 | 除进度面板（需 message_id）外一律走发送层 | `send_tg "$msg"` |

---

## 6. 发送层要求

> 这一章是**硬约束**。

- **一律 HTML parse_mode**，动态内容**必须**转义（`escape_html` / `Esc-Html` /
  `html.escape`，或经 `tg_*` 助手自动转义）。
- **HTML 解析失败（400 can't parse entities）不重发**，直接报错暴露并带上响应体
  前 200 字符：消息本来就没发出去，退化成纯文本只会把 bug 藏起来。
- **429 限流按 `retry_after` 等待重试（最多 5 次）**；长消息按 4000 字符分片
  （断在换行处，不切 UTF-8 多字节）。
- 发送失败**必须**在 stderr/日志输出原因（含响应体前 200 字符），由调用方决定
  `|| true` 还是失败；**不要 `>/dev/null 2>&1` 吞掉**。
  python 侧 `send_telegram` 返回字典（成功 `{'sent': True, 'response': …}`、
  失败 `{'sent': False, 'reason': 响应体}`），调用方**必须**把失败原因记进日志。
  **最易漏的是异常/信号兜底分支**：那里习惯写 `try: send_telegram(...) except: pass`，
  等于同时吞掉异常和返回值，限流/400 时完全没有痕迹。三套测速已统一收敛到
  `notify_best_effort(stage, msg)`（内部取返回值 + 记 `log_progress`），新增兜底分支照抄。
- **已 source 发送层的通知点不得 curl 直发**。唯一例外是需要 message_id 的进度面板
  原地维护（`openlist/telegram.sh` 的 `_tg_send_and_get_id` / `_tg_delete_message`）——
  `sendMessage` 发送层不返回 message_id，原地刷新只能直发。
- 媒体上传（`sendDocument`/`sendVideo`）不走 sendMessage 发送层（固有例外），
  但 caption **必须**转义、429 重试与发送层同口径（最多 5 次）。
- pwsh 侧 dot-source `tg_notify.ps1` 后建议加 `Get-Command Send-TgMessage` 自检：
  调用未定义函数是**终止错误**，若 step 带 `continue-on-error` 会表现为通知静默消失。

---

## 7. 测试与交付基线

> 这一章是**硬约束**。

### 7.1 openlist 回归套件（19 个）

- 必须重定向 stdin：`bash test_x.sh </dev/null`（否则
  `test_batch_precheck_circuit_breaker.sh` 会卡在读 stdin）。
- 跑全量约 4 分钟，建议后台 `nohup … &` 再轮询日志。
- **套件 PASS 不等于通过**：跑完必须 `grep "command not found"` 全库测试日志，
  **必须为空**。

### 7.2 本地基线（不是回归，勿修）

| 套件 | 现象 | 原因 |
|---|---|---|
| `test_truth.sh` | `PASS=12 FAIL=7` | 依赖 docker/真实 OpenList 服务，本地跑不了 |
| `test_progress_no_orphans.sh` | T5「强杀路径有超时上限」偶发失败 | 时序 flake |
| `test_marker_skip_guards.sh` | 1b 失败 | 测试用 `date -d`，macOS BSD date 无 `-d` |

判定基线：**17 个 EXIT=0 + test_truth 那 7 条**，偏离才是回归。

> `test_sync_trend_budget.sh` 原在本表内（`wc` 输出对齐 + `unbound variable`）。
> 2026-09-11 复跑 17/17 全绿，已从基线表移除——上面的判定基线同步由 16 改为 17。

### 7.3 渲染预览（强烈建议）

改动版式后，用真源助手构造数据渲染一遍再交付：

```bash
source .github/scripts/telegram/tg_notify.sh
msg=""; tg_add_title msg "⚠️ 示例"; tg_add_section msg "❌ 清单 · 2"
tg_add_block msg "$(tree_lines "$(tg_entry "a.mp4" "1.7 GB")")"
tg_add_footer msg; printf '%s\n' "$msg"
```

实践中这一步抓到过三类纯代码审查漏掉的问题：转义被二次处理、空行数量不对、
命令替换吃掉尾换行导致条目粘连。

### 7.4 全库版式核对基线（2026-09-12）

对全库约 30 类通知做逐套核对（四个子系统并行审计 → 逐条复核 → 渲染预览验证）。
本节是下次核对的起点——**改动版式后，下表应当仍然成立**。
（2026-09-12 第二轮复验：1–12 项全部仍成立，新增 13–15 项。）
（2026-09-12 第三轮复验：1–15 项全部仍成立，新增 16 项；本轮把 openclaw 归档告警
从整块 `<pre>` 收敛为全库 kv 形态，见 3.4 节示例。）

核对方法：① Grep 机械扫描（`<b>`/`<i>`、`• `、半角冒号、`curl` 直发、时长格式）。
② 分域通读（openlist / tg-channel / workflows 内联 / 测速三套）。③ 渲染预览（7.3 节）。

三条让核对真正有效的经验：

- **逐条复核，别直接采信审计结论**。子代理按域通读会给出方向性错误（把有意为之的
  写法判成偏差），结论必须回到代码看一眼再决定是否成立。
- **核对「折叠」要 grep 全库每个 `tree_lines` 调用点**，不能只查上次改过的那几处。
  第一轮只查了 `file_split` / `sync_marker` / `sync_to_tg` / `file_restore`，
  同属 openlist 域的 `task_engine`（4 处）与 `task_preview` 就漏网了。
- macOS 的 BSD `grep` **不支持 `\S`**（GNU 扩展），用了会静默零匹配 → 假阴性。
  用 `[^ ]*` / `[^/]*` 代替，或改用 Grep 工具。

#### 已统一 · 16 项

| # | 版式要素 | 核对范围 | 结论 |
|---|---|---|---|
| 1 | 分隔线 `TG_SEP` | bash 真源 / pwsh / python 共享层 / tg-channel 内嵌段 | 四套同值，均为 18 条全角横线 ━；openlist 侧不自带副本 |
| 2 | `<b>` / `<i>` | 全库 | 零使用（仅注释提及） |
| 3 | 条目前缀 | 全库 | 一律 `├─/└─`，无 `• ` 平铺 |
| 4 | kv 冒号 | 全库 | 全角冒号，无半角混入 |
| 5 | 收尾区 | 所有通知点 | 一律 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`，无手拼 |
| 6 | 运行日志接线 | 14 个有通知的 workflow | 全部注入 `TG_RUN_URL`；「有通知的集合」与「注入集合」完全重合 |
| 7 | 时长写法 | 全库 | 五层（4.3 节）；无 `5h 57m`、无高精度浮点、无 ISO 时间戳直出 |
| 8 | 发送通道 | 全库 | `curl` 直发仅 4 处允许位置（两个发送层自身 / 进度面板 message_id / `sendDocument`）；pwsh 发送层走 `Invoke-RestMethod`，媒体走 Telethon `send_file`，均非 `curl` |
| 9 | 发送层引入 | 每个通知点 | 均 source / dot-source，无 `command not found` 风险 |
| 10 | 转义 | 全库动态内容（含 dedupe 组头 ID/哈希、内嵌段 `esc`、**媒体 caption**） | 一律经 `escape_html` / `Esc-Html` / `html.escape` / `tg_*` 助手；**无「字符集受限」豁免**——第 6 章是硬约束 |
| 11 | 内嵌 python 助手 | `tg-channel/sync_to_tg.sh` | `esc` / `tg_entry` / `tg_pre_block` / `fmt_secs` / `shorten_name` 齐全，无 NameError 风险；`esc` 与 python 共享层同为 `quote=True` |
| 12 | 多组列表组间空行 | `tg-channel/dedupe_*.sh`、`sync_to_tg.sh` 跳过明细 | 空行带条件（首组前不补），曾漏、已修 |
| 13 | 折叠口径 | 全库列表 | 按清单性质判定（4.6 节）：流水/日志类超 8 条折叠；结构性清单（`task_preview` 同步对、`task_engine` 子目录/批次统计）**全量展示——不是漏改** |
| 14 | python 发送层返回值 | `speedtest_common.py` | `send_telegram` 成功/失败均返回字典，失败一律带 `reason`；`send_telegram_chunked` 顶层亦有 `reason`（汇总失败分片），调用方不会记空原因 |
| 15 | 媒体发送 | `tg_send_video.py` / `sync_notify.sh` 的 `sendDocument` | caption 转义 + 显式 `parse_mode='html'`（不指定则 Telethon 走 markdown 默认解析）；429 重试与发送层同口径（5 次） |
| 16 | 归档告警版式 | `openclaw.yml` 两处（`send_telegram_alert` / `send_archive_alert`，29 个调用点） | 对象 `<code>` + 结论/原因裸文本 kv + `Run ID`，原始输出单独 `<pre>` 分节（尾部 1200 字节）；两函数标题区分「归档告警 / 最终归档告警」；调用点为 4 参（对象/结论/原因/原始输出） |


## 8. 附录

### 8.1 助手速查

| 用途 | bash 真源 | pwsh | python |
|---|---|---|---|
| 标题 / 分节 | `tg_add_title` / `tg_add_section` | `$TG_SEP` 手拼 | 手拼 + `TG_SEP` |
| kv / 机器值 | `tg_add_kv` / `tg_add_path` | 手拼 | 手拼 |
| 条目（单主体） | `tg_entry` / `tg_add_entry` | — | `tg_entry(subject, *meta)` |
| 条目（文字主体） | `tg_entry_text` / `tg_add_entry_text` | — | `tg_entry(..., code=False)` |
| 条目（双机器值 →） | `tg_entry_pair` / `tg_add_entry_pair` | — | `tg_entry_pair(a, b, *meta)` |
| 条目（双机器值 ·） | `tg_entry_codes` / `tg_add_entry_codes` | — | `tg_entry_codes(a, b, *meta)` |
| 多行块 | `tg_add_pre` | — | `tg_pre_block(text)` |
| 说明段 | `tg_add_note` | 手拼 | 手拼 |
| 测速点网络分节 | — | — | `build_target_network_section` / `network_cells` |
| 树形 / 折叠 | `tree_conn` `tree_sub` `tree_lines` `tree_code_fold`（裸文本）/ `tree_fold`（已构建条目流） | 手拼 | 手拼 |
| 转义 | `escape_html` | `Esc-Html` | `html.escape` |
| 收尾 | `tg_add_footer` | `Get-TgFooter` | `tg_footer_line` / `tg_format_elapsed` |
| 发送 | `send_tg` / `send_tg_chunked` | `Send-TgMessage` | `send_telegram` / `send_telegram_chunked` |

真源文件：`.github/scripts/telegram/tg_notify.sh`、`tg_notify.ps1`、
`.github/scripts/proxy-speedtest/speedtest_common.py`。

> **pwsh 侧现状**：`tg_notify.ps1` 只有五个成员——`Esc-Html` / `Format-TgDuration` /
> `Get-TgFooter` / `Send-TgMessage` / `$TG_SEP`，**没有 kv 与条目助手**。
> 全库只有 `rdp.yml` 与 `tailscale-windows.yml` **两个** workflow dot-source 它
> （`openclaw.yml` 与 `pixivutil2.yml` 走的是 bash 真源 `tg_notify.sh`，pixivutil2 还跑在
> ubuntu-latest，都不碰 pwsh），这两处的 kv 行与树形条目是手拼的——按第 4 章的形态拼
> 即可（`标签：值`、`  ├─ 键：<code>值</code>`），注意值一律经 `Esc-Html`。
> 哪天想让它们也收敛，就在 pwsh 侧补一组 `Add-TgEntry` 之类的助手，再从两处迁移。

> 内嵌 python 段（如 `tg-channel/sync_to_tg.sh`）无法 import 共享层，
> 在本文件内同义实现 `esc` / `tg_entry` / `tg_pre_block`，三处定义保持一致。
>
> **新增助手时别忘了同步补进内嵌段**。2026-09-12 前的教训：内嵌段只实现了
> `esc` / `tg_pre_block`，代码里却调用了 `tg_entry` → 每次单文件失败都 NameError
> → python 非零退出 → 脚本提前 `exit` → **连整轮汇总通知一起丢**。这类问题
> 代码审查很容易漏（函数名看着就像内置的），改完内嵌 python 务必跑一次
> [7.3 节渲染预览](#73-渲染预览强烈建议)或等价的实跑验证。

### 8.2 状态图标语义

`✅` 成功 · `⚠️` 部分失败/警告 · `❌` 失败 · `⏭️` 跳过 · `🔄` 进行中 ·
`⏳` 待处理 · `⛔` 中断 · `🚨` 危险警告 · `🆘` 灾难恢复 · `📍` 进度面板当前阶段

建议：状态图标与结论一致——0 成功/中止/疑似未走代理时，标题应降级为 ⚠️/❌，
不要恒 `✅`。

### 8.3 批次历史行字段（进度面板）

`状态#批次号`（`✅/⚠️/❌`）· `✅00` 成功 · `🔧00` 修复 · `❗33` 失败 ·
`⏭️22` 跳过 · `♻️22` 已有 —— 五计数 `%02d` 补零 · `⏱01:15` 耗时（mm:ss 补零；
超 1 小时 mm 延伸到 3 位如 `75:20`）· `⬆️4.79G` 上传量（GiB 两位小数）。
最近 6 条滚动，全量在运行日志。

### 8.4 术语

- **面板**：需要 message_id 的原地刷新消息（openlist 进度面板）。
- **构造示例**：文档中为说明版式而用助手渲染的示例（非线上实录）。
- **硬约束**：不遵守会造成通知丢失或误判失败的规则（第 6、7 章，4.9 节）。
