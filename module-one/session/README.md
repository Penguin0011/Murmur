# Shortcut capture session

**Tool scope.** Commands below run from the repository root. This README describes standalone validation tools and dated measurements; missing features in these harnesses do not imply they are missing from the app. See [CONTRIBUTING.md](../../CONTRIBUTING.md) for app checks. [Certain]

Build from the repository root:

```sh
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift module-one/session/main.swift -o /tmp/dictation-session
/tmp/dictation-session --check
```

The synthetic check exercises start, tap stop, hold release, processing exclusion, Escape/event-stream-loss deletion, startup failure, queued failed-start recovery and shutdown without accessing the microphone. [Certain]

Explicit live capture:

```sh
/tmp/dictation-session --listen --binding right-option --listen-seconds 30
/tmp/dictation-session --listen --processor "$PWD/module-one/session/process.py" --model-directory /absolute/model/directory
```

Press starts capture immediately; a release after at least 250 ms finishes, while a short tap leaves capture listening until the next press. Escape, event stream loss, SIGINT/SIGTERM and listener shutdown cancel active recording and delete audio. Retry audio is purged every minute while the listener runs. [Certain] Capture reaches processing after five minutes (`CaptureSession.recordingLimit`) or on engine/write failure; partial audio is retained when frames exist. Processing blocks new sessions until the processor exits. [Certain]

Keyboard callbacks copy and enqueue each event on the main queue; state changes and capture actions execute together to avoid blocking the event tap. A processing child receives termination on shutdown; audio is retained for processing failure or cancellation. No transcription output is relayed to the terminal. Without a processor, completed WAV files are retained for retry with the capture store's 24-hour policy. [Certain]

The one-second listener smoke passed with Input Monitoring and Accessibility granted, without any keyboard activation or audio capture. Real physical shortcut timing and first-word preservation require live speech validation. [Certain]

## Local transcription and recovery

The executable `process.py MODEL_DIRECTORY AUDIO_FILE` verifies pinned model checksums, invokes the built runner once, atomically writes raw/final text with file/directory fsync, and deletes audio only after durable text exists. Runner timeout, integrity failure, missing/empty output, cancellation, and saving failure retain retry audio. It performs no insertion or cloud request. Transcript content is kept out of console diagnostics. [Certain]

History defaults to `~/Library/Application Support/DictationCaptureSpike/history` with directory 0700 and records 0600. This standalone checkpoint implements thirty-day expiry at processor startup only; configurable retention, continuous history expiry, history-off, and a history UI remain product work. Capture recovery expiry is a separate twenty-four-hour policy. [Certain]

```sh
python3 module-one/session/check_process.py
module-one/session/process.py /absolute/model/directory /absolute/retry.wav
```

## Verified continuation — October 2, 2026

On M3/16 GB/macOS 26.6.2, the release model runner built, pinned weight checksums verified, and actual local inference passed on synthetic speech. A root-run synthetic-file integration independently saved text durably and removed its audio, with load 0.498 s and first inference 0.103 s. These are one smoke run, not a performance distribution or real dictation benchmark. [Certain]

An injected Right Option hold followed by a tap/Escape cycle exercised the connected event tap and real microphone: the hold retained 157,696 bytes of WAV audio, and the canceled recording left no file. All audio from that test was removed. The injected events do not establish physical keyboard timing or first-word preservation. [Certain]

A separate connected acoustic smoke played a 5.73-second synthetic utterance through the speakers during an eight-second held recording. The selected local model processed the microphone WAV, the processor saved nonempty raw/final history, and audio was removed. One load took 0.424 s, audio preparation 0.046 s, and inference 0.123 s. The synthetic history entry was removed after verification. No insertion was attempted. This is microphone-path evidence, not user-speech quality or a proof against initial-word loss. [Certain]

Processor fault checks pass missing-model rejection, save failure, timeout, fsync-backed save before audio deletion, private permissions, thirty-day retention boundaries, and termination during child startup with child reaping. [Certain]
