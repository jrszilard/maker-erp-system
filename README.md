# Maker Edition — deployment bundle

Self-hostable deployment for **[Theseus ERP — Maker Edition](https://github.com/jrszilard/theseus-erp)**:
a maker-focused ERP/inventory tool for solo artists and craftspeople. Track one creative
idea across all its product formats (sticker, postcard, print, original, magnet…), store
the source files, and follow per-channel pricing, sales, costs, and margins — with an
optional AI assistant for capture and insight.

This repository is the **operator artifact**: a production `docker-compose` stack plus the
scripts and runbook to install, back up, restore, and upgrade it. The application code
lives in the public [`theseus-erp`](https://github.com/jrszilard/theseus-erp) repo and is
pinned here by commit SHA at build time.

## Topology

```
Caddy (TLS + basic-auth gate)  →  app (FastAPI/uvicorn :8000)  →  Postgres 16
                                                               →  MinIO (object storage)
```

Only Caddy's ports 80/443 are published to the host. Postgres and MinIO have no host port
mappings and are unreachable from outside the compose network.

## Quick start

Full instructions — provisioning, hardening, TLS, backups, restore, upgrade, data export —
are in the **operator runbook**: [`deploy/docs/runbook.md`](deploy/docs/runbook.md).

```sh
git clone https://github.com/jrszilard/maker-erp-system.git
cd maker-erp-system/deploy

cp .env.example .env            # fill in: THESEUS_REF, MAKER_DOMAIN, secrets
cp Caddyfile.example Caddyfile  # set basic-auth username + bcrypt hash

# Optional but recommended: smoke-test the full build/boot on localhost first
THESEUS_REF=<full-40-char-sha> ./scripts/smoke.sh

docker compose up -d --build
```

The app starts with `ENFORCE_PRODUCTION=true` and **refuses to boot** if any secret is left
at its placeholder default. The basic-auth hash lives in `Caddyfile` (not `.env`) on purpose:
a bcrypt hash's `$` characters are corrupted by compose's `.env` interpolation — see the
comments in `Caddyfile.example`.

## What's in `deploy/`

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The stack: Caddy + app + Postgres + MinIO |
| `.env.example` | Backend secrets + domain template (copy to `.env`) |
| `Caddyfile.example` | Caddy config + basic-auth template (copy to `Caddyfile`) |
| `scripts/smoke.sh` | Build + boot the full stack on localhost and assert it works |
| `scripts/backup.sh` | Postgres dump + MinIO snapshot (optional age-encrypted off-site copy) |
| `scripts/restore.sh` | Restore from a backup pair (drill it after first install) |
| `docs/runbook.md` | Full operator runbook |

## License

AGPL-3.0 — inherits [Theseus](https://github.com/jrszilard/theseus-erp). See [`LICENSE`](LICENSE).
