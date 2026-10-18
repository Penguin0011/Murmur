# Standalone macOS feasibility spike

This is PRD milestone 0, not the dictation application. It uses native Swift, AppKit, ApplicationServices, and CoreGraphics without third-party dependencies.

Build from the repository root on macOS with the Swift command-line tools:

```sh
mkdir -p spike/.build
swiftc -module-name DictationSpike spike/Shortcut.swift spike/ShortcutChecks.swift spike/Insertion.swift spike/Observation.swift spike/main.swift -o spike/.build/dictation-spike
spike/.build/dictation-spike --check
python3 spike/check_cli.py
```

Compile without optimization: the insertion and observation self-checks use assertions. Default execution also runs checks and never accesses another app or observes keyboard events.

Read-only field inspection, with time to focus a disposable field:

```sh
spike/.build/dictation-spike --inspect --delay 3
```

Global shortcut probe:

```sh
spike/.build/dictation-spike --listen --binding right-option
spike/.build/dictation-spike --listen --binding fn
spike/.build/dictation-spike --listen --binding ctrl-option-space
spike/.build/dictation-spike --listen --listen-seconds 2
```

Use Ctrl-C to exit. The listener observes rather than consumes shortcuts (except the Space of Control-Option-Space and Escape while recording, which need Accessibility for the active tap), simulates processing, and does not capture microphone audio. Conflict detection, first-word capture, and physical Fn/Right Option behavior require further real-device evidence. Permission preflight does not request grants.

Explicit synthetic insertion and optional bounded correction observation:

```sh
spike/.build/dictation-spike --insert-test --expected-app com.apple.TextEdit --observe --delay 3
```

Focus a disposable synthetic document before the delay expires. The expected bundle ID must match the actual foreground app; internal background-window focus is insufficient. This mode inserts `Acme dictation probe` once and never sends Return or submits a message. Try replacing `Acme` with `Akme`, reverting it, appending text, and leaving the field. Diagnostics show only candidate presence, field metadata, and stop reasons; they do not print field text. Observation starts only after verified insertion with a span anchored at the original selection, since an AX write need not move the caret.

Browser fixtures are available locally:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory spike
```

Open `http://127.0.0.1:8765/fields.html` in the target browser. The page has a textarea, contenteditable rich-text field, and an empty password safety probe. It has no forms or scripts. Testing it does not establish Google Docs, Notion, or chat-app support. Stop the server with Ctrl-C after testing.

The observer polls at 100 ms for up to 60 seconds, conservatively stops on changed outside anchors or unrelated selection, and does not apply dictionary mappings. Its ledger checks demonstrate two distinct-session evidence and conflict/undo handling with a supplied eligibility rule; generic semantic eligibility remains unresolved. Transient edits between polls can be missed.

Clipboard fallback snapshots all readable pasteboard types and stages a unique ownership token with its text. It verifies focus, token, and change count before posting Command-V and restores only while token and count remain its own. NSPasteboard has no atomic compare-and-post or compare-and-restore; those remaining races need live clipboard-manager testing. The fixed 500 ms paste wait can return unverified in slower apps and never triggers an automatic retry.

Insertion and learning accept only AXTextField/AXTextArea roles. A readable AXWebArea or document root is not a supported destination. Unknown browser text-field types remain unverified and excluded from learning.

No persistent recovery store exists in this spike. Do not use real or sensitive dictated content. Production insertion must save output first. See [FEASIBILITY.md](FEASIBILITY.md) for the evidence matrix and outstanding gates.
