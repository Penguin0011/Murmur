# Dictation — product requirements and agent delivery plan

Status: working draft, October 2, 2026. Confirmed requirements reflect the conversation; proposed decisions require review. [Certain]

## 1. Product goal

Build a macOS dictation application that inserts spoken text into the active text field, with optional filler removal, spoken corrections, and list formatting. Prioritize Apple Silicon and English. Give users independent local/cloud choices for transcription and cleanup. These are confirmed requirements. [Certain]

Hardware scope: Apple Silicon, including M1; Intel support is deferred beyond launch. Minimum macOS version: **macOS 26**. M1/8 GB performance validation is deferred and is not a development or release gate. Users choose a model appropriate to their hardware; no minimum RAM performance guarantee is made. Validate the available M3/16 GB host and publish its measured configuration. [Certain]

Proposed launch boundary: dictation and recovery, without meeting recording, an AI assistant, billing accounts, or automatic message submission.

Decision, October 14, 2026 (user: close the feature gaps with BetterWispr): the gaps listed in [BETTERWISPR_GAPS.md](BETTERWISPR_GAPS.md) are in scope, except #11 (one-fix learned replacement), which awaits a decision. They bring in a meeting notetaker, which replaces the "without meeting recording" boundary above, plus opt-in screen context for AI cleanup and a local Home/Insights page. Multilingual models stay out of scope. Each amended rule (local AI cleanup, tone, screen-context disclosure, meetings) still needs its own documented decision when its workstream lands. [Certain]

## 2. Confirmed requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| R1 | User-configurable global dictation shortcut; double-press toggle and hold modes. [Certain] | A double press begins a toggle recording that continues until the next press. Holding records until release. A lone short tap records nothing. Key repeat cannot start extra sessions. Settings detect unsupported bindings or conflicts where possible. |
| R2 | Selectable transcription models with a researched quick, accurate recommendation. [Certain] | Show download size, supported language, processing location, and measured device performance. Download, cancel, retry, remove, and select models. Do not start recording when the selected model is unavailable without explaining recovery. |
| R3 | Filler removal, spoken corrections, and formatting can each be enabled or disabled. [Certain] | Each toggle operates independently. All disabled means no cleanup rewrite beyond the transcription engine's output. Preserve raw and processed text for recovery. |
| R4 | Independent local/cloud choices for transcription and cleanup. [Certain] | Support local/local, local/cloud, cloud/local, and cloud/cloud. Show what leaves the device before cloud use. No silent cloud fallback. |
| R5 | Cloud access through user-supplied API keys. [Certain] | Store credentials in macOS Keychain. Validate provider configuration; explain authentication, quota, network, and rate-limit errors without losing the session. Never log keys. |
| R6 | No Dock icon; menu bar visibility is configurable. [Certain] | Dictation continues when the menu bar icon is hidden. Relaunching from Finder or Spotlight opens settings in the existing application instance. No settings shortcut. |
| R7 | Minimal bottom-screen bubble with a liquid glass appearance. [Certain] | Distinguish listening, processing, and recoverable error states; do not steal input focus. Respect accessibility contrast/transparency/motion settings. Hide after success. |
| R8 | Automatically insert at the cursor; recoverable history when insertion fails. [Certain] | Save output before insertion. If no safe destination is available, show saved status and allow copying from history. Do not submit the destination form or message. |
| R9 | User-selectable transcript retention: 30 days, six months, or forever. The repeated “forever” is treated as one option. [Certain] | Apply the selected policy to raw/final transcripts and associated history metadata. Forever means no automatic expiration, with manual deletion still available. |
| R10 | Editable custom dictionary and automatic learning from edits to dictated text in other apps at launch. [Certain] | Add, edit, and delete terms; automatically observe attributable post-insertion corrections without a history-edit or confirmation step; apply learned preferences to future dictation; let users inspect, undo, reset, and disable learning. Unsupported observation must be disclosed. |
| R11 | Open-source product published on the user's GitHub under MIT. [Certain] | Include MIT license with confirmed copyright holder, build instructions, contribution guidance, and required third-party notices. Verify model/runtime licenses separately before distributing them. |
| R12 | Check GitHub for updates; the user initiates updating. [Certain] | Detect newer stable releases, display version and release notes, and offer an explicit action to open the GitHub release for download. Never silently install or restart. |

## 3. Proposed interaction and failure rules

- Shortcut state machine (diagram required in the spike): press always starts capture; on release, a press longer than the threshold is a **hold** (release stops and finishes). A shorter press waits up to 400 ms for a second press: a **double press** latches a toggle recording that only the next press stops; without a second press the recording is cancelled and deleted. User decision, October 3, 2026. Key repeat is ignored. Modifier-only bindings (e.g. Fn, Right Option) are supported via a CGEventTap and therefore need the Input Monitoring permission in addition to Microphone and Accessibility.
- Begin microphone capture on shortcut press; determine hold versus tap on release so the first spoken word is not discarded. Proposed hold threshold: 250 ms, to validate on real keyboards.
- State sequence: idle → listening → transcribing → optional cleanup → saving → insertion → idle/recovery. Allow only one active session initially.
- Decision, October 6, 2026 (user): a dictation records for at most five minutes, then finishes and is processed, so one left on by accident stops. Cleanup replies may use up to 8,192 tokens so a five-minute dictation fits.
- Escape cancels recording; do not insert canceled speech. A new shortcut press while processing must not duplicate the prior session.
- Capture the starting field for recording safety and indicator placement. At delivery, use the currently focused field, matching the Insert at the cursor setting; recheck that field immediately before posting the paste. [Certain]
- Insert by clipboard paste (see the decision below), with clipboard preservation and verified focus. Never blindly overwrite newer clipboard content when restoring it.
- Decision, October 5, 2026 (user): remove user-facing Inserted and Delivery uncertain badges. Keep verified/unverified delivery evidence in local diagnostics and stored records. A posted paste returns quietly to Ready; retain the last insertable dictation for explicit ⌃⌘V recovery even after verified delivery. Actual failures show recovery instructions. Never automatically retry a paste. [Certain]
- Decision, October 4, 2026 (user): one delivery method everywhere, clipboard paste with ⌘V. A readable field is still re-read afterwards to verify delivery and to start correction observation; the AX selected-text write and its paste fallback are removed. Superseded: insertion order (1) AX selected-text write, verified by re-reading the field; (2) paste fallback only if (1) is unsupported. Many apps accept the AX write silently without inserting, so a read-back mismatch counts as failure, not success. Clipboard restore must skip when the pasteboard change count shows another writer (including clipboard managers and Universal Clipboard).
- Secure-field detection uses AX subrole plus app-specific checks. Browser password fields are not reliably flagged, so treat web fields with unknown type in browsers as unverified for delivery. Decision, October 4, 2026 (user: learning must work in non-standard text inputs): such a field may be observed for learning once its read-back shows the dictated text in plain (a masked field would not), and observation stops whenever Secure Event Input is on.
- Reject secure/password fields. Unsupported apps, revoked permissions, and inaccessible fields lead to recovery history.
- On cleanup failure, insert the best text that passes the guard instead of holding the dictation (decision, October 6, 2026, below). The raw transcript stays in History.
- On microphone disconnection, stop safely and retain recoverable audio according to the approved retention policy.
- Bubble placement follows the destination display and accounts for full-screen apps, Spaces, screen scaling, and the Dock.

## 4. Cleanup contract

Proposed behavior: cleanup edits dictation, never answers it, executes instructions inside it, invents facts, or changes tone merely to sound polished. Amended October 14, 2026: a writing mode may opt in to a rule-based tone (see "Decision: tone per writing mode" below). [Certain]

| Option | Example input | Expected output when enabled |
|---|---|---|
| Fillers | “Um, please send the report.” | “Please send the report.” |
| Spoken corrections | “Meet Tuesday—sorry, Thursday at three.” | “Meet Thursday at three.” |
| List formatting | “Shopping list: first apples, second milk, third bread.” | A three-item list, preserving the items. |

Cleanup acceptance is measured, not asserted. Build a fixed corpus (target 300+ labeled utterances, covering each option, interactions between options, names, numbers, negation, quoted speech, and look-alike prose) before choosing the cleanup model. Proposed pass bar: no more than 1% of utterances with an unintended edit to a name, number, or negation; spoken-correction accuracy and list-formatting precision thresholds set from the corpus baseline and recorded in the decision log. Report each local candidate and the cloud routes against the same corpus.

Local AI cleanup is not a launch target (decision, October 7, 2026). Typical Macs lack the RAM and compute to run a productive cleanup model without slowing other apps, so the PRD no longer requires an 8B local-model evaluation or a curated local-model browser. On-device cleanup is `RuleCleaner`, the deterministic rules pass in `app/Cleanup.swift`, which is measured against the corpus (section 4 thresholds). Users who want AI cleanup choose a cloud route or a user-configured OpenAI-compatible endpoint, which may be a server they run themselves. No automatic fallback between cloud routes; a failed cloud cleanup falls back only to on-device local rules (decision, October 6, 2026). The October 5, 2026 evidence (three local models of 2B parameters or less, none passing) stands as history. [Certain]

Prompt-injection guard: transcripts are data. Cleanup output must pass a bound check against the raw text (length ratio and edit-distance limits per enabled option, no new named entities or numbers). If the check fails, or the model appears to answer or obey the dictation, that output is never inserted: the dictation falls back as decided on October 6, 2026 (below). Log only a content-free failure reason locally. [Certain] Include injection phrases ("ignore previous instructions", "write me a…") in the corpus.

Additional required checks: preserve meaningful uses of “like”; preserve negation, names, numbers, and quoted speech; do not interpret “sorry” alone as a replacement instruction; do not create lists from ordinary prose. Ambiguous corrections should retain the original wording rather than guess.

Approved defaults: all three comforts on, with a plainly labeled faithful-transcription preset. Validate that disabling one feature does not disable the others. [Certain]

### Custom dictionary and correction learning

Confirmed launch scope: user-editable dictionary and automatic learning from edits to dictated text in other applications. Explicit feedback in history is not a substitute for automatic learning. [Certain]

Proposed implementation and acceptance criteria:

- Dictionary entries contain a preferred spelling and optional spoken variants or commonly mistaken forms. Support names, jargon, acronyms, and multiword terms. Apply entries in faithful-transcription mode too, independently of cleanup toggles.
- After successful insertion, track the inserted text range and observe subsequent edits in the same destination field during a bounded correction window. Automatically derive conservative term preferences from clearly attributable corrections; do not require a user confirmation or a history action. Ambiguous edits must be skipped rather than prompting or inventing a mapping.
- Approved observation window: until focus leaves the field or 60 seconds after insertion, whichever happens first. Preserve edits as provisional evidence; commit learning after the edit settles. Undo/reversion within the observation window must remove that evidence. Validate the approved behavior with real use; changes require a documented decision. [Certain]
- Associate each observation with its insertion session and range. Stop tracking when the range can no longer be identified, selection moves to unrelated text, permissions are revoked, or the field is secure. Never learn from unrelated document text or monitor typing outside a dictation correction window.
- Treat small spelling/name/term replacements as candidates. Exclude deletions, broad rewrites, tone changes, meaning changes, and ordinary text appended after the dictated span. Approved promotion rule: two consistent observations across separate dictations before applying an automatic term mapping; a conflicting correction suppresses promotion. No weight fine-tuning is assumed. [Certain]
- Keep manually entered and learned entries distinguishable in the dictionary. Allow editing, deletion, undo, and a separate learning toggle. Deleting a learned entry must stop its application to future sessions.
- Decision, October 4, 2026: where a field exposes no readable text (VS Code's default editor, canvas editors such as Google Docs), observation follows the keys typed in that app during the same window (listen-only, Input Monitoring) on an in-memory copy of the pasted span. Keystrokes are never stored or logged; only the filtered source/target pair reaches the ledger. Undo chords drop the evidence; Return, Tab, vertical caret keys and app switches end the watch and keep it. Decision, October 4, 2026 (user: fix the remaining gaps): after a click, the caret position is inferred by following every possible caret position and double-clicked word, and only a single plausible respelling is learned. The ledger diffs each span word by word, so a fix followed by more typing, and several fixes in one dictation, are each learned. The target app's own autocorrect is invisible to it. Murmur never turns on accessibility modes in other apps (VS Code switches to screen-reader mode when Electron accessibility is forced).
- Mechanism and honest limits: macOS exposes no edit-event stream with ranges. Tracking means reading the field's AX value and selection on change notifications (with bounded polling where notifications are absent), then locating the inserted span by anchored text diff. Chrome/Electron apps expose AX text only when accessibility is enabled for them; some web rich-text editors (e.g. Google Docs, Notion) may expose none. The spike must measure this rather than assume it. Learning triggers only on a whole-word or short-phrase replacement inside the anchored span; case-only and punctuation-only changes are not candidates, and "consistent" means the same source and target string after case-folding.
- Automatic post-insertion observation is required at launch. The macOS feasibility spike must prove field/range tracking in representative native, browser, rich-text, chat, and code-editor apps; publish the supported observation matrix. Unsupported apps may still support dictation, but cannot claim automatic learning. Do not replace this requirement with manual feedback. Approved launch rule: a category that fails observation ships with automatic learning marked unsupported in the published matrix and in-app (learning is off for those apps, dictation still works); it does not hold the launch. [Certain] Proposed floor: if no tested app in any category supports observation, report a launch blocker, since the feature would not exist.
- Decision, October 14, 2026 (BetterWispr gaps #9, #10, #12; the 60-second window and two-observation rule are unchanged):
  - Settle on stable text (#9): a dictation's evidence also settles once the edited span has been unchanged for 2 seconds and its reading is an accepted candidate, so a first fix adds its hint without waiting for the window to close. The watch then continues. A later edit in the same window replaces that session's evidence and withdraws what the early settle promoted; undo still withdraws it. One session never counts twice toward the two-session rule. Known limit: withdrawing a second-tier replacement this way also drops the other session's evidence, as undo always has.
  - Learn from History edits (#10): the final text of a History entry can be edited (the raw transcript never changes). Saving diffs the old and new final text through the same filter and ledger as automatic observation, as a separate session settled at once, so the same thresholds, tombstones, conflicts and learning toggle apply. This adds to automatic learning and does not replace it. A dictation fixed both in the field and in History counts as two sessions.
  - Misheard commands (#12): a dictionary entry may target a spoken command phrase ("Kocia Mark" → "question mark"). Such entries apply ahead of other entries, keep their exact form, and are left out of transcription vocabulary, the CTC boost and cleanup hints. The dictionary is applied before cleanup, so these entries run before spoken-command parsing; `DictionaryStore.commandPhrases` must stay in step with the command list in `Cleanup.swift`.
- Proposed learning implementation: persisted vocabulary/preferences, not model-weight fine-tuning. Validate that these preferences improve repeated corrections without changing unrelated dictation.
- Store dictionary and learned corrections locally. When a selected cloud stage needs relevant entries, disclose that those entries will leave the device; avoid sending unrelated history or the entire dictionary unnecessarily. Amended October 14, 2026: opt-in screen context and writing-mode instructions may also go to an AI cleanup route, with disclosure (see "Decision: screen context for AI cleanup" below). [Certain]
- Hardware policy: users may disable cleanup or choose models to suit their hardware. No M1-specific benchmark or 8 GB default rule blocks release. Keep transcription local by default; cleanup route is explicit and never silently changes to cloud. [Certain]

Prefer runtime vocabulary biasing where supported; otherwise evaluate conservative correction during processing. Document limitations for each transcription/cleanup route instead of promising identical behavior.
- Learning data has its own clear/reset controls. Transcript expiry does not silently delete user-approved vocabulary; explain the separate lifetimes in settings.
- Check automatically observed corrections in other apps, range attribution, undo/reversion, focus changes, unsupported fields, repeated corrections, conflicting entries, case, punctuation, ambiguous phrases, deletion, disabled learning, and all four local/cloud routes. A preferred term must not replace unrelated words merely because they sound similar.

## 5. Models and cloud access

Selected local English transcription default: **NVIDIA `parakeet-unified-en-0.6b`**, using the FluidInference Core ML conversion and FluidAudio Swift runtime, initially in batch mode. Selection follows research of OpenWhispr, Handy, Superwhisper, MacParakeet, and model/runtime documentation; details and source comparisons are in [MODEL_RESEARCH.md](MODEL_RESEARCH.md). M1/8 GB behavior is not yet measured. [Certain]

Validation deliverable for the selected default:

1. Benchmark selected Parakeet Unified against English Parakeet V2 and Whisper large-v3 turbo using documented macOS-compatible runtimes. Confirm exact artifacts and runtime versions.
2. Check license and redistribution rights for weights and runtime separately; record exact versions and sources.
3. Benchmark English dictation on the available Apple Silicon host, including accents, quiet speech, names, numbers, background noise, and 5/30/120-second recordings. Record RAM and macOS version; report results only for the measured configuration. M1/8 GB testing is optional future work. [Certain]
4. Record word error rate, name/number accuracy, cold/warm latency, peak memory, download size, and processing time. Publish results with the recommendation.
5. Dropped (decision, October 7, 2026): a local LLM cleanup model, for the reason in section 4. Cleanup evaluation covers the RuleCleaner baseline and the cloud and user-configured routes. [Certain]
6. Validate the selected default and choose an accuracy-focused alternative only if measurements justify it. Resolve upstream/conversion license metadata differences before redistributing weights; do not silently change the model selection if validation fails.

**Benchmark result (October 6, 2026; report `MODEL_BENCHMARK.md` at commit `3551c53`, not yet on `main`).** LibriSpeech test-clean, 100 clips, 2,172 reference words, Apple M3 with 16 GB RAM, macOS 26.6.2. Micro WER: Parakeet Unified 1.34%, Parakeet TDT V2 1.93%, Whisper large-v3 Turbo 2.12%. Median ASR time: 62 ms, 61 ms, and 1.89 s. Unified made 13 fewer word errors than V2 and 17 fewer than Whisper, at the same speed as V2. Unified stays the default. No WER threshold was set before the run; the choice rests on this comparison. [Certain]

Not measured: spontaneous dictation, accents beyond this dataset, background noise, names and numbers in dictation, short commands, and end-to-end latency. The cold-start times are not comparable, because one run included first-use compilation. Live microphone dictation is covered by the usage evidence in section 8, not by this benchmark. [Certain]

Cloud providers as shipped (decision, October 7, 2026): **Gemini** for speech-to-text and cleanup, and **any OpenAI-compatible endpoint** the user configures for speech-to-text and cleanup. Each custom stage has its own base URL, model ID, and Keychain account; the key is bound to the normalized endpoint, so changing the server requires saving the key for it again. **Fireworks and OpenRouter are not offered in Settings.** Fireworks audio inference was deprecated on 2026-06-10. OpenRouter is deprecated upstream (project owner, October 7, 2026), and users reach it or any other OpenAI-compatible service through the custom endpoint. [Certain]

**User decision — October 3, 2026:** pursue Gemini 3.5 Transcribe for cloud speech-to-text, and accept that Google stores Interactions API requests. The app must disclose before first use that audio is sent to and stored by Google. [Certain] The rest of this paragraph is still proposed.

**Verified October 3, 2026 (from the docs; no live key test):** the endpoint is `POST https://generativelanguage.googleapis.com/v1beta/interactions` with model `gemini-3.5-transcribe` and `store` true by default. Google keeps stored interactions for 55 days on the paid tier and 1 day on the free tier, and they can be deleted by ID with `DELETE /v1beta/interactions/{id}`. Implemented as `GeminiTranscribeProvider`. [Certain] Sources: [app/PROVIDERS.md](app/PROVIDERS.md).

**Superseded (October 6–7, 2026).** The provider list in this paragraph and the bullets after it is history. The shipped routes are in the paragraph above. [Certain]

**Proposed decision, pending user approval — October 3, 2026 (revised).** Historical; kept for the record. Everything in this paragraph was a proposal. No route has had a live test with a real key or a real local server. [Certain] Sources: [app/PROVIDERS.md](app/PROVIDERS.md).

- **Fireworks STT is dead.** Its audio inference was deprecated on 2026-06-10. [Certain]
- **Cloud STT options:**
  - **OpenRouter Whisper**, `POST /api/v1/audio/transcriptions` with default `openai/whisper-large-v3-turbo` and a 25 MB limit. Recommended, because it is true ASR. [Certain about the endpoint; the recommendation is a proposal]
  - **Gemini audio** through `generateContent` with inline audio (20 MB total request, 32 tokens per second). It is an LLM transcriber, not ASR. Risks: it may follow or answer spoken instructions, hallucinate text on silence, or tidy wording. There is no raw transcript to guard it against. Mitigations are implemented: temperature 0, a `{"transcript"}` schema, strict parsing, a silence pre-check, and an `answerSuspected` hold for recovery. They reduce these risks but do not remove them. [Certain about the documented limits; Likely about the risks]
  - Google also documents a dedicated ASR model, `gemini-3.5-transcribe`, but only through the Beta Interactions API. It is not implemented and needs a decision. [Certain]
- **Cleanup routes:**
  - The built-in RuleCleaner, the local default.
  - A user-run local OpenAI-compatible server (Ollama, LM Studio, llama-server or vLLM) at `{base}/v1/chat/completions`. It counts as local only for loopback hosts (`localhost`, 127.0.0.0/8, `::1`). Any other host is disclosed as "the transcript leaves this Mac to <host>", with an extra warning for plain http.
  - Gemini `generateContent`, default `gemini-3.5-flash-lite`.
  - OpenRouter chat completions.
- **Rules for every route:** no silent fallback, and a free-tier Gemini key's human-review exposure is disclosed. [Certain]

*Superseded on October 3, 2026 by the proposed decision above (kept for history):* Proposed split, pending verification: Fireworks as the first speech-to-text provider if its hosted Whisper transcription endpoint is confirmed; Gemini and OpenRouter as cleanup providers (OpenRouter also covers OpenAI/Anthropic models through one key), with Gemini audio transcription evaluated as an alternative STT route. Verify before implementation: exact model IDs, current pricing, audio format and size limits, whether each exposes a true transcription endpoint or only audio-in chat, data-retention terms, and error/rate-limit behavior. Launch needs one verified STT provider and at least one cleanup provider; do not assume the others.

Claude subscriptions do not include Claude API/Console access. [Certain] ([Anthropic documentation](https://support.claude.com/en/articles/9876003-i-have-a-paid-claude-subscription-pro-max-team-or-enterprise-plans-why-do-i-have-to-pay-separately-to-use-the-claude-api-and-console))

Subscription-funded access remains a research item, not a launch commitment. Accept only documented authorization intended for this integration; do not extract browser sessions or reuse internal tokens. API keys are the confirmed launch route. [Certain]

## 6. Privacy, history, and settings

Approved defaults are labeled below; other settings remain proposals. [Certain]

- Approved: local transcription selected initially; cleanup remains independently configurable. [Certain] User preference (October 5, 2026): most users are expected to choose Gemini cleanup, while privacy-conscious users should be able to browse and choose a quality-validated local model. The default cleanup route still needs an explicit product decision.
- Local transcript history for successful and unsuccessful insertion, with raw/final text, timestamp, processing route, and insertion status.
- Confirmed retention choices: 30 days, six calendar months, or forever. Approved default: 30 days; no transcript cloud sync. [Certain]
- For finite retention, expire entries from their recording timestamp at launch and periodically while running. Use calendar subtraction for six months, not a fixed 180-day approximation. Warn before shortening retention; delete expired entries and associated artifacts after confirmation. Forever does not prevent manual deletion.
- Approved: no permanent audio history; optional disk-based retry audio retained only when transcription has not produced usable text, for at most 24 hours. Purge after successful transcription, cancellation, explicit deletion, or expiry. Cleanup/insertion recovery uses text. Allow disabling audio recovery and explain the loss of recording recovery. [Certain]
- Offer a history-off mode with clear disclosure that recovery after app exit will then be unavailable.
- No transcript/audio telemetry. Scrub diagnostics; opt-in diagnostic export must be reviewable.
- Explain microphone and Accessibility permissions with a test dictation. Request any further permission only when the implementation needs it.
- Permissions: Microphone, Accessibility, and Input Monitoring (only if a modifier-only shortcut is chosen). Explain each when first needed.
- History cap: besides time-based retention, cap stored history at a fixed size (proposed 50 MB) and drop oldest first, except when retention is "forever", where the user is warned as the cap approaches.
- Accessibility for the user: VoiceOver announces listening, processing, inserted, and error states; the bubble is not the only signal. Respect Reduce Motion and Reduce Transparency.
- Uninstall and wipe: a "Delete all data" action removes history, dictionary, learned entries, retry audio, and Keychain items created by the app. Document manual removal in the README.
- Settings include shortcut, microphone, models, processing routes, providers, independent cleanup toggles, custom dictionary, learning controls, menu bar visibility, history retention, updates, and optional launch at login.
- Use the system input device initially; make input-device selection available. Explain missing devices and permission denial.

## 7. Architecture proposal

Distribution: the app is not App Sandbox compatible (Accessibility, event tap, cross-app observation), so there is no Mac App Store release. Ship a Developer ID signed, notarized DMG via GitHub Releases. Model weights are downloaded on first run from the pinned source, not bundled in the app or repository, so the MIT source is not mixed with the NVIDIA model license; the app displays the model license before download.

Use a native Swift macOS application with SwiftUI settings and AppKit integration for the menu bar, focus-safe overlay, and application lifecycle. Use FluidAudio/Core ML for the selected Parakeet Unified transcription path, subject to pinned-artifact and available-host validation. The cleanup runtime and minimum macOS version remain open.

Keep one session coordinator responsible for recording state, processing selection, saving, and insertion. Use small concrete boundaries for capture, transcription, cleanup, history, and insertion; do not build a general plugin framework.

Treat all transcribed text as untrusted content for cleanup prompts. Bound recording/request size, support cancellation and timeout, and keep retries explicit where duplicate insertion is possible.

## 8. Agent roles and execution order

Milestone 0 has an implemented standalone spike and recorded live results; milestone 1 validation work has started with capture, model, and independent safety workers. Live use (October 7, 2026): the development Mac's History holds 454 entries: 326 unverified, 63 verified, 34 copied, 15 held-cleanup (from before the October 6 no-hold decision), 11 failed, and 5 saved-not-inserted. The 326 unverified insertions are the largest open evidence gap: the status means delivery could not be confirmed by read-back, not that the text failed. The human-speech checks in section 10 are accepted as done on the strength of this use. Production and release acceptance remain incomplete. [Certain]

| Role | Ownership and handoff | Depends on | Completion evidence |
|---|---|---|---|
| Integration lead | Session coordinator, shared contracts, application project, integration decisions, release checklist. | Approved launch scope | Runnable skeleton, stable contracts, integrated builds and decision log. |
| Model and processing agent | Model research, local inference, model management, local/cloud transcription and cleanup, credentials, vocabulary application and correction-learning logic. | Benchmark device and shared session/dictionary contracts | Reproducible benchmark report; all four processing routes; cleanup and dictionary corpus results; cancellation and provider-error checks. |
| macOS interaction agent | Shortcut semantics, audio capture, focus tracking, insertion, clipboard fallback, permission flow, automatic observation and attribution of post-insertion edits. | Shared session/dictionary contracts | Real-device tap/hold checks, application insertion and automatic-learning observation matrices, range attribution, undo/focus-change checks, failure recovery, clipboard preservation. |
| Interface and recovery agent | Settings, onboarding, bubble, menu bar visibility, Finder/Spotlight reopening, persistent history, dictionary editor and inspect/undo/reset/disable controls for learned entries. | Shared session/history/dictionary contracts | Accessible UI; hidden-icon reopening; raw/final recovery; retention, dictionary editing and learning-control checks. |
| Verification and release agent | Independent end-to-end validation, packaging, signing/notarization, MIT/third-party notices, GitHub release and user-triggered update checks. | Integrated build and confirmed GitHub repository | Reproduction steps and evidence; release blockers resolved; installable artifact; clean build from published source; update flow without silent installation. |

Device-dependent work (benchmarks, the observation matrix, tap/hold on a real keyboard, signing) runs on an agent hosted on an available Apple Silicon Mac running macOS 26; M1/8 GB is not required. Cloud-only agents write code and harnesses but cannot claim device results. One-time macOS permission grants (Microphone, Accessibility, Input Monitoring, Screen Recording if used for app driving) need a human click on that Mac and are a setup step, not something the agent can do for itself. Every device check records machine model, RAM, macOS and app versions, and raw results.

Run no more than three implementation workers beside the integration lead. Begin independent verification after those workers hand off; roles do not require five simultaneous agents.

Each handoff includes owned files, inputs/outputs, acceptance criteria, assumptions, runnable checks, and known limits. The integration lead owns shared interfaces; workers coordinate changes before editing another role's files. Use small logical commits after each working checkpoint.

### Milestones

0. First PR is a standalone feasibility spike with a go/no-go report (no app skeleton): shortcut state machine and CGEventTap, AX insertion with read-back verification, secure-field handling, and post-insertion observation across the five app categories. A failing observation category is recorded as unsupported in the matrix per the approved launch rule; it does not block launch unless no category passes.
1. Resolve open decisions; benchmark models on the available Mac; prove shortcut/capture/insertion and automatic correction observation feasibility on macOS. Automatic-learning feasibility is measured and published per category; unsupported categories are disclosed, not blocking.
2. Ship one complete local path: record → transcribe → save → insert/recover. Prove tap and hold on real hardware.
3. Add independently toggled cleanup, local cleanup, BYOK cloud routes, model downloads, dictionary application, correction learning, and failure handling.
4. Complete bubble, settings, hidden-icon reopening, permissions, history retention, dictionary editing and automatic-learning controls.
5. Run independent acceptance checks; sign/notarize/package; verify first install and launch. Prepare the MIT GitHub repository and releases; prove update detection and user-triggered download. Public publication requires the confirmed repository and release authorization.

### GitHub releases and updates

Confirmed distribution intent: public GitHub source under MIT, with GitHub update checks and user-controlled updates. [Certain]

Proposed launch implementation: check stable GitHub Releases at launch and at most once daily, plus a manual “Check for Updates” action and an option to disable automatic checks. Show release notes and open the release page on user action; the user downloads and replaces the app. In-app installation is not assumed.

Use proper version comparison, ignore drafts/prereleases by default, validate the configured repository and release link, and handle offline/rate-limited checks without interrupting dictation. Explain that release checks use the network even when inference is local. Never transmit transcripts, audio, dictionary, or API keys in update requests.

Release handoff must include reproducible build instructions, architecture/macOS requirements, signed/notarized download artifacts where available, third-party notices, and source for the released version. The confirmed release repository is `Penguin0011/Murmur`; it is private, so the unauthenticated release check currently returns 404. The user deferred Apple Developer Program enrollment because it costs $99. Sparkle is deferred; retain user-controlled download-and-replace updates until signing and release packaging are ready. [Certain]

## 9. Release acceptance

- Functional and safety requirements pass on the available Apple Silicon/macOS 26 test configuration. Publish tested hardware and model-specific performance without promising M1/8 GB performance. Intel is outside launch acceptance. [Certain]
- Real insertion coverage includes a native editor, browser text field, rich-text editor, chat app, and code editor; publish unsupported cases rather than claiming universal compatibility.
- Exercise cursor loss, focus change, full-screen/Spaces, microphone loss, permission revocation, missing model, interrupted download, offline cloud requests, invalid key, quota exhaustion, and cleanup failure.
- Verify no inference network requests in local/local mode, and only the selected stage's data leaves the device in mixed modes. With screen context on, verify that its text goes only to the AI cleanup route and is named in that route's disclosure.
- Verify no duplicate insertion, no automatic sending, no credential exposure, and recoverable output before insertion attempts.
- Verify independent cleanup toggles against a fixed corpus, emphasizing unintended edits to names, numbers, and negation.
- Verify automatic learning from real post-insertion edits in other apps, conservative promotion and attribution, dictionary editing, undo/reset, disabled learning, and cloud disclosure without unrelated vocabulary leakage. Manual history feedback cannot satisfy the automatic-learning requirement.
- Verify each retention option, six-month calendar boundaries, retention changes, manual deletion, and forever across restarts.
- Verify GitHub update detection, no-update/offline/rate-limit behavior, ignored prereleases, user-triggered download, and no silent installation.
- Proposed performance targets: visible listening feedback within 150 ms; warm final output for a 10-second clip within 2 seconds on the agreed baseline device. Treat these as targets to measure, not established capability.
- Record cold-start performance separately. Do not hide cleanup latency within transcription-only numbers.

## 10. Decisions still needed

1. Minimum macOS 26 and Apple Silicon scope remain confirmed. M1/8 GB performance is deferred, with user-selected models and no validated minimum RAM guarantee. Intel remains deferred. [Certain]
2. Select and benchmark local models on the available Mac; retain local transcription, cleanup-on, explicit cleanup-route choice, and user model selection. Do not silently substitute cloud processing. [Certain] Transcription benchmark recorded in section 5 (October 6, 2026); local cleanup dropped (October 7, 2026).
3. Establish supported automatic-learning apps through the required feasibility spike, with unsupported categories disclosed rather than blocking launch (approved); the 60-second window and two-observation threshold are approved. [Certain]
4. Product name and release repository: **Murmur**, `Penguin0011/Murmur`, renamed October 4, 2026. The repository is currently private. The user deferred Apple Developer Program enrollment because it costs $99; Developer ID signing and notarization remain later release work. Sparkle is deferred; continue user-controlled manual download-and-replace updates. The user is the MIT copyright holder; LICENSE added October 3, 2026 with holder "Aakash" as supplied by the user. [Certain]
5. Local AI cleanup dropped (October 7, 2026, see section 5). Cloud speech-to-text and cleanup are implemented for Gemini and for any OpenAI-compatible endpoint, with Fireworks and OpenRouter removed from Settings. The Parakeet Unified benchmark is recorded in section 5 (October 6, 2026). October 5, 2026 comparison of Qwen3.5-0.8B, Qwen3.5-2B, and LFM2.5-1.2B-Instruct stands as history. [Certain]

This draft defines the confirmed product and proposed work boundaries; it is not yet a claim of full Wispr Flow feature parity. [Certain]

### Approved decision: local transcription and cleanup-on defaults

Approved by the user: local transcription and cleanup-on defaults, subject to hardware and quality validation. [Certain] The October 5 local-model comparison supersedes the earlier assumption that the built-in local cleanup path was production-ready.

Approved behavior: on first setup, select local transcription and enable filler removal, spoken corrections, and list formatting. Cleanup provider choice remains explicit; the user expects most people to use Gemini, with validated local models offered for privacy-conscious users. Explain cloud disclosure and API-key setup before any transcript is sent; offer a faithful-transcription preset. [Certain]

Local transcription keeps recording and transcription on the Mac; cleanup leaves the Mac only when the user explicitly selects and acknowledges a cloud cleanup route. Initial model downloads and enabled GitHub update checks still require network access. This is not a claim of a completely network-free application.

Small local cleanup models are not recommended for production based on current tests. Until a larger candidate passes the quality and safety gates, tell users to use cloud cleanup or run a larger local model (around 8B parameters as an evaluation starting point). This size is guidance, not a guarantee of quality or hardware fit. M1/8 GB optimization and testing are deferred. [Certain]

Cleanup-on means the initial output may differ from a literal transcript by design. Enable only the named features; do not silently add tone rewriting or summarization (a tone the user picks for a writing mode is not silent; decision of October 14, 2026). Preserve raw text in history while history is enabled, and let users disable each feature independently.

Superseding hardware decision: M1/8 GB performance does not gate development or release, and the previous automatic 8 GB cleanup-off policy is retired. Cleanup quality/safety checks still apply; model choice and cleanup toggles let users adjust resource use. No silent cloud fallback. [Certain]

### Approved decision: thirty-day default and temporary retry audio

Approved by the user: 30-day default text retention and optional retry audio with a maximum 24-hour lifetime. [Certain] The following details define the approved policy.

Approved behavior: retain text history for 30 days by default, with selectable six-month and forever options. Successful and failed insertions both appear in history; manual deletion remains available. Changing to a shorter period previews the pending deletion before applying it. [Certain]

Approved audio policy: keep audio only while recording/processing, and temporarily on disk if transcription fails before usable text exists. Use an app-private location with restrictive permissions; never sync retry audio through the app. Delete temporary audio after successful transcription, cancellation, explicit deletion, or 24 hours, whichever comes first. Enforce expiry on launch as well as while running. [Certain]

For a crash during transcription, recover an incomplete session only if its temporary audio is still within that window. Once raw text exists, a cleanup or insertion failure should recover from text without retaining audio. Retrying uses the original processing route; changing to a cloud route requires an explicit action and disclosure.

The tradeoff is recoverability versus retaining sensitive speech on disk. Temporary files may remain recoverable through backups or filesystem behavior even after deletion; the application should not promise forensic erasure. [Likely]

Approved policy: 30-day text retention and a maximum 24-hour retry-audio window, with a separate option to disable disk-based audio recovery. Disabling audio recovery must explain that failed transcription or a crash can lose the recording. [Certain]

### Approved decision: automatic-learning window and threshold

Approved by the user: a 60-second maximum observation window ending earlier on field focus departure, and promotion after two consistent corrections across separate dictations. Supported-app coverage still requires live verification. [Certain]

Approved behavior: after insertion, observe only the dictated span in the same focused field. Stop at focus departure or 60 seconds after insertion. Do not observe unrelated typing, password fields, or subsequent browsing. [Certain]

Automatically store a provisional term correction when the edit is a clear spelling/name/term replacement. Promote it into an active preference after two consistent observations across separate dictations; no confirmation dialog. A conflicting observation prevents promotion. Undo or reversion before the window closes removes the provisional evidence. Users can inspect, edit, delete, reset, or disable learned entries.

Example: changing “Acme” to “Akme” in two separate dictated passages can establish “Akme” as a preferred term. Changing “I accept” to “I decline” is a meaning change and must not establish a substitution. Ambiguous edits are skipped automatically.

The weakest assumption is reliable access to the dictated range and its edits across applications. Coverage is unverified; insertion support alone does not establish observation support. [Certain] The macOS agent must test real native text fields, Safari/Chrome text areas and rich-text editors, a chat composer, and a code editor. Record exact app/macOS versions and distinguish supported, partial, and unsupported behavior.

The feasibility deliverable must prove range identity, replacements, undo, cursor moves, appended text, focus changes, consecutive dictations in one field, and permission revocation. Specify whether selection changes terminate tracking or remain attributable. No automatic learned entry may come from text outside the session's tracked span.

Validation gate: test automatic learning in at least one real app per representative category and publish pass/partial/unsupported for each. Unsupported categories are disclosed and do not block launch (approved); at least one category must pass. Test the approved 60-second window and two-observation threshold; propose any changes with evidence.

### Decision: cleanup thresholds from the corpus baseline — October 7, 2026

Recorded from the measured baseline in `app/README.md` (corpus `app/cleanup-corpus.json`, 425 utterances, `check_cleanup`; first measured on Linux October 3, 2026, re-run on macOS October 7, 2026 with the same numbers). Thresholds are set just below the measured values. [Certain]

| Measure | Threshold | Baseline (RuleCleaner, deterministic) |
|---|---|---|
| Spoken-correction exact match | ≥ 95% | 95.8% (96 utterances) |
| Ambiguous corrections kept unchanged | 100% | 22/22 |
| List formatting precision | ≥ 97% | 97.7% (43/44) |
| List formatting recall | ≥ 95% | 100% (43/43) |
| Unintended name, number, or negation edits | ≤ 1% of utterances | 0.2% (1/425), after guard |
| Adversarial outputs accepted by the guard | 0 | 0 of 2349 (polish 0 of 2220; professional 0) |

Polish and Professional: the corpus labels cover fillers, corrections, and lists only, so the rule-based baseline does not measure their rewrites. Their evidence is the guard results above and the live Professional check (11 synthetic dictations, 22/22 passing; commit `b5481a5`). No live Polish run is recorded, so Polish stays at guard-level evidence until one is added. [Certain]

Any local candidate or cloud route must meet these thresholds on the same corpus before it is offered as the cleanup default. The 425-utterance corpus was written by the same agent that wrote the rules, so these numbers overstate real-world quality (see `app/README.md`). [Certain]

### Decision: spoken commands, numbers and the email layout — October 14, 2026

BetterWispr gaps #2–#5 (`BETTERWISPR_GAPS.md`) ship as one cleanup option, "Spoken commands and numbers" (`CleanupOptions.spoken`, key `cleanupSpokenCommands`). It is on by default and off in Faithful. Saved options from before it existed decode with it off. `RuleCleaner.spokenCommands` runs first in local cleanup. It is conservative: when a rule is unsure, the words stay. It handles:
- dictated marks and layout ("comma", "period", "new paragraph")
- spoken numbers that contain hundred or a scale word, or come before "percent" ("250,000", "2,50,000", "2.5 million", "10%")
- @ and # ("at the rate", "hashtag", "hash forty two")
- the email layout

The same operations are added to the cloud prompt. [Certain]

**Guard:** with the option on, `CleanupGuard.check` first judges output against the raw transcript as usual. If that fails, it judges the output against `spokenCommands(raw)` instead. That text is a deterministic rewrite of what was said, so every check still applies to it: answers, obeyed instructions, inserted words, and names, negations and number values. A model has to make the same conversions as the rules; otherwise its output falls back as decided on October 6, 2026. [Certain]

**Email-layout exception:** this amends "cleanup never adds structure or greetings", and only for an explicit frame at the start of the dictation: "write", "draft" or "compose" an email to someone "saying" something. With that frame, cleanup may:
- drop the frame words
- add "Hi <name>," as the greeting ("Hi" is the only word it may add)
- lay the message out with blank lines
- put a sign-off the speaker said at the end ("best regards, Kartik") on its own lines

Without the frame, an added greeting or sign-off is still rejected. The frame never lets the model compose or answer the email. `check_cleanup.swift` covers each case. [Certain]

**Evidence:** `check_cleanup.swift` covers the spec examples in both directions, plus adversarial outputs for the new path. On the 425-utterance corpus the October 7 thresholds are unchanged, with 0/237 false rejects. 0 of 2363 adversarial outputs are accepted with the option off, with it on, in Polish, or in Professional. With the option on, the rules change 4 corpus inputs, each one a spoken number that should be converted. [Certain]

### Decision: writing modes — October 14, 2026

BetterWispr gap #6. Settings → Modes holds a user-defined list of writing modes (key `writingModes`, JSON in UserDefaults). Each mode has a name, an on/off switch and three kinds of match:
- apps, by bundle ID, picked from apps dictated into since launch or running apps
- websites: "host", "host/path", "*.host" or "host/path/*". A host includes its subdomains, and a path matches itself and anything below it by whole segments.
- trigger words, said at the start or end of a dictation and cut from the text. Whole words only; a dictation that is only the trigger does not match. History's raw transcript keeps them.

A trigger word wins over a website, and a website over an app. Within one kind, the first mode in the list wins. The app and page are the ones focused when recording started. [Certain]

Each mode can override the cleanup options (Faithful, Strict, Polish, Professional and the per-option toggles), the tone, screen context, and custom instructions (at most 2,000 characters). An override left unset follows the Cleanup settings. Custom instructions go only to AI cleanup routes, inside delimiter tags, and the prompt says the rules take precedence over them. They never change what `CleanupGuard` accepts. [Certain]

**Page address:** the page URL is read through Accessibility (the web area's AXURL), not AppleScript, so there is no Automation prompt. It is read only in a known browser and only while an enabled mode lists a website. It is used once at recording start to pick the mode and is never stored, logged or sent. Murmur still never turns on accessibility modes in other apps, so a browser that exposes no web area to Accessibility does not match websites. [Certain]

**Evidence:** `check_modes.swift` covers matching priority, subdomain and path rules, trigger stripping at either end without taking part of a word, override inheritance and persistence. Not verified in the live app: reading the URL in Safari, Chrome, Arc, Edge, Brave and Firefox (Chromium may not expose its web area without an accessibility mode Murmur will not force), and the Settings screen beyond the fixture building and launching. [Certain]

### Decision: tone per writing mode — October 14, 2026

BetterWispr gap #7. This amends "cleanup never changes tone" (section 4) for one case only: a tone the user picks in a writing mode. With no mode, or with Formal, the text is unchanged. [Certain]

Tone is applied by rules (`Tone.apply` in `Cleanup.swift`) after cleanup and after any fallback, on every route:
- Formal: unchanged.
- Casual: drops commas and the final period. A comma inside a number ("250,000") stays.
- Very casual: Casual, and sentence starts are lowercased, except "I" and mixed-case or all-capitals words ("iPhone", "NASA").
- Excited: the final period becomes "!".

Tone is never applied to the email layout. The guard's ordinary checks are not loosened for tone. `CleanupGuard.acceptsTone` accepts a toned text only when it is exactly `Tone.apply` of the guarded text, so a model cannot pass other case or "!" changes off as tone. The model is not told about tone. Known limit: Casual and Excited also change a comma or final period the user dictated with a spoken command. `check_modes.swift` covers each tone and the guard's rejections. [Certain]

### Decision: screen context for AI cleanup — October 14, 2026

BetterWispr gap #8, in scope per the user's decision of the same date. This amends the disclosure rule in section 4 ("avoid sending unrelated history"): with screen context on, an AI cleanup route also receives text from the screen. [Certain]

**What is read:** when recording starts, an AI cleanup route will run, and the dictation could use context (the mode matched at start, or the global setting, has it on, or a mode with trigger words does), Murmur reads:
- the focused field's selected text
- the clipboard's plain text
- up to 3,000 characters of the focused window's text through Accessibility, bounded by node count and time

It is opt-in: a global setting in Settings → Cleanup, off by default, which a writing mode can override. Nothing is read while Secure Event Input is on or a secure field is focused, and the window walk skips secure fields. A clipboard item marked `org.nspasteboard.ConcealedType`, `TransientType` or `AutoGeneratedType` is never read. OCR is out of scope. [Certain]

**How it is used:** the text stays in memory for that one dictation. It is never sent on the local-rules route and never stored. A model output the guard rejected is not kept in History when context was sent, because it could echo screen text. In the prompt, the context sits in its own nonce-tagged block before the transcript, as reference data only, for spelling terms the transcript already says. Anything shaped like the prompt's delimiter tags is stripped from it. The guard still judges the output against the transcript alone, so context never lets added content through. [Certain]

**Disclosure:** the cleanup route's disclosure in Settings adds a sentence naming the selected text, the clipboard and the window text whenever screen context is on (globally or in any mode). It also names custom instructions when a mode has them. [Certain]

**Evidence:** `check_modes.swift` covers exclusion under Secure Input, in secure fields and for each private pasteboard type, tag stripping, size caps, the prompt layout, context absent on the local-rules route, and a model output that copies a name from the context being rejected. Not verified in the live app: the Accessibility window walk and selected text in real apps, a real password manager's pasteboard markers, a real model run with context, and whether macOS 26's pasteboard privacy prompt appears on the clipboard read. [Certain]

### Milestone 1 implementation decisions — October 2, 2026

Continue with the selected Unified model and batch processing; available-host inference remains unverified. M1/8 GB performance is deferred and does not block implementation or release. No silent model/provider substitution is permitted. [Certain]

Decision, October 6, 2026 (user: behave like Wispr Flow, which does not hold long dictations): a dictation is never held for cleanup review. When the guard rejects the cleaned words, the transcript's own words are inserted with the model's sentence punctuation and capitals (and its respelling of a dictionary term), guarded again; no second call is made. A provider error (not retried), or a transfer that fails the guard, uses on-device local rules, and if those fail the guard, the dictionary-applied transcript. Every inserted text has passed the guard or is the user's own words; an answer or obeyed instruction is never inserted. Decision, October 6, 2026 (user): cleanup has two styles. **Strict** (default) is the guard above. **Polish** also removes fillers without commas ("yeah", "you know", "like" when not a verb or comparison), removes false starts the speaker restates, and makes small grammar fixes (a word replaced by a similar or misheard word, or a grammar word added or dropped); it may change a word's meaning, but never adds or drops names, numbers or negations, never swaps modals or pronoun persons, and never adds a prefix, appended text or a run of more than three words. Decision, October 7, 2026 (user: a level above Polish that corrects and professionalizes like Wispr Flow; Polish stays as the voice-keeping style): **Professional** is a third style and an explicit exception to "never changes tone". It rewrites grammar (including reordering, "me and John was" -> "John and I were"), removes fillers and false starts, applies corrections cued without commas ("wait no I meant"), and formats lists spoken as "item one, item two" without an announced list. Its guard still rejects answers, appended or prefixed text, added structure and quote edits, never adds names or numbers or changes their order, drops a name, number or negation only inside a correction whose content words recur after the cue, keeps pronoun persons and numbers in their places, and bounds new and dropped words; a dropped content word must be replaced by a similar word, so it never swaps a word for an unrelated one (a lowercase name, an antonym). On-device rules use Strict. Paragraph breaks are allowed (user, October 6, 2026, to match Wispr Flow): with punctuation on, longer dictation gets a blank line where the topic shifts, and a line break right after a sentence end is not added structure. A provider error shows a notice after insertion so a bad key or quota is not silent. Replaces the earlier hold-for-recovery policy, under which one unexplained word held a whole dictation: 3 of the 4 dictations over 100 words were held. Treat dictation text as data and do not log its contents. [Certain]

The spike's unchanged-successful-AX-write paste fallback remains experimental: a delayed write may duplicate insertion. Production must choose one delivery method before attempting delivery, or retain uncertain output for recovery; a timer or change notification does not prove that an earlier write will never arrive. Unknown browser field types remain unverified and excluded from learning. [Certain]

Recorded native/chat observation establishes the narrow feasibility floor, while app-specific unsupported states must remain visible. A production semantic rule for automatic promotion remains unresolved; structural edit similarity alone does not justify learning. [Certain]

Decision, October 4, 2026 (user: "take the Wispr Flow style"): learning has two tiers. One settled correction that passes the rule below adds the corrected spelling as a vocabulary hint (a learned entry with no variants: it biases transcription and cleanup but replaces nothing) and shows a brief "Added … to dictionary" notice with Undo. Two consistent corrections from separate dictations add the misheard form as a variant of that same entry, so it is replaced from then on. A word the user deletes or reverses is never learned again from any mishearing. [Certain]

Decision, October 4, 2026 (user approved): with the NSSpellChecker lexicon, case-only fixes (jira→Jira), spacing fixes (git hub→GitHub, a p i→API) and words of 2–3 letters (Jon→John) are learned too; all-capitals targets skip the ordinary-word test. Without a lexicon they stay rejected. [Certain]

Approved semantic promotion rule (approved by the user October 3, 2026; implemented in `app/Learning.swift`). Condition before learning ships: back the lexicon with NSSpellChecker, so ordinary-word swaps are rejected. [Certain] Rule: a correction is learning evidence only when the target is a plausible respelling of the source. Rules: 1–3 words per side after trimming shared context; no case/punctuation/spacing-only edits, deletions, insertions or longer rewrites; reject negation flips, digits/number words, listed antonyms, function words and homophones, and inflection or short vowel-only changes; when a lexicon is available (NSSpellChecker), reject swaps of one ordinary word for another; otherwise require at least 4 letters per side and either edit similarity ≥ 0.75 or matching consonant-class phonetic keys with similarity ≥ 0.5. A target that is already a manual dictionary term waives only the similarity test. Known limits: without the lexicon, real-word swaps such as casual→causal pass; similar names (Robert→Rupert) pass; short names, plural-like respellings and spacing merges are skipped. Deleted learned entries are tombstoned so old evidence cannot re-promote them. [Likely]

Local cleanup baseline — October 3, 2026: `app/Cleanup.swift` provides a deterministic `RuleCleaner` behind the section 4 guard, with failures held for recovery. It is a baseline and stopgap, not the final local cleanup model choice; the model comparison in section 5, item 5, remains open. [Certain] Measured on Linux with Swift 6.1.2 against a 425-utterance labeled corpus (`app/cleanup-corpus.json`): 96.7% exact match; 1/425 (0.2%) unintended name/number/negation edits, within the ≤ 1% bar; 6/425 (1.4%) strict mismatches; spoken-correction exact match 95.8%, with 22 of 22 ambiguous corrections left unchanged; list precision 97.7% and recall 100%; 0/237 guard false rejects; 2348/2348 adversarial outputs rejected. [Certain] The same agent wrote the corpus, labels and baseline, and the corpus has no real ASR transcripts, so these numbers overstate real-world quality. [Certain] The spoken-correction and list thresholds were set from this baseline and recorded as a decision on October 7, 2026 (section 5, "Decision: cleanup thresholds from the corpus baseline"). [Certain]

### Superseding hardware decision — October 2, 2026

The user removed M1 performance from the required gates. M1/8 GB benchmarking and optimization may be done later; users may select lighter models. This supersedes earlier mandatory M1 baseline and 8 GB default rules, while retaining functional, privacy, safety, and measured-configuration reporting requirements. [Certain]
