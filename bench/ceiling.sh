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
# SSE unless asked otherwise: MODE=ws runs the identical ladder over WebSocket. The label has to
# carry the transport because the SSE runs are already on disk as p15-<name>-<n>, and a WS run
# reusing that name would make the verdict lookup below pick whichever directory is newest —
# judging a WebSocket tier off an SSE sample.
MODE="${MODE:-sse}"

# One copy of the pass rule, used by both the per-tier verdict and the summary table. They had
# drifted: the table checked three of the four criteria, so a tier could print `true` on the ladder
# and `FAIL` in the table below it.
PASS='(.client.established >= (.requestedConns*0.99)) and (.client.deliveryRatio >= 0.99) and ((.client.droppedDuringHold // 0) <= (.requestedConns*0.01)) and (.client.latencyMillis.p99 < 1000)'

for entry in "${@}"; do
  name="${entry%%:*}"; img="${entry##*:}"
  echo "############ $name"
  for n in $LADDER; do
    c=$(( (n + PER_CLIENT - 1) / PER_CLIENT ))
    if [ "$MODE" = "ws" ]; then tag="-ws"; else tag=""; fi
    echo "#### $name $MODE @ $n across $c client(s)"
    MODE="$MODE" CONNS=$n CLIENTS=$c RATE=4000 HOLD=90s SERVER_IMAGE=$img \
      MAX_CONNECTIONS=200000 LABEL="p15-$name$tag-$n" "$HERE/run.sh" || { echo ">>>> $name $n : RUN FAILED"; break; }
    last=$(ls -dt "$HERE"/../results/*p15-$name$tag-$n 2>/dev/null | head -1)
    [ -f "$last/summary.json" ] || { echo ">>>> $name $n : NO SUMMARY"; break; }
    # ⚠ A bare `true|false` cannot tell "the server hit a wall" from "the server has no endpoint", and
    # this ladder printed `false` for rust/go ws @ 40,000 — which reads as "ceiling below 40,000" and is
    # really a 404 that accepted zero connections (METHODOLOGY.md 缺陷 8). A capacity failure arrives
    # with established ≈ requested; a functional failure arrives with established = 0. Print the
    # numbers that separate them on every line, so the verdict is never the only thing there.
    # `|` is jq's LOWEST-precedence operator, so `[(PRED)|tostring, .client.x]` pipes the boolean into
    # every later element too and dies with "Cannot index boolean with string client" — which, under
    # set -e and with read() at EOF, used to end the ladder with no message at all. Each element that
    # carries a pipe is parenthesised on its own, and a failed read is now reported instead of silent.
    if ! IFS=$'\t' read -r ok est req rej drop p99 < <(jq -r \
      '[(('"$PASS"')|tostring), .client.established, .requestedConns, (.client.connRejected // 0),
        (.client.droppedDuringHold // 0), (.client.latencyMillis.p99 | round)] | @tsv' "$last/summary.json"); then
      echo ">>>> $name $n : VERDICT FAILED — 读不出 $last/summary.json"
      break
    fi
    if [ "$est" = "0" ]; then
      echo ">>>> $name $n : NO CONNECTIONS 建连 0/$req rejected=$rej — 服务端没有 /$MODE/stream？这是功能缺失，不是容量结论"
      break
    fi
    if [ "$ok" = "true" ]; then verdict=PASS; else verdict=FAIL; fi
    echo ">>>> $name $n : $verdict 建连=$est/$req rejected=$rej droppedInHold=$drop p99=${p99}ms"
    [ "$verdict" = "PASS" ] || break
  done
done

if [ "$MODE" = "ws" ]; then PAT='*p15-*-ws-*'; else PAT='*p15-*'; fi
printf '\n%-22s %9s %10s %11s %9s %s\n' RUN 建连 P99ms RSS 每连接 判定
for d in $(ls -d "$HERE"/../results/$PAT 2>/dev/null | sort); do
  s=$d/summary.json; [ -f "$s" ] || continue
  # ⚠ The RSS column used to come from summary.json's `.server` — the field run.sh filled from whatever
  # sample it selected at the time, which for 16 of these runs is the one the teardown left behind
  # (rust @ 100,000 printed 229 MB / 2 KB here, the exact number 缺陷 6 was written about). verdict is
  # unaffected — it never looked at RSS — but every number in this table is read out loud, so it goes
  # through the same rule collect.py and report.sh use, with the recorded field only as a fallback.
  srv="$(python3 "$HERE/final_sample.py" < "$d/server-samples.jsonl" 2>/dev/null || echo '{}')"
  [ -n "$srv" ] || srv='{}'
  jq -r --argjson srv "$srv" '[.label,.client.established,.client.latencyMillis.p99,
          (($srv.rssMb // .server.rssMb // 0)|round),
          (if .client.liveAtEnd>0 then ((($srv.rssMb // .server.rssMb // 0))*1024/.client.liveAtEnd|floor) else 0 end),
          (if .client.established==0 then "NO-ENDPOINT" elif ('"$PASS"') then "PASS" else "FAIL" end)]|@tsv' "$s" \
    | awk -F'\t' '{printf "%-22s %9s %10s %9sMB %7sKB  %s\n",$1,$2,$3,$4,$5,$6}'
done
echo CEILINGDONE
