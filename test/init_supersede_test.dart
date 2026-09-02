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

  setUp(() async {
    requests = <Uri>[];
    firstRequest = Completer<void>();
    CodePush.debugResetBaselineHashCache();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      requests.add(req.uri);
      if (!firstRequest.isCompleted) firstRequest.complete();
      req.response.statusCode = HttpStatus.noContent;
      req.response.close();
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
}
