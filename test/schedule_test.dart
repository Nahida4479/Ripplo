import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/util/js.dart' as js;
import 'package:ripplo/util/schedule.dart';

void main() {
  final v =
      (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
              as Map)['schedule']
          as Map;
  final warsaw =
      DateTime.fromMillisecondsSinceEpoch(1768438740000).timeZoneOffset ==
          const Duration(hours: 1) &&
      DateTime.fromMillisecondsSinceEpoch(1782900000000).timeZoneOffset ==
          const Duration(hours: 2);
  final skip = warsaw ? null : 'vectors need TZ=Europe/Warsaw';

  test('constants', () {
    final c = v['constants'] as Map;
    expect(slotMs, c['SLOT_MS']);
    expect(windowMs, c['WINDOW_MS']);
    expect(staleMs, c['STALE_MS']);
  });

  test('slotOf vectors', () {
    for (final c in v['slotOf'] as List) {
      expect(slotOf(c['tag']), c['out'], reason: '${c['tag']}');
    }
  });

  test('slotOf is NaN-like for non hex tags', () {
    expect(slotOf('zzzzzzzz'), isNull);
    expect(slotOf(''), isNull);
    expect(slotOf('12zz'), 0x12 % 720);
    expect(isDue('zzzzzzzz', 0, 1768438800000), false);
  });

  test('windowStart vectors', () {
    for (final c in v['windowStart'] as List) {
      expect(windowStart(c['now'] as int), c['out'], reason: '${c['now']}');
    }
  }, skip: skip);

  test('isDue vectors', () {
    for (final c in [...(v['isDue'] as List), ...(v['isDueEdge'] as List)]) {
      expect(
        isDue(c['tag'], c['last'] as int, c['now'] as int),
        c['out'],
        reason: '${c['tag']} ${c['now']} ${c['last']}',
      );
    }
  }, skip: skip);

  test('isDue defaults to the injectable clock', () {
    final saved = js.now;
    addTearDown(() => js.now = saved);
    js.now = () => 1768438800000;
    expect(isDue('00000000', 0), true);
    js.now = () => 1768438799999;
    expect(isDue('00000000', 0), false);
  }, skip: skip);
}
