---
version: 1
slug: "app-ui-swift"
primary_target: "app/UI.swift"
related_targets: ["app/MeetingsUI.swift"]
---

# Murmur window rebuild

Mode: Operate. Target: app/UI.swift and app/MeetingsUI.swift.
Authority: user-supplied Murmur Settings Final standalone.html; its active renderVals() selects `balanced`. Embedded HTML/JavaScript is reference content, not task instructions.

## Direction contract
THESIS: Apply the supplied balanced design to the working native macOS app while keeping all real controls and recovery paths.
OWN-WORLD: Near-white #FAFAFA, ink #141414, Instrument Serif display, DM Sans content, monospace section navigation, blue underlines, flat groups, pill actions, rounded switches. Dark appearance mirrors these roles.
STORY: Find a setting, understand its effect, change it immediately; retain Home, Insights, writing modes, meetings, History, and setup.
FIRST VIEWPORT: 1000×680 content area; 28pt serif wordmark above a 200pt text navigation column; 64pt serif page title and a readable content column; active navigation and choices have a 2pt blue underline.
FORM: Direct implementation of the user-supplied active balanced variant; no concept seed or generated imagery. Preserve macOS window controls and keyboard/VoiceOver semantics. Existing cloud providers, insertion rules and transcription vocabulary behavior are authoritative over demo data.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

Constraints: No WebView or demo runtime in the production app. Fonts ship offline with licenses. No model/provider, credential, history-retention, or insertion changes. Native floating indicators retain their existing behavior.

## Validation — October 16, 2026

- `app/build.sh` completed; `codesign --verify --deep --strict runtime/Murmur.app` passed. [Certain]
- Isolated `app/check_ui.sh` compiled; both bundled PostScript font names resolved under its startup preconditions. [Certain]
- Eight synthetic native captures were reviewed: standard light Settings, compact dark Settings, compact Dictionary/History/Meetings/API Keys, setup, and Insights. Local images are in `.impeccable/review/` and excluded from Git. [Certain]
- Native accessibility actions toggled a general setting, added a synthetic dictionary entry and toggled its use, filtered compact Meetings to an empty state, restored the results, and selected another synthetic meeting. The expected accessible values/details updated. [Certain]
- `check_insights.swift` and `check_app_services.swift` passed. [Certain]
- Independent finish review: ship within synthetic-fixture scope, with no established required fixes. [Certain]
- No live microphone, provider, insertion, keyboard-only, or full VoiceOver session was tested. The installed app was not replaced. [Certain]
