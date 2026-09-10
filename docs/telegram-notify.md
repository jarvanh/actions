# Telegram 通知规范（全库唯一真源）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）都在这里找答案。

## 1. 这份文档怎么用

这份文档是**风格指南**，不是军规：绝大多数条目是「建议 + 为什么 + 反例/正例」，
目的是让你在没有先例可循时也能写出和别人风格一致的通知。

只有三处是**硬约束**（不遵守会造成通知丢失或误判失败），改动前请务必读：

| 硬约束 | 位置 | 为什么是硬的 |
|---|---|---|
| 发送层行为（429 重试 / 400 不重发 / 必须转义 / 不得 curl 直发） | [§6 发送层要求](#6-发送层要求) | 不遵守 = 通知静默消失或限流丢消息 |
| 收尾区与接线（`TG_RUN_URL` / `TG_RUN_STARTED_AT`） | [§4.9 收尾区](#49-收尾区硬要求) | 不遵守 = 通知没有运行日志入口 |
| 回归测试基线（19 套件、`command not found` 归零） | [§7 测试与交付基线](#7-测试与交付基线) | 不遵守 = 无法判断改动有没有破坏既有通知 |

**改动流程建议**：改版式先改这份文档，再同步实现；实现改完跑一遍渲染预览
（[§7.3 渲染预览](#73-渲染预览强烈建议)）和相关测试。

> 版本沿革（理解现状用）：早期通知用「粗体 + 斜体 + 平铺 `• `」多种形态，
> 各子系统自己拼 HTML，版式漂移严重。2026-09 起逐步收敛为**只有两档**：
> 信息文字裸文本、机器值等宽。演变：去 `<i>` → 值去粗 → emoji 去粗 → 全去 →
> 补条目/块助手。当前形态见下。

---

## 2. 设计原则

### 2.1 一条通知要回答三个问题

> **发生了什么 / 影响多大 / 我要做什么**

写通知前先过一遍这三问，比纠结用哪个 emoji 更有价值：

- 发生了什么 → 标题（emoji + 短语）+ 状态 kv
- 影响多大 → 计数与量化（失败 3 个 / 减少 100 GiB / 跳过 12 条）
- 我要做什么 → 复制即用命令块、下一步说明、运行日志链接

### 2.2 视觉层级靠四件套，不靠粗体

| 手段 | 承担的作用 |
|---|---|
| 分隔线（`━━━` 18 条） | 标题锚点 |
| 空行 | 段落/分节边界（只有三处产生，见 §4） |
| emoji | 语义与状态的彩色锚点（比粗体更醒目） |
| 等宽 `<code>` | 「这个可以复制」的机器值 |

因此**全库不用 `<b>` 与 `<i>`**：加粗/斜体能提供的区分，上面四件套已经给足；
而「哪个位置该加粗」的边界判断（条目主体 vs kv 值）曾是反复返工的根源。
不用的另一个理由：`<i>` 对中文几乎看不出效果，却会让 HTML 变复杂。

### 2.3 只有三处需要标签

| 标签 | 用在哪 |
|---|---|
| `<code>` | 机器值：路径、文件名、命令、密码、IP、ID、端口、原始异常串 |
| `<pre>` | 多行块：日志、复制即用命令、异常栈（保留换行、整块复制） |
| `<a>` | 链接（收尾区运行日志、订阅源等） |

其余一律裸文本——但要**转义**（动态内容里的 `& < >` 会触发 400，见 §6）。

### 2.4 统一优先于个性

同一类信息在不同子系统里形态一致，读者才能跨通知扫读。
因此所有版式都尽量走真源助手（§8.1），而不是各脚本自己拼字符串。

---

## 3. 通知种类索引

全库约 30 类通知，按子系统分组。表格给出「在哪 / 何时发」，其后给出
**代表性渲染示例**（示例取自实现代码结构，个别为构造示例，已标注）。

### 3.1 OpenList 同步域（`.github/scripts/openlist/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 📋 任务预览 · 任务名 | `task_preview.sh` | 预览阶段，每个任务一条 |
| 📍 进行中 / ⛔ 同步中断 / ⚠️ 同步完成 / ✅ 同步全部完成 | `sync_progress.sh` | 进度面板原地刷新与四种终态 |
| ✅ 同步完成 / ⚠️ 部分文件同步失败 / ⚠️ 同步失败 | `sync_notify.sh` | 同步结束，按结果分三态 |
| ⏭️ 同步任务跳过 | `sync_marker.sh` | 落在 `--Nd-skip` 窗口内 |
| 🚨 源端大小异常减小 | `sync_marker.sh` | 源端比上次记录缩水超阈值 |
| 🔧 修复文件一键还原完成 | `file_restore.sh` | 还原 marker 修复条目到原路径 |
| 🆘 灾难恢复完成 / 🆘 镜像灾难恢复完成 | `file_restore.sh:530 / :644` | 目标端回填源端 |
| 📈 同步趋势 | `sync_trend.sh` | 一轮结束输出净传速率/ETA |
| ✅ 视频分割成功 / ❌ 视频分割失败 | `file_split.sh:33 / :39` | 单文件 ffmpeg 切割 |
| ✅ 7z 分卷成功 / ❌ 7z 分卷失败 | `file_split.sh:94 / :102` | 非视频大文件分卷 |
| 📊 前置大文件处理总结 | `file_split.sh` | 前置大文件批处理结束 |

**示例：任务预览**

```
📋 任务预览 · backup
━━━━━━━━━━━━━━━━━━
📊 同步对 · 1
  └─ 📁 onedrive:backup
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
源端：<code>onedrive:0/media</code>

📊 大小对比
上次记录：1.2 TB · 3200 文件
当前大小：1.1 TB · 3180 文件
减少：100 GiB · 8%

📁 缺失的目录 · 可能被删除 · 2
  ├─ <code>media/电影</code>
  └─ <code>media/纪录片</code>

🛠️ 复制即用

▸ 强制同步（全量，含本任务）
<pre>gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true</pre>

⏭️ 本次跳过同步，继续执行其他任务

⏱ 已运行 3 分钟 · 🔗 运行日志
```

**示例：进度面板（简化，仅骨架）**

```
📍 进行中
━━━━━━━━━━━━━━━━━━
状态：进行中
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
成功：2 个
失败：1 个

✅ 已还原 · 2
  ├─ <code>media/视频A.mp4</code>
  └─ <code>media/视频B.mkv</code>

❌ 失败清单 · 1
  └─ <code>media/视频C.mp4</code> · 目标端写入被拒

⏱ 已运行 5 分钟 · 🔗 运行日志
```

### 3.2 Telegram 频道视频管线（`.github/scripts/tg-channel/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 📺 同步汇总（CAPTION_PREFIX） | `sync_to_tg.sh` | 一轮频道同步结束 |
| ❌ 获取远端文件列表失败 / ❌ 下载失败 / ⏭️ 损坏视频已标记跳过 / ❌ 处理上传失败 | `sync_to_tg.sh:308 / 445 / 524 / 534` | 单文件级失败即时通知 |
| 🔍 重复视频检测与去重（按 ID / 按哈希） | `dedupe_ph_videos.sh`、`dedupe_videos_by_hash.sh` | 发现重复组 |
| 🧹 ph-dl 清理 yt-dlp 残留文件 | `cleanup_ytdlp_residual.sh` | 清理 `-Frag/.ytdl/.m3u8` |
| 🧹 频道清理完成 | `reset_tg_channel.sh` | 清空频道 + 删 uploaded/failed json |

**示例：频道同步汇总（构造示例，结构取自实现）**

```
📺 91-tg
━━━━━━━━━━━━━━━━━━
视频文件：120 条
库存状态：已上传 118 · 待上传 2
本次处理：2 条
本次成功：2 条
损坏已跳过：1 条

✅ 已上传 · 2
  ├─ <code>video_a.mp4</code> · 上传耗时 12.3 秒
  └─ <code>video_b.mp4</code> · 上传耗时 20.1 秒

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
| ✅/⚠️/❌/⛔ GitHub 全仓库备份（四态） | `github_backup_all.yml` | 备份结束，`if: always()` |
| ✅/⚠️/❌/⛔ Self-Hosted 数据备份（四态） | `self-hosted_backup.yml` | 同上 |
| ☁️/❌/⛔ iCloud 照片下载（三态） | `icloud-photos-downloader.yml`（独立 `if: always()` step） | icloudpd 跑完，按 `job.status` 分态 |
| ✅/⚠️/❌ PixivUtil2 任务完成 | `pixivutil2.yml` | 按 `PU_STATUS` 三态 |
| 🗑️ ph-dl 下载阶段损坏视频 / ✅ ph-dl 下载任务完成 | `ph-dl.yml:208 / 261` | 下载完整性 / 收尾 |

**示例：备份结果（结构取自实现）**

```
✅ GitHub 全仓库备份成功
━━━━━━━━━━━━━━━━━━
仓库数：42
备份大小：3.4 GiB
耗时：18 分钟

⏱ 已运行 18 分钟 · 🔗 运行日志
```

### 3.4 入口与凭据类

| 通知 | 位置 | 触发场景 |
|---|---|---|
| 🟢 OpenClaw Runner 已就绪 | `openclaw.yml` | Tailscale SSH 就绪，推 SSH/RDP/网络/网关 |
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
  ├─ ISP：Contoso
  ├─ ASN：<code>AS64512 · Contoso</code>
  └─ 位置：Tokyo, JP

有效期：约 6 小时 · 超时自动结束

ℹ️ 域名固定不变 · IP 每次运行会变，仅作备用 · 密码 SSH/RDP 共用

⏱ 已运行 2 分钟 · 🔗 运行日志
```

> 凭据通知**没有特殊发送通道**：照样用 `tg_add_*` 构建（密码走 `tg_add_path`
> 自动等宽 + 转义）再 `send_tg`。不要为凭据自造「单发不重试」的实现——
> 429/400 都意味着上一条没被 Telegram 收到，放弃重试只会让凭据彻底丢失。

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
规格：电影 · 2 小时 08 分 · 1080p · h264 · 5.5 GB
链路：⚡ 302直连 OneDrive · 直链剩余 40 分钟
客户端：203.0.113.57 · Safari · macOS

⏳ 起播等待 · 3
  ├─ <code>你 → Cloudflare</code> · 27 毫秒
  ├─ <code>Emby → OneDrive 取直链</code> · 1.4 秒
  └─ <code>你 → OneDrive 拉流缓冲</code> · 这段服务器测不到

▶ 打开直链

⏱ 已运行 38 分钟 · 🔗 运行日志
```

### 3.6 测速三件套（`.github/scripts/proxy-speedtest/`）

| 通知 | 位置 | 触发场景 |
|---|---|---|
| ✅/⚠️ CDN 测速完成 | `speedtest.py` | 主报告（0 可用节点降级 ⚠️） |
| ✅/⚠️ Gitee 测速完成 | `speedtest_gitee.py` | 主报告（中止/0 可用降级） |
| ✅/⚠️ 泰尔三网测速 | `taier_speedtest.py` | 主报告（0 成功/未走代理降级） |
| ❌ …异常退出 / ⛔ …异常终止 | 三件套各自 | 异常与信号终止 |

**示例：测速主报告（构造示例）**

```
✅ CDN 测速完成
━━━━━━━━━━━━━━━━━━
🕒 起止：2026-09-10 12:00:00 ~ 2026-09-10 12:20:31 · 耗时 20 分钟
📊 节点：共 12 个 · 可用 9 个

📍 测速点网络 · 2
[1] <code>mirror.example.com</code>
  ├─ 测速服务器：<code>93.184.216.34</code>
  ├─ ISP：Contoso
  ├─ ASN：<code>AS64512</code>
  └─ 位置：Hong Kong, HK

🏆 最快节点 · 5 · 按上传 · ↑上传 · ↓下载 · 延迟ms
  ├─ <code>香港 01</code> · ↑42兆 ↓58兆 35ms
  └─ <code>日本 02</code> · ↑30兆 ↓61兆 52ms

📦 订阅 · Gist
  ├─ ✅ 已更新，达标 9 个节点 · ≥10兆（按上传）
  └─ 🔗 订阅源 YAML

⏱ 已运行 20 分钟 · 🔗 运行日志
```

### 3.7 其它

- `subs-check.yml`：当前**无通知**（如需补，按 §3.3 备份类形态即可）。
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
- **时长写法（全库统一，别再自创形态）**：
  - 单位形态：`X 小时 Y 分`（分钟**不补零**，如 `2 小时 8 分`）／`X 分钟`／`X 秒`；
  - **秒一律一位小数**（`12.0 秒`、`12.3 秒`）；**不足 1 秒用整数毫秒**（`27 毫秒`）——
    子秒用一位小数秒会退化成 `0.0 秒`，属于精度分层而非另一种写法；
  - 修饰语前置、值里不重复标签语义：`约 15 分钟`（不是「预计…约 15 分钟后执行」）、
    `3 小时内`、`3 小时前`、`直链剩余 40 分钟`；
  - 进度面板批次行的 `⏱mm:ss` 是为计数列对齐的**定宽形态**（见 §5.2），与上面不是一套体系。

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
- 建议：条目一律 `├─/└─` 树形（`• ` 平铺已废弃，勿再引入）；
  元数据用 ` · ` 分隔、放在主体之后。
- 注意：`$(tg_entry …)` 会吃掉尾换行，**累积多行请用 `tg_add_entry`**。

### 4.6 折叠行

```
  └─ 还有 8 条…
```
- 助手：`tree_code_fold`（文件列表一站式：等宽 + 超 8 条折叠）
- 建议：折叠行并入条目流作末条（由 `tree_lines` 统一决定 `└─`），
  不要单独补一行造成双 `└─`；多组并列时通知内建议最多展示 8 组。

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
  否则 `X.X 秒`（一位小数，见 §4.3 时长写法）；
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

### 4.10 空行的三个来源

只有这三处会产生空行，其余地方不要手写 `\n\n`：

1. `tg_add_section` 段前
2. `tg_add_note` 段前
3. `tg_add_footer` 前

分隔线与紧随其后的内容之间不空行。

---

## 5. 各类通知的写法建议

### 5.1 结果通知

建议顺序：标题（状态 emoji）→ 关键 kv（对象/状态/计数）→ 明细分节 → 收尾。
状态与结论下沉到 kv，不要塞进标题；标题只说「谁 + 怎么了」。

### 5.2 进度面板

- 标题随终态变化（进行中 📍 / 中断 ⛔ / 完成 ⚠️·✅ / 失败 ❌）。
- 面板的阶段行与批次历史行**整行用 `<code>` 包裹**：这样计数列在各行之间竖向对齐，
  代价是行宽变长（手机上可能折成两行）。这是面板特有的取舍——其它通知不要这样用，
  行内机器值仍按 §4.4 局部等宽。
- 批次行字段：`✅00 🔧00 ❗33 ⏭️22 ♻️22 ⏱01:15 ⬆️4.79G`（五计数补零），
  最近 6 条滚动。`⏱mm:ss` 为定宽 mm:ss 补零；跑超过 1 小时时 mm 会延伸到 3 位
  （如 `⏱75:20`）——真实值优先于定宽。

### 5.3 列表明细

- 先按状态或原因分组（组头 + 计数），再树形列出条目。
- 每组建议上限 8 条，超出折叠为「还有 N 条…」。
- 组内还有附属明细时降为二层列表（`│ ` 前缀 + 缩进 2 格的 `├─/└─`）。

### 5.4 凭据与入口通知

按套分节（SSH / RDP / 出口网络），每套内的取值行用 `标签：<code>值</code>`，
可复制性优先；有效期、共用说明放说明段。

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

| 偏差 | 为什么会这样 | 建议改成 |
|---|---|---|
| 手拼 HTML（`msg+="<code>…"`） | 早期助手不全；pwsh 侧至今无助手 | bash/python 侧已全部走 §8.1 助手（`tg_add_*` / `tg_entry` 家族 / `tg_add_pre`）；pwsh 侧按 §4 形态手拼、值经 `Esc-Html`；进度面板整行等宽块是刻意取舍（§5.2） |
| 分节后跟列表却没计数 | 忘了拼 | 带 ` · N`，规模一眼可见 |
| 条目用 `• ` 平铺 | 旧形态 | 改 `├─/└─` 树形 |
| 长列表全量穷举 | 怕漏信息 | 分组 + 每组 8 条 + 折叠行 |
| 英文紧凑时长（`5h 57m`） | 脚本内部格式直接输出 | 中文三段式（§4.3 时长写法；紧凑格式只留在日志/artifacts） |
| 高精度浮点（`2.16068914 秒`） | 原始值直出 | 一位小数 |
| ISO 时间戳直出（`2026-09-05T11:34:19Z`） | 原始值直出 | `2026-09-05 11:34 UTC · 15 小时前` |
| 半角冒号 kv（`状态: 成功`） | 手误 | 全角冒号 |
| 手拼收尾行 | 不知道有助手 | `tg_add_footer` |
| 已 source 发送层仍 curl 直发 | 想要 message_id 等 | 除进度面板（需 message_id）外一律走发送层 |

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
  python 侧 `send_telegram` 只回传 `reason`，调用方**必须**把它记进日志。
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
| `test_sync_trend_budget.sh` | 「期望1条实得       1」+ `unbound variable` | macOS `wc` 输出对齐 + 远端脚本自身问题 |

判定基线：**16 个 EXIT=0 + test_truth 那 7 条**，偏离才是回归。

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

### 7.4 提交与生效

- 提交前 `git fetch` + `git pull --rebase`（远端常有他人新提交）。
- 提交信息含中文/特殊字符时用**单引号**包裹 `-m`（双引号会被 shell 拆成多个 pathspec）。
- 改动 workflow 后按约定重启可 dispatch 的：
  `emby`（需 `-f playback_mode=302`）、`tailscale-windows`、`proxy-speedtest-taier`；
  触发前先取消在跑的旧代码 run（取消非即时，ubuntu runner 约 2–4 分钟）。

---

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
| 树形 / 折叠 | `tree_conn` `tree_sub` `tree_lines` `tree_code_fold` | 手拼 | 手拼 |
| 转义 | `escape_html` | `Esc-Html` | `html.escape` |
| 收尾 | `tg_add_footer` | `Get-TgFooter` | `tg_footer_line` / `tg_format_elapsed` |
| 发送 | `send_tg` / `send_tg_chunked` | `Send-TgMessage` | `send_telegram` / `send_telegram_chunked` |

真源文件：`.github/scripts/telegram/tg_notify.sh`、`tg_notify.ps1`、
`.github/scripts/proxy-speedtest/speedtest_common.py`。

> **pwsh 侧现状**：`tg_notify.ps1` 只有 `Esc-Html` / `Get-TgFooter` / `Send-TgMessage` /
> `$TG_SEP` 四个成员，**没有 kv 与条目助手**，所以 `openclaw.yml` / `tailscale-windows.yml` /
> `rdp.yml` / `pixivutil2.yml` 里的 kv 行与树形条目是手拼的——按 §4 的形态拼即可
> （`标签：值`、`  ├─ 键：<code>值</code>`），注意值一律经 `Esc-Html`。
> 哪天想让它们也收敛，就在 pwsh 侧补一组 `Add-TgEntry` 之类的助手，再从四处迁移。

> 内嵌 python 段（如 `tg-channel/sync_to_tg.sh`）无法 import 共享层，
> 在本文件内同义实现 `esc` / `tg_pre_block`，三处定义保持一致。

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
- **硬约束**：不遵守会造成通知丢失或误判失败的规则（§6、§7、§4.9）。
