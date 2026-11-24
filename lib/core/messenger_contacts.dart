part of 'messenger.dart';

final _jsSpace = RegExp(r'[\s   -     　﻿]+');
final _digits60 = RegExp(r'^\d{60}$');

mixin _Contacts on _Base {
  Iterable<Contact> get _allContacts => [for (final v in state.contacts.values) Contact(v as ObsMap)];

  @override
  Future<void> onSealed(Uint8List payload) async {
    Opened r;
    try {
      r = await mesh.signalOpen(payload);
    } catch (e) {
      return onOpenFailed(e);
    }
    await processOpened(r, false);
  }

  @override
  Future<void> handleOpened(Map<String, Object?> rec) async {
    Opened r;
    try {
      r = (tag: '${rec['tag']}', ik: unb64(rec['ik'] as String), plaintext: unb64(rec['plaintext'] as String));
    } catch (_) {
      return;
    }
    await processOpened(r, truthy(rec['notified']));
  }

  @override
  Future<void> processOpened(Opened r, bool silent) async {
    silentNow = silent;
    try {
      await processOpenedInner(r);
    } finally {
      silentNow = false;
    }
  }

  @override
  Future<void> processOpenedInner(Opened r) async {
    final ids = deriveIds(r.ik);
    final f = ids.ripploId;
    if (hex(ids.tag) != r.tag || f == me.id) return;
    final msg = jsonDecode(unutf8(r.plaintext));
    final m = msg is Map ? Map<String, Object?>.from(msg) : null;
    if (m?['t'] == 'typing') {
      final peer = contactOf(f);
      if (peer != null && !truthy(peer.request)) onTyping(peer, m!);
      return;
    }
    if (contactOf(f) == null) {
      final asking = m?['t'] == 'invite';
      if (asking && state.settings.hidden) return;
      final known = knownName(f);
      await addContact(id: f, name: truthy(known) ? known! : 'Ripplo ${cut(f, 0, 4)}', ik: b64(r.ik), card: null, addedVia: 'incoming', request: asking ? 'in' : null);
    }
    final c = contactOf(f)!;
    final fresh = c.request == 'in' && !truthy(c['notified']);
    if (truthy(c.cardSent) && !c.cardAck) {
      c.cardAck = true;
      c.token = null;
      fire(persistContact(c));
    }
    final tk = m?['tk'];
    if (tk is String && tokenRe.hasMatch(tk)) await redeem(f, tk);
    final av = m?['av'];
    if (av is String && validAvatar(av) && (c.avatar ?? '') != av) {
      c.avatar = av;
      await persistContact(c);
    }
    final mc = m?['c'];
    if (mc is String && !truthy(c.card)) {
      try {
        final v = checkCard(unb64(mc));
        if (v.id == f) await learnCard(v, 'incoming');
      } catch (_) {}
    }
    if (mc is String && truthy(c.card) && c.cardAck && !truthy(c.request)) {
      c.avSent = null;
      c.nameSent = null;
      c.vfSent = null;
      tellVerified(c);
    }
    final vf = m?['vf'];
    if (vf is String && const ['nearby', 'qr', 'manual'].contains(vf) && c.peerVerified?['level'] != vf) {
      c.peerVerified = {'level': vf, 'at': now()};
      await persistContact(c);
    }
    final nmRaw = m?['nm'];
    final nm = nmRaw is String ? cleanName(nmRaw) : '';
    if (nm.isNotEmpty && nm != c.name) {
      c.name = nm;
      if (!truthy(c.request)) ensureChat(c.id, 'direct', nm);
      markConflicts(nm, c.id);
      await persistContact(c);
    }
    if (c.request == 'in') {
      if (m?['t'] != 'invite') return;
      if (fresh) {
        c['notified'] = true;
        await persistContact(c);
        if (!silentNow) notifier((title: t('inviteNotifyTitle'), body: t('inviteNotifyBody', {'name': c.name}), chatId: null));
      }
      return;
    }
    if (c.request == 'out') {
      if (m?['t'] == 'decline') {
        await deleteContact(f);
        return;
      }
      await becomeContact(c, 'people');
      if (m?['t'] == 'invite') fire(buildPacket(c, {'t': 'accept'}).then((p) => transmit(p)));
    }
    await onAppMessage(f, msg);
  }

  @override
  Future<void> onOpenFailed(Object e) async {
    if (e is! MeshError) return;
    final data = e.data;
    final raw = data is Map ? data['tag'] : null;
    final tag = raw is String ? raw : null;
    if (!const ['bad_message', 'no_session'].contains(e.code) || !truthy(tag)) return;
    Contact? c;
    for (final x in _allContacts) {
      if (hex(tagOf(x)) == tag) {
        c = x;
        break;
      }
    }
    if (c == null || !(await resetSession(c))) return;
    final text = t('undecryptable', {'name': c.name});
    final m = addMsg({'id': hex(random(16)), 'chatId': c.id, 'from': 'system', 'ts': now(), 'status': 'received', 'text': text});
    touchChat(c.id, text, m.ts);
  }

  @override
  Future<Contact> addContact({required String id, required String name, required String ik, required String? card, required String addedVia, String? request, String? token}) async {
    state.contacts[id] = {
      'id': id,
      'name': name,
      'ik': ik,
      'card': card,
      'verification': 'none',
      'verifiedAt': 0,
      'verifyState': 'idle',
      'addedVia': addedVia,
      'addedAt': now(),
      'conflict': false,
      if (truthy(request)) 'request': request,
      if (truthy(token)) 'token': token,
    };
    final c = contactOf(id)!;
    markConflicts(name, id);
    if (!truthy(request)) ensureChat(id, 'direct', name);
    await persistContact(c);
    if (!truthy(request)) fire(verifyNearby(id));
    return c;
  }

  @override
  Future<Contact> learnCard(ParsedCard v, String via, [String? token]) async {
    final c = contactOf(v.id);
    final card = b64(v.card), ik = b64(v.ik);
    if (c == null) {
      try {
        await mesh.signalAddContact(v.bundle);
      } catch (_) {
        throw RipploError('bad_link', 'invalid prekey bundle');
      }
      return addContact(id: v.id, name: v.name, ik: ik, card: card, addedVia: via, token: token);
    }
    if (truthy(token) && !c.cardAck && !truthy(c.token)) {
      c.token = token;
      await persistContact(c);
    }
    if (!truthy(c.card) && c.ik == ik) {
      c.card = card;
      c.name = v.name;
      if (!truthy(c.request)) ensureChat(c.id, 'direct', c.name);
      markConflicts(c.name, c.id);
      await persistContact(c);
    }
    return c;
  }

  @override
  void markConflicts(String name, String id) {
    final key = jsLowerCase(name);
    final same = _allContacts.where((c) => c.id != id && jsLowerCase(c.name) == key).toList();
    if (same.isEmpty) return;
    for (final c in same) {
      c.conflict = true;
      fire(persistContact(c));
    }
    final self = contactOf(id);
    if (self != null) {
      self.conflict = true;
      fire(persistContact(self));
    }
  }

  @override
  Future<Contact?> addCard(Uint8List raw, String via, [String? token]) async {
    final v = checkCard(raw);
    if (v.id == me.id) throw RipploError('self');
    final isNew = contactOf(v.id) == null;
    final c = await learnCard(v, via, token);
    if (!isNew) {
      if (c.request == 'in') await acceptRequest(c.id);
      return c;
    }
    for (final p in state.people) {
      if (p.id == v.id) {
        p.isContact = true;
        break;
      }
    }
    if (const ['link', 'qr', 'people'].contains(via)) fire(verifyNearby(v.id));
    if (via == 'qr') {
      await setVerified(c.id, 'qr');
    } else if (via == 'link') {
      tellVerified(c);
    }
    return c;
  }

  @override
  Future<Contact?> addContactFromLink(String text, [String via = 'link']) async {
    final v = parseLink(text);
    if (v.id == me.id) throw RipploError('self');
    return addCard(v.card, via, v.token);
  }

  @override
  Future<void> becomeContact(Contact c, String via) async {
    c.request = null;
    c['addedVia'] = via;
    ensureChat(c.id, 'direct', c.name);
    await persistContact(c);
    for (final p in state.people) {
      if (p.id == c.id) {
        p.isContact = true;
        break;
      }
    }
    fire(verifyNearby(c.id));
  }

  @override
  Future<Contact?> invite(Person person) async {
    final v = checkCard(unb64(person.card));
    if (v.id == me.id) throw RipploError('self');
    var c = contactOf(v.id);
    if (c?.request == 'in') return acceptRequest(c!.id);
    if (c != null && c.request != 'out') return c;
    if (c == null) {
      try {
        await mesh.signalAddContact(v.bundle);
      } catch (_) {
        throw RipploError('bad_link', 'invalid prekey bundle');
      }
      c = await addContact(id: v.id, name: v.name, ik: b64(v.ik), card: b64(v.card), addedVia: 'people', request: 'out');
    }
    final target = c;
    target.inviteFailed = false;
    fire(persistContact(target));
    fire(() async {
      try {
        final r = await transmit(await buildPacket(target, {'t': 'invite'}));
        if (!r.ok && contactOf(target.id)?.request == 'out') {
          target.inviteFailed = true;
          fire(persistContact(target));
        }
      } catch (_) {
        target.inviteFailed = true;
        fire(persistContact(target));
      }
    }());
    return target;
  }

  @override
  Future<Contact?> acceptRequest(String id) async {
    final c = contactOf(id);
    if (c == null || c.request != 'in') return null;
    await becomeContact(c, 'people');
    fire(buildPacket(c, {'t': 'accept'}).then((p) => transmit(p)));
    return c;
  }

  @override
  Future<void> declineRequest(String id) async {
    final c = contactOf(id);
    if (c == null || c.request != 'in') return;
    final pkt = await buildPacket(c, {'t': 'decline'}, true);
    await deleteContact(id);
    fire(transmit(pkt));
  }

  @override
  Future<void> onApp(Packet p, String from) async {
    if (isFrame(p.payload)) return calls.onMedia(p.payload, from);
    if (p.payload.isNotEmpty && p.payload[0] == typingTag) {
      final inner = Uint8List.sublistView(p.payload, 1);
      enqueue(() => onSealed(inner));
      return;
    }
    final raw = jsonDecode(unutf8(p.payload));
    final nb = state.neighbors.where((n) => n.node == from).firstOrNull;
    if (raw is! Map) return;
    final msg = Map<String, Object?>.from(raw);
    final t = msg['t'];
    if (t == 'hello') {
      ParsedCard v;
      try {
        v = checkCard(unb64(msg['card'] as String));
      } catch (_) {
        diagLog('hello rejected ${cut(from, 0, 8)}');
        if (nb != null) nb['unsupported'] = true;
        return;
      }
      diagLog('hello in ${cut(from, 0, 8)} ${v.name}${nb != null ? '' : ' (no neighbor)'}');
      if (nb != null) nb['unsupported'] = false;
      if (v.id == me.id) return;
      final card = <String, Object?>{'id': v.id, 'name': v.name, 'ik': b64(v.ik), 'card': b64(v.card)};
      if (helloCards.length >= maxHellos && !helloCards.containsKey(from)) helloCards.remove(helloCards.keys.first);
      helloCards[from] = card;
      byed.remove(from);
      if (nb != null) nb['card'] = card;
      markConflicts(v.name, v.id);
      if (contactOf(v.id) != null) await learnCard(v, 'link');
      final known = contactOf(v.id);
      if (known != null && known['node'] != from) {
        known['node'] = from;
        fire(persistContact(known));
      }
      if (known != null && !truthy(known.request)) resendFor(known.id);
      if (known != null && !truthy(known.request) && known.verification == 'none' && known.verifyState != 'checking' && now() - ((known['verifyTried'] as num?) ?? 0) > 30000) {
        known['verifyTried'] = now();
        fire(verifyNearby(v.id));
      }
      if (truthy(msg['r']) || (state.settings.hidden && !greeted.contains(from))) sendHello(from, false);
    } else if (nb == null) {
      return;
    } else if (t == 'bye') {
      diagLog('bye in ${cut(from, 0, 8)}');
      byed.add(from);
      helloCards.remove(from);
      greeted.remove(from);
      final nc = nb['card'];
      final known = nc is Map ? contactOf(nc['id'] as String?) : null;
      if (known == null || truthy(known.request)) nb.remove('card');
    } else if (t == 'challenge') {
      final n = unb64(msg['n'] as String);
      final nc = nb['card'];
      final fromId = msg['from'];
      Uint8List? ik;
      if (nc is Map && nc['id'] == fromId) {
        ik = unb64(nc['ik'] as String);
      } else {
        final cc = fromId is String ? contactOf(fromId) : null;
        if (cc != null) ik = unb64(cc.ik!);
      }
      if (n.length != 32 || ik == null || deriveIds(ik).ripploId != fromId) return;
      final mac = await mesh.signalProof(ik, n, deriveIds(ik).tag, me.tag);
      await mesh.sendApp(from, utf8(jsonEncode({'t': 'proof', 'n': msg['n'], 'mac': b64(mac)})));
    } else if (t == 'proof') {
      final w = proofs['${msg['n']}'];
      if (w == null || w.node != from) return;
      proofs.remove('${msg['n']}');
      w.resolve(unb64('${msg['mac']}'));
    }
  }

  @override
  Future<String> proveOnce(Contact c, String node) async {
    final n = random(32);
    final key = b64(n);
    final answer = Completer<Uint8List?>();
    final timer = Timer(Duration(milliseconds: tm('proof')), () {
      proofs.remove(key);
      if (!answer.isCompleted) answer.complete(null);
    });
    proofs[key] = (
      node: node,
      resolve: (mac) {
        timer.cancel();
        if (!answer.isCompleted) answer.complete(mac);
      },
    );
    try {
      await mesh.sendApp(node, utf8(jsonEncode({'t': 'challenge', 'n': key, 'from': me.id})));
    } catch (_) {
      return 'timeout';
    }
    final mac = await answer.future;
    if (mac == null) return 'timeout';
    final ik = unb64(c.ik!);
    return equal(mac, await mesh.signalProof(ik, n, me.tag, deriveIds(ik).tag)) ? 'ok' : 'bad';
  }

  Future<bool> _verifyJob(String id) async {
    final c = contactOf(id);
    if (c == null) return false;
    c.verifyState = 'checking';
    final end = now() + tm('verify');
    var ok = false;
    while (now() < end && contactOf(id) != null) {
      final nb = state.neighbors.where((n) {
        final card = n['card'];
        return card is Map && card['id'] == id;
      }).firstOrNull;
      if (nb != null) {
        final r = await proveOnce(c, nb.node);
        if (r == 'ok') {
          ok = true;
          break;
        }
        if (r == 'bad') {
          c.conflict = true;
          break;
        }
      }
      await sleep(tm('poll'));
    }
    final cur = contactOf(id);
    if (cur == null) return false;
    if (ok) {
      if (cur.verification == 'none' || cur.verification == 'nearby') cur.verification = cur.addedVia == 'qr' ? 'qr' : 'nearby';
      cur.verifiedAt = now();
      cur.verifyState = 'idle';
    } else {
      cur.verifyState = 'failed';
    }
    await persistContact(cur);
    if (ok) tellVerified(cur);
    return ok;
  }

  @override
  Future<bool> verifyNearby(String id) {
    final existing = running[id];
    if (existing != null) return existing;
    final job = _verifyJob(id).whenComplete(() {
      running.remove(id);
    });
    running[id] = job;
    return job;
  }

  @override
  Future<bool> setVerified(String id, String level) async {
    final c = contactOf(id);
    if (c == null) return false;
    c.verification = level;
    c.verifiedAt = now();
    c.verifyState = 'idle';
    await persistContact(c);
    tellVerified(c);
    return true;
  }

  @override
  Future<bool> verifyByQr(String id, Object? scanned) async {
    final c = contactOf(id);
    if (c == null) return false;
    final text = '$scanned';
    final digits = text.replaceAll(_jsSpace, '');
    if (_digits60.hasMatch(digits)) return digits == await safetyNumber(id) && await setVerified(id, 'qr');
    try {
      final v = parseLink(text);
      return b64(v.ik) == c.ik && await setVerified(id, 'qr');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> markVerified(String id) async {
    await setVerified(id, 'manual');
  }

  @override
  Future<String> safetyNumber(String id) async {
    final c = contactOf(id);
    if (c == null) throw RipploError('no_contact');
    return mesh.signalSafetyNumber(unb64(c.ik!));
  }

  @override
  Future<void> discoverRound({required Map<String, Object?> payload, required int timeout, required int quiet}) {
    final done = Completer<void>();
    final id = newId();
    Timer? timer;
    late final DiscoverRound d;
    void finish() {
      timer?.cancel();
      d.quietTimer?.cancel();
      discover = null;
      if (!done.isCompleted) done.complete();
    }

    d = DiscoverRound(hex(id), quiet, finish);
    timer = Timer(Duration(milliseconds: timeout), finish);
    discover = d;
    mesh.send(encodePacket(type: PacketType.discover, id: id, payload: utf8(jsonEncode(payload)))).then<void>((r) {
      if (r == 0) finish();
    }, onError: (Object _) => finish());
    return done.future;
  }

  @override
  Future<void> refreshPeople() async {
    if (state.peopleRefreshing) return;
    state.peopleRefreshing = true;
    state.peopleQuery = '';
    searchText = '';
    peopleBase = null;
    state.people = <Object?>[];
    try {
      var lo = 0;
      for (final h in rings) {
        final last = h == rings.last;
        await discoverRound(
          payload: {'t': 'who', if (!last) 'h': h, if (lo != 0) 'lo': lo},
          timeout: last ? tm('discover') : tm('ring'),
          quiet: last ? tm('quiet') : tm('quietRing'),
        );
        if (state.people.length >= maxScan) break;
        lo = h;
      }
    } finally {
      state.peopleRefreshing = false;
      state.peopleRefreshedAt = now();
      fire(db.put('kv', 'peopleRefreshedAt', state.peopleRefreshedAt));
    }
  }

  @override
  Future<void> searchPeople(Object? raw) async {
    final text = cut('${raw ?? ''}'.trim(), 0, 40);
    if (state.peopleRefreshing) return;
    if (text.isEmpty) {
      final base = peopleBase;
      if (base != null) {
        state.people = base;
        peopleBase = null;
      }
      state.peopleQuery = '';
      searchText = '';
      return;
    }
    if (state.peopleQuery.isEmpty) peopleBase = state.people;
    state.peopleQuery = searchText = text;
    state.people = <Object?>[];
    state.peopleRefreshing = true;
    try {
      await discoverRound(payload: {'t': 'who', 'q': findKey(text)}, timeout: tm('discover'), quiet: tm('quiet'));
    } finally {
      state.peopleRefreshing = false;
    }
  }

  @override
  void onReply(Packet p) {
    final d = discover;
    if (d == null || hex(p.dest) != d.id) return;
    ParsedCard v;
    try {
      v = checkCard(p.payload);
    } catch (_) {
      return;
    }
    if (v.id == me.id) return;
    if (searchText.isNotEmpty && !matchesQuery(searchText, v.name)) return;
    markConflicts(v.name, v.id);
    Person mk() => Person(state.map({'id': v.id, 'name': v.name, 'card': b64(v.card), 'hops': p.hops, 'seenAt': now(), 'isContact': contactOf(v.id) != null}));
    final person = mk();
    final limit = searchText.isNotEmpty ? maxSearch : maxScan;
    final list = state.people;
    final i = list.indexWhere((x) => x.id == v.id);
    if (i >= 0) {
      if (person.hops < list[i].hops) list[i] = person;
    } else if (list.length < limit) {
      list.add(person);
    } else {
      var far = 0;
      for (var k = 1; k < list.length; k++) {
        if (list[k].hops > list[far].hops) far = k;
      }
      if (person.hops < list[far].hops) list[far] = person;
    }
    list.sort((a, b) => a.hops - b.hops);
    d.bump();
  }

  @override
  void onDiscover(Packet p) {
    if (state.settings.hidden) return;
    final cur = discover;
    if (cur != null && hex(p.id) == cur.id) return;
    Object? q;
    try {
      q = jsonDecode(unutf8(p.payload));
    } catch (_) {
      return;
    }
    if (q is! Map || q['t'] != 'who') return;
    final d = p.hops + 1;
    final h = q['h'], lo = q['lo'];
    if (isFiniteNum(h) && d > (h as num)) return;
    if (isFiniteNum(lo) && d <= (lo as num)) return;
    if (q.containsKey('q') && q['q'] != findHash(normName(me.name))) return;
    fire(mesh.send(encodePacket(type: PacketType.reply, dest: p.id, payload: me.card)));
  }
}
