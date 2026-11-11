#!/bin/bash
# 系统级健康看门狗（2026-11-10 引入）
#
# 背景：2026-11-09 ubuntu-latest 漂移到 26.04 后，/dropbox 挂载被 AppArmor 拒绝，
# 连锁导致 cloudflared 凭据缺失、隧道空转 3 小时、看板 1033 —— 全过程没有任何
# TG 通知，只能等主人自己发现。本脚本按固定间隔检查关键前提，状态变化时告警。
#
# 用法：
#   system_health.sh            # 检查一次，状态变化才发 TG（定时器调用）
#   system_health.sh --force    # 无论是否变化都发（人工验证用）
#   system_health.sh --quiet    # 只打印，不发 TG（本机调试）
#
# 判定项（任一 FAIL 即异常）：
#   - /dropbox 是否挂载（持久化真源，缺了凭据/看板/配置全丢）
#   - rclone-dropbox 服务是否 active
#   - cftun-* 隧道是否 active；并按 tunnels.conf 反向核对「源站在听却无单元」
#     （从未安装的隧道也要能发现 —— 那正是 Cloudflare 1033 的静默形态）
#   - quota-board 是否 active 且 8321 在听
#   - OpenClaw gateway 18789 是否在听
#
# 状态文件 /tmp/system-health-state（签名/时间戳/是否真的告过警/上次异常明细），只在
# 「正常→异常」「异常组合变化」「异常→恢复」时发送，避免每 5 分钟刷屏；异常持续时
# 每 6 小时补一条提醒。恢复通知只列「确实告过警」的项，绝不凭签名臆测。
set -u

TG_LIB="${TG_LIB:-$HOME/.openclaw/bin/tg_notify.sh}"
STATE="${HEALTH_STATE:-/tmp/system-health-state}"
FORCE=0; QUIET=0; PRINT=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    --print) PRINT=1 ;;
  esac
done

fails=()
ok_notes=()

# 1) /dropbox 挂载
if mountpoint -q /dropbox 2>/dev/null; then
  ok_notes+=("mount=ok")
else
  fails+=("❌ /dropbox 未挂载（持久化状态不可用）")
fi

# 2) rclone-dropbox 服务
st=$(systemctl --user is-active rclone-dropbox 2>/dev/null || true)
if [ "$st" = active ]; then ok_notes+=("rclone=$st"); else fails+=("❌ rclone-dropbox: ${st:-unknown}"); fi

# 2.5) /dropbox 依赖方（2026-11-10 qoder 失联事故）：rclone 重启后 fuse 连接换代，
# 容器 bind（qoder2api /app/accounts、trae2api /app/data）与早于挂载启动的常驻服务
# 会握旧句柄 —— qoder 面板读不到密码哈希 → 401→429，看板误报「数据源失联」。
# 这里每 5 分钟体检一次，发现 stale 自动重建/重启，修不好才告警。
DEPS="$HOME/.openclaw/bin/dropbox_dependents.sh"
if [ -x "$DEPS" ]; then
  if "$DEPS" check >/dev/null 2>&1; then
    ok_notes+=("dropbox-deps=ok")
  elif "$DEPS" heal >/dev/null 2>&1 && "$DEPS" check >/dev/null 2>&1; then
    ok_notes+=("dropbox-deps=自动重建")
  else
    fails+=("❌ /dropbox 依赖方仍失效（容器 bind / 服务早于挂载）")
  fi
fi

# 启动期豁免：看板/gateway 在 job 前 ~40 分钟本来就还没起（Mount Dropbox 早于它们），
# 这段时间只盯挂载与隧道，避免开机就误报。以 PID 1 启动时刻作为 job 起点
#（hosted runner 的 PID 1 随 job 启动，与 tg_add_footer 的时长兜底同口径）。
boot_age_min=$(( ( $(date +%s) - $(stat -c %Y /proc/1 2>/dev/null || date +%s) ) / 60 ))

# 3) cloudflared 隧道 —— 先按清单补齐缺失单元，再自愈已安装单元，最后判定
# 2026-11-10：平行会话跑 handoff 测试时 cutover.sh 会真的 stop 生产隧道（测试隔离缺陷），
# 隧道被停后不会自己回来。这里先 start 一次，3 秒后复检，仍起不来才告警。
#
# 2026-11-11：原实现只查「已安装」的 cftun-*，对「从未安装」完全失明 —— qb 因
# ensure 落在看板就绪之前被静默跳过，qb.derrick.eu.org 报 Cloudflare 1033，而本脚本
# 连续三轮 fails=0（实测）。改为按 tunnels.conf 反向核对：源站端口在听却没有单元
# = 公网入口缺失，先调 tunnels.sh ensure 自愈一次，仍缺失才告警。
if [ "$boot_age_min" -ge 40 ]; then
  tun_sh=""
  for cand in "${GITHUB_WORKSPACE:-}" "$HOME/ar6" "$HOME"/*; do
    [ -n "$cand" ] && [ -f "$cand/.github/scripts/tunnels/tunnels.sh" ] \
      && { tun_sh="$cand/.github/scripts/tunnels/tunnels.sh"; break; }
  done
  if [ -n "$tun_sh" ] && [ -f "$(dirname "$tun_sh")/tunnels.conf" ]; then
    while IFS='|' read -r t_name t_args t_port; do
      case "$t_name" in ''|\#*) continue ;; esac
      # 源站不在听 → 这条隧道不是本机职责（清单含其他 workflow 的条目）
      [ -n "$t_port" ] || continue
      (exec 3<>/dev/tcp/127.0.0.1/"$t_port") 2>/dev/null || continue
      t_unit="cftun-${t_name}.service"
      # 用 LoadState 判断「是否已安装」——不能读单元文件本身（root 600，runner 无权读，
      # `systemctl cat` 会 Permission denied → 把已存在的单元误判成缺失并重复 ensure）
      [ "$(systemctl show -p LoadState --value "$t_unit" 2>/dev/null)" = loaded ] && continue
      bash "$tun_sh" ensure "$t_name" >/dev/null 2>&1 || true
      sleep 2
      if systemctl is-active --quiet "$t_unit" 2>/dev/null; then
        ok_notes+=("${t_name}=补齐(源站 :${t_port} 在听、单元曾缺失)")
      else
        fails+=("❌ ${t_name}: 源站 :${t_port} 在听但公网隧道缺失（Cloudflare 1033）")
      fi
    done < "$(dirname "$tun_sh")/tunnels.conf"
  fi
fi

units=$(systemctl list-units --all --plain --no-legend 'cftun-*.service' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//')
healed=0
for u in $units; do
  st=$(systemctl is-active "$u" 2>/dev/null || true)
  if [ "$st" != active ]; then
    sudo systemctl start "$u" >/dev/null 2>&1 && healed=1
  fi
done
if [ "$healed" = 1 ]; then
  sleep 3
  ok_notes+=("tunnels=自动拉起")
fi
for u in $units; do
  st=$(systemctl is-active "$u" 2>/dev/null || true)
  [ "$st" = active ] && ok_notes+=("$u=active") || fails+=("❌ $u: ${st:-unknown}")
done
if [ -z "$units" ]; then
  # 2026-11-11 修：隧道单元由「Run Cloudflared Tunnel」/AI 网关步骤安装，交接继任者
  # 开机时必然一个都没有（hostname 还是 openclaw-next）。此前无宽限 → 开机即告警
  # 「未发现任何 cftun-* 隧道单元」（13:08 误报实测）。与 board/gateway 同款启动期豁免。
  if [ "$boot_age_min" -lt 40 ]; then
    ok_notes+=("tunnels=skip(启动期 ${boot_age_min}m，尚未安装)")
  else
    fails+=("❌ 未发现任何 cftun-* 隧道单元（已运行 ${boot_age_min}m）")
  fi
fi


# 4) quota-board
# 一次性自愈：看板依赖 /dropbox 上的 board.py，挂载抖动后会 exit 120 且自己起不来
if [ "$boot_age_min" -ge 40 ] && ! systemctl --user is-active quota-board >/dev/null 2>&1; then
  systemctl --user start quota-board >/dev/null 2>&1 || true
  sleep 2
fi
if [ "$boot_age_min" -lt 40 ] && ! systemctl --user is-active quota-board >/dev/null 2>&1; then
  ok_notes+=("board=skip(启动期 ${boot_age_min}m)")
elif systemctl --user is-active quota-board >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:8321'; then
    ok_notes+=("board=ok")
  else
    fails+=("❌ quota-board active 但 8321 未监听")
  fi
else
  fails+=("❌ quota-board 未运行")
fi

# 5) gateway 端口
if ss -ltn 2>/dev/null | grep -q '127\.0\.0\.1:18789'; then
  ok_notes+=("gateway=ok")
elif [ "$boot_age_min" -lt 40 ]; then
  ok_notes+=("gateway=skip(启动期 ${boot_age_min}m)")
else
  fails+=("❌ OpenClaw gateway 18789 未监听")
fi

# 测试口：只用于核对版式（HEALTH_SIMULATE_FAIL="a|b"），生产不设置
if [ -n "${HEALTH_SIMULATE_FAIL:-}" ]; then
  IFS='|' read -ra _sim <<< "$HEALTH_SIMULATE_FAIL"
  for _f in "${_sim[@]}"; do fails+=("❌ $_f"); done
fi

# 展示时间统一东八区（规范 · 日期与相对时间）。hosted runner 系统时区是 UTC，
# date -u 直出会比北京时间早 8 小时，主人对不上。
now=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M（东八区）')
# 空异常列表的签名口径必须与 signature 完全一致（printf 输出一个换行）。
# 2026-11-10 事故：此处曾写成 md5('')，与 md5("\n") 永不相等，于是每次全绿都被
# 判成「从异常恢复」，每 5 分钟发一条假恢复通知（"此前异常"根本不存在）。
EMPTY_SIG=$(printf '%s\n' "" | md5sum | cut -d' ' -f1)
signature=$(printf '%s\n' "${fails[@]:-}" | md5sum | cut -d' ' -f1)

# 状态文件四段：签名 / 时间戳 / 是否真的发过告警(0|1) / 上次异常明细（逐行）。
# 旧版两行格式读进来 notified=0、无明细，不会误触发恢复通知。
prev_sig=""; prev_at=0; prev_notified=0; prev_fails=()
if [ -f "$STATE" ]; then
  mapfile -t _st < "$STATE" 2>/dev/null || _st=()
  prev_sig=${_st[0]:-}; prev_at=${_st[1]:-0}; prev_notified=${_st[2]:-0}
  prev_fails=("${_st[@]:3}")
  case "$prev_at" in ''|*[!0-9]*) prev_at=0 ;; esac
  [ "$prev_notified" = 1 ] || prev_notified=0
fi

echo "[health] $now fails=${#fails[@]} ${ok_notes[*]}"
[ ${#fails[@]} -eq 0 ] || printf '  %s\n' "${fails[@]}"

# --quiet 是调试口，不落状态，避免测试结果污染下一轮真实判定
if [ "$QUIET" = 1 ]; then exit 0; fi

should_send=0; kind=""
if [ ${#fails[@]} -gt 0 ]; then
  kind="alert"; should_send=1
  [ "$FORCE" = 0 ] && [ "$signature" = "$prev_sig" ] && should_send=0
  # 持续异常：每 6 小时补一条，避免彻底静默
  if [ "$FORCE" = 0 ] && [ "$should_send" = 0 ] && [ $(( $(date +%s) - prev_at )) -ge 21600 ]; then should_send=1; fi
elif [ "$prev_notified" = 1 ] && [ ${#prev_fails[@]} -gt 0 ]; then
  # 只有「确实告过警」才允许说恢复，并列出恢复了什么
  kind="recover"; should_send=1
elif [ "$FORCE" = 1 ]; then
  # 人工验证：全绿就报全绿，不编造「此前异常」
  kind="ok"; should_send=1
fi
[ "$should_send" = 1 ] || exit 0

# ── 发送 ────────────────────────────────────────────────────────────
# 只在状态变化时发；凭据缺失时把内容打到 stdout（journal 可查），不静默吞掉。
if [ ! -f "$TG_LIB" ]; then
  echo "[health] ⚠️ 缺少 $TG_LIB，跳过 TG 通知"
  exit 0
fi
# shellcheck disable=SC1090
source "$TG_LIB"

host=$(hostname 2>/dev/null || echo runner)
# 版式真源：docs/telegram-notify.md
#   - 机器值（主机名/Run ID）走 tg_add_path（<code> 等宽）
#   - 清单走 tg_add_section + tree_lines（唯一条目前缀），不用 tg_add_block 铺平文本
#   - 原始输出才用 <pre>（规范 · 告警通知），且作为正文最后一块
#   - 常驻服务没有 run 上下文，收尾用 🕒 报告时刻（规范 · 收尾区「常驻服务例外」）
#   - 计数放分节标题 " · N"
msg=""
if [ "$kind" = "recover" ]; then
  tier=""
  tg_add_title msg "✅ 系统健康恢复"
  tg_add_path msg "主机" "$host"
  tg_add_section msg "🔍 已恢复 · ${#prev_fails[@]}"
  _lines=""
  for f in "${prev_fails[@]}"; do
    _lines+="$(escape_html "${f#❌ }")"$'\n'
  done
  tg_add_block msg "$(tree_lines "${_lines%$'\n'}")"
elif [ "$kind" = "ok" ]; then
  tier=""
  tg_add_title msg "✅ 系统健康正常"
  tg_add_path msg "主机" "$host"
  tg_add_note msg "全部检查项通过"
else
  tier="alert"
  tg_add_title msg "🚨 系统级故障 · ${#fails[@]} 项"
  tg_add_path msg "主机" "$host"
  tg_add_section msg "🔍 异常 · ${#fails[@]}"
  _lines=""
  for f in "${fails[@]}"; do
    _lines+="$(escape_html "${f#❌ }")"$'\n'
  done
  tg_add_block msg "$(tree_lines "${_lines%$'\n'}")"
  tg_add_kv msg "其余检查项" "${#ok_notes[@]} 项正常"
fi
# 常驻服务收尾：报告时刻，不用 ⏱ 已运行
case "$msg" in
  *$'\n') tg_append msg $'\n' ;;
  *) tg_append msg $'\n\n' ;;
esac
tg_append msg "🕒 ${now}"$'\n'

if [ "$PRINT" = 1 ]; then
  printf '%s\n' "$msg"
  exit 0
fi
# 发送成功才落状态：失败时保留旧状态，下一轮同一判据会重试；告警成功才允许后续
# 发「恢复」，不会出现「没告警却报恢复」。
if send_tg "$msg" "${tier:-}"; then
  if [ "$kind" = "alert" ]; then
    { printf '%s\n%s\n1\n' "$signature" "$(date +%s)"; printf '%s\n' "${fails[@]}"; } > "$STATE" 2>/dev/null || true
  else
    printf '%s\n%s\n0\n' "$EMPTY_SIG" "$(date +%s)" > "$STATE" 2>/dev/null || true
  fi
else
  echo "[health] ⚠️ TG 发送失败（凭据或网络），状态未更新，下一轮重试"
fi
