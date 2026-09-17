#!/usr/bin/env bash
# The tuning saved 21% of per-connection memory and 16% of CPU. The ceiling is CPU-bound, so neither
# number predicts the new ceiling — it has to be measured. Climb until the four criteria stop holding.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUNED="-e MAX_HEADER_SIZE=2KB -e APP_READ_BUF=2048 -e APP_WRITE_BUF=2048"
for n in 30000 40000; do
  c=$(( (n + 19999) / 20000 ))
  echo "#### SSE @ $n, fully tuned, $c client container(s)"
  MODE=sse CONNS=$n CLIENTS=$c RATE=4000 HOLD=90s MAX_CONNECTIONS=200000 \
    EXTRA_ENV="$TUNED" LABEL="p6-sse-tuned-$n" "$HERE/run.sh" || true
  last=$(ls -dt "$HERE"/../results/*p6-sse-tuned-$n 2>/dev/null | head -1)
  [ -f "$last/summary.json" ] || break
  ok=$(jq -r '((.client.established >= (.requestedConns*0.99)) and (.client.deliveryRatio >= 0.99)
               and (.client.latencyMillis.p99 < 1000))' "$last/summary.json")
  echo ">>>> $n : $ok"
  [ "$ok" = "true" ] || break
done
