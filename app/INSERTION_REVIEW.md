# Insertion review — October 5, 2026

## Result

Posted pastes finish quietly, whether read-back verifies delivery or the destination is unreadable. Inserted and Delivery uncertain badges and the uncertainty explanation are removed, including for existing History entries. Verified/unverified evidence remains in stored records and content-free local logs. Read-back never triggers another paste. [Certain]

## Paths reviewed

| Path | Behavior |
| --- | --- |
| Local or cloud transcription | Both save raw text before processing and converge on `deliver` → `complete`. Dictionary/cleanup guards run before the final text is saved for the one delivery attempt. [Certain] |
| Readable text field | Capture the field focused at delivery, apply optional leading spacing, compare field identity/value/UTF-16 selection immediately before paste, post Command-V once, and read back for diagnostics and correction learning. [Certain] |
| Unreadable editor or missing AX focus | Paste once into the frontmost external app, preserving the clipboard. Check Accessible secure-field metadata and Secure Input; recheck app/field/window identity after clipboard staging. Two missing identities still use the existing same-app heuristic. [Certain] |
| Automatic insertion off / setup | Keep output for explicit paste or copy; onboarding shows its test result inside Murmur. Automatic insertion never pastes into Murmur itself. [Certain] |
| Paste last, Control-Command-V | Explicitly repaste the last usable final text, including verified deliveries. Ignore the chord while busy, finish the previous correction watch, run the shared secure/permission/focus checks, and show an error only on refusal. [Certain] |
| Copy / Control-Command-C | History Copy Text copies final output. Copy Raw and Control-Command-C intentionally copy raw output, including held transcripts. Copy does not paste, retry, or send. [Certain] |
| Cancellation, failed transcription, held cleanup | Recording cancellation produces no delivery; cloud callbacks require the current generation. Held cleanup/transcripts require explicit raw-text recovery. An older usable paste buffer survives unsuccessful later recordings. [Certain] |
| Deleted transcript / Delete All Data | Remove the matching paste/setup buffers after successful transcript deletion. Failed deletion keeps recovery; Delete All Data clears all buffers. [Certain] |
| Storage failure / interrupted delivery | A pre-attempt save failure blocks paste. A post-attempt status-save failure tells the user to check the target before retrying. Existing insertion-pending records display Saved with a duplicate-avoidance explanation. [Certain] |

Clipboard staging copies the existing pasteboard types, adds a unique ownership token and transient markers, and restores only while its change count and token still match. A newer clipboard write is left alone. No delivery path generates Return or submits a message. [Certain]

## Wispr Flow comparison

Wispr documents clipboard-based delivery, restoration about half a second later while preserving newer copies, explicit Paste Last Text / Copy Last Text recovery, and assumed success in a small set of apps whose fields cannot report text. Those documented recovery and quiet-completion behaviors support this change; their private implementation and complete success-status UI are unknown. [Certain] Source: [Wispr Flow insertion recovery](https://docs.wisprflow.ai/articles/1621472516-flow-fails-to-detect-text-fields-or-inserts-incorrectly-on-non-qwerty-keyboard-layouts).

Murmur keeps its existing busy-state exclusion and raw-copy shortcut; Wispr says Paste Last Text cancels processing, and describes its copy shortcut as returning the last transcript. Murmur does not automatically replace the user's clipboard with recovery text. [Certain]

## Remaining limits

- Paste and copy shortcuts use fixed ANSI key positions (V = 9, C = 8); alternative layouts need layout-aware translation and device tests. Flow documents alternative-layout support. [Certain]
- Murmur restores the clipboard after 0.5 seconds in every target, blocking the main thread during that wait. A slow reader can miss the transcript or read the restored clipboard; remote clients are not given extra time. [Certain] Flow documents a roughly five-second lease for remote viewers. [Certain] Source: [Wispr Flow insertion recovery](https://docs.wisprflow.ai/articles/1621472516-flow-fails-to-detect-text-fields-or-inserts-incorrectly-on-non-qwerty-keyboard-layouts).
- Focus checks, clipboard staging, event posting, and restoration cannot be atomic with the current macOS APIs. An app with no useful AX metadata cannot distinguish an editor from a non-editable surface or an undisclosed password field unless Secure Input is enabled. [Certain]
- Correction learning is separate from delivery: unreadable fields still use the existing bounded keystroke heuristic unless strict readable-field learning is enabled. A posted paste does not prove correction attribution. [Certain]

The native synthetic checks and History fixture verify the changed status/recovery behavior; they do not establish live cross-app paste reliability, physical shortcuts, alternative layouts, remote viewers, or clipboard-manager races. [Certain]

## Validation

The native controller executable passed the status, recovery-buffer, deletion-failure, timer, leading-space, UTF-16/read-back, clipboard-ownership, identity, helper, and chunk checks. `spike --check` passed shortcut, insertion, and observation checks. Launch, History, dictionary, provider, processing, and isolated UI fixture checks passed. `app/build.sh`, deep/strict signature verification, and the isolated preview launch passed. The screenshots and full per-row matrix are in [VISUAL_VERIFICATION.md](../VISUAL_VERIFICATION.md). [Certain]

The installed app at `/Users/aakash/Applications/Murmur.app` remains on the previously verified executable `c1b2097cb92c4ee9570efb9deee8b0fa9cf8d87b93b69bd607aa269d63aef8ea`; this task changes only the isolated UI fixture and its test seam. [Certain] The development bundle at `runtime/Murmur.app` has executable SHA-256 `424a560969b3dd40b33f5763c95a5df9c4a8d0681d8f7d10588d364352594997`. [Certain] Live microphone, provider, and cross-app delivery tests remain unrun for this task. [Certain]
