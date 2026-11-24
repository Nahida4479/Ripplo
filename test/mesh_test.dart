import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/mesh/packet.dart';
import 'package:ripplo/mesh/router.dart';
import 'package:ripplo/util/bytes.dart';

Uint8List tag(int n) => Uint8List(16)..fillRange(0, 16, n);

class Sent {
  Sent(this.from, this.to, this.p);
  final String from;
  final String to;
  final Packet p;
}

class Got {
  Got(this.p, this.from);
  final Packet p;
  final String from;
}

class Net {
  Net(List<String> names, List<List<String>> edges) : names = names {
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      inbox[name] = [];
      routers[name] = Router(
        selfTag: tag(i + 1),
        sendTo: (to, bytes) {
          sends.add(Sent(name, to, decodePacket(bytes)));
          queue.add(() => routers[to]!.onPacket(bytes, name));
        },
        deliver: (bytes, from) =>
            inbox[name]!.add(Got(decodePacket(bytes), from)),
      );
    }
    for (final e in edges) {
      routers[e[0]]!.linkUp(e[1]);
      routers[e[1]]!.linkUp(e[0]);
    }
  }

  final List<String> names;
  final Queue<void Function()> queue = Queue();
  final List<Sent> sends = [];
  final Map<String, List<Got>> inbox = {};
  final Map<String, Router> routers = {};

  void run() {
    var n = 0;
    while (queue.isNotEmpty) {
      queue.removeFirst()();
      if (++n > 10000) throw StateError('loop');
    }
  }

  Uint8List tagOf(String name) => tag(names.indexOf(name) + 1);
  List<Got> ofType(String name, int type) =>
      inbox[name]!.where((x) => x.p.type == type).toList();
}

List<String> line(int n) => 'ABCDEF'.split('').sublist(0, n);
List<List<String>> lineEdges(List<String> names) => [
  for (var i = 1; i < names.length; i++) [names[i - 1], names[i]],
];
Uint8List data(Uint8List dest, [int? ttl]) => encodePacket(
  type: PacketType.data,
  dest: dest,
  ttl: ttl ?? ttlDefault,
  payload: [1, 2, 3],
);

late Map<String, dynamic> vec;

class Stream {
  Stream(this.label);
  final String label;
  var n = 0;
  var buf = Uint8List(0);

  Uint8List take(int k) {
    while (buf.length < k) {
      buf = concat([buf, c.sha256.convert(utf8('$label#${n++}')).bytes]);
    }
    final out = buf.sublist(0, k);
    buf = buf.sublist(k);
    return out;
  }
}

Stream? rng;

void seed(String label) => rng = Stream(label);

Uint8List bytesOf(String label, int n) {
  seed(label);
  return rng!.take(n);
}

Map<String, dynamic> sim(
  String label,
  List<String> names,
  List<List<String>> edges,
  void Function(Ctx c) script,
) {
  seed('router:$label');
  final ctx = Ctx(names, edges);
  script(ctx);
  final snap = {
    for (final n in names)
      n: {
        'links': ctx.routers[n]!.neighbors(),
        'routes': [
          for (final e in ctx.routers[n]!.routes.entries)
            [e.key, e.value.n, e.value.t],
        ],
        'seen': [
          for (final e in ctx.routers[n]!.seen.entries) [e.key, e.value],
        ],
        'reverse': [
          for (final e in ctx.routers[n]!.reverse.entries)
            [
              e.key,
              e.value.prev,
              e.value.dest,
              e.value.pending,
              e.value.done,
              e.value.t,
            ],
        ],
      },
  };
  return {
    'label': label,
    'names': names,
    'selfTags': [for (var i = 0; i < names.length; i++) hex(tag(i + 1))],
    'edges': edges,
    'events': ctx.ev,
    'final': snap,
  };
}

class Ctx {
  Ctx(this.names, List<List<String>> edges) {
    for (var i = 0; i < names.length; i++) {
      final name = names[i];
      routers[name] = Router(
        selfTag: tag(i + 1),
        sendTo: (to, b) {
          ev.add({'e': 'send', 'at': name, 'to': to, 'pkt': hex(b)});
          queue.add(() => routers[to]!.onPacket(b, name));
        },
        deliver: (b, from) =>
            ev.add({'e': 'deliver', 'at': name, 'from': from, 'pkt': hex(b)}),
        now: () => clock,
      );
    }
    for (final e in edges) {
      routers[e[0]]!.linkUp(e[1]);
      routers[e[1]]!.linkUp(e[0]);
    }
  }

  final List<String> names;
  var clock = 1700000000000;
  final List<Map<String, Object?>> ev = [];
  final Queue<void Function()> queue = Queue();
  final Map<String, Router> routers = {};

  void run() {
    var n = 0;
    while (queue.isNotEmpty) {
      queue.removeFirst()();
      if (++n > 10000) throw StateError('loop');
    }
  }

  Uint8List tagOf(String n) => tag(names.indexOf(n) + 1);
  void advance(int ms) => clock += ms;
  void mark(String m) => ev.add({'e': 'mark', 'm': m});

  void inject(String at, Uint8List b, String from) {
    ev.add({'e': 'inject', 'at': at, 'from': from, 'pkt': hex(b)});
    routers[at]!.onPacket(b, from);
  }
}

Uint8List dataP(
  Uint8List dst,
  int ttl,
  Uint8List id, [
  List<int> payload = const [1, 2, 3],
]) => encodePacket(
  type: PacketType.data,
  dest: dst,
  ttl: ttl,
  id: id,
  payload: payload,
);

Uint8List ids(int k) => bytesOf('rid:$k', 16);

String errMsg(void Function() f) {
  try {
    f();
  } on FormatException catch (e) {
    return e.message;
  }
  return 'ok';
}

void main() {
  setUpAll(() {
    vec =
        jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
            as Map<String, dynamic>;
  });

  tearDown(() {
    newIdSource = () => random(16);
  });

  group('router', () {
    test(
      '(a) line: delivered once, ACK hops=5, routes learned, second DATA unicast',
      () {
        final names = line(6), t = Net(names, lineEdges(names));
        t.routers['A']!.onPacket(data(t.tagOf('F')), 'self');
        t.run();
        expect(t.ofType('F', PacketType.data), hasLength(1));
        for (final n in 'ABCDE'.split('')) {
          expect(t.ofType(n, PacketType.data), hasLength(0));
        }
        final acks = t.ofType('A', PacketType.ack);
        expect(acks, hasLength(1));
        expect(acks[0].p.hops, 5);
        expect(t.routers['B']!.routes.length, 1);
        t.sends.clear();
        t.routers['A']!.onPacket(data(t.tagOf('F')), 'self');
        t.run();
        expect(t.ofType('F', PacketType.data), hasLength(2));
        expect(t.sends.where((s) => s.p.type == PacketType.data), hasLength(5));
      },
    );

    test('(b) absent recipient: one aggregated DEAD_END, bounded sends', () {
      final names = line(6), t = Net(names, lineEdges(names));
      t.routers['A']!.onPacket(data(tag(99)), 'self');
      t.run();
      expect(t.ofType('A', PacketType.deadEnd), hasLength(1));
      expect(t.ofType('A', PacketType.ack), hasLength(0));
      expect(t.sends.length, 10);
    });

    test(
      '(c) diamond: duplicate gets DEAD_END, A still gets ACK and no DEAD_END',
      () {
        final t = Net(
          ['A', 'B', 'C', 'D'],
          [
            ['A', 'B'],
            ['A', 'C'],
            ['B', 'D'],
            ['C', 'D'],
            ['B', 'C'],
          ],
        );
        t.routers['A']!.onPacket(data(t.tagOf('D')), 'self');
        t.run();
        expect(t.ofType('D', PacketType.data), hasLength(1));
        expect(t.ofType('A', PacketType.ack), hasLength(1));
        expect(t.ofType('A', PacketType.deadEnd), hasLength(0));
        expect(t.sends.any((s) => s.p.type == PacketType.deadEnd), isTrue);
      },
    );

    test(
      '(d) no hop limit: line of 40 with ttl field 1 still delivers, hops saturate safely',
      () {
        final names = List.generate(40, (i) => 'n$i'),
            t = Net(names, lineEdges(names));
        t.routers['n0']!.onPacket(data(t.tagOf('n39'), 1), 'self');
        t.run();
        expect(t.ofType('n39', PacketType.data), hasLength(1));
        expect(t.ofType('n0', PacketType.ack)[0].p.hops, 39);
        expect(t.ofType('n0', PacketType.deadEnd), hasLength(0));
      },
    );

    test(
      '(e) DISCOVER floods, each other node delivers once, REPLYs reach origin',
      () {
        final names = line(4),
            t = Net(names, [
              ...lineEdges(names),
              ['A', 'D'],
            ]);
        for (final n in 'BCD'.split('')) {
          final r = t.routers[n]!, orig = r.deliver;
          r.deliver = (bytes, from) {
            orig(bytes, from);
            final p = decodePacket(bytes);
            if (p.type == PacketType.discover) {
              r.onPacket(
                encodePacket(
                  type: PacketType.reply,
                  dest: p.id,
                  payload: [n.codeUnitAt(0)],
                ),
                'self',
              );
            }
          };
        }
        t.routers['A']!.onPacket(
          encodePacket(type: PacketType.discover),
          'self',
        );
        t.run();
        for (final n in 'BCD'.split('')) {
          expect(t.ofType(n, PacketType.discover), hasLength(1));
        }
        expect(t.ofType('A', PacketType.discover), hasLength(0));
        expect(
          t.ofType('A', PacketType.reply).map((x) => x.p.payload[0]).toList()
            ..sort(),
          [66, 67, 68],
        );
      },
    );

    test('(f) packet roundtrip and bad input', () {
      final id = newId(),
          p = encodePacket(
            type: PacketType.data,
            ttl: 5,
            hops: 2,
            id: id,
            dest: tag(7),
            payload: [9, 8],
          );
      final d = decodePacket(p);
      expect([d.type, d.ttl, d.hops], [10, 5, 2]);
      expect(d.id, id);
      expect(d.dest, tag(7));
      expect(d.payload, [9, 8]);
      final bad = Uint8List.fromList(p)..[0] = 2;
      expect(() => decodePacket(bad), throwsA(anything));
      expect(() => decodePacket(p.sublist(0, header - 1)), throwsA(anything));
      expect(
        () => encodePacket(type: 10, payload: Uint8List(70000)),
        throwsA(anything),
      );
    });
  });

  group('packet vectors', () {
    test('constants', () {
      final k = vec['packet']['constants'] as Map<String, dynamic>;
      expect(k['TYPE'], {
        'LINK_HELLO': PacketType.linkHello,
        'PING': PacketType.ping,
        'PONG': PacketType.pong,
        'DATA': PacketType.data,
        'ACK': PacketType.ack,
        'DEAD_END': PacketType.deadEnd,
        'DISCOVER': PacketType.discover,
        'REPLY': PacketType.reply,
        'APP': PacketType.app,
      });
      expect(k['TTL_DEFAULT'], ttlDefault);
      expect(k['HEADER'], header);
      expect(k['MAX_PACKET'], maxPacket);
    });

    test('roundtrip of all types', () {
      final cases = vec['packet']['roundtrip'] as List<dynamic>;
      expect(cases, hasLength(10));
      for (final cs in cases) {
        final i = cs['in'] as Map<String, dynamic>;
        final e = encodePacket(
          type: i['type'] as int,
          ttl: (i['ttl'] as int?) ?? ttlDefault,
          hops: (i['hops'] as int?) ?? 0,
          id: unhex(i['id'] as String),
          dest: i['dest'] == null ? null : unhex(i['dest'] as String),
          payload: i['payload'] == null ? null : unhex(i['payload'] as String),
        );
        final enc = cs['encoded'];
        if (enc is String) {
          expect(hex(e), enc, reason: cs['name'] as String);
        } else {
          expect(e.length, enc['len'], reason: cs['name'] as String);
          expect(
            hex(c.sha256.convert(e).bytes),
            enc['sha256'],
            reason: cs['name'] as String,
          );
        }
        final d = decodePacket(e);
        final dec = cs['decoded'] as Map<String, dynamic>;
        expect(d.type, dec['type']);
        expect(d.ttl, dec['ttl']);
        expect(d.hops, dec['hops']);
        expect(hex(d.id), dec['id']);
        expect(hex(d.dest), dec['dest']);
        final dp = dec['payload'];
        if (dp is String) {
          expect(hex(d.payload), dp);
        } else {
          expect(d.payload.length, dp['len']);
        }
      }
    });

    test('decode errors', () {
      final cases = vec['packet']['decodeBad'] as List<dynamic>;
      expect(cases, hasLength(5));
      for (final cs in cases) {
        final i = cs['in'];
        final input = i is String
            ? unhex(i)
            : (Uint8List(i['len'] as int)
                ..fillRange(0, i['len'] as int, i['first'] as int));
        expect(errMsg(() => decodePacket(input)), (cs['out'] as Map)['error']);
      }
    });

    test('encode errors', () {
      final cases = vec['packet']['encodeBad'] as List<dynamic>;
      expect(cases, hasLength(3));
      final idA = bytesOf('idA', 16);
      for (final cs in cases) {
        final i = cs['in'] as Map<String, dynamic>;
        Uint8List? mk(String k) =>
            i.containsKey(k) ? Uint8List(i[k] as int) : null;
        expect(
          errMsg(
            () => encodePacket(
              type: 10,
              id: mk('id') ?? idA,
              dest: mk('dest'),
              payload: mk('payload'),
            ),
          ),
          (cs['out'] as Map)['error'],
        );
      }
    });

    test('defaults and newId', () {
      final d = vec['packet']['defaults'] as Map<String, dynamic>;
      seed(d['rngSeed'] as String);
      newIdSource = () => rng!.take(16);
      expect(hex(encodePacket(type: PacketType.ping)), d['encoded']);
      seed(d['rngSeed'] as String);
      expect(hex(newId()), d['newId']);
    });
  });

  group('router vectors', () {
    final scenarios = <String, Map<String, dynamic> Function()>{
      'line6': () {
        final n = line(6);
        return sim('line6', n, lineEdges(n), (c) {
          c.inject('A', dataP(c.tagOf('F'), 8, ids(1)), 'self');
          c.run();
          c.mark('second data unicast');
          c.inject('A', dataP(c.tagOf('F'), 8, ids(2)), 'self');
          c.run();
          c.mark('absent recipient');
          c.inject('A', dataP(tag(99), 8, ids(3)), 'self');
          c.run();
          c.mark('duplicate id');
          c.inject('A', dataP(c.tagOf('F'), 8, ids(1)), 'self');
          c.run();
          c.mark('linkDown C');
          c.routers['C']!.linkDown('D');
          c.routers['D']!.linkDown('C');
          c.inject('A', dataP(c.tagOf('F'), 8, ids(4)), 'self');
          c.run();
        });
      },
      'diamond': () => sim(
        'diamond',
        ['A', 'B', 'C', 'D'],
        [
          ['A', 'B'],
          ['A', 'C'],
          ['B', 'D'],
          ['C', 'D'],
          ['B', 'C'],
        ],
        (c) {
          c.inject('A', dataP(c.tagOf('D'), 8, ids(10)), 'self');
          c.run();
          c.mark('again');
          c.inject('A', dataP(c.tagOf('D'), 8, ids(11)), 'self');
          c.run();
        },
      ),
      'line40-hops': () {
        final n = List.generate(40, (i) => 'n$i');
        final t = sim('line40-hops', n, lineEdges(n), (c) {
          c.inject('n0', dataP(c.tagOf('n39'), 1, ids(20)), 'self');
          c.run();
        });
        t['events'] = (t['events'] as List<Map<String, Object?>>)
            .where(
              (e) =>
                  e['e'] == 'deliver' || e['e'] == 'mark' || e['e'] == 'inject',
            )
            .toList();
        return t;
      },
      'discover': () {
        final n = line(4);
        return sim(
          'discover',
          n,
          [
            ...lineEdges(n),
            ['A', 'D'],
          ],
          (c) {
            for (final x in 'BCD'.split('')) {
              final r = c.routers[x]!, orig = r.deliver;
              r.deliver = (b, from) {
                orig(b, from);
                final p = decodePacket(b);
                if (p.type == PacketType.discover) {
                  r.onPacket(
                    encodePacket(
                      type: PacketType.reply,
                      dest: p.id,
                      id: bytesOf('reply:$x', 16),
                      payload: [x.codeUnitAt(0)],
                    ),
                    'self',
                  );
                }
              };
            }
            c.inject(
              'A',
              encodePacket(type: PacketType.discover, id: ids(30)),
              'self',
            );
            c.run();
          },
        );
      },
      'misc': () => sim(
        'misc',
        ['A', 'B', 'C'],
        [
          ['A', 'B'],
          ['B', 'C'],
        ],
        (c) {
          c.mark('garbage');
          c.routers['B']!.onPacket(Uint8List(10), 'A');
          c.routers['B']!.onPacket(
            Uint8List.fromList([9, ...List.filled(40, 0)]),
            'A',
          );
          c.mark('app');
          c.inject(
            'B',
            encodePacket(type: PacketType.app, id: ids(40), payload: [7]),
            'A',
          );
          c.mark('discover from A');
          c.inject(
            'B',
            encodePacket(type: PacketType.discover, id: ids(41)),
            'A',
          );
          c.run();
          c.mark('same discover again');
          c.inject(
            'B',
            encodePacket(type: PacketType.discover, id: ids(41)),
            'A',
          );
          c.run();
          c.mark('ack unknown');
          c.inject(
            'B',
            encodePacket(type: PacketType.ack, id: ids(42), dest: ids(43)),
            'C',
          );
          c.run();
          c.mark('data to self from A');
          c.inject('B', dataP(c.tagOf('B'), 8, ids(44)), 'A');
          c.run();
          c.mark('data hops');
          c.inject(
            'B',
            encodePacket(
              type: PacketType.data,
              id: ids(45),
              dest: tag(77),
              hops: 255,
            ),
            'A',
          );
          c.run();
          c.mark('expire');
          c.advance(11 * 60000);
          c.inject('B', dataP(c.tagOf('C'), 8, ids(46)), 'A');
          c.run();
          c.mark('route expiry');
          c.advance(11 * 60000);
          c.inject('B', dataP(c.tagOf('C'), 8, ids(47)), 'A');
          c.run();
          c.mark('no neighbours');
          c.routers['B']!.linkDown('A');
          c.routers['B']!.linkDown('C');
          c.inject('B', dataP(tag(55), 8, ids(48)), 'self');
        },
      ),
    };

    test('vector holds the 5 scenarios', () {
      expect(
        (vec['router'] as List).map((s) => s['label']).toList(),
        scenarios.keys.toList(),
      );
    });

    for (final name in scenarios.keys) {
      test(name, () {
        newIdSource = () => rng!.take(16);
        final want =
            (vec['router'] as List).firstWhere((s) => s['label'] == name)
                as Map<String, dynamic>;
        final got =
            jsonDecode(jsonEncode(scenarios[name]!())) as Map<String, dynamic>;
        expect(got['names'], want['names']);
        expect(got['selfTags'], want['selfTags']);
        expect(got['edges'], want['edges']);
        expect(got['events'], want['events']);
        expect(got['final'], want['final']);
      });
    }
  });
}
