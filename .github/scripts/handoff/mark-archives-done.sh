#!/usr/bin/env bash
# 旧轮最终归档全部上传完成后调用（teardown 的 6a 之后）：把 old.json 推进到
# archives_done，释放继任者的上游/归档循环闸门（gate.sh archives_done）。
# 归属校验：old.json 不是本轮写的（上一轮残留）时，以本 run id 重置 ——
# 继任轮的 gate 按 old_run==HANDOFF_OF 认领，串轮标记天然被挡。
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=protocol.sh
source "$here/protocol.sh"
handoff_init
old_run="$(handoff_get "$HANDOFF_OLD_REMOTE" '.old_run')"
if [ "$old_run" = "${GITHUB_RUN_ID}" ]; then
  succ="$(handoff_get "$HANDOFF_OLD_REMOTE" '.successor_run')"
  ip="$(handoff_get "$HANDOFF_OLD_REMOTE" '.old_ts_ip')"
  cm="$(handoff_get "$HANDOFF_OLD_REMOTE" '.cutoff_epoch')"
  bm="$(handoff_get "$HANDOFF_OLD_REMOTE" '.base_marker')"
  # 2026-11-11 实测：移交成功时 cutover 已把 old.json 写成 handoff_done，
  # 而本脚本在其后的归档步骤才跑 —— 无条件写 archives_done 会把终态覆盖掉
  #（现场：new.json=serving 17:15，old.json 却回退成 archives_done 17:19）。
  # 终态语义必须保留：handoff_done = 已移交、本轮转纯备份。
  state="$(handoff_get "$HANDOFF_OLD_REMOTE" '.state')"
  case "$state" in
    handoff_done)
      # 终态保留（state 不回退），但必须补上「归档完成」信号 —— 否则继任者的
      # archives_done 闸门永远等不到（实测 2026-11-11 19:18 卡 30 分钟，
      # 归档循环/保活全被挡住，gateway-watchdog 报 archive-loop 未运行）。
      handoff_put "$HANDOFF_OLD_REMOTE" \
        "$(handoff_old_json handoff_done "${succ:-0}" "${ip:-}" "${cm:-0}" "${bm:-0}" true)"
      echo "✅ [handoff] old.json：handoff_done 终态保留 + archives_done=true（闸门放行）"
      exit 0
      ;;
  esac
else
  succ=0; ip=""; cm=0; bm=0
fi
handoff_put "$HANDOFF_OLD_REMOTE" "$(handoff_old_json archives_done "${succ:-0}" "${ip:-}" "${cm:-0}" "${bm:-0}" true)"
echo "✅ [handoff] old.json → archives_done（继任者上游闸门放行）"
