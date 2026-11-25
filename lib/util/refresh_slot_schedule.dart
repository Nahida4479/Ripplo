import 'js_compat.dart' as js;

const slotMs = 15000;
const windowMs = 3 * 3600 * 1000;
const staleMs = 20 * 3600 * 1000;
const _slots = windowMs ~/ slotMs;

int? _parseHex(String s) {
  final m = RegExp(
    r'^[\t\n\v\f\r    ﻿]*([+-]?)(?:0[xX])?([0-9a-fA-F]+)',
  ).firstMatch(s);
  if (m == null) return null;
  final v = int.parse(m.group(2)!, radix: 16);
  return m.group(1) == '-' ? -v : v;
}

int? slotOf(Object? tag) {
  final n = _parseHex(js.cut('$tag', 0, 8));
  return n == null ? null : n % _slots;
}

int windowStart(int at) {
  final d = DateTime.fromMillisecondsSinceEpoch(at);
  return DateTime(d.year, d.month, d.day, 2).millisecondsSinceEpoch;
}

bool isDue(Object? tag, num last, [int? at]) {
  final t = at ?? js.now();
  final slot = slotOf(tag);
  if (slot == null) return false;
  final start = windowStart(t);
  return t >= start + slot * slotMs &&
      t < start + windowMs &&
      t - last > staleMs;
}
