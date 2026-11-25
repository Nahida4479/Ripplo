import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/messenger.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/data/db.dart';
import 'package:ripplo/crypto/identity.dart';
import 'package:ripplo/crypto/vault.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/mesh/dev/dev_signal.dart';
import 'package:ripplo/mesh/packet.dart';
import 'package:ripplo/util/avatar.dart';
import 'package:ripplo/util/bytes.dart';
import 'package:ripplo/util/js.dart' as js;

final nodes = <PMesh>[];

class PMesh implements Mesh {
  PMesh({Uint8List? dbKey}) : dbKey = dbKey ?? random(32) {
    nodes.add(this);
  }

  final Uint8List dbKey;
  final sig = DevSignal();
  final handlers = <String, List<void Function(Map<String, Object?>)>>{};
  final node = hex(random(8));
  String tag = '';
  final neighbors = <String>{};
  final forgotten = <String>[];
  final sentApp = <Map<String, Object?>>[];
  Future<Uint8List> Function(String tag, Uint8List plaintext)? sealHook;
  Future<void> Function(String node, Uint8List payload)? appHook;
  Future<Map<String, Object?>> Function(String code)? restoreHook;

  @override
  bool get isNative => false;

  @override
  bool get devCrypto => true;

  @override
  Future<({Uint8List bundle, Uint8List ik})> signalInit() => sig.signalInit();

  @override
  Future<String> signalAddContact(Uint8List bundle) => sig.signalAddContact(bundle);

  @override
  Future<Uint8List> signalSeal(String tag, Uint8List plaintext) => sealHook != null ? sealHook!(tag, plaintext) : sig.signalSeal(tag, plaintext);

  @override
  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(Uint8List payload) => sig.signalOpen(payload);

  @override
  Future<Uint8List> signalProof(Uint8List ik, Uint8List n, Uint8List challengerTag, Uint8List proverTag) => sig.signalProof(ik, n, challengerTag, proverTag);

  @override
  Future<String> signalSafetyNumber(Uint8List ik) => sig.signalSafetyNumber(ik);

  @override
  Future<void> signalForget(String tag) {
    forgotten.add(tag);
    return sig.signalForget(tag);
  }

  @override
  Unsub on(String event, void Function(Map<String, Object?> data) cb) {
    (handlers[event] ??= []).add(cb);
    return () => handlers[event]!.remove(cb);
  }

  void emit(String event, Map<String, Object?> data) {
    Timer.run(() {
      for (final h in List.of(handlers[event] ?? const [])) {
        h(data);
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
  Future<List<InboxItem>> drainInbox() async => [];

  @override
  Future<({Uint8List key, bool insecure})> getDbKey() async => (key: dbKey, insecure: false);

  @override
  Future<void> notify(String title, String body, String? chatId) async {}

  @override
  Future<Map<String, Object?>> backupRestore(String code) => restoreHook!(code);

  @override
  Future<void> sendApp(String node, Uint8List payload) async {
    if (appHook != null) {
      await appHook!(node, payload);
      return;
    }
    await deliverApp(node, payload);
  }

  Future<void> deliverApp(String node, Uint8List payload) async {
    sentApp.add({'node': node, 'payload': payload});
    final t = nodes.where((n) => n.node == node).firstOrNull;
    if (t != null && neighbors.contains(node)) {
      t.emit('packet', {'packet': encodePacket(type: PacketType.app, payload: payload), 'from': this.node});
    }
  }

  @override
  Future<int> send(Uint8List pkt) async {
    final p = decodePacket(pkt);
    final others = nodes.where((n) => n != this).toList();
    if (p.type == PacketType.data) {
      final t = others.where((n) => n.tag == hex(p.dest)).firstOrNull;
      if (t == null) {
        emit('packet', {'packet': encodePacket(type: PacketType.deadEnd, dest: p.id), 'from': 'self'});
        return 0;
      }
      t.emit('packet', {'packet': pkt, 'from': node});
      emit('packet', {'packet': encodePacket(type: PacketType.ack, dest: p.id, hops: 1), 'from': 'self'});
    }
    return others.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void connect(PMesh a, PMesh b) {
  a.neighbors.add(b.node);
  b.neighbors.add(a.node);
  a.emit('neighbor', {'node': b.node, 'up': true, 'medium': 'lan', 'kbps': 1000});
  b.emit('neighbor', {'node': a.node, 'up': true, 'medium': 'lan', 'kbps': 1000});
}

Future<T> waitFor<T extends Object>(T? Function() fn, [int ms = 15000]) async {
  final end = DateTime.now().millisecondsSinceEpoch + ms;
  for (;;) {
    final v = fn();
    if (v != null && v != false) return v;
    if (DateTime.now().millisecondsSinceEpoch > end) throw TimeoutException('waitFor');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const timing = {'helloRetry': 40, 'ack': 1500, 'verify': 1200, 'proof': 300, 'poll': 30, 'discover': 600, 'quiet': 150, 'ring': 500, 'quietRing': 150};

class User {
  User(this.mesh, this.core, this.id, this.link);

  final PMesh mesh;
  final Core core;
  final String id;
  final String link;
  RipploState get state => core.state;
  Contact? contact(String id) => state.contact(id);
}

Future<User> user(String name) async {
  final mesh = PMesh();
  final core = Core(mesh: mesh, dbName: 'db-$name-${hex(random(4))}', notifier: (_) {}, timing: timing, raw: MemoryRawStore());
  await core.init();
  await core.createProfile(name);
  return User(mesh, core, core.state.profile!.ripploId, core.myInviteLink());
}

Future<String?> codeOf(Future<Object?> p) async {
  try {
    await p;
    return null;
  } on RipploError catch (e) {
    return e.code;
  }
}

Future<void> pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

String jpeg(int n) => b64(concat([
  [0xff, 0xd8, 0xff, 0xe0],
  List.filled(n, 7),
]));

Map<String, Object?> jsonOf(Uint8List b) => Map<String, Object?>.from(jsonDecode(unutf8(b)) as Map);

void main() {
  setUp(nodes.clear);
  tearDown(() => js.now = () => DateTime.now().millisecondsSinceEpoch);

  group('profile creation', () {
    test('rejects empty names and persists the profile', () async {
      final mesh = PMesh();
      final raw = MemoryRawStore();
      final core = Core(mesh: mesh, dbName: 'db-p', notifier: (_) {}, timing: timing, raw: raw);
      await core.init();
      expect(core.state.needsOnboarding, isTrue);
      expect(await codeOf(core.createProfile('  ')), 'bad_name');
      expect(core.state.needsOnboarding, isTrue);
      await core.createProfile('  Alice\u0001 ');
      expect(core.state.needsOnboarding, isFalse);
      expect(core.state.profile!.name, 'Alice');
      expect(core.state.profile!.avatar, '');
      expect(core.state.profile!.tag, hex(deriveIds(core.own.ik).tag));
      await core.close();
      final again = Core(mesh: mesh, dbName: 'db-p', notifier: (_) {}, timing: timing, raw: raw);
      await again.init();
      expect(again.state.needsOnboarding, isFalse);
      expect(again.state.profile!.name, 'Alice');
      expect(again.state.profile!.ripploId, core.state.profile!.ripploId);
      await again.close();
    });

    test('persists settings', () async {
      final mesh = PMesh();
      final raw = MemoryRawStore();
      final a = Core(mesh: mesh, dbName: 'db-s', notifier: (_) {}, timing: timing, raw: raw);
      await a.init();
      await a.createProfile('Alice');
      await a.saveSettings({'autoUpdate': false, 'nonsense': true, 'dev': 'yes'});
      expect(Map<String, Object?>.of(a.state.settings), {'autoUpdate': false, 'backgroundRelay': true});
      await a.close();
      final b = Core(mesh: mesh, dbName: 'db-s', notifier: (_) {}, timing: timing, raw: raw);
      await b.init();
      expect(Map<String, Object?>.of(b.state.settings), {'autoUpdate': false, 'backgroundRelay': true});
      await b.close();
    });
  });

  group('card piggyback and session reset', () {
    test('sends the card until the contact answers, and the receiver stores it', () async {
      final a = await user('Alice'), b = await user('Bob');
      final seen = <Map<String, Object?>>[];
      a.mesh.sealHook = (tag, pt) {
        seen.add(jsonOf(pt));
        return a.mesh.sig.signalSeal(tag, pt);
      };
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'one');
      await waitFor(() => b.contact(a.id)?.card);
      expect(b.contact(a.id)!.name, 'Alice');
      expect(seen[0]['c'], isNotNull);
      await b.core.sendText(a.id, 'reply');
      await waitFor(() => a.contact(b.id)!.cardAck);
      await a.core.sendText(b.id, 'two');
      await waitFor(() => seen.length >= 2);
      expect(seen.last.containsKey('c'), isFalse);
    });

    test('rejects a piggybacked card for another identity', () async {
      final a = await user('Alice'), b = await user('Bob'), c = await user('Carol');
      await b.core.addContactFromLink(a.link);
      final forged = b.contact(a.id)!;
      a.mesh.sealHook = (tag, pt) => a.mesh.sig.signalSeal(tag, utf8(jsonEncode({...jsonOf(pt), 'c': b64(parseLink(c.link).card)})));
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.state.msgs(a.id)?.isNotEmpty == true ? true : null);
      expect(forged.card, isNot(b64(parseLink(c.link).card)));
    });

    test('resets every contact with a card after a restore', () async {
      final a = await user('Alice'), b = await user('Bob');
      final key = random(32);
      final mesh = PMesh(dbKey: key);
      mesh.restoreHook = (_) async => {'meta': <String, Object?>{}};
      final raw = MemoryRawStore();
      const dbName = 'db-restore';
      final first = Core(mesh: mesh, dbName: dbName, notifier: (_) {}, timing: timing, raw: raw);
      await first.init();
      await first.createProfile('Carol');
      await first.addContactFromLink(a.link);
      await first.addContactFromLink(b.link);
      final r = await first.restoreBackup('1' * 30);
      expect(r, {'meta': <String, Object?>{}});
      await first.close();
      mesh.forgotten.clear();
      final second = Core(mesh: mesh, dbName: dbName, notifier: (_) {}, timing: timing, raw: raw);
      await second.init();
      expect(mesh.forgotten..sort(), [hex(parseLink(a.link).tag), hex(parseLink(b.link).tag)]..sort());
      final d = await openDb(dbName, Vault(key), mesh, raw: raw);
      expect(await d.get('kv', 'needsSessionReset'), isNull);
      await second.close();
    });

    test('resetSession respects the ten minute gap and needs a card', () async {
      final a = await user('Alice'), b = await user('Bob');
      final c = (await a.core.addContactFromLink(b.link))!;
      expect(await a.core.resetSession(c), isTrue);
      expect(await a.core.resetSession(c), isFalse);
      var t = js.now();
      js.now = () => t + 11 * 60 * 1000;
      expect(await a.core.resetSession(c), isTrue);
      c.card = null;
      t += 30 * 60 * 1000;
      expect(await a.core.resetSession(c), isFalse);
    });
  });

  group('profile picture', () {
    test('validates avatars', () {
      expect(isAvatar(jpeg(100)), isTrue);
      expect(isAvatar(b64(utf8('<svg onload=alert(1)>'))), isFalse);
      expect(isAvatar(jpeg(20000)), isFalse);
      expect(isAvatar(''), isFalse);
    });

    test('reaches the contact with the first message and follows changes and removal', () async {
      final a = await user('Alice'), b = await user('Bob');
      expect(await codeOf(a.core.setAvatar('not-a-jpeg')), 'bad_avatar');
      await a.core.setAvatar(jpeg(100));
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id)?.avatar == jpeg(100) ? true : null);
      await a.core.setAvatar(jpeg(200));
      await waitFor(() => b.contact(a.id)!.avatar == jpeg(200) ? true : null);
      await a.core.setAvatar('');
      await waitFor(() => b.contact(a.id)!.avatar == '' ? true : null);
      expect(a.state.profile!.avatar, '');
    });

    test('stores the profile record with name and avatar', () async {
      final a = await user('Alice');
      await a.core.setAvatar(jpeg(100));
      expect(await a.core.db.get('kv', 'profile'), {'name': 'Alice', 'avatar': jpeg(100)});
      await a.core.setAvatar(null);
      expect(await a.core.db.get('kv', 'profile'), {'name': 'Alice', 'avatar': ''});
      expect(a.core.me.avVer, '');
    });

    test('ignores an invalid avatar from a peer', () async {
      final a = await user('Alice'), b = await user('Bob');
      a.mesh.sealHook = (tag, pt) => a.mesh.sig.signalSeal(tag, utf8(jsonEncode({...jsonOf(pt), 'av': b64(utf8('<svg/>'))})));
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id));
      await waitFor(() => b.state.msgs(a.id)?.isNotEmpty == true ? true : null);
      expect(b.contact(a.id)!.avatar, isNull);
    });
  });

  group('changing the display name', () {
    test('rejects empty names and updates the contact, its chat, the card and the link', () async {
      final a = await user('Alice'), b = await user('Bob');
      expect(await codeOf(a.core.setName('  ')), 'bad_name');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id)?.card);
      await a.core.setName('Alicja');
      await waitFor(() => b.contact(a.id)!.name == 'Alicja' ? true : null);
      expect(b.state.chats.firstWhere((c) => c.id == a.id).name, 'Alicja');
      expect(a.state.profile!.name, 'Alicja');
      expect(a.state.profile!.ripploId, a.id);
      expect(parseLink(a.core.myInviteLink()).name, 'Alicja');
    });

    test('the same name changes nothing', () async {
      final a = await user('Alice');
      final card = a.core.me.card;
      await a.core.setName('Alice');
      expect(identical(a.core.me.card, card), isTrue);
    });
  });

  group('single-use invite links', () {
    test('trusts the first person who uses a link and treats a second use as a stranger', () async {
      final a = await user('Alice'), c = await user('Carol'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'first');
      await waitFor(() => b.contact(a.id)?.addedVia == 'link' ? true : null);
      await c.core.addContactFromLink(b.link);
      await c.core.sendText(b.id, 'second');
      await waitFor(() => b.contact(c.id));
      await pause(100);
      expect(b.contact(c.id)!.addedVia, 'incoming');
      await a.core.sendText(b.id, 'again');
      await waitFor(() => b.state.msgs(a.id)?.length == 2 ? true : null);
      expect(b.contact(a.id)!.addedVia, 'link');
    });

    test('each new code is a fresh link and an unknown token earns nothing', () async {
      final a = await user('Alice'), b = await user('Bob');
      final one = b.core.myInviteLink(), two = b.core.myInviteLink();
      expect(one, isNot(two));
      expect(parseLink(one).token, hasLength(11));
      expect(parseLink(two).id, b.id);
      final forged = one.replaceFirst(RegExp(r'\.[A-Za-z0-9_-]{11}$'), '.AAAAAAAAAAA');
      await a.core.addContactFromLink(forged);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id));
      await pause(100);
      expect(b.contact(a.id)!.addedVia, 'incoming');
    });

    test('keeps at most 30 pending tokens and persists them', () async {
      final b = await user('Bob');
      final first = parseLink(b.link).token;
      for (var i = 0; i < 40; i++) {
        b.core.myInviteLink();
      }
      expect(b.core.tokenPending, hasLength(maxTokens));
      expect(b.core.tokenPending.contains(first!), isFalse);
      await pause(50);
      final saved = await b.core.db.get('kv', 'tokens') as Map;
      expect(saved['pending'], b.core.tokenPending);
      expect(saved['used'], <String, Object?>{});
    });

    test('redeem consumes a pending token once, caps the used list, ignores strangers', () async {
      final b = await user('Bob');
      final tk = b64url(random(8));
      b.core.tokenPending.add(tk);
      await b.core.redeem('f1', tk);
      expect(b.core.tokenPending.contains(tk), isFalse);
      expect(b.core.tokenUsed[tk], 'f1');
      await b.core.redeem('f2', tk);
      expect(b.core.tokenUsed[tk], 'f1');
      for (var i = 0; i < 205; i++) {
        final k = b64url(random(8));
        b.core.tokenPending.add(k);
        await b.core.redeem('x$i', k);
      }
      expect(b.core.tokenUsed.length, maxUsed);
      expect(b.core.tokenUsed.containsKey(tk), isFalse);
    });
  });

  group('hello', () {
    test('keeps asking for the neighbor card until it arrives, even when hellos are lost', () async {
      final a = await user('Alice'), b = await user('Bob');
      var dropped = 0;
      b.mesh.appHook = (node, payload) async {
        if (dropped < 3) {
          dropped++;
          return;
        }
        await b.mesh.deliverApp(node, payload);
      };
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.isNotEmpty && a.state.neighbors[0]['card'] is Map && (a.state.neighbors[0]['card'] as Map)['id'] == b.id ? true : null, 6000);
      expect(dropped, 3);
    });

    test('hello carries the card, the ask flag only when asking', () async {
      final a = await user('Alice');
      a.core.sendHello('n1', true);
      a.core.sendHello('n2', false);
      await pause(20);
      final out = [for (final s in a.mesh.sentApp) jsonOf(s['payload'] as Uint8List)];
      expect(out[0], {'t': 'hello', 'card': b64(a.core.me.card), 'r': 1});
      expect(out[1], {'t': 'hello', 'card': b64(a.core.me.card)});
      expect(out[0].keys.toList(), ['t', 'card', 'r']);
      expect(a.core.greeted, containsAll(['n1', 'n2']));
    });

    test('hello is answered when the peer asks for it', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.isNotEmpty && b.state.neighbors.isNotEmpty && a.state.neighbors[0]['card'] != null && b.state.neighbors[0]['card'] != null ? true : null);
      expect((a.state.neighbors[0]['card'] as Map)['id'], b.id);
    });

    test('hidden mode greets contacts only, and sends bye to strangers when it turns on', () async {
      final a = await user('Alice'), b = await user('Bob');
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.isNotEmpty && a.state.neighbors[0]['card'] != null && b.state.neighbors[0]['card'] != null ? true : null);
      a.mesh.sentApp.clear();
      await a.core.saveSettings({'hidden': true});
      await pause(50);
      expect([for (final s in a.mesh.sentApp) jsonOf(s['payload'] as Uint8List)], [
        {'t': 'bye'},
      ]);
      a.mesh.sentApp.clear();
      a.core.sendHello(a.state.neighbors[0].node, false);
      await pause(20);
      expect(a.mesh.sentApp, isEmpty);
      await a.core.saveSettings({'hidden': false});
      await waitFor(() => (b.state.neighbors[0]['card'] as Map?)?['id'] == a.id ? true : null);
    });

    test('tellVerified and pushProfile only reach consented contacts', () async {
      final a = await user('Alice'), b = await user('Bob'), c = await user('Carol');
      final seen = <Map<String, Object?>>[];
      a.mesh.sealHook = (tag, pt) {
        seen.add(jsonOf(pt));
        return a.mesh.sig.signalSeal(tag, pt);
      };
      final cb = (await a.core.addContactFromLink(b.link))!;
      await a.core.addContactFromLink(c.link);
      a.core.state.contact(c.id)!['request'] = 'sent';
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.contact(a.id)?.card);
      seen.clear();
      a.core.tellVerified(cb);
      await waitFor(() => seen.isNotEmpty ? true : null);
      expect(seen.single['t'], 'profile');
      seen.clear();
      await a.core.setName('Alicja');
      await pause(100);
      expect(seen.where((m) => m['t'] == 'profile'), hasLength(1));
      expect(seen.single['nm'], 'Alicja');
    });
  });

  group('delete', () {
    test('deleteChat removes messages, blobs and the chat; deleteContact also forgets the session', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'one');
      await a.core.sendText(b.id, 'two');
      await waitFor(() => b.state.msgs(a.id)?.length == 2 ? true : null);
      await a.core.db.putBin('blobs', 'att1', Uint8List.fromList([1, 2, 3]));
      final m = a.state.msgs(b.id)!.first;
      m['att'] = {'attId': 'att1', 'kind': 'image'};
      await a.core.persistMsg(m);
      await pause(20);
      await a.core.deleteChat(b.id);
      expect(a.state.msgs(b.id), isNull);
      expect(a.state.chats.any((c) => c.id == b.id), isFalse);
      expect(await a.core.db.msgs(b.id), isEmpty);
      expect(await a.core.db.getBin('blobs', 'att1'), isNull);
      expect(await a.core.db.get('chats', b.id), isNull);
      expect(a.contact(b.id), isNotNull);
      await a.core.deleteContact(b.id);
      expect(a.contact(b.id), isNull);
      expect(await a.core.db.get('contacts', b.id), isNull);
      expect(a.mesh.forgotten, [hex(parseLink(b.link).tag)]);
    });

    test('deleting an unknown contact is harmless', () async {
      final a = await user('Alice');
      await a.core.deleteContact('nobody');
      expect(a.mesh.forgotten, isEmpty);
    });
  });
}
