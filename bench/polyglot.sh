#!/usr/bin/env bash
# The same SSE server in Java, Go and Rust, on the same 4 vCPU / 8 GB, driven by the same client.
#
# ⚠ THE ONLY FIGURE THAT COMPARES ACROSS RUNTIMES IS RSS.
# A JVM live set, a Go HeapAlloc and a Rust allocator arena are three different things; the kernel's
# resident set is the one number all three mean the same way. Each server's empty baseline is measured
# separately and subtracted — the JVM's is ~290 MB and a static Rust binary's is a few MB, so using one
# intercept for all of them would be worth more than the effect being measured.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${N:-20000}"

baseline() { # image -> empty RSS
  docker rm -f pgbase >/dev/null 2>&1 || true
  docker run -d --name pgbase --network ssebench --cpus 4 --memory 8g "$1" >/dev/null
  local ip; ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pgbase)
  for _ in $(seq 1 40); do
    docker run --rm --network ssebench alpine:3.21 wget -qO- "http://$ip:9090/actuator/health" 2>/dev/null | grep -q UP && break
    sleep 2
  done
  sleep 5
  docker run --rm --network ssebench alpine:3.21 wget -qO- "http://$ip:9090/actuator/bench" 2>/dev/null \
    | sed -n 's/.*"rssMb":\([0-9.]*\).*/\1/p'
  docker rm -f pgbase >/dev/null 2>&1 || true
}

declare -A BASE
for entry in "go:ssebench-go" "rust:ssebench-rust"; do
  name="${entry%%:*}"; img="${entry##*:}"
  b=$(baseline "$img"); BASE[$name]=$b
  echo "#### $name 空载 RSS = ${b} MB"
done

for entry in "go:ssebench-go" "rust:ssebench-rust"; do
  name="${entry%%:*}"; img="${entry##*:}"
  echo "#### $name SSE @ $N"
  MODE=sse CONNS=$N CLIENTS=1 RATE=4000 HOLD=90s SERVER_IMAGE=$img \
    LABEL="p14-$name-sse" "$HERE/run.sh" || true
done

printf '\n%-18s %9s %10s %11s %10s\n' RUN ESTAB P99ms RSS 每连接RSS
for entry in "go:ssebench-go" "rust:ssebench-rust"; do
  name="${entry%%:*}"
  d=$(ls -d "$HERE"/../results/*p14-$name-sse 2>/dev/null | tail -1); s=$d/summary.json
  [ -f "$s" ] || continue
  jq -r --argjson b "${BASE[$name]}" '[.label,.client.established,.client.latencyMillis.p99,
        (.server.rssMb|round), (((.server.rssMb-$b)*1024/.client.liveAtEnd)|floor)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-18s %9s %10s %9sMB %9sKB\n",$1,$2,$3,$4,$5}'
done
echo POLYDONE
