# Dictation — product requirements and agent delivery plan

Status: working draft, October 2, 2026. Confirmed requirements reflect the conversation; proposed decisions require review. [Certain]

## 1. Product goal

Build a macOS dictation application that inserts spoken text into the active text field, with optional filler removal, spoken corrections, and list formatting. Prioritize Apple Silicon and English. Give users independent local/cloud choices for transcription and cleanup. These are confirmed requirements. [Certain]

Hardware scope: Apple Silicon, including M1; Intel support is deferred beyond launch. Minimum macOS version: **macOS 26**. M1/8 GB performance validation is deferred and is not a development or release gate. Users choose a model appropriate to their hardware; no minimum RAM performance guarantee is made. Validate the available M3/16 GB host and publish its measured configuration. [Certain]

Proposed launch boundary: dictation and recovery, without meeting recording, an AI assistant, billing accounts, or automatic message submission.

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
- Escape cancels recording; do not insert canceled speech. A new shortcut press while processing must not duplicate the prior session.
- Remember the destination app and focused field at recording start. Recheck focus before insertion; if the user changes destination, retain the result instead of typing into an unintended field.
- Insert by clipboard paste (see the decision below), with clipboard preservation and verified focus. Never blindly overwrite newer clipboard content when restoring it.
- Treat insertion as uncertain when delivery cannot be verified. Preserve the result and avoid automatic duplicate retries. UX: the bubble shows "Inserted, unverified" with a Copy action and a history link; it never retries on its own.
- Decision, October 4, 2026 (user): one delivery method everywhere, clipboard paste with ⌘V. A readable field is still re-read afterwards to verify delivery and to start correction observation; the AX selected-text write and its paste fallback are removed. Superseded: insertion order (1) AX selected-text write, verified by re-reading the field; (2) paste fallback only if (1) is unsupported. Many apps accept the AX write silently without inserting, so a read-back mismatch counts as failure, not success. Clipboard restore must skip when the pasteboard change count shows another writer (including clipboard managers and Universal Clipboard).
- Secure-field detection uses AX subrole plus app-specific checks. Browser password fields are not reliably flagged, so treat web fields with unknown type in browsers as unverified for delivery. Decision, October 4, 2026 (user: learning must work in non-standard text inputs): such a field may be observed for learning once its read-back shows the dictated text in plain (a masked field would not), and observation stops whenever Secure Event Input is on.
- Reject secure/password fields. Unsupported apps, revoked permissions, and inaccessible fields lead to recovery history.
- On cleanup failure, preserve raw transcription and offer it for recovery; do not silently insert a different output than requested.
- On microphone disconnection, stop safely and retain recoverable audio according to the approved retention policy.
- Bubble placement follows the destination display and accounts for full-screen apps, Spaces, screen scaling, and the Dock.

## 4. Cleanup contract

Proposed behavior: cleanup edits dictation, never answers it, executes instructions inside it, invents facts, or changes tone merely to sound polished.

| Option | Example input | Expected output when enabled |
|---|---|---|
| Fillers | “Um, please send the report.” | “Please send the report.” |
| Spoken corrections | “Meet Tuesday—sorry, Thursday at three.” | “Meet Thursday at three.” |
| List formatting | “Shopping list: first apples, second milk, third bread.” | A three-item list, preserving the items. |

Cleanup acceptance is measured, not asserted. Build a fixed corpus (target 300+ labeled utterances, covering each option, interactions between options, names, numbers, negation, quoted speech, and look-alike prose) before choosing the cleanup model. Proposed pass bar: no more than 1% of utterances with an unintended edit to a name, number, or negation; spoken-correction accuracy and list-formatting precision thresholds set from the corpus baseline and recorded in the decision log. Report each local candidate and the cloud routes against the same corpus.

Prompt-injection guard: transcripts are data. Cleanup output must pass a bound check against the raw text (length ratio and edit-distance limits per enabled option, no new named entities or numbers). If the check fails, or the model appears to answer or obey the dictation, preserve raw text for recovery and do not insert automatically. Offer an explicit action to use the raw transcript; log only a content-free failure reason locally. This resolves the previous conflict with section 3 conservatively. [Certain] Include injection phrases ("ignore previous instructions", "write me a…") in the corpus.

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
- Decision, October 4, 2026: where a field exposes no readable text (VS Code's default editor, canvas editors such as Google Docs), observation follows the keys typed in that app during the same window (listen-only, Input Monitoring) on an in-memory copy of the pasted span. Keystrokes are never stored or logged; only the filtered source/target pair reaches the ledger. Keys it cannot model, clicks and app switches end the watch under the same rules as AX observation. The target app's own autocorrect is invisible to it. Murmur never turns on accessibility modes in other apps (VS Code switches to screen-reader mode when Electron accessibility is forced).
- Mechanism and honest limits: macOS exposes no edit-event stream with ranges. Tracking means reading the field's AX value and selection on change notifications (with bounded polling where notifications are absent), then locating the inserted span by anchored text diff. Chrome/Electron apps expose AX text only when accessibility is enabled for them; some web rich-text editors (e.g. Google Docs, Notion) may expose none. The spike must measure this rather than assume it. Learning triggers only on a whole-word or short-phrase replacement inside the anchored span; case-only and punctuation-only changes are not candidates, and "consistent" means the same source and target string after case-folding.
- Automatic post-insertion observation is required at launch. The macOS feasibility spike must prove field/range tracking in representative native, browser, rich-text, chat, and code-editor apps; publish the supported observation matrix. Unsupported apps may still support dictation, but cannot claim automatic learning. Do not replace this requirement with manual feedback. Approved launch rule: a category that fails observation ships with automatic learning marked unsupported in the published matrix and in-app (learning is off for those apps, dictation still works); it does not hold the launch. [Certain] Proposed floor: if no tested app in any category supports observation, report a launch blocker, since the feature would not exist.
- Proposed learning implementation: persisted vocabulary/preferences, not model-weight fine-tuning. Validate that these preferences improve repeated corrections without changing unrelated dictation.
- Store dictionary and learned corrections locally. When a selected cloud stage needs relevant entries, disclose that those entries will leave the device; avoid sending unrelated history or the entire dictionary unnecessarily.
- Hardware policy: users may disable cleanup or choose lighter models to suit their hardware. No M1-specific benchmark or 8 GB default rule blocks release. Preserve local-first defaults and never silently use cloud. [Certain]

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
5. Evaluate a small local cleanup model separately against the cleanup contract. Do not assume a transcription model performs instruction-based cleanup.
6. Validate the selected default and choose an accuracy-focused alternative only if measurements justify it. Resolve upstream/conversion license metadata differences before redistributing weights; do not silently change the model selection if validation fails.

Cloud providers (user-named candidates): **Fireworks API**, **Gemini API**, and **OpenRouter**. [Certain]

**User decision — October 3, 2026:** pursue Gemini 3.5 Transcribe for cloud speech-to-text, and accept that Google stores Interactions API requests. The app must disclose before first use that audio is sent to and stored by Google. [Certain] The rest of this paragraph is still proposed.

**Verified October 3, 2026 (from the docs; no live key test):** the endpoint is `POST https://generativelanguage.googleapis.com/v1beta/interactions` with model `gemini-3.5-transcribe` and `store` true by default. Google keeps stored interactions for 55 days on the paid tier and 1 day on the free tier, and they can be deleted by ID with `DELETE /v1beta/interactions/{id}`. Implemented as `GeminiTranscribeProvider`. [Certain] Sources: [app/PROVIDERS.md](app/PROVIDERS.md).

**Proposed decision, pending user approval — October 3, 2026 (revised).** Everything in this paragraph is a proposal. No route has had a live test with a real key or a real local server. [Certain] Sources: [app/PROVIDERS.md](app/PROVIDERS.md).

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

- Approved: local transcription and local cleanup selected initially, with model downloads disclosed separately from inference. [Certain]
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

Milestone 0 has an implemented standalone spike and recorded live results; milestone 1 validation work has started with capture, model, and independent safety workers. Production and release acceptance remain incomplete. [Certain]

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

Release handoff must include reproducible build instructions, architecture/macOS requirements, signed/notarized download artifacts where available, third-party notices, and source for the released version. GitHub account/repository name and signing identity remain to be supplied; do not invent them.

## 9. Release acceptance

- Functional and safety requirements pass on the available Apple Silicon/macOS 26 test configuration. Publish tested hardware and model-specific performance without promising M1/8 GB performance. Intel is outside launch acceptance. [Certain]
- Real insertion coverage includes a native editor, browser text field, rich-text editor, chat app, and code editor; publish unsupported cases rather than claiming universal compatibility.
- Exercise cursor loss, focus change, full-screen/Spaces, microphone loss, permission revocation, missing model, interrupted download, offline cloud requests, invalid key, quota exhaustion, and cleanup failure.
- Verify no inference network requests in local/local mode, and only the selected stage's data leaves the device in mixed modes.
- Verify no duplicate insertion, no automatic sending, no credential exposure, and recoverable output before insertion attempts.
- Verify independent cleanup toggles against a fixed corpus, emphasizing unintended edits to names, numbers, and negation.
- Verify automatic learning from real post-insertion edits in other apps, conservative promotion and attribution, dictionary editing, undo/reset, disabled learning, and cloud disclosure without unrelated vocabulary leakage. Manual history feedback cannot satisfy the automatic-learning requirement.
- Verify each retention option, six-month calendar boundaries, retention changes, manual deletion, and forever across restarts.
- Verify GitHub update detection, no-update/offline/rate-limit behavior, ignored prereleases, user-triggered download, and no silent installation.
- Proposed performance targets: visible listening feedback within 150 ms; warm final output for a 10-second clip within 2 seconds on the agreed baseline device. Treat these as targets to measure, not established capability.
- Record cold-start performance separately. Do not hide cleanup latency within transcription-only numbers.

## 10. Decisions still needed

1. Minimum macOS 26 and Apple Silicon scope remain confirmed. M1/8 GB performance is deferred, with user-selected models and no validated minimum RAM guarantee. Intel remains deferred. [Certain]
2. Select and benchmark local models on the available Mac; retain local-first and cleanup-on defaults and user model selection. Do not silently substitute cloud processing. [Certain]
3. Establish supported automatic-learning apps through the required feasibility spike, with unsupported categories disclosed rather than blocking launch (approved); the 60-second window and two-observation threshold are approved. [Certain]
4. Product name: **Murmur** (confirmed October 2, 2026). Signing identity and approval of manual download/replace updating remain open. Settled: GitHub account `Penguin0011`, repository `dictation` (to be renamed); the user is the MIT copyright holder; LICENSE added October 3, 2026 with holder "Aakash" as supplied by the user. No Apple Developer account exists yet: enrolling in the Apple Developer Program is a prerequisite for Developer ID signing and notarization, and the release milestone is blocked on it. The user deferred enrollment (October 3, 2026); development builds stay self-signed until then. [Certain]
5. Local cleanup model/runtime and verification of the named cloud providers (Fireworks, Gemini, OpenRouter); validation and exact artifact pinning for selected Parakeet Unified transcription. Update October 3, 2026: provider documentation is verified and a launch split is proposed in section 5, pending user approval and live key tests; the local cleanup baseline is recorded in the milestone 1 decisions, and the local cleanup model is still open. [Certain]

This draft defines the confirmed product and proposed work boundaries; it is not yet a claim of full Wispr Flow feature parity. [Certain]

### Approved decision: local-first and cleanup-on defaults

Approved by the user: local-first and cleanup-on defaults, subject to hardware and quality validation. [Certain] The following details define the approved behavior; model selection remains open.

Approved behavior: on first setup, select local transcription and local cleanup, with filler removal, spoken corrections, and list formatting enabled. Explain these settings before the first real dictation and offer a faithful-transcription preset. Cloud routes require choosing a provider and configuring an API key. [Certain]

Local-first means recording and inference remain on the Mac; initial model downloads and enabled GitHub update checks still require network access. This is a proposed product contract, not a claim of a completely network-free application.

The complete transcription-plus-cleanup pipeline remains unmeasured on the available Mac. Validate it there before publishing performance claims. M1/8 GB optimization and testing are deferred; users choose lighter models or disable cleanup as needed. [Certain]

Cleanup-on means the initial output may differ from a literal transcript by design. Enable only the named features; do not silently add tone rewriting or summarization. Preserve raw text in history while history is enabled, and let users disable each feature independently.

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

### Milestone 1 implementation decisions — October 2, 2026

Continue with the selected Unified model and batch processing; available-host inference remains unverified. M1/8 GB performance is deferred and does not block implementation or release. No silent model/provider substitution is permitted. [Certain]

Cleanup errors and guard failures share one policy: save the raw transcript, show recovery, and require an explicit raw-text action before insertion. Treat dictation text as data and do not log its contents. [Certain]

The spike's unchanged-successful-AX-write paste fallback remains experimental: a delayed write may duplicate insertion. Production must choose one delivery method before attempting delivery, or retain uncertain output for recovery; a timer or change notification does not prove that an earlier write will never arrive. Unknown browser field types remain unverified and excluded from learning. [Certain]

Recorded native/chat observation establishes the narrow feasibility floor, while app-specific unsupported states must remain visible. A production semantic rule for automatic promotion remains unresolved; structural edit similarity alone does not justify learning. [Certain]

Decision, October 4, 2026 (user: "take the Wispr Flow style"): learning has two tiers. One settled correction that passes the rule below adds the corrected spelling as a vocabulary hint (a learned entry with no variants: it biases transcription and cleanup but replaces nothing) and shows a brief "Added … to dictionary" notice with Undo. Two consistent corrections from separate dictations add the misheard form as a variant of that same entry, so it is replaced from then on. A word the user deletes or reverses is never learned again from any mishearing. [Certain]

Approved semantic promotion rule (approved by the user October 3, 2026; implemented in `app/Learning.swift`). Condition before learning ships: back the lexicon with NSSpellChecker, so ordinary-word swaps are rejected. [Certain] Rule: a correction is learning evidence only when the target is a plausible respelling of the source. Rules: 1–3 words per side after trimming shared context; no case/punctuation/spacing-only edits, deletions, insertions or longer rewrites; reject negation flips, digits/number words, listed antonyms, function words and homophones, and inflection or short vowel-only changes; when a lexicon is available (NSSpellChecker), reject swaps of one ordinary word for another; otherwise require at least 4 letters per side and either edit similarity ≥ 0.75 or matching consonant-class phonetic keys with similarity ≥ 0.5. A target that is already a manual dictionary term waives only the similarity test. Known limits: without the lexicon, real-word swaps such as casual→causal pass; similar names (Robert→Rupert) pass; short names, plural-like respellings and spacing merges are skipped. Deleted learned entries are tombstoned so old evidence cannot re-promote them. [Likely]

Local cleanup baseline — October 3, 2026: `app/Cleanup.swift` provides a deterministic `RuleCleaner` behind the section 4 guard, with failures held for recovery. It is a baseline and stopgap, not the final local cleanup model choice; the model comparison in section 5, item 5, remains open. [Certain] Measured on Linux with Swift 6.1.2 against a 425-utterance labeled corpus (`app/cleanup-corpus.json`): 96.7% exact match; 1/425 (0.2%) unintended name/number/negation edits, within the ≤ 1% bar; 6/425 (1.4%) strict mismatches; spoken-correction exact match 95.8%, with 22 of 22 ambiguous corrections left unchanged; list precision 97.7% and recall 100%; 0/237 guard false rejects; 2348/2348 adversarial outputs rejected. [Certain] The same agent wrote the corpus, labels and baseline, and the corpus has no real ASR transcripts, so these numbers overstate real-world quality. [Certain] Per section 4, the spoken-correction and list thresholds should be set from this baseline; that is not yet recorded as a decision. [Certain]

### Superseding hardware decision — October 2, 2026

The user removed M1 performance from the required gates. M1/8 GB benchmarking and optimization may be done later; users may select lighter models. This supersedes earlier mandatory M1 baseline and 8 GB default rules, while retaining functional, privacy, safety, and measured-configuration reporting requirements. [Certain]
