#!/usr/bin/env bash
# Every summary.json in results/, as one table.
set -euo pipefail
ROOT="$(dirname "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")"

printf '%-24s %-5s %8s %8s %8s %7s %7s %9s %8s %9s %8s\n' \
  LABEL MODE ASKED ESTAB LIVE REJ DROP DELIVERY P99ms RSS_MB KB/CONN
printf '%.0s-' {1..120}; echo

for f in $(ls -d "$ROOT"/results/*/summary.json 2>/dev/null | sort); do
  jq -r '
    def n(x): if x == null then 0 else x end;
    [ .label, .mode, .requestedConns,
      n(.client.established), n(.client.liveAtEnd),
      n(.client.connRejected), n(.client.droppedDuringHold),
      (n(.client.deliveryRatio) * 1000 | round / 1000),
      n(.client.latencyMillis.p99),
      (n(.server.rssMb) | round),
      (if n(.client.liveAtEnd) > 0 then (n(.server.rssMb) * 1024 / .client.liveAtEnd * 10 | round / 10) else 0 end)
    ] | @tsv' "$f" 2>/dev/null \
  | awk -F'\t' '{printf "%-24s %-5s %8s %8s %8s %7s %7s %9s %8s %9s %8s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}'
done

echo
echo "KB/CONN is whole-process RSS divided by live connections, so it carries the JVM's own ~290 MB"
echo "baseline. Subtract that baseline before quoting a per-connection cost — at 10,000 connections"
echo "it is 30 KB of the figure, and at 1,000 it is 290."
