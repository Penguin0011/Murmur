# Murmur security and privacy audit

Audit date: October 5, 2026, America/Los_Angeles. [Certain]

## Remediation — October 5, 2026

The evidence and findings below describe the original audited state; the following changes have since been implemented and checked. [Certain]

| Finding | Current status |
| --- | --- |
| F1 | Fixed: custom keys are bound to the normalized destination; unbound keys and host/scheme/port/path changes require re-entry. Secrets remain in Keychain. Route checks passed (111). [Certain] |
| F2 | Fixed: the shared sensitive-request transport refuses redirects. Loopback 307/308 checks confirmed the destination receives no request. Declared and streamed responses are limited to 8 MiB. [Certain] |
| F3 | Fixed: the confirmed wipe clears paste/setup buffers and destination/provider references, stops observation, discards queued chunks, and removes abandoned chunk audio as well as existing data directories. Isolated native wipe checks passed. [Certain] |
| F4 | Fixed: one-shot helper stdout uses a pipe with a 4 MiB limit; no transcript result file is created. A check drains output larger than pipe capacity and refuses excessive output. The warm reader is bounded too. History-off now discloses retry audio and learned spellings separately. [Certain] |
| F5 | Mitigated: each event checks foreground, Secure Input, and observable field/window identity before decoding; departures end observation. The opt-in readable-field setting disables the heuristic fallback and stops an existing key watch when enabled. Identity/security and settings checks passed. Missing identities still permit the approved same-app heuristic by default, so universal field attribution is not guaranteed. [Certain] |
| F6 | Fixed: startup and purge remove orphan pending writes under the same directory lock used by writers. The native regression confirms cleanup waits for an active writer and preserves committed history. Quarantined files now count toward the cap. [Certain] |
| F7 | Partial: development app and helper builds now have Hardened Runtime; the app has only the audio-input entitlement. A release command requires valid Developer ID signing, timestamps, notarization, stapling, and Gatekeeper assessment. The missing-configuration/identity refusals passed. No valid Developer ID identity is available here; a notarized release remains outstanding. [Certain] |
| F8 | Fixed: Settings and source comments describe cooperative clipboard markers and restoration without overwriting a newer copy. README documents the existing removal control and distinguishes local deletion from provider storage and backups. [Certain] |

Additional checks passed: provider (581), dictionary/learning/retention (172), processing (117), model downloader (158), update (91), launch, app services, native history/controller, BoostFilter, and cleanup corpus/adversarial checks. [Certain] The hardened helper successfully transcribed synthetic speech with a synthetic dictionary while `sandbox-exec` denied networking. This establishes that tested inference can run with networking denied; it does not prove dependencies never attempt network access. [Certain]

The final development build replaced the installed bundle after an idle check and backup. Both signatures passed deep/strict verification; normal launch retained all three permissions. The exact installed binary completed synthetic local transcription and verified insertion into a disposable TextEdit document. Live history filenames, dictionary/ledger metadata, and selected preferences matched the pre-probe snapshot. The current Custom API cleanup choice remains selected, with a visible warning to save its unbound key again; no live call with a newly bound key was made. [Certain]

Remaining validation: a live secure-field/editor matrix, competing clipboard managers, and public-release notarization. Synthetic input and isolated storage were used for regression checks; no live credentials or dictated contents were sent by these checks. [Certain]

## Assessment

The weakest boundary is the configurable API destination: changing the server can send an existing credential to the new server without a credential-specific confirmation. [Certain] I found eight actionable findings: one high priority, six medium priority, and one low priority; the priorities below reflect the consequences and prerequisites, rather than treating every privacy tradeoff as a vulnerability. [Certain]

The observed installation uses local transcription and local cleanup, saves history for 30 days, and enables learning and automatic update checks. [Certain] Those settings avoid the cloud-request findings during ordinary dictation, but the deletion, retention, and learning findings still apply to their respective paths. [Certain]

Recommendation: fix destination binding, deletion, temporary transcript storage, and orphan-file expiry first; keep automatic learning and clipboard delivery, with stronger boundaries and accurate disclosures.

## Scope and evidence

- Reviewed checkout `0490fb2`, including Swift application code, capture/session/helper code, provider clients, settings, learning, local storage, model verification/downloads, updates, and build/signing configuration. [Certain]
- Inspected the installed bundle at `/Users/aakash/Applications/Murmur.app`; its executable SHA-256 is `dfddb3dbe7c4c903399db7e6de799441077d4c222fcf1739864373bbc86f1422`, matching the installation recorded in `HANDOFF.md:7`. [Certain] This establishes consistency with that recorded build, rather than proving a reproducible source-to-binary build. [Certain]
- Deep/strict signature verification passed; the installed signature is `clouddev Development`, with code-signing flags `0x0`, without Hardened Runtime. [Certain]
- Read only selected preferences and filesystem metadata for live app data; observed directories were `0700`, and observed regular history, retry-audio, and dictionary files were `0600`. [Certain] No live transcript contents or Keychain secrets were read for this audit. [Certain]
- Existing checks passed: providers (581 assertions), routes (103), dictionary/learning/retention (170), processing (115), model downloader (158), updates (91), native history, and app services. [Certain]
- Additional synthetic probes reproduced destination-key reuse, cross-host redirects carrying a POST body and Gemini-style header, retained buffers after isolated deletion, acceptance of an unanchored click-based spelling, and orphan transcript files surviving expiry. [Certain] HTTP tests used loopback servers and synthetic credentials/text only. [Certain]
- A pattern scan of current tracked files flagged only explicitly fake credentials in `app/check_providers.swift`; it was not a complete scan of Git history or all possible secret formats. [Certain]
- The application is predominantly Swift; the security skill has no Swift-specific reference guide. [Certain] Apple documentation and primary provider documentation supplemented direct code review. [Certain]

No production application code, installed bundle, live settings, or live user data was changed. [Certain] Live microphone, destination-app interaction, clipboard-manager behavior, outbound traffic during real inference, and the full pinned FluidAudio implementation were not exercised or audited end to end. [Certain]

## Priorities

| ID | Priority | Finding | Friction of proposed fix |
| --- | --- | --- | --- |
| F1 | High | Custom API key survives destination changes. [Certain] | One confirmation or key replacement when changing destinations. |
| F2 | Medium | Built-in cloud clients follow redirects outside their disclosed host. [Certain] | None on normal direct requests. |
| F3 | Medium | Delete All Data leaves separate transcript buffers uncleared. [Certain] | None. |
| F4 | Medium | History-off still permits a transcript temporary file. [Certain] | None with pipe-based helper output. |
| F5 | Medium | Keystroke learning cannot distinguish another field in the same app. [Certain] | Preserve supported learning; disclose uncertain learning and offer a stricter option. |
| F6 | Medium | Abandoned history write files bypass expiry. [Certain] | None for ordinary saves. |
| F7 | Medium, release gate | Installed development build lacks Hardened Runtime. [Certain] | Release signing/setup work. |
| F8 | Low | Clipboard and data-removal descriptions overstate or lag behavior. [Certain] | Copy changes. |

## High priority

### F1 — Bind custom API credentials to their destination

**Evidence:** `app/Credentials.swift:104–107` identifies a credential by provider alone; `app/Routes.swift:226–232` retrieves `.customAPI` for the currently configured URL; `app/Providers.swift:1628–1630` permits that key for any HTTPS destination. [Certain] `app/Controller.swift:1452–1461` also uses the current URL for Validate, including before settings have been applied. [Certain]

**Reproduction:** With a synthetic saved key, changing the base URL from `https://first.example/v1` to `https://second.example/v1` produced a validation request to the second host containing the original bearer key. [Certain] Both cleanup plans had no pending acknowledgement because `app/Routes.swift:249–250` only requires a modal acknowledgement for transcription. [Certain] Cleanup does have an inline disclosure, so this is a missing credential boundary rather than an absence of all disclosure. [Certain]

**Impact:** Changing providers or mistyping a server can expose the first provider's key to the newly selected server. [Likely] Exploitation requires a destination change or altered local configuration; this is not an unauthenticated remote attack against an unchanged installation. [Certain]

**Fix:** Associate the key with the normalized API base URL, and require a replacement key or explicit approval before reusing it for a different destination. Apply the same guard to Validate and cleanup. Keep ordinary dictation free of repeat prompts.

**Acceptance check:** Save a synthetic key for A, select B, and verify neither Validate nor cleanup attaches A's key until B is approved; relaunch and confirm the binding persists.

## Medium priority

### F2 — Refuse redirects for sensitive cloud requests

**Evidence:** `app/Providers.swift:211–218` follows redirects by default; Gemini cleanup, OpenRouter transcription, and Gemini Transcribe use that default at lines 673, 623, and 1191 respectively. [Certain] The custom API client already uses `followRedirects: false` at line 1616. [Certain]

**Reproduction:** A loopback endpoint returned HTTP 307 to a different hostname; the destination received both the synthetic transcript POST body and the synthetic `x-goog-api-key` header. [Certain] Using the existing redirect refuser returned 307 and prevented the second transfer. [Certain]

**Impact:** A redirect response can move sensitive data and a Gemini credential beyond the host named in the disclosure. [Certain] This requires the trusted endpoint or an intermediary capable of supplying an accepted redirect response; no real provider compromise was demonstrated. [Certain]

**Fix:** Make sensitive provider transports refuse redirects using the existing implementation. Treat 3xx as a clear configuration/provider error. Keep model-download redirects separate because those requests carry public model data rather than dictation or provider keys. [Certain]

**Acceptance check:** Test 307/308 with synthetic audio/text and key headers; the second server must receive no request.

### F3 — Clear all application transcript references on deletion

**Evidence:** `app/Controller.swift:1418–1419` clears history/router/processing references and recovery selection, but does not clear `uninserted` or `setupTestTranscript`. [Certain] `uninserted` remains the source for the global paste action at lines 1012–1018. [Certain]

**Reproduction:** An isolated preview controller retained both synthetic buffers after a successful deletion. [Certain] The fixture compiled a copy of the controller with only the confirmation dialog bypassed and synthetic-buffer access added; it used temporary storage and skipped Keychain deletion. [Certain]

**Impact:** A successful Delete All Data action can leave the previous uninserted dictation available to the paste shortcut, and can leave a setup transcript in the controller. [Certain] No paste was injected, and the destructive action was not executed against live user data. [Certain]

**Fix:** Clear the paste-recovery buffer, setup transcript, and other application-owned transcript references during the same deletion action. Stop outstanding observation/helper work before clearing it. Treat an explicit user Copy action separately; do not indiscriminately overwrite someone else's clipboard.

**Acceptance check:** In isolated storage, seed synthetic paste/setup text, delete data, and verify the paste shortcut has no retained text and the setup transcript is empty.

### F4 — Make history-off avoid transcript files in the helper fallback

**Evidence:** The disclosure at `app/Retention.swift:151` says history-off does not save transcripts to disk. [Certain] `HistoryRouter` honors that for history entries, but `app/Controller.swift:850–868` always routes the one-shot transcription helper's stdout into `.result-<UUID>` under retry audio. [Certain] Helper stdout contains the transcript (`module-one/models/Runner/Sources/ModelBench/ModelBench.swift:35–46`). [Certain]

**Impact:** If the warm helper is unavailable or fails, a transcript is written to disk even with history off; a crash can leave it until startup cleanup at `app/Controller.swift:445–448`. [Certain] The file is private (`0600`), which reduces exposure to other users but does not make the disclosure accurate. [Certain]

**Fix:** Capture the one-shot helper's output through a pipe with a bounded reader, reusing the approach already used for the warm helper. Keep audio-retry policy separate and disclose that turning transcript history off does not disable retry audio or learned vocabulary. [Certain]

**Acceptance check:** Force the one-shot path with history off and a synthetic helper; verify no transcript-bearing file is created, including when the helper or app fails.

### F5 — Tighten the scope of keystroke learning

**Evidence:** `app/Controller.swift:1253–1257` accepts keyboard/mouse events before checking the foreground app or secure-input state. [Certain] The polling path at lines 1183–1187 checks process identity and Secure Event Input, but carries no field identity for keystroke observation. [Certain] `spike/Observation.swift:197–203` guesses caret and word selections after a click. [Certain]

**Reproduction:** The pure keystroke tracker accepted a click followed by synthetic `Akme` typing as a replacement for `Acme`, and the ledger promoted it to a learned spelling after settlement. [Certain] This demonstrates the mechanism's lack of destination evidence; it was not a live browser/password test. [Certain]

**Impact:** Typing a plausible name in another field of the same application can be misattributed to the prior dictation and persisted as vocabulary. [Likely] Enabled vocabulary can subsequently reach a selected cloud transcription route through `app/Controller.swift:901–902`. [Certain]

The PRD explicitly approves keystroke-based and click-based learning in unreadable editors; that convenience decision is preserved in this recommendation. [Certain] A plausible spelling proves linguistic similarity, not that the edit occurred in the dictated field. [Certain]

**Fix:** Check foreground identity and Secure Event Input before decoding each event; stop on any observable field/window departure. Retain anchored AX learning. For editors whose field identity cannot be established, disclose the same-app assumption and offer a stricter privacy setting that skips uncertain click-based learning. Do not promise that heuristic filtering guarantees field attribution.

**Acceptance check:** Exercise correction versus same-app field/tab changes, rapid app switches, and secure-input transitions; unrelated text must not enter the ledger or vocabulary. Document which editors cannot provide that guarantee.

### F6 — Remove abandoned atomic-write transcript files

**Evidence:** `app/History.swift:28–35` writes complete transcript JSON to a `.pending-<UUID>` file before renaming it. [Certain] Ordinary errors run deferred cleanup, but process termination can interrupt that cleanup. [Likely] History enumeration, quarantine, and expiry only consider `.json` entries and quarantined files (`app/History.swift:41–60, 76–98`), so pending files bypass those paths. [Certain]

**Reproduction:** A synthetic `.pending-*` transcript with a modification time 40 days ago survived quarantine and a 30-day purge. [Certain]

**Impact:** Crash debris can retain transcript contents past the selected lifetime without appearing in History. [Certain]

**Fix:** On startup, before accepting new saves, remove abandoned pending files; also account for them in expiry and storage housekeeping. Define a safe policy for simultaneous app instances before deleting files another instance could still be writing.

**Acceptance check:** Seed an orphan pending transcript, restart storage initialization, and verify it is removed; preserve successfully committed recovery history.

### F7 — Enable release protections before wider distribution

**Evidence:** The installed signature lacks the runtime flag, and `app/build.sh:32–33` signs without `--options runtime` or a secure timestamp. [Certain] The current bundle is a development build, consistent with the project's documented pre-release state. [Certain]

**Impact:** This build lacks Hardened Runtime protections appropriate for distributing an application with microphone, Accessibility, and Input Monitoring access. [Certain] This is a release gate, rather than evidence that the development installation has been compromised. [Certain]

**Fix:** Add a release signing path for both app and helper with Developer ID, Hardened Runtime, the minimal necessary entitlements, and a secure timestamp; notarize and staple the release. Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) require those signing/runtime protections. [Certain] Keep the lightweight development build available.

**Acceptance check:** Verify signatures/runtime flags and notarization, then test capture, helper launch, insertion, and learning under the resulting release entitlements.

## Low priority

### F8 — Replace privacy guarantees with accurate descriptions

**Evidence:** `spike/Insertion.swift:172–177` describes transient markers as ensuring pasted dictation never enters clipboard history. [Certain] The [NSPasteboard marker specification](https://nspasteboard.org/) asks clipboard managers to honor these markers; they are a cooperative convention. [Certain] The implementation also deliberately skips clipboard restoration when ownership has changed, while `app/UI.swift:394` says the clipboard is always restored. [Certain] `README.md:43` says Delete All Data is planned even though the action is implemented. [Certain]

**Impact:** Users can overestimate what Murmur guarantees against another application or misunderstand which removal controls are available. [Likely]

**Fix:** Say automatic paste is marked transient and normally restores the previous clipboard, without overwriting a newer copy. State that other software may still read or retain clipboard data. Update removal instructions to the implemented control and distinguish local deletion from cloud-provider storage and backups.

**Acceptance check:** Compare the Settings text and README against both normal paste and a competing clipboard writer; review Copy Raw/Copy as explicit user exports.

## Privacy choices worth keeping

- Local transcription and local cleanup are the source defaults as well as the observed live choices; automatic update requests are a separate feature. [Certain] Keep this default and the update toggle.
- Keychain storage, redacted credential representations, content-free provider error messages, private storage permissions, and model checksum pins are present in the reviewed implementation. [Certain] Keep these controls; they do not replace the destination binding in F1. [Certain]
- Thirty-day history supports recovery, and a separate history-off mode already exists. [Certain] Keep both, after addressing F3, F4, and F6; a mandatory extra passphrase for every dictation would add disproportionate friction for the current local desktop scope. [Likely]
- Gemini Transcribe's stored interactions and clipboard-only insertion are recorded user decisions in the PRD. [Certain] Do not silently change them. Google distinguishes paid and unpaid API data use; unpaid services can involve product improvement and human review, with regional exceptions in the [official terms](https://ai.google.dev/gemini-api/terms). [Certain] Keep that disclosure visible and make clear that deleting local data does not itself call the provider's interaction-deletion API (`app/Retention.swift:184–198`). [Certain]
- Non-loopback HTTP custom endpoints already show an unencrypted-transcript warning and omit the saved API key; loopback HTTP is supported. [Certain] Retain loopback convenience; consider a one-time explicit acknowledgement for off-device plain HTTP rather than a blanket ban on local model servers.
- Automatic insertion intentionally uses the current cursor at completion (`app/Controller.swift:977–978`). [Certain] An optional setting to save instead when the foreground app changed would reduce accidental delivery, but the current behavior is a documented convenience choice. [Likely]

## Remaining validation and optional hardening

1. Test the secure-input boundary across readable and unreadable fields before recording and upload; current fast prestart checks microphone permission, while full start checks AX secure metadata (`app/Controller.swift:201–207, 688–701`). [Certain] The generic paste path checks Secure Event Input (`spike/Insertion.swift:222–233`), but a live password-field matrix remains unverified in this audit. [Certain]
2. Verify actual local-mode network behavior with the pinned FluidAudio runtime and synthetic inference; explicit local model paths alone do not establish a complete no-network guarantee for dependencies. [Certain]
3. Bound HTTP response bytes in `URLSessionTransport.send` (`app/Providers.swift:225–233`); it currently accumulates the entire response. [Certain] A faulty or hostile custom backend could cause memory pressure or terminate the app. [Likely]
4. Include `history/unreadable` in the storage-cap calculation; `HistoryCap.usage` only counts regular files directly inside history (`app/Retention.swift:71–81`). [Certain] Quarantine expiry is implemented, so this is an incomplete size-cap calculation rather than unlimited ordinary transcript retention. [Certain]

## Reproduction artifacts

Additional probes remain under ignored `runtime/security-audit/`: `probe.swift`, `redirect_probe.py`, and the isolated deletion fixture `wipe_probe.swift` with its instrumented `Controller.swift` copy. [Certain] They use synthetic data and temporary storage, and do not request microphone permission or inject input. [Certain] These artifacts are local evidence and are not included in the report commit. [Certain]

Run from the repository root:

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift \
  app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift \
  spike/Observation.swift spike/Shortcut.swift module-one/capture/Capture.swift \
  module-one/session/Session.swift app/History.swift runtime/security-audit/probe.swift \
  -o runtime/security-audit/probe
python3 runtime/security-audit/redirect_probe.py
```

Expected observations: endpoint-key reuse, unanchored spelling acceptance, pending-file retention, followed redirect, and refused redirect. [Certain] The learning probe supplies a synthetic lexicon; it establishes missing field attribution, rather than measuring real spell-checker false-positive rates. [Certain]
