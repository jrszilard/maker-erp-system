# Maker Edition — Operator Runbook

This stack is a self-hosted deployment of [Theseus ERP — Maker Edition](https://github.com/jrszilard/theseus-erp).
The topology is: Caddy (TLS termination + basic-auth gate) → app (FastAPI/uvicorn on port 8000)
→ Postgres 16 + MinIO for object storage, all wired together with docker-compose.
One operator hosts the stack; the maker accesses it via a URL and optional phone home screen.
The app code is the public `theseus-erp` repo, pinned by commit SHA at build time.

---

## 1. First install (fresh VPS)

### 1.1 Provision and pre-requisites

1. Spin up a small VPS — 2 GB RAM is sufficient. Install Docker Engine plus the compose
   plugin (the `docker compose` sub-command, not the legacy `docker-compose` binary).
2. Point a DNS A-record for your domain at the VPS public IP and wait for it to propagate.
   Caddy will request a Let's Encrypt certificate automatically on first HTTPS request;
   it will fail if DNS has not propagated yet.
3. Harden the box **before** exposing it — see §7.

### 1.2 Clone and configure

```sh
git clone https://github.com/jrszilard/maker-erp-system.git
cd maker-erp-system/deploy
cp .env.example .env
cp Caddyfile.example Caddyfile
```

There are **two** files to fill in: `.env` (backend secrets + domain) and `Caddyfile`
(the basic-auth username + password hash). Both are gitignored.

**`.env`** — fill in every value. The app starts with `ENFORCE_PRODUCTION=true` and will
**refuse to boot** if `SECRET_KEY`, `POSTGRES_PASSWORD`, `MINIO_ROOT_USER`, or
`MINIO_ROOT_PASSWORD` are left at their placeholder defaults.

| Variable | What to set | How to generate |
|---|---|---|
| `THESEUS_REF` | A **full 40-char** commit SHA from `main` on [theseus-erp](https://github.com/jrszilard/theseus-erp) (once PR #3 is merged). Pin a SHA — not a tag (tags are mutable). An abbreviated SHA can fail BuildKit's git fetch. | Copy from the commit log on GitHub |
| `MAKER_DOMAIN` | Your DNS hostname, e.g. `maker.example.com` | — |
| `POSTGRES_PASSWORD` | Strong random password | `openssl rand -hex 24` |
| `MINIO_ROOT_USER` | MinIO root username | `openssl rand -hex 24` |
| `MINIO_ROOT_PASSWORD` | MinIO root password | `openssl rand -hex 24` |
| `SECRET_KEY` | App signing key | `openssl rand -hex 32` |

**`Caddyfile`** — edit the `basic_auth` block: set the username and paste the bcrypt
password hash. Generate the hash with:

```sh
docker run --rm caddy:2-alpine caddy hash-password --plaintext '<password>'
```

> **Why the hash is here and not in `.env`:** a bcrypt hash contains `$` characters
> (`$2a$14$…`). docker-compose interpolates `$` sequences in `.env` values and corrupts
> the hash — Caddy then fails to parse it (crash-loop) or rejects every login (401).
> Pasting it literally into `Caddyfile` keeps it out of every interpolation layer. Caddy
> will refuse to start until a real hash is present, so you cannot accidentally ship
> without auth.

### 1.3 (Recommended) Pin base images before go-live

Edit `docker-compose.yml` and replace the floating `minio/minio:latest` tag with a
specific `RELEASE.*` tag — see the comment already in the file and the current tags at
<https://hub.docker.com/r/minio/minio/tags>. Optionally pin `caddy:2-alpine` and
`postgres:16-alpine` to specific minor versions as well. Floating tags risk silent
breaking changes.

### 1.4 Start the stack

```sh
docker compose up -d --build
```

The first build clones `theseus-erp` at `THESEUS_REF` — this can take a few minutes.

Watch startup:

```sh
docker compose logs -f app
```

The app entrypoint seeds the maker pack (channels and formats) once on first boot, then
starts uvicorn. Wait until you see uvicorn's "Application startup complete" line.

### 1.5 Create the MinIO bucket

The app expects a bucket named `theseus-assets`. MinIO does **not** auto-create buckets,
and the MinIO console port (9001) is intentionally not exposed to the host — do not add
a host port mapping.

The MinIO client `mc` is a **separate image** (`minio/mc`) — it is not included in the
`minio/minio` server image. Create the bucket with a one-shot sidecar container on the
compose network:

```sh
# The MinIO client `mc` is a SEPARATE image (minio/mc) — it is not in the server
# container. Create the bucket with a one-shot sidecar on the compose network.
# Find the network name (compose project defaults to the 'deploy' dir → 'deploy_default'):
docker network ls | grep default

# Then (substitute your real .env MinIO values for <USER>/<PASS>, and the network if different):
docker run --rm --network deploy_default \
  -e MC_HOST_local="http://<MINIO_ROOT_USER>:<MINIO_ROOT_PASSWORD>@minio:9000" \
  minio/mc mb --ignore-existing local/theseus-assets
```

> **Not required for the app to boot, but required for the asset file strips (§8).** The
> app's `depends_on minio` only gates on MinIO's liveness endpoint — boot and initial
> seeding do not touch the bucket. The serve route behind the design-detail file strips
> reads objects from this bucket, so it must exist before that feature works.

### 1.6 Verify

Visit `https://<MAKER_DOMAIN>` — you should see a basic-auth prompt. Sign in and
confirm the Ideas board loads (welcome panel on first run).

### 1.7 Add to maker's phone

In the maker's mobile browser, use **Add to Home Screen** to save the URL as an app icon.

---

## 2. Upgrade

> **First upgrade to an Alembic release?** If this prod DB predates Alembic (no
> `alembic_version` table), do the one-time adoption in "Adopting Alembic on the
> existing prod database" (below) **before** `docker compose up -d` — otherwise the
> entrypoint's `theseus migrate` will fail trying to recreate existing tables.

1. **Back up first (mandatory):** `./scripts/backup.sh`

   The container entrypoint runs `theseus migrate` (`alembic upgrade head`) automatically
   before the app starts — schema changes are applied in place, with data preserved. Back
   up before every upgrade regardless.

   **Manual fallback** (e.g. to debug a migration failure without starting the app):
   ```sh
   docker compose run --rm --entrypoint sh app -c 'python -m theseus.cli migrate'
   ```

2. Bump `THESEUS_REF` in `.env` to the new commit SHA.

3. Rebuild and restart:
   ```sh
   docker compose up -d --build
   ```

4. Verify:
   ```sh
   curl -sk -u <username>:<password> https://<MAKER_DOMAIN>/health
   ```
   Expect HTTP 200, and confirm the board loads in the browser.

**Rollback:** restore the pre-upgrade backup (§4) and set `THESEUS_REF` back to the
previous SHA, then re-run `docker compose up -d --build`.

### Adopting Alembic on the existing prod database (one-time)

Prod databases built before this release have no `alembic_version` table — the schema
was created by `create_all`. The baseline migration's `CREATE TABLE` statements would
**fail** against those existing tables. Stamp the baseline **once** (records the version,
runs no DDL) **before** the first migration-image boot:

1. Verify prod has no `alembic_version` table:
   ```sh
   docker compose exec db psql -U theseus -d theseus -c "\dt alembic_version"
   ```
   Expect: "Did not find any relation". If the table already exists the DB is already
   stamped — skip to step 4.

2. **Confirm the prod schema matches the baseline — count the tables.** `create_all` no
   longer backfills at boot, so any table the baseline expects that prod lacks will *never*
   be created once you stamp. Count prod's tables and compare to the baseline (currently **32**):
   ```sh
   docker compose exec -T db sh -c \
     'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM pg_tables WHERE schemaname=current_schema()"'
   ```
   If the count is **short**, the old `create_all` boot path likely skipped tables whose
   models it never imported. (On the 2026-06-29 adoption, prod had **31** — it was missing
   **`crew_members`**, because the old boot only imported the assets + event-store models.)
   **Reconcile additively *before* stamping** — create each missing table from its model
   (non-destructive; the table holds no data). Example for `crew_members`:
   ```sh
   docker compose exec -T app python - <<'PY'
   import asyncio
   from theseus.database import engine
   from theseus.keel.auth.models import CrewMember   # import the model for the missing table
   async def _create():
       async with engine.begin() as conn:
           await conn.run_sync(CrewMember.__table__.create)
   asyncio.run(_create())
   PY
   ```
   Re-run the count and confirm it equals the baseline before continuing.

3. Stamp the baseline (bypass the entrypoint so it does not try to `upgrade`):
   ```sh
   docker compose run --rm --entrypoint sh app -c 'python -m alembic stamp head'
   ```

4. `docker compose up -d` normally — the entrypoint's `theseus migrate` is a no-op
   (already at head) and the app boots. Future deploys apply new migrations automatically.

> **Warning:** never run `theseus check-migrations` against prod — it is destructive.

---

## 3. Backups

### Manual

From the `deploy/` directory:

```sh
./scripts/backup.sh
```

Writes two files to `./backups/`:
- `db-<YYYYMMDD-HHMMSS>.sql.gz` — Postgres dump
- `assets-<YYYYMMDD-HHMMSS>.tar.gz` — MinIO data volume snapshot

Files older than `RETAIN_DAYS` days are pruned automatically (default: **14**). Override
by setting `RETAIN_DAYS=<n>` in the environment before running the script or in the cron
environment.

The backup output directory can also be overridden via `BACKUP_DIR=<path>` (default:
`./backups`).

### Nightly host cron

Add this line to the operator's crontab (`crontab -e`), adjusting the path:

```
0 3 * * * cd /path/to/maker-erp-system/deploy && ./scripts/backup.sh >> ./backups/backup.log 2>&1
```

### Encrypted off-site copy (recommended)

Set two additional environment variables (in the cron environment or a wrapper script):

| Variable | Value |
|---|---|
| `AGE_RECIPIENT` | Your `age` public key (`age1…`) |
| `RCLONE_REMOTE` | rclone destination, e.g. `s3:my-bucket/backups` |

When `AGE_RECIPIENT` is set, the script encrypts both files with
[age](https://github.com/FiloSottile/age) before they leave the box, producing
`.sql.gz.age` and `.tar.gz.age` files. When `RCLONE_REMOTE` is also set and `rclone` is
installed, those encrypted copies are pushed off-site automatically.

**Keep the age private key OFF the VPS.** Without it the off-site copies cannot be
decrypted. Store it in a password manager.

### Consistency note

The backup script tars the MinIO volume while MinIO is running. At maker (low-write)
scale this is fine. For a higher-write deployment, quiesce storage first:

```sh
docker compose stop minio
./scripts/backup.sh
docker compose start minio
```

---

## 4. Restore

> Always drill a restore after first install — see §4.1.

```sh
./scripts/restore.sh ./backups/db-<stamp>.sql.gz ./backups/assets-<stamp>.tar.gz
```

The script:
1. Prints the files it will restore and asks you to type `YES` to proceed.
2. Stops the app (prevents connection-pool races against `DROP DATABASE`).
3. Drops and recreates the `theseus` database, loads the dump with
   `ON_ERROR_STOP=1` (fails loudly on any SQL error).
4. Wipes the MinIO volume and restores the asset tar.
5. Starts the app and restarts MinIO to pick up the restored state.

**Non-interactive use** (automation/scripts):

```sh
RESTORE_ASSUME_YES=1 ./scripts/restore.sh ./backups/db-<stamp>.sql.gz ./backups/assets-<stamp>.tar.gz
```

### 4.1 Restore drill (do this once after first install)

1. Create a recognisable "marker" design in the UI (e.g. a project named `restore-test`).
2. Run a backup: `./scripts/backup.sh` — note the timestamp in the filenames.
3. Delete the marker design in the UI (or run `docker compose down -v && docker compose up -d`
   to wipe all data).
4. Restore: `./scripts/restore.sh ./backups/db-<stamp>.sql.gz ./backups/assets-<stamp>.tar.gz`
5. Confirm the marker design is back in the UI.

This proves the backups are actually restorable before you need them in anger. (Also
covers Task 12 of the Maker Edition.)

---

## 5. Data export — the maker's escape hatch

Run the built-in CLI export from inside the app container:

```sh
docker compose exec app python -m theseus.cli export --out /tmp/export.zip
docker compose cp app:/tmp/export.zip ./export.zip
```

The zip contains:
- One CSV per entity (openable in any spreadsheet app)
- All asset files
- `_missing_assets.txt` listing any asset objects that could not be read from MinIO

---

## 6. Local smoke test

Run this **before** pointing real DNS at the VPS to confirm the full stack builds and
behaves correctly:

```sh
cd deploy
THESEUS_REF=<sha> ./scripts/smoke.sh
```

The script:
1. Generates a throwaway `.env.smoke` with non-default secrets (satisfies `ENFORCE_PRODUCTION`).
2. Writes a `Caddyfile.smoke` that uses Caddy's internal self-signed TLS (no DNS required)
   and mirrors the production headers, auth, and 25 MB body cap.
3. Starts the full stack on `localhost` from `docker-compose.yml`, pointing the
   `CADDYFILE` variable at `Caddyfile.smoke` (so no production `Caddyfile` is needed to
   smoke-test, and it works regardless of compose's volume-merge behavior).
4. Asserts three checks:
   - Unauthenticated request → 401
   - Authenticated `GET /health` → 200
   - Authenticated `GET /` serves the Ideas board (contains `Ideas` or `Welcome to Maker Edition`)
5. Tears down and removes volumes on exit (pass or fail).

A successful run prints `[smoke] PASS`.

Requires Docker and a valid `THESEUS_REF` SHA. No real domain or internet TLS needed.

---

## 7. VPS hardening checklist

Before exposing the stack to the internet:

- **SSH hardening:** disable password authentication (`PasswordAuthentication no` in
  `/etc/ssh/sshd_config`), create a non-root sudo user, optionally move SSH to a
  non-default port.
- **`fail2ban`:** enable the `sshd` jail. Add a second jail watching Caddy's access log
  for repeated 401 responses (basic-auth brute force).
- **Automatic security updates:** install and enable `unattended-upgrades` for OS
  security patches.
- **Firewall:** allow only ports 22, 80, and 443.

  > **Docker bypasses UFW.** Docker writes iptables rules that bypass UFW rules. This
  > compose file publishes **only** Caddy's ports 80 and 443 to the host; Postgres (5432),
  > MinIO (9000), and the MinIO console (9001) have no host port mappings and are therefore
  > unreachable from outside. **Do not add host port mappings for `db` or `minio`**, and
  > do not leave any temporary `9001` mapping in place after debugging.

---

## 8. Known constraints

- **Asset files are shown in the UI (read-only).** As of `THESEUS_REF` `bd1672d…` the app
  serves asset bytes via `GET /api/v1/assets/raw/{key}` (raster images `inline`, everything
  else — incl. SVG — as an `attachment`; `X-Content-Type-Options: nosniff` always), and the
  design-detail screen renders Blueprint-introspected file strips. The `theseus-assets`
  bucket must exist (§1.5) for the route to fetch bytes. **Uploading/attaching files from
  the UI is still deferred** — files are attached via the asset API; the export (§5)
  includes all asset files regardless.

- **Schema is managed by Alembic migrations.** The container entrypoint runs
  `theseus migrate` (`alembic upgrade head`) before the app starts, applying any pending
  migrations in place with data preserved. Back up before every upgrade — see §2.
  Operators upgrading a database built before this release must stamp the baseline once
  before the first migration-image boot — see §2 "Adopting Alembic on the existing prod
  database (one-time)".

- **Single deployment per host assumed.** The backup and restore scripts find the MinIO
  volume by matching the suffix `miniodata` (`head -n1` picks the first alphabetically).
  Running a second Theseus stack on the same host requires explicit volume targeting in
  both scripts.

---

## 9. Monitoring & alerting

Backups protect the data; monitoring protects the maker — it tells you the app is down
**before she does**. For a single-operator deployment this is not optional. Two free,
external services (~10 min total):

- **Uptime:** point UptimeRobot (or similar) at `https://<domain>/health`. The Caddyfile
  leaves `/health` **public** on purpose so the probe reaches the app, not just Caddy.
- **Backup dead-man's-switch:** set `HEALTHCHECK_URL` (a Healthchecks.io ping URL) in the
  backup cron line; `backup.sh` pings it on success and `<url>/fail` on any failure, so a
  silently-stopped backup alerts you.

Full setup: [`monitoring.md`](monitoring.md). Route alerts to SMS/phone-push, and add a
second contact (bus factor).

---

## 10. Disaster recovery & continuity

The bundle is portable by design: a host failure (or account suspension) is "restore onto a
fresh box," not data loss — **provided** the off-site backup lives on a *different* account
than the host, and you've rehearsed the restore. The continuity doc covers restore-from-
scratch onto a new provider, the "get the maker's data out" escape hatch (`theseus export`),
billing-lapse continuity (the most common cause of an outage), and a credential inventory for
the bus-factor case.

Full procedure + the fill-in inventory: [`recovery.md`](recovery.md). **Do the clean-box
restore drill once** — a restore you've never run against a fresh box at a different provider
is a hope, not a backup.

---

## 11. Integration API (opt-in)

Lets an external storefront (or any HTTP client) pull the maker's current-version sellable
products. **Opt-in:** endpoints return 503 until `INTEGRATION_API_TOKEN` is set in `.env`.

**Enable:**

1. Set `INTEGRATION_API_TOKEN` in `.env` — generate with `openssl rand -hex 32`.
2. Confirm `Caddyfile` carves out `/api/v1/integration/*` from the `@protected` matcher
   (already present in `Caddyfile.example`).
3. Redeploy: `docker compose up -d --build`.

**Storefront call:**

```sh
curl -H "Authorization: Bearer <token>" https://<MAKER_DOMAIN>/api/v1/integration/products
```

Returns JSON — current-version sellable products. Append `/{sku}` for a single product.

**Token rotation:** update `INTEGRATION_API_TOKEN` in `.env` + redeploy. Old token is
invalidated immediately on container start. Empty the value to disable the API again.
