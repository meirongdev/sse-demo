#!/usr/bin/env bash
# How many users, one connection each, on 4 vCPU / 8 GB — measured, not extrapolated.
#
# ⚠ Extrapolating from a single point would be wrong here and the earlier runs prove it: the failure is
# a THRESHOLD effect (fan-out time crossing the tick interval), not a gentle degradation. SSE on Tomcat
# went from p99 328 ms at 20,000 to 6291 ms at 40,000. A ladder is the only honest answer.
#
# Pass = all four criteria: established ≥99%, ~0 dropped in hold, deliveryRatio ≥0.99, p99 <1000ms.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LADDER="${LADDER:-40000 60000 80000 100000}"
PER_CLIENT=20000

for entry in "${@}"; do
  name="${entry%%:*}"; img="${entry##*:}"
  echo "############ $name"
  for n in $LADDER; do
    c=$(( (n + PER_CLIENT - 1) / PER_CLIENT ))
    echo "#### $name @ $n across $c client(s)"
    MODE=sse CONNS=$n CLIENTS=$c RATE=4000 HOLD=90s SERVER_IMAGE=$img \
      MAX_CONNECTIONS=200000 LABEL="p15-$name-$n" "$HERE/run.sh" || { echo ">>>> $name $n : RUN FAILED"; break; }
    last=$(ls -dt "$HERE"/../results/*p15-$name-$n 2>/dev/null | head -1)
    [ -f "$last/summary.json" ] || { echo ">>>> $name $n : NO SUMMARY"; break; }
    ok=$(jq -r '((.client.established >= (.requestedConns*0.99))
                 and (.client.deliveryRatio >= 0.99)
                 and ((.client.droppedDuringHold // 0) <= (.requestedConns*0.01))
                 and (.client.latencyMillis.p99 < 1000))' "$last/summary.json")
    echo ">>>> $name $n : $ok"
    [ "$ok" = "true" ] || break
  done
done

printf '\n%-22s %9s %10s %11s %9s %s\n' RUN 建连 P99ms RSS 每连接 判定
for d in $(ls -d "$HERE"/../results/*p15-* 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  jq -r '[.label,.client.established,.client.latencyMillis.p99,(.server.rssMb//0|round),
          (if .client.liveAtEnd>0 then ((.server.rssMb//0)*1024/.client.liveAtEnd|floor) else 0 end),
          (if ((.client.established >= (.requestedConns*0.99)) and (.client.deliveryRatio >= 0.99)
               and (.client.latencyMillis.p99 < 1000)) then "PASS" else "FAIL" end)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-22s %9s %10s %9sMB %7sKB  %s\n",$1,$2,$3,$4,$5,$6}'
done
echo CEILINGDONE
