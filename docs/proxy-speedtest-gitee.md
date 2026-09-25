# Gitee 上下行 + 延迟测速（proxy-speedtest-gitee）

> 代码：`.github/scripts/proxy-speedtest/speedtest_gitee.py`
> 入口：`.github/workflows/proxy-speedtest-gitee.yml`

## 三件套总览

仓库代理测速三套**按测速点命名**，口径互不可比：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | 本文 | — |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | `speedtest.py` | [cdn](proxy-speedtest-cdn.md) |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | `taier_speedtest.py` + mihomo TUN | [taier](proxy-speedtest-taier.md) |

另有上游编排 `proxy-speedtest-gistnodes`（搜 gist + Sub-Store 去重 + `alive_filter` 探活后
发订阅，再 `workflow_call` 三选一），本身不测速。

调度：UTC 21/01/05/09（北京 05/09/13/17），与 cdn（UTC 22/02/06/10 → 京 06/10/14/18）、taier（UTC 23/03/07/11 → 京 07/11/15/19）各错开 1 小时；三套都只排在北京时间 05:00–21:00（夜间 runner 排队 + 出口拥塞会让读数失真）。

### 四项测量口径速查（四套对照）

容易被误读的三点写在最前：**① 只有 taier 与 gistnodes 真探活**（CDN/Gitee 的「活」是测量
成功的副产品）；**② taier 的「兆」与另外三套的 MiB/s 不是同一把尺子**（见下方换算）；
**③ 上行与下行都只计「数据在链路上跑」的那一段**（CDN 的 curl Range、Gitee 的 git blob
传输；仓库元数据协商、checkout、commit 等固定开销一律排除，见下方「下载计时」）。

| 项 | CDN | Gitee | taier | gistnodes |
|---|---|---|---|---|
| **探活** | ❌ 无（`ok = 延迟成功 or 下载成功`） | ❌ 无（push 成功即活） | ✅ 开测前一次 `GET /group/{组}/delay` 拿整组延迟表，逐节点查表 | ✅ 非惰性健康检查 + 轮询等结论 |
| **延迟** | `latency_probe`：baidu+taobao，各 4 次，8s，**HTTP 首字节** | 同实现，目标只有 `gitee.com` | 引擎对运营商服务器打**原生 TCP** | — |
| **上传** | git push→Gitee，**可切直连** | git push→Gitee，**可切直连** | 引擎发流（single/multi） | — |
| **下载** | curl 单连接 Range 10MiB，多镜像取最优 | `blob:none` clone + checkout 取文件，**只计传输** | 同一次引擎调用的「↓」列 | — |
| **单位** | MiB/s | MiB/s | 原始 Mbps | — |

⚠️ **taier 的单位陷阱**：引擎输出 Mbps，导出时 ÷8.388608 转 MiB/s、展示时 ×8 转回「兆」，
净效果 ≈ ×0.9537 ⇒ **展示值基本等于引擎原始 Mbps**。所以 taier 通知里的「兆」与 CDN/Gitee
的 MiB/s 不能直接比，跨套比较要先统一到 MiB/s。

## 双重角色

`speedtest_gitee.py` 既是独立工作流引擎，也是三套共享引擎：

1. **独立引擎**：both 模式（默认）下对每个可用节点经 mihomo 代理测三项——git push
   测速文件到 Gitee 私有仓库（上行）、clone 拉回（下行）、对 gitee.com 做 HTTP 计时
   （延迟，与 cdn 的 `latency_probe` 同实现）；
2. **共享引擎**：mihomo 下载/配置/生命周期、订阅拉取解析、节点快照与切换在本文件；
   与引擎无关的纯共享层（订阅导出策略、通知排版、归属查询、Telegram 发送、Gist 上传、
   进度日志）在 `speedtest_common.py`（2026-09-08 从本文件抽出，共享代码不再挂在 gitee
   名下），本文件按需 import、无兼容再导出；`speedtest.py` / `taier_speedtest.py` import 复用。顶层的 signal/异常通知只在 `main()` 注册，
   import 复用不会误触发。

## 功能与链路

1. 拉取并解析订阅（base64 自动解码），写成本地 provider 文件；
2. 下载/启动 mihomo（HTTP 17890 / SOCKS 17891 / mixed 17892，控制器 19090），
   `collect_provider_snapshot` **全量**取 provider 解析出的节点（**不按 `alive` 预筛**，
   理由见[为什么节点收集不等健康检查](#为什么节点收集不等健康检查)）；
   随后 `wait_provider_ready` 等 provider **真正装进组**再开测
   （判据是 `/proxies/{组}` 的 `all` 成员清单；理由见
   [为什么开测前要等 provider 装进组](#为什么开测前要等-provider-装进组三套共用)）；
3. 准备 Gitee 私有仓库（`ensure_gitee_remote`：不存在则创建，超限自动 `rebuild_gitee_repo`）；
4. 生成 `PROXY_SPEEDTEST_SIZE_MIB` MiB 测速文件；
5. 逐节点：切换 AUTO → 经代理 HTTP 计时测 gitee.com 延迟（`latency_probe`，采样
   `PROXY_SPEEDTEST_LATENCY_SAMPLES` × 超时 `PROXY_SPEEDTEST_LATENCY_TIMEOUT`）
   → 经代理 `git push`（单流 HTTPS，超时 `PROXY_SPEEDTEST_PUSH_TIMEOUT`）按推送耗时
   换算上行 → `git clone` + `checkout` 取文件（超时 `PROXY_SPEEDTEST_CLONE_TIMEOUT`）
   换算下行（只计 blob 传输，见[下载计时](#下载计时只计-blob-传输2026-09-17)）；
6. 汇总 → 按**订阅导出策略**判定达标节点（见[订阅导出策略](#订阅导出策略三套共用)）导出到专属 Gist
   （`update_gist`，只上传不回拉；2026-09-10 已移除原先「第二个 mihomo 实例（19690/19691）
   回拉 Gist raw + 抽样验证」的步骤，见[运维与排查](#运维与排查)）；
7. Telegram 推 `✅ Gitee 测速完成`（TOP 节点三项指标 + 订阅状态）。

## 运行模式与直连基线

`PROXY_SPEEDTEST_MODE`（2026-09-08 起默认 `both`）：

- `both`：↑上传（push）+ ↓下载（clone）+ 延迟三项全测，三套指标口径对齐；
- `push-only`：只测经代理上行（历史模式，可用 env 退回）；
- `git_direct_speedtest`：不经代理直连 Gitee push/clone，作为「家庭宽带上行」基线对比
  （`PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT` / `_MAX_ATTEMPTS` 控制），不受模式影响。

## 上行测速：CDN 与 Gitee 已统一（2026-09-17）

**诉求**：两套的上行要么都经代理、要么都直连，且都能用直连基线做对照——否则「节点带宽」
与「家庭宽带」两套数字混在一起，无法判断节点是否还不如直连。

**改法**：实现收敛到本文件的 `upload_speedtest`，CDN 不再自带副本。一次调用由
`via_proxy` 决定走哪条路：

| 模式 | 环境 | 测的是 |
|---|---|---|
| `via_proxy=True`（**默认**） | 带 mihomo 混合端口代理变量 | **代理节点上行** |
| `via_proxy=False` | `strip_proxy_env` 剥净 6 个代理变量 | **家庭宽带直连上行** |

两套共用**同一份代码**（`speedtest_gitee.upload_speedtest` / `run_direct_baseline`），
差别只剩「用不用代理」，因此**两种模式的数值可比**——这正是切直连做对照的前提。
测试第 10 组断言的是**函数对象同一性**（`cdn.upload_speedtest is gitee.upload_speedtest`），
不是「行为相同」：行为相同的两份实现，下一次改一处就会漂。

配套开关（两套**同名同默认**）：

| env | 默认 | 作用 |
|---|---|---|
| `PROXY_SPEEDTEST_UPLOAD_VIA_PROXY` | `1` | 上行经代理（`0` = 直连）。CDN 原有；Gitee 2026-09-17 补上 |
| `PROXY_SPEEDTEST_DIRECT_BASELINE` | `1` | 是否跑直连基线（CDN 原有开关语义；Gitee 恒跑） |
| `PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT` | `60` | 基线单次 push/clone 超时 |
| `PROXY_SPEEDTEST_DIRECT_BASELINE_MAX_ATTEMPTS` | `5` | 基线重试次数（直连 Git push 偶发超时，一次抖动不该让整轮基线缺失） |

⚠️ **默认保持「经代理」**：历史通知里的「上传」都指节点上行，改默认会让新旧数据不可比。
要测家庭宽带，显式设 `PROXY_SPEEDTEST_UPLOAD_VIA_PROXY=0`。

## 下载计时：只计 blob 传输（2026-09-17）

**原口径**：`t0 = time.time()` 包住整条 `git clone --depth 1 --single-branch`，量到的是
「远端仓库元数据协商 + 文件内容传输 + 本地 checkout」的总墙钟时间。10MiB 文件在高速节点上，
元数据/checkout 的固定开销能占掉相当比例 ⇒ 算出的 MiB/s 被**系统性低估**；且上行侧只包住
`git push` 一条命令，两侧口径本就不对称。

**现口径**：拆成两段，只量第二段：

| 段 | 命令 | 是否计时 |
|---|---|---|
| ① 元数据 clone | `git clone --depth 1 --single-branch --branch <b> --filter=blob:none <remote>` | ❌ 不计 |
| ② 内容传输 | `git checkout --force HEAD -- <file>`（触发 blob 获取并写入工作区） | ✅ **计** |

`--filter=blob:none` 是 partial clone：只取提交与树、不取任何文件内容，因此第 ① 段几乎不含
数据流量；第 ② 段的 `checkout` 才真正把 10MiB blob 拉下来——**这一段才是「下载」**。
测试第 11 组用「clone 阶段伪造 5s、checkout 阶段伪造 2s」的伪造时钟钉住：返回的
`download_seconds` 必须是 2s 而不是 7s；把 `t0` 挪回 clone 之前会立刻变红。

两点约定：

- **checkout 非 0 不直接抛**：`blob:none` 下这次 checkout 才去取内容，超时/失败都要看文件
  到底有没有落地——落地了就当这次测到（计耗时），没落地才 `RuntimeError`。避免把
  「内容已到、命令却非 0」误判成下载失败。
- **不做「远端不支持 partial clone」的兜底分支**：Gitee 支持；万一不支持，git 会告警并退回
  全量下载，此时第 ② 段几乎是空操作、退化成接近旧口径。多一条兜底就多一种「看起来成功但
  口径不同」的路径，宁可让它自然退化。

`download_seconds`（RESULT_JSON / `direct_baseline_finished` 日志）**整个替换**为这个纯传输
耗时，不并存两个口径——并存迟早有人拿错那个字段。

⚠️ **`strip_proxy_env` 必须剥净 6 个变量**（含小写的 `all_proxy`/`http_proxy`/`https_proxy`）：
漏一个就会「直连」其实还在走代理，测出来是节点带宽而非家庭宽带，**且看不出任何异常**。
测试第 10 组对此有专门断言，并已反向验证（漏掉 `all_proxy` 即变红）。

## Gist 约定（三套各用各的）

- secret：`PROXY_SPEEDTEST_GIST_ID`（本工作流）、`PROXY_SPEEDTEST_CDN_GIST_ID`（cdn）、
  `PROXY_SPEEDTEST_TAIER_GIST_ID`（taier）
  ——分别注入各 workflow 的 `PROXY_SPEEDTEST_GIST_ID` env，脚本读同名 env，共享代码零特判；
- 文件名/描述经 `PROXY_SPEEDTEST_GIST_FILENAME` / `PROXY_SPEEDTEST_GIST_DESCRIPTION`
  覆盖（`_gist_identity`，实现在 speedtest_common.py），本工作流为
  `proxy_speedtest_gitee_subscription.yaml` / `proxy speedtest subscription (gitee 上行/下行/延迟)`；
- id 缺失时自动新建（`update_gist` → `create_gist`），新 id 写回
  `~/.openclaw/.env`（runner 上不跨 run 持久）+ TG 通知给链接，需回填 secret。
- **id 存在但 PATCH 撞 404 时，先重试再判死**（2026-09-17 修，事故见下）：
  真·失效是**稳定**的、API 抖动是**瞬时**的 ⇒ 原样重试一次；仍 404 再 GET 复核
  （PATCH 与 GET 是两条独立路径，GET 能读到目标文件即证明 id 还活着），
  只有「重试仍 404 **且** GET 也读不到」才新建。
  - 事故：2026-09-17 run 35160462273 对一枚正常在用的 taier gist 拿到一次瞬时 404，
    旧实现见 404 就新建并回填 secret；而并发的另一轮仍用旧 id 正常更新、又把 secret
    覆盖回去 ⇒ 页面上出现**两个描述与文件名完全相同**的订阅 gist，新那个只活了 1 个
    修订就成孤儿，只能靠人肉发现（2026-09-17 已删除孤儿 `279597be`）。
  - 日志：`gist_patch_404_retry`（重试）→ `gist_patch_404_recovered`（重试即成功，正常）
    / `gist_patch_404_recreate`（确认失效，新建）。若看到抛错文案带「拒绝新建」，
    说明 PATCH 404 但 GET 可见、判定为抖动——**这是有意的**，暴露出来比静默建垃圾好。

## 环境变量

### secrets

| secret | 用途 |
|---|---|
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（三套共用） |
| `PROXY_SPEEDTEST_GIST_ID` | 本工作流专属订阅 Gist 的 id |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `GITEE_PRIVATE_TOKEN` | Gitee 私有仓库建仓/push |
| `PROXY_SPEEDTEST_GITEE_OWNER` | Gitee 私有仓库属主 |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |
| `GITHUB_TOKEN` | GitHub API 匿名限流时的认证回退 |

被 `proxy-speedtest-gistnodes` 当子流程调用时，结果 Gist 与通知标题可被入参覆盖：
`gist_id` / `gist_filename` / `gist_description` 把结果写进调用方的 Gist，
`label` 给通知标题加来源前缀（如 `✅ gist 节点 · Gitee 测速完成`）。
四个入参留空时行为与定时轮完全一致（写本工作流 Gist、标题不带前缀）。

### 可调参数（workflow 注入）

| env | 默认 | 说明 |
|---|---|---|
| `PROXY_SPEEDTEST_MODE` | both | both = 上行+下行+延迟三项；push-only = 只测上行 |
| `PROXY_SPEEDTEST_SIZE_MIB` | 10 | 测速文件大小 |
| `PROXY_SPEEDTEST_PUSH_TIMEOUT` / `CLONE_TIMEOUT` | 30 / 30 | 单次 push / clone 超时 |
| `PROXY_SPEEDTEST_LATENCY_SAMPLES` / `_TIMEOUT` | 4 / 8 | gitee.com 延迟采样次数 / 单次超时 |
| `PROXY_SPEEDTEST_UPLOAD_VIA_PROXY` | 1 | 上行经代理（`0` = 直连 Gitee 测家庭宽带）。与 cdn 同名同默认 |
| `PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT` / `_MAX_ATTEMPTS` | 60 / 5 | 直连基线 |
| `PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS` | 1.5 | 切节点后等待 |
| `PROXY_SPEEDTEST_BUDGET_SECONDS` | `18000` | **墙钟预算**（秒，`0` = 不限），从进程启动起算。到点不再开下一个节点，拿已测节点照常出订阅（退出码 0）。**与 job 的 `timeout-minutes` 成对**：默认 5 小时 < 360 分钟。workflow 里写死，不接仓库 Variables |
| `PROXY_SPEEDTEST_DETACH` | 0（workflow 注入） | 1 = detach 后台自跑（本地手跑用） |
| `PROXY_SPEEDTEST_GIST_FILENAME` / `_DESCRIPTION` | 见 workflow | Gist 文件名/描述 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆） |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；主指标达标数 < 回退门槛且另一指标更多时自动改用另一指标（双向对称） |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传（通知显示「达标不足 N 个」） |
| `PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES` | 3 | 判定指标回退门槛：主指标达标数 **< 该值** 且另一指标更多才改判。与 `MIN_NODES` 是两回事（后者只管传不传），别混用 |

### 墙钟预算（到点收摊，三套共用）

测速**逐节点串行**，单节点几十秒，而 `proxy-speedtest-gistnodes` 一轮交接过来的订阅可能有
几千个节点（2026-09-14 那轮 3284 个，按 gitee 口径远超 6 小时）。job 不设 `timeout-minutes`
时 GitHub 默认 **360 分钟**——撞上去是**硬取消**：整轮工作全废、下游 job 全 `skipped`，
订阅链接根本来不及提交到 Gist。

所以三套引擎都有 `PROXY_SPEEDTEST_BUDGET_SECONDS` 墙钟预算（默认 5 小时）：

- **判据**：`speedtest_common.should_stop_for_budget`（四套共用一份实现，单一来源）；
- **检查点**：每个节点**开始之前**，超预算则 `break`；单节点几十秒，所以最多超发一个节点；
- **不是失败**：退出码仍是 `0`，照常出报告、导订阅、发通知——只是通知里会说明「本轮没测完」；
- **起算点**：**进程启动**（不是节点循环），因为 job 的 `timeout-minutes` 也把前置准备算在内；
- **与硬上限成对**：默认 `18000` 秒 = 5 小时，留 1 小时给前置准备（订阅拉取 / mihomo /
  直连基线 / Gitee 准备）与收尾（报告 / 通知 / Gist 提交）。**改 `timeout-minutes` 前先确认
  这个关系没被破**。

通知表现：标题由 `✅` 降为 `⚠️`，并在「📊 节点」行**紧跟**一行
`⚠️ 本轮已中止：到点收摊：预算 <时长>，已测 N/M 个节点`。`RESULT_JSON` 里对应
`aborted_due_to_runtime` / `runtime_abort_reason` 两个字段。

### 订阅导出策略（三套共用）

三套共用同一套达标判定（`speedtest_common.resolve_subscription_policy` +
`build_subscription_bundle`，workflow env 已接仓库 **Variables**，Settings → Secrets and
variables → Actions → Variables 可随时改，留空走默认）：

1. **阈值**：`兆 = round(MiB/s × 8)`，≥ `PROXY_SPEEDTEST_MIN_MEGABIT`（默认 10）为达标；
2. **判定指标**：`PROXY_SPEEDTEST_SPEED_METRIC`（默认 `upload` 按上行）；
3. **回退**：**主指标达标数 < `PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES`（默认 3）**
   且**另一指标达标数更多**（`secondary > primary`）时，才改用另一指标。两条缺一不可——
   只按门槛会在「换了反而更少」时误换，只按「更多」会在主指标只有 1 个时丢掉用户显式
   配置的偏好（典型场景：公开节点上行普遍测不出，下行却全部达标）；
4. **最少节点数**：最终达标数 < `PROXY_SPEEDTEST_MIN_NODES`（默认 1）就不上传订阅
   （日志 `gist_skipped`，通知显示「达标不足 N 个 · 阈值 ≥X兆（按上行/下行）」）。

⚠️ **回退门槛不能复用 `min_nodes`**（2026-09-14 事故 + 2026-09-17 解耦为独立配置）。
`min_nodes` 的语义是「不足则不上传订阅」、默认 1；拿它当回退门槛就会变成「主指标有 1 个
达标就永不回退」。实测 run 34859505000：19 个节点里上行只有 1 个测得出，下行 19 个全部
达标，却因 `1 ≥ 1` 不回退 ⇒ **订阅里只剩 1 个节点**。两个语义必须分开：
门槛单列 `PROXY_SPEEDTEST_METRIC_FALLBACK_MIN_NODES`（默认 3）——下限设小了永不回退、
设大了又变成「达标不足就不上传」，绑在一起怎么调都是错的。

> 判据形式在 2026-09-17 从「倍率制」（`secondary ≥ ceil(primary × 1.5)`）改成「计数制」
> （`primary < 门槛 且 secondary > primary`）：倍率制在 `primary` 很小时（如 1）要求
> `secondary ≥ 2` 才换，与「计数制门槛 3」相比更宽松；两者都修掉了 `min_nodes` 事故，
> 计数制的好处是门槛语义直白、可直接按「想让几个达标才算主指标可信」来调。

实际采用的指标会写进日志（`subscription_policy` / `subscription_metric_fallback` /
`subscription_metric_kept`）与 TG 通知文案。节点必须有**可导出配置**才计入达标——否则导不进
订阅。取值顺序是 `source_entry.proxy` 优先、缺失时回落到 `proxy_obj`
（`speedtest_common.node_proxy_config`）。

⚠️ **回落这一层是 2026-09-17 补的，缺了它会整轮零产出。** `source_entry.proxy` 只在
「节点名匹配上订阅 source_mapping」时才有值；编排轮（gistnodes 把节点经 provider 直接喂入）
里 source_mapping 可能只有个位数条，而节点是几千个 ⇒ 绝大多数节点 `source_entry` 为空。
实测 run 35116972319：8326 个节点里 206 个**测出了速度**（最高上传 245 Mbps），却因只认
`source_entry.proxy` 全被判「无可用配置」⇒ 达标 0 ⇒ 订阅不上传。`proxy_obj` 是
`collect_provider_snapshot` 从 mihomo provider 直接读出的完整节点配置，与前者语义等价。

**TOP5 排序与判定指标一致**：三套的 TOP 榜都按实际采用的指标排序，通知标题标注
`🏆 最快节点 · N · 按上传/按下载`，避免出现「按上传导出订阅、却按下行排 TOP」的自相矛盾。

## Telegram 通知与兜底

| 标题 | 触发 |
|---|---|
| `✅ Gitee 测速完成` | 正常完成 |
| `⛔ Gitee 测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），`handle_termination_signal` 兜底 |
| `❌ Gitee 测速异常退出 · <阶段>` | 任一 `run_stage` 阶段抛异常（阶段即原因：`订阅源拉取/解析`、`mihomo 启动/配置`、`Gitee 仓库准备`、`测速文件准备`、`Gist 更新/通知`…） |

辅助机制：`/tmp/proxy_speedtest.lock` 每轮循环 touch（供外部心跳判 stale）；
`maybe_detach_self` 支持 detach 后台自跑（CI 里固定关闭）。

## 为什么节点收集不等健康检查

`collect_provider_snapshot` **全量**返回 provider 解析出的节点，`alive` 字段只作为附加
信息带出（日志里的 `alive` / `dead` 计数），**不再决定去留**。

原来它只收 `alive` 为真的节点，前提是「非惰性健康检查会在读快照前跑完」。这个前提不成立：
`wait_mihomo` 只等控制器 `/version` 就绪，**不等健康检查出结论**。订阅一大，读快照时
`alive` 可能一个都还没置位，于是「筛出活节点」退化成「一个节点都没有」。

实测 2026-09-15 run 34969408908（gistnodes 交接 13346 个节点）：

| 时间 | 事件 |
|---|---|
| 12:37:50 | `mihomo_tun_config_built`（mihomo 刚起来） |
| 12:38:05 | `source_mapping_built entries: 13136`（订阅原文解析出 13136 条） |
| 12:38:05 | `nodes_collected count: 0`（同一秒读快照，`alive` 全为假） |

配置就绪到读快照只隔 **15 秒**，13346 个节点的非惰性健康检查不可能在 15 秒内出结论。
结果是整轮零产出，而且**没有任何报错**——只有 `nodes_collected: 0` 这一行。

这与 `proxy-speedtest-gistnodes` 里 `alive_filter` 那次是同一个机理（下游读快照时还没探完），
只是那次在上游、这次在下游。

现在的判据：

- **到底哪些节点可用，交给逐节点那一步判**——taier 有 `probe_node_alive`，gitee / cdn 靠
  实测成败，它们本来就是更准的判据；
- 上游 gistnodes 在过滤层已经筛过一遍活节点（见
  [gistnodes 文档](proxy-speedtest-gistnodes.md#为什么发布前必须自己先测活)），这里再筛是重复劳动；
- 真全死时也不会「零产出」，而是每个节点各自失败并如实记进结果与通知。

⚠️ 副作用：坏节点会真的进循环、占掉一个测速窗口（gitee ≈ 数十秒、taier ≈ 31 秒，duration=13）。
这正是 taier 侧 `TAIER_ALIVE_PROBE`（默认开）存在的意义——开测前一次批量预取整组延迟表，
拿到表就按 mihomo 的明确结论判死、拿不到表就整体关闭全量放行（fail-open）。
若要限制总量用 `PROXY_SPEEDTEST_MAX_NODES`。

## 为什么开测前要等 provider 装进组（三套共用）

`wait_provider_ready(names)` 在**逐节点循环之前**跑：读 `/proxies/{组}` 的 `all`
成员清单，**哨兵名字出现在组里**就算装好（装填是整体行为，不会只装一部分；用头尾各两个
哨兵比轮询几千个名字便宜得多）。超时返回 `False`、**不抛异常**，照常往下走。

⚠️ **2026-09-24 重写：判据从「探 `/proxies/{name}`」改为「探组的成员清单」**。
旧判据等的是一件**永远不会发生**的事——`/proxies` 顶层恒为 8 个内置组名，provider 成员
**从不注册进去**（对照实验：同格式请求下 `/proxies/DIRECT/delay` 正常返回 18ms，成员名
100% 404；2 个与 2 万个节点两种池子结果一致）。于是旧实现每轮必然 `provider_ready_timeout`
（等满上限、上千次探测全 404）——`provider_ready`（成功）事件在**所有**历史轮次中
**从未出现过**，给到 900 秒那轮仍是 `waited=900.34 attempts=1810` 全 404。

新判据与测速真正走的路径**同源**（`switch_proxy` 切的就是这个组）：**判据与被测对象必须
同一条路径**，否则「等到了」也不代表真的能测。这次定案靠**对照实验**（只差一个变量：
内置组名 vs provider 成员名），而不是继续加等待——此前所有加时（60 → 按加载量放大 →
900 秒）都换不来「等到」，只换来白烧预算。

**超时按「mihomo 实际加载量」自动放大**（`_provider_ready_timeout(loaded)` = `60 秒 + 0.3 秒/节点`，
**封顶 300 秒**），**不得写死 60**。展开耗时随节点数增长，写死 60 秒在大池子上必然等不完。

⚠️ **封顶 300 秒，不要再往上加**（2026-09-23 从 900 下调）。加时换不来「等到」，只换来
「白烧预算」（15 分钟纯空转）。降级路径本身是安全的：taier 关掉测活、全量放行去测速；
gitee / cdn 不探活，只是少一道保险。故压到 5 分钟，把预算留给真正产出数据的测速。

⚠️ **参数是加载总量，不是「过滤后要测的候选数」**（2026-09-23 二次修正，踩过一次）。
装填耗时取决于 mihomo **装了多少**，与调用方之后砍到多少**无关**。第一版按候选数算：
加载 20004、过滤后 1539 ⇒ 只给 152 秒 ⇒ 仍等不完（`attempts=322` 全 404）⇒ 旧病复发
（1309 个死节点跑满 16.5 秒 ≈ 6 小时）。故三套调用点都必须显式传 `total_loaded=`——
它取自 `collect_provider_snapshot` 返回的 `provider_snapshot` 各 provider 的 `total` 之和。
测试第 14 组钉住「三套都不写死 60」+「都传 `total_loaded`」+ 放大公式的边界。

系数 0.3 是拿实测反推的下限（2 万 ⇒ 606 秒），不是精确模型。

## 为什么测速侧的 provider 健康检查要关掉（2026-09-25）

`build_mihomo_config` 里 `health-check` 现在是 `{'enable': False}`，**不是**
`enable=True + lazy:false`。

原因：非惰性（`lazy: false`）健康检查让 mihomo 在**装载 provider 的那一刻**就对全部节点
做一轮探测。编排轮装载 2.4 万+ 节点时，这一轮自己就把进程压到极限；随后 taier 的
`/group/{组}/delay` 再并发探一遍，mihomo 直接崩：

| 轮次 | 装载 | 组测速结果 |
|---|---|---|
| 36080367499 | 23536 | 4.6s `Remote end closed` → 1771 次 switch 全 refused |
| 36105783471 | 24575 | 第一次崩 → 重启 → 第二次也崩 |

崩了之后 fail-open 会放行，但面对的是一具尸体：1850 个节点全部 `switch_failed`、
零数据、Gist 都不上传。

而测速侧**根本用不到这个结论**：节点收集不按 `alive` 预筛（见「为什么节点收集不等
健康检查」）、`wait_provider_ready` 读的是组成员清单。开着只是白烧一轮 2.4 万次探测，
还把组测速挤死。

需要健康检查语义的是 **`alive_filter`**（发布前筛活节点）：它用自己那份配置，且
**显式要求 `lazy: false`**——`lazy: true` 时 `alive` 永远缺失、那一层永远等不到结论。
两处语义不同，**不要互相抄**。

**为什么不能只等 `/version`**：`wait_mihomo()` 只等控制器 HTTP 监听到来（毫秒级），
而 `/providers/proxies` 给出的是**声明清单**，不等于节点已装进组。不等就往下走，三套各有
各的坏法：

| 套 | 未装好时的表现 | 可见性 |
|---|---|---|
| taier | 组测速拿不到延迟表 ⇒ 探测层关闭、死节点不再被提前筛掉 | **报错**，上千死节点跑满测速窗口 |
| gitee / cdn | `switch_proxy` 切 `AUTO` 组时对未注册成员名**不报错、静默保持原选择**，测的其实是上一个节点的链路 | **静默失真**，结果照常记成功 |

CDN 的窗口很窄（run 35164561624）：读快照 `23:58:30.528` → 首个 `node_test_start`
`23:58:32.041`，**仅 1.5 秒**。它没炸纯粹因为 `AUTO` 组静默兜底。

⚠️ 由此派生的一条已存在隐患：`switch_proxy` 只看 `mihomo_api_put` 是否抛异常；若将来
mihomo 对「组里不存在的成员」改为报错，gitee / cdn 会立刻把整轮记成 `ok: False`
⇒ 通知全是 `❌ 失败`。等装填完成后这个窗口被关掉，两条路都绕过了。

组名收敛在常量 `PROXY_GROUP_NAME`（`speedtest_gitee.py`）：**配置生成 / `switch_proxy` /
`wait_provider_ready` / 组测速四处必须同一个**——分散写死时漏改一处不会报错，而是
「静默测错对象」（切的是 A 组、探的是 B 组），极难发现。

## 运维与排查

| 现象 | 原因 / 处置 |
|---|---|
| `nodes_collected: 0` 但 `source_mapping_built` 有值 | 见[为什么节点收集不等健康检查](#为什么节点收集不等健康检查)。`provider_snapshot_collected` 会给出 `total` / `alive` / `collected` 三个数，`collected == total` 即为正常（`alive` 为 0 只是还没探完） |
| `nodes_collected: 0` 且 **`source_mapping_built entries: 0`** | 先找 `subscription_fetch_skipped` —— 那是**订阅根本没取到**（不是节点都判死了），`source_url` + `index` + `error` 三样齐；若 `error` 是 `SSL: UNEXPECTED_EOF_WHILE_READING` 一类，就是取文途中被掐断。几 MB 的订阅体（Gist raw）上这很常见，`fetch_text` 已带 4 次指数退避重试，中间会打 `subscription_fetch_retry`；**见到 retry 后成功属正常自愈**。重试全失败才 `skipped`，此时该 `exit`/产出的方向是「定位网络或订阅源」，不要去查解析与判据（判据没参与）。**这条以前是静默的**：一次抖动 = 整份订阅消失 = 零节点 + job 仍报成功 |
| GitHub API 403/限流 | 匿名调用共享出口 IP 60 次/h；workflow 已带 `GITHUB_TOKEN`/`GH_TOKEN` 回退 |
| Gitee 仓库体积超限 | `rebuild_gitee_repo` 自动重建私有仓库 `proxy-speedtest-temp` |
| **节点 push 全部超时**（连直连基线也超时） | Gitee 仓库超限/被回收时 git 常表现为**挂起超时**而非明确报错（2026-09-08 实测连续三轮 0 成功）。引擎已自愈：本轮尚无成功 push 且节点失败为超时/被拒/size limit 时，自动 `rebuild_gitee_repo` 一次并重试该节点（日志 `repo_rebuild_on_push_timeout`，每轮限一次）；若重建后仍失败，多为 Gitee 账号级限流，等下一轮即可 |
| Gist 404 | **分两种**：真失效（重试仍 404 且 GET 也读不到）→ 新建并回填 secret；瞬时抖动（重试成功，或 404 但 GET 可见）→ 复用原 gist，绝不再建。见 [Gist 约定](#gist-约定三套各用各的)。日志 `gist_patch_404_retry` / `_recovered` / `_recreate` 三选一可定位 |
| Gist 422（`missing_field: files`） | 2026-09-08 修：`update_gist` 曾在旧文件已删除后每轮仍发 `旧文件名: null`，GitHub 判 files 无有效字段。现在先 GET 探测旧文件是否存在才发删除项，且 422 会去掉删除项重试一次 |
| 订阅可用性存疑 | 本工作流只负责导出达标节点、不做可用性回拉验证（2026-09-10 移除：抽检信息量低于本轮 push/clone 实测，且失败只制造误导性告警）。订阅端导入失败的排查重心回到「节点是否达标、订阅源本身是否可用」 |
| 该工作流当前在 Actions 里被手动禁用 | 重新启用后按计划运行 |
