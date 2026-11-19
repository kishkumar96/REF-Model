#!/usr/bin/env python3
"""Create a Model run (+ its 9 Risk information entries) on the Pacific Disaster API
for each run folder given. Mirrors how the existing Wati runs are built.

  PARTNER_API_TOKEN=<token> python3 push_runs.py --dry-run outputs/2026111700_Xavier_20261117T000000Z
  PARTNER_API_TOKEN=<token> python3 push_runs.py outputs/2026111700_Xavier_20261117T000000Z

Uses curl for every request (the server blocks Python's own HTTP client).
Tokens expire after 2 days. COUNTRY_ID defaults to 3 (CK).

DATA SEPARATION: REF is one regional model, so its exposure files mix every country the storm touches.
Only COUNTRY_ID's rows are uploaded (filtered before upload, failing closed: a row or feature that cannot be
tied to that country is dropped). Other countries' exposure data is withheld and never leaves this machine.
The hazard files (track, wind swaths, track distance) are not country data and are uploaded whole.
  --create-events   create the cyclone's event for COUNTRY_ID if it has none (or CREATE_EVENTS=1)
  --link-only       for runs already on the server, only (re)do the event linking
"""
import csv, json, os, re, shutil, subprocess, sys, tempfile

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
create_events = "--create-events" in sys.argv or os.environ.get("CREATE_EVENTS") == "1"
link_only = "--link-only" in sys.argv
folders = [a for a in sys.argv[1:] if not a.startswith("--")]
if not folders:
    sys.exit(__doc__)
if not TOKEN and not dry:
    sys.exit("PARTNER_API_TOKEN is not set")

def as_list(r):
    return r.get("results", r) if isinstance(r, dict) else r

COUNTRY_BY_NAME = {c["long_name"].strip().lower(): c["id"] for c in as_list(get(f"{P}/country/?format=json"))}
NAME_BY_ID = {c["id"]: c["long_name"].strip() for c in as_list(get(f"{P}/country/?format=json"))}

def country_id(name):
    n = name.strip().lower()
    for k, v in COUNTRY_BY_NAME.items():
        if n == k or n.startswith(k) or k.startswith(n):
            return v
    return None

def folder_countries(folder):
    """{country id: number of rows} for the countries in the run's regional-summary.csv"""
    counts = {}
    try:
        with open(f"{folder}/regional-summary.csv", encoding="utf-8-sig") as f:
            for row in csv.DictReader(f):
                cid = country_id(row.get("Country", ""))
                if cid:
                    counts[cid] = counts.get(cid, 0) + 1
                elif row.get("Country"):
                    print(f"   (country '{row['Country']}' is not on the API's country list, ignored)")
    except OSError:
        pass
    return counts

# files whose rows/features are per country (everything else is hazard-only)
FILTERED = {"exposure-by-cluster.geojson", "regional-impacts.geojson", "regional-summary.csv",
            "total-by-track-distance.csv", "total-by-windspeed.csv", "total-exposed-by-country.csv"}

def filter_file(src, dst, name, keep):
    """write only the rows/features of country id `keep`; returns (kept, dropped). Fails closed."""
    if name.endswith(".csv"):
        with open(src, encoding="utf-8-sig", newline="") as f:
            rd = csv.DictReader(f); cols = rd.fieldnames or []; rows = list(rd)
        col = "Country" if "Country" in cols else ("Region" if name == "total-exposed-by-country.csv" else None)
        if col is None:
            sys.exit(f"{name}: no Country column, refusing to upload it")
        out = [r for r in rows if country_id(r.get(col) or "") == keep]
        with open(dst, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols); w.writeheader(); w.writerows(out)
        return len(out), len(rows) - len(out)
    with open(src, encoding="utf-8") as f:
        d = json.load(f)
    feats = d.get("features", [])
    def fcountry(ft):
        p = ft.get("properties") or {}
        for k in ("Country", "Region.Country", "country"):
            if k in p:
                return country_id(str(p[k] or ""))
        return None
    out = [ft for ft in feats if fcountry(ft) == keep]
    d["features"] = out
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(d, f)
    return len(out), len(feats) - len(out)

def make_upload_set(folder, keep, tmp):
    """copy the files to upload into tmp, filtering the per-country ones; returns {file: path}, report lines"""
    paths, report = {}, []
    for fname, _, _ in FILES:
        src = f"{folder}/{fname}"
        if fname in FILTERED:
            dst = f"{tmp}/{fname}"
            kept, dropped = filter_file(src, dst, fname, keep)
            report.append(f"{fname}: kept {kept}, withheld {dropped}")
            paths[fname] = dst
        else:
            paths[fname] = src
    return paths, report

def link_events(run_id, cyc, issued, cids):
    """add the run to the cyclone's event in each affected country (matched by name + country)"""
    events = as_list(get(f"{P}/event/?format=json&page_size=100"))
    for cid in cids:
        cname = NAME_BY_ID.get(cid, cid)
        match = [e for e in events if cyc.lower() in e["title"].lower() and e["country"] == cid]
        if match:
            ev = match[0]
            if run_id in ev["model_runs"]:
                print(f"   run {run_id} already in event {ev['id']} '{ev['title']}' ({cname})"); continue
            if dry:
                print(f"   would add run {run_id} to event {ev['id']} '{ev['title']}' ({cname})"); continue
            c, b = curl(auth() + ["-H", "Content-Type: application/json", "-X", "PATCH",
                                  "-d", json.dumps({"model_runs": sorted(set(ev["model_runs"]) | {run_id})}),
                                  f"{P}/event/{ev['id']}/"])
            print(f"   added run {run_id} to event {ev['id']} '{ev['title']}' ({cname}): HTTP {c}")
        elif create_events:
            if dry:
                print(f"   would create event 'Tropical Cyclone {cyc}' for {cname} with run {run_id}"); continue
            c, b = curl(auth() + ["-H", "Content-Type: application/json", "-X", "POST",
                                  "-d", json.dumps({"title": f"Tropical Cyclone {cyc}", "event_datetime": issued,
                                                    "event_type": 1, "country": cid, "model_runs": [run_id]}),
                                  f"{P}/event/"])
            print(f"   created event 'Tropical Cyclone {cyc}' for {cname} with run {run_id}: HTTP {c}"
                  + ("" if c == 201 else f" {b[:200]}"))
        else:
            print(f"   no event for {cyc} in {cname}: re-run with --create-events, or create one and add run {run_id}")

def create_run(folder, base, cyc, stamp, run_name, t, entry_country, upload_paths, cids):
    body = json.dumps({"name": run_name, "model_run_time": t["issued_time"],
                       "model_run_completed": True, "tc_track": t["id"], "models": [MODEL_ID]})
    code, resp = curl(auth() + ["-H", "Content-Type: application/json", "-X", "POST", "-d", body, f"{P}/model_run/"])
    if code != 201:
        print(f"{base}: model run refused HTTP {code} {resp[:300]}"); return
    run_id = json.loads(resp)["id"]
    print(f"{base}: model run {run_id} created ({run_name}, track {t['id']})")
    risk_ids = []
    for fname, label, cat in FILES:
        args = auth() + ["-F", f"title=TC {cyc} {stamp} - {label}", "-F", f"country={entry_country}",
                         "-F", f"model_run={run_id}"]
        if cat:
            args += ["-F", f"risk_category={cat}"]
        args += ["-F", f"upload=@{upload_paths[fname]}", f"{P}/risk_information/"]
        c, b = curl(args)
        print(f"   {fname}: HTTP {c}" + ("" if c == 201 else f" {b[:200]}"))
        if c == 201:
            risk_ids.append(json.loads(b)["id"])
    # the run's own risks list is separate from each entry's model_run: set it so the dashboard shows them
    c, b = curl(auth() + ["-H", "Content-Type: application/json", "-X", "PATCH",
                          "-d", json.dumps({"risks": risk_ids}), f"{P}/model_run/{run_id}/"])
    print(f"   linked {len(risk_ids)} risks to run {run_id}: HTTP {c}")
    link_events(run_id, cyc, t["issued_time"], cids)

tracks = {t["cyclone_name"]: t for t in as_list(get(f"{P}/cyclone_track/?format=json"))}
existing = {r["name"]: r["id"] for r in get(f"{P}/model_run/?format=json")}

for folder in folders:
    folder = folder.rstrip("/")
    base = os.path.basename(folder)
    name = re.sub(r"_\d{8}T\d{6}Z$", "", base)          # 2026111700_Xavier
    t = tracks.get(name)
    if not t:
        print(f"{base}: no SPC track named {name}, skipped"); continue
    stamp, cyc = name.split("_", 1)
    run_name = f"Rapid Exposure Forecast - TC {cyc} {stamp}"
    counts = folder_countries(folder)
    cids = [COUNTRY]                      # events only for the country whose data we publish
    cnames = str(NAME_BY_ID.get(COUNTRY, COUNTRY))
    withheld = ", ".join(f"{NAME_BY_ID.get(c, c)} ({n} rows)" for c, n in sorted(counts.items()) if c != COUNTRY)
    if run_name in existing:
        if link_only:
            print(f"{base}: run {existing[run_name]} already on the server; linking events for: {cnames}")
            link_events(existing[run_name], cyc, t["issued_time"], cids)
        else:
            print(f"{base}: '{run_name}' already on the server, skipped")
        continue
    if link_only:
        print(f"{base}: not on the server, skipped (--link-only)"); continue
    missing = [f for f, _, _ in FILES if not os.path.isfile(f"{folder}/{f}")]
    if missing:
        print(f"{base}: missing {missing}, skipped"); continue
    entry_country = COUNTRY
    tmp = tempfile.mkdtemp(prefix="ref_upload_")
    try:
        upload_paths, report = make_upload_set(folder, COUNTRY, tmp)
        if dry:
            print(f"{base}: would create model run '{run_name}' (track {t['id']}) + {len(FILES)} risk entries for {cnames}"
                  + (f"; WITHHELD: {withheld}" if withheld else ""))
            for line in report: print(f"   {line}")
            link_events(0, cyc, t["issued_time"], cids)
            continue
        if withheld: print(f"   withholding other countries' data: {withheld}")
        for line in report: print(f"   {line}")
        create_run(folder, base, cyc, stamp, run_name, t, entry_country, upload_paths, cids)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
