import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/crypto/attachment_encryption.dart';
import 'package:ripplo/crypto/call_frame_encryption.dart';
import 'package:ripplo/crypto/contact_card_codec.dart';
import 'package:ripplo/crypto/database_vault.dart';
import 'package:ripplo/util/byte_encoding.dart';

Uint8List h(Object? s) => unhex(s as String);

RandomBytes fixed(List<Uint8List> queue) {
  final q = Queue.of(queue);
  return (n) {
    final v = q.removeFirst();
    expect(v.length, n);
    return v;
  };
}

Future<RipploError> failure(Future<Object?> Function() f) async {
  try {
    await f();
  } on RipploError catch (e) {
    return e;
  }
  fail('expected RipploError');
}

RipploError failureSync(Object? Function() f) {
  try {
    f();
  } on RipploError catch (e) {
    return e;
  }
  fail('expected RipploError');
}

void main() {
  final all =
      jsonDecode(File('test/vectors/js_vectors.json').readAsStringSync())
          as Map<String, dynamic>;

  group('identity', () {
    final v = all['identity'] as Map<String, dynamic>;

    test('deriveIds', () {
      for (final e in v['deriveIds'] as List) {
        final r = deriveIds(h(e['ik']));
        expect(hex(r.tag), e['tag']);
        expect(r.ripploId, e['ripploId']);
        expect(formatId(r.ripploId), e['formatted']);
      }
    });

    test('cleanName', () {
      for (final e in v['cleanName'] as List) {
        expect(cleanName(e['in']), e['out'], reason: jsonEncode(e['in']));
      }
    });

    test('cleanName null, undefined and number', () {
      final inputs = {'null': null, 'undefined': null, '42': 42};
      for (final e in v['cleanNameNull'] as List) {
        expect(cleanName(inputs[e['in']]), e['out']);
      }
    });

    test('encodeCard', () {
      for (final e in v['encodeCard'] as List) {
        expect(hex(encodeCard(e['name'], h(e['bundle']))), e['out']);
      }
    });

    test('encodeLink with and without token', () {
      for (final e in v['encodeLink'] as List) {
        final t = e['token'];
        expect(encodeLink(h(e['card']), t == null ? null : h(t)), e['out']);
      }
    });

    test('webLink and webLinkBad', () {
      for (final e in v['webLink'] as List) {
        expect(webLink(e['in'], e['lang']), e['out']);
      }
      final b = v['webLinkBad'] as Map;
      expect(
        failureSync(() => webLink(b['in'], 'en')).code,
        (b['out'] as Map)['error'],
      );
    });

    test('parseLink', () {
      for (final e in v['parseLink'] as List) {
        final out = e['out'] as Map;
        if (out.containsKey('error')) {
          expect(failureSync(() => parseLink(e['in'])).code, out['error']);
          continue;
        }
        final r = parseLink(e['in']);
        expect(r.id, out['id']);
        expect(hex(r.tag), out['tag']);
        expect(hex(r.ik), out['ik']);
        expect(r.name, out['name']);
        expect(hex(r.bundle), out['bundle']);
        expect(hex(r.card), out['card']);
        expect(r.token, out['token']);
      }
    });

    test('checkCardBad', () {
      for (final e in v['checkCardBad'] as List) {
        expect(
          failureSync(() => checkCard(h(e['in']))).code,
          (e['out'] as Map)['error'],
        );
      }
    });
  });

  group('vault', () {
    test('seal, open, wrong aad, tamper', () async {
      for (final e in all['vault'] as List) {
        final vault = Vault(h(e['key']), rng: fixed([h(e['nonce'])]));
        final aad = utf8((e['aad'] ?? '') as String);
        final sealed = await vault.seal(h(e['plain']), aad);
        expect(hex(sealed), e['sealed'], reason: e['name']);
        final plain = await Vault(h(e['key'])).open(h(e['sealed']), aad);
        expect(hex(plain), e['opened']);
        expect(e['wrongAad'], 'fail');
        final wrong = await failure(
          () => Vault(h(e['key'])).open(sealed, utf8('x/${e['aad'] ?? ''}')),
        );
        expect(wrong.code, 'decrypt_failed');
        expect(e['tamper'], 'fail');
        final t = Uint8List.fromList(sealed);
        t[t.length - 1] ^= 1;
        expect(
          (await failure(() => Vault(h(e['key'])).open(t, aad))).code,
          'decrypt_failed',
        );
        final t2 = Uint8List.fromList(sealed);
        t2[0] ^= 1;
        expect(
          (await failure(() => Vault(h(e['key'])).open(t2, aad))).code,
          'decrypt_failed',
        );
      }
    });
  });

  group('attachment', () {
    final a = all['attachment'] as Map<String, dynamic>;

    test('chunk size', () => expect(chunkSize, a['chunkSize']));

    test('encryptFile, decryptFile, chunks', () async {
      for (final e in a['encrypt'] as List) {
        final enc = await encryptFile(
          h(e['plain']),
          rng: fixed([h(e['key']), h(e['nonce'])]),
        );
        expect(hex(enc.key), e['key']);
        expect(hex(enc.ct), e['ct'], reason: e['name']);
        expect(hex(enc.sha256), e['sha256']);
        expect(hex(await decryptFile(enc.ct, enc.key)), e['decrypted']);
        expect(chunkCount(enc.ct), e['chunkCount']);
        final attId = h(e['attId']);
        for (final ch in e['chunks'] as List) {
          final p = chunkPayload(attId, enc.ct, ch['index'], e['chunkCount']);
          expect(hex(p), ch['payload']);
          final parsed = parseChunk(p);
          final pe = ch['parsed'] as Map;
          expect(hex(parsed.attId), pe['attId']);
          expect(parsed.index, pe['index']);
          expect(parsed.total, pe['total']);
          expect(hex(parsed.bytes), pe['bytes']);
        }
      }
    });

    test('parseChunkBad', () {
      for (final e in a['parseChunkBad'] as List) {
        expect(
          failureSync(() => parseChunk(h(e['in']))).message,
          (e['out'] as Map)['error'],
        );
      }
    });

    test('decryptBadKey', () async {
      final b = a['decryptBadKey'] as Map;
      expect(b['out'], 'fail');
      expect(
        (await failure(() => decryptFile(h(b['ct']), h(b['key'])))).code,
        'decrypt_failed',
      );
    });
  });

  group('callFrame', () {
    final f = all['callFrame'] as Map<String, dynamic>;
    final key = importCallKey(h(f['key']));
    final callId = h(f['callId']);

    test('tag', () => expect(frameTag, f['tag']));

    test('sealFrame and openFrame', () async {
      for (final e in f['sealFrame'] as List) {
        final role = e['role'] as int, seq = e['seq'] as int;
        final sealed = await sealFrame(key, callId, role, seq, h(e['plain']));
        expect(hex(sealed), e['sealed'], reason: 'role $role seq $seq');
        final opened = await openFrame(key, callId, role, sealed);
        expect(opened.seq, e['openedSeq']);
        expect(hex(opened.plain), e['opened']);
        expect(e['wrongRole'], 'fail');
        expect(
          (await failure(() => openFrame(key, callId, 1 - role, sealed))).code,
          'decrypt_failed',
        );
      }
    });

    test('packFrames and unpackFrames', () {
      for (final e in f['packFrames'] as List) {
        final frames = (e['frames'] as List).map(h).toList();
        final packed = packFrames(frames);
        expect(hex(packed), e['packed']);
        expect(unpackFrames(packed).map(hex).toList(), e['unpacked']);
      }
    });

    test('packFramesBad', () {
      for (final e in f['packFramesBad'] as List) {
        final frames = (e['frames'] as List).map(h).toList();
        expect(
          failureSync(() => packFrames(frames)).message,
          (e['out'] as Map)['error'],
        );
      }
    });

    test('unpackFramesBad', () {
      for (final e in f['unpackFramesBad'] as List) {
        expect(
          failureSync(() => unpackFrames(h(e['in']))).message,
          (e['out'] as Map)['error'],
        );
      }
    });

    test('openFrameBad', () async {
      for (final e in f['openFrameBad'] as List) {
        final err = await failure(() => openFrame(key, callId, 0, h(e['in'])));
        final want = e['out'] as String;
        expect(
          err.code,
          e['name'] == 'tamper' ? 'decrypt_failed' : want,
          reason: e['name'],
        );
      }
    });

    test('replay window', () {
      for (final e in f['replay'] as List) {
        final r = createReplay(e['size']);
        final out = [for (final s in e['seqs'] as List) r.accept(s)];
        expect(out, e['out']);
      }
    });
  });

  group('findHash', () {
    test('prefix and length', () {
      final p = all['findHashPrefix'] as Map;
      expect(findPrefix, p['prefix']);
      expect(findHashBytes, p['hashBytes']);
    });

    test('normalisation and hash', () {
      for (final e in all['findHash'] as List) {
        final norm = normName(e['name']);
        expect(norm, e['norm'], reason: jsonEncode(e['name']));
        expect(hex(utf8(norm)), e['normHex'], reason: jsonEncode(e['name']));
        expect(findHash(norm), e['hash'], reason: jsonEncode(e['name']));
        expect(findKey(e['name']), e['hash']);
      }
    });

    test('sha256 is the digest of prefix + norm', () {
      final d = c.sha256.convert(utf8('${findPrefix}anna')).bytes;
      expect(b64url(d.sublist(0, 8)), 'pNufAPCj4Ko');
    });
  });
}
