# Hetzner Server Diagram
**IP:** 5.161.104.5 — 2 GB RAM · 38 GB disk · Ubuntu

---

## Network topology

```
                            Internet
                               │
                    ┌──────────┴──────────┐
                    │   nginx (80 / 443)   │
                    │   TLS via Certbot    │
                    │   (Let's Encrypt)    │
                    └──────────┬──────────┘
                               │
           ┌───────────────────┼───────────────────┐
           │                   │                   │
           ▼                   ▼                   ▼
assistant.alphatronex   status.alphatronex   vault.alphatronex
        .com                  .com                .com
           │                   │                   │
           ▼                   ▼                   ▼
    :8000 (Docker)      :3001 (Docker)      :8200 (Docker)
 ┌─────────────────┐  ┌──────────────┐  ┌───────────────────┐
 │ personal-       │  │ uptime-kuma  │  │   vaultwarden     │
 │ assistant       │  │ (monitoring) │  │ (password manager)│
 │ FastAPI/uvicorn │  └──────────────┘  └───────────────────┘
 └────────┬────────┘
          │
          │  on startup, two daemon threads:
          │  • APScheduler  — 08:00 daily brief cron
          │  • TG poller    — Telegram long-poll for WA approvals
          │
          │  POST /whatsapp/incoming
          │◄──────────────────────────────────────────┐
          │                                           │
          │                              :3000 (host process)
          │                         ┌──────────────────────────┐
          │                         │   whatsapp-bridge        │
          │                         │   (Node.js / Baileys)    │
          │                         │   runs directly on host  │
          │                         └────────────┬─────────────┘
          │                                      │
          │                              WhatsApp Web
          │                              (QR-code auth)
          │
          │  LangGraph StateGraph  (/run-now  or  08:00 cron)
          ▼
 ┌─────────────────────────────────────────────┐
 │                                             │
 │   START                                     │
 │     │                                       │
 │     ├──► calendar  ──┐                      │
 │     ├──► gmail     ──┤                      │
 │     ├──► youtube   ──┼──► compose ──► deliver ──► END
 │     └──► reminders ──┘                      │
 │                                             │
 └─────────────────────────────────────────────┘
          │                        │
          ▼                        ▼
    Google APIs              Telegram Bot API
    • Calendar v3            sendMessage
    • Gmail v1               (+ inline keyboards
    • YouTube Data v3          for WA approvals)
          │
          ▼
    OpenAI API (gpt-4o-mini)
    • Gmail summary
    • YouTube TL;DRs
    • WhatsApp reply suggestions
```

---

## FAIS

Migrated from Render (2026-07). Source + Dockerfile/compose live in the FAIS repo;
this repo only has the nginx vhost. See [nginx/fais.alphatronex.com.conf](./nginx/fais.alphatronex.com.conf).

```
fais.alphatronex.com
        │
        ▼
  :8010 (Docker, 127.0.0.1 only)
┌───────────────────┐      ┌────────────────────┐
│     fais-app       │◄────►│    fais-mongo      │
│ Node/Express +     │      │ mongo:8            │
│ Angular (built,    │      │ --wiredTigerCache  │
│ served as static)  │      │   SizeGB 0.25      │
│ Playwright/Chromium│      │ not internet-facing│
│ (PDF affidavits)   │      │ (compose network)  │
│ mem_limit: 768m    │      │ mem_limit: 450m    │
└────────────────────┘      └────────────────────┘
```

Added to a box that was already tight on RAM (2GB total) — mem_limit caps above
are a starting point set low deliberately (see docker-compose.prod.yml in the FAIS
repo). Watch `docker stats` after go-live; if fais-app or fais-mongo get OOM-killed,
or the box swaps heavily, the plan is to rescale the Hetzner box to 4GB
(console.hetzner.cloud → server → Rescale) rather than raise the caps further.

---

## Real Dosing (supplement price comparison)

Angular SSG site (9 tracked supplement categories), same non-Docker pattern
as the root splash page below — served directly by nginx from
`/var/www/realdosing`, not proxied to a container; no Node runtime at
request time (every route is prerendered to static HTML at build time).
Source lives in the `supplement-price-app` repo (`app/` — Angular 20
workspace with `@angular/ssr` prerendering); this repo only has the nginx
vhosts and systemd units, matching the FAIS source-lives-elsewhere pattern.

**Deploy** — automated via GitHub Actions (`auto-price-deploy.yml`) on every
push to `main`. No manual rsync needed. The workflow runs `ng build` and
rsyncs `app/dist/app/browser/` to `/var/www/realdosing/`.

The vhost ([nginx/dosinghub.com.conf](./nginx/dosinghub.com.conf)) also
301-redirects the pre-migration flat `.html` URLs (`vitamin-d.html`, etc.)
to their new clean-path equivalents, and points `error_page 404` at the
prerendered `/404/index.html` shell. It also proxies `/api/price-request`
to the agentic pricing intake service on loopback:8787.

**Agentic pricing pipeline** (added 2026-07-22) — two systemd units in
`systemd/` handle automated pricing of DSLD search hits that come back
unpriced, triggered by the pricing-request modal:

| Unit | Type | Purpose |
|------|------|---------|
| `realdosing-pricing-intake.socket` | socket | Binds 127.0.0.1:8787, socket-activates the intake service on first connection (~4KB idle RAM) |
| `realdosing-pricing-intake.service` | simple | `scripts/vps/intake.py` — validates POST payload, deduplicates, appends to queue |
| `realdosing-pricing-worker.service` | oneshot | `scripts/vps/worker.py` — drains queue: DSLD fetch → category match → Anthropic web_search → CSV write → git push |
| `realdosing-pricing-worker.timer` | timer | Fires the worker every 15 minutes (`OnUnitActiveSec=15min`) |

Runtime files live in `/opt/realdosing-pricing/`: `queue.jsonl`,
`worker_state.json`, `worker_audit.jsonl`, and `env` (secrets file, mode
600, owned by `realdosing` service user — contains `ANTHROPIC_API_KEY` and
`PRICE_REQUEST_GIT_PUSH_URL`; never committed).

The repo checkout used by the worker lives at
`/opt/realdosing/supplement-price-app/` (owned by `realdosing:realdosing`).

To check service health:
```bash
sudo systemctl status realdosing-pricing-intake.socket
sudo systemctl list-timers realdosing-pricing-worker.timer
journalctl -u realdosing-pricing-worker -n 50
cat /opt/realdosing-pricing/worker_audit.jsonl | tail -5
```

Canonical domain is **dosinghub.com** (purchased 2026-07-20, DNS on
Cloudflare, cert via Certbot covering `dosinghub.com` + `www.dosinghub.com`).
See [nginx/dosinghub.com.conf](./nginx/dosinghub.com.conf) for the vhost.

The original `realdosing.alphatronex.com` subdomain briefly ran as a
redirect to `dosinghub.com` after the cutover, then was fully decommissioned
on 2026-07-20: nginx vhost removed, Certbot cert deleted
(`certbot delete --cert-name realdosing.alphatronex.com`), and the Cloudflare
DNS A record deleted. It no longer resolves.

---

## Root domain (splash page)

`alphatronex.com` / `www.alphatronex.com` is the odd one out: it's served as
static files directly by nginx from `/var/www/alphatronex` on the host, not
proxied to a container like every other vhost above. Source lives in
[splash/](./splash/) in this repo; deploy with:

```
rsync -a splash/ hetzner:/var/www/alphatronex/
```

See [nginx/alphatronex.com.conf](./nginx/alphatronex.com.conf) for the vhost.

---

## Services

| Service | Runtime | Internal port | Public URL |
|---------|---------|--------------|------------|
| personal-assistant | Docker | 8000 | https://assistant.alphatronex.com |
| uptime-kuma | Docker | 3001 | https://status.alphatronex.com |
| vaultwarden | Docker | 8200 | https://vault.alphatronex.com |
| whatsapp-bridge | Node.js (host) | 3000 | internal only (172.17.0.1:3000) |
| fais-app | Docker | 8010 | https://fais.alphatronex.com |
| fais-mongo | Docker | 27017 | internal only (compose network) |
| realdosing (static) | nginx (no container) | — | https://dosinghub.com |

---

## Persistent storage

```
/opt/assistant/data/
  agentic.db          — SQLite (all tables below)
  token.json          — Google OAuth refresh token
  credentials.json    — Google OAuth client secrets

SQLite tables
  runs              — one row per morning-brief execution
  briefs            — rendered markdown body per run
  reminders         — recurring reminders (managed via /settings)
  seen_items        — dedup log for YouTube videos
  app_settings      — feature flags (gmail_enabled, youtube_enabled)
  youtube_channels  — channel list (managed via /settings)
  pending_replies   — WhatsApp DMs awaiting Telegram approval
```

FAIS:

```
Docker volume: fais_mongo_data  →  /data/db (fais-mongo container)
server/.env.production            — secrets (JWT, SSN key, SMTP, OpenAI, B2, AWS); git-ignored, not in this repo
```

---

## Outbound traffic

| Destination | Purpose |
|-------------|---------|
| `googleapis.com` | Calendar, Gmail, YouTube Data, OAuth refresh |
| `api.telegram.org` | Delivery + long-poll for WA approvals |
| `api.openai.com` | Gmail summary, YouTube TL;DRs, WA reply suggestions (personal-assistant); AI reports (FAIS, optional) |
| `172.17.0.1:3000` | WhatsApp bridge (Docker → host, local only) |
| `s3.*.backblazeb2.com` | FAIS document storage (optional, if B2_* configured) |
| `textract.*.amazonaws.com` | FAIS document OCR via Textract (optional, if DOCUMENT_INTAKE_TEXTRACT enabled) |
| SMTP host (configurable) | FAIS invite + password-reset email (optional) |
