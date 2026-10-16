# Contributing to Murmur

Murmur is pre-release. Read [PRD.md](PRD.md) for requirements and [HANDOFF.md](HANDOFF.md) for current state and open issues before starting. [Certain]

## Requirements

- An Apple Silicon Mac running macOS 26, with the Swift toolchain (the development host uses Swift 6.3.3). [Certain]
- Python 3 for the corpus and model scripts. [Certain]
- Foundation-only modules and their checks also build on Linux; they were last checked with Swift 6.1.2. [Certain]

## Build

```sh
app/build.sh
open runtime/Murmur.app
```

`build.sh` builds the pinned `ModelBench` helper (incrementally, every run), compiles the app with `-swift-version 5`, and signs both executables with Hardened Runtime. Development builds use `clouddev Development` if present, otherwise ad hoc; the app has only the audio-input entitlement. Set `MURMUR_SIGN_IDENTITY` to use another identity; a stable identity keeps macOS permissions across rebuilds. [Certain]

For distribution, `MURMUR_RELEASE=1` requires a valid Developer ID Application identity and an existing notarytool Keychain profile. It signs with secure timestamps, submits for notarization, staples and validates the ticket, and runs Gatekeeper assessment; any failed step stops the build. [Certain]

```sh
MURMUR_RELEASE=1 \
  MURMUR_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
  MURMUR_NOTARY_PROFILE='your-existing-notary-profile' app/build.sh
```

`runtime/` and `spike/.build/` are ignored by Git. Do not commit audio, transcripts, model files or API keys. [Certain]

## Checks

None of these record audio, insert text or inject keys. Run the ones that cover your change, and all of them before a release. [Certain]

App, history and controller (macOS):

```sh
swiftc app/LaunchOptions.swift app/check_launch.swift -o /tmp/dictation-launch-check && /tmp/dictation-launch-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/check_history.swift -o /tmp/dictation-history-check && /tmp/dictation-history-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift spike/Observation.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Insights.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Routes.swift app/AppleCleanup.swift app/UI.swift app/Meetings.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/MeetingsUI.swift app/check_controller.swift -o /tmp/dictation-controller-check && /tmp/dictation-controller-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/check_recording.swift -o /tmp/murmur-recording-check && /tmp/murmur-recording-check
swiftc -swift-version 5 spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Meetings.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/check_speaker_flow.swift -o /tmp/murmur-speaker-flow-check && /tmp/murmur-speaker-flow-check
```

Foundation-only modules (macOS or Linux):

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_modes.swift -o /tmp/murmur-modes-check && /tmp/murmur-modes-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift spike/Observation.swift app/check_apple_cleanup.swift -o /tmp/murmur-apple-check && /tmp/murmur-apple-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift app/check_routes.swift -o /tmp/murmur-routes-check && /tmp/murmur-routes-check
swiftc app/Cleanup.swift app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-providers-check && /tmp/murmur-providers-check
python3 app/check_http.py
swiftc app/Updates.swift app/check_updates.swift -o /tmp/murmur-updates-check && /tmp/murmur-updates-check
swiftc app/Insights.swift app/check_insights.swift -o /tmp/murmur-insights-check && /tmp/murmur-insights-check
swiftc app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/check_meetings.swift -o /tmp/murmur-meetings-check && /tmp/murmur-meetings-check
swiftc app/Retention.swift app/Meetings.swift app/MeetingSpeakers.swift app/check_speakers.swift -o /tmp/murmur-speakers-check && /tmp/murmur-speakers-check
swiftc app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/check_app_services.swift -o /tmp/murmur-app-services-check && /tmp/murmur-app-services-check
swiftc module-one/models/Runner/Sources/ModelBench/BoostFilter.swift app/check_boost_filter.swift -o /tmp/murmur-boost-check && /tmp/murmur-boost-check
python3 app/tools/build_cleanup_corpus.py
swiftc app/Cleanup.swift app/check_cleanup.swift -o /tmp/cc && /tmp/cc app/cleanup-corpus.json
```

Visual fixture (macOS, temporary storage, no capture or insertion):

```sh
app/check_ui.sh
app/check_ui.sh --light --compact --opaque
app/check_ui.sh --paste-failed --bubble-only
app/check_ui.sh --undo --bubble-only
app/check_ui.sh --light --insights
app/check_ui.sh --history-off
app/check_ui.sh --guide 4
app/check_ui.sh --meetings --compact --light
app/check_ui.sh --meeting-live
app/check_ui.sh --meetings --speakers
app/check_ui.sh --meetings --separating
app/check_ui.sh --meeting-settings --speaker-settings --ready
```

These commands come from [app/README.md](app/README.md), which lists every fixture flag and is the source of truth if they drift. Spike and model checks are in `spike/README.md` and `module-one/*/README.md`. [Certain]

## Conventions

These are the patterns in the existing code and docs. [Likely]

- Native Swift with Apple frameworks (Foundation, AppKit, SwiftUI, AVFoundation, Security). No third-party Swift packages besides the pinned FluidAudio runtime. Keep new logic Foundation-only where possible, so its checks run on Linux too.
- Small concrete types per concern (one file per module, such as `Cleanup.swift` or `Providers.swift`), not a plugin framework (PRD section 7).
- Checks are standalone executables named `check_<module>.swift`, compiled with `swiftc` next to the files they test. They exit non-zero on failure and need no external network, real keys or microphone; `check_http.py` uses a loopback server with synthetic data. [Certain]
- Code must compile under `-swift-version 5`, which `build.sh` uses.
- Treat dictated text as untrusted data. Never log transcript text, API keys or response bodies; error reasons are content-free enums.
- Store API keys only in the Keychain. Never send transcripts, audio, dictionary entries or keys in update checks.
- No silent cloud fallback and no silent model or provider substitution.
- Document claims with evidence. In Markdown docs, end each factual claim with [Certain], [Likely] or [Guessing], and keep prose plain and short. Report device results only for the configuration actually measured.

## Commits

- Make small logical commits after each working checkpoint. [Certain]
- Use Conventional Commit subjects: `type(scope): summary`, imperative and lowercase, such as `feat(cleanup): add …`, `fix(ui): …`, `docs(providers): …`, `test: …`, `refactor(app): …`. The scope is optional. [Certain]
- Merge commits describe what is merged in plain words, such as "Merge cloud providers, Keychain credentials and GitHub update checker". [Certain]
- If an agent wrote the change, end the message with its `Co-Authored-By:` trailer. [Certain]

## Licensing

Murmur's source is MIT licensed ([LICENSE](LICENSE)); contributions are accepted under the same license. Add any new dependency or model to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) after checking its license at the pinned version. [Certain]
