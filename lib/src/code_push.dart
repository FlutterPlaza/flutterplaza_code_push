import 'dart:async' show Timer;
import 'dart:convert' show base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io' show Directory, File, FileMode, HttpClient, Platform, exit;

import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// The platform channel used to communicate with the code push engine.
const MethodChannel _channel = MethodChannel(
  'flutter/codepush',
  JSONMethodCodec(),
);

/// Channel for the SDK's own native plugin (reads Info.plist, etc.).
const MethodChannel _pluginChannel = MethodChannel('flutterplaza_code_push');

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
  /// Default code push server URL. Apps that target the FlutterPlaza
  /// production service can omit `serverUrl` in [init] and
  /// [CodePushConfig] and this constant will be used.
  static const String defaultServerUrl =
      'https://api.codepush.flutterplaza.com';

  /// The config passed to the most recent [init] call, if any.
  ///
  /// [CodePushOverlay] reads this as a fallback when its own `config`
  /// parameter is omitted, so callers that run `CodePush.init(...)` at
  /// the top of `main()` don't have to repeat the same config in their
  /// `CodePushOverlay(...)` wrapper.
  static CodePushConfig? lastConfig;

  static Timer? _timer;
  static Timer? _launchTimer;

  /// Maximum consecutive failed boots before auto-rollback.
  static const int _maxBootAttempts = 3;

  /// Seconds to wait before declaring a launch successful.
  static const int _launchGracePeriodSeconds = 10;

  /// Cached patch directory path from the engine.
  static String? _cachedPatchDir;

  /// On-disk filename of the active patch. Differs by platform so
  /// each platform's load path can find its own artifact.
  static String get _patchFilename =>
      Platform.isIOS ? 'patch.bytecode' : 'patch.vmcode';

  /// Expected first 4 bytes of every iOS patch payload after
  /// unwrapping the on-disk header. Opaque format marker.
  static const List<int> _iosPayloadHeader = <int>[0x33, 0x43, 0x42, 0x44];

  /// Debug status notifier — shows what code push is doing.
  static final ValueNotifier<String> status = ValueNotifier('init');

  /// The result from the last loaded module.
  ///
  /// On iOS, bytecode modules return a JSON string which is auto-parsed
  /// into a `Map<String, dynamic>`. Apps can listen to this to apply
  /// OTA patches to their UI.
  static final ValueNotifier<Object?> moduleResult = ValueNotifier(null);
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
    String serverUrl = defaultServerUrl,
    required String appId,
    required String releaseVersion,
    Duration interval = const Duration(hours: 4),
    String channel = 'production',
    VoidCallback? onUpdateReady,
  }) {
    print('[CP-INIT] CodePush.init called');
    // Store the config so `CodePushOverlay` can reuse it without
    // forcing the caller to repeat every field at the widget level.
    lastConfig = CodePushConfig(
      serverUrl: serverUrl,
      appId: appId,
      releaseVersion: releaseVersion,
      checkInterval: interval,
      channel: channel,
    );

    // NOTE: Any stale-patch cleanup from prior versions (0.1.4/0.1.5)
    // was unreachable on iOS — it ran inside `init()`, which runs
    // inside `main()`, and on the crash path `main()` never executes.
    // The 0.1.6 fix moved cleanup to native iOS `+load`
    // (FlutterplazaCodePushBootCleanup.m) which runs during dyld image
    // load, before the Flutter engine boots. See CHANGELOG.

    _timer?.cancel();

    // Crash protection runs async because it needs the engine's patch
    // dir via platform channel. We chain the first checkAndInstall off
    // it so that, on a boot where a previously-downloaded bad patch is
    // on disk, the three-strike auto-rollback machinery has already
    // run before we download and overwrite that file with a fresh
    // (possibly equally bad) patch. Prior versions fired checkAndInstall
    // unconditionally on init which left no room for the boot counter
    // to trip — see CHANGELOG 0.1.7 for the race condition this fixes.
    _runCrashProtection().then((_) {
      // Start launch success timer only after crash protection completes,
      // so a rollback doesn't get immediately overwritten by a success report.
      _startLaunchTimer();

      // Report any rollback that was recorded natively before Dart started
      // (crash-loop protection runs before main(), so without this the
      // server never hears about it). Best-effort, fire-and-forget.
      _reportPendingNativeRollback(serverUrl: serverUrl, appId: appId);

      // Immediate check is now *after* crash protection so a bad patch
      // on disk gets a chance to increment the boot counter before we
      // replace it.
      checkAndInstall(
        serverUrl: serverUrl,
        appId: appId,
        releaseVersion: releaseVersion,
        channel: channel,
        onUpdateReady: onUpdateReady,
      );
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
      print('[CP] checkAndInstall start');
      status.value = 'Checking server...';
      // Compute the baseline hash once, up front, so it can be
      // included in the /updates query. The server uses it as a
      // belt-and-suspenders gate: if the patch on file has a
      // recorded baseline hash that disagrees with ours, the server
      // returns 204 instead of a crash-inducing patch. Older servers
      // ignore the parameter and the SDK-side load-time check
      // (further down) still protects us.
      final deviceBaselineHash = await _computeBaselineHash();
      final deviceBaselineId = await _readBaselineId();
      final url = '$serverUrl/api/v1/updates'
          '?app_id=$appId'
          '&version=${Uri.encodeComponent(releaseVersion)}'
          '&platform=$_platform'
          '&channel=$channel'
          '${deviceBaselineHash != null ? '&baseline_hash=$deviceBaselineHash' : ''}'
          '${deviceBaselineId != null ? '&baseline_id=$deviceBaselineId' : ''}';

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

      // Check if this patch was previously rolled back.  The rollback
      // marker persists across cold starts so the same bad patch isn't
      // re-downloaded in a crash loop.
      if (Platform.isIOS) {
        final patchDir = await _getPatchDir();
        if (patchDir != null) {
          final rbFile = File('$patchDir/rolled_back_patch');
          if (rbFile.existsSync()) {
            try {
              final rb =
                  jsonDecode(rbFile.readAsStringSync()) as Map<String, dynamic>;
              final rbId = rb['patch_id']?.toString();
              final rbHash = rb['patch_hash']?.toString();
              final serverPatchId = patchId;
              final serverPatchHash = data['patch_hash']?.toString();
              final idMatch = rbId != null && rbId == serverPatchId;
              final hashMatch = rbHash != null &&
                  serverPatchHash != null &&
                  rbHash == serverPatchHash;
              print(
                '[CP] rollback check: rbId=$rbId serverId=$serverPatchId '
                'idMatch=$idMatch rbHash=${rbHash?.substring(0, 8)}... '
                'serverHash=${serverPatchHash?.substring(0, 8)}... '
                'hashMatch=$hashMatch',
              );
              if (idMatch || hashMatch) {
                status.value = 'Skipping rolled-back patch $patchId';
                print('[CP] SKIPPING rolled-back patch');
                return false;
              }
              // Different patch — clear the old rollback marker.
              rbFile.deleteSync();
            } catch (e) {
              // Corrupt marker — delete and continue.
              print('[CP] rollback marker read error: $e');
              try {
                rbFile.deleteSync();
              } catch (_) {}
            }
          }
        }
      }

      // ── Baseline compatibility guard ────────────────────────────
      //
      // Before touching any bytes, verify that the running Flutter
      // engine is a code-push-capable Flutter engine and — if the
      // server supplies an `engine_fingerprint` — that the patch was
      // built for the same Flutter SDK version.
      final actualEngineFingerprint = await _probeEngineFingerprint();
      final expectedEngineFingerprint = data['engine_fingerprint'] as String?;
      print(
        '[CP] fingerprint=$actualEngineFingerprint '
        'expected=$expectedEngineFingerprint',
      );

      if (actualEngineFingerprint == null) {
        status.value = 'Incompatible baseline: engine has no code push support';
        await _reportIncompatibleBaseline(
          serverUrl: serverUrl,
          appId: appId,
          patchId: patchId,
          reason: 'Engine has no code push support (stock Flutter engine '
              'or missing flutter/codepush method channel).',
          expectedFingerprint: expectedEngineFingerprint,
          actualFingerprint: null,
        );
        return false;
      }

      // Phase 2 defense-in-depth: only compare when both sides supply
      // a fingerprint. Older servers don't send one; older engines
      // don't expose one. Either null short-circuits to the Phase 1
      // "engine is present" check that already succeeded above.
      if (expectedEngineFingerprint != null &&
          actualEngineFingerprint != 'unknown' &&
          expectedEngineFingerprint != actualEngineFingerprint) {
        status.value = 'Incompatible baseline: engine ABI mismatch '
            '($actualEngineFingerprint vs $expectedEngineFingerprint)';
        await _reportIncompatibleBaseline(
          serverUrl: serverUrl,
          appId: appId,
          patchId: patchId,
          reason: 'Engine ABI mismatch',
          expectedFingerprint: expectedEngineFingerprint,
          actualFingerprint: actualEngineFingerprint,
        );
        return false;
      }

      // Phase 3 (0.1.7+): baseline content hash check.
      //
      // Soft gate: log a mismatch for telemetry but don't block the
      // patch download. sha256(binary) is invalid for TestFlight /
      // App Store builds because Apple's processing modifies the
      // binary after upload. Downgraded from a hard reject to a
      // warning until a distribution-proof identity replaces binary
      // hashing. The engine ABI fingerprint (Phase 2 above) remains
      // the hard safety gate.
      final expectedBaselineHash = data['baseline_hash'] as String?;
      if (expectedBaselineHash != null) {
        final actualBaselineHash = await _computeBaselineHash();
        if (actualBaselineHash != null &&
            actualBaselineHash != expectedBaselineHash &&
            // Report each distinct mismatch pair once per session —
            // checkAndInstall runs on a periodic timer, and a stable
            // mismatch (e.g. an ABI whose hash the server doesn't have)
            // would otherwise POST identical telemetry on every tick.
            _reportedBaselineMismatches.add(
              '$expectedBaselineHash|$actualBaselineHash',
            )) {
          await _reportIncompatibleBaseline(
            serverUrl: serverUrl,
            appId: appId,
            patchId: patchId,
            reason: 'Baseline hash mismatch (soft gate — proceeding '
                'with download; engine ABI check is the hard gate)',
            expectedFingerprint: expectedBaselineHash,
            actualFingerprint: actualBaselineHash,
          );
        }
      }

      status.value = 'Downloading patch...';
      print('[CP] downloading from $patchUrl');
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
        final patchDir = await _getPatchDir();

        // Persist patch metadata so rollback can record which patch
        // was bad.  Written before module load so it's available even
        // if the load crashes the process.
        if (patchDir != null) {
          try {
            final patchHash = sha256.convert(patchBytes).toString();
            File('$patchDir/patch_info.json').writeAsStringSync(
              jsonEncode(<String, Object?>{
                'patch_id': patchId,
                'patch_hash': patchHash,
                'installed_at': DateTime.now().toIso8601String(),
              }),
            );
          } catch (_) {}
        }

        try {
          // Extract the payload from the patch wrapper.
          final offsetBytes = patchBytes.buffer.asByteData();
          final payloadOffset = offsetBytes.getUint32(12, Endian.little);
          final payload = patchBytes.sublist(payloadOffset);
          if (patchDir != null) {
            _iosAppendDebugLog(
              patchDir,
              'BEFORE_LOAD patchId=$patchId bytes=${patchBytes.length} '
              'payload=${payload.length}',
            );
          }

          // Format guard: reject a patch payload that doesn't match
          // the expected iOS header before handing it to the runtime.
          // A mismatched payload cannot load cleanly, so we delete it
          // and surface an upgrade hint instead.
          bool headerMatches() {
            if (payload.length < _iosPayloadHeader.length) return false;
            for (var i = 0; i < _iosPayloadHeader.length; i++) {
              if (payload[i] != _iosPayloadHeader[i]) return false;
            }
            return true;
          }

          if (!headerMatches()) {
            if (patchDir != null) {
              _iosAppendDebugLog(
                patchDir,
                'HEADER_MISMATCH patchId=$patchId payload=${payload.length}',
              );
            }
            status.value = 'Patch format is unexpected — rolling back. '
                'Upgrade flutter_compile to the latest version and '
                'rebuild the patch.';
            await _iosImmediateRollback(
              serverUrl: serverUrl,
              appId: appId,
              patchId: patchId,
              errorMessage: 'Patch format mismatch — rejected before load',
            );
            return false;
          }

          status.value = 'Loading module...';
          if (patchDir != null) {
            _iosAppendDebugLog(
              patchDir,
              'CALL_LOAD patchId=$patchId payload=${payload.length}',
            );
          }
          // Invoke the runtime hook exposed by the code-push-capable
          // engine. The presence check above
          // (`_probeEngineFingerprint`) guarantees we only reach this
          // point on an engine that actually exposes the hook.
          //
          // Return-value semantics: the hook throws on real load
          // failures (bad format, verification failure, etc.). Any
          // non-throw return — including `null` — is a successful
          // load. `null` in particular comes back when the payload
          // loaded cleanly but had no entry-point function to invoke
          // (for example, a delta whose contents are all already
          // present in the baseline). That is a valid no-op, not a
          // failure, and must NOT trigger rollback — rolling back
          // would cause the next check to re-download, re-load, and
          // loop tightly.
          final rawResult = await ui
              // ignore: undefined_function
              .codePushLoadModule(Uint8List.fromList(payload));

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
          _moduleLoaded = true;
          moduleResult.value = result;
          status.value = 'Patch active';
          // Clear any previous rollback marker — this patch works.
          if (patchDir != null) {
            try {
              final rbFile = File('$patchDir/rolled_back_patch');
              if (rbFile.existsSync()) rbFile.deleteSync();
            } catch (_) {}
          }
          if (patchDir != null) {
            _iosAppendDebugLog(
              patchDir,
              'AFTER_LOAD patchId=$patchId result=$result '
              'moduleLoaded=$_moduleLoaded',
            );
          }
          print(
            '[CP] MODULE LOADED OK — result=$result moduleLoaded=$_moduleLoaded',
          );
          return true;
        } catch (e) {
          if (patchDir != null) {
            _iosAppendDebugLog(
              patchDir,
              'LOAD_THROW patchId=$patchId error=$e',
            );
          }
          print('[CP] MODULE LOAD THREW — $e');
          status.value = 'Module error: $e — rolling back patch';
          // Real load failure. Delete immediately instead of waiting
          // for the three-strike auto-rollback.
          await _iosImmediateRollback(
            serverUrl: serverUrl,
            appId: appId,
            patchId: patchId,
            errorMessage: 'Patch load threw $e — deleted immediately',
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

  // ── Baseline compatibility ──────────────────────────────────────

  /// Whether the running Flutter engine supports code push.
  ///
  /// Returns `true` only if the `flutter/codepush` method channel is
  /// registered and responds to a cheap probe within 2 seconds. Apps
  /// can call this to hide "check for updates" UI on devices whose
  /// baseline wasn't built for code push.
  static Future<bool> get hasCodePushEngine async {
    return (await _probeEngineFingerprint()) != null;
  }

  /// Probes the running engine for a code push compatibility
  /// fingerprint. Returns a fingerprint string on success, `"unknown"`
  /// as a fallback for older baselines that respond to the probe but
  /// don't yet expose an ABI identifier, or `null` when no code push
  /// support is present. Bounded with a 2-second timeout.
  static Future<String?> _probeEngineFingerprint() async {
    try {
      final abi = await _channel
          .invokeMethod<String>('CodePush.getEngineAbi')
          .timeout(const Duration(seconds: 2));
      if (abi != null && abi.isNotEmpty) return abi;
    } catch (_) {
      // Fall through to the fallback probe.
    }

    try {
      await _channel
          .invokeMethod<String>('CodePush.getReleaseVersion')
          .timeout(const Duration(seconds: 2));
      return 'unknown';
    } catch (_) {
      return null;
    }
  }

  /// Best-effort telemetry POST to let the server know a device was
  /// stranded on an incompatible baseline. Swallows every error so
  /// telemetry failure can never cascade into an app crash — this is
  /// already the unhappy path.
  static Future<void> _reportIncompatibleBaseline({
    required String serverUrl,
    required String appId,
    required String? patchId,
    required String reason,
    required String? expectedFingerprint,
    required String? actualFingerprint,
  }) async {
    try {
      final payload = <String, dynamic>{
        'app_id': appId,
        'kind': 'incompatible_baseline',
        'reason': reason,
        'platform': _platform,
        if (patchId != null) 'patch_id': patchId,
        if (expectedFingerprint != null)
          'expected_engine_fingerprint': expectedFingerprint,
        if (actualFingerprint != null)
          'actual_engine_fingerprint': actualFingerprint,
      };
      final client = HttpClient();
      try {
        final uri = Uri.parse('$serverUrl/api/v1/telemetry/client-error');
        final req =
            await client.postUrl(uri).timeout(const Duration(seconds: 5));
        req.headers.set('Content-Type', 'application/json');
        req.write(jsonEncode(payload));
        await req.close().timeout(const Duration(seconds: 5));
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Telemetry is best-effort. Never crash over it.
    }
  }

  /// Best-effort: report a rollback that the native side recorded in the
  /// patch directory (automatic crash-loop rollbacks happen before any
  /// Dart code runs, so they can only be reported after the fact). The
  /// marker is cleared once the server has received the report; if the
  /// device is offline, we retry on the next launch.
  static Future<void> _reportPendingNativeRollback({
    required String serverUrl,
    required String appId,
  }) async {
    try {
      final patchDir = await _getPatchDir();
      if (patchDir == null) return;
      final marker = File('$patchDir/rollback_info.json');
      if (!marker.existsSync()) return;

      Map<String, dynamic> info;
      try {
        info = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        // Unreadable marker — clear it so it can't wedge future launches.
        try {
          marker.deleteSync();
        } catch (_) {}
        return;
      }

      final payload = <String, dynamic>{
        'app_id': appId,
        'kind': 'auto_rollback',
        'reason': info['reason'] ?? 'unknown',
        'platform': _platform,
        if (info['patch_version'] != null)
          'patch_version': info['patch_version'],
        if (info['boot_count'] != null) 'boot_count': info['boot_count'],
        if (info['rolled_back_at'] != null)
          'rolled_back_at': info['rolled_back_at'],
      };
      final client = HttpClient();
      try {
        final uri = Uri.parse('$serverUrl/api/v1/telemetry/client-error');
        final req =
            await client.postUrl(uri).timeout(const Duration(seconds: 5));
        req.headers.set('Content-Type', 'application/json');
        req.write(jsonEncode(payload));
        final res = await req.close().timeout(const Duration(seconds: 5));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try {
            marker.deleteSync();
          } catch (_) {}
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Telemetry is best-effort. Never crash over it.
    }
  }

  /// In-memory cache of the running app's baseline hash.
  /// Computed lazily on first use and reused for the rest of the
  /// session, since the AOT snapshot can't change while the app is
  /// running.
  static String? _cachedBaselineHash;

  /// When the last hash computation failed (null result), the failure is
  /// remembered here so one check cycle doesn't pay the platform-channel
  /// timeout twice — [checkAndInstall] computes the hash at both the query
  /// step and the soft-gate step. Retried after [_baselineHashRetryAfter]:
  /// a transient first-boot failure (slow storage, cold cache) must not
  /// disable the baseline gate for the whole session.
  static DateTime? _baselineHashFailedAt;

  /// How long a failed hash computation short-circuits before retrying.
  static const Duration _baselineHashRetryAfter = Duration(minutes: 1);

  /// In-flight hash computation, shared so concurrent callers don't stack
  /// duplicate platform-channel invocations (and duplicate native hashing
  /// threads) while one is already running.
  static Future<String?>? _baselineHashInFlight;

  /// Test-only: forces the Android branch of the baseline-hash path in
  /// host unit tests, where `Platform.isAndroid` is always false.
  @visibleForTesting
  static bool debugForceAndroidPlatform = false;

  /// Baseline-hash mismatch pairs (`expected|actual`) already reported to
  /// the server this session, so periodic checks don't repeat identical
  /// telemetry every poll cycle.
  static final Set<String> _reportedBaselineMismatches = <String>{};

  /// Test-only: clears the baseline-hash session state between tests.
  @visibleForTesting
  static void debugResetBaselineHashCache() {
    _cachedBaselineHash = null;
    _baselineHashFailedAt = null;
    _baselineHashInFlight = null;
    _reportedBaselineMismatches.clear();
  }

  /// Cached distribution-proof baseline UUID (see [_readBaselineId]).
  static String? _cachedBaselineId;

  /// Read the distribution-proof baseline UUID from Info.plist
  /// (`FCPBaselineId` key, written by `fcp codepush release`).
  /// Returns null when the key is absent (older CLI or non-iOS).
  static Future<String?> _readBaselineId() async {
    if (_cachedBaselineId != null) return _cachedBaselineId;
    try {
      if (!Platform.isIOS) return null;
      final id = await _pluginChannel
          .invokeMethod<String>('getBaselineId')
          .timeout(const Duration(seconds: 2));
      if (id != null && id.isNotEmpty) {
        _cachedBaselineId = id;
        return id;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Returns the SHA-256 hex of the currently-running baseline's
  /// `App.framework/App` (iOS) or `libapp.so` (Android).
  ///
  /// This is the authoritative identity of the Dart code that's
  /// loaded into the VM — bumping any Dart package (including this
  /// one) changes the AOT class layout and produces a different
  /// hash. We use it as the compatibility key for patches:
  /// if `sha256(running baseline) != sha256(baseline the patch was
  /// built against)`, the patch's class offsets are wrong and
  /// `ui.codePushLoadModule` will abort the VM on the first class
  /// allocation. The check at the top of [checkAndInstall] refuses
  /// to load a patch whose recorded baseline hash disagrees with
  /// this value.
  ///
  /// Cached in memory after first computation. Hashing the few-MB
  /// AOT blob takes ~20–50 ms on a modern device — once per session
  /// is fine. On iOS the blob is read from the app bundle; on Android
  /// it is read from the platform side.
  ///
  /// Failures are memoized briefly (see [_baselineHashFailedAt]) and
  /// concurrent callers share one in-flight computation, so a device that
  /// can't produce a hash pays the platform-channel timeout at most once
  /// per retry window instead of on every call.
  static Future<String?> _computeBaselineHash() {
    if (_cachedBaselineHash != null) {
      return Future.value(_cachedBaselineHash);
    }
    final failedAt = _baselineHashFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _baselineHashRetryAfter) {
      return Future.value(null);
    }
    return _baselineHashInFlight ??=
        _computeBaselineHashUncached().then((hash) {
      if (hash == null) _baselineHashFailedAt = DateTime.now();
      return hash;
    }).whenComplete(() => _baselineHashInFlight = null);
  }

  static Future<String?> _computeBaselineHashUncached() async {
    try {
      if (debugForceAndroidPlatform || Platform.isAndroid) {
        // Android packages the AOT snapshot as lib/<abi>/libapp.so inside
        // the APK; the platform side reads and hashes it. Generous timeout:
        // a first-boot hash of a multi-MB entry on slow storage with a cold
        // page cache can take several seconds.
        final hash = await _pluginChannel
            .invokeMethod<String>('getAppLibHash')
            .timeout(const Duration(seconds: 10));
        if (hash != null && hash.isNotEmpty) {
          _cachedBaselineHash = hash;
          return hash;
        }
        return null;
      }
      if (!Platform.isIOS) return null;

      // On iOS, Platform.resolvedExecutable points at
      // `Runner.app/Runner`. Its sibling at
      // `Runner.app/Frameworks/App.framework/App` is the Dart AOT
      // snapshot — the file whose bytes define the class layout.
      final executablePath = Platform.resolvedExecutable;
      if (executablePath.isEmpty) return null;
      final runnerFile = File(executablePath);
      final bundleDir = runnerFile.parent.path;
      final appFrameworkPath = '$bundleDir/Frameworks/App.framework/App';
      final appFrameworkFile = File(appFrameworkPath);
      if (!appFrameworkFile.existsSync()) return null;

      // Stream + incremental digest keeps peak memory bounded even
      // though the file is only a few MB. sha256.bind(stream) is the
      // idiomatic async streaming form from package:crypto.
      final digest = await sha256.bind(appFrameworkFile.openRead()).first;
      _cachedBaselineHash = digest.toString();
      return _cachedBaselineHash;
    } catch (_) {
      // Hashing must never crash the app. If we can't compute the
      // hash for any reason, return null and let callers fall back
      // to their existing logic.
      return null;
    }
  }

  // ── Low-level engine API ────────────────────────────────────────

  /// Checks the engine for available updates (delegates to Dart side HTTP).
  static Future<UpdateInfo> checkForUpdate() async {
    try {
      final Map<String, dynamic>? result = await _channel
          .invokeMapMethod<String, dynamic>('CodePush.checkForUpdate');
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
    final Map<String, dynamic>? result = await _channel
        .invokeMapMethod<String, dynamic>('CodePush.getCurrentPatch');
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
      final bool? success = await _channel.invokeMethod<bool>(
        'CodePush.rollback',
      );
      if (success == true) return;
    } catch (_) {}

    // Dart-side rollback for iOS (engine updater is null).
    final patchDir = await _getPatchDir();
    if (patchDir == null) {
      throw CodePushException('No patch directory configured.');
    }
    final patchFile = File('$patchDir/$_patchFilename');
    if (!patchFile.existsSync()) {
      throw CodePushException('No active patch to roll back.');
    }
    patchFile.deleteSync();
    final infoFile = File('$patchDir/patch_info.json');
    if (infoFile.existsSync()) infoFile.deleteSync();
    _iosResetBootCounter(patchDir);
    _moduleLoaded = false;
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
    final result = await _channel.invokeMethod<bool>(
      'CodePush.downloadAndApply',
    );
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
    final patchDir = await _channel.invokeMethod<String>(
      'CodePush.getPatchDir',
    );
    if (patchDir == null || patchDir.isEmpty) {
      throw CodePushException('Engine returned no patch directory.');
    }

    final dir = Directory(patchDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final file = File('$patchDir/$_patchFilename');
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
      final patchFile = File('$patchDir/$_patchFilename');
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
    // 1. Record which patch was rolled back, then delete files.
    try {
      final patchDir = await _getPatchDir();
      if (patchDir != null) {
        // Read patch metadata before deleting so we can record the
        // rolled-back ID + hash.  This marker persists across cold
        // starts to prevent re-downloading the same bad patch.
        try {
          final infoFile = File('$patchDir/patch_info.json');
          if (infoFile.existsSync()) {
            final info =
                jsonDecode(infoFile.readAsStringSync()) as Map<String, dynamic>;
            File('$patchDir/rolled_back_patch').writeAsStringSync(
              jsonEncode(<String, Object?>{
                'patch_id': info['patch_id'],
                'patch_hash': info['patch_hash'],
                'rolled_back_at': DateTime.now().toIso8601String(),
              }),
            );
          }
        } catch (_) {}

        // Delete both the new (patch.bytecode) and legacy (patch.vmcode)
        // filenames to be safe across SDK upgrades.
        for (final name in const ['patch.bytecode', 'patch.vmcode']) {
          final f = File('$patchDir/$name');
          if (await f.exists()) await f.delete();
        }
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

  static void _iosAppendDebugLog(String patchDir, String line) {
    try {
      final dir = Directory(patchDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String();
      File('$patchDir/cp_debug.log').writeAsStringSync(
        '[$stamp] $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  /// Returns true if a rollback was performed.
  static bool _iosCheckAndAutoRollback(String patchDir) {
    final count = _iosReadBootCounter(patchDir);
    if (count < _maxBootAttempts) return false;

    // Auto-rollback: record which patch was bad, then remove files.
    try {
      // Record the rolled-back patch ID + hash before deleting.
      final infoFile = File('$patchDir/patch_info.json');
      if (infoFile.existsSync()) {
        try {
          final info =
              jsonDecode(infoFile.readAsStringSync()) as Map<String, dynamic>;
          File('$patchDir/rolled_back_patch').writeAsStringSync(
            jsonEncode(<String, Object?>{
              'patch_id': info['patch_id'],
              'patch_hash': info['patch_hash'],
              'rolled_back_at': DateTime.now().toIso8601String(),
            }),
          );
        } catch (_) {}
      }

      // Delete both the new (patch.bytecode) and legacy (patch.vmcode)
      // filenames defensively — a device upgrading from 0.1.10 might
      // still have the legacy file on disk.
      for (final name in const ['patch.bytecode', 'patch.vmcode']) {
        final f = File('$patchDir/$name');
        if (f.existsSync()) f.deleteSync();
      }
      if (infoFile.existsSync()) infoFile.deleteSync();
      _iosResetBootCounter(patchDir);
    } catch (_) {}
    return true;
  }
}

/// Configuration for [CodePushOverlay] and [CodePush.init].
///
/// `serverUrl` defaults to [CodePush.defaultServerUrl] so apps pointed
/// at the FlutterPlaza production service only need to supply `appId`
/// and `releaseVersion`.
@immutable
class CodePushConfig {
  const CodePushConfig({
    this.serverUrl = CodePush.defaultServerUrl,
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
    this.config,
    required this.child,
    this.bannerBuilder,
    this.showDebugBar = false,
  });

  /// Code push configuration.
  ///
  /// Optional from 0.1.6 onward. When omitted, the overlay falls back
  /// to [CodePush.lastConfig] — the config stored by the most recent
  /// call to [CodePush.init]. This lets apps configure the SDK once in
  /// `main()` and then just write `CodePushOverlay(child: ...)`
  /// without repeating every field.
  ///
  /// Passing a non-null [config] here always wins, for cases where the
  /// overlay needs different settings from whatever `init` was called
  /// with (e.g. a different channel for a debug build).
  final CodePushConfig? config;

  /// The app widget.
  final Widget child;

  /// Optional custom banner builder. If null, uses the default banner.
  /// Return `null` to hide the banner.
  final Widget Function(
    BuildContext context,
    VoidCallback onRestart,
    VoidCallback onDismiss,
  )? bannerBuilder;

  /// Whether to show the debug status bar at the top. Defaults to false.
  final bool showDebugBar;

  @override
  State<CodePushOverlay> createState() => _CodePushOverlayState();
}

class _CodePushOverlayState extends State<CodePushOverlay>
    with WidgetsBindingObserver {
  bool _updateReady = false;
  bool _patchActive = false;

  /// Effective config: an explicit `widget.config` always wins, then
  /// falls back to `CodePush.lastConfig` (set by an earlier
  /// `CodePush.init(...)` call, typically at the top of `main()`).
  CodePushConfig get _config {
    final explicit = widget.config;
    if (explicit != null) return explicit;
    final stored = CodePush.lastConfig;
    if (stored != null) return stored;
    throw StateError(
      'CodePushOverlay: no config provided and CodePush.init has not '
      'been called. Either pass a `config:` argument to CodePushOverlay '
      'or call CodePush.init(appId: ..., releaseVersion: ...) before '
      'runApp(...).',
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CodePush.status.addListener(_onModuleLoaded);
    CodePush.moduleResult.addListener(_onModuleLoaded);
    final cfg = _config;
    CodePush.init(
      serverUrl: cfg.serverUrl,
      appId: cfg.appId,
      releaseVersion: cfg.releaseVersion,
      interval: cfg.checkInterval,
      channel: cfg.channel,
      onUpdateReady: () {
        if (mounted) setState(() => _updateReady = true);
      },
    );
  }

  void _onModuleLoaded() {
    if (mounted && !_patchActive && CodePush.status.value == 'Patch active') {
      setState(() => _patchActive = true);
    }
  }

  @override
  void dispose() {
    CodePush.status.removeListener(_onModuleLoaded);
    CodePush.moduleResult.removeListener(_onModuleLoaded);
    CodePush.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final cfg = _config;
      CodePush.checkAndInstall(
        serverUrl: cfg.serverUrl,
        appId: cfg.appId,
        releaseVersion: cfg.releaseVersion,
        channel: cfg.channel,
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
          KeyedSubtree(key: ValueKey<bool>(_patchActive), child: widget.child),
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
                    child: Text(
                      'CP: $status',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        decoration: TextDecoration.none,
                      ),
                    ),
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
                    )
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
            const Expanded(child: Text('Update ready. Restart to apply.')),
            TextButton(onPressed: onDismiss, child: const Text('LATER')),
            const SizedBox(width: 4),
            FilledButton(onPressed: onRestart, child: const Text('RESTART')),
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
  final Widget Function(BuildContext context, String? patchData, Widget? child)
      builder;

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
              return builder(
                context,
                result.substring(patchKey!.length + 1),
                child,
              );
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
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
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
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
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
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    return _HttpResult(response.statusCode, utf8.decode(bytes), bytes);
  } finally {
    client.close();
  }
}
