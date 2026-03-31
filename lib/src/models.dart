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
