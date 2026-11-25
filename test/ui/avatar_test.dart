import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/util/avatar_image_processing.dart';

void main() {
  final a =
      (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
              as Map<String, dynamic>)['avatar']
          as Map<String, dynamic>;

  test('maxAvatar', () => expect(maxAvatar, a['maxAvatar']));

  group('isAvatar', () {
    for (final v in (a['isAvatar'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'] as String, () => expect(isAvatar(v['in']), v['out']));
    }
  });

  group('hue', () {
    for (final v in (a['hue'] as List).cast<Map<String, dynamic>>()) {
      test('${v['name']}', () {
        expect(avatarHue(v['name'] as String?), v['hue']);
      });
    }
  });

  group('initials', () {
    for (final v in (a['initials'] as List).cast<Map<String, dynamic>>()) {
      test('${v['name']}', () {
        expect(avatarInitials(v['name'] as String?), v['out']);
      });
    }
  });

  group('settingsInitials', () {
    for (final v
        in (a['settingsInitials'] as List).cast<Map<String, dynamic>>()) {
      test(
        '${v['in']}',
        () => expect(settingsInitials(v['in'] as String), v['out']),
      );
    }
  });
}
