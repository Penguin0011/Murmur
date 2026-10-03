# Shortcut capture session

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

Press starts capture immediately; a release after at least 250 ms finishes, while a short tap leaves capture listening until the next press. Escape, event stream loss, SIGINT/SIGTERM and listener shutdown cancel active recording and delete audio. Retry audio is purged every minute while the listener runs. [Certain] Capture reaches processing at 120 seconds or on engine/write failure; partial audio is retained when frames exist. Processing blocks new sessions until the processor exits. [Certain]

Keyboard callbacks copy and enqueue each event on the main queue; state changes and capture actions execute together to avoid blocking the event tap. A processing child receives termination on shutdown; audio is retained for processing failure or cancellation. No transcription output is relayed to the terminal. Without a processor, completed WAV files are retained for retry with the capture store's 24-hour policy. [Certain]

The one-second listener smoke passed with Input Monitoring and Accessibility granted, without any keyboard activation or audio capture. Real physical shortcut timing and first-word preservation require live speech validation. [Certain]
