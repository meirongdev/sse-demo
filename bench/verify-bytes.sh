#!/usr/bin/env bash
# Why did ENCODE=bytes change nothing?
#
# heapLive measures the LIVE SET; the allocation hotspots JFR found are garbage and never appear in it.
# Using it to test an allocation hypothesis was the wrong instrument. This profiles the bytes path and
# diffs its allocation top-frames against the text profile already captured, which is the instrument
# that can actually answer it — and can distinguish "the optimisation did nothing" from "it removed
# String.encodeUTF8 but the MediaType path it does not touch is the larger half".
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_LABEL=sse-bytes-20000 MODE=sse CONNS=20000 CLIENTS=1 RECORD=60 \
  EXTRA_ENV="-e ENCODE=bytes" "$HERE/profile.sh"
