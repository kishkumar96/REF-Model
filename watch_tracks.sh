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
set -a; . ./.env; set +a
BASE=https://pacific-disaster-api.spc.int/partner_api
P=$BASE/v1
MAX_AGE_H="${MAX_AGE_H:-48}"
MAX_TRIES="${MAX_TRIES:-3}"
export PATH="/usr/bin:$PATH"
mkdir -p .watch_failed
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

# new tracks, oldest first: "<id> <cyclone_name> <issued_time>"
NEW=$(python3 -I - "$MAX_AGE_H" "$P" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone, timedelta
max_age, P = float(sys.argv[1]), sys.argv[2]
def get(u): return json.loads(subprocess.run(["curl", "-s", "-m", "120", u], capture_output=True, text=True).stdout)
tracks = get(f"{P}/cyclone_track/?format=json")
tracks = tracks.get("results", tracks) if isinstance(tracks, dict) else tracks
runs = {r["name"] for r in get(f"{P}/model_run/?format=json")}
now = datetime.now(timezone.utc)
for t in sorted(tracks, key=lambda t: t["id"]):
    if not t.get("issued_time") or "_" not in t["cyclone_name"]: continue
    issued = datetime.fromisoformat(t["issued_time"].replace("Z", "+00:00"))
    if now - issued > timedelta(hours=max_age): continue
    stamp, _, cyc = t["cyclone_name"].partition("_")
    if f"Rapid Exposure Forecast - TC {cyc} {stamp}" in runs: continue
    print(t["id"], t["cyclone_name"], t["issued_time"])
PY
) || { log "could not read the track list, will try again next time"; exit 1; }

if [ -z "$NEW" ]; then log "no new tracks"; exit 0; fi

echo "$NEW" | while read -r id name issued; do
  tries=$(cat ".watch_failed/$id" 2>/dev/null || echo 0)
  if [ "$tries" -ge "$MAX_TRIES" ]; then log "track $id ($name): failed $tries times, giving up (delete .watch_failed/$id to retry)"; continue; fi
  dir="outputs/${name}_$(date -u -d "$issued" +%Y%m%dT%H%M%SZ)"
  log "track $id ($name, issued $issued): new"
  if [ "$DRY" = 1 ]; then log "  dry run: would run REF.sh then push $dir"; continue; fi

  TRACK_ID="$id" ./REF.sh
  if [ ! -f "$dir/regional-summary.csv" ]; then
    echo $((tries + 1)) > ".watch_failed/$id"
    log "  REF run failed or produced no outputs (attempt $((tries + 1))/$MAX_TRIES)"; continue
  fi
  TOKEN="$(get_token)"
  if [ -z "$TOKEN" ]; then log "  could not get a Partner API token, outputs are in $dir; push later"; continue; fi
  PARTNER_API_TOKEN="$TOKEN" python3 -I push_runs.py "$dir" || log "  push failed"
  rm -f ".watch_failed/$id"
done
