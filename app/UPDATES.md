# GitHub-hosted Sparkle updates

Sparkle 2.10.0 is pinned by archive SHA-256 in `tools/fetch_sparkle.sh`. The build embeds and signs the framework and its nested helpers and includes its MIT license. No app server, GitHub API token, or GitHub Pages site is required. [Certain]

## One-time production setup

Choose a **public** releases repository. The source can stay private if a separate public repository holds the binaries and feed. No repository is created or made public by these scripts. [Certain]

Generate a permanent Sparkle key once:

```sh
sparkle_path="$(app/tools/fetch_sparkle.sh | tail -1)"
"$sparkle_path/bin/generate_keys" --account Murmur
```

Back up this signing key securely using Sparkle's `generate_keys -x` export option; never commit it or embed it in an app. Without Developer ID as an alternative trust anchor, losing this key prevents the normal signed update chain from continuing. Test keys must never be used for production. [Certain]

## Build and prepare a release

Supply the public key printed above and the chosen repository. For example, if the main repository has been made public:

```sh
export MURMUR_UPDATE_FEED_URL='https://github.com/Penguin0011/Murmur/releases/latest/download/appcast.xml'
export MURMUR_UPDATE_PUBLIC_KEY='PUBLIC_KEY_PRINTED_BY_GENERATE_KEYS'
export MURMUR_VERSION='0.2.0'
export MURMUR_BUILD_VERSION='2'
app/build.sh
app/tools/package_update.sh
```

`MURMUR_BUILD_VERSION` must increase for every release. Packaging names the release tag `v<CFBundleVersion>` (the example uses `v2`), independently of the displayed `0.2.0` version. The script creates `runtime/update/Murmur-2.zip` and `runtime/update/appcast.xml`, checks the app signature, and uses Sparkle's tools to sign and verify the archive. Choose a fresh output directory for every release by passing it as the second argument. [Certain]

Optionally set `MURMUR_RELEASE_NOTES` to a Markdown file before packaging. Notes are embedded in the appcast, so only the ZIP and XML need uploading. For isolated testing or CI, `MURMUR_SPARKLE_KEY_FILE` can name a private key file instead of Keychain; otherwise the `Murmur` Keychain account is used (overridable with `MURMUR_SPARKLE_KEY_ACCOUNT`). [Certain]

Create a draft GitHub Release tagged `v2`, upload both generated assets, then publish it as the latest stable release. Do not mark beta/prerelease releases as latest. The appcast's ZIP link contains the exact tag; only the feed follows `/latest/`. No publishing is performed by the build/package scripts. [Certain]

Keep archives immutable after signing. Every published latest release must include `appcast.xml`. With a one-entry feed, clients older than the latest build must be able to update directly to it. Upgrade to a cumulative feed if staged migrations or multiple supported macOS branches become necessary. [Certain]

## Signing and user behavior

Sparkle's Ed25519 key authenticates updates without Apple enrollment. It does not provide Developer ID trust or notarization; a downloaded development app can still need a Gatekeeper override, and privacy grants across self-signed/ad-hoc updates remain unverified. [Certain]

Development builds disable library validation for the host only, allowing a local identity to load Sparkle. `MURMUR_RELEASE=1` still requires Developer ID, notarization, and the original strict entitlements; it also requires update configuration. Unconfigured development builds show an unavailable message and do not run the old GitHub checker. [Certain]

The existing automatic-check preference migrates to Sparkle once. Sparkle owns daily checks and its persisted preferences. Automatic installation defaults off; users can opt in from Settings or Sparkle's update UI. Checks wait during recording/processing, and relaunch is deferred until dictation and meeting recording finish. Sparkle's system profile submission is disabled. [Certain]

## Checks

```sh
python3 app/tools/check_update_config.py
swiftc -swift-version 5 -parse-as-library -F runtime/Sparkle-2.10.0 -framework Sparkle \
  -Xlinker -rpath -Xlinker "$PWD/runtime/Sparkle-2.10.0" \
  app/AppUpdater.swift app/check_app_updater.swift -o /tmp/murmur-sparkle-check
/tmp/murmur-sparkle-check
```

Use two disposable app versions, an ephemeral signing key and a localhost feed for installation tests. Never target the user's installed Murmur or its data. An isolated public GitHub-hosted download/install/relaunch smoke test passed on October 17, 2026; see [SPARKLE_TEST_RESULTS.md](SPARKLE_TEST_RESULTS.md). A real stable-build release test remains necessary after configuring the permanent production key/feed. [Certain]
