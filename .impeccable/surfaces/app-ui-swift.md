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
FIRST VIEWPORT: 1000×680 content area; 28pt serif wordmark above a 184pt text navigation column; 40pt serif settings title (64pt on other main pages) and a readable content column; active navigation and choices have a 2pt blue underline.
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


## PR #60 local interaction pass — October 16, 2026

- Minimum-size History recovery testing found truncated action labels when both raw and final text were present; the action group now falls back to a vertical stack. The matrix fixture seeds differing raw/final text, and a fresh native capture confirmed every action label is readable. Focused independent review marked this fix resolved. [Certain]
- Tested History: 7 total / 4 attention entries, unmatched search and clear, blank edits disabling Save, Escape cancel preserving the original, and Save updating final text while retaining raw text. [Certain]
- Tested Dictionary: Return adds a synthetic entry; blank preferred spelling disables Save; Escape restores the original entry. Tested API Key empty/nonempty Save states, saved actions, and empty replacement draft using a dummy value in the preview's in-memory credential store; no provider validation was invoked. [Certain]
- Tested immediate setting changes, local appearance switching, every navigation destination, setup Next/Back/direct-step selection/Finish, simulated Listening disabling settings and rejecting activation, and status dismissal preserving all seven transcripts plus the recovery-entry reference. [Certain]
- Rebuilt and signature-verified the application; rebuilt the fixture with font assertions; native History/verifier checks passed. No GitHub checks were reported for the PR at validation time. [Certain]
- Scope remains isolated native UI with synthetic data. No live microphone, transcription/provider requests, actual insertion, real Keychain validation, full VoiceOver session, installation, or merge was performed. [Certain]


## Margin refinement — October 16, 2026

The user requested less wasted space from UI margins. Use 24pt horizontal gutters, a 12pt header top inset, and 16pt page top insets. The sidebar is 184pt wide; Settings, Home, and Insights use available width without the former 640/760pt caps. History retains an 80pt date column with a smaller 16pt gap and removes the 88pt nested indent from expanded entries. Setup uses 24pt insets. Typography and control sizes remain unchanged. [Certain]

Verified this refinement with a fresh signed build and isolated native fixture at 1000×680 and 760×560, plus a zoomed window. Reviewed Settings in light/dark, History, Home, Insights, setup, and Meetings. Expanded History recovery actions remain readable and fit horizontally at the minimum size; a native toggle still updates and restores its value after resizing. Local captures use the `margins-` prefix under `.impeccable/review/`. No live dictation or installation was performed. [Certain]


## Vertical density refinement — October 16, 2026

The user requested a smaller General heading and less vertical space before/between settings. Settings titles are now 40pt (formerly 64pt), introductory text is 14pt with 6pt/8pt gaps, and shared toggle row insets are 10pt per side (formerly 18pt). General’s shortcut group, model-support row, and subgroup gaps are tighter. The existing minimum interaction height, explanatory copy, and settings bindings are preserved. [Certain]

Verified the denser settings in five native fixture captures: standard light General, compact dark General/Cleanup, and compact light Dictionary/Privacy. A native toggle switched on/off correctly and scrolling reached the final settings at minimum window size. The signed app build, signature verification, and fixture font assertions passed. No live dictation or installation was performed. [Certain]
