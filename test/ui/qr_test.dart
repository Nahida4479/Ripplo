import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/ui/qr.dart';

void main() {
  final cases =
      jsonDecode(File('test/support/qr_ref.json').readAsStringSync()) as List;
  for (final c in cases.cast<Map<String, Object?>>()) {
    final text = c['text'] as String;
    test(
      'matches node-qrcode: ${text.length > 24 ? text.substring(0, 24) : text}',
      () {
        final m = qrMatrix(text);
        expect(m.length, c['size']);
        final bits = m.expand((r) => r).map((v) => v ? '1' : '0').join();
        expect(bits, c['bits']);
      },
    );
  }
}
