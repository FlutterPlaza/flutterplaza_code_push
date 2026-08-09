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
    test('unpatched device: stops quietly, no rollback attempted', () async {
      serveOtaDisabled();
      final engineCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        engineCalls.add(call.method);
        if (call.method == 'CodePush.isPatched') return false;
        return null;
      });

      final installed = await check();

      expect(installed, isFalse);
      expect(CodePush.status.value, contains('OTA disabled'));
      expect(engineCalls, contains('CodePush.isPatched'));
      expect(engineCalls, isNot(contains('CodePush.rollback')));
    });

    test('patched device: reverts to the store baseline', () async {
      serveOtaDisabled();
      final engineCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        engineCalls.add(call.method);
        if (call.method == 'CodePush.isPatched') return true;
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
