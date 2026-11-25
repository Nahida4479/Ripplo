import 'dart:typed_data';

import '../util/bytes.dart' as b;
import '../util/js.dart' as js;
import 'packet.dart';

const selfNode = 'self';
const _expiryMs = 10 * 60 * 1000;
const _seenCap = 20000;

class Route {
  Route(this.n, this.t);
  final String n;
  final int t;
}

class Reverse {
  Reverse(this.prev, this.dest, this.t);
  final String prev;
  final String dest;
  final int t;
  int pending = 0;
  bool done = false;
}

typedef SendTo = void Function(String to, Uint8List bytes);
typedef Deliver = void Function(Uint8List bytes, String from);

class Router {
  Router({
    required List<int> selfTag,
    required this.sendTo,
    required this.deliver,
    int Function()? now,
  }) : selfHex = b.hex(selfTag),
       now = now ?? (() => js.now());

  final String selfHex;
  SendTo sendTo;
  Deliver deliver;
  int Function() now;
  final Map<String, int> seen = {};
  final Map<String, Reverse> reverse = {};
  final Map<String, Route> routes = {};
  final Set<String> links = {};

  List<String> neighbors() => links.toList();

  void linkUp(String n) => links.add(n);

  void linkDown(String n) {
    links.remove(n);
    routes.removeWhere((_, r) => r.n == n);
  }

  void onPacket(Uint8List bytes, String from) {
    final Packet p;
    try {
      p = decodePacket(bytes);
    } on FormatException {
      return;
    }
    expire();
    final id = b.hex(p.id), dest = b.hex(p.dest);
    switch (p.type) {
      case PacketType.app:
        deliver(bytes, from);
      case PacketType.data || PacketType.discover:
        if (isSeen(p, id)) {
          if (from != selfNode) sendDeadEnd(from, id);
          return;
        }
        markSeen(p, id);
        final r = Reverse(from, dest, now());
        reverse[id] = r;
        if (p.type == PacketType.data && dest == selfHex) {
          if (from != selfNode) send(from, PacketType.ack, p.id);
          deliver(bytes, from);
          return;
        }
        if (p.type == PacketType.discover && from != selfNode) {
          deliver(bytes, from);
        }
        final q = from == selfNode
            ? bytes
            : encodeFrom(p, hops: p.hops + 1 < 255 ? p.hops + 1 : 255);
        final route = p.type == PacketType.data ? routes[dest] : null;
        final targets =
            route != null && links.contains(route.n) && route.n != from
            ? [route.n]
            : neighbors().where((n) => n != from).toList();
        if (targets.isEmpty) {
          deadEnd(id);
          return;
        }
        r.pending = targets.length;
        for (final n in targets) {
          sendTo(n, q);
        }
      case PacketType.ack || PacketType.reply:
        if (isSeen(p, id)) return;
        markSeen(p, id);
        final r = reverse[dest];
        if (r == null) return;
        if (p.type == PacketType.ack) {
          if (from != selfNode) routes[r.dest] = Route(from, now());
          r.done = true;
        }
        final q = encodeFrom(p, hops: p.hops + 1 < 255 ? p.hops + 1 : 255);
        if (r.prev == selfNode) {
          deliver(q, selfNode);
        } else {
          sendTo(r.prev, q);
        }
      case PacketType.deadEnd:
        if (isSeen(p, id)) return;
        markSeen(p, id);
        final r = reverse[dest];
        if (r == null || r.done) return;
        if (--r.pending <= 0) deadEnd(dest);
    }
  }

  void deadEnd(String id) {
    final r = reverse[id]!;
    r.done = true;
    if (r.prev == selfNode) {
      deliver(
        encodePacket(type: PacketType.deadEnd, dest: b.unhex(id)),
        selfNode,
      );
    } else {
      sendDeadEnd(r.prev, id);
    }
  }

  void sendDeadEnd(String to, String id) =>
      send(to, PacketType.deadEnd, b.unhex(id));

  void send(String to, int type, List<int> dest) =>
      sendTo(to, encodePacket(id: newId(), type: type, dest: dest));

  bool isSeen(Packet p, String id) => seen.containsKey('${p.type}:$id');

  void markSeen(Packet p, String id) {
    seen['${p.type}:$id'] = now();
    if (seen.length > _seenCap) seen.remove(seen.keys.first);
  }

  void expire() {
    final cutoff = now() - _expiryMs;
    final oldSeen = <String>[];
    for (final e in seen.entries) {
      if (e.value > cutoff) break;
      oldSeen.add(e.key);
    }
    oldSeen.forEach(seen.remove);
    final oldRev = <String>[];
    for (final e in reverse.entries) {
      if (e.value.t > cutoff) break;
      oldRev.add(e.key);
    }
    oldRev.forEach(reverse.remove);
    routes.removeWhere((_, v) => v.t <= cutoff);
  }
}
