#!/usr/bin/env bash
# 交接继任轮：Tailscale 名字收回 openclaw 后，把 **OS hostname** 一起收回。
#
# 为什么需要（2026-11-12 实测缺口）：
#   workflow 的 "Lock hostname to openclaw" 只在 job 开头跑一次；继任轮按设计写成
#   openclaw-next（旧轮还占着 openclaw）。接管成功后 serving.sh / 回收守护会把
#   **Tailscale DNS 名**收回 openclaw，但没人再动 OS hostname —— 于是整轮
#   `hostname`、ZCode 客户端设备名、system_health 的 hostname 判定全停在
#   openclaw-next，和 tailnet 名不一致（现场：hostname=openclaw-next，
#   Self.DNSName=openclaw.taild54677.ts.net）。
#
# 用法: ts-sync-os-hostname.sh [目标名]   # 默认 openclaw
# 幂等、非致命：任何一步失败只告警，不阻断调用方（serving/回收守护都不能被它拖死）。
set -uo pipefail

TARGET="${1:-openclaw}"
if [ -z "$TARGET" ]; then
  echo "[ts-sync-host] ❌ 目标名为空"
  exit 1
fi

cur="$(hostname 2>/dev/null || true)"
if [ "$cur" = "$TARGET" ]; then
  echo "[ts-sync-host] ✅ OS hostname 已是 ${TARGET}"
elif sudo -n hostnamectl set-hostname "$TARGET" >/dev/null 2>&1; then
  echo "[ts-sync-host] ✅ OS hostname: ${cur:-?} → ${TARGET}"
else
  # 无免密 sudo / hostnamectl 不可用时保留现状，交给下一轮或人工处理
  echo "[ts-sync-host] ⚠️ OS hostname 改回 ${TARGET} 失败（当前 ${cur:-?}），保留现状"
  exit 0
fi

# /etc/hosts：补 127.0.1.1 <target>，并清掉继任轮遗留的 openclaw-next 回环行
# （否则 sudo 等工具可能解析到旧名；只动 127.0.1.1 开头的行，不碰其它映射）
if ! grep -qE "^127\.0\.1\.1[[:space:]]+${TARGET}([[:space:]]|$)" /etc/hosts; then
  if echo "127.0.1.1 ${TARGET}" | sudo -n tee -a /etc/hosts >/dev/null 2>&1; then
    echo "[ts-sync-host] ✅ /etc/hosts 已补 127.0.1.1 ${TARGET}"
  else
    echo "[ts-sync-host] ⚠️ /etc/hosts 追加 127.0.1.1 ${TARGET} 失败"
  fi
fi
if [ "$TARGET" != "openclaw-next" ] \
   && grep -qE "^127\.0\.1\.1[[:space:]]+openclaw-next([[:space:]]|$)" /etc/hosts; then
  sudo -n sed -i -E '/^127\.0\.1\.1[[:space:]]+openclaw-next([[:space:]]|$)/d' /etc/hosts 2>/dev/null \
    && echo "[ts-sync-host] ✅ /etc/hosts 已清理 openclaw-next 回环行" \
    || echo "[ts-sync-host] ⚠️ /etc/hosts 清理 openclaw-next 失败"
fi

exit 0
