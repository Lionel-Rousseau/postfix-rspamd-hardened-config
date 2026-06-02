#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sync-relay-recipients.sh
#
# Generates /etc/postfix/relay_recipients from the primary mailbox tree,
# compiles it, and pushes it to the secondary MX.
#
# Mailbox structure expected: /home/vmail/<domain>/<user>/
# Aliases are excluded — only real mailbox directories are enumerated.
#
# Usage:
#   sync-relay-recipients.sh [--dry-run]
#
# Cron example (daily sync):
#   0 4 * * * /usr/local/sbin/sync-relay-recipients.sh --quiet
# =============================================================================

VMAIL_BASE="${VMAIL_BASE:-/home/vmail}"
RELAY_RECIPIENTS_FILE="${RELAY_RECIPIENTS_FILE:-/etc/postfix/relay_recipients}"
SECONDARY_HOST="${SECONDARY_HOST:-mx-secondary.example.org}"
SECONDARY_USER="${SECONDARY_USER:-root}"
SECONDARY_PORT="${SECONDARY_PORT:-1622}"
SECONDARY_DEST="${SECONDARY_DEST:-/etc/postfix}"

DRY_RUN=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --quiet)   QUIET=1 ;;
  esac
done

log() { [[ $QUIET -eq 0 ]] && echo "[INFO] $*" || true; }

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run as root" >&2
  exit 1
fi

if [[ ! -d "$VMAIL_BASE" ]]; then
  echo "[ERROR] Mailbox base not found: $VMAIL_BASE" >&2
  exit 1
fi

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

log "Enumerating mailboxes under $VMAIL_BASE"

find "$VMAIL_BASE" -mindepth 2 -maxdepth 2 -type d \
  | sort \
  | while IFS= read -r maildir; do
      user="$(basename "$maildir")"
      domain="$(basename "$(dirname "$maildir")")"
      printf '%s@%s\tOK\n' "$user" "$domain"
    done > "$TMP_FILE"

COUNT="$(wc -l < "$TMP_FILE")"

if [[ "$COUNT" -eq 0 ]]; then
  echo "[ERROR] No mailboxes found under $VMAIL_BASE" >&2
  exit 1
fi

log "$COUNT recipients found"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY-RUN] Would write $COUNT entries to $RELAY_RECIPIENTS_FILE"
  cat "$TMP_FILE"
  exit 0
fi

cp "$TMP_FILE" "$RELAY_RECIPIENTS_FILE"
chmod 640 "$RELAY_RECIPIENTS_FILE"
/usr/sbin/postmap "$RELAY_RECIPIENTS_FILE"
log "relay_recipients compiled ($RELAY_RECIPIENTS_FILE.db)"

SSH_OPTS=(-p "$SECONDARY_PORT" -q -T -o LogLevel=ERROR)
SCP_OPTS=(-P "$SECONDARY_PORT" -q    -o LogLevel=ERROR)

log "Pushing to ${SECONDARY_USER}@${SECONDARY_HOST}:${SECONDARY_DEST}/ (port ${SECONDARY_PORT})"
scp "${SCP_OPTS[@]}" \
  "$RELAY_RECIPIENTS_FILE" \
  "${RELAY_RECIPIENTS_FILE}.db" \
  "${SECONDARY_USER}@${SECONDARY_HOST}:${SECONDARY_DEST}/"

log "Reloading Postfix on $SECONDARY_HOST"
ssh "${SSH_OPTS[@]}" "${SECONDARY_USER}@${SECONDARY_HOST}" "postfix reload"

log "Sync complete — $COUNT recipients pushed to $SECONDARY_HOST"
