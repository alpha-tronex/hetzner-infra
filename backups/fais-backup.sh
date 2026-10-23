#!/usr/bin/env bash
# FAIS nightly backup: every FAIS MongoDB database, every MinIO document bucket, and the env and
# credential files, into an encrypted restic repository on Backblaze B2.
#
# Installed at /opt/fais-backup/fais-backup.sh on both FAIS servers: the shared box (the demo,
# restic host tag `fais`) and the client-data server fais-clients (firms, host tag `fais-clients`,
# set by systemd/fais-backup.service.d/fais-clients.conf). Run as alphathiam (docker group) by
# fais-backup.service, fired nightly by fais-backup.timer. Source lives in hetzner-infra/backups/.
# Both servers share one restic repository; each only forgets and prunes its own host's snapshots.
#
# Files it reads on the server (all mode 600, never committed):
#   ~/.fais-backup-b2.env           B2_ACCOUNT_ID, B2_ACCOUNT_KEY, B2_BUCKET (key limited to that bucket)
#   ~/.fais-backup-restic-password  restic repository password. Keep a copy OFF this server:
#                                   without it the backups cannot be restored.
#   ~/.fais-backup-alert.env        TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID for failure alerts
#   ~/.fais-mongo-credentials       FAIS_BACKUP_PW (faisBackup login, MongoDB `backup` role)
#
# Restore: see the "Backups" section of hetzner.md.
set -euo pipefail

STAGE=/var/tmp/fais-backup
LOG_TAG=fais-backup
RESTIC_HOST="${FAIS_BACKUP_HOST:-fais}"

alert() {
  # Best effort: a failed alert must not hide the original error.
  if [ -f "$HOME/.fais-backup-alert.env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.fais-backup-alert.env"
    curl -fsS -m 20 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=$1" >/dev/null || true
  fi
}

on_error() {
  local line=$1
  logger -t "$LOG_TAG" "FAILED at line ${line}"
  alert "FAIS nightly backup FAILED on $(hostname) at line ${line}. Check: journalctl -u fais-backup --since today"
  rm -rf "$STAGE"
  docker exec fais-minio rm -rf /tmp/fais-backup-minio >/dev/null 2>&1 || true
}
trap 'on_error $LINENO' ERR

# shellcheck disable=SC1091
. "$HOME/.fais-backup-b2.env"
# shellcheck disable=SC1091
. "$HOME/.fais-mongo-credentials"
export B2_ACCOUNT_ID B2_ACCOUNT_KEY
export RESTIC_REPOSITORY="b2:${B2_BUCKET}:fais"
export RESTIC_PASSWORD_FILE="$HOME/.fais-backup-restic-password"

rm -rf "$STAGE"
mkdir -p "$STAGE/mongo" "$STAGE/minio" "$STAGE/config"
chmod 700 "$STAGE"

# --- MongoDB: the whole server in one gzip archive, dumped as faisBackup -----------------------
# Includes every FAIS database plus admin (logins and roles), so a full restore needs nothing else.
# Restore one database with: mongorestore --archive=... --gzip --nsInclude='fais_<name>.*'
# The password goes in a config file inside the container, so it never appears in `ps`.
docker exec -i fais-mongo sh -c 'umask 077; cat > /tmp/fais-backup-mongo.yaml' <<EOF
password: ${FAIS_BACKUP_PW}
EOF
docker exec fais-mongo mongodump --quiet --username faisBackup --authenticationDatabase admin \
  --config /tmp/fais-backup-mongo.yaml --archive --gzip > "$STAGE/mongo/fais-mongo.archive.gz"
docker exec fais-mongo rm -f /tmp/fais-backup-mongo.yaml

# --- MinIO: mirror every bucket out of the container -------------------------------------------
# The minio image has no sed/grep, so the bucket list is parsed here on the host.
minio() { docker exec fais-minio sh -c "mc alias set fbk http://127.0.0.1:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null && $1"; }
buckets=$(minio 'mc ls --json fbk' | python3 -c 'import sys,json; print(" ".join(json.loads(l)["key"].rstrip("/") for l in sys.stdin if l.strip()))')
if [ -z "$buckets" ]; then echo "no MinIO buckets found" >&2; false; fi
minio 'rm -rf /tmp/fais-backup-minio && mkdir -p /tmp/fais-backup-minio'
for b in $buckets; do
  minio "mc mirror --quiet --overwrite fbk/$b /tmp/fais-backup-minio/$b >/dev/null"
done
minio 'mc alias rm fbk >/dev/null'
docker cp fais-minio:/tmp/fais-backup-minio/. "$STAGE/minio/"
docker exec fais-minio rm -rf /tmp/fais-backup-minio

# --- Env and credential files (the restic repository is encrypted) -----------------------------
# The demo's env file exists only on the shared box.
if [ -f /opt/fais/server/.env.production ]; then
  cp -p /opt/fais/server/.env.production "$STAGE/config/server.env.production"
fi
cp -p /opt/fais/minio/.env.production "$STAGE/config/minio.env.production"
for f in /opt/fais/firms/*/.env.production; do
  [ -f "$f" ] && cp -p "$f" "$STAGE/config/firm-$(basename "$(dirname "$f")").env.production"
done
cp -p "$HOME"/.fais-mongo-credentials "$HOME"/.fais-firm-*-credentials "$STAGE/config/" 2>/dev/null || true

# --- Upload, then apply retention ---------------------------------------------------------------
restic backup --quiet --host "$RESTIC_HOST" --tag nightly "$STAGE"
restic forget --quiet --host "$RESTIC_HOST" --tag nightly --keep-daily 30 --keep-monthly 6 --prune

summary="mongo: $(du -h "$STAGE/mongo/fais-mongo.archive.gz" | cut -f1); buckets: ${buckets} ($(find "$STAGE/minio" -type f | wc -l) files); size: $(du -sh "$STAGE" | cut -f1)"
rm -rf "$STAGE"
logger -t "$LOG_TAG" "ok (${summary})"
echo "FAIS backup ok (${summary})"
