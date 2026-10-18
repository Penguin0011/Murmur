# App development

See the [main README](../README.md) for requirements, setup, privacy and data removal, and [CONTRIBUTING.md](../CONTRIBUTING.md) for build, signing and check commands. Run commands from the repository root.

## Source map

- `Controller.swift` coordinates recording, processing, delivery and recovery.
- `Processing.swift`, `Cleanup.swift`, `Dictionary.swift` and `Learning.swift` handle text processing and correction learning. [Vocabulary routing](VOCABULARY.md) describes the transcription safeguards.
- `Providers.swift`, `Credentials.swift` and `Routes.swift` handle optional cloud processing and Keychain credentials. See [provider integration](PROVIDERS.md).
- `History.swift`, `Retention.swift` and `AppServices.swift` handle local storage, retention and data removal.
- `ModelDownload.swift` verifies and installs pinned model artifacts; `Updates.swift` checks releases.
- `Meetings.swift`, `MeetingRecorder.swift`, `MeetingCapture.swift`, `MeetingNotes.swift` and `MeetingSpeakers.swift` implement meeting capture, transcription, notes and speaker separation.
- `UI.swift`, `MeetingsUI.swift` and `CallOfferUI.swift` provide the interface.

Save recoverable text before attempting insertion. Never automatically retry an uncertain paste or send Return. Keep API keys and transcript contents out of logs. Test secure fields, permission loss, clipboard ownership and storage failures when changing these paths; synthetic checks do not establish live cross-app reliability.

## Interface fixtures

For isolated empty-history visual inspection, run the executable directly:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --preview
```

Preview disables shortcut capture and uses temporary history/retry storage. Permission buttons and settings controls are real controls; inspecting preview does not require using them. Prefer `app/check_ui.sh` for a synthetic fixture with an in-memory credential store; `--preview` is not a general sandbox for every setting or Keychain control.

`check_ui.sh` builds and runs the synthetic visual fixture with temporary storage, synthetic transcripts, and an error bubble. It performs no capture or insertion; dismissal asserts that recovery history remains. The fixture has a working Quit menu and closes its temporary storage on normal exit.

```sh
app/check_ui.sh
app/check_ui.sh --light
app/check_ui.sh --light --compact --opaque
app/check_ui.sh --bubble-only
app/check_ui.sh --credential-warning --recovery --bubble-only
app/check_ui.sh --listening --bubble-only
app/check_ui.sh --processing --bubble-only
app/check_ui.sh --saved --bubble-only
app/check_ui.sh --saved --learned --keep-notice --bubble-only
app/check_ui.sh --custom-transcription
app/check_ui.sh --light --dictionary
app/check_ui.sh --paste-failed --bubble-only
app/check_ui.sh --undo --bubble-only
app/check_ui.sh --not-pasted --bubble-only
app/check_ui.sh --listening --live-words --bubble-only
app/check_ui.sh --light --insights
app/check_ui.sh --insights --tall
app/check_ui.sh --history-off
app/check_ui.sh --empty --insights
app/check_ui.sh --light --guide 1
app/check_ui.sh --guide 4
app/check_ui.sh --settings --system-appearance
app/check_ui.sh --meetings --light
app/check_ui.sh --meetings --compact --light
app/check_ui.sh --meeting-live
app/check_ui.sh --call-offer --saved --bubble-only
app/check_ui.sh --meeting-settings --never --light
app/check_ui.sh --meeting-live --collapsed
app/check_ui.sh --consent
app/check_ui.sh --meetings --meeting-notes --light
app/check_ui.sh --meetings --meeting-notes --outdated --tall
app/check_ui.sh --meetings --transcript --compact --light
app/check_ui.sh --meetings --notes-choice
app/check_ui.sh --meeting-settings --tall
```

`--meetings` seeds two synthetic meetings (one with hidden echo, one with leftover parts) and opens Meetings. `--meeting-live` also shows the live panel with a synthetic recording; with `--snapshot` it renders the panel, whose glass draws transparent offscreen. `--call-offer` shows Zoom's detection offer and `--call-offer-browser` Arc's; `--never` seeds the Never list shown with `--meeting-settings`. `--consent` opens the one-time consent sheet; quit it from the menu, since `--snapshot` does not close a sheet. `--meeting-notes` gives the first meeting synthetic notes and opens its Notes tab; `--outdated` marks them out of date. `--transcript` opens the Transcript tab instead. `--notes-choice` opens the first-Stop notes route question; like `--consent`, quit it from the menu. `--meeting-settings` opens Settings → Meetings with the meeting transcription and notes routes.

The window opens on Home. `--insights` seeds timed dictations into four apps over 24 days and opens Insights; with `--empty` it shows the empty state, and `--history-off` shows the History-off state. `--guide STEP` opens the welcome guide at step 0–4; without it the fixture marks the guide finished. `--settings` opens Settings, `--tall` makes the window 1100 points tall where the screen allows, and `--system-appearance` stores System (or, with `--light` or `--dark`, that choice) without forcing the app's appearance, so the bubble follows macOS. `--snapshot PATH` renders the window offscreen to a PNG and quits, which works while the screen is locked.

`--live-words` with `--listening` shows the live-words bubble with a synthetic preview. `--paste-failed` shows the paste-failure card with a synthetic three-line text, and `--not-pasted` the same card for a dictation saved with Insert at the cursor off; `--undo` shows the Undo card without its 5-second timer. Settings → General shows the shortcut recorder, the sounds toggle and the Automatic microphone option without a flag.

`--dictionary` seeds three sample entries (one turned off); open Settings → Dictionary to see them. The fixture forces only its own appearance. `--compact` uses the minimum production window size, while `--opaque` forces the same opaque rendering branch used by Reduce Transparency for the settings/History view. The separately hosted floating bubble continues to use actual system accessibility settings.

`--matrix` seeds the History delivery and held-result states in temporary storage, including one session-only row; `--empty` seeds no entries. `--light` sets both the fixture window and Settings appearance.

The developer audio probe requires both flags and must target a disposable field:

```sh
runtime/Murmur.app/Contents/MacOS/Murmur --test-audio /absolute/synthetic.wav --expected-app com.apple.TextEdit
```

This explicitly performs transcription and one insertion attempt. It preserves the supplied audio and uses temporary isolated history, retry audio, and dictionary storage, removed on exit. It does not modify the user's history or dictionary or use saved API keys. It cannot be combined with preview or timed quit; malformed flags exit before storage/UI initialization.
