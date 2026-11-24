import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/util/bytes.dart';
import 'package:ripplo/util/js.dart';

void main() {
  final v =
      (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
              as Map)['bytes']
          as Map;

  test('base32 vectors', () {
    for (final c in v['base32'] as List) {
      expect(base32(unhex(c['in'] as String)), c['out'], reason: '${c['in']}');
    }
  });

  test('base64 and base64url vectors', () {
    for (final c in v['b64'] as List) {
      final bytes = unhex(c['in'] as String);
      expect(b64(bytes), c['b64']);
      expect(b64url(bytes), c['b64url']);
      expect(hex(unb64url(c['b64url'] as String)), c['back']);
      expect(hex(unb64(c['b64'] as String)), c['back64']);
    }
  });

  test('unb64url rejects bad input exactly where JS does', () {
    for (final c in v['unb64urlBad'] as List) {
      final out = c['out'];
      if (out is Map) {
        expect(
          () => unb64url(c['in'] as String),
          throwsFormatException,
          reason: '${c['in']}',
        );
        if (out['error'] == 'bad base64url') {
          expect(
            () => unb64url(c['in'] as String),
            throwsA(predicate((e) => e.toString().contains('bad base64url'))),
          );
        }
      } else {
        expect(hex(unb64url(c['in'] as String)), out);
      }
    }
  });

  test('u32 and readU32 vectors', () {
    for (final c in v['u32'] as List) {
      final n = c['in'] as int;
      expect(hex(u32(n)), c['out']);
      expect(readU32(u32(n), 0), c['back']);
    }
    for (final c in v['readU32'] as List) {
      expect(readU32(unhex(c['in'] as String), 0), c['out']);
    }
    final o = v['readU32Offset'] as Map;
    expect(readU32(unhex(o['in'] as String), o['off'] as int), o['out']);
  });

  test('equal, concat, utf8 vectors', () {
    for (final c in v['equal'] as List) {
      expect(equal(unhex(c['a'] as String), unhex(c['b'] as String)), c['out']);
    }
    final c = v['concat'] as Map;
    expect(
      hex(concat((c['parts'] as List).map((p) => unhex(p as String)))),
      c['out'],
    );
    for (final u in v['utf8'] as List) {
      expect(hex(utf8(u['in'] as String)), u['out']);
      expect(unutf8(unhex(u['out'] as String)), u['back']);
    }
  });

  test('hex, ab and random behave like the JS helpers', () {
    expect(() => unhex('abc'), throwsFormatException);
    expect(() => unhex('zz'), throwsFormatException);
    expect(unhex('00FfA0'), [0, 255, 160]);
    expect(random(100000).length, 100000);
    final src = Uint8List.sublistView(Uint8List.fromList([9, 1, 2, 3]), 1, 3);
    expect(Uint8List.view(ab(src)), [1, 2]);
    expect(unutf8(Uint8List.fromList([0xef, 0xbb, 0xbf, 0x61])), 'a');
    expect(unutf8(Uint8List.fromList([0x61, 0xff])), 'a�');
  });

  test('js helpers', () {
    expect(
      [null, false, 0, 0.0, '', double.nan].map(truthy),
      everyElement(false),
    );
    expect(
      [true, 1, -1, 'a', '0', <int>[], <String, int>{}].map(truthy),
      everyElement(true),
    );
    expect(cut('abcdef', 1, 3), 'bc');
    expect(cut('abcdef', -2), 'ef');
    expect(cut('abcdef', 2, -1), 'cde');
    expect(cut('abcdef', 4, 2), '');
    expect(cut('abc', 0, 99), 'abc');
    expect(cut('abc', -99, 2), 'ab');
    expect(isInt(5), true);
    expect(isInt(5.0), true);
    expect(isInt(5.5), false);
    expect(isInt(double.nan), false);
    expect(isInt(double.infinity), false);
    expect(isInt('5'), false);
    expect(toInt32(double.nan), 0);
    expect(toInt32(double.infinity), 0);
    expect(toInt32(2147483648), -2147483648);
    expect(toInt32(4294967297), 1);
    expect(toInt32(-1.9), -1);
    expect(toInt32(null), 0);
    expect(toUint32(-1), 4294967295);
    expect(isFiniteNum(1.5), true);
    expect(isFiniteNum(double.infinity), false);
    expect(isFiniteNum('1'), false);
  });

  test('regressions: BOM, non-canonical base64 tail bits, huge toInt32', () {
    expect(unutf8(unhex('efbbbfefbbbf61')), '\ufeffa');
    expect(unutf8(unhex('61efbbbf')), 'a\ufeff');
    expect(hex(unb64('AB')), '00');
    expect(hex(unb64(' AB ')), '00');
    expect(hex(unb64('QUJ=')), '4142');
    expect(hex(unb64('AB=\n=')), '00');
    expect(() => unb64('QUJ=='), throwsFormatException);
    expect(hex(unb64url('AB')), '00');
    expect(hex(unb64url('__8')), 'ffff');
    expect(toInt32(1e20), 1661992960);
    expect(toInt32(-1e20), -1661992960);
    expect(toInt32(1e300), 0);
    expect(toInt32(-9223372036854775808.0), 0);
  });

  test('fire swallows errors', () async {
    fire(Future<void>.error(StateError('x')));
    fire(Future.value(1));
    await Future<void>.delayed(Duration.zero);
  });
}
