#!/usr/bin/env bash
# Does pre-encoding the frame once per tick remove the per-send cost the profiler found?
#
# JFR put 51% of SSE's allocation in StringLatin1.toLowerCase, String.encodeUTF8 and
# MediaType.parseMediaType — all of it HTTP header and content-type work done on EVERY
# SseEmitter.send(). `bytes` mode hands the converter an array encoded once per tick instead.
#
# ⚠ On the WebSocket side `bytes` sends a BINARY frame, which is a different opcode and therefore
# not the same wire. It is measured anyway because it is the only way to hand Tomcat bytes that were
# encoded once — but it is a contract change a client must agree to, unlike SSE's, which is invisible.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="CONNS=20000 CLIENTS=1 RATE=4000 HOLD=90s MAX_CONNECTIONS=200000"

for m in sse ws; do
  for e in text bytes; do
    echo "#### $m — encode=$e"
    env $C MODE=$m ENCODE=$e WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
      LABEL="p9-$m-$e" "$HERE/run.sh" || true
  done
done

printf '\n%-16s %10s %10s %9s %10s\n' RUN P99ms HEAPLIVE CPUmed FANOUTMAX
for d in $(ls -d "$HERE"/../results/*p9-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  cpu=$(awk '{for(i=2;i<=NF;i++) print $i}' "$d/docker-stats.log" 2>/dev/null \
        | awk -F'=' '/server/ {gsub(/%/,"",$2); print $2+0}' | sort -n | awk '{a[NR]=$1} END{printf "%.0f", a[int(NR/2)+1]}')
  jq -r --arg c "$cpu" '[.label,.client.latencyMillis.p99,(.server.heapLiveMb|round),$c,
       (.server.fanOutMaxMillis|round)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-16s %10s %8sMB %8s%% %9sms\n",$1,$2,$3,$4,$5}'
done
