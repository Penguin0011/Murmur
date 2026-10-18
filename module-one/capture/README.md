# Native capture probe

**Tool scope.** Commands below run from the repository root. This README describes standalone validation tools and dated measurements; missing features in these harnesses do not imply they are missing from the app. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for app checks.

This standalone Swift harness uses AVAudioEngine and AVAudioFile; it has no app skeleton or third-party dependencies. The weakest remaining claim is first-word capture: installing the tap before engine startup avoids an intentional tap/hold delay, but only a live shortcut-to-audio test can establish whether startup drops speech.

Build and run non-recording checks from the repository root:

```sh
swiftc module-one/capture/Capture.swift module-one/capture/main.swift -o /tmp/dictation-capture-spike
/tmp/dictation-capture-spike --check
/tmp/dictation-capture-spike --probe
```

The permission probe does not request a grant; recording refuses unauthorized access. Permissions belong to the execution context.

Explicit bounded recording commands, for a consenting tester speaking synthetic content:

```sh
/tmp/dictation-capture-spike --record-seconds 5
/tmp/dictation-capture-spike --record-seconds 5 --cancel-after 1
/tmp/dictation-capture-spike --purge
```

Recording accepts a finite duration above zero and at most 120 seconds, uses the system input device, and installs its tap before starting the engine. SIGINT/SIGTERM or `--cancel-after` cancels, drains writes, and deletes the file; normal completion retains retry audio because this harness has no transcription stage. Engine stop or a write error ends recording and retains any captured frames for recovery. First-buffer latency measures engine-start-to-first-buffer, not shortcut-to-speech or word accuracy.

Retry WAV files live under `~/Library/Application Support/DictationCaptureSpike/retry-audio`, with directory mode 0700 and file mode 0600 established before samples are written. Expiry uses the original creation timestamp and never extends it on reopen; future-dated files are removed conservatively. Purging runs at recording startup, during recording, and with `--purge`. A stopped CLI cannot enforce expiry while it is not running; the application must invoke this policy at launch and periodically. Crash recovery may contain an incomplete WAV, whose decodability is unverified.

The checks generate a 100 ms synthetic WAV, verify frame count and a sample on reopen, inspect permissions, prove survival before 24 hours/deletion at 24 hours, and exercise deletion of a synthetic canceled file. They do not establish live SIGINT cancellation, device disconnection, callback timing, audio quality, microphone selection, physical shortcut integration, or M1 behavior.

After usable transcription, call `RetryAudio.delete` for the session file and use text for recovery. This standalone CLI does not provide the app’s microphone-selection or device-change interface.

Interface: `Capture.start(url:)` starts immediately without a gesture classification wait; `Capture.stop()` stops the engine and tap, drains the serial writer, and closes the WAV. `RetryAudio.create`, `purge(now:)`, and `delete` own recovery storage. These shared types are wired into the shortcut session CLI in `module-one/session`.
