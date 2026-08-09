import 'dart:convert' show jsonEncode;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs HttpClient to a 400-only fake; these tests
  // need the real loopback stack to reach the local capture server.
  HttpOverrides.global = null;

  const pluginChannel = MethodChannel('flutterplaza_code_push');
  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());

  late HttpServer server;
  late void Function(HttpRequest req) handleRequest;

  Future<bool> check() => CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        releaseVersion: '1.0.0+1',
      );

  void serveOtaDisabled() {
    handleRequest = (HttpRequest req) {
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'patch_available': false,
            'ota_disabled': true,
          }),
        );
      req.response.close();
    };
  }

  setUp(() async {
    CodePush.debugResetBaselineHashCache();
    handleRequest = (HttpRequest req) {
      req.response.statusCode = HttpStatus.noContent;
      req.response.close();
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) => handleRequest(req));
  });

  tearDown(() async {
    CodePush.debugForceAndroidPlatform = false;
    CodePush.debugResetBaselineHashCache();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pluginChannel, null);
    messenger.setMockMethodCallHandler(engineChannel, null);
    await server.close(force: true);
  });

  group('server kill switch', () {
    test('clean device: stops quietly, revert attempt no-ops', () async {
      serveOtaDisabled();
      final engineCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        engineCalls.add(call.method);
        // Engine says the rollback did not apply; the Dart file
        // fallback then finds no patch dir and throws (swallowed).
        if (call.method == 'CodePush.rollback') return false;
        return null;
      });

      final installed = await check();

      expect(installed, isFalse);
      expect(CodePush.status.value, contains('OTA disabled'));
      expect(CodePush.status.value, isNot(contains('patch removed')));
    });

    test('patched device: reverts to the store baseline', () async {
      serveOtaDisabled();
      final engineCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        engineCalls.add(call.method);
        if (call.method == 'CodePush.rollback') return true;
        return null;
      });

      final installed = await check();

      expect(installed, isFalse);
      expect(
        engineCalls.where((m) => m == 'CodePush.rollback'),
        hasLength(1),
      );
      expect(CodePush.status.value, contains('patch removed'));
    });
  });

  group('init store-install gate', () {
    late List<Uri> requests;

    setUp(() {
      requests = <Uri>[];
      handleRequest = (HttpRequest req) {
        requests.add(req.uri);
        req.response.statusCode = HttpStatus.noContent;
        req.response.close();
      };
    });

    tearDown(CodePush.dispose);

    void mockChannels({required String? installer, List<String>? engineLog}) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pluginChannel,
          (MethodCall call) async {
        if (call.method == 'getInstallerSource') return installer;
        return null;
      });
      messenger.setMockMethodCallHandler(engineChannel,
          (MethodCall call) async {
        engineLog?.add(call.method);
        if (call.method == 'CodePush.rollback') return true;
        return null;
      });
    }

    test('Play install + flag: no update flow starts, leftover patch removed',
        () async {
      CodePush.debugForceAndroidPlatform = true;
      final engineLog = <String>[];
      mockChannels(installer: 'com.android.vending', engineLog: engineLog);

      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        releaseVersion: '1.0.0+1',
        disableOnPlayStoreInstalls: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(requests, isEmpty);
      expect(CodePush.status.value, contains('OTA off'));
      expect(engineLog, contains('CodePush.rollback'));
    });

    test(
        'dispose during the installer lookup wins: no ownerless flow starts '
        '(epoch regression test)', () async {
      CodePush.debugForceAndroidPlatform = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(pluginChannel,
          (MethodCall call) async {
        if (call.method == 'getInstallerSource') {
          // Hold the answer long enough for dispose() to land inside
          // the await gap, then answer "not a Play install" — the path
          // that would otherwise proceed to start the update flow.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return null;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(
          engineChannel, (MethodCall call) async => null);

      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        releaseVersion: '1.0.0+1',
        disableOnPlayStoreInstalls: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      CodePush.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(requests, isEmpty);
    });

    test('non-Play install + flag: the update flow runs normally', () async {
      CodePush.debugForceAndroidPlatform = true;
      mockChannels(installer: null);

      CodePush.init(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        releaseVersion: '1.0.0+1',
        disableOnPlayStoreInstalls: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(requests, isNotEmpty);
      expect(
        requests.first.path.endsWith('/api/v1/updates'),
        isTrue,
      );
    });
  });

  group('isPlayStoreInstall', () {
    late int installerCalls;

    void mockInstaller(String? installer) {
      installerCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pluginChannel, (MethodCall call) async {
        if (call.method == 'getInstallerSource') {
          installerCalls++;
          return installer;
        }
        return null;
      });
    }

    test('true for a Play-installed Android build, cached per session',
        () async {
      CodePush.debugForceAndroidPlatform = true;
      mockInstaller('com.android.vending');

      expect(await CodePush.isPlayStoreInstall(), isTrue);
      expect(await CodePush.isPlayStoreInstall(), isTrue);
      expect(installerCalls, 1);
    });

    test('false for other installers and sideloads', () async {
      CodePush.debugForceAndroidPlatform = true;
      mockInstaller('com.sec.android.app.samsungapps');
      expect(await CodePush.isPlayStoreInstall(), isFalse);

      CodePush.debugResetBaselineHashCache();
      mockInstaller(null);
      expect(await CodePush.isPlayStoreInstall(), isFalse);
    });

    test('false off Android without touching the channel', () async {
      mockInstaller('com.android.vending');
      expect(await CodePush.isPlayStoreInstall(), isFalse);
      expect(installerCalls, 0);
    });
  });
}
