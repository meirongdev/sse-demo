#!/usr/bin/env bash
# spc=1 at a count the LOAD GENERATOR can hold without saturating.
#
# ⚠ At 20,000 streams with one connection each, the Go client peaked at 406% of its 400% limit —
# 20,000 independent Transports, each with its own HPACK state and goroutines, is simply heavy. The
# server-side MEMORY from that run stands (every stream established, nothing dropped), but its p99 is
# the client's number, not the server's. 10,000 keeps the client clear and lines up with the existing
# HTTP/1.1 SSE rung at the same count.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A: spc=1 at 10,000, where the client stays clear — the clean latency number spc=1@20k could not give.
MODE=sse-h2 CONNS=10000 CLIENTS=1 RATE=2000 HOLD=90s MAX_CONNECTIONS=200000 \
  CLIENT_MEM=10g CLIENT_CPUS=4 STREAMS_PER_CONN=1 \
  EXTRA_ENV="-e HTTP2_ENABLED=true -e MAX_STREAMS=200000" \
  LABEL="p11-h2-spc1-10k" "$HERE/run.sh" || true

# B: spc=3, to FALSIFY the cost model fitted from spc=1 and spc=6.
#
# Those two points give ~99 KB per TCP connection and ~65 KB per stream, which puts the break-even
# against HTTP/1.1's 110 KB at about 2.2 streams per connection. The model predicts spc=3 lands at
# roughly 2030 MB of live heap. A prediction made before the run is the only kind worth anything —
# if it comes out near 1700 or near 3300 instead, the two-term model is wrong and the break-even
# figure goes with it.
MODE=sse-h2 CONNS=20000 CLIENTS=1 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
  CLIENT_MEM=10g CLIENT_CPUS=4 STREAMS_PER_CONN=3 \
  EXTRA_ENV="-e HTTP2_ENABLED=true -e MAX_STREAMS=200000" \
  LABEL="p11-h2-spc3-20k" "$HERE/run.sh" || true

printf '\n%-22s %9s %10s %10s %10s\n' RUN STREAMS P99ms HEAPLIVE OPENFDS
for d in $(ls -d "$HERE"/../results/*p11-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  jq -r '[.label,.client.established,.client.latencyMillis.p99,(.server.heapLiveMb|round),.server.openFds]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-22s %9s %10s %8sMB %10s\n",$1,$2,$3,$4,$5}'
done
