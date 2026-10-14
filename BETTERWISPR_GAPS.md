# BetterWispr feature gaps: October 14, 2026

This compares Murmur `main` (`0b0af68`) with [BetterWispr](https://github.com/opennookorg/betterwispr) at `d504749` (v0.1.5, Apache-2.0). It lists what BetterWispr has that Murmur lacks and the plan to close each gap. [Certain]

**Scope decision (user, October 14, 2026):**
- In scope:
  - every dictation gap below
  - screen context for AI cleanup
  - a Home/Insights page
  - a meeting notetaker
- Out of scope: multilingual models (Parakeet v3, Whisper, a language picker). Murmur stays English-first. [Certain]

**Licensing:** BetterWispr adapted its correction watcher, its AI correction reviewer, its polish prompt and its live word-agreement preview from VoiceInk, which is GPL-3.0 (see their `docs/oss-reuse.md`). Murmur is MIT. Reimplement ideas only. Do not copy code or prompts from BetterWispr. [Certain]

## Where Murmur is already ahead

Keep these. Do not regress them while closing gaps.

- **`CleanupGuard`:** the inserted text never answers the dictation, obeys instructions in it, or invents names or numbers. BetterWispr only checks word counts.
- **Strict / Polish / Professional styles**, with a guard for each.
- **Learning coverage and safety:**
  - a keystroke fallback for fields with no readable text (VS Code, Google Docs)
  - tombstones for deleted words
  - conflict suppression
  - an NSSpellChecker lexicon
  - it never forces `AXManualAccessibility`. BetterWispr does, and that flips VS Code into screen-reader mode.
- **Parakeet Unified:** 1.34% WER on our LibriSpeech benchmark. BetterWispr recommends Parakeet Ultra. Its numbers come from a different test set, so the two aren't directly comparable.
- **Recovery:**
  - raw and final text in History
  - ⌃⌘V paste-last
  - retention controls
  - Delete All Data
- **Cloud disclosure:** the destination host is named for every off-Mac stage.

## Gaps and plan

Size: S = days, M = about a week, L = several weeks. Workstreams (W1–W7) group the changes that touch the same files, so that at most one writer edits a given set of files at a time.

### Cleanup and text output

| # | Gap | BetterWispr | Murmur today | Plan | PRD impact | Size | W |
|---|---|---|---|---|---|---|---|
| 1 | On-device AI cleanup | Apple Intelligence (`FoundationModels`) polish, prewarmed, no download | Local rules or cloud LLM only | New `CleanupChoice` backed by `SystemLanguageModel`; output passes `CleanupGuard`; measured on `cleanup-corpus.json` before release | Revisits the Oct 7 "no local AI cleanup" decision (the reason was RAM for downloaded models, which doesn't apply to a system model) | M | W2 |
| 2 | ✅ Done (W1, Oct 14) — Voice commands | "comma", "period", "question mark", "new line", "new paragraph", "colon", "hyphen", "exclamation mark" | Only "scratch that" (as a correction cue) | Add to `RuleCleaner` and the cleanup prompt; tell `CleanupGuard` about them so the inserted marks aren't rejected | None (an extension of R-cleanup) | S | W1 |
| 3 | ✅ Done (W1, Oct 14) — Spoken numbers → digits | "two hundred fifty thousand" → 250,000, ranges, decimals, lakh/crore, keeps "give me five minutes" | Number words are used only by the guard; nothing is converted | Add a number formatter to `RuleCleaner`; teach the guard that digits match the spoken number | None | M | W1 |
| 4 | ✅ Done (W1, Oct 14) — Spoken symbols | "at the rate"/"at sign" → @, "hashtag x" → #x, "ten percent" → 10%, rejoin "gmail dot com" | None | Same pass as #2 and #3 | None | S | W1 |
| 5 | ✅ Done (W1, Oct 14) — Email layout | "write an email to Sarah saying … best regards Kartik" → greeting, body, sign-off | None | Rules-based layout, skipped when no email frame is detected | Allows added structure only for this explicit frame | S | W1 |
| 6 | Per-app / per-website / trigger-word modes | Writing Modes override cleanup, tone, context and custom instructions, matched by trigger word, then website, then app | One global `CleanupOptions` | Bundle-ID map → `CleanupOptions` override, plus browser URL matching via AX and trigger words; resolved from the app focused when recording started | New decision; custom instructions go to the cloud model only with disclosure | M | W3 |
| 7 | Tone per app category | Formal / Casual / Very casual / Excited, applied by rules (drop commas and the final period, lowercase) | None ("never changes tone") | Deterministic tone pass, opt-in per app or mode | Amends "cleanup never changes tone": only with an explicit opt-in | S | W3 |
| 8 | Screen context for AI | Selected text, clipboard (skipping password-marked items) and window text via AX, with OCR fallback, sent to the polish model | Dictionary terms only | Opt-in setting; skip secure fields, Secure Input and concealed pasteboard types; cap the size; name what leaves the Mac in the route disclosure | Amends PRD line 83 (in scope per the user, Oct 14) | M | W3 |

### Learning

| # | Gap | BetterWispr | Murmur today | Plan | PRD impact | Size | W |
|---|---|---|---|---|---|---|---|
| 9 | Learning latency | Learns once the field has been unchanged for 2 s | Settles on focus-out, Return or Tab, or after 60 s | **Done (W4, Oct 14):** Also settle on stable text; a later edit re-records, and undo still withdraws | None | S | W4 |
| 10 | Learn from History edits | Pencil edit in History learns the fix | History is read-only | **Done (W4, Oct 14):** Editable final text in History feeds the same ledger and filter (in addition to automatic learning, not a replacement) | None: the PRD forbids only *replacing* automatic learning | S | W4 |
| 11 | One-fix replacement | One fix → replacement, with an optional AI review | One fix → hint; two fixes → replacement | **Awaiting user decision; not in any workstream yet.** Option: when an AI cleanup route is active, an AI review approves a first-fix replacement | Would amend the approved two-observation rule | S | W4 |
| 12 | Commands misheard in an accent | A dictionary entry can map "Kocia Mark" → "question mark" before commands run | n/a until #2 lands | **Done (W4, Oct 14; command list to align with W1 on merge):** Dictionary entries whose target is a command run before command parsing | None | S | W4 (after W1) |

### Recording experience

| # | Gap | BetterWispr | Murmur today | Plan | PRD impact | Size | W |
|---|---|---|---|---|---|---|---|
| 13 | Live words while speaking | Parakeet preview in the capsule (confirmed words bright, guess dimmed) | Waveform only; streaming is researched in `STREAMING_TRANSCRIPTION.md` | Use FluidAudio's `StreamingUnifiedAsrManager` for display only; the final text stays a whole-clip transcription | None | M | W5 |
| 14 | Custom shortcut | Records any combination with ⌘, ⌥ or ⌃, or an F-key | Three presets | Shortcut recorder with validation; keep the presets as defaults | None | S | W5 |
| 15 | Start/stop sounds | Local system sounds, on by default, with a toggle | None | Two `NSSound` cues plus a toggle | None | S | W5 |
| 16 | Bluetooth headset mic | Automatic uses the built-in mic while the lid is open, so AirPods keep full playback quality | Uses the system default | "Automatic" device option with that rule; follows device changes mid-recording | None | S | W5 |
| 17 | Paste-failure card | Card with the text and a Copy button when the target app is gone | History recovery plus ⌃⌘V | Bubble card with Copy | None | S | W5 |
| 18 | Cancel with Undo | A cancelled dictation can be restored for a few seconds | Escape discards | Keep the audio for 5 s after cancel; Undo transcribes it | None (audio is in memory only) | S | W5 |

### Product surfaces

| # | Gap | BetterWispr | Murmur today | Plan | PRD impact | Size | W |
|---|---|---|---|---|---|---|---|
| 19 | Home and Insights | Home: shortcut, readiness, recent dictations. Insights: WPM against typing, time saved, words cleaned, streak calendar, apps used | Settings and History only | Home page computed from local History only; no telemetry | None (local only) | M | W6 |
| 20 | Theme and Dock icon | System, Light or Dark; show in Dock | Follows the system; menu bar toggle | Add both settings | None | S | W6 |
| 21 | Welcome guide | Full-window onboarding: permissions, model, first dictation; can be replayed | Setup screen | Turn the setup screen into a replayable guide with a test dictation | None | S | W6 |

### Meetings (in scope per the user, Oct 14)

| # | Gap | BetterWispr | Murmur today | Plan | PRD impact | Size | W |
|---|---|---|---|---|---|---|---|
| 22 | Meeting notetaker | Mic as "Me", system audio as "Them" (Core Audio tap), live transcript, your own notes, AI title, summary, decisions and action items | None | Write a PRD section first (consent, retention, disclosure, storage), then build capture, transcript, notes | Reverses the "no meeting recording at launch" boundary (PRD line 11) | L | W7 |
| 23 | Meeting detection | Offers to start notes when Zoom, Meet, Teams and others start using the mic | None | After #22 | Same | S | W7 |
| 24 | Speaker separation | On-device diarization (Speaker 1, 2…) with renaming | None | After #22; FluidAudio ships diarization | Same | M | W7 |

### Distribution (no change; recorded for completeness)

- **Signed Sparkle auto-updates:** BetterWispr has them. Murmur defers them because the user postponed Apple Developer enrollment (PRD). Unchanged.
- **In-app model download:** in progress in `app/ModelDownload.swift`. Finish it as planned.

## Order of work

1. **W1, cleanup rules (#2–5), done October 14, 2026:** the "Spoken commands and numbers" option (`RuleCleaner.spokenCommands`, the `CleanupGuard` second pass, prompt lines). See the PRD decision of the same date. Was pure `Cleanup.swift` work, so it has the fewest dependencies. Ship it first so W2 and W3 build on the new guard rules.
2. **W2, Apple Intelligence cleanup (#1)** and **W4, learning (#9, #10, #12):** #11 waits for a decision. These run in parallel with W1. W2 adds a new cleaner file and its route. W4 touches `Learning.swift`, `Controller.swift` (watch loop) and the History UI.
3. **W3, modes, tone and screen context (#6–8):** after W1 and W2, because it changes how options and prompts are chosen per dictation.
4. **W5, recording experience (#13–18)** and **W6, Home/Insights (#19–21):** independent of the cleanup work, but they share `UI.swift` and `Controller.swift`, so run them one after the other or carefully split by file.
5. **W7, meetings (#22–24):** PRD section first, then the build. It is the largest piece; start it once the dictation gaps are closed or have their own owners.

Every workstream keeps the PRD's evidence rules: `check_*.swift` coverage, corpus thresholds for cleanup changes, and a documented decision for any rule it amends.
