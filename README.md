# Murmur

Murmur is a macOS dictation app. Press a global shortcut, speak, and Murmur types the text into the focused field. It can remove fillers, apply spoken corrections and format lists, and each of these can be turned on or off. Transcription runs locally by default with NVIDIA Parakeet Unified English through FluidAudio and Core ML.

## Status

Pre-release source project. There is no production-signed, notarized download; build a development bundle from source.

Murmur transcribes locally by default and inserts text into the focused field. It also offers optional cloud transcription and cleanup, a custom dictionary, correction learning, meeting capture, and update checks. Cloud features require your own provider configuration.

## Requirements

- Apple Silicon Mac (M1 or later). Intel is not supported.
- macOS 26 or later.
- Swift toolchain to build (the development host uses Swift 6.3.3).
- Permissions: Microphone, Accessibility, and Input Monitoring for dictation; System Audio Recording for meeting audio from other apps.

Development and performance testing has focused on an M3 MacBook Air with 16 GB of memory.

## Build

Install Apple Command Line Tools (`xcode-select --install`) or Xcode with a macOS 26 or newer SDK and Swift toolchain before building.

```sh
git clone https://github.com/Penguin0011/Murmur.git
cd Murmur
app/build.sh
open runtime/Murmur.app
```

The first build needs internet access to fetch pinned FluidAudio source and its checksummed binary dependency. It does not download speech model weights.

For contributors, the [development guide](CONTRIBUTING.md) covers checks and fixtures. [Provider integration](app/PROVIDERS.md) explains optional route configuration; [app development](app/README.md) covers settings, recovery, and test tools.

## First run

Open Settings, download the speech model (review its license first), and grant the permissions shown by the app. Local dictation needs no provider account or API key. Cloud routes are optional and require your own provider configuration. Start with a disposable text field and synthetic speech; the default shortcut is Right Option: hold for at least 250 ms and release to finish, or double-press to keep recording until the next press. A lone short tap is canceled. Enable **Press once to start, again to stop** in Settings → General for single-press toggling. Review the shortcut and insertion options in Settings → General.

For an isolated interface preview with synthetic data and no capture or insertion, run:

```sh
app/check_ui.sh
```

See [SECURITY.md](SECURITY.md) for reporting and secret-scanning instructions.

## Privacy

Murmur keeps dictation local by default. Review these data flows before enabling optional features:

- Transcription and cleanup run locally by default. Model downloads and update checks use the network.
- Cloud processing is opt-in. Settings displays the destination and data disclosure inline. Cloud transcription does not silently switch providers; failed or rejected AI cleanup can use local rules. Use your own provider credentials where required; loopback servers can work without a key.
- API keys are stored in the macOS Keychain. The provider client redacts key representations and uses content-free errors; do not include keys in issue reports.
- Transcript history stays on the Mac with no cloud sync. Retention is 30 days by default, with six-month and forever options. History Off keeps new transcripts only until Murmur quits, but does not erase existing history or disable retry audio and dictionary learning. Each entry also keeps diagnostic detail (segment scores, cleanup output, timing) in the same file. Settings can optionally keep each dictation's recording for 7 days (off by default); Delete All Data removes it.
- Audio is not kept as a permanent history. Failed dictation audio, unfinished meeting chunks and call audio waiting for speaker separation can remain locally for up to 24 hours. Expiry is enforced while Murmur runs; quitting the app does not run a background deletion service.
- Correction learning is on by default. It observes edits to the inserted span for up to a minute; in unreadable fields it can use an in-memory key observer. Disable learning or require readable fields in Settings → Dictionary. Learned spellings are saved separately from transcript history.
- Optional screen context is off by default. When enabled for AI cleanup, selected text, clipboard text and focused-window text can accompany the transcript to the chosen cleanup route.
- Meetings start only after your action. Review the capture source and notify participants before recording; meeting transcription and generated notes have separate route choices in Settings → Meetings. Cloud transcription sends meeting audio; cloud notes send transcript content and your notes.
- No transcript or audio telemetry.
- Configured builds use Sparkle for GitHub-hosted updates. Automatic installation is off by default and can be enabled in Settings. Updates wait while dictation or meeting work is active; update checks do not send transcripts, audio, dictionary entries or provider keys.

## Removing your data

Settings → History & Privacy → Delete All Data removes local dictation and meeting history, generated and personal meeting notes, retry audio, dictionary and learning data, held transcripts, and Murmur's API keys. Settings and downloaded models remain. It does not delete copies held by cloud providers, backups, or other applications.

For manual removal after quitting Murmur, including downloaded models:

```sh
# History, settings data, dictionary, learned entries and retry audio
rm -rf ~/Library/Application\ Support/Dictation
# Downloaded models
rm -rf ~/Library/Caches/Dictation
# API keys: Keychain items with service "Murmur" (repeat until it reports none found)
security delete-generic-password -s Murmur
```

The folders still use the app's old name, Dictation. App preferences are stored under the development bundle ID, `cc.clouddev.dictation.development`; `defaults delete cc.clouddev.dictation.development` removes them. To revoke permissions, remove Murmur under System Settings → Privacy & Security → Microphone, Accessibility and Input Monitoring, plus System Audio Recording if you enabled meeting capture.

## License

Murmur is released under the [MIT License](LICENSE). Third-party licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Model weights are downloaded separately and are not bundled. The upstream Parakeet and Core ML conversion cards declare different licenses; the pinned manifest does not resolve the discrepancy. Review both declarations before downloading or redistributing weights.
