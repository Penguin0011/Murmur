# Dictation — product requirements and agent delivery plan

Status: working draft, October 2, 2026. Confirmed requirements reflect the conversation; proposed decisions require review. [Certain]

## 1. Product goal

Build a macOS dictation application that inserts spoken text into the active text field, with optional filler removal, spoken corrections, and list formatting. Prioritize Apple Silicon and English. Give users independent local/cloud choices for transcription and cleanup. These are confirmed requirements. [Certain]

Hardware scope: Apple Silicon, including M1; Intel support is deferred beyond launch. Minimum macOS version: **macOS 26**. M1/8 GB performance validation is deferred and is not a development or release gate. Users choose a model appropriate to their hardware; no minimum RAM performance guarantee is made. Validate the available M3/16 GB host and publish its measured configuration. [Certain]

Proposed launch boundary: dictation and recovery, without meeting recording, an AI assistant, billing accounts, or automatic message submission. Amended: meeting recording is in scope (October 14, 2026), as specified in section 11 (approved October 15, 2026).

Decision, October 14, 2026 (user: close the feature gaps with BetterWispr): the gaps listed in [BETTERWISPR_GAPS.md](BETTERWISPR_GAPS.md) are in scope, except #11 (one-fix learned replacement), which awaits a decision. They bring in a meeting notetaker, which replaces the "without meeting recording" boundary above, plus opt-in screen context for AI cleanup and a local Home/Insights page. Multilingual models stay out of scope. Each amended rule (local AI cleanup, tone, screen-context disclosure, meetings) still needs its own documented decision when its workstream lands. [Certain] The meetings decision is section 11, approved by the user on October 15, 2026.

## 2. Confirmed requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| R1 | User-configurable global dictation shortcut; double-press toggle and hold modes. [Certain] | A double press begins a toggle recording that continues until the next press. Holding records until release. A lone short tap records nothing. Key repeat cannot start extra sessions. Settings detect unsupported bindings or conflicts where possible. |
| R2 | Selectable transcription models with a researched quick, accurate recommendation. [Certain] | Show download size, supported language, processing location, and measured device performance. Download, cancel, retry, remove, and select models. Do not start recording when the selected model is unavailable without explaining recovery. |
| R3 | Filler removal, spoken corrections, and formatting can each be enabled or disabled. [Certain] | Each toggle operates independently. All disabled means no cleanup rewrite beyond the transcription engine's output. Preserve raw and processed text for recovery. |
| R4 | Independent local/cloud choices for transcription and cleanup. [Certain] | Support local/local, local/cloud, cloud/local, and cloud/cloud. Show what leaves the device before cloud use. No silent cloud fallback. |
| R5 | Cloud access through user-supplied API keys. [Certain] | Store credentials in macOS Keychain. Validate provider configuration; explain authentication, quota, network, and rate-limit errors without losing the session. Never log keys. |
| R6 | No Dock icon by default; menu bar visibility is configurable. "Show in Dock" is an opt-in setting (decision, October 15, 2026, gap #20). [Certain] | Dictation continues when the menu bar icon is hidden. While a meeting records, its live view stays visible even when the menu bar and Dock icons are hidden (section 11, October 15, 2026). Relaunching from Finder or Spotlight opens settings in the existing application instance. No settings shortcut. |
| R7 | Minimal bottom-screen bubble with a liquid glass appearance. [Certain] | Distinguish listening, processing, and recoverable error states; do not steal input focus. Respect accessibility contrast/transparency/motion settings. Hide after success. |
| R8 | Automatically insert at the cursor; recoverable history when insertion fails. [Certain] | Save output before insertion. If no safe destination is available, show saved status and allow copying from history. Do not submit the destination form or message. |
| R9 | User-selectable transcript retention: 30 days, six months, or forever. The repeated “forever” is treated as one option. [Certain] | Apply the selected policy to raw/final transcripts and associated history metadata. Forever means no automatic expiration, with manual deletion still available. Meetings follow the same policy (section 11, October 15, 2026). |
| R10 | Editable custom dictionary and automatic learning from edits to dictated text in other apps at launch. [Certain] | Add, edit, and delete terms; automatically observe attributable post-insertion corrections without a history-edit or confirmation step; apply learned preferences to future dictation; let users inspect, undo, reset, and disable learning. Unsupported observation must be disclosed. |
| R11 | Open-source product published on the user's GitHub under MIT. [Certain] | Include MIT license with confirmed copyright holder, build instructions, contribution guidance, and required third-party notices. Verify model/runtime licenses separately before distributing them. |
| R12 | Check GitHub for updates; the user initiates updating. [Certain] | Detect newer stable releases, display version and release notes, and offer an explicit action to open the GitHub release for download. Never silently install or restart. |

## 3. Proposed interaction and failure rules

- Shortcut state machine (diagram required in the spike): press always starts capture; on release, a press longer than the threshold is a **hold** (release stops and finishes). A shorter press waits up to 400 ms for a second press: a **double press** latches a toggle recording that only the next press stops; without a second press the recording is cancelled and deleted. User decision, October 3, 2026. Key repeat is ignored. Modifier-only bindings (e.g. Fn, Right Option) are supported via a CGEventTap and therefore need the Input Monitoring permission in addition to Microphone and Accessibility.
- Begin microphone capture on shortcut press; determine hold versus tap on release so the first spoken word is not discarded. Proposed hold threshold: 250 ms, to validate on real keyboards.
- State sequence: idle → listening → transcribing → optional cleanup → saving → insertion → idle/recovery. Allow only one active session initially.
- Decision, October 6, 2026 (user): a dictation records for at most five minutes, then finishes and is processed, so one left on by accident stops. Cleanup replies may use up to 8,192 tokens so a five-minute dictation fits. The cap is for dictation only; meetings have a 3-hour cap (section 11, approved October 15, 2026).
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

Local AI cleanup is not a launch target (decision, October 7, 2026). Typical Macs lack the RAM and compute to run a productive cleanup model without slowing other apps, so the PRD no longer requires an 8B local-model evaluation or a curated local-model browser. On-device cleanup is `RuleCleaner`, the deterministic rules pass in `app/Cleanup.swift`, which is measured against the corpus (section 4 thresholds). Users who want AI cleanup choose a cloud route or a user-configured OpenAI-compatible endpoint, which may be a server they run themselves. No automatic fallback between cloud routes; a failed cloud cleanup falls back only to on-device local rules (decision, October 6, 2026). The October 5, 2026 evidence (three local models of 2B parameters or less, none passing) stands as history. [Certain] Amended October 14, 2026 (user): Apple's on-device system model is allowed as an opt-in cleanup route, labelled less accurate than local rules and never the default; see "Decision: Apple Intelligence cleanup route" in section 10. [Certain]

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
- Treat small spelling/name/term replacements as candidates. Exclude deletions, broad rewrites, tone changes, meaning changes, and ordinary text appended after the dictated span. Promotion rule (decision, October 16, 2026, below): one settled observation that passes the learning filter applies an automatic term mapping; a conflicting correction suppresses or withdraws it. Superseded: two consistent observations across separate dictations before applying an automatic term mapping. No weight fine-tuning is assumed. [Certain]
- Keep manually entered and learned entries distinguishable in the dictionary. Allow editing, deletion, undo, and a separate learning toggle. Deleting a learned entry must stop its application to future sessions.
- Decision, October 4, 2026: where a field exposes no readable text (VS Code's default editor, canvas editors such as Google Docs), observation follows the keys typed in that app during the same window (listen-only, Input Monitoring) on an in-memory copy of the pasted span. Keystrokes are never stored or logged; only the filtered source/target pair reaches the ledger. Undo chords drop the evidence; Return, Tab, vertical caret keys and app switches end the watch and keep it. Decision, October 4, 2026 (user: fix the remaining gaps): after a click, the caret position is inferred by following every possible caret position and double-clicked word, and only a single plausible respelling is learned. The ledger diffs each span word by word, so a fix followed by more typing, and several fixes in one dictation, are each learned. The target app's own autocorrect is invisible to it. Murmur never turns on accessibility modes in other apps (VS Code switches to screen-reader mode when Electron accessibility is forced).
- Mechanism and honest limits: macOS exposes no edit-event stream with ranges. Tracking means reading the field's AX value and selection on change notifications (with bounded polling where notifications are absent), then locating the inserted span by anchored text diff. Chrome/Electron apps expose AX text only when accessibility is enabled for them; some web rich-text editors (e.g. Google Docs, Notion) may expose none. The spike must measure this rather than assume it. Learning triggers only on a whole-word or short-phrase replacement inside the anchored span; case-only and punctuation-only changes are not candidates, and "consistent" means the same source and target string after case-folding.
- Automatic post-insertion observation is required at launch. The macOS feasibility spike must prove field/range tracking in representative native, browser, rich-text, chat, and code-editor apps; publish the supported observation matrix. Unsupported apps may still support dictation, but cannot claim automatic learning. Do not replace this requirement with manual feedback. Approved launch rule: a category that fails observation ships with automatic learning marked unsupported in the published matrix and in-app (learning is off for those apps, dictation still works); it does not hold the launch. [Certain] Proposed floor: if no tested app in any category supports observation, report a launch blocker, since the feature would not exist.
- Decision, October 14, 2026 (BetterWispr gaps #9, #10, #12; the 60-second window and two-observation rule were unchanged then; the October 16 decision below replaces the two-observation rule):
  - Settle on stable text (#9): a dictation's evidence also settles once the edited span has been unchanged for 2 seconds and its reading is an accepted candidate, so a first fix is learned without waiting for the window to close. The watch then continues. A later edit in the same window replaces that session's evidence and withdraws what the early settle promoted; undo still withdraws it. One session never counts twice. Known limit: withdrawing a replacement that older (two-tier) sessions supported this way also drops the other session's evidence, as undo always has.
  - Learn from History edits (#10): the final text of a History entry can be edited (the raw transcript never changes). Saving diffs the old and new final text through the same filter and ledger as automatic observation, as a separate session settled at once, so the same thresholds, tombstones, conflicts and learning toggle apply. This adds to automatic learning and does not replace it. A dictation fixed both in the field and in History counts as two sessions.
  - Misheard commands (#12): a dictionary entry may target a spoken command phrase ("Kocia Mark" → "question mark"). Such entries apply ahead of other entries, keep their exact form, and are left out of transcription vocabulary, the CTC boost and cleanup hints. The dictionary is applied before cleanup, so these entries run before spoken-command parsing; `DictionaryStore.commandPhrases` must stay in step with the command list in `Cleanup.swift`.
  - Superseded by the decision below for the threshold only; the rest of #9, #10 and #12 is unchanged.
- Decision, October 16, 2026 (user, BetterWispr gap #11: "Yes, one word correction should be enough to learn a word replacement."): the first settled correction that passes the learning filter adds the corrected spelling with the misheard form as a variant, so the misheard form is replaced from the next dictation on. Supersedes the October 4, 2026 two-tier rule (one fix: vocabulary hint only; a second consistent fix from another dictation: replacement) and the approved two-observation promotion rule. Unchanged: the filter (including the NSSpellChecker lexicon guard), tombstones for deleted, undone or reversed entries, conflict suppression (a later conflicting fix suppresses the misheard form and withdraws its mapping), undo or reversion inside the observation window withdrawing the promotion, History-edit learning (#10) through the same path, and command-target entries (#12) kept out of hints. The "Added … to dictionary" notice has Undo, which removes what was learned (the new variant, or the entry it created) and tombstones it. Migration: an existing hint-only entry and its stored single-fix evidence are not promoted at launch or by an unrelated dictation; the next settled fix of that pair adds the variant. Consequence: the two-dictation wait was also a second guard for the short-word and case-only fixes approved October 4 (Jon→John, jira→Jira); those now replace after one fix, and the filter is the only guard. BetterWispr's optional AI review of a first fix was not adopted. [Certain]
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
- Approved: no permanent audio history; optional disk-based retry audio retained only when transcription has not produced usable text, for at most 24 hours. Purge after successful transcription, cancellation, explicit deletion, or expiry. Cleanup/insertion recovery uses text. Allow disabling audio recovery and explain the loss of recording recovery. [Certain] Meetings (section 11, approved October 15, 2026): meeting audio chunks are transient and deleted once transcribed; with speaker separation on, the Them stream may be kept for at most 24 hours until diarization finishes. [Certain]
- Offer a history-off mode with clear disclosure that recovery after app exit will then be unavailable.
- No transcript/audio telemetry. Scrub diagnostics; opt-in diagnostic export must be reviewable.
- Explain microphone and Accessibility permissions with a test dictation. Request any further permission only when the implementation needs it.
- Permissions: Microphone, Accessibility, and Input Monitoring (only if a modifier-only shortcut is chosen), plus System Audio Recording, requested at the first meeting only (section 11). Explain each when first needed.
- History cap: besides time-based retention, cap stored history at a fixed size (proposed 50 MB) and drop oldest first, except when retention is "forever", where the user is warned as the cap approaches.
- Accessibility for the user: VoiceOver announces listening, processing, inserted, and error states; the bubble is not the only signal. Respect Reduce Motion and Reduce Transparency.
- Uninstall and wipe: a "Delete all data" action removes history (including meetings, section 11), dictionary, learned entries, retry audio, and Keychain items created by the app. Document manual removal in the README.
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
3. Establish supported automatic-learning apps through the required feasibility spike, with unsupported categories disclosed rather than blocking launch (approved); the 60-second window is approved; the two-observation threshold was approved and then replaced by one settled observation (decision, October 16, 2026). [Certain]
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

Approved by the user: a 60-second maximum observation window ending earlier on field focus departure, and promotion after one settled correction (decision, October 16, 2026; superseded: two consistent corrections across separate dictations). Supported-app coverage still requires live verification. [Certain]

Approved behavior: after insertion, observe only the dictated span in the same focused field. Stop at focus departure or 60 seconds after insertion. Do not observe unrelated typing, password fields, or subsequent browsing. [Certain]

Automatically store a provisional term correction when the edit is a clear spelling/name/term replacement. Promote it into an active preference once it settles (decision, October 16, 2026; superseded: after two consistent observations across separate dictations); no confirmation dialog. A conflicting observation suppresses or withdraws it. Undo or reversion before the window closes removes the provisional evidence. Users can inspect, edit, delete, reset, or disable learned entries.

Example: changing “Acme” to “Akme” in two separate dictated passages can establish “Akme” as a preferred term. Changing “I accept” to “I decline” is a meaning change and must not establish a substitution. Ambiguous edits are skipped automatically.

The weakest assumption is reliable access to the dictated range and its edits across applications. Coverage is unverified; insertion support alone does not establish observation support. [Certain] The macOS agent must test real native text fields, Safari/Chrome text areas and rich-text editors, a chat composer, and a code editor. Record exact app/macOS versions and distinguish supported, partial, and unsupported behavior.

The feasibility deliverable must prove range identity, replacements, undo, cursor moves, appended text, focus changes, consecutive dictations in one field, and permission revocation. Specify whether selection changes terminate tracking or remain attributable. No automatic learned entry may come from text outside the session's tracked span.

Validation gate: test automatic learning in at least one real app per representative category and publish pass/partial/unsupported for each. Unsupported categories are disclosed and do not block launch (approved); at least one category must pass. Test the approved 60-second window and the one-fix threshold (October 16, 2026); propose any changes with evidence.

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

### Decision: Apple Intelligence cleanup route — October 14, 2026

**Status: approved by the user, October 14, 2026: options 1 and 2 below (opt-in, labelled, not the default). Option 3 was declined.** This amends the October 7, 2026 decision in section 4 that local AI cleanup is not a launch target. The default route stays local rules either way. [Certain]

That decision was about downloaded models: their RAM and compute cost slow other apps. Apple's FoundationModels system model doesn't have that cost. Murmur doesn't download it, macOS manages its memory, and Murmur already requires macOS 26. So BETTERWISPR_GAPS.md #1 adds it as a cleanup route: `CleanupChoice.appleIntelligence`, implemented in `app/AppleCleanup.swift`. [Certain]
- It uses the same `CleanupPrompt` and `CleanupGuard` as the other routes.
- It uses the October 6 failure policy:
  - When the model is unavailable, it names the reason (this Mac is not eligible, Apple Intelligence is off, or the model is not ready).
  - A generation error falls back to local rules.
  - So does a guard rejection.
- It sends nothing off this Mac and needs no key. [Certain]

**Measured.** Corpus `app/cleanup-corpus.json`: 425 utterances, 402 of them with cleanup on. [Certain]
- Run through the real `ProcessingCoordinator` path with `app/tools/measure_cleanup_route.swift`. The prompt is from `Cleanup.swift` at `42223c5`.
- Hardware: MacBook Air M3 (Mac15,12), 16 GB RAM, macOS 27.0.1 (26A434).
- "Inserted" means the text Murmur would insert, after the guard and the local-rules fallback.
- The corpus labels are Strict labels. Polish and Professional are expected to differ from them, so their exact-match and correction numbers are lower bounds.

| Measure (threshold) | Local rules | Apple Strict | Apple Polish | Apple Professional |
|---|---|---|---|---|
| Model output accepted by the guard | n/a | 78.4% (315/402) | 80.3% (323/402) | 63.7% (256/402) |
| Unintended name, number or negation edits, inserted (≤ 1%) | 0.2% (1/425) | 1.2% (5/425) | 1.4% (6/425) | 1.4% (6/425) |
| Spoken-correction exact match (≥ 95%) | 95.8% | 65.6% (63/96) | 51.0% (49/96) | 71.9% (69/96) |
| Ambiguous corrections kept unchanged (100%) | 22/22 | 21/22 | 14/22 | 18/22 |
| List precision (≥ 97%) | 97.7% | 100% (28/28) | 100% (22/22) | 97.5% (39/40) |
| List recall (≥ 95%) | 100% | 65.1% (28/43) | 51.2% (22/43) | 90.7% (39/43) |
| Inserted text equal to the label | 96.7% | 74.4% | 68.5% | 80.5% |
| Model latency, median / p90 / max | instant | 0.65 / 0.83 / 2.06 s | 0.61 / 0.76 / 1.57 s | 0.80 / 1.03 / 1.53 s |

What the numbers show:
- Apple Intelligence misses the section 4 thresholds in every style. Local rules meets them. [Certain]
- **Name, number and negation edits.** Every one of the 5–6 per style is one of two kinds:
  - A correction the model half-applied: both versions kept, as in "Book it for 2, 3 people", "goes to Dana, Dan" and "nine, sorry, ten".
  - Ordinal words turned into a list nobody asked for, as in "First, preheat" → "1. Preheat", or Polish's "first impressions matter, second chances" → a numbered list.

  None is a legitimate Polish or Professional rewrite. The guard accepts these outputs because no word was invented. That is a guard gap on every route, noted for W1. [Certain]
- **Most guard rejections are unexplained deletions.** The model drops words the prompt doesn't allow it to drop. It also lowercases sentence starts and drops final periods when punctuation is off. [Certain]
- **Errors and latency.** No generation errors occurred. The first call after prewarming took up to 2.1 s. [Certain]
- **Long dictation.** These were extra live runs in Professional, using non-repeating text built from corpus sentences.
  - No request exceeded the context window. That includes a single 906-word unpunctuated request, which can't be split.
  - Latency grows with length: 4.8 s for 156 words, 16.8 s for 600 words, 27–29 s for 906 words.
  - The guard rejected every one of these long outputs, because one violation rejects the whole section, so local rules were used.
  - In practice the route helps only short dictations. [Certain]

**Cloud comparison: not run.** The only keys configured on this Mac are free tier, and neither can finish a 402-call style:
- **Gemini** (gemini-3.5-flash-lite): an unthrottled pass had 75–83% of its calls rate limited, so its inserted text was mostly local rules.
- **Cerebras** gpt-oss-120b, through the Custom Provider route: limited to 5 requests a minute and 150 an hour, so 97.5% of a Strict pass was rate limited, and one style would take about 3 hours.

No numbers from those runs are recorded. To compare, run `app/tools/measure_cleanup_route.swift custom` or `gemini` with a paid or higher-limit key. `MCR_DELAY` spaces out the calls. [Certain]

**Options put to the user (1 and 2 approved):**
1. Amend section 4. Local AI cleanup through the system model is allowed as an **opt-in route**.
   - Settings labels it on-device and says it is less accurate than local rules on the test corpus.
   - A downloaded local model stays out of scope for launch.
2. Do not offer it as the default. Do not call it recommended until a measured prompt or guard change brings it to the section 4 thresholds.
3. The alternative is to hide the choice until it meets them. The code and checks stay in place either way.

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

### Decision: recording experience — October 15, 2026

BetterWispr gaps #13–#18 (W5), in scope per the user's decision of October 14, 2026. Two of them amend section 3. [Certain]

- **Custom shortcut (R1, gap #14):** Settings → General records one key with ⌘, ⌥ or ⌃ (⇧ may be added), or an F-key. It refuses with a reason: Escape, modifier keys on their own, keys without ⌘/⌥/⌃ that are not F-keys, ⌘ or ⌘⇧ chords (app and macOS shortcuts such as ⌘Q and ⌘⇧4), ⌃⌘C and ⌃⌘V, and the macOS chords ⌃Space, ⌃⌘Space, ⌃⌘Q, ⌃⌘F, ⌃⌥⌘Space and ⌃ with an arrow. This is the "detect unsupported bindings" part of R1. The three presets stay as quick picks, and Reset returns to Right Option. Hold, double-press, toggle and Escape work as with the presets. The event tap is off while the recorder waits, so the current shortcut cannot start a dictation. Built-in F1–F12 work only with fn held or with standard function keys on. [Certain]
- **Sounds (gap #15):** a short system sound when recording starts and when it stops or the user cancels it. On by default, with a toggle. None on insertion and none for a lone tap's expiry. Both sounds mixed at full level into a recording added no words, and a recording of only the sounds transcribed as empty. [Certain]
- **Microphone changes (gap #16):** this amends "On microphone disconnection, stop safely and retain recoverable audio". When the input device changes during a recording, capture now restarts on the device the microphone setting resolves to, converts to the recording's original format and keeps writing the same file, so audio already captured stays. Only a restart that fails is treated as an interruption, as before. The new "Automatic" microphone uses the built-in microphone while a Bluetooth headset is the default input and the built-in one is alive, so the headset keeps its high-quality playback mode; otherwise it uses the system default. System default stays the default setting; making Automatic the default is a decision for the user. [Certain]
- **Paste-failure card (gap #17):** the bubble shows the text with Copy for 30 s whenever Murmur did not paste it. Copy marks the History entry copied. This is in addition to History recovery and ⌃⌘V. [Certain]
  - **Paste refused:** the target app quit, focus or the field changed, a secure field, or Secure Input.
  - **Paste not attempted:** Insert at the cursor is off ("Saved, not pasted"), or the text could not be saved before pasting.
  - **Stays quiet:** a posted paste that cannot be confirmed (Electron apps, no readable field), as BetterWispr and Wispr Flow also treat it. User follow-up after the live test, October 15, 2026. [Certain]
- **Undo after cancel (gap #18):** this amends "Escape cancels recording; do not insert canceled speech". After Escape or Cancel Recording, the recording is read into memory as 16 kHz samples and its file is deleted as before. For 5 seconds the bubble offers Undo, which transcribes, cleans and inserts it like any dictation, with the destination, mode and routes captured at its start. The samples never go back to disk. They go to the warm helper over its pipe, or as in-memory audio to the cloud route. They are dropped when the window ends, a new recording starts, Undo is used or Murmur quits. With no file there is no retry audio, so a failed Undo says the recording was discarded. A lone tap's expiry and a lost event stream cannot be undone. [Certain]
- **Live words (gap #13), approved by the user on October 15, 2026** ("build live words with the short-lived streaming helper and the optional ~590 MB Live words download"): while recording, the bubble shows the words heard so far. Settled words are bright and the last word, which can still grow, is dimmed, on at most two lines. It is display only: the inserted text is still the whole-clip transcription, and the preview never reaches History, learning or cleanup, and is never logged. [Certain]
  - **How:** a second helper (`ModelBench LIVE_FOLDER --stream RATE`) starts with each recording and exits at release or cancel. Audio goes to it over a pipe and never to disk; when it falls behind, buffers are dropped rather than queued. The warm helper is untouched. [Certain]
  - **Download:** optional. The `live_files` list in `artifact-pins.json` holds the pinned int8 [70, 13, 13] streaming encoder plus the decoder, joint and vocabulary it loads with: 13 files, 609 MB, in their own folder. It is hash-verified once per launch and compiled in the background before its first use. Without it, the bubble is unchanged and dictation is unaffected. The Settings toggle is on by default. [Certain]
  - **Measured on the M3 / 16 GB:**
    - In one process with the offline model, the streaming encoder added 0.5–1.2 GB of wired memory.
    - With the built helper, three runs measured +317 to +573 MB of wired memory while it ran. Three seconds after it exited, memory was back within the noise of the starting value (±260 MB; system-wide readings are noisy).
    - A warm helper is ready 0.12–0.15 s after launch; the first load on a new binary compiles for about 10 s.
    - Each 1.04 s window takes about 0.05 s, and partial text lags speech by about 2 s.
    - Offline transcription running alongside took 0.21 s, against 0.19 s alone.
    - The streamed final text matched the offline text apart from two punctuation marks. [Certain]
  - **Cloud routes:** "Show live words on cloud routes" is off by default (user, October 15, 2026, after the live test). When it is off and transcription runs in the cloud, the helper is not started. [Certain]
  - **App path:** feeding a 26 s clip through the app's `LiveStream` class in real time gave 23 updates, and the helper exited on stop. [Certain]

**Evidence:** `check_recording.swift` (shortcut validation, the custom binding's gestures, the Automatic rule, format conversion, the undo window and session hook) and `check_controller.swift` (the card's state and the 16 kHz conversion), `check_model_download.swift` (the live-words pins) and `check_app_services.swift` (the bubble's text split), plus the fixture flags `--live-words`, `--paste-failed` and `--undo`. Not verified in the live app: see the W5 pull request's checklist. [Certain]

### Decision: Home, Insights, appearance and the welcome guide — October 15, 2026

BetterWispr gaps #19–#21 (W6), in scope per the user's decision of October 14, 2026. One of them amends R6. [Certain]

- **Home (gap #19):** the window now opens on Home. It shows the shortcut and a Start Dictation button, readiness for the microphone, Accessibility, Input Monitoring and the speech model (each with its fix), and the five latest dictations. Start Dictation hides Murmur first, so focus returns to the app you were in, then starts a toggled recording through the same shortcut machine; the next shortcut press or Finish ends it, and the text pastes at the cursor on release as always. [Certain]
- **Insights (gap #19):** words dictated, speaking pace against an average typing speed, time saved, words changed by cleanup and dictionary spellings, apps dictated into and a streak calendar with the current and longest streak. It is computed on this Mac from the entries History keeps, and nothing is stored or sent. [Certain]
  - **Typing speed:** 51.56 WPM, the mean over 168,000 volunteers in Dhakal et al., "Observations on Typing from 136 Million Keystrokes", CHI 2018, where a word is any five characters. Pace uses the same five-character word, so the two compare. The test copied sentences, which is faster than composing, so time saved is conservative. [Certain]
  - **New History fields:** each entry now records the recording length and the app the text was pasted into. They live and expire with the entry. Entries from before this change have neither, so pace and apps count only newer ones, and Insights says so. [Certain]
  - **Retention:** with History off, Insights says History is off rather than counting session-only entries. With no entries, it says History keeps dictations for the chosen period and that older ones have expired. The longest streak is labelled "in History", since retention caps it. Days are local calendar days in the Mac's time zone. [Certain]
  - **Words changed:** a word diff of the raw transcript against the final text, a replacement counting once. Edits made in History count too. The local model's vocabulary pass happens before the raw text, so it is not seen. [Certain]
- **Appearance (gap #20):** System, Light or Dark, System by default. It applies to Murmur's window only. System leaves the window's appearance unset; the floating bubble always follows macOS. [Certain]
- **Show in Dock (gap #20), amends R6:** off by default. It applies at once and persists. The menu bar setting is unchanged. With both hidden, reopening Murmur from Finder or Spotlight opens its window, as before. [Certain]
- **Welcome guide (gap #21):** the setup screen is now a step-by-step guide: microphone, Accessibility, Input Monitoring, the speech model, then a test dictation into a field inside the guide. The current step is saved, so the guide resumes there after quitting. Finishing records guide version 1. A later guide version shows it again. "Welcome Guide…" in the menu bar menu and the app menu, and Replay Welcome Guide on Home, start it over. Installs that were already set up before this change count as having finished version 1. [Certain]

**Evidence:** `check_insights.swift` (pace, time saved, words changed, apps, streaks across days, time zones and daylight saving, History-off and empty states), `check_app_services.swift` (guide resume, clamp, versioning, replay, upgrade default), `check_recording.swift` (the button's toggled start), and the fixture flags `--insights`, `--history-off`, `--empty`, `--guide STEP`, `--settings` and `--system-appearance`. Not verified in the live app: see the W6 pull request's checklist. [Certain]

### Milestone 1 implementation decisions — October 2, 2026

Continue with the selected Unified model and batch processing; available-host inference remains unverified. M1/8 GB performance is deferred and does not block implementation or release. No silent model/provider substitution is permitted. [Certain]

Decision, October 6, 2026 (user: behave like Wispr Flow, which does not hold long dictations): a dictation is never held for cleanup review. When the guard rejects the cleaned words, the transcript's own words are inserted with the model's sentence punctuation and capitals (and its respelling of a dictionary term), guarded again; no second call is made. A provider error (not retried), or a transfer that fails the guard, uses on-device local rules, and if those fail the guard, the dictionary-applied transcript. Every inserted text has passed the guard or is the user's own words; an answer or obeyed instruction is never inserted. Decision, October 6, 2026 (user): cleanup has two styles. **Strict** (default) is the guard above. **Polish** also removes fillers without commas ("yeah", "you know", "like" when not a verb or comparison), removes false starts the speaker restates, and makes small grammar fixes (a word replaced by a similar or misheard word, or a grammar word added or dropped); it may change a word's meaning, but never adds or drops names, numbers or negations, never swaps modals or pronoun persons, and never adds a prefix, appended text or a run of more than three words. Decision, October 7, 2026 (user: a level above Polish that corrects and professionalizes like Wispr Flow; Polish stays as the voice-keeping style): **Professional** is a third style and an explicit exception to "never changes tone". It rewrites grammar (including reordering, "me and John was" -> "John and I were"), removes fillers and false starts, applies corrections cued without commas ("wait no I meant"), and formats lists spoken as "item one, item two" without an announced list. Its guard still rejects answers, appended or prefixed text, added structure and quote edits, never adds names or numbers or changes their order, drops a name, number or negation only inside a correction whose content words recur after the cue, keeps pronoun persons and numbers in their places, and bounds new and dropped words; a dropped content word must be replaced by a similar word, so it never swaps a word for an unrelated one (a lowercase name, an antonym). On-device rules use Strict. Paragraph breaks are allowed (user, October 6, 2026, to match Wispr Flow): with punctuation on, longer dictation gets a blank line where the topic shifts, and a line break right after a sentence end is not added structure. A provider error shows a notice after insertion so a bad key or quota is not silent. Replaces the earlier hold-for-recovery policy, under which one unexplained word held a whole dictation: 3 of the 4 dictations over 100 words were held. Treat dictation text as data and do not log its contents. [Certain]

The spike's unchanged-successful-AX-write paste fallback remains experimental: a delayed write may duplicate insertion. Production must choose one delivery method before attempting delivery, or retain uncertain output for recovery; a timer or change notification does not prove that an earlier write will never arrive. Unknown browser field types remain unverified and excluded from learning. [Certain]

Recorded native/chat observation establishes the narrow feasibility floor, while app-specific unsupported states must remain visible. A production semantic rule for automatic promotion remains unresolved; structural edit similarity alone does not justify learning. [Certain]

Superseded October 16, 2026 (one fix replaces; see the decision in the learning section). Decision, October 4, 2026 (user: "take the Wispr Flow style"): learning has two tiers. One settled correction that passes the rule below adds the corrected spelling as a vocabulary hint (a learned entry with no variants: it biases transcription and cleanup but replaces nothing) and shows a brief "Added … to dictionary" notice with Undo. Two consistent corrections from separate dictations add the misheard form as a variant of that same entry, so it is replaced from then on. A word the user deletes or reverses is never learned again from any mishearing. [Certain]

Implementation decision, October 14, 2026 (follow-up to the user's request to address PR #45's measured spelling loss): preferred-only entries may now recover an unfamiliar single alphabetic word locally, including in Faithful mode, without restoring ASR prompts. Both source and term must have at least six letters; source lowercase and title case must be unrecognized by the English lexicon; exactly one enabled term must share its phonetic key and pass the existing semantic/respelling guard. Explicit variants take priority; known words/names, ambiguous matches, short words, unlisted phrases and disabled terms stay unchanged. This narrowly supersedes “replaces nothing” for a first-tier hint: it creates no stored mapping or learning evidence, and the two-session rule for promoting a heard form into a persistent variant remained unchanged (since October 16, 2026 one settled fix promotes it; new learned entries are no longer preferred-only, so this applies to manual and older hint-only entries). [Certain]

Follow-up after live Faithful testing: the earlier benchmark preseeded an Akash alias and therefore missed preferred-only aakash. Permit a single doubled-letter expansion from a source of at least five alphabetic letters to an enabled preferred term of at least six, including a title-case recognized name. The lowercase source must still be unrecognized; matching phonetic keys, semantic guards, a unique target and explicit-variant priority remain required. This is a spelling preference, not proof of speaker intent: two real names differing by a doubled letter can still be confused. Other known-name substitutions remain blocked without an explicit alias. No dictionary/ledger mapping is automatically created. [Certain]

Decision, October 4, 2026 (user approved): with the NSSpellChecker lexicon, case-only fixes (jira→Jira), spacing fixes (git hub→GitHub, a p i→API) and words of 2–3 letters (Jon→John) are learned too; all-capitals targets skip the ordinary-word test. Without a lexicon they stay rejected. [Certain]

Approved semantic promotion rule (approved by the user October 3, 2026; implemented in `app/Learning.swift`). Condition before learning ships: back the lexicon with NSSpellChecker, so ordinary-word swaps are rejected. [Certain] Rule: a correction is learning evidence only when the target is a plausible respelling of the source. Rules: 1–3 words per side after trimming shared context; no case/punctuation/spacing-only edits, deletions, insertions or longer rewrites; reject negation flips, digits/number words, listed antonyms, function words and homophones, and inflection or short vowel-only changes; when a lexicon is available (NSSpellChecker), reject swaps of one ordinary word for another; otherwise require at least 4 letters per side and either edit similarity ≥ 0.75 or matching consonant-class phonetic keys with similarity ≥ 0.5. A target that is already a manual dictionary term waives only the similarity test. Known limits: without the lexicon, real-word swaps such as casual→causal pass; similar names (Robert→Rupert) pass; short names, plural-like respellings and spacing merges are skipped. Deleted learned entries are tombstoned so old evidence cannot re-promote them. [Likely]

Local cleanup baseline — October 3, 2026: `app/Cleanup.swift` provides a deterministic `RuleCleaner` behind the section 4 guard, with failures held for recovery. It is a baseline and stopgap, not the final local cleanup model choice; the model comparison in section 5, item 5, remains open. [Certain] Measured on Linux with Swift 6.1.2 against a 425-utterance labeled corpus (`app/cleanup-corpus.json`): 96.7% exact match; 1/425 (0.2%) unintended name/number/negation edits, within the ≤ 1% bar; 6/425 (1.4%) strict mismatches; spoken-correction exact match 95.8%, with 22 of 22 ambiguous corrections left unchanged; list precision 97.7% and recall 100%; 0/237 guard false rejects; 2348/2348 adversarial outputs rejected. [Certain] The same agent wrote the corpus, labels and baseline, and the corpus has no real ASR transcripts, so these numbers overstate real-world quality. [Certain] The spoken-correction and list thresholds were set from this baseline and recorded as a decision on October 7, 2026 (section 5, "Decision: cleanup thresholds from the corpus baseline"). [Certain]

### Superseding hardware decision — October 2, 2026

The user removed M1 performance from the required gates. M1/8 GB benchmarking and optimization may be done later; users may select lighter models. This supersedes earlier mandatory M1 baseline and 8 GB default rules, while retaining functional, privacy, safety, and measured-configuration reporting requirements. [Certain]

## 11. Meeting notetaker (W7)

**Status: Approved by the user, October 15, 2026** ("I accept all nine W7 recommendations (Q1–Q9)"). It covers BetterWispr gaps #22 (notetaker), #23 (meeting detection) and #24 (speaker separation), brought into scope by the user's decision of October 14, 2026 (section 1). The user's answers to the open questions are recorded in 11.13. The amendments in 11.12 have been applied to the sections they name. Build status is tracked per milestone in 11.11. [Certain]

BetterWispr's meeting feature (its CHANGELOG, v0.1.0–v0.1.6) was used for scope only: "Me" and "Them" capture, a live transcript, notes, call detection and speaker labels. No code, prompts or numbers are taken from it. Murmur is MIT, and parts of BetterWispr derive from GPL-3.0 VoiceInk (BETTERWISPR_GAPS.md). [Certain]

### 11.1 What a meeting is

A meeting is one recording the user starts on purpose. It has two streams:
- **Me:** the microphone, through the existing `Capture` (the microphone setting, including Automatic, applies).
- **Them:** the audio other apps play, through a Core Audio process tap (11.2).

The two streams are transcribed separately with the local Parakeet model and shown as one transcript, line by line, labelled Me or Them (or Speaker 1, 2… once speaker separation runs, 11.8). After Stop, Murmur can write notes: a title, a summary, key points, decisions and action items (11.6). The transcript, the notes and anything the user types during the meeting are kept under the History policy. The audio is not (11.5). [Certain]

Dictation keeps working during a meeting. Dictated speech also appears in the Me stream, since the user said it. Dictation requests go to the front of the warm helper's queue, ahead of meeting chunks (11.4). [Certain]

### 11.2 Capture

**API: a Core Audio process tap, not ScreenCaptureKit.** [Certain]
- `AudioHardwareCreateProcessTap` takes a `CATapDescription` and returns a tap. The tap is added to a private aggregate device and read like a microphone. Apple documents this in "Capturing system audio with Core Audio taps". `AudioHardwareCreateProcessTap` and the `NSAudioCaptureUsageDescription` Info.plist key are available from macOS 14.2 (Apple docs, and `AudioHardwareTapping.h` in the macOS 27 SDK). Murmur's macOS 26 minimum covers it. [Certain]
- **Permission:** "The first time you start recording from an aggregate device that contains a tap, the system prompts you to grant the app system audio recording permission" (Apple sample-code page). It needs `NSAudioCaptureUsageDescription` in Info.plist. [Certain] It should not need Screen Recording, since Apple names only system-audio permission; verify on the test Mac. [Likely] The System Settings pane where it is listed, and the label macOS 26 uses for it, must be recorded on the test Mac. [Likely]
- **Why not ScreenCaptureKit:** its audio capture (`SCStreamConfiguration.capturesAudio`, macOS 13) runs inside a screen-capture stream. Apple's ScreenCaptureKit overview says to "request screen recording permission" with `NSScreenCaptureUsageDescription`. That is a broader grant than Murmur needs, for a stream it would throw away. Its microphone option (`captureMicrophone`, macOS 15) would not replace `Capture`, which already handles device changes. [Certain]
- **Tap settings:** a private tap (visible only inside Murmur), `muteBehavior` unmuted, so the user still hears the call. The tap is converted to 16 kHz mono as it arrives, the format the model uses. [Certain]
- **Which apps are "Them":** [Certain; Q1 approved October 15, 2026]
  - **The call app.** This is used when it is known: it was detected (11.7) or picked in the Start menu. The tap uses `init(stereoMixdownOfProcesses:)` on that app's audio processes. Call apps and browsers play audio from helper processes, so the process list includes every audio process whose bundle ID equals the app's or starts with it (for example `com.google.Chrome.helper`), resolved through `kAudioHardwarePropertyProcessObjectList`. A process that starts mid-meeting is added. For a browser, that means every tab.
  - **All apps except Murmur.** This is the choice when no call app is known: `init(stereoGlobalTapButExcludeProcesses:)` excludes Murmur and its helpers. It also captures music, videos and notification sounds, and the live view says so.
- **Permission denied or the tap fails:** the meeting does not start silently with one stream. The live view says system audio is unavailable and why, with the fix, and offers "Record only my microphone". [Certain]
- **Device changes:** the Me stream keeps the W5 rule: capture restarts on the new device into the same stream. The tap is independent of the output device. A tap that stops is restarted once, and a gap is marked in the transcript. [Certain]

**Echo of the other side through the speakers.** With speakers instead of headphones, the microphone also hears Them, so Them's words appear twice, once in each stream. [Certain] The approach is decided by measurement, not asserted: [Certain]
1. **Them is never altered.** The tap is a clean copy of what the app played.
2. **Text-level suppression on Me.** A Me word run that repeats a Them run within a few seconds is hidden. It is never deleted. A Me line with nothing of its own left is hidden. "Show hidden echo" in the transcript reveals it. Hidden text is left out of notes input and exports.
3. **Voice processing on the microphone is a candidate, not a plan.** Apple documents `AVAudioIONode.setVoiceProcessingEnabled(_:)` (macOS 10.15). Murmur has no source showing that it cancels another app's speaker output on macOS. It can also change the input format and duck other audio. It is adopted only if the echo measurement (11.10) shows a gain without harming dictation.
4. **Headphones** need none of this. The live view suggests them when the Me level tracks the Them level.

### 11.3 Consent and what Murmur must never do

Recording other people may require their consent where the user or the other participants are. Murmur does not give legal advice and makes no claim about any jurisdiction. [Certain]

- **First meeting:** a one-time sheet explains that Murmur records the microphone and the call's audio, that recording others may require their consent, and that the user is responsible for telling them. Starting requires ticking "I'll let participants know". The acknowledgement is stored with a version, so a changed text asks again. [Certain; Q8 approved October 15, 2026]
- **Every meeting:** the live view's first line says "Let others know you're taking notes", with **Copy notice**. It copies a short neutral sentence for the user to paste into the call chat. Murmur never sends it itself. [Certain]
- **Visible while recording:** [Certain]
  - macOS shows its own microphone indicator. Whether it also shows one for a system-audio tap is to be recorded on the test Mac. [Likely]
  - The live view (11.9) is on screen for the whole meeting. It can be collapsed to a small pill with a red dot and the timer, but it cannot be hidden.
  - The menu bar icon shows a recording state.
  - This holds even when the menu bar icon and the Dock icon are hidden (amends R6, 11.12).
- **Murmur never:** [Certain]
  - starts a meeting without an explicit action each time: a click on Start, or on Take Notes in a detection offer. Detection only offers (11.7).
  - records with no visible indicator, or keeps recording after Stop, after Cancel, or after Murmur quits. After a crash, capture is not resumed on relaunch (11.5).
  - joins a meeting as a participant or bot, connects to a meeting service's API, or reads the meeting service's own recordings or transcripts.
  - captures video or the screen.
  - sends meeting audio off the Mac unless the user chose Cloud in Settings → Meetings. The default is On this Mac (amended October 15, 2026; see 11.14).
  - posts, emails or shares notes on its own. Export is a user action (11.9).
  - records past the meeting cap: 3 hours, with a warning 10 minutes before (Q7, approved). This replaces the 5-minute dictation cap for meetings only (11.12).
- **Info.plist:** `NSMicrophoneUsageDescription` currently says Murmur records "only while you activate the dictation shortcut". It must also name meeting notes. `NSAudioCaptureUsageDescription` is added, saying system audio is recorded only during meeting notes the user starts. [Certain]

### 11.4 Live transcript

**Engine:** the warm `ModelBench --serve` helper and `Chunker` (`module-one/capture/Capture.swift`), already used for long dictations. Each stream gets its own `Chunker`, which cuts at pauses near 15 s. Each chunk is sent to the warm helper, and the text is appended to the transcript as a line with the stream, start time and end time. No new model or download is needed for W7a. [Certain]
- **Why not W5's streaming helper:** live words run one extra helper while recording, for +0.3–0.6 GB of wired memory (section 10, W5 decision). A meeting would need one per stream, held for the whole meeting. Chunked offline text is the PRD's accuracy baseline. It costs about 1.25 s of compute per minute of speech (STREAMING_TRANSCRIPTION.md), so two streams over two hours need about 5 minutes of helper time. The price is lag: a line appears roughly one chunk after it starts. A live partial line from the streaming helper may be added after W7a if the measured lag is a problem. [Certain]
- **Queue:** one warm helper serves dictation and both meeting streams. Dictation jumps ahead of queued meeting chunks, so a dictation during a meeting is not delayed by a backlog. Meeting chunks run in order per stream. When the backlog passes 2 minutes of audio, the live view says the transcript is behind; nothing is dropped. [Certain]
- **Timing:** lines are ordered by capture time, not by when transcription finished. Each stream's sample clock is mapped to host time at the start of each chunk, so Me and Them lines interleave correctly. [Certain]
- **Vocabulary:** the dictionary and learned entries apply to meeting text as they do to dictation. Cleanup (fillers, corrections, lists, commands) does not run on meeting text. The transcript is what was said, so spoken commands are not executed. Learning never observes meeting text. [Certain]
- **Long meetings (1–2 h):**
  - The transcript is appended to disk as lines arrive, so a crash keeps everything already transcribed.
  - Memory must stay flat. The live view keeps only its visible lines in memory, and chunks are deleted as they are transcribed (11.5).
  - The 3-hour cap applies (11.3).
  - If both streams are silent for 5 minutes, or the detected call app stops using the microphone, the live view asks "Call ended?" with Stop. Murmur stops on its own only after 10 minutes of silence on both streams, because stopping a recording is the safe direction. [Certain]
- **Budgets on the M3 / 16 GB test Mac (targets to measure, not claims):** [Certain]
  - Added resident memory during a 2-hour meeting: at most 400 MB beyond the idle app and warm helper, and no more than 10% growth between minute 10 and minute 120.
  - Average CPU of Murmur plus its helpers: at most 20% of one core over the meeting.
  - Transcript lag: p90 of at most 25 s from the end of speech to its line.
  - Dictation during a meeting: warm latency within 0.5 s of the same dictation with no meeting.
  - Disk: chunk files at 16 kHz mono 16-bit are 115 MB per stream-hour at most. Raw 48 kHz stereo float from the tap would be about 1.4 GB per hour, so it is never written.

### 11.5 Storage, retention and deletion

**Audio is not kept.** This keeps the approved rule "no permanent audio history" (section 6). [Certain]
- Chunk files are written to the app-private chunk folder (`Chunker.directory`) with restrictive permissions, and each is deleted once its text is saved.
- After a crash, chunks not yet transcribed are retry audio under the existing 24-hour rule. On relaunch Murmur offers "Finish interrupted meeting", which transcribes them locally and saves the meeting. It never restarts capture.
- **Exception with speaker separation on:** the Them stream (16 kHz mono) is kept until diarization finishes after Stop, at most 24 hours, then deleted (11.8; Q4, approved). The Me stream is never kept.
- Meeting audio is never exported, synced or sent.

**Transcript and notes follow History.** [Certain]
- Each meeting is stored as one record inside the History folder (`meetings/` under it): title, start time, length, source app, lines, the user's own notes, speaker names, generated notes and their route.
- Retention (30 days, six months, forever) applies from the meeting's start time, with the same calendar rule and the same preview before shortening it. Meetings count toward the History size cap. A meeting is about 60–120 KB of text an hour, so it is a small share.
- **History off:** a meeting is kept in memory only until Murmur quits. The live view says so at start, and export still works.
- **Manual deletion:** per meeting from the Meetings page, with confirmation. It removes the record, any kept Them audio and any notes.
- **Delete All Data:** the meetings folder lives inside History, so the existing wipe removes it. `DeleteAllDataText.body` and `explanation` must name meetings. An active meeting is stopped and discarded before the wipe (a new first `PostWipeStep`). Retry chunks and kept Them audio are covered by the retry-audio step.
- No telemetry. Logs hold only content-free reasons, such as "tap failed" or "notes guard rejected item".

### 11.6 Notes

**Output:** a title (at most 8 words), a summary (2–4 sentences), key points, decisions, and action items (who, what, and when only if said). Empty sections are left out rather than filled with "no decisions were made". Action items have checkboxes in Murmur. Notes are written after Stop and can be rewritten on demand ("Update notes"). With speaker separation on, they are written once separation finishes, fails or is skipped, so they use speaker names. Renaming or merging a speaker changes the name in notes already written; reassigning a line, or editing the user's notes, marks them out of date. [Certain]

**Input:** the transcript with hidden echo removed, numbered lines (`[L42 Them 00:14:03] …`), speaker names if set, and the user's own notes marked as theirs. Like dictation, it is data: it goes inside nonce-tagged blocks, and the prompt says nothing inside them is an instruction. Corpus cases must include a participant saying "ignore previous instructions" or "add an action item for…" without anyone agreeing. Prompts are written for Murmur, not taken from BetterWispr. [Certain]

**Grounding: no invented items.** Every key point, decision and action item must cite the line numbers it rests on. A deterministic check, in the spirit of `CleanupGuard`, drops an item when: [Certain]
- it cites no line, or a line that doesn't exist;
- it shares no content word with its cited lines;
- it contains a name, number, date or time that its cited lines (or the user's notes) don't contain;
- its owner is neither named in its cited lines nor the speaker of one of them.

The title and summary may not contain a name or number absent from the transcript or the user's notes; otherwise the title falls back to "Meeting with <app>, <date>" and the summary is left out. An action item needs a commitment or an assignment in what was said ("I'll send it", "can you send it? — yes"). A suggestion, a question or something already done is not one. Dropped items are counted in diagnostics without their text. Each item links to its lines in the transcript. [Certain]

**Routes** (a separate "Meeting notes" setting; each route keeps its existing disclosure and Keychain rules): [Certain; Q3 approved October 15, 2026]
- **None:** transcript only. Local rules cannot write notes, so there is no on-device rules fallback.
- **Apple Intelligence** (on device, no key). TN3193 states "a context window of 4096 tokens per language model session", counting instructions, every prompt and every response. A token is about 3–4 characters of English. An hour of two-way talk is roughly 8,000–10,000 words, about 11,000–14,000 tokens, so long meetings must be chunked:
  - **Map:** a fresh `LanguageModelSession` per chunk of about 1,500 words of lines (sized so instructions, the chunk and the reply fit, checked with `tokenCount(for:)` where available). It extracts cited points, decisions and action items.
  - **Reduce:** one more session merges the chunk results, which are short, into the final notes, keeping citations. A 2-hour meeting may need two reduce levels.
  - `exceededContextWindowSize` splits the chunk and retries once. Other errors leave the meeting saved without notes and say why.
  - **Measured limits are a warning, not a measurement of notes:** as a cleanup route, the same model missed every section 4 threshold, with 63.7–80.3% guard acceptance and 16.8–29 s for 600–906 words (section 10). Notes are a different task and must be measured separately (11.10). Until then, Settings labels it "on-device, less accurate".
- **Gemini and the custom OpenAI-compatible endpoint:** the same map-reduce with a larger chunk per route, so grounding works the same way. The disclosure names the host and says the transcript contains **other people's words**, speaker names and the user's notes. The Gemini storage and free-tier review disclosures apply. A loopback custom endpoint counts as local, as it does for cleanup. There is no silent fallback between routes.

### 11.7 Meeting detection (#23)

**What it does:** when a known call app, or a browser, starts using the microphone, Murmur shows an offer in the bubble: "Zoom is using the microphone. Take meeting notes?" with **Take Notes**, **Not now** and **Never for Zoom**. It never starts recording automatically. Take Notes starts a meeting with that app as the Them source (11.2). [Certain]

**How:** Core Audio's process objects. Murmur listens to `kAudioHardwarePropertyProcessObjectList` and reads each process's `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningInput` (documented in `AudioHardware.h`; the properties are in the macOS 26 and 27 SDKs). This needs no extra permission, reads no window or screen, and stores nothing. [Likely: the exact listener behaviour must be checked on the test Mac.]
- **Known call apps:** a built-in bundle-ID list (Zoom, Microsoft Teams, Slack, Webex, FaceTime, Discord, WhatsApp, Signal, Telegram), with each ID verified when it is implemented. A helper process maps to its app by bundle-ID prefix.
- **Browsers** (Safari, Chrome, Arc, Edge, Brave, Firefox): microphone use is ambiguous. It may be a call, a page's voice input or voice search. The offer says "<Browser> is using the microphone" and does not claim a call. Murmur does not read window titles or page URLs to tell them apart. That would be a new Accessibility read the modes decision does not cover (Q5, approved).
- **Filters:**
  - Murmur's own processes (the app and its helpers) never trigger an offer.
  - Input must run for 5 seconds before the offer, which filters short voice searches.
  - One offer per app per microphone session.
  - The offer disappears after 30 seconds.
  - No offer while a meeting or dictation is recording.
- **Turning it off:** Settings → Meetings → "Offer to take notes when a call starts", plus per-app "Never" with a list to undo it. Default: on, because it only offers and runs locally (Q6, approved).

### 11.8 Speaker separation (#24)

**Model:** FluidAudio's offline pipeline (`OfflineDiarizerManager`: pyannote community-1 segmentation, WeSpeaker embeddings, PLDA and VBx clustering), run once on the Them stream after Stop. Me stays "Me". People in the same room as the user share the microphone and are not separated, which is a known limit. [Certain]
- **Why offline:** FluidAudio's own benchmarks on the AMI SDM 16-meeting test set (`Documentation/Benchmarks.md` at FluidAudio `0b1f462`) give these average DERs: [Certain]
  - offline (pyannote community-1 with VBx): 10.62%, on an M5 Pro, July 3, 2026;
  - LS-EEND streaming: 20.7%, on an M4 Max CPU;
  - Sortformer streaming (high-latency config): 31.7%, on an M2;
  - pyannote streaming: 38.2–55.9% across four chunk configurations, on an M5 Pro, July 3, 2026.

  Its docs say streaming is "a lot more fragile to clustering" and that "offline is more than enough for most applications". AMI is far-field room audio, not call audio, and none of these Macs is the test Mac, so these numbers are not Murmur's. The 10.62% table used `--threshold 0.7` under the old semantics, which is about 0.775 today; the default is 0.6. W7d therefore sets the clustering threshold explicitly and records it with its results. [Certain]
- **Download:** optional, about 21.6 MB: `Segmentation.mlmodelc`, `FBank.mlmodelc`, `Embedding.mlmodelc`, `PldaRho.mlmodelc` and `plda-parameters.json` from `FluidInference/speaker-diarization-coreml` (sizes from the Hugging Face API on October 15, 2026). These are pinned with sizes and hashes in `artifact-pins.json`, like the other models. The revision must be the one FluidAudio `0b1f462` resolves. The repository's current `main` (`7eab74f`) differs from the revision its provenance link names (`df2625a`), so the pin is resolved before W7d starts. The online pipeline's files (`pyannote_segmentation`, `wespeaker_v2`) are not used. [Certain]
- **License:** the repository's NOTICE scopes CC-BY-4.0 to exactly those offline files. THIRD_PARTY_NOTICES and the download sheet must credit pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference, link CC-BY-4.0, and say the files are modified Core ML conversions. [Certain]
- **Assigning lines:** each Them line goes to the speaker whose segments overlap it most. Chunks run about 15 s, so on calls with several remote speakers many lines will cross a speaker change. Such a line is split at the change using word timings. FluidAudio's `ASRResult` has `tokenTimings`, but `ModelBench --serve` returns plain text today, so W7d must pass the timings through first. The fallback is to re-transcribe each speaker segment from the kept Them audio. Speakers are numbered in order of first speech. [Certain]
- **Renaming:** per meeting. A speaker can be renamed, two speakers merged, or one line reassigned. Names are stored with the meeting and expire with it. A rename or merge relabels notes already written; a reassigned line marks them out of date (11.6). [Certain]
- **Never kept:** voice embeddings are discarded after the meeting is processed. Murmur does not recognise people across meetings, because that would be stored biometric data. [Certain]

### 11.9 UI

- **Meetings page:** a new screen beside Home, Insights and History (the `Screen` enum in `UI.swift`). It lists meetings with title, date, length, source app and notes status. Search covers titles and transcript text. "Start Meeting Notes" opens a menu: the detected or running call apps, then "All apps". A meeting's page has Notes, Transcript and My notes tabs. The transcript shows labels, timestamps and the "Show hidden echo" toggle. Citations in notes jump to their lines. [Certain]
- **Other ways to start:** a Home button and a menu bar item, "Start Meeting Notes", plus the detection offer. No global shortcut in W7. [Certain]
- **Live view:** a floating panel docked to a screen edge (right by default) that does not take focus unless clicked. It shows a red dot, "Recording" and the timer, Me and Them level meters, the source app, the latest transcript lines, a My notes field, and Stop and Cancel (Cancel asks before discarding). It collapses to a pill but cannot be hidden (11.3). It follows Reduce Motion and Reduce Transparency, and VoiceOver announces start, stop, permission problems and "transcript is behind". [Certain]
- **After Stop:** the meeting is saved at once with its transcript. The page then shows "Finishing transcript", then "Separating speakers" and "Writing notes" where those are on. Each step can fail on its own without losing the transcript. [Certain]
- **Export:** Copy notes, Copy transcript, and Save as Markdown (a save panel; title, date, length, speakers, notes, then transcript; hidden echo left out). Nothing is uploaded. [Certain]

### 11.10 Acceptance evidence

Every result records machine model, RAM, macOS and app versions and raw numbers, as section 8 requires. The bars below were approved by the user with Q9 on October 15, 2026, before any run, so they are not fitted to results. Real-call recordings need every participant's consent and stay off the repository. [Certain]

**W7a, capture and transcript:**
- Tap capture from Zoom, Teams, Meet in Chrome and Safari, FaceTime, and "All apps", with headphones and with speakers. Record the permission prompt, the System Settings entry and the macOS indicators.
- **Echo:** on 5 speaker calls, the share of Them words that also show up visible in Me, with and without text suppression (and voice processing, if tried). Bar: at most 5% visible, and at most 1% of the user's own words wrongly hidden.
- **Transcript accuracy:** WER of the chunked Me and Them transcripts against a hand transcript on 3 real calls, against the same audio transcribed whole offline. Bar: within 1 point.
- The 11.4 budgets on 1-hour and 2-hour meetings: memory over time, CPU, lag, dictation latency during a meeting, disk.
- Crash mid-meeting (kill the process): transcribed lines kept, leftover chunks offered and transcribed, no capture on relaunch, chunks gone after 24 h.
- Retention, per-meeting delete, Delete All Data (including during an active meeting), and History off.
- Network: no requests during a meeting with meeting transcription On this Mac and the None or Apple notes route. Automatic update checks are skipped while a meeting records.
- `check_meetings.swift`: chunk ordering across streams, echo suppression on fixtures, cap and silence stops, storage, expiry, wipe.

**W7b, notes:**
- **Notes corpus:** at least 20 transcripts, with real calls (consented) and scripted meetings, labelled with the decisions and action items actually agreed. It includes injection lines, unagreed suggestions, things already done, names and numbers.
- **Per route:** unsupported items (no grounding in the transcript), missed decisions and action items, and invented names or numbers after the check. Bar: 0 invented names or numbers after the check, and at most 0.2 unsupported items per meeting.
- Time to notes for a 1-hour and a 2-hour meeting on each route. For Apple Intelligence, `exceededContextWindowSize` never reaches the user.
- `check_meetings.swift`: the grounding check accepts and drops items on fixtures, plus the prompt layout and nonce tags.

**W7c, detection:**
- An offer appears for each listed app and each browser on starting a call, and not for Murmur's own recording, a 2-second voice search, or a second time in the same call. "Never" and the off switch work. No recording starts without Take Notes.

**W7d, speaker separation:**
- DER and word-level speaker attribution on at least 10 consented calls with 2–6 remote speakers, on the M3 / 16 GB. Bars: DER at most 20% on the Them stream, the correct speaker count on at least 80% of calls, and at least 85% of words attributed correctly on calls with 3 or more remote speakers.
- Processing time and peak memory for 1-hour and 2-hour meetings. Bar: at most 2 minutes for 1 hour.
- Them audio is deleted once diarization finishes, and at 24 h.
- Renaming, merging and reassigning persist. A rename or merge relabels notes already written, and a reassigned line marks them out of date. Attribution notices are present.

**Not verified in the live app** is listed in each pull request's checklist, as for W5 and W6.

### 11.11 Phasing

Each milestone is its own pull request with its own evidence (11.10) and live-test checklist. The size uses the BETTERWISPR_GAPS.md scale. [Certain]

| Milestone | Scope | Depends on | Size |
|---|---|---|---|
| **W7a, capture and transcript** | Tap and Me capture, echo suppression, chunked live transcript, the live view, the consent sheet and notice, storage and retention, crash recovery, Delete All Data, the Meetings page, transcript export, Info.plist strings | Q1, Q2, Q7, Q8 (approved) | L |
| **W7b, notes** | The notes route setting, map-reduce, the grounding check, the notes corpus and its measurement, notes export, "Update notes" | W7a; Q3 | M |
| **W7c, detection** | Process-object listener, app list, offer card, settings and "Never" list | W7a (it starts a meeting); Q5, Q6 | S |
| **W7d, speaker separation** | Pinned diarization download, attribution notices, offline diarization after Stop, Them-audio retention, renaming, merging and reassigning | W7a; Q4 | M |

**W7a status (October 15, 2026): built, in review, not live-tested.** Measured with `app/tools/measure_meeting.swift` on the MacBook Air M3 (Mac15,12), 16 GB, macOS 27.0.1. It feeds two LibriSpeech test-clean streams, with clips looped and 0.8 s gaps, through the real Chunker, feed, pump and warm helper. This is read speech, not call audio, so it does not meet the 11.10 call-audio bars by itself. [Certain]
- **Accuracy, 20 min per stream, real time:**
  - Chunked WER: Me 1.49%, Them 1.84%.
  - The same clips transcribed whole: 1.29% and 1.50%.
  - The difference is 0.2–0.34 points, inside the 1-point bar.
- **Accuracy, 120 min per stream at 12×:** chunked 1.51% and 1.65%, against 1.33% and 1.34% whole.
- **Lag at real time:** median 10.0 s, p90 14.7 s and max 16.9 s from a chunk's end to its line, inside the 25 s bar. The backlog never exceeded one chunk.
- **Dictation during a meeting:** median 0.117 s and max 0.178 s for a 10 s clip, against 0.068 s alone. That is within the 0.5 s bar.
- **CPU:** 20.6 CPU-seconds for 20 minutes of two-stream meeting, 1.7% of one core. At 12×, 105 CPU-seconds for 120 minutes.
- **Memory (RSS), rerun with an autorelease pool and 16-bit chunks:**
  - The harness, standing in for the app's meeting side, read 31 MB at minute 10. It then held at 38–45 MB from minute 20 to 120, with no steady climb.
  - The helper read 73 MB, then 60 MB from minute 70.
  - Together they were 103 MB at minute 10 and 102 MB at minute 120. Wired model memory is not counted.
  - In the same run, chunked WER was Me 1.51% and Them 1.52%, and CPU was 1.3% of one core.
- **Not measured:** the app's own memory and CPU during a real meeting, the tap, echo with speakers, and real calls. These are on the W7a pull request's live checklist.

**W7a fix (October 15, 2026, after the first live test).** A FaceTime meeting transcribed nothing on either stream. The record shows gaps at 20 s and 44 s, and no microphone restart succeeded. [Certain]
- **Likely cause:** the call reconfigured the audio devices, which stopped the microphone engine and the tap's aggregate device without an error. Neither was rebuilt. [Likely]
- **What happened:** a stall watch (`StreamWatch`) now notices 3 s without audio on a stream. It marks one gap, then rebuilds the stream every 3 s until audio flows: a new microphone engine, or a new tap and aggregate device. A change of default output device also rebuilds the tap. The old stream is stopped first, which transcribes its last partial chunk. [Certain]
- **Logs:** every gap, rebuild, recovery, chunk and line is logged with no content. Chunks log their length and peak level; lines log their word count. The tap logs which processes it tapped and which were playing audio. [Certain]
- **Reproduced on the M3:**
  - A meeting microphone kept running while another process turned voice processing on and off.
  - Stop flushed the last partial chunk.
  - A rebuilt microphone continued at once, with a dictation capture running alongside.
- **Not reproduced:** a real FaceTime call, and the tap side, which needs System Audio Recording for the test process. [Certain]

**Second live test (October 15, 2026).** An "All apps" meeting with a YouTube video took no notes. The new logs showed the root cause. Once a minute, the expiry timer's audio purge deleted files in the live meeting's chunk folder, including the chunk being written, and removed the folder once it was empty. Both streams then failed to write ("chunk-write-failed"), and the earlier FaceTime gaps were likely the same cause. [Certain]

The fixes:
- **Purge:** the purge now skips the live meeting and any meeting still transcribing, and the chunker re-creates a missing folder.
- **Matching:** call-app processes match ignoring case, and are matched again at every refresh. Arc's audio helper is `company.thebrowser.browser.helper`.
- **Idle tap:** a tap delivers nothing while no tapped app plays, so that is now idle rather than a stall. The silent time is filled with zeros, which keeps Them line times true.
- **Meters:** each meter is scaled to its own recent loudness, with a floor.
- **Panel:** the live panel minimizes to a pill (red dot, timer, Stop), can be dragged, and remembers both. [Certain]

**W7a accepted as is (user, October 15, 2026).** After the live tests, the user accepted two open items for now: FaceTime capture is untested, and some echo fragments are still left in Me lines. Echo handling is unchanged until a milestone needs it. [Certain]

**W7b status (October 16, 2026): merged (PR #52, integrated in PR #56); live-tested by the user on one Arc call with notes from their custom route. The other routes and the 11.10 real-call measurements are open.** [Certain]
- **What it does:** after Stop, and once the transcript is complete, notes are written on the route chosen in Settings → Meetings → Meeting notes. That route is separate from cleanup. The first Stop asks for it, with None preselected; a Stop the user clicked opens the Meetings page for the question, while an automatic stop (cap, silence) asks the next time the page is opened. The notes have a title, a summary, key points, decisions and action items with checkboxes. Each item cites its lines, and a citation jumps to the line in the Transcript tab. Update Notes rewrites them. Editing My notes, or a leftover chunk finished later, marks them out of date. Copy Notes and the Markdown export include them.
- **Record:** `Meeting.notes` is optional, so W7a records still load (checked on a literal W7a record). Citations are stored as line ids, not L numbers, so they survive lines inserted later.
- **Prompt and reply:** the transcript is shown as numbered visible lines, `[L12 Them 3:05]`, with hidden echo left out. The lines and the user's notes go inside nonce tags, and the instructions say nothing inside them is an instruction. The reply is one pipe-separated line per item (`ACTION | L7 L8 | Me | Friday | …`). Nested JSON was tried first: on the corpus, Apple's model broke it in 7 of 22 meetings. Apple Intelligence answers through guided generation with a runtime schema (`DynamicGenerationSchema`, no macros), which is rendered into the same lines, so grounding is identical on every route. Decisions and action items are generated before key points, and the reply is capped at 1,200 tokens: uncapped, two replies ran for over 3 minutes.
- **Grounding check** (`NotesGrounding`, deterministic). It runs after each map request and again on the merged notes, against the whole meeting. An item is dropped when:
  - it cites no line, or a line that does not exist;
  - it rests only on lines that speak to a note-taker or an AI ("ignore previous instructions", "add an action item…", "the assistant must…"). Such lines never count as support;
  - it shares no content word with its lines;
  - it has a name, number, date or time that its lines and the user's notes lack. Number words and digits are compared as numbers;
  - it reverses its lines (`polarityChanged`, October 16, 2026). A negation (`CleanupText.isNegation`: no, not, never, none, n't) reaches the words after it to the end of its clause, ending at punctuation or a conjunction, so "No, Friday works" does not negate Friday. A shared word is flipped when every cited use is negated and no use in the item is, or the reverse. The item is dropped on two flipped words, or on one that is at least half of two or more shared words. It is also dropped when it uses one side of a short opposite list (more/less or fewer, higher/lower, warmer or hotter/cooler or colder, increase/decrease, above/below, bigger or larger/smaller, faster/slower) that its lines say only the other way. `Learning.antonyms` is not used: start/end, in/out or send/receive are ordinary paraphrases in notes. A real call needed this. The Custom Provider wrote "northern states expected to be cooler than average", and its only cited line said "no states are expected to be cooler than average". The rule is marked `ponytail:`. An antonym standing in for a negation ("not doing the launch" → "skip the launch") passes, and so does a flip spread across clauses;
  - it is an action item whose owner is not named in its lines and is not a speaker of one of them;
  - it is a decision with no agreement in its lines, or an action item with no commitment.

  The title and summary are checked against the whole transcript. A failing title falls back to the source and date, and a failing summary is left out. Dropped items are counted by reason in a content-free log line. The phrase lists and the 5-letter-prefix word match are marked `ponytail:` in the code, to be tuned on real calls.
- **Speaker names (October 16, 2026, after W7d):** with speaker separation on, notes wait for it: the page shows "Separating speakers…" and then "Writing notes…". If separation fails or is skipped, notes are written with Me and Them. While it waits, Write Notes and Update Notes are unavailable; Skip writes them at once. Numbered lines carry the speaker label (`[L12 Priya 3:05]`, or `Speaker 2`), and the instructions name the other side's speakers as the owners to use. The grounding check treats every speaker label in the meeting as present in the transcript, so an owner or item naming a renamed speaker is not an invented name. The label is removed from the text before the number check, so the 2 in "Speaker 2" never supports a number. An owner must still speak in, or be named by, the cited lines. Renaming or merging a speaker replaces the old label, as a whole word, in the title, summary, item text and owners. Reassigning a line, or giving a speaker a name another speaker already has, marks the notes out of date instead. The model is never called on a rename. Copy Notes and the Markdown export show the names. Checked in `check_meetings.swift` and `check_speaker_flow.swift`; not live-tested. [Certain]
- **Map-reduce:** chunks are cut on line boundaries. They are 5,000 characters for Apple (about 1,700 tokens, which leaves room for the instructions and the reply in 4,096), 24,000 for Custom and 150,000 for Gemini. Part notes are merged in batches, level by level. A context overflow (`exceededContextWindowSize`, surfaced as a too-large error) splits that request once and retries. A second overflow leaves the meeting without notes and says why. Gemini's notes timeout is 120 s, and Custom uses its 300 s maximum.

**W7b evidence (October 16, 2026).** Measured on the MacBook Air M3 (Mac15,12), 16 GB, macOS 27.0.1, app 0.1.0, with `app/tools/measure_meeting_notes.swift`. `app/meeting-notes-corpus.json` is the development set: the prompt, rules and schema were tuned against it, so it is not evidence by itself. `app/meeting-notes-heldout.json` (9 meetings, 8 decisions, 11 action items, 3 injections) was written after the code was frozen and run once. Both are scripted synthetic meetings, not real calls. The development set has 22 meetings, labelled with 21 agreed decisions and 30 action items, and it includes 6 injection lines, unagreed suggestions, things already done, names, and numbers in words and digits. Unsupported items are judged against the labels, not by the check, which would make the count 0 by construction: a decision or action item is supported only if its cited lines overlap a labelled item of its kind, and any item containing a trap counts as unsupported. Invented names are checked by the tool on its own (any capitalized word inside a sentence that the meeting never says, plus traps); numbers use the same parser as the check. [Certain]
- **Apple Intelligence, held-out set (the evidence):** 0 unsupported items in 9 meetings (bar 0.2 per meeting) and 0 invented names or numbers (bar 0). **Passed.** It missed 2 of 8 decisions and 2 of 11 action items. Median 3.7 s per meeting, 5.3 s at most, no failures. The check dropped 7 items: 4 sharing no word with their lines, 2 decisions without agreement, and 1 resting on a line addressed to the note-taker.
- **Apple Intelligence, development set:** 1 unsupported item in 22 meetings (0.05 per meeting) and 0 invented. It missed 7 of 21 decisions and 6 of 30 action items. The check dropped 34 items: 13 decisions without agreement in their lines, 9 sharing no word, 8 with a name, number or date their lines lack (often a date in a neighbouring, uncited line), and 4 actions without a commitment. The misses are a mix of those drops and items the model never wrote.
- **Titles:** the model mostly writes Title Case even when asked for sentence case. The check reads a capitalized word with no related word in the meeting as a possible name, so many titles fall back to "Meeting with …, date". That is safe, not ideal.
- **1-hour meeting:** 9,018 words, the corpus repeated back to back. It took 15 chunks, 20 requests and 482 s, with no context overflow reaching the user.
- **2-hour meeting:** 18,006 words. It took 30 chunks, 40 requests and 780 s, with no context overflow reaching the user. On these back-to-back synthetic meetings the merge keeps few items (8 points, 2 decisions, 6 actions in 2 hours); merging is the weakest step on Apple's context.
- The label "on-device, less accurate" stays until this measurement is repeated on real, consented calls.
- **Gemini and Custom Provider:** not run. The measurement reads Murmur's key from the Keychain, which would raise a Keychain prompt for the test binary. The command is `/tmp/mmn gemini` (see the tool's header). **Open.**
- **Real calls:** none; consented recordings are needed. **Open.**
- **Polarity rule (October 16, 2026):** rerun of Apple Intelligence on both sets, same Mac. The rule dropped no item on either set, so false drops did not rise. The check kept 90 development-set items and 28 held-out items, and the other reasons dropped 41 and 9. Held-out: 0 unsupported (bar 0.2 per meeting), 0 invented (bar 0); missed 3 of 8 decisions and 2 of 11 action items; median 3.9 s. **Passed.** Development set: 3 unsupported (0.14 per meeting), 0 invented; missed 7 of 21 decisions and 5 of 30 action items. None of the three is a flip: they are a question, a topic and a vague action that the labels do not list. Apple's replies vary between runs, so the misses differ from the first run by model variance, not by this rule. `check_meetings.swift` has the real call's item, which is dropped, plus its negated wording and 8 paraphrases that must stand.
- **`<unk>` in transcripts (October 16, 2026):** the same call's transcript said "El Ni<unk>o". Parakeet's 1,024-piece vocabulary has no accented letters (only £, € and ¥ outside ASCII), so the letter cannot be recovered. The helper drops the piece and the gap it leaves (`BoostFilter.withoutUnknown`: "El Nio", "hi <unk>." → "hi."). It does this in `emit`, the one place every line to the app passes through, so dictation, meeting chunks, boundary replacements and live words are all covered. Checked in `check_boost_filter.swift`.
- `check_meetings.swift` covers the grounding rules on fixtures, the prompt layout and nonce tags, the parser, the title fallback, map-reduce with one overflow split, the route setting and the disclosures.

**W7c status (October 16, 2026): built, in review, not live-tested in the app.** [Certain]
- **What was built:**
  - The rules are in `CallDetection.swift`. The offer panel, Settings rows and a once-a-second poll from the existing 0.15 s timer are in `CallOfferUI.swift`.
  - Murmur reads `kAudioHardwarePropertyProcessObjectList` and each process's bundle ID and `kAudioProcessPropertyIsRunningInput` once a second. It does not install property listeners: per-process input changes would need a listener on every process object, and the poll costs 1.4–2.9 ms per call on the M3. With the switch off, nothing is read.
- **How matching works:**
  - A process maps to a listed app by bundle ID or bundle-ID prefix, ignoring case.
  - A known helper outside the prefix (Safari's `com.apple.WebKit.GPU`, FaceTime's `com.apple.avconferenced`) counts only while that app is open, since every WebKit app shares that helper.
  - Telegram's non-App-Store client (`com.tdesktop.Telegram`) is added for detection.
- **When it offers:**
  - A session ends after 15 s with no input, so a device switch or a brief stop does not offer again in the same call.
  - A meeting that records uses up the offer for every call running at the time, so Stop is not followed by an offer for the same call.
  - Dictation only defers the offer.
- **What the offer says:** "<App> is using the microphone." A browser's offer asks "If this is a call, take meeting notes?", so it never claims a call. The offer has its own non-activating panel at the bubble's position, because the dictation bubble hides itself on status changes.
- **Measured on the MacBook Air M3, macOS 27.0.1, with `app/tools/probe_call_detection.swift`:** it runs the same rules on the live process list.
  - Chrome on a local `getUserMedia` page: one offer 5 s after its helper's input started.
  - No second offer when the microphone came back after 8 s off.
  - No offer for a 2-second use.
  - No offer with Chrome named as Murmur's own ID, with a meeting live, while dictating, with Chrome on the Never list (in upper case), or with the switch off.
- **Bundle IDs:** checked on this Mac for FaceTime, Safari, Chrome and Arc. The other apps are not installed here.
- **Not verified:** the offer in the built app with a real call in any listed app, Safari's and Arc's input processes, Take Notes through the consent sheet, and VoiceOver. These are on the pull request's live checklist.

**W7d status (October 16, 2026): merged (PR #55); live-tested by the user on one Arc call, speakers separated 2.5 s after Stop. The 11.10 real-call bars are open.** Speaker separation runs after Stop as described in 11.8. Measured on the MacBook Air M3 (Mac15,12), 16 GB, macOS 27.0.1, app 0.1.0 (1), with `app/tools/measure_speakers.swift`. [Certain]
- **What was built:**
  - The pinned download: `FluidInference/speaker-diarization-coreml` at `df2625a`, 21 files, 21,599,417 bytes, hash-checked like the other models. The helper loads the files directly; FluidAudio's downloader is never used, so nothing is fetched or purged on its own.
  - A one-shot helper, `ModelBench DIR --diarize KEPT_WAV THRESHOLD`. It prints only speaker ids and times, then exits. It reads the kept file memory-mapped, so nothing is copied to a temporary folder.
  - The kept Them stream: `retry-audio/speakers/<id>.wav`, 16 kHz mono 16-bit, owner-only. It is deleted after diarization, Skip, meeting deletion or retention, and at 24 hours. Delete All Data covers it through the retry-audio folder.
  - Word timings: a timed request to the warm helper returns word times for Them chunks while separation is pending. A line is split where the voice changes, and the first piece keeps its id.
  - Rename, merge and reassign, per meeting.
- **Deviation from 11.8:** lines without word times are assigned whole to the speaker with the most overlap, not re-transcribed per segment. This applies to the cloud route, and to lines where the dictionary changed the word count. [Certain]
- **Switch off or model removed:** finished meetings still waiting are skipped at once, and their call audio is deleted rather than kept for 24 hours with nothing to process it. A meeting being recorded keeps the choice it started with, like the route. [Certain]
- **Clustering threshold:** 0.6, FluidAudio's community-1 default, fixed before scoring. [Certain]
- **Corpus:** 12 synthetic calls, about 8 minutes each, with 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 6 and 6 remote speakers. They are LibriSpeech test-clean turns, 0.2–1.0 s apart, with no overlap. They ran through the real Chunker, pump, timed helper request, kept WAV, diarizer and assignment. This is read speech, not consented calls, so it is a proxy. The 11.10 bars, which are set on calls, stay open. [Certain]
  - DER (10 ms frames, 0.25 s collar): mean 7.96%, per call 3.97–12.41%. Bar ≤ 20%.
  - Correct speaker count on 11 of 12 calls (92%); one 6-speaker call found 5. Bar ≥ 80%.
  - Words attributed correctly on calls with 3+ speakers: 98.5% of 12,115. Bar ≥ 85%.
- **Processing time and memory** (6 speakers, diarization alone):
  - 1 hour: 18.1 s, peak footprint 885 MB, max RSS 568 MB, wired memory +572 MB while the helper ran. It found 6 speakers, with a DER of 7.17%.
  - 2 hours: 31.7 s, peak footprint 1,010 MB, max RSS 841 MB, wired memory +638 MB. It found 7 speakers for 6, with a DER of 7.93%.
  - Bar: at most 2 minutes for 1 hour (passed). The memory is given back when the helper exits.
- **Notes (October 16, 2026):** the user live-tested an Arc call with speakers separated (2.5 s after Stop) and notes from their custom route. The notes had been written in parallel with separation, so they said Them. Notes now wait for separation and use speaker names; renames and merges relabel them (W7b status, "Speaker names"). [Certain]
- **Not verified in the live app:** Them audio deleted at 24 hours, and notes written after separation with names, then relabelled by a rename. [Certain]

W7c and W7d touch different files and can run in parallel after W7a. W7b can run alongside them, coordinating on the meeting record's schema, which W7a owns.

### 11.12 Amendments (applied October 15, 2026)

- **Section 1, line 11:** the "without meeting recording" boundary was already replaced on October 14, 2026. This section is the documented meetings decision that decision asked for.
- **Section 3, 5-minute cap:** it applies to dictation only. Meetings have a 3-hour cap.
- **Section 6, audio:** meeting chunks are transient audio, deleted once transcribed. With speaker separation on, the Them stream may be kept for at most 24 hours until diarization finishes.
- **Section 6, permissions:** adds System Audio Recording, requested at the first meeting only.
- **Section 6, Delete All Data, and R9:** both cover meetings.
- **R6:** while a meeting records, its live view stays visible even when the menu bar and Dock icons are hidden.

### 11.13 Decisions on the open questions (user, October 15, 2026)

The user accepted every recommendation: "I accept all nine W7 recommendations (Q1–Q9)." [Certain]

1. **Q1, what "Them" captures:** the call app when known (detected or picked). "All apps except Murmur" is used only when the user picks it, with a note that it includes music and notifications.
2. **Q2, cloud transcription for meetings:** local only in W7. Meetings hold other people's voices, and Gemini stores audio requests (section 5). Amended the same day by the user: a Cloud choice is allowed, with On this Mac the default (11.14).
3. **Q3, default notes route:** ask at the first meeting's Stop, with None preselected. Apple Intelligence is offered as "on-device, less accurate" until its notes measurement passes. The cloud and custom routes carry their disclosure.
4. **Q4, audio for speaker separation:** keep the Them stream (16 kHz mono) only until diarization finishes after Stop, at most 24 hours. Streaming diarization was declined: its best result in FluidAudio's AMI benchmarks is 20.7% DER (LS-EEND), against 10.6% offline (11.8).
5. **Q5, browser calls:** offer on browser microphone use, worded as microphone use rather than a call. Read no window titles or URLs.
6. **Q6, detection default:** on, since it only offers and runs locally, with a per-app "Never" and a global switch.
7. **Q7, meeting cap:** 3 hours, with a warning at 2 h 50 min, and an automatic stop after 10 minutes of silence on both streams.
8. **Q8, consent reminder:** a one-time acknowledgement sheet, then the "Let others know" line with Copy notice at every meeting, rather than a confirmation dialog each time.
9. **Q9, evidence bars:** the thresholds in 11.10 (echo, notes, diarization) are approved as written.

### 11.14 Decision: meeting transcription route — October 15, 2026

The user amended Q2 and the rule in 11.3 that meeting audio never leaves the Mac: "A toggle option should be there for users so select a local or a cloud model for the meeting dictation as long meetings can increase cost significantly." [Certain]

- **Setting:** Settings → Meetings → Meeting transcription, separate from dictation's route. The options are **On this Mac (Parakeet)**, the default, and **Cloud**, which uses the cloud transcriber configured for dictation (Gemini or Custom Provider) with its existing key. An unconfigured Cloud choice refuses to start a meeting. It never starts on this Mac instead. [Certain]
- **Fixed per meeting:** the route is chosen when a meeting starts. Changing the setting never switches a meeting in progress. [Certain]
- **Disclosure and cost:** under Cloud, Settings shows the route's existing disclosure plus a note:
  - all meeting audio goes to the named host, including other participants' voices;
  - that is up to about 230 MB an hour with both streams, since chunks are 16 kHz mono 16-bit;
  - long meetings can cost significantly.
  No price is quoted, because per-minute prices are not verified for either route; the note says the price depends on the provider. When the transcriber is Gemini, the note says Google stores audio requests (section 5). [Certain]
- **Failure:** a cloud chunk that fails is transcribed on this Mac, and its line is marked "Transcribed on this Mac: the cloud failed". Failures include a rate limit, a network error, or an answer-shaped LLM reply. The meeting stays on the cloud route, so the next chunk tries the cloud again. A local chunk never goes to the cloud. Leftover chunks after a crash are always finished on this Mac. [Certain]
- **Vocabulary:** the same `CloudTranscription.run` path as dictation, so PR #45's rule holds: no dictionary prompt goes to custom transcription. [Certain]
- **Evidence:** `check_meetings.swift` covers the default, persistence, the route fixed at start after the setting changes, the per-chunk fallback and its mark, no local-to-cloud fallback, silence adding no line, and the note's contents. No live cloud meeting has been run. [Certain]

**Sources:**
- Apple, "Capturing system audio with Core Audio taps": https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- `AudioHardwareCreateProcessTap` (macOS 14.2): https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- `CATapDescription`: https://developer.apple.com/documentation/coreaudio/catapdescription
- `NSAudioCaptureUsageDescription` (macOS 14.2): https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
- ScreenCaptureKit overview: https://developer.apple.com/documentation/screencapturekit
- `capturesAudio`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- `captureMicrophone`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone
- `setVoiceProcessingEnabled(_:)`: https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
- TN3193, the on-device model's context window: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Process properties: `CoreAudio.framework/Headers/AudioHardware.h` in the macOS 27 SDK.
- FluidAudio `0b1f462`: `Documentation/Benchmarks.md`, `Documentation/Diarization/GettingStarted.md`, and `Sources/FluidAudio/ModelNames.swift` (`OfflineDiarizer`).
- Diarization models and license: https://huggingface.co/FluidInference/speaker-diarization-coreml (NOTICE.md, LICENSE, file sizes from the API).
