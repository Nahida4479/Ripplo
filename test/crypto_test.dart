import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:qr/qr.dart';
import 'package:ripplo/crypto/attachment_encryption.dart';
import 'package:ripplo/crypto/call_frame_encryption.dart';
import 'package:ripplo/crypto/contact_card_codec.dart';
import 'package:ripplo/crypto/database_vault.dart';
import 'package:ripplo/util/byte_encoding.dart';
import 'package:zxing2/qrcode.dart';

Uint8List sha(Uint8List b) => Uint8List.fromList(c.sha256.convert(b).bytes);

({Uint8List card, Uint8List ik, String link}) makeLink([
  String name = 'Alice',
  Random? rng,
]) {
  final bundle = rng == null
      ? random(1776)
      : Uint8List.fromList(List.generate(1776, (_) => rng.nextInt(256)));
  bundle[0] = 2;
  bundle[5] = 5;
  final card = encodeCard(name, bundle);
  return (card: card, ik: bundle.sublist(5, 38), link: encodeLink(card));
}

String? code(void Function() fn) {
  try {
    fn();
    return null;
  } on RipploError catch (e) {
    return e.code;
  }
}

String relink(Uint8List card) =>
    'ripplo://add/${b64url(card)}.${b64url(sha(card).sublist(0, 6))}';

void main() {
  group('bytes', () {
    test('base32 of 10 bytes is 16 chars', () {
      expect(base32(random(10)), hasLength(16));
      expect(base32(Uint8List(10)), '0' * 16);
    });
  });

  group('invite link', () {
    test('roundtrips, tolerates wrapping, rejects tampering', () {
      final m = makeLink();
      final v = parseLink(m.link);
      expect(v.card, m.card);
      expect(v.name, 'Alice');
      expect(v.ik, m.ik);
      expect(v.id, deriveIds(m.ik).ripploId);
      expect(formatId(v.id), matches(RegExp(r'^\w{4}-\w{4}-\w{4}-\w{4}$')));
      expect(
        parseLink(
          '  ${m.link.substring(0, 30)}\n ${m.link.substring(30)} \n',
        ).id,
        v.id,
      );
      expect(
        parseLink('join me: https://ripplo.app/add?x=${m.link} thanks').id,
        v.id,
      );
      final parts = m.link.split('.');
      final head = parts[0], sum = parts[1];
      expect(
        code(
          () => parseLink(
            '$head.${sum.substring(0, 7)}${sum[7] == 'A' ? 'B' : 'A'}',
          ),
        ),
        'bad_checksum',
      );
      final flipped =
          head.substring(0, 40) +
          (head[40] == 'A' ? 'B' : 'A') +
          head.substring(41);
      expect(code(() => parseLink('$flipped.$sum')), 'bad_checksum');
      expect(code(() => parseLink('hello')), 'bad_link');
    });

    test('rejects tampered or short cards', () {
      final card = makeLink().card;
      final nl = card[1];
      String? bad(Uint8List cc) => code(() => parseLink(relink(cc)));
      Uint8List v(int i, int x) {
        final cc = Uint8List.fromList(card);
        cc[i] = x;
        return cc;
      }

      expect(bad(card.sublist(0, 100)), 'bad_link');
      expect(bad(card.sublist(0, card.length - 1)), 'bad_link');
      expect(bad(concat([card, Uint8List(1)])), 'bad_link');
      expect(bad(v(0, 1)), 'bad_link');
      expect(bad(v(1, 0)), 'bad_link');
      expect(bad(v(1, 121)), 'bad_link');
      expect(bad(v(2 + nl, 1)), 'bad_link');
      expect(bad(v(2 + nl + 5, 4)), 'bad_link');
      expect(
        bad(
          concat([
            Uint8List.fromList([2, 2]),
            utf8('  '),
            card.sublist(2 + nl),
          ]),
        ),
        'bad_link',
      );
      expect(code(() => checkCard(Uint8List(0))), 'bad_link');
    });

    test('renders as a QR code that zxing decodes', () {
      final link = makeLink('A' * 40, Random(1)).link;
      expect(link.length, greaterThan(2300));
      final img = QrImage(
        QrCode(
          payload: QrPayload.fromString(link),
          errorCorrectLevel: QrErrorCorrectLevel.low,
        ),
      );
      const px = 6, quiet = 4;
      final n = img.moduleCount, size = (n + quiet * 2) * px;
      final pixels = Int32List(size * size)
        ..fillRange(0, size * size, 0xffffffff);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final mx = x ~/ px - quiet, my = y ~/ px - quiet;
          if (mx >= 0 && my >= 0 && mx < n && my < n && img.isDark(my, mx)) {
            pixels[y * size + x] = 0xff000000;
          }
        }
      }
      final bitmap = BinaryBitmap(
        HybridBinarizer(RGBLuminanceSource(size, size, pixels)),
      );
      expect(QRCodeReader().decode(bitmap).text, link);
    });
  });

  group('attachment', () {
    test('encrypts, chunks and decrypts 100 KB', () async {
      final file = random(100 * 1024);
      final enc = await encryptFile(file);
      expect(enc.sha256, sha(enc.ct));
      final total = chunkCount(enc.ct);
      expect(total, ((100 * 1024 + 28) / chunkSize).ceil());
      final attId = random(16);
      final parts = List.generate(
        total,
        (i) => parseChunk(chunkPayload(attId, enc.ct, i, total)),
      );
      expect(
        parts.indexed.every((e) => e.$2.index == e.$1 && e.$2.total == total),
        isTrue,
      );
      final joined = concat(parts.map((p) => p.bytes));
      expect(await decryptFile(joined, enc.key), file);
      joined[40] ^= 1;
      await expectLater(
        decryptFile(joined, enc.key),
        throwsA(isA<RipploError>()),
      );
    });
  });

  group('regressions', () {
    test('final sigma uses Cased and Case_Ignorable like JS', () {
      expect(normName('\u03a3'), '\u03c3');
      expect(normName('\u0391\u03a3'), '\u03b1\u03c2');
      expect(normName('\u0391\u03a3\u{1F150}'), '\u03b1\u03c3\u{1F150}');
      expect(normName('\u0391\u03a3\u055f\u0392'), '\u03b1\u03c3\u055f\u03b2');
      expect(normName('\u0391\u03a3\u05f4'), '\u03b1\u03c2\u05f4');
    });

    test(
      'short ciphertext fails the future instead of throwing synchronously',
      () async {
        await expectLater(
          Vault(Uint8List(32)).open(Uint8List(3), Uint8List(0)),
          throwsA(isA<RipploError>()),
        );
        await expectLater(
          decryptFile(Uint8List(3), Uint8List(32)),
          throwsA(isA<RipploError>()),
        );
      },
    );

    test('sealFrame refuses role or seq that would wrap the nonce', () async {
      final key = importCallKey(Uint8List(32)),
          id = Uint8List(8),
          p = Uint8List(1);
      expect(
        await sealFrame(key, id, 1, 0xffffffff, p),
        hasLength(1 + 8 + 4 + 1 + 16),
      );
      for (final (role, seq) in [
        (0, 0x100000000),
        (0, -1),
        (256, 0),
        (-1, 0),
      ]) {
        await expectLater(
          sealFrame(key, id, role, seq, p),
          throwsA(isA<RipploError>()),
        );
      }
    });
  });
}
