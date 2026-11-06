#!/usr/bin/env bash
# 2026-11-06: extra new-api deployment for DR runner.
# It intentionally does not touch OmniRoute / zcode2api / other gateway steps.
# Data model mirrors OmniRoute: local live SQLite + Dropbox cold archive.
set -uo pipefail

NEWAPI_DIR="/dropbox/self-hosted/new-api"
LOCAL_DATA="/home/runner/.local/share/new-api/data"
ARCHIVE="dropbox:self-hosted/NewAPI.tar.gz"
TAR="/tmp/NewAPI-restore.tar.gz"
STAGE="/tmp/new-api-restore-stage"
PORT="20129"
IMAGE="calciumion/new-api:latest"

log() { echo "[new-api-deploy] $*"; }
warn() { echo "[new-api-deploy][warn] $*" >&2; }

mkdir -p "$NEWAPI_DIR" "$LOCAL_DATA"

need_files=0
need_db=0
[ -f "$NEWAPI_DIR/docker-compose.yml" ] && [ -f "$NEWAPI_DIR/.env" ] || need_files=1
[ -s "$LOCAL_DATA/one-api.db" ] || need_db=1

archive_ok=0
PREFETCH="/tmp/openclaw-newapi-prefetch"
if [ "$need_files" = "1" ] || [ "$need_db" = "1" ]; then
  rm -rf "$STAGE" "$TAR"
  mkdir -p "$STAGE"
  # 先消费 Prefetch 后台产物；缺失/损坏再回落同步 rclone。
  for attempt in 1 2 3; do
    log "restore archive attempt ${attempt}/3 (prefetch first): $ARCHIVE"
    got=0
    if [ -f "$PREFETCH/pid" ]; then
      _pid="$(cat "$PREFETCH/pid" 2>/dev/null | tr -dc '0-9')"
      _waited=0
      while [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null && [ "$_waited" -lt 180 ]; do
        sleep 2; _waited=$((_waited + 2))
      done
    fi
    if [ -s "$PREFETCH/NewAPI.tar.gz" ]; then
      cp -f "$PREFETCH/NewAPI.tar.gz" "$TAR" && got=1
    fi
    if [ "$got" != "1" ]; then
      rclone copyto "$ARCHIVE" "$TAR" \
        --retries 3 --low-level-retries 10 --timeout 1m --contimeout 15s >/dev/null 2>&1 || true
    fi
    if [ -s "$TAR" ] && tar -tzf "$TAR" >/dev/null 2>&1 && tar -xzf "$TAR" -C "$STAGE"; then
      archive_ok=1
      break
    fi
    sleep 10
  done
  if [ "$archive_ok" != "1" ]; then
    warn "NewAPI.tar.gz missing or invalid; deployment files must already exist to continue"
  fi
fi

if [ "$need_files" = "1" ]; then
  if [ "$archive_ok" != "1" ]; then
    warn "deployment directory incomplete and archive unavailable; skip extra new-api"
    exit 3
  fi
  for item in docker-compose.yml .env CONSOLE.txt README.md scripts secrets; do
    if [ -e "$STAGE/$item" ]; then
      cp -a "$STAGE/$item" "$NEWAPI_DIR/"
    fi
  done
  chmod 600 "$NEWAPI_DIR/.env" 2>/dev/null || true
  chmod 700 "$NEWAPI_DIR/secrets" 2>/dev/null || true
  find "$NEWAPI_DIR/secrets" -type f -exec chmod 600 {} + 2>/dev/null || true
  log "deployment files restored"
fi

# Live DB must stay on a POSIX local disk; never mount sqlite from rclone FUSE.
if ! grep -q '^NEWAPI_DATA_DIR=' "$NEWAPI_DIR/.env" 2>/dev/null; then
  printf '\nNEWAPI_DATA_DIR=%s\n' "$LOCAL_DATA" >> "$NEWAPI_DIR/.env"
fi

bootstrap=0
if [ "$need_db" = "1" ]; then
  if [ "$archive_ok" = "1" ] && [ -s "$STAGE/one-api-backup.sqlite" ]; then
    cp -f "$STAGE/one-api-backup.sqlite" "$LOCAL_DATA/one-api.db"
    rm -f "$LOCAL_DATA/one-api.db-wal" "$LOCAL_DATA/one-api.db-shm"
    log "restored local SQLite from archive backup"
    python3 - "$LOCAL_DATA/one-api.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
print('[new-api-deploy] sqlite integrity:', c.execute('PRAGMA integrity_check').fetchone()[0])
c.close()
PY
  else
    bootstrap=1
    log "no DB backup; bootstrap empty new-api database from restored .env"
  fi
fi

cd "$NEWAPI_DIR" || exit 1
set -a
# shellcheck disable=SC1091
. ./.env
set +a

log "starting container on 127.0.0.1:${PORT} (image ${IMAGE})"
if ! docker compose up -d; then
  warn "docker compose up failed"
  exit 1
fi

healthy=0
for i in $(seq 1 60); do
  if curl -fsS -m 3 "http://127.0.0.1:${PORT}/api/status" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" != "1" ]; then
  warn "new-api did not become healthy on port ${PORT}"
  docker logs --tail 80 new-api 2>&1 || true
  exit 1
fi

if [ "$bootstrap" = "1" ] && [ -f scripts/configure.py ] && [ -f secrets/upstream_export.json ]; then
  log "bootstrapping admin/channels/options from secrets/upstream_export.json"
  if ! python3 -I scripts/configure.py; then
    warn "configure.py failed; container is up but may lack channels"
    exit 1
  fi
fi

# Console entry; failure is non-fatal for the main workflow.
if command -v tailscale >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n tailscale serve --bg --https=8449 "http://127.0.0.1:${PORT}" >/dev/null 2>&1 \
    || warn "tailscale serve 8449 failed; local console still available"
fi

log "done: local http://127.0.0.1:${PORT}/ ; tailnet https://openclaw.taild54677.ts.net:8449/"
