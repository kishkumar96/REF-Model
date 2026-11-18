#!/usr/bin/env bash
# upload_watch.sh - upload finished run folders in outputs/ to the Pacific Disaster API. No RiskScape.
#
#   ./upload_watch.sh              upload every run folder the server does not have yet
#   ./upload_watch.sh --dry-run    show what would be uploaded, change nothing
#
# A folder is uploaded once it holds regional-summary.csv (i.e. it finished downloading).
# push_runs.py skips runs the server already has, so it is safe to run this over and over.
#
# .env needs: PARTNER_USERNAME and PARTNER_PASSWORD (a fresh token is fetched on every check),
# or PARTNER_API_TOKEN (valid for 2 days only). Put a password with ' or & in double quotes.
#
# Schedule it (every 15 minutes):  crontab -e  and add
#   */15 * * * * /path/to/REF-Model/upload_watch.sh >> /path/to/REF-Model/upload.log 2>&1

set -u
cd "$(dirname "$0")"
exec 9>.upload.lock
flock -n 9 || { echo "$(date -u +%FT%TZ) another upload is still running, skipping"; exit 0; }
log() { echo "$(date -u +%FT%TZ) $*"; }

[ -f .env ] || { log "ERROR: .env is missing in $(pwd)"; exit 1; }
set -a; . ./.env; set +a
BASE=https://pacific-disaster-api.spc.int/partner_api
OUTPUT_DIR="${OUTPUT_DIR:-outputs}"
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

if [ -n "${PARTNER_USERNAME:-}" ] && [ -n "${PARTNER_PASSWORD:-}" ]; then
  TOKEN=$(curl -s -m 30 -X POST "$BASE/api-token-auth/" \
    --data-urlencode "username=$PARTNER_USERNAME" --data-urlencode "password=$PARTNER_PASSWORD" \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null)
  [ -n "$TOKEN" ] || { log "ERROR: login to the Pacific Disaster API failed (check PARTNER_USERNAME / PARTNER_PASSWORD)"; exit 1; }
else
  TOKEN="${PARTNER_API_TOKEN:-}"
  [ -n "$TOKEN" ] || { log "ERROR: .env needs PARTNER_USERNAME + PARTNER_PASSWORD, or PARTNER_API_TOKEN"; exit 1; }
fi

DIRS=""
for d in "$OUTPUT_DIR"/*/; do
  d="${d%/}"; [ -f "$d/regional-summary.csv" ] && DIRS="$DIRS $d"
done
[ -n "$DIRS" ] || { log "no finished run folders in $OUTPUT_DIR"; exit 0; }

# shellcheck disable=SC2086
PARTNER_API_TOKEN="$TOKEN" python3 -I push_runs.py $DRY $DIRS
