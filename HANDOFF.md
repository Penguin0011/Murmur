# Connected local path checkpoint — October 2, 2026

Implemented shortcut → capture → local processor → durable text history. Release model runner build and pinned model checksum verification passed on the available M3. Synthetic injected-key microphone hold/cancel and synthetic speaker-to-microphone processing passed; all test audio was deleted. No insertion, physical-key first-word guarantee, or real speech quality claim is made. [Certain]

Build/run commands and precise results are in `module-one/session/README.md`. Model cache: `~/Library/Caches/Dictation/module-one/unified-d32e972`; speech/recovery/cache artifacts are excluded from Git. Recovery history uses the standalone app-support directory. Privacy, retention settings/UI, memory-only capture, and production insertion remain product work. [Certain]

Independent review found queued-action ordering, continuous retry-audio expiry, and processor signal/spawn gaps. All three findings are fixed: processor cancellation reaps its child, keyboard transition/action delivery is serialized with a queued failed-start regression, and a minute timer expires retry audio while the listener runs. Relevant synthetic checks pass. [Certain]

# Superseding hardware scope — October 2, 2026

M1/8 GB performance is no longer a development or release gate, per the user. Use the available M3/16 GB host for functional/inference validation, publish only measured results, and leave users model selection for their hardware. Earlier M1-gate references below are historical and superseded. Next implementation step remains wiring shortcut events into capture, then validating the local transcription path. [Certain]

# Current continuation — October 2, 2026

Work proceeds on `aakash-module-one`, fast-forwarded from the recorded feasibility continuation at `da78462`. The go/no-go report now permits milestone 1 validation and retains NO-GO for production/release. [Certain]

“Module one” is interpreted as PRD milestone 1: resolve decisions, prepare model benchmarks, and validate shortcut/capture/insertion/observation feasibility. No separately named module-one plan exists in the checkout. [Certain]

Current checks: Swift spike build, deterministic checks, ten CLI rejection cases, read-only Codex field inspection, bounded event-tap startup, capture build/synthetic storage checks, and synthetic benchmark scoring checks passed. Microphone permission reports authorized; no speech recording or model inference is claimed. Historical real-app evidence is preserved separately from current verification. [Certain]

Workers own `module-one/capture/`, `module-one/models/`, and `module-one/SAFETY_REVIEW.md`; the lead owns this handoff, PRD decisions, and `spike/FEASIBILITY.md`. Live microphone permission and M1 availability must be reported without requesting intervention or fabricating results. [Certain]

Model checkpoint: immutable runtime/model pins, file integrity verifier, scoring/resource/timeout harness, and a source-checked Swift adapter are committed. Python checks pass; the Swift dependency download was stopped before compilation completed, so the adapter build and all real inference remain unverified. No weights were downloaded. [Certain]

Capture checkpoint: native harness build, synthetic WAV/storage/expiry checks, read-only authorized microphone probe, and five invalid-argument checks passed. Capture is not yet wired into the shortcut state machine; memory-only capture and live speech/device checks remain open. [Certain]

---

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

## Live continuation

TextEdit 1.20 on the M3 host passed verified native AX insertion, observable spelling replacement, Undo evidence removal, and stop on unrelated cursor movement. The live test exposed caret anchoring and foreground capture bugs; both are fixed with integrated checks. [Certain]

Arc 1.166.0's local textarea exposed AXWebArea to native capture; AX write reported success but the visible textarea did not change. Unverified delivery correctly stopped without paste retry or learning. Browser enhanced accessibility remains a setup investigation, not an assumed fix. No settings or permission grants were changed. [Certain]

Bounded CGEventTap startup/teardown passed. User-operated Right Option hold-release and tap-stop passed a labeled live trace; Escape cancellation appeared in the earlier live trace. Fn, additional native observation cases, rich/chat/code-editor coverage, and the M1/8 GB baseline remain pending. `--insert-test` now requires `--expected-app` and malformed/mixed CLI modes are rejected before UI access, checked by `python3 spike/check_cli.py`. [Certain]

Independent review found and fixed a clipboard ownership gap. The paste fallback now requires its staged unique token and stable change count before paste/restoration; regression checks pass. AXWebArea/document roles are rejected for insertion and learning, even if a native API reports readable value/selection. [Certain]

Safari 26.6.2 + Google Docs: default setup exposes no focused AX element. With Docs screen reader support enabled, AX write delivered (user-observed) but stays harness-unverified and learning-ineligible as an unknown browser field. The user requires no screen-reader setup, so this route is unsupported by default; a no-setup Docs insertion route is an open question. [Certain]

Automated TextEdit run (Claude-driven, harness outside the command sandbox): append, focus departure, 60-second expiry, consecutive dictations, and the foreground guard now have live evidence. Fixed a stale `frontmostApplication` in polling (run loop never spun) and focus departure being misreported as lost access. Consecutive dictations glue without a space; the product needs inter-dictation spacing. Permission revocation, clipboard fallback, and repeated-session learning remain pending. [Certain]

Chat composer (ChatGPT/Codex desktop 26.928.40906, new unsent chat): readable AXTextArea, but the AX write reports success without delivering; harness correctly reports unverified with no paste. Open decision: allow paste fallback when read-back shows the field unchanged. [Certain]

Paste fallback added for AX writes that report success but leave a non-browser field unchanged (300 ms settle). Codex composer now verifies via the fallback, and observation passes the live-testable cases. Arc exposed a focused AXTextArea this time, but the write was dropped again and the fallback correctly skipped the unknown browser field type. Open decision: whether browser fields may use the fallback. [Certain]

Fallback extended to browser fields of unknown type (user decision; secure fields still rejected). Arc textarea now receives the text exactly once via paste, screen-confirmed; it stays harness-unverified and learning-ineligible. [Certain]

Code editor (VS Code 1.140.0, default settings): the editor exposes an empty stub AXTextArea. The AX write is ignored; the paste fallback delivered the text once (screen-confirmed) but stays unverified, so no observation is possible. Learning in VS Code would need screen reader mode or an extension. [Certain]
