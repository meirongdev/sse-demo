#!/usr/bin/env bash
# Tomcat vs Netty, at the count every other transport has already been measured at.
#
# The profiler put SSE's per-connection cost on the servlet stack squarely in Tomcat's own types —
# 41 MessageBytes, 45 ByteChunk, 42 CharChunk and an Http11Processor held for the life of an HTTP
# request that never completes. None of those exist on Netty. This is the only test that can say
# whether "SSE is expensive" was a statement about SSE or a statement about Tomcat.
#
# ⚠ This changes MORE than one variable and is labelled accordingly: no servlet model, no virtual
# thread per connection, a Sinks.Many in place of the bounded queue. It answers "does the stack move
# the number", not "is SSE cheaper than WebSocket" — that question is already answered per stack.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${N:-20000}"
for m in sse ws; do
  echo "#### WebFlux/Netty — $m @ $N"
  MODE=$m CONNS=$N CLIENTS=1 RATE=4000 HOLD=90s SERVER_IMAGE=ssebench-webflux \
    LABEL="p12-webflux-$m" "$HERE/run.sh" || true
done

printf '\n%-22s %9s %10s %10s %9s %10s\n' RUN ESTAB P99ms HEAPLIVE 每连接 FANOUTMAX
for d in $(ls -d "$HERE"/../results/*p12-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  jq -r '[.label,.client.established,.client.latencyMillis.p99,(.server.heapLiveMb|round),
          (if .client.liveAtEnd>0 then (((.server.heapLiveMb-74)*1024/.client.liveAtEnd)|floor) else 0 end),
          (.server.fanOutMaxMillis|round)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-22s %9s %10s %8sMB %7sKB %9sms\n",$1,$2,$3,$4,$5,$6}'
done
