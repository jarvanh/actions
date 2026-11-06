#!/usr/bin/env bash
# 2026-11-06: Create NewAPI.tar.gz for DR restore.
# Mirrors OmniRoute archive pattern: deployment files + SQLite online backup.
# Live DB is local POSIX disk; this archive is cold-only and can live on Dropbox.
set -euo pipefail

OUTPUT_TAR="${1:-}"
if [ -z "$OUTPUT_TAR" ]; then
  echo "Usage: $0 /path/to/NewAPI.tar.gz" >&2
  exit 2
fi

MIN_SIZE=$((16 * 1024))
DIR="/dropbox/self-hosted/new-api"
DATA="${NEWAPI_DATA_DIR:-/home/runner/.local/share/new-api/data}"
DB="$DATA/one-api.db"
STAGE="$(mktemp -d /tmp/new-api-archive-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

rm -f "$OUTPUT_TAR"

if [ ! -f "$DIR/docker-compose.yml" ] || [ ! -f "$DIR/.env" ]; then
  echo "new_api_deploy_dir_missing" >&2
  exit 3
fi
if [ ! -s "$DB" ]; then
  echo "new_api_sqlite_missing" >&2
  exit 3
fi

# sqlite3 CLI may be absent; Python backup gives a consistent snapshot.
python3 - "$DB" "$STAGE/one-api-backup.sqlite" <<'PYNEWAPI'
import sqlite3, sys
src = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
dst = sqlite3.connect(sys.argv[2])
try:
    src.backup(dst)
finally:
    dst.close()
    src.close()
PYNEWAPI

cp -a "$DIR/docker-compose.yml" "$DIR/.env" "$DIR/CONSOLE.txt" "$DIR/README.md" "$STAGE/" 2>/dev/null || true
cp -a "$DIR/scripts" "$DIR/secrets" "$STAGE/" 2>/dev/null || true
# do not archive the live data directory; only the cold sqlite backup
chmod 600 "$STAGE/.env" 2>/dev/null || true
chmod 700 "$STAGE/secrets" 2>/dev/null || true
find "$STAGE/secrets" -type f -exec chmod 600 {} + 2>/dev/null || true

tar -C "$STAGE" -czf "$OUTPUT_TAR" .
chmod 644 "$OUTPUT_TAR" 2>/dev/null || true

actual_size=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null || echo 0)
if [ "$actual_size" -lt "$MIN_SIZE" ] || ! tar -tzf "$OUTPUT_TAR" >/dev/null 2>&1; then
  echo "new_api_archive_invalid size=$actual_size output=$OUTPUT_TAR" >&2
  exit 1
fi
echo "new_api_archive_ready size=$actual_size output=$OUTPUT_TAR"
