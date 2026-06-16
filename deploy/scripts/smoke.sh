#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${THESEUS_REF:?set THESEUS_REF to a theseus-erp commit SHA that exists on the remote}"

COMPOSE="docker compose --env-file .env.smoke -f docker-compose.yml"

cleanup() {
  $COMPOSE down -v >/dev/null 2>&1 || true
  rm -f .env.smoke Caddyfile.smoke
}
trap cleanup EXIT

# Generate bcrypt hash into a shell var BEFORE writing any files — baking it literally
# into Caddyfile.smoke avoids compose/dotenv $-interpolation corrupting the hash.
SMOKE_USER=test
SMOKE_PASS=testpass
SMOKE_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$SMOKE_PASS")

# Throwaway env (non-default secrets so the app's ENFORCE_PRODUCTION boot guard passes).
# CADDYFILE points the base compose at the baked-hash smoke Caddyfile below — no override
# compose file needed, so this is robust regardless of compose's volume-merge behavior.
cat > .env.smoke <<EOF
THESEUS_REF=${THESEUS_REF}
MAKER_DOMAIN=localhost
CADDYFILE=./Caddyfile.smoke
POSTGRES_PASSWORD=smokepg$(date +%s)
MINIO_ROOT_USER=smokeminiouser
MINIO_ROOT_PASSWORD=smokeminiosecret$(date +%s)
SECRET_KEY=smoke-secret-not-for-real-use-0123456789abcdef0123456789abcdef
EOF

# Localhost Caddyfile with internal self-signed certs (mirrors the prod headers/auth/body-cap).
# Unquoted heredoc so ${SMOKE_USER}/${SMOKE_HASH} expand — baking the literal values in.
cat > Caddyfile.smoke <<EOF
{
	local_certs
}
localhost {
	basic_auth {
		${SMOKE_USER} ${SMOKE_HASH}
	}
	request_body {
		max_size 25MB
	}
	reverse_proxy app:8000
}
EOF

echo "[smoke] building + starting the stack (first build clones theseus-erp@$THESEUS_REF)…"
$COMPOSE up -d --build

echo "[smoke] waiting for the app to become reachable + healthy through Caddy…"
ok=""
for _ in $(seq 1 60); do
  code=$(curl -sk -u "$SMOKE_USER:$SMOKE_PASS" -o /dev/null -w '%{http_code}' https://localhost/health 2>/dev/null || true)
  if [ "$code" = "200" ]; then ok=1; break; fi
  sleep 2
done
[ -n "$ok" ] || { echo "[smoke] FAIL: stack never became healthy"; $COMPOSE logs --tail 50 caddy app; exit 1; }

echo "[smoke] 1/3 unauthenticated request must be 401…"
code=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/ || true)
[ "$code" = "401" ] || { echo "[smoke] FAIL: expected 401, got $code"; exit 1; }

echo "[smoke] 2/3 authenticated /health must be 200…"
code=$(curl -sk -u "$SMOKE_USER:$SMOKE_PASS" -o /dev/null -w '%{http_code}' https://localhost/health || true)
[ "$code" = "200" ] || { echo "[smoke] FAIL: expected 200, got $code"; $COMPOSE logs --tail 50 app; exit 1; }

echo "[smoke] 3/3 authenticated board must render…"
body=$(curl -sk -u "$SMOKE_USER:$SMOKE_PASS" https://localhost/ || true)
echo "$body" | grep -q "Ideas\|Welcome to Maker Edition" \
  || { echo "[smoke] FAIL: board not served"; exit 1; }

echo "[smoke] PASS"
