import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Upgrade-deadlock fix: while a module is loaded, `checkAndInstall`
/// must distinguish "the offer IS the running patch" (skip) from "the
/// offer is a NEW patch" (persist + restart-to-apply). That decision is
/// [CodePush.debugInstalledIdentityMatches] over `patch_info.json`;
/// anything missing or unreadable must count as NOT matching, because
/// the safe consequence of a false negative is re-persisting identical
/// bytes, while a false positive discards a genuinely new patch and
/// deadlocks upgrades. (The persist-vs-load branch itself is
/// Platform.isIOS-gated and exercised on device, not here.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cp_deadlock_test');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  void writeInfo(Object? content) {
    final f = File('${tmp.path}/patch_info.json');
    if (content is String) {
      f.writeAsStringSync(content);
    } else {
      f.writeAsStringSync(jsonEncode(content));
    }
  }

  test('null patchDir never matches', () {
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: null,
        patchId: 'p1',
        patchHash: 'h1',
      ),
      isFalse,
    );
  });

  test('missing patch_info.json never matches', () {
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: 'p1',
        patchHash: 'h1',
      ),
      isFalse,
    );
  });

  test('corrupt patch_info.json never matches', () {
    writeInfo('{not json');
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: 'p1',
        patchHash: 'h1',
      ),
      isFalse,
    );
  });

  test('matches by patch_id even when hashes differ', () {
    writeInfo({'patch_id': 'p1', 'patch_hash': 'stored-hash'});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: 'p1',
        patchHash: 'different-hash',
      ),
      isTrue,
    );
  });

  test('matches by hash when ids are absent (legacy server)', () {
    writeInfo({'patch_id': null, 'patch_hash': 'h1'});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: null,
        patchHash: 'h1',
      ),
      isTrue,
    );
  });

  test('a genuinely new patch does not match — the upgrade case', () {
    writeInfo({'patch_id': 'p1', 'patch_hash': 'h1'});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: 'p2',
        patchHash: 'h2',
      ),
      isFalse,
    );
  });

  test('all-null identities never match', () {
    writeInfo({'patch_id': null, 'patch_hash': null});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: null,
        patchHash: null,
      ),
      isFalse,
    );
  });

  test('null offered id still matches on hash', () {
    writeInfo({'patch_id': 'p1', 'patch_hash': 'h1'});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: null,
        patchHash: 'h1',
      ),
      isTrue,
    );
  });

  test('empty-string hashes never alias two different patches', () {
    // A server emitting patch_hash: "" must not make patch p2 look
    // "already installed" because p1's record also carries "" — that
    // would re-create the upgrade deadlock through the identity file.
    writeInfo({'patch_id': 'p1', 'patch_hash': ''});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: 'p2',
        patchHash: '',
      ),
      isFalse,
    );
  });

  test('empty-string ids never match each other', () {
    writeInfo({'patch_id': '', 'patch_hash': 'h1'});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: '',
        patchHash: 'h2',
      ),
      isFalse,
    );
  });

  test('all-empty identities never match', () {
    writeInfo({'patch_id': '', 'patch_hash': ''});
    expect(
      CodePush.debugInstalledIdentityMatches(
        patchDir: tmp.path,
        patchId: '',
        patchHash: '',
      ),
      isFalse,
    );
  });
}
