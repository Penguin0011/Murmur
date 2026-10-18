# Murmur

Murmur is a macOS dictation app. Press a global shortcut, speak, and Murmur types the text into the focused field. It can remove fillers, apply spoken corrections and format lists, and each of these can be turned on or off. Transcription runs locally by default with NVIDIA Parakeet Unified English through FluidAudio and Core ML. [Certain]

## Status

Pre-release source project. There is no production-signed, notarized download; build a development bundle from source. [Certain]

What works on the development Mac: shortcut → microphone → local model → insertion into the focused field, with recoverable history when insertion fails. Cleanup routes, cloud providers, API keys, the custom dictionary, correction learning and update checks are wired into the app; cloud requests still need validation with each user's provider key. [Certain] Settings includes a downloader for pinned models and also accepts an existing verified model folder. [Certain] The app also includes meeting capture, transcripts, optional speaker separation and generated notes. These features still need the live release checks described below. [Certain] Start with the [documentation guide](DOCUMENTATION.md) for current instructions and dated development records.

## Requirements

- Apple Silicon Mac (M1 or later). Intel is not supported. [Certain]
- macOS 26 or later. [Certain]
- Swift toolchain to build (the development host uses Swift 6.3.3). [Certain]
- Permissions: Microphone, Accessibility, and Input Monitoring for dictation; System Audio Recording for meeting audio from other apps. [Certain]

Only an M3 MacBook Air with 16 GB has been tested. No performance claim is made for other Macs; pick a model that suits yours. [Certain]

## Build

Install Apple Command Line Tools (`xcode-select --install`) or Xcode with a macOS 26 or newer SDK and Swift toolchain before building. [Certain]

```sh
git clone https://github.com/Penguin0011/Murmur.git
cd Murmur
app/build.sh
open runtime/Murmur.app
```

The first build needs internet access to fetch pinned FluidAudio source and its checksummed binary dependency. It does not download speech model weights. Checks and fixture commands are in [CONTRIBUTING.md](CONTRIBUTING.md) and [app/README.md](app/README.md). [Certain]

## First run

Open Settings, download the speech model (review its license first), and grant the permissions shown by the app. Local dictation needs no provider account or API key. Cloud routes are optional and require your own provider configuration. Start with a disposable text field and synthetic speech; the default shortcut is Right Option (hold to record and release to finish, or tap to start and tap again to finish). Review the shortcut and insertion options in Settings → General. [Certain]

For an isolated interface preview with synthetic data and no capture or insertion, run: [Certain]

```sh
app/check_ui.sh
```

See [SECURITY.md](SECURITY.md) for reporting and secret-scanning instructions. [Certain]

## Privacy

Cloud providers, dictionary learning, history retention and update checks are implemented. The following describes the intended data boundaries; release testing must still verify them end to end. [Certain]

- Local transcription and local cleanup are the default. Model downloads and update checks use the network; dictation in local mode should not, which release testing must still verify. [Certain]
- Cloud processing is opt-in. Settings displays the destination and data disclosure inline. Cloud transcription does not silently switch providers; failed or rejected AI cleanup can use local rules. Use your own provider credentials where required; loopback servers can work without a key. [Certain]
- API keys are stored in the macOS Keychain. The provider client redacts key representations and uses content-free errors; do not include keys in issue reports. [Certain]
- Transcript history stays on the Mac with no cloud sync. Retention is 30 days by default, with six-month and forever options. History Off keeps new transcripts only until Murmur quits, but does not erase existing history or disable retry audio and dictionary learning. [Certain]
- Audio is not kept as a permanent history. Failed dictation audio, unfinished meeting chunks and call audio waiting for speaker separation can remain locally for up to 24 hours. Expiry is enforced while Murmur runs; quitting the app does not run a background deletion service. [Certain]
- Correction learning is on by default. It observes edits to the inserted span for up to a minute; in unreadable fields it can use an in-memory key observer. Disable learning or require readable fields in Settings → Dictionary. Learned spellings are saved separately from transcript history. [Certain]
- Optional screen context is off by default. When enabled for AI cleanup, selected text, clipboard text and focused-window text can accompany the transcript to the chosen cleanup route. [Certain]
- Meetings start only after your action. Review the capture source and notify participants before recording; meeting transcription and generated notes have separate route choices in Settings → Meetings. Cloud transcription sends meeting audio; cloud notes send transcript content and your notes. [Certain]
- No transcript or audio telemetry. [Certain]
- Update checks never send transcripts, audio, dictionary entries or keys. [Certain]

## Removing your data

Settings → History & Privacy → Delete All Data removes local dictation and meeting history, generated and personal meeting notes, retry audio, dictionary and learning data, held transcripts, and Murmur's API keys. Settings and downloaded models remain. It does not delete copies held by cloud providers, backups, or other applications. [Certain]

For manual removal after quitting Murmur, including downloaded models: [Certain]

```sh
# History, settings data, dictionary, learned entries and retry audio
rm -rf ~/Library/Application\ Support/Dictation
# Downloaded models
rm -rf ~/Library/Caches/Dictation
# API keys: Keychain items with service "Murmur" (repeat until it reports none found)
security delete-generic-password -s Murmur
```

The folders still use the app's old name, Dictation. [Certain] App preferences are stored under the development bundle ID, `cc.clouddev.dictation.development`; `defaults delete cc.clouddev.dictation.development` removes them. [Likely] To revoke permissions, remove Murmur under System Settings → Privacy & Security → Microphone, Accessibility and Input Monitoring, plus System Audio Recording if you enabled meeting capture. [Certain]

## License

Murmur is released under the [MIT License](LICENSE). [Certain] Third-party licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Model weights are downloaded separately and are not bundled. The upstream Parakeet and Core ML conversion cards declare different licenses; the pinned manifest does not resolve the discrepancy. Review both declarations before downloading or redistributing weights. [Certain]
