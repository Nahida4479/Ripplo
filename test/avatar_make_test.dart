import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ripplo/util/avatar.dart';
import 'package:ripplo/util/bytes.dart';

void main() {
  test('makeAvatar crops to a 160px jpeg within the size limit', () async {
    final src = img.Image(width: 300, height: 200);
    img.fill(src, color: img.ColorRgb8(200, 40, 90));
    final s = await makeAvatar(Uint8List.fromList(img.encodePng(src)));
    expect(isAvatar(s), isTrue);
    final out = img.decodeJpg(unb64(s))!;
    expect(out.width, 160);
    expect(out.height, 160);
  });

  test('makeAvatar rejects non-images', () async {
    await expectLater(
      makeAvatar(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<StateError>()),
    );
  });
}
