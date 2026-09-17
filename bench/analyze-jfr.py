#!/usr/bin/env python3
"""Aggregate JFR ExecutionSample / ObjectAllocationSample stacks into top frames.

A flame graph collapsed to two questions: which leaf method is on CPU, and which call site allocates.
Frames are counted once per sample, so the percentages are of samples, not of wall time — the same
caveat every sampling profiler carries.
"""
import re, subprocess, sys, collections, pathlib

def stacks(jfr, event):
    out = subprocess.run(["jfr", "print", "--events", event, jfr],
                         capture_output=True, text=True).stdout
    cur, res = None, []
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("stackTrace = ["):
            cur = []
        elif cur is not None:
            if s == "]" or s.startswith("..."):
                if cur: res.append(cur)
                cur = None
            else:
                m = re.match(r"([\w.$]+\.[\w$<>]+)\(", s)
                if m: cur.append(m.group(1))
    return res

def top(jfr, event, label, n=12):
    ss = stacks(jfr, event)
    leaf = collections.Counter(s[0] for s in ss if s)
    total = len(ss)
    print(f"\n--- {label}: {total} samples")
    for fr, c in leaf.most_common(n):
        print(f"  {100*c/total:5.1f}%  {c:5d}  {fr}")
    return total, leaf

for mode in ("sse", "ws"):
    f = f"results/profile-{mode}-20000/hold.jfr"
    print(f"\n{'='*70}\n{mode.upper()}  —  20,000 connections, 60 s steady state\n{'='*70}")
    top(f, "jdk.ExecutionSample", "CPU (leaf frame)")
    top(f, "jdk.ObjectAllocationSample", "ALLOCATION (leaf frame)", 10)
