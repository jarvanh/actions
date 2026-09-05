# Telegram 通知规范（全库唯一）

全库所有 Telegram 通知（workflows 内联 + scripts 下各子系统）统一遵守本文档。
**改版式先改这里，再同步各实现**；本文档是规范的唯一真源。

## 1. 实现真源

| 运行环境 | 真源 | 说明 |
|---|---|---|
| ubuntu runner（bash） | [`scripts/telegram/tg_notify.sh`](../.github/scripts/telegram/tg_notify.sh) | 排版助手 + 发送层（HTML 退化 / 429 重试 / 4000 分片），`source` 使用 |
| openlist docker 容器 | [`scripts/openlist/telegram.sh`](../.github/scripts/openlist/telegram.sh) | 排版助手同款（容器内路径不同不跨目录 source），**与 tg_notify.sh 需同步维护** |
| python | `scripts/proxy-speedtest/speedtest_gitee.py` 的 `tg_format_elapsed` / `tg_footer_line` | 其余 python 一律复用或经 `notify()` 借 bash 生成，**禁止自造** |
| PowerShell（windows runner） | `rdp.yml` / `tailscale-windows.yml` 内联 `$footer` 构建 | 形态与降级链必须与 bash 版逐字对齐 |

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

## 3. 收尾区（全库唯一收尾形态）

```
（空行）⏱ 已运行 <b>X 小时 Y 分</b> · 🔗 <a href="TG_RUN_URL">运行日志</a>
```

- **时长三段式**：`≥1h → "X 小时 Y 分"`、`≥1min → "X 分钟"`、否则 `"X 秒"`。
  语义 = 当前时间 − `github.run_started_at`（run 已运行时长），**不是**步骤自身耗时
  （正文里单文件/单轮耗时可用 `耗时：N 秒` 等 kv 行表达，勿加 ⏱ 前缀冒充收尾）。
- **降级链**（必须逐字一致）：无 `TG_RUN_STARTED_AT` → 不显示时长；
  `TG_RUN_URL` 与时长皆无 → 整行跳过。
- **附加链接**：`tg_add_footer <var> ["标签" "URL"]...` → 追加 ` · 🔗 <a>标签</a>`。
- **环境变量接线**（workflow 侧注入，缺一 Impact 只影响时长）：

```yaml
env:
  TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
  TG_RUN_STARTED_AT: ${{ github.run_started_at }}
```

## 4. 禁止事项（历史踩坑，勿回退）

| 禁止 | 反例 | 正例 |
|---|---|---|
| 全角括号堆计数 | `⛔ 同步中断（13 个待处理、1 个失败）` | 标题 `⛔ 同步中断` + `状态：<b>待处理 13 · 失败 1</b>` |
| 英文紧凑时长进通知 | `⏱ 已运行 5h 57m`、`耗时: 12.34s` | `⏱ 已运行 5 小时 57 分`（紧凑格式仅允许进 RESULT_JSON artifacts） |
| 手拼收尾行 | `"\n\n⏱ 🔗 <a>运行日志</a>"` | 一律经 `tg_add_footer` / `tg_footer_line` |
| `⏱️`（带 VS16 变体） | `⏱️ 已用：…` | 裸 `⏱` + `已运行`（全库唯一写法） |
| 半角冒号 kv 行 | `📦 分组: xxx` | `📦 分组：xxx` |
| `🥇 TOP 5` 等自造分节前缀混用 | — | 分节 emoji 与语义对齐：📍 进行中 / ✅ 完成 / ⏭️ 跳过 / ❌ 失败 / ⚠️ 警告 |

状态 emoji 语义（全库统一）：
`✅` 成功 / `⚠️` 部分失败 / `❌` 失败 / `⏭️` 跳过 / `🔄` 进行中 / `⛔` 中断 / `🚨` 危险警告。

## 5. 发送层要求

- **一律 HTML parse_mode**，动态内容必须转义（`escape_html` / `tg_*` 助手已内置）。
- HTML 解析失败（400 can't parse entities）→ 自动去标签退化纯文本重发：宁可样式变朴素，不让通知消失。
- 429 限流按 `retry_after` 等待重试；长消息按 4000 字符分片（断在换行处，不切 UTF-8 多字节）。
- 安全边界例外：凭据私信（如 openlist 改密）不走发送层，curl 直发且密码经实体转义、绝不落日志。

## 6. 新增通知检查清单

- [ ] 标题 = emoji + 短语，计数/细节下沉 kv 行，无全角括号
- [ ] 分节计数 ` · N`；条目元数据 ` · <i>…</i>`；kv 行全角冒号
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
