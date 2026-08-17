---
name: sync-notify-humanize
overview: 优化 OpenList 同步通知文案：将 fix_list 分支的状态行改为更直白的"N 个缺失文件已全部通过替代方式同步"，并移除多余的上传虚报（假成功）提示行，使 Telegram 通知更易读懂。
todos:
  - id: update-status-line
    content: 修改 sync.sh:1597 状态行为含缺失文件数的文案
    status: completed
  - id: remove-fake-success-block
    content: 删除 sync.sh:1462-1465 假成功提示整块
    status: completed
  - id: verify-notify
    content: 检查通知函数无空行残留与语法正确
    status: completed
    dependencies:
      - update-status-line
      - remove-fake-success-block
---

## 用户需求

优化 OpenList 同步成功通知（Telegram 推送）的文案，使其更通俗易懂。

## 产品概述

在 `.github/scripts/openlist/sync.sh` 的同步结果通知函数中，调整 `fix_list` 非空分支（缺失文件已通过替代方式同步）的提示措辞，并移除"假成功文件"提示行。

## 核心改动

- 状态行：由 `状态：缺失文件已全部通过替代方式同步` 改为 `状态：${fix_total} 个缺失文件已全部通过替代方式同步`（明确缺失文件数量）。
- 移除 `⚠️ 假成功文件：N 个（数据未落盘，已重启 OpenList 暴露并当轮修复）` 这一整行提示及其空判断块，通知中不再展示假成功/虚报信息。
- 通知标题 `⚠️ ${task_name} 部分文件已通过其他方式同步` 维持原样不变。

## 技术栈

- 脚本语言：Bash（项目现有同步/修复脚本）
- 通知渠道：Telegram（send_telegram_message 函数）

## 实现方案

本任务为纯文案调整，不涉及架构变动。直接修改 `sync.sh` 中两处通知拼接逻辑：

1. `fix_list` 分支（行 1590-1616）的状态行，使用函数内已定义的 `fix_total` 变量（行 1475 通过 `grep -c` 计算得到）替换原固定文案。
2. 假成功提示块（行 1462-1465），将整个 `if [ "${FAKE_SUCCESS_COUNT:-0}" -gt 0 ]` 判断块删除，因为块内仅一行 `count_info` 拼接，删除后该分支无其余逻辑，保留空 if 无意义。

## 实现要点

- `fix_total` 在 `_send_sync_result_notification` 函数内（约行 1475）已定义，1597 行所在分支同属该函数作用域，可直接引用，无需新增变量。
- 删除假成功 if 块时需保证移除完整块（含 `if` 行、拼接行、`fi` 行），避免留下空行或语法残留。
- 注意 `count_info` 在假成功块之前已拼接了文件数信息，删除该块不影响 `count_info` 其它内容。
- 保持现有缩进风格与 `\n'` 换行拼接方式一致。

## 架构设计

仅修改现有通知生成函数内的字符串拼接，无新增模块、无接口变更、不影响同步/修复主流程。

## 目录结构

```
.github/scripts/openlist/sync.sh   # [MODIFY] 调整 fix_list 分支状态行文案；删除假成功文件提示 if 块
```