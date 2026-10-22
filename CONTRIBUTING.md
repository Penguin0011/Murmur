# Contributing to Murmur

Murmur is pre-release. Use the root [README](README.md) for visitor setup and privacy information.

## Requirements

- An Apple Silicon Mac running macOS 26 or later, with Xcode Command Line Tools or Xcode and Swift 6.0 or later for the pinned helper package. The app compiles in Swift 5 language mode.
- Python 3 for the corpus and model scripts.
- Foundation-only modules and their checks also build on Linux; they were last checked with Swift 6.1.2.

## Build

Run commands from the repository root. The first build needs internet access to fetch the pinned FluidAudio package and Sparkle archive. It does not download speech model weights.

```sh
app/build.sh
open runtime/Murmur.app
```

`build.sh` builds the pinned `ModelBench` helper (incrementally, every run), compiles the app with `-swift-version 5`, and signs both executables with Hardened Runtime. Development builds use `clouddev Development` if present, otherwise ad hoc; release builds use the audio-input entitlement, while development builds also disable library validation so the local signing identity can load Sparkle. Set `MURMUR_SIGN_IDENTITY` to use another identity; a stable identity keeps macOS permissions across rebuilds.

For distribution, first configure the update feed and public key described in [update packaging](app/UPDATES.md). `MURMUR_RELEASE=1` also requires a valid Developer ID Application identity and an existing notarytool Keychain profile. It signs with secure timestamps, submits for notarization, staples and validates the ticket, and runs Gatekeeper assessment; any failed step stops the build.

```sh
MURMUR_RELEASE=1 \
  MURMUR_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAM_ID)' \
  MURMUR_NOTARY_PROFILE='your-existing-notary-profile' app/build.sh
```

`runtime/` and `spike/.build/` are ignored by Git. Do not commit audio, transcripts, model files or API keys.

## Documentation

Keep tracked documentation useful to users or contributors: setup, privacy, security reporting, licensing, maintained tool instructions and reproducible measurements with limitations. Keep conversation logs, agent handoffs, local installation evidence and private audits outside the repository. Moving a tracked file or adding it to `.gitignore` does not make it private; deleted files remain in Git history.

## Publication checks

Run the redacted secret scans in [SECURITY.md](SECURITY.md) before sharing a branch or making a release. Review all fetched branches and PR refs, and hosted content separately before changing repository visibility. Keep private audit evidence outside this tree.

## Checks

The commands in this section use offline or loopback synthetic checks; they do not record audio, insert text or inject keys. Run the ones that cover your change, and all of them before a release. Commands below run from the repository root. When using Command Line Tools with its macOS 27 SDK, select its macOS 26 SDK if available, as the build scripts do:

```sh
# In the same shell used for the swiftc checks below.
murmur_sdk26="$(dirname "$(xcrun --show-sdk-path)")/MacOSX26.sdk"
if [ -z "${SDKROOT:-}" ] && [ -d "$murmur_sdk26" ]; then export SDKROOT="$murmur_sdk26"; fi
```

App, history and controller (macOS):

```sh
swiftc app/LaunchOptions.swift app/check_launch.swift -o /tmp/dictation-launch-check && /tmp/dictation-launch-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/Cleanup.swift app/History.swift app/check_history.swift -o /tmp/dictation-history-check && /tmp/dictation-history-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift spike/Observation.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Insights.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/ModelDownload.swift app/Updates.swift app/AppUpdater.swift app/AppServices.swift app/Routes.swift app/AppleCleanup.swift app/UI.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/MeetingsUI.swift app/CallDetection.swift app/CallOfferUI.swift app/check_controller.swift -o /tmp/dictation-controller-check && /tmp/dictation-controller-check
swiftc -swift-version 5 spike/Shortcut.swift spike/Insertion.swift spike/Observation.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Insights.swift app/Controller.swift app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/ModelDownload.swift app/Updates.swift app/AppUpdater.swift app/AppServices.swift app/Routes.swift app/AppleCleanup.swift app/UI.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/MeetingsUI.swift app/CallDetection.swift app/CallOfferUI.swift app/check_meeting_start.swift -o /tmp/murmur-meeting-start-check && /tmp/murmur-meeting-start-check
swiftc spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/check_recording.swift -o /tmp/murmur-recording-check && /tmp/murmur-recording-check
swiftc -swift-version 5 spike/Shortcut.swift module-one/capture/Capture.swift module-one/session/Session.swift app/History.swift app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/Cleanup.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/MeetingCapture.swift app/MeetingRecorder.swift app/check_speaker_flow.swift -o /tmp/murmur-speaker-flow-check && /tmp/murmur-speaker-flow-check
```

Foundation-only modules (macOS or Linux):

```sh
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/cd && /tmp/cd
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_processing.swift -o /tmp/murmur-processing-check && /tmp/murmur-processing-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_modes.swift -o /tmp/murmur-modes-check && /tmp/murmur-modes-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift spike/Observation.swift app/check_apple_cleanup.swift -o /tmp/murmur-apple-check && /tmp/murmur-apple-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/AppleCleanup.swift app/check_routes.swift -o /tmp/murmur-routes-check && /tmp/murmur-routes-check
swiftc app/Cleanup.swift app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-providers-check && /tmp/murmur-providers-check
python3 app/check_http.py
swiftc app/Updates.swift app/check_updates.swift -o /tmp/murmur-updates-check && /tmp/murmur-updates-check
swiftc app/Insights.swift app/check_insights.swift -o /tmp/murmur-insights-check && /tmp/murmur-insights-check
swiftc app/Retention.swift app/Cleanup.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/check_meetings.swift -o /tmp/murmur-meetings-check && /tmp/murmur-meetings-check
swiftc app/Retention.swift app/Cleanup.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/CallDetection.swift app/check_call_detection.swift -o /tmp/murmur-detection-check && /tmp/murmur-detection-check
swiftc app/Retention.swift app/Cleanup.swift app/Meetings.swift app/MeetingNotes.swift app/MeetingSpeakers.swift app/check_speakers.swift -o /tmp/murmur-speakers-check && /tmp/murmur-speakers-check
swiftc -swift-version 5 app/ModelDownload.swift app/check_model_download.swift -o /tmp/murmur-model-check && /tmp/murmur-model-check
python3 app/tools/check_update_config.py
swiftc app/Retention.swift app/ModelDownload.swift app/Updates.swift app/AppServices.swift app/check_app_services.swift -o /tmp/murmur-app-services-check && /tmp/murmur-app-services-check
swiftc module-one/models/Runner/Sources/ModelBench/BoostFilter.swift app/check_boost_filter.swift -o /tmp/murmur-boost-check && /tmp/murmur-boost-check
python3 app/tools/build_cleanup_corpus.py
swiftc app/Cleanup.swift app/check_cleanup.swift -o /tmp/cc && /tmp/cc app/cleanup-corpus.json
```

Visual fixture (macOS, temporary storage, no capture or insertion):

```sh
app/check_ui.sh
app/check_ui.sh --light --compact --opaque
app/check_ui.sh --settings-search --sidebar-collapsed --snapshot /tmp/murmur-search-dark.png
app/check_ui.sh --settings-search --light --compact --snapshot /tmp/murmur-search-light.png
app/check_ui.sh --paste-failed --bubble-only
app/check_ui.sh --undo --bubble-only
app/check_ui.sh --light --insights
app/check_ui.sh --history-off
app/check_ui.sh --guide 4
app/check_ui.sh --meetings --compact --light
app/check_ui.sh --meeting-live
app/check_ui.sh --meetings --meeting-notes --meeting-settings --never --light --speaker-settings --ready
app/check_ui.sh --call-offer --saved --bubble-only
app/check_ui.sh --meetings --speakers --meeting-notes
app/check_ui.sh --meetings --separating
```

Additional fixture flags and their side effects are described in [app/README.md](app/README.md). Standalone checks are in the [insertion spike](spike/README.md), [capture probe](module-one/capture/README.md), [capture session](module-one/session/README.md), and [model tooling](module-one/models/README.md) guides. A synthetic fixture is not live capture, insertion, or provider evidence.

## Conventions

These are the patterns in the existing code and docs.

- Native Swift with Apple frameworks (Foundation, AppKit, SwiftUI, AVFoundation, Security). FluidAudio is the pinned Swift package; Sparkle is a separately pinned framework archive. Keep new logic Foundation-only where possible, so its checks run on Linux too.
- Small concrete types per concern (one file per module, such as `Cleanup.swift` or `Providers.swift`), not a plugin framework.
- Checks are standalone executables named `check_<module>.swift`, compiled with `swiftc` next to the files they test. They exit non-zero on failure and need no external network, real keys or microphone; `check_http.py` uses a loopback server with synthetic data.
- Code must compile under `-swift-version 5`, which `build.sh` uses.
- Treat dictated text as untrusted data. Never log transcript text, API keys or response bodies; error reasons are content-free enums.
- Store API keys only in the Keychain. Never send transcripts, audio, dictionary entries or keys in update checks.
- Keep transcription routes fixed on failure. Preserve the Gemini cleanup failover and guarded local fallback described in [provider integration](app/PROVIDERS.md); do not add model or provider substitutions without an explicit product decision.
- Document claims with evidence. In Markdown docs, distinguish measured results from assumptions and keep prose plain and short. Report device results only for the configuration actually measured.

## Commits

- Make small logical commits after each working checkpoint.
- Use Conventional Commit subjects: `type(scope): summary`, imperative and lowercase, such as `feat(cleanup): add …`, `fix(ui): …`, `docs(providers): …`, `test: …`, `refactor(app): …`. The scope is optional.
- Merge commits describe what is merged in plain words, such as "Merge cloud providers, Keychain credentials and GitHub update checker".
- Write commit messages as a human and do not add Codex co-author trailers.

## Licensing

Murmur's source is MIT licensed ([LICENSE](LICENSE)); contributions are accepted under the same license. Add any new dependency or model to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) after checking its license at the pinned version.

Sparkle builds and release asset preparation are documented in [app/UPDATES.md](app/UPDATES.md). Public updates need an accessible GitHub feed and the existing production signing key; Developer ID signing and notarization are separate release steps.
