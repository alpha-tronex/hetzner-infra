# Hetzner Server Diagram
**IP:** 5.161.104.5 — 3 vCPU · 4 GB RAM · 40 GB disk (local) · Ubuntu

This file is mostly about the shared box above. FAIS firm deployments (client data) run on a second
server, **fais-clients** (178.156.222.192): see [Client-data server](#client-data-server-fais-clients).

## Server plan (as of 2026-09-22)

| Spec | Value |
|------|-------|
| vCPU | 3 |
| RAM | 4 GB |
| Disk (local) | 40 GB |
| Traffic out | 2 TB/mo included (0 TB used as of this writing) |
| Cost | ~37.49/mo (console shows ~20.29 usage so far this billing period) |

Rescaled up from the original 2 GB RAM plan (see the FAIS and Quiz Master
sections below, written when the box was still on 2 GB — the "rescale to
4GB" contingency they mention has since happened). Headroom is meaningfully
better now, but re-check `free -h` / `docker stats --no-stream` after any
RAM-heavy change (new service, load/stress test) rather than assuming it's
still fine — those sections' mem_limit caps were tuned for the old 2 GB
ceiling and haven't been revisited since the rescale.

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
          │                         │   → residential proxy    │
          │                         │     (see note below)     │
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
this repo only has the nginx vhosts. Since 2026-10-23 the demo is **demo.faislaw.com**
([nginx/demo.faislaw.com.conf](./nginx/demo.faislaw.com.conf)); `faislaw.com` 302s to it until there's
a landing page ([nginx/faislaw.com.conf](./nginx/faislaw.com.conf)), and the old `fais.alphatronex.com`
301-redirects to it ([nginx/fais.alphatronex.com.conf](./nginx/fais.alphatronex.com.conf)). The demo's
`APP_BASE_URL` is `https://demo.faislaw.com`. `www.faislaw.com` shares the apex vhost and certificate.
The dev box is **dev.faislaw.com** ([nginx/dev.faislaw.com.conf](./nginx/dev.faislaw.com.conf), since
2026-10-28): basic auth (user `alpha`, `/etc/nginx/fais-dev.htpasswd`), certificate expires 2027-01-26.

```
demo.faislaw.com
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

Added to a box that was tight on RAM back when this ran on the original 2GB
plan — mem_limit caps above were a starting point set low deliberately (see
docker-compose.prod.yml in the FAIS repo). The box has since been rescaled to
4GB / 3 vCPU (see Server plan above), so headroom is meaningfully better now;
the caps themselves haven't been revisited since the rescale. Watch
`docker stats` after any future RAM-heavy change — if fais-app or fais-mongo
get OOM-killed, or the box swaps heavily, raise the specific service's
mem_limit rather than assuming another rescale is needed.

**CD (2026-10-13):** `FAIS/.github/workflows/ci.yml` deploys on every push to
`main` that passes checks (server typecheck + node:test, client Vitest, prod
build, testability audit). The `DEPLOY_SSH_KEY` key is forced to
`/opt/fais/deploy.sh` (untracked copy of `FAIS/deploy/deploy.sh`), which resets
`/opt/fais` to `origin/main`, rebuilds `app` with `GIT_SHA`, and waits for
`/api/health` to report it. Details and rollback: `FAIS/deploy/README.md`.

**MongoDB auth (2026-10-20):** `fais-mongo` runs with `--auth`. Logins (admin db): `faisRoot`
(humans), `faisApp` (demo, `fais_demo` + `fais_demo_snapshot`), `faisAgent` (read-only AI Query),
`faisBackup` (backup role), plus `fais<Firm>` / `fais<Firm>Agent` per firm. Passwords:
`~/.fais-mongo-credentials` and `~/.fais-firm-<firm>-credentials` (mode 600); URIs in each env
file. For a shell: source the credentials file, then
`docker exec -it fais-mongo mongosh -u faisRoot -p "$FAIS_ROOT_PW" --authenticationDatabase admin`.
Plan and rollback: `FAIS/docs/operations/MONGODB_AUTH_PLAN.md`. The old `fais` database is kept until
about 2026-10-27, then dropped.

**Firm deployments moved off this box (2026-10-23).** They run on the client-data server
(below). Since then this box's `fais-mongo` and `fais-minio` hold only demo data (`fais_demo`,
`fais_demo_snapshot`, the old `fais`, bucket `fais-documents`), and `deploy.sh demo` starts only
`mongo`, `minio` and `app`. The firm's container, database, logins, bucket, MinIO user and
credentials were deleted here after the move. `/opt/fais/firms/alphatronex/.env.production` is an
empty stub until the FAIS PR that drops `app-alphatronex` from `docker-compose.prod.yml` is merged;
delete it then. `mongo` is pinned to `mongo:8.2.11` by digest (see the client-data server's notes).

**Document encryption (2026-10-21):** `fais-minio` encrypts every object at rest (SSE-S3, AES-256)
with a static KMS key, `MINIO_KMS_SECRET_KEY=fais-documents-key:<base64>` in
`/opt/fais/minio/.env.production` (mode 600). Every bucket has default encryption (`mc encrypt set
sse-s3`), so the app needs no changes; a new firm bucket needs the same command. **Without this key no document can be read**, including documents restored from backup: it's in the nightly backup (in `minio.env.production`), and must also be kept in Vaultwarden and off this server. This key and the root password leaked into a session transcript on 2026-10-22, so they now protect only the demo's fictional documents; firm documents are under the client-data server's own key. Check with
`mc admin kms key status <alias>` and `mc encrypt info <alias>/<bucket>` inside `fais-minio`. Don't
rotate it by editing the env file: objects encrypted under the old key would become unreadable.

**Backups (2026-10-20; both servers since 2026-10-23):** on each FAIS server, `fais-backup.timer` runs `/opt/fais-backup/fais-backup.sh` (source:
[backups/fais-backup.sh](./backups/fais-backup.sh)) nightly at 07:30 UTC, after the demo reset. It
dumps the whole MongoDB server as `faisBackup` (all FAIS databases plus logins and roles), mirrors
every MinIO bucket, copies the env and credential files, and uploads them to an encrypted restic
repository `b2:faisdocs-backups:fais` (Backblaze B2, key limited to that bucket). It keeps 30 daily and 6 monthly snapshots. Any failure sends a Telegram alert through @alphatronexbot.
Both servers share the repository, with their own restic host tag (`fais` here, `fais-clients` on
the client-data server, set by [systemd/fais-backup.service.d/fais-clients.conf](./systemd/fais-backup.service.d/fais-clients.conf));
each one's `forget --prune` only touches its own host's snapshots. Alpha Tronex's data is in the `fais-clients` snapshots from `87174954` (2026-10-23 16:48 UTC) on;
the last copy taken on this box is `7d3f4fb7` (2026-10-22), expiring on the normal schedule. Running
the job twice in a day keeps only the later snapshot for that day.
- Server files (mode 600): `~/.fais-backup-b2.env`, `~/.fais-backup-alert.env`,
  `~/.fais-backup-restic-password`. **Keep a copy of the restic password off this server**
  (Vaultwarden runs here too); without it the backups can't be restored.
- Logs: `journalctl -u fais-backup`. Run now: `sudo systemctl start fais-backup.service`.
- Restore (restore-tested 2026-10-20):
  ```bash
  set -a; . ~/.fais-backup-b2.env; set +a
  export RESTIC_REPOSITORY="b2:${B2_BUCKET}:fais" RESTIC_PASSWORD_FILE=~/.fais-backup-restic-password
    restic snapshots --host fais          # or --host fais-clients for firm data
  restic restore latest --host fais --target /var/tmp/fais-restore     # files land under var/tmp/fais-backup/
  # On fais-clients restore under /srv/fais-data (the encrypted volume), not /var/tmp.
  # One database:  mongorestore --archive=.../mongo/fais-mongo.archive.gz --gzip --nsInclude='fais_demo.*'
  # Documents:     mc mirror .../minio/<bucket> <alias>/<bucket>   (inside fais-minio)
  ```

---

## Client-data server (fais-clients)

Added 2026-10-23 so client data no longer sits next to the public demo and unrelated apps. Runs **only**
FAIS firm deployments with their own MongoDB and MinIO. Plan and cutover log:
`FAIS/docs/operations/CLIENT_DATA_SERVER_PLAN.md`.

| Spec | Value |
|------|-------|
| Name | `fais-clients` (Hetzner #172080698), SSH alias `fais-clients` |
| IP | 178.156.222.192, IPv6 2a01:4ff:f0:bd1b::/64 |
| Plan | CPX11: 2 vCPU · 2 GB RAM · 40 GB disk · 1 TB traffic, Ashburn, Ubuntu 26.04 |
| Volume | 20 GB Hetzner Volume (`scsi-0HC_Volume_107253450`), LUKS2, mounted at `/srv/fais-data` |
| Cost | €20.49/month (console, server + volume + IPv4) |
| Firewall | Hetzner Cloud Firewall `fais-clients` + `ufw`: 22, 80, 443 only. SSH by key, no root login |
| First boot | [client-data/cloud-init.yml](./client-data/cloud-init.yml) |

2 GB holds mongo (450m), minio (384m) and one firm (768m) with 2 GB swap. **Rescale to CPX21
(4 GB) before a second firm.**

```
alphatronex.faislaw.com
        │   nginx + Certbot (issued 2026-10-23, renews here)
        ▼
  :8011 (Docker, 127.0.0.1 only)
┌────────────────────┐      ┌────────────────────┐   ┌────────────────────┐
│  fais-alphatronex   │◄────►│    fais-mongo      │   │    fais-minio      │
│  same image as the  │      │ mongo:8.2.11       │   │ SSE-S3, own KMS key│
│  demo, demo mode off│◄────►│ --auth             │   │ bucket per firm    │
└────────────────────┘      └────────────────────┘   └────────────────────┘
                     all of Docker's data: /srv/fais-data/docker (LUKS)
```

**Encryption at rest.** `/etc/crypttab` unlocks the volume at boot with `/etc/luks/fais-data.key`
(root, mode 400, on the unencrypted OS disk), then `/etc/fstab` mounts it. Docker's `data-root` is
`/srv/fais-data/docker` (`/etc/docker/daemon.json`), and a drop-in
(`/etc/systemd/system/docker.service.d/fais-data.conf`, `RequiresMountsFor=/srv/fais-data`) keeps
Docker from starting before the mount. The 2 GB swap file is on the volume too. Reboot tested
2026-10-23. This protects copies of the volume (snapshots, retired drives, a volume attached
elsewhere), not root on the running server. Check: `sudo cryptsetup status fais-data`, `findmnt /srv/fais-data`.

**Keys and where they are kept.** All generated on this server on 2026-10-23, none printed. **Copy
each into Vaultwarden and an offline copy** (a printed sheet or an encrypted USB key); Vaultwarden
runs on the shared box, so it alone isn't enough.

| Secret | On the server (mode 600) | Without it |
|---|---|---|
| LUKS key file | `/etc/luks/fais-data.key` (64 random bytes) | Volume can't unlock at boot (use the passphrase) |
| LUKS recovery passphrase (key slot 1) | `~/.fais-luks-recovery-passphrase` | Volume unreadable if the key file is lost |
| LUKS header backup | `/root/fais-data-luks-header.img` | Volume unreadable if its header is damaged |
| MinIO root user, password and KMS key `fais-clients-documents-key` | `/opt/fais/minio/.env.production` | **No document can be read**, restored ones included |
| Mongo `faisRoot`, `faisBackup` | `~/.fais-mongo-credentials` | Admin access, backups |
| Firm logins and MinIO user | `~/.fais-firm-<firm>-credentials`, `/opt/fais/firms/<firm>/.env.production` | Firm app (also holds the firm's `SSN_ENCRYPTION_KEY_B64`) |
| restic password (shared with the shared box) | `~/.fais-backup-restic-password` | No backup can be restored |

The MinIO, Mongo and firm files and the restic password are also inside each nightly backup; the
LUKS secrets aren't (the backup holds the data itself). To copy them to Vaultwarden, view them in
your own terminal (`ssh fais-clients sudo cat /etc/luks/fais-data.key | base64`, `ssh fais-clients
cat ~/.fais-luks-recovery-passphrase`), not in a Claude session.

**Images.** `mongo` is pinned to `mongo:8.2.11@sha256:951c2ff9…`: `mongo:8` images from October
2026 refuse to start on kernels 6.19 and newer (SERVER-121912), including Ubuntu 26.04's 7.0 kernel,
where 8.2.11 runs fine. MinIO's community image can no longer be pulled (Docker Hub and quay.io), so
`minio/minio:RELEASE.2025-09-07T16-13-09Z` was copied from the shared box with `docker save`; a copy
is at `/srv/fais-data/images/`. Replace MinIO before more firms (FAIS readiness plan).

**Deploys.** `/opt/fais` is a clone of FAIS with its own read-only GitHub deploy key. CI's
`DEPLOY_CLIENTS_SSH_KEY` is forced to `/opt/fais/deploy.sh clients` (`docker-compose.clients.yml`,
health check on every firm port). `docker-buildx` is installed for the build secret. Details:
`FAIS/deploy/README.md`.

**Backups.** Same script, units and B2 repository as the shared box, host tag `fais-clients`, nightly
at 07:30 UTC. Restore-tested 2026-10-23 (412 documents and 18 files matched live).

**Services**

| Service | Runtime | Internal port | Public URL |
|---------|---------|--------------|------------|
| fais-alphatronex | Docker | 8011 | https://alphatronex.faislaw.com (Alpha Tronex, fictional test firm). The old `alphatronex.fais.alphatronex.com` is a 301 on the shared box, where its DNS record points |
| fais-fiori | Docker | 8012 | https://fiori.faislaw.com (Law Office of Christophe Fiori, PLLC; onboarded 2026-10-23). Vhost [nginx/fiori.faislaw.com.conf](./nginx/fiori.faislaw.com.conf) |
| fais-mongo | Docker | 27017 | internal only (compose network) |
| fais-minio | Docker | 9000 | internal only (compose network) |

---

## Quiz Master

Migrating from Render (2026-09). Source + Dockerfile/docker-compose.prod.yml
live in the `quizzes` repo; this repo only has the nginx vhost. See
[nginx/quizmaster.alphatronex.com.conf](./nginx/quizmaster.alphatronex.com.conf).

**CD (2026-09-29):** `quizzes/.github/workflows/ci.yml` deploys automatically
on every push to `main` that passes checks (lint, typecheck, Angular/Karma
tests, backend Jest tests). Deploy step SSHes in with a restricted,
forced-command key (`command="/opt/quizmaster/deploy.sh",restrict` in
`alphathiam`'s `authorized_keys`) that can only run
`/opt/quizmaster/deploy.sh` (git pull + `docker compose up -d --build` +
local health check against `/privacy`), then the GitHub runner smoke-tests
the public URL too. Secrets: `DEPLOY_SSH_KEY`, `DEPLOY_HOST_KEY` on the
`quizzes` repo. Failure mode: checks or deploy failing leaves production on
the previous version — nothing is torn down mid-deploy. Rollback: `ssh
hetzner`, `cd /opt/quizmaster/quizzes`, `git reset --hard <previous-sha>`,
re-run `/opt/quizmaster/deploy.sh` by hand.

```
quizmaster.alphatronex.com
        │
        ▼
  :8020 (Docker, 127.0.0.1 only)
┌─────────────────────┐      ┌─────────────────────┐
│    quizmaster-app    │◄────►│   quizmaster-mongo   │
│  Node/Express +      │      │  mongo:8             │
│  Angular (built,     │      │  --wiredTigerCache   │
│  served as static)   │      │    SizeGB 0.25       │
│  mem_limit: 256m     │      │  not internet-facing │
└─────────────────────┘      │  mem_limit: 400m     │
                              └─────────────────────┘
```

**RAM note:** written back when this box ran on the original 2GB plan —
fais-app + fais-mongo alone used ~1.2GB (see the FAIS section above), and
quizmaster-app + quizmaster-mongo (~656MB combined mem_limit) pushed total
committed memory close to the ceiling. The box has since been rescaled to
4GB / 3 vCPU (see Server plan above), so there's meaningfully more headroom
now. Still worth checking `free -h` and `docker stats --no-stream` after any
significant change (new containers, a load/stress test) rather than assuming
it's fine — the mem_limit values above haven't been revisited since the
rescale.

---

## TTS Service (Wolof and Bambara voices)

Added 2026-10-03 for the Language Translator app. OpenAI's voices don't cover
Wolof or Bambara, so the translator API (Next.js on **Vercel**) sends the
translated text here and gets an MP3 back. Phones never call this service
directly. Source + Dockerfile/docker-compose.prod.yml live in the
`tts-service` repo (`alpha-tronex/tts-service`, local folder `TTS Service`);
this repo only has the nginx vhost. See
[nginx/tts.alphatronex.com.conf](./nginx/tts.alphatronex.com.conf).

```
Language Translator API (Vercel)
        │  POST /speak  {lang, text}   header X-TTS-Key
        ▼
tts.alphatronex.com
        │   nginx: only /speak (rate-limited 5 r/s) and /health; everything else 404
        ▼
  :8300 (Docker, 127.0.0.1 only)
┌──────────────────────────────┐
│         tts-service           │
│ Python 3.11 / FastAPI /       │
│ uvicorn (1 worker), CPU torch │
│ wo: SpeechT5 (MIT)            │
│ bm: Meta MMS VITS (CC-BY-NC)  │
│ mem_limit: 1500m              │
└──────────────────────────────┘
```

- **Code on the server:** `/opt/tts-service/tts-service`.
- **Secret:** `.env.production` there (mode 600, never committed) holds
  `TTS_SHARED_SECRET`. The same value is `TTS_SERVICE_KEY` in the Vercel
  project for the translator API, next to `TTS_SERVICE_URL`. Changing one
  means changing the other and redeploying the API.
- **Models:** downloaded from Hugging Face on the first start into the
  `tts-models` Docker volume (about 1 GB); later starts need no network.
- **Deploy:** manual, per `DEPLOY.md` in the `tts-service` repo
  (`git pull`, `docker compose -f docker-compose.prod.yml build`, `up -d`).
  The repo's GitHub Actions workflow only runs tests; there is no CD yet.
- **Health:** `curl -s https://tts.alphatronex.com/health` →
  `{"status":"ok","languages":["bm","wo"]}`. `docker logs tts-service` shows
  one JSON line per request (language, characters, ms, cached), never the text.
- **If it is down:** the translator still returns the translation and the app
  shows "Audio temporarily unavailable"; only Wolof and Bambara audio is lost.
- **Licence:** the Bambara model is non-commercial. Fine while the app is free
  with no ads; replace it before the app ever charges.

**RAM note (2026-10-03):** before this service was added the box had 1.9 GB
available with 736 MB of swap already in use, so the cap was set at 1500m
instead of the 2 GB first planned. This is the largest single consumer on the
box. If `free -h` shows available memory under ~300 MB or swap climbing well
past 1 GB, rescale to the 8 GB plan rather than squeezing the other caps.

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

The workflow's `DEPLOY_SSH_KEY` (`github-actions-deploy` in
`authorized_keys`) is **restricted to that one rsync push** (2026-10-13).
Before that it gave a full shell. The key's forced command is
[`ssh/rsync-push-only.sh`](./ssh/rsync-push-only.sh), installed at
`/home/alphathiam/bin/rsync-push-only.sh`:

```
command="/home/alphathiam/bin/rsync-push-only.sh /var/www/realdosing/",restrict ssh-ed25519 AAAA… github-actions-deploy
```

It allows only `rsync --server -<flags> --delete . /var/www/realdosing/` (the
server side of the workflow's `rsync -a --delete`). Shells, other paths, pulls
and anything with shell metacharacters are rejected and logged:
`sudo journalctl -t rsync-push-only`. It's a custom wrapper rather than the
stock `rrsync` because `rrsync` treats the workflow's absolute destination as
relative to its root, which would break the deploy. **If you change the
workflow's rsync flags or destination**, update the forced command to match.
After editing the wrapper here, re-install it with
`scp ssh/rsync-push-only.sh hetzner:bin/ && ssh hetzner chmod 700 bin/rsync-push-only.sh`.

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

## Dashboard (apps overview)

Added 2026-10-20. `dashboard.alphatronex.com` is one static page listing the
apps on this box and elsewhere (host, port, address, CI/CD state). Same
non-Docker pattern as the root splash page: served directly by nginx from
`/var/www/dashboard`, source in [dashboard/](./dashboard/) in this repo. The
app list is hard-coded in `dashboard/index.html`: a snapshot of the notes in
this file and the CI/CD status tables, **not** a live health check, so edit it
when an app or its pipeline status changes, then redeploy.

The page names internal hostnames and ports, so the vhost sits behind HTTP
basic auth (`/etc/nginx/.htpasswd-dashboard`, created with `htpasswd`; the
password is not in this repo) and sends `X-Robots-Tag: noindex`. See
[nginx/dashboard.alphatronex.com.conf](./nginx/dashboard.alphatronex.com.conf).

Deploy:

```
rsync -a --delete --chmod=D755,F644 dashboard/ hetzner:/var/www/dashboard/
```

First-time setup (DNS A record `dashboard` → 5.161.104.5 at the provider
hosting `alphatronex.com`, the directory, the password file, the vhost and
Certbot) is listed in the vhost file's header comment. Certbot cert expiry:
add once issued.

---

## Personal assistant — CD (added 2026-10-07)

Until 2026-10 `/opt/assistant` was a hand-copied `backend/` folder and the
container a bare `docker run`. It is now deployed from git:
`Personal-Assistant/.github/workflows/ci.yml` runs ruff, pytest, a
testability audit and shellcheck on every push, and on `main` SSHes in with a
forced-command key (`command="/opt/assistant/deploy.sh",restrict` in
`alphathiam`'s `authorized_keys`). `deploy.sh` does `git reset --hard
origin/main` in `/opt/assistant/repo`, then `docker compose -f
backend/docker-compose.prod.yml` build + `up -d`, and waits until `/healthz`
reports the new short SHA. The runner then checks the same thing on the
public URL. Secret: `DEPLOY_SSH_KEY` (raw PEM) on the repo.

**Auth (2026-10-07):** the app requires a login for everything except
`/healthz` (uptime-kuma + CI), `/reauth*` (Google OAuth) and `/whatsapp/*`.
nginx blocks `/whatsapp/*` publicly ([nginx/assistant.alphatronex.com](./nginx/assistant.alphatronex.com));
the bridge reaches it on 127.0.0.1:8000. Login settings are in `/opt/assistant/.env`.

**Public demo (2026-10-07):** `personal-assistant-demo` (same image,
`DEMO_MODE=true`, 127.0.0.1:8001, `mem_limit: 384m`) serves
https://demo.alphatronex.com from sample data. It has no `.env`, no volume
and no login, and its nginx site rate-limits per IP
([nginx/demo.alphatronex.com](./nginx/demo.alphatronex.com)). Deployed and
smoke-tested alongside the app.

State stays outside the checkout and is mounted in: `/opt/assistant/.env`,
`config/`, `data/`. The old top-level copies of `app/`, `Dockerfile` etc. in
`/opt/assistant/` are now unused. The container has `mem_limit: 768m`
(steady state ~190 MiB). The WhatsApp bridge and its systemd units are **not**
deployed by this pipeline. Setup, rollback and schema-change notes:
`Personal-Assistant/backend/deploy/README.md`.

---

## WhatsApp bridge — residential proxy (added 2026-08-04)

WhatsApp started hard-rejecting connections from this box's IP (`Connection
closed. Code: 405` on every attempt, including a completely fresh,
unauthenticated session — confirmed via a side-by-side test that the same
code connects cleanly from a residential IP). Root cause: WhatsApp blocking
the Hetzner datacenter IP range, not a session/auth problem.

Fix: the bridge (source in the Personal Assistant repo's `whatsapp_service/`)
now routes its WebSocket through a static-session residential proxy
(IPRoyal) via a `PROXY_URL` env var wired into Baileys' socket `agent`
option. Set on the host via `pm2 start ... ` (not a `.env` file — matches
this app's existing all-env-vars pattern) and persisted with `pm2 save`
into `/home/alphathiam/.pm2/dump.pm2`.

**The bridge runs under alphathiam's pm2, not root's.** `pm2-alphathiam.service`
resurrects it at boot. Never run `sudo pm2 ...` for the bridge: root has its
own pm2 home (`/root/.pm2`), so that starts a second, root-owned bridge.
That happened Sep–Oct 2026. The renewal script restarted a root copy that
couldn't take :3000, its health check hit the real (unproxied) bridge and
reported success, and root-owned files in `auth/` caused thousands of
`EACCES ... creds.json` errors plus constant 500/428 disconnects. Quick
check: `pm2 env 0 | grep -c PROXY_URL` (as alphathiam) should print 1, and
`sudo find /opt/whatsapp-bridge/auth ! -user alphathiam | wc -l` should print 0.

**Maintenance — the sticky proxy session expires every 7 days**
(`_lifetime-7d`, IPRoyal's max). This is now automated: a systemd timer
(`whatsapp-proxy-renew.timer`, fires every 6 days — one day inside the
7-day cap) generates a fresh session, sanity-checks the new exit IP is
US, and only then swaps it into the live pm2 process; if the new session
fails its checks it leaves the running bridge untouched. After the restart
it verifies the new pid owns :3000, carries the new session in its env and
holds a connection to the proxy before reporting success. Success/failure
alerts go to the same Telegram bot personal-assistant already uses for
daily briefs. Source (script + unit files) lives in the Personal
Assistant repo's `whatsapp_service/systemd/`; the real credentials file
(`proxy-renew.env`, template in that same dir) exists only on the server
at `/opt/whatsapp-bridge/proxy-renew.env`, mode 600, never committed. If
alerts stop arriving or `pm2 logs whatsapp-bridge` shows a resumed
`Code: 405`/reconnect loop, check `sudo systemctl status
whatsapp-proxy-renew.timer` and `/var/log/whatsapp-proxy-renew.log` first.

**Outage handling (2026-10-08).** The sticky session's residential exit IP
can rotate mid-session. That drops the WhatsApp WebSocket, and once a
reconnect hung for about 11.5 h with pm2 still showing "online". The bridge
now handles this itself (`whatsapp_service/lib/outage.js`):

- A reconnect that isn't open within 90 s exits, and pm2 restarts it.
- An outage longer than 10 min sends a Telegram alert through
  `POST /whatsapp/disconnected-alert` (at most hourly), plus a "reconnected"
  notice afterwards.
- The outage clock is kept in `/tmp/whatsapp-bridge/`, so it survives those
  restarts.

`/healthz` returns 200 even when disconnected, so any monitor must check for
`"connected":true` in the body.

**Deploying bridge code** (not covered by CI/CD):

```bash
scp index.js hetzner:/opt/whatsapp-bridge/
scp -r lib hetzner:/opt/whatsapp-bridge/
ssh hetzner pm2 restart whatsapp-bridge
```

Run the `scp` lines from `whatsapp_service/`. Restart as alphathiam, never
with sudo.

Bandwidth is tracked by `whatsapp-nethogs.service` (`nethogs -t -d 60`,
bridge lines only, logging to `/var/log/nethogs-wa.log`) to size actual
proxy cost — IPRoyal's rotating-pool product is billed per-GB ($1.75/GB).
The first 3.8-day sample (Aug 2026) came to ~0.05 GB/month (~$0.09/month).
`whatsapp-bandwidth-report.timer` sends a one-off Telegram report 7 days
after it's enabled.

---

## Services

| Service | Runtime | Internal port | Public URL |
|---------|---------|--------------|------------|
| personal-assistant | Docker | 8000 | https://assistant.alphatronex.com |
| personal-assistant-demo | Docker | 8001 | https://demo.alphatronex.com (public demo, sample data) |
| uptime-kuma | Docker | 3001 | https://status.alphatronex.com |
| vaultwarden | Docker | 8200 | https://vault.alphatronex.com |
| whatsapp-bridge | Node.js (host) | 3000 | internal only (172.17.0.1:3000) |
| fais-app | Docker | 8010 | https://demo.faislaw.com (public demo; firms are on fais-clients). `faislaw.com` 302s here; `fais.alphatronex.com` and `alphatronex.fais.alphatronex.com` are 301 redirects |
| fais-dev | Docker | 8030 | https://dev.faislaw.com (FAIS dev box: debug build, synthetic data, basic auth except `/api/health`; deployed from the `dev` branch out of `/opt/fais-dev`) |
| fais-mongo | Docker | 27017 | internal only (compose network) |
| fais-minio | Docker | 9000 | internal only (compose network) |
| realdosing (static) | nginx (no container) | — | https://dosinghub.com |
| dashboard (static) | nginx (no container) | — | https://dashboard.alphatronex.com (basic auth) |
| quizmaster-app | Docker | 8020 | https://quizmaster.alphatronex.com |
| quizmaster-mongo | Docker | 27017 | internal only (compose network) |
| tts-service | Docker | 8300 | https://tts.alphatronex.com (only `/speak` and `/health`) |

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

TTS Service:

```
Docker volume: tts-models  →  /models (tts-service container; Hugging Face model cache, ~1 GB)
.env.production               — secret (TTS_SHARED_SECRET); git-ignored, not in this repo
```

Quiz Master:

```
Docker volume: quizmaster_mongo_data  →  /data/db (quizmaster-mongo container)
server/.env.production                  — secrets (JWT_SECRET); git-ignored, not in this repo
```

---

## Outbound traffic

| Destination | Purpose |
|-------------|---------|
| `googleapis.com` | Calendar, Gmail, YouTube Data, OAuth refresh |
| `api.telegram.org` | Delivery + long-poll for WA approvals |
| `api.openai.com` | Gmail summary, YouTube TL;DRs, WA reply suggestions (personal-assistant); AI reports (FAIS, optional) |
| `172.17.0.1:3000` | WhatsApp bridge (Docker → host, local only) |
| `geo.iproyal.com:12321` | WhatsApp bridge → residential proxy → WhatsApp (see note above; datacenter IP is blocked by WA directly) |
| `s3.*.backblazeb2.com` | FAIS document storage (optional, if B2_* configured) |
| `textract.*.amazonaws.com` | FAIS document OCR via Textract (optional, if DOCUMENT_INTAKE_TEXTRACT enabled) |
| SMTP host (configurable) | FAIS invite + password-reset email (optional) |
| `huggingface.co` | tts-service model download, first start only (cached in the `tts-models` volume afterwards) |
