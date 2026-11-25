import 'dart:async';

int Function() now = () => DateTime.now().millisecondsSinceEpoch;

bool truthy(Object? v) {
  if (v == null || v == false || v == '') return false;
  if (v is num) return !(v == 0 || v.isNaN);
  return true;
}

String cut(String s, int start, [int? end]) {
  final n = s.length;
  int norm(int i) => i < 0 ? (n + i < 0 ? 0 : n + i) : (i > n ? n : i);
  final a = norm(start);
  final b = end == null ? n : norm(end);
  return a >= b ? '' : s.substring(a, b);
}

bool isInt(Object? v) {
  if (v is int) return true;
  return v is double && v.isFinite && v == v.truncateToDouble();
}

bool isFiniteNum(Object? v) => v is num && v.isFinite;

int toInt32(Object? v) {
  if (v is! num || v.isNaN || v.isInfinite) return 0;
  final n = v is int
      ? v & 0xffffffff
      : (v.truncateToDouble() % 4294967296.0).toInt();
  return n >= 0x80000000 ? n - 0x100000000 : n;
}

int toUint32(Object? v) => toInt32(v) & 0xffffffff;

void fire(Future<Object?> f) {
  f.then<void>((_) {}, onError: (Object _, StackTrace _) {});
}
