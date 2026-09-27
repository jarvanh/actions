# AGENTS.md

动手前先读完与本次改动相关的约定；细节一律看链接指向的真源。

## 通用约定

- **改完代码，同步更新注释与文档**：实现改了就更新文件头注释与相关 `docs/*.md`、`README.md`；改了通知版式要同步更新核对基线（`skills/telegram-notify-audit/references/audit-checklist.md`）——规范文档只写版式，不写「哪一轮核对过什么」。注释放「为什么这么写」，不复述代码。
- 提交信息：`type(scope): 中文描述`，正文用 `- ` 列表说清「改了什么 + 为什么」。
- main 会被并行推送，push 前先 `git fetch` 确认落后数。
- **长跑（保活型）workflow 的交接走共享接力脚本** `.github/scripts/lib/self_retrigger.sh`：判据（人工取消不接力 / 已有排队则跳过 / 开关关闭不接力）、cron 频率取舍（别用 `*/5`，会被限流）与接入配方见 `docs/self-retrigger.md`。周期性任务**不要**接（会把任务变常驻）。

## Telegram 通知

- **规范真源 `docs/telegram-notify.md`：动通知前必读，实现必须与它一致。**
  - 实现与规范不一致 → 改实现；规范本身过时或有误 → **先改规范，再同步实现**（依赖方向恒为 文档 → 实现，不反向）。
  - 三处硬约束没有例外条款：规范 · 发送层（一律 HTML、动态内容必须转义、429 按 `retry_after` 重试最多 5 次、400 不重发直接暴露、已 source 发送层不得 curl 直发）、规范 · 收尾区与 `TG_RUN_URL` 接线、规范 · 8回归基线。
- 三套实现真源：bash `.github/scripts/telegram/tg_notify.sh`、pwsh `.github/scripts/telegram/tg_notify.ps1`、python `.github/scripts/proxy-speedtest/speedtest_common.py`。**新增或修改助手要三处同步**（大小/时长格式另有三处同义实现，规范 · 大小写法）。
- 全库禁用 `<b>` / `<i>`；条目一律 `├─/└─` 树形；kv 一律全角冒号。

### 可用 skill

放在仓库根 `skills/` 下，遵循 Agent Skills 开放标准，任何支持该标准的工具都能发现并使用：

| skill | 何时用 |
|---|---|
| `skills/telegram-notify-send` | **写**通知：新增一条、给 workflow/脚本加通知、改通知内容 |
| `skills/telegram-notify-audit` | **核对**通知：审查全库版式是否统一、改版式后复验基线 |

两者配套：先写后核。

### 改完必验

- 通知：`bash skills/telegram-notify-audit/scripts/render_preview.sh`（渲染预览 + 自动校验）。
