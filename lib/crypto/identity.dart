import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../util/bytes.dart';
import '../util/js.dart';

class RipploError implements Exception {
  RipploError(this.code, [String? message]) : message = message ?? code;

  final String code;
  final String message;

  @override
  String toString() => 'RipploError($code): $message';
}

class ParsedCard {
  ParsedCard({
    required this.id,
    required this.tag,
    required this.ik,
    required this.name,
    required this.bundle,
    required this.card,
    this.token,
  });

  final String id;
  final Uint8List tag;
  final Uint8List ik;
  final String name;
  final Uint8List bundle;
  final Uint8List card;
  final String? token;
}

const _maxName = 40;
const _maxNameBytes = 120;
const _bundle = 1776;
const _site = 'https://nahida4479.github.io/Ripplo';
const findPrefix = 'ripplo-find-v1\u0000';
const findHashBytes = 8;

final _badChars = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]',
);
final _trimRe = RegExp(r'^\s+|\s+$');
final _wsRun = RegExp(r'\s+');
final _linkRe = RegExp(
  r'(?:ripplo:\/\/add\/|https:\/\/nahida4479\.github\.io\/Ripplo\/(?:pl\/)?add\/?#)([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]{8})(?:\.([A-Za-z0-9_-]{11}))?',
);
final _webRe = RegExp(r'^ripplo:\/\/add\/(.+)$');
final _cased = RegExp(r'\p{Cased}', unicode: true);
final _caseIgnorable = RegExp(r'\p{Case_Ignorable}', unicode: true);

Uint8List _sha256(List<int> b) => Uint8List.fromList(c.sha256.convert(b).bytes);

String _jsTrim(String s) => s.replaceAll(_trimRe, '');

String cleanName(Object? s) => cut(
  _jsTrim((s == null ? '' : '$s').replaceAll(_badChars, '')),
  0,
  _maxName,
);

({Uint8List tag, String ripploId}) deriveIds(Uint8List ik33) {
  final tag = _sha256(ik33).sublist(0, 16);
  return (tag: tag, ripploId: base32(tag.sublist(0, 10)));
}

String formatId(String id) =>
    RegExp('.{4}').allMatches(id).map((m) => m[0]!).join('-');

Uint8List encodeCard(String name, Uint8List bundle) {
  final n = utf8(cleanName(name));
  return concat([
    Uint8List.fromList([2, n.length]),
    n,
    bundle,
  ]);
}

ParsedCard checkCard(Uint8List card) {
  RipploError bad() => RipploError('bad_link', 'invalid contact card');
  if (card.length < 2 + _bundle || card[0] != 2) throw bad();
  final len = card[1];
  if (len < 1 || len > _maxNameBytes || card.length != 2 + len + _bundle) {
    throw bad();
  }
  final name = cleanName(unutf8(Uint8List.sublistView(card, 2, 2 + len)));
  final bundle = Uint8List.sublistView(card, 2 + len);
  if (name.isEmpty || bundle[0] != 2 || bundle[5] != 5) throw bad();
  final ik = bundle.sublist(5, 38);
  final ids = deriveIds(ik);
  return ParsedCard(
    id: ids.ripploId,
    tag: ids.tag,
    ik: ik,
    name: name,
    bundle: bundle,
    card: card,
  );
}

String encodeLink(Uint8List card, [Uint8List? token]) {
  final sum = b64url(_sha256(card).sublist(0, 6));
  return 'ripplo://add/${b64url(card)}.$sum${token != null && token.isNotEmpty ? '.${b64url(token)}' : ''}';
}

String webLink(String link, String? lang) {
  final m = _webRe.firstMatch(link);
  if (m == null) throw RipploError('bad_link', 'not a Ripplo link');
  return '$_site${lang == 'pl' ? '/pl' : ''}/add/#${m[1]}';
}

ParsedCard parseLink(Object? text) {
  final m = _linkRe.firstMatch('$text'.replaceAll(_wsRun, ''));
  if (m == null) throw RipploError('bad_link', 'not a Ripplo link');
  Uint8List card;
  try {
    card = unb64url(m[1]!);
    if (!equal(_sha256(card).sublist(0, 6), unb64url(m[2]!))) {
      throw RipploError('bad_checksum', 'link is corrupted');
    }
  } catch (e) {
    throw e is RipploError ? e : RipploError('bad_link', 'not a Ripplo link');
  }
  final v = checkCard(card);
  final token = m[3];
  return token == null
      ? v
      : ParsedCard(
          id: v.id,
          tag: v.tag,
          ik: v.ik,
          name: v.name,
          bundle: v.bundle,
          card: v.card,
          token: token,
        );
}

String jsLowerCase(String s) {
  final runes = s.runes.toList();
  bool isCased(int i) => _cased.hasMatch(String.fromCharCode(runes[i]));
  bool ignorable(int i) =>
      _caseIgnorable.hasMatch(String.fromCharCode(runes[i]));
  bool finalSigma(int i) {
    var j = i - 1;
    while (j >= 0 && ignorable(j)) {
      j--;
    }
    if (j < 0 || !isCased(j)) return false;
    j = i + 1;
    while (j < runes.length && ignorable(j)) {
      j++;
    }
    return j >= runes.length || !isCased(j);
  }

  final out = StringBuffer();
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (r == 0x3a3) {
      out.write(finalSigma(i) ? '\u03c2' : '\u03c3');
    } else if (r == 0x130) {
      out.write('i\u0307');
    } else {
      out.write(String.fromCharCode(r).toLowerCase());
    }
  }
  return out.toString();
}

String normName(Object? s) =>
    _jsTrim(jsLowerCase(unorm.nfkc('$s')).replaceAll(_wsRun, ' '));

String findHash(String norm) =>
    b64url(_sha256(utf8('$findPrefix$norm')).sublist(0, findHashBytes));

String findKey(Object? text) => findHash(normName(text));

bool matchesQuery(Object? text, Object? name) =>
    normName(name) == normName(text);
