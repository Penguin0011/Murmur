# Standalone macOS feasibility spike

This is PRD milestone 0, not the dictation application. It uses native Swift, AppKit, ApplicationServices, and CoreGraphics without third-party dependencies. [Certain]

Build from the repository root on macOS with the Swift command-line tools:

```sh
mkdir -p spike/.build
swiftc -module-name DictationSpike spike/Shortcut.swift spike/ShortcutChecks.swift spike/Insertion.swift spike/Observation.swift spike/main.swift -o spike/.build/dictation-spike
spike/.build/dictation-spike --check
```

Compile without optimization: the insertion and observation self-checks use assertions. Default execution also runs checks and never accesses another app or observes keyboard events. [Certain]

Read-only field inspection, with time to focus a disposable field:

```sh
spike/.build/dictation-spike --inspect --delay 3
```

Global shortcut probe:

```sh
spike/.build/dictation-spike --listen --binding right-option
spike/.build/dictation-spike --listen --binding fn
spike/.build/dictation-spike --listen --binding ctrl-option-space
```

Use Ctrl-C to exit. The listener observes rather than consumes shortcuts, simulates processing, and does not capture microphone audio. Conflict detection, first-word capture, and physical Fn/Right Option behavior require further real-device evidence. Permission preflight does not request grants. [Certain]

Explicit synthetic insertion and optional bounded correction observation:

```sh
spike/.build/dictation-spike --insert-test --observe --delay 3
```

Focus a disposable synthetic document before the delay expires. This mode inserts `Acme dictation probe` once and never sends Return or submits a message. Try replacing `Acme` with `Akme`, reverting it, appending text, and leaving the field. Diagnostics show only candidate presence, field metadata, and stop reasons; they do not print field text. Observation starts only after verified insertion with an identifiable span. [Certain]

The observer polls at 100 ms for up to 60 seconds, conservatively stops on changed outside anchors or unrelated selection, and does not apply dictionary mappings. Its ledger checks demonstrate two distinct-session evidence and conflict/undo handling with a supplied eligibility rule; generic semantic eligibility remains unresolved. Transient edits between polls can be missed. [Certain]

Clipboard fallback snapshots all readable pasteboard types, verifies focus before posting Command-V, and restores only while its staged change count remains current. NSPasteboard has no atomic compare-and-restore; that remaining race needs live clipboard-manager testing. The fixed 200 ms paste wait can return unverified in slower apps and never triggers an automatic retry. [Certain]

No persistent recovery store exists in this spike. Do not use real or sensitive dictated content. Production insertion must save output first. See [FEASIBILITY.md](FEASIBILITY.md) for the evidence matrix and outstanding gates. [Certain]
