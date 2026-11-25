import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/messenger.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/data/db.dart';
import 'package:ripplo/crypto/identity.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/mesh/dev/dev_signal.dart';
import 'package:ripplo/mesh/packet.dart';
import 'package:ripplo/util/bytes.dart';
import 'package:ripplo/util/js.dart' as js;

final nodes = <FakeMesh>[];

class FakeMesh implements Mesh {
  FakeMesh() {
    nodes.add(this);
  }

  final sig = DevSignal();
  final handlers = <String, List<void Function(Map<String, Object?>)>>{};
  final node = hex(random(8));
  String tag = '';
  final neighbors = <String>{};
  bool offline = false;
  Map<String, FakeMesh> origin = {};
  Future<Uint8List> Function(String tag, Uint8List plaintext)? sealHook;
  Future<int?> Function(Uint8List pkt)? sendHook;

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
  Future<void> signalForget(String tag) => sig.signalForget(tag);

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
  Future<({Uint8List key, bool insecure})> getDbKey() async => (key: random(32), insecure: false);

  @override
  Future<void> notify(String title, String body, String? chatId) async {}

  @override
  Future<void> sendApp(String node, Uint8List payload) async {
    final t = nodes.where((n) => n.node == node).firstOrNull;
    if (t != null && neighbors.contains(node)) {
      t.emit('packet', {'packet': encodePacket(type: PacketType.app, payload: payload), 'from': this.node});
    }
  }

  Future<int> rawSend(Uint8List pkt) async {
    final p = decodePacket(pkt);
    final others = nodes.where((n) => n != this && !n.offline && !offline).toList();
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
  Future<int> send(Uint8List pkt) async {
    final r = sendHook == null ? null : await sendHook!(pkt);
    return r ?? await rawSend(pkt);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void connect(FakeMesh a, FakeMesh b) {
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

  final FakeMesh mesh;
  final Core core;
  final String id;
  final String link;
  RipploState get state => core.state;
}

Future<User> user(String name, [Map<String, int> tm = timing]) async {
  final mesh = FakeMesh();
  final core = Core(mesh: mesh, dbName: 'db-$name-${hex(random(4))}', notifier: (_) {}, timing: tm, raw: MemoryRawStore());
  await core.init();
  await core.createProfile(name);
  return User(mesh, core, core.state.profile!.ripploId, core.myInviteLink());
}

Future<void> unlock(User a, User b) async {
  await a.core.sendText(b.id, 'hi');
  await waitFor(() => b.state.contact(a.id)?.card);
  await b.core.sendText(a.id, 'hello');
  await waitFor(() => a.state.contact(b.id)!.cardAck);
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

AttFile file(Uint8List bytes, String type, [num? duration]) => (bytes: bytes, type: type, duration: duration);

Msg? withAtt(User u, String chat) => u.state.msgs(chat)?.where((x) => x.att != null).firstOrNull;

bool typingOf(User u, String chat, String who) => ((u.state.typing[chat] as List?) ?? const []).contains(who);

bool anyTyping(User u, String chat) => ((u.state.typing[chat] as List?) ?? const []).isNotEmpty;

void main() {
  setUp(nodes.clear);
  tearDown(() => js.now = () => DateTime.now().millisecondsSinceEpoch);

  group('messaging', () {
    test('Alice -> Bob (PreKey), Bob -> Alice, several messages', () async {
      final a = await user('Alice'), b = await user('Bob');
      final contact = await a.core.addContactFromLink(b.link);
      expect(contact!.id, b.id);
      expect(contact.verification, 'none');
      final m1 = await a.core.sendText(b.id, 'hello bob');
      await waitFor(() => m1.status == 'delivered');
      expect(m1['hops'], 1);
      final inc = await waitFor(() => b.state.msgs(a.id)?.firstOrNull);
      expect(inc.text, 'hello bob');
      expect(b.state.contact(a.id)!.addedVia, 'link');
      expect(b.state.contact(a.id)!.verification, 'none');
      expect(b.state.chats.firstWhere((c) => c.id == a.id).unread, 1);
      final r1 = await b.core.sendText(a.id, 'hi alice');
      await waitFor(() => r1.status == 'delivered');
      await waitFor(() => a.state.msgs(b.id)?.any((m) => m.text == 'hi alice'));
      for (var i = 0; i < 5; i++) {
        await a.core.sendText(b.id, 'a$i');
        await b.core.sendText(a.id, 'b$i');
      }
      await waitFor(() => b.state.msgs(a.id)!.length == 12 && a.state.msgs(b.id)!.length == 12);
      final got = [for (final m in b.state.msgs(a.id)!) if (m.text!.startsWith('a')) m.text!]..sort();
      expect(got, ['a0', 'a1', 'a2', 'a3', 'a4']);
      b.core.markRead(a.id);
      expect(b.state.chats.firstWhere((c) => c.id == a.id).unread, 0);
    });

    test('rejects text over 1000 chars and empty text', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      expect(await codeOf(a.core.sendText(b.id, 'x' * 1001)), 'too_long');
      expect(await codeOf(a.core.sendText(b.id, '   ')), 'empty');
      expect(await codeOf(a.core.sendText(b.id, null)), 'empty');
    });

    test('retries after out_of_range', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      b.mesh.offline = true;
      final m = await a.core.sendText(b.id, 'later');
      await waitFor(() => m.status == 'out_of_range');
      b.mesh.offline = false;
      await a.core.retry(m.id);
      await waitFor(() => m.status == 'delivered');
      await waitFor(() => b.state.msgs(a.id)?.length == 1);
    });
  });

  group('attachments, groups', () {
    test('sends a 100 KB file through chunks', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      final data = random(100 * 1024);
      final m = await a.core.sendAttachment(b.id, file(data, 'image/png', null), 'image');
      await waitFor(() => m.status == 'delivered', 8000);
      expect(m.progress, 1);
      final got = await waitFor(() => withAtt(b, a.id), 8000);
      expect(got.att!.kind, 'image');
      expect(got.att!.mime, 'image/png');
      expect(got.att!.size, data.length);
      expect(got.att!.bytes, data);
      expect(await b.core.db.getBin('blobs', got.att!.attId!), data);
      expect(await a.core.db.getBin('blobs', m.att!.attId!), data);
    });

    test('rejects files over 20 MiB', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      expect(await codeOf(a.core.sendAttachment(b.id, file(Uint8List(21 * 1024 * 1024), 'video/mp4'), 'video')), 'too_big');
      expect(await codeOf(a.core.sendAttachment(b.id, file(Uint8List(5), 'video/mp4'), 'gif')), 'bad_kind');
    });

    test('group fan-out tracks delivered/total', () async {
      final a = await user('Alice'), b = await user('Bob'), c = await user('Carol');
      await a.core.addContactFromLink(b.link);
      await a.core.addContactFromLink(c.link);
      final chat = await a.core.createGroup('Trio', [b.id, c.id]);
      await waitFor(() => b.state.chats.any((x) => x.id == chat.id) && c.state.chats.any((x) => x.id == chat.id));
      final m = await a.core.sendText(chat.id, 'all');
      await waitFor(() => m.status == 'delivered');
      expect([m.delivered, m.total], [2, 2]);
      await waitFor(() => b.state.msgs(chat.id)?.firstOrNull?.text == 'all' && c.state.msgs(chat.id)?.firstOrNull?.text == 'all');
      final reply = await b.core.sendText(chat.id, 'from bob');
      await waitFor(() => reply.status == 'delivered');
      await waitFor(() => c.state.msgs(chat.id)!.length == 2 && a.state.msgs(chat.id)!.length == 2);
    });

    test('createGroup validates its input', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      expect(await codeOf(a.core.createGroup('   ', [b.id])), 'bad_group');
      expect(await codeOf(a.core.createGroup('Solo', [])), 'bad_group');
      expect(await codeOf(a.core.createGroup('Ghost', ['0' * 16])), 'no_contact');
      expect(await codeOf(a.core.createGroup('Many', [for (var i = 0; i < 31; i++) '$i'])), 'too_many');
    });
  });

  group('voice messages', () {
    test('carries the duration and the waveform to the receiver and bounds them', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      final wave = [for (var i = 0; i < 40; i++) (i * 6) % 256];
      final m = await a.core.sendAttachment(b.id, file(random(2000), 'audio/webm'), 'voice', duration: 3, wave: wave);
      await waitFor(() => m.status == 'delivered', 8000);
      final got = await waitFor(() => withAtt(b, a.id), 8000);
      expect(got.att!.kind, 'voice');
      expect(got.att!.mime, 'audio/webm');
      expect(got.att!.duration, 3);
      expect(got.att!.wave, wave);
      expect(m.att!.duration, 3);
    });

    test('drops an oversized waveform and a silly duration', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      final m = await a.core.sendAttachment(b.id, file(random(500), 'audio/webm'), 'voice', duration: 99999, wave: List.filled(500, 9));
      expect(m.att!.wave, isNull);
      expect(m.att!.duration, 3600);
      expect(m.att!.containsKey('url'), false);
    });
  });

  group('media from and to people who have not replied', () {
    test('blocks sending media until the other person answers, text is fine', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      final blob = file(random(300), 'image/png');
      expect(await codeOf(a.core.sendAttachment(b.id, blob, 'image')), 'media_locked');
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.state.contact(a.id)?.card);
      expect(await codeOf(a.core.sendAttachment(b.id, blob, 'image')), 'media_locked');
      await b.core.sendText(a.id, 'hello');
      await waitFor(() => a.state.contact(b.id)!.cardAck);
      final m = await a.core.sendAttachment(b.id, blob, 'image');
      await waitFor(() => m.status == 'delivered', 8000);
    });

    test('drops a media pointer from a stranger who wrote first until you reply', () async {
      final a = await user('Alice'), b = await user('Bob');
      final burner = await user('Burner');
      await burner.core.addContactFromLink(b.link);
      await burner.core.sendText(b.id, 'x');
      await waitFor(() => b.state.contact(burner.id)?.addedVia == 'link');
      await a.core.addContactFromLink(b.link);
      await a.core.sendText(b.id, 'hi');
      await waitFor(() => b.state.contact(a.id)?.card);
      a.state.contact(b.id)!.cardAck = true;
      final blob = file(random(300), 'image/png');
      final m = await a.core.sendAttachment(b.id, blob, 'image');
      await waitFor(() => m.status == 'delivered', 8000);
      await pause(200);
      expect((b.state.msgs(a.id) ?? const <Msg>[]).any((x) => x.att != null), false);
      await b.core.sendText(a.id, 'ok');
      await waitFor(() => b.state.contact(a.id)!.cardSent != 0);
      final m2 = await a.core.sendAttachment(b.id, blob, 'image');
      await waitFor(() => m2.status == 'delivered', 8000);
      await waitFor(() => (b.state.msgs(a.id) ?? const <Msg>[]).any((x) => x.att != null), 8000);
    });
  });

  group('replies and captions', () {
    test('quotes the replied text message on both sides', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      final first = await a.core.sendText(b.id, 'lunch at noon?');
      final got = await waitFor(() => b.state.msgs(a.id)?.where((x) => x.text == 'lunch at noon?').firstOrNull);
      final mine = await b.core.sendText(a.id, 'sure', got.id);
      expect(mine.re!['who'], a.id);
      expect(mine.re!['text'], 'lunch at noon?');
      expect(mine.re!['mid'], got.id);
      final back = await waitFor(() => a.state.msgs(b.id)?.where((x) => x.text == 'sure').firstOrNull);
      expect(back.re!['who'], a.id);
      expect(back.re!['text'], 'lunch at noon?');
      expect(back.re!['mid'], first.id);
      final again = await a.core.sendText(b.id, 'great', back.id);
      expect(again.re!['who'], b.id);
      expect(again.re!['text'], 'sure');
      final seen = await waitFor(() => b.state.msgs(a.id)?.where((x) => x.text == 'great').firstOrNull);
      expect(seen.re!['mid'], mine.id);
    });

    test('sends a caption with a photo and replies to a photo', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      final m = await a.core.sendAttachment(b.id, file(random(400), 'image/png'), 'image', caption: 'look!');
      await waitFor(() => m.status == 'delivered', 8000);
      final got = await waitFor(() => withAtt(b, a.id), 8000);
      expect(got.text, 'look!');
      final r = await b.core.sendText(a.id, 'nice one', got.id);
      expect(r.re!['kind'], 'image');
      expect(r.re!['text'], 'look!');
      expect(await codeOf(a.core.sendAttachment(b.id, file(random(50), 'image/png'), 'image', caption: 'x' * 1001)), 'too_long');
    });

    test('drops a malformed reply reference but keeps the message', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      a.mesh.sealHook = (tag, pt) {
        final o = Map<String, Object?>.from(jsonDecode(unutf8(pt)) as Map);
        if (o['t'] == 'msg') o['re'] = {'id': '../x', 'who': 'nope', 'text': 5};
        return a.mesh.sig.signalSeal(tag, utf8(jsonEncode(o)));
      };
      await a.core.sendText(b.id, 'hello there');
      final got = await waitFor(() => b.state.msgs(a.id)?.where((x) => x.text == 'hello there').firstOrNull);
      expect(got.re, isNull);
    });
  });

  group('unsending messages', () {
    test('removes a text message for both people', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      final m = await a.core.sendText(b.id, 'wrong chat');
      await waitFor(() => b.state.msgs(a.id)?.any((x) => x.text == 'wrong chat'));
      await a.core.unsendMessage(b.id, m.id);
      expect(a.state.msgs(b.id)!.any((x) => x.id == m.id), false);
      await waitFor(() => !b.state.msgs(a.id)!.any((x) => x.text == 'wrong chat'));
      expect(b.state.chats.firstWhere((c) => c.id == a.id).lastText, '');
    });

    test('only the author can unsend and a message that arrives after its unsend is dropped', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      final theirs = await a.core.sendText(b.id, 'keep me');
      await waitFor(() => b.state.msgs(a.id)?.length == 1);
      expect(await codeOf(b.core.unsendMessage(a.id, b.state.msgs(a.id)![0].id)), 'no_message');
      expect(b.state.msgs(a.id), hasLength(1));
      final held = <Uint8List>[];
      final seen = <String>[];
      var hold = true;
      a.mesh.sealHook = (tag, pt) {
        seen.add((jsonDecode(unutf8(pt)) as Map)['t'] as String);
        return a.mesh.sig.signalSeal(tag, pt);
      };
      a.mesh.sendHook = (pkt) async {
        if (hold && decodePacket(pkt).type == PacketType.data) {
          held.add(pkt);
          return 1;
        }
        return null;
      };
      final m = await a.core.sendText(b.id, 'late');
      await waitFor(() => seen.contains('msg'));
      await a.core.unsendMessage(b.id, m.id);
      await waitFor(() => held.length >= 2);
      hold = false;
      final ordered = seen.indexOf('msg') < seen.indexOf('unsend') ? [held[1], held[0]] : [held[0], held[1]];
      await a.mesh.rawSend(ordered[0]);
      await pause(100);
      await a.mesh.rawSend(ordered[1]);
      await pause(200);
      expect(b.state.msgs(a.id)!.any((x) => x.text == 'late'), false);
      expect(b.state.msgs(a.id)!.any((x) => x.text == 'keep me'), true);
      expect(theirs.text, 'keep me');
    });

    test('removes a photo and clears the quoted excerpt in replies', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      final m = await a.core.sendAttachment(b.id, file(random(300), 'image/png'), 'image', caption: 'secret pic');
      final got = await waitFor(() => withAtt(b, a.id), 8000);
      final reply = await b.core.sendText(a.id, 'what is this', got.id);
      await waitFor(() => a.state.msgs(b.id)?.any((x) => x.text == 'what is this'));
      expect(reply.re!['text'], 'secret pic');
      final attId = m.att!.attId!;
      await a.core.unsendMessage(b.id, m.id);
      await waitFor(() => !b.state.msgs(a.id)!.any((x) => x.att != null));
      final quoted = b.state.msgs(a.id)!.firstWhere((x) => x.text == 'what is this');
      expect(quoted.re!.containsKey('text'), false);
      expect(await a.core.db.getBin('blobs', attId), isNull);
    });
  });

  group('typing indicator and resend', () {
    final fast = {...timing, 'typing': 50, 'typingTtl': 400, 'resend': 50};

    Future<void> near(User a, User b) async {
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      connect(a.mesh, b.mesh);
      await waitFor(() => a.state.neighbors.firstOrNull?['card'] != null && b.state.neighbors.firstOrNull?['card'] != null);
    }

    test('shows that the other person is typing and clears it after a moment', () async {
      final a = await user('Alice', fast), b = await user('Bob', fast);
      await near(a, b);
      await a.core.sendTyping(b.id);
      await waitFor(() => typingOf(b, a.id, a.id));
      await waitFor(() => !anyTyping(b, a.id));
    });

    test('clears the indicator when the message arrives', () async {
      final slow = {...fast, 'typingTtl': 5000};
      final a = await user('Alice', slow), b = await user('Bob', slow);
      await near(a, b);
      await a.core.sendTyping(b.id);
      await waitFor(() => anyTyping(b, a.id));
      await a.core.sendText(b.id, 'done');
      await waitFor(() => !anyTyping(b, a.id));
    });

    test('does not send typing to someone who is not a direct neighbor', () async {
      final a = await user('Alice', fast), b = await user('Bob', fast);
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      await a.core.sendTyping(b.id);
      await pause(200);
      expect(anyTyping(b, a.id), false);
    });

    test('resends an undelivered message when the contact comes back into range', () async {
      final a = await user('Alice', fast), b = await user('Bob', fast);
      await a.core.addContactFromLink(b.link);
      await unlock(a, b);
      b.mesh.offline = true;
      final m = await a.core.sendText(b.id, 'later');
      await waitFor(() => m.status == 'out_of_range');
      b.mesh.offline = false;
      connect(a.mesh, b.mesh);
      await waitFor(() => m.status == 'delivered', 6000);
    });
  });

  group('chunks and expiry', () {
    test('drops chunks of an unannounced transfer after the pending TTL', () async {
      final b = await user('Bob');
      final ct = random(1000);
      final attId = random(16);
      final tag = unhex(b.state.profile!.tag);
      b.mesh.emit('packet', {'packet': encodePacket(type: PacketType.data, dest: tag, payload: chunkPayloadFor(attId, ct, 0, 2)), 'from': 'x'});
      await waitFor(() => b.core.pending.isNotEmpty);
      expect(b.core.pendingBytes(), 1000);
      expect(await b.core.db.keysByPrefix('chunks', hex(attId)), hasLength(1));
      final base = DateTime.now().millisecondsSinceEpoch;
      js.now = () => base + pendingTtl + 1000;
      await b.core.dropExpired();
      expect(b.core.pending, isEmpty);
      expect(await b.core.db.keysByPrefix('chunks', hex(attId)), isEmpty);
    });

    test('ignores malformed chunks and chunks past the limits', () async {
      final b = await user('Bob');
      final tag = unhex(b.state.profile!.tag);
      final attId = random(16);
      for (final p in [
        chunkPayloadFor(attId, Uint8List(0), 0, 1),
        chunkPayloadFor(attId, random(10), 0, maxChunks + 1),
        chunkPayloadFor(attId, random(10), 5, 2),
        Uint8List.fromList([2, 1, 2, 3]),
      ]) {
        b.mesh.emit('packet', {'packet': encodePacket(type: PacketType.data, dest: tag, payload: p), 'from': 'x'});
      }
      await pause(200);
      expect(b.core.pending, isEmpty);
    });
  });

  group('developer logs', () {
    test('sends a log to a contact and deletes it again', () async {
      final a = await user('Alice'), b = await user('Bob');
      await a.core.addContactFromLink(b.link);
      final text = 'line\n' * 200;
      final r = await a.core.sendDevLog(b.id, text);
      expect(r.ok, true);
      final got = await waitFor(() => b.state.devLogs.firstOrNull);
      expect(got.text, text);
      expect(got.from, a.id);
      expect(got.name, 'Alice');
      b.core.deleteDevLog(got.id);
      expect(b.state.devLogs, isEmpty);
      expect(await codeOf(a.core.sendDevLog('0' * 16, 'x')), 'no_chat');
    });
  });
}

Uint8List chunkPayloadFor(Uint8List attId, Uint8List ct, int index, int total) => concat([
  [2],
  attId,
  u32(index),
  u32(total),
  ct,
]);
