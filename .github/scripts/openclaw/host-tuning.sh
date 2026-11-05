#!/usr/bin/env bash
# host-tuning.sh — 宿主机资源参数幂等收敛（swap 容量 / vm.swappiness）
#
# 背景（2026-11-05 实测）：
#   宿主每轮重置后 /swapfile 回到镜像内置的 3G，vm.swappiness 回到默认 60。
#   而本机 swap 会在约 2 小时内被打满（free=0），网关单进程占其中 1.17G；
#   打满后同一颗盘上的 SQLite 写入出现 37s 级停顿，下一次内存尖峰即直接
#   OOM kill。另：本机 / 为旋转盘（ROTA=1 / mq-deadline），swap I/O 慢，
#   更不该让内核轻易把 anon 页换出。
#
# 边界：本脚本**只做与 openclaw 自身无关**的宿主机调整。
#   网关的 cgroup 限额（MemoryHigh/MemoryMax/MemorySwapMax）由
#   run-openclaw.sh 里的 memory.conf drop-in 负责，不在这里重复。
#
# 幂等 + 非致命：任何一步失败只告警、不退出非零，绝不阻断 gateway 启动。
# 用法：bash host-tuning.sh [--dry-run]

set -uo pipefail

SWAPFILE="${SWAPFILE:-/swapfile}"
SWAP_TARGET_MB="${SWAP_TARGET_MB:-25600}"
SWAPPINESS="${SWAPPINESS:-10}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-swappiness.conf}"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

log() { printf '[host-tuning] %s\n' "$*"; }
run() {
  if [ "$DRY" = 1 ]; then log "DRY-RUN: $*"; return 0; fi
  "$@"
}
sudo_run() {
  if [ "$DRY" = 1 ]; then log "DRY-RUN(sudo): $*"; return 0; fi
  sudo -n "$@"
}

# 当前 /swapfile 对应的 swap 区大小（MB）；未启用则输出空
current_swap_mb() {
  awk -v f="$SWAPFILE" '$1 == f { printf "%d\n", $3 / 1024 }' /proc/swaps 2>/dev/null | head -n 1
}

ensure_fstab_entry() {
  local line="$SWAPFILE none swap sw 0 0"
  if grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab 2>/dev/null; then
    log "fstab 已有 $SWAPFILE 条目，跳过"
    return 0
  fi
  if printf '%s\n' "$line" | sudo_run tee -a /etc/fstab >/dev/null; then
    log "✅ 已补写 fstab 条目：$line"
  else
    log "⚠️ 写 fstab 失败（开机不会自动挂载，但本次运行不受影响）"
  fi
}

ensure_swap() {
  local cur threshold
  cur="$(current_swap_mb || true)"
  # 容差：fallocate -l 25600M 之后 swapon 报出来是 25599MB（区头/取整差异），
  # 用严格 >= 会导致每次开机都白重建一遍 25G。留 5% 容差。
  threshold=$(( SWAP_TARGET_MB * 95 / 100 ))
  if [ -n "$cur" ] && [ "$cur" -ge "$threshold" ]; then
    log "swap 已满足：${cur}MB ≥ ${threshold}MB（目标 ${SWAP_TARGET_MB}MB，容差 5%），跳过重建"
    ensure_fstab_entry
    return 0
  fi

  log "swap 不足（当前 ${cur:-未启用}MB < ${threshold}MB），开始重建"
  # 先关旧区：swapoff 要把已换出的页拉回内存，内存不足会失败 ——
  # 失败就保持现状退出，绝不硬删正在使用的 swapfile。
  if [ -n "$cur" ]; then
    if ! sudo_run swapoff "$SWAPFILE"; then
      log "⚠️ swapoff 失败（内存不足或被占用），保持现有 swap 不动"
      return 0
    fi
  fi

  if ! sudo_run fallocate -l "${SWAP_TARGET_MB}M" "$SWAPFILE"; then
    log "fallocate 失败，回退 dd 写入"
    if ! sudo_run dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_TARGET_MB" status=none; then
      log "❌ 创建 swapfile 失败"
      return 0
    fi
  fi

  sudo_run chmod 600 "$SWAPFILE" || { log "⚠️ chmod 失败，继续"; }
  if ! sudo_run mkswap "$SWAPFILE" >/dev/null 2>&1; then
    log "❌ mkswap 失败"
    return 0
  fi
  if ! sudo_run swapon "$SWAPFILE"; then
    log "❌ swapon 失败"
    return 0
  fi

  ensure_fstab_entry
  log "✅ swap 重建完成：$(current_swap_mb)MB"
}

ensure_swappiness() {
  local cur
  cur="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo '')"
  if [ "$cur" = "$SWAPPINESS" ]; then
    log "swappiness 已为 $SWAPPINESS，跳过"
    return 0
  fi

  if printf '# 降低 anon 换出倾向：优先回收 page cache（host-tuning.sh，2026-11-05）\nvm.swappiness = %s\n' \
      "$SWAPPINESS" | sudo_run tee "$SYSCTL_FILE" >/dev/null; then
    log "✅ 已写入 $SYSCTL_FILE"
  else
    log "⚠️ 写 $SYSCTL_FILE 失败，仅尝试本次生效"
  fi

  if sudo_run sysctl -w "vm.swappiness=$SWAPPINESS" >/dev/null; then
    log "✅ swappiness: ${cur:-?} → $SWAPPINESS"
  else
    log "⚠️ sysctl 应用失败（若 sysctl.d 已写入，下次开机仍会生效）"
  fi
}

main() {
  log "start (dry-run=$DRY, target=${SWAP_TARGET_MB}MB, swappiness=$SWAPPINESS)"
  ensure_swap
  ensure_swappiness
  return 0
}

main || true
exit 0
