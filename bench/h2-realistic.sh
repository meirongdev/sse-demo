#!/usr/bin/env bash
# HTTP/2 with a REALISTIC client population.
#
# ⚠ The first h2 runs put every stream on one shared transport, so 20,000 streams rode one TCP
# connection. That models one client opening 20,000 streams — it measures h2's multiplexing CEILING,
# not a population of users. A browser opens one h2 connection per origin and shares it across that
# user's tabs, so the real ratio is 1 to a handful.
#
#   1  — every simulated client independent. The honest baseline, and the case where h2 should LOSE:
#        the connection-level cost is paid in full, plus h2's own connection state and HPACK tables.
#   6  — one user with six tabs, the ratio HTTP/1.1's six-connections-per-origin limit used to cap.
#   all — the original shared-transport run, kept as the upper bound it actually is.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${N:-20000}"
for spc in 1 6; do
  echo "#### SSE/h2c @ $N streams, $spc stream(s) per TCP connection"
  MODE=sse-h2 CONNS=$N CLIENTS=1 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
    CLIENT_MEM=10g CLIENT_CPUS=4 STREAMS_PER_CONN=$spc \
    EXTRA_ENV="-e HTTP2_ENABLED=true -e MAX_STREAMS=200000" \
    LABEL="p10-h2-spc$spc" "$HERE/run.sh" || true
done

printf '\n%-16s %9s %10s %10s %10s %9s\n' RUN STREAMS P99ms HEAPLIVE OPENFDS CPUmed
for d in $(ls -d "$HERE"/../results/*p10-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  cpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/server/ {gsub(/%/,"",$2); print $2+0}' | sort -n | awk '{a[NR]=$1} END{printf "%.0f", a[int(NR/2)+1]}')
  ccpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/client/ {gsub(/%/,"",$2); if($2+0>m) m=$2+0} END{printf "%.0f", m}')
  jq -r --arg c "$cpu" --arg cc "$ccpu" '[.label,.client.established,.client.latencyMillis.p99,
       (.server.heapLiveMb|round),.server.openFds,$c,$cc]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-16s %9s %10s %8sMB %10s %8s%%  (client peak %s%% of 400%%)\n",$1,$2,$3,$4,$5,$6,$7}'
done
