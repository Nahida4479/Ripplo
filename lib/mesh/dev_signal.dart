import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;

import '../util/bytes.dart';
import 'bridge.dart';

const _bundleLen = 1776;
const _mark = 0xee;

String _tagOf(Uint8List ik) => hex(c.sha256.convert(ik).bytes.sublist(0, 16));

Uint8List _sorted(Uint8List a, Uint8List b) =>
    hex(a).compareTo(hex(b)) <= 0 ? concat([a, b]) : concat([b, a]);

MeshError _bad(String code) => MeshError(code, code);

class DevBundleStore {
  const DevBundleStore({required this.get, required this.set});

  final Uint8List? Function() get;
  final void Function(Uint8List bundle) set;
}

class DevSignal {
  DevSignal({DevBundleStore? store, Uint8List Function(int n) rng = random}) {
    final saved = store?.get();
    bundle = saved ?? rng(_bundleLen);
    if (saved == null) {
      bundle[0] = 2;
      bundle.setRange(
        5,
        38,
        concat([
          [5],
          rng(32),
        ]),
      );
      store?.set(bundle);
    }
    ik = bundle.sublist(5, 38);
  }

  late final Uint8List bundle;
  late final Uint8List ik;
  final Map<String, Uint8List> _known = {};

  Future<({Uint8List bundle, Uint8List ik})> signalInit() async =>
      (bundle: bundle, ik: ik);

  Future<String> signalAddContact(Uint8List b) async {
    if (b.length != _bundleLen || b[0] != 2 || b[5] != 5) {
      throw _bad('bad_bundle');
    }
    final key = b.sublist(5, 38);
    final tag = _tagOf(key);
    _known[tag] = key;
    return tag;
  }

  Future<Uint8List> signalSeal(String tag, Uint8List plaintext) async {
    if (!_known.containsKey(tag)) {
      throw _bad('no_session');
    }
    return concat([
      [_mark],
      ik,
      plaintext,
    ]);
  }

  Future<({String tag, Uint8List ik, Uint8List plaintext})> signalOpen(
    Uint8List payload,
  ) async {
    if (payload.length < 34 || payload[0] != _mark || payload[1] != 5) {
      throw _bad('bad_message');
    }
    final key = payload.sublist(1, 34);
    final tag = _tagOf(key);
    _known[tag] = key;
    return (tag: tag, ik: key, plaintext: payload.sublist(34));
  }

  Future<Uint8List> signalProof(
    Uint8List other,
    Uint8List n,
    Uint8List challengerTag,
    Uint8List proverTag,
  ) async {
    final key = c.sha256.convert(_sorted(ik, other)).bytes;
    return Uint8List.fromList(
      c.Hmac(
        c.sha256,
        key,
      ).convert(concat([n, challengerTag, proverTag])).bytes,
    );
  }

  Future<String> signalSafetyNumber(Uint8List other) async {
    final h = c.sha512.convert(_sorted(ik, other)).bytes;
    final out = StringBuffer();
    for (var i = 0; i < 60; i += 5) {
      final v =
          h.sublist(i, i + 5).fold<int>(0, (a, b) => a * 256 + b) % 100000;
      out.write(v.toString().padLeft(5, '0'));
    }
    return out.toString();
  }

  Future<void> signalForget(String tag) async {
    _known.remove(tag);
  }
}
