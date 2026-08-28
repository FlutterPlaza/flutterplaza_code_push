import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Pre-publish hardening (reconcile-review findings): download integrity,
/// cleartext refusal, single-flight checks, and the download size cap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());
  final patchBytes = List<int>.generate(64, (i) => (i * 5) % 256);
  final patchHash = sha256.convert(patchBytes).toString();

  late Directory patchDir;
  late HttpServer server;
  late int downloads;
  late int updateChecks;
  Duration offerDelay = Duration.zero;
  String? offeredHash;
  String? offeredUrlOverride;
  String? offeredEngineFingerprint;
  Future<void> Function()? onTelemetry;

  void serve() {
    server.listen((HttpRequest req) async {
      if (req.uri.path.endsWith('/updates')) {
        updateChecks++;
        if (offerDelay > Duration.zero) await Future.delayed(offerDelay);
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'patch_available': true,
            'patch_id': 'p1',
            if (offeredHash != null) 'patch_hash': offeredHash,
            if (offeredEngineFingerprint != null)
              'engine_fingerprint': offeredEngineFingerprint,
            'patch_url':
                offeredUrlOverride ?? 'http://127.0.0.1:${server.port}/patch',
          }));
      } else if (req.uri.path.endsWith('/telemetry/client-error')) {
        if (onTelemetry != null) await onTelemetry!();
        req.response.statusCode = HttpStatus.ok;
      } else {
        downloads++;
        req.response.statusCode = HttpStatus.ok;
        req.response.add(patchBytes);
      }
      await req.response.close();
    });
  }

  setUp(() async {
    patchDir = Directory.systemTemp.createTempSync('hardening');
    downloads = 0;
    updateChecks = 0;
    offerDelay = Duration.zero;
    offeredHash = null;
    offeredUrlOverride = null;
    offeredEngineFingerprint = null;
    onTelemetry = null;
    CodePush.debugResetBaselineHashCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engineChannel, (MethodCall call) async {
      if (call.method == 'CodePush.getPatchDir') return patchDir.path;
      if (call.method == 'CodePush.getEngineAbi') return 'abi';
      if (call.method == 'CodePush.installPatch') return true;
      return null;
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(engineChannel, null);
    CodePush.debugResetBaselineHashCache();
    CodePush.debugMaxPatchDownloadBytes = 256 * 1024 * 1024;
    CodePush.debugHttpRequestTimeout = const Duration(seconds: 30);
    await server.close(force: true);
    patchDir.deleteSync(recursive: true);
  });

  Future<bool> check() => CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'app',
        releaseVersion: '1.0.0+1',
      );

  group('download integrity', () {
    test('matching patch_hash installs', () async {
      offeredHash = patchHash;
      serve();

      expect(await check(), isTrue);
      expect(CodePush.status.value, 'Restart to apply');
    });

    test('mismatching patch_hash is refused before install', () async {
      offeredHash = 'f' * 64;
      serve();

      expect(await check(), isFalse);
      expect(CodePush.status.value, 'Patch failed verification');
      expect(downloads, 1, reason: 'refusal happens after download');
    });

    test('legacy offer without patch_hash still installs', () async {
      offeredHash = null;
      serve();

      expect(await check(), isTrue);
    });
  });

  group('cleartext refusal', () {
    test('non-loopback http patch_url is refused without download', () async {
      offeredHash = patchHash;
      offeredUrlOverride = 'http://updates.example.com/patch';
      serve();

      expect(await check(), isFalse);
      expect(CodePush.status.value, 'Insecure patch URL refused');
      expect(downloads, 0);
    });

    test('loopback http stays allowed for development', () async {
      offeredHash = patchHash;
      serve();

      expect(await check(), isTrue);
    });
  });

  group('single-flight', () {
    test('a stalled server times out and RELEASES the guard', () async {
      // Regression guard for the wedge: connectionTimeout doesn't bound
      // the response, so a server that accepts and never answers used
      // to hang the check forever — latching _checkInFlight and
      // silently disabling all future update checks.
      CodePush.debugHttpRequestTimeout = const Duration(milliseconds: 300);
      server.listen((HttpRequest req) {
        updateChecks++;
        // Accept and stall: no response is ever written.
      });

      final first = await CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'app',
        releaseVersion: '1.0.0+1',
      ).timeout(const Duration(seconds: 5));
      expect(first, isFalse);

      final second = await CodePush.checkAndInstall(
        serverUrl: 'http://127.0.0.1:${server.port}',
        appId: 'app',
        releaseVersion: '1.0.0+1',
      ).timeout(const Duration(seconds: 5));
      expect(second, isFalse);
      expect(updateChecks, 2,
          reason: 'the guard must release after a timeout — a second '
              'check reaches the server instead of returning early');
    });

    test('overlapping checks collapse to one server round-trip', () async {
      offeredHash = patchHash;
      offerDelay = const Duration(milliseconds: 300);
      serve();

      final results = await Future.wait([check(), check(), check()]);

      expect(results.where((r) => r).length, 1,
          reason: 'exactly one check wins');
      expect(updateChecks, 1, reason: 'losers return before the network');
      expect(downloads, 1);
    });

    test('a losing overlapped check writes its own reason to status',
        () async {
      // Contract: checkAndInstall leaves its reason in CodePush.status
      // before EVERY false return — including the single-flight early
      // return, which previously left the other check's in-flight state
      // in place (so a caller surfacing status after `false` rendered a
      // foreign operation's progress as its own result).
      offeredHash = patchHash;
      offerDelay = const Duration(milliseconds: 300);
      serve();

      // Both calls in the same synchronous turn: the winner latches the
      // guard before its first await, and the loser's status write also
      // lands before ITS first await — so no wall-clock sequencing is
      // needed (a delay could even over-sleep past the offer window and
      // turn the "loser" into a real second check).
      final winner = check();
      final loser = check();
      expect(CodePush.status.value, 'A check is already running');
      expect(await loser, isFalse);

      await winner;
    });

    test(
        'incompatible-baseline terminal status survives a concurrent check '
        'during the telemetry POST', () async {
      // Regression guard for the reordered terminal writes: the engine
      // ABI-mismatch branch reports telemetry (awaited) BEFORE writing
      // its terminal status. A concurrent check() arriving inside that
      // await stamps 'A check is already running'; the terminal write
      // must land AFTER the await so the actionable message is what
      // stands when the winner returns. Moving that write back up next
      // to its branch condition turns this test red.
      offeredHash = patchHash;
      offeredEngineFingerprint = 'flutter-9.9.9'; // mocked engine: 'abi'
      Future<bool>? loser;
      String? statusDuringReport;
      onTelemetry = () async {
        // The winner is parked on the awaited telemetry POST with the
        // single-flight guard held — exactly the reordered-write window.
        loser ??= check();
        statusDuringReport = CodePush.status.value;
      };
      serve();

      expect(await check(), isFalse);
      expect(loser, isNotNull, reason: 'the telemetry hook must have fired');
      expect(await loser, isFalse);
      expect(statusDuringReport, 'A check is already running',
          reason: 'the loser must have stamped its status inside the '
              'window, or this test is not exercising the race');
      expect(
        CodePush.status.value,
        startsWith('Incompatible baseline: engine ABI mismatch'),
      );
      expect(downloads, 0, reason: 'mismatch is refused before download');
    });
  });

  group('download size cap', () {
    test('a response larger than the cap fails soft', () async {
      offeredHash = patchHash;
      CodePush.debugMaxPatchDownloadBytes = 16; // patch is 64 bytes
      serve();

      expect(await check(), isFalse);
      expect(CodePush.status.value, contains('Download failed'));
    });

    test(
        'a chunked response with no declared length is capped while '
        'streaming', () async {
      // A hostile server omits Content-Length, so the pre-check cannot
      // fire — only the streaming guard can. Chunked transfer encoding
      // exercises exactly that branch.
      offeredHash = patchHash;
      CodePush.debugMaxPatchDownloadBytes = 1024;
      server.listen((HttpRequest req) async {
        if (req.uri.path.endsWith('/updates')) {
          req.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({
              'patch_available': true,
              'patch_id': 'p1',
              'patch_hash': patchHash,
              'patch_url': 'http://127.0.0.1:${server.port}/patch',
            }));
        } else {
          // The client aborts mid-stream once the cap trips; writes to
          // a dead connection throw and must not fail the test zone.
          try {
            req.response.headers.chunkedTransferEncoding = true;
            for (var i = 0; i < 64; i++) {
              req.response.add(List<int>.filled(64, i)); // 4 KB total
              await req.response.flush();
            }
          } catch (_) {}
        }
        try {
          await req.response.close();
        } catch (_) {}
      });

      expect(await check(), isFalse);
      expect(CodePush.status.value, contains('Download failed'));
    });
  });
}
