#!/usr/bin/env bash
# Forced command for GitHub Actions rsync deploy keys (authorized_keys):
#   command="/home/alphathiam/bin/rsync-push-only.sh /var/www/realdosing/",restrict ssh-ed25519 ...
# Allows only `rsync -a --delete <dir>/ host:<dest>` pushing into exactly <dest>.
# Anything else (a shell, another path, a pull) is rejected and logged.
set -euo pipefail
dest="${1:?usage: rsync-push-only.sh <dest-dir/>}"
cmd="${SSH_ORIGINAL_COMMAND:-}"
re='^rsync --server -[A-Za-z.]+ --delete \. ([^ ]+)$'
if [[ "$cmd" =~ $re ]] && [ "${BASH_REMATCH[1]}" = "$dest" ]; then
  # Word splitting is intended; the regex admits no shell metacharacters.
  # shellcheck disable=SC2086
  exec $cmd
fi
logger -t rsync-push-only "rejected for ${dest}: ${cmd}"
echo "rejected: this key may only rsync into ${dest}" >&2
exit 1
