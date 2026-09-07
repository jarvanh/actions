# Telegram 通知规范（全库唯一）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）统一遵守本文档。
**改版式先改这里，再同步各实现**；本文档是规范的唯一真源。

## 1. 实现真源

| 运行环境 | 真源 | 说明 |
|---|---|---|
| ubuntu runner（bash） | [`scripts/telegram/tg_notify.sh`](../.github/scripts/telegram/tg_notify.sh) | 排版助手 + 发送层（429 重试 / 4000 分片 / 解析失败直接报错不重发 / curl `-m 15`），`source` 使用 |
| Telegram 频道内容管线 | `scripts/tg-channel/` | 频道同步 / 上传 / 去重 / 清理（**不是**通知域），单向依赖上面的 `tg_notify.sh` |
| openlist 同步脚本（runner 上执行） | [`scripts/openlist/telegram.sh`](../.github/scripts/openlist/telegram.sh) | 薄适配层：只放「需要 message_id」的进度面板函数（`send_telegram_message` / 原地编辑 3 函数）；排版与发送经 `load_all.sh` L0 层 source 上一行真源，不再自带副本 |
| python | `scripts/proxy-speedtest/speedtest_gitee.py` 的 `tg_format_elapsed` / `tg_footer_line` / `send_telegram_chunked` | 其余 python 一律复用或经 `notify()` 借 bash 生成，**禁止自造** |
| PowerShell（windows runner） | [`scripts/telegram/tg_notify.ps1`](../.github/scripts/telegram/tg_notify.ps1)（`rdp.yml` / `tailscale-windows.yml` dot-source，需先 checkout） | `Esc-Html` / `Get-TgFooter` / `Send-TgMessage` / `$TG_SEP`；语义与 bash 版对齐（429 读 `Retry-After` 重试 5 次，解析失败不重发直接抛出并带响应体） |

## 2. 版式模板

```
{emoji} <b>标题</b>              ← tg_add_title（emoji + 短语，副标题说明下沉 kv 行）
━━━━━━━━━━━━━━━━━━              ← TG_SEP（18 个全角横线，勿手写）

标签：<b>值</b>                  ← tg_add_kv（全角冒号，关键值加粗）
标签：<code>路径/命令</code>      ← tg_add_path（等宽展示）

{emoji} <b>分节 · N</b>          ← tg_add_section（段前空行；计数一律 " · N"）
📁 <b>组头</b> · <i>大小</i>      ← 分组列表：组头路径加粗
  ├─ <code>条目</code> · <i>备注</i>   ← tree_conn / tree_lines（末条 └─）
  │   子行                      ← tree_sub（│ 后 3 空格；末条目整行前缀 6 空格）
  └─ <i>还有 N 条…</i>          ← 超长折叠行（并入条目流作末条，禁双 └─）

<pre>日志块</pre>                ← tg_add_block（需对齐的多行内容）
<i>备注说明</i>                  ← tg_add_note（段前空行）

（空行）⏱ 已运行 <b>X</b> · 🔗 <a href="URL">运行日志</a>   ← tg_add_footer
```

完整示例（`任务预览`，2026-09-07 实录）：

```
📋 任务预览 · backup
━━━━━━━━━━━━━━━━━━

📊 同步对 · 2
📁 <b>onedrive:backup</b>
  ├─ <code>aliyundriveCrypt/backup</code> · <i>源端 36.065 GiB / 1415 文件</i> · <b>+7.268 GiB / +2 文件</b>
  │   差异构成：同名更新 2
  │   排除 · 3
  │     ├─ <code>notion/**</code>
  │     ├─ <code>self-hosted_latest.tar.gz</code>
  │     └─ <code>github_repos_latest.tar.gz</code>
  └─ <code>wopan176Crypt/backup</code> · <i>源端 53.594 GiB / 1417 文件</i> · <b>+26.509 GiB / +41 文件</b>
      差异构成：新增 38 · 同名更新 3
      已扣减 1 个修复文件 / 2.796 KiB

📦 合计预估待同步：33.777 GiB / 43 文件 · 新增 38 · 同名更新 3

⏱ 已运行 22 分钟 · 🔗 运行日志
```

### 2.1 标签锚点行（多字段拼行必用）

一行要塞多个字段时（类型/时长/分辨率/编码…），**禁止无锚点的裸 " · " 串**——
整条消息读起来是一坨。每行用全角冒号标签打头作锚点（规格：/链路：/客户端：…），
动作行（如 ▶ 打开直链）段前空行与正文数据区隔。
实现参考：`emby.yml` 播放通知（`notify()`）。

```
🎬 五十度灰 (2015)
━━━━━━━━━━━━━━━━━━
规格：电影 · 2 小时 08 分 · 1080p · h264 · 5.5 GB
链路：⚡ 302直连 OneDrive · 直链剩余 40 分钟
客户端：94.177.131.137 · 起播 2.2 秒

▶ 打开直链

⏱ 已运行 38 分钟 · 🔗 运行日志
```

### 2.2 明细列表与分组

**三种分组场景，形态一致**（组头 + 条目树形）：

1. **长列表** —— 条目数可能很大（跳过、失败、待处理），必须按状态或原因分组，
   不得穷举裸文本；组头 `<b>原因</b> · N` + 条目 `<code>名称</code>` 树形。
2. **多套同类信息** —— 条目虽少但存在多套并列结构（如 SSH / RDP 两套入口凭据），
   按套分节（emoji 区分语义），否则平铺混排难以扫读；组头可不带计数。
   实现参考：`tailscale-windows.yml` 与 `openclaw.yml`（`🟢 … 已就绪`）。
3. **条目子树（附属明细）** —— 某条目自身还有附属明细（如任务预览的排除规则）且
   **条数 ≥2** 时，降为二层列表：组头 = `tree_sub` 前缀 + `标签 · N`，子条目再缩进
   2 格用 `├─/└─`（模式内末条 └─）；仅 1 条时并入子行（`标签：<code>…</code>`），不为
   单条扩树。子树会显著拉高通知，谨慎使用。

```
  ├─ <code>aliyundriveCrypt/backup</code> · <i>源端 …</i> · <b>+7.270 GiB / +2 文件</b>
  │   排除 · 2
  │     ├─ <code>notion/**</code>
  │     └─ <code>self-hosted_latest.tar.gz</code>
  └─ <code>wopan176Crypt/backup</code> · …
        排除 · N（末条目的子树前缀 8 空格 + ├─/└─）
```

   实现参考：`openlist/task_preview.sh`（`排除 · N` 子树）。

```
⚠️ 跳过/过滤文件
损坏 · 43
  ├─ <code>Sexy Young 1.mp4</code>
  ├─ <code>Sexy Young 2.mp4</code>
  └─ <i>还有 35 条…</i>
非视频 · 2
  ├─ <code>failed_videos.json</code>
  └─ <code>uploaded_videos.json</code>
```

- **每组上限 8 条**（`SKIP_DETAIL_MAX` 可调），超出折叠为 `还有 N 条…`：
  43 条损坏全列会刷屏，且容易顶到 4000 字符分片边界把收尾区切走。
  多组并列时（如去重明细）通知内**最多展示 8 组**，超出折叠为 `还有 N 组…`。
- **折叠行必须并入条目流再交给 `tree_lines`**，由它统一决定末条 ——
  单独补一行 `  └─ 还有 N 条…` 会造成双 `└─` 同级、层次混淆。
  文件类列表可直接用一站式助手 `tree_code_fold <多行> [max=8]`
  （真源 `telegram/tg_notify.sh`，逐行 `<code>转义</code>` + 折叠 + 树形一次完成）。
- **职责分层**：脚本层只输出结构化数据（如 `中文原因\t路径`），
  HTML 与树形一律交给 `tg_*` 助手；脚本侧自造标签是版式漂移的根源。
- 实现参考：`tg-channel/sync_to_tg.sh` 的 `_render_skipped_groups`。

> 踩坑：`tree_lines` **接收参数、不读 stdin**。
> `... | tree_lines` 会静默输出空条目（无报错），必须 `tree_lines "$var"`。

## 3. 收尾区（全库唯一收尾形态）

```
（空行）⏱ 已运行 <b>X 小时 Y 分</b> · 🔗 <a href="TG_RUN_URL">运行日志</a>
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
| `🥇 TOP 5` 等自造分节前缀混用 | — | 分节 emoji 与语义对齐：📍 进行中 / ✅ 完成 / ⏭️ 跳过 / ❌ 失败 / ⚠️ 警告 |
| 裸文本条目列表 | `not_video: failed_videos.json` | 按原因分组：组头 `<b>非视频</b> · 2` + `  ├─ <code>failed_videos.json</code>` |
| 英文原因/状态 token 直出 | `corrupt: xxx` | 用中文标签（损坏 / 非视频 / 重复） |
| 双 `└─` 同级 | 条目末尾 `└─` 后再补 `  └─ 还有 N 条…` | 折叠行并入条目流，由 `tree_lines` 统一决定末条 |
| 超长列表全量穷举 | 43 条损坏逐行列 | 每组上限 8 条 + `还有 N 条…`；多组并列最多展示 8 组 |
| 已 source 发送层仍 curl 直发 | `curl ... sendMessage \|\| { plain=$(...); curl ... }` | 一律 `send_tg "$msg"`（429 重试已内建；自造发送缺 429 处理，限流时通知消失） |
| 高精度浮点直出 | `起播 2.16068914 秒` | 一位小数：`起播 2.2 秒`（原始精度无意义，只碍扫读） |
| ISO 原始时间戳直出 | `时间：2026-09-05T11:34:19Z` | 人性化：`上次同步：2026-09-05 11:34 UTC · 15 小时前`（`date -d` 解析，失败保留原值） |

状态 emoji 语义（全库统一）：
`✅` 成功 / `⚠️` 部分失败 / `❌` 失败 / `⏭️` 跳过 / `🔄` 进行中 / `⏳` 待处理 / `⛔` 中断 / `🚨` 危险警告。

批次计数 emoji 字段表（进度面板批次历史行，**全字段恒显 + 定宽补零**；行宽 ≈42 全角，
手机折 2 行为既定取舍 —— 换取计数列竖向对齐）：
`❌#n` 状态+批次号 | `✅00` 成功 | `🔧00` 修复 | `❗33` 失败（不用 ❌，避免与状态撞形）|
`⏭️22` 跳过 | `♻️22` 已有（目标端已存在）—— 五计数 `%02d` 补零 | `⏱01:15` 耗时（mm:ss 补零）|
`⬆️4.79G` 上传量（GiB 两位小数，末列不补）。
状态: ✅全成 ⚠️部分失败 ❌失败 ⏭️整批跳过 ♻️整批已有。全部入史（MAX=6 滚动窗口，全量在运行日志）。
实现：`openlist/task_engine.sh` 批次历史行。

既定形态豁免（不算违例，勿"修复"）：
内容片长分钟补零 `2 小时 08 分`（条目内媒体时长，区别于收尾区无补零的
`X 小时 Y 分`）。

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
- 429 重试是发送层职责，调用方勿自造重复实现——
  已 `source` 发送层的通知点再 curl 直发属禁止事项（见 §4）。
- 媒体上传（`sendDocument`/`sendVideo` 等）不走 sendMessage 发送层（固有例外），
  但 caption 仍须转义、429 重试仍需自带（参考 `sync_notify.sh` 的 sendDocument 段）。
- **凭据/密码类消息**（如 OpenList 改密回执）**没有**特殊发送通道：用 `tg_add_*` 构建
  （密码走 `tg_add_path`，自动 `escape_html`）后照常 `send_tg`。
  不要为凭据自造「单发不重试不退化」的实现 —— 429 与 400 都表示上一条**没被 Telegram
  接收**，重试/退化不会产生两条密码；放弃重试反而会让凭据在限流时直接丢失。
  实现参考：`emby.yml` 的 OpenList 凭据通知。

## 6. 新增通知检查清单

- [ ] 标题 = emoji + 短语，计数/细节下沉 kv 行
- [ ] 分节计数 ` · N`；条目元数据 ` · <i>…</i>`；kv 行全角冒号
- [ ] 明细列表按状态/原因分组、树形列出，超长折叠（无裸文本、无双 `└─`）
- [ ] 脚本层只出结构化数据，HTML 与树形交给 `tg_*` 助手（不在脚本里拼标签）
- [ ] 收尾区经 `tg_add_footer`（bash）/ `tg_footer_line`（python），无手拼
- [ ] workflow 已注入 `TG_RUN_URL` / `TG_RUN_STARTED_AT`（job 或 step 级 env）
- [ ] 动态内容全部经转义助手；发送走 `send_tg` / `send_tg_chunked` / `notify()`
- [ ] 数值/时间戳已人性化：无原始高精度浮点、无 ISO 原始戳直出（见 §4）
- [ ] 进度面板批次行按 §4 字段 emoji 表（六计数 %02d 恒显 + ⏱mm:ss + ⬆️GiB）
- [ ] 相关测试同步更新（如 `openlist/tests/test_progress_final_title.sh`）

## 7. 回归测试守卫

`openlist/tests/` 现有 **17 个回归套件**——凡改动 `telegram/tg_notify.sh`（真源）/
`openlist/telegram.sh` / `task_engine.sh` 批次行 / 同步管线，全量跑通后再交付，
且全量日志 `command not found` 必须为零。与本规范直接相关的守卫点：

| 测试 | 守卫点 |
|---|---|
| `openlist/tests/test_progress_final_title.sh` | 收尾标题四态 + 状态行下沉 |
| `openlist/tests/test_preview_diff.sh` | 任务预览合计行/树形/排除子树/扣减子行 |
| `openlist/tests/test_progress_phase_layout.sh` | 进度面板无 ⏱ 尾 + 批次历史行 emoji 形态渲染 |
| `openlist/tests/test_skip_preview_hint.sh` | 跳过预览提示 |
| `openlist/tests/test_batch_precheck_circuit_breaker.sh` | 批次熔断分支（字段 emoji stub 在此） |
| `openlist/tests/test_method_id_naming.sh` | 修复方法 ID ↔ 中文标签映射 |
| `openlist/tests/test_hash_dir_fallback.sh` | 哈希目录兜底（含 fix_log 文案） |
| `openlist/tests/test_fix_log_section.sh` | fix_log 分节横幅 |

`tg-channel/sync_to_tg.sh`（ph-dl / 91 通知）**暂无测试套件**——
改动后靠本地渲染实测验证（提取函数 + 造模拟数据跑 `tree_lines` 输出对比）。
后续补测试时可参考上述 openlist 套件的 mock 方式（mock `tg_add_*` +
捕获 `send_telegram_message` 入参）。
