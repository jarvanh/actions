# Telegram 通知规范（全库唯一）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）统一遵守本文档。
**改版式先改这里，再同步各实现**；本文档是规范的唯一真源。

## 1. 实现真源

| 运行环境 | 真源 | 说明 |
|---|---|---|
| ubuntu runner（bash） | [`scripts/telegram/tg_notify.sh`](../.github/scripts/telegram/tg_notify.sh) | 排版助手 + 发送层（HTML 退化 / 429 重试 / 4000 分片 / curl `-m 15`），`source` 使用 |
| openlist docker 容器 | [`scripts/openlist/telegram.sh`](../.github/scripts/openlist/telegram.sh) | 排版助手 + 发送层同款（`send_tg` / `send_tg_chunked` / 降级链已对齐；容器内路径不同不跨目录 source），**与 tg_notify.sh 需同步维护** |
| python | `scripts/proxy-speedtest/speedtest_gitee.py` 的 `tg_format_elapsed` / `tg_footer_line` / `send_telegram_chunked` | 其余 python 一律复用或经 `notify()` 借 bash 生成，**禁止自造** |
| PowerShell（windows runner） | `rdp.yml` / `tailscale-windows.yml` 内联 `$footer` 构建 + `Send-TgMessage` | 形态与降级链必须与 bash 版逐字对齐（429 读 `Retry-After` 重试 5 次同语义） |

## 2. 版式模板

```
{emoji} <b>标题</b>              ← tg_add_title（emoji + 短语，副标题说明下沉 kv 行）
━━━━━━━━━━━━━━━━━━              ← TG_SEP（18 个全角横线，勿手写）

标签：<b>值</b>                  ← tg_add_kv（全角冒号，关键值加粗）
标签：<code>路径/命令</code>      ← tg_add_path（等宽展示）

{emoji} <b>分节 · N</b>          ← tg_add_section（段前空行；计数一律 " · N"）
📁 <b>组头</b> · <i>大小</i>      ← 分组列表：组头路径加粗
  ├─ <code>条目</code> · <i>备注</i>   ← tree_conn / tree_lines（末条 └─）
  │     子行                    ← tree_sub（末条目子行 6 空格）
  └─ <i>还有 N 条…</i>          ← 超长折叠行（并入条目流作末条，禁双 └─）

<pre>日志块</pre>                ← tg_add_block（需对齐的多行内容）
<i>备注说明</i>                  ← tg_add_note（段前空行）

（空行）⏱ 已运行 <b>X</b> · 🔗 <a href="URL">运行日志</a>   ← tg_add_footer
```

完整示例（`任务预览`）：

```
📋 任务预览 · emby
━━━━━━━━━━━━━━━━━━

📊 同步对 · 12
📁 onedrive:media → openlist:/media
  ├─ openlist:/media/a.mp4 · +300 B / +1 文件
  │     差异构成：新增 1 · 同名更新 1
  └─ openlist:/media/b.mp4 · 无变动

📦 合计预估待同步：900 B / 2 文件 · 新增 1 · 同名更新 1

⏱ 已运行 1 小时 12 分 · 🔗 运行日志
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

**两种分组场景，形态一致**（组头 + 条目树形）：

1. **长列表** —— 条目数可能很大（跳过、失败、待处理），必须按状态或原因分组，
   不得穷举裸文本；组头 `<b>原因</b> · N` + 条目 `<code>名称</code>` 树形。
2. **多套同类信息** —— 条目虽少但存在多套并列结构（如 SSH / RDP 两套入口凭据），
   按套分节（emoji 区分语义），否则平铺混排难以扫读；组头可不带计数。
   实现参考：`tailscale-windows.yml`（`🟢 Windows runner 已就绪`）。

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
  （tg_notify.sh：逐行 `<code>转义</code>` + 折叠 + 树形一次完成）。
- **职责分层**：脚本层只输出结构化数据（如 `中文原因\t路径`），
  HTML 与树形一律交给 `tg_*` 助手；脚本侧自造标签是版式漂移的根源。
- 实现参考：`telegram/sync_to_tg.sh` 的 `_render_skipped_groups`。

> 踩坑：`tree_lines` **接收参数、不读 stdin**。
> `... | tree_lines` 会静默输出空条目（无报错），必须 `tree_lines "$var"`。

## 3. 收尾区（全库唯一收尾形态）

```
（空行）⏱ 已运行 <b>X 小时 Y 分</b> · 🔗 <a href="TG_RUN_URL">运行日志</a>
```

- **时长三段式**：`≥1h → "X 小时 Y 分"`、`≥1min → "X 分钟"`、否则 `"X 秒"`。
  语义 = 当前时间 − `github.run_started_at`（run 已运行时长），**不是**步骤自身耗时
  （正文里单文件/单轮耗时可用 `耗时：N 秒` 等 kv 行表达，勿加 ⏱ 前缀冒充收尾）。
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
| 全角括号（计数或补充说明） | `⛔ 同步中断（13 个待处理、1 个失败）`、`域名（每次运行不变）`、`约 6 小时（超时自动结束）` | 计数下沉 kv 行；补充说明改 ` · <i>…</i>`：`域名：<code>x</code> · <i>固定不变</i>`、`约 6 小时 · 超时自动结束` |
| 英文紧凑时长进通知 | `⏱ 已运行 5h 57m`、`耗时: 12.34s` | `⏱ 已运行 5 小时 57 分`（紧凑格式仅允许进 RESULT_JSON artifacts） |
| 手拼收尾行 | `"\n\n⏱ 🔗 <a>运行日志</a>"` | 一律经 `tg_add_footer` / `tg_footer_line` |
| `⏱️`（带 VS16 变体） | `⏱️ 已用：…` | 裸 `⏱` + `已运行`（全库唯一写法） |
| 半角冒号 kv 行 | `📦 分组: xxx` | `📦 分组：xxx` |
| `🥇 TOP 5` 等自造分节前缀混用 | — | 分节 emoji 与语义对齐：📍 进行中 / ✅ 完成 / ⏭️ 跳过 / ❌ 失败 / ⚠️ 警告 |
| 裸文本条目列表 | `not_video: failed_videos.json` | 按原因分组：组头 `<b>非视频</b> · 2` + `  ├─ <code>failed_videos.json</code>` |
| 英文原因/状态 token 直出 | `corrupt: xxx` | 用中文标签（损坏 / 非视频 / 重复） |
| 双 `└─` 同级 | 条目末尾 `└─` 后再补 `  └─ 还有 N 条…` | 折叠行并入条目流，由 `tree_lines` 统一决定末条 |
| 超长列表全量穷举 | 43 条损坏逐行列 | 每组上限 8 条 + `还有 N 条…`；多组并列最多展示 8 组 |
| 已 source 发送层仍 curl 直发 | `curl ... sendMessage \|\| { plain=$(_tg_strip_html ...); curl ... }` | 一律 `send_tg "$msg"`（退化/429 重试已内建；自造退化链缺 429 处理，限流时通知消失） |
| 高精度浮点直出 | `起播 2.16068914 秒` | 一位小数：`起播 2.2 秒`（原始精度无意义，只碍扫读） |
| ISO 原始时间戳直出 | `时间：2026-09-05T11:34:19Z` | 人性化：`上次同步：2026-09-05 11:34 UTC · 15 小时前`（`date -d` 解析，失败保留原值） |

状态 emoji 语义（全库统一）：
`✅` 成功 / `⚠️` 部分失败 / `❌` 失败 / `⏭️` 跳过 / `🔄` 进行中 / `⏳` 待处理 / `⛔` 中断 / `🚨` 危险警告。

既定形态豁免（不算违例，勿"修复"）：
媒体标题年份半角括号 `五十度灰 (2015)`（媒体惯例）；内容片长分钟补零
`2 小时 08 分`（条目内媒体时长，区别于收尾区无补零的 `X 小时 Y 分`）。

## 5. 发送层要求

- **一律 HTML parse_mode**，动态内容必须转义（`escape_html` / `tg_*` 助手已内置）。
  > pwsh 侧注意：转义函数需自行定义（`Esc-Html`）。调用未定义函数是**终止错误**，
  > 若该 step 带 `continue-on-error: true`，表现为通知静默消失、不报失败
  > （`tailscale-windows.yml` 曾因此缺发入口通知）。加转义调用前先确认函数存在。
- HTML 解析失败（400 can't parse entities）→ 自动去标签退化纯文本重发：宁可样式变朴素，不让通知消失。
- 429 限流按 `retry_after` 等待重试；长消息按 4000 字符分片（断在换行处，不切 UTF-8 多字节）。
- 降级链（HTML 退化 + 429 重试）是发送层职责，调用方勿自造重复实现——
  已 `source` 发送层的通知点再 curl 直发属禁止事项（见 §4）。
- 媒体上传（`sendDocument`/`sendVideo` 等）不走 sendMessage 发送层（固有例外），
  但 caption 仍须转义、429 重试仍需自带（参考 `sync_notify.sh` 的 sendDocument 段）。
- 安全边界例外：凭据私信（如 openlist 改密）不走发送层，curl 直发且密码经实体转义、绝不落日志。

## 6. 新增通知检查清单

- [ ] 标题 = emoji + 短语，计数/细节下沉 kv 行，无全角括号
- [ ] 分节计数 ` · N`；条目元数据 ` · <i>…</i>`；kv 行全角冒号
- [ ] 明细列表按状态/原因分组、树形列出，超长折叠（无裸文本、无双 `└─`）
- [ ] 脚本层只出结构化数据，HTML 与树形交给 `tg_*` 助手（不在脚本里拼标签）
- [ ] 收尾区经 `tg_add_footer`（bash）/ `tg_footer_line`（python），无手拼
- [ ] workflow 已注入 `TG_RUN_URL` / `TG_RUN_STARTED_AT`（job 或 step 级 env）
- [ ] 动态内容全部经转义助手；发送走 `send_tg` / `send_tg_chunked` / `notify()`
- [ ] 相关测试同步更新（如 `openlist/tests/test_progress_final_title.sh`）

## 7. 回归测试守卫

| 测试 | 守卫点 |
|---|---|
| `openlist/tests/test_progress_final_title.sh` | 收尾标题四态 + 状态行下沉 |
| `openlist/tests/test_preview_diff.sh` | 任务预览合计行/树形/扣减子行 |
| `openlist/tests/test_progress_phase_layout.sh` | 进度面板无 ⏱ 尾（时长只从 footer 出） |
| `openlist/tests/test_skip_preview_hint.sh` | 跳过预览提示 |

`telegram/sync_to_tg.sh`（ph-dl / 91 通知）**暂无测试套件**——
改动后靠本地渲染实测验证（提取函数 + 造模拟数据跑 `tree_lines` 输出对比）。
后续补测试时可参考上述 openlist 套件的 mock 方式（mock `tg_add_*` +
捕获 `send_telegram_message` 入参）。
