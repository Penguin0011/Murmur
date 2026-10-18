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

The initial download tests used localhost. The public GitHub smoke test below supersedes that transport limitation. No permanent production signing key or stable release feed has been configured. Developer ID signing/notarization, first-download Gatekeeper behavior, privacy-grant persistence across updates, install-on-quit behavior and unattended background installation have not been verified. The relaunch guard was tested with synthetic busy state, not a live microphone or meeting. [Certain]

## Public GitHub smoke test — October 17, 2026

After the repository became public, anonymous repository/release API access returned HTTP 200. There were no published releases and the stable `/releases/latest/download/appcast.xml` endpoint returned 404. [Certain]

Created disposable prerelease `sparkle-smoke-20261017`, explicitly excluded from latest/stable selection, containing an isolated `cc.clouddev.murmur.sparkle-public-test` fixture ZIP and appcast. The fixture used the production `AppUpdater.swift`, local development signing/Hardened Runtime, an ephemeral Ed25519 key and bundled license notices. It contained no dictation, models, recordings, transcripts or provider credentials. [Certain]

- Anonymous HTTPS downloads of the appcast and ZIP each returned HTTP 200 after one GitHub asset redirect, without a token or authenticated session. Downloaded files matched the uploaded bytes; the appcast length and Ed25519 signature verified. The ZIP was 1,109,273 bytes, SHA-256 `7d36dab305befec6d4897bc003036381d61baa5af912e88e47d90358f2d85117`. [Certain]
- The version-1 fixture fetched the public GitHub feed, found version 2, downloaded it through Sparkle's standard UI, installed it and relaunched. Verified installed `CFBundleVersion=2`, strict code signatures and the new process's `installed-and-relaunched-v2` marker. No localhost server was involved. [Certain]
- The stable/latest appcast remained HTTP 404 throughout, so the disposable prerelease did not enter the production update path. Removed the temporary release and its tag after testing; the release API returned 404 afterward. Deleted the ephemeral private key. [Certain]

This verifies GitHub asset delivery and the production updater adapter in an isolated app. It does not establish first-install Gatekeeper behavior, privacy-grant persistence, unattended/background installation or multi-machine reliability for the full Murmur app. A permanent production key and a real stable build/feed remain release setup work. The earlier one-off launch stall remains unexplained; it did not recur in this public test. [Certain]
