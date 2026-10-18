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

The initial download tests used localhost. The public GitHub smoke test below supersedes that transport limitation. At that checkpoint no permanent production signing key or stable release feed had been configured. The publication-preparation section below supersedes key setup, isolated microphone-grant persistence and background install-on-quit coverage. Developer ID signing/notarization and full-app first-download Gatekeeper/permission behavior remain outside that initial validation. The relaunch guard was tested with synthetic busy state, not a live microphone or meeting. [Certain]

## Public GitHub smoke test — October 17, 2026

After the repository became public, anonymous repository/release API access returned HTTP 200. There were no published releases and the stable `/releases/latest/download/appcast.xml` endpoint returned 404. [Certain]

Created disposable prerelease `sparkle-smoke-20261017`, explicitly excluded from latest/stable selection, containing an isolated `cc.clouddev.murmur.sparkle-public-test` fixture ZIP and appcast. The fixture used the production `AppUpdater.swift`, local development signing/Hardened Runtime, an ephemeral Ed25519 key and bundled license notices. It contained no dictation, models, recordings, transcripts or provider credentials. [Certain]

- Anonymous HTTPS downloads of the appcast and ZIP each returned HTTP 200 after one GitHub asset redirect, without a token or authenticated session. Downloaded files matched the uploaded bytes; the appcast length and Ed25519 signature verified. The ZIP was 1,109,273 bytes, SHA-256 `7d36dab305befec6d4897bc003036381d61baa5af912e88e47d90358f2d85117`. [Certain]
- The version-1 fixture fetched the public GitHub feed, found version 2, downloaded it through Sparkle's standard UI, installed it and relaunched. Verified installed `CFBundleVersion=2`, strict code signatures and the new process's `installed-and-relaunched-v2` marker. No localhost server was involved. [Certain]
- The stable/latest appcast remained HTTP 404 throughout, so the disposable prerelease did not enter the production update path. Removed the temporary release and its tag after testing; the release API returned 404 afterward. Deleted the ephemeral private key. [Certain]

This verifies GitHub asset delivery and the production updater adapter in an isolated app. It does not establish first-install Gatekeeper behavior, privacy-grant persistence, unattended/background installation or multi-machine reliability for the full Murmur app. Permanent production key setup was still pending at this checkpoint and is covered below; the stable feed remains unpublished pending approval. The earlier one-off launch stall remains unexplained; it did not recur in this public test. [Certain]

## Publication preparation — October 17, 2026

Generated the permanent production Ed25519 key in the macOS Keychain account `Murmur`. The public key is `OLsVG/pPafKOshla810tZqhA0fOK8Ya88htcW7pc3XE=`; the exact build configuration is recorded in UPDATES.md. A temporary owner-only export outside the repository was prepared for the user's requested password-manager import, and its derived public key was checked without printing private material. The user confirmed importing the key into Apple Passwords, and the temporary export was then deleted. Password contents, off-device sync and recovery were not independently verified; the original Keychain signing key remains available. [Certain]

Fixed a relaunch gap found during review: stopping a meeting clears its live state before its final transcription, speaker separation and notes tasks finish. The updater now includes those tasks in its existing busy guard. Regression checks exercised the real transcription recovery pump and asynchronous notes/separation, proving the guard releases again after completion. [Certain]

A new disposable `cc.clouddev.murmur.sparkle-background-test` fixture used the production updater adapter, local development signing, Hardened Runtime and an ephemeral key. With automatic checks/downloads enabled and a due scheduled check, it downloaded and verified the update from localhost without manual update UI. A normal timed quit at 45 seconds installed version 2; strict signature verification and its next-launch marker passed. This verifies background downloading and install-on-quit in an isolated app, not the full Murmur capture process. [Certain]

Sparkle logged its standard background-app gentle-reminder warning: scheduled update alerts after launch can appear behind other apps because Murmur does not implement a custom reminder delegate. Automatic download/install-on-quit still passed. No notification permission was requested. [Certain]

With the user's explicit permission, a disposable `Murmur Update Permission Test` app (`cc.clouddev.murmur.sparkle-permission-test`) requested microphone authorization without recording audio. After the user clicked Allow, version 1 automatically downloaded and installed version 2 on normal quit. Its next launch reported `version=2 microphone=3` (authorized), with no second grant and strict signatures passing. Both versions used the same local development identity and designated requirement. This covers microphone authorization in the isolated fixture, not Accessibility, Input Monitoring or system-audio grants in the full app. Ephemeral test signing material was deleted afterward, and `tccutil reset Microphone cc.clouddev.murmur.sparkle-permission-test` successfully revoked only the disposable fixture's microphone grant. [Certain]

Prepared a fresh full Murmur `0.2.0` / build `2` candidate, preserving `cc.clouddev.dictation.development`, the local development signing identity and the permanent Sparkle key. The build started with no existing output bundle. Full build, strict nested signature verification, packaging/signature verification and a timed synthetic-preview launch passed. The ZIP contains the project, third-party and Sparkle notices and no private-key filenames. An independent CryptoKit check verified the archive Ed25519 signature using only the embedded public key, without reading Keychain/private signing material. Archive SHA-256: `db9253387b03745e47482c92774b94936a9d5b3a6d3c853a1af84f46b43679c7` (14,105,177 bytes). [Certain]

Gatekeeper assessment of the finished candidate returned `rejected` (exit 3), as expected for the local identity without Developer ID/notarization. This is not a Gatekeeper pass or a real browser-download first-launch test. The release notes identify the artifact as an unsigned preview and disclose the first-launch trust limitation. Developer ID release-mode checks were not bypassed. [Certain]

Current publication limits: the stable appcast is not public until the prepared draft is published, and existing builds without Sparkle require a one-time manual installation. Full-app Accessibility/Input Monitoring/system-audio grant continuity, live meeting capture during an update, and multi-machine reliability remain unverified. One earlier installation/relaunch stalled before startup; repeated local/public fixture runs passed, but its cause remains unresolved. No merge or stable publication has been performed. [Certain]
