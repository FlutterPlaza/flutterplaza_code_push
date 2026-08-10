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
    // The engine writes patch.vmcode on Android/desktop (host platform in
    // tests). The skip is gated on these bytes being present.
    File patchFile() => File('${patchDir.path}/patch.vmcode');

    setUp(() => patchDir = Directory.systemTemp.createTempSync('reoffer'));
    tearDown(() => patchDir.deleteSync(recursive: true));

    void installed({String? id, String? hash}) {
      patchFile().writeAsBytesSync([1, 2, 3]);
      identity().writeAsStringSync(jsonEncode({
        if (id != null) 'patch_id': id,
        if (hash != null) 'patch_hash': hash,
      }));
    }

    test('no identity file → not already installed', () {
      patchFile().writeAsBytesSync([1]);
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
      installed(id: 'installed');
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
      installed(id: 'old', hash: 'oldhash');
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

    test(
        'REGRESSION: identity survives but patch bytes were rolled back → '
        'NOT already installed (re-delivery not blocked)', () {
      // OTA kill switch / public rollback() removes the patch bytes but
      // leaves installed_patch_identity.json. A re-offer of the same
      // patch must proceed, not be skipped forever.
      installed(id: 'reverted', hash: 'h');
      patchFile().deleteSync(); // rolled back — bytes gone, identity stale
      expect(
        CodePush.debugIsPatchAlreadyInstalled(
          patchDir: patchDir.path,
          patchId: 'reverted',
          patchHash: 'h',
        ),
        isFalse,
      );
    });

    test('corrupt identity does not block a fresh install', () {
      patchFile().writeAsBytesSync([1]);
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
      expect(int.parse(first), greaterThanOrEqualTo(0));
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

  // ── Finding #6 end-to-end through checkAndInstall ───────────────────
  group('checkAndInstall already-installed short-circuit', () {
    late Directory patchDir;
    late HttpServer server;
    late int downloads;

    void serveOffer() {
      server.listen((HttpRequest req) {
        if (req.uri.path.endsWith('/updates')) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'patch_available': true,
              'patch_id': 'p1',
              'patch_hash': 'h1',
              'patch_url': 'http://127.0.0.1:${server.port}/patch',
            }));
        } else {
          downloads++; // the patch download endpoint
          req.response.statusCode = HttpStatus.notFound;
        }
        req.response.close();
      });
    }

    setUp(() async {
      patchDir = Directory.systemTemp.createTempSync('reoffer_e2e');
      downloads = 0;
      CodePush.debugResetBaselineHashCache();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
        if (call.method == 'CodePush.getPatchDir') return patchDir.path;
        if (call.method == 'CodePush.getEngineAbi') return 'abi';
        return null;
      });
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engineChannel, null);
      CodePush.debugResetBaselineHashCache();
      await server.close(force: true);
      patchDir.deleteSync(recursive: true);
    });

    Future<bool> check() => CodePush.checkAndInstall(
          serverUrl: 'http://127.0.0.1:${server.port}',
          appId: 'app',
          releaseVersion: '1.0.0+1',
        );

    test('installed patch re-offered → skipped, no download', () async {
      // Simulate the patch already installed (bytes + identity).
      File('${patchDir.path}/patch.vmcode').writeAsBytesSync([1, 2, 3]);
      File('${patchDir.path}/installed_patch_identity.json').writeAsStringSync(
          jsonEncode({'patch_id': 'p1', 'patch_hash': 'h1'}));
      serveOffer();

      final installed = await check();

      expect(installed, isFalse);
      expect(CodePush.status.value, contains('already installed'));
      expect(downloads, 0, reason: 'must not re-download the same patch');
    });

    test(
        'after rollback (bytes gone, identity stale) → NOT skipped, '
        'download proceeds', () async {
      // Identity survives, but the patch bytes were reverted.
      File('${patchDir.path}/installed_patch_identity.json').writeAsStringSync(
          jsonEncode({'patch_id': 'p1', 'patch_hash': 'h1'}));
      serveOffer();

      await check();

      expect(downloads, 1, reason: 're-delivery must not be blocked');
    });
  });
}
