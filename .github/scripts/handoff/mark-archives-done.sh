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
else
  succ=0; ip=""; cm=0; bm=0
fi
handoff_put "$HANDOFF_OLD_REMOTE" "$(handoff_old_json archives_done "${succ:-0}" "${ip:-}" "${cm:-0}" "${bm:-0}")"
echo "✅ [handoff] old.json → archives_done（继任者上游闸门放行）"
