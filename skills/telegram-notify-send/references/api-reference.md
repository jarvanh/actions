# 通知构件速查

本文件只记**签名与易错点**。版式规则、折叠判据、时长 / 大小 / 日期口径、状态图标
一律以 [`docs/telegram-notify.md`](../../../docs/telegram-notify.md) 为唯一真源，本文不重复。

定位函数用 grep，不记行号（行号必漂）：

```bash
grep -nE '^(函数名)\(\)|^def 函数名|^function 函数名|\$?TG_SEP *=' 真源文件
```

## 1. 三套实现边界

| | bash `tg_notify.sh` | pwsh `tg_notify.ps1` | python `speedtest_common.py` |
|---|---|---|---|
| 适用 | Linux / macOS runner | Windows runner | python 脚本 |
| 排版助手 | 全套 `tg_add_*` / `tg_entry*` / `tree_*` | 无，全部手拼 | 返回字符串的镜像函数，自己 `join` |
| 大小 / 耗时 | `format_bytes` / `tg_format_ms` / `tg_format_duration` | `Format-TgDuration` | `tg_format_elapsed`；**无大小助手** |
| 发送 | `send_tg` / `send_tg_chunked`（可选 `tier`） | `Send-TgMessage <text> [tier]`，无分片 | `send_telegram` / `send_telegram_chunked`（可选 `tier`） |
| 分隔线 | `TG_SEP` | `$TG_SEP` | `TG_SEP` |
| 转义 | `escape_html` | `Esc-Html` | `html.escape` |

pwsh 只有 **5 个成员**：`$TG_SEP` / `Esc-Html` / `Format-TgDuration` / `Get-TgFooter` /
`Send-TgMessage`。全库 dot-source 它的只有 `rdp.yml` 与 `tailscale-windows.yml`。

## 2. bash 签名（易记错的部分）

```bash
tg_append      <变量名> <原始文本>          # 第一参是变量名不是值；不转义
tg_add_kv      <变量名> <标签> <值>          # 值转义，输出 "标签：值"
tg_add_path    <变量名> <标签> <值>          # 值转义 + <code>
tg_add_link    <变量名> <标签> <URL> <文本>   # <a href>，文本与 URL 都转义
tg_add_footer  <变量名> ["标签" "URL"]...    # 附加链接对
tg_entry       <主体> [元数据...]            # 单行，无尾换行
tg_add_entry   <变量名> <主体> [元数据...]    # 2 必填 + 变长元数据，追加一整行
tg_format_ms   <秒>                          # "27 毫秒" / "1.40 秒"；空或非法返回空
tree_fold      <多行条目流> [上限=8]          # 只截断
tree_code_fold <多行裸文本> [上限=8]          # 转义 + <code> + 截断
```

- `tg_add_*` 的第一参都是**变量名**（内部 `printf -v` + `${!1}`），写 `tg_add_title "$msg"` 是错的。
- `tg_add_entry` 的主体收**裸文本**，内部才包 `<code>` 并转义；预先包好会二次转义。
- `tg_add_footer` 必须对**已积累正文**的变量原地追加；附加链接只在 `TG_RUN_URL` 非空时追加。
- `send_tg` 空文本直接 `return 0`；`_tg_send_once` 返回 `2` 表示 HTML 解析失败（400，不重发）。

## 3. 两个折叠助手

| 助手 | 输入 | 做什么 |
|---|---|---|
| `tree_code_fold` | 裸文本（未转义、无标签） | 逐行转义 + `<code>` + 超上限折叠 |
| `tree_fold` | 已由 `tg_add_entry` / `tg_entry` 构建的条目流 | **只**截断 + 加折叠行 |

二者不可互换，误用会二次转义。折叠行并入条目流作末条（由 `tree_lines` 统一决定 `└─`），
不要单独补一行造成双 `└─`。折叠与否看清单性质（流水折叠、结构性全量），判据见规范 · 折叠行。

## 4. 高频坑

1. **二次转义**：对已含 `<code>` 的条目流用 `tree_code_fold` → `&` 变 `&amp;amp;`、整条 400。
2. **尾换行被吃掉**：`$(tg_entry …)` 不输出换行，命令替换还会吃掉它 → 累积多行用 `tg_add_entry`。
3. **footer 两步写法**：先接在空变量上再拼正文 → 空行丢失。
4. **函数体内 source 真源**：子 shell 只改自己的函数表，调用点对 `send_tg` 的覆写会被还原。
5. **`<pre>` 超长**：原始输出取尾部 1200 字节，用 `tg_tail_safe` / `tg_tail_file_safe`，
   不要裸 `tail -c`（会切断 UTF-8）。
6. **内嵌 python 段**：无法 import 共享层，用到的助手必须在本文件同义实现，漏实现会 `NameError`。
7. **pwsh 不自检**：dot-source 后必须 `Get-Command Send-TgMessage`，否则调用未定义函数会静默消失。
8. **python 兜底吞异常**：用 `notify_best_effort(stage, msg)`，不要 `except: pass`。

回归基线（openlist 域）见
[`telegram-notify-audit/references/audit-checklist.md`](../../telegram-notify-audit/references/audit-checklist.md)。
