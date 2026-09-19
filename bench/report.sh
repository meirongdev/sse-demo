#!/usr/bin/env bash
# Every summary.json in results/, as one table.
set -euo pipefail
ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"

printf '%-24s %-5s %8s %8s %8s %7s %7s %9s %8s %9s %8s\n' \
  LABEL MODE ASKED ESTAB LIVE REJ DROP DELIVERY P99ms RSS_MB KB/CONN
printf '%.0s-' {1..120}; echo

for f in $(ls -d "$ROOT"/results/*/summary.json 2>/dev/null | sort); do
  d="$(dirname "$f")"
  # The server block comes from the sample series, through the same rule run.sh and collect.py use.
  # summary.json's own `.server` field is whatever the extractor believed at the time and is
  # deliberately not backfilled — for the old runs that includes teardown samples this rule now
  # rejects (METHODOLOGY.md 缺陷 6), which is a 2 KB/connection row in this table.
  if [ -f "$d/server-samples.jsonl" ]; then
    srv="$(python3 "$ROOT/bench/final_sample.py" < "$d/server-samples.jsonl" 2>/dev/null || echo '{}')"
  else
    srv='{}'
  fi
  # ⚠ The row is built before it is printed, and a failure is reported instead of ending the table.
  # Under `set -euo pipefail` a single jq error used to abort the whole loop with its stderr sent to
  # /dev/null: the run that broke printed nothing, and so did every run after it in sort order. That
  # is how the `n(k)` bug below stayed invisible — the table quietly stopped at 58 of 64 runs, and
  # the missing six were a complete WS ladder. A table that cannot show a row must say so.
  if ! row="$(jq -r --argjson srv "$srv" '
    def n(x): if x == null then 0 else x end;
    def S(k): if ($srv | has(k)) then $srv[k] else n(.server[k]) end;
    [ .label, .mode, .requestedConns,
      n(.client.established), n(.client.liveAtEnd),
      n(.client.connRejected), n(.client.droppedDuringHold),
      (n(.client.deliveryRatio) * 1000 | round / 1000),
      n(.client.latencyMillis.p99),
      (n(S("rssMb")) | round),
      (if n(.client.liveAtEnd) > 0 then (n(S("rssMb")) * 1024 / .client.liveAtEnd * 10 | round / 10) else 0 end)
    ] | @tsv' "$f" 2>&1)"; then
    printf '%-24s ROW FAILED: %s\n' "$(basename "$d")" "$(printf '%s' "$row" | tr '\n' ' ')"
    continue
  fi
  printf '%s\n' "$row" \
  | awk -F'\t' '{printf "%-24s %-5s %8s %8s %8s %7s %7s %9s %8s %9s %8s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}'
done

echo
echo "KB/CONN is whole-process RSS divided by live connections, so it is NOT a per-connection cost."
echo "The amortised term is the COMMITTED HEAP, which G1 grows with load — 2268 MB at 10,000"
echo "connections and 5736 MB from 40,000 up, not the ~290 MB idle baseline this note used to claim."
echo "So there is no single constant to subtract: at 10,000 the committed heap is already 8x the idle"
echo "figure. For a real per-connection cost use the SLOPE between two tiers, or heapLive minus the"
echo "stack baseline in METHODOLOGY section 2."
