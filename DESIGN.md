# Dictation interface

## Direction

Native macOS 26 utility in Operate mode. The recording bubble is a temporary, nonactivating glass surface near the bottom of the destination display. Settings use the platform's ordinary grouped forms, controls, and tab navigation; history uses a selectable master/detail list. No decorative motion, marketing typography, custom widgets, or placeholder provider controls.

## Tokens

- Typography: macOS system font; body and callout for content, headline for section and state labels, caption for secondary metadata.
- Color: system primary/secondary foreground and window background; system control accent only for primary actions. Supports the system appearance.
- Spacing: 4–8 pt within text groups; 12 pt bubble spacing; 18 pt transcript group spacing; 20 pt settings/detail inset.
- Shape: 24 pt rounded rectangle for the status bubble; native system shapes for controls.
- Material: macOS 26 regular glass for the bubble. Opaque window background when Reduce Transparency or Increased Contrast is enabled.
- Elevation: one system NSPanel shadow. No shadows on form groups.
- Motion: none authored; status changes replace content immediately.

## Behavior

The bubble never becomes the key or main window and does not activate the app. Listening exposes Stop and Cancel; recoverable status exposes Copy and History. Error status exposes the recovery-audio action. History opens the History tab and selects the latest saved entry. Settings explicitly describe unavailable model downloads, cloud transcription, and cleanup instead of presenting inactive settings for those features.

## Verification boundary

UI.swift typechecks against Swift 6.3.3 with the macOS 26 SDK using the agreed controller contract. Native screenshot and live interaction inspection require the integrated app build; this document does not claim those checks passed.
