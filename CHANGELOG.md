## 0.1.7

- **crash-loop fix**: closes a separate crash class that 0.1.6's `+load` cleanup couldn't touch. The `+load` hook only deletes *stale* patches (patches older than the running bundle); it cannot help when the SDK's own `checkAndInstall` downloads a *fresh* patch that's incompatible with the baseline the device actually runs. The server returns the latest active patch for a release regardless of which baseline version the device is on, so a device running a baseline built against `flutterplaza_code_push 0.1.5` can end up downloading a patch built against `0.1.6` or `0.1.7`. The Dart class layouts differ across package versions (every release adds or removes fields, methods, statics — `CodePush.lastConfig` static added in 0.1.6, `IncompatibleBaselineException` added in 0.1.3, etc.), the AOT snapshot references class offsets that don't exist in the running baseline, and the VM aborts inside `DN_Internal_loadDynamicModule` on the first class allocation. The engine ABI fingerprint introduced in 0.1.3 doesn't catch this because both sides ship the same Flutter SDK version.
- **the fix**: SHA-256 content-hash baseline check. The server now stores a per-patch `baseline_hash` (the SHA-256 of the `App.framework/App` file the patch was compiled against), records it at upload time, includes it in the `GET /api/v1/updates` response, **and** refuses to serve a patch when the device's own `baseline_hash` query parameter disagrees with the patch's recorded hash. The SDK computes its own baseline hash by streaming `<app bundle>/Frameworks/App.framework/App` through `package:crypto`'s `sha256` at first `checkAndInstall`, caches the result in memory for the session, and refuses to load any patch whose recorded `baseline_hash` disagrees.
- **init order fix**: `CodePush.init()` previously fired `checkAndInstall(...)` immediately, in parallel with `_runCrashProtection()`. In a crash loop where a previously-downloaded bad patch is on disk, the boot counter lived in the patch directory that `_runCrashProtection()` checks — but `checkAndInstall` could overwrite that same file with a fresh download before the counter had a chance to increment, so the three-strike auto-rollback never fired. 0.1.7 chains the first `checkAndInstall` off `_runCrashProtection().then(...)` so the crash-protection pass always runs first, giving the boot counter a chance to trip when appropriate.
- **new dependency**: `crypto: ^3.0.6`, used only for the streaming SHA-256 digest of the baseline file. Adds ~5 KB to the compiled app.
- **migration**: no app code changes required. The compatibility check is additive — older servers that don't return `baseline_hash` fall through to the existing engine-ABI check, and older CLI versions that don't upload a `baseline_hash` produce patches that skip the check on the device side. Running `flutter pub upgrade flutterplaza_code_push` + `cd ios && pod install` is sufficient. For the fix to actually prevent the crash, the **server** must be running the matching deploy (`code-push-server` 2026-04-10 or later, adds `baseline_hash` to the Patch model) and the **CLI** must be 0.19.10+ (includes `baseline_hash` in the upload). The three pieces were shipped together.
- **diagnostic telemetry**: when the SDK refuses a patch due to a baseline hash mismatch, it posts a structured `IncompatibleBaselineException` record to `/api/v1/telemetry/client-error` with `reason: 'Baseline hash mismatch'` plus the expected and actual SHA-256 values, so publishers can see how many devices are stranded on incompatible baselines in the admin dashboard.

## 0.1.6

- **crash fix (the big one)**: moves the stale-patch cleanup out of Dart and into iOS native code. 0.1.3/0.1.4/0.1.5 all tried to clean up inside `CodePush.init()`, which runs inside `main()` — but on the reported crash path **`main()` never runs**. The custom Flutter engine loads `patch.vmcode` as the isolate's snapshot data during isolate initialization, before `Dart_InvokeMain` is ever called; if the on-disk patch is incompatible with the running baseline, the VM aborts with `SIGABRT` inside `DN_Internal_loadDynamicModule` and the process dies without executing a single line of Dart.
  - 0.1.6 converts `flutterplaza_code_push` into a Flutter plugin with iOS native code. A new Objective-C class registers a `+load` method that runs during dyld image loading — **before** `main()` in the ObjC entry point, **before** `UIApplicationMain`, **before** the Flutter engine is instantiated, **before** any Dart code runs. This is the earliest hook available to a Flutter plugin.
  - The `+load` cleanup computes `<NSDocumentDirectory>/code_push_patches/patch.vmcode`, compares its mtime against the max of `Runner.app/Runner` and `Runner.app/Frameworks/App.framework/App` (so the check works for native-only rebuilds, Dart-only rebuilds, and full builds), and deletes the patch plus its sibling files (`boot_counter`, `launch_status.json`, `patch_info.json`, `patch.vmcode.tmp`) if the bundle is newer. Steady-state runs where the patch is newer than the bundle are a no-op.
  - Apps upgrading from 0.1.5 get automatic CocoaPods integration on their next `flutter pub get` + `cd ios && pod install`. No `AppDelegate` or `main.dart` changes required. Users who previously added the 0.1.5 Dart-side `CodePush.init(...)` as the first line of `main()` can leave it there — it's now redundant for crash prevention but still configures the SDK normally.
  - The unreachable Dart-side `_cleanupStalePatchSync` is removed. Its doc comment was correct about the crash mechanism but wrong about the fix layer; keeping dead code that can't possibly fire is worse than deleting it.
  - Non-iOS is unchanged. Android's engine uses a different load path and does not hit this crash.

- **API improvement — config reuse**: `CodePushOverlay` already calls `CodePush.init(...)` internally from its `initState`, which meant apps that wrapped their root widget in `CodePushOverlay` and **also** called `CodePush.init(...)` at the top of `main()` were double-initializing with identical config. 0.1.6 fixes the duplication three ways:
  - `CodePush.init` stores its config in a new `CodePush.lastConfig` static field on every call.
  - `CodePushOverlay.config` is now **optional**. When omitted, the overlay falls back to `CodePush.lastConfig` — so apps that want to configure at the top of `main()` can now write `CodePushOverlay(child: ...)` without repeating every field. An explicit `config:` on the overlay still wins for cases where the overlay needs different settings.
  - `CodePush.init` and `CodePushConfig` both make `serverUrl` **optional** now, defaulting to the new `CodePush.defaultServerUrl` constant (`https://api.codepush.flutterplaza.com`). Apps targeting the production service only need to supply `appId` and `releaseVersion`.
  - Typical new shape:
    ```dart
    void main() {
      CodePush.init(
        appId: Platform.isIOS ? '...ios-app-id...' : '...android-app-id...',
        releaseVersion: '1.2.0+15',
      );
      runApp(CodePushOverlay(child: MyApp()));
    }
    ```
    …or, if you prefer one call site:
    ```dart
    void main() {
      runApp(CodePushOverlay(
        config: CodePushConfig(
          appId: Platform.isIOS ? '...ios...' : '...android...',
          releaseVersion: '1.2.0+15',
        ),
        child: MyApp(),
      ));
    }
    ```
    Both work. `serverUrl` can still be overridden explicitly if you're pointing at a self-hosted server.

- **breaking-ish**: this release adds a CocoaPod dependency to your iOS build. On first `flutter pub get` you'll need to run `cd ios && pod install` (or let Flutter do it on the next build). If your app already has `flutter_compile`-built code push working, `pod install` should be a no-op beyond adding the `flutterplaza_code_push` pod itself.

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
