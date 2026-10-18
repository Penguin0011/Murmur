# Window typography

Murmur bundles Instrument Serif for display text and DM Sans for body text, so typography needs no network requests at runtime.

- [InstrumentSerif-Regular.ttf](InstrumentSerif-Regular.ttf): [upstream source](https://github.com/google/fonts/blob/main/ofl/instrumentserif/InstrumentSerif-Regular.ttf).
- [DMSans.ttf](DMSans.ttf), variable optical size and weight: [upstream source](https://github.com/google/fonts/blob/main/ofl/dmsans/DMSans%5Bopsz,wght%5D.ttf).

The corresponding SIL Open Font License notices are included beside the fonts and copied into the application bundle. `WindowType` in [UI.swift](../UI.swift) registers them for this process. [check_ui.swift](../check_ui.swift) asserts both PostScript names resolve before opening the isolated fixture.
