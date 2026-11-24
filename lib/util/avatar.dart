import 'dart:math' as math;

import 'bytes.dart';

const int maxAvatar = 16 * 1024;

final RegExp _b64Body = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
final RegExp _spaces = RegExp(r'\s+');

const Map<int, String> _fullUpper = {
  0xDF: 'SS',
  0x149: '\u02BCN',
  0x1F0: 'J\u030C',
  0x587: '\u0535\u0552',
  0x1E96: 'H\u0331',
  0x1E97: 'T\u0308',
  0x1E98: 'W\u030A',
  0x1E99: 'Y\u030A',
  0x1E9A: 'A\u02BE',
  0xFB00: 'FF',
  0xFB01: 'FI',
  0xFB02: 'FL',
  0xFB03: 'FFI',
  0xFB04: 'FFL',
  0xFB05: 'ST',
  0xFB06: 'ST',
  0xFB13: '\u0544\u0546',
  0xFB14: '\u0544\u0535',
  0xFB15: '\u0544\u053B',
  0xFB16: '\u054E\u0546',
  0xFB17: '\u0544\u053D',
};

String jsUpper(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final special = _fullUpper[r];
    b.write(special ?? String.fromCharCode(r).toUpperCase());
  }
  return b.toString();
}

bool isAvatar(Object? s) {
  if (s is! String ||
      s.isEmpty ||
      s.length > (maxAvatar * 4 / 3).ceil() + 4 ||
      !_b64Body.hasMatch(s)) {
    return false;
  }
  try {
    final b = unb64(s);
    return b.length <= maxAvatar &&
        b.length >= 3 &&
        b[0] == 0xff &&
        b[1] == 0xd8 &&
        b[2] == 0xff;
  } catch (_) {
    return false;
  }
}

String _nameOrMark(String? name) => name == null || name.isEmpty ? '?' : name;

int avatarHue(String? name) {
  var h = 7;
  for (final r in _nameOrMark(name).runes) {
    final unit = r > 0xFFFF ? 0xD800 + ((r - 0x10000) >> 10) : r;
    h = (h * 31 + unit) % 360;
  }
  return h;
}

String avatarInitials(String? name) => jsUpper(
  _nameOrMark(name)
      .trim()
      .split(_spaces)
      .take(2)
      .map((w) => w.isEmpty ? '' : String.fromCharCode(w.runes.first))
      .join(),
);

String settingsInitials(String login) =>
    jsUpper(login.substring(0, math.min(2, login.length)));
