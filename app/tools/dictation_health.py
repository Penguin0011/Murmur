#!/usr/bin/env python3
"""Content-free dictation health report from local History metadata and Murmur's unified log.

Prints counts only: never rawText, finalText, rejected output or log message bodies.
Usage: python3 -I app/tools/dictation_health.py [--hours 24] [--json] [--self-check]
Exit status 1 when a regression flag is raised, so a scheduler can surface it.
"""
import collections
import json
import os
import re
import subprocess
import sys
import time

HISTORY = os.path.expanduser("~/Library/Application Support/Dictation/history")
APPLE_EPOCH = 978307200  # Swift Date's reference date, in Unix seconds.
# Thresholds from CLEANUP_BENCHMARK.md (October 22, 2026) and History before it; see that file.
MIN_DICTATIONS = 10
MAX_FALLBACK_RATE = 0.15     # Trust on: the guard is bypassed, so fallbacks mean provider failure or the judge.
MAX_CLEANER_FAILED_RATE = 0.05
MAX_NO_SPEECH_RATE = 0.10
MAX_INSERT_FAILED_RATE = 0.05
LOG_PATTERNS = {
    "noSpeechAllUnsure": re.compile(r"transcript-tail all \d+ segments below logprob .*: no speech"),
    "tailSegmentDropped": re.compile(r"transcript-tail segment=.* dropped=true"),
    "cleanupFallback": re.compile(r"cleanup-fallback entry="),
    "cleanupHeld": re.compile(r"cleanup-held reason="),
    "cleanupFailover": re.compile(r"cleanup-failover "),
}
REASON = re.compile(r"cleanup-(?:fallback|held) .*?reason=(\w+)")


def history(hours, directory=HISTORY, now=None):
    cutoff = (now or time.time()) - hours * 3600 - APPLE_EPOCH
    rows = []
    for name in os.listdir(directory) if os.path.isdir(directory) else []:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, name)) as f:
                entry = json.load(f)
        except (OSError, ValueError):
            continue
        if entry.get("recordedAt", 0) >= cutoff:
            # Keep metadata only; text fields are dropped here and never leave this function.
            rows.append({k: entry.get(k) for k in ("cleanupOutcome", "cleanupFallback", "insertionStatus", "appVersion", "contextUsed")})
    return rows


def log_counts(hours, lines=None):
    if lines is None:
        out = subprocess.run(["log", "show", "--last", f"{hours}h", "--style", "compact", "--predicate",
                              'subsystem == "cc.clouddev.dictation"'], capture_output=True, text=True).stdout
        lines = out.splitlines()
    counts, reasons, errors = collections.Counter(), collections.Counter(), 0
    for line in lines:
        for key, pattern in LOG_PATTERNS.items():
            if pattern.search(line):
                counts[key] += 1
        m = REASON.search(line)
        if m:
            reasons[m.group(1)] += 1
        # Compact style marks the level in the third column: E = error, F = fault.
        if re.match(r"\S+ \S+\s+[EF]\s", line):
            errors += 1
    return dict(counts), dict(reasons), errors


def report(rows, logs):
    counts, reasons, errors = logs
    total = len(rows)
    outcome = collections.Counter(str(r["cleanupOutcome"]) for r in rows)
    fallback = collections.Counter(str(r["cleanupFallback"]) for r in rows if r["cleanupFallback"])
    insertion = collections.Counter(str(r["insertionStatus"]) for r in rows)
    # Rates use only entries from builds that record provenance (cleanupOutcome), with cleanup on.
    tracked = [r for r in rows if r["cleanupOutcome"] not in (None, "off")]
    cleaned = len(tracked)
    fb = sum(1 for r in tracked if r["cleanupFallback"])
    fallback_tracked = collections.Counter(str(r["cleanupFallback"]) for r in tracked if r["cleanupFallback"])
    no_speech = counts.get("noSpeechAllUnsure", 0)
    flags = []
    if cleaned >= MIN_DICTATIONS:
        if fb / cleaned > MAX_FALLBACK_RATE:
            flags.append(f"cleanup fallback rate {fb}/{cleaned} above {MAX_FALLBACK_RATE:.0%}")
        if fallback_tracked.get("cleanerFailed", 0) / cleaned > MAX_CLEANER_FAILED_RATE:
            flags.append(f"cleanerFailed {fallback_tracked['cleanerFailed']}/{cleaned} above {MAX_CLEANER_FAILED_RATE:.0%}")
    if total >= MIN_DICTATIONS:
        if no_speech / (total + no_speech) > MAX_NO_SPEECH_RATE:
            flags.append(f"no-speech results {no_speech} vs {total} dictations above {MAX_NO_SPEECH_RATE:.0%}")
        if insertion.get("failed", 0) / total > MAX_INSERT_FAILED_RATE:
            flags.append(f"insertion failed {insertion['failed']}/{total} above {MAX_INSERT_FAILED_RATE:.0%}")
    if errors:
        flags.append(f"{errors} error/fault log lines")
    return {"dictations": total, "cleanupOutcome": dict(outcome), "cleanupFallback": dict(fallback),
            "insertionStatus": dict(insertion), "appVersion": dict(collections.Counter(str(r["appVersion"]) for r in rows)),
            "contextUsed": sum(1 for r in rows if r["contextUsed"]), "log": counts, "logReasons": reasons,
            "logErrors": errors, "flags": flags}


def self_check():
    rows = [{"cleanupOutcome": "modelAccepted", "cleanupFallback": None, "insertionStatus": "verified", "appVersion": "x", "contextUsed": True}] * 9
    rows += [{"cleanupOutcome": "localRules", "cleanupFallback": "cleanerFailed", "insertionStatus": "failed", "appVersion": "x", "contextUsed": False}] * 3
    logs = log_counts(0, lines=[
        "2026-10-22 10:00:00.000 Df Murmur[1:2] [cc.clouddev.dictation:timing] transcript-tail all 2 segments below logprob -1.0: no speech",
        "2026-10-22 10:00:01.000 Df Murmur[1:2] [cc.clouddev.dictation:timing] transcript-tail segment=2/2 no_speech=0.9 logprob=-1.2 dropped=true",
        "2026-10-22 10:00:02.000 Df Murmur[1:2] [cc.clouddev.dictation:timing] cleanup-fallback entry=A reason=cleanerFailed provider-error=timeout",
        "2026-10-22 10:00:03.000 E  Murmur[1:2] [cc.clouddev.dictation:timing] something failed"])
    assert logs[0] == {"noSpeechAllUnsure": 1, "tailSegmentDropped": 1, "cleanupFallback": 1}, logs
    assert logs[1] == {"cleanerFailed": 1} and logs[2] == 1, logs
    r = report(rows, logs)
    assert r["dictations"] == 12 and r["cleanupFallback"] == {"cleanerFailed": 3}
    assert any("fallback rate" in f for f in r["flags"]) and any("insertion failed" in f for f in r["flags"])
    assert not report(rows[:9], ({}, {}, 0))["flags"]
    assert "rawText" not in json.dumps(r) and "finalText" not in json.dumps(r)
    print("self-check passed")


def main(argv):
    if "--self-check" in argv:
        return self_check()
    hours = int(argv[argv.index("--hours") + 1]) if "--hours" in argv else 24
    r = report(history(hours), log_counts(hours))
    if "--json" in argv:
        print(json.dumps(r, indent=1, sort_keys=True))
    else:
        print(f"Murmur health, last {hours}h: {r['dictations']} dictations, outcomes {r['cleanupOutcome']}, "
              f"fallbacks {r['cleanupFallback'] or 'none'}, insertion {r['insertionStatus']}, "
              f"no-speech {r['log'].get('noSpeechAllUnsure', 0)}, tail drops {r['log'].get('tailSegmentDropped', 0)}, "
              f"log errors {r['logErrors']}")
        print("REGRESSION: " + "; ".join(r["flags"]) if r["flags"] else "OK: no regression flags")
    return 1 if r["flags"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
