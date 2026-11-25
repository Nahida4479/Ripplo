import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/core/diag.dart';
import 'package:ripplo/core/obs.dart';
import 'package:ripplo/core/state.dart';
import 'package:ripplo/util/js.dart' as js;

void main() {
  final v =
      (jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
              as Map)['state']
          as Map;

  test('default shape equals the JS createState()', () {
    final s = RipploState();
    expect(jsonDecode(jsonEncode(s.data)), v['defaults']);
    expect(jsonEncode(s.data), jsonEncode(v['defaults']));
  });

  test('deep mutations notify once per microtask', () async {
    final s = RipploState();
    var n = 0;
    s.addListener(() => n++);
    s.contacts['a'] = {
      'id': 'a',
      'name': 'A',
      'peerVerified': {'level': 'qr'},
    };
    final c = s.contact('a')!;
    expect(identical(s.contacts['a'], c.m), true);
    c.peerVerified!['level'] = 'nearby';
    c.cardAck = true;
    await Future<void>.delayed(Duration.zero);
    expect(n, 1);
    c.cardAck = null;
    expect(c.containsKey('cardAck'), false);
    await Future<void>.delayed(Duration.zero);
    expect(n, 2);
    c.name = 'A';
    await Future<void>.delayed(Duration.zero);
    expect(n, 2);
    s.update.progress = 5;
    s.settings.autoUpdate = false;
    await Future<void>.delayed(Duration.zero);
    expect(n, 3);
    s.dispose();
  });

  test('lists wrap records, keep identity, sort stably and notify', () async {
    final s = RipploState();
    var n = 0;
    s.addListener(() => n++);
    final ch = Chat(
      s.map({
        'id': 'x',
        'type': 'direct',
        'name': 'X',
        'lastText': '',
        'lastTs': 1,
        'unread': 0,
      }),
    );
    s.chats.add(ch);
    s.chats.add(Chat(s.map({'id': 'y', 'lastTs': 1})));
    s.chats.add(Chat(s.map({'id': 'z', 'lastTs': 2})));
    expect(identical(s.chats.first, ch), true);
    await Future<void>.delayed(Duration.zero);
    n = 0;
    s.chats.sort((a, b) => b.lastTs - a.lastTs);
    expect(s.chats.map((c) => c.id), ['z', 'x', 'y']);
    ch.unread = ch.unread + 1;
    await Future<void>.delayed(Duration.zero);
    expect(n, 1);
    s.messages['x'] = s.list<Msg>([
      {
        'id': 'm',
        'chatId': 'x',
        'from': 'me',
        'ts': 3,
        'status': 'sent',
        'att': {
          'kind': 'image',
          'wave': [1, 2],
        },
      },
    ]);
    final m = s.msgs('x')!.single;
    m.att!.bytes = Uint8List(3);
    expect(m.att!['bytes'], isA<Uint8List>());
    expect(m.att!['wave'], isA<ObsList<Object?>>());
    s.devLogs = [
      {'id': 'd', 'text': 't'},
    ];
    expect(s.devLogs.single.text, 't');
    s.call = {
      'peer': 'p',
      'dir': 'in',
      'status': 'ringing',
      'muted': false,
      'startedAt': 0,
    };
    s.call = {...s.call!, 'status': 'ended'};
    expect(s.call!.status, 'ended');
    s.chats.removeWhere((c) => c.id == 'y');
    expect(s.chats.length, 2);
  });

  test('diag keeps a 400 line ring and feeds the sink', () async {
    final got = <String>[];
    final clock = js.now;
    final print0 = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {};
    addTearDown(() {
      js.now = clock;
      debugPrint = print0;
    });
    js.now = () =>
        DateTime.utc(2026, 1, 15, 10, 30, 5, 7).millisecondsSinceEpoch;
    setDiagSink((t) async {
      got.add(t);
      throw StateError('sink errors are swallowed');
    });
    diagClear();
    for (var i = 0; i < 405; i++) {
      diagLog('l$i');
    }
    final lines = diagText().split('\n');
    expect(lines.length, 400);
    expect(lines.first, '10:30:05.007 l5');
    expect(got.last, 'js 10:30:05.007 l404');
    expect(got.length, 405);
    setDiagSink(null);
    diagClear();
    expect(diagText(), '');
    await Future<void>.delayed(Duration.zero);
  });
}
