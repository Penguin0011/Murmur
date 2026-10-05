---
name: Dictation
description: Paper-and-ink settings window; native Liquid Glass floating indicator
rounded:
  utility: "18pt"
  bubble: "no live container / 18pt error"
spacing:
  compact: "4pt"
  related: "8pt"
  controls: "12pt"
  section: "14pt"
  inset: "18pt"
  content: "20pt"
---

# Design System: Dictation

## Overview

**Two surfaces.** The Murmur window (Settings, History, first run) uses the clouddev paper-and-ink system: flat paper, ink rules, square controls, monospaced uppercase labels and one blue accent. The floating recording indicator and error bubble stay native Liquid Glass (see the last section).

## Colors

**Logo.** Five bars rise and fall like a voice, loud and soft in turn: ink on accent, with the accent square as the full stop. `Logo` (app/UI.swift) holds the bars on a 96-unit grid and draws the one-colour menu bar mark (a template image, so it follows the menu bar tint) and the full-colour mark (literal #141414 bars on accent) for the window header and, outlined in ink and tilted 1.5°, the first-run panel. The app icon is `app/AppIcon.icns`, the rounded-square variant on the macOS 824-in-1024 grid; regenerate it with `swift app/tools/make_icon.swift`.

Window tokens live in `Palette` (app/UI.swift), copied from the clouddev design system: paper #F4F2ED, ink #141414 with 80/70/64/45/20% alphas, accent #5995C9 (fills, toggles, underlines, logo), accent-ink #2F6EA6 (accent text, 4.8:1 on paper), accent-deep #285F90 (pressed fills, tags) and accent at 16% (notes, tags, setup panel). Settings → General → Appearance switches the window between Light (default) and Dark, stored in UserDefaults as `appearance`. Dark swaps paper and ink and lifts accent-ink to #8DB6DC and accent-deep to #A9C8E6. Only the Murmur window changes: the floating indicator keeps following the system appearance.

## Typography

System font in place of Archivo (not bundled): 36–56 pt bold with tight tracking for titles, 16–18 pt semibold row titles, 14 pt secondary text at ink 70%. Eyebrows, the sidebar, tabs, status words and tags use the system monospaced font, uppercase, tracked 0.08 em.

## Layout

A 64 pt header holds the full-colour mark and wordmark (name plus accent square), Settings/History tabs with an accent underline, the transcription route and the current phase. Ink banners below it carry the status message (with Dismiss) and an unfinished-setup prompt. Settings is a 216 pt numbered sidebar (General, Transcription, Cleanup, Dictionary, History & Privacy, API Keys, Updates) beside a 640 pt content column. History groups transcripts by day; a row expands to its note, final and raw text, and Copy/Delete. First run is a 5:7 split: accent panel with the full-colour mark, then four numbered steps. The default window is 1000 × 680 pt, minimum 760 × 560.

## Shapes and controls

Everything is square. Borders are 1.5 pt ink (strong) or 1 pt ink 20% (row dividers). Buttons and segments are 44 pt tall: filled ink, outlined ink, or accent-ink for Save Key. Toggles are a 48 × 24 pt bordered box with a 17 pt ink knob and accent fill when on, exposed to VoiceOver as native toggles. No glass, blur or shadow inside the window.

## Do's and Don'ts

- Do keep every setting applying as soon as it changes, and disable editing while dictating.
- Do keep disclosures (what leaves this Mac) next to the route that sends it.
- Don't add colors beyond the palette; errors use ink banners, not orange.
- Don't put glass controls inside the floating glass bubble.

## Compact floating indicators

Recording and processing always use a 80×24-point transparent panel containing five standalone voice-reactive native glass circles. Processing becomes static with Reduce Motion. The phase remains an accessibility label; the shortcut controls finish/cancel. Saved output and successful insertion hide the panel. Error messages use a 240-point maximum panel, a clickable short summary and conditional Audio, with no close button: every status leaves on its own (no speech 2 s, other errors 8 s, everything else 5 s), as does the matching Settings banner. Settings retain full error details; History retains delivery results and copy controls. [Certain]
