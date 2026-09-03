#!/bin/bash
# emby302 公共 shell 函数库
#
# 被 emby.yml 的多个步骤 source 复用（install emby / backup emby data / 收尾归档）。
# 只定义函数、不设 shell 选项，避免污染调用方的 `set -euo pipefail` 语义。
#
# 用法：
#   source "$GITHUB_WORKSPACE/.github/scripts/emby302/lib.sh"
#
# 注意：本文件不做 `set -e`，被调用方决定错误处理策略；函数内部一律显式判断返回值。

# ---------- 磁盘空间预检 ----------
# 备份/恢复涉及 30GB 级 tarball，落盘前先确认空间，避免解压到一半才失败、
# 留下半恢复的残库（残库会被 Emby 当成空库重建，风险极高）。
free_kb() {
  df -Pk "${1:-/tmp}" | awk 'NR==2 {print $4}'
}

require_free_kb() { # $1=路径 $2=需要的 KB $3=场景名
  local path="$1" min_kb="$2" label="$3"
  local avail
  avail=$(free_kb "$path")
  if [ "${avail:-0}" -lt "$min_kb" ]; then
    echo "❌ ${label}: insufficient free space at ${path}. available=${avail}KB required=${min_kb}KB" >&2
    return 1
  fi
  echo "✅ ${label}: free space ok at ${path}. available=${avail}KB required=${min_kb}KB"
}

# ---------- /mnt 容量预算（动态分配） ----------
# /mnt 是共享分区，上面有两个消费者，且它们的大小都只有运行时才知道：
#   /mnt/emby-cache   —— emby 图片缓存（由 /var/lib/emby/cache 软链过来），解压后才有答案
#   /mnt/vfs/onedrive —— rclone VFS 缓存，随播放/扫描增长
# 所以不写死"缓存约 30GB"这类历史经验值，一律按实时剩余空间分配：
#   预留 MNT_RESERVE_KB 给 emby-cache 增长与安全垫，其余基本全给 VFS；
#   运行期若真被挤到，由 --vfs-cache-min-free-space 主动逐出让位。
MNT_RESERVE_KB=${MNT_RESERVE_KB:-$((6 * 1024 * 1024))}   # 6GB，可用 workflow env 覆盖

mnt_total_kb() { df -Pk /mnt | awk 'NR==2 {print $2}'; }
mnt_free_kb()  { df -Pk /mnt | awk 'NR==2 {print $4}'; }
dir_used_kb() {                                 # 目录实际占用；不存在或无权限算 0
  local u
  u=$(sudo du -sk "$1" 2>/dev/null | awk '{print $1}')
  echo "${u:-0}"
}

# 可分配余量 = 当前空闲 - 预留
# （VFS 与 emby-cache 的占用已经体现在 free 里，此处不重复扣减）
mnt_headroom_kb() {
  local h
  h=$(( $(mnt_free_kb) - MNT_RESERVE_KB ))
  [ "$h" -gt 0 ] || h=0
  echo "$h"
}

# VFS 缓存上限：余量基本全部给它（剩余空间都可以拿去用），仅保留 2GB 下限防止退化
alloc_vfs_cache_kb() {
  local min_kb=$((2 * 1024 * 1024)) h
  h=$(mnt_headroom_kb)
  if [ "$h" -lt "$min_kb" ]; then echo "$min_kb"; else echo "$h"; fi
}

# ---------- 归档临时文件清理 ----------
# 解压/打包用的 tarball 体积巨大，成功失败都要清掉，否则占满根分区。
cleanup_archive_workdir() {
  sudo rm -f "$HOME/emby-backup.tar.zst" /tmp/emby-backup.tar.zst 2>/dev/null || true
}

# ---------- Emby 数据完整性校验 ----------
# 真正的校验逻辑在 emby_guard.py 里（两处共用同一份实现，避免走样）。
# 不通过即以非零码返回，调用方必须据此中止，绝不能带着残库继续。
validate_emby_data() { # $1=emby 数据根目录
  local root="$1"
  sudo test -f "$root/data/users.db" || return 1
  sudo test -f "$root/data/library.db" || return 1
  # sudo 默认不透传环境变量，所以在这里显式把 EMBY_USER 带进去
  # （用户名来自 workflow secret，不能写死在脚本里）
  sudo EMBY_USER="${EMBY_USER:-}" python3 "$EMBY302_DIR/emby_guard.py" "$root"
}

# ---------- 日志归档脱敏 ----------
# 用于把 runner 上的日志 tail 进 workflow 归档（仓库公开，必须拦一道）：
#   redact_log  —— ge2o 等第三方日志：整行丢弃噪声 + 脱敏密钥与 URL
#   redact_urls —— odlink 等自有日志：本身已脱敏，这里只再拦一道 URL
# 注意：探活诊断另有一套更严格的脱敏（连媒体路径一起脱），在 emby.yml 内就地定义，
# 因为它要脱的东西更多，不应与这里的归档口径混用。
redact_log() {
  grep -v "headers to encode cacheKey" \
    | sed -E 's/api_key=[^& ]*/api_key=[redacted]/g; s/X-Emby-Token=[^& ]*/X-Emby-Token=[redacted]/g; s#https?://[^ "]*#<url>#g'
}

redact_urls() {
  sed -E 's#https?://[^ "]*#<url>#g'
}

# ---------- 直链源的"唯一真相" ----------
# host 与 token 由 start odlink 步骤写入这两个文件，ge2o 配置、启动探活、
# 运行中 watchdog 全部从这里读，保证三者打到同一个源——否则会出现
# "探活通过、但 ge2o 实际还在绕 OpenList" 的假健康。
link_host() {
  cat /tmp/link-host 2>/dev/null || echo "http://127.0.0.1:5244"
}

link_token() {
  cat /tmp/link-token 2>/dev/null || echo ""
}
