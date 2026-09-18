#!/usr/bin/env python3
"""Collapse every results/*/summary.json into one CSV plus one JSON.

Written so the archive survives the raw directories being deleted: results/ is ~50 runs of probe
samples and container logs, and the two files this produces carry everything the report cites.

⚠ The server snapshot is taken from the SAMPLE SERIES, not from summary.json's `server` field.
Those two disagreed for the Go and Rust runs: run.sh used to pick the server's final sample by line
position, and Go's stats endpoint emits a trailing newline the JVM's does not, so the field came back
null. The series is authoritative. Which sample in it describes the hold is decided by
final_sample.py — the same one run.sh writes server-final.json with, so the CSV and the per-run
summary cannot disagree about it.
"""
import csv, json, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from final_sample import final_sample

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESULTS = ROOT / "results"

def server_from_series(d):
    f = d / "server-samples.jsonl"
    if not f.exists():
        return {}
    return final_sample(f.read_text(errors="replace")) or {}

def peak_cpu(d, needle):
    f = d / "docker-stats.log"
    if not f.exists():
        return None
    peak = 0.0
    for line in f.read_text(errors="replace").splitlines():
        for tok in line.split()[1:]:
            if "=" not in tok or needle not in tok:
                continue
            m = re.search(r"=([\d.]+)%", tok)
            if m:
                peak = max(peak, float(m.group(1)))
    return peak or None

rows = []
for d in sorted(RESULTS.glob("*/")):
    s = d / "summary.json"
    if not s.exists():
        continue
    try:
        sm = json.loads(s.read_text())
    except Exception:
        continue
    srv = server_from_series(d) or (sm.get("server") or {})
    cl = sm.get("client", {})
    lat = cl.get("latencyMillis", {}) or {}
    live = cl.get("liveAtEnd") or 0
    rss = srv.get("rssMb")
    heap = srv.get("heapLiveMb")
    rows.append({
        "run": d.name,
        "label": sm.get("label"),
        "mode": sm.get("mode"),
        "requested": sm.get("requestedConns"),
        "established": cl.get("established"),
        "liveAtEnd": live,
        "droppedInHold": cl.get("droppedDuringHold"),
        "deliveryRatio": cl.get("deliveryRatio"),
        "p99ms": lat.get("p99"),
        "rssMb": rss,
        "heapLiveMb": heap,
        "rssKbPerConn": round((rss * 1024 / live), 1) if (rss and live) else None,
        "fanOutMaxMs": srv.get("fanOutMaxMillis"),
        "openFds": srv.get("openFds"),
        "serverCpuPeakPct": peak_cpu(d, "server"),
        "clientCpuPeakPct": peak_cpu(d, "client"),
        "maxConnections": (sm.get("config") or {}).get("maxConnections"),
    })

out_csv = RESULTS / "ALL-RUNS.csv"
with out_csv.open("w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
(RESULTS / "ALL-RUNS.json").write_text(json.dumps(rows, indent=2, ensure_ascii=False))
print(f"{len(rows)} runs -> {out_csv.name}, ALL-RUNS.json")
