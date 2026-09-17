#!/usr/bin/env bash
# Addendum to the sweep: what the buffer Spring cannot reach is worth.
#
# The tuned profile in phase 2 sets maxText/maxBinaryMessageBufferSize to 1024 and stops there,
# because those are the only two knobs Spring exposes. WsFrameBase allocates a THIRD buffer —
# inputBuffer, 8192 bytes — from a system property. Three runs at one fixed connection count
# isolate each layer, and the SSE run is the floor the WebSocket side is being measured against.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONNS="${CONNS:-20000}"
HOLD="${HOLD:-90s}"
COMMON="MAX_CONNECTIONS=200000 CONNS=$CONNS CLIENTS=1 RATE=4000 HOLD=$HOLD"

echo "#### a — WS, Tomcat defaults everywhere (~33 KB/conn of buffer)"
env $COMMON MODE=ws WS_TEXT_BUFFER=8192 WS_BINARY_BUFFER=8192 \
  LABEL="p4a-ws-buf-default" "$HERE/run.sh" || true

echo "#### b — WS, both Spring knobs at 1 KB (inputBuffer still 8 KB)"
env $COMMON MODE=ws WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
  LABEL="p4b-ws-buf-spring" "$HERE/run.sh" || true

echo "#### c — WS, Spring knobs AND the system property (~3 KB/conn of buffer)"
env $COMMON MODE=ws WS_TEXT_BUFFER=1024 WS_BINARY_BUFFER=1024 \
  EXTRA_JAVA_OPTS="-Dorg.apache.tomcat.websocket.DEFAULT_BUFFER_SIZE=2048" \
  LABEL="p4c-ws-buf-all" "$HERE/run.sh" || true

echo "#### d — SSE at the same count, as the floor to compare against"
env $COMMON MODE=sse LABEL="p4d-sse-baseline" "$HERE/run.sh" || true

"$HERE/report.sh"
