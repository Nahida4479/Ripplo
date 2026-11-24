import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

typedef Touch = void Function();

Object? obs(Touch touch, Object? v) {
  if (v is ObsMap || v is ObsList || v is TypedData) return v;
  if (v is Map) return ObsMap(touch, v);
  if (v is List) return ObsList<Object?>(touch, v);
  return v;
}

class ObsMap extends MapBase<String, Object?> {
  ObsMap(this._touch, [Map<Object?, Object?>? src]) {
    if (src != null) {
      for (final e in src.entries) {
        _m['${e.key}'] = obs(_touch, e.value);
      }
    }
  }

  final Touch _touch;
  final _m = <String, Object?>{};

  @override
  Object? operator [](Object? key) => _m[key];

  @override
  void operator []=(String key, Object? value) {
    final v = obs(_touch, value);
    if (_m.containsKey(key) && _m[key] == v) return;
    _m[key] = v;
    _touch();
  }

  void put(String key, Object? value) =>
      value == null ? remove(key) : this[key] = value;

  @override
  Object? remove(Object? key) {
    if (!_m.containsKey(key)) return null;
    final v = _m.remove(key);
    _touch();
    return v;
  }

  @override
  void clear() {
    if (_m.isEmpty) return;
    _m.clear();
    _touch();
  }

  @override
  Iterable<String> get keys => _m.keys;

  @override
  int get length => _m.length;

  @override
  bool containsKey(Object? key) => _m.containsKey(key);
}

class ObsList<T> extends ListBase<T> {
  ObsList(this._touch, [Iterable<Object?>? src]) {
    if (src != null) _l.addAll(src.map(_w));
  }

  final Touch _touch;
  final _l = <T>[];

  T _w(Object? e) => obs(_touch, e) as T;

  @override
  int get length => _l.length;

  @override
  set length(int n) {
    if (n == _l.length) return;
    _l.length = n;
    _touch();
  }

  @override
  T operator [](int i) => _l[i];

  @override
  void operator []=(int i, T v) {
    final w = _w(v);
    if (_l[i] == w) return;
    _l[i] = w;
    _touch();
  }

  @override
  void add(T element) {
    _l.add(_w(element));
    _touch();
  }

  @override
  void addAll(Iterable<T> iterable) {
    final n = _l.length;
    _l.addAll(iterable.map(_w));
    if (_l.length != n) _touch();
  }

  @override
  void insert(int index, T element) {
    _l.insert(index, _w(element));
    _touch();
  }

  @override
  void insertAll(int index, Iterable<T> iterable) {
    final n = _l.length;
    _l.insertAll(index, iterable.map(_w));
    if (_l.length != n) _touch();
  }

  @override
  void setRange(int start, int end, Iterable<T> iterable, [int skipCount = 0]) {
    _l.setRange(start, end, iterable.skip(skipCount).map(_w));
    if (end > start) _touch();
  }

  @override
  bool remove(Object? element) {
    final ok = _l.remove(element);
    if (ok) _touch();
    return ok;
  }

  @override
  T removeAt(int index) {
    final v = _l.removeAt(index);
    _touch();
    return v;
  }

  @override
  T removeLast() {
    final v = _l.removeLast();
    _touch();
    return v;
  }

  @override
  void removeRange(int start, int end) {
    _l.removeRange(start, end);
    if (end > start) _touch();
  }

  @override
  void removeWhere(bool Function(T element) test) {
    final n = _l.length;
    _l.removeWhere(test);
    if (_l.length != n) _touch();
  }

  @override
  void retainWhere(bool Function(T element) test) {
    final n = _l.length;
    _l.retainWhere(test);
    if (_l.length != n) _touch();
  }

  @override
  void clear() {
    if (_l.isEmpty) return;
    _l.clear();
    _touch();
  }

  @override
  void sort([int Function(T a, T b)? compare]) {
    final cmp =
        compare ??
        (T a, T b) => Comparable.compare(a as Comparable, b as Comparable);
    final idx = List.generate(_l.length, (i) => i)
      ..sort((a, b) {
        final c = cmp(_l[a], _l[b]);
        return c != 0 ? c : a - b;
      });
    final sorted = [for (final i in idx) _l[i]];
    _l.setAll(0, sorted);
    _touch();
  }

  @override
  void shuffle([Random? random]) {
    _l.shuffle(random);
    _touch();
  }
}
