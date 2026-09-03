# emby302 —— Emby 媒体服务器 + 302 直链子系统

> 入口：`.github/workflows/emby.yml`
> 脚本：`.github/scripts/emby302/`
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
| 定时（`cron: 0 2,8,14,20 * * *`） | 仓库变量 `vars.EMBY_PLAYBACK_MODE`，缺省 `302` |
| 手动 `workflow_dispatch` | 输入项 `playback_mode`（`302` / `direct`） |
| `watch` | 同定时 |

> ⚠️ **cron 按 UTC 执行**：`2/8/14/20` UTC 对应北京时间 `10:00 / 16:00 / 22:00 / 次日 04:00`。
> `TZ: Asia/Shanghai` 只影响 runner 内 `date` 的输出（即通知里的时间戳），不改变 cron 时刻。

### 并发与时长

- `concurrency: emby-singleton` —— 同时只允许一个 run，后来的排队而不打断
- `sudo sleep 340m`（约 5 小时 40 分）—— 留出余量给每 6 小时一次的定时触发
- run 结束即销毁 runner，所有状态靠云端备份延续

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
`/tmp/PLAYBACK_MODE`（当前模式）、`/opt/odlink-last.json`（最近一次直链，供通知用）。

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

`odlink.py` 对外**伪装成 OpenList 的 `/api/fs/*`**，对内用 Microsoft Graph **复刻 rclone
的快捷方式跟随**，把 `@microsoft.graph.downloadUrl`（官方预授权直链，约 1 小时有效）
作为 `raw_url` 返回，ge2o 据此发出 302。

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
  └─ 否则 → Graph 逐段下钻 → 返回直链
```

非快捷方式路径与解析失败**一律原样转发本机 OpenList**，所以 odlink 不可用时
行为与没有它时完全一致（零回归）。

### 4.4 顶层名单固定，子路径动态（重要语义）

这是最容易被误解的一点：

| 范围 | 时机 | 说明 |
|---|---|---|
| **顶层**快捷方式名单 | 启动时一次性快照 | `bootstrap()` 列一次根目录，成功后即固定。**本轮内新建/改名/删除的快捷方式不会被感知**（走 fallback 转发 OpenList），需下次 run 才纳入 |
| 快捷方式**内部**的子路径 | 每次请求实时下钻 | 任意深度都无需预先扫描，结果进 `dir_cache` 缓存 |
| 嵌套快捷方式（快捷方式里的快捷方式） | 实时跟随跨盘 | 下钻途中遇 `remoteItem` 即切换 drive |

> 顶层列举用 `$top=200`，根目录条目超过 200 会被截断。

---

## 5. 健康检查与自动回退

三层保护，任一层不通过就回退 `direct`：

| 层 | 时机 | 行为 |
|---|---|---|
| **启动探活** | run 启动后 | 依次检查：ge2o 存活 → 直链源 `fs/get` → 直链源 `fs/list`。重试 3 次（间隔 10s），全失败则 `MODE=direct` |
| **运行中 watchdog** | 每 60 秒 | 相同检查；**连续 3 次失败**自动 kill cloudflared、改指 Emby:8096、写 `direct` 到 `/tmp/PLAYBACK_MODE` 并 TG 通知，然后退出 |
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
| `📺 Emby 启动` | 模式决策后立刻 | 模式、直链源、快捷方式解析数、探活结果、时间 | ✅ 正文回显（无敏感信息） |
| `🎬 播放 [302直链/中转] 片名` | 检测到播放 | 片名；302 时附**直链**（3 分钟内的最近一次） | ❌ 仅记片名 |
| `📺 Emby 302 链路连续 3 次探活失败，已自动回退 direct` | watchdog 触发 | — | — |
| `📺 Emby` | run 收尾 | 状态、模式、运行时长、302 链路统计、时间 | ✅ 正文回显 |
| `🔐 OpenList 凭据` | **仅改密时** | 用户名、密码明文、入口 | ❌ 绝不落日志 |

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

---

## 8. 数据与备份

### 恢复（三级降级，任一通过即止）

```
① OneDrive 流式：rclone cat onedrive:backup/emby/emby-backup.tar.zst | tar -I zstd -xf -
      （30GB 级 tarball 不落本地盘，流式解压）
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

### 回传

- **Emby**：流式 `tar | rclone rcat` 回传 `onedrive:backup/emby/emby-backup.tar.zst`（排除 `logs`、`transcoding-temp`）
- **OpenList**：`config.json` + `data.db` 同步到 `dropbox:self-hosted/openlist-emby/`，
  且**仅当 `fs/list` 实测通过**才回传，防止空数据覆盖远端
- 前置闸门：只有 `install emby` 校验通过才会 `touch /tmp/EMBY_READY_FOR_BACKUP`，
  收尾步骤见到该标记才允许打包

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

### 9.1 `odlink.py`

伪装成 OpenList 的直链服务。

**环境变量**

| 变量 | 默认 | 说明 |
|---|---|---|
| `ODLINK_PORT` | `5245` | 监听端口 |
| `ODLINK_UPSTREAM` | `http://127.0.0.1:5244` | 回退的 OpenList 地址 |
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
| POST | `/api/fs/get` | 取直链 → `data.raw_url` |
| POST | `/api/fs/list` | 列目录 → `data.content` |
| POST | `/api/fs/other` | 转码预览未启用，返回非 200 |

**统计字段**（`/stats` 与收尾通知）

| 字段 | 含义 |
|---|---|
| `fs.get` / `fs.list` | 请求次数 |
| `fs.link_ok` / `fs.link_miss` | 取到 / 未取到直链 |
| `fs.resolve_err` | Graph 解析失败 |
| `fs.fallback` | 回退 OpenList 次数 |
| `fs.cross_drive` | 跨盘（跟随快捷方式）次数 |
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
四个步骤 source。只定义函数、不设 shell 选项，避免污染调用方的 `set -euo pipefail`。

| 函数 | 用途 |
|---|---|
| `free_kb` / `require_free_kb` | 磁盘空间预检 |
| `cleanup_archive_workdir` | 清理 30GB 级临时 tarball |
| `validate_emby_data` | 转调 `emby_guard.py` |
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
| `/opt/logs/playlog.log` | 播放事件监听、Emby 认证矩阵、TG 通道自检 |
| `/opt/logs/watchdog.log` | 探活失败计数与回退记录 |
| `/opt/logs/openlist.log` | OpenList 启动与存储状态 |
| `/opt/logs/odprobe.log` | 快捷方式探测结论 |
| `/opt/logs/rclone-mount.log` | 挂载层：VFS 缓存逐出、429/403 限流、seek 后重取（归档时按关键行筛选，非纯 tail） |
| `/opt/logs/emby-console.log` | Emby 侧：起播时的 ffprobe / ffmpeg 记录——**定位"点击播放要等很久"的关键现场** |
| `/opt/logs/warmup.log` | 预热耗时：直链冷解析均值 + 挂载冷读均值（判断起播慢在哪一层的量化依据） |

收尾步骤会把 `playlog.log`（80 行）、`ge2o.log`（60 行）、`odlink.log`（60 行）、
`rclone-mount.log`（关键行 40）、`emby-console.log`（60 行）、`warmup.log`（40 行）
脱敏后归档进 workflow 日志。

> `rclone-mount.log` 用 `grep` 筛关键行而非纯 `tail`：缓存清理类输出每 15s 一条，
> 5.7 小时上千行，纯 tail 只会被它们占满、看不到真正的异常。

### 症状 → 排查

| 症状 | 优先看 | 常见原因 |
|---|---|---|
| 播放一直显示"中转" | 启动通知里的`直链源` + `ge2o.log` | ① 直链源是 `OpenList:5244`（odlink 没起来）② 路径换算断了（探活 `map_ok=0`）③ 首段不在顶层快捷方式名单里 |
| 收尾通知 `直链命中 0` | `odlink.log` | odlink 未就绪，或全部回退 OpenList |
| `oe.<VD>.eu.org` 登录不上 | 是否收到 `🔐 OpenList 凭据` 通知 | 没收到 = 密码没变，用 `admin` + `OPENLIST_ADMIN_PASSWORD`；收到 = 用通知里的密码（仅本轮有效） |
| Emby 启动成空库 | `install emby` 步骤 | 恢复三级全失败，或 `emby_guard.py` 校验不通过 |
| 备份没回传 | 收尾步骤 | `/tmp/EMBY_READY_FOR_BACKUP` 不存在（Emby 未成功启动），或磁盘预检未过 |
| 播放通知没来 | `playlog.log` 的 TG 通道自检 | ge2o 日志格式变化 / Emby 401 / 300s 去重窗口内 |
| 点击播放后要等很久才起播 | `emby-console.log` + `warmup.log` | ① Emby 现场 ffprobe（该条目此前未探测过，走挂载随机读）② 转码启动（播放通知标 `[中转]`）③ odlink 冷解析 ④ 播放器缓冲——见下方"起播慢怎么定位" |

### 起播慢怎么定位

`warmup images` 步骤做三段预热，**每段都带计时**，输出进 `warmup.log`：

| 段 | 做什么 | 成本 | 对 **302 直连播放** | 预热后的效果 |
|---|---|---|---|---|
| 海报墙 | 请求最新条目海报，让 Emby 现场缩放 + ge2o 内存缓存就绪 | 低 | ✅ 有效（与模式无关，纯 Emby 侧） | 首页秒开 |
| 直链 | 提前打一次 odlink `/api/fs/get`，填充 `dir_cache` / `link_cache` | 零流量 | ✅ **最有效**——ge2o→odlink 的直链解析本身就是 302 起播链路的一环 | 起播时不再逐段下钻 Graph |
| 头尾 | 读每个条目的头部与尾部，落进 VFS 稀疏缓存 | 真实流量，受 `WU_BUDGET_MB` 约束 | ⚠️ **基本无效**（视频流不过挂载），只在转码 / 回退 `direct` 时才用得上 | ffprobe / ffmpeg 起播读命中本地 |

日志里两个**均值**就是判断依据：

- **直链均值** —— 起播时 ge2o 那一段的耗时（预热后趋近 0）
- **头尾均值** —— 冷读 `WU_EDGE_MB × 2` 的成本，换算成 MB/s 可反推 ffprobe 会花多久

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
> 历史坑：`warmup.sh` 曾用 `UID` 存用户 ID，而 `UID` 是 bash **只读内建变量**，
> 赋值直接报 `readonly variable` 并失败 —— 查询拿到空结果、预热静默空转。
> 已改名为 `USER_ID`。

### 怎么确认 302 真的生效

1. 启动通知里`直链源`应为 `odlink:5245（Graph 跟随快捷方式）`
2. 播放通知的标签应为 `[302直链]` 而非 `[中转]`
3. 收尾通知的 `302 链路` 中 `直链命中` 应大于 0
4. `odlink.log` 里应有 `get 文件 ... 直链 host=... ` 记录

---

## 11. 修改指南

| 想改什么 | 改哪里 |
|---|---|
| 播放模式默认值 | workflow `env.PLAYBACK_MODE_INPUT` 的兜底值 / 仓库变量 `EMBY_PLAYBACK_MODE` |
| 探活判据与重试次数 | `run cloudflared` 步骤的探活循环、`/opt/watchdog.sh` heredoc |
| odlink 分流规则 | `odlink.py` 的 `do_POST` |
| 顶层快捷方式刷新策略 | `odlink.py` 的 `bootstrap_loop`（当前为一次性，成功后不再重跑） |
| 直链缓存时长 | `odlink.py` 的 `LINK_TTL` |
| rclone mount 参数（seek 优先口径） | `emby.yml` 的 `rclone-run` 步骤 |
| `/mnt` 容量预留 | workflow `env:` 的 `MNT_RESERVE_KB`（默认 6GB），分配逻辑在 `lib.sh` |
| 预热规模 | workflow `env:` 的 `WU_ITEMS`(10) / `WU_EDGE_MB`(64) / `WU_BUDGET_MB`(2048)，脚本在 `emby.yml` 的 `warmup images` 步骤；**302 直连为主时建议 3 / 32**（头尾预热对直连播放基本无效，只当冷读探针，见[起播慢怎么定位](#起播慢怎么定位)） |
| 校验用的 Emby 用户名 | secret `EMBY_USER`（**不写死在代码里**；未配置则退化为"至少一个用户"） |
| Emby 校验项 | `emby302/emby_guard.py`（恢复侧与备份侧共用同一份） |
| 磁盘预检阈值 / 脱敏口径 | `emby302/lib.sh` |
| 通知内容与时机 | 启动通知、收尾通知在 workflow 内；播放通知在 `playlog.sh` heredoc |
| 备份源优先级 | `install emby` 步骤的三级恢复分支 |
| 新增公共函数 | `emby302/lib.sh`，在需要的步骤 `source` 它 |
