# Integration handoff

## Current checkpoint — October 2, 2026

Integration lead: this chat. Three implementation workers own shortcut handling, insertion, and observation respectively. The first deliverable is PRD milestone 0: a standalone feasibility spike, without an application skeleton. [Certain]

Owned files: lead owns `spike/main.swift`, build instructions, feasibility report, and this handoff; workers own `spike/Shortcut*.swift`, `spike/Insertion.swift`, and `spike/Observation.swift`. [Certain]

The host is a MacBook Air Mac15,12, Apple M3, 16 GB, macOS 26.6.2 (25G83), Swift 6.3.3. It is a newer-device candidate, not the required M1/8 GB baseline. [Certain]

## Integration decisions

- Use a directly compiled Swift command-line harness and native frameworks; no external runtime, downloaded model, app skeleton, or production interface yet. [Certain]
- Default execution runs deterministic checks; cross-app inspection, insertion, shortcut listening, and correction observation require explicit command-line modes. [Certain]
- Live permission grants require human setup per the PRD. Failed preflight is recorded as pending setup, never as an unsupported application. [Certain]
- Keep arbitrary field contents out of diagnostics. The observation spike exercises attribution; heuristic candidates are not proof that a replacement preserves meaning. [Certain]
- Resolve the PRD's cleanup conflict before production processing: section 3 says preserve raw text for recovery on cleanup failure, while section 4 says insert raw text on guard failure. Neither policy is implemented in this spike. [Certain]

## Next gates

Run checks and build the integrated spike, then complete real keyboard and five-category app tests. Record versions and synthetic test results in `spike/FEASIBILITY.md`. Do not claim go until at least one category passes automatic observation and shortcut/insertion safety checks have live evidence. Model validation remains a separate M1/8 GB gate. [Certain]

## Completed handoff

All three workers handed off their owned Swift files. The lead compiled the integrated harness and ran `spike/.build/dictation-spike --check` successfully after fixing a surrogate-boundary assertion failure. Read-only focus inspection had no accessible field; no live insertion or keyboard coverage is claimed. [Certain]

Runnable inputs/outputs and safety limits are documented in `spike/README.md`; current acceptance evidence is in `spike/FEASIBILITY.md`. Next session should begin with the live synthetic-field matrix, not an app skeleton or model download. [Certain]
