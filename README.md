# Murmur

Murmur is a macOS dictation app. Press a global shortcut, speak, and Murmur types the text into the focused field. It can remove fillers, apply spoken corrections and format lists, and each of these can be turned on or off. Transcription runs locally by default with NVIDIA Parakeet Unified English through FluidAudio and Core ML. [Certain]

## Status

Pre-release. Only development builds exist, and there is no signed or notarized download. [Certain]

What works on the development Mac: shortcut → microphone → local model → insertion into the focused field, with recoverable history when insertion fails. Cleanup routes, cloud providers, API keys, the custom dictionary, correction learning and update checks are wired into the app; cloud requests still need validation with each user's provider key. [Certain] The model downloader is in progress; today the model folder is chosen manually. [Certain] See [HANDOFF.md](HANDOFF.md) for open issues and [PRD.md](PRD.md) for the full requirements.

## Requirements

- Apple Silicon Mac (M1 or later). Intel is not supported. [Certain]
- macOS 26 or later. [Certain]
- Swift toolchain to build (the development host uses Swift 6.3.3). [Certain]
- Permissions: Microphone, Accessibility, and Input Monitoring. [Certain]

Only an M3 MacBook Air with 16 GB has been tested. No performance claim is made for other Macs; pick a model that suits yours. [Certain]

## Build

```sh
app/build.sh
open runtime/Murmur.app
```

The build compiles the pinned FluidAudio helper on first run. Checks and fixture commands are in [CONTRIBUTING.md](CONTRIBUTING.md) and [app/README.md](app/README.md). [Certain]

## Privacy

Summarized from [PRD.md](PRD.md) section 6. These are product rules. Rules for cloud, dictionary and update features apply once those modules are wired in.

- Local transcription and local cleanup are the default. Model downloads and update checks use the network; dictation in local mode should not, which release testing must still verify. [Certain]
- Cloud processing is opt-in, uses your own API key, and is never a silent fallback. Murmur must show what leaves the Mac before a cloud stage runs. [Certain]
- API keys are stored in the macOS Keychain and never logged. [Certain]
- Transcript history stays on the Mac with no cloud sync. Retention is 30 days by default, or six months, or forever (approved). [Certain]
- No permanent audio history. Retry audio is kept only when transcription fails, for at most 24 hours (approved). [Certain]
- No transcript or audio telemetry. [Certain]
- Update checks never send transcripts, audio, dictionary entries or keys. [Certain]

## Removing your data

A "Delete all data" action is planned. Until it ships, remove data by hand after quitting Murmur: [Certain]

```sh
# History, settings data, dictionary, learned entries and retry audio
rm -rf ~/Library/Application\ Support/Dictation
# Downloaded models
rm -rf ~/Library/Caches/Dictation
# API keys: Keychain items with service "Murmur" (repeat until it reports none found)
security delete-generic-password -s Murmur
```

The folders still use the app's old name, Dictation. [Certain] App preferences are stored under the development bundle ID, `cc.clouddev.dictation.development`; `defaults delete cc.clouddev.dictation.development` removes them. [Likely] To revoke permissions, remove Murmur under System Settings → Privacy & Security → Microphone, Accessibility and Input Monitoring. [Certain]

## License

Murmur is released under the [MIT License](LICENSE). [Certain] Third-party licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The Parakeet model is downloaded under the NVIDIA Open Model License and is not bundled. [Certain]
