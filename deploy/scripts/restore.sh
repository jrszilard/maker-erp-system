#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DB_DUMP="${1:?usage: restore.sh <db-*.sql.gz> <assets-*.tar.gz>}"
ASSETS_TAR="${2:?usage: restore.sh <db-*.sql.gz> <assets-*.tar.gz>}"

if [ ! -f "$DB_DUMP" ];    then echo "[restore] no such file: $DB_DUMP";    exit 1; fi
if [ ! -f "$ASSETS_TAR" ]; then echo "[restore] no such file: $ASSETS_TAR"; exit 1; fi

COMPOSE="docker compose -f docker-compose.yml"

echo "[restore] This will PERMANENTLY REPLACE the live database and MinIO volume with:"
echo "    DB dump : $DB_DUMP"
echo "    Assets  : $ASSETS_TAR"
if [ "${RESTORE_ASSUME_YES:-}" != "1" ]; then
  read -r -p "Type YES to proceed: " _confirm
  [ "$_confirm" = "YES" ] || { echo "[restore] aborted."; exit 1; }
fi

echo "[restore] stopping app so its connection pool cannot race DROP DATABASE…"
$COMPOSE stop app

echo "[restore] restoring database…"
# WITH (FORCE) (PG13+) terminates any lingering sessions (e.g. the db healthcheck) so the
# drop cannot lose the race to a transient connection. The app is already stopped above.
$COMPOSE exec -T db psql -U theseus -d postgres -c "DROP DATABASE IF EXISTS theseus WITH (FORCE);"
$COMPOSE exec -T db psql -U theseus -d postgres -c "CREATE DATABASE theseus OWNER theseus;"
gunzip -c "$DB_DUMP" | $COMPOSE exec -T db psql -U theseus -d theseus -v ON_ERROR_STOP=1 >/dev/null

echo "[restore] restoring assets volume…"
# NOTE: assumes a single deployment on this host. If multiple deployments share the
# host, more than one volume may end in 'miniodata'; head -n1 picks the first alphabetically.
VOL="$(docker volume ls --format '{{.Name}}' | grep -E 'miniodata$' | head -n1)"
if [ -z "$VOL" ]; then echo "[restore] ERROR: could not find the miniodata volume"; exit 1; fi
# Resolve assets tar to absolute dir + basename before mounting into the helper container.
ASSETS_DIR="$(cd "$(dirname "$ASSETS_TAR")" && pwd)"
ASSETS_FILE="$(basename "$ASSETS_TAR")"
docker run --rm -v "$VOL":/data -v "$ASSETS_DIR":/in alpine \
  sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /in/$ASSETS_FILE -C /data"

echo "[restore] starting app + restarting minio to pick up restored state…"
$COMPOSE start app
$COMPOSE restart minio

echo "[restore] done."
