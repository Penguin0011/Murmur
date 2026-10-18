# Shortcut capture session

**Tool scope.** Commands below run from the repository root. This README describes standalone validation tools and dated measurements; missing features in these harnesses do not imply they are missing from the app. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for app checks.

Build from the repository root:

```sh
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift module-one/session/main.swift -o /tmp/dictation-session
/tmp/dictation-session --check
```

The synthetic check exercises start, tap stop, hold release, processing exclusion, Escape/event-stream-loss deletion, startup failure, queued failed-start recovery and shutdown without accessing the microphone.

Explicit live capture:

```sh
/tmp/dictation-session --listen --binding right-option --listen-seconds 30
/tmp/dictation-session --listen --processor "$PWD/module-one/session/process.py" --model-directory /absolute/model/directory
```

Press starts capture immediately; a release after at least 250 ms finishes, while a short tap leaves capture listening until the next press. Escape, event stream loss, SIGINT/SIGTERM and listener shutdown cancel active recording and delete audio. Retry audio is purged every minute while the listener runs. Capture reaches processing after five minutes (`CaptureSession.recordingLimit`) or on engine/write failure; partial audio is retained when frames exist. Processing blocks new sessions until the processor exits.

Keyboard callbacks copy and enqueue each event on the main queue; state changes and capture actions execute together to avoid blocking the event tap. A processing child receives termination on shutdown; audio is retained for processing failure or cancellation. No transcription output is relayed to the terminal. Without a processor, completed WAV files are retained for retry with the capture store's 24-hour policy.

Physical shortcut timing and first-word preservation require live speech validation.

## Local transcription and recovery

The executable `process.py MODEL_DIRECTORY AUDIO_FILE` verifies pinned model checksums, invokes the built runner once, atomically writes raw/final text with file/directory fsync, and deletes audio only after durable text exists. Runner timeout, integrity failure, missing/empty output, cancellation, and saving failure retain retry audio. It performs no insertion or cloud request. Transcript content is kept out of console diagnostics.

History defaults to `~/Library/Application Support/DictationCaptureSpike/history` with directory 0700 and records 0600. This standalone CLI implements thirty-day expiry at processor startup only; it does not provide the app’s retention controls or History interface. Capture recovery expiry is a separate twenty-four-hour policy.

```sh
python3 module-one/session/check_process.py
module-one/session/process.py /absolute/model/directory /absolute/retry.wav
```
