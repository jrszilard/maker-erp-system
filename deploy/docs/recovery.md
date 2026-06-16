# Disaster recovery & continuity (the bus-factor doc)

This stack holds a working maker's **business records and livelihood**. One person (the
operator) runs it. This document exists so that the data survives — and the maker is not
stranded — even in the worst cases: the host nukes the account, the box dies, or **the
operator is unavailable**.

Read this once when you set up. Keep a copy somewhere the operator's family / the maker's
trusted contact could find it (not only on the server, and not only in the operator's head).

---

## 1. Where everything lives (fill this in)

The system is only as recoverable as this inventory. Fill in the blanks and store this
filled-in copy in a password manager you've shared emergency access to.

| Thing | Where it is | Who can reach it |
|---|---|---|
| Deploy bundle (this repo) | `https://github.com/jrszilard/maker-erp-system` (public) | anyone |
| App version pin | `THESEUS_REF` in `.env` (a `theseus-erp` commit SHA) | — |
| Host account | _________ (e.g. DigitalOcean, login + 2FA backup codes) | _________ |
| Domain registrar / DNS | _________ | _________ |
| Server secrets | `deploy/.env` + `deploy/Caddyfile` **on the box** (never in git) | _________ |
| **Off-site backups** | `RCLONE_REMOTE` = _________ (MUST be a *different* provider/account than the host) | _________ |
| **age private key** (decrypts backups) | _________ (password manager — **never on the VPS**) | _________ |
| Monitoring accounts | UptimeRobot + Healthchecks logins | _________ |
| Who pays the bill | card on file at host + registrar; renewal dates _________ | _________ |

> **Correlated-failure warning:** the off-site backup destination must be a **different
> account and ideally a different provider** than the host. If your backups sit in the same
> cloud account that gets suspended, the suspension takes the backups too. The whole
> "restore elsewhere" plan depends on this.

---

## 2. Restore onto a brand-new box (the host died / suspended the account)

This is the path the portable bundle is built for. Target: back online in ~1 hour.

1. **Provision a fresh VPS** (any provider — Ubuntu 24.04, ≥2 GB RAM) and install Docker +
   the compose plugin. Harden per runbook §7.
2. **Clone + configure:**
   ```sh
   git clone https://github.com/jrszilard/maker-erp-system.git
   cd maker-erp-system/deploy
   cp .env.example .env            # set THESEUS_REF (same SHA as before), MAKER_DOMAIN, fresh-or-reused secrets
   cp Caddyfile.example Caddyfile  # username + bcrypt hash
   ```
3. **Repoint DNS:** update the `A` record to the new box's IP. (Let's Encrypt re-issues
   automatically once DNS resolves.)
4. **Fetch the latest off-site backup** and decrypt it:
   ```sh
   rclone copy "$RCLONE_REMOTE/db-<stamp>.sql.gz.age"     ./backups/
   rclone copy "$RCLONE_REMOTE/assets-<stamp>.tar.gz.age" ./backups/
   age -d -i /path/to/age-key.txt -o ./backups/db-<stamp>.sql.gz     ./backups/db-<stamp>.sql.gz.age
   age -d -i /path/to/age-key.txt -o ./backups/assets-<stamp>.tar.gz ./backups/assets-<stamp>.tar.gz.age
   ```
5. **Boot, then restore:**
   ```sh
   docker compose up -d --build
   ./scripts/restore.sh ./backups/db-<stamp>.sql.gz ./backups/assets-<stamp>.tar.gz
   ```
6. **Verify** the board loads and the marker data is present (runbook §4.1). Re-point any
   monitors (UptimeRobot/Healthchecks) at the new host.

> **Rehearse this once, for real, before you need it.** Spin up a throwaway box, restore the
> latest *off-site* backup onto it, and confirm the board loads. A restore script you've
> never run against a clean box at a different provider is a hope, not a backup. (A local
> restore drill has been done; the clean-box-elsewhere drill is the one that proves the
> off-site + age-key + rclone chain end to end.)

---

## 3. "Get the maker's data out" — the no-operator escape hatch

If the operator is unavailable and someone just needs **the maker's data in a usable form**, two
paths, in order of preference:

1. **From a running instance** — the built-in export produces plain CSVs + asset files:
   ```sh
   docker compose exec app python -m theseus.cli export --out /tmp/export.zip
   docker compose cp app:/tmp/export.zip ./export.zip
   ```
   The zip opens in any spreadsheet app. This needs no deep knowledge of the stack.
2. **From a backup only** (no running instance) — restore per §2 onto any box, then run the
   export above. Requires the off-site backup **and** the age private key (§1).

Whoever might need to do this should know it exists and where the age key + host login live.
That is the entire point of §1.

---

## 4. Billing continuity (the quiet killer)

The most common "suspension" isn't abuse enforcement — it's an **expired card or an unread
renewal email**. Mitigate:

- Use a card that won't expire soon; set a calendar reminder before it does.
- Make sure host + registrar renewal notices go to an address the operator actually reads.
- Consider a **second billing contact** or a shared account so a lapsed card doesn't silently
  take down the maker's livelihood.

---

## 5. A note on data custody

These are someone else's business records on the operator's account. Worth a short written
understanding with the maker: who owns the data (she does), how she gets it (§3), and that
she should keep her own copy of any periodic export. Low effort, removes ambiguity, and is
the honest thing to do when you're hosting a person's livelihood.
