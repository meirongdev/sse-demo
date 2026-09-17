#!/usr/bin/env bash
# Spring MVC on Jetty — the run that separates "the servlet model" from "Tomcat's implementation of it".
#
# §10 changed two things at once: servlet → reactive AND Tomcat → Netty, so its 4.5x cannot be attributed.
# This changes ONE: the same Java, the same Spring MVC, a different servlet container.
#
#   Jetty ≈ Tomcat  → the cost is the SERVLET MODEL (an async request must keep Request/Response alive),
#                     and only leaving the servlet model helps.
#   Jetty << Tomcat → the cost was TOMCAT'S IMPLEMENTATION, and a container swap is enough.
#
# ⚠ This build has no container tuning (TomcatTuning is Tomcat-only and is excluded), so the comparison
# is against the Tomcat UNTUNED baseline — both stacks at their own defaults.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${N:-20000}"
for m in sse ws; do
  echo "#### Jetty — $m @ $N"
  MODE=$m CONNS=$N CLIENTS=1 RATE=4000 HOLD=90s SERVER_IMAGE=ssebench-jetty \
    MAX_CONNECTIONS=200000 LABEL="p13-jetty-$m" "$HERE/run.sh" || true
done
printf '\n%-20s %9s %10s %10s %10s\n' RUN ESTAB P99ms HEAPLIVE 每连接
for d in $(ls -d "$HERE"/../results/*p13-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  jq -r '[.label,.client.established,.client.latencyMillis.p99,(.server.heapLiveMb|round),
          (if .client.liveAtEnd>0 then (((.server.heapLiveMb-74)*1024/.client.liveAtEnd)|floor) else 0 end)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-20s %9s %10s %8sMB %7sKB\n",$1,$2,$3,$4,$5}'
done
