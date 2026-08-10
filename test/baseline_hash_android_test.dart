import 'dart:convert' show jsonEncode;
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

  // Per-test server behavior; the default answers every request 204.
  late void Function(HttpRequest req) handleRequest;

  setUp(() async {
    hashCalls = 0;
    requests = <Uri>[];
    CodePush.debugForceAndroidPlatform = true;
    CodePush.debugResetBaselineHashCache();
    handleRequest = (HttpRequest req) {
      req.response.statusCode = HttpStatus.noContent;
      req.response.close();
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      requests.add(req.uri);
      handleRequest(req);
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

    test(
        'soft-gate mismatch: hash computed once within a check, telemetry '
        'reported once across checks', () async {
      mockAppLibHash(fakeHash);

      // A code-push-capable engine, so the flow reaches the soft gate.
      const engineChannel = MethodChannel(
        'flutter/codepush',
        JSONMethodCodec(),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        if (call.method == 'CodePush.getEngineAbi') return 'test-abi';
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(engineChannel, null);
      });

      var telemetryPosts = 0;
      final mismatchingHash = 'b' * 64;
      handleRequest = (HttpRequest req) {
        if (req.uri.path.endsWith('/api/v1/updates')) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(<String, dynamic>{
              'patch_available': true,
              'patch_id': 'p1',
              'patch_url': 'http://127.0.0.1:${server.port}/patch',
              'baseline_hash': mismatchingHash,
            }));
        } else if (req.uri.path.endsWith('/api/v1/telemetry/client-error')) {
          telemetryPosts++;
          req.response.statusCode = HttpStatus.ok;
        } else {
          // Patch download — fail it so the check exits after the gate.
          req.response.statusCode = HttpStatus.notFound;
        }
        req.response.close();
      };

      // Within one check the hash is computed at the query step AND the
      // soft-gate step — the shared cache/in-flight future must collapse
      // that to a single platform-channel invocation.
      await check();
      expect(hashCalls, 1);
      expect(telemetryPosts, 1);

      // A second check sees the same mismatch pair — already reported,
      // so no further telemetry.
      await check();
      expect(hashCalls, 1);
      expect(telemetryPosts, 1);
    });
  });
}
