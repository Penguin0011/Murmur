# Native Murmur app

Build the local development bundle on Apple Silicon/macOS 26:

```sh
app/build.sh
open runtime/Murmur.app
```

The bundle uses the pinned local ModelBench helper. Model download, cleanup, cloud providers, signing/notarization, and production release remain separate work. [Certain]

## Recovery and interface

Idle errors have a Dismiss control. Dismissal hides status without deleting history or retry audio; it is unavailable while recording or processing. Storage failure remains an error rather than claiming the app is ready. [Certain]

Settings show the current state above the scrollable form, model file availability, individual permission rows, and an always-visible Apply Settings button. Model availability checks file sizes; full checksums are verified before inference. History supports search, delivery status, initial selection, and recovery-entry selection. [Certain]

Recording and processing use a compact standalone glass-dot voice indicator on a transparent background by default. Saved output and successful insertion show no popup; delivery status remains in History. Only errors show a compact clickable message and, when recovery audio exists, Audio. Clicking the popup opens the Dictation tab with the full error, even when History was selected. Dismiss and Audio have separate actions. [Certain]

Corrupt or mismatched history files produce an error and prevent retention from silently skipping data; corruption at startup currently blocks dictation. Automatic repair/quarantine is not implemented. [Certain]

## Checks

All of these avoid live recording, insertion, and keyboard injection:

```sh
swiftc app/LaunchOptions.swift app/check_launch.swift -o /tmp/dictation-launch-check
/tmp/dictation-launch-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/check_history.swift -o /tmp/dictation-history-check
/tmp/dictation-history-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Controller.swift app/UI.swift app/check_controller.swift -o /tmp/dictation-controller-check
/tmp/dictation-controller-check
```

### Cloud providers, credentials, and updates

`Providers.swift`, `Credentials.swift`, and `Updates.swift` use only Foundation and are not wired into the app yet. Their checks need no network and no keys. They pass with Swift 6.1.2 on Linux. They have not yet been compiled on the macOS 26 host (Swift 6.3.3, `-swift-version 5`), and the Keychain store is compiled only on macOS. [Certain]

```sh
swiftc app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-providers-check
/tmp/murmur-providers-check
swiftc app/Updates.swift app/check_updates.swift -o /tmp/murmur-updates-check
/tmp/murmur-updates-check
```

No provider call has been made with a real API key. The request shapes come from official documentation, and the error shapes from documentation or from unauthenticated responses (see [PROVIDERS.md](PROVIDERS.md), verified October 3, 2026). Fireworks deprecated audio inference on June 10, 2026. OpenRouter's transcription endpoint is the documented alternative. Each route needs a live check with a real key before it is offered. [Certain]

For isolated empty-history visual inspection, run the executable directly:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --preview
```

Preview disables shortcut capture and uses temporary history/retry storage. Permission buttons and Apply Settings are real controls; inspecting preview does not require using them. [Certain]

`check_ui.sh` builds and runs the synthetic visual fixture with temporary storage, synthetic transcripts, and an error bubble. It performs no capture or insertion; dismissal asserts that recovery history remains. The fixture has a working Quit menu and closes its temporary storage on normal exit. [Certain]

```sh
app/check_ui.sh
app/check_ui.sh --light
app/check_ui.sh --light --compact --opaque
app/check_ui.sh --bubble-only
app/check_ui.sh --listening --bubble-only
app/check_ui.sh --processing --bubble-only
app/check_ui.sh --saved --bubble-only
```

The fixture forces only its own appearance. `--compact` uses the minimum production window size, while `--opaque` forces the same opaque rendering branch used by Reduce Transparency for the settings/History view. The separately hosted floating bubble continues to use actual system accessibility settings. [Certain]

The developer audio probe requires both flags and must target a disposable field:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

This explicitly performs transcription and one insertion attempt. It preserves the supplied audio, using a private retry copy, and writes durable history. It cannot be combined with preview or timed quit; malformed flags exit before storage/UI initialization. [Certain]

## Evidence from October 2, 2026

The app bundle built and ad-hoc signing passed. Launch, history/model-verifier, controller dismissal/audio ownership, session state, processor fault/signal, and spike insertion/observation checks passed. Native screenshots/AX inspection confirmed settings and empty/populated History, error dismissal to Ready, preserved synthetic entries, matching-transcript selection, and no-results search. The native Liquid Glass update was captured in light, dark, and forced opaque compact appearances. Scoped screenshot review resolved supporting-text and search-placeholder contrast findings. Native History filtering/clearing and the floating bubble Dismiss click passed; the fixture confirmed preserved recovery history. [Certain]

Physical shortcut/microphone first-word behavior, real speech quality, clipboard-manager races, and live insertion after these changes remain unverified. The synthetic bubble click does not establish focus preservation in a real destination app. [Certain]

## Leading space

Enable **Intelligently add a leading space** and apply settings to separate inserted dictation from existing text. The option defaults off. It uses the original field value and UTF-16 cursor position, and only inserts a space when preceding text needs separation. It skips existing whitespace, opening delimiters, punctuation-led output, selected-text replacement, word interiors, and unavailable/invalid context. The insertion safety check still rejects changed destinations. Raw transcription stays unchanged; History final text records the attempted insertion including its added space. Copy-only output remains unchanged. [Certain]
