// Tests for the iOS crash protection logic in CodePush.
//
// The boot counter and auto-rollback methods are private static methods on
// CodePush, so we cannot call them directly. Instead, we replicate the
// file I/O logic here and verify behaviour against the same file layout
// the production code uses (boot_counter file, patch.vmcode, patch_info.json
// inside a patch directory).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Replicas of private CodePush crash-protection helpers
// ---------------------------------------------------------------------------

const int _maxBootAttempts = 3;

int _readBootCounter(String patchDir) {
  try {
    final file = File('$patchDir/boot_counter');
    if (!file.existsSync()) return 0;
    return int.tryParse(file.readAsStringSync().trim()) ?? 0;
  } catch (_) {
    return 0;
  }
}

void _writeBootCounter(String patchDir, int count) {
  try {
    final dir = Directory(patchDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$patchDir/boot_counter').writeAsStringSync('$count');
  } catch (_) {}
}

void _incrementBootCounter(String patchDir) {
  _writeBootCounter(patchDir, _readBootCounter(patchDir) + 1);
}

void _resetBootCounter(String patchDir) {
  _writeBootCounter(patchDir, 0);
}

/// Returns true if a rollback was performed.
bool _checkAndAutoRollback(String patchDir) {
  final count = _readBootCounter(patchDir);
  if (count < _maxBootAttempts) return false;

  // Auto-rollback: remove the patch and reset the counter.
  try {
    final patchFile = File('$patchDir/patch.vmcode');
    if (patchFile.existsSync()) patchFile.deleteSync();
    final infoFile = File('$patchDir/patch_info.json');
    if (infoFile.existsSync()) infoFile.deleteSync();
    _resetBootCounter(patchDir);
  } catch (_) {}
  return true;
}

// ---------------------------------------------------------------------------
// Replica of immediate rollback file cleanup (mirrors _iosImmediateRollback)
// ---------------------------------------------------------------------------

/// Simulates the file-cleanup portion of _iosImmediateRollback.
/// In production, this also calls CodePush.rollback (platform channel) and
/// POSTs telemetry to the server. Here we only test the filesystem behaviour.
Future<void> _immediateRollback(String patchDir) async {
  try {
    final patchFile = File('$patchDir/patch.vmcode');
    if (await patchFile.exists()) await patchFile.delete();
    final infoFile = File('$patchDir/patch_info.json');
    if (await infoFile.exists()) await infoFile.delete();
    _resetBootCounter(patchDir);
  } catch (_) {
    // Never crash the app over cleanup.
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late String patchDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('crash_protection_test_');
    patchDir = tempDir.path;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ── Boot counter file I/O ───────────────────────────────────────────

  group('Boot counter file I/O', () {
    test('read returns 0 when no boot_counter file exists', () {
      expect(_readBootCounter(patchDir), 0);
    });

    test('write creates the file and read returns the written value', () {
      _writeBootCounter(patchDir, 5);

      final file = File('$patchDir/boot_counter');
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), '5');
      expect(_readBootCounter(patchDir), 5);
    });

    test('write overwrites an existing value', () {
      _writeBootCounter(patchDir, 1);
      _writeBootCounter(patchDir, 42);

      expect(_readBootCounter(patchDir), 42);
    });

    test('increment increases value by 1 from 0', () {
      _incrementBootCounter(patchDir);

      expect(_readBootCounter(patchDir), 1);
    });

    test('increment increases value by 1 from existing value', () {
      _writeBootCounter(patchDir, 7);
      _incrementBootCounter(patchDir);

      expect(_readBootCounter(patchDir), 8);
    });

    test('multiple increments accumulate correctly', () {
      _incrementBootCounter(patchDir);
      _incrementBootCounter(patchDir);
      _incrementBootCounter(patchDir);

      expect(_readBootCounter(patchDir), 3);
    });

    test('reset sets the counter back to 0', () {
      _writeBootCounter(patchDir, 10);
      _resetBootCounter(patchDir);

      expect(_readBootCounter(patchDir), 0);
    });

    test('reset on a non-existent counter writes 0', () {
      _resetBootCounter(patchDir);

      final file = File('$patchDir/boot_counter');
      expect(file.existsSync(), isTrue);
      expect(_readBootCounter(patchDir), 0);
    });

    test('read returns 0 for corrupted (non-integer) file content', () {
      File('$patchDir/boot_counter').writeAsStringSync('not-a-number');

      expect(_readBootCounter(patchDir), 0);
    });

    test('read returns 0 for empty file', () {
      File('$patchDir/boot_counter').writeAsStringSync('');

      expect(_readBootCounter(patchDir), 0);
    });

    test('read trims whitespace from file content', () {
      File('$patchDir/boot_counter').writeAsStringSync('  4\n');

      expect(_readBootCounter(patchDir), 4);
    });

    test('write creates parent directories if they do not exist', () {
      final nested = '${tempDir.path}/nested/deep/dir';
      _writeBootCounter(nested, 3);

      expect(File('$nested/boot_counter').existsSync(), isTrue);
      expect(_readBootCounter(nested), 3);
    });
  });

  // ── Auto-rollback logic ─────────────────────────────────────────────

  group('iOS auto-rollback', () {
    test('rolls back when counter equals max boot attempts (3)', () {
      // Set up a patch directory with a patch file and a counter at the threshold.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      File('$patchDir/patch_info.json').writeAsStringSync('{"v":"1.0"}');
      _writeBootCounter(patchDir, 3);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isTrue);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(File('$patchDir/patch_info.json').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);
    });

    test('rolls back when counter exceeds max boot attempts', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      _writeBootCounter(patchDir, 10);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isTrue);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);
    });

    test('resets counter to 0 after rollback', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      _writeBootCounter(patchDir, 5);

      _checkAndAutoRollback(patchDir);

      expect(_readBootCounter(patchDir), 0);
    });

    test('deletes patch_info.json along with patch.vmcode', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      File('$patchDir/patch_info.json').writeAsStringSync('{"v":"1.0"}');
      _writeBootCounter(patchDir, 3);

      _checkAndAutoRollback(patchDir);

      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(File('$patchDir/patch_info.json').existsSync(), isFalse);
    });

    test('handles missing patch_info.json gracefully during rollback', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      // No patch_info.json
      _writeBootCounter(patchDir, 3);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isTrue);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);
    });

    test('handles missing patch.vmcode gracefully during rollback', () {
      // No patch.vmcode file, but counter is at threshold.
      _writeBootCounter(patchDir, 3);

      final rolled = _checkAndAutoRollback(patchDir);

      // Rollback still returns true (counter was at threshold),
      // even though there was nothing to delete.
      expect(rolled, isTrue);
      expect(_readBootCounter(patchDir), 0);
    });
  });

  // ── Below-threshold: no rollback ────────────────────────────────────

  group('Boot counter below threshold (no rollback)', () {
    test('does NOT rollback when counter is 0', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      _writeBootCounter(patchDir, 0);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
    });

    test('does NOT rollback when counter is 1', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      _writeBootCounter(patchDir, 1);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
    });

    test('does NOT rollback when counter is 2 (one below threshold)', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      _writeBootCounter(patchDir, 2);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
      // Counter is unchanged by checkAndAutoRollback when below threshold.
      expect(_readBootCounter(patchDir), 2);
    });

    test('does NOT rollback when no boot_counter file exists', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);

      final rolled = _checkAndAutoRollback(patchDir);

      expect(rolled, isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
    });

    test('preserves patch_info.json when below threshold', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xDE, 0xAD]);
      File('$patchDir/patch_info.json').writeAsStringSync('{"v":"2.0"}');
      _writeBootCounter(patchDir, 2);

      _checkAndAutoRollback(patchDir);

      expect(File('$patchDir/patch_info.json').existsSync(), isTrue);
      expect(
        File('$patchDir/patch_info.json').readAsStringSync(),
        '{"v":"2.0"}',
      );
    });
  });

  // ── End-to-end boot cycle simulation ────────────────────────────────

  group('Boot cycle simulation', () {
    test('three consecutive failed boots trigger rollback', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xCA, 0xFE]);

      // Simulate three boot attempts without a success report.
      _incrementBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 1);
      expect(_checkAndAutoRollback(patchDir), isFalse);

      _incrementBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 2);
      expect(_checkAndAutoRollback(patchDir), isFalse);

      _incrementBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 3);

      // Third failed boot — should trigger rollback.
      final rolled = _checkAndAutoRollback(patchDir);
      expect(rolled, isTrue);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);
    });

    test('successful launch resets counter and prevents rollback', () {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xCA, 0xFE]);

      // Two failed boots.
      _incrementBootCounter(patchDir);
      _incrementBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 2);

      // Successful launch resets the counter.
      _resetBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 0);

      // Next boot — counter is back to 0, no rollback.
      _incrementBootCounter(patchDir);
      expect(_checkAndAutoRollback(patchDir), isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
    });

    test('rollback cleans up then new patch can be installed fresh', () {
      // First patch crashes 3 times.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      _writeBootCounter(patchDir, 3);
      _checkAndAutoRollback(patchDir);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);

      // New patch is installed.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0x60, 0x0D]);
      // Counter is fresh at 0 — first boot.
      _incrementBootCounter(patchDir);
      expect(_checkAndAutoRollback(patchDir), isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
      expect(_readBootCounter(patchDir), 1);
    });
  });

  // ── iOS immediate rollback on load failure ──────────────────────────

  group('iOS immediate rollback (load failure)', () {
    test('deletes patch.vmcode on first failed load attempt', () async {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      _writeBootCounter(patchDir, 1); // Only 1 boot — below 3-boot threshold.

      await _immediateRollback(patchDir);

      // Patch deleted immediately — no need to wait for 3 boots.
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);
    });

    test('deletes patch_info.json alongside patch.vmcode', () async {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      File('$patchDir/patch_info.json').writeAsStringSync('{"v":"1.0"}');

      await _immediateRollback(patchDir);

      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(File('$patchDir/patch_info.json').existsSync(), isFalse);
    });

    test('resets boot counter to 0', () async {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      _writeBootCounter(patchDir, 2);

      await _immediateRollback(patchDir);

      expect(_readBootCounter(patchDir), 0);
    });

    test('handles missing patch.vmcode gracefully', () async {
      // No patch file on disk — cleanup should not throw.
      _writeBootCounter(patchDir, 1);

      await _immediateRollback(patchDir);

      expect(_readBootCounter(patchDir), 0);
    });

    test('handles missing patch_info.json gracefully', () async {
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      // No patch_info.json.

      await _immediateRollback(patchDir);

      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
    });

    test('after immediate rollback, new patch can be installed fresh', () async {
      // Bad patch triggers immediate rollback.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      _writeBootCounter(patchDir, 1);
      await _immediateRollback(patchDir);

      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
      expect(_readBootCounter(patchDir), 0);

      // New (good) patch is installed — counter starts fresh.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0x60, 0x0D]);
      _incrementBootCounter(patchDir);
      expect(_readBootCounter(patchDir), 1);
      expect(_checkAndAutoRollback(patchDir), isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);
    });

    test('immediate rollback is faster than 3-boot auto-rollback', () async {
      // Demonstrate the key difference: auto-rollback needs 3 boots,
      // immediate rollback acts on first failure.
      File('$patchDir/patch.vmcode').writeAsBytesSync([0xBA, 0xD0]);
      _writeBootCounter(patchDir, 0);

      // Auto-rollback would NOT act here (counter below threshold).
      expect(_checkAndAutoRollback(patchDir), isFalse);
      expect(File('$patchDir/patch.vmcode').existsSync(), isTrue);

      // Immediate rollback DOES act.
      await _immediateRollback(patchDir);
      expect(File('$patchDir/patch.vmcode').existsSync(), isFalse);
    });
  });
}
