#!/usr/bin/env bash
# SSE over HTTP/2 (h2c), against the same ladder the HTTP/1.1 runs used.
#
# The question this answers: how much of SSE's 110 KB per connection was the COST OF A TCP CONNECTION
# rather than the cost of a stream? Under h2 many streams share one connection, so everything the
# profiler attributed to NioSocketWrapper, Http11InputBuffer and the socket buffers is paid once per
# connection instead of once per stream.
#
# ⚠ One client container is enough and that is itself a result: multiplexing removes the ephemeral-port
# wall that forced the HTTP/1.1 runs to fan out across containers.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for n in 10000 20000 40000; do
  echo "#### SSE/h2c @ $n streams"
  MODE=sse-h2 CONNS=$n CLIENTS=1 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
    CLIENT_MEM=8g CLIENT_CPUS=2 \
    EXTRA_ENV="-e HTTP2_ENABLED=true -e MAX_STREAMS=200000" \
    LABEL="p8-sse-h2-$n" "$HERE/run.sh" || true
done
printf '\n%-20s %8s %10s %10s %10s %8s\n' RUN STREAMS P99ms HEAPLIVE OPENFDS CPUmed
for d in $(ls -d "$HERE"/../results/*p8-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  cpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/server/ {gsub(/%/,"",$2); print $2+0}' | sort -n | awk '{a[NR]=$1} END{printf "%.0f", a[int(NR/2)+1]}')
  jq -r --arg c "$cpu" '[.label,.client.established,.client.latencyMillis.p99,
       (.server.heapLiveMb|round),.server.openFds,$c]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-20s %8s %10s %8sMB %10s %7s%%\n",$1,$2,$3,$4,$5,$6}'
done
