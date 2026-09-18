#!/usr/bin/env bash
# One run: start a 4C8G server container, ramp connections onto it from N client containers,
# hold, and write a single summary JSON.
#
# Plain docker rather than compose, deliberately. A benchmark needs the client containers scaled,
# started together and reaped together, their summaries merged, and the server polled on its own
# port throughout — compose would have needed a wrapper around it to do all four anyway, and a
# second source of truth for the limits that define the experiment.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
RESULTS="$ROOT/results"

MODE="${MODE:-sse}"              # sse | ws
CONNS="${CONNS:-20000}"          # total connections across all client containers
CLIENTS="${CLIENTS:-2}"          # client containers; each gets its own IP and its own ephemeral-port pool
RATE="${RATE:-2000}"             # connections/sec, total
HOLD="${HOLD:-120s}"
ROOMS="${ROOMS:-1}"
# sse-h2 only: how many SSE streams share one TCP connection. 1 = every simulated client is independent,
# which is what a population of separate browsers looks like. A large value measures h2's multiplexing
# ceiling instead, which is a bound, not a traffic model.
STREAMS_PER_CONN="${STREAMS_PER_CONN:-1}"
LABEL="${LABEL:-$MODE-$CONNS}"

# The machine under test. Everything about "4C8G" is these two lines.
# Which server under test. The servlet module by default; ssebench-webflux swaps Tomcat for Netty,
# which is the one variable that module exists to change.
SERVER_IMAGE="${SERVER_IMAGE:-ssebench-server}"

CPUS="${CPUS:-4}"
MEM="${MEM:-8g}"

# Server knobs. The `default` profile leaves Tomcat's own defaults in place; `tuned` is what you
# would actually deploy. The difference between the two passes is the finding, not a detail.
MAX_CONNECTIONS="${MAX_CONNECTIONS:-8192}"
WS_TEXT_BUFFER="${WS_TEXT_BUFFER:-8192}"
WS_BINARY_BUFFER="${WS_BINARY_BUFFER:-8192}"
FRAME_BYTES="${FRAME_BYTES:-265}"
TICK_INTERVAL_MS="${TICK_INTERVAL_MS:-1000}"
ENCODE="${ENCODE:-text}"
QUEUE_DEPTH="${QUEUE_DEPTH:-256}"
EXTRA_JAVA_OPTS="${EXTRA_JAVA_OPTS:-}"
# Extra `-e KEY=VALUE` pairs for the server container, for knobs that are not part of the standard matrix.
EXTRA_ENV="${EXTRA_ENV:-}"

# ⚠ The client containers share the same 10-vCPU VM as the server. If they saturate, the run reports
# the LOAD GENERATOR's ceiling as the server's — so they are limited explicitly and their CPU is
# recorded alongside the server's, and the report is not to be believed if these are pinned.
CLIENT_CPUS="${CLIENT_CPUS:-1}"
CLIENT_MEM="${CLIENT_MEM:-2g}"

# ⚠ MUTUAL EXCLUSION, and it is not paranoia — it cost a set of runs.
#
# Every invocation of this script uses the SAME fixed container names, and its own cleanup starts by
# `docker rm -f`-ing them. Two runs overlapping therefore delete each other's containers mid-flight,
# and the symptom is silent: `docker wait` succeeds, `docker logs` then reports "No such container",
# `set -e` exits, and the run leaves behind a results directory with no summary and no error in it.
#
# The lock is held from here until the EXIT trap fires — see bench/benchlock.sh for why release is a
# separate function and cannot live in cleanup().
# shellcheck source=benchlock.sh
. "$HERE/benchlock.sh"
bench_lock_acquire || exit 3

NET=ssebench
SERVER=ssebench-server
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$RESULTS/$STAMP-$LABEL"
mkdir -p "$OUT"

cleanup() {
  docker rm -f "$SERVER" >/dev/null 2>&1 || true
  docker rm -f ssebench-probe >/dev/null 2>&1 || true
  for i in $(seq 1 "$CLIENTS"); do docker rm -f "ssebench-client-$i" >/dev/null 2>&1 || true; done
}
# Release last, after the containers are gone, so the next run cannot start while these still exist.
trap 'cleanup; bench_lock_release' EXIT

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
cleanup

echo "==> server: ${CPUS} vCPU / ${MEM}, maxConnections=$MAX_CONNECTIONS, wsBuffers=${WS_TEXT_BUFFER}/${WS_BINARY_BUFFER}, frame=${FRAME_BYTES}B, tick=${TICK_INTERVAL_MS}ms, encode=$ENCODE"
docker run -d --name "$SERVER" --network "$NET" \
  --cpus "$CPUS" --memory "$MEM" --memory-swap "$MEM" \
  --ulimit nofile=1048576:1048576 \
  --sysctl net.core.somaxconn=65535 \
  --sysctl net.ipv4.tcp_max_syn_backlog=65535 \
  -e MAX_CONNECTIONS="$MAX_CONNECTIONS" \
  -e WS_TEXT_BUFFER="$WS_TEXT_BUFFER" \
  -e WS_BINARY_BUFFER="$WS_BINARY_BUFFER" \
  -e FRAME_BYTES="$FRAME_BYTES" \
  -e TICK_INTERVAL_MS="$TICK_INTERVAL_MS" \
  -e ENCODE="$ENCODE" \
  -e QUEUE_DEPTH="$QUEUE_DEPTH" \
  $EXTRA_ENV \
  -e JAVA_OPTS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv4Stack=true $EXTRA_JAVA_OPTS" \
  "$SERVER_IMAGE" >/dev/null

SERVER_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SERVER")"
echo "==> server at $SERVER_IP, waiting for health"
for _ in $(seq 1 60); do
  if docker run --rm --network "$NET" alpine:3.21 \
       wget -qO- "http://$SERVER_IP:9090/actuator/health" 2>/dev/null | grep -q UP; then break; fi
  sleep 1
done

# Poll the server on its MANAGEMENT port for the whole run, from ONE long-lived probe container.
# A `docker run` per sample would have been a container start every five seconds — a second of CPU
# on the same machine as the thing being measured, which is how a harness ends up in its own numbers.
docker rm -f ssebench-probe >/dev/null 2>&1 || true
docker run -d --name ssebench-probe --network "$NET" --cpus 0.5 alpine:3.21 sh -c \
  "while true; do printf '%s ' \$(date +%s); wget -qO- http://$SERVER_IP:9090/actuator/bench 2>/dev/null || echo '{}'; echo; sleep 5; done" >/dev/null

( while true; do
    printf '%s ' "$(date +%s)"
    docker stats --no-stream --format '{{.Name}}={{.CPUPerc}}' \
      $(docker ps --format '{{.Names}}' --filter name=ssebench- | grep -v probe | tr '\n' ' ') 2>/dev/null | tr '\n' ' '
    echo
    sleep 5
  done ) > "$OUT/docker-stats.log" 2>/dev/null &
STATSER=$!

PER_CLIENT=$((CONNS / CLIENTS))
PER_RATE=$((RATE / CLIENTS))
echo "==> $CLIENTS client container(s), $PER_CLIENT conns each at $PER_RATE/s, mode=$MODE, hold=$HOLD"

for i in $(seq 1 "$CLIENTS"); do
  docker run -d --name "ssebench-client-$i" --network "$NET" \
    --ulimit nofile=1048576:1048576 \
    --sysctl net.ipv4.ip_local_port_range="10000 65535" \
    --cpus "$CLIENT_CPUS" --memory "$CLIENT_MEM" \
    -v "$OUT:/out" \
    ssebench-loadgen \
      -target "$SERVER_IP:8080" -mode "$MODE" -conns "$PER_CLIENT" -rate "$PER_RATE" \
      -hold "$HOLD" -rooms "$ROOMS" -streams-per-conn "$STREAMS_PER_CONN" \
      -id "$i" -out "/out/client-$i.json" >/dev/null
done

for i in $(seq 1 "$CLIENTS"); do
  docker wait "ssebench-client-$i" >/dev/null
  docker logs "ssebench-client-$i" > "$OUT/client-$i.log" 2>&1
done

kill $STATSER 2>/dev/null || true
docker logs ssebench-probe > "$OUT/server-samples.jsonl" 2>/dev/null || true

# The sample that describes the hold, chosen by bench/final_sample.py — the same rule collect.py
# reads the series with, so the two cannot drift (that drift was 缺陷 5).
#
# "The last line whose liveSessions is non-zero" is not "still carrying the load". The server's own
# counter lags the kernel by one sample at teardown: the sockets are gone, RSS has collapsed, and
# it still reports the full population with `disconnects: 0`. Rust @ 100,000 published 228.8 MB out
# of a 3389.1 MB plateau — 2 KB/connection instead of 35 — and a fan-out figure inflated by the
# teardown itself. See METHODOLOGY.md 缺陷 6.
[ -f "$OUT/server-samples.jsonl" ] && python3 "$HERE/final_sample.py" \
  < "$OUT/server-samples.jsonl" > "$OUT/server-final.json" || true
[ -s "$OUT/server-final.json" ] || echo '{}' > "$OUT/server-final.json"
docker logs "$SERVER" > "$OUT/server.log" 2>&1 || true

jq -n \
  --arg label "$LABEL" --arg mode "$MODE" --arg stamp "$STAMP" \
  --argjson cpus "$CPUS" --arg mem "$MEM" \
  --argjson maxConnections "$MAX_CONNECTIONS" \
  --argjson wsTextBuffer "$WS_TEXT_BUFFER" --argjson wsBinaryBuffer "$WS_BINARY_BUFFER" \
  --argjson frameBytes "$FRAME_BYTES" --argjson tickMs "$TICK_INTERVAL_MS" --arg encode "$ENCODE" \
  --argjson requested "$CONNS" \
  --slurpfile clients <(cat "$OUT"/client-*.json) \
  --slurpfile server <(cat "$OUT/server-final.json" 2>/dev/null || echo '{}') \
  '{
     label: $label, mode: $mode, stamp: $stamp,
     limits: { cpus: $cpus, memory: $mem },
     config: { maxConnections: $maxConnections, wsTextBuffer: $wsTextBuffer, wsBinaryBuffer: $wsBinaryBuffer,
               frameBytes: $frameBytes, tickIntervalMs: $tickMs, encode: $encode },
     requestedConns: $requested,
     client: {
       established:  ([$clients[].established]  | add),
       liveAtEnd:    ([$clients[].liveAtEnd]    | add),
       connFailed:   ([$clients[].connFailed]   | add),
       connRejected: ([$clients[].connRejected] | add),
       droppedDuringHold: ([$clients[].droppedDuringHold] | add),
       framesPerSec: ([$clients[].framesPerSec] | add),
       mbitPerSec:   ([$clients[].mbitPerSec]   | add),
       deliveryRatio: ([$clients[] | .deliveryRatio // 0] | add / length),
       latencyMillis: { p50:  ([$clients[].latencyMillis.p50  // 0] | max),
                        p99:  ([$clients[].latencyMillis.p99  // 0] | max),
                        p999: ([$clients[].latencyMillis.p999 // 0] | max),
                        max:  ([$clients[].latencyMillis.max  // 0] | max) },
       errors: ([$clients[].errors] | add)
     },
     server: $server[0]
   }' > "$OUT/summary.json"

echo "==> $OUT/summary.json"
jq '{label, mode, requestedConns,
     established: .client.established, live: .client.liveAtEnd,
     failed: .client.connFailed, rejected: .client.connRejected, droppedInHold: .client.droppedDuringHold,
     deliveryRatio: (.client.deliveryRatio | .*1000 | round / 1000),
     framesPerSec: (.client.framesPerSec | round), mbitPerSec: (.client.mbitPerSec | .*10 | round / 10),
     p99ms: .client.latencyMillis.p99,
     rssMb: (.server.rssMb // null), heapLiveMb: (.server.heapLiveMb // null),
     serverLive: (.server.liveSessions // null), slowClosed: (.server.slowConsumerClosed // null),
     fanOutMaxMs: (.server.fanOutMaxMillis // null), gcCount: (.server.gcCount // null)}' "$OUT/summary.json"

# ⚠ PRINTED EVERY RUN, because a saturated client invalidates the run and it is invisible in the
# server's own numbers. The server can look comfortable at 335% of 400% while the load generator is
# pinned at 190% of 200% and is the thing actually setting the ceiling.
echo "--- peak container CPU (a client near its own limit INVALIDATES the run) ---"
awk '{for(i=2;i<=NF;i++) print $i}' "$OUT/docker-stats.log" 2>/dev/null \
  | awk -F'=' '/=/ {gsub(/%/,"",$2); if($2+0>m[$1]) m[$1]=$2+0}
               END {for(k in m) printf "  %-22s %6.0f%% of %d00%%\n", k, m[k], (k ~ /server/ ? 4 : 1)}' | sort
