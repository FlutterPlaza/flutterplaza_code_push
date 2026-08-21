import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

// CodePushPatchBuilder is a StatelessWidget over CodePush.moduleResult
// (a ValueNotifier), so it needs no method channel and no CodePush.init:
// set moduleResult.value, pump, and read what the builder received. These
// tests pin the documented contract — only *string* results pass through;
// a Map/List payload (the common iOS shape) yields the baseline branch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The builder records what patchData it was handed on the last build.
  Object? lastPatchData = #unset;
  Future<void> pump(WidgetTester tester, {String? patchKey}) async {
    lastPatchData = #unset;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CodePushPatchBuilder(
          patchKey: patchKey,
          child: const Text('baseline'),
          builder: (context, patchData, child) {
            lastPatchData = patchData;
            return patchData == null ? child! : Text(patchData);
          },
        ),
      ),
    );
  }

  tearDown(() => CodePush.moduleResult.value = null);

  testWidgets('null result yields the baseline branch', (tester) async {
    CodePush.moduleResult.value = null;
    await pump(tester);
    expect(lastPatchData, isNull);
    expect(find.text('baseline'), findsOneWidget);
  });

  testWidgets('a Map payload yields the baseline branch (not passed through)',
      (tester) async {
    CodePush.moduleResult.value = {'promo': 'Hello'};
    await pump(tester);
    expect(lastPatchData, isNull);
    expect(find.text('baseline'), findsOneWidget);
  });

  testWidgets('an empty string yields the baseline branch', (tester) async {
    CodePush.moduleResult.value = '';
    await pump(tester);
    expect(lastPatchData, isNull);
  });

  testWidgets('patchKey null passes a whole string result through',
      (tester) async {
    CodePush.moduleResult.value = 'Hello World';
    await pump(tester);
    expect(lastPatchData, 'Hello World');
    expect(find.text('Hello World'), findsOneWidget);
  });

  testWidgets('patchKey passes only the text after the colon', (tester) async {
    CodePush.moduleResult.value = 'promo_banner:Hello World';
    await pump(tester, patchKey: 'promo_banner');
    expect(lastPatchData, 'Hello World');
    expect(find.text('Hello World'), findsOneWidget);
  });

  testWidgets('patchKey mismatch yields the baseline branch', (tester) async {
    CodePush.moduleResult.value = 'other:Hello World';
    await pump(tester, patchKey: 'promo_banner');
    expect(lastPatchData, isNull);
    expect(find.text('baseline'), findsOneWidget);
  });

  testWidgets('rebuilds when moduleResult changes', (tester) async {
    CodePush.moduleResult.value = 'first';
    await pump(tester);
    expect(find.text('first'), findsOneWidget);

    CodePush.moduleResult.value = 'second';
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });
}
