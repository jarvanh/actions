# 通知构件速查

真源行号取自 2026-09-12 的版本，**改真源时同步更新本表**。bash 列漂过一次（`tg_notify.sh` 在 `TG_SEP` 与 `tg_add_title` 之间插过代码，其后整列偏 14 行，已修正）——核对方式：`grep -nE '^函数名\(\)' 真源`。

## 1. 三套实现对照

| 用途 | bash `tg_notify.sh` | pwsh `tg_notify.ps1` | python `speedtest_common.py` |
|---|---|---|---|
| 转义 | `escape_html` (L54) | `Esc-Html` (L17) | `html.escape` |
| 分隔线 18 条 | `TG_SEP` (L63) | `$TG_SEP` (L15) | `TG_SEP` (L560) |
| 标题 | `tg_add_title` (L86) | 手拼 | 手拼 |
| kv（裸文本值） | `tg_add_kv` (L92) | 手拼 | 手拼 |
| kv（机器值 `<code>`） | `tg_add_path` (L97) | 手拼 | 手拼 |
| 分节 | `tg_add_section` (L108) | 手拼 | 手拼 |
| 说明段 | `tg_add_note` (L119) | 手拼 | 手拼 |
| 多行块（原样） | `tg_add_block` (L129) | — | — |
| 多行块（`<pre>`） | `tg_add_pre` (L325) | — | `tg_pre_block` (L658) |
| 收尾区 | `tg_add_footer` (L147) | `Get-TgFooter` (L39) | `tg_footer_line` (L663) |
| 条目（单行，无尾换行） | `tg_entry` (L265) | — | `tg_entry` (L617) |
| 条目（累积，含尾换行） | `tg_add_entry` (L283) | — | 自己 join |
| 条目（文字主体） | `tg_entry_text` (L274) / `tg_add_entry_text` (L288) | — | `tg_entry(..., code=False)` |
| 条目（双机器值 `→`） | `tg_entry_pair` (L309) / `tg_add_entry_pair` (L313) | — | `tg_entry_pair` (L642) |
| 条目（双机器值 `·`） | `tg_entry_codes` (L311) / `tg_add_entry_codes` (L318) | — | `tg_entry_codes` (L650) |
| 树形前缀 | `tree_conn` (L194) / `tree_sub` (L201) | 手写 `  ├─ ` `  └─ ` | 手写 |
| 多行 → 树形 | `tree_lines` (L207) | — | — |
| 折叠（裸文本） | `tree_code_fold` (L225) | — | — |
| 折叠（已构建条目流） | `tree_fold` (L249) | — | — |
| 时长格式化 | `tg_add_footer` 内置 | `Format-TgDuration` (L23) | `tg_format_elapsed` (L599) |
| 发送 | `send_tg` (L373) / `send_tg_chunked` (L380) | `Send-TgMessage` (L61) | `send_telegram` (L507) / `send_telegram_chunked` (L565) |
| 原样追加（**不转义**） | `tg_append` (L80) | — | — |

pwsh 侧**只有 5 个成员**（`$TG_SEP` / `Esc-Html` / `Format-TgDuration` / `Get-TgFooter` / `Send-TgMessage`），没有第六个。全库 dot-source 它的只有 `rdp.yml:86` 与 `tailscale-windows.yml:119`。

## 2. bash 函数签名（易记错的部分）

```bash
tg_append      <变量名> <原始文本>          # 第一参是变量名不是值；不转义
tg_add_kv      <变量名> <标签> <值>          # 值转义，输出 "标签：值"
tg_add_path    <变量名> <标签> <值>          # 值转义 + <code>
tg_add_footer  <变量名> ["标签" "URL"]...    # 附加链接对
tg_entry       <主体> [元数据...]            # 单行，无尾换行
tg_add_entry   <变量名> <主体> [元数据...]    # 2 必填 + 变长元数据，追加一整行
tree_fold      <多行条目流> [上限=8]          # 只截断
tree_code_fold <多行裸文本> [上限=8]          # 转义 + <code> + 截断
```

- `tg_add_*` 的第一参都是**变量名**（内部 `printf -v` + `${!1}`），写 `tg_add_title "$msg"` 是错的。
- `tg_add_entry` 的主体收**裸文本**，内部才包 `<code>` 并转义。
- `tg_add_footer` 的附加链接只在 `TG_RUN_URL` 非空时才追加；两者都缺则整个收尾区跳过（`return 0`）。
- `send_tg` 空文本直接 `return 0`。`_tg_send_once` 返回 `2` 表示 HTML 解析失败（400，不重发）。

## 3. 折叠规则

两个助手按**输入**选，不可互换：

| 助手 | 输入 | 做什么 |
|---|---|---|
| `tree_code_fold` | 裸文本（未转义、无标签） | 逐行转义 + `<code>` + 超 8 条折叠 |
| `tree_fold` | 已由 `tg_add_entry` / `tg_entry` 构建的条目流 | **只**截断 + 加折叠行 |

折叠与否看**清单性质**，不是看长度：

| 清单性质 | 超 8 条 | 例 |
|---|---|---|
| 流水/日志类（单条价值低） | 折叠为「还有 N 条…」 | 已上传文件、删除的重复文件、排除规则、日志行 |
| 结构性清单（读者要逐条核对） | **全量展示** | `task_preview` 同步对、`task_engine` 子目录/批次统计、**进度面板四组任务列表** |

判据：折叠掉后半段会不会让读者误判。

`tree_fold` 只适用于**单行条目流**（一个输入行 = 一个完整条目）。带子行的二层列表（1 条目行 + N 行 `│ ` 子行）要由调用方按**条目**计数自行补折叠行——实例是 `task_preview.sh` 的条目子行与 `sync_marker.sh` 的方法摘要。子行只补一句话，**不要往里灌日志**（规范 · 说人话）——`sync_notify.sh` 的失败清单曾这么干，2026-09-12 已删。

折叠行并入条目流作末条（由 `tree_lines` 统一决定 `└─`），不要单独补一行造成双 `└─`。

## 4. 数值与时长格式

**时长五层**（规范 · 时长写法）：

| 形态 | 适用 | 例 |
|---|---|---|
| `X 小时 Y 分`（分钟不补零） | ≥ 1 小时 | `2 小时 8 分` |
| `X 分钟` | ≥ 1 分钟 | `20 分钟` |
| `X.XX 秒`（固定两位小数） | ≥ 1 秒 | `12.00 秒` |
| `X 毫秒`（整数） | < 1 秒 | `27 毫秒` |
| `⏱mm:ss`（定宽） | 进度面板批次行 | `⏱01:15` |

已知例外：测速指标串里的延迟用紧凑 `NNms`（要和 `↑`/`↓` 并排）。

**大小**：1024 进制 + 三位小数 + IEC 单位 → `1.150 GiB` / `800 MiB`。bash 侧唯一实现是通知真源 `tg_notify.sh` 的 `format_bytes`，source 真源后直接用；python 侧仍有两处同义实现（`add_uploaded_video.py`、`sync_to_tg.sh` 内嵌段），改口径时要同步。**不要用 `du -h` 的 `1G`，也不要输出裸字节。**

**日期**：`YYYY-MM-DD HH:MM UTC` + ` · N 小时前`（解析失败保留原值）。

**计数**：分节 ` · N`；中文化错误码写「退出码 45」而不是 `exit=45`。

## 5. 空行规则

只有这几处产生空行，其余不要手写 `\n\n`：

1. `tg_add_section` 段前（紧跟标题/分隔线或空消息时自动不补）
2. `tg_add_note` 段前
3. `tg_add_footer` 前
4. 正文与动作行之间（调用方补，先判断是否已有尾换行）
5. 多组列表的组与组之间——**必须带条件**：`[ "$_gi" -gt 0 ] && _out+=$'\n'`（首组之前补会多空行）

## 6. 状态图标语义

`✅` 成功 · `⚠️` 部分失败/警告 · `❌` 失败 · `⏭️` 跳过 · `🔄` 进行中 · `⏳` 待处理 · `⛔` 中断 · `🚨` 危险警告 · `🆘` 灾难恢复 · `📍` 进度面板当前阶段

图标要与结论一致：0 成功 / 中止 / 数据缺失时标题应降级。**不要自造** `⭐` `🥇` 之类前缀。

## 7. 回归基线（动到 openlist 域时）

```bash
cd .github/scripts/openlist/tests
for t in test_*.sh; do bash "$t" </dev/null > "/tmp/x_${t%.sh}.log" 2>&1; echo "$t EXIT=$?"; done
grep "command not found" /tmp/x_*.log   # 必须为空
```

判定基线：**17 个 EXIT=0** + 两个已知环境失败：`test_truth`（依赖 docker）、`test_marker_skip_guards` 1b（macOS BSD `date` 无 `-d`）。全量约 10 分钟，后台跑。

已知 flake（负载高时）：`test_progress_no_orphans`（时序断言）、`test_get_openlist_token_login`（sandbox IPC 超时）。**单独复跑确认再下结论，别急着改代码。**
