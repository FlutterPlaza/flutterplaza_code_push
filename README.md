# flutterplaza_code_push

Over-the-air code push updates for Flutter apps. Push updates to your users
without going through the app store review process.

This package provides the **runtime SDK** that you add to your Flutter app.
It communicates with a code-push-enabled Flutter engine (installed via the
`fcp` CLI) to check for updates, download patches, apply them, and
automatically roll back if something goes wrong.

## Features

- **Automatic update checking** -- checks on launch, periodically, and on app resume
- **Live patching (iOS)** -- bytecode modules load without restarting the app
- **Restart-based patching (Android/Desktop)** -- ELF patches applied on next cold restart
- **Crash protection with auto-rollback** -- reverts bad patches after repeated failed boots
- **RSA signature verification** -- optional cryptographic signing for patch integrity
- **SHA-256 hash verification** -- always-on integrity check for every patch
- **Debug status bar** -- opt-in overlay showing real-time code push status

## Prerequisites

1. **`fcp` CLI** installed (`dart pub global activate flutter_compile`)
2. A FlutterPlaza Code Push account -- run `fcp codepush login`
3. Code-push-enabled engine artifacts -- run `fcp codepush setup`

## Installation

```yaml
dependencies:
  flutterplaza_code_push: ^0.1.0
```

```bash
flutter pub get
```

## Quick Start

Wrap your root widget with `CodePushOverlay`. This handles the entire update
lifecycle automatically -- checking for updates, downloading patches, and
showing a restart banner when an update is ready.

```dart
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  runApp(
    CodePushOverlay(
      config: CodePushConfig(
        serverUrl: 'https://your-server.com',
        appId: 'your-app-id',
        releaseVersion: '1.0.0+1',
      ),
      child: MyApp(),
    ),
  );
}
```

That is the only change needed. The overlay checks for updates on launch, every
4 hours (configurable), and whenever the app returns from the background. When a
patch is downloaded and installed, a banner appears prompting the user to restart.

### Enable the debug status bar

During development, you can enable a small status bar at the top of the screen
that shows what code push is doing in real time:

```dart
CodePushOverlay(
  config: CodePushConfig(
    serverUrl: 'https://your-server.com',
    appId: 'your-app-id',
    releaseVersion: '1.0.0+1',
  ),
  showDebugBar: true, // Shows "CP: Checking server...", "CP: Patch active", etc.
  child: MyApp(),
)
```

## API Reference

### `CodePush.init()`

Starts the automatic update lifecycle. Call once at app startup. This is what
`CodePushOverlay` calls internally -- you only need this if you are **not**
using the overlay widget.

```dart
CodePush.init(
  serverUrl: 'https://your-server.com',
  appId: 'your-app-id',
  releaseVersion: '1.0.0+1',
  interval: Duration(hours: 4),    // optional, default 4 hours
  channel: 'production',           // optional, default 'production'
  onUpdateReady: () {
    // Called when a patch is installed and a restart is needed.
  },
);
```

What `init` does:

1. Runs crash protection checks (auto-rollback if needed)
2. Checks for updates immediately
3. Checks periodically at the configured interval
4. Reports launch success after a 10-second grace period

### `CodePush.dispose()`

Stops automatic update checking and cancels the launch timer.

```dart
CodePush.dispose();
```

### `CodePush.checkAndInstall()`

Checks the server for updates, downloads, and installs if available. Returns
`true` if a patch was installed.

```dart
final installed = await CodePush.checkAndInstall(
  serverUrl: 'https://your-server.com',
  appId: 'your-app-id',
  releaseVersion: '1.0.0+1',
  channel: 'production',
  onUpdateReady: () {
    // Prompt user to restart (Android/Desktop only).
  },
);
```

On iOS, bytecode patches are loaded live without a restart. On Android and
desktop, `onUpdateReady` is called so you can prompt the user to restart.

### `CodePush.checkForUpdate()`

Checks the engine for available updates without downloading.

```dart
final UpdateInfo info = await CodePush.checkForUpdate();
if (info.isUpdateAvailable) {
  print('Patch ${info.patchVersion} available (${info.downloadSize} bytes)');
}
```

### `CodePush.installPatch()`

Installs a patch from raw bytes. Use this when you download the patch yourself
(for example, via your own HTTP client).

```dart
final Uint8List patchBytes = await myHttpClient.downloadPatch(url);
await CodePush.installPatch(patchBytes);
```

The engine verifies patch integrity (SHA-256 hash, optional RSA signature)
before installing. The patch takes effect on the next cold restart.

### `CodePush.rollback()`

Rolls back to the base release by removing the active patch. Takes effect on
next cold restart.

```dart
await CodePush.rollback();
```

### `CodePush.restart()`

Triggers a cold restart of the app. On next launch, the engine loads the
installed patch.

```dart
CodePush.restart();
```

### `CodePush.isPatched`

Returns whether the app is currently running with a code push patch.

```dart
final bool patched = await CodePush.isPatched;
```

### `CodePush.currentPatch`

Returns information about the currently installed patch, or `null` if none
is active.

```dart
final PatchInfo? patch = await CodePush.currentPatch;
if (patch != null) {
  print('Version: ${patch.version}');
  print('Installed at: ${patch.installedAt}');
}
```

### `CodePush.releaseVersion`

Returns the release version string for this app build.

```dart
final String version = await CodePush.releaseVersion;
```

### `CodePush.status`

A `ValueNotifier<String>` that broadcasts what code push is currently doing.
Useful for debug UIs or logging.

```dart
CodePush.status.addListener(() {
  print('Code push status: ${CodePush.status.value}');
});
```

Values include: `init`, `Checking server...`, `Downloading patch...`,
`Patch active`, `No update (204)`, `Restart to apply`, etc.

### `CodePush.moduleResult`

A `ValueNotifier<Object?>` that holds the result from the last loaded
bytecode module (iOS live patches). Apps can listen to this to apply OTA
patches to their UI without a restart.

```dart
CodePush.moduleResult.addListener(() {
  final result = CodePush.moduleResult.value;
  if (result is Map<String, dynamic>) {
    // Use the patch data to update your UI.
  }
});
```

## Widgets

### `CodePushOverlay`

The recommended way to integrate code push. Wraps your app widget, manages
the full update lifecycle, and shows a restart banner when an update is ready.

```dart
CodePushOverlay(
  config: CodePushConfig(...),
  child: MyApp(),
  showDebugBar: false,       // optional, shows status bar at top
  bannerBuilder: (context, onRestart, onDismiss) {
    // optional, return a custom banner widget
    return MyCustomBanner(onRestart: onRestart, onDismiss: onDismiss);
  },
)
```

### `CodePushConfig`

Configuration object for `CodePushOverlay`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `serverUrl` | `String` | required | Your code push server URL |
| `appId` | `String` | required | Your app's identifier |
| `releaseVersion` | `String` | required | The current release version (e.g. `1.0.0+1`) |
| `checkInterval` | `Duration` | 4 hours | How often to check for updates |
| `channel` | `String` | `production` | The update channel |

### `CodePushPatchBuilder`

A widget that rebuilds when a bytecode module result becomes available. Use
this to apply OTA patches to specific parts of your UI.

```dart
CodePushPatchBuilder(
  patchKey: 'promo_banner',
  builder: (context, patchData, child) {
    if (patchData == null) return child!;
    return Text(patchData);
  },
  child: Text('Default content'),
)
```

If `patchKey` is provided, the builder only receives data from module results
that start with that key (e.g. `promo_banner:Hello World` passes
`Hello World` to the builder). If `patchKey` is null, all module results are
passed through.

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

Thrown when a code push operation fails. Contains a `message` field describing
the error.

## Crash Protection

Code push includes automatic crash protection to prevent a bad patch from
bricking your app. Here is how it works:

1. **Boot counter** -- Each time the app starts with an active patch, a boot
   counter is incremented.
2. **Grace period** -- After 10 seconds of successful execution, the launch is
   marked as successful and the boot counter resets to zero.
3. **Auto-rollback** -- If the app fails to survive the grace period 3 times
   in a row, the patch is automatically removed on the next launch, reverting
   the app to its base release.

This works on all platforms:

- **Android and Desktop** -- The engine handles crash protection natively in C++.
- **iOS** -- Crash protection runs in Dart (the engine's native updater is
  disabled on iOS due to Apple Clang LTO constraints).

No configuration is needed. Crash protection is always active when a patch is
installed.

## Security

Every patch is verified before installation:

### SHA-256 hash verification (always on)

The engine computes a SHA-256 hash of every downloaded patch and verifies it
against the expected hash. Tampered or corrupted patches are rejected.

### RSA signature verification (optional)

For additional security, you can configure RSA signature verification. When
enabled, the engine verifies that each patch was signed with your private key
before installing it.

**iOS** -- Add your RSA public key to `Info.plist`:

```xml
<key>FLTCodePushPublicKey</key>
<string>-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhki...your key here...
-----END PUBLIC KEY-----</string>
```

**Android** -- Add your RSA public key to `codepush.yaml` in your project root:

```yaml
public_key: |
  -----BEGIN PUBLIC KEY-----
  MIIBIjANBgkqhki...your key here...
  -----END PUBLIC KEY-----
```

When a public key is configured, patches without a valid signature are rejected.
When no public key is configured, signature verification is skipped (SHA-256
hash verification still applies).

## Platform Behavior

| Platform | Patch Type | Restart Required | Live Reload |
|----------|------------|------------------|-------------|
| iOS      | Bytecode   | No (data modules)| Yes         |
| Android  | ELF        | Yes              | No          |
| Desktop  | ELF        | Yes              | No          |

- **iOS**: Bytecode patches are loaded as data modules at runtime. The app does
  not need to restart. Listen to `CodePush.moduleResult` or use
  `CodePushPatchBuilder` to react to live patches.
- **Android and Desktop**: ELF patches are written to disk and loaded by the
  engine on the next cold restart. The `onUpdateReady` callback (or the overlay
  banner) lets you prompt the user to restart.

## Typical Workflow

```
1. fcp codepush login                                        # one-time auth
2. fcp codepush setup                                        # download engine artifacts
3. fcp codepush init                                         # register app on server
4. fcp codepush release --build --platform apk               # upload baseline
5. # ... make code changes ...
6. fcp codepush patch --build --platform apk --release-id <id>  # upload patch
7. App detects update, downloads, installs, and restarts (or live-loads on iOS)
```

## License

BSD 3-Clause. See [LICENSE](LICENSE) for details.
