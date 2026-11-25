import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/mesh/dev/dev_signal.dart';
import 'package:ripplo/util/bytes.dart';

Uint8List seeded(String label, int n) {
  var buf = Uint8List(0);
  var i = 0;
  while (buf.length < n) {
    buf = concat([buf, c.sha256.convert(utf8('$label#${i++}')).bytes]);
  }
  return buf.sublist(0, n);
}

Uint8List bundle(String label) {
  final b = seeded(label, 1776);
  b[0] = 2;
  b[5] = 5;
  return b;
}

DevSignal signal(Uint8List b) => DevSignal(
  store: DevBundleStore(get: () => Uint8List.fromList(b), set: (_) {}),
);

Future<String> code(Future<Object?> Function() f) async {
  try {
    await f();
  } on MeshError catch (e) {
    return e.code;
  }
  return '';
}

void main() {
  final all =
      jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final v = all['devSignal'] as Map<String, dynamic>;
  final bA = bundle('bundleA');
  final bB = bundle('bundleB');
  final sigA = signal(bA);
  final sigB = signal(bB);
  final by = {hex(bA.sublist(5, 38)): sigA, hex(bB.sublist(5, 38)): sigB};

  test('proof and safety number', () async {
    for (final p in v['proofs'] as List) {
      final sig = by[p['ik']]!;
      final proof = await sig.signalProof(
        unhex(p['other']),
        unhex(p['n']),
        unhex(p['challengerTag']),
        unhex(p['proverTag']),
      );
      expect(hex(proof), p['proof']);
      expect(await sig.signalSafetyNumber(unhex(p['other'])), p['safety']);
    }
    expect(await sigA.signalSafetyNumber(sigA.ik), v['safetySelf']);
  });

  test('seal and open', () async {
    for (final m in v['seal'] as List) {
      final s = signal(bA);
      final tag = await s.signalAddContact(bB);
      expect(tag, m['tag']);
      final sealed = await s.signalSeal(tag, Uint8List.fromList([1, 2, 3]));
      expect(hex(sealed), m['sealed']);
      final o = await sigB.signalOpen(sealed);
      expect(o.tag, m['opened']['tag']);
      expect(hex(o.ik), m['opened']['ik']);
      expect(hex(o.plaintext), m['opened']['plaintext']);
    }
  });

  test('errors and forget', () async {
    final s = signal(bA);
    expect(await code(() => s.signalSeal('00', Uint8List(1))), 'no_session');
    expect(await code(() => s.signalAddContact(Uint8List(10))), 'bad_bundle');
    expect(await code(() => s.signalOpen(Uint8List(10))), 'bad_message');
    final tag = await s.signalAddContact(bB);
    await s.signalForget(tag);
    expect(await code(() => s.signalSeal(tag, Uint8List(1))), 'no_session');
  });

  test('fresh bundle is stored', () async {
    Uint8List? saved;
    final s = DevSignal(
      store: DevBundleStore(get: () => saved, set: (b) => saved = b),
    );
    expect(saved, isNotNull);
    expect(saved!.length, 1776);
    expect(saved![0], 2);
    expect(saved![5], 5);
    expect(s.ik, saved!.sublist(5, 38));
  });
}
