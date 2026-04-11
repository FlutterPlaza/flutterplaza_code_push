## 0.1.5

- **fix**: `_cleanupStalePatchSync` in 0.1.4 compared `patch.vmcode` against `Platform.resolvedExecutable`, which on iOS resolves to `Runner.app/Runner` — the thin Objective-C / Swift shell. Flutter's incremental iOS build only rewrites `Runner` when native code changes; a pure Dart rebuild (including `fcp codepush patch --build`) updates `Runner.app/Frameworks/App.framework/App` (the AOT snapshot) but leaves `Runner` alone. Result: stale patches from previous rebuilds were never detected because the Runner mtime stayed frozen in the past while the AOT blob and the patch both advanced. The crash scenario that 0.1.4 was supposed to prevent still fired.
- The fix uses the **max** of `Runner.app/Runner` and `Runner.app/Frameworks/App.framework/App` as the bundle freshness proxy. Whichever is newer represents "when the current code was last touched", so the comparison stays robust across native-only rebuilds, Dart-only rebuilds, and full builds. Missing files are tolerated gracefully (use the other; skip cleanup if both are missing). The derivation uses only `dart:io`, so the cleanup still runs synchronously before any microtask yield.

## 0.1.4

- **fix**: the 0.1.3 compatibility guard only covered `CodePush.checkAndInstall` (fresh downloads). It did not protect against a stale `patch.vmcode` file that was already on disk from a previous install — the Flutter engine's boot flow schedules a dynamic-module load of that file during isolate initialization, *before* the SDK's `checkAndInstall` runs. On iOS, that load fired `SIGABRT` inside `DN_Internal_loadDynamicModule` with a release-mode VM assert and no user-visible diagnostic when the stale patch was incompatible with the newly-installed app binary (the Documents directory is preserved across app updates, but the `.app` bundle is replaced). The engine's existing three-strike auto-rollback (`kMaxBootAttempts = 3` on the native side) still eventually recovered the app, but the user experienced three crash loops before the rollback fired.
- The fix is a new synchronous `_cleanupStalePatchSync()` that runs at the very top of `CodePush.init()`, before any microtask can drain. It uses `Platform.environment['HOME']` and `dart:io` only (no method channels, no FFI, no `path_provider`) so nothing yields. It compares the patch file's mtime against `Platform.resolvedExecutable`'s mtime, and deletes the patch (plus the `boot_counter`, `launch_status.json`, `patch_info.json`, and `patch.vmcode.tmp` siblings) if the app binary is newer than the patch — the signal that the patch was written by a previous install. Steady-state users whose patch is newer than the binary are unaffected; the cleanup is a no-op. Non-iOS is a no-op (the Android engine has its own in-process recovery and does not crash in this scenario).
- **Required**: call `CodePush.init(...)` at the very top of your `main()`, before `runApp()` and before any other `await`. The cleanup only works if it runs before the Dart isolate's event loop starts draining microtasks.
- **Safety net**: if you miss the `init()` call, or if the cleanup fails for any reason (e.g. unusual sandbox permissions), the engine's built-in three-strike auto-rollback will still recover the app on the fourth boot after the upgrade — ugly UX but not a brick.

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
