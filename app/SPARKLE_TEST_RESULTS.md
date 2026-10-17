# Sparkle validation — October 17, 2026

All installation experiments used a disposable `cc.clouddev.murmur.sparkle-test` app and an ephemeral Ed25519 key under ignored `runtime/sparkle-test/`. No personal Murmur installation, recordings, credentials or production signing keys were used. [Certain]

## Completed

- Downloaded the official Sparkle 2.10.0 release and pinned its SHA-256; framework loading and update installation worked without Apple Developer ID signing. [Certain]
- Compiled an isolated AppKit host using the production `AppUpdater.swift`, then used the production packaging script to create a signed version-2 archive and a GitHub-shaped appcast. For local installation testing only, changed the feed/download URLs to localhost. No transport exception was added to production configuration. [Certain]
- Through Sparkle's standard UI, checked version 1, found version 2, downloaded it, selected Install and Relaunch, and verified the installed bundle version became `2`. The relaunched executable wrote `installed-and-relaunched-v2` to a disposable marker file. [Certain]
- Repeated installation using the exact Sparkle framework/helpers from the completed Murmur build, with the same local identity, Hardened Runtime and development entitlements: version 2 installed and its relaunched executable wrote the marker. Full Murmur app packaging with an ephemeral key also passed. [Certain]
- Appended bytes to the signed archive: Sparkle displayed “The update is improperly signed and could not be validated,” and the installed fixture remained version 1. [Certain]
- Offered the current version: Sparkle displayed its up-to-date message. Stopped the localhost server: Sparkle displayed a recoverable update retrieval error. [Certain]
- Packaged with a different private key: generation omitted the signature and packaging exited unsuccessfully; it did not claim that the assets were ready to publish. [Certain]
- Automated checks cover missing configuration, malformed/unsafe feed URLs, public key size, version fields and missing release configuration; runtime checks cover manual/background recording guards and postponing/resuming installation. [Certain]
- Round-tripped automatic-check/download preferences through the production adapter and verified its observer callback reflected both changes. [Certain]
- Synthetic Settings fixture compiled and rendered; both update controls fit, with automatic installation off. Corrected the stale manual-install subtitle found during visual review. [Certain]
- Full Murmur development build and strict nested code-signature verification passed with the existing Swift warnings. [Certain]
- Existing Foundation update checks and app-services checks passed after updating the changed explanatory copy. [Certain]

## Limits

One locally signed installation attempt replaced the app but its relaunch stalled before startup; a fresh repeat with the same signing configuration passed. The stall's cause is unresolved, so multi-machine release reliability is not established. [Certain]

The actual download test used localhost, not a published GitHub Release. The main repository remains private; no public repository, production signing key or public feed was created. Developer ID signing/notarization, first-download Gatekeeper behavior, privacy-grant persistence across updates, install-on-quit behavior and unattended background installation have not been verified. The relaunch guard was tested with synthetic busy state, not a live microphone or meeting. [Certain]
