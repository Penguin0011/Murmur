# Module one interaction safety review

**Dated development record.** Statements, task instructions and validation limits below apply to their recorded checkpoints. They are not current release clearance or authorization to merge or change settings. See the [documentation guide](../DOCUMENTATION.md) for current entry points. [Certain]

Decision: **GO for bounded milestone-1 investigation; NO-GO for declaring the complete feasibility or release gate passed.** Current source and recorded evidence support continuing work, but do not prove duplicate-free insertion, secure-field handling across applications, microphone capture, or production automatic correction promotion. [Certain]

The weakest interaction assumption is that an AX write returning success but leaving a field unchanged for 300 ms proves that delivery will never occur. It does not: a delayed application write can arrive after fallback Command-V, creating a duplicate. [Certain]

## Evidence boundary

Reviewed `spike/Insertion.swift`, `spike/Observation.swift`, `spike/Shortcut.swift`, `spike/ShortcutChecks.swift`, `spike/main.swift`, the PRD acceptance criteria, and the recorded feasibility matrix on October 2, 2026. A fresh unoptimized build to `/tmp/dictation-safety-spike` and its `--check` passed on this host. No keyboard, microphone, browser, clipboard-manager, or secure-field live test was performed by this review. [Certain]

The matrix in `spike/FEASIBILITY.md` is prior recorded evidence. It describes TextEdit and the Codex composer passing insertion plus structural observation scenarios; Arc and VS Code receiving synthetic paste once with unverified delivery and no learning; and default Safari/Google Docs lacking an accessible destination. These observations were not independently repeated in this review. [Certain]

The recorded host is M3/16 GB, while the earlier PRD baseline was M1/8 GB (now deferred by user decision). Neither historical interaction success nor this deterministic check measures the baseline model pipeline. [Certain]

## Findings and smallest useful actions

| Finding | Assessment | Module-one action |
|---|---|---|
| Successful AX write followed by unchanged read-back triggers paste after a fixed 300 ms. | A late AX delivery can duplicate insertion; increasing the wait or subscribing to notifications cannot establish permanent non-delivery. [Certain] | In production-safe mode, return unverified and preserve output after any uncertain AX success. Keep the previously authorized fallback only as an explicit compatibility probe, or select paste before attempting AX for a destination with established compatibility. |
| Unsupported/not-implemented AX writes take the paste route. | These explicit errors are stronger fallback evidence than unchanged read-back after success, but posting global paste still races focus and clipboard changes. [Certain] | Keep existing focus and ownership checks; report delivery as unverified when field identity/value cannot prove the result. Never retry automatically. |
| Secure subrole, password metadata, or protected content rejects insertion. | Source guards exist, but recorded live password and permission-revocation coverage is incomplete. Unknown browser types can receive insertion when secure metadata is missing, per the prior user decision. [Certain] | Preserve that disclosed compatibility decision; exclude unknown browser types from learning. Add reproducible synthetic secure-field checks and record only actual live outcomes. Do not call absence of metadata proof of safety. |
| Clipboard ownership token and stable change count guard paste and restoration. | They reduce interference but do not make NSPasteboard operations atomic. A writer or focus switch can occur after the final check; fixed 200 ms restoration can precede an application's pasteboard read. [Certain] | Keep unverified recovery, no automatic retry, and disclose the race. Exercise a deliberately competing clipboard writer before making a clipboard-preservation acceptance claim. |
| Observation is restricted to a verified inserted span with exact outside anchors. | Undo, appended text, selection departure, focus departure, expiry, and grapheme boundaries have deterministic checks; transient edits between 100 ms polls can be missed. [Certain] | Preserve conservative stop rules. Add permission-revocation and separate-session live evidence when the environment supports them; record unavailable access as pending. |
| Two-session evidence can promote only with a supplied eligibility predicate. | The default predicate rejects every candidate. One-letter replacements alone do not establish spelling/name identity: `form`→`farm` and `cat`→`car` change meaning while fitting the structural rule. [Certain] | Keep automatic promotion disabled until a conservative known-term/spelling gate is implemented and measured against negative semantic examples. Report structural observation separately from learned-preference application. |
| Shortcut listener starts immediately on press and suppresses repeat/processing starts. | Deterministic state checks and recorded physical Right Option traces support its state machine; the listener captures no microphone audio and simulates processing completion. [Certain] | Wire capture start/finish/cancel in a bounded harness, preserve first-word audio, and test a real short clip. Do not label the existing listener proof of capture latency or microphone behavior. |

## Exit criteria

Milestone one remains open until available-host model validation, real capture/shortcut path, insertion recovery, and published per-category automatic-learning evidence are resolved. Unsupported learning categories may be disclosed under the approved PRD rule; a passing structural tracker does not satisfy conservative semantic promotion by itself. [Certain]

Release remains NO-GO while the duplicate fallback, secure-field/permission coverage, and recovery invariant lack acceptance evidence. The spike explicitly has no persistent recovery store, so it must continue using disposable synthetic content. [Certain]

This review recommends no new dependency, application skeleton, general event framework, or speculative retry machinery. The immediate safe improvement is an explicit boundary between uncertain-delivery compatibility experiments and production insertion. [Likely]
