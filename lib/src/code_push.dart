import 'dart:async' show Timer;
import 'dart:convert' show base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io' show Directory, File, HttpClient, Platform, exit;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// The platform channel used to communicate with the code push engine.
/// The engine handler parses messages as JSON, so we must use JSONMethodCodec
/// instead of the default StandardMethodCodec (binary).
const MethodChannel _channel =
    MethodChannel('flutter/codepush', JSONMethodCodec());

/// Service for managing over-the-air code push updates.
///
/// Provides both low-level methods (check, install, rollback) and a
/// high-level [init] method that handles the entire update lifecycle
/// automatically.
///
/// ## Quick start
///
/// ```dart
/// // In your app's root widget:
/// CodePush.init(
///   serverUrl: 'https://api.codepush.flutterplaza.com',
///   appId: 'your-app-id',
///   releaseVersion: '1.0.0+1',
/// );
/// ```
///
/// Or wrap your app with [CodePushOverlay] for the update-ready banner:
///
/// ```dart
/// CodePushOverlay(
///   config: CodePushConfig(
///     serverUrl: 'https://api.codepush.flutterplaza.com',
///     appId: 'your-app-id',
///     releaseVersion: '1.0.0+1',
///   ),
///   child: MyApp(),
/// )
/// ```
abstract final class CodePush {
  static Timer? _timer;
  static Timer? _launchTimer;

  /// Maximum consecutive failed boots before auto-rollback.
  static const int _maxBootAttempts = 3;

  /// Seconds to wait before declaring a launch successful.
  static const int _launchGracePeriodSeconds = 10;

  /// Cached patch directory path from the engine.
  static String? _cachedPatchDir;

  /// Debug status notifier — shows what code push is doing.
  static final ValueNotifier<String> status = ValueNotifier('init');

  /// The result from the last loaded module.
  ///
  /// On iOS, bytecode modules return a JSON string which is auto-parsed
  /// into a `Map<String, dynamic>`. Apps can listen to this to apply
  /// OTA patches to their UI.
  static final ValueNotifier<Object?> moduleResult = ValueNotifier(null);
  static Object? _lastModuleResult;
  static bool _moduleLoaded = false;

  /// Initializes automatic code push update checking with crash protection.
  ///
  /// Call this once in your app's startup. It will:
  /// 1. Run crash protection checks (auto-rollback if needed)
  /// 2. Check for updates immediately
  /// 3. Check periodically at the given [interval]
  /// 4. Check on app resume from background
  /// 5. Report launch success after [_launchGracePeriodSeconds]
  ///
  /// When a patch is installed, [onUpdateReady] is called so you can
  /// prompt the user to restart.
  static void init({
    required String serverUrl,
    required String appId,
    required String releaseVersion,
    Duration interval = const Duration(hours: 4),
    String channel = 'production',
    VoidCallback? onUpdateReady,
  }) {
    _timer?.cancel();

    // Crash protection runs async because it needs the engine's patch dir
    // via platform channel. We fire-and-forget — it must not block init.
    _runCrashProtection().then((_) {
      // Start launch success timer only after crash protection completes,
      // so a rollback doesn't get immediately overwritten by a success report.
      _startLaunchTimer();
    });

    _timer = Timer.periodic(interval, (_) {
      checkAndInstall(
        serverUrl: serverUrl,
        appId: appId,
        releaseVersion: releaseVersion,
        channel: channel,
        onUpdateReady: onUpdateReady,
      );
    });
    // Check immediately on init.
    checkAndInstall(
      serverUrl: serverUrl,
      appId: appId,
      releaseVersion: releaseVersion,
      channel: channel,
      onUpdateReady: onUpdateReady,
    );
  }

  /// Stops automatic update checking and cancels the launch timer.
  static void dispose() {
    _timer?.cancel();
    _timer = null;
    _launchTimer?.cancel();
    _launchTimer = null;
  }

  /// Checks the server for updates, downloads and installs if available.
  ///
  /// Returns `true` if a patch was installed (restart needed).
  static Future<bool> checkAndInstall({
    required String serverUrl,
    required String appId,
    required String releaseVersion,
    String channel = 'production',
    VoidCallback? onUpdateReady,
  }) async {
    try {
      status.value = 'Checking server...';
      final url = '$serverUrl/api/v1/updates'
          '?app_id=$appId'
          '&version=${Uri.encodeComponent(releaseVersion)}'
          '&platform=$_platform'
          '&channel=$channel';

      final r = await _httpGet(url);
      if (r.statusCode == 204 || r.statusCode != 200) {
        status.value = 'No update (${r.statusCode})';
        return false;
      }

      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['patch_available'] != true) {
        status.value = 'No patch available';
        return false;
      }

      final patchId = data['patch_id']?.toString();
      final patchUrl = data['patch_url'] as String?;
      if (patchUrl == null || patchUrl.isEmpty) {
        status.value = 'No patch URL';
        return false;
      }

      status.value = 'Downloading patch...';
      final dlR = await _httpGetBytes(patchUrl);
      if (dlR.statusCode != 200) {
        status.value = 'Download failed (${dlR.statusCode})';
        return false;
      }
      final patchBytes = Uint8List.fromList(dlR.bytes);
      if (patchBytes.isEmpty) {
        status.value = 'Empty patch';
        return false;
      }

      status.value = 'Installing (${patchBytes.length}B)...';
      if (Platform.isIOS) {
        if (_moduleLoaded) {
          status.value = 'Patch active';
          return false; // Already loaded this session.
        }
        await _installPatchFromDart(patchBytes);
        try {
          // Extract the payload from the patch wrapper.
          final offsetBytes = patchBytes.buffer.asByteData();
          final payloadOffset = offsetBytes.getUint32(12, Endian.little);
          final payload = patchBytes.sublist(payloadOffset);

          // Check if payload is ELF (can't load on iOS) or bytecode
          final isELF = payload.length > 4 &&
              payload[0] == 0x7f && payload[1] == 0x45 &&
              payload[2] == 0x4c && payload[3] == 0x46;
          if (isELF) {
            status.value = 'Patch is ELF (needs bytecode for iOS). Restart required.';
            onUpdateReady?.call();
            return true;
          }
          status.value = 'Loading module...';
          final rawResult = await ui.codePushLoadModule(Uint8List.fromList(payload));

          // If the engine returns null/false, the module failed to load
          // (bad bytecode, version mismatch, verification failure).
          // Delete the patch immediately instead of waiting for 3-boot
          // auto-rollback.
          if (rawResult == null || rawResult == false) {
            status.value = 'Module load failed — rolling back patch';
            await _iosImmediateRollback(
              serverUrl: serverUrl,
              appId: appId,
              patchId: patchId,
              errorMessage:
                  'loadDynamicModule returned ${rawResult ?? "null"} — deleted immediately',
            );
            return false;
          }

          // Module loaded live — no restart needed on iOS.
          // Auto-parse JSON strings into Map/List for structured data.
          Object? result = rawResult;
          if (rawResult is String) {
            try {
              final parsed = jsonDecode(rawResult);
              if (parsed is Map || parsed is List) result = parsed;
            } catch (_) {
              // Not JSON — keep as raw string.
            }
          }
          _lastModuleResult = result;
          _moduleLoaded = true;
          moduleResult.value = result;
          status.value = 'Patch active';
          return true;
        } catch (e) {
          status.value = 'Module error: $e — rolling back patch';
          // Patch is bad (corrupt bytecode, exception during load, etc.).
          // Delete immediately instead of retrying for 3 boots.
          await _iosImmediateRollback(
            serverUrl: serverUrl,
            appId: appId,
            patchId: patchId,
            errorMessage:
                'loadDynamicModule threw $e — deleted immediately',
          );
          return false;
        }
      } else {
        // Android/desktop: install via engine, restart required.
        await installPatch(patchBytes);
        status.value = 'Restart to apply';
        onUpdateReady?.call();
        return true;
      }
    } catch (e) {
      status.value = 'Error: $e';
      return false;
    }
  }

  /// Kills the app process for a cold restart.
  ///
  /// On next launch, the engine will load the installed patch.
  /// This is the only way to apply a patch — warm resumes don't
  /// re-initialize the Dart VM.
  static void restart() => exit(0);

  // ── Low-level engine API ────────────────────────────────────────

  /// Checks the engine for available updates (delegates to Dart side HTTP).
  static Future<UpdateInfo> checkForUpdate() async {
    try {
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
        isUpdateAvailable: result['isUpdateAvailable'] == true,
        patchVersion: result['patchVersion']?.toString(),
        downloadSize: result['downloadSize'] is int
            ? result['downloadSize'] as int
            : null,
      );
    } on CodePushException {
      rethrow;
    } catch (e) {
      throw CodePushException('Update check failed: $e');
    }
  }

  /// Installs a patch from raw bytes.
  ///
  /// The [patchBytes] must be a valid `.vmcode` file. The engine verifies
  /// the patch integrity (SHA-256 hash, optional RSA signature) before
  /// installing it.
  ///
  /// The patch takes effect on the next cold restart.
  static Future<void> installPatch(Uint8List patchBytes) async {
    final String base64Data = base64Encode(patchBytes);
    final result = await _channel.invokeMethod<dynamic>(
      'CodePush.installPatch',
      <String>[base64Data],
    );
    if (result != true) {
      throw CodePushException(
        'Failed to install patch${result is String ? ": $result" : ""}',
      );
    }
  }

  /// Returns information about the currently installed patch, or null if
  /// no patch is active.
  static Future<PatchInfo?> get currentPatch async {
    final Map<String, dynamic>? result =
        await _channel.invokeMapMethod<String, dynamic>(
      'CodePush.getCurrentPatch',
    );
    if (result == null) return null;
    return PatchInfo(
      version: result['version'] as String,
      installedAt: DateTime.fromMillisecondsSinceEpoch(
        result['installedAt'] as int,
      ),
    );
  }

  /// Returns whether the app is currently running with a code push patch.
  ///
  /// Returns `false` if the code push engine is not available.
  static Future<bool> get isPatched async {
    try {
      return await _channel.invokeMethod<bool>('CodePush.isPatched') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Rolls back to the previous version by removing the active patch.
  /// Takes effect on next cold restart. On iOS (where the engine updater
  /// is disabled), removes the patch file directly from Dart.
  static Future<void> rollback() async {
    // Try engine-side rollback first (works on Android/desktop).
    try {
      final bool? success =
          await _channel.invokeMethod<bool>('CodePush.rollback');
      if (success == true) return;
    } catch (_) {}

    // Dart-side rollback for iOS (engine updater is null).
    final patchDir = await _getPatchDir();
    if (patchDir == null) {
      throw CodePushException('No patch directory configured.');
    }
    final patchFile = File('$patchDir/patch.vmcode');
    if (!patchFile.existsSync()) {
      throw CodePushException('No active patch to roll back.');
    }
    patchFile.deleteSync();
    final infoFile = File('$patchDir/patch_info.json');
    if (infoFile.existsSync()) infoFile.deleteSync();
    _iosResetBootCounter(patchDir);
    _moduleLoaded = false;
    _lastModuleResult = null;
    moduleResult.value = null;
  }

  /// Returns the release version string from the engine config.
  static Future<String> get releaseVersion async {
    return await _channel.invokeMethod<String>('CodePush.getReleaseVersion') ??
        '';
  }

  /// Downloads and applies the latest patch from the engine.
  ///
  /// Throws [CodePushException] if the download or application fails.
  static Future<void> downloadAndApply() async {
    final result =
        await _channel.invokeMethod<bool>('CodePush.downloadAndApply');
    if (result != true) {
      throw CodePushException('Failed to download and apply patch.');
    }
  }

  /// Removes old patch files, returning the number of patches removed.
  static Future<int> cleanupOldPatches() async {
    return await _channel.invokeMethod<int>('CodePush.cleanupOldPatches') ?? 0;
  }

  /// Returns the number of installed patches.
  static Future<int> get patchCount async {
    return await _channel.invokeMethod<int>('CodePush.getPatchCount') ?? 0;
  }

  /// Periodically checks for updates and calls [onUpdateAvailable] when one
  /// is found. Returns a [Timer] that can be cancelled to stop checking.
  static Timer checkForUpdatePeriodically({
    required Duration interval,
    required void Function(UpdateInfo update) onUpdateAvailable,
  }) {
    return Timer.periodic(interval, (_) async {
      try {
        final info = await checkForUpdate();
        if (info.isUpdateAvailable) {
          onUpdateAvailable(info);
        }
      } catch (_) {}
    });
  }

  // ── Private helpers ─────────────────────────────────────────────

  /// iOS-only: write patch directly from Dart to bypass engine C++ file I/O
  /// which breaks Apple Clang LTO.
  static Future<void> _installPatchFromDart(Uint8List patchBytes) async {
    // Ask the engine for its configured patch directory path.
    final patchDir = await _channel.invokeMethod<String>('CodePush.getPatchDir');
    if (patchDir == null || patchDir.isEmpty) {
      throw CodePushException('Engine returned no patch directory.');
    }

    final dir = Directory(patchDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final file = File('$patchDir/patch.vmcode');
    await file.writeAsBytes(patchBytes, flush: true);
  }

  static String get _platform {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }

  // ── Crash protection ──────────────────────────────────────────────

  /// Runs crash protection on startup.
  ///
  /// On iOS, the engine's C++ Updater is disabled (Apple Clang LTO issue),
  /// so we handle the boot counter entirely in Dart. On other platforms,
  /// the engine handles it natively — we just start the launch timer so
  /// Dart can signal success back via the platform channel.
  static Future<void> _runCrashProtection() async {
    if (!Platform.isIOS) return; // Engine handles non-iOS.
    try {
      final patchDir = await _getPatchDir();
      if (patchDir == null) return;
      final patchFile = File('$patchDir/patch.vmcode');
      if (!patchFile.existsSync()) return; // No patch, nothing to protect.

      if (_iosCheckAndAutoRollback(patchDir)) {
        status.value = 'Auto-rolled back (crash loop detected)';
      } else {
        _iosIncrementBootCounter(patchDir);
      }
    } catch (e) {
      // Crash protection must never itself crash the app.
      status.value = 'Crash protection error: $e';
    }
  }

  /// Starts a timer that reports a successful launch after a grace period.
  static void _startLaunchTimer() {
    _launchTimer?.cancel();
    _launchTimer = Timer(
      Duration(seconds: _launchGracePeriodSeconds),
      _reportLaunchSuccess,
    );
  }

  /// Reports a successful launch to the engine (resets boot counter).
  static Future<void> _reportLaunchSuccess() async {
    try {
      await _channel.invokeMethod<dynamic>('CodePush.reportLaunchSuccess');
    } catch (_) {
      // Engine updater may be null (iOS). Handle in Dart.
    }
    // Also reset in Dart for iOS.
    if (Platform.isIOS) {
      try {
        final patchDir = await _getPatchDir();
        if (patchDir != null) _iosResetBootCounter(patchDir);
      } catch (_) {}
    }
  }

  /// iOS-only: immediately deletes the patch and reports failure to the server
  /// when [ui.codePushLoadModule] fails. This avoids waiting for the 3-boot
  /// auto-rollback threshold — the bad patch is removed on first attempt.
  static Future<void> _iosImmediateRollback({
    required String serverUrl,
    required String appId,
    required String? patchId,
    required String errorMessage,
  }) async {
    // 1. Delete the patch files from disk.
    try {
      final patchDir = await _getPatchDir();
      if (patchDir != null) {
        final patchFile = File('$patchDir/patch.vmcode');
        if (await patchFile.exists()) await patchFile.delete();
        final infoFile = File('$patchDir/patch_info.json');
        if (await infoFile.exists()) await infoFile.delete();
        _iosResetBootCounter(patchDir);
      }
    } catch (_) {
      // Never crash the app over cleanup — engine rollback is the safety net.
    }

    // 2. Tell the engine to reset its internal state / boot counter.
    try {
      await _channel.invokeMethod<dynamic>('CodePush.rollback');
    } catch (_) {}

    // 3. Reset in-memory module state so the app runs on baseline.
    _moduleLoaded = false;
    _lastModuleResult = null;
    moduleResult.value = null;

    // 4. Report the failure to the server (fire-and-forget).
    try {
      await _httpPostJson('$serverUrl/api/v1/telemetry/device-report', {
        'app_id': appId,
        'patch_id': patchId,
        'success': false,
        'platform': 'ios',
        'error_message': errorMessage,
      });
    } catch (_) {
      // Telemetry is best-effort — never block the app.
    }
  }

  // ── iOS-only boot counter (Dart-side, since engine updater is disabled) ──

  /// Gets the patch directory, checking the local filesystem first (fast)
  /// then falling back to the engine platform channel.
  ///
  /// On iOS the engine updater is disabled, so we check the standard
  /// Application Support path first. This avoids waiting for a platform
  /// channel timeout when the custom engine isn't present.
  static Future<String?> _getPatchDir() async {
    if (_cachedPatchDir != null) return _cachedPatchDir;
    // Try the engine's platform channel first (fast when available).
    try {
      final dir = await _channel.invokeMethod<String>('CodePush.getPatchDir');
      if (dir != null && dir.isNotEmpty) {
        _cachedPatchDir = dir;
        return dir;
      }
    } catch (_) {}
    // Fallback for iOS when the custom engine isn't present.
    // Directory.systemTemp on iOS returns <data-container>/tmp/.
    // The data container root is the parent of tmp.
    if (Platform.isIOS) {
      try {
        final dataContainer = Directory.systemTemp.parent.path;
        final local = '$dataContainer/Library/Application Support/code_push';
        if (Directory(local).existsSync()) {
          _cachedPatchDir = local;
          return local;
        }
      } catch (_) {}
    }
    return null;
  }

  static int _iosReadBootCounter(String patchDir) {
    try {
      final file = File('$patchDir/boot_counter');
      if (!file.existsSync()) return 0;
      return int.tryParse(file.readAsStringSync().trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static void _iosWriteBootCounter(String patchDir, int count) {
    try {
      final dir = Directory(patchDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('$patchDir/boot_counter').writeAsStringSync('$count');
    } catch (_) {}
  }

  static void _iosIncrementBootCounter(String patchDir) {
    _iosWriteBootCounter(patchDir, _iosReadBootCounter(patchDir) + 1);
  }

  static void _iosResetBootCounter(String patchDir) {
    _iosWriteBootCounter(patchDir, 0);
  }

  /// Returns true if a rollback was performed.
  static bool _iosCheckAndAutoRollback(String patchDir) {
    final count = _iosReadBootCounter(patchDir);
    if (count < _maxBootAttempts) return false;

    // Auto-rollback: remove the patch and reset the counter.
    try {
      final patchFile = File('$patchDir/patch.vmcode');
      if (patchFile.existsSync()) patchFile.deleteSync();
      final infoFile = File('$patchDir/patch_info.json');
      if (infoFile.existsSync()) infoFile.deleteSync();
      _iosResetBootCounter(patchDir);
    } catch (_) {}
    return true;
  }
}

/// Configuration for [CodePushOverlay].
@immutable
class CodePushConfig {
  const CodePushConfig({
    required this.serverUrl,
    required this.appId,
    required this.releaseVersion,
    this.checkInterval = const Duration(hours: 4),
    this.channel = 'production',
  });

  final String serverUrl;
  final String appId;
  final String releaseVersion;
  final Duration checkInterval;
  final String channel;
}

/// A widget that wraps your app and shows an update-ready banner
/// when a code push patch has been downloaded and installed.
///
/// ```dart
/// runApp(
///   CodePushOverlay(
///     config: CodePushConfig(
///       serverUrl: 'https://api.codepush.flutterplaza.com',
///       appId: 'your-app-id',
///       releaseVersion: '1.0.0+1',
///     ),
///     child: MyApp(),
///   ),
/// );
/// ```
class CodePushOverlay extends StatefulWidget {
  const CodePushOverlay({
    super.key,
    required this.config,
    required this.child,
    this.bannerBuilder,
    this.showDebugBar = false,
  });

  /// Code push configuration.
  final CodePushConfig config;

  /// The app widget.
  final Widget child;

  /// Optional custom banner builder. If null, uses the default banner.
  /// Return `null` to hide the banner.
  final Widget Function(BuildContext context, VoidCallback onRestart,
      VoidCallback onDismiss)? bannerBuilder;

  /// Whether to show the debug status bar at the top. Defaults to false.
  final bool showDebugBar;

  @override
  State<CodePushOverlay> createState() => _CodePushOverlayState();
}

class _CodePushOverlayState extends State<CodePushOverlay>
    with WidgetsBindingObserver {
  bool _updateReady = false;
  bool _patchActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CodePush.moduleResult.addListener(_onModuleLoaded);
    CodePush.init(
      serverUrl: widget.config.serverUrl,
      appId: widget.config.appId,
      releaseVersion: widget.config.releaseVersion,
      interval: widget.config.checkInterval,
      channel: widget.config.channel,
      onUpdateReady: () {
        if (mounted) setState(() => _updateReady = true);
      },
    );
  }

  void _onModuleLoaded() {
    if (CodePush.moduleResult.value != null && mounted) {
      setState(() => _patchActive = true);
    }
  }

  @override
  void dispose() {
    CodePush.moduleResult.removeListener(_onModuleLoaded);
    CodePush.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      CodePush.checkAndInstall(
        serverUrl: widget.config.serverUrl,
        appId: widget.config.appId,
        releaseVersion: widget.config.releaseVersion,
        channel: widget.config.channel,
        onUpdateReady: () {
          if (mounted) setState(() => _updateReady = true);
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,
          if (widget.showDebugBar && !_patchActive)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<String>(
                valueListenable: CodePush.status,
                builder: (_, status, __) => GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: 'CP: $status'));
                  },
                  child: Container(
                    color: const Color(0xFF1A237E),
                    padding: const EdgeInsets.fromLTRB(12, 50, 12, 6),
                    child: Text('CP: $status',
                        style: const TextStyle(color: Colors.white, fontSize: 11, decoration: TextDecoration.none)),
                  ),
                ),
              ),
            ),
          if (_updateReady)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 16,
            child: widget.bannerBuilder != null
                ? widget.bannerBuilder!(
                    context,
                    CodePush.restart,
                    () => setState(() => _updateReady = false),
                  )!
                : _DefaultUpdateBanner(
                    onRestart: CodePush.restart,
                    onDismiss: () => setState(() => _updateReady = false),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DefaultUpdateBanner extends StatelessWidget {
  const _DefaultUpdateBanner({
    required this.onRestart,
    required this.onDismiss,
  });

  final VoidCallback onRestart;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface,
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.system_update, size: 20),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Update ready. Restart to apply.'),
            ),
            TextButton(
              onPressed: onDismiss,
              child: const Text('LATER'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: onRestart,
              child: const Text('RESTART'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A widget that rebuilds when a code push module result is available.
///
/// Use this to apply OTA patches to specific parts of your UI.
///
/// ```dart
/// CodePushPatchBuilder(
///   patchKey: 'settings_banner',
///   builder: (context, patchData, child) {
///     if (patchData == null) return child!;
///     final parts = patchData.split('|');
///     return Text(parts[0]);
///   },
///   child: Text('Default content'),
/// )
/// ```
class CodePushPatchBuilder extends StatelessWidget {
  const CodePushPatchBuilder({
    super.key,
    this.patchKey,
    required this.builder,
    this.child,
  });

  /// Optional key to filter which patch data this builder responds to.
  /// If the module result is a pipe-delimited string starting with this key,
  /// the remaining data is passed to the builder. If null, all results
  /// are passed through.
  final String? patchKey;

  /// Builder called with the patch data string (or null if no patch).
  final Widget Function(BuildContext context, String? patchData, Widget? child) builder;

  /// Optional child widget passed to the builder (typically the default/baseline UI).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: CodePush.moduleResult,
      builder: (context, result, _) {
        if (result is String && result.isNotEmpty) {
          if (patchKey != null) {
            if (result.startsWith('$patchKey:')) {
              return builder(context, result.substring(patchKey!.length + 1), child);
            }
            return builder(context, null, child);
          }
          return builder(context, result, child);
        }
        return builder(context, null, child);
      },
    );
  }
}

// ── HTTP helpers (run in isolates) ────────────────────────────────────

class _HttpResult {
  final int statusCode;
  final String body;
  final List<int> bytes;
  _HttpResult(this.statusCode, this.body, this.bytes);
}

Future<_HttpResult> _httpGet(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    return _HttpResult(response.statusCode, utf8.decode(bytes), bytes);
  } finally {
    client.close();
  }
}

Future<_HttpResult> _httpGetBytes(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    return _HttpResult(response.statusCode, '', bytes);
  } finally {
    client.close();
  }
}

Future<_HttpResult> _httpPostJson(String url, Map<String, dynamic> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(Uri.parse(url));
    request.headers.set('Content-Type', 'application/json');
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk));
    return _HttpResult(response.statusCode, utf8.decode(bytes), bytes);
  } finally {
    client.close();
  }
}
