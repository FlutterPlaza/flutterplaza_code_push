## Unreleased

- Documentation: `CodePushOverlay.bannerBuilder` no longer instructs returning `null` (which its type never accepted). To show no banner, return `const SizedBox.shrink()` — the builder call itself is the "patch ready" signal, so drive your own UI from there with the `onRestart`/`onDismiss` callbacks. Also documented: the overlay calls `CodePush.init` itself, superseding any earlier `init`; apps that want to own the update lifecycle should use `CodePush.init`/`checkAndInstall` directly instead of the overlay.

## 0.1.11

- Adds Android support: patches download, verify, and apply on the next app restart.
- Patch downloads are verified before use, and update URLs must use HTTPS (plain-HTTP hosts other than localhost are refused).
- Adds `disableOnPlayStoreInstalls` for keeping over-the-air updates off on Play Store installs.
- Devices no longer re-download an already-installed or rolled-back patch.

## 0.1.10+1

- Documentation-only release: rewrites the changelog with concise, user-facing notes. No code changes from 0.1.10.
- If you are on the 0.1.x stable line, prefer the 0.1.11 release candidates (see below).

## 0.1.11-rc.7

- Patch downloads are now verified against the update metadata before use.
- Update checks and patch downloads now require HTTPS. If you point the SDK at a plain-HTTP server or patch host (other than localhost during development), updates will be refused after this upgrade — switch those URLs to HTTPS.
- Fixes an issue where overlapping update checks could interfere with an applied patch.

## 0.1.11-rc.6

- Fix: apps now rebuild correctly after a successful patch load even when the patch returns no data.

## 0.1.11-rc.5

- Fix: after a patch loads on iOS, the app UI now refreshes automatically without requiring a manual restart.
- Pairs with the matching engine update.

## 0.1.11-rc.4

- Feature: the SDK reads a distribution-proof baseline UUID from `Info.plist` and sends it with every update check. TestFlight and App Store builds now correctly identify themselves to the server.
- Pairs with `flutter_compile 0.19.15-rc.7` and a server update.

## 0.1.11-rc.3

- Fix: baseline hash mismatch no longer blocks patch downloads. The hash check is now a soft warning.

## 0.1.11-rc.2

- Fix: a successful patch load with nothing new to apply no longer triggers a rollback-and-retry loop. The SDK now treats a non-error load as a success, regardless of return value.
- Pairs with `flutter_compile 0.19.15-rc.4`.

## 0.1.11-rc.1

- **Retracted.** Use 0.1.11-rc.2 or later.

## 0.1.10

- **Retracted.** Use 0.1.11-rc.2 or later.

## 0.1.9

- **Retracted.** Use 0.1.11-rc.2 or later.

## 0.1.8

- **Retracted.** Use 0.1.11-rc.2 or later.

## 0.1.7

- Feature: the SDK now computes a baseline content hash and sends it with every update check. The server can use this to refuse patches that don't match the device's running binary, preventing a crash-loop on baseline drift.
- Feature: new telemetry path reports devices stranded on an incompatible baseline so publishers can see them in the admin dashboard.
- Fix: `CodePush.init()` runs crash protection before the first update check, so the auto-rollback counter has a chance to trip when a prior bad patch is on disk.
- New dependency: `crypto: ^3.0.6` (used for the baseline hash).
- Migration: no app code changes required. Pair with the matching CLI and server release to enable the new check.

## 0.1.6

- **Crash fix**: the stale-patch cleanup moved from Dart into an iOS native hook that runs before the Flutter engine starts. This closes a crash that could fire before `main()` ever ran, which the previous Dart-level cleanup couldn't reach.
- Feature: `CodePushOverlay.config` is now optional. When omitted it falls back to `CodePush.lastConfig`, so an app that already calls `CodePush.init(...)` at the top of `main()` can write `CodePushOverlay(child: MyApp())` without repeating its config.
- Feature: `serverUrl` is now optional on both `CodePush.init` and `CodePushConfig`, defaulting to `CodePush.defaultServerUrl` (`https://api.codepush.flutterplaza.com`). Apps on the production service only need `appId` and `releaseVersion`.
- Note: this release adds a CocoaPod dependency on iOS. Run `cd ios && pod install` on your next `flutter pub get` if your build tooling doesn't auto-run it.

## 0.1.5

- Fix: the 0.1.4 stale-patch cleanup used the wrong file to decide whether a patch was stale on iOS. A pure Dart rebuild did not update that file, so stale patches from previous rebuilds were never detected. 0.1.5 uses a more robust freshness check that covers native-only, Dart-only, and full rebuilds.

## 0.1.4

- Fix: a stale patch file on disk from a previous install could crash the app on iOS during the first boot after an upgrade, before the SDK had a chance to detect the mismatch. 0.1.4 adds a synchronous cleanup at the very top of `CodePush.init()` that removes the patch (and its siblings) when the app bundle is newer than the patch. Call `CodePush.init(...)` at the very top of your `main()` for this to take effect.

## 0.1.3

- **Security / fix**: reject patches when the running Flutter engine doesn't support code push, instead of attempting to apply them.
  - New public `CodePush.hasCodePushEngine` — async getter apps can use to hide update UI on incompatible baselines.
  - `CodePush.checkAndInstall` now runs a compatibility probe before writing any patch bytes to disk.
  - New `IncompatibleBaselineException` carrying `reason`, `expectedFingerprint`, and `actualFingerprint` for apps that want to handle the rejection explicitly.
  - When a patch is refused on this check, the SDK posts a structured telemetry record so publishers can see how many devices are stranded on incompatible baselines in the admin dashboard.

## 0.1.2

- Fix: safe type handling for server responses (prevents crashes from malformed data).
- Fix: broad exception catch on all platform channel calls.

## 0.1.1

- Fix: license updated to BSD 3-Clause (was incorrectly MIT).
- Fix: README license reference corrected.
- Add: `.pubignore` to exclude build artifacts from the published archive.
- Add: `topics` and `issue_tracker` to `pubspec.yaml` for discoverability.

## 0.1.0

- Initial release
- `CodePush.checkForUpdate()` — check server for available patches
- `CodePush.downloadAndApply()` — download and install a patch (with progress callback)
- `CodePush.currentPatch` — info about the active patch
- `CodePush.isPatched` — check if running with a patch
- `CodePush.rollback()` — remove the active patch
- `CodePush.installPatch()` — install a patch from raw bytes
- `CodePush.releaseVersion` — baseline release version
- `CodePush.cleanupOldPatches()` — free disk space
- `CodePush.checkForUpdatePeriodically()` — periodic background checks
- `CodePush.patchCount` — number of stored patches
