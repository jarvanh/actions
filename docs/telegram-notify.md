# Telegram 通知规范（全库唯一）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）统一遵守本文档。
**改版式先改这里，再同步各实现**；本文档是规范的唯一真源。

## 1. 实现真源

| 运行环境 | 真源 | 说明 |
|---|---|---|
| ubuntu runner（bash） | [`scripts/telegram/tg_notify.sh`](../.github/scripts/telegram/tg_notify.sh) | 排版助手 + 发送层（429 重试 / 4000 分片 / 解析失败直接报错不重发 / curl `-m 15`），`source` 使用 |
| Telegram 频道内容管线 | `scripts/tg-channel/` | 频道同步 / 上传 / 去重 / 清理（**不是**通知域），单向依赖上面的 `tg_notify.sh` |
| openlist 同步脚本（runner 上执行） | [`scripts/openlist/telegram.sh`](../.github/scripts/openlist/telegram.sh) | 薄适配层：只放「需要 message_id」的进度面板函数（`send_telegram_message` / 原地编辑 3 函数）；排版与发送经 `load_all.sh` L0 层 source 上一行真源，不再自带副本 |
| python | `scripts/proxy-speedtest/speedtest_common.py` 的 `tg_format_elapsed` / `tg_footer_line` / `send_telegram` / `send_telegram_chunked` | 三件套（`speedtest.py` / `speedtest_gitee.py` / `taier_speedtest.py`）一律 `from speedtest_common import ...` 复用，**禁止自造**；`notify()` 是 `emby.yml` 内联的播放通知函数，不是通用出口 |
| PowerShell（windows runner） | [`scripts/telegram/tg_notify.ps1`](../.github/scripts/telegram/tg_notify.ps1)（`rdp.yml` / `tailscale-windows.yml` dot-source，需先 checkout） | `Esc-Html` / `Get-TgFooter` / `Send-TgMessage` / `$TG_SEP`；语义与 bash 版对齐（429 读 `Retry-After` 重试 5 次，解析失败不重发直接抛出并带响应体） |

## 2. 版式模板

```
{emoji} 标题              ← tg_add_title（纯文字；层级靠分隔线与 emoji）
━━━━━━━━━━━━━━━━━━              ← TG_SEP（18 个全角横线，勿手写；其后不空行）
标签：值                          ← tg_add_kv（全角冒号）
标签：<code>路径/命令</code>      ← tg_add_path（等宽展示）

{emoji} 分节 · N          ← tg_add_section（段前空行；计数一律 " · N"）
{emoji} 组头 · 大小      ← 分组列表：组头（emoji 与计数同态裸文本）
  ├─ <code>条目</code> · 备注    ← tree_conn / tree_lines（末条 └─；备注无标签）
  │   子行                      ← tree_sub（│ 后 3 空格；末条目整行前缀 6 空格）
  └─ 还有 N 条…                 ← 超长折叠行（并入条目流作末条，禁双 └─）

<pre>日志块</pre>                ← tg_add_pre（转义 + <pre> 包裹；tg_add_block 仅用于已含标签的片段）
备注说明                        ← tg_add_note（段前空行）

（空行）⏱ 已运行 X · 🔗 <a href="URL">运行日志</a>   ← tg_add_footer
```

> **空行只由三处产生**：`tg_add_section` 段前、`tg_add_note` 段前、`tg_add_footer` 前。
> 分隔线与紧随其后的内容之间**不空行**（`tg_add_title` 只输出 `标题\n分隔线\n`）。
> 若紧随分隔线的是分节/说明（任务预览的 `📊 同步对`、openclaw/tailscale 的 `🔐 SSH`），
> `tg_add_section` / `tg_add_note` 会**自动省略段前空行**——分隔线后一律不留空。
> 另两种不补的情形：消息为空（首个分节/说明，开头不需要空行）；正文变量**无尾换行**
> 时（手拼变量，如 `emby.yml` 播放通知的 `text`）会先补一个 `\n` 收尾，再补段前空行 ——
> 否则那个 `\n` 只给正文末行换行，空行消失（`tg_add_footer` 同款处理）。
> pwsh 侧无这两个助手，`tailscale-windows.yml` 手拼时同样不得在分隔线后加 `` `n ``。

#### 标签语义表（全库唯一，冲突按下表裁决）

`§2` 模板只列了 6 类形态，实际内容有 11 类语义——缺归属的部分过去由 4 套发送层各自手拼，
这是全库标签不一致的根源。下表是唯一裁决依据：

> **2026-09-10 终版拍板：全库无 `<b>`。**
> 一切信息文字（标题/分节/组头/条目主体/kv 值/状态/计数/数值/元数据/折叠行/说明段）
> 一律**裸文本**（动态内容照常转义）；仅有标签的是机器值 `<code>`、日志/命令块 `<pre>`、
> 链接 `<a>`。理由：emoji（彩色）+ 分隔线 + 空行 + 等宽已完整承担视觉层级，加粗是
> 冗余权重；且「哪个位置该加粗」的边界判断（条目主体 vs kv 值）是历史返工的根源，
> 归零后新增通知零判断成本。（演变：09-09 去 `<i>` → 值去粗 → emoji 去粗 → 全去。）

| # | 语义 | 标签 | 产出方式 | 例 |
|---|---|---|---|---|
| 1 | 标题 / 分节 | 无 | `tg_add_title` / `tg_add_section` | `📋 任务预览 · backup`、`📊 同步对 · 2` |
| 2 | 结论值（kv 值 / 状态 / 计数 / 数值） | 无 | `tg_add_kv` | `状态：成功` |
| 3 | 机器值（路径 / 文件名 / 命令 / 密码 / IP / ID / 端口 / 原始异常串） | `<code>` | `tg_add_path` | `文件：<code>a/b.mp4</code>` |
| 4 | 条目主体 | 文件类 `<code>`，其它无 | **`tg_entry` / `tg_add_entry`** | `<code>x.mp4</code>`、`香港 01` |
| 5 | 元数据（` · ` 后的大小 / 时间 / 图例 / 备注） | 无 | **同上（作为 `tg_entry` 的后续参数）** | ` · 1.7 GB · 2160p` |
| 6 | 折叠行 | 无 | `tree_code_fold` | `还有 8 条…` |
| 7 | 说明段（独立成段） | 无 | `tg_add_note` | `密码 SSH/RDP 共用` |
| 8 | 日志块 | `<pre>` | **`tg_add_pre`** | `<pre>…</pre>` |
| 9 | 可复制命令块 | `<pre>` | **`tg_add_pre`**（§2.3） | `<pre>gh workflow run …</pre>` |
| 10 | 双机器值条目（替换关系） | 两个都 `<code>` | **`tg_entry_pair`** | `<code>原名</code> → <code>替代名</code> · 1.2 GiB` |
| 11 | 双机器值条目（并列） | 两个都 `<code>` | **`tg_entry_codes`** | `<code>香港 01</code> · <code>connection reset</code>` |

> **全库语义 100% 有产出方式，规范中已无"手写"**（2026-09-10）：
> - 单主体条目：`tg_entry <主体> [元数据...]`（返回**单行无尾换行**，`$( )` 会吃掉换行，
>   拼接时自行补 `$'\n'`）；累积多行列表用 `tg_add_entry <var> <主体> [元数据...]`。
> - **双机器值条目**（两个主体都是机器值，非"主体 + 元数据"结构）：
>   `tg_entry_pair <A> <B> [元数据...]` → `<code>A</code> → <code>B</code> · 元数据`
>   （`→` 表替换/映射关系，如原名 → 替代名，**不可写成 " · "**；B 为空自动省略）；
>   `tg_entry_codes <A> <B> [元数据...]` → `<code>A</code> · <code>B</code> · 元数据`
>   （并列机器值、无主次，如节点名 · 原始异常串）。追加版 `tg_add_entry_pair` /
>   `tg_add_entry_codes`。
> - python 侧同义：`speedtest_common.tg_entry(subject, *meta)` / `tg_entry_pair` /
>   `tg_entry_codes` / `tg_pre_block(text)`。

**裁决规则（冲突时按此，勿各自发挥）**：

1. **一切信息文字裸文本**：不加粗、不斜体，动态内容照常转义。说明性内容
   （有效期、连接方式…）进 kv 值或 `tg_add_note` 说明段。
2. **条目非文件值不加等宽**：可复制的机器值用 `<code>`；非机器值的条目主体
   （如节点名、原因短语）裸文本 + emoji 表意。
3. **条目前缀**：一律 `├─/└─` 树形（真源唯一形态，`tree_lines` / `tree_code_fold`）。
   `• ` 平铺已于 2026-09-09 全库清除（含 file_restore / sync_marker / file_split /
   sync_notify），**不得再引入**——同一条通知更不得两种前缀并存。
4. **组头形态**：`{emoji} 名 · 大小/计数`（emoji 打头、计数 ` · ` 尾随，全裸文本）。
5. **分节前缀不得自造**：`🥇` / `⭐` 等不在语义表内的前缀一律不用；名次类分节用
   `🏆 最快节点 · N`，图例挂 ` · …`。
6. **条目不编号**：树形条目靠顺序表名次，不加 `1.` `2.`（与 bash 侧一致）。
7. **emoji 与文字同态**：emoji 跟随它所在的文字——文字有标签它就有，文字没有它就
   没有。全库无 `<b>` 后此规则自动满足，唯一例外是批次行等宽 `<code>`（见下）。
   等宽对齐块：进度面板阶段行/批次历史行整行包 `<code>` 换数字列竖向对齐，
   emoji 与 `▸` 随之在 `<code>` 内（§4 字段表）。
8. **错误/原因三选一**：中文阶段/原因 → 裸文本；原始异常串 → `<code>`；多行日志 → `<pre>`。

完整示例（`任务预览`，2026-09-07 实录）：

```
📋 任务预览 · backup
━━━━━━━━━━━━━━━━━━
📊 同步对 · 2
📁 onedrive:backup
  ├─ <code>aliyundriveCrypt/backup</code> · 源端 36.065 GiB / 1415 文件 · +7.268 GiB / +2 文件
  │   差异构成：同名更新 2
  │   排除 · 3
  │     ├─ <code>notion/**</code>
  │     ├─ <code>self-hosted_latest.tar.gz</code>
  │     └─ <code>github_repos_latest.tar.gz</code>
  └─ <code>wopan176Crypt/backup</code> · 源端 53.594 GiB / 1417 文件 · +26.509 GiB / +41 文件
      差异构成：新增 38 · 同名更新 3
      已扣减 1 个修复文件 / 2.796 KiB

📦 合计预估待同步：33.777 GiB / 43 文件 · 新增 38 · 同名更新 3

⏱ 已运行 22 分钟 · 🔗 运行日志
```

### 2.1 标签锚点行（多字段拼行必用）

一行要塞多个字段时（类型/时长/分辨率/编码…），**禁止无锚点的裸 " · " 串**——
整条消息读起来是一坨。每行用全角冒号标签打头作锚点（规格：/链路：/客户端：…），
kv 值无标签（语义表 #2），` · ` 后的元数据同样无标签（全库无 `<b>`/`<i>`，见语义表拍板说明）；
动作行（如 ▶ 打开直链）段前空行与正文数据区隔，条目化等待链走独立分节。
实现参考：`emby.yml` 播放通知（`notify()`）。

```
🎬 五十度灰 (2015)
━━━━━━━━━━━━━━━━━━
规格：电影 · 2 小时 08 分 · 1080p · h264 · 5.5 GB
链路：⚡ 302直连 OneDrive · 直链剩余 40 分钟
客户端：203.0.113.57 · Safari · macOS

⏳ 起播等待
  ├─ <code>你 → Cloudflare</code> · 27 毫秒
  └─ <code>你 → OneDrive 拉流缓冲</code> · 这段服务器测不到

▶ 打开直链

⏱ 已运行 38 分钟 · 🔗 运行日志
```

### 2.2 明细列表与分组

**三种分组场景，形态一致**（组头 + 条目树形）：

1. **长列表** —— 条目数可能很大（跳过、失败、待处理），必须按状态或原因分组，
   不得穷举裸文本；组头 `原因 · N` + 条目 `<code>名称</code>` 树形。
2. **多套同类信息** —— 条目虽少但存在多套并列结构（如 SSH / RDP 两套入口凭据），
   按套分节（emoji 区分语义），否则平铺混排难以扫读。
   **列表分节一律带 ` · N`**（2026-09-09 收敛，取消「多套同类信息免计数」例外）——
   `🔐 SSH · 3`、`🖥️ RDP · 3`、`🤖 AI 网关 · N` 同样计数；
   分节后跟 kv 行或单段说明的（如 `📊 大小对比`）不带。
3. **条目子树（附属明细）** —— 某条目自身还有附属明细（如任务预览的排除规则）且
   **条数 ≥2** 时，降为二层列表：组头 = `tree_sub` 前缀 + `标签 · N`，子条目再缩进
   2 格用 `├─/└─`（模式内末条 └─）；仅 1 条时并入子行（`标签：<code>…</code>`），不为
   单条扩树。子树会显著拉高通知，谨慎使用。

```
  ├─ <code>aliyundriveCrypt/backup</code> · 源端 … · +7.270 GiB / +2 文件
  │   排除 · 2
  │     ├─ <code>notion/**</code>
  │     └─ <code>self-hosted_latest.tar.gz</code>
  └─ <code>wopan176Crypt/backup</code> · …
        排除 · N（末条目的子树前缀 8 空格 + ├─/└─）
```

   实现参考：`openlist/task_preview.sh`（`排除 · N` 子树）。

### 2.3 复制即用命令块（操作指引给人可执行命令，不给数据文件路径）

通知里需要用户后续操作时（跳过通知的强制同步/修复还原、失败通知的重跑入口…），
**直接给可复制执行的 `gh` 命令**，用 `<pre>` 包裹（等宽不折行、TG 点按整块复制）；
不要给 marker/JSON 等数据文件路径 —— 那是程序消费的落盘载体，对人没有动作。

- 参数值必须按实际匹配逻辑核实（如 `restore_task` 按 marker 文件名**首个 `_` 前缀**
  精确匹配，`file_restore.sh` —— 填完整任务名反而匹配不到）；行为差异需注明
  （`force_sync` 是全量，无单任务参数）。
- 实现参考：`openlist/sync_marker.sh` `send_sync_skipped`（🛠️ 复制即用）。

```
🛠️ 复制即用

▸ 强制同步（全量，含本任务）
gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true

▸ 还原 5 个非原名文件（restore_task=task0）
gh workflow run openlist.yml \
  -f run_mode='⚠️ 还原 · 修复文件还原为原路径' \
  -f restore_task=task0
```

```
⚠️ 跳过/过滤文件
损坏 · 43
  ├─ <code>Sexy Young 1.mp4</code>
  ├─ <code>Sexy Young 2.mp4</code>
  └─ 还有 35 条…
非视频 · 2
  ├─ <code>failed_videos.json</code>
  └─ <code>uploaded_videos.json</code>
```

- **每组上限 8 条**，超出折叠为 `还有 N 条…`：
  43 条损坏全列会刷屏，且容易顶到 4000 字符分片边界把收尾区切走。
  上限 8 是各实现的内定值（`tg-channel/sync_to_tg.sh` 读 `SKIP_DETAIL_MAX`（默认 8，
  全库无定义点）、其余 openlist/tg-channel 处均硬编码 8）——改上限需逐处改，暂无全局开关。
  多组并列时（如去重明细）通知内**最多展示 8 组**，超出折叠为
  `还有 N 组未展开 · 明细见运行日志`（实现：`tg-channel/dedupe_videos_by_hash.sh` /
  `dedupe_ph_videos.sh` 的 `_grp_block`，文案与条目级 `还有 N 条…` 不同，勿混写）。
- **折叠行必须并入条目流再交给 `tree_lines`**，由它统一决定末条 ——
  单独补一行 `  └─ 还有 N 条…` 会造成双 `└─` 同级、层次混淆。
  文件类列表可直接用一站式助手 `tree_code_fold <多行> [max=8]`
  （真源 `telegram/tg_notify.sh`，逐行 `<code>转义</code>` + 折叠 + 树形一次完成）。
- **职责分层**：脚本层只输出结构化数据（如 `中文原因\t路径`），
  HTML 与树形一律交给 `tg_*` 助手；脚本侧自造标签是版式漂移的根源。
- 实现参考：`tg-channel/sync_to_tg.sh` 的 `_render_skipped_groups`。

> 踩坑：`tree_lines` **接收参数、不读 stdin**。
> `... | tree_lines` 会静默输出空条目（无报错），必须 `tree_lines "$var"`。

### 2.4 「📍 测速点网络」统一 KV 树（测速三件套）

三件套（`speedtest.py` / `speedtest_gitee.py` / `taier_speedtest.py`）的测速点网络归属
共用唯一渲染入口 **`speedtest_common.build_target_network_section(targets)`**，
`targets = [(server, label, info)]`（cdn/gitee 传解析 IP + 域名，taier 传 ip:port + 主机名）。
单测速点 = 测速服务器/ISP/ASN/位置 4 行树；多测速点 = 标题带 ` · N`，
每块以 `[{i}] 域名` 定位行打头（与组头同级的定位行，非树形条目）：

```
📍 测速点网络 · 2
[1] <code>mirror.example.com</code>
  ├─ 测速服务器：<code>93.184.216.34</code>
  ├─ ISP：…
  ├─ ASN：<code>AS15169</code>
  └─ 位置：…
[2] <code>…</code>
  └─ 归属获取失败（…）
```

`server` 解析失败时该块降级为「归属获取失败」一行（``，不裸文本）。
python 侧共用 `TG_SEP`（`speedtest_common.TG_SEP`）与 `tg_footer_line`，勿再手写 `'━' * 18`。

## 3. 收尾区（全库唯一收尾形态）

```
（空行）⏱ 已运行 X 小时 Y 分 · 🔗 <a href="TG_RUN_URL">运行日志</a>
```

- **时长三段式**：`≥1h → "X 小时 Y 分"`、`≥1min → "X 分钟"`、否则 `"X 秒"`。
  语义 = run 已运行时长，**不是**步骤自身耗时。条目内耗时用 `⏱mm:ss` 定宽形态
  （如批次历史行 `⏱01:15`，见 §4 字段 emoji 表）；收尾区专属的是
  「⏱ 已运行 X」完整形态，两者不混用。
- **降级链**（必须逐字一致）：`TG_RUN_STARTED_AT` → 时长；
  缺失时兜底 **runner 开机时刻**（Linux `/proc/1` mtime / Windows `LastBootUpTime`，
  hosted runner 随 job 启动、误差秒级）；仍取不到 → 不显示时长；
  `TG_RUN_URL` 与时长皆无 → 整行跳过。
  > 背景：GitHub 已于 2026-09-05 移除 `github.run_started_at` 表达式上下文
  > （API 字段仍在），workflow 注入的 `TG_RUN_STARTED_AT` 变为空值，兜底必须存在。
- **附加链接**：`tg_add_footer <var> ["标签" "URL"]...` → 追加 ` · 🔗 <a>标签</a>`。
- **环境变量接线**（workflow 侧注入；`TG_RUN_URL` 决定有无链接，
  `TG_RUN_STARTED_AT` 只影响时长精度）：

```yaml
env:
  TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
  TG_RUN_STARTED_AT: ${{ github.run_started_at }}
```

> 注：`github.run_started_at` 目前已被平台从表达式上下文移除（注入后为空值），
> 时长靠上述 runner 开机时刻兜底。注入行保留——属性若恢复可立即生效，
> 且自托管 runner 仍可用精确值覆盖。

## 4. 禁止事项（历史踩坑，勿回退）

| 禁止 | 反例 | 正例 |
|---|---|---|
| 英文紧凑时长进通知 | `⏱ 已运行 5h 57m`、`耗时: 12.34s` | `⏱ 已运行 5 小时 57 分`（紧凑格式仅允许进 RESULT_JSON artifacts；批次历史行 `⏱01:15` mm:ss 为既定字段形态，见下方字段表） |
| 手拼收尾行 | `"\n\n⏱ 🔗 <a>运行日志</a>"` | 一律经 `tg_add_footer` / `tg_footer_line` |
| `⏱️`（带 VS16 变体） | `⏱️ 已用：…` | 裸 `⏱`：收尾区 `⏱ 已运行 X`；条目内耗时 `⏱1分15秒`（紧跟数字无空格） |
| 半角冒号 kv 行 | `📦 分组: xxx` | `📦 分组：xxx` |
| emoji 入 `<b>`（已随全库无 `<b>` 作废） | `<b>✅ 3</b>`、`<b>📁 组头</b>` | `✅ 3`、`📁 组头`（全裸文本，语义表 #1/#2/#4） |
| `🥇 TOP 5` 等自造分节前缀混用 | — | 分节 emoji 与语义对齐：📍 进行中（进度面板阶段）/ ✅ 完成 / ⏭️ 跳过 / ❌ 失败 / ⚠️ 警告 |
| 裸文本条目列表 | `not_video: failed_videos.json` | 按原因分组：组头 `非视频 · 2` + `  ├─ <code>failed_videos.json</code>` |
| 英文原因/状态 token 直出 | `corrupt: xxx` | 用中文标签（损坏 / 非视频 / 重复） |
| 双 `└─` 同级 | 条目末尾 `└─` 后再补 `  └─ 还有 N 条…` | 折叠行并入条目流，由 `tree_lines` 统一决定末条 |
| 超长列表全量穷举 | 43 条损坏逐行列 | 每组上限 8 条 + `还有 N 条…`；多组并列最多展示 8 组 |
| 已 source 发送层仍 curl 直发 | `curl ... sendMessage \|\| { plain=$(...); curl ... }` | 一律 `send_tg "$msg"`（429 重试已内建；自造发送缺 429 处理，限流时通知消失） |
| 高精度浮点直出 | `起播 2.16068914 秒` | 一位小数：`起播 2.2 秒`（原始精度无意义，只碍扫读） |
| ISO 原始时间戳直出 | `时间：2026-09-05T11:34:19Z` | 人性化：`上次同步：2026-09-05 11:34 UTC · 15 小时前`（`date -d` 解析，失败保留原值） |

状态 emoji 语义（全库统一）：
`✅` 成功 / `⚠️` 部分失败 / `❌` 失败 / `⏭️` 跳过 / `🔄` 进行中 / `⏳` 待处理 / `⛔` 中断 / `🚨` 危险警告。

> **📍 与 🔄 的分工**（曾两表互相打架，此处裁决）：`📍` 是进度面板「进行中」**分节**标题
> （当前阶段，正常在跑）；`🔄` 是**状态/活动**语义（进行中的条目与标题）。同一面板里
> 两者是互斥分支：`📍 进行中 · N`（未收尾）／`🔄 进行中 · N · 未执行完`（已 finalize
> 但仍有任务在跑）。实现：`openlist/sync_progress.sh`。判违例时按此分工，勿互相替代。

批次计数 emoji 字段表（进度面板批次历史行，**全字段恒显 + 定宽补零**；行宽 ≈42 全角，
手机折 2 行为既定取舍 —— 换取计数列竖向对齐）：
`❌#n` 状态+批次号 | `✅00` 成功 | `🔧00` 修复 | `❗33` 失败（不用 ❌，避免与状态撞形）|
`⏭️22` 跳过 | `♻️22` 已有（目标端已存在）—— 五计数 `%02d` 补零 | `⏱01:15` 耗时（mm:ss 补零；
≥1h 时 mm 延伸为 3 位，如 `75:20`，定宽让位于真值）|
`⬆️4.79G` 上传量（GiB 两位小数，末列不补）。
状态: ✅全成 ⚠️部分失败 ❌失败 ⏭️整批跳过 ♻️整批已有。全部入史（MAX=6 滚动窗口，全量在运行日志）。
实现：条目生成 `openlist/task_engine.sh`（`_bh_entry`）；滚动窗口与渲染
`openlist/sync_progress.sh`（`PROGRESS_BATCH_HISTORY_MAX=6` / `_progress_batch_history_render`）。

既定豁免清单（**技术必需**，不算违例，勿"修复"；2026-09-10 终版仅剩这 3 条，
风格类豁免——`• ` 平铺、列表分节免计数、加粗/斜体——已全部清除）：
1. 内容片长分钟补零 `2 小时 08 分`（条目内媒体时长，区别于收尾区无补零的 `X 小时 Y 分`）。
2. 批次历史行 `⏱mm:ss` ≥1h 时 mm 延伸 3 位（`75:20`）——定宽让位于真值。
3. 进度面板阶段行/批次历史行整行 `<code>` 等宽包裹（emoji/`▸` 随之在 `<code>` 内）——
   换计数列竖向对齐，见上方字段表；`🔗` 在 `<a>` 内、`▸`/`▶` 动作行前缀同理（链接/
   动作形态）。`tg_add_note` 说明段整段 `escape_html`、段内无法带标签——在全库无
   `<b>` 后已自动与规则一致，不再是特例。

## 5. 发送层要求

- **一律 HTML parse_mode**，动态内容必须转义（`escape_html` / `tg_*` 助手已内置）。
  > pwsh 侧：转义/发送经 `telegram/tg_notify.ps1` dot-source 提供（`Esc-Html` /
  > `Send-TgMessage` / `Get-TgFooter`），dot-source 后加 `Get-Command Send-TgMessage`
  > 自检——调用未定义函数是**终止错误**，若 step 带 `continue-on-error: true`
  > 会表现为通知静默消失、不报失败（`tailscale-windows.yml` 曾因此缺发入口通知）。
- HTML 解析失败（400 can't parse entities）→ **不重发**，直接报错暴露（见下）。消息本来就没被
  Telegram 接收，退化成纯文本只是把版式 bug 藏起来；动态内容一律经 `tg_*` 助手转义即可避免。
- 429 限流按 `retry_after` 等待重试（最多 5 次）；长消息按 4000 字符分片（断在换行处，不切 UTF-8 多字节）。
- 发送失败必须在 stderr/日志输出错误原因（含 API 响应体前 200 字符），由调用方决定 `|| true` 还是失败。
  bash 真源把原因写 stderr——调用方**不要 `>/dev/null 2>&1` 吞掉**；python 侧 `send_telegram`
  失败不写 stderr，靠返回值 `{'sent': False, 'reason': …}` 回传，**调用方必须把 reason 记进日志**
  （三件套已在发送后 `log_progress('telegram_send_finished', …)`），否则 400 解析失败表现为通知静默消失。
- **curl 直发的唯一豁免**：需要 message_id 的进度面板原地维护（`openlist/telegram.sh` 的
  `_tg_send_and_get_id` / `_tg_delete_message`）——sendMessage 发送层不返回 message_id，
  原地编辑/删旧必须直发；除此之外已 source 发送层的通知点再 curl 直发仍属禁止（见 §4）。
- 媒体上传（`sendDocument`/`sendVideo` 等）不走 sendMessage 发送层（固有例外），
  但 caption 仍须转义、429 重试与发送层同口径（**最多 5 次**，见 `sync_notify.sh` sendDocument 段）。
- 429 重试是发送层职责，调用方勿自造重复实现——
  已 `source` 发送层的通知点再 curl 直发属禁止事项（见 §4）。
- **凭据/密码类消息**（如 OpenList 改密回执）**没有**特殊发送通道：用 `tg_add_*` 构建
  （密码走 `tg_add_path`，自动 `escape_html`）后照常 `send_tg`。
  不要为凭据自造「单发不重试不退化」的实现 —— 429 与 400 都表示上一条**没被 Telegram
  接收**，重试/退化不会产生两条密码；放弃重试反而会让凭据在限流时直接丢失。
  实现参考：`emby.yml` 的 OpenList 凭据通知。

## 6. 新增通知检查清单

- [ ] 标题 = emoji + 短语，计数/细节下沉 kv 行
- [ ] 列表分节计数 ` · N`（分节后跟条目列表必带；kv/单段说明分节不带）；条目元数据 ` · …` 无标签；kv 行全角冒号；全库无 `<b>`
- [ ] 明细列表按状态/原因分组、树形列出，超长折叠（无裸文本、无双 `└─`）
- [ ] 脚本层只出结构化数据，HTML 与树形交给 `tg_*` 助手（不在脚本里拼标签）
- [ ] 收尾区经 `tg_add_footer`（bash）/ `tg_footer_line`（python），无手拼
- [ ] workflow 已注入 `TG_RUN_URL` / `TG_RUN_STARTED_AT`（job 或 step 级 env）
- [ ] 动态内容全部经转义助手；发送走 `send_tg` / `send_tg_chunked`（python 侧 `send_telegram` / `send_telegram_chunked`）
- [ ] 数值/时间戳已人性化：无原始高精度浮点、无 ISO 原始戳直出（见 §4）
- [ ] 进度面板批次行按 §4 字段 emoji 表（**五计数** %02d 恒显 + ⏱mm:ss + ⬆️GiB）
- [ ] 相关测试同步更新（如 `openlist/tests/test_progress_final_title.sh`）

## 7. 回归测试守卫

`openlist/tests/` 现有 **19 个回归套件**（2026-09-09 由 17 增至 19，新增
`test_marker_skip_guards.sh` / `test_sync_trend_budget.sh`）——凡改动 `telegram/tg_notify.sh`（真源）/
`openlist/telegram.sh` / `task_engine.sh` 批次行 / 同步管线，全量跑通后再交付，
且全量日志 `command not found` 必须为零。

> **本地跑的 4 个已知失败属基线，不是回归**（macOS 环境所致，Linux runner 正常）：
> `test_truth.sh` FAIL=7（容器重启依赖 docker/真实服务）、`test_progress_no_orphans.sh`
> 的 T5 时序 flake、`test_marker_skip_guards.sh` 1b（BSD `date` 无 `-d`）、
> `test_sync_trend_budget.sh`（macOS `wc` 输出对齐空格 + 脚本 `unbound variable`）。
> 判定时与这条基线比对，偏离才算回归。

与本规范直接相关的守卫点：

| 测试 | 守卫点 |
|---|---|
| `openlist/tests/test_progress_final_title.sh` | 收尾标题四态 + 状态行下沉 |
| `openlist/tests/test_preview_diff.sh` | 任务预览合计行/树形/排除子树/扣减子行 |
| `openlist/tests/test_progress_phase_layout.sh` | 进度面板无 ⏱ 尾 + 批次历史行 emoji 形态渲染 |
| `openlist/tests/test_skip_preview_hint.sh` | 跳过预览提示 |
| `openlist/tests/test_batch_precheck_circuit_breaker.sh` | 批次熔断分支（字段 emoji stub 在此） |
| `openlist/tests/test_method_id_naming.sh` | 修复方法 ID ↔ 中文标签映射 |
| `openlist/tests/test_hash_dir_fallback.sh` | 哈希目录兜底（含 fix_log 文案） |
| `openlist/tests/test_fix_log_section.sh` | 修复日志区段头 `=== 尝试修复失败文件: <rel> ===` 写完整相对路径 + 通知侧 awk 能切出非空片段 + 相邻区段不串味 |
| `openlist/tests/test_marker_skip_guards.sh` | 跳过窗口守卫（未来戳 / rclone size 失败 fail-open / 源端缩小 warning / FORCE_SYNC 放行）→ 决定 `send_sync_skipped` 是否触发 |
| `openlist/tests/test_sync_trend_budget.sh` | `📈 同步趋势`通知（sync_trend.sh）的跨 run 记录与预算门控 |

`tg-channel/sync_to_tg.sh`（ph-dl / 91 通知）**暂无测试套件**——
改动后靠本地渲染实测验证（提取函数 + 造模拟数据跑 `tree_lines` 输出对比）。
后续补测试时可参考上述 openlist 套件的 mock 方式（mock `tg_add_*` +
捕获 `send_telegram_message` 入参）。
