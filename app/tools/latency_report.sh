#!/bin/bash
# Summarize Murmur's per-stage dictation timing from the unified log.
# Usage: app/tools/latency_report.sh [window]   (default 24h, e.g. 2h, 7d)
# Prints count, p50, p95 and max seconds for each `took=` stage. Logs hold numbers and enum names only.
set -euo pipefail
window="${1:-24h}"
log show --last "$window" --style compact \
  --predicate 'subsystem == "cc.clouddev.dictation" AND category == "timing"' |
awk '
  match($0, / (cloud-transcribe|cleanup|insert|warm-runner|dictation) /) {
    stage = substr($0, RSTART + 1, RLENGTH - 2)
    if (match($0, /took=[0-9.]+/)) print stage, substr($0, RSTART + 5, RLENGTH - 5)
  }' |
sort -k1,1 -k2,2g |
awk '
  { count[$1]++; value[$1, count[$1]] = $2; if ($2 > max[$1]) max[$1] = $2 }
  END {
    printf "%-16s %6s %8s %8s %8s\n", "stage", "count", "p50", "p95", "max"
    n = split("cloud-transcribe cleanup insert warm-runner dictation", order, " ")
    for (i = 1; i <= n; i++) {
      s = order[i]
      if (!count[s]) { printf "%-16s %6d %8s %8s %8s\n", s, 0, "-", "-", "-"; continue }
      p50 = value[s, int((count[s] + 1) / 2)]
      p95 = value[s, int((count[s] * 95 + 99) / 100)]
      printf "%-16s %6d %8.3f %8.3f %8.3f\n", s, count[s], p50, p95, max[s]
    }
  }'
