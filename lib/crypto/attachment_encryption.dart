import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../util/byte_encoding.dart';
import 'contact_card_codec.dart';
import 'database_vault.dart';

const chunkSize = 32 * 1024;
const _inlineLimit = 64 * 1024;

Future<Uint8List> _seal(Uint8List key, Uint8List nonce, Uint8List plain) =>
    plain.length < _inlineLimit
    ? gcmSeal(key, nonce, const [], plain)
    : Isolate.run(() => gcmSeal(key, nonce, const [], plain));

Future<Uint8List> _open(Uint8List key, Uint8List nonce, Uint8List body) =>
    body.length < _inlineLimit
    ? gcmOpen(key, nonce, const [], body)
    : Isolate.run(() => gcmOpen(key, nonce, const [], body));

Uint8List _sha256(Uint8List b) => Uint8List.fromList(c.sha256.convert(b).bytes);

Future<({Uint8List ct, Uint8List key, Uint8List sha256})> encryptFile(
  Uint8List bytes, {
  RandomBytes rng = random,
}) async {
  final key = rng(32), nonce = rng(12);
  final ct = concat([nonce, await _seal(key, nonce, bytes)]);
  return (ct: ct, key: key, sha256: _sha256(ct));
}

Future<Uint8List> decryptFile(Uint8List ct, Uint8List key) async {
  if (key.length != 32 || ct.length < 12) throw RipploError('decrypt_failed');
  return _open(
    key,
    Uint8List.sublistView(ct, 0, 12),
    Uint8List.sublistView(ct, 12),
  );
}

int chunkCount(Uint8List ct) => (ct.length + chunkSize - 1) ~/ chunkSize;

Uint8List chunkPayload(Uint8List attId, Uint8List ct, int index, int total) {
  final a = (index * chunkSize).clamp(0, ct.length),
      b = ((index + 1) * chunkSize).clamp(0, ct.length);
  return concat([
    Uint8List.fromList([2]),
    attId,
    u32(index),
    u32(total),
    Uint8List.sublistView(ct, a, b),
  ]);
}

({Uint8List attId, int index, int total, Uint8List bytes}) parseChunk(
  Uint8List payload,
) {
  if (payload.length < 25 || payload[0] != 2) {
    throw RipploError('bad_chunk', 'bad chunk');
  }
  return (
    attId: payload.sublist(1, 17),
    index: readU32(payload, 17),
    total: readU32(payload, 21),
    bytes: payload.sublist(25),
  );
}
