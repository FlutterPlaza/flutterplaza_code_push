import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding installs an HttpClient stub that answers every
  // request with a 400 and never touches the network. These tests need
  // the real loopback stack to reach the local capture server.
  HttpOverrides.global = null;

  const pluginChannel = MethodChannel('flutterplaza_code_push');
  const fakeHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  late HttpServer server;
  late List<Uri> requests;
  late int hashCalls;

  void mockAppLibHash(String? hash) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pluginChannel, (MethodCall call) async {
      if (call.method == 'getAppLibHash') {
        hashCalls++;
        return hash;
      }
      return null;
    });
  }

  Future<void> check() => CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        releaseVersion: '1.0.0+1',
      );

  setUp(() async {
    hashCalls = 0;
    requests = <Uri>[];
    CodePush.debugForceAndroidPlatform = true;
    CodePush.debugResetBaselineHashCache();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      requests.add(req.uri);
      req.response.statusCode = HttpStatus.noContent;
      req.response.close();
    });
  });

  tearDown(() async {
    CodePush.debugForceAndroidPlatform = false;
    CodePush.debugResetBaselineHashCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pluginChannel, null);
    await server.close(force: true);
  });

  group('Android baseline hash on /updates', () {
    test('sends baseline_hash when the platform side resolves a hash',
        () async {
      mockAppLibHash(fakeHash);

      await check();

      expect(requests, hasLength(1));
      expect(requests.single.queryParameters['baseline_hash'], fakeHash);
    });

    test('omits baseline_hash when the platform side returns null', () async {
      mockAppLibHash(null);

      await check();

      expect(requests, hasLength(1));
      expect(
        requests.single.queryParameters.containsKey('baseline_hash'),
        isFalse,
      );
    });

    test(
        'caches a successful hash: platform channel invoked once across '
        'checks', () async {
      mockAppLibHash(fakeHash);

      await check();
      await check();

      expect(hashCalls, 1);
      expect(requests, hasLength(2));
      expect(requests.last.queryParameters['baseline_hash'], fakeHash);
    });

    test(
        'remembers a failure briefly: platform channel not re-invoked '
        'within the retry window', () async {
      mockAppLibHash(null);

      await check();
      await check();

      expect(hashCalls, 1);
      expect(requests, hasLength(2));
      expect(
        requests.last.queryParameters.containsKey('baseline_hash'),
        isFalse,
      );
    });
  });
}
