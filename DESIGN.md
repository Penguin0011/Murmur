---
name: Murmur
description: Balanced serif-and-sans macOS window with native floating indicators
colors:
  paper: "#FAFAFA"
  ink: "#141414"
  accent: "#5995C9"
  accent-ink: "#2F6EA6"
  accent-deep: "#285F90"
  dark-paper: "#181818"
  dark-ink: "#FAFAFA"
  dark-accent-ink: "#8DB6DC"
  dark-accent-deep: "#A9C8E6"
typography:
  display:
    fontFamily: "Instrument Serif"
    fontSize: "64pt"
    fontWeight: 400
    letterSpacing: "-1.28pt"
  settings-title:
    fontFamily: "Instrument Serif"
    fontSize: "40pt"
    fontWeight: 400
    letterSpacing: "-0.8pt"
  wordmark:
    fontFamily: "Instrument Serif"
    fontSize: "28pt"
    fontWeight: 400
  body:
    fontFamily: "DM Sans"
    fontSize: "15pt"
  supporting:
    fontFamily: "DM Sans"
    fontSize: "13pt"
  navigation:
    fontFamily: "system monospace"
    fontSize: "11pt"
    letterSpacing: "0.88pt"
rounded:
  field: "4pt"
spacing:
  related: "8pt"
  controls: "12pt"
  row: "18pt"
  toggle-inset: "10pt"
  section: "28pt"
  content: "24pt"
  outer: "24pt"
  page-top: "16pt"
  header-top: "12pt"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    height: "36pt minimum"
    padding: "0 18pt"
  input:
    rounded: "{rounded.field}"
    height: "44pt"
    padding: "0 12pt"
---

# Design System: Murmur

## Overview

The user-supplied **Murmur Settings Final standalone.html**, with its active `balanced` variant, replaces the previous square paper-and-ink window direction. The native SwiftUI implementation pairs expressive serif headings with quiet sans-serif content, text navigation, blue selection underlines, and pill actions. [Certain]

This document describes the inspected source in `app/UI.swift` and `app/MeetingsUI.swift`; it does not establish pixel parity, runtime font loading, or completed accessibility validation. [Certain]

## Colors

### Primary

Blue accent supplies selection, progress, and restrained emphasis; the darker accent-ink role supplies readable accent text and active underlines. Accent-deep supplies status surfaces, and accent at 16% supplies supporting tint. [Certain]

### Neutral

Near-white paper and near-black ink define the light window. Dark appearance swaps these roles to dark paper and near-white ink, with lighter accent text roles. Supporting ink uses opacity levels of 80%, 70%, 64%, 45%, and 20%; the last is used for quiet dividers and field borders. [Certain]

Appearance is scoped to the main window with System, Light, and Dark choices; floating indicators follow the system. [Certain]

## Typography

Instrument Serif supplies the wordmark and display headings. DM Sans supplies the main window's authored body, setting titles, help, and buttons. Both fonts are registered from bundled font resources by `WindowType`; no runtime font download is requested by this code. [Certain]

Settings section titles use 40pt regular serif type and 14pt introductory text, with 6pt above and 8pt below the introduction. Other display titles retain 64pt regular serif type with tight tracking and 16pt page ledes; setting titles use 15pt semibold, and supporting copy uses 13pt with added line spacing. Navigation and eyebrows use uppercase system monospace, with tracking equal to 0.08 times the font size. [Certain]

Meetings page content and consent/notes sheets use the shared DM Sans typography; its start menu uses a 36pt ink capsule with a 14pt semibold label. The floating meeting recording panel retains system typography. The speaker settings subsection also retains some system-font labels. [Certain]

## Layout

The main window has a sparse wordmark header with a small monochrome voice mark and a trailing setup action. A 184pt text sidebar contains Home, Insights, Meetings, settings sections, and History; current phase sits at its foot. Navigation uses text rather than numbered boxes or header tabs; rows have a 36pt minimum height and 2pt gaps. [Certain]

Settings, Home, and Insights use the available content width with 24pt horizontal gutters and a 16pt top inset. The wordmark header uses the same horizontal gutter and a 12pt top inset. History uses matching outer gutters, an 80pt day column with a 16pt gap, and expanded entry content without an extra nested indent. Page titles lead each section, followed by a lede and flat setting groups. The window's declared minimum is 760×560pt. Home and Insights share the serif page hierarchy. Populated Meetings uses a 200pt inner list beside detail when its content is at least 680pt wide; below that threshold, a search field and native meeting picker sit above detail. Search constrains the selected meeting to matching results. [Certain]

Setup remains a distinct 5:7 split with 24pt insets and five numbered steps on paper, a blue underline for the selected step, and a plain monochrome voice mark. It is not evidence that every screen follows the settings composition. [Certain]

## Elevation & Depth

The main settings/history window uses flat color, spacing, rules, and occasional tint rather than authored shadows or stacked glass cards. Floating dictation status and meeting panels remain native macOS exceptions, using `UtilityGlass` or native glass capsule treatments. `UtilityGlass` falls back to an opaque system window background under Reduce Transparency or Increase Contrast. [Certain]

## Shapes

Shared action buttons are capsules with a 36pt minimum height. Text fields use a fine outline and modest 4pt corners, while switches use a rounded 44×26pt track and 22pt circular thumb. Flat dividers and underline selections retain crisp rectangular geometry. [Certain]

## Components

### Buttons

Shared actions use ink fill, ink outline, accent-ink fill, or plain text. Labels use 14pt semibold DM Sans; pressed opacity is 0.7 and disabled opacity is 0.45. Do not import web hover animations or iOS control assumptions into these native macOS controls. [Certain]

History and Meetings actions keep full labels in a horizontal row when they fit, and stack vertically when they do not. [Certain]

### Inputs / Fields

Shared text and secure fields use plain text styling, an explicit accessible label, an ink-64 placeholder overlay, horizontal padding, and a quiet border. Native pickers, checkboxes, menus, sheets, and alerts remain where the implementation uses them. [Certain]

### Navigation and choices

Active sidebar entries, segmented choices, setup steps, and Meetings detail tabs use a 2pt accent-ink underline. Sidebar entries retain uppercase monospace labels; choice labels use medium DM Sans. Selection is exposed through accessibility traits. [Certain]

### Switches

Shared toggle rows use 10pt vertical insets and retain the switch’s 40pt minimum interaction height. Rounded switches use ink when on, reduced-opacity ink when off, and a paper thumb. The custom button-backed drawing exposes a native Toggle accessibility representation. [Certain]

### Floating indicators

The recording indicator remains a nonactivating native glass surface with voice-reactive capsules and system accessibility behavior. Recovery, cancellation, learned-word notices, and the meeting recording panel retain their own existing floating layouts and system typography. Their behavior is outside this window rebuild. [Certain]

## Do's and Don'ts

- Do use the supplied balanced reference as the main window's visual authority.
- Do preserve native macOS window chrome, keyboard interaction, VoiceOver labels, and recovery paths.
- Do use serif headings, sans-serif reading text, sparse text navigation, and underlines for the rebuilt window.
- Don't restore the former square-button, numbered-sidebar system as the window default.
- Don't extend the window's custom font and paper treatment into the native floating indicators without a separate decision.
- Don't treat source inspection as rendered or functional validation.
