#!/usr/bin/env python3
"""Pick the one server sample that describes the hold, out of run.sh's 5-second poll series.

Two gates, both self-calibrating against the series itself, because the bug this replaces was a
constant-shaped assumption — "`liveSessions` > 0 means it is still carrying the load". Rust @
100,000 published 228.8 MB out of a 3389.1 MB plateau: during teardown the kernel closes the
sockets and RSS falls away, while the server's own counter is still reporting the full population.
The artifact sample says it itself: `disconnects: 0`, `liveSessions: 100000`, `openFds` 100013 → 13.

  1. population gate — `liveSessions` >= 99% of the series' own peak. 99% because one lost
     connection in 100,000 is 0.001%, so the band absorbs the harness's own slow-consumer closes
     without admitting a sample whose population has already decayed. The peak is read from the
     series rather than from CONNS: a run that hit Tomcat's maxConnections wall plateaus below
     what was requested and is still a valid run of what actually happened.
  2. physical gate — of those, walk back past any trailing sample whose `rssMb` has fallen below
     half the plateau median. Memory that is already gone while the counter still claims a full
     population is a teardown artifact, not a hold reading.

⚠ `openFds` looks like the better signal (kernel-sourced, cannot lag) and is not one: under HTTP/2
the population shares TCP connections — `p8-sse-h2-20000` peaks at **242 FDs for 20,000 streams** —
so it counts sockets, not users, and would gate every h2 run to an early, low sample.

The half in gate 2 is calibrated against the 64 series in `results/` (62 of which carried load),
not guessed: the artifact sits at 0.07× its own plateau, and the lowest legitimate full-population
sample anywhere in the corpus sits at 0.72× (netty @ 100,000, which genuinely shed 28% of its RSS
mid-hold while still holding 99,624 of 100,000 connections). Anything in (0.07, 0.72] separates
them; 0.5 keeps 7× of margin over the artifact and 1.4× clear of the nearest real reading.
A tighter band — the bare median, say — discards real samples and their cumulative counters
along with them.

run.sh writes server-final.json through this, and collect.py re-derives the server block through
the same function. They used to hold two versions of the rule, which is how defect 5 in
METHODOLOGY.md survived as long as it did.
"""
import json
import statistics
import sys

COLLAPSE_BAND = 0.5


def samples(text):
    """Every JSON object in the series, tolerating the shapes four runtimes actually produce:
    the probe prefixes a timestamp, Go's encoder appends a newline the JVM's does not (so blank
    lines), and a truncated tail is dropped rather than being fatal."""
    out = []
    for line in text.splitlines():
        i = line.find("{")
        if i < 0:
            continue
        try:
            out.append(json.loads(line[i:]))
        except Exception:
            continue
    return out


def final_sample(text):
    """The sample describing the hold, or None if the series never carried load."""
    loaded = [o for o in samples(text) if isinstance(o.get("liveSessions"), (int, float))]
    if not loaded:
        return None
    peak = max(o["liveSessions"] for o in loaded)
    if peak <= 0:
        return None
    plateau = [o for o in loaded if o["liveSessions"] >= peak * 0.99]
    rss = [o["rssMb"] for o in plateau if isinstance(o.get("rssMb"), (int, float))]
    if rss:
        floor = statistics.median(rss) * COLLAPSE_BAND
        for o in reversed(plateau):
            r = o.get("rssMb")
            if not isinstance(r, (int, float)) or r >= floor:
                return o
    return plateau[-1]


if __name__ == "__main__":
    print(json.dumps(final_sample(sys.stdin.read()) or {}))
