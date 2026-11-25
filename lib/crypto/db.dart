import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../mesh/bridge.dart';
import '../util/bytes.dart';
import 'vault.dart';

abstract interface class RawStore {
  Future<void> put(String store, String key, Uint8List value, {String? idx});
  Future<Uint8List?> get(String store, String key);
  Future<void> del(String store, String key);
  Future<bool> has(String store, String key);
  Future<List<String>> keys(String store, {String? prefix});
  Future<List<(String, Uint8List)>> all(String store);
  Future<List<(String, Uint8List)>> byIdx(String idx);
  Future<void> close();
}

class NativeRawStore implements RawStore {
  NativeRawStore(this._mesh);

  final Mesh _mesh;

  @override
  Future<void> put(String store, String key, Uint8List value, {String? idx}) =>
      _mesh.dbPut(store, key, idx, value);

  @override
  Future<Uint8List?> get(String store, String key) => _mesh.dbGet(store, key);

  @override
  Future<void> del(String store, String key) => _mesh.dbDel(store, key);

  @override
  Future<bool> has(String store, String key) async =>
      await _mesh.dbGet(store, key) != null;

  @override
  Future<List<String>> keys(String store, {String? prefix}) =>
      _mesh.dbKeys(store, prefix: prefix);

  @override
  Future<List<(String, Uint8List)>> all(String store) => _mesh.dbAll(store);

  @override
  Future<List<(String, Uint8List)>> byIdx(String idx) =>
      _mesh.dbByIdx('messages', idx);

  @override
  Future<void> close() async {}
}

class MemoryRawStore implements RawStore {
  final _rows = <String, Map<String, ({Uint8List value, String? idx})>>{};

  Map<String, ({Uint8List value, String? idx})> _s(String store) =>
      _rows.putIfAbsent(store, () => {});

  int get length => _rows.values.fold(0, (n, m) => n + m.length);

  @override
  Future<void> put(
    String store,
    String key,
    Uint8List value, {
    String? idx,
  }) async {
    _s(store)[key] = (value: Uint8List.fromList(value), idx: idx);
    await changed();
  }

  @override
  Future<Uint8List?> get(String store, String key) async {
    final v = _s(store)[key]?.value;
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<void> del(String store, String key) async {
    _s(store).remove(key);
    await changed();
  }

  @override
  Future<bool> has(String store, String key) async =>
      _s(store).containsKey(key);

  @override
  Future<List<String>> keys(String store, {String? prefix}) async {
    final p = prefix == null || prefix.isEmpty ? null : '$prefix/';
    return (_s(store).keys.where((k) => p == null || k.startsWith(p)).toList())
      ..sort();
  }

  @override
  Future<List<(String, Uint8List)>> all(String store) async => [
    for (final k in await keys(store))
      (k, Uint8List.fromList(_s(store)[k]!.value)),
  ];

  @override
  Future<List<(String, Uint8List)>> byIdx(String idx) async => [
    for (final e in _s('messages').entries)
      if (e.value.idx == idx) (e.key, Uint8List.fromList(e.value.value)),
  ];

  @override
  Future<void> close() async {}

  Future<void> changed() async {}
}

class FileRawStore extends MemoryRawStore {
  FileRawStore._(this._file);

  final File _file;
  Future<void> _queue = Future.value();

  static Future<FileRawStore> open(File file) async {
    final s = FileRawStore._(file);
    if (await file.exists()) {
      final j = jsonDecode(await file.readAsString()) as Map;
      for (final se in j.entries) {
        for (final re in (se.value as Map).entries) {
          final r = re.value as Map;
          s._s(se.key as String)[re.key as String] = (
            value: unb64(r['v'] as String),
            idx: r['i'] as String?,
          );
        }
      }
    }
    return s;
  }

  @override
  Future<void> changed() {
    final snap = jsonEncode({
      for (final se in _rows.entries)
        if (se.value.isNotEmpty)
          se.key: {
            for (final re in se.value.entries)
              re.key: {'v': b64(re.value.value), 'i': ?re.value.idx},
          },
    });
    return _queue = _queue.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(snap, flush: true);
      await tmp.rename(_file.path);
    });
  }
}

class Db {
  Db(this._raw, this._vault);

  final RawStore _raw;
  final Vault _vault;

  Uint8List _aad(String store, String key) => utf8('$store/$key');

  Future<void> putBin(
    String store,
    String key,
    Uint8List bytes, {
    String? idx,
  }) async {
    await _raw.put(
      store,
      key,
      await _vault.seal(bytes, _aad(store, key)),
      idx: idx,
    );
  }

  Future<Uint8List?> getBin(String store, String key) async {
    final v = await _raw.get(store, key);
    return v == null ? null : _vault.open(v, _aad(store, key));
  }

  Future<void> put(String store, String key, Object? obj) =>
      putBin(store, key, utf8(jsonEncode(obj)));

  Future<Object?> get(String store, String key) async {
    final b = await getBin(store, key);
    return b == null ? null : jsonDecode(unutf8(b));
  }

  Future<void> del(String store, String key) => _raw.del(store, key);

  Future<bool> has(String store, String key) => _raw.has(store, key);

  Future<bool> hasMsg(String id) => _raw.has('messages', id);

  Future<List<(String, Object?)>> all(String store) async => Future.wait([
    for (final (k, v) in await _raw.all(store))
      _vault.open(v, _aad(store, k)).then((b) => (k, jsonDecode(unutf8(b)))),
  ]);

  Future<List<String>> keysByPrefix(String store, String prefix) =>
      _raw.keys(store, prefix: prefix);

  Future<void> putMsg(Map<String, Object?> m) => putBin(
    'messages',
    m['id'] as String,
    utf8(jsonEncode(m)),
    idx: m['chatId'] as String?,
  );

  Future<List<Map<String, Object?>>> msgs(String chatId) async {
    final list = await Future.wait([
      for (final (id, v) in await _raw.byIdx(chatId))
        _vault
            .open(v, _aad('messages', id))
            .then(
              (b) => Map<String, Object?>.from(jsonDecode(unutf8(b)) as Map),
            ),
    ]);
    num ts(Map<String, Object?> m) => m['ts'] is num ? m['ts'] as num : 0;
    final order = [for (var i = 0; i < list.length; i++) i]
      ..sort((a, b) {
        final c = ts(list[a]).compareTo(ts(list[b]));
        return c != 0 ? c : a.compareTo(b);
      });
    return [for (final i in order) list[i]];
  }

  Future<void> delMsg(String id) => _raw.del('messages', id);

  Future<void> close() => _raw.close();
}

Future<Db> openDb(String name, Vault vault, Mesh mesh, {RawStore? raw}) async =>
    Db(raw ?? NativeRawStore(mesh), vault);
