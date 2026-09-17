#!/usr/bin/env python3
"""Diff an empty class histogram against a loaded one, and normalise by connection count.

What survives the subtraction is what a CONNECTION costs. The JVM's own furniture — its classes, its
interned strings, the framework graph built at startup — is in both snapshots and cancels.
"""
import re, sys, json, pathlib

def load(path):
    out = {}
    for line in pathlib.Path(path).read_text(errors="replace").splitlines():
        m = re.match(r"\s*\d+:\s+(\d+)\s+(\d+)\s+(\S+)", line)
        if m:
            inst, by, cls = int(m.group(1)), int(m.group(2)), m.group(3)
            out[cls] = (out.get(cls, (0, 0))[0] + inst, out.get(cls, (0, 0))[1] + by)
    return out

def report(tag, d, conns, topn=18):
    empty, loaded = load(d / "histogram-empty.txt"), load(d / "histogram-loaded.txt")
    rows = []
    for cls, (inst, by) in loaded.items():
        e_inst, e_by = empty.get(cls, (0, 0))
        d_by, d_inst = by - e_by, inst - e_inst
        if d_by > 0:
            rows.append((d_by, d_inst, cls))
    rows.sort(reverse=True)
    total = sum(r[0] for r in rows)
    print(f"\n===== {tag} — {conns:,} connections — heap held by connections: {total/1048576:.0f} MB "
          f"({total/conns/1024:.1f} KB/conn) =====")
    print(f"{'BYTES/CONN':>11} {'INST/CONN':>10}  CLASS")
    for d_by, d_inst, cls in rows[:topn]:
        print(f"{d_by/conns:11.0f} {d_inst/conns:10.2f}  {cls}")
    return {c: (b, i) for b, i, c in rows}

conns = 20000
sse = report("SSE", pathlib.Path("results/profile-sse-20000"), conns)
ws  = report("WebSocket", pathlib.Path("results/profile-ws-20000"), conns)

print("\n===== 差额：SSE 比 WS 多出来的（按每连接字节，取前 16）=====")
print(f"{'SSE B/conn':>11} {'WS B/conn':>10} {'DELTA':>10}  CLASS")
delta = []
for cls in set(sse) | set(ws):
    s = sse.get(cls, (0, 0))[0] / conns
    w = ws.get(cls, (0, 0))[0] / conns
    delta.append((s - w, s, w, cls))
delta.sort(reverse=True)
for d, s, w, cls in delta[:16]:
    if d > 100:
        print(f"{s:11.0f} {w:10.0f} {d:+10.0f}  {cls}")
