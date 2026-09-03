import 'dart:convert' show LineSplitter;
import 'dart:io' show Directory, File;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// Widget coverage for [CodePushOverlay] (issue #29) and the
/// [CodePush.statusPatchActive] contract (issue #31).
///
/// The overlay drives the live update cycle from `initState`, so every test
/// here installs [CodePushOverlay.debugUpdateCycleOverride] first: it captures
/// the `onUpdateReady` callback the overlay hands out and leaves the real
/// client (server checks, patch-directory file I/O, the process-global
/// `CodePush.dispose`) untouched.
void main() {
  const config = CodePushConfig(
    appId: 'overlay-test-app',
    releaseVersion: '1.0.0+1',
  );

  /// Fires the overlay's own update-ready handler, as an install would.
  late VoidCallback signalUpdateReady;
  late List<CodePushConfig> cycleConfigs;

  setUp(() {
    cycleConfigs = <CodePushConfig>[];
    signalUpdateReady = () {};
    CodePushOverlay.debugUpdateCycleOverride = (cfg, onUpdateReady) {
      cycleConfigs.add(cfg);
      signalUpdateReady = onUpdateReady;
    };
  });

  tearDown(() {
    // Statics: a leak here would disable the update cycle — or pin a stale
    // status — for every later test in this process.
    CodePushOverlay.debugUpdateCycleOverride = null;
    CodePush.lastConfig = null;
    CodePush.status.value = 'init';
  });

  /// The overlay reads `MediaQuery` for the banner inset and is meant to sit
  /// ABOVE the app, so the test provides the ancestor the app would.
  Future<void> pumpOverlay(
    WidgetTester tester, {
    CodePushConfig? config,
    Widget Function(BuildContext, VoidCallback, VoidCallback)? bannerBuilder,
    bool showDebugBar = false,
  }) =>
      tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: CodePushOverlay(
            config: config,
            bannerBuilder: bannerBuilder,
            showDebugBar: showDebugBar,
            child: const Text('app'),
          ),
        ),
      );

  group('bannerBuilder contract', () {
    testWidgets('no banner slot before an update is ready', (tester) async {
      await pumpOverlay(
        tester,
        config: config,
        bannerBuilder: (_, __, ___) => const Text('custom banner'),
      );

      expect(find.text('app'), findsOneWidget);
      expect(find.text('custom banner'), findsNothing);
    });

    testWidgets('the builder\'s widget is what renders when ready',
        (tester) async {
      await pumpOverlay(
        tester,
        config: config,
        bannerBuilder: (_, __, ___) => const Text('custom banner'),
      );

      signalUpdateReady();
      await tester.pump();

      expect(find.text('custom banner'), findsOneWidget);
      // The custom builder REPLACES the default banner, never adds to it.
      expect(find.text('Update ready. Restart to apply.'), findsNothing);
      expect(find.text('RESTART'), findsNothing);
    });

    testWidgets('the handed onDismiss removes the banner', (tester) async {
      await pumpOverlay(
        tester,
        config: config,
        bannerBuilder: (_, __, onDismiss) => TextButton(
          onPressed: onDismiss,
          child: const Text('dismiss me'),
        ),
      );

      signalUpdateReady();
      await tester.pump();
      expect(find.text('dismiss me'), findsOneWidget);

      await tester.tap(find.text('dismiss me'));
      await tester.pump();

      expect(find.text('dismiss me'), findsNothing);
      // The app itself is untouched by the dismissal.
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('a dismissed banner comes back for the next update',
        (tester) async {
      await pumpOverlay(
        tester,
        config: config,
        bannerBuilder: (_, __, onDismiss) => TextButton(
          onPressed: onDismiss,
          child: const Text('dismiss me'),
        ),
      );

      signalUpdateReady();
      await tester.pump();
      await tester.tap(find.text('dismiss me'));
      await tester.pump();
      expect(find.text('dismiss me'), findsNothing);

      signalUpdateReady();
      await tester.pump();
      expect(find.text('dismiss me'), findsOneWidget);
    });

    testWidgets(
        'SizedBox.shrink() from the builder renders nothing '
        'hit-testable', (tester) async {
      const bannerKey = Key('shrunk-banner');
      await pumpOverlay(
        tester,
        config: config,
        bannerBuilder: (_, __, ___) => const SizedBox.shrink(key: bannerKey),
      );

      signalUpdateReady();
      await tester.pump();

      // The documented "show no banner" recipe: the slot is occupied, but it
      // covers nothing and swallows no taps meant for the app underneath.
      // The banner slot is a left/right-anchored Positioned, so the returned
      // box is stretched to the overlay's width — zero HEIGHT is what makes
      // it invisible and untappable, not a zero-by-zero size.
      expect(find.byKey(bannerKey), findsOneWidget);
      expect(find.byKey(bannerKey).hitTestable(), findsNothing);
      expect(tester.getSize(find.byKey(bannerKey)).height, 0);
    });

    testWidgets('without a builder the default banner renders and dismisses',
        (tester) async {
      await pumpOverlay(tester, config: config);

      signalUpdateReady();
      await tester.pump();
      expect(find.text('Update ready. Restart to apply.'), findsOneWidget);
      expect(find.text('RESTART'), findsOneWidget);

      await tester.tap(find.text('LATER'));
      await tester.pump();

      expect(find.text('Update ready. Restart to apply.'), findsNothing);
    });
  });

  group('config resolution', () {
    testWidgets('falls back to CodePush.lastConfig when config is omitted',
        (tester) async {
      CodePush.lastConfig = config;

      await pumpOverlay(tester);

      expect(cycleConfigs.single.appId, 'overlay-test-app');
    });

    testWidgets('an explicit config wins over CodePush.lastConfig',
        (tester) async {
      CodePush.lastConfig = const CodePushConfig(
        appId: 'stored',
        releaseVersion: '1.0.0+1',
      );

      await pumpOverlay(tester, config: config);

      expect(cycleConfigs.single.appId, 'overlay-test-app');
    });

    testWidgets('no config and no prior init throws an actionable StateError',
        (tester) async {
      CodePush.lastConfig = null;

      await pumpOverlay(tester);

      final error = tester.takeException();
      expect(error, isA<StateError>());
      expect((error as StateError).message, contains('no config provided'));
      expect(cycleConfigs, isEmpty);
    });
  });

  group('debug bar and the patch-active latch', () {
    testWidgets('shows the live status only while showDebugBar is on',
        (tester) async {
      CodePush.status.value = 'Checking server...';

      await pumpOverlay(tester, config: config, showDebugBar: true);
      expect(find.text('CP: Checking server...'), findsOneWidget);

      CodePush.status.value = 'No update (204)';
      await tester.pump();
      expect(find.text('CP: No update (204)'), findsOneWidget);
    });

    testWidgets('hidden by default', (tester) async {
      CodePush.status.value = 'Checking server...';

      await pumpOverlay(tester, config: config);

      expect(find.textContaining('CP: '), findsNothing);
    });

    testWidgets('the statusPatchActive edge latches and retires the debug bar',
        (tester) async {
      CodePush.status.value = 'Downloading patch...';
      await pumpOverlay(tester, config: config, showDebugBar: true);
      expect(find.text('CP: Downloading patch...'), findsOneWidget);

      // The latch reads the same constant every writer writes (issue #31);
      // a literal copy on either side would silently stop matching.
      CodePush.status.value = CodePush.statusPatchActive;
      await tester.pump();

      expect(find.textContaining('CP: '), findsNothing);
      expect(find.text('app'), findsOneWidget);

      // Latched, not tracking: the edge never returns, so a later status
      // must not bring the bar back.
      CodePush.status.value = 'Patch already installed';
      await tester.pump();
      expect(find.textContaining('CP: '), findsNothing);
    });
  });

  group('CodePush.statusPatchActive', () {
    test('keeps the app-facing wire value', () {
      // Apps and the debug console latch this exact text; the constant
      // exists so it can only change deliberately.
      expect(CodePush.statusPatchActive, 'Patch active');
    });

    test('is the only place the literal appears in the library source', () {
      // The point of the constant is that a future status-text edit moves
      // every writer and the overlay's latch together. Prose in doc comments
      // is free to name the text; executable code is not. Scans EVERY
      // library source file, and strips trailing comments so a
      // `// ... 'Patch active'` remark cannot false-positive.
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        for (final raw in LineSplitter.split(entity.readAsStringSync())) {
          var line = raw.trim();
          if (line.startsWith('//')) continue;
          final comment = line.indexOf('//');
          if (comment >= 0) line = line.substring(0, comment);
          if (!line.contains("'Patch active'")) continue;
          if (line.contains('statusPatchActive =')) continue;
          offenders.add('${entity.path}: $line');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'use CodePush.statusPatchActive instead of the literal',
      );
    });
  });

  group('restart-pending episodes (PR #36 rounds 6-10)', () {
    setUp(() {
      CodePush.debugSetInstallPendingRestart(false);
    });
    tearDown(() {
      CodePush.debugSetInstallPendingRestart(false);
    });

    testWidgets(
        'an install during the overlay\'s life shows the banner '
        'whatever the status reads', (tester) async {
      await pumpOverlay(tester, config: config);
      expect(find.text('Update ready. Restart to apply.'), findsNothing);

      CodePush.debugSetInstallPendingRestart(true);
      CodePush.debugBumpInstallSeq();
      // The busy status channel has already moved past the level —
      // production truth: every check overwrites it.
      CodePush.status.value = 'Patch already installed';
      await tester.pump();

      expect(find.text('Update ready. Restart to apply.'), findsOneWidget);
    });

    testWidgets(
        'an overlay mounting AFTER the install shows the banner '
        'even while the status reads a transient', (tester) async {
      CodePush.debugSetInstallPendingRestart(true);
      CodePush.debugBumpInstallSeq();
      CodePush.status.value = 'No update (204)';

      await pumpOverlay(tester, config: config);
      await tester.pump();

      expect(find.text('Update ready. Restart to apply.'), findsOneWidget,
          reason: 'the anchor is the SDK pending state, not the status '
              'string of the moment');
    });

    testWidgets(
        'a dismissal stands for its episode across BOTH delivery '
        'paths and every status churn; a LATER install re-offers',
        (tester) async {
      await pumpOverlay(tester, config: config);
      CodePush.debugSetInstallPendingRestart(true);
      CodePush.debugBumpInstallSeq();
      CodePush.status.value = CodePush.statusRestartToApply;
      await tester.pump();
      await tester.tap(find.text('LATER'));
      await tester.pump();
      expect(find.text('Update ready. Restart to apply.'), findsNothing);

      // Production re-announce sequence: the status is overwritten
      // FIRST, then the callback fires (round 10's exact ordering).
      CodePush.status.value = 'Patch already installed';
      await tester.pump();
      signalUpdateReady();
      await tester.pump();
      expect(find.text('Update ready. Restart to apply.'), findsNothing,
          reason: 'the dismissed episode stays dismissed through the '
              'callback path with the status off the level');

      // More notifier churn cannot resurrect it either.
      CodePush.moduleResult.value = Object();
      await tester.pump();
      expect(find.text('Update ready. Restart to apply.'), findsNothing);
      CodePush.moduleResult.value = null;

      // A LATER install is a NEW episode: re-offer.
      CodePush.debugBumpInstallSeq();
      CodePush.status.value = CodePush.statusRestartToApply;
      await tester.pump();
      expect(find.text('Update ready. Restart to apply.'), findsOneWidget);
    });
  });
}
