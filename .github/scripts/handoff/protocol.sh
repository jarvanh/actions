#!/usr/bin/env bash
# ── openclaw warm-standby 交接协议 · 共享库（2026-11-10 Phase 1）──
#
# 目标：把每轮 6h job 交接的下线时长从实测 466s 压到 ~2-3min，数据零丢失为硬约束
#（停机瞬间之前的全部写入必须完整到达继任者 —— rsync 增量直传；到达不了就由
#  旧轮的 Dropbox 最终归档兜底走传统路径。任何分支都不允许「静默丢窗口」）。
#
# 双文件标记（Dropbox 单对象覆盖写，各只有一个写入方 → 无写写竞态）：
#   dropbox:self-hosted/handoff/old.json ← 只有旧轮写
#     {protocol, role, old_run, successor_run, state, old_ts_ip,
#      cutoff_epoch, base_marker, ts}
#     state: handing_over   网关已停、sqlite 已 checkpoint、rsync 源就绪
#          | handoff_done   继任者已 serving，旧轮转纯备份收尾
#          | archives_done  旧轮最终归档全部上传完成（继任者上游闸门放行点）
#          | handoff_aborted 交接失败，旧轮回退传统收尾（继任者读到即自我放弃）
#   dropbox:self-hosted/handoff/new.json ← 只有继任者写
#     {protocol, role, old_run, successor_run, state, ts}
#     state: ready          基座恢复完，等 CUTOVER
#          | rsync_started | rsync_done | serving
#          | aborted        继任者自我放弃（旧轮读到可提前回退）
#
# 防双服三件套（取代原 job 级单例 concurrency）：
#   1. serving 主轮独占并发组 openclaw-serve（cron 兜底轮在组里排队，不占 runner）
#   2. 继任者用 openclaw-handoff-<run_id> 专属组，与旧轮合法并存
#   3. guard.sh：serve 模式启动时发现其他未完成 run → 自我取消让位
# 不变量：任意时刻 ≤1 个「通过 guard 且已接管 serving」的 run。

HANDOFF_REMOTE_DIR="dropbox:self-hosted/handoff"
HANDOFF_OLD_REMOTE="$HANDOFF_REMOTE_DIR/old.json"
HANDOFF_NEW_REMOTE="$HANDOFF_REMOTE_DIR/new.json"
# AI 栈快照的独立 marker（Phase 1.5）：与 old.json 分开写，避免两个写入方互踩
HANDOFF_AI_REMOTE="$HANDOFF_REMOTE_DIR/ai.json"
HANDOFF_STATE_DIR="/tmp/openclaw-handoff"
HANDOFF_RSYNC_PORT="${HANDOFF_RSYNC_PORT:-8730}"
HANDOFF_PROTOCOL=1
# 预算（分钟）：T-12min 触发继任者 → T-4min 就绪看门狗 → 死线交出
HANDOFF_TRIGGER_BEFORE_MIN="${HANDOFF_TRIGGER_BEFORE_MIN:-12}"
HANDOFF_READY_DEADLINE_MIN="${HANDOFF_READY_DEADLINE_MIN:-4}"
# 继任者等 CUTOVER 上限；旧轮等 serving 上限（两者错开，旧轮先行超时回退）
HANDOFF_CUTOVER_WAIT_SEC="${HANDOFF_CUTOVER_WAIT_SEC:-1500}"
# 2026-11-14 复核：收尾预算 26min = serving 等待 + 归档等固定步骤。
# serving 正常 200-300s 到达；900s 的旧上限在最坏情况下把收尾挤超预算
#（实测 11-14：双重等待 35min 撞 360min 硬上限被杀）。改为 600s：
# 仍覆盖慢链路（正常上限 ~300s + 2 倍余量），超时立即 abort 回退，
# 给归档/接力留足时间 —— 不再出现「等太久而撞墙被杀」。
HANDOFF_SERVING_WAIT_SEC="${HANDOFF_SERVING_WAIT_SEC:-600}"
# 继任者等旧轮 archives_done 上限（超时=旧轮半路死，降级用基座数据续命）
HANDOFF_ARCHIVES_WAIT_SEC="${HANDOFF_ARCHIVES_WAIT_SEC:-1500}"

handoff_init() { mkdir -p "$HANDOFF_STATE_DIR" 2>/dev/null || true; }

# serve 轮=false，交接继任轮=true（HANDOFF_OF 由 job env 注入）
handoff_is_successor() { [ -n "${HANDOFF_OF:-}" ]; }

# handoff_put <remote> <json 字符串>：rcat 单对象覆盖写
handoff_put() {
  printf '%s' "$2" | rclone rcat "$1" >/dev/null 2>&1
}

# handoff_get <remote> <jq 表达式>：读不到/解析失败一律输出空串，绝不上抛
handoff_get() {
  local out=""
  out="$(rclone cat "$1" 2>/dev/null | jq -r "$2 // empty" 2>/dev/null | head -n 1 || true)"
  printf '%s' "${out:-}"
}

# 归属校验后的读法：owner 不匹配（上一轮残留标记）一律视为「无标记」。
# 这是防串轮的关键 —— 标记文件是全局单槽，跨轮残留必须被 ownership 挡掉。
handoff_old_state() { # <old_run 期望值>
  local owner state
  owner="$(handoff_get "$HANDOFF_OLD_REMOTE" '.old_run')"
  [ "$owner" = "$1" ] || { printf ''; return 0; }
  state="$(handoff_get "$HANDOFF_OLD_REMOTE" '.state')"
  printf '%s' "${state:-}"
}

# ai.json 的归属校验读法（旧轮写、继任者读）
handoff_ai_state() { # <old_run 期望值>
  local owner state
  owner="$(handoff_get "$HANDOFF_AI_REMOTE" '.old_run')"
  [ "$owner" = "$1" ] || { printf ''; return 0; }
  state="$(handoff_get "$HANDOFF_AI_REMOTE" '.state')"
  printf '%s' "${state:-}"
}

handoff_new_state() { # <successor_run 期望值>
  local owner state
  owner="$(handoff_get "$HANDOFF_NEW_REMOTE" '.successor_run')"
  [ "$owner" = "$1" ] || { printf ''; return 0; }
  state="$(handoff_get "$HANDOFF_NEW_REMOTE" '.state')"
  printf '%s' "${state:-}"
}

handoff_run_status() { # <run_id> → queued|in_progress|completed|unknown
  gh api "repos/${GITHUB_REPOSITORY}/actions/runs/$1" --jq '.status' 2>/dev/null || echo "unknown"
}

# 手写 JSON 免转义坑：字段全是受控值（数字/枚举/IP），不拼接用户输入
handoff_old_json() { # <state> <successor_run> <old_ts_ip> <cutoff_epoch> <base_marker> [archives_done true|false]
  # 2026-11-11：新增 archives_done 布尔字段。原因：移交成功后 state 必须保持
  # handoff_done（终态），但继任者的 archives_done 闸门需要「最终归档已完成」
  # 这个独立信号 —— 两者用同一字段互相覆盖，必然有一方失效（实测：闸门空等 25min）。
  printf '{"protocol":%d,"role":"old","old_run":%s,"successor_run":%s,"state":"%s","old_ts_ip":"%s","cutoff_epoch":%s,"base_marker":%s,"archives_done":%s,"ts":%s}' \
    "$HANDOFF_PROTOCOL" "${GITHUB_RUN_ID:-0}" "${2:-0}" "$1" "${3:-}" "${4:-0}" "${5:-0}" "${6:-false}" "$(date +%s)"
}

# 归档是否已全部上传（归属校验；true|false）。与 state 解耦：handoff_done 终态下
# 仍可置 true，供 gate.sh archives_done 放行，且不会被后续标记覆盖回 false。
handoff_old_archives_done() { # <old_run 期望值>
  local owner v
  owner="$(handoff_get "$HANDOFF_OLD_REMOTE" '.old_run')"
  [ "$owner" = "$1" ] || { printf 'false'; return 0; }
  v="$(handoff_get "$HANDOFF_OLD_REMOTE" '.archives_done')"
  printf '%s' "${v:-false}"
}

handoff_new_json() { # <state>
  printf '{"protocol":%d,"role":"new","old_run":%s,"successor_run":%s,"state":"%s","ts":%s}' \
    "$HANDOFF_PROTOCOL" "${HANDOFF_OF:-0}" "${GITHUB_RUN_ID:-0}" "$1" "$(date +%s)"
}
