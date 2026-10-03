# Milestone 0 feasibility report

Decision, updated October 2, 2026: **GO for milestone 1 validation work; NO-GO for production readiness or release**. Recorded live evidence establishes Right Option tap/hold and attributable observation in TextEdit and the Codex composer; it permits continued engineering, not a claim of complete acceptance. [Certain]

The weakest unresolved gate is safe, recoverable end-to-end delivery on the available Mac. M1/8 GB performance is deferred by user decision and is not a development or release blocker. Microphone first-word capture, permission revocation, clipboard-manager races, delayed AX-write duplicate delivery, and semantic eligibility for learned replacements also remain unproved. [Certain]

The five categories have recorded outcomes below. Native and chat have partial acceptance with passing live observation cases; the tested browser field and default VS Code configuration do not support learning; default Safari + Google Docs has no usable AX destination. These limits do not defeat the approved at-least-one-category observation floor, but they require published support limits. [Certain]

Current-run verification: the integrated Swift build, deterministic checks, and ten CLI rejection cases passed on this host. Read-only focus inspection exposed a Codex AXTextArea; it did not repeat the historical insertion/observation tests. Earlier live results below are retained as recorded evidence, not presented as freshly rerun tests. [Certain]

Integrated build and `--check` passed on this host. Checks cover tap/hold, repeat/cancel/processing behavior, event-stream loss, UTF16 insertion bounds including emoji surrogate boundaries, read-back mismatch/focus/browser exclusions, observation attribution, undo, expiry, and conflicting two-session evidence. [Certain]

The initial read-only `--inspect --delay 0` probe exited with `No accessible focused field`. The harness now falls back to the actual foreground application's focused AX element, with PID and foreground rechecks. Background TextEdit UI focus did not make TextEdit the macOS foreground app; the user brought the synthetic document forward for the successful tests below. [Certain]

`--listen --listen-seconds 2` created a real CGEventTap with both permission preflights true and exited cleanly after two seconds. This proves listener startup/teardown, not physical shortcut semantics or microphone capture. [Certain]

The user then exercised Right Option physically. An initial unlabeled trace established start/finish and Escape cancellation but lacked a distinct hold cycle. A labeled 45-second retest established both hold-release finishing and tap-stop finishing, with processing returning to idle between sessions: [Certain]

```text
shortcut action=start state=listening
shortcut gesture=hold-release
shortcut action=finish state=processing
shortcut state=idle
shortcut action=start state=listening
shortcut gesture=tap-stop
shortcut action=finish state=processing
shortcut state=idle
```

Right Option tap/hold and Escape cancellation therefore have live keyboard evidence on this device. Fn, configured-chord conflicts, microphone first-word capture, and the M1 baseline remain unverified. Key-repeat and processing suppression remain deterministic-check evidence. [Certain]

## Milestone 1 continuation checkpoint

Standalone capture now builds and passes synthetic WAV roundtrip, restrictive file/directory permissions, original-creation 24-hour expiry, and synthetic canceled-file deletion checks. The current execution context reports microphone authorization, but no speech recording or physical shortcut/audio integration has been tested. A fresh bounded two-second CGEventTap startup/teardown passed with Accessibility and Input Monitoring granted. [Certain]

Model work lives in `module-one/models/`; capture work lives in `module-one/capture/`. The independent review in `module-one/SAFETY_REVIEW.md` identifies delayed AX-write duplicate delivery, non-atomic clipboard/focus races, incomplete secure-field coverage, and unresolved semantic correction promotion as production acceptance gaps. [Certain]

## Device and tools

October 2, 2026: MacBook Air Mac15,12, Apple M3, 16 GB RAM, macOS 26.6.2 (25G83), Swift 6.3.3. Accessibility and Input Monitoring preflight returned true for the execution context. The M1/8 GB baseline is unavailable in this run. [Certain]

## Shortcut contract

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> listening: press / start
    listening --> listening: release before 250ms / tap
    listening --> processing: release at or after 250ms / finish
    listening --> processing: next press / finish
    listening --> idle: Escape / cancel
    processing --> idle: explicit processing completion
```

Repeated down events do not create sessions. A release belonging to the tap that stopped recording cannot finish another session. Processing blocks additional starts. The listener emits actions rather than recording audio; first-word capture and microphone performance remain untested. [Certain]

## Application observation matrix

| Category | Intended test target | Insertion | Observation | Evidence |
|---|---|---|---|---|
| Native editor | TextEdit 1.20 | Verified AX write | Pass for live-testable cases | Replacement, Undo, appended text, cursor outside span, focus departure, 60-second expiry, consecutive dictations; permission revocation and clipboard fallback pending |
| Browser text field | Arc 1.166.0, local textarea | Delivered once via paste fallback (screen-confirmed); harness-unverified by design | Ineligible (unknown browser field type) | AX write alone silently drops text; field exposed as AXTextArea this session |
| Rich text | Safari 26.6.2, synthetic Google Doc | Default: no field exposed. With Docs screen reader support: AX write delivered (user-observed), harness-unverified | Ineligible (browser field type unknown) | Requires a user-enabled Docs setting; product requirement says this must not be needed |
| Chat composer | ChatGPT/Codex desktop 26.928.40906 (`com.openai.codex`), new unsent chat | Verified via paste fallback after unchanged AX write | Pass for live-testable cases | Replacement, Undo, append, focus departure, consecutive dictations; AX write alone silently drops text |
| Code editor | VS Code 1.140.0, throwaway `code-probe.txt`, default settings (no screen reader mode) | Delivered once via paste fallback (screen-confirmed); harness-unverified | Not possible: AX value is an empty stub | AX write silently dropped; editor buffer not exposed to AX |

The matrix records tested configurations only. Browser and code learning are unsupported under the tested default configurations; native/chat permission-revocation acceptance remains pending. Untested app variants remain unverified. [Certain]

## Native synthetic test evidence

TextEdit 1.20, default rich-text Untitled document, initial text `Native probe: `. The harness inserted `Acme dictation probe` and verified the full AX value. The native UI independently showed `Native probe: Acme dictation probe`. [Certain]

An initial observation attempt exposed the incorrect assumption that AX insertion advances the caret. Tracking now uses the pre-insertion selection offset and verified output. After resetting only the synthetic content, the next live run produced: [Certain]

```text
app=com.apple.TextEdit role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=true
insertion=verified detail=AX selected-text write matched full-field readback
Observing the synthetic span for at most 60 seconds; text is never printed.
provisionalCandidate=true; no dictionary mapping applied
provisionalCandidate=false; no dictionary mapping applied
observationStopped=selection left dictated span candidateRetained=false
```

The UI actions replaced `Acme` with `Akme`, then Undo restored `Acme`, then moved the caret before `Native`. The later automated run below covers focus departure, expiry, appended text, and consecutive dictations; repeated-session learning, permission revocation, and clipboard fallback remain pending live tests. The structural tracker and evidence ledger cover those branches with deterministic checks, but production semantic eligibility remains unresolved and mappings are not applied. [Certain]

### Automated native run (October 2, 2026)

Claude drove a fresh TextEdit 1.20 Untitled document (`Native probe: `) from this session: harness outside the command sandbox (inside it, Accessibility preflight fails), TextEdit activated via AppleScript, edits sent as System Events keystrokes while TextEdit was frontmost. Synthetic text only. [Certain]

| Scenario | Actions | Result |
|---|---|---|
| A | Replace `Acme`→`Akme`, Undo, append ` appended` | `provisionalCandidate=true`, then `false` after Undo, then `observationStopped=appended text candidateRetained=false` |
| A (first try) | Caret jumped to document start before editing | `observationStopped=selection left dictated span` (selection outside span) |
| B | Replace, then activate Finder | `observationStopped=focus departed candidateRetained=true` (after fixes below) |
| Expiry | Insert, no edits | `observationStopped=window ended` about 60 s after start |
| D | Two dictations, space between, replace in second span | Both verified; candidate attributed to the second span; `window ended candidateRetained=true` |
| Foreground guard | Claude desktop took focus before an insert | `Foreground app differs from --expected-app; no insertion attempted` |

Two harness bugs found and fixed in this run (deterministic checks and CLI checks still pass): [Certain]

1. `NSWorkspace.frontmostApplication` is refreshed only when the run loop delivers workspace notifications. The observer polls with `Thread.sleep`, so it kept seeing TextEdit after Finder came forward and observed for the full 60 seconds. `captureFocus` now drains the run loop before reading the frontmost app.
2. The observe loop derived "readable" from whichever field now had focus, so departing to Finder's unreadable `AXGroup` was misreported as `access or security lost` and discarded a valid candidate. Readability now applies to the dictated field; leaving it is a focus departure, and lost Accessibility permission still stops as access lost.

Product findings: [Certain]

- Consecutive dictations at the same caret are glued (`probeAcme`). The tracker correctly refuses spans that cut a word, so the product needs automatic inter-dictation spacing or observation is lost for the second dictation.
- In this run the AX write advanced the caret (14→34), so the second dictation landed after the first. The earlier non-advancing observation may vary by state; anchoring on the pre-insertion offset remains correct either way.

Still pending: permission revocation mid-observation (a security-settings change the user must perform), clipboard fallback (TextEdit accepts AX writes, so the paste path does not trigger), clipboard-manager races, and repeated-session learning (the spike has no persisted ledger; deterministic checks only). [Certain]

## Browser synthetic test evidence

Arc 1.166.0 (`company.thebrowser.Browser`), local `fields.html` textarea. The user foregrounded the browser and focused Plain text. Native capture exposed `AXWebArea` rather than the textarea. An AX selected-text write returned success, but full-field read-back did not establish delivery; the browser UI independently showed the original `Browser probe: ` value. The harness classified delivery as unverified, did not paste/retry, and did not start learning. [Certain]

```text
app=company.thebrowser.Browser role=AXWebArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=false
insertion=unverified detail=AX selected-text write delivery unverified; retain output, never automatically retry
```

Reading the foreground app's AXRole did not resolve the field exposure in a subsequent probe; that unsuccessful extra read was removed from the harness. Chromium's main source describes native accessibility activation on this role read and enhanced screen-reader mode through `AXEnhancedUserInterface`, with a two-second debounce. Electron separately documents `AXManualAccessibility`. These describe upstream mechanisms, not verified Arc 1.166.0 behavior. No enhanced accessibility setting was changed in this run. [Certain] ([Chromium source](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm), [Electron documentation](https://github.com/electron/electron/blob/main/docs/tutorial/accessibility.md))

This result is limited to the tested Arc setup. It does not establish Chrome, Safari, password-field detection, or rich-editor compatibility. Unknown browser field types remain excluded from learning. Further browser accessibility setup and field-specific native focus are required before calling this route supported. [Certain]

The final harness also rejects AXWebArea/document roles before insertion and learning. Consequently this Arc setup now reports an unsupported text destination without attempting a write; the earlier silent-success trace remains useful evidence for why read-back verification is required. [Certain]

## Chat-composer synthetic test evidence

ChatGPT/Codex desktop 26.928.40906 (`com.openai.codex`), a new empty chat opened from File → New Chat; the existing agent session was not touched. Claude drove it from this session; the draft was seeded with `Chat probe: `, Return was never pressed, nothing was sent, and the draft was cleared afterwards. The Claude desktop composer was not used because this session runs in it. [Certain]

The composer exposes a readable, nonsecure `AXTextArea` with a readable selection, so it is learning-eligible by role. The AX selected-text write returned success, but full-field read-back did not match and the composer visibly still read `Chat probe: ` in a clean single-insert run. The harness reported `unverified`, did not paste or retry, and did not start observation. [Certain]

```text
app=com.openai.codex role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=true
insertion=unverified detail=AX selected-text write delivery unverified; retain output, never automatically retry
```

This matches the Arc silent-success pattern in a second Chromium-based surface. Under the current safety rule (paste only when the AX write is unsupported), dictation delivers nothing to this composer. Read-back here showed the field unchanged, which is distinguishable from an unexpected change; whether "unchanged after a successful-looking write" may safely trigger the paste fallback is an open design decision, not implemented. Slack, Discord, Messages, and the Claude desktop composer remain untested. [Certain]

### Paste fallback after an unchanged AX write (retest)

New rule in `insertText`: if an AX selected-text write reports success but read-back does not verify, the harness waits 300 ms and, only if the same non-browser field still reads exactly as before (value and selection), stages the clipboard and pastes once. Browser fields of unknown type never take this path. A write the app applies later than 300 ms would double-insert; that bounded wait is a spike shortcut. Deterministic checks cover the decision predicate. [Certain]

Codex composer retest: every insertion reported `clipboard paste after unchanged AX write matched full-field readback`, and the clipboard was restored afterwards. Observation then behaved like TextEdit: [Certain]

| Scenario | Result |
|---|---|
| Replace, Undo, append | `provisionalCandidate=true` → `false` → `observationStopped=appended text candidateRetained=false` |
| Replace, then Finder | `observationStopped=focus departed candidateRetained=true` |
| Two dictations with a space, replace in second | Both verified; candidate attributed to the second span |

Arc 1.166.0 retest, local `fields.html` textarea focused by the user, Arc brought forward by AppleScript activation only: Arc now exposed a focused `AXTextArea` (the earlier run saw `AXWebArea`). The AX write again reported success, and the visible box still read `Browser probe: `. Arc exposes no `AXDOMInputType` for the textarea, so the field is an unknown browser type: no fallback paste, no learning. [Certain]

```text
app=company.thebrowser.Browser role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=false
insertion=unverified detail=AX selected-text write delivery unverified; retain output, never automatically retry
```

The Arc exposure change may come from another accessibility client (the computer-use tool) activating Chromium's tree; it is not established as default behavior. Extending the fallback to browser fields needs a separate decision on unknown field types. [Certain]

### Paste fallback extended to browser fields (Arc retest)

At the user's direction, browser fields of unknown type now also take the unchanged-write paste fallback. Secure fields are still rejected before any write (AXSecureTextField, `AXDOMInputType=password`, protected content), and a secure field has no readable value, so the fallback predicate cannot pass for it. A browser paste remains `unverified` because read-back of unknown browser fields is not trusted, and learning stays excluded. A password field a browser fails to mark as secure would now receive a paste; that is the accepted risk of this decision. [Certain]

Arc 1.166.0, same focused local textarea: [Certain]

```text
app=company.thebrowser.Browser role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=false
insertion=unverified detail=clipboard paste after unchanged AX write delivery unverified; retain output, never automatically retry
```

A screenshot afterwards showed `Browser probe: Acme dictation probe`: delivered exactly once, no duplicate. [Certain]

## Code-editor synthetic test evidence

VS Code 1.140.0 (`com.microsoft.VSCode`, updated from the 1.138.0 seen earlier), default settings with screen reader optimized mode off, in Restricted Mode. A throwaway `code-probe.txt` containing `Code probe: ` was opened in a new window from Claude's scratchpad (outside the repo), caret at line 1, column 13. Claude had click-only access to VS Code, so the user ran the insertion. [Certain]

Before any click, with VS Code frontmost after an update, the harness found no focused AX element (`systemAX=-25204 appAX=-25212`); the release-notes tab had focus. After Claude clicked the `code-probe.txt` tab, the editor exposed a readable, learning-eligible `AXTextArea`. As with Arc, this exposure may follow from another accessibility client activating Electron's tree. [Certain]

```text
app=com.microsoft.VSCode role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=true
insertion=unverified detail=clipboard paste after unchanged AX write delivery unverified; retain output, never automatically retry
```

A screenshot afterwards showed `Code probe: Acme dictation probe` (Ln 1, Col 33): delivered exactly once by the paste fallback. Reading the focused element's AX value afterwards returned an empty string with 0 characters. VS Code exposes a stub text area, not the buffer, outside screen reader mode. The AX write went into the stub and was ignored. Read-back stayed unchanged, which correctly triggered the paste, but read-back can never confirm delivery or support observation here. [Certain]

Product findings: [Certain]

- Insertion into VS Code works in its default configuration via the paste fallback, which meets the no-user-setup requirement for delivery.
- `learningEligible=true` is only a pre-insertion check, and this stub field passes it. Learning was already blocked here: observation starts only after verified read-back, and the inserted text must sit at the anchored range. `observe()` now requires a verified insertion itself rather than relying on its caller; checks and a live TextEdit regression (replace, Undo, append) still pass.
- Correction learning in VS Code would need screen reader mode or an editor extension, both setup the user has ruled out for launch.

## Rich-text synthetic test evidence

Safari 26.6.2 (`com.apple.Safari`), new disposable Google Doc containing `Rich probe: `, run by the user from a terminal holding Accessibility permission (this Claude desktop session lacked it and recorded nothing). Notion and Pages are not installed. [Certain]

Default Docs settings, caret in the document body: Safari reported no focused AX element (`systemAX=-25204` cannot complete, `appAX=-25212` no value). An earlier attempt reported `AXList/AXCollectionList`, attributed to focus outside the body. No write was attempted in either case. [Certain]

```text
Spike: No accessible focused field; frontmost=com.apple.Safari systemAX=-25204 appAX=-25212
```

After the user enabled Google Docs Tools → Accessibility → Screen reader support, the body exposed a readable AXTextArea with no `AXDOMInputType`, so the harness treats it as an unknown browser field type: read-back cannot verify delivery and learning is excluded. [Certain]

```text
app=com.apple.Safari role=AXTextArea subrole=unknown secure=false valueReadable=true selectionReadable=true learningEligible=false
insertion=unverified detail=AX selected-text write delivery unverified; retain output, never automatically retry
```

The user confirmed the Doc then showed the inserted text, so the AX write delivered despite the harness's conservative `unverified` status; no paste or retry occurred and observation did not start. [Certain]

Product requirement from the user: dictation must not depend on users enabling screen reader support in Docs. Under that requirement Safari + Google Docs is **unsupported via AX in the default setup**. Whether a no-setup route exists (for example keyboard-event or clipboard paste into the Docs canvas, which works without AX exposure but cannot be read back) is untested; it would deliver without verification and give observation nothing to read. Chrome + Docs and Notion remain untested. [Certain]

## Independent review

After implementation handoff, a separate worker reviewed the integrated safety paths and found a clipboard-ownership gap after staging and final AX focus capture. The fallback now attaches a unique token to the staged pasteboard item and checks both token and stable change count immediately before paste and restoration. Deterministic checks cover foreign/missing ownership tokens and change-count races; live clipboard-manager behavior remains pending. NSPasteboard still offers no atomic compare-and-post/restore transaction. [Certain]

Code-editor setup inspection: VS Code 1.138.0, newly created Untitled-1 buffer, reports “The editor is not accessible at this time” and offers screen-reader optimized mode. That mode was not enabled; native insertion/observation remain pending setup. Claude 2.19675.0 has a prepared unsent synthetic Prompt draft; no message was sent. [Certain]

Use synthetic text only. In each category, test verified insertion, an attributable spelling replacement, undo/reversion, appended text, selection outside the span, focus departure, consecutive dictations, and permission revocation. Confirm the 60-second deadline and two distinct-session threshold separately. Mark pass/partial/unsupported with evidence; inability to obtain setup permission is pending setup. [Certain]

## Safety and remaining gates

- AX read-back mismatch must retain the output without another insertion attempt, except one paste when a nonsecure field (browser fields included) reads exactly unchanged after the settle wait; otherwise paste only when the AX write is unsupported. Clipboard restoration must skip after another writer changes the clipboard. [Certain]
- Known secure fields must be rejected. Browser fields of unknown type must remain unverified and excluded from learning even when text read-back matches. [Certain]
- Anchored range attribution does not prove semantic equivalence. A short replacement can change meaning, so candidates alone cannot justify automatic vocabulary promotion. [Certain]
- Persisted recovery, audio capture, production learning eligibility, model inference, UI, signing, and packaging are outside this standalone spike. [Certain]
- The recorded Right Option and native/chat observation evidence satisfies the narrow feasibility floor for starting milestone 1. The remaining safety checks and available-host model/audio validation remain acceptance gates; this report does not authorize a production-ready claim. [Certain]
