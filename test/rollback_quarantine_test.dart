import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Finding #7: once a patch has been rolled back on this device, the SDK
/// must refuse to re-download it (offline, no server round-trip), so a
/// bad patch at 100% rollout can't crash-loop the device forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory patchDir;
  File marker() => File('${patchDir.path}/rolled_back_patch');
  File identity() => File('${patchDir.path}/installed_patch_identity.json');

  setUp(() {
    patchDir = Directory.systemTemp.createTempSync('quarantine_test');
  });
  tearDown(() => patchDir.deleteSync(recursive: true));

  group('_isPatchQuarantined', () {
    void writeMarker({String? id, String? hash}) {
      marker().writeAsStringSync(jsonEncode({
        if (id != null) 'patch_id': id,
        if (hash != null) 'patch_hash': hash,
      }));
    }

    test('no marker → not quarantined', () {
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'p1',
          patchHash: 'h1',
        ),
        isFalse,
      );
    });

    test('matches by patch_id', () {
      writeMarker(id: 'bad');
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'bad',
          patchHash: 'whatever',
        ),
        isTrue,
      );
    });

    test('matches by patch_hash', () {
      writeMarker(hash: 'deadbeef');
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'different-id',
          patchHash: 'deadbeef',
        ),
        isTrue,
      );
    });

    test('a different patch is not quarantined AND clears the stale marker',
        () {
      writeMarker(id: 'bad', hash: 'oldhash');
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'newgood',
          patchHash: 'newhash',
        ),
        isFalse,
      );
      // The quarantine is never permanent: once the server moves on, the
      // marker is dropped.
      expect(marker().existsSync(), isFalse);
    });

    test('a corrupt marker is cleared and does not block', () {
      marker().writeAsStringSync('{ not json');
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'p1',
          patchHash: 'h1',
        ),
        isFalse,
      );
      expect(marker().existsSync(), isFalse);
    });
  });

  group('Android promotion (install identity → rollback marker)', () {
    test('promotes the surviving identity and consumes it', () {
      CodePush.debugRecordInstalledIdentity(
        patchDir: patchDir.path,
        patchId: 'bad',
        patchHash: 'badhash',
      );
      expect(identity().existsSync(), isTrue);

      CodePush.debugPromoteRolledBackIdentity(patchDir.path);

      // The identity is now the quarantine marker...
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'bad',
          patchHash: null,
        ),
        isTrue,
      );
      // ...and the identity file is consumed, so a persisting rollback
      // breadcrumb can't re-promote a later good patch's identity.
      expect(identity().existsSync(), isFalse);
    });

    test('promotion with no identity file is a safe no-op', () {
      CodePush.debugPromoteRolledBackIdentity(patchDir.path);
      expect(marker().existsSync(), isFalse);
    });
  });

  group('_quarantineFromBreadcrumb (once-per-breadcrumb guard)', () {
    File breadcrumb() => File('${patchDir.path}/rollback_info.json');

    void writeBreadcrumb({bool quarantined = false}) {
      breadcrumb().writeAsStringSync(jsonEncode({
        'reason': 'boot_loop',
        'patch_version': '1.0.0+2',
        if (quarantined) 'quarantined': true,
      }));
    }

    test('a fresh breadcrumb promotes the identity and flags itself', () {
      CodePush.debugRecordInstalledIdentity(
        patchDir: patchDir.path,
        patchId: 'bad',
        patchHash: 'h',
      );
      writeBreadcrumb();

      CodePush.debugQuarantineFromBreadcrumb(patchDir.path);

      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'bad',
          patchHash: null,
        ),
        isTrue,
      );
      final bc =
          jsonDecode(breadcrumb().readAsStringSync()) as Map<String, dynamic>;
      expect(bc['quarantined'], isTrue);
      expect(identity().existsSync(), isFalse); // consumed
    });

    test(
        'a breadcrumb already flagged does NOT re-quarantine a good patch '
        'installed in the meantime', () {
      // The bad patch was already quarantined; its breadcrumb lingers
      // (telemetry never acked, device offline).
      writeBreadcrumb(quarantined: true);
      // Meanwhile a genuinely good patch got installed.
      CodePush.debugRecordInstalledIdentity(
        patchDir: patchDir.path,
        patchId: 'good',
        patchHash: 'goodhash',
      );

      CodePush.debugQuarantineFromBreadcrumb(patchDir.path);

      // The good patch must NOT be quarantined by the stale breadcrumb.
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'good',
          patchHash: 'goodhash',
        ),
        isFalse,
      );
      // The good identity is untouched (not consumed).
      expect(identity().existsSync(), isTrue);
    });

    test('no breadcrumb → safe no-op', () {
      CodePush.debugQuarantineFromBreadcrumb(patchDir.path);
      expect(marker().existsSync(), isFalse);
    });

    test('end-to-end: install bad → rollback → the bad patch is quarantined',
        () {
      // Install records identity.
      CodePush.debugRecordInstalledIdentity(
        patchDir: patchDir.path,
        patchId: 'p-bad',
        patchHash: 'h-bad',
      );
      // Engine rolls it back → SDK promotes the identity.
      CodePush.debugPromoteRolledBackIdentity(patchDir.path);
      // A later check offering the same patch is refused.
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'p-bad',
          patchHash: 'h-bad',
        ),
        isTrue,
      );
      // But a genuinely new patch is allowed (and clears the quarantine).
      expect(
        CodePush.debugIsPatchQuarantined(
          patchDir: patchDir.path,
          patchId: 'p-good',
          patchHash: 'h-good',
        ),
        isFalse,
      );
    });
  });
}
