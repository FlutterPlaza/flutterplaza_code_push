import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutterplaza_code_push/flutterplaza_code_push.dart';

/// [CodePush.debugExtractIosPayload] runs on every launch against
/// whatever bytes are on disk, so every malformed shape must produce a
/// clean `null` — never a throw — and offset arithmetic must be
/// view-correct.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The on-wire payload format marker (first four payload bytes).
  const marker = <int>[0x33, 0x43, 0x42, 0x44];

  /// Builds a container: 16-byte header with the payload offset at
  /// bytes 12-15 (little-endian), then the payload.
  Uint8List buildContainer({
    int payloadOffset = 16,
    List<int> payload = marker,
    int headerLength = 16,
  }) {
    final bytes = Uint8List(headerLength + payload.length);
    ByteData.sublistView(bytes).setUint32(12, payloadOffset, Endian.little);
    bytes.setAll(headerLength, payload);
    return bytes;
  }

  test('valid container extracts the payload', () {
    final payload = CodePush.debugExtractIosPayload(
        buildContainer(payload: [...marker, 1, 2, 3]));
    expect(payload, isNotNull);
    expect(payload!.sublist(0, 4), marker);
    expect(payload.length, 7);
  });

  test('empty input returns null', () {
    expect(CodePush.debugExtractIosPayload(Uint8List(0)), isNull);
  });

  test('input shorter than the offset field returns null', () {
    expect(CodePush.debugExtractIosPayload(Uint8List(15)), isNull);
  });

  test('offset pointing before the header end returns null', () {
    expect(
      CodePush.debugExtractIosPayload(buildContainer(payloadOffset: 8)),
      isNull,
    );
  });

  test('offset at or past the end returns null', () {
    final c = buildContainer();
    expect(
      CodePush.debugExtractIosPayload(buildContainer(payloadOffset: c.length)),
      isNull,
    );
    expect(
      CodePush.debugExtractIosPayload(buildContainer(payloadOffset: 0xFFFFFF)),
      isNull,
    );
  });

  test('payload shorter than the format marker returns null', () {
    expect(
      CodePush.debugExtractIosPayload(
          buildContainer(payload: marker.sublist(0, 2))),
      isNull,
    );
  });

  test('wrong format marker returns null', () {
    expect(
      CodePush.debugExtractIosPayload(
          buildContainer(payload: [0x7F, 0x45, 0x4C, 0x46])),
      isNull,
    );
  });

  test('a sub-view container reads its OWN header, not the buffer root', () {
    // Regression: buffer.asByteData() indexed the underlying buffer
    // from byte 0. Embed a valid container at a non-zero offset inside
    // a larger buffer whose leading bytes are garbage — extraction must
    // behave identically to the zero-offset case.
    final inner = buildContainer(payload: [...marker, 9]);
    final outer = Uint8List(8 + inner.length);
    for (var i = 0; i < 8; i++) {
      outer[i] = 0xEE; // garbage prefix the old code would misread
    }
    outer.setAll(8, inner);
    final view = Uint8List.view(outer.buffer, 8, inner.length);

    final payload = CodePush.debugExtractIosPayload(view);
    expect(payload, isNotNull);
    expect(payload!.sublist(0, 4), marker);
    expect(payload.length, 5);
  });
}
