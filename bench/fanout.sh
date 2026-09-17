#!/usr/bin/env bash
# Does sharding the fan-out move the ceiling?
#
# Two pairs, and in each pair the ONLY variable is FANOUT_THREADS. Both rungs are ones that failed:
# SSE at 40,000 and WebSocket at 60,000 — and SSE at 40,000 fails with 267% of CPU still unused, which
# is what makes it the sharpest test of whether one enqueue thread is the wall.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCK="-e MAX_HEADER_SIZE=2KB -e APP_READ_BUF=2048 -e APP_WRITE_BUF=2048"

for f in 1 4; do
  echo "#### SSE @ 40,000 — fanout threads = $f"
  MODE=sse CONNS=40000 CLIENTS=2 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
    EXTRA_ENV="$SOCK -e FANOUT_THREADS=$f" LABEL="p7-sse-40k-fanout$f" "$HERE/run.sh" || true
done

for f in 1 4; do
  echo "#### WS @ 60,000 — fanout threads = $f"
  MODE=ws CONNS=60000 CLIENTS=3 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
    WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
    EXTRA_JAVA_OPTS="-Dorg.apache.tomcat.websocket.DEFAULT_BUFFER_SIZE=2048" \
    EXTRA_ENV="$SOCK -e FANOUT_THREADS=$f" LABEL="p7-ws-60k-fanout$f" "$HERE/run.sh" || true
done

printf '\n%-24s %8s %10s %11s %9s %8s\n' RUN ESTAB P99ms FANOUTMAXms HEAPLIVE CPUmed
for d in $(ls -d "$HERE"/../results/*p7-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  cpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/server/ {gsub(/%/,"",$2); print $2+0}' | sort -n | awk '{a[NR]=$1} END{printf "%.0f", a[int(NR/2)+1]}')
  jq -r --arg c "$cpu" '[.label,.client.established,.client.latencyMillis.p99,
       (.server.fanOutMaxMillis|round),(.server.heapLiveMb|round),$c]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-24s %8s %10s %11s %8sMB %7s%%\n",$1,$2,$3,$4,$5,$6}'
done
