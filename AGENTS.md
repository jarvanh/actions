# AGENTS.md — Telegram 通知的 AI 操作入口

本仓库所有 Telegram 通知的**唯一规范**是 [`docs/telegram-notify.md`](docs/telegram-notify.md)。
本文件是给 AI 的**操作清单**：动通知代码前先看这里，版式细节一律以规范文档为准
（**不要**把规范全文复制到别处——两处维护必然漂移）。

## 1. 先读什么

| 要改什么 | 去规范文档哪里看 |
|---|---|
| 版式构件（标题/分节/kv/条目/块/收尾区） | 第 4 章「版式构件速查」 |
| 某类通知长什么样（约 30 类真实示例） | 第 3 章「通知种类索引」 |
| 设计原则与视觉层级 | 第 2 章 |
| 各类通知写法建议、常见偏差 | 第 5 章 |
| 发送/重试/转义的硬约束 | 第 6 章 |
| 改完怎么验证、哪些失败是基线 | 第 7 章 |
| 助手速查表、状态图标、批次行字段 | 第 8 章 |

改版式**先改规范文档，再改实现**。

## 2. 三条硬约束（违反会让通知消失或误判失败）

1. **发送层**：一律 HTML parse_mode，动态内容**必须**转义；
   400 `can't parse entities` **不重发**，直接报错并带响应体前 200 字符；
   429 按 `retry_after` 重试最多 5 次；长消息 4000 字符分片（断在换行处）。
   已 source 发送层的通知点**不得 curl 直发**——唯一例外是需要 message_id 的进度面板
   原地维护（`openlist/telegram.sh` 的 `_tg_send_and_get_id` / `_tg_delete_message`）。
   发送失败必须留痕，不要 `>/dev/null 2>&1` 吞掉；python 侧 `send_telegram` 返回字典，
   失败原因在 `reason` 里，调用方必须记日志。
2. **收尾区与接线**：每条通知都要有收尾区（`tg_add_footer` / `Get-TgFooter` /
   `tg_footer_line`），形态 `⏱ 已运行 X · 🔗 运行日志`；
   含通知的 workflow 必须在 job 或 step 级 env 注入
   `TG_RUN_URL` 与 `TG_RUN_STARTED_AT`。
3. **回归基线**：改动涉及 openlist 通知时跑 `openlist/tests/` 的 19 个套件
   （`bash test_x.sh </dev/null`，后台跑约 4 分钟）；
   全量日志 `command not found` **必须为零**；
   4 个本地已知失败按基线容忍（truth 依赖 docker、marker_skip 的 BSD `date -d`、
   sync_trend 的 macOS `wc`、no_orphans 的 T5 时序 flake），偏离这套基线才算回归。

## 3. 用助手构建，不要手拼 HTML

| 环境 | 真源 | 可用助手 |
|---|---|---|
| bash | `.github/scripts/telegram/tg_notify.sh` | `tg_add_title` / `section` / `kv` / `path` / `note` / `block` / `pre` / `footer`、`tg_entry` / `tg_entry_text` / `tg_add_entry` / `tg_add_entry_text` / `tg_entry_pair`（`→`）/ `tg_entry_codes`（`·`）/ `tg_add_entry_pair` / `tg_add_entry_codes`、`tree_conn` / `tree_sub` / `tree_lines` / `tree_code_fold`、`escape_html`、`send_tg` / `send_tg_chunked` |
| pwsh | `.github/scripts/telegram/tg_notify.ps1` | 对外四个：`Esc-Html` / `Get-TgFooter` / `Send-TgMessage` / `$TG_SEP`（内部还有 `Format-TgDuration` 供 `Get-TgFooter` 使用）。**没有 kv 与条目助手**，按第 4 章形态手拼，值一律 `Esc-Html` |
| python | `.github/scripts/proxy-speedtest/speedtest_common.py` | `tg_entry` / `tg_entry_pair` / `tg_entry_codes` / `tg_pre_block` / `tg_footer_line` / `tg_format_elapsed` / `send_telegram` / `send_telegram_chunked` / `TG_SEP` |

内嵌 python 段（如 `tg-channel/sync_to_tg.sh`）无法 import 共享层，
在**本文件内同义实现** `esc` / `tg_pre_block`，与共享层保持一致。

## 4. 版式速查（一句话规则）

- 全库**无 `<b>`、无 `<i>`**；只有 `<code>`（机器值）/ `<pre>`（日志命令块）/ `<a>`（链接）带标签。
- 条目一律 `├─/└─` 树形（`• ` 平铺不是全库形态，勿引入）。
- 分节后跟条目列表时带计数 ` · N`；跟 kv 行或单段说明时可不带。
- kv 用全角冒号；元数据放在 ` · ` 之后。
- **时长五层**（第 4.3 节的统一形态）：
  `X 小时 Y 分`（分钟不补零）／`X 分钟`／`X.XX 秒`（固定两位小数）／`X 毫秒`（不足 1 秒）／
  `⏱mm:ss`（进度面板列字段，为计数列对齐，与上面不是一套体系）。
  已知例外：测速节点指标串用紧凑 `NNms`（如 `35ms`），属指标字段而非时长表述。
- 空行只由这些地方产生：`tg_add_section` 段前、`tg_add_note` 段前、`tg_add_footer` 前，
  以及正文与动作行（如「▶ 打开直链」）之间由调用方补（先判断正文尾换行，避免双空行）。

## 5. 改通知的固定流程

1. 查规范第 3 章有没有同类通知示例 → 照抄形态（标题、kv 顺序、条目结构）。
2. 用真源助手构建，不手拼 HTML。
3. **渲染预览**：`source` 真源 + 构造数据打印消息，肉眼确认版式、空行、时长形态。
4. 跑相关测试 + openlist 19 套件（与基线比对、`command not found` 归零）。
5. 版式改动先改规范文档再改实现。

## 6. 高频踩坑（都踩过）

- **转义边界**：`tg_add_kv` / `path` / `note` / `title` 内部会 `escape_html`，**只能传纯文本**；
  要带 HTML 的片段走 `tg_add_block`（不转义）或先 `escape_html` 再用 `tg_append` 拼。
- **命令替换吃换行**：`$(tg_entry …)` 会吃掉尾换行，**累积多行列表用 `tg_add_entry`**。
- **macOS 限制**：没有 `date -d`，收尾区时长走 `/proc/1` 兜底，本机测不到带 `TG_RUN_STARTED_AT` 的分支。
- 测试必须 `</dev/null` 重定向 stdin，否则 `test_batch_precheck_circuit_breaker.sh` 会卡住。
- 批量替换标签/文案前先**穷尽式 grep** 出完整清单逐行甄别（窄模式抽样会漏），改完必须渲染预览复核。
- 文档写作偏好（改规范文档时同样适用）：
  只写「现在是怎样 + 为什么」，不写版本沿革/演变/「已废弃」；
  不设「豁免清单」这类集中列例外的结构，技术现状按主题分别说明；
  交叉引用用「第 N 章 / N.M 节」这类文字表述，不要使用章节符号。

## 7. 提交前自检

- [ ] 没有手拼 HTML（pwsh 除外），动态内容全部转义
- [ ] 收尾区齐全，`TG_RUN_URL` / `TG_RUN_STARTED_AT` 已注入
- [ ] 渲染预览看过，时长/条目/空行符合规范
- [ ] openlist 19 套件通过（与基线一致），`command not found` 为零
- [ ] 版式改动已同步到规范文档
