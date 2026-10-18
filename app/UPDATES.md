# GitHub-hosted Sparkle updates

Sparkle 2.10.0 is pinned by archive SHA-256 in `tools/fetch_sparkle.sh`. The build embeds and signs the framework and its nested helpers and includes its MIT license. No app server, GitHub API token, or GitHub Pages site is required.

## One-time production setup

Choose a **public** releases repository. The source can stay private if a separate public repository holds the binaries and feed. No repository is created or made public by these scripts.

The existing production signing key uses the macOS Keychain account `Murmur`. Its public key is `OLsVG/pPafKOshla810tZqhA0fOK8Ya88htcW7pc3XE=`. Preserve this key for subsequent releases; the matching private key must stay outside the repository and app bundle.

To retrieve the existing public key without generating or replacing it:

```sh
sparkle_path="$(app/tools/fetch_sparkle.sh | tail -1)"
"$sparkle_path/bin/generate_keys" --account Murmur -p
```

Back up this signing key securely using Sparkle's `generate_keys -x` export option; never commit it or embed it in an app. Without Developer ID as an alternative trust anchor, losing this key prevents the normal signed update chain from continuing. Test keys must never be used for production.

## Build and prepare a release

The release repository is `Penguin0011/Murmur`. This configuration preserves the existing bundle identifier; choose the intended version and a new build number for each release. Clean the generated `runtime/Murmur.app` output before building a public candidate so stale resources cannot enter the archive.

```sh
export MURMUR_UPDATE_FEED_URL='https://github.com/Penguin0011/Murmur/releases/latest/download/appcast.xml'
export MURMUR_UPDATE_PUBLIC_KEY='OLsVG/pPafKOshla810tZqhA0fOK8Ya88htcW7pc3XE='
export MURMUR_VERSION='0.2.0'
export MURMUR_BUILD_VERSION='2'
app/build.sh
app/tools/package_update.sh
```

`MURMUR_BUILD_VERSION` must increase for every release. Packaging names the release tag `v<CFBundleShortVersionString>` (`v0.2.0` here), so older builds' GitHub version checker displays the correct product version; archives use the monotonic build number. The script creates `runtime/update/Murmur-2.zip` and `runtime/update/appcast.xml`, checks the app signature, and uses Sparkle's tools to sign and verify the archive. Choose a fresh output directory for every release by passing it as the second argument.

Optionally set `MURMUR_RELEASE_NOTES` to a Markdown file before packaging. Notes are embedded in the appcast, so only the ZIP and XML need uploading. For isolated testing or CI, `MURMUR_SPARKLE_KEY_FILE` can name a private key file instead of Keychain; otherwise the `Murmur` Keychain account is used (overridable with `MURMUR_SPARKLE_KEY_ACCOUNT`).

Create a draft GitHub Release tagged `v0.2.0`, upload both generated assets, then publish it as the latest stable release. Do not mark beta/prerelease releases as latest. The appcast's ZIP link contains the exact tag; only the feed follows `/latest/`. No publishing is performed by the build/package scripts.

Keep archives immutable after signing. Every published latest release must include `appcast.xml`. With a one-entry feed, clients older than the latest build must be able to update directly to it. Upgrade to a cumulative feed if staged migrations or multiple supported macOS branches become necessary.

## Signing and user behavior

Sparkle's Ed25519 key authenticates updates without Apple enrollment. It does not provide Developer ID trust or notarization; a downloaded development app can still need a Gatekeeper override. Verify first-install behavior and privacy-grant continuity on the release build.

Development builds disable library validation for the host only, allowing a local identity to load Sparkle. `MURMUR_RELEASE=1` still requires Developer ID, notarization, and the original strict entitlements; it also requires update configuration. Unconfigured development builds show an unavailable message and do not run the old GitHub checker.

The existing automatic-check preference migrates to Sparkle once. Sparkle owns daily checks and its persisted preferences. Automatic installation defaults off; users can opt in from Settings or Sparkle's update UI. Checks wait during recording/processing, and relaunch is deferred until dictation, meeting recording, final transcription, speaker separation and notes writing finish. Sparkle's system profile submission is disabled.

## Checks

The configuration check needs Python 3 only. The adapter check also needs the pinned Sparkle archive in `runtime/Sparkle-2.10.0`, populated by the app build.

```sh
python3 app/tools/check_update_config.py
swiftc -swift-version 5 -parse-as-library -F runtime/Sparkle-2.10.0 -framework Sparkle \
  -Xlinker -rpath -Xlinker "$PWD/runtime/Sparkle-2.10.0" \
  app/AppUpdater.swift app/check_app_updater.swift -o /tmp/murmur-sparkle-check
/tmp/murmur-sparkle-check
```

Use two disposable app versions, an ephemeral signing key and a localhost feed for installation tests. Never target an existing Murmur installation or its data. Test public GitHub delivery, valid and invalid signatures, busy-state deferral, installation and relaunch on the release build. Local fixture checks do not establish multi-machine reliability. Older builds without Sparkle require one manual installation of a Sparkle-enabled build. Until a latest release contains `appcast.xml`, the configured stable feed cannot serve updates.
