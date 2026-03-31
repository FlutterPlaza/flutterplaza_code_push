import 'dart:async' show Timer;
import 'dart:convert' show base64Encode;

import 'package:flutter/services.dart';

import 'models.dart';

/// The platform channel used to communicate with the code push engine.
const MethodChannel _channel = MethodChannel('flutter/codepush');

/// Service for managing over-the-air code push updates.
///
/// Code push allows pushing Dart code changes to deployed apps without
/// requiring App Store or Play Store review. This class provides methods
/// to check for updates, download and apply patches, query the current
/// patch status, and roll back to the previous version.
///
/// All methods communicate with the native engine through the
/// `flutter/codepush` platform channel, which is handled by the
/// custom FlutterPlaza code push engine.
///
/// ```dart
/// final update = await CodePush.checkForUpdate();
/// if (update.isUpdateAvailable) {
///   await CodePush.downloadAndApply(
///     onProgress: (progress) => print('Download: ${(progress * 100).toInt()}%'),
///   );
/// }
/// ```
abstract final class CodePush {
  /// Checks the code push server for available updates.
  ///
  /// Returns an [UpdateInfo] describing whether an update is available and
  /// its metadata.
  ///
  /// Throws a [CodePushException] if the check fails (e.g., network error).
  static Future<UpdateInfo> checkForUpdate() async {
    final Map<String, dynamic>? result =
        await _channel.invokeMapMethod<String, dynamic>(
      'CodePush.checkForUpdate',
    );
    if (result == null) {
      throw CodePushException(
        'Failed to check for update: no response from engine.',
      );
    }
    return UpdateInfo(
      isUpdateAvailable: result['isUpdateAvailable'] as bool? ?? false,
      patchVersion: result['patchVersion'] as String?,
      downloadSize: result['downloadSize'] as int?,
    );
  }

  /// Downloads and applies the latest available patch.
  ///
  /// The optional [onProgress] callback is called with a value between 0.0
  /// and 1.0 representing the download progress.
  ///
  /// The patch will take effect on the next app restart.
  ///
  /// Throws a [CodePushException] if the download or application fails.
  static Future<void> downloadAndApply({
    ValueChanged<double>? onProgress,
  }) async {
    if (onProgress != null) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'CodePush.downloadProgress') {
          final double progress = (call.arguments as num).toDouble();
          onProgress(progress);
        }
        return null;
      });
    }

    try {
      final bool? success = await _channel.invokeMethod<bool>(
        'CodePush.downloadAndApply',
      );
      if (success != true) {
        throw CodePushException('Failed to download and apply patch.');
      }
    } finally {
      if (onProgress != null) {
        _channel.setMethodCallHandler(null);
      }
    }
  }

  /// Returns information about the currently installed patch, or null if
  /// no patch is active.
  static Future<PatchInfo?> get currentPatch async {
    final Map<String, dynamic>? result =
        await _channel.invokeMapMethod<String, dynamic>(
      'CodePush.getCurrentPatch',
    );
    if (result == null) {
      return null;
    }
    return PatchInfo(
      version: result['version'] as String,
      installedAt: DateTime.fromMillisecondsSinceEpoch(
        result['installedAt'] as int,
      ),
    );
  }

  /// Returns whether the app is currently running with a code push patch.
  static Future<bool> get isPatched async {
    final bool? result = await _channel.invokeMethod<bool>(
      'CodePush.isPatched',
    );
    return result ?? false;
  }

  /// Rolls back to the previous version by removing the active patch.
  ///
  /// The rollback takes effect on the next app restart.
  ///
  /// Throws a [CodePushException] if the rollback fails.
  static Future<void> rollback() async {
    final bool? success = await _channel.invokeMethod<bool>(
      'CodePush.rollback',
    );
    if (success != true) {
      throw CodePushException('Failed to roll back patch.');
    }
  }

  /// Installs a patch from raw bytes.
  ///
  /// The [patchBytes] must be a valid `.vmcode` file. The engine verifies
  /// the patch integrity (SHA-256 hash, optional RSA signature) before
  /// installing it.
  ///
  /// This is useful when the app downloads the patch itself (e.g., using
  /// `dart:io` HttpClient or the `http` package) and wants to install it
  /// directly.
  ///
  /// The patch takes effect on the next app restart.
  ///
  /// Throws a [CodePushException] if verification or installation fails.
  static Future<void> installPatch(Uint8List patchBytes) async {
    final String base64Data = base64Encode(patchBytes);
    final bool? success = await _channel.invokeMethod<bool>(
      'CodePush.installPatch',
      <String>[base64Data],
    );
    if (success != true) {
      throw CodePushException(
        'Failed to install patch: verification failed or write error.',
      );
    }
  }

  /// Returns the release version string that this app build corresponds to.
  static Future<String> get releaseVersion async {
    final String? version = await _channel.invokeMethod<String>(
      'CodePush.getReleaseVersion',
    );
    return version ?? '';
  }

  /// Requests the engine to clean up old, inactive patches from local storage.
  ///
  /// This frees disk space by removing patches that are no longer active.
  /// The currently active patch (if any) is never removed.
  ///
  /// Returns the number of patches removed, or 0 if none were cleaned up.
  static Future<int> cleanupOldPatches() async {
    final int? removed = await _channel.invokeMethod<int>(
      'CodePush.cleanupOldPatches',
    );
    return removed ?? 0;
  }

  /// Starts periodic background checks for code push updates.
  ///
  /// Checks the server every [interval] for new patches. When an update
  /// is found, [onUpdateAvailable] is called with the [UpdateInfo].
  ///
  /// Returns a [Timer] that can be cancelled to stop periodic checks.
  ///
  /// ```dart
  /// final timer = CodePush.checkForUpdatePeriodically(
  ///   interval: Duration(hours: 4),
  ///   onUpdateAvailable: (update) {
  ///     print('Update available: ${update.patchVersion}');
  ///   },
  /// );
  /// // Later: timer.cancel();
  /// ```
  static Timer checkForUpdatePeriodically({
    required Duration interval,
    required ValueChanged<UpdateInfo> onUpdateAvailable,
  }) {
    return Timer.periodic(interval, (_) async {
      try {
        final UpdateInfo update = await checkForUpdate();
        if (update.isUpdateAvailable) {
          onUpdateAvailable(update);
        }
      } on CodePushException {
        // Silently ignore check failures during periodic checks.
      }
    });
  }

  /// Returns the number of patches currently stored on the device.
  ///
  /// This includes both active and inactive patches waiting to be cleaned up.
  static Future<int> get patchCount async {
    final int? count = await _channel.invokeMethod<int>(
      'CodePush.getPatchCount',
    );
    return count ?? 0;
  }
}
