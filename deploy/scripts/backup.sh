#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${BACKUP_DIR:-./backups}"
RETAIN_DAYS="${RETAIN_DAYS:-14}"
mkdir -p "$OUT_DIR"

COMPOSE="docker compose -f docker-compose.yml"

echo "[backup] pg_dump…"
$COMPOSE exec -T db pg_dump -U theseus theseus | gzip > "$OUT_DIR/db-$STAMP.sql.gz"

echo "[backup] minio data volume…"
# NOTE: assumes a single deployment on this host. If multiple deployments share the
# host, more than one volume may end in 'miniodata'; head -n1 picks the first alphabetically.
VOL="$(docker volume ls --format '{{.Name}}' | grep -E 'miniodata$' | head -n1)"
if [ -z "$VOL" ]; then
  echo "[backup] ERROR: could not find the miniodata volume"; exit 1
fi
# OUT_DIR may be relative; resolve it to absolute before mounting.
ABS_OUT="$(cd "$OUT_DIR" && pwd)"
docker run --rm -v "$VOL":/data -v "$ABS_OUT":/out alpine \
  tar czf "/out/assets-$STAMP.tar.gz" -C /data .

echo "[backup] pruning backups older than ${RETAIN_DAYS}d…"
find "$OUT_DIR" -name 'db-*.sql.gz'         -mtime +"$RETAIN_DAYS" -delete
find "$OUT_DIR" -name 'assets-*.tar.gz'   -mtime +"$RETAIN_DAYS" -delete
find "$OUT_DIR" -name 'db-*.sql.gz.age'   -mtime +"$RETAIN_DAYS" -delete
find "$OUT_DIR" -name 'assets-*.tar.gz.age' -mtime +"$RETAIN_DAYS" -delete

# Optional encrypted off-site copy (recommended). Requires `age` + a recipient public key.
# Set AGE_RECIPIENT (age1… pubkey) to enable encryption.
# Set RCLONE_REMOTE (e.g. "s3:my-bucket/backups") to also push off-site via rclone.
if [ -n "${AGE_RECIPIENT:-}" ]; then
  echo "[backup] encrypting with age…"
  age -r "$AGE_RECIPIENT" -o "$OUT_DIR/db-$STAMP.sql.gz.age"     "$OUT_DIR/db-$STAMP.sql.gz"
  age -r "$AGE_RECIPIENT" -o "$OUT_DIR/assets-$STAMP.tar.gz.age" "$OUT_DIR/assets-$STAMP.tar.gz"
  if command -v rclone >/dev/null 2>&1 && [ -n "${RCLONE_REMOTE:-}" ]; then
    echo "[backup] pushing encrypted copies off-site via rclone…"
    rclone copy "$OUT_DIR/db-$STAMP.sql.gz.age"     "$RCLONE_REMOTE"
    rclone copy "$OUT_DIR/assets-$STAMP.tar.gz.age" "$RCLONE_REMOTE"
  fi
fi

echo "[backup] done: $OUT_DIR/db-$STAMP.sql.gz + assets-$STAMP.tar.gz"
