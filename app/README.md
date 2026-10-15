# Native Murmur app

Build the local development bundle on Apple Silicon/macOS 26:

```sh
app/build.sh
open runtime/Murmur.app
```

`build.sh` and `check_ui.sh` build against the Command Line Tools' macOS 26 SDK when it is installed, because their macOS 27 SDK lacks the SwiftUI macro plugin; other commands that compile `UI.swift` need `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk`. The bundle uses the pinned local ModelBench helper. `build.sh` compiles the app with `-O` (see [Model download, retention and updates](#model-download-retention-and-updates-wired-in)). Cloud transcription and cleanup routes and API keys are wired in (see [Processing routes and API keys](#processing-routes-and-api-keys-wired-in)) but untested with real keys. Signing/notarization, and production release remain separate work. [Certain]

## Recovery and interface

Idle errors have a Dismiss control. Dismissal hides status without deleting history or retry audio; it is unavailable while recording or processing. Storage failure remains an error rather than claiming the app is ready. [Certain]

Settings show the current state above the scrollable form, model file availability, individual permission rows, and an always-visible Apply Settings button. Model availability checks file sizes; full checksums are verified before inference. History supports search, delivery status, initial selection, and recovery-entry selection. [Certain]

Recording and processing use a compact standalone glass-dot voice indicator on a transparent background by default. Posted pastes return quietly to Ready, with no Inserted or Delivery uncertain badge in History; read-back evidence stays in the local log and stored records. History shows actionable failures and interrupted delivery, with copy controls. Only errors show a compact clickable message. Every floating popup is buttonless, including learned-word notices. Clicking an error opens Settings with the full error, even when History was selected. Retained audio is reachable through Settings → History & Privacy → Show Retained Audio; learned entries can be removed in Settings → Dictionary. [Certain]

Corrupt or mismatched history files produce an error and prevent retention from silently skipping data; corruption at startup currently blocks dictation. Automatic repair/quarantine is not implemented. [Certain]

## Checks

All of these avoid live recording, insertion, and keyboard injection:

```sh
swiftc app/LaunchOptions.swift app/check_launch.swift -o /tmp/dictation-launch-check
/tmp/dictation-launch-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/check_history.swift -o /tmp/dictation-history-check
/tmp/dictation-history-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift spike/Observation.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Routes.swift app/AppleCleanup.swift app/UI.swift app/check_controller.swift -o /tmp/dictation-controller-check
/tmp/dictation-controller-check
```

**Verified on macOS, October 6, 2026** (Command Line Tools, macOS 26 SDK): every check passes: launch; history; cleanup (0/237 guard false rejects, 2349/2349 adversarial outputs rejected, 2685/2685 punctuation transfers keep the transcript's words); processing 126; dictionary 177; providers 632 assertions; updates 91 assertions; model download 158; app services; routes 119; boost filter 18; native controller. Counts in dated records below are as of their dates. [Certain]

## Processing: dictionary, cleanup and recovery

`Processing.swift` is Foundation-only and is compiled into the app. `ProcessingCoordinator` runs after transcription, on the main thread:

1. `DictionaryStore.apply` runs first, in every mode including faithful transcription.
2. Cleanup runs on the selected route with the enabled options. Local rules (`RuleCleaner`) run synchronously through `process`. Any other route (Gemini or a custom OpenAI-compatible endpoint, which may be a local model server) goes through `processAsync`: one `CleanupProvider` call via `CleanupPrompt`, with only the relevant dictionary entries, on the main actor except for the request itself. The synchronous path never calls the network.
3. Nothing is held (PRD decision, October 6, 2026). When the guard rejects the cleaned words, `CleanupPipeline.punctuated` puts the model's . , ? : and capitals on the transcript's own words (keeping a dictionary-term respelling), guarded as `ProcessingCoordinator.punctuationOnly`; there is no second call. A provider error (not retried), an unconfigured provider, or a transfer that fails the guard uses local rules, and if those fail the guard, the dictionary-applied transcript. `check_cleanup.swift` checks that every transfer over the corpus and adversarial outputs keeps the transcript's words and passes the guard. With punctuation on, the prompt asks for a paragraph break where a longer dictation changes topic; with punctuation on, the guard does not count a line break after a sentence end (a `.`, `?` or `!` token, so not "Dr.") that closes at least three words as added structure (`CleanupText.joiningParagraphs`), and the transfer keeps those breaks. Settings → Cleanup → Cleanup style picks Strict (default) or Polish (`CleanupOptions.polish`, key `cleanupPolish`): Polish applies on model cleanup routes; the built-in On this Mac rules always use Strict. Polish changes the prompt to ask for filler, false-start and grammar edits, and `CleanupGuard.check` accepts them within bounds (closed word lists, similarity, budgets of 8% new words and max(4, 10%) dropped words, runs of at most 3 new and 6 dropped words). `check_cleanup.swift` requires polish to reject every adversarial output too. Professional (`CleanupOptions.professional`, key `cleanupProfessional`, which also sets `polish`) asks the model to rewrite into clear professional writing; the guard lets words move, accepts comma-free "wait no" / "I meant" / "or rather" / "scratch that" corrections whose dropped words recur after the cue, and otherwise checks budgets: new words at most max(4, 25%), inside the text; dropped words are fillers, droppable grammar words, a pronoun replaced in the same person, or a content word replaced by a similar new word (never an unrelated one, so a lowercase name or antonym cannot be swapped); names and pronoun persons keep their order, and a kept number or negation keeps its context. `check_cleanup.swift` requires it to reject every adversarial output. Before the prompt is built, Professional removes a comma-free correction's restated stretch itself (`CleanupGuard.applyCommaFreeCorrections`, the same stretch the guard accepts, keeping a leading so/and/but/then); a cue with no restated content word is left alone ("I did not say that I meant it"). Live runs showed the model alone either kept both versions or deleted an earlier clause. `app/tools/check_professional_live.swift` sends 11 synthetic dictations through the configured custom cleanup route and the guard (October 7, 2026, gpt-oss-120b on Cerebras, after the PR review fixes: 22 of 22 correct, including every run of the test dictation). When the guard rejects a cleanup, the History entry also keeps the model's output as `cleanupRejectedOutput` for debugging (it expires and is deleted with the entry). A negative contraction that speech recognition truncated ("it doesn spread") counts as a negation, and the cleanup may complete it in the same place. `lastFallback` (content-free) is logged as `cleanup-fallback`; a provider error also shows "Inserted with local cleanup." after insertion. `held-cleanup` remains only for older History entries and for dictations made while the dictionary is unavailable.

Settings has three independent cleanup toggles, a Faithful Transcription button, a learning toggle, and a dictionary editor (add, edit in place, per-entry on/off, delete, learned/manual badge, Reset Learned, and a Not learned list of blocked heard forms and spellings with Unblock). Cleanup and learning settings take effect on Apply Settings; dictionary edits save immediately. After an insertion whose read-back shows the dictated text (native fields, and browser fields of unknown type), `AppController` polls the dictated span with `DictationObservation` every 0.25 s. Other fields (VS Code's stub, web canvases, any paste that cannot be read back) get a listen-only key tap for the window: `KeystrokeSpan` replays the keys on a copy of the pasted span and feeds the same tracker. Cmd/Ctrl chords (undo) drop the evidence; Return, Tab, vertical arrows and app switches end the watch and keep it. After a click the caret position is unknown, so `KeystrokeSpan` follows every caret position and double-clicked word at once and, on each poll, takes the one reading the learning filter finds to be a plausible respelling (fewest words changed; readings implying the same fix count as one). Each change goes to `ProcessingCoordinator.observeSpan`; the ledger diffs the span word by word (`CorrectionFilter.replacements`), so each replaced run is separate evidence, words typed after the span are ignored, and a deletion or a rewrite of more than half the span teaches nothing. A span emptied by sending a chat message keeps the fix made before it. Undo or lost attribution drops the session's evidence. The ledger settles when focus leaves, 60 seconds pass, the caret leaves the span or the next insertion starts. The `--test-audio` probe stays up until that window closes. The settings keys are `cleanupFillers`, `cleanupCorrections`, `cleanupLists`, `cleanupRoute` (derived from `cleanupChoice`, see below), `learningEnabled`, `historyMode` and `updateChecksEnabled`. The last two are wired in (see below) and are also written directly on Apply Settings, so they persist when the dictionary is unavailable. A corrupt `dictionary.json` or `ledger.json` blocks startup, like corrupt history. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_processing.swift -o /tmp/murmur-processing-check
/tmp/murmur-processing-check
```

Writing modes, tone and screen context (BetterWispr gaps #6–#8; PRD decisions of October 14, 2026): `WritingMode`, `WritingModes` (matching: trigger word, then website, then app) and `DictationStyle` (the settings with a mode's overrides) are in `Processing.swift`; `Tone` and `ScreenContext` are in `Cleanup.swift`. `process` and `processAsync` take an optional `DictationStyle`; tone is applied last, and screen context and custom instructions reach only `CleanupPrompt` on AI routes. `AppController` matches the app (and, through Accessibility, the page URL) when recording starts, captures screen context then if it is on, and resolves a trigger word on the transcript. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_modes.swift -o /tmp/murmur-modes-check && /tmp/murmur-modes-check
```

The processing check passes with Swift 6.1.2 on Linux. The Controller/UI integration has only been typechecked on Linux against hand-written AppKit/SwiftUI stubs; it has not been built or run on the Mac. [Certain]

## Dictionary, learning and retention

`Dictionary.swift`, `Learning.swift` and `Retention.swift` are Foundation-only, so their checks also run on Linux. They are compiled into the app through `Processing.swift`. The history cap, history-off mode and Delete all data are wired in through `AppServices.swift` (see [Model download, retention and updates](#model-download-retention-and-updates-wired-in)).

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd
```

- `DictionaryStore` keeps `dictionary.json` (0600, directory 0700). `apply(to:)` replaces exact variants as whole words and space-separated phrases (case-insensitive, longest match). The app also supplies its English lexicon: an unfamiliar alphabetic word of at least six letters may use one uniquely matching enabled term of at least six letters, with the same phonetic key and the existing semantic/respelling checks. A second narrow path permits a source of at least five letters when the stored term adds exactly one adjacent duplicate letter, even if title case is a recognized name (Akash → aakash, Alison → allison). Ordinary lowercase words remain protected, and phonetic/semantic checks, unique matching, enabled entries and explicit-variant priority still apply. Already-correct preferred forms take priority over near terms. Other recognized names, short words and unlisted phrases stay unchanged; explicit variants win. Without a lexicon, application remains exact-only. It inserts the preferred spelling as stored, and capitalizes its first letter only at a sentence start when the spelling is all lowercase. `relevantEntries(for:)` returns the entries present in the text, plus up to 10 whose preferred spelling sounds like a 1–3 word span (`DictionaryStore.soundsLike`: matching phonetic keys and similarity ≥ 0.5, or similarity ≥ 0.75 for terms of 6+ letters). That is what a cloud stage may receive. The broader 1–3 word near matches feed the cleanup prompt and guard; local respelling stays within the narrower single-word rule above. [Certain]
- Transcription: Gemini gets `vocabularyTerms` (every enabled preferred spelling, manual first): Gemini 3.5 Transcribe uses structured `custom_vocabulary`; Gemini audio uses spelling instructions. Custom OpenAI-compatible transcription sends no dictionary prompt: Whisper can continue that text as if it were prior speech. Manual/learned variants and lexicon-guarded single-word respellings apply afterward in every mode; other near matches require model cleanup. On-device transcription uses dictionary support (below). See [the vocabulary review](VOCABULARY.md) for the provider comparison and limits. [Certain]
- `CorrectionLedger` keeps `ledger.json` with short source/target strings only. The flow per session is `record` (provisional) while the window is open, then `settle` when it closes; `revert` undoes. One settled session adds the target as a vocabulary hint (learned entry, no variants); a second consistent session (case-folded) adds the source as a variant of that entry, so a second mishearing of the same spelling joins the same entry. A tombstoned target is never learned again from any source. The app shows a buttonless "Added … to dictionary" notice when a new entry is learned; deleting it in Settings → Dictionary removes it and tombstones the spelling. A conflicting target suppresses the source until `reset()`. A deleted learned entry is tombstoned and its evidence cleared. With learning off, nothing is recorded.
- `Retention.swift` covers the 50 MB history cap (drop oldest first; Forever warns via `HistoryCapStatus`), the history-off disclosure, and `DataWipe.deleteAllData`. Six-month and 30-day expiry stay in `HistoryStore`.

**Dictionary support in on-device transcription.** Settings → Dictionary offers an optional download of the pinned Parakeet CTC 110M model (`FluidInference/parakeet-ctc-110m-coreml`, 12 files, 103 MB, CC-BY-4.0). It goes to FluidAudio's own folder, `~/Library/Application Support/FluidAudio/Models/parakeet-ctc-110m-coreml`, because FluidAudio's rescorer reads the CTC tokenizer only from there. That folder may be shared with other FluidAudio apps, so it is hash-verified before every use (`ModelVerificationCache`, per folder) and skipped, never fatal, when it does not match. [Certain]

- Every dictionary change goes through `refreshDictionary()`, which rewrites `dictionary/parakeet-vocabulary.json` (0600; enabled entries with their "heard as" forms as aliases) and pre-warms the helper. `HelperLaunch.make` is the only place that builds the helper's `--ctc DIR --vocabulary FILE` arguments and the warm key, so warm, chunked and one-shot transcription agree; any change to the model, the dictionary model or the vocabulary restarts the warm helper. [Certain]
- The helper (`ModelBench`) transcribes with timings, rescores with FluidAudio's `VocabularyBoostingSession`, then `BoostFilter` keeps a replacement only when it joins or recases the term, matches a listed alias, or replaces a word that is not ordinary English (NSSpellChecker) and is spelled at least half like the term. The raw transcript is the base, so punctuation is kept. A vocabulary or model error never fails transcription: the helper runs without boosting and reports `vocabulary_error`, which Settings shows. [Certain]
- Measured with synthetic speech (`say -o`, never played) and a 20-term dictionary: 0/119 ordinary sentences changed (6/119 before `BoostFilter`), and cubectal→kubectl, ShelfMud→Shelfmate, Akash→Aakash, CloudEv→Clouddev, Supa Basin→Supabase and open router→OpenRouter were fixed; about 0.12 s more per transcription. The first load after a download compiles the model (about 14 s). A term split by a chunk cut is repaired: at each cut the chunker also writes a boundary clip (3 s each side), the helper answers `{"boundary": PATH}` with the replacements it kept there, and `ChunkJob` applies only a replacement whose words are the end of one chunk plus the start of the next (`Chunker.repair`, letters only, so a word cut in two also matches). Boundary clips are processed during recording and only with dictionary support. Measured: with the cut forced inside the term, open router and cube cuddle were repaired to the whole-file result; on 4 long recordings (23 cuts) the repair changed nothing. Removing chunking instead would make release wait for rescoring of the whole recording (dictionary rescoring costs about 15 ms per second of audio: 1.3 s at 1 minute, 4.9 s at 3.6 minutes, against at most about 0.4 s for the last chunk). Limits: casing-only fixes (tailscale→Tailscale) are not made, and History's raw text is the rescored transcript. Human speech is untested. [Certain]

```sh
swiftc module-one/models/Runner/Sources/ModelBench/BoostFilter.swift app/check_boost_filter.swift -o /tmp/murmur-boost-check && /tmp/murmur-boost-check
```

**Promotion rule (approved October 3, 2026; two tiers since October 4, see above).** A correction counts as learning evidence only if the target is a plausible respelling of the source. All of these must hold:

1. Structure: 1–3 words per side after trimming shared context words. Punctuation-only edits are rejected, as are deletions, insertions/appends and longer rewrites. Case-only (jira→Jira) and spacing (git hub→GitHub, a p i→API) fixes are accepted only with the lexicon, and then pass rules 2–3 like any other fix (the lexicon rejects recasing or joining ordinary words: notion→Notion, every one→everyone). A case-only fix keeps its target casing in the ledger.
2. Meaning guards: reject negation flips (not/n't/un-/dis-…), digits or number words, listed antonyms, function words and listed homophones, inflection-only changes and vowel-only changes in short words. When an `isCommonWord` lexicon is supplied, reject swaps where every word on both sides is an ordinary word. The app supplies NSSpellChecker (English) through `ProcessingCoordinator(directory:isCommonWord:)`: a word is common when the checker finds no misspelling.
3. Respelling: at least 4 letters per side (2 with the lexicon, so Jon→John and Ana→Anna are learned; an all-capitals target such as API or JSON skips the ordinary-word test), and either edit similarity ≥ 0.75, or equal consonant-class phonetic keys with similarity ≥ 0.5.
4. Known terms: if the target is already a manual entry's preferred spelling, rule 3 is waived, but not rules 1–2.

Known failure modes: without the lexicon (the Linux checks, or if the spell checker misjudges a word), real-word swaps that look like respellings (casual→causal, lunch→launch, Cloud→Claude) are accepted, and two such corrections would promote them. Similar names (Robert→Rupert) are accepted, because they look like transcription errors. Legitimate respellings are still skipped when they add an `s` (Postgres→Postgress), involve numbers, recase or join ordinary words (notion→Notion, Tail wind→Tailwind), or do not sound alike by the phonetic key (sequel→SQL); add those manually. Capitalising a term at a sentence start can teach that capitalisation. Measured with NSSpellChecker over 44 realistic corrections plus 18 edge cases on October 4, 2026. [Certain]

### Cloud providers, credentials, and updates

`Providers.swift`, `Credentials.swift`, and `Updates.swift` use only Foundation. `build.sh` compiles all three. Providers and keys are reachable from Settings through `Routes.swift` (see [Processing routes and API keys](#processing-routes-and-api-keys-wired-in)). The update checker is wired in (see below). Their checks need no network and no keys. They pass with Swift 6.1.2 on Linux. They have not yet been compiled on the macOS 26 host (Swift 6.3.3, `-swift-version 5`), and the Keychain store is compiled only on macOS. [Certain]

```sh
swiftc app/Cleanup.swift app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-providers-check
/tmp/murmur-providers-check
swiftc app/Updates.swift app/check_updates.swift -o /tmp/murmur-updates-check
/tmp/murmur-updates-check
```

No provider call has been made with a real API key. The request shapes come from official documentation, and the error shapes from documentation or from unauthenticated responses (see [PROVIDERS.md](PROVIDERS.md), verified October 3, 2026). Fireworks and OpenRouter clients were removed on October 7, 2026 (Fireworks deprecated audio inference on June 10, 2026; OpenRouter is deprecated upstream, per the project owner). Any other OpenAI-compatible service is reached through the custom endpoint. Each new route needs a live check with a real key before it is offered. [Certain]

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
app/check_ui.sh --credential-warning --recovery --bubble-only
app/check_ui.sh --listening --bubble-only
app/check_ui.sh --processing --bubble-only
app/check_ui.sh --saved --bubble-only
app/check_ui.sh --saved --learned --keep-notice --bubble-only
app/check_ui.sh --custom-transcription
app/check_ui.sh --light --dictionary
```

`--dictionary` seeds three sample entries (one turned off); open Settings → Dictionary to see them. The fixture forces only its own appearance. `--compact` uses the minimum production window size, while `--opaque` forces the same opaque rendering branch used by Reduce Transparency for the settings/History view. The separately hosted floating bubble continues to use actual system accessibility settings. [Certain]

`--matrix` seeds the History delivery and held-result states in temporary storage, including one session-only row; `--empty` opens History with no entries. `--light` sets both the fixture window and Settings appearance. [Certain]

The developer audio probe requires both flags and must target a disposable field:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

This explicitly performs transcription and one insertion attempt. It preserves the supplied audio and uses temporary isolated history, retry audio, and dictionary storage, removed on exit. It does not modify the user's history or dictionary or use saved API keys. It cannot be combined with preview or timed quit; malformed flags exit before storage/UI initialization. [Certain]

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

**Updates (R12).** `Updates.swift` is compiled into the app. When `updateChecksEnabled` is set, outside preview, an automatic `check(manual: false)` runs at launch. The 60-second timer then attempts one at most hourly (`UpdateSchedule`). `UserDefaultsUpdateCheckStore` limits completed checks to one a day across relaunches. The hourly limit exists because offline attempts do not count toward that daily throttle. Check for Updates (Settings and the menu bar) runs `check(manual: true)`. Results only change the Updates status line in Settings and the menu item title. They never change the dictation phase or show a bubble. An available release shows its title and plain-text notes, plus Open Release Page, which opens the validated GitHub page through `NSWorkspace`. Nothing is downloaded. The toggle explains that checks use the network even though inference is local. The current version comes from `CFBundleShortVersionString` (`0.1.0`). The release repository is `Penguin0011/Murmur`. [Certain]

**Verified on Linux (Swift 6.1.2), October 3, 2026:** `check_app_services.swift` passes. It covers the model row and gates, the license and confirmation text, history-off routing (including concurrent saves), memory retention, the post-wipe order and messages against a real temporary `DataWipe`, update text, the hourly attempt rule, and the UserDefaults throttle across checker instances. Controller.swift, UI.swift and check_controller.swift typecheck under `-swift-version 5` against hand-written AppKit/SwiftUI stubs. The stubs check identifiers, types and bindings, not real SDK signatures. main.swift cannot be typechecked on Linux (`#selector`). [Certain]

**Not verified until the Mac build:** the app and fixture builds with `-O`, the real SwiftUI layout of the new rows (`ProgressView` is the only view type new to UI.swift), the alerts, a real 1.8 GB download, cancel and resume in the app, Keychain deletion, a live GitHub check, and opening the release page. [Certain]

## Cleanup

`Cleanup.swift` is Foundation-only. The app uses it through `Processing.swift` (see above). It provides:
- `CleanupOptions`: fillers, corrections, and lists toggle independently. All are on by default, and `.faithful` turns all off.
- `spoken` ("Spoken commands and numbers", on by default in the app): `RuleCleaner.spokenCommands` runs first and handles:
  - dictated marks and layout
  - spoken numbers with hundred or a scale word, or before "percent", as digits
  - @ and # symbols
  - the explicit "write an email to X saying …" layout

  `CleanupGuard.check` also accepts output that matches `spokenCommands(raw)` (PRD decision, October 14, 2026).
- `CleanupGuard`: the PRD bound check between raw and cleaned text.
- `CleanupPrompt`: messages for an LLM provider.
- `RuleCleaner`: a deterministic local baseline.
- `CleanupPipeline`: returns `.cleaned`, `.unchanged` (all options off), or `.heldForRecovery(raw:reason:)` for a cleaner error or a guard failure; `ProcessingCoordinator` turns the latter into a fallback, never a hold. The reason is a content-free enum. [Certain]

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

## Gemini transcription and custom cleanup APIs

`Providers.swift` adds `GeminiTranscriptionProvider` and `OpenAICompatibleCleanupProvider`. Both are wired in through `Routes.swift` (next section) and covered by `check_providers.swift`, which uses no network and no keys. [Certain]

- **Gemini transcription** is a language model asked to transcribe, not a speech recognizer. Before sending, call `GeminiTranscriptionProvider.shouldSkipForSilence(peakLevel:durationSeconds:)` and skip silent recordings. Use `transcribeChecked(_:)` and hold the result for recovery when `answerSuspected` is true. Its disclosure says that audio leaves this Mac to Google, and that free-tier keys allow human review. [Certain]
- **Custom API cleanup** sends the prompt to `{base}/v1/chat/completions` using the configured model ID and Keychain key. The endpoint must accept OpenAI-compatible chat-completions requests. It can point to hosted services or a local server; only loopback addresses count as on this Mac, and other hosts are disclosed before the first request. [Certain]

No real Gemini key or local model server has been used yet; see [PROVIDERS.md](PROVIDERS.md). [Certain]

## Gemini 3.5 Transcribe (not yet wired in)

`Providers.swift` adds `GeminiTranscribeProvider`, which uses Google's dedicated speech model `gemini-3.5-transcribe` through the Beta Interactions API (`POST https://generativelanguage.googleapis.com/v1beta/interactions`). It conforms to `TranscriptionProvider`, so wiring it in takes one factory line: `GeminiTranscribeProvider(apiKey: key)`. Facts and sources are in [PROVIDERS.md](PROVIDERS.md). [Certain]

- **Defaults:** verbatim mode, the payload language as `language_codes` (`["en"]`), and `AudioPayload.vocabularyHint` as `custom_vocabulary` (one term per line or comma-separated; pass only relevant terms). `store = true`, per the user's decision of October 3, 2026. [Certain]
- **Disclosure:** audio and the relevant dictionary terms are sent to and stored by Google. Google keeps them 55 days on a paid-tier key or 1 day on a free-tier key, and they can be deleted earlier. Free-tier keys also allow product use and human review. [Certain]
- **Interaction ids:** `transcribeDetailed(_:onInteractionCreated:)` returns `GeminiTranscribeResult` with `interactionID`, and `deleteStored(interactionID:)` deletes the stored record. The provider persists no ids. Whether to keep them in memory, in History, or delete right after insertion is the integrator's decision. [Certain]
- **Polling:** if the server answers `in_progress` or `queued`, the same interaction is polled with GET, never re-submitted. Polling is bounded by `overallDeadline` (90 s) and `maxPolls`, and Task cancellation stops it. [Certain]

The checks pass with Swift 6.1.2 on Linux, in both `-swift-version 5` and the default mode. No real key has been used. [Certain]

## Apple Intelligence cleanup

`app/AppleCleanup.swift` adds `AppleCleanupProvider`, a `CleanupProvider` (and an `AsyncCleaner`) backed by Apple's FoundationModels system model. You pick it in Settings → Cleanup runs with → Apple Intelligence. [Certain]
- **How it runs:**
  - It uses `CleanupPrompt.build` unchanged, puts the system text in the session's instructions, and uses greedy sampling.
  - Each call gets a fresh session.
  - Murmur prewarms the model when the route is applied and when a dictation starts.
- **No key and no disclosure.** It needs no key, sends nothing off this Mac, and adds no disclosure stage.
- **Availability** is checked on every call.
  - If the model is unavailable, the provider throws `ProviderError.modelUnavailable`, with one of three reasons: this Mac is not eligible, Apple Intelligence is off, or the model is not ready.
  - `ProcessingCoordinator` then uses local rules and shows "Inserted with local cleanup." with that reason.
  - Settings shows the same reason under the route.
- **Generation errors** are mapped to `ProviderError` and also fall back to local rules:

  | Generation error | `ProviderError` |
  |---|---|
  | Context exceeded | payload too large |
  | Guardrail or refusal | content blocked |
  | Rate limit | rate limited |
  | Assets unavailable | model not ready |

- **Context window:** about 4K tokens. Text of 600 words or more is cleaned in sections of about 400 words, each guarded on its own.

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift spike/Observation.swift app/check_apple_cleanup.swift -o /tmp/murmur-apple-check && /tmp/murmur-apple-check
```

**What the check covers.** `check_apple_cleanup.swift` (29 checks) uses an injected status and a fake model:
- the route wiring: no key read, no refusal, no disclosure;
- each unavailable reason: the model is never called, the local-rules output is used, and the reason's message is shown;
- the generation-error fallback;
- guard rejection of an answer;
- splitting long text into sections. [Certain]

**Measured on October 14, 2026** with `app/tools/measure_cleanup_route.swift` (MacBook Air M3, 16 GB, macOS 27.0.1). It misses the corpus thresholds in all three styles, though the median latency is 0.6–0.8 s. The numbers are in PRD section 10, "Proposed decision: Apple Intelligence cleanup route". [Certain]

## Processing routes and API keys (wired in)

`Routes.swift` is Foundation-only and holds the route decisions; Controller and UI display and act on them. [Certain]

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift app/check_routes.swift -o /tmp/murmur-routes-check
/tmp/murmur-routes-check
```

**Settings → Processing routes (R4).** Route and model changes apply as soon as they are made. Custom transcription and cleanup have separate editable base URLs, model IDs and destination-bound Keychain keys. Only endpoint preferences are stored in UserDefaults. [Certain]
- Transcription: On this Mac (Parakeet, the default) or Cloud. Cloud offers Gemini and Custom Provider. Gemini defaults to `gemini-3.5-transcribe`; other model IDs use Gemini's general audio endpoint. Custom transcription posts multipart audio and spelling hints to `/v1/audio/transcriptions`; a compatible server must implement that format. [Certain]
- Cleanup: Local rules (the default), Apple Intelligence (on this Mac; see [Apple Intelligence cleanup](#apple-intelligence-cleanup)), Gemini or Custom Provider. The custom route uses an editable OpenAI-compatible base URL and model ID; it defaults to Cerebras (`https://api.cerebras.ai/v1`, `gpt-oss-120b`) and also works with compatible local servers. [Certain]
- Existing shared custom settings migrate to separate transcription and cleanup settings. Existing keys are copied to separate Keychain accounts; each remains usable only when its saved destination matches that route's endpoint. [Certain]

**A dictation on a cloud route.**
- At start, `RoutePlan` picks the transcriber and cleaner from the applied settings and the Keychain. It refuses, without fallback, when a key is missing or the custom endpoint or model is invalid. Local loopback endpoints do not need a key. The model gate applies only to local transcription.
- `CloudTranscription.run` replaces the ModelBench runner. It converts the recording to 16 kHz mono 16-bit WAV (`CloudAudio`), trims the silent tail to 0.5 s (Whisper transcribes a silent tail as "Thank you."), and makes one provider call. If the provider has a silence pre-check (Gemini audio, the custom transcription endpoint), silent or very short recordings are skipped and reported as "No speech was detected".
- A transcript then follows the local path: history save, dictionary and cleanup, insertion. An empty transcript is "no speech".
- A provider error shows its `userMessage` in the Error phase. On preserve dispositions the audio stays for retry (24-hour policy).
- A Gemini transcript that looks like an answer (`answerSuspected`) is saved with status `held-transcript` (raw text only, Copy Raw) and never inserted.
- Cloud cleanup calls `processAsync`. A hold names the provider error, for example "Gemini reports no remaining quota…".
- Nothing falls back to the local model, local rules or another provider.
- Both calls run in a main-actor `CloudRequest` Task. Results are delivered behind the session's generation token. Escape while processing (through `ShortcutListener.onEscapeWhileProcessing`) or the menu bar's Cancel Request cancels the Task and its HTTP request. Nothing is inserted; during transcription the audio is deleted, and a transcript that was already saved stays in History. Escape is not swallowed in that state.

**Cloud disclosures.** Settings shows disclosures inline, including destination hosts and any plain-HTTP warning. Selecting a cloud route and starting dictation do not show a disclosure popup. Loopback endpoints send nothing off this Mac. Custom API keys are omitted on unencrypted connections off this Mac. [Certain]

**API keys (R5).** Settings → API keys has separate rows for Gemini, Custom transcription and Custom cleanup. Custom keys use distinct Keychain accounts and endpoint bindings; replacing or removing one does not change the other. A typed key stays in a SecureField until Save, then the field clears. Messages come from fixed strings and `ProviderError.userMessage`, never from the key or a response body. Preview uses an in-memory store. [Certain]

**Learning lexicon.** `isCommonEnglishWord` in Controller.swift backs `CorrectionLedger.isCommonWord` with `NSSpellChecker` (language "en"): a word is common when no misspelling is found. `ProcessingCoordinator(directory:defaults:isCommonWord:)` injects it, including after Delete All Data. [Certain]

**Verified on Linux (Swift 6.1.2), October 3, 2026:** `check_routes.swift` passes (86 checks). It uses mock providers and transports and no network. It covers:
- no fallback: an unconfigured route refuses, never uses the local model, makes one call and no retry;
- the silence skip with the real `GeminiTranscriptionProvider` (no request sent);
- the answer-suspected hold;
- inline disclosure changes when a provider or endpoint changes; loopback versus LAN;
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

### Insertion review — October 5, 2026

See [INSERTION_REVIEW.md](INSERTION_REVIEW.md) for the complete delivery/recovery paths, Wispr Flow comparison, and remaining compatibility limits. The paste-last buffer now includes verified deliveries, survives canceled/empty/failed recordings, and is cleared when its transcript is deleted or all data is removed. Manual pastes check Accessibility permission, Secure Input, and accessible secure-field metadata, then recheck the focused field/window before posting. [Certain]
