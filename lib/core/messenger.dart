import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../crypto/attachment.dart';
import '../crypto/call_frame.dart';
import '../crypto/db.dart';
import '../crypto/identity.dart';
import '../crypto/vault.dart';
import '../i18n.dart';
import '../mesh/bridge.dart' hide mesh;
import '../mesh/packet.dart';
import '../util/avatar.dart';
import '../util/bytes.dart';
import '../util/js.dart';
import 'call_audio.dart';
import 'calls.dart';
import 'diag.dart';
import 'obs.dart';
import 'state.dart';

part 'messenger_msgs.dart';
part 'messenger_contacts.dart';

const maxText = 1000;
const maxFile = 20 * 1024 * 1024;

const maxPending = 100 * 1024 * 1024;
const pendingTtl = 24 * 3600 * 1000;
const maxChunks = 700;
const maxGroup = 30;
const maxWave = 64;
const reText = 120;
const maxTokens = 30;
const maxUnsent = 1000;
const maxUsed = 200;
final tokenRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
const maxScan = 20;
const maxSearch = 50;
const rings = [1, 3, 8, 255];
const maxHellos = 64;
const chunkWindow = 4;
final idRe = RegExp(r'^[0-9A-HJKMNP-TV-Z]{16}$');
final wireIdRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
const kinds = ['image', 'video', 'voice'];
const resetGap = 10 * 60 * 1000;
const typingTag = 2;
const dlogBodyMax = 45000;
const defaultTiming = <String, int>{
  'ack': 60000,
  'chunkAck': 20000,
  'tries': 4,
  'retry': 2000,
  'resend': 15000,
  'typing': 3000,
  'typingTtl': 5000,
  'discover': 30000,
  'quiet': 10000,
  'ring': 8000,
  'quietRing': 3000,
  'helloRetry': 3000,
  'verify': 60000,
  'proof': 5000,
  'poll': 500,
};

typedef TxResult = ({bool ok, int? hops, bool error});
typedef Opened = ({String tag, Uint8List ik, Uint8List plaintext});
typedef Notice = ({String title, String body, String? chatId});
typedef Notifier = void Function(Notice n);
typedef AttFile = ({Uint8List bytes, String type, num? duration});
typedef Own = ({Uint8List bundle, Uint8List ik});

const TxResult txFail = (ok: false, hops: null, error: false);
const TxResult txError = (ok: false, hops: null, error: true);

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

String pktId(Uint8List pkt) => hex(Uint8List.sublistView(pkt, 4, 20));

final _mimeRe = RegExp(r'^(image|video|audio)/[a-z0-9.+-]{1,40}$');

String safeMime(Object? m) {
  final base = (truthy(m) ? '$m' : '').split(';')[0].trim().toLowerCase();
  return _mimeRe.hasMatch(base) ? base : 'application/octet-stream';
}

String fmtDur(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

Map<String, Object?> wireRe(Map<String, Object?> r) => {
  'id': r['id'],
  'who': r['who'],
  if (truthy(r['text'])) 'text': r['text'],
  if (truthy(r['kind'])) 'kind': r['kind'],
};

Future<Vault> createVault(Mesh mesh) async {
  final k = await mesh.getDbKey();
  return Vault(k.key, insecure: k.insecure);
}

Map<String, Object?> _obj(Object? v) => Map<String, Object?>.from(v as Map);

class Me {
  Me({required this.ik, required this.tag, required this.id, required this.name, required this.avatar, required this.avVer, required this.card});

  final Uint8List ik;
  final Uint8List tag;
  final String id;
  final String name;
  final String avatar;
  final String avVer;
  final Uint8List card;
}

class CoreAudio {
  const CoreAudio({required this.supported, required this.create, this.ensureMic});

  final bool Function() supported;
  final Future<CallAudio> Function() create;
  final Future<void> Function()? ensureMic;
}

Future<CallAudio> _createAudio() => createAudio();

const defaultAudio = CoreAudio(supported: audioSupported, create: _createAudio);

class DiscoverRound {
  DiscoverRound(this.id, this.quiet, this.finish);

  final String id;
  final int quiet;
  final void Function() finish;
  bool dead = false;
  Timer? quietTimer;

  void bump() {
    if (!dead) return;
    quietTimer?.cancel();
    quietTimer = Timer(Duration(milliseconds: quiet), finish);
  }

  void settle() {
    dead = true;
    bump();
  }
}

abstract class _Base {
  _Base({
    required this.mesh,
    this.dbName = 'ripplo',
    RipploState? state,
    Notifier? notifier,
    Map<String, int> timing = const {},
    this.audio = defaultAudio,
    this.raw,
  }) : state = state ?? RipploState(),
       timing = {...defaultTiming, ...timing} {
    this.notifier = notifier ?? (n) => fire(mesh.notify(n.title, n.body, n.chatId));
    if (mesh.isNative) setDiagSink(mesh.usbLog);
    calls = Calls(
      state: this.state,
      timing: {
        for (final e in const {'ring': 'callRing', 'silence': 'callSilence', 'hold': 'callHold', 'warn': 'callWarn', 'gone': 'callGone'}.entries)
          if (timing[e.value] != null) e.key: timing[e.value]!,
      },
      supported: audio.supported,
      newAudio: audio.create,
      ensureMic: audio.ensureMic ?? _ensureMic,
      hasNeighbor: (id, node) => neighborOf(id, node) != null,
      sendMedia: (id, bytes, node) {
        final nb = neighborOf(id, node);
        if (nb == null) return false;
        fire(mesh.sendApp(nb.node, bytes));
        return true;
      },
      signal: (id, body) async {
        final c = contactOf(id);
        if (c == null || truthy(c.request)) return false;
        try {
          return (await transmit(await buildPacket(c, body))).ok;
        } catch (_) {
          return false;
        }
      },
      notify: (id) {
        if (!silentNow) this.notifier((title: contactOf(id)?.name ?? '', body: t('incomingCall'), chatId: null));
      },
      log: (id, reason, ms) {
        if (contactOf(id) == null) return;
        final text = reason == 'ended' ? t('callLog', {'time': fmtDur(ms)}) : t('call_$reason');
        final m = addMsg({'id': hex(random(16)), 'chatId': id, 'from': 'system', 'ts': now(), 'status': 'received', 'text': text});
        touchChat(id, text, m.ts);
      },
    );
  }

  final Mesh mesh;
  final String dbName;
  final RipploState state;
  late final Notifier notifier;
  final Map<String, int> timing;
  final CoreAudio audio;
  final RawStore? raw;
  late final Calls calls;

  Db? dbOrNull;
  Db get db => dbOrNull!;
  late Me me;
  late Own own;
  List<Unsub> unsubs = [];
  Future<void> queue = Future<void>.value();
  Map<String, Map<String, Object?>> pending = {};
  List<String> tokenPending = [];
  Map<String, String> tokenUsed = {};
  Set<String> unsent = {};
  List<Map<String, Object?>> unsends = [];
  bool flushing = false;
  bool silentNow = false;
  String searchText = '';
  ObsList<Person>? peopleBase;
  DiscoverRound? discover;
  final loaded = <String>{};
  final waits = <String, ({Completer<TxResult> done, Timer timer})>{};
  final proofs = <String, ({String node, void Function(Uint8List mac) resolve})>{};
  final running = <String, Future<bool>>{};
  final seenIds = <String>{};
  final lastReset = <String, int>{};
  final helloCards = <String, Map<String, Object?>>{};
  final greeted = <String>{};
  final byed = <String>{};
  final lastResend = <String, int>{};
  final lastTyping = <String, int>{};
  final typingTimers = <String, Timer>{};

  int tm(String k) => timing[k]!;

  Contact? contactOf(String? id) => id == null ? null : state.contact(id);

  bool isFrame(Uint8List payload) => payload.isNotEmpty && payload[0] == frameTag;

  bool validAvatar(Object? av) => av == '' || isAvatar(av);

  bool chunkFits(Uint8List bytes) => bytes.isNotEmpty && bytes.length <= chunkSize;

  Future<Map<String, Object?>> packLog(String text) async => {'z': b64(gzip.encode(utf8(text)))};

  Future<String?> unpackLog(Map<String, Object?> body) async {
    final raw = body['raw'], z = body['z'];
    if (raw is String) return raw;
    if (z is! String) return null;
    return unutf8(gzip.decode(unb64(z)));
  }

  Chat? chatOf(String id) {
    for (final c in state.chats) {
      if (c.id == id) return c;
    }
    return null;
  }

  Future<void> _ensureMic() async {
    if (!mesh.isNative) return;
    final p = await mesh.checkPermissions();
    final mic = p['microphone'];
    if (truthy(mic) && mic != 'granted') {
      final r = await mesh.requestPermissions();
      if (r['microphone'] != 'granted') throw StateError('mic');
    }
  }

  void enqueue(Future<void> Function() fn) {
    queue = queue.then((_) => fn()).then<void>((_) {}, onError: (Object _) {});
  }

  void later(int ms, void Function() fn) {
    Timer(Duration(milliseconds: ms), fn);
  }

  Future<void> persistContact(Contact c) => db.put('contacts', c.id, c);

  Future<void> persistChat(Chat c) => db.put('chats', c.id, c);

  Future<void> persistMsg(Msg m) {
    if (m.unsent) return Future<void>.value();
    final att = m['att'];
    return db.putMsg({
      ...m,
      if (att is Map) 'att': {...att}..remove('bytes')..remove('path'),
    });
  }

  Uint8List tagOf(Contact c) => deriveIds(unb64(c.ik!)).tag;

  String? nodeOf(String id) {
    final c = contactOf(id);
    return c != null && truthy(c.ik) ? hex(tagOf(c)) : null;
  }

  Future<void> persistTokens() => db.put('kv', 'tokens', {'pending': tokenPending, 'used': tokenUsed});

  bool consented(Contact? c) => c != null && !truthy(c.request) && (c.addedVia != 'incoming' || truthy(c['cardSent']));

  bool canCall(Contact? c) => consented(c);

  Neighbor? neighborOf(String id, String? node) {
    final ns = state.neighbors;
    if (truthy(node)) {
      for (final n in ns) {
        if (n.node == node) return n;
      }
    }
    for (final n in ns) {
      final card = n['card'];
      if (card is Map && card['id'] == id) return n;
    }
    final cn = contactOf(id)?['node'];
    for (final n in ns) {
      if (truthy(n['node']) && n.node == cn) return n;
    }
    return null;
  }

  String? knownName(String id) {
    for (final n in state.neighbors) {
      final card = n['card'];
      if (card is Map && card['id'] == id) return card['name'] as String?;
    }
    for (final p in state.people) {
      if (p.id == id) return p.name;
    }
    return null;
  }

  String? routeChat(String f, Map<String, Object?> msg) {
    if (!msg.containsKey('g')) return f;
    final g = msg['g'];
    final chat = g is String ? chatOf(g) : null;
    return chat != null && chat.type == 'group' && (chat.members ?? const []).contains(f) ? g as String : null;
  }

  String? groupOf(String chatId) => chatOf(chatId)?.type == 'group' ? chatId : null;

  String? captionOf(Object? v) => v is String && v.length <= maxText && v.trim().isNotEmpty ? v : null;

  void touchChat(String chatId, String text, int ts, [int unread = 0, String? lastKind]) {
    final chat = chatOf(chatId);
    if (chat == null) return;
    chat['lastText'] = text;
    chat['lastKind'] = lastKind;
    chat['lastTs'] = ts;
    chat['unread'] = chat.unread + unread;
    state.chats.sort((a, b) => b.lastTs.compareTo(a.lastTs));
    fire(persistChat(chat));
  }

  Chat ensureChat(String id, String type, String name, [List<String>? members]) {
    var chat = chatOf(id);
    if (chat == null) {
      state.chats.add(Chat(state.map({'id': id, 'type': type, 'name': name, 'lastText': '', 'lastTs': now(), 'unread': 0, 'members': ?members})));
      chat = state.chats.last;
    } else {
      chat.name = name;
      if (members != null) chat.members = members;
    }
    fire(persistChat(chat));
    return chat;
  }

  Msg addMsg(Map<String, Object?> m) {
    final chatId = m['chatId'] as String;
    if (state.msgs(chatId) == null) state.messages[chatId] = state.list<Msg>();
    final list = state.msgs(chatId)!;
    list.add(Msg(state.map(m)));
    final out = list.last;
    fire(persistMsg(out));
    return out;
  }

  List<String> recipientsOf(String chatId) {
    var chat = chatOf(chatId);
    final peer = contactOf(chatId);
    if (truthy(peer?.request)) throw RipploError('no_chat');
    if (chat == null && peer != null) chat = ensureChat(chatId, 'direct', peer.name);
    if (chat == null) throw RipploError('no_chat');
    return chat.type == 'group' ? [for (final x in chat.members ?? const []) x as String] : [chatId];
  }

  void loadMe(String name, [String avatar = '']) {
    final ids = deriveIds(own.ik);
    me = Me(
      ik: own.ik,
      tag: ids.tag,
      id: ids.ripploId,
      name: name,
      avatar: avatar,
      avVer: avatar.isNotEmpty ? cut(hex(c.sha256.convert(utf8(avatar)).bytes), 0, 8) : '',
      card: encodeCard(name, own.bundle),
    );
    state.profile = {'name': name, 'ripploId': ids.ripploId, 'tag': hex(ids.tag), 'avatar': avatar};
  }

  Future<void> init() async {
    final vault = await createVault(mesh);
    state.insecureStorage = vault.insecure;
    state.devCrypto = mesh.devCrypto;
    own = await mesh.signalInit();
    dbOrNull = await openDb(dbName, vault, mesh, raw: raw);
    final settings = await db.get('kv', 'settings');
    if (settings is Map) {
      for (final e in settings.entries) {
        state.settings['${e.key}'] = e.value;
      }
    }
    state.contacts = {
      for (final (id, v) in await db.all('contacts')) id: {..._obj(v), 'verifyState': 'idle'},
    };
    state.chats = [for (final (_, v) in await db.all('chats')) v];
    state.chats.sort((a, b) => b.lastTs.compareTo(a.lastTs));
    final p = await db.get('kv', 'pending');
    pending = p is Map ? {for (final e in p.entries) '${e.key}': _obj(e.value)} : {};
    final tk = await db.get('kv', 'tokens');
    tokenPending = tk is Map && tk['pending'] is List ? [for (final x in tk['pending'] as List) '$x'] : [];
    tokenUsed = tk is Map && tk['used'] is Map ? {for (final e in (tk['used'] as Map).entries) '${e.key}': '${e.value}'} : {};
    final us = await db.get('kv', 'unsent');
    unsent = {if (us is List) for (final x in us) '$x'};
    final dl = await db.get('kv', 'devLogs');
    state.devLogs = dl is List ? dl : const [];
    final un = await db.get('kv', 'unsends');
    unsends = [if (un is List) for (final x in un) _obj(x)];
    final pr = await db.get('kv', 'peopleRefreshedAt');
    state.peopleRefreshedAt = pr is num ? pr.toInt() : 0;
    final profile = await db.get('kv', 'profile');
    state.needsOnboarding = profile == null;
    if (profile is Map) {
      loadMe(profile['name'] as String, (profile['avatar'] as String?) ?? '');
      await dropExpired();
      await start();
      if (await db.get('kv', 'needsSessionReset') != null) {
        for (final id in state.contacts.keys.toList()) {
          final c = contactOf(id);
          if (c == null) continue;
          try {
            await resetSession(c);
          } catch (_) {}
        }
        await db.del('kv', 'needsSessionReset');
      }
    }
    state.ready = true;
  }

  Future<void> start() async {
    unsubs.add(mesh.on('packet', (e) => onPacket(e['packet'] as Uint8List, e['from'] as String?)));
    unsubs.add(mesh.on('neighbor', onNeighbor));
    unsubs.add(mesh.on('opened', (rec) => enqueue(() => handleOpened(rec))));
    await mesh.start(me.tag);
    for (final n in await mesh.getNeighbors()) {
      onNeighbor({...n, 'up': true});
    }
    for (final item in await mesh.drainInbox()) {
      switch (item) {
        case InboxOpened(:final opened):
          enqueue(() => handleOpened(opened));
        case InboxPacket(:final packet, :final from):
          onPacket(packet, from);
      }
    }
    fire(flushUnsends());
  }

  Future<void> close() async {
    for (final u in unsubs) {
      u();
    }
    unsubs = [];
    for (final w in waits.values) {
      w.timer.cancel();
    }
    waits.clear();
    for (final tt in typingTimers.values) {
      tt.cancel();
    }
    typingTimers.clear();
    await dbOrNull?.close();
  }

  void onNeighbor(Map<String, Object?> e) {
    final node = e['node'] as String;
    final up = e['up'] == true;
    final medium = e['medium'], kbps = e['kbps'], rttMs = e['rttMs'];
    diagLog('neighbor ${up ? 'up ' : 'down '}${cut(node, 0, 8)} $medium ${kbps}kbps');
    final i = state.neighbors.indexWhere((n) => n.node == node);
    if (!up) {
      if (i >= 0) state.neighbors.removeAt(i);
      helloCards.remove(node);
      greeted.remove(node);
      byed.remove(node);
      return;
    }
    if (i >= 0) {
      final n = state.neighbors[i];
      n['medium'] = medium;
      n['kbps'] = kbps;
      n['rttMs'] = rttMs;
    } else {
      state.neighbors.add(Neighbor(state.map({'node': node, 'medium': medium, 'kbps': kbps, 'rttMs': rttMs})));
      askCard(node, 0);
      fire(flushUnsends());
    }
    fire(
      mesh.getNeighbors().then<void>((all) {
        Map<String, Object?>? fresh;
        for (final x in all) {
          if (x['node'] == node) fresh = x;
          if (fresh != null) break;
        }
        final cur = state.neighbors.where((n) => n.node == node).firstOrNull;
        if (fresh?['links'] != null && cur != null) cur['links'] = fresh!['links'];
      }),
    );
    final nb = state.neighbors.firstWhere((n) => n.node == node);
    if (nb['card'] == null && helloCards.containsKey(node)) nb['card'] = helloCards[node];
    if (i < 0) sendHello(node, nb['card'] == null);
  }

  void onPacket(Uint8List bytes, String? from) {
    Packet p;
    try {
      p = decodePacket(bytes);
    } catch (_) {
      return;
    }
    final id = hex(p.id);
    switch (p.type) {
      case PacketType.data:
        if (seenIds.contains(id)) return;
        seenIds.add(id);
        if (seenIds.length > 2000) seenIds.remove(seenIds.first);
        if (p.payload.isEmpty) return;
        if (p.payload[0] == 2) {
          enqueue(() => onChunk(p));
        } else if (p.payload[0] == 1 || (mesh.devCrypto && p.payload[0] == 0xee)) {
          enqueue(() => onSealed(p.payload));
        }
      case PacketType.ack:
        settle(hex(p.dest), (ok: true, hops: p.hops, error: false));
      case PacketType.deadEnd:
        final d = discover;
        if (d != null && hex(p.dest) == d.id) {
          d.settle();
        } else {
          settle(hex(p.dest), txFail);
        }
      case PacketType.discover:
        onDiscover(p);
      case PacketType.reply:
        onReply(p);
      case PacketType.app:
        if (from != null) fire(onApp(p, from));
    }
  }

  Future<TxResult> transmit(Uint8List pkt, [int? ms]) {
    final id = pktId(pkt);
    final done = Completer<TxResult>();
    final timer = Timer(Duration(milliseconds: ms ?? tm('ack')), () => settle(id, txFail));
    waits[id] = (done: done, timer: timer);
    mesh.send(pkt).then<void>((_) {}, onError: (Object _) => settle(id, txError));
    return done.future;
  }

  void settle(String id, TxResult result) {
    final w = waits.remove(id);
    if (w == null) return;
    w.timer.cancel();
    w.done.complete(result);
  }

  Future<Uint8List> buildPacket(Contact c, Map<String, Object?> extra, [bool bare = false]) async {
    var obj = extra;
    if (!bare) {
      if (!c.cardAck) {
        obj = {...extra, 'c': b64(me.card), if (truthy(c['token'])) 'tk': c['token']};
        if (!truthy(c['cardSent'])) {
          c['cardSent'] = now();
          fire(persistContact(c));
        }
      }
      if ((truthy(me.avatar) || truthy(c['avSent'])) && c['avSent'] != me.avVer) {
        obj = {...obj, 'av': me.avatar};
        c['avSent'] = me.avVer;
        fire(persistContact(c));
      }
      if (c['nameSent'] != me.name) {
        obj = {...obj, 'nm': me.name};
        c['nameSent'] = me.name;
        fire(persistContact(c));
      }
      if (c['verification'] != 'none' && c['vfSent'] != c['verification']) {
        obj = {...obj, 'vf': c['verification']};
        c['vfSent'] = c['verification'];
        fire(persistContact(c));
      }
    }
    final payload = await mesh.signalSeal(hex(tagOf(c)), utf8(jsonEncode(obj)));
    return encodePacket(type: PacketType.data, dest: tagOf(c), payload: payload);
  }

  Future<void> startCall(String id) async {
    if (!canCall(contactOf(id))) throw RipploError('call_no_contact');
    return calls.start(id);
  }

  Future<void> acceptCall() => calls.accept();

  void hangUp() => calls.hangup();

  void setMuted(bool muted) => calls.setMuted(muted);

  void tellVerified(Contact c) {
    if (!consented(c)) return;
    void failed() => c.vfSent = '?';
    fire(
      buildPacket(c, {'t': 'profile'}).then((p) => transmit(p)).then<void>((r) {
        if (!r.ok) failed();
      }).catchError((Object _) => failed()),
    );
  }

  String newInviteLink() {
    final raw = random(8);
    tokenPending.add(b64url(raw));
    if (tokenPending.length > maxTokens) tokenPending.removeAt(0);
    fire(persistTokens());
    return encodeLink(me.card, raw);
  }

  String myInviteLink() => newInviteLink();

  Future<void> redeem(String f, String tk) async {
    final i = tokenPending.indexOf(tk);
    if (i >= 0) {
      tokenPending.removeAt(i);
      tokenUsed[tk] = f;
      if (tokenUsed.length > maxUsed) tokenUsed.remove(tokenUsed.keys.first);
      await persistTokens();
    } else if (tokenUsed[tk] != f) {
      return;
    }
    final c = contactOf(f);
    if (c != null && !truthy(c.request) && c.addedVia == 'incoming') {
      c['addedVia'] = 'link';
      await persistContact(c);
    }
  }

  Future<void> createProfile(String name) async {
    final clean = cleanName(name);
    if (clean.isEmpty) throw RipploError('bad_name');
    await db.put('kv', 'profile', {'name': clean});
    loadMe(clean);
    state.needsOnboarding = false;
    await start();
  }

  void pushProfile() {
    for (final n in state.neighbors.toList()) {
      sendHello(n.node, false);
    }
    for (final id in state.contacts.keys.toList()) {
      final c = contactOf(id);
      if (c == null || !consented(c)) continue;
      void failed() {
        c.avSent = '?';
        c.nameSent = '?';
        c.vfSent = '?';
      }

      fire(
        buildPacket(c, {'t': 'profile'}).then((p) => transmit(p)).then<void>((r) {
          if (!r.ok) failed();
        }).catchError((Object _) => failed()),
      );
    }
  }

  Future<void> setAvatar(String? avatar) async {
    if (truthy(avatar) && !isAvatar(avatar)) throw RipploError('bad_avatar');
    loadMe(me.name, avatar ?? '');
    await db.put('kv', 'profile', {'name': me.name, 'avatar': me.avatar});
    pushProfile();
  }

  Future<void> setName(String name) async {
    final clean = cleanName(name);
    if (clean.isEmpty) throw RipploError('bad_name');
    if (clean == me.name) return;
    loadMe(clean, me.avatar);
    await db.put('kv', 'profile', {'name': me.name, 'avatar': me.avatar});
    pushProfile();
  }

  void sendHello(String node, bool ask) {
    if (state.settings.hidden) {
      final nb = state.neighbors.where((n) => n.node == node).firstOrNull;
      final card = nb == null || !truthy(nb['card']) ? helloCards[node] : nb['card'];
      final id = card is Map ? card['id'] : null;
      final c = id is String ? contactOf(id) : null;
      if (!truthy(id) || c == null || truthy(c.request)) return;
    }
    greeted.add(node);
    diagLog('hello out ${cut(node, 0, 8)}${ask ? ' ask' : ''}');
    fire(mesh.sendApp(node, utf8(jsonEncode({'t': 'hello', 'card': b64(me.card), if (ask) 'r': 1}))));
  }

  void askCard(String node, int n) {
    final ms = n >= 20 ? 60000 : min(tm('helloRetry') * (1 << n), 60000);
    later(ms, () {
      final nb = state.neighbors.where((x) => x.node == node).firstOrNull;
      if (nb == null || truthy(nb['card']) || byed.contains(node)) return;
      sendHello(node, true);
      askCard(node, n + 1);
    });
  }

  Future<bool> resetSession(Contact c) async {
    if (!truthy(c.card) || now() - (lastReset[c.id] ?? 0) < resetGap) return false;
    lastReset[c.id] = now();
    final v = checkCard(unb64(c.card!));
    try {
      await mesh.signalForget(hex(tagOf(c)));
    } catch (_) {}
    await mesh.signalAddContact(v.bundle);
    fire(buildPacket(c, {'t': 'reset'}).then((p) => transmit(p)));
    return true;
  }

  Future<Map<String, Object?>> restoreBackup(String code) async {
    final r = await mesh.backupRestore(code);
    final d = await openDb(dbName, await createVault(mesh), mesh, raw: raw);
    await d.put('kv', 'needsSessionReset', {'at': now()});
    await d.close();
    return r;
  }

  Future<void> deleteChat(String chatId) async {
    for (final m in await db.msgs(chatId)) {
      final att = m['att'];
      if (att is Map && att['attId'] is String) await db.del('blobs', att['attId'] as String);
      await db.delMsg(m['id'] as String);
    }
    state.messages.remove(chatId);
    loaded.remove(chatId);
    state.chats = state.chats.where((c) => c.id != chatId).toList();
    await db.del('chats', chatId);
  }

  Future<void> deleteContact(String id) async {
    await deleteChat(id);
    final c = contactOf(id);
    state.contacts.remove(id);
    await db.del('contacts', id);
    if (c != null && c.ik != null) {
      try {
        await mesh.signalForget(hex(tagOf(c)));
      } catch (_) {}
    }
  }

  Future<void> saveSettings(Map<String, Object?> patch) async {
    for (final k in const ['autoUpdate', 'backgroundRelay', 'appLock', 'hidden', 'dev']) {
      if (patch[k] is bool) state.settings[k] = patch[k];
    }
    if (patch['hidden'] == false) {
      for (final n in state.neighbors.toList()) {
        sendHello(n.node, !truthy(n['card']));
      }
    }
    if (patch['hidden'] == true) {
      for (final n in state.neighbors.toList()) {
        final card = n['card'];
        final c = card is Map ? contactOf(card['id'] as String?) : null;
        if (c == null || truthy(c.request)) fire(mesh.sendApp(n.node, utf8('{"t":"bye"}')));
      }
    }
    await db.put('kv', 'settings', {...state.settings});
  }

  ({Msg m, List<String> recips}) newOutgoing(String chatId, Map<String, Object?> extra);
  Future<void> fanout(Msg m, Map<String, Object?> body, List<String> recips);
  Map<String, Object?> textBody(Msg m, String? group);
  Map<String, Object?>? localRef(String chatId, String localId);
  Map<String, Object?>? parseRe(Object? raw);
  Future<({bool ok, int? hops})> sendDevLog(String to, String text);
  void deleteDevLog(String id);
  Future<Msg> sendText(String chatId, Object? text, [String? replyTo]);
  Future<Msg> sendAttachment(String chatId, AttFile file, String kind, {num? duration, List<Object?>? wave, Object? caption, String? replyTo});
  Future<void> runAttachment(Msg m, Uint8List bytes, List<String> recips);
  Future<void> retry(String msgId);
  void resendFor(String id);
  void clearTyping(String chatId, String from);
  void onTyping(Contact c, Map<String, Object?> msg);
  Future<void> sendTyping(String chatId);
  Future<void> onAppMessage(String f, Object? msg);
  Future<void> receive(Map<String, Object?> m, String preview, [String? notifyBody]);
  Future<void> onGroup(String f, Map<String, Object?> msg);
  Future<void> removeMessage(String chatId, String localId);
  Future<void> flushUnsends();
  Future<void> unsendMessage(String chatId, String localId);
  Future<ObsList<Msg>> loadMessages(String chatId);
  void markRead(String chatId);
  Future<Chat> createGroup(String name, List<String> memberIds);
  Future<void> dropExpired();
  Future<void> discard(String aid);
  int pendingBytes();
  Future<void> onChunk(Packet p);
  Future<void> tryFinish(String aid);

  Future<void> onSealed(Uint8List payload);
  Future<void> handleOpened(Map<String, Object?> rec);
  Future<void> processOpened(Opened r, bool silent);
  Future<void> processOpenedInner(Opened r);
  Future<void> onOpenFailed(Object e);
  Future<Contact> addContact({required String id, required String name, required String ik, required String? card, required String addedVia, String? request, String? token});
  Future<Contact> learnCard(ParsedCard v, String via, [String? token]);
  void markConflicts(String name, String id);
  Future<Contact?> addCard(Uint8List raw, String via, [String? token]);
  Future<Contact?> addContactFromLink(String text, [String via = 'link']);
  Future<void> becomeContact(Contact c, String via);
  Future<Contact?> invite(Person person);
  Future<Contact?> acceptRequest(String id);
  Future<void> declineRequest(String id);
  Future<void> onApp(Packet p, String from);
  Future<String> proveOnce(Contact c, String node);
  Future<bool> verifyNearby(String id);
  Future<bool> setVerified(String id, String level);
  Future<bool> verifyByQr(String id, Object? scanned);
  Future<void> markVerified(String id);
  Future<String> safetyNumber(String id);
  Future<void> discoverRound({required Map<String, Object?> payload, required int timeout, required int quiet});
  Future<void> refreshPeople();
  Future<void> searchPeople(Object? raw);
  void onReply(Packet p);
  void onDiscover(Packet p);
}

class Core extends _Base with _Msgs, _Contacts {
  Core({required super.mesh, super.dbName, super.state, super.notifier, super.timing, super.audio, super.raw});
}
