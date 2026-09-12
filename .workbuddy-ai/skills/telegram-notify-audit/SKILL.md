---
name: telegram-notify-audit
description: 对 actions 仓库的全部 Telegram 通知做版式一致性核对与复验。This skill should be used when the user asks to 核对/审查 telegram 通知、检查通知样式结构是否统一、改版式后复验基线是否仍成立，或要求按 docs/telegram-notify.md 第 7.4 节的「已统一 N 项」逐项确认。覆盖 openlist、tg-channel、workflows 内联、测速三套+pwsh 四个域共约 30 类通知，产出疑似偏差清单并回写核对基线。
agent_created: true
---

# Telegram 通知版式核对

## Overview

`docs/telegram-notify.md` 是全库通知版式的唯一真源，其 7.4 节记录了逐轮累积的
「已统一 N 项」基线。本 skill 把该基线的核对流程固化下来：机械扫描 → 四域并行
通读 → **逐条复核** → 渲染预览 → 回归验证 → 回写基线。

核对的目标不是「找 bug」，而是「确认基线仍然成立，并找出新出现的不一致」。
多数轮次的结论是「1–N 项仍成立 + 少数几条待修」。

## 何时使用

- 用户要求核对 / 审查 / 检查 telegram 通知的样式结构是否统一
- 改动了任何通知版式后，需要确认 7.4 节基线没被破坏
- 用户问「某类通知是不是漏改了」——用本流程定位并给出判定依据

## 核对流程

### 第 0 步：读真源（不可跳过）

先完整读 `docs/telegram-notify.md`，重点是第 4 章「版式构件速查」、4.6 节折叠判定、
第 6 章发送层（硬约束）、第 7 章测试基线、7.4 节既有基线。

判定「谁是真源」看三样：真源文件的注释、测试夹具、与平行实现的对照——
**不看出现次数**。多处重复实现不代表它是规范。

### 第 1 步：机械扫描

按 `references/audit-checklist.md` 的「机械扫描项」逐条 grep。这些项本轮应全部为零命中
（`<b>`/`<i>`、`• `、半角冒号 kv、`5h 57m` 式紧凑时长、ISO 时间戳直出、curl 直发、
手拼收尾行）。

扫描时注意本机环境坑，见下方「必读的坑」。

### 第 2 步：四域并行通读

派 4 个 worker 并行通读（各自只读审计，不改文件）：

| 域 | 范围 |
|---|---|
| openlist | `.github/scripts/openlist/*.sh`（排除 `tests/`） |
| tg-channel | `.github/scripts/tg-channel/*` |
| workflows 内联 | `.github/workflows/*.yml` 里的内联通知段 |
| 测速 + pwsh | `.github/scripts/proxy-speedtest/*` 与 `.github/scripts/telegram/tg_notify.ps1` |

每个 worker 的 prompt 必须自包含（worker 看不到本对话）：给出真源路径、判据摘要
（标题/分节/kv/条目/折叠/收尾区/时长/转义）、输出格式
（`文件:行号 | 渲染后形态 | 违反哪条 | 置信度`）。

额外要求每个 worker **单独列一节「看着可疑但可能是有意写法」**——这一节与偏差清单
同等重要，是第 3 步的输入。

### 第 3 步：逐条复核（不可跳过）

**worker 的结论不可直接采信。** 历史上出现过方向性错误：把符合规范的写法判成偏差，
且是 3:1 的多数意见。每条结论都要回到代码看一眼，再决定是真偏差还是有意为之。

复核时回到规范原文确认：某个写法到底是「硬约束」还是「建议」。
硬约束只有三处（第 6 章发送层、4.9 收尾区接线、第 7 章测试基线）。
**「字符集受限、风险低」不是硬约束的豁免理由**——第 6 章明写动态内容必须转义。

易误判为偏差、实为合规的写法见 `references/audit-checklist.md`「易误判项」。
每次核对若发现新的易误判项，追加进该文件。

### 第 4 步：渲染预览

执行 `scripts/render_preview.sh`，用真源助手构造数据渲染一遍。
这一步能抓到纯代码审查漏掉的三类问题：转义被二次处理、空行数量不对、
`$( )` 吃掉尾换行导致条目粘连。

### 第 5 步：回归验证

改动若触及 openlist 域，跑 `references/audit-checklist.md`「回归基线」里的命令。
判定基线与 flake 名单都在该文件，**新增的 flake 要补进去**。

### 第 6 步：回写基线

把本轮结论写进 `docs/telegram-notify.md` 7.4 节：本轮方法、1–N 项是否仍成立、
修正了哪些文档自身错误、新增/待修条目。本节是下一轮的起点。

同时修正核对中发现的**文档与实现不符**——文档数字（行数、状态数、秒数、计数、
成员清单）最容易腐化，凭印象写下的断言几乎必错。改文档数字前先 grep 出实现行号，
一并写进正文。

## 必读的坑

- **Grep 工具默认跳过以 `.` 开头的目录** → 搜 `.github/` 下代码必须显式传 `path=.github`。
- **zsh 下无匹配的通配会中断整条命令链** → 命令开头别用裸通配 `rm -f /tmp/x_*.log`，
  整个循环包进 `bash -c '...'`。
- **macOS BSD `grep` 不支持 `\S`**（GNU 扩展），用了会**静默零匹配**造成假阴性 →
  写 `[^ ]*` / `[^/]*`，或改用 Grep 工具。bash `grep` 的 `|` 是字面量同理。
- **`tg_notify.sh` 是 bash 语法**（`printf -v` / `${!var}` / `$'\n'`）→ 默认 shell 是 zsh，
  直接 source 会 `bad substitution`，必须 `bash -c '...'`。
- **`tg_add_entry` 收的是裸主体 + 元数据**，传 `$(tg_entry …)` 会套出双层 `<code>`；
  `$( )` 还会吃掉尾换行导致条目粘连——累积多行用 `tg_add_entry`，不要拼 `$(tg_entry A)$(tg_entry B)`。
  这个坑极易在写渲染预览时踩到。
- **回归跑期间绝对不要并发跑单个测试**：多个测试共用 `tests/extracted.sh`，
  并发会报出**假的** `command not found`。
- **改 `docs/*.md` 不要用 Edit 工具**（会触发全局重排版，把实质改动淹没在格式噪音里）。
  用 python 按真实字节替换，改完 `git diff --numstat` 核对规模是否只有实质改动。
  另外 Read 工具渲染 md 会美化（表格对齐、行尾补空格），照它显示的写 old_string 会匹配不上。
- **推送前先 `git fetch`**：main 会被并行推送，确认落后数后再决定是否 rebase。

## Resources

### scripts/

- `render_preview.sh` —— 用真源助手渲染预览（对应规范 7.3 节），直接执行即可。

### references/

- `audit-checklist.md` —— 机械扫描项、四域判据、易误判项、回归基线与 flake 名单。
  第 1、3、5 步都要读它。
