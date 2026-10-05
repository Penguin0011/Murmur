# Wispr Flow-style learning and paste-only insertion — October 4, 2026

Branch `aakash/dictionary-learning-exploration-6182a5`. User decisions: replicate Wispr Flow's auto-add, and insert only with ⌘V paste. [Certain]

- Insertion: `insertText` always pastes (clipboard preserved and restored as before), then reads the field back to verify and to hand it to AX observation. The AX selected-text write, the unchanged-write paste fallback and the per-app method table are gone. [Certain]
- Learning: one settled correction adds a vocabulary hint (learned entry, no variants: reaches Parakeet's vocabulary file and cloud vocabulary, `apply()` changes nothing) and shows "Added “X” to dictionary" with Undo for 5 s; the second consistent correction adds the misheard form as a variant of the same entry. Deleted or reversed words are never re-learned from any mishearing. Version-1 ledgers load unchanged. [Certain]
- Live, TextEdit, local cleanup, synthetic `say -o` audio (never played): every insertion pasted once with status `verified`. Run 1: two keyboard fixes (ACME→Akme, chairs→Chayrs) then " Thanks a lot." typed at the end → two hints. Run 3: ACME→Akme again, then Return and a new line → Akme gained the ACME variant and reached `parakeet-vocabulary.json`. Run 4: the same dictation inserted "Akme" unaided. A test tool whose typing replaced the whole field taught nothing (rewrite guard). Not live-tested: click-to-fix in keystroke-watched fields (VS Code is click-only for the test harness, LibreOffice access was declined); covered by checks only. The notice is not visible in probe runs because the probe exits when the watch ends. Data, settings and test history were restored afterwards. [Certain]
- Installed `6262079` to `~/Applications/Murmur.app` (signed "clouddev Development"), executable SHA-256 `54466b71d2af3b33dcf85674aa5570d2f3b7a20a4c9a46c8a682ffab693419d3`; previous build at `~/Applications/Murmur-backups/20261004-222500/Murmur.app`. [Certain]
- Passing on the Mac: launch, history, controller, dictionary, processing, providers, updates, boost filter, routes, app services, model download, cleanup corpus and `spike --check`. Of the UI fixtures only `check_ui.sh --saved --learned --bubble-only` was run (notice renders; Undo click not exercised). The live TextEdit probe was not run: it needs TextEdit frontmost, and the screen-takeover approval was not available. Paste-only delivery is unverified live. [Certain]
- Gaps closed (`52a721f` and follow-up): a fix followed by more typing is learned (word diff ignores added words; a trailing run tries its first 1–3 words first); several fixes in one dictation are separate evidence; a rewrite of more than half the span or a deletion teaches nothing; clicking to fix in keystroke-watched fields (Chrome, VS Code, Docs) follows every possible caret position and double-clicked word and learns only a single plausible fix; Return/Tab end a keystroke watch keeping the fix; a chat composer emptied by sending keeps the fix. Cost: resolving guesses runs on the 0.25 s poll, about 50 ms worst case for a 400-character span with the spell checker. [Certain]
- Case, spacing and short-word fixes (user approval): learned when NSSpellChecker is the lexicon. Real-checker battery: jira→Jira, figma→Figma, git hub→GitHub, open AI→OpenAI, para keet→Parakeet, fig ma→Figma, rust C→rustc, a p i→API, J son→JSON, Jon→John, Ana→Anna, Al→Ali learned; notion→Notion, murmur→Murmur, Tail wind→Tailwind, every one→everyone, data base→database, the→The, us→US rejected; sequel→SQL rejected (sounds unlike by the phonetic key). "a lot"→"alot" and "ok"→"OK" would be learned. [Certain]
- Live (TextEdit, local cleanup, silent audio): Parakeet wrote "JIRA"; changing it to "Jira" added a Jira hint that reached `parakeet-vocabulary.json`; insertion verified. Data restored afterwards. Installed `8e3e87d`, executable SHA-256 `b35600d53ffdd79a1e5c731624896b2d0a51f20b1b824af78ed6dd706e10aee5`; previous build at `~/Applications/Murmur-backups/20261004-223446/Murmur.app`. [Certain]
- Settings → Dictionary lists what learning skips under "Not learned" (heard forms suppressed by conflicting or reversed fixes, spellings deleted, undone or reversed), each with Unblock; Reset Learned also clears them. Checked in the UI fixture (`check_ui.sh --light --dictionary`). [Certain]
- Still open: right-click spelling suggestions and mouse drag-selection of part of a word are not followed in keystroke fields. [Certain]

# Dictionary feature — October 4, 2026

Branch `aakash/dictionary-feature-523123`. Goal: make the custom dictionary matter on the main route (local transcription, then Gemini cleanup) and finish the editor. [Certain]

Done:
- `7a4e865` Sound-alike terms reach cleanup. `DictionaryStore.relevantEntries` now adds up to 10 enabled entries whose preferred spelling sounds like a 1–3 word span of the transcript (matching phonetic keys and similarity ≥ 0.5, or similarity ≥ 0.75 for terms of 6+ letters). `apply()` stays exact. The cleanup prompt says the dictionary respelling overrides "never respell". The guard lets one term join 2–3 raw words that spell it exactly ("cloud dev" → "clouddev"). [Certain]
- Measured with a 20-term sample dictionary over the 425-utterance corpus: 9/425 transcripts pulled in a term, all genuine; 0 false positives after the 6-letter rule (before it, "I mean" pulled in "Sean" 20 times). Recall probe: shawn/seen→Sean, coopernetties→Kubernetes, a cash→Aakash, jiminy→Gemini, para keet→Parakeet matched; figment→Figma, germany→Gemini, shivon→Siobhan did not. [Certain]

Known limits: "seen" sends "Sean" to the cleanup provider; the prompt tells it to respell only where the term is clearly meant. Not yet tested against a live Gemini call. [Certain]

- `01f9fc3` Settings → Dictionary: Edit turns a row into fields with Save and Cancel (Return saves, Escape cancels). Each row has an on/off toggle; entries that are off are dimmed and no longer apply. A conflicting variant shows its error message. Return in the Add fields adds. There's an empty state, and the help text explains exact versus sound-alike matching. `ProcessingCoordinator.updateEntry` keeps an entry's source; learned promotions are keyed by entry ID, so editing a learned entry can't re-promote the old spelling. Checks pass: dictionary 140, processing 95, routes 89, providers, cleanup corpus, and the controller compile. [Certain]
- Merged the live Gemini validation notes from local `main` (section below). That run found Gemini writing "shelf made"/"shelf-made" for Shelfmate. With this branch, a Shelfmate entry that has no variants reaches the cleanup prompt for both forms. `2135bac` lets the guard accept a term that replaces 2–3 words that sound like it, on the cloud path only ("shelf made" → "Shelfmate"; this also covers "cube cuddle" → kubectl). Checks: processing 96, routes 89, dictionary 140, providers, cleanup corpus. [Certain]
- UI fixture (`app/check_ui.sh --light --dictionary`), inspected in pixels: found and fixed squeezed Add-row fields and a visible "Use <term>" label beside each toggle. After the fix: rows show the badge, toggle, Edit and ×; the disabled entry is dimmed; Edit → change variants → Save updated the row; the toggles carry VoiceOver labels ("Use Kubernetes"). Dark mode was not inspected. [Certain]

Not done: a live Gemini call through this branch's sound-alike path; the earlier live run used exact variants on `main`. Next live check: remove Shelfmate's variants and say "Send the Shelfmate report". [Certain]

**User decisions, October 4, 2026:** cloud transcription gets the dictionary; dictionary support in Parakeet is critical (most users run local transcription with cloud cleanup); the user runs the live Gemini test. [Certain]

- `aa31965` Cloud transcription sends every enabled preferred spelling (manual first) as the vocabulary hint: Gemini 3.5 Transcribe as custom vocabulary, Gemini audio as spelling hints, OpenRouter Whisper none. Disclosures now say "your dictionary's spellings". [Certain]
- `7f31ad1`, `10de932` Dictionary support in on-device transcription:
  - Optional 103 MB download (Settings → Dictionary) of the pinned Parakeet CTC 110M model, `FluidInference/parakeet-ctc-110m-coreml` at `accdafd8`, CC-BY-4.0 (recorded in the pins and in THIRD_PARTY_NOTICES). [Certain]
  - Installed in FluidAudio's own folder, `~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`, because `VocabularyBoostingSession` reads the CTC tokenizer only from `CtcModels.defaultCacheDirectory`. Other FluidAudio apps (Handy, OpenWhispr are installed here) could share it, so it is hash-verified before every use and skipped when it does not match; the Download and Remove alerts name the folder and say it may be shared. [Certain]
  - Helper: `ModelBench … --ctc DIR --vocabulary FILE` rescoring, then `BoostFilter` (see `app/README.md`). Vocabulary or model errors never fail transcription. `build.sh` now always builds the helper. [Certain]
  - App: `refreshDictionary()` rewrites `dictionary/parakeet-vocabulary.json` and pre-warms; `HelperLaunch.make` builds arguments and key for warm, chunk and one-shot paths. [Certain]
- Measured (synthetic `say -o` speech, never played; 20-term dictionary): 0/119 ordinary corpus sentences changed (6/119 before the filter: nothing→Notion, remind→Gemini, getting→Gemini, option→Notion); 6 misheard terms fixed (kubectl, Shelfmate, Aakash, Clouddev, Supabase, OpenRouter); +0.12 s per transcription; first load after download about 14 s (Core ML compile, pre-warmed). [Certain]
- Verified: clean-state download through `ModelDownloader` with the real pins into the real folder (10 s, full hash pass); the bundled helper from `build.sh` with that folder; bad vocabulary and missing model still transcribe. All checks pass. [Certain]
- Downloader fix found by a fresh-parent test: a target under `/private` lost every file to `pruneUnexpected` (paths standardized differently before and after the staging folder existed). Fixed with relative paths, plus a regression check that fails without the fix. `~/Library` targets were never affected. [Certain]
- Launch now pre-warms once (dictionary refreshes pre-warm only after `start()`), and Download no longer blocks the window on the helper. [Certain]
- Installed build: `~/Applications/Murmur.app` replaced at 13:22; previous build backed up at `~/Applications/Murmur-backups/20261004-132250/Murmur.app`; relaunched because it was running. The running helper was started with `--ctc ~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml --vocabulary ~/Library/Application Support/Dictation/dictionary/parakeet-vocabulary.json`; the file is 0600 with 1 enabled term. The installed helper with that file turned the synthetic "ShelfMud" clip into "Shelfmate", with no vocabulary error. [Certain]
- Not verified: the Settings download row in pixels and dark mode (the screen was locked), a download clicked in the app, and any human speech. On this Mac the CTC folder is already installed (from the clean-state test), so the app shows it as downloaded. [Certain]
- For the user's tests: local dictation of a dictionary word that has no "heard as" forms; for the sound-alike Gemini cleanup path, first remove Shelfmate's "heard as" forms, since those exact forms would hide the new behavior. [Certain]

- Chunk cuts (October 4, later): measured that removing chunking costs far more than it saves with dictionary support on (release wait with rescoring: 0.29 s at 15 s, 1.33 s at 56 s, 2.51 s at 110 s, 4.90 s at 218 s of audio, against at most about 0.4 s for the last chunk), so chunking stays. Each cut now also emits a boundary clip; the helper returns its kept replacements and `Chunker.repair` applies only one that crosses the cut. With the cut forced inside the term (0.4 s pause), open router and cube cuddle were repaired to the whole-file result; super base, shelf mate and Kuber netties were not fixed by whole-file transcription either. 23 cuts on long control recordings: no change. [Certain] Installed in `~/Applications/Murmur.app` at 20:37 (previous build backed up at `~/Applications/Murmur-backups/20261004-203721/Murmur.app`); after relaunch the helper runs with `--ctc … --vocabulary …`. [Certain]

- `2cb63a6` (from a Codex review on the PR): the cleanup guard let an inserted dictionary term excuse deleting any one unrelated word. Each term must now replace 1–3 raw words in its own alignment gap that spell it, are spelled at least half like it, or sound like it. Installed at 20:41 (previous build backed up at `~/Applications/Murmur-backups/20261004-204123/Murmur.app`). [Certain]

Limits: casing-only fixes (tailscale→Tailscale) are not made by the helper (cloud cleanup handles them); a cut inside a term still leaves a stray period when the term is not in the dictionary ("super. Base"); History's raw text is the rescored transcript; a CTC folder with the right sizes but wrong content shows "Downloaded" while being skipped. [Certain]

Deferred: automatic learning from edits (`TODO(observation)` in Controller.swift). [Certain]

---

# Live Gemini and dictionary validation — October 4, 2026

Current checkout: `main` at `f077b53`; working tree was clean at start. The installed `~/Applications/Murmur.app` executable and `runtime/Murmur.app` executable have the same SHA-256 (`4d032d274013ab8abecb69a6468b1ab2873adc4b5c7a8069c8f18b2db5347fc6`). Older sections below are historical; their uncompiled/unwired/no-real-key claims do not describe this checkpoint. [Certain]

- Real Gemini calls succeeded using the saved key, without printing it: Gemini 3.5 Transcribe returned `Send the shelf-made report to Acme Robotics. Um, the total is $42.`; Gemini audio returned `Send a shelf made report to Acme Robotics. Um, the total is $42.` Synthetic Samantha speech was uploaded through the production `CloudTranscription` and provider code. This proves real network behavior, not human speech quality. [Certain]
- Production `ProcessingCoordinator.processAsync` with Gemini cleanup preserved `ACME Robotics`, removed the filler, and retained the amount. A control with the configured variant `shelf mate` produced `Shelfmate`. Both audio cases missed `Shelfmate` because only `shelf mate`/`shelfmate` were registered, while Gemini returned `shelf-made`/`shelf made`. Dictionary replacement uses explicit whole-word variants, not fuzzy matching. [Certain]
- The app currently passes no dictionary vocabulary hint to cloud transcription (`Controller.transcribeInCloud` → `CloudTranscription.run`). Dictionary replacement and relevant-term cloud cleanup run after transcription. Do not claim dictionary bias at recognition time. OpenRouter STT ignores prompts by design. [Certain]
- Repeated real API tests with `shelf mate, shelfmate, shelf made, shelf-made` variants: **both Gemini 3.5 Transcribe and Gemini audio passed** dictionary replacement plus Gemini cleanup, producing `Shelfmate` and `ACME Robotics`, removing `Um`, and preserving `$42`. Gemini audio changed “the” to “a” in its raw transcript; the dictionary cannot repair unrelated transcription errors. [Certain]
- `check_processing.swift`: 92 checks passed, zero failed. `check_providers.swift`: 553 assertions passed. Live OpenRouter remains untested because no OpenRouter key is saved. [Certain]
- **Human-speech installed-app test passed.** User physically pressed Fn, spoke the requested phrase, and pressed Fn again. TextEdit visibly contained `Send the Shelfmate report to Acme Robotics. The total is $42.`; the matching durable History record contains that text as both raw and final, with `insertionStatus: verified`. Gemini recognized Shelfmate directly in this human sample; replacement itself was independently proved by the synthetic API samples above. [Certain]
- Settings at checkpoint: Gemini 3.5 Transcribe selected; Gemini cleanup with all four options enabled; original Fn shortcut restored. Added temporary manual Shelfmate with `shelf mate, shelf made, shelf-made` variants. The user began another recording while results were being inspected, so cloud transcription and the test entry were left in place to avoid disrupting active use. Original transcription route was Local; no original dictionary entries existed. Cleanup was already Gemini. [Certain]
- Native automated shortcut input typed a space without starting recording, and modifier-only input was rejected by the tool. The physical-user test above resolves the full-path gate; automated shortcut input is not evidence of a production shortcut defect. [Certain]

- User clarified that transcription will usually run locally. Restored **On this Mac (Parakeet)** in the installed app and verified the selected control and LOCAL TRANSCRIPTION status. Gemini cleanup remains selected as before testing; dictionary replacements apply after either transcription route. Treat local transcription as the normal route and cloud transcription as an explicit alternative. [Certain]

Ignored diagnostics are under `runtime/cloud-live/`; no credentials were written there. [Certain]

---

# Session checkpoint — October 3, 2026

Branch `aakash/stoic-pascal-2p0zyt`. Since the merge commit `027c1bf`, these landed first (through `fecee29`): [Certain]

| Area | Commits | What it adds |
|---|---|---|
| Cleanup | `9b1ad25`, `47af2ab`, `4c52312`, `867743c`, merged in `08fd0e0` | `app/Cleanup.swift`: independent cleanup options, the PRD bound-check guard, the LLM prompt, a deterministic `RuleCleaner` baseline and a pipeline that holds failures for recovery. A 425-utterance labeled corpus (`app/cleanup-corpus.json`, built by `app/tools/build_cleanup_corpus.py`) and `app/check_cleanup.swift`. |
| Dictionary, learning, retention | `d2470c3`, `17c359b`, `325f72a`, `0ee1c6a`, `82b0f92`, merged in `8d2bf02` | `app/Dictionary.swift` (custom dictionary, whole-word apply), `app/Learning.swift` (correction ledger and the proposed promotion rule), `app/Retention.swift` (50 MB cap, history-off mode, data wipe), and `app/check_dictionary.swift`. |
| Providers, Keychain, updates | `952c999`, `2e51682`, `c7b928e`, `5f5c0f8`, `06d215b`, merged in `6b09a2d` | `app/PROVIDERS.md` (verified provider facts), `app/Credentials.swift` (Keychain store, service "Murmur"), `app/Providers.swift` (OpenRouter STT, Gemini and OpenRouter cleanup, deprecated Fireworks STT, error classification), `app/Updates.swift` (GitHub Releases checker), with checks. |
| Shared type | `fecee29` | One `CleanupMessages` type used by both cleanup and providers. |
| Docs | `7270591` | Marks the PRD cleanup-failure conflict resolved. |

All of these are Foundation-only modules. Their checks passed on Linux with Swift 6.1.2. They are **not wired into the app and have not been compiled on the Mac** (Swift 6.3.3, `-swift-version 5`); the Keychain store compiles only on macOS, so it has never been compiled. [Certain]

Measured cleanup baseline (Linux, 425 utterances): 96.7% exact match, 1/425 unintended name/number/negation edits, 0/237 guard false rejects, 2348/2348 adversarial outputs rejected. The same agent wrote corpus, labels and baseline, so real quality is lower. `RuleCleaner` is a baseline, not the local cleanup model choice. Details are in `app/README.md` and PRD "Milestone 1 implementation decisions". [Certain]

Providers: Fireworks deprecated audio inference on 2026-06-10. PRD section 5 now proposes OpenRouter `/api/v1/audio/transcriptions` for STT and Gemini/OpenRouter for cleanup, pending user approval. No call has been made with a real API key. [Certain]

Release files added on this branch: `README.md`, `CONTRIBUTING.md`, `THIRD_PARTY_NOTICES.md`. FluidAudio at the pinned revision is Apache-2.0; the Parakeet weights are under the NVIDIA Open Model License and are downloaded, not bundled; the Core ML conversion's card says CC-BY-4.0, which does not resolve the upstream license. [Certain] No LICENSE file was added (see blocker below). [Certain]

Later the same day (through `e0b39b4`): [Certain]

| Area | Merge | What it adds |
|---|---|---|
| App wiring: cleanup and dictionary | `b9fdbf9`, fix `8a582e7` | `app/Processing.swift` coordinator (dictionary first, then cleanup; guard failures held with Copy Raw). Settings: three cleanup toggles, Faithful Transcription, learning toggle, dictionary editor. `failed` and `unverified` insertions now show different messages. A corrupt dictionary disables only processing, not dictation. |
| Model downloader | `c68f308` | `app/ModelDownload.swift`: pinned Hugging Face download (19 files, 1,801,783,964 bytes), streaming SHA-256/blob-SHA-1 verification, cancel, resume, remove, staged atomic install. URL scheme verified with real small-file downloads; the full weights were never downloaded. |
| Gemini STT and local cleanup server | `df62098` | Gemini audio transcription through `generateContent` (LLM transcriber: structured JSON, temperature 0, silence skip, answer-suspected flag). OpenAI-compatible local cleanup server (Ollama, LM Studio, llama-server, vLLM), with host-based disclosure (only loopback counts as on-device) and redirects refused. PRD section 5 was revised to match; it's still a proposal. |
| App wiring: downloads, retention, updates | `e0b39b4` | Model row in Settings (license shown before download), history cap, history-off mode (memory-only recovery until quit), Delete All Data (includes Keychain), GitHub update check (launch, hourly at most, manual menu item; opens the release page only). `build.sh` now builds with `-O`. |
| Gemini 3.5 Transcribe | `de72390` | `GeminiTranscribeProvider`: Interactions API (`POST /v1beta/interactions`), verbatim mode, `en-US`, custom vocabulary, `store: true`; Google keeps stored interactions 55 days (paid) or 1 day (free), deletable by ID (IDs not persisted yet). |
| Routes, keys, disclosure, lexicon | `5e89d18` | `app/Routes.swift`: Local/Cloud transcription (Gemini 3.5 Transcribe default cloud choice, OpenRouter Whisper, Gemini audio LLM) and cleanup (rules, local server, Gemini, OpenRouter) with no fallback; disclosure alert before first use of any off-Mac route and on change; Keychain key rows with Validate; Escape cancels a cloud request; NSSpellChecker backs the learning lexicon. |

Every Controller/UI/main change is **uncompiled on the Mac**. Workers type-checked Controller and UI against stub AppKit/SwiftUI modules on Linux, which catches names and bindings but not real SDK signatures. Expect the first `app/build.sh` run to need fixes. [Certain]

Still not wired: onboarding, VoiceOver announcements, launch at login, input-device selection. Decided since: pursue `gemini-3.5-transcribe` with stored requests; promotion rule approved. [Certain]

Learning from corrections is wired in (October 4, 2026): verified insertions into learning-eligible fields are watched with `spike/Observation.swift`, and the ledger receives the original-case span so the approved filter decides. Live probe into TextEdit: "Please call ACME about the invoice" was inserted and edited to "Akme" by AX in two sessions. A further run that selected the word and typed over it with keystrokes also settled evidence. That promoted a learned `Akme` ← `ACME` entry, and the third dictation inserted "Akme". Test data, settings and documents were restored afterwards. Typing after the dictated span or editing outside it still drops that session's evidence. Fixing a word through a right-click spelling suggestion is untested (the menu may move AX focus and end the window early). `refreshDictionary()` runs after every settle, so learned entries reach the Parakeet vocabulary file (`writeHelperVocabulary`) as soon as they are promoted. [Certain]

Installed `main` at `42dfd64` (learning merged) to `~/Applications/Murmur.app`, executable SHA-256 `287671065e70d617781234aee8b2fd2fb21ce2d6ca26f2689d424efae9950339`; the previous build is at `~/Applications/Murmur-backups/20261004-205537/Murmur.app`. Before install, all documented silent checks passed on that commit, and a live TextEdit probe promoted `Akme` ← `ACME` after two keystroke fixes and applied it on the third dictation. [Certain]

Learning bug found by the user (October 4, 2026): real dictations never learned, because the whole dictated span reached `CorrectionFilter`, which rejects any punctuation (`unsupportedCharacters`), so "Hi, my name is Akash." → "…Aakash." was dropped. Earlier live probes passed only because their synthetic sentence had no punctuation. `ProcessingCoordinator.observeSpan` now passes only the changed words (`changedWords`; superseded on the Wispr-style branch by the ledger's case-sensitive word diff, which also skips punctuation and keeps capitalisation fixes learnable). Live TextEdit probe with "Hi, my name is Akash": two keystroke fixes promoted `Aakash` ← `Akash`, and the third dictation inserted "Aakash". [Certain]

Learning in non-standard fields (October 4, 2026, user request): live probe runs, each dictating "Please call ACME about the invoice" and then fixing the word with System Events keystrokes (Option-Left ×4, Shift-Option-Right, type "Akme"), then activating Finder. Every case settled one `ACME` → `Akme` correction in the ledger. Settings, dictionary and test History were restored afterwards. [Certain]

| App and field | Delivery | Observation route |
|---|---|---|
| Chrome, plain textarea | paste, unverified | keystrokes |
| Chrome, contenteditable | paste, unverified | keystrokes |
| Safari, textarea | unverified | AX read-back |
| Arc, textarea | unverified | AX read-back |
| VS Code, default settings | paste, unverified | keystrokes |
| Google Docs in Chrome, default settings (a new doc from docs.new, left in the user's Drive) | paste, unverified | keystrokes |

The first keystroke run recorded `akme`: System Events' synthetic keys carry only the Shift flag, not the shifted character. Shift and Caps Lock are now applied to letters; a rerun in Chrome and VS Code then recorded `Akme`. Untested: autocorrect in the target app, IME input, right-click spelling fixes, Slack/Discord. [Certain]

**Mac-side next steps**
1. Pull this branch, run `app/build.sh` and every check in `app/README.md` (including `check_ui.sh`) on the macOS 26 host. Fix anything that fails under Swift 6.3.3 and `-swift-version 5`. [Certain]
2. Run a live key test per provider: OpenRouter STT, OpenRouter chat, Gemini `generateContent`, and the Fireworks turbo host only if it is to be offered. Record status codes and error shapes; do not offer a route in settings until its test passes. [Certain]
3. Back the learning lexicon with NSSpellChecker (`isCommonWord`) before shipping learning. Without it, real-word swaps such as casual→causal pass the filter and can promote. [Certain]
4. Get user approval for the proposed provider split and the proposed promotion rule. [Certain]

**User decisions, October 3, 2026:** MIT `LICENSE` added with holder "Aakash"; the promotion rule is approved (NSSpellChecker lexicon still required before learning ships); pursue Gemini 3.5 Transcribe and accept Google storing requests (must be disclosed); Apple Developer enrollment deferred, so Developer ID signing and notarization remain blocked. [Certain]

---

# Open issues — October 3, 2026 (after merging `aakash-module-one` into main; updated at the session checkpoint above)

Merged state: module-one's standalone glass-dot indicator and error-only popup replace main's three-pill bubble; main's Murmur naming, active event tap (`ShortcutListener.createTap()`, Control–Option–Space Space and Escape-while-recording swallowed), permission refresh on activation, "No speech was detected" message, Audio gating and stable signing identity are kept. The merge was resolved on Linux without a Swift toolchain, so **the merged app has not been compiled or run**; run `app/build.sh` and the checks in `app/README.md` first. [Certain]

**Fixed by module-one**
- ~~Saved and Error bubbles stay on screen with no dismiss control~~: Saved and Inserted show no popup; the Error popup has a dismiss button, and idle errors can be dismissed in settings.
- ~~The pills follow a timer, not the microphone level~~: the glass dots follow `Capture.level` while listening (processing is still a timed pulse). Live microphone responsiveness is untested.
- ~~The indicator has never been seen in pixels~~: the glass dots and error popup were inspected in the native UI fixture (light, dark, opaque fallback). The real panel over a destination app is still unseen.
- Consecutive dictations gluing words: partly addressed by the default-off "Intelligently add a leading space" toggle; live insertion is unverified.

**Murmur app**
1. A refused insertion (`failed`) and an uncertain one (`unverified`) share the "Delivery could not be verified" message; with no Saved popup it is now visible only in settings and History.
2. The bubble's Audio button shows when this error's audio is known (selects that file) or when any retained audio exists (opens the retry folder). Confirm this union is the intended behavior.
3. Settings changes take effect only after Apply Settings.
4. No onboarding, dictionary editor or learning controls. Cleanup, cloud providers, Keychain credentials, dictionary, learning, retention cap and update checks now exist as checked Foundation-only modules, but are not wired in; wiring is in progress. The model downloader is in progress; until then the model folder is chosen manually.
5. Corrupt history blocks startup; there is no user-visible repair path.

**Shortcut and capture**
6. Every shortcut uses an active event tap: Accessibility is required for all bindings, and a stalled main thread delays keystrokes system-wide. Clean failure without Accessibility on macOS 26.6 is unverified.
7. Escape swallowing is covered by deterministic checks only; repeats of an Escape held from before recording still pass through.
8. The Fn binding, physical key timing and first-word preservation with real speech are untested live.

**Insertion and observation**
9. ~~The paste fallback's fixed 300 ms settle can double-insert if an app applies an AX write later.~~ Resolved October 4, 2026: no AX write any more, paste only.
10. A browser password field not marked secure would receive a paste (accepted risk).
11. Learning is unsupported in Arc fields, default Google Docs and VS Code; permission revocation mid-session, clipboard-manager races and cross-session learning are untested.

**Product, release and housekeeping**
12. ~~The PRD cleanup-failure conflict (section 3 vs section 4) is unresolved.~~ Resolved in PRD "Milestone 1 implementation decisions": cleanup errors and guard failures both save the raw transcript, show recovery, and require an explicit raw-text action before insertion.
13. Builds are self-signed (`clouddev Development`); Developer ID signing and notarization need an Apple Developer Program account.
14. Bundle ID `cc.clouddev.dictation.development`, the `~/Library/{Application Support,Caches}/Dictation` folders, the `Dictation-preview-` temp folders, notification names and the repository still use the old name.
15. Test transcripts from live runs remain in Murmur's History.
16. ~~No LICENSE file~~: added (MIT, Aakash). `README.md`, `CONTRIBUTING.md` and `THIRD_PARTY_NOTICES.md` now exist.
17. The new modules have never been compiled on the Mac; the Keychain store has never been compiled at all.

**Processing and providers**
18. No provider has been called with a real API key. Fireworks STT is deprecated upstream; the OpenRouter STT and Gemini/OpenRouter cleanup split is a proposal pending user approval.
19. The local cleanup model is unselected. `RuleCleaner` is a baseline; its corpus has no real ASR transcripts, and the guard will hold more real LLM output than baseline output.
20. Learning's lexicon check needs NSSpellChecker on macOS before learning ships; the semantic promotion rule is approved.
21. The Parakeet conversion's CC-BY-4.0 label conflicts with the upstream NVIDIA Open Model License; the app must show the model license before download.

---

# History from main (`aakash/bubble-pill-indicator`)

# Bubble indicator and Murmur rename — October 2, 2026

Branch `aakash/bubble-pill-indicator`, from `aakash-module-one` at `900ad61`. The app is now named **Murmur** in everything users see: window, menus, microphone prompt and `runtime/Murmur.app/Contents/MacOS/Murmur`. The bundle ID `cc.clouddev.dictation.development` and the Application Support/Caches `Dictation` folders are unchanged, so permissions, settings, history and the model cache carry over. The Listening and Processing bubbles show three white pills: a wave while listening, a sequential pulse while processing. They are static with Reduce Motion and use the primary color on the Reduce Transparency/Increase Contrast fallback. The pills are timed, not driven by audio level. [Certain]

The app compiles, and the history checks pass. A standalone pill render matches the intended shapes. The live app run did not happen: the Mac's screen was locked (`CGSSessionScreenIsLocked=1`), so focus capture returned `com.apple.loginwindow` and every `--test-audio` probe refused before insertion. Nothing was inserted. Storage and pinned model sizes were verified by the same diagnostic. Pixel screenshots also need Screen Recording granted to the Claude app, because the development build cannot be granted to the computer-use tool. A copy is installed at `~/Applications/Murmur.app` for that purpose. [Certain]

Live run (same day, Mac unlocked, `~/Applications/Murmur.app` with Microphone, Accessibility and Input Monitoring granted to Murmur itself, synthetic audio only, throwaway TextEdit document): [Certain]

| Scenario | Observed bubble states | Result |
|---|---|---|
| `--test-audio` probe | Processing → Inserted | Transcript inserted into TextEdit |
| Probe, focus moved to Finder during processing | Processing → Saved | Kept in History; nothing inserted |
| Injected Control–Option–Space hold, synthetic speech through speakers into the real microphone | Listening (Stop/Cancel) → Processing → Inserted, auto-hid about 1.6 s later | Shortcut → mic → local model → inserted; no stray space |
| Hold, then Escape | Listening → hidden | Canceled; nothing inserted |

Found and fixed during the run: Control–Option–Space typed its Space into the destination, because both the spike listener and the app's own tap were listen-only. The chord now uses an active tap that drops only the chord's Space (`672badc`, `b3f14df`). At 19% output volume the recording reached only -45 dBFS. The model returned an empty transcript, and the app reported "Transcription failed"; that message should say no speech was detected. [Certain]

Follow-up on the same day: four agent fixes were merged (`8c449d9` permission refresh on activation with automatic shortcut start; `a6d0937` "No speech was detected" for empty transcripts, with the audio kept; `6d605cd` the Audio button only when retry audio exists, selecting that file; `b06a0ec` Escape swallowed only while listening, via one shared `ShortcutListener.createTap()`). Builds are signed with the self-signed `clouddev Development` identity (`c439c34`). Its designated requirement is the bundle ID plus the certificate root, so grants persist across rebuilds. After a one-time user-run `tccutil reset` and re-grant, the status line updated to all-allowed without a relaunch or Apply Settings. [Certain]

Live rerun on the merged, signed build: the probe inserted; the probe with focus moved was Saved; the injected Control–Option–Space hold with speech through the microphone went Listening → Processing → Inserted with no stray space; hold-then-Escape canceled; and a silent hold showed "No speech was detected. Check your microphone and try again." with History and Audio. All active shortcuts now require Accessibility as well as Input Monitoring. [Certain]

Remaining app issues: a refused insertion (`failed`) shows the same "Delivery could not be verified" message as an uncertain one. A Saved/Error bubble stays on screen until the next action. Escape swallowing is covered by deterministic checks, not observed in a destination app. The bubble and pills have not been seen in pixels, because Screen Recording is not granted to Claude. [Certain]

---

# History from `aakash-module-one`

# Standalone glass dots — in progress, October 2, 2026

User requested removal of the live indicator capsule: standalone voice-reactive Liquid Glass dots on a transparent background. Plan: remove matte background, border, and padding; use circular native glass surfaces and preserve reduced-transparency/increased-contrast fallback. Implemented standalone circular native glass dots, transparent unpadded 80×24-point live panel, and no outer panel shadow. Production/fixture builds passed; native dark preview showed only dots with accessible Listening label. Implementation committed as 17eca1c; signed installed bundle verified and replaced, backup at /Users/aakash/Applications/Murmur-backups/20261002-224829/Murmur.app. Installed Murmur reopened Ready with settings and permissions retained. Visual fixture confirmed standalone dots; production build and signature checks passed. Live microphone responsiveness not newly tested. Checkpoint ready for GitHub push. [Certain]

---

# Matte glass indicators — in progress, October 2, 2026

User requested a smaller clickable error popup and neutral glass voice pills over a contrasting matte surface. Plan: narrow the error panel and reduce its padding/type; replace blue circles with reactive capsules using native glass and an opaque accessibility fallback. Preserve popup click-through, dismissal, and recovery audio. [Certain]

Checkpoint: source changes implemented: 240-point error panel, 12-point summary, 8-point padding; reactive neutral 7-point capsules with native glass over an opaque matte background and Reduce Transparency/increased-contrast fallback. Production and fixture builds passed. Native dark-mode error and listening previews passed: smaller clickable error, neutral contrasting pills without blue. Light appearance also passed native visual inspection. Evidence: runtime/glass-review/matte-glass-dark.png and matte-glass-light.png. Implementation committed as 597ecfe; installed Murmur replaced with the signed verified build. Backup: /Users/aakash/Applications/Murmur-backups/20261002-223935/Murmur.app. Reopened installed Murmur: Ready, existing Fn shortcut/leading-space preference/model and permissions retained. Light/dark synthetic visual checks passed; no new live recording or insertion claim. Final checkpoint committed with implementation for GitHub push. [Certain]

---

# Clickable errors — October 2, 2026

Removed Details from the compact error panel. Clicking its surface opens the app and selects Dictation to show the full error; Dismiss and Audio remain independent controls. The popup is exposed as an accessible button with an error label and open-app hint. [Certain]

---

# Compact indicators — October 2, 2026

User superseded the optional minimal display: compact voice indicators are now the default (96 points), with no Saved or Inserted popup. Only errors show short messages and Details/conditional Audio actions. Full status remains in settings and History. The prior minimal-display preference is ignored; leading-space settings remain available. [Certain]

---

# Intelligent leading-space checkpoint — October 2, 2026

Added a default-off, locally persisted leading-space toggle. The setting is captured at recording start; spacing uses the original destination context before the existing single-attempt safety check. Raw history remains unchanged, and final history records insertion text. Deterministic checks cover whitespace, punctuation, selection, word interiors, unavailable/invalid context, and UTF-16 emoji boundaries. Live target-app insertion remains unverified. [Certain]

---

# Minimal transcription display — October 2, 2026

Added a locally saved, default-off setting that shows only compact voice-reactive circles during Listening, a processing pulse, and brief completion. Errors, saved output, and uncertain delivery retain recovery details. Native minimal Listening/Processing panel inspection confirmed no visible status text and accessible phase labels with Listening shortcut help. The toggle switched both ways, and minimal-mode errors retained Copy Text, History, Settings, and Dismiss. Production build and controller mode/recovery checks passed. Live microphone responsiveness remains unverified in this checkpoint. [Certain]

---

# Liquid Glass checkpoint — October 2, 2026

User approved autonomous native Liquid Glass direction across settings, History, and the status bubble. Implemented native glass surfaces and controls, fixed action footers, semantic text contrast, and opaque accessibility fallbacks. Production build and synthetic UI fixture compile passed. [Certain]

Captured light, dark, and forced opaque compact appearances. Independent scoped contrast review resolved its findings; the final light search placeholder measured approximately 5.8:1. Native search filtering/clearing passed. The real floating panel Dismiss click hid the panel, and the fixture asserted recovery history remained. Evidence is local and ignored under runtime/glass-review/. [Certain]

Remaining validation: actual destination focus preservation, physical shortcut/microphone behavior, live speech, insertion, and clipboard races. The opaque fixture exercises the fallback branch without changing system accessibility preferences. See app/README.md for repeatable fixture commands and DESIGN.md for native design values. [Certain]

---

# Native app recovery and UI checkpoint — October 2, 2026

This supersedes the older no-app-skeleton continuation below. Branch `aakash-module-one` now contains the native app in `app/`; build/run/check instructions and current evidence are in `app/README.md`. [Certain]

Three delegated reviewers covered recording lifecycle, history/settings, and insertion safety, followed by a UI review. Fixed idle error dismissal, stale shortcut callbacks, monitor pauses during menu tracking, probe input deletion, unsafe probe arguments, invalid retention, and mismatched/corrupt history handling. Settings now show state/model/individual permissions with a fixed Apply footer; History has search and delivery status; the bubble has dismissal and context-sensitive audio recovery. [Certain]

The app builds; launch/history/controller/session/processor/spike checks pass. Native synthetic UI inspection verified idle Error to Ready, retained recovery entries, settings and History layouts, filtered selection and no-results search. No live recording/insertion or physical-key claims are added. See `app/README.md` for the exact boundary. [Certain]

Next steps: validate physical-key first-word capture and error/restart behavior with the actual app, verify the floating bubble click path without stealing destination focus, then repeat live per-app insertion and clipboard-race cases. Genuine labeled speech benchmarks and cleanup/model-management work remain open. Corrupt history currently blocks startup; a user-visible repair path remains future work. [Certain]

---

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
