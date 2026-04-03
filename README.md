# flutterplaza_code_push

Over-the-air code push updates for Flutter apps. Check for updates, download
patches, and roll back — all at runtime.

This package provides the **runtime API** that app developers add to their
Flutter apps. It communicates with the custom code-push engine (installed via
the `fcp` CLI) through a platform channel.

## Prerequisites

Before using this package, you need:

1. **`fcp` CLI** installed (`dart pub global activate flutter_compile`)
2. A FlutterPlaza Code Push account — run `fcp codepush login` (opens browser for sign-in)
3. Code-push-enabled engine artifacts (`fcp codepush setup`)

## Installation

```yaml
dependencies:
  flutterplaza_code_push: ^0.1.0
```

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

// Check for updates
final update = await CodePush.checkForUpdate();
if (update.isUpdateAvailable) {
  print('Update available: ${update.patchVersion}');
  print('Download size: ${update.downloadSize} bytes');

  // Download and apply
  await CodePush.downloadAndApply(
    onProgress: (progress) {
      print('Download: ${(progress * 100).toInt()}%');
    },
  );
  // Patch takes effect on next app restart.
}
```

## API Reference

### `CodePush.checkForUpdate()`

Checks the server for available updates.

```dart
final UpdateInfo info = await CodePush.checkForUpdate();
// info.isUpdateAvailable — bool
// info.patchVersion     — String? (e.g., '1.0.0+2')
// info.downloadSize     — int? (bytes)
```

Throws `CodePushException` on failure.

### `CodePush.downloadAndApply()`

Downloads and applies the latest patch. Takes effect on next restart.

```dart
await CodePush.downloadAndApply(
  onProgress: (double progress) {
    // 0.0 to 1.0
  },
);
```

Throws `CodePushException` if the download or application fails.

### `CodePush.installPatch(Uint8List patchBytes)`

Installs a patch from raw bytes. Useful when the app downloads the patch
itself (e.g., via `http` package).

```dart
final bytes = await myHttpClient.downloadPatch(url);
await CodePush.installPatch(bytes);
```

The engine verifies the patch integrity (SHA-256 hash, optional RSA
signature) before installing.

### `CodePush.rollback()`

Rolls back to the previous version by removing the active patch. Takes
effect on next restart.

```dart
await CodePush.rollback();
```

### `CodePush.currentPatch`

Returns information about the currently active patch.

```dart
final PatchInfo? info = await CodePush.currentPatch;
if (info != null) {
  print('Patch version: ${info.version}');
  print('Installed at: ${info.installedAt}');
}
```

### `CodePush.isPatched`

Returns whether the app is running with a code push patch.

```dart
final bool patched = await CodePush.isPatched;
```

### `CodePush.releaseVersion`

Returns the release version string for this app build.

```dart
final String version = await CodePush.releaseVersion;
```

### `CodePush.patchCount`

Returns the number of patches stored on the device.

```dart
final int count = await CodePush.patchCount;
```

### `CodePush.cleanupOldPatches()`

Removes old, inactive patches from local storage to free disk space.
The currently active patch is never removed.

```dart
final int removed = await CodePush.cleanupOldPatches();
print('Removed $removed old patches');
```

### `CodePush.checkForUpdatePeriodically()`

Starts periodic background checks for updates.

```dart
final timer = CodePush.checkForUpdatePeriodically(
  interval: Duration(hours: 4),
  onUpdateAvailable: (UpdateInfo update) {
    showUpdateDialog(update);
  },
);

// Stop checking:
timer.cancel();
```

## Models

### `UpdateInfo`

| Field | Type | Description |
|-------|------|-------------|
| `isUpdateAvailable` | `bool` | Whether an update is available |
| `patchVersion` | `String?` | Version string of the available patch |
| `downloadSize` | `int?` | Size of the patch in bytes |

### `PatchInfo`

| Field | Type | Description |
|-------|------|-------------|
| `version` | `String` | Patch version string |
| `installedAt` | `DateTime` | When the patch was installed |

### `CodePushException`

Thrown when a code push operation fails. Contains a `message` field
describing the error.

## Typical Workflow

```
1. fcp codepush login          # opens browser, click Authorize (one-time)
2. fcp codepush setup          # download engine artifacts (per Flutter version)
3. fcp codepush init           # register app on server
4. fcp codepush release --build --platform apk   # upload baseline
5. # ... make code changes ...
6. fcp codepush patch --build --platform apk --release-id <id>  # upload patch
7. App calls CodePush.checkForUpdate() → downloads → restarts with new code
```

## Platform Support

| Platform | Status |
|----------|--------|
| Android  | Supported |
| iOS      | Supported |
| macOS    | Supported |
| Linux    | Supported |
| Windows  | Supported |

## License

BSD 3-Clause. See [LICENSE](LICENSE) for details.
