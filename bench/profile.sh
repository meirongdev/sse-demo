#!/usr/bin/env bash
# Where does a connection's cost actually go? Measured, not inferred from reading Tomcat's source.
#
# Three instruments, each answering a different question:
#   GC.class_histogram   — WHICH OBJECTS hold the heap. Taken empty and loaded, then differenced, so what
#                          is left is per-connection and not the JVM's own furniture.
#   VM.native_memory     — where the memory that is NOT heap goes. RSS minus heap has to live somewhere.
#   JFR (settings=profile) — where the CPU goes, and what allocates. Started at steady state, so the ramp's
#                          connection-establishment cost does not drown out the 1 Hz push being profiled.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

MODE="${MODE:-sse}"
CONNS="${CONNS:-20000}"
CLIENTS="${CLIENTS:-1}"
RATE="${RATE:-4000}"
RECORD="${RECORD:-60}"
# ⚠ The SAME lock run.sh takes, and for a different reason than container names: profiling pins a
# server and a client on the same 10-vCPU machine a benchmark run would be using. The two do not share
# container names, so nothing would visibly break — both measurements would simply be wrong, which is
# worse. Held until the EXIT trap fires; see bench/benchlock.sh.
# shellcheck source=benchlock.sh
. "$HERE/benchlock.sh"
bench_lock_acquire || exit 3

NET=ssebench
SRV=sseprof-server
# ⚠ PROFILE_LABEL exists because this line used to be fixed at profile-$MODE-$CONNS and the script
# starts with `rm -rf "$OUT"` — profiling the same mode twice with different settings would silently
# delete the first profile, which is exactly the baseline the second one has to be compared against.
OUT="$ROOT/results/profile-${PROFILE_LABEL:-$MODE-$CONNS}"
rm -rf "$OUT"; mkdir -p "$OUT"

cleanup() {
  docker rm -f "$SRV" >/dev/null 2>&1 || true
  for i in $(seq 1 "$CLIENTS"); do docker rm -f "sseprof-client-$i" >/dev/null 2>&1 || true; done
}
trap 'cleanup; bench_lock_release' EXIT
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
cleanup

echo "==> $MODE @ $CONNS, profiling image (JDK + NMT + JFR)"
docker run -d --name "$SRV" --network "$NET" --cpus 4 --memory 8g \
  --ulimit nofile=1048576:1048576 --sysctl net.core.somaxconn=65535 \
  -e MAX_CONNECTIONS=200000 -e WS_TEXT_BUFFER=1024 -e WS_BINARY_BUFFER=1024 \
  ${EXTRA_ENV:-} \
  ssebench-server-prof >/dev/null
IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SRV")
until docker run --rm --network "$NET" alpine:3.21 wget -qO- "http://$IP:9090/actuator/health" 2>/dev/null | grep -q UP; do sleep 2; done

# Baseline, with nothing connected. GC.class_histogram runs a full GC first, so both snapshots are
# live-object counts and the difference is what the connections brought.
echo "==> baseline snapshots (0 connections)"
docker exec "$SRV" jcmd 1 GC.class_histogram > "$OUT/histogram-empty.txt" 2>&1
docker exec "$SRV" jcmd 1 VM.native_memory summary > "$OUT/nmt-empty.txt" 2>&1

PER=$((CONNS / CLIENTS))
for i in $(seq 1 "$CLIENTS"); do
  docker run -d --name "sseprof-client-$i" --network "$NET" \
    --ulimit nofile=1048576:1048576 --sysctl net.ipv4.ip_local_port_range="10000 65535" \
    --cpus "${CLIENT_CPUS:-1}" --memory "${CLIENT_MEM:-2g}" ssebench-loadgen \
    -target "$IP:8080" -mode "$MODE" -conns "$PER" -rate $((RATE / CLIENTS)) \
    -hold $((RECORD + 120))s -id "$i" >/dev/null
done

# ⚠ BOUNDED, and it checks the client is still alive.
#
# This loop used to be an unbounded `until liveSessions = CONNS`. When the load generator could not
# reach the full count — an h2 run whose client saturated — it finished its hold, exited, and left this
# script waiting for a number that could never arrive. It blocked the queue for twenty minutes and
# produced nothing. A wait on another process's success needs a deadline and a liveness check, or it is
# a hang with extra steps.
echo "==> waiting for $CONNS connections (deadline 180s)"
deadline=$(( $(date +%s) + 180 ))
while :; do
  n=$(docker run --rm --network "$NET" alpine:3.21 wget -qO- "http://$IP:9090/actuator/bench" 2>/dev/null \
      | sed -n 's/.*"liveSessions":\([0-9]*\).*/\1/p')
  [ "$n" = "$CONNS" ] && break
  if ! docker ps --format '{{.Names}}' | grep -q "sseprof-client-1"; then
    echo "!! client exited with only ${n:-0}/$CONNS connections up — profiling what is there" >&2
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "!! deadline reached at ${n:-0}/$CONNS connections — profiling what is there" >&2
    break
  fi
  sleep 3
done
echo "==> settling 20s before recording, so the ramp is not in the profile"
sleep 20

docker exec "$SRV" jcmd 1 JFR.start name=hold settings=profile duration=${RECORD}s filename=/tmp/hold.jfr >/dev/null
echo "==> recording ${RECORD}s of steady-state push"
sleep $((RECORD + 8))

docker exec "$SRV" jcmd 1 GC.class_histogram > "$OUT/histogram-loaded.txt" 2>&1
docker exec "$SRV" jcmd 1 VM.native_memory summary > "$OUT/nmt-loaded.txt" 2>&1
docker exec "$SRV" jcmd 1 JFR.dump name=hold filename=/tmp/hold.jfr >/dev/null 2>&1 || true
docker cp "$SRV:/tmp/hold.jfr" "$OUT/hold.jfr" >/dev/null 2>&1 || echo "(no jfr)"
docker run --rm --network "$NET" alpine:3.21 wget -qO- "http://$IP:9090/actuator/bench" 2>/dev/null > "$OUT/bench.json"

echo "==> $OUT"
