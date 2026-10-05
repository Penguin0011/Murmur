# Next-agent handoff: insertion and visual verification

## Assignment and completion

Review the entire insertion/recovery flow, run the visual and behavioral matrix below, fix regressions, and leave measured evidence. **Create a pull request and merge it when the review is complete and required checks pass.** Do not stop after writing a report or opening the PR.

The user's instruction for this handoff was: “make sure the agent knows to make a PR and merge once done.” PR creation and merging after verification are authorized by that request. [Certain]

Keep fixes small, commit working checkpoints, and preserve existing provider, credential, learning, and privacy behavior. Never add Codex as a co-author. If an external permission, unavailable target, or failing required check prevents completion, describe the concrete blocker and preserve the work; never label an unrun case passed.

## Starting point

- Workspace: `/Users/aakash/.codex/worktrees/8947/Dictation`; branch: `aakash-insertion-behavior`. [Certain]
- Application changes: `1f07d1a` (quiet delivery and paste-last recovery), `20294e3` (secure/focus checks), and review documentation: `5ea3ce5`. The handoff commit follows these. [Certain]
- Installed application: `/Users/aakash/Applications/Murmur.app`. Its executable SHA-256 at installation was `c1b2097cb92c4ee9570efb9deee8b0fa9cf8d87b93b69bd607aa269d63aef8ea`; source code was through `5ea3ce5`. [Certain]
- Previous app: `/Users/aakash/Applications/Murmur-backups/20261005-132505/Murmur.app`. [Certain]
- Installation signature verification passed; installed launch showed Ready, the updated paste-last help text, and Microphone/Accessibility/Input Monitoring allowed. All 279 history filenames were preserved across replacement. [Certain]
- Controller checks, `spike --check`, production build/signature verification, and preview launch passed. The native History fixture showed delivered rows without badges and no delivered rows under Needs attention. **Live microphone, provider, cross-app delivery, keyboard-layout, remote-client, and clipboard-manager tests have not been run for these changes.** [Certain]

Read [app/INSERTION_REVIEW.md](app/INSERTION_REVIEW.md), [CONTRIBUTING.md](CONTRIBUTING.md), [PRD.md](PRD.md), and the latest [HANDOFF.md](HANDOFF.md) before testing. Inspect the actual code when documents disagree; do not assume earlier smoke tests cover the current executable.

## Test isolation and evidence

- Use synthetic phrases, disposable unsent drafts, a disposable TextEdit document, and local browser fixtures. Never submit a message/form or inspect real transcript contents to prove delivery.
- Use `app/check_ui.sh` for visual fixtures; it creates temporary preview storage and does not capture or insert. Its default appearance is dark; `--light`, `--compact`, and `--opaque` affect only the fixture. [Certain]
- The current fixture seeds only two in-memory entries (`verified` and `unverified`) and a synthetic status. `--saved` is a synthetic Saved phase with a model-error message; it does not prove real quiet completion. The fixture's dismissal assertion expects two entries. [Certain] Extend this existing fixture minimally for other statuses; update its assertion and save synthetic records into its isolated storage if testing deletion. Do not add records to the user's history.
- Use Computer Use for native GUI actions and current AX snapshots/screenshots. Do not substitute synthetic event injection for physical shortcut/microphone evidence. The explicit developer audio probe is available for isolated automated pipeline testing. [Certain]
- Record actual macOS/app versions, appearance, window size, executable hash, steps, expected/actual result, screenshot path, relevant content-free log excerpt, and verdict for every matrix row. Use **PASS / FAIL / NOT RUN**, with a reason for each NOT RUN. Keep synthetic screenshots/output in `runtime/verification/`; do not commit private transcripts, credentials, model files, or audio.
- Preserve the user's settings, dictionary, history, clipboard, open documents, and selected provider. Use fixture-only appearance/accessibility overrides where possible. Do not delete live data or change global privacy permissions to exercise failure cases; simulate those cases in isolated checks.

## Verification results — October 5, 2026

Environment: macOS 26.6.2; app bundle version 0.1.0 (build 1); arm64; fixture window 1000×680 points, compact 760×560 points; full application executable SHA-256 `424a560969b3dd40b33f5763c95a5df9c4a8d0681d8f7d10588d364352594997`. [Certain] `app/build.sh`, `codesign --verify --deep --strict runtime/Murmur.app`, and `runtime/Murmur.app/Contents/MacOS/Murmur --preview --quit-after 2` passed after the source change. [Certain]

| Area / step | Expected and observed | Evidence / verdict |
| --- | --- | --- |
| History status matrix; dark full-size | Seven synthetic rows showed verified/unverified without delivery badges, failed as Not inserted, pending as Saved with duplicate-avoidance guidance, held results as recoverable, and session-only retention disclosure; Needs attention excluded verified, unverified, and saved-not-inserted. | `runtime/verification/history-matrix-dark-full.png`, `history-matrix-needs-attention.png`, `history-session-only-dark.png` — PASS. [Certain] |
| History visual variants | Long multiline text wraps; light, dark, compact, and opaque layouts were inspected. Search no-results and empty History appeared; the empty state disables Clear History. | `runtime/verification/history-matrix-light-full.png`, `history-matrix-light-compact-opaque.png`, `history-search-empty.png`, `history-empty-dark.png` — PASS. [Certain] |
| History actions | Synthetic row deletion removed one fixture record; Clear History confirmation showed irreversible-deletion text, Cancel retained rows, Delete All cleared only the fixture. Copy Text and Copy Raw showed copied feedback; the original clipboard's item/type representation was restored and verified unchanged. | `runtime/verification/history-clear-confirmation.png` — PASS. [Certain] |
| Bubble and recovery UI | Listening and processing bubbles rendered; error status click opened Settings and dismiss cleared the status. Saved/learned synthetic notice rendered. | `runtime/verification/bubble-listening.png`, `bubble-processing.png`, `error-dismiss-ready-dark.png` — PASS. [Certain] |
| Keyboard/accessibility | Tab focus reached Search with visible focus ring; labels exposed History states and bubble status through Accessibility. | UI Automation accessibility snapshots — PASS. [Certain] |
| Isolated UI matrix | `app/check_ui.sh --history --saved --matrix`, light/full, light/compact/opaque, empty History, and listening/processing/recovery bubble fixtures were run. | PASS. [Certain] |
| Source checks | Launch (normal/preview/probe and 13 invalid combinations), History persistence/retention/deletion, controller, insertion spike, dictionary, provider and processing checks passed. | PASS. [Certain] |
| Build/signature/preview | Production build completed; deep/strict bundle signature verification succeeded; preview exited 0. | PASS. [Certain] |
| Physical speech and live model insertion | Not run: the pinned Parakeet model directory contains metadata/configuration only, not its model weight files. The production `--test-audio` probe therefore cannot reach transcription. | NOT RUN; no weights downloaded and no provider/preferences changed. [Certain] |
| Live target-app insertion and recovery | TextEdit, browser fields, rich-text/canvas editors, chat composers, code editor/terminal, secure fields, focus changes, physical shortcut, alternate keyboard layout, remote client, and clipboard-manager race cases were not exercised in this run. | NOT RUN; no disposable target-app matrix was executed. Synthetic UI is not delivery evidence. [Certain] |
| Reduce Motion / contrast preferences | Not run because exercising them would require changing persistent system appearance/accessibility settings; opaque rendering was exercised in the fixture. | NOT RUN. [Certain] |

Residual race limits remain: macOS focus checks, clipboard staging, posting, and restoration are not atomic; the 0.5-second clipboard lease may be too short for slow or remote readers. [Certain] This verification does not establish universal delivery reliability. [Certain]

## Visual review

Run these separately and quit each fixture before opening another:

```sh
app/check_ui.sh --history --saved
app/check_ui.sh --light --history --saved
app/check_ui.sh --light --compact --opaque --history --saved
app/check_ui.sh --listening --bubble-only
app/check_ui.sh --processing --bubble-only
app/check_ui.sh --recovery
app/check_ui.sh --saved --learned --bubble-only
```

- [ ] Inspect verified and unverified History rows, collapsed and expanded. Neither should show Inserted, Delivery uncertain, a verification explanation, or a success banner. Final text and copy controls must remain readable.
- [ ] Inspect All, Needs attention, search results, no-results state, empty History, initial recovery selection, and long/multiline transcripts. Delivered entries must not enter Needs attention solely because read-back was unavailable.
- [ ] Add isolated fixture cases for `failed`, `insertion-pending`, `saved-not-inserted`, `held-cleanup`, `held-transcript`, and session-only history. Actual failures/held results must remain discoverable. Pending delivery must say Saved and tell the user to check the target before recovery, avoiding duplicates.
- [ ] Inspect full-size and minimum-size layouts in light/dark and opaque rendering. Check truncation, wrapping, alignment, contrast, scrolling, focus rings, keyboard navigation, and accessible names. Inspect Copy Text, Copy Raw, Delete, Clear History, and copied feedback.
- [ ] Confirm listening/processing indicators do not steal focus and disappear when delivery finishes. Successful/unverified delivery must return the app/menu bar to Ready. Actual paste failure must show a brief actionable error with full details accessible in Settings.
- [ ] Verify error click/navigation and dismissal, error timeout, a newer status replacing an older timer, and preservation of recovery after dismissal. Check retained-audio access and learned-word notices for regressions.
- [ ] Verify assistive completion uses “Dictation finished.” without asserting verified delivery. Check VoiceOver/keyboard access where available, and Reduce Motion/Transparency/Increase Contrast without altering the user's persistent settings.

## Live insertion and recovery matrix

For every available target category, record a separate visual result and delivery result. An attractive History screenshot is not delivery evidence.

| Target | Cases to exercise |
| --- | --- |
| Native editor: disposable TextEdit document | Empty field; append; middle of text; selection replacement; emoji/UTF-16 boundaries; multiline output; leading-space toggle on/off. |
| Browser native inputs: Safari and/or Chrome | Local `spike/fields.html` textarea and rich text; empty local password field refusal; address/search field where available. |
| Rich-text editor / canvas | Disposable unsent Google Docs/Notion or equivalent editor; compare readable and unreadable AX behavior; paste exactly once. |
| Chat / Electron composer | Disposable unsent draft; no Return or submission; finish, cancel, change focus, copy recovery, paste-last. |
| Code editor and terminal | Disposable untitled file or editor scratch buffer. For terminal testing, use a non-executing disposable text sink, never the user's live shell prompt. |

Start the local browser fixture if needed:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory spike
```

Open `http://127.0.0.1:8765/fields.html` and stop the server after testing. The fixture has no forms or scripts. [Certain]

Use the production pipeline with a synthetic audio file and an exact disposable foreground destination when physical speech is unavailable:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

The probe uses temporary user-data storage/local cleanup, preserves the supplied audio, and does not use saved API keys. [Certain] Quit the normal installed app only while idle, avoid conflicting app instances/shortcuts, and relaunch the installed app after isolated tests. The probe is not physical-microphone or live-provider evidence.

- [ ] Verify local and cloud routes converge on the shared delivery path. Use mocked provider checks for all route combinations. For live cloud coverage, use synthetic input through already configured, acknowledged routes without displaying/extracting keys; a new data-sharing destination still requires its normal in-app acknowledgement.
- [ ] Confirm the currently focused field at delivery receives text. Moving focus during processing should follow the existing Insert at the cursor setting; a further change during staging should refuse delivery when identity is available. Automatic insertion must never paste into Murmur itself.
- [ ] Test automatic insertion off and setup dictation; retain processed output for explicit recovery. Test blank/filler-only output, canceled recording/request, failed transcription, held cleanup/transcript, and busy-state shortcut exclusion.
- [ ] Press Control-Command-V after verified delivery, unreadable delivery, and a failed attempt. Check the destination before retrying; each explicit press should perform at most one paste. Confirm an unsuccessful later recording does not erase the older usable buffer, and a newer usable dictation replaces it.
- [ ] Verify Copy Text preserves processed output and Copy Raw/Control-Command-C intentionally return raw output. No copy action should paste, submit, or automatically retry.
- [ ] Test empty/secure/unavailable destinations and accessible password metadata, including when Secure Input is not set. Check both readable automatic insertion and the unreadable/manual path, including a Secure Input transition during clipboard staging. Do not use an actual password.
- [ ] Exercise pre-attempt save failure, post-attempt status-save failure, and restart with a pending record using isolated fault injection/checks. Pre-attempt failure must not paste; post-attempt recovery must avoid encouraging blind duplication.
- [ ] Delete a synthetic transcript and clear synthetic History; matching paste/setup buffers must become unavailable only after successful deletion. Test failed deletion and Delete All Data only in isolated storage. Consider buffers whose History record has expired/been evicted, as well as duplicate final texts.
- [ ] Verify correction learning still watches only the attributable dictation span, respects strict readable-field mode and secure/focus boundaries, and handles undo, app switches, and explicit paste-last without following unrelated typing.

## Clipboard, compatibility, and remaining risks

- [ ] Verify prior plain text, rich text, images, and an empty clipboard restore after automatic/manual paste. Check newer copies during the lease are preserved and clipboard-owner/count mismatches refuse unsafe posting/restoration. Use synthetic clipboard contents.
- [ ] Check for duplicate insertion after delayed read-back; never add automatic retry as a fix. Test an unreadable/non-editable surface separately from a real editable field.
- [ ] Review the fixed ANSI paste/copy key positions and test an alternative layout if available. Prefer native layout translation if fixing this; do not add a keyboard library. Restore any temporary layout change.
- [ ] Review the fixed 0.5-second clipboard lease and synchronous main-thread wait. Test a slow reader/remote viewer if available; document unavailable targets. Fix reproducible delivery/UI freezes with the smallest shared change, without introducing blind retries or remote-specific code solely on speculation.
- [ ] Review focus, clipboard, and Secure Input checks immediately before posting. The current APIs do not make checking/staging/posting/restoration atomic, and missing AX identities retain a same-app heuristic. [Certain] Describe residual races honestly rather than marking delivery confirmed from an event being posted.

Wispr documents clipboard restoration around 0.5 seconds, extra time for remote viewers, explicit recovery, and assumed success in some unreadable fields. Its private implementation is unknown. [Certain] See [its insertion recovery guide](https://docs.wisprflow.ai/articles/1621472516-flow-fails-to-detect-text-fields-or-inserts-incorrectly-on-non-qwerty-keyboard-layouts) and [remote-desktop guide](https://docs.wisprflow.ai/articles/7336156466-use-flow-with-remote-desktops-citrix-rdp-vdi). Compare documented Mac behavior; do not apply Android restrictions to macOS without evidence.

## Required checks and deliverables

Run the native controller command in CONTRIBUTING.md and the spike checks after relevant changes. Run the history, launch, processing/learning, and route/provider checks when their behavior is touched. Finish with `app/build.sh`, deep/strict signature verification, preview launch, and installed-app verification after any final code changes. Run required repository/CI checks; do not run paid providers merely to satisfy mocked-route coverage.

```sh
mkdir -p spike/.build
swiftc -module-name DictationSpike spike/Shortcut.swift spike/ShortcutChecks.swift spike/Insertion.swift spike/Observation.swift spike/main.swift -o spike/.build/dictation-spike
spike/.build/dictation-spike --check
app/build.sh
codesign --verify --deep --strict runtime/Murmur.app
runtime/Murmur.app/Contents/MacOS/Murmur --preview --quit-after 2
```

Update this file with the completed matrix/evidence, [app/INSERTION_REVIEW.md](app/INSERTION_REVIEW.md) with resolved findings and honest limits, and HANDOFF.md with final source/install hashes and backup location. Keep screenshots of private user data out of the PR.

## PR and merge — required final steps

1. Fetch `origin`, inspect current `main`, and integrate newer changes into `aakash-insertion-behavior` before final validation. Preserve unrelated work and newer provider/UI fixes; never force-push or reset another agent's work blindly.
2. Review the final diff and commit the completed verification/fixes in logical chunks. Push the branch and create a PR into the verified default branch. Describe quiet completion, explicit recovery, secure/focus checks, measured visual/delivery evidence, and any residual limits. Use an existing PR for this branch if one already exists.
3. Attach the created PR to the working chat with `mcp__codex_app__attach_artifact`. Resolve actionable review findings and wait for required checks to pass.
4. **Merge the PR after verification is complete. Do not ask the user again merely for permission to create or merge it; this handoff explicitly requests both.** Honor enforced GitHub protections. If essential verification fails or a blocking finding remains, fix it before merging; unavailable optional target apps may be recorded as NOT RUN with an explicit coverage limit.
5. Confirm the PR is merged and record the merge commit. Build/verify the merged source and install it locally if fixes or integration changed the app, with an idle-state check, backup, signature/executable verification, and a Ready/permission check. Leave the installed app running normally and temporary fixtures/servers closed.
6. Report the PR link, merge commit, installed hash/path, completed tests, evidence location, and remaining coverage limits. Do not claim universal insertion reliability from this matrix.
