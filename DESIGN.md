---
name: Dictation
description: Native macOS Liquid Glass utility
rounded:
  utility: "18pt"
  bubble: "24pt"
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

**Creative North Star: "Native glass, calm content"**

Native macOS Liquid Glass lifts status and actions above calm, readable content. Settings retain native forms and navigation; History keeps a selectable list and readable transcript detail. [Certain]

**Key Characteristics:**

- System typography and semantic colors. [Certain]
- Glass for status, search, and actions; opaque reading surfaces. [Certain]
- Nonactivating recording bubble with explicit recovery. [Certain]

## Colors

Primary foreground, the system accent, and NSColor.windowBackgroundColor adapt to appearance. Authored supporting text, metadata, and the search prompt use Color.primary.opacity(0.72); selected History rows use full primary. Model attention text uses full primary, while the status error icon uses orange. These are native semantic values, not fixed CSS colors; their source definitions live in the sidecar's nativeMacOS extension. [Certain]

## Typography

Use SwiftUI's system roles: largeTitle with semibold weight for the window title; title2 with semibold weight for History; headline for status and transcript labels; callout for explanations; caption for metadata. Prominent glass action labels use the system font at 14 pt bold with white foreground applied inside the actual Text/Label over the native control accent; opaque prominent buttons retain platform styling. No custom font family is authored. [Certain]

## Layout

The window uses a transparent titlebar with its native title hidden, a header, and native tab navigation above Settings/History. Settings separates persistent status and actions from its scrollable grouped form. History separates search, master/detail content, transcript actions, and refresh/delete controls. Content insets and spacing use the frontmatter scale; list/detail dimensions remain native extension values. [Certain]

The bubble is centered above the destination display's bottom edge. Its message wraps; recovery controls switch from a horizontal row to a vertical stack when space is insufficient. [Certain]

## Elevation & Depth

UtilityGlass uses native regular glass on the local-transcription badge, Settings status, History search, and the recording bubble. UtilityButton uses native glass/glassProminent styles for standalone actions, grouped in GlassEffectContainer. Native TabView owns navigation appearance. Grouped forms and transcript reading content do not receive a custom glass layer. [Certain]

**The One Glass Layer Rule.** Keep the bubble's own controls bordered; never place glass buttons inside its glass surface.

Reduce Transparency or Increased Contrast replaces utility glass with window background color and glass buttons with bordered/borderedProminent styles. The isolated visual fixture can force this same opaque branch through utilityOpaquePreview without changing system accessibility preferences. The floating NSPanel uses its native shadow. No authored animations or synthetic blur/shadow stack are present. [Certain]

## Shapes

Utility surfaces and the bubble use the frontmatter radii. Buttons, tabs, lists, and grouped forms retain platform-owned shapes. [Certain]

## Components

- **Status:** a semantic icon, state label, wrapping message, and idle dismiss action above the form. [Certain]
- **Settings:** native grouped controls, model-file status, separate permission rows, disabled editing while busy, and persistent Apply/Refresh actions. [Certain]
- **History:** a native sidebar list, delivery labels/icons, searchable raw/final text, selectable transcript text, and persistent Copy/Delete actions. Recovery opens the correct entry and clears search. [Certain]
- **Search:** a plain text field inside utility glass with a labeled clear action. [Certain]
- **Bubble:** a nonactivating NSPanel with Stop/Cancel during recording and Copy/History/Settings/available audio recovery when idle. Dismiss preserves recovery data. [Certain]

## Do's and Don'ts

- Do use native glassEffect and system button styles.
- Do keep transcripts and grouped settings readable on calm surfaces.
- Do provide opaque fallbacks and explicit labels for icon actions.
- Don't imitate glass with custom blur, gradients, or extra shadows.
- Don't stack glass cards or put glass controls inside a glass bubble.
- Don't replace system type or semantic colors with hard-coded approximations.


Implementation values are extracted from app/UI.swift and app/main.swift. Integrated source compilation passed. The lead captured the dark floating bubble and clicked its native Dismiss control; the fixture asserted that synthetic recovery history remained. Light, dark, and forced opaque compact captures were reviewed. The scoped contrast review resolved its findings; the explicit search placeholder overlay measures approximately 5.8:1 in the captured light appearance. These checks do not establish real destination focus, physical recording, or live insertion behavior. [Certain]
