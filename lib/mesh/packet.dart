import 'dart:typed_data';

import '../util/bytes.dart' as b;

abstract final class PacketType {
  static const linkHello = 1;
  static const ping = 2;
  static const pong = 3;
  static const data = 10;
  static const ack = 11;
  static const deadEnd = 12;
  static const discover = 13;
  static const reply = 14;
  static const app = 20;
}

const ttlDefault = 8;
const header = 36;
const maxPacket = 65536;

final Uint8List zero16 = Uint8List(16);

Uint8List Function() newIdSource = () => b.random(16);

Uint8List newId() => newIdSource();

class Packet {
  Packet({
    required this.type,
    required this.ttl,
    required this.hops,
    required this.id,
    required this.dest,
    required this.payload,
  });

  final int type;
  final int ttl;
  final int hops;
  final Uint8List id;
  final Uint8List dest;
  final Uint8List payload;

  Packet copyWith({int? hops}) => Packet(
    type: type,
    ttl: ttl,
    hops: hops ?? this.hops,
    id: id,
    dest: dest,
    payload: payload,
  );
}

Uint8List encodePacket({
  required int type,
  int ttl = ttlDefault,
  int hops = 0,
  List<int>? id,
  List<int>? dest,
  List<int>? payload,
}) {
  final i = id ?? newId();
  final d = dest ?? zero16;
  final p = payload ?? const <int>[];
  if (i.length != 16 || d.length != 16) {
    throw const FormatException('bad id/dest length');
  }
  if (header + p.length > maxPacket) {
    throw const FormatException('packet too large');
  }
  final out = Uint8List(header + p.length);
  out[0] = 1;
  out[1] = type & 0xff;
  out[2] = ttl & 0xff;
  out[3] = hops & 0xff;
  out.setRange(4, 20, i);
  out.setRange(20, 36, d);
  out.setRange(header, out.length, p);
  return out;
}

Packet decodePacket(Uint8List bytes) {
  if (bytes.length < header) throw const FormatException('short packet');
  if (bytes.length > maxPacket) throw const FormatException('packet too large');
  if (bytes[0] != 1) throw const FormatException('bad version');
  return Packet(
    type: bytes[1],
    ttl: bytes[2],
    hops: bytes[3],
    id: bytes.sublist(4, 20),
    dest: bytes.sublist(20, 36),
    payload: bytes.sublist(header),
  );
}

Uint8List encodeFrom(Packet p, {int? hops}) => encodePacket(
  type: p.type,
  ttl: p.ttl,
  hops: hops ?? p.hops,
  id: p.id,
  dest: p.dest,
  payload: p.payload,
);
