import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Regression harness for issue #30 — a later [CodePush.init] must supersede
/// an earlier one.
///
/// `init` bumps an epoch and every async gap BEFORE the update flow starts
/// re-checks it, so a superseded session cannot start timers or fire
/// telemetry. The flow's own continuation (crash protection → reload →
/// launch timer → quarantine/rollback reporting → first check) does not carry
/// that epoch, so two `init` calls leave two live chains and the FIRST one
/// wins the single-flight guard. That is the race behind
/// "`CodePushOverlay` does not actually supersede an earlier
/// `init(onUpdateReady:)`": the app's own callback fires and the overlay's
/// banner never appears.
///
/// This asserts the fixed behavior and is deliberately SKIPPED: the fix lives
/// in the update flow itself (threading the captured epoch into the
/// continuation), which is outside the widget-layer scope of the branch that
/// added this file. Removing the `skip:` is the acceptance criterion for #30.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs HttpClient to a 400-only fake; this test needs the
  // real loopback stack to reach the local capture server.
  HttpOverrides.global = null;

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());
  const pluginChannel = MethodChannel('flutterplaza_code_push');

  late HttpServer server;
  late List<Uri> requests;

  setUp(() async {
    requests = <Uri>[];
    CodePush.debugResetBaselineHashCache();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      requests.add(req.uri);
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
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(requests, isNotEmpty, reason: 'the surviving session must check');
      expect(
        requests.map((Uri u) => u.queryParameters['app_id']).toSet(),
        <String>{'overlay-owner'},
        reason: 'the superseded session must not reach the server',
      );
    },
  );
}
