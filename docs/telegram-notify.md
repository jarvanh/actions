# Telegram 通知规范（版式与发送规则）

全库所有 Telegram 通知的版式与发送规则以本文件为准。本文只写**规则与示例**，
不登记逐条通知——发送点、标题、档位用脚本现场枚举：

```bash
bash skills/telegram-notify-audit/scripts/list_notify.sh          # 全部发送点
bash skills/telegram-notify-audit/scripts/list_notify.sh openlist # 只看某个域
```

域级出口与档位路由见 [`telegram-notify-registry.md`](telegram-notify-registry.md)（下称「台账」）。
写新通信用 `skills/telegram-notify-send`，核对版式用 `skills/telegram-notify-audit`。

**硬约束只有四处**：规范 · 收尾区、规范 · 接线、规范 · 发送层要求、规范 · 验证与交付。
其余是「建议 + 为什么 + 反例」，没有先例可循时照着写即可。

**引用写主题名**（如「规范 · 折叠行」），不要写章节号——章节号会随文档重排失效。
改版式先改本文档、再同步实现，然后跑渲染预览与机械校验。新增 / 改名 / 下线单条通知
**不需要改任何文档**。

---

## 1. 原则

### 1.1 一条通知回答三个问题

**发生了什么 / 影响多大 / 我要做什么**

- 发生了什么 → 标题（emoji + 短语）+ 状态 kv
- 影响多大 → 计数与量化（失败 3 个 / 减少 100 GiB / 跳过 12 条）
- 我要做什么 → 复制即用命令、下一步说明、运行日志链接

### 1.2 视觉层级靠四种手段

| 手段 | 作用 |
|---|---|
| 分隔线（18 条 `━`） | 标题锚点 |
| 空行 | 段落边界（来源见规范 · 空行） |
| emoji | 语义与状态的彩色锚点 |
| 等宽 `<code>` | 「这段可以直接复制」的机器值 |

不使用 `<b>` / `<i>`：四种手段已给足区分度，`<i>` 对中文几乎看不出效果。

### 1.3 只有三种标签

| 标签 | 用在哪 |
|---|---|
| `<code>` | 机器值：路径、文件名、命令、密码、IP、ID、端口、版本、原始异常串 |
| `<pre>` | 多行块：日志、复制即用命令、异常栈 |
| `<a>` | 链接：运行日志、订阅源、播放直链、run 链接 |

其余一律裸文本，但动态内容必须转义（`& < >` 会触发 400，见规范 · 发送层要求）。

**取值行口径**：一条 `标签：值` 用等宽还是裸文本，只看**来源**——

| 值的来源 | 口径 | 例 |
|---|---|---|
| 机器返回（IP、ISP、ASN、位置、主机名、域名、版本、ID、端口、路径、文件名、命令、原始异常串） | `<code>` | `位置：<code>Tokyo, JP</code>` |
| 人写的结论（原因、状态、计数、时长、备注） | 裸文本 | `状态：部分失败` |

同一次查询返回的 IP / ISP / ASN / 位置属于同一批机器值，建议整节同为等宽；逐个判断
会产出「IP 等宽 → ISP 正体 → ASN 等宽」的斑马纹，读者只会当成版式 bug。

### 1.4 说人话，术语留日志

通知读者不一定是实现者。**读者要「看懂」的字段一律用日常说法**：

| 别写（内部机制） | 写成（人话） |
|---|---|
| 后端写熔断，未探测 | 存储端本轮整体故障，未试写 |
| 短哈希目录 / base64URL 目录 | 备用目录 / 编码目录 |
| 已重启容器复核 | 已复核确认 |

判据是「这句话给实现者排查用，还是给读者做判断用」：`rc=1`、`HTTP_CODE:200`、容器重启、
方法名一律留运行日志，通知只给结论与下一步。把日志原样搬进通知（尤其搬成条目子行）
会把一条通知撑成几十行、把结论埋进噪音。`<code>` 里的路径、命令、原始异常串照旧原样
输出，那是可复制可搜索的机器值。

---

## 2. 版式构件

每个构件给出形态、助手与要点；跨语言对照见规范 · 助手速查。

### 2.1 标题与分隔线

```
{emoji} 标题
━━━━━━━━━━━━━━━━━━
```

- 助手：`tg_add_title`；pwsh / python 用 `TG_SEP` 手拼。
- emoji + 短语，状态与细节下沉到 kv；标题后紧跟分隔线，不空行。
- 分隔线恒为 18 条全角横线；bash / pwsh / python / `sync_to_tg.sh` 内嵌四份同值，不要自造。
- 同一套流程被不同来源触发时，标题要能区分来源：`{emoji} {来源标签} · {原标题}`。
  标签由触发方经环境变量传入，留空时标题保持原样。现有实例：测速三套的
  `PROXY_SPEEDTEST_LABEL`（被 gistnodes 调用时传 `gist 节点`）。标签只拼主报告标题；
  ❌ / ⛔ 兜底标题不带 label。

### 2.2 kv 行

```
标签：值
```

- 助手：`tg_add_kv`（值自动转义）。
- 全角冒号；一行多字段用 ` · ` 连接，并以全角冒号标签打头作锚点（`规格：` / `链路：`），
  避免无锚点的裸 ` · ` 串。

### 2.3 机器值

```
路径：<code>/mnt/media/a.mp4</code>
```

- 助手：`tg_add_path`；需要可点击时用 `tg_add_link`。
- 路径 / 文件名 / 命令 / 密码 / IP / ID / 端口 / 原始异常串一律等宽。判据见规范 · 取值行口径。

### 2.4 分节

```
{emoji} 分节 · N
```

- 助手：`tg_add_section`（段前自动空行；紧跟分隔线时自动不空行）。
- **分节后跟条目列表时带计数 ` · N`**；后面是 kv 行、`<pre>` 或单段说明时可以不带。
- 反例：`❌ 失败清单`（后面 3 条条目却没有计数）。

### 2.5 条目与树形

```
  ├─ <code>video_a.mp4</code> · 1.700 GiB · 2160p
  └─ <code>video_b.mp4</code> · 重试修复失败
```

- 助手：`tg_entry`（单行）/ `tg_add_entry`（累积多行）；双机器值用 `tg_entry_pair`
  （`→` 替换关系）或 `tg_entry_codes`（`·` 并列）；树形由 `tree_lines` 统一决定末条 `└─`。
- 条目一律 `├─/└─` 树形，元数据 ` · ` 分隔、放在主体之后。反例：`• video_a.mp4` 平铺。
- `$(tg_entry …)` 不输出尾换行、命令替换还会吃掉它——**累积多行用 `tg_add_entry`**。
- 树形前缀统一包等宽 `<code>`（`<code>  ├─ </code>`）：正文是比例字体，裸前缀的竖线列
  必然错位；手拼前缀同样包 `<code>`。
- 二层列表：子行用 `tree_sub`，前缀宽度必须与 `tree_conn` 相等（各 5 字符），否则子行
  正文比条目正文右移一格。子行只补一句话，不搬日志。

### 2.6 折叠行

```
  └─ 还有 8 条…
```

- 两个助手按**输入**选，选错会二次转义：

  | 助手 | 输入 | 做什么 |
  |---|---|---|
  | `tree_code_fold` | 裸文本（未转义、无标签） | 逐行转义 + 套 `<code>` + 折叠 |
  | `tree_fold` | 已由 `tg_add_entry` / `tg_entry` 构建的条目流 | 只截断 + 加折叠行 |

- 折叠行并入条目流作末条，不要单独补一行造成双 `└─`。
- 折叠与否看**清单性质**：

  | 性质 | 超上限怎么办 | 例 |
  |---|---|---|
  | 流水 / 日志（单条价值低） | 折叠为「还有 N 条…」 | 已上传文件、重复文件、排除规则 |
  | 结构性（读者要逐条核对） | 全量展示 | 任务预览同步对、进度面板任务列表、批次统计、归档明细 |

  判据是「折叠掉后半段会不会让读者误判」，不是列表长不长。结构性清单很长时靠分节计数
  交代规模即可。
- 二层列表不在 `tree_fold` 适用范围内（它按行截断，会把子行切半）：由调用方按**条目**
  计数并自行补折叠行，折叠行仍并入条目流作末条。

### 2.7 多行块

```
<pre>gh workflow run openlist.yml -f run_mode=同步</pre>
```

- 助手：`tg_add_pre`（转义 + `<pre>` 包裹）；`tg_add_block` 只用于已含标签的片段。
- 日志、异常栈、复制即用命令用 `<pre>`；不要用它替代行内 `<code>`。
- 原始输出取**尾部 1200 字节**：bash 分片会在边界闭合标签，python 分片不闭合，超长
  `<pre>` 会跨分片破版；截短后两套口径都不用操心。

### 2.8 说明段

```
如确认无误，请手动触发 force_sync=true
```

- 助手：`tg_add_note`（段前自动空行；整段转义，**段内不能带 HTML 标签**）。

### 2.9 收尾区（硬要求）

```
⏱ 已运行 22 分钟 · 🔗 <a href="…">运行日志</a>
```

**所有通知都必须有收尾区**，唯一例外是媒体 caption（规范 · 媒体 caption）与常驻服务的
`🕒` 报告时刻形态。

- 必须用 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`，不要手拼；附加链接用
  `tg_add_footer <var> "标签" "URL"` 追加。
- 语义是 **run 已运行时长**，不是步骤自身耗时。降级链：`TG_RUN_STARTED_AT`（仅本地
  测试覆写）→ runner 开机时刻兜底 → 取不到则不显示时长；`TG_RUN_URL` 缺失则整行跳过。
- 常驻服务（无 run 上下文，如看板、网关哨兵、健康看门狗）的「已运行」会把主机开机
  时长误报成服务时长，收尾区固定为报告时刻 `🕒 2026-11-06 19:32（东八区）`。
  `🕒` 只用于此处，不与 `⏱` 混用。

**接线（硬要求）**：发通知的 step 必须注入 `TG_RUN_URL`：

```yaml
env:
  TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

- **不要注入 `TG_RUN_STARTED_AT`**：`github` 上下文没有该属性，求值恒为空串，属死配置。
- 配合 `if: ${{ always() }}`，否则任务失败时反而收不到通知。
- 通知写在业务步末尾、失败就走不到时，按场景决定是否拆独立 step：

  | 场景 | 处理 |
  |---|---|
  | 只依赖落盘产物（`/tmp/*.note`、状态文件） | 拆成独立 step，读文件重建消息 |
  | 依赖同一 shell 的运行时变量 | 业务步内加失败兜底分支，不拆 |
  | 语义是「服务/监听已就绪」 | 不拆（启动失败时发「已就绪」是错的） |
  | 长驻循环内的逐事件通知 | 不拆（循环没起来就没有事件） |

反例：给整个业务 step 加 `if: always()` 让它失败后重跑——挂载失败了还照常跑下载 / 去重。

### 2.10 空行的来源

只有这几处产生空行，其余不要手写 `\n\n`：

1. `tg_add_section` 段前
2. `tg_add_note` 段前
3. `tg_add_footer` 前
4. 正文与动作行之间（调用方补，先判断是否已有尾换行）
5. 多组列表的组与组之间（唯一允许手写的空行，**必须带条件**：只在前面已有组时补）

分隔线与紧随其后的内容之间不空行。

---

## 3. 通知形态

写新通知时先判断属于哪类，照示例与要点来；具体某个线上通知长什么样，用脚本枚举。

| 形态 | 典型场景 | 要点 |
|---|---|---|
| 结果通知 | 备份 / 同步 / 测速 / 分卷等收尾 | 标题 emoji 随结论降级，多分支共用一条发送出口 |
| 清单明细 | 已同步文件、失败清单、账号池 | 流水类折叠、结构性清单不折叠 |
| 复制即用命令块 | 跳过通知给 force_sync、还原入口 | 分节 + 说明段 + `<pre>` 命令块 |
| 失败与异常兜底 | 未捕获异常、信号终止、可控失败 | 极简形态，必须留痕，先恢复环境再发 |
| 告警通知 | 归档失败、网关启动失败、存储失效 | 对象机器值 + 结论原因裸文本 + `<pre>` |
| 入口与凭据 | Runner 就绪推 SSH / RDP / 出口网络、改密回执 | 按套分节，整节同为等宽机器值 |
| 进度面板 | openlist 同步进度原地刷新 | 唯一需要 message_id 的场景 |
| 生命周期播报 | 交接五态、停机倒计时、新 run 启动 | 标题写阶段，kv 说服务是否可用与预计时间；普通档 |
| 常驻服务报告 | 健康看门狗、看板、网关哨兵 | 无 run 上下文，收尾区用 `🕒` 报告时刻 |
| 带动作行 | 播放通知的「▶ 打开直链」 | 正文与动作行之间补一个空行 |
| 媒体 caption | 随视频发出的说明 | 无标题 / 分隔线 / 收尾区 |

### 3.1 结果通知

顺序：**标题（状态 emoji）→ 关键 kv（对象 / 状态 / 计数）→ 明细分节 → 收尾区**。
状态与结论下沉到 kv，标题只说「谁 + 怎么了」。

```bash
case "$STATUS" in
  cancelled) tg_add_title msg "⛔ 任务已中断"
             tg_add_note  msg "任务被取消，数据未受影响；如需继续请重新运行。"
             tg_add_footer msg; send_tg "$msg"; exit 0 ;;   # 提前返回，避免二次追加
  success)   tg_add_title msg "✅ 备份成功"; tg_add_kv msg "状态" "完成" ;;
  *)         tg_add_title msg "❌ 备份失败"; tg_add_kv msg "状态" "失败" ;;
esac
tg_add_footer msg
send_tg "$msg" || echo "::warning::TG 通知发送失败（不影响任务）"
```

```
✅ 备份成功
━━━━━━━━━━━━━━━━━━
日期：2026-09-10
文件：<code>backup.tar.gz</code>
大小：1.150 GiB
状态：完成

⏱ 已运行 18 分钟 · 🔗 运行日志
```

要点：状态图标随结论降级（0 成功、数据缺失、中止 → ⚠️ / ❌，不要恒 ✅）；降级依据是
**本轮发生的事**，不是历史累计数（累计数放 kv 并标注「（累计）」）；发送失败用
`|| echo "::warning::…"` 或 `|| true` 留痕，不要吞掉。

### 3.2 清单明细

先按状态或原因**分组**（组头 + 计数），再树形列出：

```
📋 处理结果 · 3
📁 onedrive:media
  ├─ <code>电影/A.mkv</code> · 3.100 GiB
  └─ <code>电影/B.mkv</code> · 800.000 MiB

📁 onedrive:backup
    ├─ <code>aliyundriveCrypt/backup</code> · 源端 36.065 GiB / 1415 文件 · +7.268 GiB / +2 文件
    │  差异构成：新增 1 · 同名更新 1
    └─ <code>aliyundriveCrypt/media</code> · 无变动
```

- 流水类每组上限 8 条，超出折叠；结构性清单不折叠（规范 · 折叠行）。
- 二层列表子行只补一句话，不搬日志；失败清单**不挂子行**，原因写进条目元数据。
- **空清单整段跳过**，不要渲染 `✅ 已处理 · 0`；零计数分节用 `if [ "$n" -gt 0 ]` 包起来。

### 3.3 复制即用命令块

给人**可复制执行的命令**，不是数据文件路径（marker / JSON 人读不懂）。固定形态是
「分节 + 描述说明段 + 命令块」，多条命令重复这一组：

```
🛠️ 复制即用

▸ 强制同步（全量，含本任务）
<pre>gh workflow run openlist.yml -f run_mode=同步 -f force_sync=true</pre>
```

参数值要按实际匹配逻辑核实（例如 `restore_task` 按 marker 文件名首个 `_` 前缀匹配，
填完整任务名反而匹配不到）。多行命令用 `\` 续行，整块可直接复制。

### 3.4 失败与异常

- 阶段或原因写清楚；原始异常串用 `<code>`；多行日志用 `<pre>`（尾部 1200 字节）。
- 错误码中文化：`退出码 45` 而不是 `exit=45`。
- 给出下一步（复制即用命令，或「见运行日志」）。

```
❌ 下载失败
━━━━━━━━━━━━━━━━━━
文件：<code>video_a.mp4</code>
耗时：12.34 秒

📄 rclone stderr
<pre>ERROR : Failed to copy: connection reset</pre>

请检查源端可用性后重跑本任务。

⏱ 已运行 5 分钟 · 🔗 运行日志
```

异常与信号兜底可以极简（标题 + 原因 + 收尾区）：

```
❌ 泰尔三网测速异常退出 · 环境准备失败
━━━━━━━━━━━━━━━━━━
原因：<code>TUN 启动超时：mihomo 未在 30 秒内就绪</code>

⏱ 已运行 1 分钟 · 🔗 运行日志
```

- 兜底分支**必须留痕**：python 统一走 `notify_best_effort(stage, msg)`；直接
  `send_telegram(...)` 后 `except: pass` 会同时吞掉异常和返回值。
- 发送前先恢复环境（如先撤 TUN 再发），否则连 API 都送不出去。

### 3.5 告警通知

形态固定为「对象（机器值）+ 结论 / 原因（裸文本）+ 原始输出（`<pre>` 分节）」：

```
⚠️ 归档告警 · OpenClaw 主包
━━━━━━━━━━━━━━━━━━
对象：<code>openclaw.tar.gz</code>
结论：上传失败 · 退出码 2
原因：rclone 上传失败
Run ID：<code>12345678</code>

🧾 原始输出
<pre>2026/09/12 09:00:00 ERROR : Failed to copy: connection reset</pre>

⏱ 已运行 41 分钟 · 🔗 运行日志
```

分节后跟 `<pre>` 时**不带** ` · N`；`<pre>` 是正文最后一块，其后只跟收尾区。

### 3.6 入口与凭据

按套分节（SSH / RDP / 出口网络），每套内的取值行**整节同为 `标签：<code>值</code>`**；
有效期与共用说明是自然语言，走说明段。

```
🟢 Windows runner 已就绪
━━━━━━━━━━━━━━━━━━
🔐 SSH · 3
  ├─ 命令：<code>ssh runner@example.ts.net</code>
  ├─ 域名：<code>runner.example.ts.net</code>
  └─ 备用 IP：<code>100.64.0.1</code>

🖥️ RDP · 3
  ├─ 地址：<code>runner.example.ts.net:3389</code>
  ├─ 用户：<code>runner</code>
  └─ 密码：<code>********</code>

🌐 出口网络 · 3
  ├─ 出口 IP：<code>203.0.113.7</code> · ISP：<code>Contoso</code>
  └─ 位置：<code>Tokyo, JP</code>

有效期：约 6 小时 · 超时自动结束

⏱ 已运行 2 分钟 · 🔗 运行日志
```

分节 emoji 不要与标题 emoji 重复。凭据通知**没有特殊发送通道**：照样用 `tg_add_path`
构建（自动等宽 + 转义）再发，不要自造「单发不重试」——429 / 400 都意味着上一条没被
Telegram 收到，放弃重试只会让凭据丢失。

### 3.7 进度面板（原地刷新）

- 标题：刷新态 `🔄 同步进度`；终态按严重度——`⛔ 同步中断`（注册前即死）>
  `⏸️ 同步轮次收摊`（预算到站 / 撞 6h，剩余下轮接力）> `⚠️ 同步完成`（有失败）>
  `✅ 同步全部完成`。收摊排在失败之前：收摊伴生的失败只是「没跑完」的副产物。
- 五组任务列表（进行中 / 待处理 / 已完成 / 已跳过 / 失败）**全量展示不折叠**。
- 阶段行与批次历史行整行用 `<code>` 包裹（计数列要对齐）；这是面板特有的取舍。
- 时长只从收尾区出。

```
⏸️ 同步轮次收摊
━━━━━━━━━━━━━━━━━━
状态：待处理 4 · 进行中未执行完 2 · 失败 1
📊 总 12 · 待处理 4 · 进行中 2 · 完成 5 · 跳过 0 · 失败 1

时间预算到站，剩余任务下轮自动接力

🔄 进行中 · 2
  ├─ <code>onedrive:media/电影</code> · 3.100 GiB / 12 文件
  └─ <code>onedrive:media/剧集</code> · 800.000 MiB / 5 文件

⏱ 已运行 45 分钟 · 🔗 运行日志
```

面板是**唯一需要 message_id 的场景**（删旧 + 发新），也是唯一需要直连 sendMessage API
的地方；并发刷新用锁串行化，否则会产生孤儿面板消息。

### 3.8 带动作行的通知

正文与动作行（如「▶ 打开直链」）之间补一个空行，**先判断正文是否已有尾换行**，避免
产出双空行。

### 3.9 媒体 caption

随视频发出的 caption：**没有标题、分隔线、收尾区**，三行依次为文件名 / 大小 / 修改时间
（东八区），分片场景中间行写 `part 2/3 (800.000 MiB)`：

```
video_2026.mp4
1.150 GiB
2026-09-10 08:12
```

它不走 sendMessage 发送层（媒体上传固有例外），但同样**必须转义并显式 HTML
parse_mode**；429 重试与发送层同口径（最多 5 次）。`sendDocument` 发送日志文件同理，
caption 用单行 `📁 任务 · 错误日志`。

---

### 3.10 生命周期播报

交接、停机、接力这类「过程状态」通知：标题写阶段，kv 只回答**现在能不能用 / 还要多久**，
不重复实现细节。

```
🤝 OpenClaw 交接 · 准备中
━━━━━━━━━━━━━━━━━━
阶段：继任者已启动，正在恢复基座并预热链路
预计交出：约 12 分钟后

此阶段服务完全在线，可正常使用；停机会在交出前单独提示。

⏱ 已运行 3 小时 20 分 · 🔗 运行日志
```

- 阶段推进用不同 emoji（🤝 准备 / ✅ 就绪 / ⏳ 已交出 / 🚀 入口恢复 / 🏁 全部完成），
  同一条通知内不复用。
- 「服务是否可用」必须写清楚：可用 / 下线窗口 / 已恢复。
- 预计时间用「约 N 分钟后」，已发生用 `tg_format_ms`；不要混用。

### 3.11 常驻服务报告

无 run 上下文的常驻服务（健康看门狗、看板、网关哨兵）没有「已运行」语义，收尾区固定为
报告时刻：

```
✅ 系统健康正常
━━━━━━━━━━━━━━━━━━
主机：<code>runner-01</code>

全部检查项通过

🕒 2026-11-06 19:32（东八区）
```

- `🕒` 只用于这里，不与 `⏱` 混用。
- 报告时刻用东八区，格式 `YYYY-MM-DD HH:MM（东八区）`。
- 恢复通知与故障通知分开发；故障 alert、恢复普通（见台账）。

## 4. 表达约定

### 4.1 时长

全库统一五层，按量级选：

| # | 形态 | 适用 | 示例 |
|---|---|---|---|
| 1 | `X 小时 Y 分`（分钟不补零） | ≥ 1 小时 | `2 小时 8 分`、`1 小时 0 分` |
| 2 | `X 分钟` | ≥ 1 分钟 | `20 分钟`、`45 分钟` |
| 3 | `X.XX 秒`（两位小数） | ≥ 1 秒 | `12.34 秒`、`59.00 秒` |
| 4 | `X 毫秒`（整数） | < 1 秒 | `27 毫秒`、`340 毫秒` |
| 5 | `⏱mm:ss`（定宽） | 面板批次行 | `⏱01:15` |

- 第 1–3 层由三套收尾区实现，逐字一致；正文单条耗时（毫秒 / 秒双档）用 `tg_format_ms`。
- 正文需要三段式时长（如趋势的「历时」）用 `tg_format_duration`（bash）/
  `tg_format_elapsed`（python），不要自造同义实现。
- 第 3 层固定两位小数（整数秒写 `12.00 秒`）；第 4 层专用于 < 1 秒，避免退化成
  `0.00 秒`；第 5 层只用于面板对齐。
- 修饰语前置：`约 15 分钟`、`3 小时内`、`3 小时前`。
- 例外：测速指标串（`↑42兆 ↓58兆 35ms`）的延迟用紧凑 `NNms`，与 `↑` / `↓` 并排。

### 4.2 大小

1024 进制 + 三位小数 + IEC 单位：`1.150 GiB`、`800.000 MiB`、`12.000 KiB`。
不要 `du -h` 的 `1G`，也不要裸字节。

- **例外**：进度面板批次行用紧凑 `4.79G`（定宽对齐、不走 `format_bytes`），只此一处。
- bash 侧唯一实现：真源 `format_bytes`（source 真源后直接用）。
- python 侧两份同口径 `human_size`：`sync_to_tg.sh` 内嵌（进入通知）与
  `add_uploaded_video.py`（只写台账 / 日志）。改口径要同步。
- openlist 的 `format_bytes_iec` 与 workflow 内联 `numfmt` **只进日志 / env，不进通知**。

### 4.3 日期与相对时间

`YYYY-MM-DD HH:MM（东八区）` + ` · N 小时前`（解析失败写「未知」，原始值只留日志）：

```
时间：2026-09-07 19:34（东八区） · 3 小时前
```

不要直出 ISO 时间戳，也不要写 UTC：**展示时间一律东八区**。机器值（marker / JSON /
日志 / run 时间戳）仍按 UTC 存，两者不要混用。

### 4.4 计数与量化

- 分节计数：`{emoji} 分节 · N`。
- 影响写进 kv：失败 3 个 / 减少 100 GiB / 跳过 12 条。
- 错误码中文化：`退出码 45` 而不是 `exit=45`。
- 文件数行：`源端 X / 目标 Y` 恒定；源端比目标多时前置 `差异 N · `，目标端更多时不前置
  （会渲染出负数的「差异 -1」）；两端一致写 `X · 一致`。
- 面板批次行定宽：`✅00 🔧00 ❗33 ⏭️22 ♻️22 ⏱01:15 ⬆️4.79G`（计数补零、上传量 GiB
  两位小数、最近 6 条滚动）。

### 4.5 状态图标语义

| 图标 | 语义 |
|---|---|
| `✅` | 成功 / 恢复边沿 |
| `🟢` | 服务就绪（网关 / runner 入口类主标题） |
| `⚠️` | 部分失败 / 警告 / 降级但可用 |
| `❌` | 失败 |
| `🔴` | 需人工解封（上游风控停用账号池） |
| `🟠` | 需人工介入（介于警告与失败之间） |
| `🟡` | 降级但服务在（通道缺失 / 额度耗尽，等即可） |
| `⛔` | 中断（注册前即死） |
| `⏸️` | 轮次收摊（预算到站，预期内，只用于同步面板终态） |
| `⏭️` | 跳过 |
| `⏳` | 待处理 |
| `🔄` | 进行中 / 接力启动 |
| `🚨` | 危险警告 |
| `🆘` | 灾难恢复 |
| `📍` | 进度面板当前阶段 |
| `🚫` | 本轮中止（预期内收尾，如配额预检不通过） |
| `🧯` | 自动接力熔断（需手动 dispatch 恢复） |
| `🧹` | 清理类（残留文件 / 频道清理） |
| `🕒` | 报告时刻（只用于常驻服务收尾区） |

这张表只定义**状态语义**。域图标（📺 频道、🎬 播放、🔍 去重、☁️ iCloud、🗑️ 损坏、
🏁 交接完成等）由各域自定、不登记，只要求与结论不矛盾、同一条通知里不让同一个 emoji
承担两种角色。不要用 `⭐` / `🥇` 这类无状态含义的前缀。

---

## 5. 实现与接线

### 5.1 选哪套

| 场景 | 用哪套 | 有什么 / 没什么 |
|---|---|---|
| Linux / macOS runner 的 bash step | `telegram/tg_notify.sh` | 助手最全：排版、条目、树形、折叠、收尾、日志截断、发送（含分片） |
| Windows runner（pwsh） | `telegram/tg_notify.ps1` | **只有** `$TG_SEP` / `Esc-Html` / `Format-TgDuration` / `Get-TgFooter` / `Send-TgMessage`；无 kv / 条目助手、无分片 |
| python 脚本 | `proxy-speedtest/speedtest_common.py` | 镜像函数（返回字符串，自己 join）、发送与分片、`TG_SEP`、时间换算；无 `tg_add_*`、无大小助手 |
| bash 内嵌 python 段 | 无法 import 共享层 | 在本文件内同义实现用到的助手 |

### 5.2 接线（硬要求）

每个发通知的 step 都需要：

```yaml
      - name: "Notify: xxx 结果"
        if: ${{ always() }}
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
          # 只有 alert 档通知才需要下面两行
          TELEGRAM_BOT_TOKEN_ALERT: ${{ secrets.TELEGRAM_BOT_TOKEN_ALERT }}
          TELEGRAM_CHAT_ID_ALERT: ${{ secrets.TELEGRAM_CHAT_ID_ALERT }}
          TG_RUN_URL: https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }}
```

- 只注入 `TG_RUN_URL`；`TG_RUN_STARTED_AT` 不要注入。
- 凭据校验在**调用方**、放在 source 之前：`if [ -z "$TELEGRAM_BOT_TOKEN" ] … exit 0`。
  只适用于「整个 step 没凭据就什么都不该发」；**alert 档凭据缺失不要加静默守卫**——
  发送层的「缺失即失败留痕」是故意的。
- alert 档由调用点显式声明：`send_tg "$msg" alert` / `send_tg_chunked "$msg" alert` /
  `send_telegram_message "$msg" HTML alert` / `send_telegram(env, text, 'alert')`。
  发送层不按标题匹配，档位清单见台账。
- bash 真源兼容历史名 `TG_BOT_TOKEN` / `TG_CHAT_ID`；pwsh 没有这层回退。
- python 侧凭据从传入 `env` 读，但 `TG_RUN_URL` 只读 `os.environ`。
- pwsh step 要 `shell: pwsh`，dot-source 后加 `Get-Command Send-TgMessage` 自检——
  调用未定义函数是终止错误，带 `continue-on-error` 时表现为通知静默消失。

### 5.3 助手速查

| 用途 | bash 真源 | pwsh | python |
|---|---|---|---|
| 标题 / 分节 | `tg_add_title` / `tg_add_section` | `$TG_SEP` 手拼 | 手拼 + `TG_SEP` |
| kv / 机器值 | `tg_add_kv` / `tg_add_path` | 手拼 | 手拼 |
| 链接 | `tg_add_link` | 手拼 `<a>` | 手拼 |
| 条目（单主体） | `tg_entry` / `tg_add_entry` | — | `tg_entry(subject, *meta)` |
| 条目（文字主体） | `tg_entry_text` / `tg_add_entry_text` | — | `tg_entry(..., code=False)` |
| 条目（双机器值 `→`） | `tg_entry_pair` / `tg_add_entry_pair` | — | `tg_entry_pair(a, b, *meta)` |
| 条目（双机器值 `·`） | `tg_entry_codes` / `tg_add_entry_codes` | — | `tg_entry_codes(a, b, *meta)` |
| 多行块 | `tg_add_pre`；已含标签的片段用 `tg_add_block` | — | `tg_pre_block(text)` |
| 说明段 | `tg_add_note` | 手拼 | 手拼 |
| 树形 / 折叠 | `tree_conn` `tree_sub` `tree_lines` `tree_code_fold`（裸文本）/ `tree_fold`（条目流）；前缀自带 `<code>` | 手拼（前缀同样包 `<code>`） | 手拼（同左） |
| 大小格式化 | `format_bytes` | 手算 | 无共享函数：`sync_to_tg.sh` 内嵌 `human_size` 同口径 |
| 耗时（正文单条） | `tg_format_ms` | — | — |
| 时长三段式 | `tg_format_duration` | `Format-TgDuration` | `tg_format_elapsed` |
| 日志尾部安全截断 | `tg_tail_safe` / `tg_tail_file_safe` | — | — |
| 日期换算（东八区） | `TZ=Asia/Shanghai date` | 手拼 | `tg_format_time_bj` |
| 转义 | `escape_html` | `Esc-Html` | `html.escape` |
| 收尾 | `tg_add_footer` | `Get-TgFooter` | `tg_footer_line` |
| 发送 | `send_tg` / `send_tg_chunked` | `Send-TgMessage`（无分片） | `send_telegram` / `send_telegram_chunked` |
| 原始追加（不转义） | `tg_append` | — | — |

`tg_add_*` 的第一参是**变量名**。`tg_add_entry` 收裸主体，内部才包 `<code>` 并转义——
预先包好再传会二次转义。

### 5.4 内嵌 python 段

bash 里 `python3 - <<'PY'` 无法 import 共享层，用到的助手必须在本文件内同义实现，且与
共享层逐字一致。漏实现会 `NameError` → 脚本提前退出 → 连整轮汇总通知一起丢，代码审查
很难看出来，改完务必实跑一次。

### 5.5 通知函数的正确接法

**真源只在顶层 source 一次。** 函数体可能在子 shell 里执行（`m=$(fn)`、`fn | …`、
`fn &`），子 shell 内 `source` 只改子 shell 的函数表：调用点对 `send_tg` 的本地覆写会被
还原成真发，`local` 也不隔离。

```bash
source "${GITHUB_WORKSPACE}/.github/scripts/telegram/tg_notify.sh"   # step 顶层，一次

wb_notify() {                    # 函数体只用助手，不再 source
  local _msg=""
  tg_add_title _msg "$1"
  send_tg "$_msg" || echo "::warning::TG 通知发送失败（不影响任务）"
}
```

**长跑接力去重**：同一份 service 被接力 run 反复启动时，默认只在首轮推「已就绪」，
用 `/tmp` 标记文件区分首轮与接力轮（runner 生命周期内有效）；标记文件只在服务真的起来
时写。**例外**：某服务被明确要求每轮都发时（当前只有 workbuddy-gateway），要在该域文档
与调用点写明，不要文档写「只发首轮」、代码却在每轮发。

---

## 6. 发送层要求（硬约束）

- **一律 HTML parse_mode**，动态内容必须转义（`escape_html` / `Esc-Html` /
  `html.escape`，或经 `tg_*` 助手）。没有「值是脚本自造」的豁免。
- **HTML 解析失败（400 can't parse entities）不重发**，直接报错并带响应体前 200 字符。
- **429 按 `retry_after` 等待重试（最多 5 次）**；长消息自动分片，断在换行处、不切
  UTF-8 多字节。分片口径三套有意不同：
  - bash：>3900 UTF-16 码元触发，按 3800 UTF-16 码元切，边界自动闭合 / 重开 HTML 标签；
    5xx / 网络错误也退避重试。
  - python：按 4000 Python 码点切，**不闭合标签**（故 `<pre>` 按 1200 字节截断）。
  - pwsh：无分片。
- 发送失败必须在 stderr / 日志输出原因；python 侧 `send_telegram` 返回字典（失败带
  `reason`），调用方必须记日志。
- **已引入发送层的通知点不得 curl 直发**。唯一例外：需要 message_id 的进度面板、
  媒体上传（`sendDocument` / `sendVideo`）。
- **档位路由**：`send_tg` / `send_tg_chunked` 收可选 `tier`。
  - `alert` = 重要通知（告警 + 信息）→ @SaberFuckBot；无回落，凭据缺失即失败留痕。
  - 不传 = 普通通知（结果 + 流水）→ @FuckSaberBot。
  进度面板直连主 bot，不参与路由。

### 6.1 全库 bot 分工（唯一口径）

| bot | 职责 | 本机 | 仓库 |
|---|---|---|---|
| @openclaw_sb_bot | 主对话（不发通知） | ✓ | — |
| @FuckSaberBot | 一般通知（业务） | ✓ | ✓ |
| @SaberFuckBot | 重要通知 | ✓ | ✓ |
| @sbsb / @sbsbsb / @sbsbsbsb / @sbsbsbsbsb | agent 各自对话窗口 | ✓ | — |
| @ass_openclaw_bot | 内部消息隔离带（relay / 后台完成 / 串号排查） | ✓ | — |

**两档 × 两侧，共 4 格，只用 2 个通知 bot。** 判定：一般 = 业务结果；重要 = 告警 +
信息（runner 重启、setup-env 报告、测速告警、入口 / 凭据、服务启停）。内部消息不属于
任何一档，不进业务通知通道。

> 判据（易踩）：GitHub Secrets 只写不可读，本机 `.env` 的值 ≠ 仓库 secrets 的值。
> 判断仓库接的是哪个 bot 只能看消息头。也不要把本机裸变量 `TELEGRAM_BOT_TOKEN` 改值——
> 那是本机重要通知的出口。

已知差异（当前实现）：pwsh 无分片；python 429 耗尽抛异常而非返回字典；python
分片不带标签闭合。

---

## 7. 验证与交付（硬约束）

### 7.1 渲染预览与机械校验

```bash
source .github/scripts/telegram/tg_notify.sh
msg=""; tg_add_title msg "⚠️ 示例"; tg_add_section msg "❌ 清单 · 2"
tg_add_block msg "$(tree_lines "$(tg_entry "a.mp4" "1.700 GiB")")"
tg_add_footer msg; printf '%s\n' "$msg"

bash skills/telegram-notify-audit/scripts/render_preview.sh        # 真源渲染 + 16 项自动校验
bash skills/telegram-notify-audit/scripts/list_notify.sh --check   # 机械校验（偏差退出 1）
```

两步都已接进 `tests.yml` 的 `notify` 域（手动 dispatch）：

```bash
gh workflow run tests.yml -f domain=notify
```

### 7.2 回归套件

改到 openlist 域时跑：

```bash
cd .github/scripts/openlist/tests
for t in test_*.sh; do bash "$t" </dev/null > "/tmp/x_${t%.sh}.log" 2>&1; echo "$t EXIT=$?"; done
grep "command not found" /tmp/x_*.log   # 必须为空
```

必须重定向 stdin；**套件 PASS 不等于通过**，`command not found` 必须为空。具体基线与
flake 名单见 `skills/telegram-notify-audit/references/audit-checklist.md`。

### 7.3 资产段桥接冒烟

看板是资产口径真源、通知只是引用方，改看板口径 / 结构后跑：

```bash
bash skills/telegram-notify-audit/scripts/smoke_assets_bridge.sh
```

校验契约而非数据快照；空输出合法；本机看板缺失返回 2 = SKIP。新增校验项后必须做一次
负向验证（把被测处退回错误形态，确认校验变红），否则可能是恒真断言。

---

## 8. 术语

- **面板**：需要 message_id 的原地刷新消息（openlist 进度面板）。
- **结构性清单**：读者要逐条核对、折叠掉会造成误判的清单。
- **硬约束**：不遵守会造成通知丢失或误判失败的规则（收尾区、接线、发送层、验证与交付）。
