#!/bin/bash
# ===== OpenList 同步工具 — 存储账号失效巡检与告警 =====
#
# 职责边界:
#   - 读取 OpenList 全部存储的驱动健康状态（/api/admin/storage/list）
#   - 把"驱动初始化失败"（网盘账号登录态失效）的存储筛出来，发 Telegram 告警
#   - 带冷却与首次发现时间记账，避免每轮重复轰炸（openlist 每小时 cron + 自续接力）
#
# 为什么需要单独这一层（2026-10-13 主人要求「有存储账号过期应该发送 Telegram 通知」）:
#   网盘账号登录态到期后，故障历来只在**同步进行中**才暴露:
#     · _pre_webdav_health_check / _openlist_api_health_check —— 某同步对开跑之后
#     · _has_wopan_login_failure（容器日志 8005）—— 写入已经失败之后
#   三者都只把该同步对判"跳过"，读者拿不到一份完整的"现在到底哪些存储坏了"清单，
#   且每个同步对各自判定、各自跳过，同一后端坏掉时只会多几条同类日志、没有一条通知。
#   OpenList 自己把驱动 Init 的失败原因**持久化**进 x_storages.status:
#     · internal/op/storage.go  initStorage(): Init 失败 → SetStatus(err.Error())，
#       成功 → SetStatus(WORK)；随后 MustSaveDriverStorage 写库
#     · internal/op/const.go    WORK="work" / DISABLED="disabled"
#     · internal/db/storage.go  GetStorages() —— storage/list 正是读这张表
#   因此**开跑前**读一次 storage/list 就是全量真值，这是唯一能"事前"看见账号失效的
#   位置; 容器启动（bootstrap.LoadStorages）与传输期间的 load_all 保鲜循环都会重跑
#   Init 并刷新 status，所以该值在整个 run 内都是新鲜的不是上一次的残留。
#
# 判据（只认持久化的驱动健康度，不猜）:
#   status == "work"                       → 健康
#   status == ""                           → 未初始化/未落库，跳过（不冤枉）
#   status == "disabled" 或 disabled=true   → 人工停用，跳过（不是故障）
#   其余（非空且非上述）                     → 驱动 Init 失败，告警；status 即错误原文
#
# 依赖: openlist_api.sh (_get_openlist_token)、tg_notify.sh 排版助手（load_all L0）、
#       telegram.sh (send_telegram_message); task_engine.sh (SYNC_TASK_REGISTRY) 可选
# 开关: OPENLIST_STORAGE_ALERT=0 关闭 · OPENLIST_STORAGE_ALERT_COOLDOWN=冷却秒数
#
# 命名口径: 本文件属 openlist 适配层（openlist_*）。与 openlist_api.sh 的分工是
#   它管**存储健康**、后者管**服务就绪**; 勿把探测逻辑塞回 wait_openlist_ready ——
#   那是个 fail-fast 门禁，加告警会让 openlist / diag / fix-check / tryrun 四个
#   workflow 的行为耦合在一起。

# ===== 开关 =====
# 告警总开关（1 开 / 0 关）。关闭时仍会打印巡检结论到运行日志，只是不发 Telegram。
OPENLIST_STORAGE_ALERT="${OPENLIST_STORAGE_ALERT:-1}"
# 同一批失效存储的重复告警冷却（秒）。默认 6h: cron 每小时一轮 + 自续接力，
# 不冷却会把同一个失效账号刷成一整页; 6h 覆盖"发现 → 人工重登"的观察窗。
# 首轮发现（历史状态里没有的挂载）**不受冷却约束**，一定立刻发。
OPENLIST_STORAGE_ALERT_COOLDOWN="${OPENLIST_STORAGE_ALERT_COOLDOWN:-21600}"

# ===== 存储健康巡检 =====
# 全局输出（供调用方直接读，不走命令替换——子 shell 里赋值回不到父进程）:
#   _SS_TOTAL       存储总数（含被人工停用的）
#   _SS_BROKEN_TSV  失效存储清单，每行 "mount_path \t driver \t status 错误原文"
#                   status 内的 \r\n\t 已被 jq 归一成单空格，保证行式读取不串行
# 返回: 0=巡检完成（_SS_BROKEN_TSV 可能为空 = 全部健康）/ 1=巡检本身失败（不误报）
_SS_TOTAL=0
_SS_BROKEN_TSV=""
_ol_storage_health_scan() {
  _SS_TOTAL=0
  _SS_BROKEN_TSV=""
  local tok="" resp=""

  # token 拿不到时**不能**当成"账号失效"—— 那只会得到一份空的/全坏的假清单。
  # _get_openlist_token 自带两次重试（各 sleep 2），失败已在 stderr 留痕。
  tok=$(_get_openlist_token 2>/dev/null) || tok=""
  if [ -z "$tok" ]; then
    echo "  ⚠️ 存储健康巡检: OpenList 管理面 token 不可用，本轮跳过巡检（不误报账号失效）" >&2
    return 1
  fi

  resp=$(curl -s -m 20 -X GET "http://127.0.0.1:5244/api/admin/storage/list" \
    -H "Authorization: $tok" 2>/dev/null) || resp=""
  if [ -z "$resp" ] || ! printf '%s' "$resp" | jq -e . >/dev/null 2>&1; then
    echo "  ⚠️ 存储健康巡检: /api/admin/storage/list 无有效响应，本轮跳过巡检（不误报账号失效）" >&2
    return 1
  fi

  _SS_TOTAL=$(printf '%s' "$resp" | jq -r '(.data.content // .data // []) | length' 2>/dev/null || echo 0)
  case "$_SS_TOTAL" in ''|*[!0-9]*) _SS_TOTAL=0 ;; esac
  if [ "$_SS_TOTAL" -eq 0 ]; then
    # 空清单与 wait_openlist_ready 阶段2.5 的判据同口径: 拉到的 data.db 可能为空/坏库，
    # 此时把"什么都没扫到"当"全部失效"会发出全假告警
    echo "  ⚠️ 存储健康巡检: 存储清单为空（total=0），本轮跳过巡检" >&2
    return 1
  fi

  _SS_BROKEN_TSV=$(printf '%s' "$resp" | jq -r '
    (.data.content // .data // [])[]?
    | select((.status // "") != "" and .status != "work" and .status != "disabled")
    | select((.disabled // false) == false)
    | [ (.mount_path // "?"), (.driver // "?"),
        ((.status // "") | gsub("[\\r\\n\\t]+"; " ")) ] | @tsv
  ' 2>/dev/null || true)
  return 0
}

# 由失效存储推导会被跳过的同步对（含 Crypt 派生: 底层 wopan176 坏 → wopan176Crypt 全挂）
# 用法: _ol_storage_affected_tasks <broken_tsv>
# 输出: 每行 "<task_id>\t<dest_path>"; 注册表不可用（单文件 source 的测试）时安静返回
# 为什么要派生 Crypt: 加密挂载的驱动完全建立在底层存储之上，底层登录态失效时上层
#   必然写不进 —— 只报底层挂载名，读者看不出任务清单里哪几对会停。
_ol_storage_affected_tasks() {
  local tsv="$1"
  declare -F _backend_root_of >/dev/null 2>&1 || return 0
  [ -n "${SYNC_TASK_REGISTRY+x}" ] || return 0

  local -A bad=()
  local mp norm e id src dst rest
  while IFS=$'\t' read -r mp _rest _; do
    [ -n "$mp" ] || continue
    norm="${mp#/}"
    bad["openlist:${norm}"]=1
    bad["openlist:${norm}Crypt"]=1
  done <<< "$tsv"
  [ "${#bad[@]}" -gt 0 ] || return 0

  for e in "${SYNC_TASK_REGISTRY[@]}"; do
    IFS='|' read -r id src dst rest <<< "$e"
    [ -n "$id" ] || continue
    if [ -n "${bad[$(_backend_root_of "$dst")]:-}" ]; then
      printf '%s\t%s\n' "$id" "$dst"
    fi
  done
  return 0
}

# ===== 跨轮记账（冷却 + 首次发现时间）=====
# 落盘位置与 backend_dead.json / task_rotation.json 同目录（SYNC_STATE_DIR，
# 随收尾镜像到 dropbox:self-hosted/openlist/sync_state_mirror 并有打包外置备份）。
# 形态: {"<mount_path>":{"driver":..,"status":..,"first_seen":epoch,
#        "last_seen":epoch,"notified_at":epoch}}
_ol_storage_alert_state_path() {
  echo "${SYNC_STATE_DIR:-onedrive:/logs/sync_state}/storage_alert.json"
}

# 全局输出: _SA_STATE（读到的 JSON；读不到/非法 = 空串，调用方按"首轮"处理）
_SA_STATE=""
_ol_storage_alert_load() {
  _SA_STATE=""
  local raw=""
  raw=$(rclone cat "$(_ol_storage_alert_state_path)" 2>/dev/null) || raw=""
  case "$raw" in '{'*) _SA_STATE="$raw" ;; *) _SA_STATE="" ;; esac
  return 0
}

# 按当前失效清单重写状态文件: 仍在失效的保留 first_seen（"已持续多久"才准），
# 已恢复的条目自然消失（相当于自动销账），notified_at 只在真发了告警时才推进。
# 用法: _ol_storage_alert_save <now_epoch> <notified 0|1>
# 返回: 0=写成功 / 1=生成或写入失败（调用方只记日志，不阻断巡检）
_ol_storage_alert_save() {
  local now="$1" notified="$2"
  local json=""
  json=$(printf '%s' "$_SS_BROKEN_TSV" | jq -R -s \
    --argjson now "$now" --argjson notified "$notified" --arg old "$_SA_STATE" '
    ($old | fromjson? // {}) as $prev
    | ( split("\n") | map(select(length > 0) | split("\t")) ) as $rows
    | reduce $rows[] as $r ({};
        .[$r[0]] = {
          driver: ($r[1] // ""),
          status: ($r[2] // ""),
          first_seen: ($prev[$r[0]].first_seen // $now),
          last_seen: $now,
          notified_at: (if $notified == 1 then $now
                        else ($prev[$r[0]].notified_at // 0) end)
        })
  ' 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  # 与 _marker_write 同口径: 落盘前先验 JSON 合法，避免把半截内容写成状态文件
  printf '%s\n' "$json" | jq . >/dev/null 2>&1 || return 1
  printf '%s\n' "$json" | rclone rcat "$(_ol_storage_alert_state_path)" 2>/dev/null || return 1
  return 0
}

# ===== 巡检入口 =====
# 用法: check_openlist_storage_health（workflow step 顶层调用，无入参）
# 返回: 恒 0 —— 巡检与告警都是 fire-and-forget，不能因为它让同步 step 失败
check_openlist_storage_health() {
  local now cooldown
  now=$(date +%s)
  cooldown="${OPENLIST_STORAGE_ALERT_COOLDOWN:-21600}"
  case "$cooldown" in ''|*[!0-9]*) cooldown=21600 ;; esac

  _ol_storage_health_scan || return 0
  _ol_storage_alert_load

  # --- 全部健康: 销账（此前失效的已恢复时留一条结论），不发通知 ---
  if [ -z "$_SS_BROKEN_TSV" ]; then
    if [ -n "$_SA_STATE" ] && printf '%s' "$_SA_STATE" | jq -e 'length > 0' >/dev/null 2>&1; then
      local _was
      _was=$(printf '%s' "$_SA_STATE" | jq -r 'keys | join(", ")' 2>/dev/null || echo "?")
      echo "✅ 存储健康巡检: ${_SS_TOTAL} 个存储全部健康，此前失效的已恢复（${_was}）"
      _ol_storage_alert_save "$now" 0 || true
    else
      echo "✅ 存储健康巡检: ${_SS_TOTAL} 个存储全部健康"
    fi
    return 0
  fi

  local n_broken
  n_broken=$(printf '%s\n' "$_SS_BROKEN_TSV" | grep -c . || true)
  case "$n_broken" in ''|*[!0-9]*) n_broken=0 ;; esac

  # --- 决定要不要发: ① 历史里没有的挂载（新坏）必发 ② 全是老面孔则按冷却 ---
  local do_notify=0 mp drv st dis
  if [ -z "$_SA_STATE" ]; then
    do_notify=1
  else
    while IFS=$'\t' read -r mp drv st dis; do
      [ -n "$mp" ] || continue
      if ! printf '%s' "$_SA_STATE" | jq -e --arg k "$mp" 'has($k)' >/dev/null 2>&1; then
        do_notify=1
        break
      fi
    done <<< "$_SS_BROKEN_TSV"
    if [ "$do_notify" -eq 0 ]; then
      local last
      last=$(printf '%s' "$_SA_STATE" | jq -r '[.[].notified_at // 0] | max // 0' 2>/dev/null || echo 0)
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ $(( now - last )) -ge "$cooldown" ]; then
        do_notify=1
      fi
    fi
  fi

  if [ "$do_notify" -ne 1 ]; then
    echo "ℹ️ 存储健康巡检: ${n_broken} 个存储仍失效（冷却 ${cooldown}s 内，不重复告警）: $(printf '%s' "$_SS_BROKEN_TSV" | cut -f1 | tr '\n' ' ')"
    _ol_storage_alert_save "$now" 0 || true
    return 0
  fi

  # ===== 构建告警（规范 · 告警通知: 对象机器值 + 结论裸文本 + 原始输出 <pre>）=====
  local msg=""
  tg_add_title msg "🚨 存储账号失效 · ${n_broken}"
  tg_add_kv msg "结论" "${n_broken} 个存储的登录态已失效（共 ${_SS_TOTAL} 个），涉及它们的同步对会被跳过"

  # 时间上下文: 首轮只给发现时刻; 跨轮在账的给"已持续多久"（取最早 first_seen）
  local first_seen fs_txt dur
  first_seen=$(printf '%s' "$_SA_STATE" | jq -r '[.[].first_seen // 0] | min // 0' 2>/dev/null || echo 0)
  case "$first_seen" in ''|*[!0-9]*) first_seen=0 ;; esac
  if [ "$first_seen" -gt 0 ]; then
    dur=$(( now - first_seen ))
    local dur_txt
    if [ "$dur" -ge 3600 ]; then
      dur_txt="$(( dur / 3600 )) 小时 $(( (dur % 3600) / 60 )) 分"
    elif [ "$dur" -ge 60 ]; then
      dur_txt="$(( dur / 60 )) 分钟"
    else
      dur_txt="${dur} 秒"
    fi
    fs_txt=$(date -u -d "@${first_seen}" '+%Y-%m-%d %H:%M' 2>/dev/null) || fs_txt=""
    if [ -n "$fs_txt" ]; then
      tg_add_kv msg "已持续" "${dur_txt}（首次发现 ${fs_txt} UTC）"
    else
      tg_add_kv msg "已持续" "$dur_txt"
    fi
  else
    tg_add_kv msg "首次发现" "$(date -u '+%Y-%m-%d %H:%M') UTC"
  fi

  # 对象清单: 挂载名与驱动都是机器返回值 → <code>
  tg_add_section msg "🧾 失效存储 · ${n_broken}"
  local _e=""
  while IFS=$'\t' read -r mp drv st dis; do
    [ -n "$mp" ] || continue
    tg_add_entry _e "$mp" "$drv"
  done <<< "$_SS_BROKEN_TSV"
  tg_append msg "$(tree_fold "${_e%$'\n'}")"$'\n'

  # 影响面: 哪几个同步对会因此被跳过（含 Crypt 派生，见 _ol_storage_affected_tasks）
  local affected
  affected=$(_ol_storage_affected_tasks "$_SS_BROKEN_TSV" || true)
  if [ -n "$affected" ]; then
    local _t="" aid adst
    tg_add_section msg "⏭️ 会被跳过的同步对 · $(printf '%s\n' "$affected" | grep -c .)"
    while IFS=$'\t' read -r aid adst; do
      [ -n "$aid" ] || continue
      tg_add_entry_codes _t "$aid" "$adst"
    done <<< "$affected"
    tg_append msg "$(tree_fold "${_t%$'\n'}")"$'\n'
  fi

  # 下一步（规范 · 说人话）: 这些登录态到期后无法自动续期，只能人工重登
  tg_add_note msg "这些存储的登录态到期后无法自动续期，需要在 OpenList 管理后台重新填写账号; 重登成功后同步会自动恢复，不需要改动本仓库的任何配置。"

  # 原始输出放最后（规范 · 告警通知: <pre> 是正文最后一块，其后只跟收尾区）
  local raw=""
  while IFS=$'\t' read -r mp drv st dis; do
    [ -n "$mp" ] || continue
    raw+="${mp} (${drv}): ${st}"$'\n'
  done <<< "$_SS_BROKEN_TSV"
  tg_add_section msg "🧾 原始错误"
  tg_add_pre msg "${raw%$'\n'}"

  tg_add_footer msg

  if [ "${OPENLIST_STORAGE_ALERT:-1}" = "0" ]; then
    echo "ℹ️ 存储健康巡检: ${n_broken} 个存储失效，但 OPENLIST_STORAGE_ALERT=0，不发 Telegram（明细见上方原始错误）"
    echo "$raw"
    _ol_storage_alert_save "$now" 0 || true
    return 0
  fi

  # alert 档: 需人工介入，与「源端大小异常减小」同级（@SaberFuckBot，无回落）
  send_telegram_message "$msg" HTML alert
  echo "🚨 存储健康巡检: ${n_broken} 个存储登录态失效，已发 Telegram 告警: $(printf '%s' "$_SS_BROKEN_TSV" | cut -f1 | tr '\n' ' ')"
  _ol_storage_alert_save "$now" 1 || true
  return 0
}
