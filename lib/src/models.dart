import 'package:flutter/foundation.dart';

/// Information about an available code push update.
@immutable
class UpdateInfo {
  /// Creates an [UpdateInfo] instance.
  const UpdateInfo({
    required this.isUpdateAvailable,
    this.patchVersion,
    this.downloadSize,
  });

  /// Whether a new patch is available for download.
  final bool isUpdateAvailable;

  /// The version identifier of the available patch, if any.
  final String? patchVersion;

  /// The size of the patch download in bytes, or null if unknown.
  final int? downloadSize;

  @override
  String toString() => 'UpdateInfo(isUpdateAvailable: $isUpdateAvailable, '
      'patchVersion: $patchVersion, downloadSize: $downloadSize)';
}

/// Information about the currently installed code push patch.
@immutable
class PatchInfo {
  /// Creates a [PatchInfo] instance.
  const PatchInfo({
    required this.version,
    required this.installedAt,
  });

  /// The patch version identifier.
  final String version;

  /// When the patch was installed.
  final DateTime installedAt;

  @override
  String toString() =>
      'PatchInfo(version: $version, installedAt: $installedAt)';
}

/// Exception thrown when a code push operation fails.
class CodePushException implements Exception {
  /// Creates a [CodePushException] with the given [message].
  CodePushException(this.message);

  /// A human-readable description of the error.
  final String message;

  @override
  String toString() => 'CodePushException: $message';
}

/// Structured error raised when the SDK refuses to apply a patch because
/// the running Flutter engine is incompatible with what the patch was
/// built against.
///
/// This guard exists to prevent a SIGSEGV inside the Dart VM (typically
/// `DRT_AllocateObject` reading from `0x10`) that occurs when an AOT
/// snapshot's class layout disagrees with the running VM's view of the
/// world. The mismatch can happen in two realistic ways:
///
///   1. **Engine has no code push support at all.** The baseline on the
///      device was built with a stock Flutter engine (no patchable
///      runtime), but the server still served a patch. The SDK detects
///      this by probing the `flutter/codepush` method channel; if no
///      handler is registered, [actualFingerprint] is null.
///   2. **Engine has code push support but at a different ABI.** Both
///      sides speak the method channel, but the patch was compiled for
///      a different Flutter SDK version (and therefore a different VM
///      class layout). The SDK detects this when the server's
///      `engine_fingerprint` disagrees with the running engine's
///      reported fingerprint.
///
/// In both cases the SDK refuses to load the patch, rolls back any
/// staged bytes, and (best-effort) reports the mismatch back to the
/// server telemetry endpoint so publishers can see how many devices
/// are stranded on incompatible baselines.
@immutable
class IncompatibleBaselineException implements Exception {
  /// Creates an [IncompatibleBaselineException].
  const IncompatibleBaselineException({
    required this.reason,
    this.expectedFingerprint,
    this.actualFingerprint,
  });

  /// Human-readable explanation of why the baseline was rejected.
  final String reason;

  /// The engine fingerprint the server expected (from the release's
  /// recorded Flutter SDK version). Null if the server did not supply
  /// a fingerprint (older servers, or releases created before the
  /// column existed).
  final String? expectedFingerprint;

  /// The engine fingerprint reported by the running Flutter engine.
  /// Null when the engine has no code push support at all (stock
  /// Flutter engine or missing `flutter/codepush` method channel).
  final String? actualFingerprint;

  @override
  String toString() => 'IncompatibleBaselineException: $reason '
      '(expected=${expectedFingerprint ?? "unknown"}, '
      'actual=${actualFingerprint ?? "none"})';
}
