import 'dart:async';
import 'dart:convert' show base64Decode;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter/codepush');
  late List<MethodCall> log;

  setUp(() {
    log = <MethodCall>[];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('CodePush.checkForUpdate', () {
    test('returns update info when update is available', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return <String, dynamic>{
          'isUpdateAvailable': true,
          'patchVersion': '1.0.0+2',
          'downloadSize': 102400,
        };
      });

      final UpdateInfo info = await CodePush.checkForUpdate();

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.checkForUpdate');
      expect(info.isUpdateAvailable, isTrue);
      expect(info.patchVersion, '1.0.0+2');
      expect(info.downloadSize, 102400);
    });

    test('returns no update when none is available', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return <String, dynamic>{
          'isUpdateAvailable': false,
        };
      });

      final UpdateInfo info = await CodePush.checkForUpdate();

      expect(info.isUpdateAvailable, isFalse);
      expect(info.patchVersion, isNull);
      expect(info.downloadSize, isNull);
    });

    test('throws when no response from engine', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      expect(
        () => CodePush.checkForUpdate(),
        throwsA(isA<CodePushException>()),
      );
    });
  });

  group('CodePush.downloadAndApply', () {
    test('invokes download and apply method', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return true;
      });

      await CodePush.downloadAndApply();

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.downloadAndApply');
    });

    test('throws when download fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return false;
      });

      expect(
        () => CodePush.downloadAndApply(),
        throwsA(isA<CodePushException>()),
      );
    });
  });

  group('CodePush.currentPatch', () {
    test('returns patch info when patch is active', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return <String, dynamic>{
          'version': '1.0.0+2',
          'installedAt': 1700000000000,
        };
      });

      final PatchInfo? info = await CodePush.currentPatch;

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.getCurrentPatch');
      expect(info, isNotNull);
      expect(info!.version, '1.0.0+2');
      expect(
        info.installedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('returns null when no patch is active', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      final PatchInfo? info = await CodePush.currentPatch;

      expect(info, isNull);
    });
  });

  group('CodePush.isPatched', () {
    test('returns true when patched', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return true;
      });

      final bool patched = await CodePush.isPatched;

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.isPatched');
      expect(patched, isTrue);
    });

    test('returns false when not patched', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return false;
      });

      final bool patched = await CodePush.isPatched;

      expect(patched, isFalse);
    });
  });

  group('CodePush.rollback', () {
    test('invokes rollback method', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return true;
      });

      await CodePush.rollback();

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.rollback');
    });

    test('throws when rollback fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return false;
      });

      expect(
        () => CodePush.rollback(),
        throwsA(isA<CodePushException>()),
      );
    });
  });

  group('CodePush.installPatch', () {
    test('sends base64-encoded bytes to engine', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return true;
      });

      final patchBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      await CodePush.installPatch(patchBytes);

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.installPatch');
      final args = (log.single.arguments as List<Object?>).cast<String>();
      expect(args, hasLength(1));
      final decoded = Uint8List.fromList(base64Decode(args[0]));
      expect(decoded, patchBytes);
    });

    test('throws when installation fails', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return false;
      });

      expect(
        () => CodePush.installPatch(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<CodePushException>()),
      );
    });
  });

  group('CodePush.releaseVersion', () {
    test('returns version string', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return '1.0.0+1';
      });

      final String version = await CodePush.releaseVersion;

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.getReleaseVersion');
      expect(version, '1.0.0+1');
    });

    test('returns empty string when no version available', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      final String version = await CodePush.releaseVersion;

      expect(version, '');
    });
  });

  group('CodePush.cleanupOldPatches', () {
    test('returns number of removed patches', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return 3;
      });

      final int removed = await CodePush.cleanupOldPatches();

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.cleanupOldPatches');
      expect(removed, 3);
    });

    test('returns 0 when null response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      final int removed = await CodePush.cleanupOldPatches();

      expect(removed, 0);
    });
  });

  group('CodePush.checkForUpdatePeriodically', () {
    test('calls onUpdateAvailable when update is found', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return <String, dynamic>{
          'isUpdateAvailable': true,
          'patchVersion': '2.0.0+1',
          'downloadSize': 204800,
        };
      });

      UpdateInfo? receivedUpdate;
      final Timer timer = CodePush.checkForUpdatePeriodically(
        interval: const Duration(milliseconds: 10),
        onUpdateAvailable: (UpdateInfo update) {
          receivedUpdate = update;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      timer.cancel();

      expect(receivedUpdate, isNotNull);
      expect(receivedUpdate!.isUpdateAvailable, isTrue);
      expect(receivedUpdate!.patchVersion, '2.0.0+1');
    });

    test('does not call callback when no update available', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return <String, dynamic>{
          'isUpdateAvailable': false,
        };
      });

      bool callbackCalled = false;
      final Timer timer = CodePush.checkForUpdatePeriodically(
        interval: const Duration(milliseconds: 10),
        onUpdateAvailable: (UpdateInfo update) {
          callbackCalled = true;
        },
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      timer.cancel();

      expect(callbackCalled, isFalse);
    });

    test('can be cancelled via timer', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return <String, dynamic>{
          'isUpdateAvailable': true,
          'patchVersion': '2.0.0+1',
        };
      });

      final Timer timer = CodePush.checkForUpdatePeriodically(
        interval: const Duration(milliseconds: 10),
        onUpdateAvailable: (UpdateInfo update) {},
      );

      timer.cancel();
      expect(timer.isActive, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(log, isEmpty);
    });
  });

  group('CodePush.patchCount', () {
    test('returns count when patches exist', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        return 5;
      });

      final int count = await CodePush.patchCount;

      expect(log, hasLength(1));
      expect(log.single.method, 'CodePush.getPatchCount');
      expect(count, 5);
    });

    test('returns 0 when null response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        return null;
      });

      final int count = await CodePush.patchCount;

      expect(count, 0);
    });
  });

  group('Model classes', () {
    test('UpdateInfo.toString includes all fields', () {
      const info = UpdateInfo(
        isUpdateAvailable: true,
        patchVersion: '1.0.0+2',
        downloadSize: 1024,
      );
      expect(info.toString(), contains('isUpdateAvailable: true'));
      expect(info.toString(), contains('patchVersion: 1.0.0+2'));
      expect(info.toString(), contains('downloadSize: 1024'));
    });

    test('PatchInfo.toString includes all fields', () {
      final info = PatchInfo(
        version: '1.0.0+2',
        installedAt: DateTime(2024),
      );
      expect(info.toString(), contains('version: 1.0.0+2'));
    });

    test('CodePushException.toString includes message', () {
      final exception = CodePushException('test error');
      expect(exception.toString(), 'CodePushException: test error');
      expect(exception.message, 'test error');
    });
  });
}
