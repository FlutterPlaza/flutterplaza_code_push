import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Finding #14: production servers historically sent no `patch_id` in the
/// /updates offer, so identity matching must work hash-only and the skip
/// status must never render a null id ("Skipping rolled-back patch null").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());
  const patchHash =
      'aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999';

  late Directory patchDir;
  late HttpServer server;
  late int downloads;

  setUp(() async {
    patchDir = Directory.systemTemp.createTempSync('offer_shape');
    downloads = 0;
    CodePush.debugResetBaselineHashCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
      if (call.method == 'CodePush.getPatchDir') return patchDir.path;
      if (call.method == 'CodePush.getEngineAbi') return 'abi';
      return null;
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      if (req.uri.path.endsWith('/updates')) {
        // The real legacy offer shape: patch_hash/patch_number/
        // release_version but NO patch_id.
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'patch_available': true,
            'patch_hash': patchHash,
            'patch_number': 2,
            'release_version': '1.0.0+1',
            'patch_url': 'http://127.0.0.1:${server.port}/patch',
          }));
      } else {
        downloads++;
        req.response.statusCode = HttpStatus.notFound;
      }
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

  test(
      'id-less offer matching a hash-only quarantine marker is skipped '
      'without rendering null', () async {
    // What the Android breadcrumb promotion produces when the server
    // never sent an id: identity carried hash only.
    File('${patchDir.path}/rolled_back_patch')
        .writeAsStringSync(jsonEncode({'patch_hash': patchHash}));

    final installed = await CodePush.checkAndInstall(
      serverUrl: 'http://127.0.0.1:${server.port}',
      appId: 'app',
      releaseVersion: '1.0.0+1',
    );

    expect(installed, isFalse);
    expect(CodePush.status.value, contains('Skipping rolled-back patch'));
    expect(CodePush.status.value, isNot(contains('null')));
    expect(CodePush.status.value, contains(patchHash.substring(0, 8)));
    expect(downloads, 0, reason: 'quarantined patch must not re-download');
  });

  test('id-less offer for a fresh patch still downloads (no false skip)',
      () async {
    final installed = await CodePush.checkAndInstall(
      serverUrl: 'http://127.0.0.1:${server.port}',
      appId: 'app',
      releaseVersion: '1.0.0+1',
    );

    expect(installed, isFalse); // download 404s in this stub
    expect(downloads, 1, reason: 'no marker → offer must proceed');
  });
}
