#!/usr/bin/env bash
# Can SSE's 110 KB per connection be brought down?
#
# ⚠ The baseline is RE-MEASURED on the current build rather than taken from the sweep. The image changed
# between the two, and a saving compared against a differently-built baseline is not a saving.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="CONNS=20000 CLIENTS=1 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 MODE=sse"

echo "#### a — baseline, Tomcat defaults (8 KB headers, 8 KB socket buffers)"
env $C LABEL="p5a-sse-base" "$HERE/run.sh" || true

echo "#### b — request header buffers 8 KB → 2 KB (SSE-specific: WS sheds these at upgrade)"
env $C EXTRA_ENV="-e MAX_HEADER_SIZE=2KB" LABEL="p5b-sse-hdr2k" "$HERE/run.sh" || true

echo "#### c — header buffers AND the two NIO socket buffers → 2 KB (helps both transports)"
env $C EXTRA_ENV="-e MAX_HEADER_SIZE=2KB -e APP_READ_BUF=2048 -e APP_WRITE_BUF=2048" \
  LABEL="p5c-sse-all2k" "$HERE/run.sh" || true

printf '\n%-18s %10s %10s %9s %8s\n' CONFIG heapLive KB/conn p99ms CPUmed
for d in $(ls -dt "$HERE"/../results/*p5* | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  cpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/server/ {gsub(/%/,"",$2); print $2+0}' | sort -n | awk '{a[NR]=$1} END{printf "%.0f", a[int(NR/2)+1]}')
  jq -r --arg cpu "$cpu" '[.label,(.server.heapLiveMb|round),
      (((.server.heapLiveMb - 74) * 1024 / .client.liveAtEnd)*10|round/10),
      .client.latencyMillis.p99,$cpu]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-18s %9sMB %9sKB %8sms %7s%%\n",$1,$2,$3,$4,$5}'
done
