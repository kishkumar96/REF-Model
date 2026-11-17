#!/usr/bin/env python3
"""Create a Model run (+ its 9 Risk information entries) on the Pacific Disaster API
for each run folder given. Mirrors how the existing Wati runs are built.

  PARTNER_API_TOKEN=<token> python3 push_runs.py --dry-run outputs/2026111700_Xavier_20261117T000000Z
  PARTNER_API_TOKEN=<token> python3 push_runs.py outputs/2026111700_Xavier_20261117T000000Z

Uses curl for every request (the server blocks Python's own HTTP client).
Tokens expire after 2 days. COUNTRY_ID defaults to 3 (CK).
"""
import json, os, re, subprocess, sys

P = os.environ.get("PARTNER_API_URL", "https://pacific-disaster-api.spc.int/partner_api/v1")
TOKEN = os.environ.get("PARTNER_API_TOKEN", "")
COUNTRY = int(os.environ.get("COUNTRY_ID", "3"))  # 3 = CK on the Pacific Disaster API
MODEL_ID = 2                                      # Rapid Exposure Forecast
# file -> (title suffix, risk_category); categories copied from the Wati runs
FILES = [
    ("cyclone-track.geojson", "cyclone track", None),
    ("exposure-by-cluster.geojson", "exposure by cluster", 3),
    ("regional-impacts.geojson", "regional impacts", 7),
    ("regional-summary.csv", "regional summary", 9),
    ("total-by-track-distance.csv", "total by track distance", None),
    ("total-by-windspeed.csv", "total by windspeed", None),
    ("total-exposed-by-country.csv", "total exposed by country", None),
    ("track-distance.geojson", "track distance", None),
    ("wind-swaths.geojson", "wind swaths", None),
]

def curl(args):
    out = subprocess.run(["curl", "-s", "-m", "300", "-w", "\n%{http_code}"] + args,
                         capture_output=True, text=True).stdout
    body, code = out.rsplit("\n", 1)
    return int(code), body

def get(url):
    code, body = curl([url])
    if code != 200:
        sys.exit(f"GET {url} failed: HTTP {code}")
    return json.loads(body)

def auth():
    return ["-H", f"Authorization: Token {TOKEN}"]

dry = "--dry-run" in sys.argv
folders = [a for a in sys.argv[1:] if not a.startswith("--")]
if not folders:
    sys.exit(__doc__)
if not TOKEN and not dry:
    sys.exit("PARTNER_API_TOKEN is not set")

tracks = {t["cyclone_name"]: t for t in get(f"{P}/cyclone_track/?format=json")}
existing = {r["name"] for r in get(f"{P}/model_run/?format=json")}

for folder in folders:
    folder = folder.rstrip("/")
    base = os.path.basename(folder)
    name = re.sub(r"_\d{8}T\d{6}Z$", "", base)          # 2026111700_Xavier
    t = tracks.get(name)
    if not t:
        print(f"{base}: no SPC track named {name}, skipped"); continue
    stamp, cyc = name.split("_", 1)
    run_name = f"Rapid Exposure Forecast - TC {cyc} {stamp}"
    if run_name in existing:
        print(f"{base}: '{run_name}' already on the server, skipped"); continue
    missing = [f for f, _, _ in FILES if not os.path.isfile(f"{folder}/{f}")]
    if missing:
        print(f"{base}: missing {missing}, skipped"); continue
    if dry:
        print(f"{base}: would create model run '{run_name}' (track {t['id']}) + {len(FILES)} risk entries"); continue
    body = json.dumps({"name": run_name, "model_run_time": t["issued_time"],
                       "model_run_completed": True, "tc_track": t["id"], "models": [MODEL_ID]})
    code, resp = curl(auth() + ["-H", "Content-Type: application/json", "-X", "POST", "-d", body, f"{P}/model_run/"])
    if code != 201:
        print(f"{base}: model run refused HTTP {code} {resp[:300]}"); continue
    run_id = json.loads(resp)["id"]
    print(f"{base}: model run {run_id} created ({run_name}, track {t['id']})")
    risk_ids = []
    for fname, label, cat in FILES:
        args = auth() + ["-F", f"title=TC {cyc} {stamp} - {label}", "-F", f"country={COUNTRY}",
                         "-F", f"model_run={run_id}"]
        if cat:
            args += ["-F", f"risk_category={cat}"]
        args += ["-F", f"upload=@{folder}/{fname}", f"{P}/risk_information/"]
        c, b = curl(args)
        print(f"   {fname}: HTTP {c}" + ("" if c == 201 else f" {b[:200]}"))
        if c == 201:
            risk_ids.append(json.loads(b)["id"])
    # the run's own risks list is separate from each entry's model_run: set it so the dashboard shows them
    c, b = curl(auth() + ["-H", "Content-Type: application/json", "-X", "PATCH",
                          "-d", json.dumps({"risks": risk_ids}), f"{P}/model_run/{run_id}/"])
    print(f"   linked {len(risk_ids)} risks to run {run_id}: HTTP {c}")
    # add the run to this cyclone's event (matched by name and country) so the dashboard lists it
    events = [e for e in get(f"{P}/event/?format=json&page_size=100").get("results", [])
              if cyc.lower() in e["title"].lower() and e["country"] == COUNTRY]
    if not events:
        print(f"   no event for {cyc} in country {COUNTRY}: create one, then add run {run_id} to it")
    else:
        ev = events[0]
        c, b = curl(auth() + ["-H", "Content-Type: application/json", "-X", "PATCH",
                              "-d", json.dumps({"model_runs": sorted(set(ev["model_runs"]) | {run_id})}),
                              f"{P}/event/{ev['id']}/"])
        print(f"   added run {run_id} to event {ev['id']} '{ev['title']}': HTTP {c}")
