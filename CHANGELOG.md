## 0.1.3

- **security / fix**: refuse to apply a patch when the running Flutter engine has no code push support, instead of loading it into the VM and crashing. Previously, if a device's baseline build was made with a stock Flutter engine (or any engine whose ABI disagreed with the patch's build environment), the SDK called into a runtime hook that does not exist on that engine, which manifested as a release-mode `EXC_BAD_ACCESS (SIGSEGV)` inside `DRT_AllocateObject` reading from `0x10` — an unrecoverable crash with no diagnostic. The fix:
  - `CodePush.hasCodePushEngine` (new, public) — async getter that probes the `flutter/codepush` method channel with a 2s timeout. Apps can use it to hide update UI on incompatible baselines.
  - Internal two-phase fingerprint probe:
    1. **Phase 2** (when the engine exposes a `CodePush.getEngineAbi` method channel handler) — ABI-level comparison against the server's `engine_fingerprint` field.
    2. **Phase 1** (fallback for older engines) — presence check via the existing `CodePush.getReleaseVersion` handler. Treats "engine present" as sufficient and skips the ABI comparison.
  - `CodePush.checkAndInstall` runs the probe **before** writing any patch bytes to disk or calling into `dart:ui`. If the probe returns null, the patch is rejected with a structured status message and a best-effort telemetry POST to `/api/v1/telemetry/client-error` so publishers can see how many devices are stranded on incompatible baselines.
  - New `IncompatibleBaselineException` (in `models.dart`) carrying `reason`, `expectedFingerprint`, `actualFingerprint` for apps that want to handle the rejection explicitly.
- chore: suppress the analyzer's `undefined_function` warning on `ui.codePushLoadModule` with a narrowly-scoped `// ignore` comment, since the hook is provided dynamically at runtime by the custom engine and cannot be resolved statically. No behavior change.

## 0.1.2

- fix: safe type handling for server responses (prevents crashes from malformed data)
- fix: broad exception catch on all platform channel calls

## 0.1.1

- fix: license updated to BSD 3-Clause (was incorrectly MIT)
- fix: README license reference corrected
- add: `.pubignore` to exclude build artifacts from pub.dev archive
- add: `topics` and `issue_tracker` to pubspec.yaml for discoverability

## 0.1.0

- Initial release
- `CodePush.checkForUpdate()` — check server for available patches
- `CodePush.downloadAndApply()` — download and install a patch (with progress callback)
- `CodePush.currentPatch` — get info about the active patch
- `CodePush.isPatched` — check if running with a patch
- `CodePush.rollback()` — remove the active patch
- `CodePush.installPatch()` — install a patch from raw bytes
- `CodePush.releaseVersion` — get the baseline release version
- `CodePush.cleanupOldPatches()` — free disk space
- `CodePush.checkForUpdatePeriodically()` — periodic background checks
- `CodePush.patchCount` — number of stored patches
