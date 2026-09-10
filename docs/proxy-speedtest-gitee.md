# Gitee 上下行 + 延迟测速（proxy-speedtest-gitee）

> 代码：`.github/scripts/proxy-speedtest/speedtest_gitee.py`
> 入口：`.github/workflows/proxy-speedtest-gitee.yml`

## 三件套总览

仓库代理测速三件套**按测速点命名**，口径互不可比：

| 工作流 | 测速点 | 口径 | 引擎/链路 | 文档 |
|---|---|---|---|---|
| `proxy-speedtest-gitee` | Gitee 私有仓库 | 经代理 git push 上行 + clone 下行 + gitee.com HTTP 延迟 | 本文 | — |
| `proxy-speedtest-cdn` | 国内 CDN/镜像站 + baidu/taobao | 经代理单连接 curl 下载 + HTTP 计时延迟 | `speedtest.py` | [cdn](proxy-speedtest-cdn.md) |
| `proxy-speedtest-taier` | 泰尔三网（电信/联通/移动测速服务器） | taierspeedtest 延迟 + 单/多线程上下行 | `taier_speedtest.py` + mihomo TUN | [taier](proxy-speedtest-taier.md) |

调度：UTC 02/08/14/20（北京 10/16/22/04）。

## 双重角色

`speedtest_gitee.py` 既是独立工作流引擎，也是三件套共享引擎：

1. **独立引擎**：both 模式（默认）下对每个可用节点经 mihomo 代理测三项——git push
   测速文件到 Gitee 私有仓库（上行）、clone 拉回（下行）、对 gitee.com 做 HTTP 计时
   （延迟，与 cdn 的 `latency_probe` 同实现）；
2. **共享引擎**：mihomo 下载/配置/生命周期、订阅拉取解析、节点快照与切换在本文件；
   与引擎无关的纯共享层（订阅导出策略、通知排版、归属查询、Telegram 发送、Gist 上传、
   进度日志）在 `speedtest_common.py`（2026-09-08 从本文件抽出，共享代码不再挂在 gitee
   名下），本文件按需 import、无兼容再导出；`speedtest.py` / `taier_speedtest.py`
   import 复用。顶层的 signal/异常通知只在 `main()` 注册，import 复用不会误触发。

## 功能与链路

1. 拉取并解析订阅（base64 自动解码），写成本地 provider 文件；
2. 下载/启动 mihomo（HTTP 17890 / SOCKS 17891 / mixed 17892，控制器 19090），provider
   健康检查后 `collect_provider_snapshot` 取存活节点；
3. 准备 Gitee 私有仓库（`ensure_gitee_remote`：不存在则创建，超限自动 `rebuild_gitee_repo`）；
4. 生成 `PROXY_SPEEDTEST_SIZE_MIB` MiB 测速文件；
5. 逐节点：切换 AUTO → 经代理 HTTP 计时测 gitee.com 延迟（`latency_probe`，采样
   `PROXY_SPEEDTEST_LATENCY_SAMPLES` × 超时 `PROXY_SPEEDTEST_LATENCY_TIMEOUT`）
   → 经代理 `git push`（单流 HTTPS，超时 `PROXY_SPEEDTEST_PUSH_TIMEOUT`）按推送耗时
   换算上行 → `git clone` 拉回（超时 `PROXY_SPEEDTEST_CLONE_TIMEOUT`）换算下行；
6. 汇总 → 按**订阅导出策略**判定达标节点（见[订阅导出策略](#订阅导出策略三件套共用)）导出到专属 Gist
   （`update_gist`，只上传不回拉；2026-09-10 已移除原先「第二个 mihomo 实例（19690/19691）
   回拉 Gist raw + 抽样验证」的步骤，见[运维与排查](#运维与排查)）；
7. Telegram 推 `✅ Gitee 测速完成`（TOP 节点三项指标 + 订阅状态）。

## 运行模式与直连基线

`PROXY_SPEEDTEST_MODE`（2026-09-08 起默认 `both`）：

- `both`：↑上传（push）+ ↓下载（clone）+ 延迟三项全测，三件套指标口径对齐；
- `push-only`：只测经代理上行（历史模式，可用 env 退回）；
- `git_direct_speedtest`：不经代理直连 Gitee push/clone，作为「家庭宽带上行」基线对比
  （`PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT` / `_MAX_ATTEMPTS` 控制），不受模式影响。

## Gist 约定（三件套各用各的）

- secret：`PROXY_SPEEDTEST_GIST_ID`（本工作流）、`PROXY_SPEEDTEST_CDN_GIST_ID`（cdn）、
  `PROXY_SPEEDTEST_TAIER_GIST_ID`（taier）——分别注入各 workflow 的
  `PROXY_SPEEDTEST_GIST_ID` env，脚本读同名 env，共享代码零特判；
- 文件名/描述经 `PROXY_SPEEDTEST_GIST_FILENAME` / `PROXY_SPEEDTEST_GIST_DESCRIPTION`
  覆盖（`_gist_identity`，实现在 speedtest_common.py），本工作流为
  `proxy_speedtest_gitee_subscription.yaml` / `proxy speedtest subscription (gitee 上行/下行/延迟)`；
- id 缺失或 404 时自动新建（`update_gist` → `create_gist`），新 id 写回
  `~/.openclaw/.env`（runner 上不跨 run 持久）+ TG 通知给链接，需回填 secret。

## 环境变量

### secrets

| secret | 用途 |
|---|---|
| `PROXY_SPEEDTEST_SUB_URLS` | 订阅源（三件套共用） |
| `PROXY_SPEEDTEST_GIST_ID` | 本工作流专属订阅 Gist 的 id |
| `PAT` | gist 写权限（默认 GITHUB_TOKEN 无 gist scope 会 403） |
| `GITEE_PRIVATE_TOKEN` | Gitee 私有仓库建仓/push |
| `PROXY_SPEEDTEST_GITEE_OWNER` | Gitee 私有仓库属主 |
| `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` | 通知 |
| `GITHUB_TOKEN` | GitHub API 匿名限流时的认证回退 |

### 可调参数（workflow 注入）

| env | 默认 | 说明 |
|---|---|---|
| `PROXY_SPEEDTEST_MODE` | both | both = 上行+下行+延迟三项；push-only = 只测上行 |
| `PROXY_SPEEDTEST_SIZE_MIB` | 10 | 测速文件大小 |
| `PROXY_SPEEDTEST_PUSH_TIMEOUT` / `CLONE_TIMEOUT` | 30 / 30 | 单次 push / clone 超时 |
| `PROXY_SPEEDTEST_LATENCY_SAMPLES` / `_TIMEOUT` | 4 / 8 | gitee.com 延迟采样次数 / 单次超时 |
| `PROXY_SPEEDTEST_DIRECT_BASELINE_TIMEOUT` / `_MAX_ATTEMPTS` | 60 / 5 | 直连基线 |
| `PROXY_SPEEDTEST_SWITCH_SETTLE_SECONDS` | 1.5 | 切节点后等待 |
| `PROXY_SPEEDTEST_DETACH` | 0（workflow 注入） | 1 = detach 后台自跑（本地手跑用） |
| `PROXY_SPEEDTEST_GIST_FILENAME` / `_DESCRIPTION` | 见 workflow | Gist 文件名/描述 |
| `PROXY_SPEEDTEST_MIN_MEGABIT` | 10 | 达标阈值（兆） |
| `PROXY_SPEEDTEST_SPEED_METRIC` | upload | 判定指标 `upload`/`download`；达标数 < 最少节点数时自动改用另一指标（双向对称） |
| `PROXY_SPEEDTEST_MIN_NODES` | 1 | 上传订阅的最少节点数，不足则不上传（通知显示「达标不足 N 个」） |

### 订阅导出策略（三件套共用）

三件套共用同一套达标判定（`speedtest_common.resolve_subscription_policy` +
`build_subscription_bundle`，workflow env 已接仓库 **Variables**，Settings → Secrets and
variables → Actions → Variables 可随时改，留空走默认）：

1. **阈值**：`兆 = round(MiB/s × 8)`，≥ `PROXY_SPEEDTEST_MIN_MEGABIT`（默认 10）为达标；
2. **判定指标**：`PROXY_SPEEDTEST_SPEED_METRIC`（默认 `upload` 按上行）；
3. **双向回退**：主指标达标数 < `PROXY_SPEEDTEST_MIN_NODES` 时自动改用另一指标重新判定
   （例：默认按上行，上行达标 0 个 → 改按下行）；另一指标也不更多时维持主指标；
4. **最少节点数**：最终达标数仍 < `PROXY_SPEEDTEST_MIN_NODES` 就不上传订阅
   （日志 `gist_skipped`，通知显示「达标不足 N 个 · 阈值 ≥X兆（按上行/下行）」）。

实际采用的指标会写进日志（`subscription_policy` / `subscription_metric_fallback`）与
TG 通知文案。节点必须有原始配置（`source_entry.proxy`）才计入达标——否则导不进订阅。

**TOP5 排序与判定指标一致**：三件套的 TOP 榜都按实际采用的指标排序，通知标题标注
`🏆 最快节点 · N · 按上传/按下载`，避免出现「按上传导出订阅、却按下行排 TOP」的自相矛盾。

## Telegram 通知与兜底

| 标题 | 触发 |
|---|---|
| `✅ Gitee 测速完成` | 正常完成 |
| `⛔ Gitee 测速异常终止` | 收到 SIGTERM/SIGINT（run 被取消/超时），`handle_termination_signal` 兜底 |
| `❌ Gitee 测速异常退出 · <阶段>` | 任一 `run_stage` 阶段抛异常（阶段即原因：`订阅源拉取/解析`、`mihomo 启动/配置`、`Gitee 仓库准备`、`测速文件准备`、`Gist 更新/通知`…） |

辅助机制：`/tmp/proxy_speedtest.lock` 每轮循环 touch（供外部心跳判 stale）；
`maybe_detach_self` 支持 detach 后台自跑（CI 里固定关闭）。

## 运维与排查

| 现象 | 原因 / 处置 |
|---|---|
| GitHub API 403/限流 | 匿名调用共享出口 IP 60 次/h；workflow 已带 `GITHUB_TOKEN`/`GH_TOKEN` 回退 |
| Gitee 仓库体积超限 | `rebuild_gitee_repo` 自动重建私有仓库 `proxy-speedtest-temp` |
| **节点 push 全部超时**（连直连基线也超时） | Gitee 仓库超限/被回收时 git 常表现为**挂起超时**而非明确报错（2026-09-08 实测连续三轮 0 成功）。引擎已自愈：本轮尚无成功 push 且节点失败为超时/被拒/size limit 时，自动 `rebuild_gitee_repo` 一次并重试该节点（日志 `repo_rebuild_on_push_timeout`，每轮限一次）；若重建后仍失败，多为 Gitee 账号级限流，等下一轮即可 |
| Gist 404 | id 失效 → 自动新建新 Gist，TG 给链接后回填 secret |
| Gist 422（`missing_field: files`） | 2026-09-08 修：`update_gist` 曾在旧文件已删除后每轮仍发 `旧文件名: null`，GitHub 判 files 无有效字段。现在先 GET 探测旧文件是否存在才发删除项，且 422 会去掉删除项重试一次 |
| 订阅可用性存疑 | 本工作流只负责导出达标节点、不做可用性回拉验证（2026-09-10 移除：抽检信息量低于本轮 push/clone 实测，且失败只制造误导性告警）。订阅端导入失败的排查重心回到「节点是否达标、订阅源本身是否可用」 |
| 该工作流当前在 Actions 里被手动禁用 | 重新启用后按计划运行 |
