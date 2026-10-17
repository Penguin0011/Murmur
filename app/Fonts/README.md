# Window typography

The supplied standalone design uses Instrument Serif for display text and DM Sans for body text. These original TrueType fonts ship locally so the native app needs no network requests for typography.

- InstrumentSerif-Regular.ttf: https://github.com/google/fonts/blob/main/ofl/instrumentserif/InstrumentSerif-Regular.ttf
- DMSans.ttf (variable optical size/weight): https://github.com/google/fonts/blob/main/ofl/dmsans/DMSans%5Bopsz,wght%5D.ttf

The corresponding SIL Open Font License notices are included beside the fonts and copied into the application bundle. WindowType in app/UI.swift registers them for this process. app/check_ui.swift asserts both PostScript names resolve before opening the isolated fixture.
