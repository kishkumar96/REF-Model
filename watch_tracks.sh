#!/usr/bin/env bash
# watch_tracks.sh - run REF for any new cyclone track, then push the run to the Pacific Disaster API.
#
#   ./watch_tracks.sh              check once; run + push anything new
#   ./watch_tracks.sh --dry-run    show what it would do, change nothing
#
# A track is "new" if it was issued in the last MAX_AGE_H hours (default 48) and the server has
# no model run named "Rapid Exposure Forecast - TC <name> <stamp>" yet. The server is the record,
# so there is no state file. A track whose run keeps failing is retried MAX_TRIES times, then left.
#
# .env needs API_KEY (RiskScape) and either
#   PARTNER_USERNAME + PARTNER_PASSWORD   (a fresh token is fetched every check; best, tokens expire in 2 days)
# or PARTNER_API_TOKEN (will stop working after 2 days).
#
# Schedule it (every 15 minutes):  crontab -e  and add
#   */15 * * * * /home/kishank/REF-Model/watch_tracks.sh >> /home/kishank/REF-Model/watch.log 2>&1

set -u
cd "$(dirname "$0")"
exec 9>.watch.lock
flock -n 9 || { echo "$(date -u +%FT%TZ) another check is still running, skipping"; exit 0; }

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
[ -f .env ] || { echo "$(date -u +%FT%TZ) ERROR: .env is missing in $(pwd)"; exit 1; }
set -a; . ./.env; set +a
[ -n "${API_KEY:-}" ] || { echo "$(date -u +%FT%TZ) ERROR: API_KEY is empty in .env"; exit 1; }
CAN_PUSH=1
if [ -z "${PARTNER_API_TOKEN:-}" ] && { [ -z "${PARTNER_USERNAME:-}" ] || [ -z "${PARTNER_PASSWORD:-}" ]; }; then
  CAN_PUSH=0
  echo "$(date -u +%FT%TZ) WARNING: no Pacific API login or token in .env: will run REF and keep the outputs, but not upload"
fi
BASE=https://pacific-disaster-api.spc.int/partner_api
P=$BASE/v1
MAX_AGE_H="${MAX_AGE_H:-48}"
MAX_TRIES="${MAX_TRIES:-3}"
export PATH="/usr/bin:$PATH"
mkdir -p .watch_failed .watch_done
log() { echo "$(date -u +%FT%TZ) $*"; }

get_token() {
  if [ -n "${PARTNER_USERNAME:-}" ] && [ -n "${PARTNER_PASSWORD:-}" ]; then
    curl -s -m 30 -X POST "$BASE/api-token-auth/" \
      --data-urlencode "username=$PARTNER_USERNAME" --data-urlencode "password=$PARTNER_PASSWORD" \
      | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' 2>/dev/null
  else
    echo "${PARTNER_API_TOKEN:-}"
  fi
}

# notify "<subject>" "<message>": email NOTIFY_EMAIL (comma-separated) through the Pacific API mailer.
# Does nothing if NOTIFY_EMAIL is unset or there is no token. Never stops the watcher if it fails.
notify() {
  [ -n "${NOTIFY_EMAIL:-}" ] || return 0
  [ "$DRY" = 1 ] && return 0
  local tok; tok="$(get_token)"; [ -n "$tok" ] || return 0
  local body; body=$(python3 -I -c 'import json,sys; print(json.dumps({"recipients": [a.strip() for a in sys.argv[1].split(",") if a.strip()], "subject": sys.argv[2], "message": sys.argv[3]}))' "$NOTIFY_EMAIL" "$1" "$2")
  local code; code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Token $tok" -H "Content-Type: application/json" -d "$body" "$P/mailer/send/")
  log "  email '$1': HTTP $code"
}

# new tracks, oldest first: "<id> <cyclone_name> <issued_time>"
NEW=$(python3 -I - "$MAX_AGE_H" "$P" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone, timedelta
max_age, P = float(sys.argv[1]), sys.argv[2]
def get(u): return json.loads(subprocess.run(["curl", "-s", "-m", "120", u], capture_output=True, text=True).stdout)
tracks = get(f"{P}/cyclone_track/?format=json")
tracks = tracks.get("results", tracks) if isinstance(tracks, dict) else tracks
runs = {r["name"] for r in get(f"{P}/model_run/?format=json")}
import os
now = datetime.now(timezone.utc)
for t in sorted(tracks, key=lambda t: t["id"]):
    if not t.get("issued_time") or "_" not in t["cyclone_name"]: continue
    issued = datetime.fromisoformat(t["issued_time"].replace("Z", "+00:00"))
    if now - issued > timedelta(hours=max_age): continue
    stamp, _, cyc = t["cyclone_name"].partition("_")
    base = f"Rapid Exposure Forecast - TC {cyc} {stamp}"
    if any(n == base or n.startswith(base + " (") for n in runs): continue
    if os.path.exists(f".watch_done/{t['id']}"): continue
    print(t["id"], t["cyclone_name"], t["issued_time"])
PY
) || { log "could not read the track list, will try again next time"; exit 1; }

if [ -z "$NEW" ]; then log "no new tracks"; exit 0; fi

echo "$NEW" | while read -r id name issued; do
  tries=$(cat ".watch_failed/$id" 2>/dev/null || echo 0)
  if [ "$tries" -ge "$MAX_TRIES" ]; then log "track $id ($name): failed $tries times, giving up (delete .watch_failed/$id to retry)"; continue; fi
  dir="outputs/${name}_$(date -u -d "$issued" +%Y%m%dT%H%M%SZ)"
  log "track $id ($name, issued $issued): new"
  [ "$tries" = 0 ] && notify "New cyclone track: $name" "A new track $name (id $id, issued $issued) is available. REF is starting now; you will get another email when the run is on the dashboard."
  if [ "$DRY" = 1 ]; then log "  dry run: would run REF.sh then push $dir"; continue; fi

  if [ -f "$dir/regional-summary.csv" ]; then
    log "  outputs already in $dir, skipping the REF run"
  else
    TRACK_ID="$id" ./REF.sh
  fi
  if [ ! -f "$dir/regional-summary.csv" ]; then
    echo $((tries + 1)) > ".watch_failed/$id"
    log "  REF run failed or produced no outputs (attempt $((tries + 1))/$MAX_TRIES)"
    [ $((tries + 1)) -ge "$MAX_TRIES" ] && notify "REF run FAILED: $name" "The REF run for track $name (id $id) failed $MAX_TRIES times and will not be retried. See watch.log on the server. Delete .watch_failed/$id to retry."
    continue
  fi
  if [ "$CAN_PUSH" = 0 ]; then log "  outputs saved in $dir, not uploaded (no Pacific login)"; continue; fi
  TOKEN="$(get_token)"
  if [ -z "$TOKEN" ]; then log "  could not get a Partner API token, outputs are in $dir; push later"; continue; fi
  OUT="$(PARTNER_API_TOKEN="$TOKEN" python3 -I push_runs.py "$dir" 2>&1)"; RC=$?; echo "$OUT"
  if [ "$RC" = 0 ]; then
    touch ".watch_done/$id"      # handled (even if no published country was affected)
    if echo "$OUT" | grep -q "created"; then
      notify "REF run uploaded: $name" "The REF run for $name (track $id) finished and is on the Pacific Disaster API. $(echo "$OUT" | grep -E 'model run .* created|added run|created event' | tr '\n' ' ')"
    else
      log "  nothing to upload: the storm affects no published country"
    fi
  else
    log "  push failed"
    notify "REF upload FAILED: $name" "The REF run for $name (track $id) finished but the upload failed (token expired?). Outputs are in $dir. See watch.log. Fix the token in .env and run ./upload_watch.sh."
  fi
  rm -f ".watch_failed/$id"
done
