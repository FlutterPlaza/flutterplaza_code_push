import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// A deliberate [CodePush.rollback] must STICK: it quarantines the
/// removed patch so the next update check cannot silently re-deliver it
/// while the server still offers it. (The OTA kill switch goes through
/// the non-quarantining internal path instead — there the server has
/// stopped offering, and a re-enable must resume with the same patch.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const engineChannel = MethodChannel('flutter/codepush', JSONMethodCodec());
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // ONE directory for the whole file: CodePush memoizes the patch dir
  // (_cachedPatchDir), so per-test directories would go stale after the
  // first lookup. Contents are wiped between tests instead.
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('cp_rollback_test');
  });

  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    for (final e in tmp.listSync()) {
      try {
        e.deleteSync(recursive: true);
      } catch (_) {}
    }
    messenger.setMockMethodCallHandler(engineChannel, (MethodCall call) async {
      switch (call.method) {
        case 'CodePush.rollback':
          return false; // Engine updater absent → Dart-side branch runs.
        case 'CodePush.getPatchDir':
          return tmp.path;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(engineChannel, null);
  });

  test('public rollback() quarantines the removed patch', () async {
    File('${tmp.path}/patch.vmcode').writeAsBytesSync([1, 2, 3, 4]);
    File('${tmp.path}/patch_info.json').writeAsStringSync(
      jsonEncode({'patch_id': 'p1', 'patch_hash': 'h1'}),
    );

    await CodePush.rollback();

    expect(File('${tmp.path}/patch.vmcode').existsSync(), isFalse,
        reason: 'patch file must be deleted');
    expect(File('${tmp.path}/patch_info.json').existsSync(), isFalse,
        reason: 'patch metadata must be deleted');

    final marker = File('${tmp.path}/rolled_back_patch');
    expect(marker.existsSync(), isTrue,
        reason: 'a deliberate rollback must quarantine the patch');
    final rb = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
    expect(rb['patch_id'], 'p1');
    expect(rb['patch_hash'], 'h1');
  });

  test('rollback() without patch metadata still deletes, no marker', () async {
    File('${tmp.path}/patch.vmcode').writeAsBytesSync([1, 2, 3, 4]);

    await CodePush.rollback();

    expect(File('${tmp.path}/patch.vmcode').existsSync(), isFalse);
    expect(File('${tmp.path}/rolled_back_patch').existsSync(), isFalse,
        reason: 'no identity to quarantine — marker must not be written');
  });

  test('rollback() on a clean device throws and writes nothing', () async {
    await expectLater(CodePush.rollback(), throwsA(isA<Exception>()));
    expect(File('${tmp.path}/rolled_back_patch').existsSync(), isFalse);
  });
}
