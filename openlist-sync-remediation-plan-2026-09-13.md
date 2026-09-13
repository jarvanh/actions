# openlist.yml 同步修复实施计划（2026-09-13）

- 代码基线：起步于 `5c01d32`（`task_engine.sh` 与被剖析的 run 34728107625 所在 commit 零差异，结论可平移）；**现已落地到 `e5296ed`**（Phase 1 全量 + Phase 2 第一批，见 §进度日志）
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
| Phase 2 剩余 | F9 字节计数落盘、F10 405 fail-fast、F12 sleep 60 条件化、F13 僵尸 run 心跳 |
| F3 第二步 | 根目录文件的短哈希兜底（第一步「不短路 + 不计数」已落地） |
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
| 短哈希目录可写性 | ds4.1「折叠 Copied 但零落盘 ⇒ 后端全死」 vs glm-f「折叠被熔断没实测过，大概率可写」 | **两者可并存**：折叠路径确实出现过假成功（软失败），但「短名必失败」未获证明——假成功另有可能的并发诱因（见 §1.4 F0）。需 F3 落地后实测裁决 |
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

### F7 修复成效拆分（让零产出告警真正生效）✅ 已落地（3737688）
`file_fix_pipeline.sh:1126-1136` 的 `add_ok` 含「沿用上轮修复」→ 拆 `ROUND_FIXED_NEW`（本轮新落盘）/ `ROUND_REUSED`（沿用）；`openlist.yml:503` 告警判据只看 NEW。收尾通知两数分列展示。

### F8 源端清单失败 → remaining 记 unknown ✅ 已落地（3737688）
`task_preview.sh:137-143`（源失败静默 `src_json="[]"`）→ 加 `PREVIEW_FAIL_SRC_PAIRS` 计数 + 与目标端同款通知提示；`sync_trend.sh:50` 任一源端失败时写 null，不参与求和。趋势曲线不再出现 TB 级假进展。

### F9 字节计数落盘
记账点 `task_engine.sh:316`、`:869` 改为即时追加 `/tmp` 计数文件（强杀后收尾仍可读）；顺带排查同值重传 churn（同批内容轮轮重传）。

### F10 405 fail-fast
初始 sync / 批次阶段：同一目录连续 N（默认 20）个 `405 Method Not Allowed` → 中止该目录本轮尝试（marker 置失败、留给修复管线换形态），不再 2103 个逐个烧完（34728107625 烧了 115min）。监控线程可仿 `_start_batch_progress_thread` 模式。

### F11 SESSION_HOLD 兜底 ✅ 已落地（3737688）
`openlist.yml:565` `|| 'true'` → `|| 'false'`，与声明默认（false、冲刺期窗口全给同步）一致。现状是颗雷：同步 step 一旦以 success 收场，schedule 轮会真执行 hold 5h。

### F12 `_refresh_openlist_cache` 的无条件 sleep 60 条件化
每子目录前后各一次、一轮 ≈85 次纯 sleep（~85min，预算 26%）→ 改「驱动未就绪时才等待」。落手前先核实现场行数与调用次数。

### F13 僵尸 run 心跳检测
自续触发 step 或轮入口：存在 in_progress 且 >45min 无更新的 run → `gh run cancel`。34752801560 形态（step 超时是 330min 后的兜底，不是主防）。

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
2. `gh run view <id> --log | grep -E "优雅收摊|后端写入全拒|熔断|修复成功 ·|顽固缺失|transfers=|同步时间预算"`。
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
- [ ] C · trend transferred 与 truth-check 确认落盘量差 <2x
      —— 未达标且更需警惕: 该轮 transferred_bytes=2,077,403,120（2.08GB，此前三轮
      恒为 171MB）而真实落盘 0 ⇒ 差值无限大，计数包含了假成功。
- [ ] D · 非 wopan176 的同步对开始被执行 —— 未达标（该轮仍只碰 wopan176Crypt/2）。
- [ ] E · 零真实落盘轮次能触发零产出告警 —— 该轮未触发（收尾报「成功 183」含沿用上轮，
      当时尚未部署 F7）；F7 已落地，下轮起看「新落盘」口径。

迭代纪律：一轮观察周期 5.5-6h；每轮最多一批修复，push 前过 §8 回归；失败形状复现优先于新功能。

## 7. 决策门

- **Gate 1**（Phase 1+2 落地并观察 2 轮后）：wopan176 truth-check 真实落盘仍为 0 且熔断/轮转工作正常 → 判账号级死亡，进 Phase 3 后端切换。
- **Gate 2**（F14 后）：三个备选后端写入全失败 → 账号/配额层问题，升级用户，AI 停手。
- **Gate 3**（F16 后）：主副本确立且持续吞吐 ≥3GiB/轮 → 更新剩余量推演；若仍年级收敛，带数据请用户裁决继续/终止。

## 8. 工程红线（每次改动，无例外）

1. **通知**：动通知文案/版式必遵 `docs/telegram-notify.md`；改完跑 `bash skills/telegram-notify-audit/scripts/render_preview.sh`（16 项校验）。排版/发送一律 source `tg_notify.sh`，不得 curl 直发。
2. **回归**：19 个测试**串行**跑（`bash test_x.sh </dev/null`），基线 16 EXIT=0 + test_truth.sh 7 FAIL（环境性）；全部日志 `grep "command not found"` 为空。已知 flaky 单独重跑：progress_no_orphans T5、marker_skip_guards、sync_trend_budget。
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
- 待办/未做: F3 第二步（根目录文件短哈希兜底）、Phase 2 剩余（F9 字节计数落盘、F10 405
  fail-fast、F12 sleep 60 条件化、F13 僵尸 run 心跳）、Phase 3（F14 起，含 Gate 1/2）。
  **Gate 1 已逼近**: 连续两轮 wopan176Crypt 整批零真实落盘 + 熔断/轮转工作正常 ⇒ 下轮
  若复现同形状，按 Gate 1 判账号级死亡并转 Phase 3 后端切换（但 F6 刚落地，先看它把
  熔断跨轮传播后的效果再判）。
