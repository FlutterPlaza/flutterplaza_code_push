import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// The incompatible-reload stranding report: correct payload, latched
/// per process on DELIVERY (a completed HTTP round trip), and retried
/// when the device was offline at boot.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding stubs HttpClient to a 400-only fake; these tests
  // need the real loopback stack.
  HttpOverrides.global = null;

  late HttpServer server;
  late List<Map<String, dynamic>> posts;

  setUp(() async {
    CodePush.debugResetIncompatibleReloadLatch();
    posts = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      posts.add(
        jsonDecode(await utf8.decoder.bind(req).join()) //
            as Map<String, dynamic>,
      );
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    CodePush.debugResetIncompatibleReloadLatch();
  });

  Future<void> fire({String? url}) => CodePush.debugReportIncompatibleReload(
        serverUrl: url ?? 'http://127.0.0.1:${server.port}',
        appId: 'test-app',
        patchId: 'p1',
        storedAbi: 'flutter-3.41.2',
        liveAbi: 'flutter-3.41.6',
      );

  test('posts kind incompatible_reload with stored vs live ABI', () async {
    await fire();

    expect(posts, hasLength(1));
    final p = posts.single;
    expect(p['kind'], 'incompatible_reload');
    expect(p['app_id'], 'test-app');
    expect(p['patch_id'], 'p1');
    expect(p['expected_engine_fingerprint'], 'flutter-3.41.2');
    expect(p['actual_engine_fingerprint'], 'flutter-3.41.6');
  });

  test('a delivered report latches — re-init does not re-POST', () async {
    await fire();
    await fire();

    expect(posts, hasLength(1),
        reason: 'one delivered report per process is sufficient');
  });

  test('transport failure clears the latch so a later re-init retries',
      () async {
    // A port with no listener — connection refused, no round trip.
    final deadServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = deadServer.port;
    await deadServer.close(force: true);

    await fire(url: 'http://127.0.0.1:$deadPort');
    expect(posts, isEmpty);

    // Device back online (the real server): the retry must fire.
    await fire();
    expect(posts, hasLength(1),
        reason: 'an offline boot must not permanently lose the report');
  });
}
