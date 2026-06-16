# Monitoring & alerting

Backups protect the *data*. Monitoring protects the *maker* — it's what tells you the app
is down **before she does**. For a single-operator deployment this is not optional: you are
the only pager, so something external has to watch the box and reach you when it's unwell.

Two pieces, both free, ~10 minutes total. Both are **external** on purpose: a monitor that
runs on the same box can't tell you the box is down.

---

## 1. Uptime monitoring — "is the app serving?"

The Caddyfile leaves **`/health` public** (everything else stays behind basic-auth) so an
external HTTP monitor can verify the *app* is actually responding — not just that Caddy is up.

> **Why public /health matters:** if you point a monitor at a path behind basic-auth, an
> unauthenticated probe gets a `401` that Caddy returns *itself, without ever proxying to the
> app*. The app could be dead and the check still "passes". A public `/health` request
> reverse-proxies to FastAPI, so a failure means the app is genuinely down. `/health` returns
> no sensitive data.

**Set it up (UptimeRobot, free — or BetterStack / Healthchecks / Pingdom, same idea):**

1. Create a free account at <https://uptimerobot.com>.
2. Add a **HTTP(s)** monitor:
   - URL: `https://<your-domain>/health`
   - Interval: 5 minutes (free tier)
   - Expected: HTTP 200
3. Add an **alert contact** you actually see fast — **SMS or phone-push**, not just email.
   A craft-fair Saturday outage you read on Monday is the failure this is meant to prevent.
4. (Recommended) Add a **second contact** so you're not the only path — see the bus-factor
   note in [`recovery.md`](recovery.md).

That's it. If the app stops serving, you get paged within minutes.

---

## 2. Backup dead-man's-switch — "did the backup actually run?"

A backup that silently stopped running is worse than no backup, because you *think* you're
covered. `backup.sh` supports a **dead-man's-switch**: it pings a URL on success and
`<url>/fail` on any failure. If the success ping doesn't arrive on schedule, the service
alerts you.

**Set it up (Healthchecks.io, free):**

1. Create a free account at <https://healthchecks.io>.
2. Create a **Check**:
   - Name: `maker-edition-backup`
   - Schedule: match your cron (e.g. "every day", with a **grace period** of a few hours
     to cover a slow run).
3. Copy the check's **ping URL** (looks like `https://hc-ping.com/<uuid>`).
4. Add it to the **cron environment** so `backup.sh` sees it. Edit the crontab line:
   ```
   0 3 * * * cd /path/to/maker-erp-system/deploy && HEALTHCHECK_URL=https://hc-ping.com/<uuid> ./scripts/backup.sh >> ./backups/backup.log 2>&1
   ```
5. Add an alert contact (email + push). Healthchecks pings you if a daily success ping is
   ever missed (cron died, box down, disk full, pg_dump failed — all of which trigger the
   `/fail` ping or simply the *absence* of a success ping).

`backup.sh` does the rest: an `EXIT` trap pings the bare URL on success and `<url>/fail` on
any error (including `set -e` aborts and explicit failures like "miniodata volume not found").

---

## What "good" looks like

- An app outage pages you on your phone within ~5 minutes.
- A missed/failed nightly backup pages you the next morning.
- Both alerts also reach a second person (or at least a second channel), so a dead phone
  isn't a single point of failure.

These two free services close the gap between "the data is safe" and "the maker isn't left
stranded." Pair them with a rehearsed restore (see [`recovery.md`](recovery.md)) and the
single-operator risk is genuinely managed, not just hoped about.
