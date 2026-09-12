# Telegram 通知版式核对清单

本文件是 SKILL.md 第 1、3、5 步的输入。所有行号与数字均为 2026-09-12 第五轮核对时的
实测值，**会随实现变化**——数字对不上时先怀疑数字腐化，回代码确认后再改本文件。

## 1. 机械扫描项（Grep 工具，path 显式传 `.github`）

| # | 扫描项 | 模式 | 期望结果 |
|---|---|---|---|
| 1 | 粗体/斜体 | `<b>\|</b>\|<i>\|</i>` | 零使用，仅注释提及 |
| 2 | 平铺条目 | `•` | 零使用，仅注释提及 |
| 3 | 半角冒号 kv | `[一-龥]:[^/:= ]` | 仅非通知代码（echo/grep 表达式） |
| 4 | 紧凑时长 / 高精度浮点 / ISO 直出 | `[0-9]+h ?[0-9]+m\|[0-9]\.[0-9]{4,} 秒\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}` | 仅注释、测试夹具、非通知数据 |
| 5 | curl 直发 | `curl .*(sendMessage\|/bot)` | 6 处 = 3 类：发送层自身（`tg_notify.sh:322/328`）、进度面板 message_id 与 deleteMessage（`openlist/telegram.sh:64/70/102`）、`sendDocument`（`sync_notify.sh:357`） |
| 6 | 分隔线 | `TG_SEP *=\|━━━` | 四套同值 18 条（bash 真源 / ps1 `0x2501*18` / python `'━'*18` / sync_to_tg 内嵌） |
| 7 | 收尾区覆盖 | 分别统计 `tg_add_title` 与 `tg_add_footer\|Get-TgFooter\|tg_footer_line` 的**按文件**计数 | 计数不等时逐个查是否「分支汇聚」或「注释」造成；每处标题分支都必须能走到 footer |
| 8 | 运行日志接线 | `TG_RUN_URL` 按文件列出 | 14 个 workflow，与「有通知集合」完全重合 |
| 9 | 树形/折叠调用点 | `tree_lines\|tree_fold\|tree_code_fold` | 逐个确认折叠口径（见第 3 节） |
| 10 | 分节计数 | `tg_add_section +[a-z_]+ +"[^"]*"` | 后跟列表的带 ` · N`；后跟 `<pre>` 或 kv 行的可不带 |

## 2. 四域判据（派 worker 时写进 prompt 的摘要）

- 标题 = `{emoji} 标题` + 18 条全角横线 ━，不空行
- 分节 `{emoji} 分节 · N`：后跟条目列表必须带计数
- kv 一律**全角冒号**；机器返回值（路径/文件名/IP/ISP/ASN/位置/域名/端口/密码/ID/
  命令/版本号/原始异常串）用 `<code>`，自然语言（原因/结论/状态/备注/有效期）裸文本
- **同一分节内口径必须一致**：一次查询返回的 IP/ISP/ASN/位置整节同为等宽；
  逐个判断会产出斑马纹，读者会当成版式 bug
- 条目一律 `├─/└─` 树形，元数据 ` · ` 跟在主体后
- 折叠看**清单性质**不只看条数：流水/日志类超 8 条折叠为「还有 N 条…」；
  结构性清单全量展示
- `tree_code_fold` 收裸文本、`tree_fold` 收已构建条目流，误用会二次转义
- 收尾区 `⏱ 已运行 X · 🔗 运行日志` 必须走 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`
- 时长五层：`X 小时 Y 分`（分钟不补零）/ `X 分钟` / `X.XX 秒` / `X 毫秒` / 面板 `⏱mm:ss`
- 动态内容必须转义，无豁免
- 空行只来自：section 段前、note 段前、footer 前、正文与动作行之间、多组列表组间
  （组间空行必须带「前面已有组」的条件，首组前不补）

## 3. 易误判为偏差、实为合规（每次核对最容易误报的地方）

| 写法 | 为什么合规 |
|---|---|
| 进度面板四组任务列表（待处理/已完成/已跳过/失败 + 进行中）不折叠 | 结构性清单：折掉后半段等于把「哪些任务没跑完」藏起来（`sync_progress.sh:476-478` 注释即此意） |
| `task_preview` 同步对、`task_engine` 子目录/批次统计不折叠 | 结构性清单，同 4.6 节判据 |
| `sync_to_tg.sh` 失败清单走 `tree_fold` | 流水类，与同通知「已上传」同口径 |
| `📍 测速点网络` 分节不带 ` · N` | taier/gitee 恒单目标，共享层有 count_hint 逻辑 |
| 后跟 `<pre>` 或 kv 行的分节不带计数 | 4.2 节允许 |
| emby 规格行 codec（h264）裸文本 | 一行多字段混排，单独套 `<code>` 会成斑马纹 |
| openclaw 两处归档告警标题不同 | 有意区分「归档告警」/「最终归档告警」，否则读者分不清轮次 |
| 媒体 caption 无标题/分隔线/收尾区 | 4.9 节固有例外，但必须转义 + 显式 parse_mode |
| 测速节点指标串里的 `35ms` | 指标字段（与 `↑`/`↓` 并排），非独立时长表述，不走「毫秒」层 |
| 标题数与 footer 数不等 | 多为分支汇聚（如 `github_backup_all.yml` 4:2）或注释造成的计数差 |

## 4. 回归基线（改动触及 openlist 域时必跑）

```bash
cd .github/scripts/openlist/tests
bash -c 'rm -f /tmp/x_*.log 2>/dev/null; for t in test_*.sh; do bash "$t" </dev/null > "/tmp/x_${t%.sh}.log" 2>&1; echo "$t EXIT=$?"; done'
grep -l "command not found" /tmp/x_*.log   # 必须为空（硬要求）
```

- 全量约 8–12 分钟，后台跑；**跑期间不要并发跑单个测试**。
- 判定基线：**17 套 EXIT=0** + 2 个已知失败：
  - `test_truth.sh`（依赖 docker / 真实 OpenList 服务）
  - `test_marker_skip_guards.sh` 1b（macOS BSD `date` 无 `-d`）
- `command not found` 扫描**必须为空**——套件 PASS 不等于通过。

### flake 名单（单独复跑确认后再下结论，别急着改代码）

- `test_progress_no_orphans.sh` T5「强杀路径有超时上限 <15s」：负载高即失败，
  实测全量跑时必现、单独复跑 `PASS=16 FAIL=0`
- `test_get_openlist_token_login.sh`：sandbox broker IPC `ETIMEDOUT`
- `test_batch_precheck_circuit_breaker.sh`：回归期间被并发跑过会出现假的
  `command not found`（共用 `tests/extracted.sh`）
