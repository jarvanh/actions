# openlist.yml 同步修复实施计划（2026-09-13）

- 代码基线：起步于 `5c01d32`（`task_engine.sh` 与被剖析的 run 34728107625 所在 commit 零差异，结论可平移）；**现已落地到 `acbbff5`**（Phase 1 全量 + Phase 2 第一批，见 §进度日志）
- 依据：仓库根报告三份（`openlist-sync-glm-f-report` / `openlist-sync-feasibility-report` / `openlist-sync-assessment-ds4.1-report`，均为 2026-09-13）+ 对 HEAD 的代码核验 + 审核新发现（§1.4）
- **本文档是执行蓝图：与报告冲突时以本文档为准；本文档与代码冲突时现场查证并更新本文档进度。**

---

## 0. AI 接手须知（每次开工先读这一节）

**任务**：修 `openlist.yml` 网盘同步——让它从「每轮 5.5h 全被硬杀、零真实落盘、游标卡死在同一个后端」变成「能优雅到站、指标可信、开始真正搬数据」。判断标准只有 §6 的退出标准 A–E，别自创口径。

**当前阶段**（2026-09-14 +08 更新）：

| 阶段 | 状态 |
|---|---|
| Phase 0 解堵 + 基线 | ✅ 完成 |
| Phase 1（F0–F5） | ✅ 全部落地并 push，**已在生产验证**: run 34770092689 首次拿到非硬杀的 success，F1/F5/F0/F4 实锤生效（逐条证据见 §6） |
| Phase 2 第一批（F6/F7/F8/F11） | ✅ 落地（`e5296ed` / `3737688`），**尚未被任何一轮跑过** |
| F6 触发源接线（F5 全拒 → `SYNC_BACKEND_DEAD`） | ✅ 落地 `acbbff5`（**2026-09-14 补 push**，此前只在本机 commit、origin/main 没有，见进度日志），未跑过；把熔断点从 ~2.5h 提前到批次 1 巩固结束，见 §4 · F6 |
| Phase 2 剩余 | F9 **前提已核实、范围收窄**（见 §4 · F9）；F10 / F12 / F13 **本轮评估后推迟**（理由见 §4 · F10/F12/F13） |
| F3 第二步 | 根目录文件的短哈希兜底 —— **本轮评估后推迟**：该死角从未复现（日志 `无目录可换` 0 次），收益亦存疑，见 §4 · F3 |
| Phase 3 | F14 三后端写入自检起；**Gate 1 已逼近**（见 §7） |

**开工四步**（一个观察周期 5.5–6h）：

1. `git fetch` 看落后数；`gh run list --workflow=openlist.yml --limit 5 --json databaseId,status,conclusion,event,createdAt,headSha` —— **先核对 `headSha` 是不是你要验证的那版代码**：schedule 轮钉的是「创建那一刻」的 main sha，新 push 只影响之后创建的轮次。
2. `gh run view <id> --log > /tmp/ol.log`（in_progress 的取不到日志，等结束再取）后按 §6 关键词 grep。
3. 本机 `rclone cat onedrive:/logs/sync_state/{task_rotation.json,trend.jsonl,backend_dead.json}` 看游标 / 趋势 / 跨轮熔断命中。
4. 对照 §6 记录增量 → **更新本文档的复选框与 §进度日志**。这是唯一的跨会话进度真源（`.codebuddy/memory/` 是本机私有记忆，不在 git 里，别的 AI 读不到）。

**红线**（§8，无例外）：run_mode 只允许「同步」与「调试 · 修复管线测试」；动通知必跑 `bash skills/telegram-notify-audit/scripts/render_preview.sh`；改完跑 22 套串行回归 + 全部日志 `grep "command not found"` 必须为空；push 前 `git fetch` 并更新本文档。

**必须问用户的**（AI 权限外，见 §9）：wopan176 账号配额/限流/封禁/token 状态（Gate 1 的关键输入）、F16 主副本选型、F15 `transfers=2` 实验批准。

---

## 1. 问题总览

### 1.1 三份报告共识（可直接采信）

1. **接力机制健康**（`session_hold`/`self_retrigger` 已修好并验证），marker/游标增量持久化无丢失。
2. **近 12 轮 0 success**；近 4 轮同步 step 耗时精确 330m12s±1s ⇒ 全部被 `timeout-minutes: 330` 硬杀，320min 预算优雅到站从未发生。直接根因：**文件批次循环没有预算闸**（`task_engine.sh` L1459 起，核验属实）。
3. **wopan176Crypt 是主故障后端**，两类失败并存：
   - 硬失败：密文名 >100B（wopan 实测上限）→ 405。文件级超名 24%，目录级超名 74%（父目录超长连坐短名文件）。
   - 软失败（假成功）：rclone 报 `Copied`、重启容器取真值后零落盘。跨轮重复率 32.3%，同一文件 24h 内「成功复制」9 次仍缺失。
4. **熔断粒度过粗**：405 路径特异性被提升为后端级熔断（`OPENLIST_BACKEND_DEAD_THRESHOLD=3`），短路了本可生效的短哈希目录/zip 分卷兜底；写探针探挂载根+lsf 读回不过缓存（假阳性+假阴性并存）。修复率 8.6% 且 183 全是「沿用上轮」。
5. **轮转游标钉死**：`task_rotation.json` cursor=8（task2→wopan176Crypt/2）attempts=6，上限 8（≈44h）；另外 15 对近四轮零执行，**baidupanCrypt / wopan175 / aliyundriveCrypt 可写性零证据**。
6. **指标双失真**：`remaining_bytes` 源端列举失败静默归零（单轮假降 2.49TB）；`transferred_bytes` 强杀丢内存计数（同值重传 churn：18282971×3、171257627×2）。
7. **规模与速率**：源端去重 4.12TiB / 16 对 10.1TB（2.25 倍冗余）；实测净传均值 ≈334MB/轮 ⇒ 均值口径 14.5 年、最好轮 2.9 年。**当前路径下不可能完成。**

### 1.2 报告审核裁定（矛盾处怎么采信）

| 矛盾点 | 报告立场 | 裁定 |
|---|---|---|
| 405 成因 | ds4.1「全路径拒写、与名长无关」vs glm-f/feasibility「路径特异性（名长）」 | **采信后者**。ds4.1 的关键证据（22B 文件名照样 405）被 feasibility 的交叉验证推翻：391 个 22B 文件失败源于**父目录名超长**，ds4.1 把目录级超名误读成了「名长无关」 |
| 短哈希目录可写性 | ds4.1「折叠 Copied 但零落盘 ⇒ 后端全死」 vs glm-f「折叠被熔断没实测过，大概率可写」 | **已裁决（2026-09-14，run 34770092689）：采信 ds4.1 的「后端全死」结论**。F3 第一步生效后，目录级批量折叠**真的被执行了**——`19:32:57 🔀 …（44 个文件）→ 短哈希目录 f22c8c73`、`19:36:03 🔀 …（39 个文件）→ 短哈希目录 cb4f0d57`，合计 83 个文件；两次都在 `19:39:01` 熔断（连续 3 个目录不可写）**之前**，即**未被熔断短路**。结果两处都以 `❌ 批量折叠零落盘（rc=0），该目录退回逐文件修复` 收场（19:34:39 / 19:37:37）。⇒ **「缩短名字即可绕过」在真实路径上被直接证伪**：折叠后的 8 字符目录名拿到了实测写尝试、rclone 报 rc=0，后端照样零落盘。名长不再是必要解释，主因是后端整体不可写（与 §1.4 F0 的 transfers 错位叠加） |
| 能否完成 | ds4.1「永不」 vs glm-f「机制能/速率不能」 vs feasibility「修完 P0 约 1.5–2 个月」 | 分解后一致：后端账号可恢复 + P0 修复 + 冗余削减 ⇒ 月级；账号不可恢复 ⇒ 必须切后端（Phase 3）；都不做 ⇒ 等于永不 |
| 质量排序 | — | feasibility 交叉验证最严谨，作主干；glm-f 的速率/预算数学最好；ds4.1 的单轮取证与缺陷清单（缺陷 3/5/6/7/8）全部有效，但顶层结论「全路径拒写、运维层故障」**过推，不采信** |

### 1.3 审核新发现（三份报告都漏掉，已核验代码）

**F0 · 批次路径 transfers 变量错位（疑似假成功主源，优先级最高的一行改动）**

- `openlist.yml:185` 设置 `OPENLIST_TRANSFERS: ${{ inputs.transfers || '1' }}`（输入默认 1，描述明确「wopan176 保持 1——run 32749862280 整批假成功事故后端」）。
- 但批次 copy（`task_engine.sh:1489`）与巩固串行重试（`:1095`）读的是 **`OPENLIST_TARGET_TRANSFERS:-4`**——该变量全库无人设置 ⇒ **批次路径实际一直 transfers=4**，而日志（`:1495`）硬编码打印「transfers=1」掩盖了这一点。
- 批次循环头注释（L1480-1483）自述：「批次 copy 此前无 transfers 限制（默认 4 并发上传），慢后端来不及持久化 → object not found / PUT 假成功——正是批次 exit=4 与预览差值不动的直接诱因之一」。**即低并发保护加错了变量名，从未生效。**
- 这解释了 34728107625 的形态闭环：批次 copy transfers=4 假成功 → 巩固发现 1037 缺失 → 串行重试也 transfers=4 假成功（`retry_copied=1037`）→ 重启取真值仍 1037 缺失 → `BATCH_BACKEND_DEAD` 判据要求 `retry_copied -eq 0` 恒不触发 → 照常开批次 2/3。
- 注意：`sync_engine.sh:195`（初始 sync）与 `file_fix_pipeline.sh:412`（折叠）读的是正确的 `OPENLIST_TRANSFERS`，只有 task_engine 的两处错位。

### 1.4 本计划不解决的事

wopan176 账号本身的配额/限流/封禁/token 状态——需用户登 OpenList 管理面或网盘账号后台确认（§9）。100B 上限与假成功可能同源于此。

---

## 2. Phase 0 · 解堵与基线（无代码改动，立即执行）

- [x] **0.1 取消僵尸 run**：2026-09-14 00:15 +08 已 cancel `34752801560`（in_progress 5h29m）与 `34763535089`（pending 1h31m），两者均 completed/cancelled。副作用: 自续触发判定「人工取消，不接力」，接力链中断。
- [x] **0.2 基线快照**：已存 `/tmp/openlist-remediation-baseline.txt`（task_rotation cursor=8/attempts=6、trend.jsonl 末 3 条、近 5 轮结论、run 34752801560 六项取证）。
- [x] **0.3 不手动触发新同步**：Phase 1 落地前未触发。Phase 1 全量 push 后（2f60f26）于 2026-09-13 16:56Z 手动 dispatch `34770092689` 开观察轮——接力链已断且 cron 1h 未见新 run。

## 3. Phase 1 · P0 修复（恢复优雅到站 + 熔断准确，逐项 commit）

完成本阶段全部条目后统一跑 §8 回归再 push。

### F0 批次路径 transfers 统一（一行改动，先做）✅ 已落地（339d58a）

- 位置：`task_engine.sh:1095`、`:1489`。
- 改法：两处 `OPENLIST_TARGET_TRANSFERS:-4` → `OPENLIST_TRANSFERS:-1`；`:1495` 与 `sync_engine.sh:200` 的日志改为打印实际值（`transfers=${_ol_transfers}`），消除硬编码烟幕；同步修正 L532-535 注释。
- 验收：日志出现真实 transfers 值；下一轮 wopan176 批次的顽固缺失数显著下降（对照基线 1037）。
- 风险：极低。串行重试本来就是「串行兜底」语义，transfers=1 与其本意一致。

### F1 批次循环预算闸（近 4 轮 failure 的直接根因）✅ 已落地（339d58a）

- 位置：`task_engine.sh` `sync_by_file_batches` 批次循环（`:1459` `for i in $(seq 0 $batch_num)`，`if [ -s "$bf" ]` 块内、批次启动前）。
- 改法：
  1. 循环头加 `sync_budget_stop && { SYNC_TIME_EXHAUSTED=1; break; }`（与同步对级 `:171` 同款文案「优雅收摊」）。
  2. 批内修复管线置位的 `SYNC_TIME_EXHAUSTED=1` 必须阻止下一批开启：循环头加 `[ "${SYNC_TIME_EXHAUSTED:-0}" = "1" ] && break`。
  3. 新增 `OPENLIST_BATCH_MIN_SLICE_SECONDS`（默认 3600）：批次的最小工作片。600s 假设已被「一批 = copy+巩固+修复 ≈ 1h+」实测推翻（批次 1 实测 1h17m）。其他层仍用 600s。
- 验收：新增测试用例（deadline 已过 → 不开新批、优雅返回、SYNC_TIME_EXHAUSTED=1）；下一轮日志出现「时间预算将尽，优雅收摊」且 conclusion=success。
- 风险：闸过紧导致零批开跑——320min 预算下预留 60min 片长不会误伤正常批次。

### F2 逐文件修复循环熔断短路（单轮省 ~119min）✅ 已落地（339d58a）

- 位置：`file_fix_pipeline.sh:762-767`（时间预算检查旁并列）。
- 改法（ds4.1 草案可直接用，`_fix_backend_root_of` 在 `file_fix.sh:725` 已有）：
  ```bash
  local _fix_be_root; _fix_be_root=$(_fix_backend_root_of "$dest_path")
  if [ "${_BACKEND_DEAD[$_fix_be_root]:-0}" = "1" ]; then
    echo "🛑 后端 ${_fix_be_root} 本轮已熔断，跳过剩余 $((_cb_total - _cb_done)) 个文件" | tee -a "$LOG_FILENAME"
    SYNC_BACKEND_DEAD=1   # 注意：不要置 SYNC_TIME_EXHAUSTED——「预算到点」与「后端故障」两种出口语义不得混用
    break
  fi
  ```
- 验收：单测（预置 `_BACKEND_DEAD[root]=1` → 循环立即退出且 `SYNC_BACKEND_DEAD=1`）。

### F3 熔断与名长解耦（修 8.6% 修复率，本阶段最复杂）✅ 第一步已落地（2f60f26）

- 位置：`file_fix.sh:819-833`（后端熔断计数）+ 名长诊断消费路径。
- 原则：
  1. 名长诊断已命中「密文名 > 后端已接受最长（100B）」的目录/文件，属**内容性**失败：不进入 `_BACKEND_DEAD` 连续计数，直接走短哈希目录折叠 / zip 分卷等替代形态（不被熔断短路）。
  2. 熔断计数只收集「短名（含折叠后的 8 字符哈希目录）也写不进」的情形。
  3. 补「文件位于目标端根目录、无目录可换」死角：根目录文件也有短哈希兜底目录。
- 验收：调试模式对 wopan176 跑含超长名的任务（`fix_test_max=20`）：短哈希目录有**实测写尝试**（日志见 rclone 调用而非「熔断推断」）；修复成功率（新落盘口径）> 8.6% 基线。
- 风险：改判定最深的逻辑。建议两步走：先做「不计数+不短路」（小 diff），根目录兜底第二步再做。

**第一步验收已达标（2026-09-14，run 34770092689 实测）**：短哈希目录拿到**实测写尝试**——两次目录级批量折叠（44 + 39 = 83 个文件）都落在熔断（19:39:01）**之前**，日志见 `🔀 目录级批量折叠 … → 短哈希目录 f22c8c73 / cb4f0d57` 及其后的 rclone 调用，不是「熔断推断」。修复成功率仍未达标的**原因已不在本项**（折叠路径自身也零落盘，见 §1.2 裁决行）。

**第二步（根目录短哈希兜底）本轮评估后推迟 —— 该死角从未真实复现**：

- 缺口位置确认无误：`file_fix.sh:1023-1027`，`file_dir_rel = "."` 或空时直接 `_HASH_DIR_FAIL_REASON="无目录可换"` 并 `return 1`。
- 但 `run 34770092689` 全量日志里 `无目录可换` **出现 0 次** ⇒ 根目录文件这一形态在本轮 1036 个触碰文件里一个都没走到。
- 收益亦存疑：根目录文件唯一可换的元素就是**文件名**，而方法 2 `copyto_shorthash`（`file_fix.sh:937-`）已在同一目录里把文件改成 8 字符哈希名；再套一层短哈希**目录**只会让路径**更长**（`<dest>/<原名>` → `<dest>/<8hex>/<原名>`），与「压短路径」的目的相反。只有当「目标端根目录不可写、其下新建子目录却可写」这种反常后端行为成立时才有收益，目前零证据。
- **重启条件**：日志里真正出现 `无目录可换`（或根目录文件其余方法全败）再落地，并同步补单测。现在动手属于「为不存在的问题加分支」，违反 §6 迭代纪律。

### F4 写探针分层（探针判死即整轮省 5.5h）✅ 已落地（2f60f26）

- 位置：`openlist_driver.sh:380-434` `_backend_write_probe`。
- 改法：1) 探针目标从挂载根 `${root}/${probe_name}` 改到**真实任务子路径**（`${dest_path}` 自身或其一级子目录）；2) `:409` 的 lsf 读回前先调 OpenList `/api/fs/refresh` 刷新缓存（否则 PUT 假成功活在缓存里，读回拦不住——该函数注释声称能拦，实测拦不住）。
- 验收：探针结论按（后端 × 路径深度）分层记录；34728107625 形态（探针通过 89s 后即大量 405）不再出现。

### F5 后端写入全拒判据（假成功下恒不触发）✅ 已落地（339d58a）

- 位置：`task_engine.sh:1118-1133`。
- 现状：判据要求 `retry_copied -eq 0`，假成功时 `retry_copied=1037` ⇒ 恒假（该轮 grep「后端写入全拒」= 0）。
- 改法：判定下移到 stubborn 算出之后（`:1139-1151`），判据改 `stubborn_n >= touched_n && touched_n >= 3`。**保留语义**（L1125-1127 用户规格）：熔断只中止剩余批次，本批顽固缺失仍转修复管线，不豁免。
- 验收：同形态轮次在批次 1 巩固后立即中止批次 2/3（省 ~80min），单测覆盖「假成功（retry_copied>0 但 stubborn==touched）」用例。

---

## 4. Phase 2 · P1（熔断传播 + 指标可信 + 防僵尸）

### F6 后端熔断跨轮持久化 ✅ 已落地（e5296ed）
`sync_state/backend_dead.json`：熔断时写挂载根+时间戳+TTL（默认 12h，死后端常是暂态：登录/限流）；下轮 task_engine 入口读取、跳过该后端的同步对（游标后移）。边界：全部 OpenList 后端都死 → 忽略跳过标记并告警（不许全线停摆）。收益：游标从「44h 才让路」降到 1 轮。

**F6 补充 · 触发源接线（本轮落地，未跑过）**：F6 原先只认 `SYNC_BACKEND_DEAD=1`，而该标志的两个来源都不好用——① 入口写探针（`sync_engine.sh:152`）在 run 34770092689 里**通过**了（探针打的是任务子路径、后端仍照收 405/假成功）；② 修复管线的目录级熔断（`file_fix_pipeline.sh:781`）同轮实测晚至 19:39、开跑约 2.5h 后才触发。于是"整批 1036 个触碰文件零落盘"这种最硬的证据反而不会让后端进入跨轮熔断。现把 F5 的「后端写入全拒」判据（`task_engine.sh` `_batch_consolidate`，`_truth_confirmed` + `stubborn_n >= touched_n >= 3`，即容器重启复核后本批 100% 未落盘）同时置 `SYNC_BACKEND_DEAD=1`，熔断点从 ~2.5h 提前到批次 1 巩固结束（实测 1h17m）。语义不变：本批顽固缺失仍转修复管线（F5 既有用户规格）。

### F7 修复成效拆分（让零产出告警真正生效）✅ 已落地（3737688）
`file_fix_pipeline.sh:1126-1136` 的 `add_ok` 含「沿用上轮修复」→ 拆 `ROUND_FIXED_NEW`（本轮新落盘）/ `ROUND_REUSED`（沿用）；`openlist.yml:503` 告警判据只看 NEW。收尾通知两数分列展示。

### F8 源端清单失败 → remaining 记 unknown ✅ 已落地（3737688）
`task_preview.sh:137-143`（源失败静默 `src_json="[]"`）→ 加 `PREVIEW_FAIL_SRC_PAIRS` 计数 + 与目标端同款通知提示；`sync_trend.sh:50` 任一源端失败时写 null，不参与求和。趋势曲线不再出现 TB 级假进展。

### F9 字节计数落盘
记账点 `task_engine.sh:316`、`:869` 改为即时追加 `/tmp` 计数文件（强杀后收尾仍可读）；顺带排查同值重传 churn（同批内容轮轮重传）。

**前提已核实（2026-09-14，部分不成立，改动范围需收窄）**：趋势口径的记账**本来就是即时落盘**——`sync_trend.sh:42-46` `trend_record_transferred` 每次调用即 `echo >> /tmp/ol_trend_transferred.log`，收尾 `trend_record_and_notify` 只做 `awk` 求和（`sync_trend.sh:81-84`），所以"强杀丢内存计数"对 trend 这条链**不成立**（硬杀轮的 trend 样本确实写出来了，见 §6 · C）。F9 真正剩两件：
1. **核对覆盖面**：确认所有传输路径都调了 `trend_record_transferred`（已知 `task_engine.sh:437`、`:1001`；批次路径 `:1738` 只把字节累加进 `batch_transferred_bytes` 供进度行展示，是否另需记入趋势待查）。
2. **churn 已确诊（新证据）**：`trend.jsonl` 里 `transferred_bytes` 出现**逐字相同的重复值**——`18282971` 连续三轮（09-11 11:36 / 09-11 21:45 / 09-12 06:22）、`171257627` 连续三轮（09-13 05:18 / 10:53 / 16:17），而同期 `remaining_bytes` 摆动达 2.5TB。被 330min 硬杀的三轮不可能凑出字节级完全一致的真测量 ⇒ **同一批内容每轮被重新"传输"一次**（rclone 照报 Copied、后端零落盘），与 §6 · C「transferred 2.08GB vs 真实落盘 0」同一根因。**结论：`transferred_bytes` 是"rclone 声称量"，不是"落盘量"**，C 达标必须换判据（如用巩固/修复管线的新落盘计数），不能靠修 F9 的落盘时机。

**覆盖面已核实（2026-09-14 第三轮；结论：批次路径整体不计入趋势）**：

- 全库 `trend_record_transferred` 调用点只有两处：`task_engine.sh:437`（`_sync_task_finalize` 尾部，取 `SYNC_TRANSFERRED_BYTES`）与 `:1001`（顶层最终完整同步尾部）。**批次路径没有任何一处调用它。**
- 机制（已核到行）：`sync_by_file_batches` 把每批字节累加进 `batch_transferred_bytes`（`:1749`），但**只**喂给进度行的 `⬆️` 字段（`:1820-1823`），从不回写 `SYNC_TRANSFERRED_BYTES`；函数尾部（`:1855-1862`）为省一次全量扫描把 `OPENLIST_FIX_TEST_MODE` 临时置 1 再调 `sync_with_logging`，而该模式会 `: > "$LAST_ATTEMPT_LOG"` 跳过真实传输（`sync_engine.sh:170-174`）→ 日志为空 → `SYNC_TRANSFERRED_BYTES=0`（`sync_notify.sh:197`）→ `_sync_task_finalize` 记 0。
- 结论：趋势里的 `transferred_bytes` 只反映"未经批次的直接 sync 路径"，而**批次路径正是本域的主传输通道** ⇒ 该数字同时具备「含假成功（偏高）」与「漏批次量（偏低）」两种失真，双重不可用。
- **不改代码**：本项属"指标定义"而非"失败形状"，且本节已定「C 达标必须换判据」。若将来要保留该指标，最小改法是让 `sync_by_file_batches` 把 `batch_transferred_bytes` 并入 `SYNC_TRANSFERRED_BYTES` 再返回——**必须在尾部那次 fix_test `sync_with_logging` 之后赋值**，否则被其 0 覆盖。

### F10 405 fail-fast
初始 sync / 批次阶段：同一目录连续 N（默认 20）个 `405 Method Not Allowed` → 中止该目录本轮尝试（marker 置失败、留给修复管线换形态），不再 2103 个逐个烧完（34728107625 烧了 115min）。监控线程可仿 `_start_batch_progress_thread` 模式。

**本轮推迟（2026-09-14）**：属热路径改动（新增监控线程 + 改「中止该目录」语义），而下一轮要干净地验证 F6/F5 接线（Gate 1 的唯一输入）。且 405 的根因路径已被 F3（名长解耦）+ F6（跨轮跳过死后端）覆盖，先看它们的效果，避免多个热路径改动同轮落地导致归因失真——§6 迭代纪律「失败形状复现优先于新功能」。

### F11 SESSION_HOLD 兜底 ✅ 已落地（3737688）
`openlist.yml:565` `|| 'true'` → `|| 'false'`，与声明默认（false、冲刺期窗口全给同步）一致。现状是颗雷：同步 step 一旦以 success 收场，schedule 轮会真执行 hold 5h。

### F12 `_refresh_openlist_cache` 的无条件 sleep 60 条件化
每子目录前后各一次、一轮 ≈85 次纯 sleep（~85min，预算 26%）→ 改「驱动未就绪时才等待」。落手前先核实现场行数与调用次数。

**本轮推迟 + 计数待实测（2026-09-14）**：静态调用点只有 **3 处**（`sync_engine.sh:66` 8005 重试内、`sync_engine.sh:157` 每次 `sync_with_logging` 一次、`sync_notify.sh:112`），并非「每子目录前后各一次」；「≈85 次/轮」取决于 `sync_with_logging` 一轮被调多少次，**需从真实日志数一遍再动手**（本节自己写的「落手前先核实」）。推迟的另一理由：`/api/fs/refresh` 是异步接口、**没有完成信号**，「条件化」只能靠启发式（轮询 listing 是否稳定），改错会让 rclone 读到未刷新的 stale listing → 重传风暴，代价远大于省下的 85min。

### F13 僵尸 run 心跳检测
自续触发 step 或轮入口：存在 in_progress 且 >45min 无更新的 run → `gh run cancel`。34752801560 形态（step 超时是 330min 后的兜底，不是主防）。

**本轮推迟（2026-09-14）**：自然落点「自续触发 step」被 §8 红线 4 明令禁止改动（接力逻辑已验证健康），只能改走「轮入口新增 step」；且当前**没有**僵尸（在跑的 `34779382573` step 正常推进）。等真正复现僵尸形态再落地，不为不存在的问题加 step。

---

## 5. Phase 3 · 吞吐与结构（决定「能否完成」，含决策点）

### F14 三后端写入自检（先做，是后续一切决策的前提）
调试模式（`run_mode=调试 · 修复管线测试`，`force_sync=true`，`fix_test_max=5`）对 baidupanCrypt / wopan175 / aliyundriveCrypt 各跑一次小任务。它们近四轮零执行、可写性完全未知。产出：三后端可写性证据 + 实测速率。

### F15 transfers=2 实验（需用户批准）
F0 落地后，对 wopan176 用 `transfers=2` 调试模式试一批，观察 object-not-found 率与 truth-check 结果。注意输入描述明确「wopan176 保持 1」，实验需用户点头；baidupan/wopan175 可直接试。

### F16 冗余削减（最大杠杆，需用户决策）
16 对 10.1TB → 主副本 4.5TB（工期 1/2~1/3）。依据 F14 结果集中填满**一份**健康后端，wopan176 的 7 对降级或暂停。选哪个后端做主副本由用户定；三个都不健康则问题在账号/配额层，升级用户（Gate 2）。

### F17 预览降耗
预览 30m41s 占预算 9.6%，其中 listing 失败拖满 `OPENLIST_RCLONE_LISTING_TIMEOUT=900`：加短超时 / 失败快弃 / 跨轮源端 size 缓存；或常态 `skip_preview=true`（代价：通知失去待传量信息，需用户选）。

### F18 cron 降频
`0 * * * *` → `0 */2 * * *`。接力正常时 cron 纯兜底，降频让 run 列表干净；代价是兜底延迟 ≤2h。

---

## 6. Phase 4 · 观察循环与退出标准

每轮观察动作（AI 可全权执行）：

1. `gh run list --workflow=openlist.yml --limit 5` 看 conclusion。
2. `gh run view <id> --log | grep -E "优雅收摊|后端写入全拒|熔断|后端跨轮熔断|跳过让路|修复成功 ·|顽固缺失|transfers=|同步时间预算"`。
3. 本机 rclone 读 `onedrive:/logs/sync_state/`：task_rotation.json 游标移动、trend.jsonl 末条、backend_dead.json 命中情况。
4. 对照 0.2 基线记录增量，更新本文档复选框。

**退出标准（全部满足、连续 ≥3 轮）：**

- [ ] A · run conclusion=success（320min 优雅到站，非 330min 硬杀）
      —— 观察轮 34770092689（2f60f26，Phase 1）已达标 1/3: conclusion=success，
      16:56→22:14（5h18m），22:12「时间预算将尽，优雅收摊: 剩余 15 个同步对」，
      22:19 预算到点前正常收摊，全 step success（含收尾/会话保持/Persist/自续触发）。
- [ ] B · wopan176 新落盘口径修复率 >50%，或熔断正确短路且游标 2 轮内轮转离开 #9
      —— 未达标: 该轮批次 1 巩固「后端写入全拒（1036/1036 个触碰文件经复核全部未落盘）」
      ⇒ 整批仍无真实落盘；熔断按 F3 只看短名路径后于 19:39 触发（连续 3 个目录不可写）。
      游标 8→9 已移动（attempts=1）。
      【2026-09-14 补证据】短哈希折叠路径**已被真实尝试、且同样零落盘**：19:32:57 与 19:36:03
      两次目录级批量折叠（44 + 39 = 83 个文件）→ 短哈希目录 `f22c8c73` / `cb4f0d57`，两次都在
      19:39:01 熔断**之前**（即未被短路），结果均 `❌ 批量折叠零落盘（rc=0）`（19:34:39 / 19:37:37）。
      ⇒ B 的「或」分支里「熔断正确短路」成立（F3 第一步达标），但主判据「新落盘口径修复率」仍为 0。
- [ ] C · trend transferred 与 truth-check 确认落盘量差 <2x
      —— 未达标且更需警惕: 该轮 transferred_bytes=2,077,403,120（2.08GB，此前三轮
      恒为 171MB）而真实落盘 0 ⇒ 差值无限大，计数包含了假成功。
      【2026-09-14 补证据】批次 1 巩固的自述就是假成功样本：`本批成功 1036 个 / 直接失败 0 个，
      重启容器校验后端真值` → 校验结果 `后端写入全拒（1036/1036 个触碰文件经复核全部未落盘）`。
      ⇒ rclone 侧「成功 1036、失败 0」与真实落盘 0 可以同时成立：任何基于 rclone 退出码 /
      `Copied` 行数的判据在本后端上都不可信（与 §1.1 第 3 条、§1.3 F0 同源）。
- [ ] D · 非 wopan176 的同步对开始被执行 —— 未达标（该轮仍只碰 wopan176Crypt/2）。
- [ ] E · 零真实落盘轮次能触发零产出告警 —— 该轮未触发（收尾报 `本轮修复成效: 成功 183 ·
      缺失 2146 · 未修复 1963`，而 183 条**全部**是 `♻ 沿用上轮修复`——新落盘 0，持久化验证
      汇总 `复核 183/183 / 通过 183 / 失败 0`——当时尚未部署 F7）；F7 已落地，下轮起看「新落盘」口径。

**2026-09-14 08:05 +08 观察快照（无新完成轮，A–E 无变化）**：

- 最新**完成**轮仍是 `34770092689`（2f60f26，Phase 1）⇒ A–E 证据同上，本轮**无新增数据点**。
- 在跑 `34779382573`（`06cc0df`，**Phase 1 代码**，schedule）：run 创建 09-13 20:00:11Z，
  job 22:14:04Z 才拿到 concurrency 锁开跑（排队 2h14m）；08:05 +08 时 step 18「任务预览与全量同步」
  已跑 1h48m，330min 上限 ⇒ 预计 11:40 +08 前后收场。**它跑的是 Phase 1，不含 Phase 2**，
  观测价值 = 又一个已知形状样本。
- 排队 `34787645966`（`0eef148`，**同为 Phase 1**，06:43 +08 创建，已 pending 1h22m）——
  两个在队轮次都钉在 Phase 2 之前的 sha 上。**但不必人工干预**：在跑轮正常收场后自续触发
  `gh workflow run` 会用「触发那一刻」的 main，届时 Phase 2 全量进入下一轮（同 concurrency 组内
  较旧的 pending 会被顶掉）。
- 本机 rclone 状态：`task_rotation.json` = `{cursor: 9, attempts: 1, updated: 2026-09-13T22:55:23Z}`
  —— 22:55 的写入正是 `34779382573` 的"执行前落盘"（idx 9），即**这一轮又回到上一轮同一对
  wopan176Crypt 上重试**，是 F6 尚未生效的预期形态。`backend_dead.json` **不存在**（F6 从未被
  任何一轮执行过，符合预期）。
- 结论：**Gate 1 仍未到**（要求 Phase 1+2 落地后观察 2 轮，目前 Phase 2 观察 0 轮）。本轮不再
  追加同形状样本的推断，等下一条完整日志。

**2026-09-14 09:10 +08 观察快照（无新完成轮；两项既有认知被实测推翻）**：

- **轮次盘点**（`gh run list`）：最新**完成**轮仍是 `34770092689`（2f60f26，Phase 1，success）⇒ **A–E 无新增数据点**。
  - `34772641066`（2f60f26，Phase 1）→ cancelled；`34787645966`（0eef148，Phase 1）→ cancelled（被更晚的 pending 顶掉）。
  - **在跑** `34779382573`（`06cc0df`，Phase 1）：job 22:14:04Z 拿到 concurrency 锁，同步 step 22:16:54Z 起；320min 预算 ⇒ 预计 **03:36Z ≈ 11:36 +08** 收场。
  - **排队** `34793014398`（`8acfc6f`，含 Phase 2 第一批 F6/F7/F8/F11，**不含 F6 触发源接线**）——它是 Gate 1 的第一个 Phase 2 数据点，会在在跑轮收场后立即开跑（约 03:36Z 起、5.5h 后 ≈ 17:00 +08 收场）。
- **推翻①：`task_rotation.json` cursor=9 不是"又回到 wopan176Crypt"**。注册表索引已逐条导出核对（`SYNC_TASK_REGISTRY` 共 16 对）：
  idx 8 = `task2 → openlist:wopan176Crypt/2`（上一轮实执行的那一对），**idx 9 = `task2-wopan175 → openlist:wopan175/2`**。
  运行日志实锤：`同步对轮转: 本轮从第 9/16 个同步对开始（已连续尝试 6 次）`（17:01:44Z 预览 pass、17:30:32Z 真实 pass 各一次）+ 预览 pass 的 `注册进度: 2/16 onedrive:2 → openlist:wopan175/2`。
  ⇒ 上一轮 §0 写的"cursor 9 = 回到同一对 wopan176Crypt 重试"是**索引误读**；cursor 9 是一个 **wopan175** 对。
- **推翻②：自续触发没有接力**。`34770092689` 尾部实锤 `已有 1 个排队/等待中的运行，跳过接力`（22:13:57Z，护栏 3）。cron `0 * * * *` 会持续把 run 塞进队列，所以"在跑轮收场后自续触发用触发那一刻的 main"**不成立**——接力被护栏跳过，队列里那个**旧 sha 的 pending** 才是下一轮。
  ⇒ **新代码进生产的延迟 ≈ 2 轮（约 11h）**：push 只影响"之后新建的 run"，而队列里已排队的旧 sha pending 会先跑。这正是 `acbbff5`（08:28 +08 commit）至今未被任何一轮执行的原因。**不要再按"push 完下一轮就生效"安排验证节奏。**
- **A–E 逐条（新增实测细节，结论不变）**：
  - A 达标 1/3（证据同上）。新细节：`34770092689` 的**真实 pass 只执行了 1 个同步对**（idx 8）——22:12:09Z `⏳ 时间预算将尽，优雅收摊: 剩余 15 个同步对`（n−i=15 ⇒ i=1）。预览/注册 pass 覆盖全部 16 对但只读。
  - B/C/D/E 全部未达标，证据同下。D 的精确表述：**真实 pass 未执行任何非 wopan176 对**（预览 pass 的 16 对注册不算"执行"）。
- **F6 静态链已复核到行（含两条此前未记录的有利性质）**：
  1. `_backend_dead_mark`（`task_engine.sh:149`）在写文件前**先把 root 塞进内存 `_BACKEND_DEAD_ROUND`** ⇒ 同一轮内后续的 wopan176Crypt 对会被 `:286` 直接跳过，**不必等下轮**（D 有机会在同一轮达标）。
  2. "全线皆死"保护不会误伤 F6：注册表只有 **4 个后端**（aliyundriveCrypt / wopan176Crypt / baidupanCrypt / wopan175），判死 1 个 → `1/4` → 走"跳过让路"分支（`:258` 要求 `_dead_backend_n ≥ _backend_total` 才清空）。
  3. 链路无子 shell：`_batch_consolidate`（`:1755` 直调）→ `sync_by_file_batches` `return 1` 并置 `SYNC_FAILED=1`（`:1780`）→ `_run_registry_entry`（`:309` 直调 `|| true`）→ `run_all_tasks` 的 `elif [ "${SYNC_BACKEND_DEAD:-0}" = "1" ]`（`:320`）→ `_backend_dead_mark`。`SYNC_BACKEND_DEAD` 全库只有 `:308` 一处归零（每对开始前），执行期间无覆盖点。
- **顺带记录（不修）**：`⚠️ raw 计数持续为 0（容器重启后列表未就绪），本轮禁用落盘即时校验` 出现 6 次；`34770092689` 的修复持久化汇总 = `复核 183/183 / 通过 183 / 失败 0`，其中 181 条是 `♻ 沿用上轮修复`（F7 已针对此落地，下轮起看"新落盘"口径）。
- **在跑轮很可能正在执行 `wopan175/2`（待收场日志确认）**：推理链——`34770092689` 收场时游标停在 8/attempts 7（i=0 落盘 `save(8,7)`，i=1 被预算闸 break，未再落盘）；`34779382573` 起手 start=8，i=0 的 idx 8 失败后 `_rot_attempts` 达 8 → 阀门（`:334`）→ `save(9,0)`，i=1 的 idx 9 = `task2-wopan175` → `save(9,1)`（22:55:23Z，与实测 `cursor 9 / attempts 1` 完全吻合）。若成立，则**真实 pass 首次落到非 wopan176 后端**，D 有机会在该轮达标——但它是"轮转自然轮到"而非 F6 之功（该轮不含 F6 接线），**记录时不要把它算成 F6 的功劳**。
- **本轮结论：Gate 1 仍未到**（要求 Phase 1+2 落地后观察 2 轮；目前 Phase 1 观察 1 轮、Phase 2 观察 0 轮）。等 `34793014398` 收场后才有第一个 Phase 2 数据点。

迭代纪律：一轮观察周期 5.5-6h；每轮最多一批修复，push 前过 §8 回归；失败形状复现优先于新功能。

## 7. 决策门

- **Gate 1**（Phase 1+2 落地并观察 2 轮后）：wopan176 truth-check 真实落盘仍为 0 且熔断/轮转工作正常 → 判账号级死亡，进 Phase 3 后端切换。
- **Gate 2**（F14 后）：三个备选后端写入全失败 → 账号/配额层问题，升级用户，AI 停手。
- **Gate 3**（F16 后）：主副本确立且持续吞吐 ≥3GiB/轮 → 更新剩余量推演；若仍年级收敛，带数据请用户裁决继续/终止。

## 8. 工程红线（每次改动，无例外）

1. **通知**：动通知文案/版式必遵 `docs/telegram-notify.md`；改完跑 `bash skills/telegram-notify-audit/scripts/render_preview.sh`（16 项校验）。排版/发送一律 source `tg_notify.sh`，不得 curl 直发。
2. **回归**：`tests/` 下全部 `test_*.sh` **串行**跑（`bash test_x.sh </dev/null`）。**2026-09-14 实测基线：22 套 / 20 EXIT=0 / 2 非 0**——`test_marker_skip_guards.sh`（macOS `date` 无 `-d`，环境性）、`test_truth.sh`（需 docker，环境性）；全部日志 `grep "command not found"` 为空。已知 flaky 单独重跑即过：`progress_no_orphans`（T5 时序）、`sync_trend_budget`（macOS `wc` 前导空格）。跑法注意：zsh 下 `rm -f /tmp/x_*.log` 无匹配会中断整条命令链，日志请写进新建目录。
3. **Git**：push 前先 `git fetch`（main 有并行推送）；commit `fix(openlist): 中文描述` + `- ` 列表正文；禁 force / --no-verify；不 commit 除非任务需要（本计划授权提交）。
4. **不许动**：接力 step 逻辑（已验证健康）、truth-check 重启取真值机制、marker/游标增量持久化设计、「熔断不豁免修复管线」用户规格。
5. **注释**写「为什么」；实现改了同步文件头注释与相关 docs。
6. **dispatch 纪律**：只允许「同步」（默认）与「调试 · 修复管线测试」；**⚠️ 还原 / ⚠️ 灾难恢复模式禁碰**（需用户明示）。run_mode 默认即真实同步数小时；手动触发注意 concurrency 单例排队。

## 9. 需用户协助（AI 权限外）

1. **wopan176 账号状态**：登 OpenList 管理面/网盘后台查配额、限流、封禁、token——100B 上限与假成功可能同源于此（Gate 1 的关键输入）。
2. F16 主副本选型（保哪个后端的 4.5TB）。
3. F15 wopan176 transfers=2 实验批准。
4. ~~报告三份与本计划文件是否入库~~ → **已入库**（2026-09-14，本文件与三份报告一并提交）。

## 10. 接手指令模板（可直接粘给另一个 AI）

> 继续跟进 openlist 同步修复。先读仓库根 `openlist-sync-remediation-plan-2026-09-13.md` 的 §0（AI 接手须知）、§8（红线）、§9（需用户协助）与文末进度日志，再读 `.github/scripts/openlist/` 的代码。
> 然后：
> 1. `gh run list --workflow=openlist.yml --limit 5 --json databaseId,status,conclusion,event,createdAt,headSha` 看最新轮 conclusion，**并用 headSha 确认它跑的是哪版代码**；`gh run view <id> --log` 按 §6 关键词 grep。
> 2. 对照 §6 退出标准 A–E 记录进度（把实测证据写进对应条目，别只打勾）；出现新失败形状就地定位修复，遵守 §8 红线。
> 3. 满足当前阶段退出标准就推进下一阶段；到 §7 决策门（Gate 1/2/3）停下问用户。
> 4. 收尾前：更新本计划文档的复选框、进度日志与阶段表，跑 §8 回归套件（22 套串行 + `command not found` 扫描为空）再 push。
> 5. 需要用户做的事只有 §9 那几项，别自行代答。

---

## 进度日志

- 2026-09-13 · 计划制定（基于三报告 + HEAD 核验 + F0 新发现）。Phase 0-4 未开始。
- 2026-09-14（+08）· Phase 0 完成 + Phase 1（F0-F5）全量落地并 push。
  - 现状取证（run 34752801560，Phase 1 前最后样本）: 修复成效 成功 183 / 缺失 2126 / 未修复 1943，成功数与上轮逐字相同 ⇒ **新落盘 0**；批次 1 顽固缺失 1037（与上轮同值，F0 假成功闭环复现）；grep「后端写入全拒」= 0 条（F5 旧判据恒不触发，实锤）；13:48Z 起熔断刷屏致短哈希目录全部"未试写"（F3 实锤）；日志硬编码 transfers=1 掩盖实际 4（F0 烟幕实锤）。
  - 落地: `339d58a`（F0 transfers 统一 + F1 批次预算闸 + F1 配套 finalize 不写成功 marker + F2 熔断短路 + F5 全拒判据下移）、`2f60f26`（F3 名长解耦第一步 + F4 写探针分层到任务子路径 + 复核前刷缓存）。
  - 回归: 21 套串行，18 EXIT=0；`marker_skip_guards` / `sync_trend_budget` / `truth` 为既有环境失败（已对拍 HEAD 确认）；`command not found` 扫描为空（顺带补了该测试缺失的 `tg_add_entry_text` / `_batch_budget_stop` stub）。
  - 退出标准 A-E 当前**全部未满足**（基线见 `/tmp/openlist-remediation-baseline.txt`）；观察轮 `34770092689` 已于 2026-09-13 16:56Z dispatch，按 §6 观察。
- 2026-09-14（+08）· Phase 2 第一批落地（F6/F7/F8/F11）+ 观察轮 1 结果回读。
  - 落地: `3737688`（F7 修复成效拆分 ROUND_REUSED + 收尾看"新落盘"、F8 源端失败记 unknown、
    F11 SESSION_HOLD 兜底 'true'→'false'）、`e5296ed`（F6 后端熔断跨轮持久化
    `sync_state/backend_dead.json` + TTL 12h + 全线皆死保护 + 新测试 10 项）。
  - 观察轮 `34770092689`（2f60f26）**new: A 达标 1/3** —— 首次非硬杀的 success 收场，
    F1 预算闸生效；同时 **F5 首次真实触发**（「后端写入全拒（1036/1036）→ 中止剩余 2 批」，
    省约 80min）；F0 生效（日志打印真实 transfers=1）；F4 生效（写探针改到任务子路径
    `openlist:wopan176Crypt/2/1024j/动漫本子`，探针通过）。但 **B/C/D/E 全部未达标**:
    批次整批无真实落盘、transferred 2.08GB vs 落盘 0、仍只碰 wopan176Crypt、告警未触发。
  - 注意: 观察轮用的是 2f60f26（Phase 1），F7/F8/F11/F6 要等后续轮次（当前在跑的
    `34779382573` = 06cc0df、排队 `34787645966` = 0eef148，均只含 Phase 1）。
  - 计划文件 §6 · 退出标准处已按轮次逐条记录实测证据。

- 2026-09-14（+08，第二轮）· 观察快照 + F6 触发源接线落地。
  - **无新完成轮**: 最新完成轮仍是 `34770092689`（Phase 1），A–E 无新增数据点（逐条证据
    见 §6 末尾的「2026-09-14 08:05 观察快照」）。在跑 `34779382573` = `06cc0df`（Phase 1，
    step 18 已 1h48m，330min 上限 ⇒ 约 11:40 +08 收场），排队 `34787645966` = `0eef148`
    （同为 Phase 1）。**两个在队轮次都钉在 Phase 2 之前的 sha**，但无需人工干预: 在跑轮正常
    收场后自续触发会用「触发那一刻」的 main，Phase 2 全量进下一轮。
  - rclone 侧: `task_rotation.json` = `cursor 9 / attempts 1 / updated 22:55:23Z` —— 该写入正是
    在跑轮的"执行前落盘"（idx 9），即本轮又回到上一轮同一对 wopan176Crypt 重试；
    `backend_dead.json` **不存在**（F6 从未被执行过，符合预期）。
  - **落地 `acbbff5`**（F6 触发源接线，见 §4 · F6 补充）: F5「后端写入全拒」同时置
    `SYNC_BACKEND_DEAD=1`，把 F6 的熔断点从 ~2.5h 提前到批次 1 巩固结束。**这是本轮唯一的
    代码改动**——F10/F12/F13 评估后推迟（理由写进各自小节），因为下一轮要干净地验证
    F6/F5 接线（Gate 1 的唯一输入），再塞热路径改动会让归因失真。
  - **F9 前提已核实、范围收窄**（见 §4 · F9）: 趋势记账本来就是即时落盘（`sync_trend.sh:42-46`
    每次调用即追加 `/tmp` 文件），「强杀丢内存计数」对 trend 这条链不成立；**新证据**是
    `transferred_bytes` 出现逐字相同的重复值（`18282971`×3、`171257627`×3）而同期 remaining
    摆动 2.5TB ⇒ 同一批内容每轮被重新"传输"，`transferred_bytes` 是「rclone 声称量」而非
    「落盘量」，C 达标必须换判据。
  - **静态核验（待下轮实测确认）**: F6 的信号链能穿过函数边界——`_fix_probe_dir_writable`
    （`file_fix.sh:738`）在 `file_fix_pipeline.sh:377`、`file_fix.sh:1101/1276` 都是普通调用
    （无管道/命令替换），`while ... done < <(...)` 走进程替换在主 shell 执行，故
    `_BACKEND_DEAD` / `SYNC_BACKEND_DEAD` 能传到 `run_all_tasks` 的 `elif`；批次路径
    `sync_by_file_batches`（`task_engine.sh:755/769`）同样无子 shell，中止出口置 `SYNC_FAILED=1`
    后走 `_backend_dead_mark`。**串行（默认 subdir_parallel=1）成立；并行 worker 是子 shell，
    标志传不回父级**，与既有认知一致。
  - 回归: 22 套串行 / 20 EXIT=0；非 0 仅 `marker_skip_guards`（macOS 无 `date -d`）、
    `truth`（需 docker）；`command not found` 扫描为空。§8 · 回归基线数字已按实测更新
    （旧文写「19 个测试 / 16 EXIT=0」与现场对不上）。

- 待办/未做（2026-09-14 第二轮更新）:
  - **等观测（最高优先）**: 下一轮（首次含 Phase 2 全量代码）是 Gate 1 的唯一输入——看 F6 是否
    写入 `sync_state/backend_dead.json`、`run_all_tasks` 是否打印「后端跨轮熔断: N/M 个后端在
    TTL 内被判死」与「⏭ 同步对轮转…跳过让路」，以及退出标准 D（非 wopan176 的同步对开始被执行）
    能否首次达标。`gh run view <id> --log` 后按 §6 关键词 grep。
  - F3 第二步（根目录文件的短哈希兜底）。
  - Phase 2 剩余: F9（范围已收窄，见 §4 · F9）、F10 / F12 / F13（推迟理由已写进各自小节）。
  - Phase 3: F14 三后端写入自检起（含 Gate 1/2）。
  - **Gate 1 判据提醒**: 要求 Phase 1+2 落地后**观察 2 轮**。目前 Phase 1 观察 1 轮、Phase 2
    观察 0 轮，**未到**；下一轮若仍复现「wopan176 整批零真实落盘 + 熔断/轮转工作正常」，
    才可判账号级死亡并转 Phase 3 后端切换。

- 2026-09-14（+08，第三轮）· 观察快照 + 两项认知纠正 + 补 push 滞留 commit。
  - **无新完成轮**，A–E 无新增数据点（逐条证据见 §6 · 「2026-09-14 09:10 观察快照」）。
    轮次盘点: 在跑 `34779382573`（`06cc0df`，Phase 1）、排队 `34793014398`（`8acfc6f`，**Phase 2 第一批**，
    即 Gate 1 的第一个 Phase 2 数据点）、`34772641066`/`34787645966` 已 cancelled。
  - **发现并修复一个流程缺陷**: `acbbff5`（F6 触发源接线）**只在本机 commit、从未 push**——
    上一轮日志写"落地"但 origin/main 上没有它（`git rev-list --left-right --count origin/main...HEAD` = `0 1`）。
    本轮已补 push，并把上一轮遗留未提交的计划文档改动一并入库。**教训: 收尾务必核对 push 真的成功
    （沙箱会拦 push），别只写"已落地"。**
  - **纠正①**: cursor=9 不是"回到同一对 wopan176Crypt 重试"，而是 `task2-wopan175 → openlist:wopan175/2`
    （注册表 16 对索引逐条导出核对 + 日志 `注册进度: 2/16 onedrive:2 → openlist:wopan175/2` 实锤）。
  - **纠正②**: 自续触发**没有**接力——`34770092689` 尾部实锤「已有 1 个排队/等待中的运行，跳过接力」（护栏 3）。
    ⇒ 新代码进生产延迟 ≈ 2 轮（~11h），"push 完下一轮就生效"的假设不成立。
  - **F9 覆盖面已核实**（写进 §4 · F9）: `trend_record_transferred` 全库只有两处调用点，**批次路径整体
    不计入趋势**（`batch_transferred_bytes` 只喂进度行；尾部那次 `sync_with_logging` 跑在
    `OPENLIST_FIX_TEST_MODE=1` 下、日志被置空 ⇒ 记 0）⇒ 该指标同时偏高（含假成功）与偏低（漏批次量）。
    **不改代码**（属指标定义问题，且 C 达标已定要换判据）。
  - **F6 链路复核到行**（写进 §6）: `_backend_dead_mark` 会同步更新内存熔断表 ⇒ 同轮即可跳过后续同后端对；
    注册表 4 个后端 ⇒「全线皆死」保护不误伤；链路无子 shell；`SYNC_BACKEND_DEAD` 无执行期覆盖点。
  - **本轮零代码改动**（§6 迭代纪律: 失败形状复现优先于新功能；下一轮要干净验证 F6/F5 接线）。
  - 回归（§8）: 22 套串行 / **20 EXIT=0 / 2 非 0**（`marker_skip_guards` 无 `date -d`、`truth` 需 docker，
    均为既有环境性失败）；`progress_no_orphans` 单跑即过（PASS=16 FAIL=0，确认 flake）；
    **全部日志 `grep "command not found"` = 0 命中**。基线数字与 §8 一致，无需修订。
  - 待办不变: 等 `34793014398`（Phase 2 第一批）收场 → 再等一轮含 `acbbff5` 的 → 才够 Gate 1 的"观察 2 轮"。

- 2026-09-14（+08，第三轮续）· 从上一轮的日志里挖出**裁决性证据** + 两处小改动。
  - **§1.2 悬而未决的「短哈希目录可写性」已裁决（采信 ds4.1「后端全死」）**: `34770092689` 里
    F3 第一步生效后，目录级批量折叠**真的被执行了**——`19:32:57`（44 个文件）→ 短哈希目录
    `f22c8c73`、`19:36:03`（39 个文件）→ `cb4f0d57`，两次都在 `19:39:01` 熔断**之前**（未被短路）；
    结果两处都是 `❌ 批量折叠零落盘（rc=0）`（`19:34:39` / `19:37:37`）。
    ⇒「缩短名字即可绕过」在真实路径上被**直接证伪**；F3 第一步的验收（短哈希目录有实测写尝试）**达标**。
  - **F3 第二步推迟（评估后）**: `file_fix.sh:1023-1027` 的「根目录无目录可换」缺口存在，但
    `无目录可换` 在日志里 **0 次** ⇒ 该形态从未复现；且收益存疑（方法 2 已把文件名改短，再套一层
    短哈希目录只会让路径更长）。重启条件已写进 §4 · F3。
  - **§6 · C/E 补精确证据**: C 的假成功样本 = 批次 1 巩固自述「本批成功 1036 个 / 直接失败 0 个」
    → 复核「1036/1036 全部未落盘」；E 的收尾数字 = `成功 183 · 缺失 2146 · 未修复 1963`，
    而 183 条**全部**是 `♻ 沿用上轮修复`（新落盘 0）。
  - **代码改动（1 处文案 + 1 处测试）**:
    1. `task_engine.sh`「跳过让路」文案去掉「上轮判死」——F6 触发源接线落地后判死也可能发生在
       **同一轮**的批次巩固里，原文案与事实相反；下一轮就会命中这个形态，先修掉免得日志误导。
    2. `tests/test_backend_dead_round.sh` 场景 5 补 **5c/5d**: 断言 `_backend_dead_mark` 之后
       **同一轮内**后续同后端对（p2）当场被跳过、且日志含「跳过让路」。原场景 5 只断言落盘，
       把内存熔断表那行删掉测试照样全绿（假通过）——而退出标准 D 正是靠这条性质在同一轮成立。
       **已负向验证**: 注掉 `_BACKEND_DEAD_ROUND["$root"]="$now"` 后 5c/5d（连带 4a/5b/6b）变红，
       恢复后 **12 PASS / 0 FAIL**。
  - **`AGENTS.md` 回归基线纠正**: 原文「22 套中 19 套 `EXIT=0`」+ 列 4 个非 0（19+4≠22）自相矛盾；
    实测应为 **20**（非 0 仅 `marker_skip_guards`、`truth` 两项环境性；`progress_no_orphans`、
    `sync_trend_budget` 为 flaky）。已改为与 §8 一致。
  - 回归（§8）: 22 套串行 / **20 EXIT=0 / 2 非 0**（同上两项环境性）；本轮 `progress_no_orphans`
    直接 EXIT=0（未触发 flake）；**`command not found` 扫描 0 命中**。耗时 8m42s。
  - 待办不变: 等 `34793014398`（Phase 2 第一批）收场 → 再等一轮含 `acbbff5` 的 → 才够 Gate 1 的"观察 2 轮"。
