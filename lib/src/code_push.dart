import 'dart:async' show Timer, TimeoutException, unawaited;
import 'dart:convert' show base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io' show Directory, File, FileMode, HttpClient, Platform, exit;
import 'dart:math' show Random;

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

/// Outcome of the iOS loaded-session offer decision — see
/// [CodePush.debugDecideLoadedSessionOffer]. Only produced by
/// test-visible methods; not part of the supported runtime API.
@visibleForTesting
enum IosLoadedSessionDecision {
  /// The offer is already persisted on disk: nothing to write.
  skipAlreadyInstalled,

  /// The container fails the format check: refuse to overwrite the
  /// working patch.
  rejectMalformed,

  /// Persist, but the offer IS the running module (the server withdrew
  /// a pending update): no restart banner, no callback.
  persistSilently,

  /// Persist a genuinely new patch and surface restart-to-apply.
  persistAndRestart,
}

/// Outcome of the iOS cold-start reload gate — see
/// [CodePush.debugDecideReloadGate]. Only produced by
/// test-visible methods; not part of the supported runtime API.
@visibleForTesting
enum IosReloadGateDecision {
  /// The on-disk patch may be fed to the runtime.
  load,

  /// The patch records a different engine ABI than the live probe:
  /// loading risks a VM abort. Skip, release the strike, keep baseline.
  skipIncompatibleAbi,

  /// The on-disk bytes don't match the recorded hash: corruption, not a
  /// bad patch. Delete WITHOUT quarantining so re-download can heal.
  dropCorrupt,
}

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

  /// Bumped by every [init] and [dispose]; async init work checks it
  /// after each await so a stale closure can't start timers for a
  /// session that was disposed or re-initialized mid-flight.
  static int _initEpoch = 0;

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

  /// Unwraps an on-disk iOS patch container and returns its payload, or
  /// `null` when the container is malformed or the payload's format
  /// marker doesn't match.
  ///
  /// Fully bounds-checked and never throws: since the reload path runs
  /// this on every launch against whatever is on disk, a truncated or
  /// garbage file must produce a clean rejection rather than an
  /// exception at startup.
  @visibleForTesting
  static Uint8List? debugExtractIosPayload(Uint8List container) {
    // The payload offset lives in a fixed-width header field; a file
    // too small to contain that field cannot be a patch.
    const offsetField = 12;
    if (container.length < offsetField + 4) return null;
    // sublistView, not buffer.asByteData(): the latter indexes the
    // UNDERLYING buffer from byte 0, so a caller passing a sub-view
    // (non-zero offsetInBytes) would silently read the wrong field.
    final payloadOffset =
        ByteData.sublistView(container).getUint32(offsetField, Endian.little);
    if (payloadOffset < offsetField + 4 || payloadOffset >= container.length) {
      return null;
    }
    final payload = container.sublist(payloadOffset);
    if (payload.length < _iosPayloadHeader.length) return null;
    for (var i = 0; i < _iosPayloadHeader.length; i++) {
      if (payload[i] != _iosPayloadHeader[i]) return null;
    }
    return payload;
  }

  /// Debug status notifier — shows what code push is doing.
  static final ValueNotifier<String> status = ValueNotifier('init');

  /// The result from the last loaded module.
  ///
  /// On iOS, bytecode modules return a JSON string which is auto-parsed
  /// into a `Map<String, dynamic>`. Apps can listen to this to apply
  /// OTA patches to their UI.
  static final ValueNotifier<Object?> moduleResult = ValueNotifier(null);
  static bool _moduleLoaded = false;

  /// Identity of the module that is loaded in THIS VM right now (iOS).
  /// Distinct from `patch_info.json`, which describes the patch
  /// persisted on disk — after a pending update is persisted, the two
  /// deliberately differ until the next cold start.
  static String? _loadedPatchId;
  static String? _loadedPatchHash;

  /// Once-per-process latch for the incompatible-reload telemetry —
  /// repeated init() calls re-enter the reload and must not re-POST a
  /// DELIVERED report. Cleared again on transport failure so devices
  /// that boot offline retry on a later re-init.
  static bool _reportedIncompatibleReload = false;

  /// Fires the incompatible-reload stranding report. Latched per
  /// process on DELIVERY: set optimistically (no duplicate in-flight
  /// posts), cleared again if the POST never completed an HTTP round
  /// trip (device offline at boot) so a later re-init retries. One
  /// delivered report per process is exactly sufficient — an engine
  /// ABI cannot change within a running process.
  @visibleForTesting
  static Future<void> debugReportIncompatibleReload({
    required String serverUrl,
    required String appId,
    required String? patchId,
    required String? storedAbi,
    required String? liveAbi,
  }) async {
    if (_reportedIncompatibleReload) return;
    _reportedIncompatibleReload = true;
    final delivered = await _reportIncompatibleBaseline(
      serverUrl: serverUrl,
      appId: appId,
      patchId: patchId,
      kind: 'incompatible_reload',
      reason: 'Installed patch was built for a different engine '
          'ABI; reload skipped, baseline running',
      expectedFingerprint: storedAbi,
      actualFingerprint: liveAbi,
    );
    if (!delivered) _reportedIncompatibleReload = false;
  }

  /// Test-only: clears the incompatible-reload latch.
  @visibleForTesting
  static void debugResetIncompatibleReloadLatch() {
    _reportedIncompatibleReload = false;
  }

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
    bool disableOnPlayStoreInstalls = false,
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
      disableOnPlayStoreInstalls: disableOnPlayStoreInstalls,
    );

    // NOTE: Any stale-patch cleanup from prior versions (0.1.4/0.1.5)
    // was unreachable on iOS — it ran inside `init()`, which runs
    // inside `main()`, and on the crash path `main()` never executes.
    // The 0.1.6 fix moved cleanup to native iOS `+load`
    // (FlutterplazaCodePushBootCleanup.m) which runs during dyld image
    // load, before the Flutter engine boots. See CHANGELOG.

    _timer?.cancel();

    final epoch = ++_initEpoch;
    unawaited(() async {
      // Developer-selected store-only mode: when enabled and this build
      // was installed from the Play Store, OTA stays off for the whole
      // session — no server checks — and any patch left over from
      // before the setting shipped is removed so the device runs the
      // store baseline. Detection failure leaves OTA enabled: a build
      // without the plugin (debug, sideload) is not a store install.
      if (disableOnPlayStoreInstalls && await isPlayStoreInstall()) {
        // Stale-session check after EVERY await in this branch: its
        // side effects (a telemetry POST, a patch deletion) must never
        // fire for a session that was disposed or superseded while a
        // lookup was in flight — a stale rollback could even delete a
        // patch a newer session just installed.
        if (epoch != _initEpoch) return;
        status.value = 'OTA off (store-installed build)';
        // A native crash-loop rollback recorded before Dart started is
        // still history worth reporting (and its marker worth
        // clearing), even though OTA is off from here on.
        await _reportPendingNativeRollback(serverUrl: serverUrl, appId: appId);
        if (epoch != _initEpoch) return;
        try {
          // rollback() removes the patch wherever the platform keeps it
          // (engine on Android/desktop, direct file removal on iOS) and
          // throws when there is nothing to remove — the common,
          // healthy case, swallowed below.
          await rollback();
          status.value = 'OTA off (store-installed build) — patch removed';
        } catch (_) {
          // Nothing to revert.
        }
        return;
      }
      // A dispose() or a newer init() during the await above owns the
      // session now — don't start timers for a stale one.
      if (epoch != _initEpoch) return;
      _startUpdateFlow(
        serverUrl: serverUrl,
        appId: appId,
        releaseVersion: releaseVersion,
        interval: interval,
        channel: channel,
        onUpdateReady: onUpdateReady,
      );
    }());
  }

  /// Starts crash protection, the first update check, and the periodic
  /// check timer. Split out of [init] so the store-install gate can
  /// decide whether the flow starts at all.
  static void _startUpdateFlow({
    required String serverUrl,
    required String appId,
    required String releaseVersion,
    required Duration interval,
    required String channel,
    VoidCallback? onUpdateReady,
  }) {
    // Crash protection runs async because it needs the engine's patch
    // dir via platform channel. We chain the first checkAndInstall off
    // it so that, on a boot where a previously-downloaded bad patch is
    // on disk, the three-strike auto-rollback machinery has already
    // run before we download and overwrite that file with a fresh
    // (possibly equally bad) patch. Prior versions fired checkAndInstall
    // unconditionally on init which left no room for the boot counter
    // to trip — see CHANGELOG 0.1.7 for the race condition this fixes.
    _runCrashProtection().then((_) async {
      // Re-apply a patch that was installed on a previous launch. On
      // iOS the patch is loaded into the running VM rather than mapped
      // at boot by the engine, so without this the patch would only be
      // active in the session it was downloaded and every later launch
      // would silently run the baseline — including offline launches,
      // where no check can re-download it.
      //
      // Ordering is load-bearing: this runs AFTER _runCrashProtection
      // (so a crash-looping patch is rolled back before we load it
      // again) and BEFORE _startLaunchTimer (so a load that crashes or
      // hangs cannot be reported as a successful launch, leaving the
      // boot counter incremented for the next attempt).
      await _iosReloadInstalledPatch(serverUrl: serverUrl, appId: appId);

      // Start launch success timer only after crash protection completes,
      // so a rollback doesn't get immediately overwritten by a success report.
      _startLaunchTimer();

      // Quarantine any just-rolled-back patch synchronously BEFORE the
      // first check, so a bad patch isn't re-downloaded even once on this
      // boot (the fast, no-network half of the rollback handling). The
      // telemetry POST below is the slow, best-effort half.
      //
      // NOT on iOS: the breadcrumb (`rollback_info.json`) is written only
      // by the engine's updater, which is disabled on iOS — and iOS now
      // writes `installed_patch_identity.json` with "currently
      // active/pending" semantics, so promoting it into the quarantine
      // marker here would quarantine the RUNNING GOOD patch if a
      // breadcrumb ever appeared (restored backup, future engine change).
      if (!Platform.isIOS) {
        final quarantineDir = await _getPatchDir();
        if (quarantineDir != null) {
          _quarantineFromBreadcrumb(quarantineDir);
        }

        // Report any rollback that was recorded natively before Dart
        // started (crash-loop protection runs before main(), so without
        // this the server never hears about it). Best-effort,
        // fire-and-forget.
        _reportPendingNativeRollback(serverUrl: serverUrl, appId: appId);
      }

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
    _initEpoch++;
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
    // Single-flight: the init chain, the periodic timer, and app-resume
    // can overlap. Concurrent checks would double-download, and on iOS a
    // second load of the same payload throws — whose rollback would then
    // revert the copy the first call just loaded successfully. The guard
    // is deliberately global (not per appId/channel): apps use a single
    // config, and a losing caller's `false` means "another check is
    // already running", not "no update".
    if (_checkInFlight) return false;
    _checkInFlight = true;
    try {
      print('[CP] checkAndInstall start');
      status.value = 'Checking server...';
      // The offer is the trust root — it vends both the patch URL and
      // the hash the download is verified against — so the metadata
      // channel itself must be secure too. Loopback is exempt for
      // development and tests.
      final serverUri = Uri.tryParse(serverUrl);
      final isLoopbackServer = serverUri != null &&
          (serverUri.host == '127.0.0.1' ||
              serverUri.host == 'localhost' ||
              serverUri.host == '::1');
      if (serverUri == null ||
          (serverUri.scheme != 'https' && !isLoopbackServer)) {
        status.value = 'Insecure server URL refused';
        return false;
      }
      // Compute the baseline hash once, up front, so it can be
      // included in the /updates query. The server uses it as a
      // belt-and-suspenders gate: if the patch on file has a
      // recorded baseline hash that disagrees with ours, the server
      // returns 204 instead of a crash-inducing patch. Older servers
      // ignore the parameter and the SDK-side load-time check
      // (further down) still protects us.
      final deviceBaselineHash = await _computeBaselineHash();
      final deviceBaselineId = await _readBaselineId();
      final deviceHash = await _deviceHash();
      final url = '$serverUrl/api/v1/updates'
          '?app_id=${Uri.encodeComponent(appId)}'
          '&version=${Uri.encodeComponent(releaseVersion)}'
          '&platform=$_platform'
          '&channel=${Uri.encodeComponent(channel)}'
          '${deviceBaselineHash != null ? '&baseline_hash=$deviceBaselineHash' : ''}'
          '${deviceBaselineId != null ? '&baseline_id=$deviceBaselineId' : ''}'
          '${deviceHash != null ? '&device_hash=$deviceHash' : ''}';

      final r = await _httpGet(url);
      if (r.statusCode == 204 || r.statusCode != 200) {
        status.value = 'No update (${r.statusCode})';
        return false;
      }

      final data = jsonDecode(r.body) as Map<String, dynamic>;

      // Fleet-wide OTA kill switch (server-controlled). When the server
      // says OTA is off for this app, stop offering updates AND revert
      // any installed patch, so the fleet returns to the store baseline
      // within one check interval of the switch being flipped.
      if (data['ota_disabled'] == true) {
        status.value = 'OTA disabled by server';
        try {
          // Unconditional: rollback() knows where each platform keeps
          // the patch (engine on Android/desktop, file removal on iOS
          // where the engine channel is disabled and isPatched would
          // always answer false) and throws harmlessly when the device
          // is already clean.
          await rollback();
          status.value =
              'OTA disabled by server — patch removed (restart to apply)';
        } catch (_) {
          // Best-effort: a clean device has nothing to revert.
        }
        return false;
      }

      if (data['patch_available'] != true) {
        status.value = 'No patch available';
        return false;
      }

      final patchId = data['patch_id']?.toString();
      final serverPatchHash = data['patch_hash']?.toString();
      final patchUrl = data['patch_url'] as String?;
      if (patchUrl == null || patchUrl.isEmpty) {
        status.value = 'No patch URL';
        return false;
      }
      // Executable code must never travel over cleartext. Loopback is
      // exempt for local development and tests.
      final patchUri = Uri.tryParse(patchUrl);
      final isLoopbackPatchHost = patchUri != null &&
          (patchUri.host == '127.0.0.1' ||
              patchUri.host == 'localhost' ||
              patchUri.host == '::1');
      if (patchUri == null ||
          (patchUri.scheme != 'https' && !isLoopbackPatchHost)) {
        status.value = 'Insecure patch URL refused';
        return false;
      }

      // Skip a patch this device already rolled back, so a bad patch at
      // 100% rollout can't crash-loop the device forever (rollback →
      // refetch → re-crash). The marker persists across cold starts and
      // works offline — no server round-trip needed. Cross-platform: on
      // iOS the marker is written by the immediate/three-strike rollback;
      // on Android it's promoted from the engine's rollback breadcrumb
      // (see _reportPendingNativeRollback).
      final quarantineDir = await _getPatchDir();
      if (quarantineDir != null &&
          _isPatchQuarantined(
            patchDir: quarantineDir,
            patchId: patchId,
            patchHash: serverPatchHash,
          )) {
        // Older servers omit patch_id from the offer, so the match may
        // have come from the hash — never render a null id.
        final skippedLabel = patchId ??
            ((serverPatchHash?.length ?? 0) >= 8
                ? serverPatchHash!.substring(0, 8)
                : 'unknown');
        status.value = 'Skipping rolled-back patch $skippedLabel';
        return false;
      }

      // Don't re-offer a patch this device already installed. On Android
      // a patch applies on the next cold boot, so without this the server
      // keeps offering the same patch every launch and the SDK
      // re-downloads it and re-fires "restart to apply" forever. The
      // install-time identity (finding #7's `installed_patch_identity.json`)
      // survives the restart, so a matching offer means "already applied".
      // Written at install on BOTH platforms: on iOS it stops the SDK
      // re-downloading the patch that is already running (or persisted
      // and pending restart) on every check cycle.
      if (quarantineDir != null &&
          _isPatchAlreadyInstalled(
            patchDir: quarantineDir,
            patchId: patchId,
            patchHash: serverPatchHash,
          )) {
        status.value = 'Patch already installed';
        return false;
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
        // Report each distinct mismatch pair once per session —
        // checkAndInstall runs on a periodic timer, and a stable
        // mismatch (e.g. an ABI whose hash the server doesn't have)
        // would otherwise POST identical telemetry on every tick. The
        // pair is recorded once the report completes an HTTP round
        // trip, whatever the status: a persistently failing endpoint
        // must not turn every mismatching device into a per-poll
        // beacon. Only a transport failure (offline, timeout) retries.
        final mismatchKey = '$expectedBaselineHash|$actualBaselineHash';
        if (actualBaselineHash != null &&
            actualBaselineHash != expectedBaselineHash &&
            !_reportedBaselineMismatches.contains(mismatchKey)) {
          final reported = await _reportIncompatibleBaseline(
            serverUrl: serverUrl,
            appId: appId,
            patchId: patchId,
            reason: 'Baseline hash mismatch (soft gate — proceeding '
                'with download; engine ABI check is the hard gate)',
            expectedFingerprint: expectedBaselineHash,
            actualFingerprint: actualBaselineHash,
          );
          if (reported) {
            _reportedBaselineMismatches.add(mismatchKey);
          }
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

      // Verify the download against the offer before anything touches
      // it: the server's patch_hash covers the exact stored bytes, so a
      // mismatch means transport corruption or tampering. Legacy servers
      // that omit the hash skip this check (on Android the engine still
      // verifies integrity and signature at load time).
      final downloadedHash = sha256.convert(patchBytes).toString();
      if (serverPatchHash != null && serverPatchHash.isNotEmpty) {
        if (downloadedHash != serverPatchHash) {
          status.value = 'Patch failed verification';
          return false;
        }
      }
      // The hash used for identity records and comparisons. An
      // empty-string server hash must fall back exactly like a missing
      // one: storing '' would let a later ''-hash offer of a DIFFERENT
      // patch "match" by hash and deadlock upgrades.
      final offerHash = (serverPatchHash != null && serverPatchHash.isNotEmpty)
          ? serverPatchHash
          : downloadedHash;

      status.value = 'Installing (${patchBytes.length}B)...';
      if (Platform.isIOS) {
        final patchDir = await _getPatchDir();
        if (_moduleLoaded) {
          // A module is already active in this VM. If the offer is the
          // patch already persisted on disk, there is nothing to do. If
          // it is a DIFFERENT patch, it cannot be loaded into a VM that
          // already holds the old module — but it must not be discarded
          // either: a device that reloads v1 at every cold start would
          // then never take v2 (permanent upgrade deadlock). Persist it
          // and ask for a restart, mirroring the Android path.
          final decision = debugDecideLoadedSessionOffer(
            offerMatchesDisk: debugInstalledIdentityMatches(
              patchDir: patchDir,
              patchId: patchId,
              patchHash: offerHash,
            ),
            formatValid: debugExtractIosPayload(patchBytes) != null,
            offerMatchesRunningModule: _identityMatches(
              <String, Object?>{
                'patch_id': _loadedPatchId,
                'patch_hash': _loadedPatchHash,
              },
              patchId,
              offerHash,
            ),
          );
          switch (decision) {
            case IosLoadedSessionDecision.skipAlreadyInstalled:
              // Heal the pre-download skip for installs made by older
              // SDK versions that never wrote the identity file on iOS.
              if (patchDir != null) {
                _recordInstalledIdentity(
                  patchDir: patchDir,
                  patchId: patchId,
                  patchHash: offerHash,
                );
              }
              status.value = 'Patch active';
              return false;
            case IosLoadedSessionDecision.rejectMalformed:
              // This branch never goes through _iosLoadPayload's format
              // guard, and persisting a malformed container would
              // destroy the WORKING patch's bytes and strand the device
              // on baseline at the next cold start.
              status.value =
                  'Patch format is unexpected — keeping the current patch. '
                  'Upgrade flutter_compile to the latest version and '
                  'rebuild the patch.';
              return false;
            case IosLoadedSessionDecision.persistSilently:
            case IosLoadedSessionDecision.persistAndRestart:
              await _installPatchFromDart(patchBytes);
              if (patchDir != null) {
                // patch_info deliberately stores the CONTAINER hash
                // (downloadedHash) — reload re-verifies the on-disk
                // bytes against it. offerHash is provably equal
                // whenever the server sent a hash (checked above);
                // identity records use it for offer comparisons.
                _writeIosPatchInfo(
                  patchDir,
                  patchId,
                  downloadedHash,
                  engineAbi: actualEngineFingerprint,
                );
                _recordInstalledIdentity(
                  patchDir: patchDir,
                  patchId: patchId,
                  patchHash: offerHash,
                );
                // The pending patch gets a fresh three-strike budget:
                // any strikes accrued so far belong to the OLD patch,
                // and the next boot runs the new one — charging it for
                // its predecessor's crashes could quarantine a fix
                // before it ever runs once.
                _iosResetBootCounter(patchDir);
              }
              if (decision == IosLoadedSessionDecision.persistSilently) {
                // The server withdrew a pending update and reverted to
                // the module that is running right now: disk converged,
                // a restart would change nothing — no banner, no
                // callback.
                status.value = 'Patch active';
                return false;
              }
              status.value = 'Restart to apply';
              onUpdateReady?.call();
              return true;
          }
        }
        await _installPatchFromDart(patchBytes);

        // Persist patch metadata so rollback can record which patch
        // was bad.  Written before module load so it's available even
        // if the load crashes the process.
        if (patchDir != null) {
          _writeIosPatchInfo(
            patchDir,
            patchId,
            downloadedHash,
            engineAbi: actualEngineFingerprint,
          );
          _recordInstalledIdentity(
            patchDir: patchDir,
            patchId: patchId,
            patchHash: offerHash,
          );
        }

        return _iosLoadPayload(
          container: patchBytes,
          patchDir: patchDir,
          patchId: patchId,
          serverUrl: serverUrl,
          appId: appId,
          origin: 'install',
        );
      } else {
        // Android/desktop: install via engine, restart required.
        await installPatch(patchBytes);
        // Record this patch's server identity in a file the engine's
        // rollback does NOT delete. If the patch crash-loops, the engine
        // rolls it back pre-main and deletes patch_info.json before any
        // Dart runs — so without this, the next launch couldn't learn
        // which patch to quarantine. Promoted to the rollback marker by
        // _reportPendingNativeRollback when the breadcrumb appears.
        final patchDir = await _getPatchDir();
        if (patchDir != null) {
          _recordInstalledIdentity(
            patchDir: patchDir,
            patchId: patchId,
            patchHash: offerHash,
          );
        }
        status.value = 'Restart to apply';
        onUpdateReady?.call();
        return true;
      }
    } catch (e) {
      status.value = 'Error: $e';
      return false;
    } finally {
      _checkInFlight = false;
    }
  }

  /// Guards [checkAndInstall] against overlapping invocations.
  static bool _checkInFlight = false;

  /// Maximum accepted patch download size. Visible for tests; real
  /// patches are tens of megabytes, so the default is generous.
  @visibleForTesting
  static int debugMaxPatchDownloadBytes = 256 * 1024 * 1024;

  /// Per-await bound on update-check and download HTTP operations
  /// (connect, response start, body read / inter-chunk gap). Visible
  /// for tests. Prevents a stalled server from wedging the
  /// single-flight guard — one hang must never latch updates off for
  /// the process lifetime.
  @visibleForTesting
  static Duration debugHttpRequestTimeout = const Duration(seconds: 30);

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
  /// already the unhappy path. Returns true when the request completed
  /// an HTTP round trip (any status — the report was delivered even if
  /// the server refused it); false only on transport failure, so
  /// callers can retry when the device was offline.
  static Future<bool> _reportIncompatibleBaseline({
    required String serverUrl,
    required String appId,
    required String? patchId,
    required String reason,
    required String? expectedFingerprint,
    required String? actualFingerprint,
    String kind = 'incompatible_baseline',
  }) async {
    try {
      final payload = <String, dynamic>{
        'app_id': appId,
        'kind': kind,
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
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        // Send encoded bytes, not a string: HttpClientRequest.write()
        // defaults to Latin-1, which throws on any non-Latin-1 character
        // in the payload (e.g. an em dash in a reason string) and would
        // silently drop the report.
        req.add(utf8.encode(jsonEncode(payload)));
        final res = await req.close().timeout(const Duration(seconds: 5));
        await res.drain<void>();
        return true;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Telemetry is best-effort. Never crash over it.
      return false;
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

      // Quarantine the rolled-back patch BEFORE the (best-effort, maybe
      // offline) telemetry POST, so the crash-loop breaks even with no
      // network.
      _quarantineFromBreadcrumb(patchDir);

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
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        // Encoded bytes, not a string: write() defaults to Latin-1 and
        // throws on any non-Latin-1 character in the native-written
        // reason, which would silently strand the marker forever.
        req.add(utf8.encode(jsonEncode(payload)));
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

  // ── Rolled-back-patch quarantine ──────────────────────────────────
  //
  // Breaks the "bad patch at 100% rollout crash-loops forever" failure:
  // once a patch has been rolled back on this device, its server
  // identity is recorded in `rolled_back_patch` and [checkAndInstall]
  // refuses to re-download a patch that matches — offline, no server
  // change needed. The marker holds `{patch_id, patch_hash}` and is
  // cleared automatically once the server moves on to a different patch.

  /// Whether a stored `{patch_id, patch_hash}` identity matches the
  /// server's offer (by id OR hash). Shared by the quarantine and
  /// already-installed checks.
  static bool _identityMatches(
    Map<String, dynamic> stored,
    String? patchId,
    String? patchHash,
  ) {
    // Empty strings are treated as absent on BOTH sides: '' == '' must
    // never count as a match, or two unrelated patches whose server
    // omits ids/hashes as '' would alias each other and an upgrade
    // would be skipped as "already installed" forever.
    final sId = _nonEmptyOrNull(stored['patch_id']?.toString());
    final sHash = _nonEmptyOrNull(stored['patch_hash']?.toString());
    final oId = _nonEmptyOrNull(patchId);
    final oHash = _nonEmptyOrNull(patchHash);
    final idMatch = sId != null && sId == oId;
    final hashMatch = sHash != null && oHash != null && sHash == oHash;
    return idMatch || hashMatch;
  }

  static String? _nonEmptyOrNull(String? s) =>
      (s == null || s.isEmpty) ? null : s;

  /// Whether [patchId]/[patchHash] matches the locally quarantined
  /// rolled-back patch. Clears a stale marker when the server has moved
  /// on to a different patch, so the quarantine is never permanent.
  static bool _isPatchQuarantined({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) {
    final rbFile = File('$patchDir/rolled_back_patch');
    if (!rbFile.existsSync()) return false;
    try {
      final rb = jsonDecode(rbFile.readAsStringSync()) as Map<String, dynamic>;
      if (_identityMatches(rb, patchId, patchHash)) return true;
      // Different patch — the previously-bad one is superseded; drop it.
      rbFile.deleteSync();
      return false;
    } catch (_) {
      // Corrupt marker — clear it and don't block this patch.
      try {
        rbFile.deleteSync();
      } catch (_) {}
      return false;
    }
  }

  /// Whether the server-offered [patchId]/[patchHash] is the patch this
  /// device already installed — read from `installed_patch_identity.json`
  /// (written at install on Android and iOS, surviving the restart). Does NOT clear
  /// the file on mismatch: a different offer is a genuinely new patch to
  /// install, which will overwrite the identity anyway.
  ///
  /// Gated on the patch bytes still being present: EVERY rollback path
  /// (crash three-strike, the OTA kill switch, or a public `rollback()`)
  /// removes the patch file, so a surviving-but-stale identity must not
  /// block re-delivery of the same patch after it was reverted.
  static bool _isPatchAlreadyInstalled({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) {
    if (!File('$patchDir/$_patchFilename').existsSync()) return false;
    final f = File('$patchDir/installed_patch_identity.json');
    if (!f.existsSync()) return false;
    try {
      final stored = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return _identityMatches(stored, patchId, patchHash);
    } catch (_) {
      // Corrupt — don't block a fresh install.
      return false;
    }
  }

  /// Whether the server-offered [patchId]/[patchHash] matches the patch
  /// currently PERSISTED ON DISK, read from `patch_info.json` — which
  /// may be a pending update awaiting restart, not necessarily the
  /// running module (that is `_loadedPatchId`/`_loadedPatchHash`). Used
  /// by the iOS upgrade check while a module is already loaded: a match
  /// means disk already holds the offer; anything missing or unreadable
  /// counts as NOT matching, because the safe consequence is
  /// re-persisting identical bytes — never discarding a genuinely new
  /// patch.
  @visibleForTesting
  static bool debugInstalledIdentityMatches({
    required String? patchDir,
    required String? patchId,
    required String? patchHash,
  }) {
    if (patchDir == null) return false;
    final f = File('$patchDir/patch_info.json');
    if (!f.existsSync()) return false;
    try {
      final stored = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return _identityMatches(stored, patchId, patchHash);
    } catch (_) {
      return false;
    }
  }

  /// Persists `patch_info.json` for the just-installed iOS patch: the
  /// rollback paths read it to record which patch was bad, the upgrade
  /// check compares offers against it, and the cold-start reload
  /// re-verifies the on-disk bytes ([patchHash] is the container hash)
  /// and the engine compatibility ([engineAbi] is the fingerprint the
  /// patch was installed against). Best-effort.
  static void _writeIosPatchInfo(
    String patchDir,
    String? patchId,
    String patchHash, {
    String? engineAbi,
  }) {
    try {
      File('$patchDir/patch_info.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'patch_id': patchId,
          'patch_hash': patchHash,
          'engine_abi': engineAbi,
          'installed_at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  /// Pure decision for whether the on-disk patch may be fed to the
  /// runtime at cold-start reload. Priority: engine-ABI compatibility
  /// first (an incompatible patch must not be loaded regardless of its
  /// integrity), then integrity. Absent, empty, or `'unknown'` metadata
  /// skips the corresponding check, so pre-`engine_abi` installs and
  /// older baselines degrade to loading exactly as before.
  @visibleForTesting
  static IosReloadGateDecision debugDecideReloadGate({
    required String? storedAbi,
    required String? liveAbi,
    required String? storedHash,
    required String? actualHash,
  }) {
    final sAbi = _nonEmptyOrNull(storedAbi);
    final sHash = _nonEmptyOrNull(storedHash);
    if (sAbi != null &&
        sAbi != 'unknown' &&
        liveAbi != null &&
        liveAbi != 'unknown' &&
        sAbi != liveAbi) {
      return IosReloadGateDecision.skipIncompatibleAbi;
    }
    if (sHash != null && actualHash != null && sHash != actualHash) {
      return IosReloadGateDecision.dropCorrupt;
    }
    return IosReloadGateDecision.load;
  }

  /// Pure decision for an offer that arrives while a module is already
  /// loaded (iOS). Extracted so the four-way branch the upgrade-deadlock
  /// fix hinges on is testable off-device. Priority order matters:
  /// an offer already persisted on disk is skipped without looking at
  /// its bytes (nothing would be written anyway), then malformed
  /// containers are rejected before they can overwrite the working
  /// patch, and only then is persist-silent vs persist-restart chosen.
  @visibleForTesting
  static IosLoadedSessionDecision debugDecideLoadedSessionOffer({
    required bool offerMatchesDisk,
    required bool formatValid,
    required bool offerMatchesRunningModule,
  }) {
    if (offerMatchesDisk) {
      return IosLoadedSessionDecision.skipAlreadyInstalled;
    }
    if (!formatValid) {
      return IosLoadedSessionDecision.rejectMalformed;
    }
    return offerMatchesRunningModule
        ? IosLoadedSessionDecision.persistSilently
        : IosLoadedSessionDecision.persistAndRestart;
  }

  /// A stable, numeric per-install identifier for the `device_hash`
  /// query param. Persisted to the patch dir so it survives restarts;
  /// numeric so the server can both key its 15-minute per-device rate
  /// limit and bucket staged rollout (`device_hash % 100`). Best-effort:
  /// returns null when it can't be read/created, which simply leaves the
  /// param off — the server then skips the limiter, exactly as before.
  static String? _cachedDeviceHash;

  static Future<String?> _deviceHash() async {
    final cached = _cachedDeviceHash;
    if (cached != null) return cached;
    try {
      final patchDir = await _getPatchDir();
      if (patchDir == null) return null;
      final f = File('$patchDir/device_id');
      if (f.existsSync()) {
        final v = f.readAsStringSync().trim();
        if (v.isNotEmpty) return _cachedDeviceHash = v;
      }
      final rng = Random.secure();
      // A positive 63-bit int (two draws), as a decimal string.
      final id = (rng.nextInt(0x80000000) << 32) | rng.nextInt(0x100000000);
      Directory(patchDir).createSync(recursive: true);
      f.writeAsStringSync('$id');
      return _cachedDeviceHash = '$id';
    } catch (_) {
      return null;
    }
  }

  /// Records the just-installed patch's server identity in a file the
  /// engine's rollback does not delete (Android), so a later launch can
  /// quarantine it if the engine rolled it back. Best-effort.
  static void _recordInstalledIdentity({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) {
    try {
      File('$patchDir/installed_patch_identity.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'patch_id': patchId,
          'patch_hash': patchHash,
          'installed_at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {
      // Non-fatal: without it the crash-loop still bottoms out at the
      // engine's three-strike rollback, just without the quarantine.
    }
  }

  /// If the engine left a rollback breadcrumb (`rollback_info.json`),
  /// quarantine the rolled-back patch — but only ONCE per breadcrumb. A
  /// breadcrumb that lingers offline (telemetry never acked) must not
  /// re-quarantine a good patch that was installed in the meantime, so
  /// the breadcrumb is flagged `quarantined` after the first promotion.
  /// Synchronous, best-effort, idempotent — safe to call more than once.
  ///
  /// Cross-component assumption: the native engine (`Updater::Rollback`)
  /// **replaces** `rollback_info.json` wholesale on each rollback, so a
  /// new bad patch always arrives as a fresh, unflagged breadcrumb. If a
  /// future engine ever did a read-modify-write that preserved unknown
  /// keys, a stale `quarantined` flag would make this early-return and
  /// the new bad patch would fall back to the engine's three-strike
  /// protection instead of being quarantined.
  static void _quarantineFromBreadcrumb(String patchDir) {
    try {
      final marker = File('$patchDir/rollback_info.json');
      if (!marker.existsSync()) return;
      final info =
          jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      if (info['quarantined'] == true) return;
      // Flag the breadcrumb BEFORE promoting, so this is all-or-nothing:
      // if the flag write throws, we return WITHOUT consuming the identity
      // (a later boot retries cleanly). The alternative order could leave
      // the breadcrumb unflagged AND the identity consumed — and if a good
      // patch were installed before the next boot, the still-live
      // breadcrumb would then quarantine that good patch.
      info['quarantined'] = true;
      marker.writeAsStringSync(jsonEncode(info));
      _promoteRolledBackIdentity(patchDir);
    } catch (_) {
      // Best-effort; the three-strike rollback still protects the device.
    }
  }

  /// Promotes the surviving install-time identity into the
  /// `rolled_back_patch` marker, then consumes the identity file. Called
  /// when the engine's rollback breadcrumb is detected on Android.
  static void _promoteRolledBackIdentity(String patchDir) {
    try {
      final idFile = File('$patchDir/installed_patch_identity.json');
      if (!idFile.existsSync()) return;
      final id = jsonDecode(idFile.readAsStringSync()) as Map<String, dynamic>;
      File('$patchDir/rolled_back_patch').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'patch_id': id['patch_id'],
          'patch_hash': id['patch_hash'],
          'rolled_back_at': DateTime.now().toIso8601String(),
        }),
      );
      idFile.deleteSync();
    } catch (_) {
      // Best-effort quarantine; the three-strike rollback still protects
      // the device even if this fails.
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
    _cachedIsPlayInstall = null;
    _cachedDeviceHash = null;
    _cachedPatchDir = null;
  }

  /// Test-only wrappers for the rolled-back-patch quarantine helpers.
  @visibleForTesting
  static bool debugIsPatchQuarantined({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) =>
      _isPatchQuarantined(
        patchDir: patchDir,
        patchId: patchId,
        patchHash: patchHash,
      );

  @visibleForTesting
  static void debugRecordInstalledIdentity({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) =>
      _recordInstalledIdentity(
        patchDir: patchDir,
        patchId: patchId,
        patchHash: patchHash,
      );

  @visibleForTesting
  static void debugPromoteRolledBackIdentity(String patchDir) =>
      _promoteRolledBackIdentity(patchDir);

  @visibleForTesting
  static void debugQuarantineFromBreadcrumb(String patchDir) =>
      _quarantineFromBreadcrumb(patchDir);

  @visibleForTesting
  static bool debugIsPatchAlreadyInstalled({
    required String patchDir,
    required String? patchId,
    required String? patchHash,
  }) =>
      _isPatchAlreadyInstalled(
        patchDir: patchDir,
        patchId: patchId,
        patchHash: patchHash,
      );

  @visibleForTesting
  static Future<String?> debugDeviceHash() => _deviceHash();

  /// Cached distribution-proof baseline UUID (see [_readBaselineId]).
  static String? _cachedBaselineId;

  /// Cached installer-source verdict for the session.
  static bool? _cachedIsPlayInstall;

  /// Whether this build was installed by the Google Play Store.
  ///
  /// Backs [init]'s `disableOnPlayStoreInstalls`: developers who want
  /// store-only updates for Play-installed builds set that flag, and
  /// this check decides whether it applies to the running install.
  /// Only meaningful on Android; false elsewhere and on any failure
  /// (a build without the plugin — debug, sideload — is not a store
  /// install, so failing open keeps OTA available where it is allowed).
  @visibleForTesting
  static Future<bool> isPlayStoreInstall() async {
    final cached = _cachedIsPlayInstall;
    if (cached != null) return cached;
    try {
      if (!(debugForceAndroidPlatform || Platform.isAndroid)) {
        return _cachedIsPlayInstall = false;
      }
      final installer = await _pluginChannel
          .invokeMethod<String>('getInstallerSource')
          .timeout(const Duration(seconds: 2));
      return _cachedIsPlayInstall = installer == 'com.android.vending';
    } catch (_) {
      // Transient failure (slow first boot, torn-down messenger): fail
      // open for this call but do NOT cache it, so the next init or
      // check re-asks instead of pinning the wrong answer all session.
      return false;
    }
  }

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
    _loadedPatchId = null;
    _loadedPatchHash = null;
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

    // Write-to-tmp then rename: a process kill mid-write must never
    // leave a truncated container at the final path — the next boot
    // would roll back and quarantine whatever patch `patch_info.json`
    // currently names, which may be the GOOD running patch. An orphaned
    // `.tmp` is harmless (never loaded) and is reaped opportunistically
    // by the next install or the native stale-bundle cleanup.
    final tmp = File('$patchDir/$_patchFilename.tmp');
    await tmp.writeAsBytes(patchBytes, flush: true);
    tmp.renameSync('$patchDir/$_patchFilename');
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
  /// iOS-only: unwraps a patch container and hands its payload to the
  /// runtime, latching success or rolling back on failure.
  ///
  /// Shared by both routes that can load a patch — the post-download
  /// install and the startup reload — so the two can never drift. This
  /// is the most failure-sensitive code in the SDK: one copy only.
  ///
  /// [origin] is recorded in the on-device debug log so a failure can
  /// be attributed to the install or the reload route.
  static Future<bool> _iosLoadPayload({
    required Uint8List container,
    required String? patchDir,
    required String? patchId,
    required String serverUrl,
    required String appId,
    required String origin,
  }) async {
    try {
      final payload = debugExtractIosPayload(container);
      if (patchDir != null) {
        _iosAppendDebugLog(
          patchDir,
          'BEFORE_LOAD origin=$origin patchId=$patchId '
          'bytes=${container.length} payload=${payload?.length}',
        );
      }

      // Format guard: reject a payload that doesn't match the expected
      // iOS marker before handing it to the runtime. A mismatched or
      // truncated payload cannot load cleanly, so delete it and surface
      // an upgrade hint instead.
      if (payload == null) {
        if (patchDir != null) {
          _iosAppendDebugLog(
            patchDir,
            'HEADER_MISMATCH origin=$origin patchId=$patchId '
            'bytes=${container.length}',
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
          'CALL_LOAD origin=$origin patchId=$patchId '
          'payload=${payload.length}',
        );
      }
      // Invoke the runtime hook exposed by the code-push-capable
      // engine. Callers guarantee the hook exists (install MATCHES the
      // server's fingerprint before downloading; reload verifies the
      // stored engine ABI against the live probe before reading).
      //
      // Return-value semantics: the hook throws on real load failures
      // (bad format, verification failure, etc.). Any non-throw return
      // — including `null` — is a successful load. `null` in particular
      // comes back when the payload loaded cleanly but had no entry
      // point to invoke (for example, a delta whose contents are all
      // already present in the baseline). That is a valid no-op, not a
      // failure, and must NOT trigger rollback — rolling back would
      // cause the next check to re-download, re-load, and loop tightly.
      final rawResult = await ui
          // ignore: undefined_function
          .codePushLoadModule(Uint8List.fromList(payload));

      // A `false` return is the one non-throw value we refuse: no
      // engine build uses it to mean success, so if one ever signals
      // failure this way, latching success here would mark a bad patch
      // active AND clear its quarantine marker below. Throwing routes
      // it through the normal rollback path.
      if (rawResult == false) {
        throw StateError('module load reported failure');
      }

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
      _loadedPatchId = patchId;
      _loadedPatchHash = sha256.convert(container).toString();
      moduleResult.value = result;
      status.value = 'Patch active';
      // Clear any previous rollback marker — this patch works.
      if (patchDir != null) {
        try {
          final rbFile = File('$patchDir/rolled_back_patch');
          if (rbFile.existsSync()) rbFile.deleteSync();
        } catch (_) {}
        _iosAppendDebugLog(
          patchDir,
          'AFTER_LOAD origin=$origin patchId=$patchId result=$result '
          'moduleLoaded=$_moduleLoaded',
        );
      }
      print(
        '[CP] MODULE LOADED OK ($origin) — result=$result '
        'moduleLoaded=$_moduleLoaded',
      );
      return true;
    } catch (e) {
      if (patchDir != null) {
        _iosAppendDebugLog(
          patchDir,
          'LOAD_THROW origin=$origin patchId=$patchId error=$e',
        );
      }
      print('[CP] MODULE LOAD THREW ($origin) — $e');
      status.value = 'Module error: $e — rolling back patch';
      // Real load failure. Delete immediately instead of waiting for
      // the three-strike auto-rollback.
      await _iosImmediateRollback(
        serverUrl: serverUrl,
        appId: appId,
        patchId: patchId,
        errorMessage: 'Patch load threw $e — deleted immediately',
      );
      return false;
    }
  }

  /// iOS-only: loads the already-installed patch from disk at startup.
  ///
  /// The engine maps patches at boot on Android/desktop; on iOS the
  /// patch is handed to the runtime from Dart, so it must be re-loaded
  /// on every launch. No network is involved — this is what makes an
  /// installed patch survive a restart and work offline.
  ///
  /// Never throws: any failure either rolls the patch back (a real load
  /// failure) or leaves the baseline running.
  static Future<void> _iosReloadInstalledPatch({
    required String serverUrl,
    required String appId,
  }) async {
    if (!Platform.isIOS || _moduleLoaded) return;
    try {
      final patchDir = await _getPatchDir();
      if (patchDir == null) return;
      final patchFile = File('$patchDir/$_patchFilename');
      if (!patchFile.existsSync()) return;

      // The runtime hook only exists on a code-push-capable engine.
      // Without it no load is possible, so release the strike that
      // _runCrashProtection just recorded — three launches on a stock
      // engine must not quarantine a patch that was never attempted.
      final liveAbi = await _probeEngineFingerprint();
      if (liveAbi == null) {
        _iosResetBootCounter(patchDir);
        return;
      }

      final info = _readInstalledPatchInfo(patchDir);
      final patchId = info?['patch_id']?.toString();

      final container = await patchFile.readAsBytes();

      // Re-check BEFORE acting on the gate: a resume-triggered
      // checkAndInstall can install and load a patch while the probe /
      // file read were in flight. Without this, the stale `info` read
      // above could be compared against the freshly-installed container
      // — a false dropCorrupt verdict that would DELETE the good patch
      // (and a second load on the load path would throw and quarantine
      // the wrong patch).
      if (_moduleLoaded) return;

      final gate = debugDecideReloadGate(
        storedAbi: info?['engine_abi']?.toString(),
        liveAbi: liveAbi,
        storedHash: info?['patch_hash']?.toString(),
        actualHash: sha256.convert(container).toString(),
      );
      switch (gate) {
        case IosReloadGateDecision.skipIncompatibleAbi:
          // The engine changed under the patch (a store update whose
          // staleness the native mtime heuristic missed). Feeding it to
          // the new engine risks a VM abort no try/catch can route to
          // rollback. Baseline keeps running; the next check fetches a
          // compatible patch.
          _iosResetBootCounter(patchDir);
          status.value = 'Installed patch was built for a different '
              'engine — waiting for a compatible update';
          // Fleet observability: without this, engine-changed devices
          // sit on baseline invisibly. Fire-and-forget so the boot path
          // never waits on telemetry; delivery/latch semantics live in
          // the helper.
          unawaited(
            debugReportIncompatibleReload(
              serverUrl: serverUrl,
              appId: appId,
              patchId: patchId,
              storedAbi: info?['engine_abi']?.toString(),
              liveAbi: liveAbi,
            ),
          );
          return;
        case IosReloadGateDecision.dropCorrupt:
          // Corruption, NOT a bad patch — delete without quarantining
          // (a rolled_back_patch marker would wrongly block
          // re-downloading the same, good patch). The identity file
          // goes too so the on-disk records stay consistent.
          try {
            patchFile.deleteSync();
          } catch (_) {}
          try {
            File('$patchDir/patch_info.json').deleteSync();
          } catch (_) {}
          try {
            File('$patchDir/installed_patch_identity.json').deleteSync();
          } catch (_) {}
          _iosResetBootCounter(patchDir);
          status.value =
              'Installed patch failed integrity check — will re-download';
          return;
        case IosReloadGateDecision.load:
          break;
      }

      await _iosLoadPayload(
        container: container,
        patchDir: patchDir,
        patchId: patchId,
        serverUrl: serverUrl,
        appId: appId,
        origin: 'reload',
      );
    } catch (e) {
      // Reload must never take the app down; the baseline is running.
      status.value = 'Patch reload error: $e';
    }
  }

  /// Reads the installed patch's metadata map from `patch_info.json`
  /// (`patch_id`, `patch_hash`, `engine_abi`, `installed_at`), or null
  /// when absent/unreadable.
  static Map<String, dynamic>? _readInstalledPatchInfo(String patchDir) {
    try {
      final f = File('$patchDir/patch_info.json');
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }

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
    _loadedPatchId = null;
    _loadedPatchHash = null;
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
    this.disableOnPlayStoreInstalls = false,
  });

  final String serverUrl;
  final String appId;
  final String releaseVersion;
  final Duration checkInterval;
  final String channel;

  /// Keep OTA updates off for builds installed from the Play Store, so
  /// those installs only ever change through store updates. Off-store
  /// installs (sideload, other stores, MDM) are unaffected. Off by
  /// default.
  final bool disableOnPlayStoreInstalls;
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
      disableOnPlayStoreInstalls: cfg.disableOnPlayStoreInstalls,
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
  const _HttpResult(this.statusCode, this.body, this.bytes);
}

Future<_HttpResult> _httpGet(String url) async {
  // connectionTimeout only bounds establishing the connection; a server
  // that accepts and then stalls would otherwise hang this await forever
  // — and with the single-flight guard in checkAndInstall, one such
  // hang would silently disable all future update checks for the
  // process lifetime. Every await is bounded.
  final timeout = CodePush.debugHttpRequestTimeout;
  // Offers and errors are kilobytes of JSON; cap generously so a
  // hostile server can't OOM the app through the metadata channel
  // either (the patch download has its own, larger cap).
  const maxBytes = 1024 * 1024;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.contentLength > maxBytes) {
      return const _HttpResult(-1, '', <int>[]);
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(
      timeout,
      onTimeout: (sink) =>
          sink.addError(TimeoutException('response stalled', timeout)),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        return const _HttpResult(-1, '', <int>[]);
      }
    }
    return _HttpResult(response.statusCode, utf8.decode(bytes), bytes);
  } finally {
    client.close(force: true);
  }
}

Future<_HttpResult> _httpGetBytes(String url) async {
  final maxBytes = CodePush.debugMaxPatchDownloadBytes;
  final timeout = CodePush.debugHttpRequestTimeout;
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    // The bytes we hash must be exactly the bytes on the wire — don't
    // let transparent gunzip make integrity depend on whether a CDN
    // toggled Content-Encoding.
    ..autoUncompress = false;
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    final response = await request.close().timeout(timeout);
    // Cap the download so a misbehaving server can't drive the app out
    // of memory. Real patches are tens of megabytes.
    if (response.contentLength > maxBytes) {
      return const _HttpResult(-1, '', <int>[]);
    }
    // Stalls are bounded two ways: the stream timeout fires on any
    // inter-chunk gap, and the deadline bounds a trickling server that
    // sends a byte just often enough to reset the gap timer.
    final deadline = DateTime.now().add(const Duration(minutes: 15));
    final bytes = <int>[];
    await for (final chunk in response.timeout(
      timeout,
      onTimeout: (sink) =>
          sink.addError(TimeoutException('patch download stalled', timeout)),
    )) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes || DateTime.now().isAfter(deadline)) {
        return const _HttpResult(-1, '', <int>[]);
      }
    }
    return _HttpResult(response.statusCode, '', bytes);
  } finally {
    client.close(force: true);
  }
}

Future<_HttpResult> _httpPostJson(String url, Map<String, dynamic> body) async {
  final timeout = CodePush.debugHttpRequestTimeout;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(Uri.parse(url)).timeout(timeout);
    request.headers.set('Content-Type', 'application/json');
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close().timeout(timeout);
    final bytes = await response.fold<List<int>>(
        <int>[], (prev, chunk) => prev..addAll(chunk)).timeout(timeout);
    return _HttpResult(response.statusCode, utf8.decode(bytes), bytes);
  } finally {
    client.close(force: true);
  }
}
