# Native Murmur app

Build the local development bundle on Apple Silicon/macOS 26:

```sh
app/build.sh
open runtime/Murmur.app
```

The bundle uses the pinned local ModelBench helper. Model download, cloud providers in the UI, automatic correction learning, signing/notarization, and production release remain separate work. [Certain]

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
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/UI.swift app/check_controller.swift -o /tmp/dictation-controller-check
/tmp/dictation-controller-check
```

## Processing: dictionary, cleanup and recovery

`Processing.swift` is Foundation-only and is compiled into the app. `ProcessingCoordinator` runs after transcription, on the main thread:

1. `DictionaryStore.apply` runs first, in every mode including faithful transcription.
2. Cleanup runs on the selected route with the enabled options. Settings offer only the local `RuleCleaner` route. The cloud route (`CleanupProvider` via `CleanupPrompt`, with only the relevant dictionary entries) is tested but not exposed, and the app's synchronous path never calls the network: a cloud route holds rather than falling back to local.
3. A cleaner error or a guard failure returns `.heldForRecovery(raw:reason:)`. The controller saves the raw transcript with status `held-cleanup` and shows an error. It does not insert. History offers **Copy Raw**. The reason is content-free and is not stored.

Settings has three independent cleanup toggles, a Faithful Transcription button, a learning toggle, and a dictionary editor (add, delete, learned/manual badge, Reset Learned). Cleanup and learning settings take effect on Apply Settings; dictionary edits save immediately. Automatic observation of edits is not wired in, so nothing feeds learning yet. The settings keys are `cleanupFillers`, `cleanupCorrections`, `cleanupLists`, `cleanupRoute`, `learningEnabled`, `historyMode` and `updateChecksEnabled`; the last two are only persisted for now. A corrupt `dictionary.json` or `ledger.json` blocks startup, like corrupt history. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/check_processing.swift -o /tmp/murmur-processing-check
/tmp/murmur-processing-check
```

The processing check passes with Swift 6.1.2 on Linux. The Controller/UI integration has only been typechecked on Linux against hand-written AppKit/SwiftUI stubs; it has not been built or run on the Mac. [Certain]

## Dictionary, learning and retention (not yet wired in)

`Dictionary.swift`, `Learning.swift` and `Retention.swift` are Foundation-only, so their checks also run on Linux. They are compiled into the app through `Processing.swift`. The history cap, history-off mode and Delete all data are not wired into Controller/UI yet.

```sh
swiftc app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd
```

- `DictionaryStore` keeps `dictionary.json` (0600, directory 0700). `apply(to:)` replaces exact variants as whole words and space-separated phrases (case-insensitive, longest match, never fuzzy). It inserts the preferred spelling as stored, and capitalizes its first letter only at a sentence start when the spelling is all lowercase. `relevantEntries(for:)` returns only the entries present in the text, which is what a cloud stage may receive.
- `CorrectionLedger` keeps `ledger.json` with short source/target strings only. The flow per session is `record` (provisional) while the window is open, then `settle` when it closes; `revert` undoes. It promotes after two settled, consistent sessions (case-folded). A conflicting target suppresses the source until `reset()`. A deleted learned entry is tombstoned and its evidence cleared. With learning off, nothing is recorded.
- `Retention.swift` covers the 50 MB history cap (drop oldest first; Forever warns via `HistoryCapStatus`), the history-off disclosure, and `DataWipe.deleteAllData`. Six-month and 30-day expiry stay in `HistoryStore`.

**Proposed promotion rule (pending user approval).** A correction counts as learning evidence only if the target is a plausible respelling of the source. All of these must hold:

1. Structure: 1–3 words per side after trimming shared context words. Case-only, punctuation-only and spacing-only edits are rejected, as are deletions, insertions/appends and longer rewrites.
2. Meaning guards: reject negation flips (not/n't/un-/dis-…), digits or number words, listed antonyms, function words and listed homophones, inflection-only changes and vowel-only changes in short words. When an optional `isCommonWord` lexicon is supplied (NSSpellChecker on macOS), reject swaps where every word on both sides is an ordinary word.
3. Respelling: at least 4 letters per side, and either edit similarity ≥ 0.75, or equal consonant-class phonetic keys with similarity ≥ 0.5.
4. Known terms: if the target is already a manual entry's preferred spelling, rule 3 is waived, but not rules 1–2.

Known failure modes: without the lexicon, real-word swaps that look like respellings (casual→causal, lunch→launch, Cloud→Claude) are accepted, and two such corrections would promote them. Similar names (Robert→Rupert) are accepted, because they look like transcription errors. Legitimate respellings are skipped when they are short (Jon→John), add an `s` (Postgres→Postgress), only change spacing (Micro soft→Microsoft), or involve numbers. [Certain]

### Cloud providers, credentials, and updates

`Providers.swift`, `Credentials.swift`, and `Updates.swift` use only Foundation. `build.sh` compiles `Providers.swift` and `Credentials.swift` because `Processing.swift` uses their types, but no provider, key or update check is reachable from the app yet; `Updates.swift` is not compiled into the app. Their checks need no network and no keys. They pass with Swift 6.1.2 on Linux. They have not yet been compiled on the macOS 26 host (Swift 6.3.3, `-swift-version 5`), and the Keychain store is compiled only on macOS. [Certain]

```sh
swiftc app/Cleanup.swift app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-providers-check
/tmp/murmur-providers-check
swiftc app/Updates.swift app/check_updates.swift -o /tmp/murmur-updates-check
/tmp/murmur-updates-check
```

No provider call has been made with a real API key. The request shapes come from official documentation, and the error shapes from documentation or from unauthenticated responses (see [PROVIDERS.md](PROVIDERS.md), verified October 3, 2026). Fireworks deprecated audio inference on June 10, 2026. OpenRouter's transcription endpoint is the documented alternative. Each route needs a live check with a real key before it is offered. [Certain]

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

## Model download (not yet wired in)

`ModelDownload.swift` is Foundation-only and not in `build.sh` yet; the integration lead wires it into Controller/UI. [Certain]

```sh
swiftc -swift-version 5 app/ModelDownload.swift app/check_model_download.swift -o /tmp/cm && /tmp/cm   # run from the repository root
```

- `ModelManifest(contentsOf:)` reads `artifact-pins.json`. It keeps only the pinned `batch_files` for `FluidInference/parakeet-unified-en-0.6b-coreml` and requires a 40-hex revision. It rejects unsafe `rfilename`s (absolute, `..`, `.`, empty segments, backslashes, control characters). `totalBytes` is the download size to show first: 1,801,783,964 bytes (~1.80 GB) for the current pins.
- `ModelDownloader.install(progress:)` blocks; `start(progress:completion:)` runs it on a background queue. It fetches `https://huggingface.co/<repo>/resolve/<revision>/<rfilename>` into a hidden sibling `.<name>.download-<rev12>`. It checks each file's size, then its SHA-256 (LFS files) or blob SHA-1 (other files) through `FileHasher`. Only when every file passes is staging renamed onto the target. An existing model is first renamed aside, then restored if the rename fails. Stray staged files are deleted, not installed.
- `cancel()` keeps verified and partial files in staging. The next `install` re-hashes verified files locally instead of re-downloading them, and resumes a partial with `Range` (or restarts it if the server sends 200). `remove()` deletes the target and staging.
- `status()` returns `notDownloaded`, `downloading(progress)`, `verifying`, `ready`, `corrupt(reason)` or `failed(error)`. It is a cheap size check, the same as `modelFilesAvailable`. `verifyInstalled()` hashes every file.
- `ModelDownloadError` covers network, disk full (preflight and ENOSPC), checksum mismatch, HTTP status, cancelled, invalid manifest, unsafe path, file system, and busy. Each `userMessage` names no file, path, or URL.
- `license` is read from the manifest only when the manifest records one. The current pins record none, so the downloader shows both model-card declarations and says they are unresolved: upstream NVIDIA Open Model License, conversion CC-BY-4.0.

The SHA-256/SHA-1 code is pure Swift because CryptoKit is unavailable on Linux. It runs at about 56 MB/s on SHA-256 in an unoptimized build on the Linux dev box, and about 210 MB/s with `-O`. On October 3, 2026, `URLSessionModelTransport` installed four small pinned files through the real Hugging Face redirects on Linux. All four verified, and a `Range` request returned 206. The full weights were not downloaded, and the code has not been compiled on macOS yet. [Certain]

## Cleanup

`Cleanup.swift` is Foundation-only. The app uses it through `Processing.swift` (see above). It provides:
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
