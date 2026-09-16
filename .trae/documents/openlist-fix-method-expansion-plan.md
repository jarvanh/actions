# openlist 修复方法扩充 + 命名口径统一 方案

- 关联：仓库根 `openlist-sync-remediation-plan-2026-09-13.md`（本文档是其 **§12.13 的实施细化**）
- 起因：§12.12「分卷假成功」专攻 —— 现有 4 种方法**全部经 rclone/WebDAV 写入**，
  判定其成败的"目录计数"不可信；方法 3 一旦"成功"即 `return 0`，方法 4 与目录折叠**从未被尝试**
- 用户决策（2026-09-16）：
  ① **按原计划执行**（扩方法）；② 命名统一为 **`方法N·动作·变体`（中文可读）**；
  ③ 目录折叠**暂不动**，先看新方法效果

---

## 1. 目标与成功标准

**目标**：给修复管线增加**不依赖 WebDAV** 的写入通道，把落盘判据从不可信的计数口径改成
**可验证口径**，并把方法命名统一到"人能直接读懂"的一种形式。

| # | 成功标准 | 判据 |
|---|---|---|
| S1 | 修复成功不再以"目录文件数增长"为唯一依据 | 写入类方法改用**大小精确匹配**为主判据 |
| S2 | 新增 API 写入方法，绕开 WebDAV | 新方法经 `127.0.0.1:5244/api/fs/put` 写入，日志可见 |
| S3 | 分卷改用 7z 原生分卷 | 产物 `<file>.7z.001`，复用 `file_split.sh` 实现，去掉手工改名 |
| S4 | 方法命名**单一口径**、中文可读 | 日志 / marker / 黑名单 / 通知 / 文档五处同源同形 |
| S5 | 不回归 | CI `tests.yml` 全绿；`command not found` 扫描为空 |

**非目标**：不改目录折叠逻辑；不删现有方法；不改同步主链路 `sync_engine.sh`。

---

## 2. 现状分析（已核验，带行号）

### 2.1 四种方法全部经 WebDAV 写入

| 方法 | 写入调用 | 落盘确认 |
|---|---|---|
| 1 `copyto_original` | [file_fix.sh:943](file:///workspace/.github/scripts/openlist/file_fix.sh#L943) `rclone copyto "$src_file"` | [L946](file:///workspace/.github/scripts/openlist/file_fix.sh#L946) `_confirm_persist_by_count` |
| 2 `copyto_shorthash` | [L975](file:///workspace/.github/scripts/openlist/file_fix.sh#L975) `rclone copyto "$local_file"` | [L978](file:///workspace/.github/scripts/openlist/file_fix.sh#L978) 同上 |
| 3 `zip_split_original` | [L510](file:///workspace/.github/scripts/openlist/file_fix.sh#L510) 逐卷 `rclone copyto` | [L515](file:///workspace/.github/scripts/openlist/file_fix.sh#L515) 逐卷 `rclone size` + [L531](file:///workspace/.github/scripts/openlist/file_fix.sh#L531) 计数确认 |
| 4 `zip_split_shorthash` | 同方法 3（`encode_name=1`） | 同方法 3 |

### 2.2 落盘确认的口径问题（§12.12 三次实证）

- `_confirm_persist_by_count`（[file_fix.sh:639-668](file:///workspace/.github/scripts/openlist/file_fix.sh#L639-L668)）
  读 `_raw_dir_count` → `rclone size` 的**文件计数**，刷新后 `sleep 5` 就读。
- 三次 fix-check 实测 `raw 未增长 52→52` 出现 6 次（3 文件 × 方法 1/2），计数一次未动；
  方法 2 仅耗 **5.3 秒**（200MB 不可能传完）⇒ 计数不动是必然，**不能据此判假成功**。
- 而方法 3 的"成功"依据是同一计数器**必然 +1**（分卷 = 1 个文件）⇒ 判据恒真。

### 2.3 方法 3 的"成功"短路了后续所有兜底

- [file_fix.sh:998-999](file:///workspace/.github/scripts/openlist/file_fix.sh#L998-L999)：
  `_try_fix_split_archive ... && return 0`。
- 后果：**方法 4 从未被尝试**（三次日志「修复方法4」0 次）；Step 5 折叠要求"4 方法全败"，
  也因此**从未触发**（三次日志「目录级兜底」0 次）。

### 2.4 未被使用的 OpenList 原生能力（全库 grep 0 命中）

已核验无 `fs/put`、`fs/form`、`fs/copy`、`fs/move`、`fs/rename`、`fs/batch_rename`、
`server-side-across-configs`、`chunker`。
现用：`/api/auth/login`、`/api/admin/storage/{list,load_all}`、`/api/fs/{mkdir,refresh,list}`。

**关键不对称**：目录创建已用 API 兜底（[file_fix.sh:1240-1250](file:///workspace/.github/scripts/openlist/file_fix.sh#L1240-L1250)），
**文件写入仍只走 WebDAV** —— 这正是 405/8005 的来源层。

### 2.5 分卷实现是自研的，与 file_split.sh 重复

| | file_split.sh（已有，未被复用） | file_fix.sh 方法 3/4（现行） |
|---|---|---|
| 打包 | `7z a -t7z -mx=0 -v<volume>` [file_split.sh:470](file:///workspace/.github/scripts/openlist/file_split.sh#L470) | `7z a -tzip` + `split` 裸切 + **手工倒序改名** [file_fix.sh:467](file:///workspace/.github/scripts/openlist/file_fix.sh#L467)、[L483-498](file:///workspace/.github/scripts/openlist/file_fix.sh#L483-L498) |
| 校验 | `_validate_split_parts`（卷数 + 超阈值） [L159-175](file:///workspace/.github/scripts/openlist/file_split.sh#L159-L175) | 逐卷 `rclone size` 比对 |
| 还原 | `7z x 文件名.7z.001` 即可 | `cat *.zip.0* > merged.zip && 7z x` |

### 2.6 ★ 命名口径的完整兼容面（本方案最容易出事的地方）

`_fix_method_desc` 的输出**不只是日志文本**，它是**持久化身份**：

| 消费点 | 位置 | 用法 |
|---|---|---|
| marker `fix_blacklist` 值 | [file_fix.sh:399](file:///workspace/.github/scripts/openlist/file_fix.sh#L399)、[sync_marker.sh:300-302](file:///workspace/.github/scripts/openlist/sync_marker.sh#L300-L302) | **写进 JSON 跨轮持久化**，下轮读回比对 |
| 跨轮读回比对 | [file_fix.sh:412](file:///workspace/.github/scripts/openlist/file_fix.sh#L412) `_fix_method_blocked` | 与上轮存的字符串**精确比对** |
| marker `method_id` 字段 | [file_fix.sh:45](file:///workspace/.github/scripts/openlist/file_fix.sh#L45) | 记录用哪个方法修的 |
| `restore_info.jq` **子串匹配** | [restore_info.jq:18-24](file:///workspace/.github/scripts/openlist/restore_info.jq#L18-L24) | `test("分卷切割")`、`test("短哈希文件名")`、`test("短哈希目录 ")`、`test("base64URL 编码目录 ")` |
| 通知展示 | [sync_notify.sh:158](file:///workspace/.github/scripts/openlist/sync_notify.sh#L158) `_fix_method_short` | 用户可见 |
| 回归测试硬编码 | [test_method_id_naming.sh:33-36](file:///workspace/.github/scripts/openlist/tests/test_method_id_naming.sh#L33-L36) | 断言四个字符串**逐字相等** |
| 扫描脚本注释 | [scan_fix_signatures.py:9-13](file:///workspace/.github/scripts/openlist/scan_fix_signatures.py#L9-L13) | 文档性引用 |

**⇒ 改名必须同时满足两条**：
1. `restore_info.jq` 依赖的 4 个子串**必须保留**（`分卷切割` / `短哈希文件名` / `短哈希目录 ` / `base64URL 编码目录 `）；
2. 旧 marker 里的历史黑名单会因字符串变化而**失配** ⇒ 需**兼容读取**（见 §3.5）。

---

## 3. 方案设计

### 3.1 方法表扩充：4 → 6 种

| 序 | method_id | 中文短标签（新） |
|---|---|---|
| 1 | `copyto_original` | `方法1·原名直传` |
| 2 | `copyto_shorthash` | `方法2·短名直传` |
| 3 | `zip_split_original` | `方法3·分卷·原名` |
| 4 | `zip_split_shorthash` | `方法4·分卷·短名` |
| **5** | **`api_put_original`**（新） | `方法5·API直传·原名` |
| **6** | **`api_put_shorthash`**（新） | `方法6·API直传·短名` |

> **追加在尾部**（D1）：历史 marker 黑名单按"方法 1–4"语义存储，追加不会使序号漂移。

### 3.2 命名统一（S4，用户已选"方法N·动作·变体"）

**统一后的两套输出**（都由 `file_fix.sh` 单点生成）：
- `_fix_method_short <id>` → 展示层：`方法3·分卷·原名`（日志/通知）
- `_fix_method_desc <id>` → 持久化层：必须**保留 restore_info.jq 依赖的子串**

**具体字符串**（保持子串兼容）：

| id | `_fix_method_short` | `_fix_method_desc`（含必需子串） |
|---|---|---|
| `copyto_original` | `方法1·原名直传` | `方法1·原名直传` + 保留 `原文件名` |
| `copyto_shorthash` | `方法2·短名直传` | `方法2·短名直传` + 保留 `短哈希文件名` |
| `zip_split_original` | `方法3·分卷·原名` | `方法3·分卷·原名` + 保留 `分卷切割`、`原文件名` |
| `zip_split_shorthash` | `方法4·分卷·短名` | `方法4·分卷·短名` + 保留 `分卷切割`、`短哈希文件名` |
| `api_put_original` | `方法5·API直传·原名` | `方法5·API直传·原名` |
| `api_put_shorthash` | `方法6·API直传·短名` | `方法6·API直传·短名` + 保留 `短哈希文件名` |

**同时清理现有两套并存**：`file_fix.sh` 内 4 处硬编码 `✅ 文件修复方法1 成功` /
`❌ 文件修复方法1 失败`（[L947](file:///workspace/.github/scripts/openlist/file_fix.sh#L947)、[L960](file:///workspace/.github/scripts/openlist/file_fix.sh#L960)、[L979](file:///workspace/.github/scripts/openlist/file_fix.sh#L979)、[L987](file:///workspace/.github/scripts/openlist/file_fix.sh#L987)）
改为调 `_fix_method_short`，消除"两套口径"。

**方法 3 的括号补充**（`（粒度 1.0GiB）`，[L998](file:///workspace/.github/scripts/openlist/file_fix.sh#L998)）保留——
它是粒度信息，不属于命名体系。

### 3.3 新增：API 写入方法（`api_put_*`）

**位置**：`file_fix.sh` 新增 `_try_fix_api_put()`，与 `_try_fix_split_archive` 并列；
在 `_try_fix_methods_round` 尾部（方法 4 之后）追加两个门禁。

**接口**（依据 OpenList `POST /api/fs/put`）：
```
POST http://127.0.0.1:5244/api/fs/put
Authorization: <token>
File-Path: <url-encoded 绝对路径>
Content-Type: application/octet-stream
Content-Length: <字节数>
Body: 文件流
```

**要点（写进注释）**：
- `File-Path` **必须 URL 编码**（路径含中文/空格/括号）→ `jq -rn --arg v "$p" '$v|@uri'`；
- **必须带 `Content-Length`**，不可用 chunked（D7）；
- token 复用 `_get_openlist_token`（[openlist_api.sh:20](file:///workspace/.github/scripts/openlist/openlist_api.sh#L20)）；
- 源用本地副本 `$local_file`（Step 3 已下载）。

**成功判据（S1）**：**不以计数为唯一依据**：
1. HTTP 2xx；**且**
2. **大小精确匹配**：`rclone size --json <目标全路径>` 的 `.bytes` == 本地字节数
   （同 [file_fix_pipeline.sh:161](file:///workspace/.github/scripts/openlist/file_fix_pipeline.sh#L161) 的 `is_transformed=0` 口径）；
3. 计数确认降级为**辅助信号**（仅记日志，不单独否决）。

### 3.4 修正：方法 1/2 的假成功判据（S1，核心）

**问题**：计数不增长即否决 → 级联拉黑（§12.12 实证）。

**改法**：新增 `_confirm_persist_by_size`，口径 = "目标 `rclone size` == 期望字节数"；
方法 1/2 的成功判据改为 **`尺寸匹配` 或 `计数增长`（取或）**：
- 方法 1 期望值：`rclone size "$src_file"` 的 bytes；
- 方法 2 期望值：`stat -c%s "$local_file"`。

**取"或"而非"且"的理由（D2）**：本轮目标是消除**假阴性**（该判成功却判失败，代价是
级联拉黑 → 好方法被误杀）；假阳性由**重启容器真值复核**兜底（既有设计，见
[file_fix_pipeline.sh:1074](file:///workspace/.github/scripts/openlist/file_fix_pipeline.sh#L1074) `_persist_verify_entries`）。

### 3.5 命名改动的兼容处理（§2.6 的落地）

**问题**：改字符串会让**旧 marker 的黑名单失配**。

**处理**：
- `_fix_method_blocked`（[L409-416](file:///workspace/.github/scripts/openlist/file_fix.sh#L409-L416)）保留**旧格式识别**：
  匹配新短标签 + 旧全名（`文件修复方法N <id>: …`）+ 裸语义 ID 三种形态；
- 代码注释注明：旧条目最坏效果 = 该文件多跑一轮已判定的方法后被重新拉黑，代价可控
  （与 [L331-333](file:///workspace/.github/scripts/openlist/file_fix.sh#L331-L333) 既有的"不兼容历史全名"处理同哲学）；
- `restore_info.jq` 的 4 个子串**保持不变** ⇒ 历史 `fixed_files` 条目的还原元数据不受影响。

### 3.6 分卷改用 7z 原生分卷（S3）

替换 `_try_fix_split_archive` 的打包段，复用 `file_split.sh` 能力：
- 打包 `7z a -t7z -mx=0 -v<volume> "<out>/<base>.7z" "<local_file>"`；
- 产物 `<base>.7z.001`…（删掉 [L486-498](file:///workspace/.github/scripts/openlist/file_fix.sh#L486-L498) 手工倒序改名）；
- 校验复用 `_validate_split_parts`；
- **粒度仍用 `OPENLIST_SPLIT_PART_BYTES`（1GiB）**（D3，一次只改一个变量）；
- **不引入** `.sha256` / `.restore.txt`（D4：会改变 `alternative` 语义与防删除 filter，
  见 [file_fix_pipeline.sh:271-276](file:///workspace/.github/scripts/openlist/file_fix_pipeline.sh#L271-L276)）——**此差异写进注释**；
- `restore_info.jq` 的 `split_zip` 分支 scripts 改为 `7z x '<base>.7z.001'`
  （**子串 `分卷切割` 必须保留**，否则分类失效）。

### 3.7 方法 3 不再短路兜底？—— 本方案**不改控制流**（D5）

**理由**：§12.12 建议"方法 3 之后不再 `return 0`"，但那会让每个成功文件白跑剩余方法。
若判据修好（§3.4/§3.6）后"成功"可信，则真修好即返回（快）、真失败继续走 5→6→折叠（全）。
**若 V3 复验后仍观察到"方法 3 判成功但未落盘"，再回改控制流** —— 列为后续决策点。

### 3.8 目录折叠：不动（用户决定 D6）

保持 `OPENLIST_HASH_DIR_FALLBACK` 默认 `1` 与现有触发条件。

---

## 4. 改动清单

| 文件 | 改动 | 风险 |
|---|---|---|
| `file_fix.sh` | ① `_confirm_persist_by_size`（新）；② `_try_fix_api_put`（新）；③ 方法 1/2 判据改"或"；④ 分卷改 7z；⑤ 命名统一（`_fix_method_short`/`_fix_method_desc` + 6 处硬编码）；⑥ `_fix_method_blocked` 兼容旧格式；⑦ `_try_fix_methods_round` 加 2 个门禁 | 中高（热路径） |
| `restore_info.jq` | `split_zip` 的 steps/script 改 `7z x .7z.001`（**保留 `分卷切割` 子串**） | 中 |
| `scan_fix_signatures.py` | 特征 2 加 `.7z.001` 识别 | 低 |
| `sync_marker.sh` | 仅注释（[L300-302](file:///workspace/.github/scripts/openlist/sync_marker.sh#L300-L302) 引用旧格式） | 低 |
| `tests/test_method_id_naming.sh` | 断言字符串全部改写（[L33-36](file:///workspace/.github/scripts/openlist/tests/test_method_id_naming.sh#L33-L36)）+ 加旧格式兼容用例 | 中（**必改**） |
| `tests/test_hash_dir_fallback.sh` | [L195](file:///workspace/.github/scripts/openlist/tests/test_hash_dir_fallback.sh#L195) 方法列表、[L319](file:///workspace/.github/scripts/openlist/tests/test_hash_dir_fallback.sh#L319) 固定文本 | 中（**必查**） |
| `tests/test_fix_check.sh` | [L259](file:///workspace/.github/scripts/openlist/tests/test_fix_check.sh#L259)/[L269](file:///workspace/.github/scripts/openlist/tests/test_fix_check.sh#L269) 黑名单字符串 | 中（**必查**） |
| `tests/test_batch_consolidate.sh` | [L64](file:///workspace/.github/scripts/openlist/tests/test_batch_consolidate.sh#L64) 固定方法文本 | 中（**必查**） |
| `README.md` | [L168](file:///workspace/README.md#L168) 方法表（加 5/6 + 命名说明） | 低 |
| `openlist-sync-remediation-plan-2026-09-13.md` | 追加 §12.13 | 低 |
| `docs/telegram-notify.md` | 若通知出现方法名，**先改文档再改实现** | 低 |

---

## 5. 假设与决策记录

| # | 决策 | 依据 |
|---|---|---|
| D1 | 新方法追加尾部（5/6） | 避免历史黑名单因序号漂移错配 |
| D2 | 判据改"**尺寸匹配 或 计数增长**"（取或） | 目标是消除**假阴性**；假阳性由重启真值复核兜底 |
| D3 | 分卷换 7z 但**粒度仍用 `OPENLIST_SPLIT_PART_BYTES`** | 一次只改一个变量 |
| D4 | 分卷**不引入** `.sha256`/`.restore.txt` | 会改变 `alternative` 语义与防删除 filter |
| D5 | **不改** `return 0` 控制流 | 先修判据；若假成功仍复现再回改（决策点） |
| D6 | 目录折叠**不动** | 用户决定 |
| D7 | API 方法**必须带 Content-Length** | OpenList `fs/put` 依赖 |
| D8 | `File-Path` **必须 URL 编码** | 路径含中文/空格/括号 |
| D9 | 命名用 `方法N·动作·变体`，且**保留 restore_info.jq 的 4 个子串** | 用户选定；子串是分类依据 |
| D10 | `_fix_method_blocked` **兼容旧格式** | 旧 marker 黑名单不能因改名失效 |

**环境约束（影响验证方式）**：本沙箱**无 rclone、无法直连 OpenList 容器**
⇒ 所有验证必须走 CI（`gh workflow run`），无法本地复现。

---

## 6. 验证步骤

**纪律**（`AGENTS.md` / §8 红线）：测试在 **CI** 跑（用户要求避免消耗本机资源）；
本机只做秒级静态检查；改 workflow 后**停止并重启**再测。

| # | 步骤 | 命令 | 通过标准 |
|---|---|---|---|
| V1 | 静态 | `bash -n .github/scripts/openlist/file_fix.sh`；`python3 -c "import ast;ast.parse(open('.github/scripts/openlist/scan_fix_signatures.py').read())"` | 无语法错误 |
| V2 | 回归（CI） | `gh workflow run tests.yml` → `gh run list --workflow=tests.yml --limit 1 --json databaseId,status,conclusion` | 全绿；无 `command not found` |
| V3 | **判决性**：定点复验 | `gh workflow run openlist-fix-check.yml -f mode=list -f task=task5 -f subdir=1024j-视频-pornhub-channel -f reset_blacklist=是 -f truth_restart=是 -f files=<同 3 个 ph 后缀>` | `fake_success` 归零，或明确回答哪条路可落盘 |
| V4 | 对照 | 对比 V3 与 `35079518553`（改前基线）的 `VERDICT` | 差异可归因 |
| V5 | 生产观察（可选） | 短轮 `sync_budget_min=60` | 无新失败形状 |

---

## 7. 执行顺序（增量、每步可独立回滚）

1. **Step A（最小、最有信息量）**：命名统一（§3.2/§3.5）+ `_confirm_persist_by_size` +
   方法 1/2 判据切换（§3.4）。→ 跑 V1/V2/V3，**先回答"方法 1/2 是不是被误判"**。
2. **Step B**：分卷改 7z 原生（§3.6）+ `restore_info.jq` / `scan_fix_signatures.py` / 测试同步。
3. **Step C**：新增 API 写入方法 5/6（§3.3）+ 门禁接入。
4. **Step D**：更新计划文档 §12.13、README、跑 V1/V2/V3，提交。

> **Step A 单独即可交付验证**。若 A 后 V3 显示方法 1/2 能落盘，则 B/C 的必要性大幅下降 ⇒
> 届时按实测重新决策，避免过度投入。
