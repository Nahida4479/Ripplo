import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:ripplo/util/qr_multipart_codec.dart';

const _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
final link =
    'ripplo://add/${List.generate(2400, (i) => _alphabet[(i * 7 + (i >> 3)) % 64]).join()}.abcdefgh.ABCDEFGHIJK';

void main() {
  final v =
      (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
              as Map)['qrparts']
          as Map;

  test(
    'splits a large link into small frames that each fit a modest QR version',
    () {
      final parts = splitLink(link);
      expect(parts.length, greaterThan(3));
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(partSize + 40));
        expect(
          QrCode(
            payload: QrPayload.fromString(p),
            errorCorrectLevel: QrErrorCorrectLevel.low,
          ).typeNumber,
          lessThanOrEqualTo(14),
        );
      }
    },
  );

  test('assembles frames in any order, with repeats and unrelated noise', () {
    final parts = splitLink(link);
    final a = createAssembler();
    expect(a.add('hello'), isNull);
    expect(a.add('ripplo://add/xyz.abcdefgh'), isNull);
    final order = List.generate(parts.length, (i) => i)..shuffle(Random());
    Map<String, Object?>? last;
    for (final i in order) {
      last = a.add(parts[i]);
      a.add(parts[i]);
      if (i != order.last) expect(last!['have'] as int, lessThan(parts.length));
    }
    expect(last!['link'], link);
  });

  test('rejects a set whose checksum does not match and malformed frames', () {
    final parts = splitLink(link);
    final a = createAssembler();
    final tampered = [
      for (var i = 0; i < parts.length; i++)
        i == 1
            ? parts[i].substring(0, parts[i].length - 1) +
                  (parts[i].endsWith('A') ? 'B' : 'A')
            : parts[i],
    ];
    Map<String, Object?>? r;
    for (final p in tampered) {
      r = a.add(p);
    }
    expect(r!['bad'], true);
    expect(
      createAssembler().add('ripplo://p/abcdefgh.9.3.xx')!['ignored'],
      true,
    );
    expect(
      createAssembler().add('ripplo://p/abcdefgh.1.99.xx')!['ignored'],
      true,
    );
    expect(
      createAssembler().add(
        'ripplo://p/abcdefgh.1.2.${'x' * (partSize + 1)}',
      )!['ignored'],
      true,
    );
  });

  test('keeps two codes shown one after another apart', () {
    final other = link.replaceFirst('add/A', 'add/B');
    final a = createAssembler();
    final p1 = splitLink(link), p2 = splitLink(other);
    a.add(p1[0]);
    a.add(p2[0]);
    for (var i = 1; i < p1.length - 1; i++) {
      a.add(p1[i]);
    }
    for (var i = 1; i < p2.length; i++) {
      a.add(p2[i]);
    }
    expect(a.add(p1.last)!['link'], link);
  });

  test('splitLink vectors', () {
    expect(partSize, v['partSize']);
    for (final c in v['splitLink'] as List) {
      expect(splitLink(c['link'] as String), c['parts']);
    }
  });

  test('assembler vectors', () {
    for (final c in v['assemble'] as List) {
      final a = createAssembler();
      final got = [for (final p in c['parts'] as List) a.add(p)];
      expect(got, c['out'], reason: '${c['name']}');
    }
  });
}
