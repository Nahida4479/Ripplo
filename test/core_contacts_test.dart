import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/messenger_core.dart';
import 'package:ripplo/core/observable_collections.dart';
import 'package:ripplo/core/app_state.dart';
import 'package:ripplo/data/app_database.dart';
import 'package:ripplo/crypto/contact_card_codec.dart';
import 'package:ripplo/mesh/native_mesh_bridge.dart';
import 'package:ripplo/mesh/dev/desktop_plaintext_signal.dart';
import 'package:ripplo/mesh/mesh_packet.dart';
import 'package:ripplo/util/byte_encoding.dart';

final nodes = <FakeMesh>[];

class FakeMesh implements Mesh {
  FakeMesh() {
    nodes.add(this);
  }

  final sig = DevSignal();
  final node = hex(random(8));
  String tag = '';
  final neighbors = <String>{};
  final origin = <String, FakeMesh>{};
  final handlers = <String, List<void Function(Map<String, Object?>)>>{};
  bool offline = false;
  int hopsToOrigin = 1;
  List<InboxItem> inbox = [];
  Future<Uint8List> Function(String tag, Uint8List pt, Future<Uint8List> Function(String, Uint8List) orig)? sealHook;
  Future<int> Function(Uint8List pkt, Future<int> Function(Uint8List) orig)? sendHook;
  Future<void> Function(String node, Uint8List payload, Future<void> Function(String, Uint8List) orig)? sendAppHook;

  @override
  bool get isNative => false;

  @override
  bool get devCrypto => true;

  @override
  Future<({Uint8List bundle, Uint8List ik})> signalInit() => sig.signalInit();

  @override
  Future<String> signalAddContact(Uint8List bundle) => sig.signalAddContact(bundle);

  @override
  Future<Uint8List> signalSeal(String tag, Uint8List plaintext) => sealHook == null ? sig.signalSeal(tag, plaintext) : sealHook!(tag, plaintext, sig.signalSeal);

  @override
  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(Uint8List payload) => sig.signalOpen(payload);

  @override
  Future<Uint8List> signalProof(Uint8List ik, Uint8List n, Uint8List challengerTag, Uint8List proverTag) => sig.signalProof(ik, n, challengerTag, proverTag);

  @override
  Future<String> signalSafetyNumber(Uint8List ik) => sig.signalSafetyNumber(ik);

  @override
  Future<void> signalForget(String tag) => sig.signalForget(tag);

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    (handlers[event] ??= []).add(cb);
    return () => handlers[event]!.remove(cb);
  }

  void emit(String ev, Map<String, Object?> d) {
    Timer(Duration.zero, () {
      for (final h in List.of(handlers[ev] ?? const [])) {
        h(d);
      }
    });
  }

  @override
  Future<String> start(Uint8List selfTag) async {
    tag = hex(selfTag);
    return node;
  }

  @override
  Future<List<Map<String, Object?>>> getNeighbors() async => [];

  @override
  Future<List<InboxItem>> drainInbox() async => inbox;

  @override
  Future<({Uint8List key, bool insecure})> getDbKey() async => (key: random(32), insecure: false);

  Future<void> _sendApp(String to, Uint8List payload) async {
    final t = nodes.where((n) => n.node == to).firstOrNull;
    if (t != null && neighbors.contains(to)) {
      t.emit('packet', {'packet': encodePacket(type: PacketType.app, payload: payload), 'from': node});
    }
  }

  @override
  Future<void> sendApp(String to, Uint8List payload) => sendAppHook == null ? _sendApp(to, payload) : sendAppHook!(to, payload, _sendApp);

  Future<int> _send(Uint8List pkt) async {
    final p = decodePacket(pkt);
    final others = nodes.where((n) => n != this && !n.offline && !offline).toList();
    if (p.type == PacketType.data) {
      final t = others.where((n) => n.tag == hex(p.dest)).firstOrNull;
      if (t == null) {
        emit('packet', {'packet': encodePacket(type: PacketType.deadEnd, dest: p.id), 'from': 'self'});
        return -1;
      }
      t.emit('packet', {'packet': pkt, 'from': node});
      emit('packet', {'packet': encodePacket(type: PacketType.ack, dest: p.id, hops: 1), 'from': 'self'});
    } else if (p.type == PacketType.discover) {
      for (final n in others) {
        n.origin[hex(p.id)] = this;
        n.emit('packet', {'packet': pkt, 'from': node});
      }
      Timer(const Duration(milliseconds: 100), () => emit('packet', {'packet': encodePacket(type: PacketType.deadEnd, dest: p.id), 'from': 'self'}));
    } else if (p.type == PacketType.reply) {
      origin[hex(p.dest)]!.emit('packet', {'packet': encodePacket(type: PacketType.reply, dest: p.dest, hops: hopsToOrigin, payload: p.payload), 'from': 'self'});
    }
    return others.length;
  }

  @override
  Future<int> send(Uint8List pkt) => sendHook == null ? _send(pkt) : sendHook!(pkt, _send);

  @override
  Future<void> setHello(String card, bool hidden) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void connect(FakeMesh a, FakeMesh b) {
  a.neighbors.add(b.node);
  b.neighbors.add(a.node);
  a.emit('neighbor', {'node': b.node, 'up': true, 'medium': 'lan', 'kbps': 1000});
  b.emit('neighbor', {'node': a.node, 'up': true, 'medium': 'lan', 'kbps': 1000});
}

Future<T> waitFor<T>(T? Function() fn, [int ms = 15000]) async {
  final end = DateTime.now().millisecondsSinceEpoch + ms;
  for (;;) {
    final v = fn();
    if (v != null && v != false) return v;
    if (DateTime.now().millisecondsSinceEpoch > end) throw StateError('timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

const timing = <String, int>{'helloRetry': 40, 'ack': 1500, 'verify': 1200, 'proof': 300, 'poll': 30, 'discover': 600, 'quiet': 150, 'ring': 500, 'quietRing': 150};

class U {
  U(this.mesh, this.core, this.link);

  final FakeMesh mesh;
  final Core core;
  final String link;

  RipploState get state => core.state;
  String get id => core.state.profile!.ripploId;
  Contact? contact(String id) => state.contact(id);
}

var _seq = 0;

Future<U> user(String name, {Map<String, int> t = timing, Notifier? notifier, List<InboxItem> inbox = const []}) async {
  final mesh = FakeMesh()..inbox = inbox.toList();
  final core = Core(mesh: mesh, dbName: 'db-$name-${_seq++}', notifier: notifier ?? (_) {}, timing: t, raw: MemoryRawStore());
  await core.init();
  await core.createProfile(name);
  return U(mesh, core, core.myInviteLink());
}

Future<String?> codeOf(Future<Object?> f) async {
  try {
    await f;
    return null;
  } on RipploError catch (e) {
    return e.code;
  }
}

Person personOf(U u) => Person(ObsMap(() {}, {'id': u.id, 'name': u.state.profile!.name, 'card': b64(parseLink(u.link).card), 'hops': 1}));

Future<void> burn(U b) async {
  final x = await user('Burner');
  await x.core.addContactFromLink(b.link);
  await x.core.sendText(b.id, 'x');
  await waitFor(() => b.contact(x.id)?.addedVia == 'link');
}

Map<String, Object?> record(U a, Map<String, Object?> obj, bool notified) {
  final v = parseLink(a.link);
  return {'tag': hex(deriveIds(v.ik).tag), 'ik': b64(v.ik), 'plaintext': b64(utf8(jsonEncode(obj))), 'notified': notified};
}

void main() {
  setUp(nodes.clear);

  group('contacts and links', () {
    test('rejects own link and a card with a bad bundle', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      expect(await codeOf(a.core.addContactFromLink(a.link)), 'self');
      final card = Uint8List.fromList(parseLink(b.link).card);
      card[2 + card[1] + 5] = 4;
      final forged = 'ripplo://add/${b64url(card)}.${b64url(c.sha256.convert(card).bytes.sublist(0, 6))}';
      final x = await user('Carol');
      expect(await codeOf(x.core.addContactFromLink(forged)), 'bad_link');
      expect(x.contact(b.id), isNull);
    });

    test('drops a malformed sealed payload without creating a contact', () async {
      final b = await user('Bob');
      final tag = parseLink(b.link).tag;
      b.mesh.emit('packet', {
        'packet': encodePacket(type: PacketType.data, dest: tag, payload: concat([
          [0xee, 5],
          random(10),
        ])),
        'from': 'x',
      });
      await pause(200);
      expect(b.state.contacts.keys, isEmpty);
    });

    test('addContactFromLink creates a contact with the persisted shape', () async {
      final a = await user('Alice'), b = await user('Bob');
      final ct = (await a.core.addContactFromLink(b.link))!;
      expect(ct.id, b.id);
      expect(ct.verification, 'none');
      expect(ct.addedVia, 'link');
      expect(ct['verifiedAt'], 0);
      expect(ct['conflict'], false);
      expect(ct.containsKey('card'), isTrue);
      expect(a.state.chats.any((x) => x.id == b.id), isTrue);
    });

    test('a link without a token still adds the contact; a web link works', () async {
      final a = await user('Alice'), b = await user('Bob'), x = await user('Carol');
      final bare = b.core.myInviteLink().replaceFirst(RegExp(r'\.[A-Za-z0-9_-]{11}$'), '');
      expect(parseLink(bare).token, isNull);
      expect((await a.core.addContactFromLink(bare))!.id, b.id);
      final web = webLink(a.link, 'pl');
      expect((await x.core.addContactFromLink(web))!.id, a.id);
      expect(x.contact(a.id)!.verification, 'none');
    });

    test('same name flags a conflict on both contacts', () async {
      final a = await user('Alice'), b = await user('Bob'), e = await user('bob');
      await a.core.addContactFromLink(b.link);
      await a.core.addContactFromLink(e.link);
      expect(a.contact(b.id)!.conflict, isTrue);
      expect(a.contact(e.id)!.conflict, isTrue);
    });

    test('flags a neighbor whose hello card this version cannot read', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => b.state.neighbors.firstOrNull?['card']);
      await a.mesh.sendApp(b.mesh.node, utf8(jsonEncode({'t': 'hello', 'card': b64([9, 9, 9])})));
      await waitFor(() => b.state.neighbors.first['unsupported'] == true);
    });

    test('hello is answered when the peer asks for it', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      expect((a.state.neighbors.first['card'] as Map)['id'], b.id);
    });

    test('keeps asking for the neighbor card until it arrives, even when hellos are lost', () async {
      final a = await user('Alice'), b = await user('Bob');
      var dropped = 0;
      b.mesh.sendAppHook = (node, payload, orig) async {
        if (dropped < 3) {
          dropped++;
          return;
        }
        await orig(node, payload);
      };
      connect(a.mesh, b.mesh);
      await waitFor(() => (a.state.neighbors.firstOrNull?['card'] as Map?)?['id'] == b.id, 6000);
      expect(dropped, 3);
    });
  });

  group('verification', () {
    test('scanning a link makes the owner see the scanner as a contact at once', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      await a.core.addContactFromLink(b.link, 'qr');
      await waitFor(() => b.contact(a.id) != null && !truthyReq(b.contact(a.id)!));
      expect(b.contact(a.id)!.addedVia, 'link');
    });

    test('a contact added by qr is verified at once, link only tells', () async {
      final a = await user('Alice'), b = await user('Bob'), x = await user('Carol');
      final q = (await a.core.addContactFromLink(b.link, 'qr'))!;
      expect(q.verification, 'qr');
      expect(q.verifiedAt, greaterThan(0));
      final l = (await a.core.addContactFromLink(x.link, 'link'))!;
      expect(l.verification, 'none');
    });

    test('nearby proof succeeds for the real key holder', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      final ct = (await a.core.addContactFromLink(b.link, 'link'))!;
      await waitFor(() => ct.verification == 'nearby');
      final q = await user('Qia'), r = await user('Rob');
      connect(q.mesh, r.mesh);
      await waitFor(() => q.state.neighbors.firstOrNull?['card']);
      final rc = (await q.core.addContactFromLink(r.link, 'qr'))!;
      await waitFor(() => rc.verification == 'qr');
    });

    test('proof fails for a node announcing the card without the private key; same name other key flags conflict', () async {
      final a = await user('Alice'), b = await user('Bob');
      final ct = (await a.core.addContactFromLink(b.link))!;
      final mal = FakeMesh();
      mal.on('packet', (e) {
        final p = decodePacket(e['packet'] as Uint8List);
        final msg = jsonDecode(unutf8(p.payload)) as Map;
        if (msg['t'] == 'challenge') mal.sendApp(a.mesh.node, utf8(jsonEncode({'t': 'proof', 'n': msg['n'], 'mac': b64(random(32))})));
      });
      connect(a.mesh, mal);
      await waitFor(() => a.state.neighbors.length == 1);
      mal.sendApp(a.mesh.node, utf8(jsonEncode({'t': 'hello', 'card': b64(parseLink(b.link).card)})));
      await waitFor(() => (a.state.neighbors.first['card'] as Map?)?['id'] == b.id);
      expect(await a.core.verifyNearby(b.id), isFalse);
      expect(ct.verifyState, 'failed');
      expect(ct.verification, 'none');
      final evil = await user('Bob');
      mal.sendApp(a.mesh.node, utf8(jsonEncode({'t': 'hello', 'card': b64(parseLink(evil.link).card)})));
      await waitFor(() => ct.conflict);
    });

    test('verifyByQr accepts the safety number or the matching link and markVerified sets manual', () async {
      final a = await user('Alice'), b = await user('Bob'), x = await user('Xavier');
      await a.core.addContactFromLink(b.link);
      await b.core.addContactFromLink(a.link);
      final sn = await a.core.safetyNumber(b.id);
      expect(RegExp(r'^\d{60}$').hasMatch(sn), isTrue);
      expect(await b.core.safetyNumber(a.id), sn);
      expect(await a.core.verifyByQr(b.id, x.link), isFalse);
      expect(await a.core.verifyByQr(b.id, '1' * 60), isFalse);
      expect(await a.core.verifyByQr(b.id, 'garbage'), isFalse);
      expect(await a.core.verifyByQr(b.id, sn.replaceAllMapped(RegExp('(.{5})'), (m) => '${m[1]} ')), isTrue);
      expect(a.contact(b.id)!.verification, 'qr');
      expect(await b.core.verifyByQr(a.id, a.link), isTrue);
      await a.core.addContactFromLink(x.link);
      await a.core.markVerified(x.id);
      expect(a.contact(x.id)!.verification, 'manual');
      expect(await codeOf(a.core.safetyNumber('NOPE')), 'no_contact');
      expect(await a.core.setVerified('NOPE', 'qr'), isFalse);
    });

    test('does not carry verification over when the same person is added again', () async {
      final a = await user('Alice'), b = await user('Bob');
      await b.core.addContactFromLink(a.link);
      await b.core.markVerified(a.id);
      expect(b.contact(a.id)!.verification, 'manual');
      await b.core.deleteContact(a.id);
      final again = (await b.core.addContactFromLink(a.link))!;
      expect(again.verification, 'none');
      expect(again.verifiedAt, 0);
    });

    test('verifies a re-added contact again over a direct link', () async {
      final a = await user('Alice'), b = await user('Bob');
      await b.core.addContactFromLink(a.link);
      await b.core.markVerified(a.id);
      await b.core.deleteContact(a.id);
      connect(a.mesh, b.mesh);
      final again = (await b.core.addContactFromLink(a.link))!;
      expect(again.verification, 'none');
      await waitFor(() => b.contact(a.id)!.verification == 'nearby');
    });

    test('tells the other person that you verified their key, as a hint only', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id)?.card);
      await a.core.markVerified(b.id);
      await waitFor(() => b.contact(a.id)!.peerVerified?['level'] == 'manual');
      expect(b.contact(a.id)!.verification, 'none');
    });

    test('always tries the nearby proof, also for someone who wrote first', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id)?.verification == 'nearby', 6000);
      await waitFor(() => a.contact(b.id)!.verification == 'nearby', 6000);
    });

    test('does not tell a stranger who only wrote first anything about you', () async {
      final a = await user('Alice'), b = await user('Bob');
      await burn(b);
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id));
      await b.core.markVerified(a.id);
      await pause(200);
      expect(a.contact(b.id)!.peerVerified, isNull);
    });
  });

  group('invitations and visibility', () {
    test('invite shows as a request, accept creates the chat on both sides', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.refreshPeople();
      await a.core.invite(a.state.people.firstWhere((p) => p.id == b.id));
      expect(a.contact(b.id)!.request, 'out');
      expect(a.state.chats.any((x) => x.id == b.id), isFalse);
      await waitFor(() => b.contact(a.id)?.request == 'in');
      expect(b.state.chats.any((x) => x.id == a.id), isFalse);
      await b.core.acceptRequest(a.id);
      expect(b.contact(a.id)!.request, isNull);
      expect(b.state.chats.any((x) => x.id == a.id), isTrue);
      await waitFor(() => a.contact(b.id)!.request == null);
      expect(a.state.chats.any((x) => x.id == b.id), isTrue);
      await a.core.sendText(b.id, 'hello after accept');
      await waitFor(() => b.state.msgs(a.id)?.isNotEmpty);
    });

    test('decline removes the pending contact on both sides', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.invite(personOf(b));
      await waitFor(() => b.contact(a.id)?.request == 'in');
      await b.core.declineRequest(a.id);
      expect(b.contact(a.id), isNull);
      await waitFor(() => a.contact(b.id) == null);
    });

    test('ignores chat messages from a requester until accepted', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.invite(personOf(b));
      await waitFor(() => b.contact(a.id)?.request == 'in');
      a.contact(b.id)!.request = null;
      await a.core.sendText(b.id, 'spam');
      await pause(200);
      expect(b.state.msgs(a.id)?.length ?? 0, 0);
    });

    test('a hidden user is not found in mesh search', () async {
      final a = await user('Alice'), b = await user('Bob');
      await b.core.saveSettings({'hidden': true});
      await a.core.refreshPeople();
      expect(a.state.people.any((p) => p.id == b.id), isFalse);
      await b.core.saveSettings({'hidden': false});
      await a.core.refreshPeople();
      expect(a.state.people.any((p) => p.id == b.id), isTrue);
    });

    test('hidden removes you from strangers nearby lists and refuses their invitations', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      await a.core.saveSettings({'hidden': true});
      await waitFor(() => b.state.neighbors.first['card'] == null);
      await pause(300);
      expect(b.state.neighbors.first['card'], isNull);
      await b.core.invite(Person(ObsMap(() {}, {'id': a.id, 'name': 'Alice', 'card': b64(parseLink(a.link).card), 'hops': 1})));
      await pause(250);
      expect(a.contact(b.id), isNull);
      await a.core.saveSettings({'hidden': false});
      await waitFor(() => (b.state.neighbors.first['card'] as Map?)?['id'] == a.id);
    });

    test('keeps showing you to your contacts', () async {
      final a = await user('Alice'), b = await user('Bob');
      await b.core.addContactFromLink(a.link);
      await a.core.addContactFromLink(b.link);
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
      await a.core.saveSettings({'hidden': true});
      await pause(300);
      expect((b.state.neighbors.first['card'] as Map?)?['id'], a.id);
    });
  });

  group('mesh search', () {
    test('keeps listening after a dead end so late replies from far phones are not lost', () async {
      final a = await user('Alice', t: {...timing, 'quiet': 700, 'quietRing': 700, 'ring': 3000, 'discover': 3000}), b = await user('Bob');
      b.mesh.sendHook = (pkt, orig) async {
        if (decodePacket(pkt).type == PacketType.reply) await pause(350);
        return orig(pkt);
      };
      await a.core.refreshPeople();
      expect(a.state.people.any((p) => p.id == b.id), isTrue);
    });

    test('finishes at once when there are no neighbors', () async {
      final a = await user('Alice', t: {...timing, 'quiet': 5000, 'quietRing': 5000, 'ring': 5000, 'discover': 5000});
      a.mesh.sendHook = (_, _) async => 0;
      final t0 = DateTime.now();
      await a.core.refreshPeople();
      expect(DateTime.now().difference(t0).inMilliseconds, lessThan(1000));
    });

    test('keeps at most 20 people and lets closer ones replace the farthest', () async {
      final a = await user('Alice');
      final far = [for (var i = 0; i < 24; i++) await user('Far$i')];
      for (final u in far) {
        u.mesh.hopsToOrigin = 6;
      }
      final near = [for (var i = 0; i < 3; i++) await user('Near$i')];
      for (final u in near) {
        u.mesh.hopsToOrigin = 1;
      }
      await a.core.refreshPeople();
      expect(a.state.people.length, 20);
      for (final n in near) {
        expect(a.state.people.any((p) => p.id == n.id), isTrue);
      }
      final hops = [for (final p in a.state.people) p.hops];
      expect(hops, [...hops]..sort());
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('finds a person by exact username only, case-insensitively, and never sends the name in clear', () async {
      final a = await user('Alice'), b = await user('Bob Builder'), x = await user('Carol');
      final sent = <String>[];
      a.mesh.sendHook = (pkt, orig) {
        sent.add(unutf8(decodePacket(pkt).payload));
        return orig(pkt);
      };
      await a.core.searchPeople('  bob   BUILDER ');
      expect([for (final p in a.state.people) p.id], [b.id]);
      expect(a.state.peopleQuery, 'bob   BUILDER');
      expect(RegExp('bob', caseSensitive: false).hasMatch(sent.join()), isFalse);
      await a.core.searchPeople(x.id.replaceAllMapped(RegExp('(.{4})'), (m) => '${m[1]}-').substring(0, 19));
      expect(a.state.people, isEmpty);
      await a.core.searchPeople('carol');
      expect([for (final p in a.state.people) p.id], [x.id]);
      await a.core.searchPeople('Bo');
      expect(a.state.people, isEmpty);
    });

    test('restores the previous list when the search is cleared', () async {
      final a = await user('Alice'), b = await user('Bob'), x = await user('Carol');
      await a.core.refreshPeople();
      expect(a.state.people.length, 2);
      await a.core.searchPeople('Bob');
      expect([for (final p in a.state.people) p.id], [b.id]);
      await a.core.searchPeople('');
      expect([for (final p in a.state.people) p.id]..sort(), [b.id, x.id]..sort());
      expect(a.state.peopleQuery, '');
    });

    test('answers only inside the requested distance ring', () async {
      final a = await user('Alice'), b = await user('Bob');
      var replies = 0;
      b.mesh.sendHook = (pkt, orig) {
        if (decodePacket(pkt).type == PacketType.reply) replies++;
        return orig(pkt);
      };
      void ask(int hops, Map<String, Object?> body) => b.mesh.emit('packet', {'packet': encodePacket(type: PacketType.discover, id: newId(), hops: hops, payload: utf8(jsonEncode(body))), 'from': a.mesh.node});
      ask(3, {'t': 'who', 'h': 2});
      ask(0, {'t': 'who', 'lo': 1});
      await pause(100);
      expect(replies, 0);
      ask(2, {'t': 'who', 'h': 3, 'lo': 1});
      await waitFor(() => replies == 1);
    });
  });

  group('request hygiene', () {
    test('notifies about an invitation with the sender name', () async {
      final seen = <Notice>[];
      final bob = await user('Bob', notifier: seen.add);
      final a = await user('Alice');
      await a.core.invite(personOf(bob));
      await waitFor(() => seen.length == 1);
      expect(RegExp('invitation|zaproszenie', caseSensitive: false).hasMatch(seen[0].title), isTrue);
      expect(seen[0].body, contains('Alice'));
    });

    test('does not send profile changes or a name/photo with a decline to people you have not accepted', () async {
      final a = await user('Alice'), b = await user('Bob');
      final seen = <Object?>[];
      b.mesh.sealHook = (tag, pt, orig) {
        seen.add(jsonDecode(unutf8(pt)));
        return orig(tag, pt);
      };
      await a.core.invite(personOf(b));
      await waitFor(() => b.contact(a.id)?.request == 'in');
      await b.core.setAvatar(b64(concat([
        [0xff, 0xd8, 0xff, 0xe0],
        Uint8List(50),
      ])));
      await b.core.setName('Robert');
      await pause(200);
      expect(seen, isEmpty);
      await b.core.declineRequest(a.id);
      await waitFor(() => seen.length == 1);
      expect(seen[0], {'t': 'decline'});
    });

    test('scanning the QR of someone who invited you accepts the request', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.invite(personOf(b));
      await waitFor(() => b.contact(a.id)?.request == 'in');
      await b.core.addContactFromLink(a.link, 'qr');
      expect(b.contact(a.id)!.request, isNull);
      expect(b.state.chats.any((x) => x.id == a.id), isTrue);
    });

    test('does not open a chat with someone you only invited', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.invite(personOf(b));
      expect(await codeOf(a.core.sendText(b.id, 'x')), 'no_chat');
    });
  });

  group('single-use invite links', () {
    test('trusts the first person who uses a link and treats a second use as a stranger', () async {
      final a = await user('Alice'), x = await user('Carol'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'first');
      await waitFor(() => b.contact(a.id)?.addedVia == 'link');
      await x.core.addContactFromLink(b.link);
      await x.core.sendText(b.id, 'second');
      await waitFor(() => b.contact(x.id));
      await pause(100);
      expect(b.contact(x.id)!.addedVia, 'incoming');
      await a.core.sendText(b.id, 'again');
      await waitFor(() => b.state.msgs(a.id)?.length == 2);
      expect(b.contact(a.id)!.addedVia, 'link');
    });

    test('an unknown token earns nothing', () async {
      final a = await user('Alice'), b = await user('Bob');
      final one = b.core.myInviteLink();
      final forged = one.replaceFirst(RegExp(r'\.[A-Za-z0-9_-]{11}$'), '.AAAAAAAAAAA');
      await a.core.addContactFromLink(forged);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id));
      await pause(100);
      expect(b.contact(a.id)!.addedVia, 'incoming');
    });
  });

  group('messages already opened by the native layer', () {
    test('shows a drained message and stays silent when the native layer already notified', () async {
      final a = await user('Alice');
      final seen = <Notice>[];
      final b = await user('Bob', notifier: seen.add, inbox: [InboxOpened(record(a, {'t': 'msg', 'id': 'm1', 'text': 'hello from native'}, true))]);
      await b.core.start();
      await waitFor(() => b.state.msgs(a.id)?.any((m) => m.text == 'hello from native'));
      expect(seen, isEmpty);
    });

    test('notifies itself when the native layer did not', () async {
      final a = await user('Alice');
      final seen = <Notice>[];
      final b = await user('Bob', notifier: seen.add);
      b.mesh.emit('opened', record(a, {'t': 'msg', 'id': 'm2', 'text': 'plain'}, false));
      await waitFor(() => seen.length == 1);
      expect(seen[0].body, 'plain');
    });

    test('shows an invitation silently', () async {
      final a = await user('Alice');
      final seen = <Notice>[];
      final b = await user('Bob', notifier: seen.add);
      b.mesh.emit('opened', record(a, {'t': 'invite'}, true));
      await waitFor(() => b.contact(a.id)?.request == 'in');
      expect(seen, isEmpty);
    });

    test('ignores a malformed opened record', () async {
      final b = await user('Bob');
      b.mesh.emit('opened', {'tag': 1, 'ik': '!!', 'plaintext': null});
      await pause(100);
      expect(b.state.contacts.keys, isEmpty);
    });
  });

  group('session reset', () {
    test('resets the session on a decrypt failure once per 10 minutes and tells the user', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'one');
      await waitFor(() => b.contact(a.id)?.card);
      final tag = hex(parseLink(a.link).tag);
      await b.core.onOpenFailed(MeshError('bad_message', 'x', {'tag': tag}));
      final sys = b.state.msgs(a.id)!.where((m) => m.from == 'system').toList();
      expect(sys, hasLength(1));
      expect(sys.first.text, contains('Alice'));
    });
  });
}

bool truthyReq(Contact c) => c.request != null;
