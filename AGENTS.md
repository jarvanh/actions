# AGENTS.md

本文件是给 AI 助手的仓库入口（Claude Code / Cursor / Codex / Copilot / WorkBuddy 等
均会自动读取）。用法与约定写在这里，避免每个助手重新摸索。

## 仓库是什么

GitHub Actions 工作流与脚本集合：OpenList 网盘同步、Emby 302 直链、代理测速三套、
各类备份、Telegram 频道视频管线等。功能清单与用法见 `README.md`。

## 可用 skill

放在仓库根的 `skills/` 下，遵循 Agent Skills 开放标准（`SKILL.md` + YAML frontmatter）。
任何支持该标准的工具都能直接发现并使用：

| skill | 何时用 |
|---|---|
| `skills/telegram-notify-send` | **写通知**：新增一条通知、给 workflow/脚本加通知、改通知内容或版式 |
| `skills/telegram-notify-audit` | **核对通知**：审查全部 Telegram 通知的版式风格是否统一；改动通知版式后复验基线是否仍成立 |

两者配套：先用 `send` 写，再用 `audit` 核对。

## 改 Telegram 通知前必读

- **版式唯一真源**：`docs/telegram-notify.md`。改版式先改文档，再同步实现。
  其中三处是**硬约束**：第 6 章发送层（429 按 retry_after 重试 / 400 不重发直接暴露 /
  动态内容必须转义 / 已 source 发送层不得 curl 直发）、4.9 节收尾区与 `TG_RUN_URL` 接线、
  第 7 章测试基线。
- 三套实现真源：bash `.github/scripts/telegram/tg_notify.sh`、
  pwsh `.github/scripts/telegram/tg_notify.ps1`、
  python `.github/scripts/proxy-speedtest/speedtest_common.py`。
- 全库禁用 `<b>` / `<i>`；条目一律 `├─/└─` 树形；kv 一律全角冒号。
- 改完跑渲染预览自检：`bash skills/telegram-notify-audit/scripts/render_preview.sh`。

## 其他约定

- **没有任何 workflow 监听 `push` / `pull_request`**，全是 `schedule` + `workflow_dispatch`。
  推送代码不会触发任何运行；判断某分支会不会产出通知，只看它是否支持 `workflow_dispatch`。
- openlist 域改动后跑回归套件，基线见 `docs/telegram-notify.md` 7.1 / 7.2 节：
  17 套 `EXIT=0` + 2 个已知环境失败，且 `command not found` 扫描必须为空。
- main 会被并行推送，push 前先 `git fetch` 确认落后数。
