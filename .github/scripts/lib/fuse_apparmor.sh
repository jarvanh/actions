#!/usr/bin/env bash
# Ubuntu 26.04+ 的 fusermount3 AppArmor 白名单只放行 @{HOME}、/mnt、/run/user/<uid>、
# /media、/tmp、/cvmfs；其余挂载点（/onedrive、/dropbox、/openlist …）会被 EPERM
# 拒绝，表现为 rclone mount 秒退 1（日志: fusermount3: mount failed: Permission denied）。
#
# 背景：2026-11-09 ubuntu-latest 漂移到 26.04，emby 因此停摆 6.5 小时（/onedrive 被拒）。
# 这里为指定挂载点补最小 local 授权（只放行该路径，仍保留 nosuid,nodev），幂等。
#
# 用法（在 rclone mount 之前调用，挂载点目录已创建）：
#   source "$GITHUB_WORKSPACE/.github/scripts/lib/fuse_apparmor.sh"
#   ensure_fuse_apparmor /onedrive [/dropbox /openlist ...]
ensure_fuse_apparmor() {
  # 老镜像（≤24.04）没有 fusermount3 profile，没有限制，直接跳过
  [ -f /etc/apparmor.d/fusermount3 ] || return 0

  local changed=0 mp
  for mp in "$@"; do
    # 判据必须与 services.sh 里 rclone-dropbox 的 ExecStartPre 一致：
    # 只认规则行的挂载目标 "-> <mp>/"，避免两边判据不同各写一份（2026-11-10
    # 实测 /dropbox 规则被写了两次）。
    # 注意 --：模式以 "-" 开头，不加 -- 会被 grep 当成选项（invalid option -- '>'）
    if ! grep -qF -- "-> ${mp}/" /etc/apparmor.d/local/fusermount3 2>/dev/null; then
      sudo mkdir -p /etc/apparmor.d/local
      printf '%s\n' \
        "mount fstype=@{fuse_types} options=(nosuid,nodev) options in (ro,rw,noatime,dirsync,nodiratime,noexec,sync) -> ${mp}/{,**/}," \
        "umount ${mp}/{,**/}," \
        | sudo tee -a /etc/apparmor.d/local/fusermount3 >/dev/null
      changed=1
    fi
  done

  # 新写的规则要重新加载 profile 才生效；若本机已带规则（changed=0）则 profile 已含之
  if [ "$changed" = 1 ]; then
    sudo /usr/sbin/apparmor_parser -r /etc/apparmor.d/fusermount3 2>/dev/null || true
  fi
}

# 挂载点完整前置（2026-11-10）：fuse.conf + AppArmor + 「未挂载却非空」清理。
# 用法（rclone mount 之前，挂载点变量已就绪）：
#   source "$GITHUB_WORKSPACE/.github/scripts/lib/fuse_apparmor.sh"
#   ensure_fuse_mountpoint /dropbox [/openlist ...]
#
# 为什么还要清非空：26.04 上首次挂载被 AppArmor 拒绝后，后续步骤会把状态写进
# 未挂载的挂载点，rclone 从此永久报 "<path> is not empty"（openclaw 实测空转
# 1091 次、持续 3 小时），只挪不删以便人工找回。
ensure_fuse_mountpoint() {
  # 1) --allow-other 的前提
  if ! grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    echo user_allow_other | sudo tee -a /etc/fuse.conf >/dev/null
  fi

  # 2) AppArmor 白名单
  ensure_fuse_apparmor "$@"

  # 3) 未挂载却非空 → 整体挪走
  local orphan="" mp
  for mp in "$@"; do
    sudo mkdir -p "$mp"
    mountpoint -q "$mp" 2>/dev/null && continue
    [ -z "$(ls -A "$mp" 2>/dev/null)" ] && continue
    [ -n "$orphan" ] || orphan="/tmp/rclone-orphan-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$orphan"
    if sudo find "$mp" -mindepth 1 -maxdepth 1 -exec mv -t "$orphan" {} + 2>/dev/null; then
      echo "[fuse] ⚠️ $mp 未挂载但非空，残留已移至 $orphan"
    else
      echo "[fuse] ❌ $mp 非空且清理失败（rclone 会拒绝挂载）"
    fi
  done
}
