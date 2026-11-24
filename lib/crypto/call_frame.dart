import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../util/bytes.dart';
import 'identity.dart';
import 'vault.dart';

const frameTag = 1;
const _maxFrames = 8;
const _maxOpus = 1275;

SecretKey importCallKey(List<int> raw) {
  if (raw.length != 32) throw RipploError('bad_key');
  return SecretKey(Uint8List.fromList(raw));
}

Uint8List _nonce(int role, int seq) {
  final n = Uint8List(12);
  n[0] = role & 255;
  n.setRange(4, 8, u32(seq));
  return n;
}

Uint8List _aad(Uint8List callId, int seq) => concat([callId, u32(seq)]);

Future<List<int>> _raw(SecretKey key) => key.extractBytes();

Future<Uint8List> sealFrame(
  SecretKey key,
  Uint8List callId,
  int role,
  int seq,
  Uint8List plain,
) async {
  if (role < 0 || role > 255 || seq < 0 || seq > 0xffffffff) {
    throw RipploError('bad_frame');
  }
  final ct = await gcmSeal(
    await _raw(key),
    _nonce(role, seq),
    _aad(callId, seq),
    plain,
  );
  return concat([
    Uint8List.fromList([frameTag]),
    callId,
    u32(seq),
    ct,
  ]);
}

Future<({int seq, Uint8List plain})> openFrame(
  SecretKey key,
  Uint8List callId,
  int role,
  Uint8List packet,
) async {
  if (packet.length < 29 || packet[0] != frameTag) {
    throw RipploError('bad_frame');
  }
  for (var i = 0; i < 8; i++) {
    if (i >= callId.length || packet[1 + i] != callId[i]) {
      throw RipploError('bad_call');
    }
  }
  final seq = readU32(packet, 9);
  final plain = await gcmOpen(
    await _raw(key),
    _nonce(role, seq),
    _aad(callId, seq),
    Uint8List.sublistView(packet, 13),
  );
  return (seq: seq, plain: plain);
}

Uint8List packFrames(List<Uint8List> frames) {
  if (frames.isEmpty || frames.length > _maxFrames) {
    throw RipploError('bad_frames');
  }
  final parts = <Uint8List>[
    Uint8List.fromList([frames.length]),
  ];
  for (final f in frames) {
    if (f.isEmpty || f.length > _maxOpus) throw RipploError('bad_frames');
    parts
      ..add(Uint8List.fromList([f.length >> 8, f.length & 255]))
      ..add(f);
  }
  return concat(parts);
}

List<Uint8List> unpackFrames(Uint8List b) {
  final n = b.isEmpty ? 0 : b[0];
  if (n == 0 || n > _maxFrames) throw RipploError('bad_frames');
  final out = <Uint8List>[];
  var p = 1;
  for (var i = 0; i < n; i++) {
    if (p + 2 > b.length) throw RipploError('bad_frames');
    final len = (b[p] << 8) | b[p + 1];
    p += 2;
    if (len == 0 || len > _maxOpus || p + len > b.length) {
      throw RipploError('bad_frames');
    }
    out.add(Uint8List.sublistView(b, p, p + len));
    p += len;
  }
  if (p != b.length) throw RipploError('bad_frames');
  return out;
}

class Replay {
  Replay([this.size = 64]);

  final int size;
  int _max = -1;
  final Set<int> _seen = {};

  bool accept(int seq) {
    if (seq + size <= _max || _seen.contains(seq)) return false;
    _seen.add(seq);
    if (seq > _max) {
      _max = seq;
      _seen.removeWhere((s) => s + size <= _max);
    }
    return true;
  }
}

Replay createReplay([int size = 64]) => Replay(size);
