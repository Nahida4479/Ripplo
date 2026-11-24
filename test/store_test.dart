import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/crypto/db.dart';
import 'package:ripplo/crypto/vault.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/util/bytes.dart';

Uint8List h(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
    ]);

const codec = JSONMethodCodec();
const channel = MethodChannel('ripplo/mesh', codec);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final key = random(32);
  final mesh = MeshBridge();

  Future<void> exercise(Db db) async {
    await db.put('kv', 'profile', {'name': 'A'});
    await db.putBin('blobs', 'b1', Uint8List.fromList([1, 2, 3]));
    for (var i = 0; i < 450; i++) {
      await db.putBin('chunks', 'x/$i', Uint8List.fromList([i % 256]));
    }
    await db.putBin('chunks', 'xy/1', Uint8List.fromList([9]));
    await db.putMsg({'id': 'm1', 'chatId': 'c1', 'ts': 2, 'text': 'second'});
    await db.putMsg({'id': 'm2', 'chatId': 'c1', 'ts': 1, 'text': 'first'});
    await db.putMsg({'id': 'm3', 'chatId': 'c2', 'ts': 1, 'text': 'other'});
    expect(await db.get('kv', 'profile'), {'name': 'A'});
    expect(await db.get('kv', 'none'), isNull);
    expect(await db.getBin('blobs', 'b1'), Uint8List.fromList([1, 2, 3]));
    expect((await db.msgs('c1')).map((m) => m['text']), ['first', 'second']);
    expect((await db.keysByPrefix('chunks', 'x')).length, 450);
    expect(await db.hasMsg('m3'), isTrue);
    await db.delMsg('m3');
    expect(await db.hasMsg('m3'), isFalse);
    expect(await db.has('kv', 'profile'), isTrue);
    expect((await db.all('kv')).map((r) => r.$1), ['profile']);
    expect((await db.all('kv')).single.$2, {'name': 'A'});
    await db.del('kv', 'profile');
    expect(await db.has('kv', 'profile'), isFalse);
  }

  group('memory store', () {
    test('seals, opens, indexes and sorts messages', () async {
      final raw = MemoryRawStore();
      final db = await openDb('t', Vault(key), mesh, raw: raw);
      await exercise(db);
      await db.close();
    });

    test('rows are sealed and bound to store and key', () async {
      final raw = MemoryRawStore();
      final db = await openDb('t', Vault(key), mesh, raw: raw);
      await db.put('kv', 'a', {'secret': 'plain'});
      final sealed = (await raw.get('kv', 'a'))!;
      expect(utf8Of(sealed).contains('plain'), isFalse);
      await raw.put('kv', 'b', sealed);
      await raw.put('contacts', 'a', sealed);
      await expectLater(db.get('kv', 'b'), throwsA(anything));
      await expectLater(db.get('contacts', 'a'), throwsA(anything));
      await expectLater(openDb('t', Vault(random(32)), mesh, raw: raw).then((d) => d.get('kv', 'a')), throwsA(anything));
    });

    test('equal timestamps keep insertion order', () async {
      final db = await openDb('t', Vault(key), mesh, raw: MemoryRawStore());
      for (final id in ['a', 'b', 'c']) {
        await db.putMsg({'id': id, 'chatId': 'c', 'ts': 5});
      }
      expect((await db.msgs('c')).map((m) => m['id']), ['a', 'b', 'c']);
    });

    test('opens a row sealed by the JS build', () async {
      final raw = MemoryRawStore();
      await raw.put(
        'messages',
        'abc',
        h('5e84db527cf5c076198b1b04cc1956d803003d0dfcc20aebe658c93865f0e3695f8a32c6b6644680a184abfc'),
        idx: 'c',
      );
      final db = await openDb(
        't',
        Vault(h('2d1670408017e2eacfebfe0b7c9f90aa8336871c089373df252ad210ceeb17be')),
        mesh,
        raw: raw,
      );
      expect(await db.getBin('messages', 'abc'), h('465660986fe9df7ed93f0551d9e94e01'));
    });
  });

  group('file store', () {
    test('persists rows across reopen', () async {
      final dir = await Directory.systemTemp.createTemp('ripplo-db');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/db.json');
      final a = await openDb('t', Vault(key), mesh, raw: await FileRawStore.open(f));
      await exercise(a);
      await a.put('kv', 'keep', 1);
      await a.putMsg({'id': 'k1', 'chatId': 'z', 'ts': 1});
      final b = await openDb('t', Vault(key), mesh, raw: await FileRawStore.open(f));
      expect(await b.get('kv', 'keep'), 1);
      expect((await b.msgs('z')).single['id'], 'k1');
      expect(await b.hasMsg('k1'), isTrue);
    });
  });

  group('native store', () {
    final calls = <MethodCall>[];
    final rows = <String, ({String store, String key, String? idx, String value})>{};

    setUp(() {
      calls.clear();
      rows.clear();
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c);
        final a = c.arguments as Map;
        final k = '${a['store']}\u0000${a['key']}';
        switch (c.method) {
          case 'dbPut':
            rows[k] = (store: a['store'], key: a['key'], idx: a['idx'], value: a['value']);
            return null;
          case 'dbGet':
            return {'value': rows[k]?.value};
          case 'dbDel':
            rows.remove(k);
            return null;
          case 'dbKeys':
            final p = a['prefix'] as String?;
            return {
              'keys': [
                for (final r in rows.values)
                  if (r.store == a['store'] && (p == null || r.key.startsWith('$p/'))) r.key,
              ],
            };
          case 'dbAll':
            return {
              'rows': [
                for (final r in rows.values)
                  if (r.store == a['store']) {'key': r.key, 'value': r.value},
              ],
            };
          case 'dbByIdx':
            return {
              'rows': [
                for (final r in rows.values)
                  if (r.store == a['store'] && r.idx == a['idx']) {'key': r.key, 'value': r.value},
              ],
            };
        }
        throw MissingPluginException();
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('delegates every operation to the native channel', () async {
      final db = await openDb('t', Vault(key), mesh);
      await exercise(db);
    });

    test('sends exact params and sealed base64 values', () async {
      final db = await openDb('t', Vault(key), mesh);
      await db.putMsg({'id': 'm1', 'chatId': 'c1', 'ts': 1});
      await db.put('kv', 'k', 7);
      final msg = calls.firstWhere((c) => c.method == 'dbPut' && (c.arguments as Map)['store'] == 'messages');
      final m = msg.arguments as Map;
      expect(m.keys.toSet(), {'store', 'key', 'idx', 'value'});
      expect(m['key'], 'm1');
      expect(m['idx'], 'c1');
      final sealed = unb64(m['value'] as String);
      expect(
        jsonDecode(unutf8(await Vault(key).open(sealed, utf8('messages/m1')))),
        {'id': 'm1', 'chatId': 'c1', 'ts': 1},
      );
      final kv = calls.firstWhere((c) => c.method == 'dbPut' && (c.arguments as Map)['store'] == 'kv').arguments as Map;
      expect(kv.containsKey('idx'), isFalse);
      calls.clear();
      await db.keysByPrefix('chunks', 'x');
      expect(calls.single.method, 'dbKeys');
      expect(calls.single.arguments, {'store': 'chunks', 'prefix': 'x'});
      calls.clear();
      await db.msgs('c1');
      expect(calls.single.method, 'dbByIdx');
      expect(calls.single.arguments, {'store': 'messages', 'idx': 'c1'});
      calls.clear();
      expect(await db.hasMsg('nope'), isFalse);
      expect(calls.single.method, 'dbGet');
      expect(calls.single.arguments, {'store': 'messages', 'key': 'nope'});
    });
  });
}

String utf8Of(Uint8List b) => latin1.decode(b);
