import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../util/bytes.dart';
import 'identity.dart';

typedef RandomBytes = Uint8List Function(int n);

const _tagLen = 16;
const _nonceLen = 12;

Future<Uint8List> gcmSeal(
  List<int> key,
  List<int> nonce,
  List<int> aad,
  List<int> plain,
) async {
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  return concat([box.cipherText, box.mac.bytes]);
}

Future<Uint8List> gcmOpen(
  List<int> key,
  List<int> nonce,
  List<int> aad,
  Uint8List ctTag,
) async {
  if (ctTag.length < _tagLen) throw RipploError('decrypt_failed');
  final split = ctTag.length - _tagLen;
  try {
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        Uint8List.sublistView(ctTag, 0, split),
        nonce: nonce,
        mac: Mac(Uint8List.sublistView(ctTag, split)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw RipploError('decrypt_failed');
  }
}

class Vault {
  Vault(List<int> rawKey, {this.insecure = false, RandomBytes rng = random})
    : _key = Uint8List.fromList(rawKey),
      _rng = rng {
    if (_key.length != 32) throw RipploError('bad_key');
  }

  final bool insecure;
  final Uint8List _key;
  final RandomBytes _rng;

  Future<Uint8List> seal(Uint8List bytes, Uint8List aad) async {
    final nonce = _rng(_nonceLen);
    return concat([nonce, await gcmSeal(_key, nonce, aad, bytes)]);
  }

  Future<Uint8List> open(Uint8List sealed, Uint8List aad) async {
    if (sealed.length < _nonceLen) throw RipploError('decrypt_failed');
    return gcmOpen(
      _key,
      Uint8List.sublistView(sealed, 0, _nonceLen),
      aad,
      Uint8List.sublistView(sealed, _nonceLen),
    );
  }
}
