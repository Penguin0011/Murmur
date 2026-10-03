# Native Murmur app

Build the local development bundle on Apple Silicon/macOS 26:

```sh
app/build.sh
open runtime/Murmur.app
```

The bundle uses the pinned local ModelBench helper. Model download, cleanup, cloud providers, signing/notarization, and production release remain separate work. [Certain]

## Recovery and interface

Idle errors have a Dismiss control. Dismissal hides status without deleting history or retry audio; it is unavailable while recording or processing. Storage failure remains an error rather than claiming the app is ready. [Certain]

Settings show the current state above the scrollable form, model file availability, individual permission rows, and an always-visible Apply Settings button. Model availability checks file sizes; full checksums are verified before inference. History supports search, delivery status, initial selection, and recovery-entry selection. [Certain]

Recording and processing use a compact standalone glass-dot voice indicator on a transparent background by default. Saved output and successful insertion show no popup; delivery status remains in History. Only errors show a compact clickable message and, when recovery audio exists, Audio. Clicking the popup opens the Dictation tab with the full error, even when History was selected. Dismiss and Audio have separate actions. [Certain]

Corrupt or mismatched history files produce an error and prevent retention from silently skipping data; corruption at startup currently blocks dictation. Automatic repair/quarantine is not implemented. [Certain]

## Checks

All of these avoid live recording, insertion, and keyboard injection:

```sh
swiftc app/LaunchOptions.swift app/check_launch.swift -o /tmp/dictation-launch-check
/tmp/dictation-launch-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/check_history.swift -o /tmp/dictation-history-check
/tmp/dictation-history-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Controller.swift app/UI.swift app/check_controller.swift -o /tmp/dictation-controller-check
/tmp/dictation-controller-check
```

For isolated empty-history visual inspection, run the executable directly:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --preview
```

Preview disables shortcut capture and uses temporary history/retry storage. Permission buttons and Apply Settings are real controls; inspecting preview does not require using them. [Certain]

`check_ui.sh` builds and runs the synthetic visual fixture with temporary storage, synthetic transcripts, and an error bubble. It performs no capture or insertion; dismissal asserts that recovery history remains. The fixture has a working Quit menu and closes its temporary storage on normal exit. [Certain]

```sh
app/check_ui.sh
app/check_ui.sh --light
app/check_ui.sh --light --compact --opaque
app/check_ui.sh --bubble-only
app/check_ui.sh --listening --bubble-only
app/check_ui.sh --processing --bubble-only
app/check_ui.sh --saved --bubble-only
```

The fixture forces only its own appearance. `--compact` uses the minimum production window size, while `--opaque` forces the same opaque rendering branch used by Reduce Transparency for the settings/History view. The separately hosted floating bubble continues to use actual system accessibility settings. [Certain]

The developer audio probe requires both flags and must target a disposable field:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

This explicitly performs transcription and one insertion attempt. It preserves the supplied audio, using a private retry copy, and writes durable history. It cannot be combined with preview or timed quit; malformed flags exit before storage/UI initialization. [Certain]

## Cleanup

`Cleanup.swift` is Foundation-only and is not yet wired into the app. It provides:
- `CleanupOptions`: fillers, corrections, and lists toggle independently. All are on by default, and `.faithful` turns all off.
- `CleanupGuard`: the PRD bound check between raw and cleaned text.
- `CleanupPrompt`: messages for an LLM provider.
- `RuleCleaner`: a deterministic local baseline.
- `CleanupPipeline`: returns `.cleaned`, `.unchanged` (all options off), or `.heldForRecovery(raw:reason:)`. A cleaner error or a guard failure both produce a hold. The reason is a content-free enum. [Certain]

**RuleCleaner is a conservative stopgap, not the PRD's cleanup-model selection.** [Certain]

```sh
python3 app/tools/build_cleanup_corpus.py        # regenerates app/cleanup-corpus.json
swiftc app/Cleanup.swift app/check_cleanup.swift -o /tmp/cc && /tmp/cc app/cleanup-corpus.json   # add --verbose for misses
```

The check exits non-zero if the name/number/negation bar or any adversarial case fails. Measured October 3, 2026 on Linux with Swift 6.1.2. It also type-checks under `-swift-version 5` and `-swift-version 6`. [Certain]

| Metric (425 utterances) | Result |
|---|---|
| Exact match, all utterances | 96.7% (fillers only 95.3%, corrections only 95.8%, lists only 97.8%, all on 99.0%, all off 100%) |
| Unintended name/number/negation edits (PRD bar ≤ 1%) | 1/425 = 0.2%. The one case is the list false positive below. |
| Strict mismatch with labels, including corrections the baseline missed | 6/425 = 1.4% |
| Spoken-correction exact match / ambiguous corrections kept unchanged | 95.8% / 22 of 22 |
| List formatting precision / recall | 97.7% / 100% |
| Expected-unchanged utterances left untouched | 187/188 |
| Guard false rejects on labeled cleanups | 0/237 |
| Adversarial outputs rejected | 2348/2348: 60 hand-written cases (answers, obeyed instructions, poems, translation, tone polish, dropped `not`, added/changed numbers, added/dropped names, quote edits, emoji) plus systematic mutations of every label |
| Plausible LLM variants accepted (not gating) | 11/16 |

Treat these numbers with caution:
- The same agent wrote the corpus, its labels, and the baseline, so exact-match overstates real-world quality. [Certain]
- A 40-utterance `heldout` group was written after tuning. Its first run scored 38/40. That run found two bugs: a stray "." after a sentence-only "Hmm.", and a list length-ratio limit that held a correct "number one…" list. Both are fixed now, so the group is no longer held out. [Certain]
- The guard is strict on purpose. It holds an added `?` or `!`, number-word-to-digit changes, `gonna`→`going to`, and bullet lists, so real LLM output will reach recovery more often than RuleCleaner output. [Certain]

Known gaps:
- After a removed hesitation, comma handling uses a word list. This misses introductory phrases ("To be honest, um, I…") and over-keeps after a capitalized first word ("Please, um, don't…").
- Corrections need an explicit cue set off by punctuation and either a same-category swap (weekday, month, number, time, color, name) or a phrase restarted with the same function word. These stay unchanged: "Order three pizzas, sorry, four", "Add salt, no wait, add sugar", and corrections inside list items.
- "Remember: first impressions matter, second chances are rare" becomes a list.
- The guard does not convert number words; "twenty five" vs "25" is rejected.
- No real ASR transcripts are in the corpus. [Certain]

## Evidence from October 2, 2026

The app bundle built and ad-hoc signing passed. Launch, history/model-verifier, controller dismissal/audio ownership, session state, processor fault/signal, and spike insertion/observation checks passed. Native screenshots/AX inspection confirmed settings and empty/populated History, error dismissal to Ready, preserved synthetic entries, matching-transcript selection, and no-results search. The native Liquid Glass update was captured in light, dark, and forced opaque compact appearances. Scoped screenshot review resolved supporting-text and search-placeholder contrast findings. Native History filtering/clearing and the floating bubble Dismiss click passed; the fixture confirmed preserved recovery history. [Certain]

Physical shortcut/microphone first-word behavior, real speech quality, clipboard-manager races, and live insertion after these changes remain unverified. The synthetic bubble click does not establish focus preservation in a real destination app. [Certain]

## Leading space

Enable **Intelligently add a leading space** and apply settings to separate inserted dictation from existing text. The option defaults off. It uses the original field value and UTF-16 cursor position, and only inserts a space when preceding text needs separation. It skips existing whitespace, opening delimiters, punctuation-led output, selected-text replacement, word interiors, and unavailable/invalid context. The insertion safety check still rejects changed destinations. Raw transcription stays unchanged; History final text records the attempted insertion including its added space. Copy-only output remains unchanged. [Certain]
