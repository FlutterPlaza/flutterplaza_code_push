import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Regression harness for issue #30 — a later [CodePush.init] must supersede
/// an earlier one.
///
/// `init` bumps an epoch and every async gap BEFORE the update flow starts
/// re-checks it, so a superseded session cannot start timers or fire
/// telemetry. The flow's continuation (crash protection → reload →
/// launch timer → quarantine/rollback reporting → first check) originally
/// did NOT carry that epoch, so two `init` calls left two live chains and
/// the FIRST one won the single-flight guard. That was the race behind
/// "`CodePushOverlay` does not actually supersede an earlier
/// `init(onUpdateReady:)`": the app's own callback fires and the overlay's
/// banner never appears.
///
/// This asserts the fixed behavior: the update flow threads the captured
/// init epoch into its continuation and re-checks it after every await,
/// so the superseded chain dies before reaching the server. The file was
/// originally committed skipped as a pre-fix reproduction (it failed with
/// the stale session winning the guard); it now runs as the regression
/// gate for #30.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs HttpClient to a 400-only fake; this test needs the
  // real loopback stack to reach the local capture server.
  HttpOverrides.global = null;

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());
  const pluginChannel = MethodChannel('flutterplaza_code_push');

  late HttpServer server;
  late List<Uri> requests;
  late Completer<void> firstRequest;
  // Per-test request handler: the server's single listen subscription
  // delegates here, so a test can swap in custom behavior (e.g. holding
  // a response open) without re-listening on the stream.
  late Future<void> Function(HttpRequest req) handler;

  setUp(() async {
    requests = <Uri>[];
    firstRequest = Completer<void>();
    handler = (HttpRequest req) async {
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
    };
    CodePush.debugResetBaselineHashCache();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      requests.add(req.uri);
      if (!firstRequest.isCompleted) firstRequest.complete();
      handler(req);
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        engineChannel, (MethodCall call) async => null);
    messenger.setMockMethodCallHandler(
        pluginChannel, (MethodCall call) async => null);
  });

  tearDown(() async {
    CodePush.dispose();
    CodePush.debugResetBaselineHashCache();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(engineChannel, null);
    messenger.setMockMethodCallHandler(pluginChannel, null);
    await server.close(force: true);
  });

  test(
    'a second init supersedes the first: only the newest session checks the '
    'server (issue #30)',
    () async {
      // The two sessions are told apart by `app_id`, which rides on the
      // /updates query — so the captured request names which session's
      // config (and therefore whose onUpdateReady) owns the update cycle.
      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'superseded-main',
        releaseVersion: '1.0.0+1',
      );
      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'overlay-owner',
        releaseVersion: '1.0.0+1',
      );
      // Deterministic sync: wait for the surviving chain's request to
      // land (generous timeout for loaded CI runners), then one short
      // settle window in which a stale chain's request — the bug —
      // would also have arrived.
      await firstRequest.future.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(requests, isNotEmpty, reason: 'the surviving session must check');
      expect(
        requests.map((Uri u) => u.queryParameters['app_id']).toSet(),
        <String>{'overlay-owner'},
        reason: 'the superseded session must not reach the server',
      );
    },
  );

  test(
    'a supersede DURING an in-flight check re-arms the live session: the '
    'stale request is answered, then the live session checks (issue #30 '
    'starvation half)',
    () async {
      // Hold the FIRST request's response open so the stale chain is
      // provably inside the single-flight guard when the supersede
      // lands; every later request answers immediately.
      final releaseFirst = Completer<void>();
      var held = 0;
      handler = (HttpRequest req) async {
        if (held == 0) {
          held = 1;
          await releaseFirst.future;
        }
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      };

      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'stale-holder',
        releaseVersion: '1.0.0+1',
      );
      // Wait until the stale chain's request is in flight (it holds the
      // single-flight guard from here until the response is released).
      await firstRequest.future.timeout(const Duration(seconds: 30));

      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'live-owner',
        releaseVersion: '1.0.0+1',
      );
      // Give the live chain time to reach checkAndInstall, lose the
      // guard to the stale in-flight check, and register its re-arm.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      releaseFirst.complete();
      // The stale chain's post-offer epoch check kills it; the guard
      // clears; the re-arm fires the live session's own check.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        requests.last.queryParameters['app_id'],
        'live-owner',
        reason: 'the re-arm must run the LIVE session\'s check after the '
            'stale in-flight one releases the guard',
      );
      expect(
        requests.where(
          (Uri u) => u.queryParameters['app_id'] == 'live-owner',
        ),
        hasLength(1),
        reason: 'exactly one re-armed check — no stampede',
      );
    },
  );

  test(
    'crash protection runs at most once per process across multiple inits '
    '(boot-counter latch)',
    () async {
      CodePush.debugResetCrashProtectionLatch();
      final before = CodePush.debugCrashProtectionRuns;
      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'latch-a',
        releaseVersion: '1.0.0+1',
      );
      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'latch-b',
        releaseVersion: '1.0.0+1',
      );
      await firstRequest.future.timeout(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        CodePush.debugCrashProtectionRuns - before,
        1,
        reason: 'two init chains, one crash-protection run',
      );
      CodePush.debugResetCrashProtectionLatch();
      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'latch-c',
        releaseVersion: '1.0.0+1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        CodePush.debugCrashProtectionRuns - before,
        2,
        reason: 'the test-only reset re-enables exactly one more run',
      );
    },
  );
}
