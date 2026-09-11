# emby —— Emby 媒体服务器 + 302 直链子系统

> 入口：`.github/workflows/emby.yml`
> 脚本：`.github/scripts/emby302/`（目录名沿用历史命名，不随本文档改名）
>
> 在 GitHub Actions runner 上临时拉起一套可用的 Emby（含数据恢复与备份），并把媒体播放
> 流量从"经服务器中转"改为"播放器直连 OneDrive 直链"（302 重定向）。

---

## 目录

- [1. 它做了什么](#1-它做了什么)
- [2. 配置清单](#2-配置清单)
- [3. 架构](#3-架构)
- [4. 302 直链原理](#4-302-直链原理)
- [5. 健康检查与自动回退](#5-健康检查与自动回退)
- [6. 凭据体系](#6-凭据体系)
- [7. 通知体系](#7-通知体系)
- [8. 数据与备份](#8-数据与备份)
- [9. 脚本参考](#9-脚本参考)
- [10. 运维排查手册](#10-运维排查手册)
- [11. 修改指南](#11-修改指南)

---

## 1. 它做了什么

一次 run 完成三件事：

1. **恢复并启动 Emby** —— 从云端备份拉回媒体库元数据（用户、海报、播放进度），校验通过后才允许启动
2. **建立 302 直链链路** —— 让播放器直接向 OneDrive 拉流，视频流不经过 runner
3. **运行约 5.7 小时后收尾** —— 优雅停机、打包回传备份、发送汇总通知

### 触发方式

| 触发 | 模式来源 |
|---|---|
| **自续触发（常态）** | 上一轮收尾用 `gh workflow run` 立刻起下一轮，中间不留空档；模式沿用默认值 |
| 定时（`cron: 0 2,8,14,20 * * *`，**兜底**） | 仓库变量 `vars.EMBY_PLAYBACK_MODE`，缺省 `302`。只在接力链条断裂（run 被杀/失败且接力 step 没跑到）时才真正起作用 |
| 手动 `workflow_dispatch` | 输入项 `playback_mode`（`302` / `direct`）；另有 `run_minutes`（本轮保留时长，调试可填 8）、`self_retrigger`（收尾是否起下一轮）、`clear_emby_cache`、`clear_warm_state`，见下 |
| `watch` | 同定时 |

**清理开关**（仅手动触发生效，在 restore 之后、Emby 启动之前执行）：

| 开关 | 清什么 | 效果 |
|---|---|---|
| `clear_emby_cache` | `/mnt/emby-cache` | 图片缓存从零开始：所有海报首次浏览重新冷读；本轮收尾备份同步变小，之后轮次也没有旧缓存可用 |
| `clear_warm_state` | `warm-state.json` | 预热档位从头统计：首屏/海报墙预热跳过，等 wallwarmer 重新记录客户端档位；**回看预热列表（recent）一并清空**，最近播放过的条目下轮不再定向预热 |

两者可同时勾选——相当于把"缓存 + 档位统计"全部归零，从冷启动重建画像。

> ⚠️ **cron 按 UTC 执行**：`2/8/14/20` UTC 对应北京时间 `10:00 / 16:00 / 22:00 / 次日 04:00`。
> `TZ: Asia/Shanghai` 只影响 runner 内 `date` 的输出（即通知里的时间戳），不改变 cron 时刻。

### 并发与时长

- `concurrency: emby-singleton` —— 同时只允许一个 run，后来的排队而不打断（自续触发正是靠它排成一条链）
- 保留时长由 `EMBY_RUN_MINUTES` 控制（默认 `270`）。⚠️ **GitHub job 硬上限 6 小时**（含 5 分钟宽限）：保留时长 + 启动恢复 + 收尾备份必须全部留在 6h 内
- run 结束即销毁 runner，所有状态靠云端备份延续

### 流式接力（为什么改成自续触发）

一轮跑完再等 cron 会有空档，而把 cron 调高频（`*/5`）又会撞上 GitHub 对高频定时的限流、
并造成队列积压（实测排队 3h41m 才开跑）。所以改成：**收尾最后一步立刻 dispatch 下一轮**，
cron 退回 6 小时一档只做兜底。三道护栏：

| 护栏 | 行为 |
|---|---|
| 开关 `self_retrigger` | 手动触发可关（调试时关掉，本轮结束后完全静止） |
| 人工取消不接力 | job conclusion 为 cancelled 且运行 < 5h50m（≈非 6h 上限导致）时不接力，避免跟你手动取消对着干 |
| 防堆积 | 已存在排队/等待中的 run 就跳过（cron 也会创建排队 run） |

---

## 2. 配置清单

### Secrets

| Secret | 用途 | 说明 |
|---|---|---|
| `RCLONE` | rclone 配置全文 | 写入 `~/.config/rclone/rclone.conf`，需含 `[onedrive]` 与 `[dropbox]` 段 |
| `OPENLIST_ADMIN_PASSWORD` | OpenList 管理员密码 | **密码的唯一真相源**，详见[凭据体系](#6-凭据体系) |
| `EMBY_API_TOKEN` | Emby API 密钥 | 用于探活、片名反查、海报预热、优雅停机、播放监听 |
| `EMBY_USER` | 期望存在的 Emby 用户名 | 校验"这份数据是我们的备份"与预热定位用户。**仓库公开，用户名不写死在代码里**；走 secret 还自带日志打码 |
| `TELEGRAM_BOT_TOKEN` | TG 机器人 | 所有通知 |
| `TG_CHAT_ID` | TG 会话 ID | 通知目标（私密 chat） |
| `VD` | 域名前缀 | OpenList 维护入口 `oe.<VD>.eu.org` |
| `GITHUB_TOKEN` | 内置 | 调 GitHub API 取最新 release，避免 runner 共享出口 IP 的匿名配额耗尽 |

### Variables

| Variable | 缺省 | 用途 |
|---|---|---|
| `EMBY_PLAYBACK_MODE` | `302` | 定时/watch 触发时的播放模式；取值 `302` / `direct`，大小写不敏感 |

### 环境变量（workflow `env:` 块）

| 变量 | 说明 |
|---|---|
| `PLAYBACK_MODE_INPUT` | 归一化后的模式入参（手动输入优先，其次仓库变量，最后 `302`） |
| `TZ` | 固定 `Asia/Shanghai`，统一所有日志与通知的时间戳 |
| `EMBY302_DIR` | 脚本目录，各步骤 `source $EMBY302_DIR/lib.sh` 复用公共函数 |
| `EMBY_RUN_MINUTES` | 本轮保留时长（默认 `270`），手动触发可用 `run_minutes` 覆盖（调试填 8） |
| `EMBY_BACKUP_EVERY_MIN` | 运行期增量备份间隔（默认 `25` 分钟） |
| `EMBY_BACKUP_DEST` | 增量备份远端目录（默认 `onedrive:backup/emby/live`），同时是恢复侧第 ① 级来源 |
| `EMBY_FULL_BACKUP` | 收尾全量打包：`auto`（按剩余预算决定，默认）/ `0`（永远关） |
| `EMBY_FULL_BACKUP_ETA` | 全量打包预计耗时（默认 `2400`s），收尾据此判断预算够不够 |
| `EMBY_JOB_BUDGET` | job 总预算（默认 `20400`s = 5h40m），超过就不再启动任何耗时操作 |
| `EMBY_PREFETCH` | 直链预热器开关（默认 `1`），见[起播慢怎么定位](#起播慢怎么定位) |
| `EMBY_PREFETCH_MAX_DIRS` | 目录回填上限（默认 `400` 个目录） |

---

## 3. 架构

### 3.1 两种播放模式

> ⚠️ **命名反直觉，不要按字面理解。**

| 模式 | 链路 | 视频流量 |
|---|---|---|
| `302` | cloudflared → **ge2o:8095** → Emby:8096 | **不经过 runner**，播放器直连 OneDrive |
| `direct` | cloudflared → Emby:8096 | 全部经 runner 中转到网盘 |

**`direct` 指的是"直连 Emby"，不是"直连网盘"** —— 它的流量反而全走服务器。

### 3.2 数据流

```
                       302 模式                                direct 模式
              ┌──────────────────────────┐              ┌──────────────────────┐
  播放器 ────▶│ cloudflared (隧道 e)     │               │ cloudflared (隧道 e) │
              │        ↓                 │               │        ↓             │
              │ ge2o :8095               │               │ Emby :8096           │
              │   ├─ /api/fs/get 取直链  │               │        ↓             │
              │   │      ↓               │               │  rclone mount        │
              │   │  odlink :5245 ───────┼──▶ Graph API  │   /onedrive          │
              │   │      ↘ (回退)        │               │                      │
              │   │   OpenList :5244     │               │                      │
              │   ↓ 302/307 重定向       │               │                      │
              │ OneDrive 直链 ◀── 播放器直连拉流          │                      │
              └──────────────────────────┘              └──────────────────────┘
```

### 3.3 端口与路径

| 组件 | 端口 | 数据/日志 |
|---|---|---|
| Emby | 8096 | `/var/lib/emby`（cache 软链到 `/mnt/emby-cache`） |
| ge2o | 8095 | `/opt/ge2o/config.yml`、`/opt/logs/ge2o.log` |
| OpenList | 5244 | `/opt/openlist`（回传 `dropbox:self-hosted/openlist-emby/`） |
| odlink | 5245 | `/opt/logs/odlink.log` |
| rclone mount | — | 挂载点 `/onedrive`，VFS 缓存 `/mnt/vfs/onedrive`（**上限动态分配**），日志 `/opt/logs/rclone-mount.log` |

**运行时落盘位置**：`/tmp/link-host`、`/tmp/link-token`（直链源契约，见下）、
`/tmp/openlist-token`（机器自动登录所得的 OpenList 会话 token）、`/tmp/odlink-token`（odlink 访问令牌）、
`/tmp/PLAYBACK_MODE`（当前模式）、`/tmp/EMBY_READY_FOR_BACKUP`（收尾打包闸门）、
`/opt/odlink-last.json`（最近一次直链，供通知用）、`/var/lib/emby/warm-state.json`（海报档位 + 回看预热，随备份跨 run 传递）。

### 3.4 路径映射约束（关键坑）

rclone 挂载根 = OpenList 存储根 = 网盘根，因此 Emby 路径 `/onedrive/3/...` 与
OpenList 的 `/onedrive/3/...` **原样一致**。ge2o 靠 `emby2openlist: /onedrive:/onedrive`
映射原样替换。

> ⚠️ **绝不能给 ge2o 配 `mount-path`**：它会先剥掉 `/onedrive` 前缀，导致映射永不命中——
> 首选路径变成 `/3/...`（storage not found），兜底重试又丢掉二级目录，最终只能回源中转。

启动探活与运行中 watchdog 都会用"媒体库目录同路径 `fs/get`"做映射探针，换算断了会告警并回退 `direct`。

---

## 4. 302 直链原理

### 4.1 问题：网盘根目录下全是快捷方式

OneDrive 根目录下的 `0`~`5`、`backup` 等条目，**全都是快捷方式（`remoteItem`）**，
各自指向独立的远程盘。OpenList 官方 OneDrive 驱动**不跟随 remoteItem**，按路径寻址
必然 `object not found` → 302 直链永不生效 → 播放静默回源中转。

rclone 之所以能通，是因为它逐段解析、遇到 `remoteItem` 就切换到
`/drives/{driveId}/items/{itemId}` 继续下钻。

### 4.2 解法：odlink

`odlink.py` 对外**伪装成 OpenList 的 `/api/fs/*`**，对内用 Microsoft Graph 跟随快捷方式，
把 `@microsoft.graph.downloadUrl`（官方预授权直链，约 1 小时有效）作为 `raw_url` 返回，
ge2o 据此发出 302。

路径解析是三级策略（按成本从低到高，`resolve()`）：

1. **整路径缓存命中** → 零 Graph 调用（此前解析过，或列目录时回填过 `dir_cache`）；
2. **路径寻址一次解析**：首段快捷方式切盘后，剩余子路径用
   `/drives/{driveId}/items/{itemId}:/{sub/path}:` 一次请求拿到底——冷解析从 N 段
   串行 Graph 往返压到 1 次，这是 302 起播慢的服务端主要优化点；
3. **逐段下钻兜底**（复刻 rclone：逐段解析、遇 `remoteItem` 切换 drive 继续），
   路径寻址失败或终点本身是快捷方式时走这条。

直链源契约由 `start odlink` 步骤写入，ge2o 配置、启动探活、运行中 watchdog
**全部从这两个文件读**，保证三者打到同一个源：

| 文件 | 内容 |
|---|---|
| `/tmp/link-host` | `http://127.0.0.1:5245`（odlink 就绪）或 `...:5244`（回退 OpenList） |
| `/tmp/link-token` | 对应的 token |

### 4.3 分流与零回归

```
请求 path=/onedrive/3/电影/x.mkv
  ├─ 剥掉 /onedrive 前缀 → ["3","电影","x.mkv"]
  ├─ odlink 未就绪？            → 转发 OpenList
  ├─ 首段不是快捷方式？          → 转发 OpenList
  ├─ Graph 解析失败？           → 转发 OpenList
  └─ 否则 → 缓存命中 / 路径寻址一次解析（失败兜底逐段下钻）→ 返回直链
```

非快捷方式路径与解析失败**一律原样转发本机 OpenList**，所以 odlink 不可用时
行为与没有它时完全一致（零回归）。

### 4.4 顶层名单固定，子路径动态（重要语义）

这是最容易被误解的一点：

| 范围 | 时机 | 说明 |
|---|---|---|
| **顶层**快捷方式名单 | 启动时一次性快照 | `bootstrap()` 列一次根目录，成功后即固定。**本轮内新建/改名/删除的快捷方式不会被感知**（走 fallback 转发 OpenList），需下次 run 才纳入 |
| 快捷方式**内部**的子路径 | 每次请求实时解析 | 任意深度都无需预先扫描；解析结果进 `dir_cache`（无 TTL），列目录还会把子条目批量回填进缓存 |
| 嵌套快捷方式（快捷方式里的快捷方式） | 实时跟随跨盘 | 路径寻址不跟随中段 `remoteItem`（会失败），自动兜底逐段下钻切换 drive |

> 顶层列举用 `$top=200`，根目录条目超过 200 会被截断。

---

## 5. 健康检查与自动回退

三层保护，任一层不通过就回退 `direct`：

| 层 | 时机 | 行为 |
|---|---|---|
| **启动探活** | run 启动后 | 依次检查：ge2o 存活 → 直链源 `fs/get` → 直链源 `fs/list`。重试 3 次（间隔 10s），全失败则 `MODE=direct` |
| **运行中 watchdog** | 每 60 秒 | 相同检查（含媒体库目录 `fs/get` 映射探针）；**连续 3 次失败**自动 kill cloudflared、改指 Emby:8096、写 `direct` 到 `/tmp/PLAYBACK_MODE`、发 `⚠️ Emby 直链已回退` 通知，然后退出 |
| **odlink 自身降级** | 请求级 | 解析失败即单请求回退 OpenList，不影响整体模式 |

探活**必须打 ge2o 实际在用的那个源**（`link_host` / `link_token`），否则会出现
"探活通过、但 ge2o 仍在绕 OpenList"的假健康。

---

## 6. 凭据体系

**三套凭据互不相干**——混淆它们是绝大部分"登录不上"类问题的根因。

| # | 凭据 | 归属 | 谁在用 | 来源 | 需要你做什么 |
|---|---|---|---|---|---|
| 1 | **Graph access_token** | 微软 OneDrive | odlink、od_probe | rclone.conf `[onedrive]` 段的 `refresh_token` 自动换取 | **不用管**，全自动 |
| 2 | **OpenList 会话 token** | OpenList | ge2o、探活、转发 | 机器用 `OPENLIST_ADMIN_PASSWORD` 调 `/api/auth/login` 自动获取，写入 `/tmp/openlist-token` | **不用管**，全自动 |
| 3 | **admin 密码** | OpenList 管理面 | 仅 **oe 后台人工登录** | `OPENLIST_ADMIN_PASSWORD` secret | 用 `admin` + 该 secret 登录 |

### 密码策略

`OPENLIST_ADMIN_PASSWORD` secret 是**唯一长期真相源**：

```
机器尝试用 secret 登录
  ├─ 成功 → 库内密码本就对齐 → 绝不动密码，也【不发通知】
  └─ 失败 → 库内密码漂移（Dropbox 历史恢复 / oe 人工改动）
           → 无条件重置为 secret 值，并经 TG 私信告知
```

由此保证：**你随时用 `admin` + secret 登录 oe 必成**。只有真正执行过改密动作
（secret 为空随机生成、或库内漂移纠正）才会收到 `🔐 OpenList 凭据` 通知。

> 密码明文**只进 TG 私信**，绝不写公开日志。JSON 请求体用 `jq` 构造，
> 避免密码含 `"` 或 `\` 时手拼 JSON 破损。

### 关于第 1 套凭据的探测日志

`probe onedrive shortcuts` 步骤会输出类似：

```
凭据提取: client_id 长度=0 client_secret 长度=0 refresh_token 长度=457
直接换取 token 失败，改用 rclone 自身刷新后取回
✅ 已获取 access_token（长度=1464，内容不打印）
```

**这不是故障**。rclone 内置应用注册下 `client_id`/`client_secret` 通常为空，
所以"自己拿 refresh_token 去换"必然失败，脚本会自动降级为"让 rclone 自己刷新
再从 conf 读回"——三级降级中的第二级，是正常工作路径。

---

## 7. 通知体系

全部经 Telegram 私信推送，时区统一为**北京时间**（`TZ=Asia/Shanghai`）。

| 通知 | 时机 | 内容 | 落日志 |
|---|---|---|---|
| `📺 Emby 服务启动` | 模式决策后立刻 | 模式、直链源、网盘快捷方式（解析数）、取链自检（通过/未通过）、时间，外加一条"网盘快捷方式"的说明行 | ✅ 正文回显（无敏感信息） |
| `🎬 媒体播放` | 检测到播放 | 多行卡片：首行 **片名+年份**（剧集为剧名 + SxxExx），分隔线后三行标签锚点行 **规格 / 链路 / 客户端**，302 时另起一段附 **直链**（3 分钟内的最近一次，以 HTML `<a>` 折叠为 `▶ 打开直链`） | ❌ 仅记片名 |
| `⚠️ Emby 直链已回退` | watchdog 触发 | 事件（连续 3 次链路自检失败）、动作（已自动切到中转模式） | — |
| `📺 Emby 服务停止` | run 收尾 | 状态、模式、**本轮直链**（成功取到 / 未取到 / 解析失败 / 改走备用 / 跨网盘，共 N 次）、**海报预热**（请求数 + 宽度档）、**播放客户端**（authentication.db 里本轮有活动的 AppName 去重，只列应用名不带设备名/用户名）、时间 | ✅ 正文回显 |
| `🔐 OpenList 凭据` | **仅改密时**（secret 为空随机生成 / 库内密码漂移纠正） | 场景、用户名、密码明文（`<code>` 等宽）、入口，外加一条"长期有效密码 = secret"的说明行 | ❌ 绝不落日志 |

全部通知采用**全库统一 HTML 版式**，规范唯一真源见
[`docs/telegram-notify.md`](telegram-notify.md)（实现层：bash `telegram/tg_notify.sh`
+ pwsh `telegram/tg_notify.ps1`；openlist 侧仅薄适配面板函数）：`emoji 标题 + ━━━ 分隔线 +
键值区 + 统一收尾行`（`⏱ 已运行 X · 🔗 运行日志`，时长 = run 已运行时长，
收尾区与正文间固定一个空行）。凭据私信同样走发送层 `send_tg`
（密码经 `tg_add_path` 自动实体转义，绝不落日志；
HTML 解析失败不重发、429 限流保留重试——与全库其余通知同一套语义）。

### 安全边界

- **公开日志**（workflow run log）：只出现片名、计数、HTTP 码、域名，**绝不出现用户名**（`EMBY_USER` 走 secret，且失败信息只回显计数）
- **TG 私信**：可含直链与密码
- 所有归档日志都过脱敏：直链 → `<url>`，密钥 → `[redacted]`，媒体路径 → `<path>`
- ge2o 的 `headers to encode cacheKey` 调试行整行丢弃（内含完整请求头与 `cf_clearance` Cookie）

### 播放事件的两个数据源

| 源 | 适用 | 判定 |
|---|---|---|
| ge2o 访问日志（主源） | 302 模式 | `302/307` → 直链；`200/206` → 中转；`304` 不计 |
| Emby Sessions 轮询（兜底） | direct 模式 / 日志格式变化 | `Transcode` → 中转；否则按当前模式判定 |

两源共享去重状态：同一 item **300 秒内只推一次**。

### 播放通知的卡片结构（统一版式 + 收尾区）

```
🎬 五十度飞 (2018)                                   ← 第 1 行：片名 + 年份
━━━━━━━━━━━━━━━━━━                                  ← 第 2 行：统一分隔线
规格：电影 · 1 小时 58 分 · 2160p · hevc · 1.7 GB    ← 第 3 行：规格（标签锚点行）
链路：⚡ 302直连 OneDrive · 直链剩余 38 分钟           ← 第 4 行：链路
客户端：Infuse-Direct · iPhone · 203.0.113.42          ← 第 5 行：客户端
⏳ 起播等待 · 7                                      ← 第 6 行起：等待（访问链 KV 树，同测速套件）
  ├─ 你 → Cloudflare hkg01（香港） → Emby（预估值）：120 毫秒   ← 你 → 隧道 → 服务器
  ├─ Emby → OneDrive 读文件头（走挂载）：27 毫秒        ← Emby 打开视频前读文件头
  ├─ Emby → OneDrive 取直链：1.40 秒                   ← 服务器去要下载直链
  ├─ 你 → OneDrive 拉首字节（预估值）：200 毫秒         ← 直链拿到第一个字节
  ├─ Emby → OneDrive 抽字幕：2.80 秒                   ← 抽内封字幕（首次最慢）
  ├─ 拖动进度条（Emby → OneDrive 重取直链）：880 毫秒   ← 该条目最近一次 seek
  └─ 你 → OneDrive 拉流缓冲：这段服务器测不到           ← 剩下的都在播放器自己身上
                                                    ← 空行
▶ 打开直链                                           ← 超链接（仅 302）
                                                    ← 空行（收尾区铁律）
⏱ 已运行 1 小时 35 分 · 🔗 运行日志                    ← 统一收尾行
```

| 行 | 来源 | 说明 |
|---|---|---|
| 1 片名 | Emby `Items` | 剧集显示**剧名 + SxxExx**，集名下移到规格行；查不到显示`未知` |
| 2 分隔线 | `TG_SEP` | 与全库通知一致（18 全角横线） |
| 3 规格 | Emby `Items` 一次取全 + odlink | 集名（剧集）/ 类型 / 时长 / 分辨率 / 编码 / 体积；体积来自 `odlink-last.json`（仅 302 有）——**任一项取不到就整项省略**，不会出现 `null · · 0` |
| 4 链路 | 模式 + `odlink-last.json` | 302 = `⚡ 302直连 OneDrive` + 直链剩余有效期；中转 = `🔁 视频流经 runner 中转到网盘`。`2400s` = `odlink.py` 的 `LINK_TTL`，改缓存时长需同步 `playlog.sh` 的 `notify()` |
| 5 客户端 | Emby `Sessions` + ge2o 日志 | 客户端名 / 设备名来自 Sessions；IP 来自 ge2o 访问日志（数据源 A 才有，用于"谁在播"） |
| 6 起播等待 | ge2o 访问日志 + warmup 探针 | **访问链 KV 树版式**（与测速套件「📍 测速点网络」同款，`tree_lines` 渲染），每行 = 谁访问哪里 + 耗时，**按点播放后的先后顺序排**：`你 → Cloudflare hkg01（香港） → Emby`（预估值，含边缘机房）→ `Emby → OneDrive 读文件头（走挂载）`（`PlaybackInfo` 里的 `ffprobe`）→ `Emby → OneDrive 取直链`（ge2o + odlink）→ `你 → OneDrive 拉首字节`（预估值，直链 TTFB）→ `Emby → OneDrive 抽字幕`（首次最慢，常是隐藏大头）→ `拖动进度条（Emby → OneDrive 重取直链）`（该条目最近一次 seek）→ 末行固定提示**还有一段在你播放器侧、服务器测不到**，避免把上面几项加起来当成总耗时。耗时 <1 秒用整数毫秒、≥1 秒用两位小数秒（`fmt_ms`）；「你 → Cloudflare → Emby」与「你 → OneDrive 拉首字节」两行来自 warmup 启动探测、**不是本次播放实测**，故标`（预估值）`。措辞按"读通知的人不懂内部术语"写。**取不到的项整行省略**，全都没有则整段不出现 |
| 7 直链 | `odlink-last.json` | 3 分钟内才视为本次播放所用；HTML `<a>` 折叠，段前空一行 |
| 8 收尾区 | `tg_notify.sh` 的 `tg_add_footer` | 读 `TG_RUN_URL` / `TG_RUN_STARTED_AT`，缺席时优雅降级跳过 |

**HTML 解析失败（400 can't parse entities）不重发**：发送层 `send_tg` 直接输出错误并返回非 0；
只有 **429 限流保留重试**（最多 5 次，按 `retry_after` 等待）。解析失败说明版式有 bug，
退化成纯文本只会把 bug 藏起来；且两类失败都意味着上一条未被 Telegram 接收，不存在"发重复"风险。

> 实现坑（已踩过）：TSV 用 tab 分隔会让 `read` 吃掉中间空字段（tab 是 IFS 空白字符，连续分隔符被折叠），
> 导致电影没有 series/季集时后续字段整体前移。现改用 `\037`（单元分隔符）。

---

## 8. 数据与备份

### 恢复（四级降级，任一通过即止）

```
① 增量目录：onedrive:backup/emby/live —— 上一轮运行期持续同步、收尾又补过一次的
      最新关键数据（data / config / plugins / metadata），不含图片缓存。体量小、恢复快，
      是最新的，所以排在最前
② OneDrive 流式：rclone cat onedrive:backup/emby/emby-backup.tar.zst | tar -I zstd -xf -
      （30GB 级 tarball 不落本地盘，流式解压；含图片缓存，但可能已是几轮之前的进度）
② Dropbox 流式：rclone cat dropbox:self-hosted/emby-backup.tar.zst | tar -I zstd -xf -
      （同样不落本地盘——根分区 ≈14GB 容不下 30GB 级 tarball）
③ Dropbox 目录：dropbox:self-hosted/emby → 整目录拷贝（**唯一会落盘的兜底**，
  需先按远端体量预检 /tmp；恢复后必须重建 `cache` 软链，否则缓存会写进根分区）
```

**每级恢复后都必须过 `emby_guard.py` 校验闸**，不通过就拒绝启动——残库会被 Emby
当成空库重建，比本轮直接失败更糟。

### 校验项（`emby_guard.py`）

1. `data/users.db`、`data/library.db` 存在
2. 存在 `EMBY_USER` 指定的用户（未配置该 secret 时退化为"至少一个用户"）
3. 根结构正确：`Id=1` 为 `Media Folders`、`Id=2` 为 `root`
4. `Media Folders` 下存在媒体库目录
5. `root` 下存在 `/onedrive/` 开头的真实媒体路径

> 只输出计数，绝不打印用户名与媒体路径明细。

### 回传：运行期增量 + 收尾全量

**为什么改**：旧方案是收尾一次性打包 30GB 级 tarball 上传，而 `sleep 340m` + 启动恢复
已经吃掉 5h45m，必然越过 GitHub job 6h 硬上限——实测两轮都精确死在 6h05m，备份 step
每轮被 SIGTERM（exit 143），**关键数据一轮都没落过云端**，收尾通知也恒 skipped。

```
运行期（每 EMBY_BACKUP_EVERY_MIN=25 分钟，后台常驻 /opt/emby_incbak.sh）
   SQLite 用 VACUUM INTO 做一致性快照（Emby 运行中直接 cp 可能拿到撕裂页）
   → rclone copy 到 onedrive:backup/emby/live（排除 cache / logs / transcoding-temp）
收尾（Emby 优雅停机后，/opt/emby_incbak.sh once）
   ① 增量同步（必做）：此时 Emby 已停，这份快照最一致，只补最后一轮差量
   ② 全量打包（可选）：仅当剩余时间预算够（EMBY_JOB_BUDGET − 已运行 − ETA > 0）
      才 tar|zstd|rcat 上传含缓存的全量包；不够就跳过——缓存丢了只是重新冷读，
      绝不能为了它把关键数据一起拖过 6h 上限
```

用 `rclone copy` 而非 `sync`：远端不会被"本轮快照恰好缺失"误删。

- **OpenList**：`config.json` + `data.db` 同步到 `dropbox:self-hosted/openlist-emby/`，
  且**仅当 `fs/list` 实测通过**才回传，防止空数据覆盖远端
- 前置闸门：只有 `install emby` 校验通过才会 `touch /tmp/EMBY_READY_FOR_BACKUP`，
  收尾步骤见到该标记才允许回传
- 结果落 `/tmp/emby-backup-result`，收尾通知的「数据备份」行与接力 step 都会回显它

### 磁盘预检

大体积数据在落盘/解压前统一做空间预检（`require_free_kb`），避免解压到一半
失败留下残库。图片缓存软链到 `/mnt`（根分区约 14GB 放不下约 30GB 缓存，`/mnt` 独立分区约 65GB）。

**容量改成动态分配，不再写死经验值**：`/mnt` 上有两个消费者——emby 图片缓存
（`/mnt/emby-cache`）与 rclone VFS 缓存（`/mnt/vfs/onedrive`），两者大小都只有运行时
才知道（缓存多大要等解压后才有答案）。所以：

| 项 | 口径 |
|---|---|
| VFS 缓存上限 | `alloc_vfs_cache_kb` —— `/mnt` 剩余空间减去 `MNT_RESERVE_KB`（默认 6GB）预留，其余基本全给；下限 2GB |
| 让位机制 | `--vfs-cache-min-free-space` = 同一预留值，运行期真被 emby 缓存挤到时 VFS 主动逐出 |
| 解压预检 | 包体 + `MNT_RESERVE_KB`，按实时剩余空间判定 |
| 打包预检 | 流式打包不落 staging，根分区只需 1GB |

`MNT_RESERVE_KB` 可用 workflow `env:` 覆盖，无需改脚本。

---

## 9. 脚本参考

```
.github/scripts/emby302/
├── odlink.py        直链服务（常驻，:5245）
├── od_probe.sh      快捷方式只读探测（一次性）
├── emby_guard.py    Emby 数据完整性校验（恢复后/备份前）
└── lib.sh           公共 shell 函数库（被各步骤 source）
```

### 9.0 运行时生成的常驻脚本

由各步骤 heredoc 写到 runner 上、不在仓库里。前两个是 2026-09-12 新增：

| 脚本 | 作用 | 日志 |
|---|---|---|
| `/opt/emby_incbak.sh` | 运行期增量备份（后台循环；`once` 参数 = 只跑一次，收尾用） | `/opt/logs/incbackup.log` |
| `/opt/odwarm.sh` | 直链预热器：`dir_cache` 批量回填 + 详情页预取 | `/opt/logs/odwarm.log` |
| `/opt/warmup.sh` | 五段预热 + 链路基线测量 | `/opt/logs/warmup.log` |
| `/opt/wallwarmer.sh` | 全库海报预热 | `/opt/logs/wallwarm.log` |
| `/opt/playlog.sh` | 播放监听与播放通知 | `/opt/logs/playlog.log` |
| `/opt/watchdog.sh` | 直链链路探活与自动回退 | `/opt/logs/watchdog.log` |

### 9.1 `odlink.py`

伪装成 OpenList 的直链服务。

**环境变量**

| 变量 | 默认 | 说明 |
|---|---|---|
| `ODLINK_PORT` | `5245` | 监听端口 |
| `ODLINK_UPSTREAM` | `http://127.0.0.1:5244` | 回退的 OpenList 地址 |
| `ODLINK_UPSTREAM_TOKEN` | `/tmp/openlist-token` | 转发上游时带的 token 文件（OpenList 会话 token） |
| `ODLINK_ROOT` | `/onedrive` | 需剥掉的挂载前缀 |
| `ODLINK_TOKEN` | 空 | 校验 `Authorization` 头；为空则不校验 |
| `ODLINK_LOG` | `/opt/logs/odlink.log` | 日志 |
| `ODLINK_LAST` | `/opt/odlink-last.json` | 最近一次直链落盘（供播放通知取用） |
| `ODLINK_RCLONE_CONF` | `~/.config/rclone/rclone.conf` | 取 Graph token 的配置 |

**接口**

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/ping` | 存活 |
| GET | `/healthz` | 就绪（ready + token 可取 → 200，否则 503） |
| GET | `/stats` | 运行统计（不含任何凭据与直链） |
| POST | `/api/fs/get` | 取直链 → `data.raw_url`；命中目录时返回 200 但 `raw_url` 为空（探活正是拿媒体库目录打这一接口，不能报错否则会误判链路不健康） |
| POST | `/api/fs/list` | 列目录 → `data.content` |
| POST | `/api/fs/other` | 转码预览未启用：HTTP 200，body 里 `code=500` |

> 根目录请求（`path=/onedrive`）在 `ready` 后由 odlink 本地应答（bootstrap 已拿到全部顶层条目），
> 不再绕上游——少一个级联故障点。未配置 `ODLINK_TOKEN` 时启动日志会告警"不校验 Authorization"。

**统计字段**（`/stats` 与收尾通知）

| 字段 | 含义 |
|---|---|
| `ready` / `shortcuts` | 是否已就绪 / 顶层快捷方式数量 |
| `fs.get` / `fs.list` | 请求次数 |
| `fs.link_ok` / `fs.link_miss` | 取到 / 未取到直链 |
| `fs.resolve_err` | Graph 解析失败 |
| `fs.fallback` | 回退 OpenList 次数（含"首段非快捷方式"与"解析失败"两类） |
| `fs.cross_drive` | 跨盘（跟随快捷方式）次数 |
| `fs.fast_path` | 路径寻址一次解析命中次数（第 2 级策略） |
| `dirs_cached` / `links_cached` | 路径缓存 / 直链缓存条数 |
| `graph.ok` / `graph.err` / `graph.refresh` | Graph 请求成功/失败/触发 token 刷新 |

**Token 取值三级降级**：① 直接拿 refresh_token 换（需 client_id/secret）
② 调 `rclone about` 触发刷新后从 conf 读回 ③ 从 rclone 请求头抓取。

### 9.2 `od_probe.sh`

**纯只读旁路诊断**，不改变任何链路行为，失败也不阻塞后续步骤。回答一个问题：
*302 直链方案是否可行*。

```
① Graph 能否跟随快捷方式（remoteItem → /drives/{driveId}/items/{id}）
② 跟随后的子目录能否列举
③ 目标文件能否返回 @microsoft.graph.downloadUrl
```

**结果解读**

- 出现 `✅ 取到预授权直链` → 方案可行，odlink 会据此提供直链
- 全是 `❌ 跟随后仍无法列子目录` → Graph 侧也跟随不了，odlink 会自动退回 OpenList

日志：`/opt/logs/odprobe.log`。输出一律脱敏（不打印 token、完整直链、完整路径）。

### 9.3 `emby_guard.py`

```bash
sudo EMBY_USER="$EMBY_USER" python3 emby_guard.py <emby-data-root>   # 例：/var/lib/emby
```

校验通过打印计数并以 0 退出；任一项不通过即以非零码退出并说明原因。
详见[校验项](#校验项emby_guardpy)。

> **用户名不写死在代码里**：期望用户由环境变量 `EMBY_USER` 传入（来自 workflow secret，
> 日志里自动打码）。`sudo` 默认不透传环境变量，所以必须由调用方显式带上——
> `lib.sh` 的 `validate_emby_data` 已处理好，直接用它即可。
> 若未配置该 secret，第 2 项退化为"至少一个用户"，仍然能拦住空库。

### 9.4 `lib.sh`

被 `install emby` / `backup emby data` / `run cloudflared` / `send telegram notification`
四个 workflow 步骤、以及 `warmup.sh`（`warmup images` 步骤生成的脚本）source。
只定义函数、不设 shell 选项，避免污染调用方的 `set -euo pipefail`。

| 函数 | 用途 |
|---|---|
| `free_kb` / `require_free_kb` | 磁盘空间预检 |
| `mnt_total_kb` / `mnt_free_kb` / `dir_used_kb` | `/mnt` 与目录容量读数 |
| `mnt_headroom_kb` / `alloc_vfs_cache_kb` | VFS 缓存上限动态分配（余量 = 空闲 − `MNT_RESERVE_KB`，下限 2GB） |
| `cleanup_archive_workdir` | 清理 30GB 级临时 tarball |
| `validate_emby_data` | 转调 `emby_guard.py`（`sudo` 下显式透传 `EMBY_USER`） |
| `redact_log` | 归档脱敏（丢弃 cacheKey 行 + 脱敏密钥/URL） |
| `redact_urls` | 只脱敏 URL（自有日志兜底） |
| `link_host` / `link_token` | 读直链源契约（带缺省回退） |

> 另有 `redact_pub`（探针诊断专用，连媒体路径一起脱）就地定义在 `run cloudflared` 步骤内，
> 因为它要脱的东西更多，不应与归档口径混用。

---

## 10. 运维排查手册

### 关键日志

| 日志 | 看什么 |
|---|---|
| `/opt/logs/odlink.log` | 直链解析：段数、是否跨盘、Graph 码、是否取到直链 |
| `/opt/logs/ge2o.log` | 播放走直链还是中转、路径换算是否命中 |
| 收尾归档的「ge2o 请求耗时统计」 | 按类型（起播准备 / 视频流 / 字幕 / 图片）汇总的均值与最大耗时——一次看清"点播放"的等待落哪类请求 |
| `/opt/logs/seek.log` | 拖动进度条 / 续播的重新取链耗时（同一条目的第 2 次起 stream 请求），收尾归档带均值与最大值 |
| `/opt/logs/playlog.log` | 播放事件监听、Emby 认证矩阵、TG 通道自检 |
| `/opt/logs/watchdog.log` | 探活失败计数与回退记录 |
| `/opt/logs/openlist.log` | OpenList 启动与存储状态 |
| `/opt/logs/odprobe.log` | 快捷方式探测结论 |
| `/opt/logs/rclone-mount.log` | 挂载层：VFS 缓存逐出、429/403 限流、seek 后重取（归档时按关键行筛选，非纯 tail） |
| `/opt/logs/emby-console.log` | Emby 侧：起播时的 ffprobe / ffmpeg 记录——**定位"点击播放要等很久"的关键现场** |
| `/opt/logs/warmup.log` | 预热耗时：直链冷解析均值 + 挂载冷读均值（判断起播慢在哪一层的量化依据） |
| `/opt/logs/wallwarm.log` | 全库海报预热：本轮覆盖页数与请求数、宽度档位、是否触发时长/磁盘/停机保护 |
| `/opt/logs/incbackup.log` | 运行期增量备份：每轮快照的文件数与体积、上传耗时、失败原因 |
| `/opt/logs/odwarm.log` | 直链预热器：目录回填进度（个/累计秒）、详情页预取命中 |
| `/opt/logs/cloudflared.log` | 隧道 e 的运行日志（回退后另写 `cloudflared-direct.log`） |

收尾步骤会把 `playlog.log`（80 行）、`ge2o.log`（60 行 + 按类型的耗时统计）、`odlink.log`（60 行）、
`rclone-mount.log`（关键行 40）、`emby-console.log`（60 行）、`warmup.log`（汇总行 + 尾部 40 行）、
`wallwarm.log`（15 行）脱敏后归档进 workflow 日志。

> `rclone-mount.log` 用 `grep` 筛关键行而非纯 `tail`：缓存清理类输出每 15s 一条，
> 5.7 小时上千行，纯 tail 只会被它们占满、看不到真正的异常。

### 症状 → 排查

| 症状 | 优先看 | 常见原因 |
|---|---|---|
| 播放一直显示"中转" | 启动通知里的`直链源` + `ge2o.log` | ① 直链源是 `OpenList:5244`（odlink 没起来）② 路径换算断了（探活 `map_ok=0`）③ 首段不在顶层快捷方式名单里 |
| 收尾通知`本轮直链`里"成功取到 0" | `odlink.log` | odlink 未就绪，或全部回退 OpenList |
| `oe.<VD>.eu.org` 登录不上 | 是否收到 `🔐 OpenList 凭据` 通知 | 没收到 = 密码没变，用 `admin` + `OPENLIST_ADMIN_PASSWORD`；收到 = 用通知里的密码（仅本轮有效） |
| Emby 启动成空库 | `install emby` 步骤 | 恢复三级全失败，或 `emby_guard.py` 校验不通过 |
| 备份没回传 | 收尾步骤 | `/tmp/EMBY_READY_FOR_BACKUP` 不存在（Emby 未成功启动），或磁盘预检未过 |
| 通知「数据备份」显示`全量跳过（预算不足）` | `incbackup.log` + 收尾步骤 | 保留时长设太长或启动恢复太慢，剩余预算不够全量打包。**关键数据已增量同步**，只是图片缓存本轮不回传；调小 `EMBY_RUN_MINUTES` 即可 |
| 恢复走了旧的全量包 | `install emby` 步骤 | 增量目录 `onedrive:backup/emby/live` 为空或校验失败（看该步骤是否打印`增量恢复校验不通过`） |
| 播放通知片名显示`未知` | 归档的 `playlog.log` | 反查全程 401 = secret 密钥在恢复库里失效（Tokens_2 中无此登录态或 IsActive=0）。`run emby` 步骤启动前会把 secret 密钥以专属设备登录态写回 `authentication.db` 并激活（幂等自愈）；若日志出现"密钥自愈失败"则需人工核对 Emby 版本 schema |
| 播放通知没来 | `playlog.log` 的 TG 通道自检 | ge2o 日志格式变化 / Emby 401 / 300s 去重窗口内 |
| 点击播放后要等很久才起播 | 播放通知的**「起播等待」段**（访问链：Cloudflare → Emby → OneDrive 各一行）→ `warmup.log` / `emby-console.log` | 按秒数定位段：**"抽字幕"大** = Emby 侧 ffprobe / 内封字幕提取（走挂载随机读，可让"起播准备预热"提前付掉）；**"取直链"大** = odlink 冷解析（未命中 `dir_cache`，扩 `WU_ITEMS`，目录预热 1b 会批量回填）；**各项都小却仍慢** = 卡在你播放器侧（联网 + 缓冲，服务器测不到），或链路行显示`🔁 视频流经 runner 中转到网盘`（转码）——见下方"起播慢怎么定位" |

### 起播慢怎么定位

`warmup images` 步骤做五段预热，**每段都带计时**，输出进 `warmup.log`。
段序刻意安排：**快且关键的在前**（直链几十秒、基线秒级），慢的（海报墙 / 头尾 / 起播准备）
靠后——中途取消 run 也保得住最重要的读数：

| 段 | 做什么 | 成本 | 对 **302 直连播放** | 预热后的效果 |
|---|---|---|---|---|
| 1 直链 | 提前打一次 odlink `/api/fs/get`，填充 `link_cache` 并测 TTFB | 零流量，几十秒完成 | ✅ **最有效**——ge2o→odlink 的直链解析本身就是 302 起播链路的一环 | 起播时不再逐段下钻 Graph。路径来源两路去重：**recent（最近播放，最可能回看）+ Latest 前 N 条** |
| 1b 目录 | 对预热路径所在目录打一次 `/api/fs/list`，odlink 会**批量**把该目录所有子条目写进 `dir_cache` | 每目录约 0.5s，十来个目录 | ✅ **覆盖率最高**：一次请求覆盖几十上百个文件；命中 `dir_cache` 后起播只需重新签发直链（1 次 Graph），不必逐段解析。冷解析实测 **1.75s/条**（段数 5、跨盘 1），这是压"取直链 1.40 秒"的主力 |
| 2 链路基线 | 见下方"第 2 段是测量" | 秒级 | — | — |
| 3 海报墙 | 请求最新条目海报，让 Emby 现场缩放 + ge2o 内存缓存就绪 | 低 | ✅ 有效（与模式无关，纯 Emby 侧） | 首页秒开 |
| 3b 各库首屏 | 每个媒体库按默认排序取前 20 张海报 | 约 1-2s/张×档位数，串行 | ✅ 滑进任意媒体库第一屏命中缓存 | 首屏秒开。宽度档位读跨 run 统计 Top5（`/var/lib/emby/warm-state.json`，随备份跨 run 传递）；**无统计时整体跳过**（不预热没人消费的尺寸） |
| 4 头尾 | 读每个条目的头部与尾部，落进 VFS 稀疏缓存 | 真实流量，受 `WU_BUDGET_MB` 约束 | ⚠️ **基本无效**（视频流不过挂载），只在转码 / 回退 `direct` 时才用得上 | ffprobe / ffmpeg 起播读命中本地 |
| 5 起播准备 | 对条目连打**两次** `POST /emby/Items/{id}/PlaybackInfo`（走 ge2o:8095） | 冷调用可能触发 ffprobe / 字幕提取（读挂载） | ✅ **直接消掉"点播放"第一步的冷成本**：ge2o 对该接口有 12h 缓存，冷调用已把 Emby 侧探测与直链改写跑完，用户点开即走热路径 | 冷/热两个均值直接给出「Emby 准备耗时」与「预热能省多少秒」 |
| 全库海报（`wallwarmer`） | 按 DateCreated 倒序遍历全部条目持续预热 | 后台持续 ~5h，并发 2 | ✅ 滑到已覆盖区域即秒开；逐轮往深处推进 | 深层页面首次浏览不再冷读 |

**第 2 段（链路基线）是测量、不是预热**（`warmup.log` 里单独输出，不产生缓存）：

| 读数 | 怎么测 | 回答什么问题 |
|---|---|---|
| 隧道边缘机房 | 从 `cloudflared.log` 抓 `location=XXX` | cloudflared 连到哪个 Cloudflare 机房。离你越远，客户端每次 API 往返越贵——而这段**完全不进服务器日志** |
| 隧道往返 TTFB | 经公网域名打一次 `/emby/System/Info/Public` 测首字节（域名默认由 `VD` secret 拼成 `e.<VD>.eu.org`，可用仓库 Variables `EMBY_PUBLIC_HOST` 覆盖） | ≈ 客户端到服务器的单程基线，解释"为什么起播 1.4 + 准备 5.3，实际却等了 10 秒" |

日志里这几个**均值**就是判断依据：

- **起播准备冷/热均值** —— Emby 组装 `PlaybackInfo` 的成本（含 ffprobe / 内封字幕提取 / ge2o 取链改写）。
  冷 - 热 = 预热能省下的秒数；**热均值 ≈ 真正起播时这一段还要等的时间**
- **直链均值** —— 起播时 ge2o 那一段的耗时（预热后趋近 0）
- **头尾均值** —— 冷读 `WU_EDGE_MB × 2` 的成本，换算成 MB/s 可反推 ffprobe 会花多久
- **直链 TTFB** —— 302 之后取第一个字节要多久（1 字节 Range 实测）。它慢说明 OneDrive 侧响应慢，
  与本仓库链路无关，且是"点播放到出画面"里服务端唯一能近似的客户端成本
- **隧道边缘机房 / 隧道往返 TTFB**（第 2 段）—— 网络侧的基线。服务器耗时加起来只有 6.7 秒、
  你却等了 10 秒时，差额基本就在这里：客户端 → Cloudflare 边缘 → runner 的往返，
  且 `PlaybackInfo` 这类接口往往要往返好几次。边缘机房会漂移（实测出现过 sjc01 / iad14），
  通知里带中文城市（`edge_cn` 映射表，IATA 机场码 → 中文，未收录回退原代码）

> ⚠️ **ge2o 日志的耗时列单位不固定**：同一列会出现 `152.244µs` / `90.36ms` / `1.4s` 三种单位，
> 只认 "数字s" 会漏掉全部毫秒级请求——`PlaybackInfo` 实测全是 ms 级（冷 22~27ms），
> 这是首版「Emby 读文件头」永远缺失的真因。仓库侧已用 `to_sec()` 归一化，自己 grep 时注意。
> 另外 ge2o 对同一请求打两行：带路由的那行是完整耗时，紧随其后的空路由行是 µs 级上游子请求，
> 取数要认带路由的（小写 `playbackinfo` / `subtitles`）。

> 想定位单次播放：直接看**播放通知的「起播等待」段**（访问链写法，一行 = 谁访问哪里 + 耗时）——
> 「Emby → OneDrive 取直链」是服务器去拿下载链接的时间（未命中 `dir_cache` 冷解析 1.75s，
> 命中后几十毫秒）；「Emby → OneDrive 读文件头」是 Emby 打开视频前读文件头的时间；
> 剩下的都在你播放器自己身上（联网 + 缓冲），服务器测不到。

> **头尾预热对 302 直连播放基本没用**：302 模式下播放器拿到重定向后直连 OneDrive CDN
> 拉 Range，全程不经过挂载，VFS 缓存根本不参与。它真正兜住的是四类"仍会读挂载"的场景：
>
> 1. 未探测条目的 Emby **ffprobe**（读的正是头尾：`moov` / MKV 的 `SeekHead`）
> 2. 客户端触发**转码**（ffmpeg 起播要读头部解析 `moov`；非 faststart 的 MP4 还得读尾部）
> 3. **字幕 / 章节图片**提取（随机读，头尾预热只覆盖头尾区间，命中率低）
> 4. watchdog 回退 **`direct`**（起播顺序读与探测全部走挂载）
>
> 另外它还兼着**唯一的挂载冷读速度探针**（即上面的"头尾均值"），这个价值与播放模式无关；
> 顺带的好处是提前暴露 OneDrive 限流——限流会在预热阶段就显现，而不是等到你点播放时。
>
> **若播放以 302 直连为主、很少转码**，建议把头尾预热压到最小、只当探针用：
> `WU_ITEMS=3` + `WU_EDGE_MB=32`（≈190MB/轮，约为默认的 15%）。
> 配置在 workflow `env:` 或仓库变量即可，不需要改脚本。
>
> 直链预热的价值主要在 `dir_cache`（无 TTL）：直链本身 40 分钟后会过期，
> 但路径解析结果本轮内一直命中，届时只需重新签发一次（1 次 Graph 调用，而非逐段下钻）。
>
> **回看预热（recent）**：playlog 在每次播放时把条目媒体路径记入 `warm-state.json` 的
> `recent` 列表（保留最近 12 条，随备份跨 run 持久化），下轮 warmup 优先预热这些路径——
> 你最近在看什么，下一轮点开就基本是热的。`clear_warm_state` 会连它一起清掉；
> wallwarmer 写回档位统计时会保留该字段，两条链路互不覆盖（写侧共用 flock）。
>
> 历史坑：`warmup.sh` 曾用 `UID` 存用户 ID，而 `UID` 是 bash **只读内建变量**，
> 赋值直接报 `readonly variable` 并失败 —— 查询拿到空结果、预热静默空转。
> 已改名为 `USER_ID`。

### 怎么确认 302 真的生效

1. 启动通知里`直链源`应为 `OneDrive 原生直链 · 可跟随网盘快捷方式`（回退时才显示 `OpenList · 备用取链通道`）
2. 播放通知的`链路`行应为 `⚡ 302直连 OneDrive`，而不是 `🔁 视频流经 runner 中转到网盘`
3. 收尾通知的`本轮直链`中"成功取到"应大于 0
4. `odlink.log` 里应有 `get 文件 ... 直链 host=... ` 记录

---

## 11. 修改指南

| 想改什么 | 改哪里 |
|---|---|
| 播放模式默认值 | workflow `env.PLAYBACK_MODE_INPUT` 的兜底值 / 仓库变量 `EMBY_PLAYBACK_MODE` |
| 保留时长 | workflow `env.EMBY_RUN_MINUTES`（默认 270；手测可用 `run_minutes` 覆盖）。⚠️ 总时长必须留在 6h 内 |
| 增量备份（间隔/远端） | `EMBY_BACKUP_EVERY_MIN` / `EMBY_BACKUP_DEST`；脚本 `start incremental backup` 步骤的 `/opt/emby_incbak.sh` |
| 全量打包是否做 | `EMBY_FULL_BACKUP`（auto/0）、`EMBY_FULL_BACKUP_ETA`、`EMBY_JOB_BUDGET`；判断逻辑在 `backup emby data` 步骤 |
| 直链预热器 | `EMBY_PREFETCH` / `EMBY_PREFETCH_MAX_DIRS`；脚本 `start link prefetcher` 步骤的 `/opt/odwarm.sh` |
| 自续触发（接力） | workflow 末尾「自续触发（下轮接力）」步骤：三道护栏见[流式接力](#流式接力为什么改成自续触发) |
| 探活判据与重试次数 | `run cloudflared` 步骤的探活循环、`/opt/watchdog.sh` heredoc |
| odlink 分流规则 | `odlink.py` 的 `do_POST` |
| odlink 路径解析策略（缓存 / 一次寻址 / 逐段兜底） | `odlink.py` 的 `resolve()` 与 `_resolve_drill()`；列目录回填缓存在 `list_children()` |
| 顶层快捷方式刷新策略 | `odlink.py` 的 `bootstrap_loop`（当前为一次性，成功后不再重跑） |
| 直链缓存时长 | `odlink.py` 的 `LINK_TTL`（40 分钟 = 2400s；改它必须同步 `playlog.sh` 里 `notify()` 写死的 2400，否则播放通知的"直链剩余"会算错） |
| 播放通知去重窗口 | `start playlog` 生成的 `/opt/playlog.sh` 的 `claim()`（同一 item 300 秒内只推一次，两数据源共享状态文件） |
| Emby API 密钥自愈 | `run emby` 步骤（把 secret 密钥以 `emby302-workflow` 专属设备登录态写回 `authentication.db` 的 `Tokens_2` 并激活，幂等） |
| rclone mount 参数（seek 优先口径） | `emby.yml` 的 `rclone-run` 步骤 |
| `/mnt` 容量预留 | workflow `env:` 的 `MNT_RESERVE_KB`（默认 6GB），分配逻辑在 `lib.sh` |
| 预热规模 | workflow `env:` 的 `WU_ITEMS`(30) / `WU_EDGE_MB`(32) / `WU_BUDGET_MB`(2048) / `WU_PI_ITEMS`(6)，脚本在 `emby.yml` 的 `warmup images` 步骤。`WU_ITEMS` 同时管直链（零流量）与头尾（真实流量）预热，30×32MB×2≈1.9GB 仍在预算内；`WU_PI_ITEMS` 是起播准备预热的条目数（每条连打两次 `PlaybackInfo`，冷调用可能触发 ffprobe/字幕提取，别设太大）。段序：1 直链 → 1b 目录 → 2 链路基线 → 3 海报墙/3b 首屏 → 4 头尾 → 5 起播准备（快且关键的在前，中途取消也保得住读数）。直链预热另含 **recent 回看预热**（playlog 写入 `warm-state.json`，保留最近 12 条，条数无需配置）。想量化起播慢看 `warmup.log` 的均值与收尾的「ge2o 请求耗时统计」 |
| 全库海报预热 | `start wall warmer` 步骤的 `/opt/wallwarmer.sh`：按 DateCreated 倒序分页遍历全部条目，把 Primary 海报拉进 Emby 缓存（`/mnt/emby-cache`）。**宽度档位跨 run 统计**——状态文件 `/var/lib/emby/warm-state.json` 存 `[宽度,得分]`（得分=按半衰期衰减的历史请求量，`WW_DECAY`=0.5），每轮启动先对历史得分衰减一次，再与本轮 ge2o 实测计数合并取 Top5（`WW_SIZES_MAX`=5）作为预热档位；持续被消费的档位留存，无人用的按半衰期退出（得分<1 淘汰）。每条目按这些档位各预热一份；请求只带 `maxWidth` 不带 `maxHeight`（缓存键含参数组合，box-fit 下带两者会得到更小的图、与客户端要的对不上）。统计每页写回状态文件、随备份跨 run 传递——ge2o 日志每轮清零，跨 run 全靠它。环境变量 `WW_WORKERS`(2) / `WW_GAP`(0.2s) / `WW_MAX_MIN`(300min) / `WW_SIZES_MAX`(5) / `WW_DECAY`(0.5) / `WW_MIN_FREE_KB`(/mnt 剩余 10GB 下限) / `WW_START_DELAY`(180s，让首屏预热先跑)。直连 Emby 不过 ge2o；缓存随备份持久化，逐轮往深处推进。**写回时保留 `recent` 字段**（playlog 记录的最近播放路径）——persist_state 是整体覆盖写，丢掉它回看预热就失效 |
| 校验用的 Emby 用户名 | secret `EMBY_USER`（**不写死在代码里**；未配置则退化为"至少一个用户"） |
| Emby 公网域名（隧道往返自测用） | 默认取 `e.<VD>.eu.org`（`VD` secret 拼出来，公开仓库不写死域名，日志里也会被自动打码）；换域名时用仓库 **Variables** `EMBY_PUBLIC_HOST` 覆盖。域名解析不通则跳过隧道 TTFB，只记边缘机房 |
| 起播等待树的基线与字幕/拖动读数 | 基线由 `warmup.sh` 第 2 段写入 `/tmp/warm-baseline.env`（`TUNNEL_TTFB` / `TUNNEL_EDGE` / `LINK_TTFB`），playlog 每次播放现读；字幕耗时取同 IP 最近一次 `Subtitles` 请求（µs/ms/s 三种单位经 `to_sec()` 归一化）；拖动取链由 playlog 写 `/opt/logs/seek.log`（同一条目第 2 次起 stream 请求才算拖动，首播不计） |
| 取消 run 也要拿诊断日志 | `gh run cancel`（**不要 force-cancel**：force 直接杀 runner，`always()` 步骤不执行）→ 等 ~5 分钟宽限期 → `archive diagnostics` 步骤会在宽限期内秒级输出 warmup / seek / ge2o 分类统计 / odlink / emby-console 全部诊断。该步骤排在 `backup emby data` **之前**——备份是 30GB 级上传，宽限期跑不完会被 SIGTERM 强杀，排它后面的归档永远轮不到输出 |
| Emby 校验项 | `emby302/emby_guard.py`（恢复侧与备份侧共用同一份） |
| 磁盘预检阈值 / 脱敏口径 | `emby302/lib.sh` |
| 通知内容与时机 | 启动通知、收尾通知在 workflow 内；播放通知在 `playlog.sh` heredoc |
| 备份源优先级 | `install emby` 步骤的三级恢复分支 |
| 新增公共函数 | `emby302/lib.sh`，在需要的步骤 `source` 它 |
