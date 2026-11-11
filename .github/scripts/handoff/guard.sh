#!/usr/bin/env bash
# cron 兜底轮自检（2026-11-10 Phase 1）。
# 背景：job 级单例并发组改为「serve 主轮独占 + 继任者专属组」后，存在一个
# 新窗口 —— 旧轮 job 结束、继任者已在 serving 的瞬间，组里排队中的 cron 轮
# 会拿到 runner。此刻它必须让位，否则与继任者双服（两个 VM 同时写同一份状态）。
# 判据 = 仓库内其他「未完成」的 openclaw run（状态 pending/queued/in_progress）。
# 让位方式 = 自我取消：run 级取消会让后续所有 `!cancelled()` 步骤跳过，
# 这是 GitHub Actions 里唯一能从一个 step 干净终止整个 job 的手段。
set -uo pipefail

others="$(gh run list --repo "${GITHUB_REPOSITORY}" --workflow openclaw.yml \
  --json databaseId,status \
  --jq "[.[] | select(.databaseId != ${GITHUB_RUN_ID} and .status != \"completed\")] | length" 2>/dev/null || echo 0)"
case "${others:-0}" in ''|*[!0-9]*) others=0 ;; esac

if [ "$others" -gt 0 ]; then
  echo "🛑 [handoff-guard] 检测到 ${others} 个未完成的 openclaw run（serving 主轮或交接继任者）—— 本轮 cron 兜底让位"
  # 2026-11-11：落标记 —— 收尾步骤是 `if: always()`，取消状态照样会跑，
  # 于是会在一台从未部署任何服务的 VM 上执行最终归档，四个对象全「未初始化」
  # 并刷三条失败告警（run 42950865534 实测）。标记让收尾静默跳过。
  : > /tmp/openclaw-guard-declined
  gh run cancel "${GITHUB_RUN_ID}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1 || true
  # 给取消传播留时间：若 20s 后仍没被取消，走 exit 1 兜底
  #（后续步骤多数带 !cancelled()，取消落地后照常跳过；个别 continue-on-error
  #  步骤即便抢跑，也只会在 ~20s 后随 job 死掉，无落盘副作用）
  sleep 20
  exit 1
fi
echo "✅ [handoff-guard] 无并存 run，本轮按常规启动"
