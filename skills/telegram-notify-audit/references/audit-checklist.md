# Telegram 通知版式核对清单

本文件是 `skills/telegram-notify-audit` 第 1、3、5 步的输入：机械扫描项、四域判据、
易误判项、回归基线与 flake 名单。**只记录可复用的判据与基线，不记录「哪一轮改了什么」**
（过程记录会让文件迅速腐化）。

## 1. 机械扫描项（Grep 工具，path 显式传 `.github`）

| # | 扫描项 | 模式 | 期望结果 |
|---|---|---|---|
| 1 | 粗体/斜体 | `<b>\|</b>\|<i>\|</i>` | 零使用，仅注释提及 |
| 2 | 平铺条目 | `•` | 零使用，仅注释提及 |
| 3 | 半角冒号 kv | `[一-龥]:[^/:= ]` | 仅非通知代码（echo/grep 表达式） |
| 4 | 紧凑时长 / 高精度浮点 / ISO 直出 | `[0-9]+h ?[0-9]+m\|[0-9]\.[0-9]{4,} 秒\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}` | 仅注释、测试夹具、非通知数据 |
| 5 | curl 直发 | `curl .*(sendMessage\|/bot)` | 只允许三类：发送层自身（`tg_notify.sh` 两处、`speedtest_common.py` 一处）、进度面板 `message_id` 与 `deleteMessage`（`openlist/telegram.sh`）、`sendDocument`（`sync_notify.sh`）。`ensure-miniapp-menu.sh` 调 Bot API 配置菜单，不属通知。**新增直发点即偏差**，不按固定处数判 |
| 6 | 分隔线 | `TG_SEP *=\|━━━` | 四处同值 18 条（bash 真源 / pwsh `0x2501*18` / python `'━'*18` / `sync_to_tg.sh` 内嵌） |
| 7 | 收尾区覆盖 | 分别统计 `tg_add_title` 与 `tg_add_footer\|Get-TgFooter\|tg_footer_line` 的**按文件**计数 | 计数不等时逐个查是否「分支汇聚」或「注释」造成；每处标题分支都必须能走到 footer |
| 8 | 运行日志接线 | `grep -l TG_RUN_URL .github/workflows/*.yml` | **现场重数，不记固定数字**。判据是「每个发通知的 step 都有 `TG_RUN_URL`」；直接构造通知的 workflow 数与注入面不必相等（多数经被调脚本/复用 workflow 发送）。caption 场景也需注入 |
| 9 | 树形/折叠调用点 | `tree_lines\|tree_fold\|tree_code_fold` | 逐个确认折叠口径（见第 2 节判据） |
| 10 | 分节计数 | `tg_add_section +[a-z_]+ +"[^"]*"` | 后跟列表的带 ` · N`；后跟 `<pre>` 或 kv 行的可不带 |
| 11 | 速查表函数存在性 | 对 `api-reference.md` 三列表里的每个函数名 `grep -nE '^(函数名)\(\)|^def 函数名|^function 函数名'` 对真源 | 每个名字都能在对应真源找到（速查表只记函数名不记行号——行号会漂，发现表里有真源不存在的函数名即为文档腐化，反过来真源新增公开助手时应补进表） |
| 12 | **函数体内 `source` 真源** | `source .*tg_notify\.sh`，人工判断是否落在 `name() { … }` 之间 | 只允许在 step 顶层 / heredoc 脚本顶层。函数体在子 shell 里跑时，函数内 `source` 不影响父 shell 函数表，会把调用点对 `send_tg` 的本地覆写还原掉，`local` 也失效（规范 · 通知函数的正确接法） |
| 13 | 接力轮重复通知 | 长跑 workflow 里按「服务已就绪」判据发通知的调用点 | 用 `/tmp` 标记文件区分首轮/接力轮，接力轮只记日志；否则每个接力 run 重复推同一条（规范 · 通知函数的正确接法） |
| 14 | `🕒` 误用 | `🕒` | 只允许出现在无 run 上下文的常驻服务收尾区（`health/system_health.sh`、`board.py`、`gateway-watchdog.py`）；正文分节/时间行不得使用 |
| 15 | 展示时间时区 | 通知字符串里的 `UTC`；无 `TZ=` 的 `date +%F` | 展示时间一律东八区（`YYYY-MM-DD HH:MM（东八区）`）；仅机器值（marker/JSON/日志/run 时间戳）可 UTC。取展示值必须 `TZ=Asia/Shanghai` |
| 16 | 通知清单枚举 / 一键校验 | `bash scripts/list_notify.sh`（清单）/ `--check`（1–15 项机械校验，FAIL 退出 1）；CI 侧走 `tests.yml` 的 `notify` 域 | 发送点/标题/档位三段可正常输出；档位为「动态」的必须逐个回文件确认取值（当前 4 处：`system_health.sh`、两个 backup、`pixivutil2.yml`）。**清单不落文档**，别把枚举结果抄回任何 md |
| 17 | 业务步内嵌通知 | 找「通知写在业务 step 末尾、该 step 无 `always()`」的调用点 | 按规范 · 接线的判据分类：依赖落盘产物的应拆独立 step；依赖运行时变量的应有失败兜底；「已就绪」语义与长驻循环通知**不拆**。别把「不拆」重复报成缺陷 |

## 2. 四域判据（派 worker 时写进 prompt 的摘要）

- 标题 = `{emoji} 标题` + 18 条全角横线 ━，不空行
- 分节 `{emoji} 分节 · N`：后跟条目列表必须带计数
- kv 一律**全角冒号**；机器返回值（路径/文件名/IP/ISP/ASN/位置/域名/端口/密码/ID/
  命令/版本号/原始异常串）用 `<code>`，自然语言（原因/结论/状态/备注/有效期）裸文本
- **同一分节内口径必须一致**：一次查询返回的 IP/ISP/ASN/位置整节同为等宽；
  逐个判断会产出斑马纹，读者会当成版式 bug
- 条目一律 `├─/└─` 树形（前缀统一包等宽 `<code>`，规范 · 清单明细），元数据 ` · ` 跟在主体后
- 折叠看**清单性质**不只看条数：流水/日志类超 8 条折叠为「还有 N 条…」；
  结构性清单全量展示
- `tree_code_fold` 收裸文本、`tree_fold` 收已构建条目流，误用会二次转义
- 收尾区 `⏱ 已运行 X · 🔗 运行日志` 必须走 `tg_add_footer` / `Get-TgFooter` / `tg_footer_line`
- 时长五层：`X 小时 Y 分`（分钟不补零）/ `X 分钟` / `X.XX 秒` / `X 毫秒` / 面板 `⏱mm:ss`
- 展示时间一律东八区（`YYYY-MM-DD HH:MM（东八区）`）；机器值仍存 UTC，两者不混用
- 动态内容必须转义，无豁免
- 读者要「看懂」的字段说人话（规范 · 说人话）：失败原因/状态/结论里的内部机制
  （熔断、探测、哈希目录、base64URL、重启复核）一律翻译成日常说法；运行日志不搬进
  通知，尤其不搬成条目子行（单文件能撑出十几行）
- 空行只来自：section 段前、note 段前、footer 前、正文与动作行之间、多组列表组间
  （组间空行必须带「前面已有组」的条件，首组前不补）

## 3. 易误判为偏差、实为合规（每次核对最容易误报的地方）

| 写法 | 为什么合规 |
|---|---|
| 进度面板四组任务列表（待处理/已完成/已跳过/失败 + 进行中）不折叠 | 结构性清单：折掉后半段等于把「哪些任务没跑完」藏起来（`sync_progress.sh` 终态判定段 `_progress_render_task_list` 一带注释即此意） |
| `task_preview` 同步对、`task_engine` 子目录/批次统计不折叠 | 结构性清单，同 规范 · 折叠行判据 |
| `sync_to_tg.sh` 失败清单走 `tree_fold` | 流水类，与同通知「已上传」同口径 |
| `📍 测速点网络` 分节带 ` · N` | 恒带计数（规范 · 分节：后跟条目列表必须带），taier/gitee 单目标即 ` · 1`——共享层 `count_hint` 无条件拼（`speedtest_common.py` build_target_network_section） |
| taier 通知**没有**「⚠️ 测活探测异常」分节 | 旧分节记「探测机制没跑通」的误伤（逐个探 `/proxies/{name}` 恒 404）；改批量延迟表判活后只有两种世界：拿不到表 ⇒ 探测层整体关闭、不产生判死条目；拿到了 ⇒ 「表里没有」是真判死、计入 `❌ 失败`。若再出现该分节即为回退（`docs/proxy-speedtest-taier.md`） |
| taier 的「未更新订阅」按真因分文案（三种） | 真·达标不足 / 有速度但缺可导出配置（实现层丢 `proxy_obj`）/ 到点收摊少测（句尾补「预算内仅测完 N/总数 个」）是三回事，文案必须分开（`docs/proxy-speedtest-taier.md`） |
| 后跟 `<pre>` 或 kv 行的分节不带计数 | 规范 · 分节允许 |
| emby 规格行 codec（h264）裸文本 | 一行多字段混排，单独套 `<code>` 会成斑马纹 |
| openclaw 归档告警标题随阶段 + 对象变化 | 「归档告警 · <对象>」/「最终归档告警 · <对象>」：阶段区分轮次，对象区分是哪个归档包 |
| openclaw「最终归档结果」的 `📦 归档明细` 只调 `tree_lines`、不折叠 | 固定几项的结构性清单（最多 5 个归档对象），折掉任一项都会让读者误判归档是否完整；条目由 `tg_add_entry` 构建（已含 `<code>`），本就该走 `tree_lines`/`tree_fold` 而非 `tree_code_fold` |
| 媒体 caption 无标题/分隔线/收尾区 | 规范 · 收尾区固有例外，但必须转义 + 显式 parse_mode |
| 测速节点指标串里的 `35ms` | 指标字段（与 `↑`/`↓` 并排），非独立时长表述，不走「毫秒」层 |
| emby「取直链」的 `（缓存命中）` / `（冷解析）` | 与既有 `（预估值）`「（走挂载）」同为**冒号前**、紧跟被测量对象的括号说明（不是行尾后缀），说明本次取链是否真花了那段时间；对象已有括号时并入同一括号、以 ` · ` 分隔。属自然语言裸文本，不套 `<code>`；判据见 `docs/emby.md`「起播等待」 |
| 标题数与 footer 数不等 | 多为分支汇聚（如 `github_backup_all.yml` 4:2）或注释造成的计数差 |
| openclaw 的 `wb_notify` / `wb_stop_notify` 两处各存一份版式 | `Run workbuddy-gateway` 与 `Stop OpenClaw and Final Archive` 是两个 step、shell 不共享，函数无法跨 step 复用；**改版式必须两处一起改**，这是最容易「改一处漏一处」的地方（域字段口径见 `docs/openclaw.md` 九 / `openclaw.yml` 两处函数头注释） |
| `wb_notify` 账号池的子行不是 `tree_lines` 渲染的 | 子行必须用 `tree_sub` 前缀**手拼**：`tree_lines` 把每行当兄弟条目，子行经它会渲染成 `├─/└─` 与条目平级（规范 · 清单明细二层列表）。条目行用 `tree_conn`，子行紧接其后用 `tree_sub`，末条索引两处一致 |
| 收尾停止通知只有结论行、没有账号池 | 收尾 step 里没有 `WB_CREDS` / `WB_POOL`（启动 step 的局部变量），且网关已停——列账号池会让人以为服务还在跑。**不是漏字段** |
| `tg_append _msg $'\n'` 出现在账号池块之后 | 块尾补空行：`tg_add_block` 不补尾空行，否则下一个 kv（数据目录）会紧贴末条子行，与规范示例的「块与 kv 区之间空一行」不一致 |
| trae2api 通知（`openclaw.yml` 单份内联；按需签到 workflow 已移除）无「凭据」分节、「🧾 原始输出」非空才渲染 | 与 workbuddy 版式同源但数据来源不同：版本写 Release tag（取 fork Release 静态二进制部署）；「原始输出」照 wb_notify 的 $6 口径非空才渲染，部署失败给脚本 stderr、启动失败给容器日志尾部、签到分支给签到工具 stderr 尾部（1200 字节） |
| workbuddy 账号池用 `jq` 解析 `workbuddy-status.json` | **不是**「解析未文档化文件」：键名由上游 Go 结构体 `accountSnapshot` 的 json tag 固定，比 `status` 子命令的对齐文本表格可靠（后者字段名后跟多个空格、`过期时间` 独立成行，解析脆且易漏）。域字段口径见 `docs/openclaw.md` 九 |
| `quotaKnown` 为 false 时显示「额度未获取」而不是 0 | 快照里 `quotaRemaining` 此时是无意义的 0（还没查到），显示 0 会与「付费耗尽」混淆。照上游 `monitor` 显示 `-` 的同一判断 |
| workbuddy 通知里的 `exp` / `awk` 解析残留 | 已全面改用 jq；若再看到 awk 解析 `status` 文本输出即为回退。**另：awk 里 `exp` 是内置函数（指数），不能当变量名**（历史踩坑） |
| workbuddy 免费模型列**具体模型名**而非只给计数 | `freeModels` 只是个数字，只写「免费模型 1」读者不知道是哪个。名字取自上游模型目录接口（见下条），按「生效倍率为 0 且促销未过期」筛出 |
| 免费模型名清单**全量展示、不折叠** | 属**结构性清单**（规范 · 折叠行：判据是「折掉会不会让读者误判」）：读者要逐条核对哪些模型免费，折叠成「还有 N 个…」等于把最需要看的部分藏起来。名字多时靠 `免费模型 N` 交代规模，并拆到独立子行避免单行过长 |
| 免费模型名走**上游模型目录接口**（`GET {Base}/v2/enterprises/personal/models`） | 只读、不耗额度、无回环限制，一次拿全量模型的 `credits` 与促销。站点由凭据 `edition` 决定（国内站 `copilot.tencent.com` / 国际站 `workbuddy.ai`），故**逐账号**各请求一次。免费判据照上游 `siteKnownFree`：倍率能解析出、且生效倍率为 0、且促销未过期。**不读快照 `modelStates`**（只在模型被真实请求过时才有键，默认 `unknown`，拿不到名字），**也不用 `POST /admin/probe`**（逐账号 × 逐模型真实请求，实测 634 秒 > serve `WriteTimeout: 300s` 必被截断，且耗额度、可能触发限流冷却） |
| 免费名单取到但为空 vs 取不到，写法不同 | 取到但 0 个免费 → 如实写「免费模型 0」；**取不到**（超时/非 200/JSON 无 `models`）→ 整段降级退回首轮的计数口径，**绝不编造模型名**，也绝不把「取不到」当「没有免费」。这是降级不是漏字段 |
| 冷却写**「什么时候恢复」**而非只给数量，且账号级/模型级**两层都给** | 上游 `markCooldown`（屏蔽整账号）与 `markModelCooldown`（只屏蔽单模型）是两套独立冷却、恢复时刻不同，只给「模型冷却 2」读者没法判断该等还是该换账号。账号级取 `cooldownUntil` → `冷却 YYYY-MM-DD HH:MM`（**只在 `state=cooldown` 时展示**，`cooldownUntil` 是 `omitempty`，其他状态下残留也不展示，否则与「可用」自相矛盾）；模型级取 `modelStates[].cooldownUntil` 的 **min**（`模型冷却 N · 最早 HH:MM 恢复`）。**一律绝对时刻、不折算「还剩多久」** —— 通知是快照，读者几分钟后看到时相对时长已不准 |
| 模型冷却的「最早恢复」只在拿得到时刻时才写 | `modelStates` 可能缺失或该模型无 `cooldownUntil`（`omitempty`），此时**只给数量、不写半截**（如只写「模型冷却 2」，不写「最早 - 恢复」）。`cooldownMsg`（上游 429 原文，可能上百字符）**不进通知**，会撑爆子行且读者要的是时刻不是原文 |
| workbuddy TSV 的**每一列都不许为空**（空值填哨兵 `-`） | `read` 会把连续制表符折叠成一个（制表符属 IFS 空白），中段任一列为空，其后的值就整体左移、错位嫁接到前一个变量上。**只把第 1 列放非空是不够的**（那挡不住中段错位）：第 7 列（免费模型名）与第 8 列（模型冷却）都可能为空且相邻，实测会把冷却数当模型名渲染成 `免费模型 1 · <code>2</code>` —— 等于**编造模型名**。故 `jq` 侧一律填 `-`，渲染侧读进来先还原成空串再走「非空才并入」。第 1 列的判定标记仍放最前，但只是冗余保护 |
| 规范样例区的树形前缀是裸 `├─ `，实现渲染成 `<code>  ├─ </code>` | 样例是抽象版式，只示意层级与正文位置；前缀统一包等宽 `<code>` 是规范 · 清单明细的规则（比例字体下盒线字符不成列）。核对以规则与真源渲染为准，别拿样例判偏差，更别照样例写断言（render_preview 曾因此假红） |

## 3.1 已知历史形态（冒烟/核对必须能抓，不是规范）

- 资产段「📅 资产」节标题曾因 `tg_section` 追加语义被放在数据行**之后**，通知里 kv
  行悬进上一节、标题空挂。看板侧再动 `_assets_block` 结构时，先想它是否破坏
  「标题在前」契约。
- `_DAYS_CACHE` 漏定义曾导致快照后台重算每轮 `NameError`、SWR 恒回旧值、
  `/api/days` 500，而通知侧完全无感。`board.log` 扫描项即为此设。
- 空输出（任一源当日无数据、qingyan 回退快照）= 合法，非偏差。

## 4. 回归基线（改动触及 openlist 域时必跑）

```bash
cd .github/scripts/openlist/tests
bash -c 'rm -f /tmp/x_*.log 2>/dev/null; for t in test_*.sh; do bash "$t" </dev/null > "/tmp/x_${t%.sh}.log" 2>&1; echo "$t EXIT=$?"; done'
grep -l "command not found" /tmp/x_*.log   # 必须为空（硬要求）
```

- 全量约 5–12 分钟（随套件数与机器负载变化），后台跑；**跑期间不要并发跑单个测试**。
- 判定基线：**除环境假红外全部 `EXIT=0`**（套件数会变，别记数字）；已知环境假红固定为：
  - `test_truth.sh`（依赖 docker / 真实 OpenList 服务）
  - `test_marker_skip_guards.sh` 1b（macOS BSD `date` 无 `-d`）
- `command not found` 扫描**必须为空**——套件 PASS 不等于通过。

### 共享抽取文件与噪声

- `tests/extracted.sh` 曾被三套测试共用，串行跑时后跑的覆写先跑的，产生假 cnf。相关
  套件已改把抽取文件写进各自 `WORK_DIR`；新写测试不要再用共享抽取文件。
- `test_batch_precheck_circuit_breaker` 的 409 死目录闸（`_batch_409_deadlock`）需要
  stub，漏补会因 `rc≠124` 分支一走进 cnf。
- 修完 cnf 后必须 `grep -l "command not found" /tmp/x_*.log` 复验为空。

### flake 名单（单独复跑确认后再下结论，别急着改代码）

- `test_progress_no_orphans.sh` T5「强杀路径有超时上限 <15s」：负载高即失败，
  实测全量跑时必现、单独复跑 `PASS=16 FAIL=0`
- `test_get_openlist_token_login.sh`：sandbox broker IPC `ETIMEDOUT`
- `test_batch_precheck_circuit_breaker.sh`：回归期间被并发跑过会出现假的
  `command not found`（共用 `tests/extracted.sh`）
- `test_pair_parallel.sh`：`wc` 前导空白使 `[: 0\n0: integer expression expected`，
  场景 3a 误报「仍执行 4 个」，单独复跑 `PASS=11 FAIL=0`
