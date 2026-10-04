# Native Murmur app

Build the local development bundle on Apple Silicon/macOS 26:

```sh
app/build.sh
open runtime/Murmur.app
```

The bundle uses the pinned local ModelBench helper. `build.sh` compiles the app with `-O` (see [Model download, retention and updates](#model-download-retention-and-updates-wired-in)). Cloud transcription and cleanup routes and API keys are wired in (see [Processing routes and API keys](#processing-routes-and-api-keys-wired-in)) but untested with real keys. Automatic correction observation, signing/notarization, and production release remain separate work. [Certain]

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
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Routes.swift app/UI.swift app/check_controller.swift -o /tmp/dictation-controller-check
/tmp/dictation-controller-check
```

## Processing: dictionary, cleanup and recovery

`Processing.swift` is Foundation-only and is compiled into the app. `ProcessingCoordinator` runs after transcription, on the main thread:

1. `DictionaryStore.apply` runs first, in every mode including faithful transcription.
2. Cleanup runs on the selected route with the enabled options. Local rules (`RuleCleaner`) run synchronously through `process`. Any other route (Gemini, OpenRouter or a local model server) goes through `processAsync`: one `CleanupProvider` call via `CleanupPrompt`, with only the relevant dictionary entries, on the main actor except for the request itself. An unconfigured provider or a provider error holds; nothing falls back to local rules. The synchronous path still never calls the network.
3. A cleaner error or a guard failure returns `.heldForRecovery(raw:reason:)`. The controller saves the raw transcript with status `held-cleanup` and shows an error. It does not insert. History offers **Copy Raw**. The reason is content-free and is not stored.

Settings has three independent cleanup toggles, a Faithful Transcription button, a learning toggle, and a dictionary editor (add, edit in place, per-entry on/off, delete, learned/manual badge, Reset Learned). Cleanup and learning settings take effect on Apply Settings; dictionary edits save immediately. Automatic observation of edits is not wired in, so nothing feeds learning yet. The settings keys are `cleanupFillers`, `cleanupCorrections`, `cleanupLists`, `cleanupRoute` (derived from `cleanupChoice`, see below), `learningEnabled`, `historyMode` and `updateChecksEnabled`. The last two are wired in (see below) and are also written directly on Apply Settings, so they persist when the dictionary is unavailable. A corrupt `dictionary.json` or `ledger.json` blocks startup, like corrupt history. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/check_processing.swift -o /tmp/murmur-processing-check
/tmp/murmur-processing-check
```

The processing check passes with Swift 6.1.2 on Linux. The Controller/UI integration has only been typechecked on Linux against hand-written AppKit/SwiftUI stubs; it has not been built or run on the Mac. [Certain]

## Dictionary, learning and retention

`Dictionary.swift`, `Learning.swift` and `Retention.swift` are Foundation-only, so their checks also run on Linux. They are compiled into the app through `Processing.swift`. The history cap, history-off mode and Delete all data are wired in through `AppServices.swift` (see [Model download, retention and updates](#model-download-retention-and-updates-wired-in)).

```sh
swiftc app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd
```

- `DictionaryStore` keeps `dictionary.json` (0600, directory 0700). `apply(to:)` replaces exact variants as whole words and space-separated phrases (case-insensitive, longest match, never fuzzy). It inserts the preferred spelling as stored, and capitalizes its first letter only at a sentence start when the spelling is all lowercase. `relevantEntries(for:)` returns the entries present in the text, plus up to 10 whose preferred spelling sounds like a 1–3 word span (`DictionaryStore.soundsLike`: matching phonetic keys and similarity ≥ 0.5, or similarity ≥ 0.75 for terms of 6+ letters). That is what a cloud stage may receive. Near matches only feed the cleanup prompt and the guard, which then accepts the term in place of 1–3 sound-alike words; `apply` never uses them.
- `CorrectionLedger` keeps `ledger.json` with short source/target strings only. The flow per session is `record` (provisional) while the window is open, then `settle` when it closes; `revert` undoes. It promotes after two settled, consistent sessions (case-folded). A conflicting target suppresses the source until `reset()`. A deleted learned entry is tombstoned and its evidence cleared. With learning off, nothing is recorded.
- `Retention.swift` covers the 50 MB history cap (drop oldest first; Forever warns via `HistoryCapStatus`), the history-off disclosure, and `DataWipe.deleteAllData`. Six-month and 30-day expiry stay in `HistoryStore`.

**Proposed promotion rule (pending user approval).** A correction counts as learning evidence only if the target is a plausible respelling of the source. All of these must hold:

1. Structure: 1–3 words per side after trimming shared context words. Case-only, punctuation-only and spacing-only edits are rejected, as are deletions, insertions/appends and longer rewrites.
2. Meaning guards: reject negation flips (not/n't/un-/dis-…), digits or number words, listed antonyms, function words and listed homophones, inflection-only changes and vowel-only changes in short words. When an `isCommonWord` lexicon is supplied, reject swaps where every word on both sides is an ordinary word. The app supplies NSSpellChecker (English) through `ProcessingCoordinator(directory:isCommonWord:)`: a word is common when the checker finds no misspelling.
3. Respelling: at least 4 letters per side, and either edit similarity ≥ 0.75, or equal consonant-class phonetic keys with similarity ≥ 0.5.
4. Known terms: if the target is already a manual entry's preferred spelling, rule 3 is waived, but not rules 1–2.

Known failure modes: without the lexicon (the Linux checks, or if the spell checker misjudges a word), real-word swaps that look like respellings (casual→causal, lunch→launch, Cloud→Claude) are accepted, and two such corrections would promote them. Similar names (Robert→Rupert) are accepted, because they look like transcription errors. Legitimate respellings are skipped when they are short (Jon→John), add an `s` (Postgres→Postgress), only change spacing (Micro soft→Microsoft), or involve numbers. [Certain]

### Cloud providers, credentials, and updates

`Providers.swift`, `Credentials.swift`, and `Updates.swift` use only Foundation. `build.sh` compiles all three. Providers and keys are reachable from Settings through `Routes.swift` (see [Processing routes and API keys](#processing-routes-and-api-keys-wired-in)). The update checker is wired in (see below). Their checks need no network and no keys. They pass with Swift 6.1.2 on Linux. They have not yet been compiled on the macOS 26 host (Swift 6.3.3, `-swift-version 5`), and the Keychain store is compiled only on macOS. [Certain]

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
app/check_ui.sh --light --dictionary
```

`--dictionary` seeds three sample entries (one turned off); open Settings → Dictionary to see them. The fixture forces only its own appearance. `--compact` uses the minimum production window size, while `--opaque` forces the same opaque rendering branch used by Reduce Transparency for the settings/History view. The separately hosted floating bubble continues to use actual system accessibility settings. [Certain]

The developer audio probe requires both flags and must target a disposable field:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

This explicitly performs transcription and one insertion attempt. It preserves the supplied audio, using a private retry copy, and writes durable history. It cannot be combined with preview or timed quit; malformed flags exit before storage/UI initialization. [Certain]

## Model download

`ModelDownload.swift` is Foundation-only and compiled into the app; see the next section for the wiring. [Certain]

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

## Model download, retention and updates (wired in)

`AppServices.swift` is Foundation-only and holds the decisions that Controller and UI only display or act on. Controller keeps the AppKit calls (alerts, `NSWorkspace`) and the wiring. [Certain]

```sh
swiftc app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/check_app_services.swift -o /tmp/murmur-app-services-check
/tmp/murmur-app-services-check   # run from the repository root; it reads app/Info.plist
```

**Model (R2).** Settings → Recording shows a model row: name, download size (`downloader.downloadSize`, 1.80 GB), English, Runs on this Mac, status, and Download / Retry / Cancel / Remove. Both license declarations are listed with links, and the note says the license is unresolved. Download first shows an alert with the size and the full license text, so nothing is fetched before the license is shown. The downloader targets the existing default folder `~/Library/Caches/Dictation/module-one/unified-d32e972` with the bundled `artifact-pins.json`, so a model already there shows as Downloaded. The main-thread monitor timer samples progress and the verifying phase (`status()` is lock-protected). Completion is marshaled with `DispatchQueue.main.async`. On success, `modelDirectory` is set to that folder and saved. The folder chooser remains as an advanced option, with Use Default.
- Recording is refused with recovery text when the model or runtime is missing ("Download the model in Settings, or choose a downloaded model folder"), and while a download is replacing the folder dictation would use.
- Download and Remove are refused while recording or processing (checked again after their confirmation alert), and in preview, which must not touch the real model cache. Remove is also refused while a download runs. Quitting cancels a download; staged files are kept and Retry resumes them.

**Build speed.** `build.sh` compiles the app with `-O`. The pure-Swift SHA-256 is about 56 MB/s unoptimized and 210 MB/s with `-O` on the Linux dev box, so verifying 1.8 GB drops from about 32 s to about 9 s. No `assert()` is reachable in the app (only spike test helpers that the app never calls use it), so `-O` removes no runtime checks. `precondition`, overflow traps and exclusivity checks stay on. `check_ui.sh` and the checks stay unoptimized. [Certain]

**History cap (R9, §6).** `HistoryCap.enforce` runs at launch, after each dictation's final save, on Apply Settings and in the 60-second purge. Finite retention drops the oldest entries over 50 MB but always keeps the newest. With Forever, nothing is dropped and the cap warning shows under Keep transcripts. A cap failure at launch or after a dictation only shows a warning. [Certain]

**History off.** Settings → Output and history has a Transcript history picker. Choosing Off shows `HistoryMode.offDisclosure`, and Apply Settings asks for confirmation. All history reads and writes go through `HistoryRouter`:
- With history off, entries are kept only in memory, so a held cleanup or a failed or uncertain insertion can still be copied from History until Murmur quits. Nothing is written to disk. Disk save failures still surface as errors and are not silently moved to memory.
- Memory entries stay in memory if history is turned back on, so one dictation never splits across disk and memory. They follow the retention cutoff and are limited to the newest 100.
- History marks them "Not saved to disk", completion messages say "Kept in History until Murmur quits", and the header says history is off.
- Turning history off does not delete existing history.
- Retry audio is separate: it still follows the 24-hour policy. [Certain]

**Delete All Data (§6).** Settings → Output and history has a button that asks for confirmation, then runs `DataWipe.deleteAllData` on history, dictionary/ledger and retry audio. It also calls `KeychainCredentialStore(service: "Murmur").deleteAll()`, which is skipped in preview. Then it follows `PostWipeStep` in order: discard in-memory state (including memory-only history), recreate history, recreate retry audio, rebuild `ProcessingCoordinator` (it re-reads the now-empty dictionary and ledger), and refresh. Each step runs even if an earlier one fails, and failures are reported. Settings and the downloaded model are kept. Backups or snapshots may still hold copies. [Certain]

**Updates (R12).** `Updates.swift` is compiled into the app. When `updateChecksEnabled` is set, outside preview, an automatic `check(manual: false)` runs at launch. The 60-second timer then attempts one at most hourly (`UpdateSchedule`). `UserDefaultsUpdateCheckStore` limits completed checks to one a day across relaunches. The hourly limit exists because offline attempts do not count toward that daily throttle. Check for Updates (Settings and the menu bar) runs `check(manual: true)`. Results only change the Updates status line in Settings and the menu item title. They never change the dictation phase or show a bubble. An available release shows its title and plain-text notes, plus Open Release Page, which opens the validated GitHub page through `NSWorkspace`. Nothing is downloaded. The toggle explains that checks use the network even though inference is local. The current version comes from `CFBundleShortVersionString` (`0.1.0`). The repository is still the `Penguin0011/dictation` default in `UpdateConfiguration`. [Certain]

**Verified on Linux (Swift 6.1.2), October 3, 2026:** `check_app_services.swift` passes. It covers the model row and gates, the license and confirmation text, history-off routing (including concurrent saves), memory retention, the post-wipe order and messages against a real temporary `DataWipe`, update text, the hourly attempt rule, and the UserDefaults throttle across checker instances. Controller.swift, UI.swift and check_controller.swift typecheck under `-swift-version 5` against hand-written AppKit/SwiftUI stubs. The stubs check identifiers, types and bindings, not real SDK signatures. main.swift cannot be typechecked on Linux (`#selector`). [Certain]

**Not verified until the Mac build:** the app and fixture builds with `-O`, the real SwiftUI layout of the new rows (`ProgressView` is the only view type new to UI.swift), the alerts, a real 1.8 GB download, cancel and resume in the app, Keychain deletion, a live GitHub check, and opening the release page. [Certain]

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

## Gemini transcription and local cleanup servers

`Providers.swift` adds `GeminiTranscriptionProvider` and `OpenAICompatibleCleanupProvider`. Both are wired in through `Routes.swift` (next section) and covered by `check_providers.swift`, which uses no network and no keys. [Certain]

- **Gemini transcription** is a language model asked to transcribe, not a speech recognizer. Before sending, call `GeminiTranscriptionProvider.shouldSkipForSilence(peakLevel:durationSeconds:)` and skip silent recordings. Use `transcribeChecked(_:)` and hold the result for recovery when `answerSuspected` is true. Its disclosure says that audio leaves this Mac to Google, and that free-tier keys allow human review. [Certain]
- **Local cleanup** sends the cleanup prompt to `{base}/v1/chat/completions` on a server the user runs. Documented defaults: Ollama `http://localhost:11434`, LM Studio `http://localhost:1234`, llama-server `http://127.0.0.1:8080`, vLLM `http://localhost:8000`. `discoverModels()` lists the server's models. Only loopback addresses count as on this Mac; any other host is disclosed as leaving it. If nothing is listening, the error reads "No local model server is running at host:port". [Certain]

No real Gemini key or local model server has been used yet; see [PROVIDERS.md](PROVIDERS.md). [Certain]

## Gemini 3.5 Transcribe (not yet wired in)

`Providers.swift` adds `GeminiTranscribeProvider`, which uses Google's dedicated speech model `gemini-3.5-transcribe` through the Beta Interactions API (`POST https://generativelanguage.googleapis.com/v1beta/interactions`). It conforms to `TranscriptionProvider`, so wiring it in takes one factory line: `GeminiTranscribeProvider(apiKey: key)`. Facts and sources are in [PROVIDERS.md](PROVIDERS.md). [Certain]

- **Defaults:** verbatim mode, the payload language as `language_codes` (`["en"]`), and `AudioPayload.vocabularyHint` as `custom_vocabulary` (one term per line or comma-separated; pass only relevant terms). `store = true`, per the user's decision of October 3, 2026. [Certain]
- **Disclosure:** audio and the relevant dictionary terms are sent to and stored by Google. Google keeps them 55 days on a paid-tier key or 1 day on a free-tier key, and they can be deleted earlier. Free-tier keys also allow product use and human review. [Certain]
- **Interaction ids:** `transcribeDetailed(_:onInteractionCreated:)` returns `GeminiTranscribeResult` with `interactionID`, and `deleteStored(interactionID:)` deletes the stored record. The provider persists no ids. Whether to keep them in memory, in History, or delete right after insertion is the integrator's decision. [Certain]
- **Polling:** if the server answers `in_progress` or `queued`, the same interaction is polled with GET, never re-submitted. Polling is bounded by `overallDeadline` (90 s) and `maxPolls`, and Task cancellation stops it. [Certain]

The checks pass with Swift 6.1.2 on Linux, in both `-swift-version 5` and the default mode. No real key has been used. [Certain]

## Processing routes and API keys (wired in)

`Routes.swift` is Foundation-only and holds the route decisions; Controller and UI display and act on them. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/check_routes.swift -o /tmp/murmur-routes-check
/tmp/murmur-routes-check
```

**Settings → Processing routes (R4).** Routes take effect on Apply Settings. The settings keys are `transcriptionRoute`, `cloudTranscriber`, `cleanupChoice`, `localServerURL` and `localServerModel`. Keys are never stored in UserDefaults.
- Transcription: On this Mac (Parakeet, the default) or Cloud. The cloud picker lists only implemented, non-deprecated providers: OpenRouter Whisper (`OpenRouterTranscriptionProvider`) and Gemini audio (`GeminiTranscriptionProvider`, a language model). Fireworks is not listed. `makeTranscriptionProvider(id:key:)` is the single factory. To add Gemini 3.5 Transcribe, add a `CloudTranscriber` case (with `displayName` and `providerID` `.gemini`) and one factory case; its own `disclosure` must say that Google stores the audio (PRD §5 user decision).
- Cleanup: Local rules (the default), Local model server, Gemini or OpenRouter. The local server has an address (default `http://localhost:11434`), a model name, Find Models (`discoverModels()`, which sends no transcript) and an optional key.

**A dictation on a cloud route.**
- At start, `RoutePlan` picks the transcriber and cleaner from the applied settings and the Keychain. It refuses, without fallback, when a key is missing, the local server address or model is invalid, or a disclosure is unconfirmed. The model gate applies only to local transcription.
- `CloudTranscription.run` replaces the ModelBench runner. It converts the recording to 16 kHz mono 16-bit WAV (`CloudAudio`) and makes one provider call. If the provider has a silence pre-check (Gemini), silent or very short recordings are skipped and reported as "No speech was detected".
- A transcript then follows the local path: history save, dictionary and cleanup, insertion. An empty transcript is "no speech".
- A provider error shows its `userMessage` in the Error phase. On preserve dispositions the audio stays for retry (24-hour policy).
- A Gemini transcript that looks like an answer (`answerSuspected`) is saved with status `held-transcript` (raw text only, Copy Raw) and never inserted.
- Cloud cleanup calls `processAsync`. A hold names the provider error, for example "Gemini reports no remaining quota…".
- Nothing falls back to the local model, local rules or another provider.
- Both calls run in a main-actor `CloudRequest` Task. Results are delivered behind the session's generation token. Escape while processing (through `ShortcutListener.onEscapeWhileProcessing`) or the menu bar's Cancel Request cancels the Task and its HTTP request. Nothing is inserted; during transcription the audio is deleted, and a transcript that was already saved stays in History. Escape is not swallowed in that state.

**Disclosure before cloud use.** Apply Settings computes each stage that sends data off this Mac. For any stage whose signature (route, provider, endpoint) is not yet confirmed, it shows an NSAlert with the provider's `DataDisclosure` summary and warning. Cancel reverts the route fields and applies nothing. The confirmed signatures are stored in `acknowledgedCloudRoutes`, replaced on every Apply. A change of route, provider or endpoint, or switching away and back, asks again. A loopback local server sends nothing off this Mac and needs no alert; any other host does. The Gemini disclosure says that audio leaves this Mac to Google, that free-tier content may be read by human reviewers, and that paid-tier prompts are logged for a limited time. Settings also shows the summary under each cloud choice. [Certain]

**API keys (R5).** Settings → API keys has a row each for Gemini, OpenRouter and the local model server (optional). Each row has a SecureField, Save (`KeychainCredentialStore(service: "Murmur")`), Validate (`validate()`, showing its `userMessage`) and Remove. The row shows only "Key saved" or "No key saved". The typed key lives only in the field until Save and is cleared after it. Messages come from fixed strings and `ProviderError.userMessage`, never from the key or a response body. Preview uses an in-memory store. [Certain]

**Learning lexicon.** `isCommonEnglishWord` in Controller.swift backs `CorrectionLedger.isCommonWord` with `NSSpellChecker` (language "en"): a word is common when no misspelling is found. `ProcessingCoordinator(directory:defaults:isCommonWord:)` injects it, including after Delete All Data. [Certain]

**Verified on Linux (Swift 6.1.2), October 3, 2026:** `check_routes.swift` passes (86 checks). It uses mock providers and transports and no network. It covers:
- no fallback: an unconfigured route refuses, never uses the local model, makes one call and no retry;
- the silence skip with the real `GeminiTranscriptionProvider` (no request sent);
- the answer-suspected hold;
- disclosure needed, acknowledged, provider or endpoint changed, and switched away and back; loopback versus LAN;
- keys never in messages, including 401 bodies that echo the key, and no key in UserDefaults;
- cancel preventing delivery (in flight, finished-but-canceled, superseded);
- WAV conversion;
- cloud cleanup holds;
- the lexicon condition: with a fake lexicon, lunch→launch and casual→causal are rejected.

`Routes.swift` also typechecks under `-swift-version 6`. `check_processing.swift` still passes. Controller.swift, UI.swift and check_controller.swift typecheck under `-swift-version 5` against hand-written AppKit/SwiftUI stubs, which check identifiers and bindings, not real SDK signatures. main.swift was not typechecked. [Certain]

**Not verified until the Mac build:**
- the app and fixture builds, the new SwiftUI rows (`SecureField` and `ForEach(_:id:)` are new to UI.swift), the NSAlert, and the Escape hook in a real event tap;
- Keychain save, read and remove, including whether ad-hoc signed builds prompt on read;
- `NSSpellChecker` with language "en";
- the WAV format AVAudioFile actually writes;
- every live provider call with a real key or a real local server. [Certain]
