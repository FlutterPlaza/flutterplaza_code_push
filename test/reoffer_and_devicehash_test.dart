import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());

  // ── Finding #6: already-installed skip ──────────────────────────────
  group('_isPatchAlreadyInstalled', () {
    late Directory patchDir;
    File identity() => File('${patchDir.path}/installed_patch_identity.json');

    setUp(() => patchDir = Directory.systemTemp.createTempSync('reoffer'));
    tearDown(() => patchDir.deleteSync(recursive: true));

    void writeIdentity({String? id, String? hash}) {
      identity().writeAsStringSync(jsonEncode({
        if (id != null) 'patch_id': id,
        if (hash != null) 'patch_hash': hash,
      }));
    }

    test('no identity file → not already installed', () {
      expect(
        CodePush.debugIsPatchAlreadyInstalled(
          patchDir: patchDir.path,
          patchId: 'p1',
          patchHash: 'h1',
        ),
        isFalse,
      );
    });

    test('matches the installed patch by id (would skip re-offer)', () {
      writeIdentity(id: 'installed');
      expect(
        CodePush.debugIsPatchAlreadyInstalled(
          patchDir: patchDir.path,
          patchId: 'installed',
          patchHash: 'anything',
        ),
        isTrue,
      );
    });

    test('a genuinely new patch is not "already installed", file kept', () {
      writeIdentity(id: 'old', hash: 'oldhash');
      expect(
        CodePush.debugIsPatchAlreadyInstalled(
          patchDir: patchDir.path,
          patchId: 'new',
          patchHash: 'newhash',
        ),
        isFalse,
      );
      // Unlike the quarantine check, a mismatch does NOT delete the
      // identity — the new patch's install will overwrite it.
      expect(identity().existsSync(), isTrue);
    });

    test('corrupt identity does not block a fresh install', () {
      identity().writeAsStringSync('{ nope');
      expect(
        CodePush.debugIsPatchAlreadyInstalled(
          patchDir: patchDir.path,
          patchId: 'p1',
          patchHash: 'h1',
        ),
        isFalse,
      );
    });
  });

  // ── Finding #11: device_hash ────────────────────────────────────────
  group('device_hash', () {
    late Directory patchDir;
    late HttpServer server;
    late List<Uri> requests;

    setUp(() async {
      patchDir = Directory.systemTemp.createTempSync('devicehash');
      requests = <Uri>[];
      CodePush.debugResetBaselineHashCache();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        if (call.method == 'CodePush.getPatchDir') return patchDir.path;
        if (call.method == 'CodePush.getEngineAbi') return 'abi';
        return null;
      });
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) {
        requests.add(req.uri);
        req.response.statusCode = HttpStatus.noContent;
        req.response.close();
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, null);
      CodePush.debugResetBaselineHashCache();
      await server.close(force: true);
      patchDir.deleteSync(recursive: true);
    });

    test('generates a stable numeric id, persisted to the patch dir', () async {
      final first = await CodePush.debugDeviceHash();
      final second = await CodePush.debugDeviceHash();

      expect(first, isNotNull);
      expect(int.tryParse(first!), isNotNull, reason: 'must be numeric');
      expect(int.parse(first), greaterThan(0));
      expect(second, equals(first), reason: 'stable across calls');
      expect(File('${patchDir.path}/device_id').existsSync(), isTrue);
    });

    test('checkAndInstall sends device_hash on the /updates query', () async {
      await CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'app',
        releaseVersion: '1.0.0+1',
      );

      expect(requests, hasLength(1));
      final dh = requests.single.queryParameters['device_hash'];
      expect(dh, isNotNull);
      expect(int.tryParse(dh!), isNotNull);
    });
  });
}
