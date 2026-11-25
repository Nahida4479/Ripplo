part of 'messenger.dart';

final _msgAttIdRe = RegExp(r'^[0-9a-f]{32}$');
final _msgShaRe = RegExp(r'^[0-9a-f]{64}$');
final _msgGroupRe = RegExp(r'^[A-Za-z0-9_-]{6,32}$');
final _msgWaveRe = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

bool _msgWireId(Object? v) => v is String && wireIdRe.hasMatch(v);

num _msgNum(num v) =>
    v is double && v.isFinite && v == v.truncateToDouble() && v.abs() < 1e15
    ? v.toInt()
    : v;

mixin _Msgs on _Base {
  Iterable<Msg> _msgAll() sync* {
    for (final l in state.messages.values.toList()) {
      if (l is! List) continue;
      for (final x in l.toList()) {
        if (x is ObsMap) yield Msg(x);
      }
    }
  }

  void _msgFailed(Msg m) {
    m.status = 'failed';
    fire(persistMsg(m));
  }

  @override
  ({Msg m, List<String> recips}) newOutgoing(
    String chatId,
    Map<String, Object?> extra,
  ) {
    final recips = recipientsOf(chatId);
    final m = addMsg({
      'id': hex(random(16)),
      'chatId': chatId,
      'from': 'me',
      'ts': now(),
      'status': 'encrypting',
      'undelivered': [...recips],
      'delivered': 0,
      'total': recips.length,
      ...extra,
    });
    return (m: m, recips: recips);
  }

  @override
  Future<void> fanout(
    Msg m,
    Map<String, Object?> body,
    List<String> recips,
  ) async {
    m.status = 'sending';
    fire(persistMsg(m));
    await Future.wait([
      for (final rid in recips)
        () async {
          TxResult r;
          try {
            r = await transmit(await buildPacket(contactOf(rid)!, body));
          } catch (_) {
            r = txError;
          }
          if (r.ok) {
            m.undelivered = [
              for (final x in m.undelivered ?? const [])
                if (x != rid) x,
            ];
            m.delivered = m.total - (m.undelivered?.length ?? 0);
            m.put('hops', r.hops);
          } else if (r.error) {
            m.errored = true;
          }
          if (!r.ok) {
            final c = contactOf(rid)!;
            c.avSent = c.nameSent = c.vfSent = '?';
          }
        }(),
    ]);
    m.status = (m.undelivered?.isEmpty ?? true)
        ? 'delivered'
        : m.errored
        ? 'failed'
        : 'out_of_range';
    fire(persistMsg(m));
  }

  @override
  Map<String, Object?> textBody(Msg m, String? group) {
    final re = m.re;
    return {
      't': 'msg',
      'id': m.id,
      'text': m.text,
      'ts': m.ts,
      if (truthy(group)) 'g': group,
      if (re != null) 're': wireRe(re),
    };
  }

  @override
  Map<String, Object?>? localRef(String chatId, String localId) {
    Msg? m;
    for (final x in state.msgs(chatId) ?? const <Msg>[]) {
      if (x.id == localId) {
        m = x;
        break;
      }
    }
    if (m == null || m.from == 'system') return null;
    final mine = m.from == 'me';
    final text = m.text;
    final att = m.att;
    return {
      'id': mine ? m.id : cut(m.id, m.id.indexOf('.') + 1),
      'who': mine ? me.id : m.from,
      'mid': m.id,
      if (truthy(text)) 'text': cut(text!, 0, reText),
      if (att != null) 'kind': att.kind,
    };
  }

  @override
  Map<String, Object?>? parseRe(Object? raw) {
    if (raw is! Map ||
        !_msgWireId(raw['id']) ||
        raw['who'] is! String ||
        !idRe.hasMatch(raw['who'] as String)) {
      return null;
    }
    final id = raw['id'] as String, who = raw['who'] as String;
    final out = <String, Object?>{
      'id': id,
      'who': who,
      'mid': who == me.id ? id : '$who.$id',
    };
    final text = raw['text'];
    if (text is String) out['text'] = cut(text, 0, reText);
    if (kinds.contains(raw['kind'])) out['kind'] = raw['kind'];
    return out;
  }

  @override
  Future<({bool ok, int? hops})> sendDevLog(String to, String text) async {
    final c = contactOf(to);
    if (c == null || truthy(c.request)) throw RipploError('no_chat');
    final body = <String, Object?>{
      't': 'dlog',
      'id': hex(random(16)),
      'ts': now(),
      ...await packLog(text),
    };
    final z = body['z'];
    if (z is String && z.length > dlogBodyMax) throw RipploError('too_big');
    final r = await transmit(await buildPacket(c, body));
    return (ok: r.ok, hops: r.hops);
  }

  @override
  void deleteDevLog(String id) {
    state.devLogs = state.devLogs.where((x) => x.id != id).toList();
    fire(
      db.put('kv', 'devLogs', [
        for (final x in state.devLogs) {...x},
      ]),
    );
  }

  @override
  Future<Msg> sendText(String chatId, Object? text, [String? replyTo]) async {
    if (text is! String || text.trim().isEmpty) throw RipploError('empty');
    if (text.length > maxText) throw RipploError('too_long');
    final re = truthy(replyTo) ? localRef(chatId, replyTo!) : null;
    final o = newOutgoing(chatId, {'text': text, 're': ?re});
    touchChat(chatId, text, o.m.ts);
    fire(fanout(o.m, textBody(o.m, groupOf(chatId)), o.recips));
    return o.m;
  }

  @override
  Future<Msg> sendAttachment(
    String chatId,
    AttFile file,
    String kind, {
    num? duration,
    List<Object?>? wave,
    Object? caption,
    String? replyTo,
  }) async {
    if (!kinds.contains(kind)) throw RipploError('bad_kind');
    if (file.bytes.length > maxFile) throw RipploError('too_big');
    final peer = contactOf(chatId);
    if (peer != null && peer.addedVia != 'incoming' && !peer.cardAck) {
      throw RipploError('media_locked');
    }
    final bytes = file.bytes;
    final attId = hex(random(16));
    await db.putBin('blobs', attId, bytes);
    final att = <String, Object?>{
      'kind': kind,
      'mime': safeMime(file.type),
      'size': bytes.length,
      'attId': attId,
      'bytes': bytes,
    };
    final dur = duration ?? file.duration;
    if (dur != null && isFiniteNum(dur) && dur > 0) {
      att['duration'] = _msgNum(dur > 3600 ? 3600 : dur);
    }
    if (wave != null && wave.length <= maxWave) {
      att['wave'] = [for (final v in wave) toInt32(v).clamp(0, 255)];
    }
    if (truthy(caption) && captionOf(caption) == null) {
      throw RipploError('too_long');
    }
    final cap = captionOf(caption);
    final re = truthy(replyTo) ? localRef(chatId, replyTo!) : null;
    final o = newOutgoing(chatId, {
      'att': att,
      'progress': 0,
      'text': ?cap,
      're': ?re,
    });
    touchChat(chatId, cap ?? '', o.m.ts, 0, kind);
    runAttachment(
      o.m,
      bytes,
      o.recips,
    ).then<void>((_) {}, onError: (Object _) => _msgFailed(o.m));
    return o.m;
  }

  @override
  Future<void> runAttachment(
    Msg m,
    Uint8List bytes,
    List<String> recips,
  ) async {
    m.status = 'encrypting';
    m.progress = 0;
    final enc = await encryptFile(bytes);
    final ct = enc.ct;
    final attId = newId();
    final total = chunkCount(ct);
    final all = total * recips.length;
    var acked = 0;
    m.status = 'sending';
    final okRecips = <String>[];
    await Future.wait([
      for (final rid in recips)
        () async {
          final dest = tagOf(contactOf(rid)!);
          var next = 0;
          var failed = false;
          Future<bool> sendChunk(int i) async {
            for (var k = 0; k < tm('tries'); k++) {
              final r = await transmit(
                encodePacket(
                  type: PacketType.data,
                  dest: dest,
                  payload: chunkPayload(attId, ct, i, total),
                ),
                tm('chunkAck'),
              );
              if (r.ok) return true;
              if (k + 1 < tm('tries')) await sleep(tm('retry'));
            }
            return false;
          }

          Future<void> worker() async {
            while (!failed && next < total) {
              final i = next++;
              if (!await sendChunk(i)) {
                failed = true;
                return;
              }
              acked++;
              m.progress = acked == all ? 1 : acked / all;
            }
          }

          await Future.wait([
            for (
              var w = 0;
              w < (total < chunkWindow ? total : chunkWindow);
              w++
            )
              worker(),
          ]);
          if (!failed) okRecips.add(rid);
        }(),
    ]);
    final g = groupOf(m.chatId);
    final att = m.att!;
    final dur = att.duration;
    final aw = att.wave;
    final re = m.re;
    final body = <String, Object?>{
      't': 'att',
      'id': m.id,
      'attId': hex(attId),
      'kind': att.kind,
      'mime': att.mime,
      'size': att.size,
      'sha256': hex(enc.sha256),
      'key': b64(enc.key),
      'chunks': total,
      'ts': m.ts,
      'g': ?g,
      if (truthy(dur)) 'duration': dur,
      if (aw != null)
        'wave': b64(
          Uint8List.fromList([for (final v in aw) (v as num).toInt()]),
        ),
      if (truthy(m.text)) 'text': m.text,
      if (re != null) 're': wireRe(re),
    };
    await fanout(m, body, okRecips);
  }

  @override
  Future<void> retry(String msgId) async {
    Msg? m;
    for (final x in _msgAll()) {
      if (x.id == msgId) {
        m = x;
        break;
      }
    }
    if (m == null ||
        m.from != 'me' ||
        !const ['out_of_range', 'failed'].contains(m.status)) {
      return;
    }
    final un = m.undelivered ?? const [];
    final recips = un.isNotEmpty
        ? [for (final x in un) x as String]
        : recipientsOf(m.chatId);
    m.errored = false;
    final att = m.att;
    if (att == null) {
      fire(fanout(m, textBody(m, groupOf(m.chatId)), recips));
      return;
    }
    final target = m;
    final bytes = await db.getBin('blobs', att.attId!);
    if (bytes == null) {
      _msgFailed(target);
      return;
    }
    runAttachment(
      target,
      bytes,
      recips,
    ).then<void>((_) {}, onError: (Object _) => _msgFailed(target));
  }

  @override
  void resendFor(String id) {
    if (now() - (lastResend[id] ?? 0) < tm('resend')) return;
    lastResend[id] = now();
    for (final m in _msgAll()) {
      if (m.from == 'me' &&
          const ['out_of_range', 'failed'].contains(m.status) &&
          (m.undelivered?.contains(id) ?? false)) {
        fire(retry(m.id));
      }
    }
  }

  @override
  void clearTyping(String chatId, String from) {
    final k = '$chatId/$from';
    typingTimers.remove(k)?.cancel();
    final l = state.typing[chatId];
    if (l is List && l.contains(from)) {
      state.typing = {
        ...state.typing,
        chatId: [
          for (final x in l)
            if (x != from) x,
        ],
      };
    }
  }

  @override
  void onTyping(Contact c, Map<String, Object?> msg) {
    final ts = msg['ts'];
    if (isFiniteNum(ts) && now() - (ts as num) > tm('typingTtl')) return;
    final chatId = routeChat(c.id, msg);
    if (chatId == null) return;
    final k = '$chatId/${c.id}';
    typingTimers[k]?.cancel();
    final l = state.typing[chatId];
    final list = l is List ? l : const [];
    if (!list.contains(c.id)) {
      state.typing = {
        ...state.typing,
        chatId: [...list, c.id],
      };
    }
    typingTimers[k] = Timer(
      Duration(milliseconds: tm('typingTtl')),
      () => clearTyping(chatId, c.id),
    );
  }

  @override
  Future<void> sendTyping(String chatId) async {
    final ts = now();
    if (ts - (lastTyping[chatId] ?? 0) < tm('typing')) return;
    List<String> recips;
    try {
      recips = recipientsOf(chatId);
    } catch (_) {
      return;
    }
    lastTyping[chatId] = ts;
    final g = groupOf(chatId);
    final body = utf8(jsonEncode({'t': 'typing', 'ts': ts, 'g': ?g}));
    for (final rid in recips) {
      final c = contactOf(rid);
      final nb = c != null && c.cardAck && !truthy(c.request)
          ? neighborOf(rid, c['node'] as String?)
          : null;
      if (nb == null) continue;
      try {
        await mesh.sendApp(
          nb.node,
          concat([
            Uint8List.fromList([typingTag]),
            await mesh.signalSeal(hex(tagOf(c!)), body),
          ]),
        );
      } catch (_) {}
    }
  }

  @override
  Future<void> onAppMessage(String f, Object? msg) async {
    if (msg is! Map) return;
    final m = Map<String, Object?>.from(msg);
    final id = m['id'];
    switch (m['t']) {
      case 'msg':
        final text = m['text'];
        if (!_msgWireId(id) || text is! String || text.length > maxText) return;
        final chatId = routeChat(f, m);
        if (chatId == null) return;
        final re = parseRe(m['re']);
        await receive({
          'id': '$f.$id',
          'chatId': chatId,
          'from': f,
          'text': text,
          're': ?re,
        }, text);
      case 'att':
        final sender = contactOf(f);
        if (sender != null &&
            sender.addedVia == 'incoming' &&
            !truthy(sender['cardSent'])) {
          return;
        }
        final aid = m['attId'],
            sha = m['sha256'],
            size = m['size'],
            chunks = m['chunks'],
            key = m['key'];
        if (!_msgWireId(id) ||
            aid is! String ||
            !_msgAttIdRe.hasMatch(aid) ||
            !kinds.contains(m['kind']) ||
            sha is! String ||
            !_msgShaRe.hasMatch(sha)) {
          return;
        }
        if (!isInt(size) ||
            (size as num) < 0 ||
            size > maxFile ||
            !isInt(chunks) ||
            (chunks as num) < 1 ||
            chunks > maxChunks) {
          return;
        }
        if (key is! String ||
            unb64(key).length != 32 ||
            routeChat(f, m) == null) {
          return;
        }
        await db.put('kv', 'ptr/$aid', {'f': f, 'msg': m, 'silent': silentNow});
        await tryFinish(aid);
      case 'unsend':
        if (!_msgWireId(id)) return;
        final chatId = routeChat(f, m);
        if (chatId == null) return;
        final localId = '$f.$id';
        unsent.add(localId);
        if (unsent.length > maxUnsent) unsent.remove(unsent.first);
        await db.put('kv', 'unsent', unsent.toList());
        await removeMessage(chatId, localId);
      case 'dlog':
        final sender = contactOf(f);
        if (sender == null ||
            truthy(sender.request) ||
            id is! String ||
            id.length > 64) {
          return;
        }
        String? text;
        try {
          text = await unpackLog(m);
        } catch (_) {
          text = null;
        }
        if (text == null || text.length > 400000) return;
        state.devLogs = [
          {'id': id, 'from': f, 'name': sender.name, 'ts': now(), 'text': text},
          for (final x in state.devLogs)
            if (x.id != id) x,
        ].take(100).toList();
        fire(
          db.put('kv', 'devLogs', [
            for (final x in state.devLogs) {...x},
          ]),
        );
      case 'group':
        await onGroup(f, m);
      case 'call':
        if (canCall(contactOf(f))) await calls.onSignal(f, m);
    }
  }

  @override
  Future<void> receive(
    Map<String, Object?> m,
    String preview, [
    String? notifyBody,
  ]) async {
    final mid = m['id'] as String;
    if (unsent.contains(mid) || await db.hasMsg(mid)) return;
    final msg = addMsg({...m, 'ts': now(), 'status': 'received'});
    final chatId = m['chatId'] as String, from = m['from'] as String;
    clearTyping(chatId, from);
    final att = m['att'];
    touchChat(
      chatId,
      preview,
      msg.ts,
      1,
      att is Map ? att['kind'] as String? : null,
    );
    final chat = chatOf(chatId);
    if (!silentNow) {
      final who = contactOf(from)?.name ?? '';
      notifier((
        title: chat?.type == 'group' ? '${chat!.name}: $who' : who,
        body: notifyBody ?? preview,
        chatId: chatId,
      ));
    }
  }

  @override
  Future<void> onGroup(String f, Map<String, Object?> msg) async {
    final g = msg['g'], members = msg['members'];
    if (g is! String ||
        !_msgGroupRe.hasMatch(g) ||
        members is! List ||
        members.length < 2 ||
        members.length > maxGroup + 1) {
      return;
    }
    final name = cleanName(msg['name']);
    if (name.isEmpty) return;
    List<ParsedCard> cards;
    try {
      cards = [for (final x in members) checkCard(unb64(x as String))];
    } catch (_) {
      return;
    }
    final ids = [for (final x in cards) x.id];
    if (!ids.contains(f) || !ids.contains(me.id)) return;
    final existing = chatOf(g);
    if (existing != null &&
        (existing.type != 'group' ||
            !(existing.members ?? const []).contains(f))) {
      return;
    }
    for (final v in cards) {
      if (v.id != me.id) await learnCard(v, 'group');
    }
    ensureChat(g, 'group', name, [
      for (final i in ids)
        if (i != me.id) i,
    ]);
  }

  @override
  Future<void> removeMessage(String chatId, String localId) async {
    final list = state.msgs(chatId);
    final i = list == null ? -1 : list.indexWhere((x) => x.id == localId);
    Map<String, Object?>? m;
    if (i >= 0) {
      m = list![i];
    } else {
      for (final x in await db.msgs(chatId)) {
        if (x['id'] == localId) {
          m = x;
          break;
        }
      }
    }
    if (m != null) m['unsent'] = true;
    if (i >= 0) list!.removeAt(i);
    final att = m?['att'];
    if (att is Map && att['attId'] is String) {
      await db.del('blobs', att['attId'] as String);
    }
    await db.delMsg(localId);
    for (final x in (list ?? const <Msg>[]).toList()) {
      final re = x.re;
      if (re != null &&
          re['mid'] == localId &&
          (truthy(re['text']) || truthy(re['kind']))) {
        re.remove('text');
        re.remove('kind');
        fire(persistMsg(x));
      }
    }
    final chat = chatOf(chatId);
    if (chat != null) {
      final List<Map<String, Object?>> remaining =
          state.msgs(chatId) ?? await db.msgs(chatId);
      final last = remaining.isEmpty ? null : remaining.last;
      final lastAtt = last?['att'];
      chat.lastText = truthy(last?['text']) ? last!['text'] as String : '';
      chat.lastKind = lastAtt is Map && truthy(lastAtt['kind'])
          ? lastAtt['kind'] as String
          : null;
      chat.lastTs = truthy(last?['ts'])
          ? (last!['ts'] as num).toInt()
          : chat.lastTs;
      fire(persistChat(chat));
    }
  }

  @override
  Future<void> flushUnsends() async {
    if (flushing) return;
    flushing = true;
    try {
      for (final u in List.of(unsends)) {
        final to = List<Object?>.of(u['to'] as List);
        u['to'] = to;
        for (final rid in List.of(to)) {
          final c = contactOf(rid as String);
          if (c == null || truthy(c.request)) {
            to.remove(rid);
            continue;
          }
          TxResult r;
          try {
            r = await transmit(
              await buildPacket(c, {
                't': 'unsend',
                'id': u['id'],
                if (truthy(u['g'])) 'g': u['g'],
              }),
            );
          } catch (_) {
            r = txFail;
          }
          if (r.ok) to.remove(rid);
        }
      }
      unsends = unsends.where((u) => (u['to'] as List).isNotEmpty).toList();
      await db.put('kv', 'unsends', unsends);
    } finally {
      flushing = false;
    }
  }

  @override
  Future<void> unsendMessage(String chatId, String localId) async {
    Msg? m;
    for (final x in state.msgs(chatId) ?? const <Msg>[]) {
      if (x.id == localId && x.from == 'me') {
        m = x;
        break;
      }
    }
    if (m == null) throw RipploError('no_message');
    final recips = recipientsOf(chatId);
    final g = groupOf(chatId);
    await removeMessage(chatId, localId);
    unsends.add({
      'id': localId,
      'g': ?g,
      'to': [...recips],
    });
    await db.put('kv', 'unsends', unsends);
    fire(flushUnsends());
  }

  @override
  Future<ObsList<Msg>> loadMessages(String chatId) async {
    if (loaded.contains(chatId)) {
      if (state.msgs(chatId) == null) {
        state.messages[chatId] = state.list<Msg>();
      }
      return state.msgs(chatId)!;
    }
    loaded.add(chatId);
    final mem = {for (final x in state.msgs(chatId) ?? const <Msg>[]) x.id: x};
    final rows = await db.msgs(chatId);
    for (final r in rows) {
      final att = r['att'];
      if (mem.containsKey(r['id']) ||
          att is! Map ||
          att['bytes'] != null ||
          att['attId'] is! String) {
        continue;
      }
      final bytes = await db.getBin('blobs', att['attId'] as String);
      if (bytes != null) att['bytes'] = bytes;
    }
    state.messages[chatId] = state.list<Msg>([
      for (final r in rows) mem[r['id']] ?? r,
    ]);
    return state.msgs(chatId)!;
  }

  @override
  void markRead(String chatId) {
    final chat = chatOf(chatId);
    if (chat != null && chat.unread != 0) {
      chat.unread = 0;
      fire(persistChat(chat));
    }
  }

  @override
  Future<Chat> createGroup(String name, List<String> memberIds) async {
    final clean = cleanName(name);
    final ids = memberIds.toSet().toList();
    if (clean.isEmpty || ids.isEmpty) throw RipploError('bad_group');
    if (ids.length > maxGroup) throw RipploError('too_many');
    if (ids.any((i) {
      final c = contactOf(i);
      return c == null || !truthy(c.card) || truthy(c.request);
    })) {
      throw RipploError('no_contact');
    }
    final g = b64(random(9)).replaceAll('+', '-').replaceAll('/', '_');
    final chat = ensureChat(g, 'group', clean, ids);
    final body = {
      't': 'group',
      'g': g,
      'name': clean,
      'members': [b64(me.card), for (final i in ids) contactOf(i)!.card],
    };
    await Future.wait([
      for (final i in ids)
        () async {
          try {
            await mesh.send(await buildPacket(contactOf(i)!, body));
          } catch (_) {}
        }(),
    ]);
    return chat;
  }

  @override
  Future<void> dropExpired() async {
    for (final aid in pending.keys.toList()) {
      if ((pending[aid]!['ts'] as num) < now() - pendingTtl) await discard(aid);
    }
  }

  @override
  Future<void> discard(String aid) async {
    for (final k in await db.keysByPrefix('chunks', aid)) {
      await db.del('chunks', k);
    }
    pending.remove(aid);
    await db.put('kv', 'pending', pending);
    await db.del('kv', 'ptr/$aid');
  }

  @override
  int pendingBytes() =>
      pending.values.fold<int>(0, (n, x) => n + (x['bytes'] as num).toInt());

  @override
  Future<void> onChunk(Packet p) async {
    ({Uint8List attId, int index, int total, Uint8List bytes}) ch;
    try {
      ch = parseChunk(p.payload);
    } catch (_) {
      return;
    }
    final index = ch.index, total = ch.total, bytes = ch.bytes;
    final aid = hex(ch.attId);
    if (total < 1 ||
        total > maxChunks ||
        index >= total ||
        bytes.isEmpty ||
        bytes.length > chunkSize) {
      return;
    }
    await dropExpired();
    final meta =
        pending[aid] ?? {'ts': now(), 'total': total, 'count': 0, 'bytes': 0};
    final key = '$aid/$index';
    if (meta['total'] != total ||
        await db.has('chunks', key) ||
        pendingBytes() + bytes.length > maxPending) {
      return;
    }
    await db.putBin('chunks', key, bytes);
    meta['count'] = (meta['count'] as int) + 1;
    meta['bytes'] = (meta['bytes'] as int) + bytes.length;
    pending[aid] = meta;
    await db.put('kv', 'pending', pending);
    if (meta['count'] == total) await tryFinish(aid);
  }

  @override
  Future<void> tryFinish(String aid) async {
    final ptr = await db.get('kv', 'ptr/$aid');
    final meta = pending[aid];
    if (ptr is! Map ||
        meta == null ||
        (meta['count'] as num) < (meta['total'] as num)) {
      return;
    }
    final f = ptr['f'] as String;
    final msg = Map<String, Object?>.from(ptr['msg'] as Map);
    final silent = ptr['silent'];
    try {
      if (meta['total'] != msg['chunks']) throw StateError('chunk count');
      final parts = <Uint8List>[];
      for (var i = 0; i < (meta['total'] as int); i++) {
        parts.add((await db.getBin('chunks', '$aid/$i'))!);
      }
      final ct = concat(parts);
      if (!equal(c.sha256.convert(ct).bytes, unhex(msg['sha256'] as String))) {
        throw StateError('hash');
      }
      final plain = await decryptFile(ct, unb64(msg['key'] as String));
      if (plain.length != msg['size']) throw StateError('size');
      final mime = safeMime(msg['mime']);
      await db.putBin('blobs', aid, plain);
      final att = <String, Object?>{
        'kind': msg['kind'],
        'mime': mime,
        'size': plain.length,
        'attId': aid,
        'bytes': plain,
      };
      final dur = msg['duration'];
      if (isFiniteNum(dur) && (dur as num) > 0) {
        att['duration'] = _msgNum(dur > 3600 ? 3600 : dur);
      }
      final wave = msg['wave'];
      if (wave is String && wave.length <= 96 && _msgWaveRe.hasMatch(wave)) {
        att['wave'] = unb64(wave).toList();
      }
      final caption = captionOf(msg['text']);
      final re = parseRe(msg['re']);
      silentNow = truthy(silent);
      await receive(
        {
          'id': '$f.${msg['id']}',
          'chatId': truthy(msg['g']) ? msg['g'] : f,
          'from': f,
          'att': att,
          'text': ?caption,
          're': ?re,
        },
        caption ?? '',
        '${t(msg['kind'] == 'image' ? 'notifPhoto' : 'notifAttachment')}${caption != null ? ': $caption' : ''}',
      );
    } catch (_) {
      silentNow = false;
      return discard(aid);
    }
    silentNow = false;
    await discard(aid);
  }
}
