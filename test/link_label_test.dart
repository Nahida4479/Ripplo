import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/util/link_label.dart';

void main() {
  test('isCodedLink vectors', () {
    final v =
        jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
            as Map;
    for (final c in v['linkLabel'] as List) {
      expect(
        isCodedLink(c['undef'] == true ? null : c['in']),
        c['out'],
        reason: jsonEncode(c),
      );
    }
  });
}
