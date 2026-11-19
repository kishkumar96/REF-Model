#!/usr/bin/env bash
# check_watcher.sh - is the REF watcher healthy? Read-only: it only looks at logs and the public API.
#   ./check_watcher.sh
cd "$(dirname "$0")"
P=https://pacific-disaster-api.spc.int/partner_api/v1
now=$(date -u +%s); bad=0
ok()   { echo "  OK    $*"; }
warn() { echo "  WARN  $*"; bad=1; }

echo "1. Is it running every 15 minutes?"
if [ -f watch.log ]; then
  last=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' watch.log | tail -1)
  ts=${last%% *}; mins=$(( (now - $(date -u -d "$ts" +%s)) / 60 ))
  [ "$mins" -le 20 ] && ok "last check ${mins} min ago ($ts)" || warn "last check was ${mins} min ago ($ts): cron may not be running it"
  hr=$(grep -c "^$(date -u -d '1 hour ago' +%FT%H)" watch.log)
  [ "$hr" -ge 3 ] && ok "$hr log lines in the previous hour (expect about 4)" || warn "only $hr log lines in the previous hour (expect about 4)"
else
  warn "no watch.log here: cron has not run it yet, or this is the wrong folder"
fi
crontab -l 2>/dev/null | grep -q "watch_tracks.sh" && ok "cron line present" || warn "no watch_tracks.sh line in 'crontab -l'"

echo "2. Any errors or failures recently?"
if [ -f watch.log ]; then
  e=$(grep -E "ERROR|FAILED|failed|Invalid token|expired|refused|Unauthorized" watch.log | tail -3)
  [ -z "$e" ] && ok "no errors in watch.log" || { warn "recent problems in watch.log:"; echo "$e" | sed 's/^/        /'; }
fi
ls .watch_failed/* >/dev/null 2>&1 && warn "tracks stuck after repeated failures: $(ls .watch_failed | tr '\n' ' ')" || ok "no tracks stuck in retry"

echo "3. Is the API up to date with the newest tracks?"
python3 -I - "$P" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone
P = sys.argv[1]
def get(u): return json.loads(subprocess.run(["curl", "-s", "-m", "240", u], capture_output=True, text=True).stdout)
tr = get(f"{P}/cyclone_track/?format=json"); tr = tr.get("results", tr) if isinstance(tr, dict) else tr
runs = {r["name"] for r in get(f"{P}/model_run/?format=json")}
now = datetime.now(timezone.utc); missing = []
for t in sorted(tr, key=lambda t: -t["id"])[:8]:
    if not t.get("issued_time") or "_" not in t["cyclone_name"]: continue
    age = (now - datetime.fromisoformat(t["issued_time"].replace("Z", "+00:00"))).total_seconds() / 3600
    stamp, _, cyc = t["cyclone_name"].partition("_")
    has = f"Rapid Exposure Forecast - TC {cyc} {stamp}" in runs
    print(f"  {'OK  ' if has else ('WAIT' if age < 0.5 else 'WARN')}  track {t['id']} {t['cyclone_name']} (issued {age:.1f} h ago): {'run on the API' if has else 'NO run yet'}")
    if not has and age >= 0.5: missing.append(t["id"])
sys.exit(1 if missing else 0)
PY
[ $? -ne 0 ] && bad=1

echo "4. Can it log in and send email?"
set -a; [ -f .env ] && . ./.env; set +a
if [ -n "${PARTNER_USERNAME:-}" ] && [ -n "${PARTNER_PASSWORD:-}" ]; then
  r=$(curl -s -m 30 -X POST "${P%/v1}/api-token-auth/" --data-urlencode "username=$PARTNER_USERNAME" --data-urlencode "password=$PARTNER_PASSWORD" | cut -c1-9)
  [ "$r" = '{"token":' ] && ok "login to the Pacific API works" || warn "login to the Pacific API FAILED (password changed?)"
else warn "no PARTNER_USERNAME/PARTNER_PASSWORD in .env (a token alone expires in 2 days)"; fi
[ -n "${NOTIFY_EMAIL:-}" ] && ok "email notifications on" || echo "  note  NOTIFY_EMAIL not set: no emails"
[ "${CREATE_EVENTS:-0}" = 1 ] && ok "CREATE_EVENTS=1 (events are created for new countries)" || warn "CREATE_EVENTS is not 1: a new country's event will not be created automatically"
echo; [ $bad = 0 ] && echo "Watcher looks healthy." || echo "Something needs attention (see WARN above)."
