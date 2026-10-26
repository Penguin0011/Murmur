#!/bin/bash
# Summarize Murmur's per-stage dictation timing from the unified log.
# Usage: app/tools/latency_report.sh [window]   (default 24h, e.g. 2h, 7d)
# Prints count, p50, p95 and max seconds for each `took=` stage. Logs hold numbers and enum names only.
# tail-quiet: how much of the 0.4 s release tail was silent at its end (0.4 or more: all of it).
# release-to-transcribe: key release (the event, not when the main thread handled it) to transcription start,
# so the release tail. text-visible: insertion start to ⌘V posted or the first matching read-back. insert: the
# whole insertion call. dictation: release to text visible (0.2.3 and earlier: to the end of a 0.5 s wait after ⌘V).
set -euo pipefail
window="${1:-24h}"
log show --last "$window" --style compact \
  --predicate 'subsystem == "cc.clouddev.dictation" AND category == "timing" AND process == "Murmur"' |
awk '
  match($0, / (tail-quiet|release-to-transcribe|cloud-transcribe|cleanup|text-visible|insert|warm-runner|dictation) /) {
    stage = substr($0, RSTART + 1, RLENGTH - 2)
    if (match($0, /took=[0-9.]+/)) print stage, substr($0, RSTART + 5, RLENGTH - 5)
  }' |
sort -k1,1 -k2,2g |
awk '
  { count[$1]++; value[$1, count[$1]] = $2; if ($2 > max[$1]) max[$1] = $2 }
  END {
    printf "%-22s %6s %8s %8s %8s\n", "stage", "count", "p50", "p95", "max"
    n = split("tail-quiet release-to-transcribe cloud-transcribe cleanup text-visible insert warm-runner dictation", order, " ")
    for (i = 1; i <= n; i++) {
      s = order[i]
      if (!count[s]) { printf "%-22s %6d %8s %8s %8s\n", s, 0, "-", "-", "-"; continue }
      p50 = value[s, int((count[s] + 1) / 2)]
      p95 = value[s, int((count[s] * 95 + 99) / 100)]
      printf "%-22s %6d %8.3f %8.3f %8.3f\n", s, count[s], p50, p95, max[s]
    }
  }'
