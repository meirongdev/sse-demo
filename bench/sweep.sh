#!/usr/bin/env bash
# The matrix. Three phases, each answering a different question, in the order that makes the next
# one interpretable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
HOLD="${HOLD:-90s}"
LADDER="${LADDER:-10000 20000 40000 60000 80000}"

# Each client container holds at most this many connections. The ceiling is the ephemeral-port pool:
# 10000-65535 is ~55,000 ports per (source IP, destination IP, destination port), and every client
# container has its own IP. 20,000 leaves a wide margin — a run that exhausts ports reports
# "connection refused" that looks exactly like a server at its limit.
PER_CLIENT_MAX="${PER_CLIENT_MAX:-20000}"

clients_for() { echo $(( ($1 + PER_CLIENT_MAX - 1) / PER_CLIENT_MAX )); }

echo "################ phase 1 — Tomcat's own defaults, and the wall they put in the way"
for mode in sse ws; do
  MODE=$mode CONNS=12000 CLIENTS=1 RATE=2000 HOLD="$HOLD" \
    MAX_CONNECTIONS=8192 WS_TEXT_BUFFER=8192 WS_BINARY_BUFFER=8192 \
    LABEL="p1-default-$mode" "$HERE/run.sh" || true
done

echo "################ phase 2 — tuned, ramped until it breaks"
for mode in sse ws; do
  for conns in $LADDER; do
    c=$(clients_for "$conns")
    echo "---- $mode @ $conns across $c client container(s)"
    if ! MODE=$mode CONNS=$conns CLIENTS=$c RATE=4000 HOLD="$HOLD" \
         MAX_CONNECTIONS=200000 WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
         LABEL="p2-tuned-$mode-$conns" "$HERE/run.sh"; then
      echo "---- $mode failed at $conns; stopping this ladder"
      break
    fi
    # Stop climbing once a level stops being SERVED rather than merely reached.
    last="$(ls -dt "$ROOT"/results/*p2-tuned-$mode-$conns 2>/dev/null | head -1)"
    if [ -n "$last" ] && [ -f "$last/summary.json" ]; then
      ok=$(jq -r '((.client.established >= (.requestedConns * 0.99))
                   and (.client.deliveryRatio >= 0.99)
                   and (.client.latencyMillis.p99 < 1000))' "$last/summary.json")
      if [ "$ok" != "true" ]; then
        echo "---- $mode stopped meeting the pass criteria at $conns; stopping this ladder"
        break
      fi
    fi
  done
done

echo "################ phase 3 — what Tomcat's 8 KB WebSocket buffers cost, at one fixed count"
MODE=ws CONNS=20000 CLIENTS=1 RATE=4000 HOLD="$HOLD" \
  MAX_CONNECTIONS=200000 WS_TEXT_BUFFER=8192 WS_BINARY_BUFFER=8192 \
  LABEL="p3-wsbuf-8192" "$HERE/run.sh" || true

echo "################ results"
"$HERE/report.sh"
