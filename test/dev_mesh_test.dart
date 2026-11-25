import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/mesh/dev/dev_mesh.dart';
import 'package:ripplo/mesh/packet.dart';
import 'package:ripplo/util/bytes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

class Node {
  Node(this.mesh) {
    mesh.on('neighbor', events.add);
    mesh.on('packet', packets.add);
  }

  final DevMesh mesh;
  final events = <Map<String, Object?>>[];
  final packets = <Map<String, Object?>>[];

  Future<void> start() async {
    await mesh.start(random(16));
  }
}

void main() {
  late DevHub hub;
  final open = <DevMesh>[];

  Node node(DevHub h, {bool solo = false, int Function()? now}) {
    final m = DevMesh.memory(h, solo: solo, now: now);
    open.add(m);
    return Node(m);
  }

  setUp(() => hub = DevHub());
  tearDown(() async {
    for (final m in open) {
      await m.close();
    }
    open.clear();
  });

  test('flags', () {
    final m = DevMesh.memory(hub);
    expect(m.isNative, false);
    expect(m.devCrypto, true);
  });

  test('neighbour up on both sides, down on bye', () async {
    final a = node(hub), b = node(hub), c = node(hub);
    await a.start();
    await b.start();
    await c.start();
    await settle();
    expect(
      a.events.where((e) => e['up'] == true).map((e) => e['node']).toSet(),
      {b.mesh.nodeTag, c.mesh.nodeTag},
    );
    expect(a.events.first['medium'], 'lan');
    expect(a.events.first['kbps'], 20000);
    expect((await a.mesh.getNeighbors()).length, 2);
    final n = (await b.mesh.getNeighbors()).first;
    expect(n['rttMs'], 1);
    expect(n['links'], [
      {'medium': 'lan', 'kbps': 20000},
    ]);
    await c.mesh.close();
    await settle();
    expect(a.events.last, {
      'node': c.mesh.nodeTag,
      'up': false,
      'medium': 'lan',
      'kbps': 20000,
    });
    expect((await a.mesh.getNeighbors()).map((e) => e['node']), [
      b.mesh.nodeTag,
    ]);
  });

  test('silent peer dropped by sweep after 5 s', () async {
    var t = 1000;
    final a = node(hub, now: () => t), b = node(hub);
    await a.start();
    await b.start();
    await settle();
    expect((await a.mesh.getNeighbors()).length, 1);
    t += 4000;
    a.mesh.sweep();
    expect((await a.mesh.getNeighbors()).length, 1);
    t += 2000;
    a.mesh.sweep();
    expect(a.events.last['up'], false);
    expect(await a.mesh.getNeighbors(), isEmpty);
  });

  test('sendApp is delivered only to the addressee', () async {
    final a = node(hub), b = node(hub), c = node(hub);
    await a.start();
    await b.start();
    await c.start();
    await settle();
    await a.mesh.sendApp(b.mesh.nodeTag, Uint8List.fromList([1, 2, 3]));
    await settle();
    expect(c.packets, isEmpty);
    expect(b.packets.length, 1);
    expect(b.packets.first['from'], a.mesh.nodeTag);
    final p = decodePacket(b.packets.first['packet'] as Uint8List);
    expect(p.type, PacketType.app);
    expect(p.payload, [1, 2, 3]);
  });

  test(
    'send routes data through the router and delivers at the destination',
    () async {
      final a = node(hub), b = node(hub);
      await a.start();
      final tagB = random(16);
      await b.mesh.start(tagB);
      await settle();
      final pkt = encodePacket(type: PacketType.data, dest: tagB, payload: [9]);
      expect(await a.mesh.send(pkt), 1);
      await settle();
      expect(b.packets.length, 1);
      expect(b.packets.first['from'], a.mesh.nodeTag);
      expect(decodePacket(b.packets.first['packet'] as Uint8List).payload, [9]);
    },
  );

  test('send before start fails', () async {
    final a = node(hub);
    await expectLater(a.mesh.send(Uint8List(0)), throwsA(isA<MeshError>()));
  });

  test('start is idempotent', () async {
    final a = node(hub);
    final t1 = await a.mesh.start(random(16));
    expect(await a.mesh.start(random(16)), t1);
    expect(t1, a.mesh.nodeTag);
    expect(t1.length, 32);
  });

  test('stubs and devConnect semantics', () async {
    final m = DevMesh.memory(hub);
    expect(await m.devConnect('n', 'x'), false);
    await m.devDisconnect('n', 'lan');
    expect(await m.drainInbox(), isEmpty);
    expect(await m.isLocked(), false);
    expect(await m.takeOpen(), isNull);
    expect(await m.selfHash(), isNull);
    expect((await m.getTransports()).single['name'], 'broadcast');
    expect((await m.checkPermissions())['bluetooth'], 'granted');
    expect(await m.authenticate('x'), true);
    expect((await m.backupStatus())['enabled'], false);
    await expectLater(m.backupEnable(), throwsA(isA<MeshError>()));
    await expectLater(m.startRing(), throwsA(isA<MeshError>()));
    final k = await m.getDbKey();
    expect(k.insecure, true);
    expect(k.key.length, 32);
    expect((await m.getDbKey()).key, k.key);
  });

  test('db roundtrip', () async {
    final m = DevMesh.memory(hub);
    await m.dbPut('messages', 'a/1', 'chat', Uint8List.fromList([1]));
    await m.dbPut('messages', 'a/2', 'chat', Uint8List.fromList([2]));
    await m.dbPut('messages', 'b/1', 'other', Uint8List.fromList([3]));
    expect(await m.dbGet('messages', 'a/1'), [1]);
    expect(await m.dbKeys('messages', prefix: 'a'), ['a/1', 'a/2']);
    expect((await m.dbByIdx('messages', 'chat')).length, 2);
    expect((await m.dbAll('messages')).length, 3);
    await m.dbDel('messages', 'a/1');
    expect(await m.dbGet('messages', 'a/1'), isNull);
  });

  test('signal seal and open between two instances', () async {
    final a = DevMesh.memory(hub), b = DevMesh.memory(hub);
    final ia = await a.signalInit(), ib = await b.signalInit();
    final tagB = await a.signalAddContact(ib.bundle);
    final payload = await a.signalSeal(tagB, Uint8List.fromList([7, 8, 9]));
    final opened = await b.signalOpen(payload);
    expect(opened.plaintext, [7, 8, 9]);
    expect(opened.ik, ia.ik);
    expect(await b.signalSeal(opened.tag, Uint8List.fromList([1])), isNotEmpty);
    expect(
      await a.signalSafetyNumber(ib.ik),
      await b.signalSafetyNumber(ia.ik),
    );
    await a.signalForget(tagB);
    await expectLater(
      a.signalSeal(tagB, Uint8List(1)),
      throwsA(isA<MeshError>()),
    );
  });

  test('solo is isolated both ways', () async {
    final a = node(hub), s = node(hub, solo: true), b = node(hub);
    await a.start();
    await s.start();
    await b.start();
    await settle();
    expect(s.events, isEmpty);
    expect(await s.mesh.getNeighbors(), isEmpty);
    expect(a.events.map((e) => e['node']).toSet(), {b.mesh.nodeTag});
    await a.mesh.sendApp(s.mesh.nodeTag, Uint8List(1));
    await s.mesh.sendApp(a.mesh.nodeTag, Uint8List(1));
    await settle();
    expect(s.packets, isEmpty);
    expect(a.packets, isEmpty);
  });

  test('frame codec roundtrip', () {
    final f = DevFrame(
      DevFrameType.pkt,
      'a' * 32,
      'b' * 32,
      Uint8List.fromList([5, 6]),
    );
    final d = DevFrame.decode(f.encode())!;
    expect(d.type, DevFrameType.pkt);
    expect(d.from, 'a' * 32);
    expect(d.to, 'b' * 32);
    expect(d.bytes, [5, 6]);
    final h = DevFrame.decode(DevFrame(DevFrameType.hello, 'c' * 32).encode())!;
    expect(h.to, '');
    expect(DevFrame.decode(Uint8List(3)), isNull);
  });

  test(
    'udp loopback: two profiles find each other and exchange app packets',
    () async {
      final root = await Directory.systemTemp.createTemp('ripplo-dev-test');
      final a = DevMesh(
        profile: 'ta',
        solo: false,
        dir: Directory('${root.path}/a'),
      );
      final b = DevMesh(
        profile: 'tb',
        solo: false,
        dir: Directory('${root.path}/b'),
      );
      addTearDown(() async {
        await a.close();
        await b.close();
        await root.delete(recursive: true);
      });
      final up = Completer<void>();
      final got = Completer<Uint8List>();
      a.on('neighbor', (e) {
        if (e['up'] == true && !up.isCompleted) up.complete();
      });
      b.on('packet', (e) => got.complete(e['packet'] as Uint8List));
      await a.start(random(16));
      await b.start(random(16));
      await up.future.timeout(const Duration(seconds: 5));
      await a.sendApp(b.nodeTag, Uint8List.fromList([4, 2]));
      final p = decodePacket(
        await got.future.timeout(const Duration(seconds: 5)),
      );
      expect(p.payload, [4, 2]);
      await a.dbPut('s', 'k', null, Uint8List.fromList([1]));
      await a.close();
      final a2 = DevMesh(profile: 'ta', dir: Directory('${root.path}/a'));
      addTearDown(a2.close);
      expect(await a2.dbGet('s', 'k'), [1]);
      expect((await a2.signalInit()).bundle, (await a.signalInit()).bundle);
    },
  );
}
