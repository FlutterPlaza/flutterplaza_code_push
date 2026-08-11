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

  group('debugDecideLoadedSessionOffer (the four-way branch)', () {
    // Note: this is the HELPER's priority order — a disk match wins
    // regardless of the other inputs. The call site still evaluates
    // all three predicates eagerly (they are pure and cannot throw).
    test('a disk match wins regardless of the other inputs', () {
      expect(
        CodePush.debugDecideLoadedSessionOffer(
          offerMatchesDisk: true,
          formatValid: false,
          offerMatchesRunningModule: true,
        ),
        IosLoadedSessionDecision.skipAlreadyInstalled,
      );
    });

    test('malformed containers are rejected before any write', () {
      expect(
        CodePush.debugDecideLoadedSessionOffer(
          offerMatchesDisk: false,
          formatValid: false,
          offerMatchesRunningModule: false,
        ),
        IosLoadedSessionDecision.rejectMalformed,
      );
      // Even when the offer claims to be the running module — bytes
      // that fail the format check must never reach disk.
      expect(
        CodePush.debugDecideLoadedSessionOffer(
          offerMatchesDisk: false,
          formatValid: false,
          offerMatchesRunningModule: true,
        ),
        IosLoadedSessionDecision.rejectMalformed,
      );
    });

    test('server revert to the running module persists silently', () {
      expect(
        CodePush.debugDecideLoadedSessionOffer(
          offerMatchesDisk: false,
          formatValid: true,
          offerMatchesRunningModule: true,
        ),
        IosLoadedSessionDecision.persistSilently,
      );
    });

    test('a genuinely new patch persists with restart-to-apply', () {
      expect(
        CodePush.debugDecideLoadedSessionOffer(
          offerMatchesDisk: false,
          formatValid: true,
          offerMatchesRunningModule: false,
        ),
        IosLoadedSessionDecision.persistAndRestart,
      );
    });
  });

  group('debugDecideReloadGate (ABI + integrity)', () {
    test('legacy install with no metadata loads as before', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: null,
          liveAbi: 'flutter-3.41.2',
          storedHash: null,
          actualHash: 'h',
        ),
        IosReloadGateDecision.load,
      );
    });

    test('matching ABI and hash loads', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'flutter-3.41.2',
          liveAbi: 'flutter-3.41.2',
          storedHash: 'h1',
          actualHash: 'h1',
        ),
        IosReloadGateDecision.load,
      );
    });

    test('ABI mismatch skips the load', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'flutter-3.41.2',
          liveAbi: 'flutter-3.41.6',
          storedHash: 'h1',
          actualHash: 'h1',
        ),
        IosReloadGateDecision.skipIncompatibleAbi,
      );
    });

    test('unknown on either side skips the ABI comparison', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'unknown',
          liveAbi: 'flutter-3.41.6',
          storedHash: 'h1',
          actualHash: 'h1',
        ),
        IosReloadGateDecision.load,
      );
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'flutter-3.41.2',
          liveAbi: 'unknown',
          storedHash: 'h1',
          actualHash: 'h1',
        ),
        IosReloadGateDecision.load,
      );
    });

    test('empty-string metadata is treated as absent', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: '',
          liveAbi: 'flutter-3.41.6',
          storedHash: '',
          actualHash: 'h1',
        ),
        IosReloadGateDecision.load,
      );
    });

    test('hash mismatch drops the corrupt container', () {
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'flutter-3.41.2',
          liveAbi: 'flutter-3.41.2',
          storedHash: 'h1',
          actualHash: 'h2',
        ),
        IosReloadGateDecision.dropCorrupt,
      );
    });

    test('ABI incompatibility wins over integrity', () {
      // An incompatible patch must not be loaded regardless of its
      // bytes; it also must NOT be dropped as corrupt (it may be a
      // perfectly good patch for the engine it was built against).
      expect(
        CodePush.debugDecideReloadGate(
          storedAbi: 'flutter-3.41.2',
          liveAbi: 'flutter-3.41.6',
          storedHash: 'h1',
          actualHash: 'h2',
        ),
        IosReloadGateDecision.skipIncompatibleAbi,
      );
    });
  });
}
