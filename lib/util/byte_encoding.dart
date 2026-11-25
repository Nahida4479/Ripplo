import 'dart:convert' as conv;
import 'dart:math';
import 'dart:typed_data';

const _b64chars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const _crockford = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _rng = Random.secure();
final _b64url = RegExp(r'^[A-Za-z0-9_-]*$');
final _hex = RegExp(r'^([0-9a-f]{2})*$', caseSensitive: false);
final _ws = RegExp(r'[\t\n\f\r ]');

Uint8List utf8(String s) => Uint8List.fromList(conv.utf8.encode(s));

String unutf8(List<int> b) => conv.utf8.decode(b, allowMalformed: true);

Uint8List random(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

String b64(List<int> bytes) => conv.base64.encode(bytes);

Uint8List unb64(String s) {
  var t = s.replaceAll(_ws, '');
  if (t.length % 4 == 0) {
    t = t.replaceFirst(RegExp(r'==?$'), '');
  }
  if (t.length % 4 == 1 || t.contains(RegExp(r'[^A-Za-z0-9+/]'))) {
    throw const FormatException('Invalid character');
  }
  final spare = const [0, 0, 15, 3][t.length % 4];
  if (spare != 0) {
    final i = _b64chars.indexOf(t[t.length - 1]) & ~spare;
    t = t.substring(0, t.length - 1) + _b64chars[i];
  }
  return Uint8List.fromList(
    conv.base64.decode(t.padRight((t.length + 3) ~/ 4 * 4, '=')),
  );
}

String b64url(List<int> bytes) => b64(
  bytes,
).replaceAll('+', '-').replaceAll('/', '_').replaceFirst(RegExp(r'=+$'), '');

Uint8List unb64url(String s) {
  if (!_b64url.hasMatch(s)) throw const FormatException('bad base64url');
  return unb64(
    s.replaceAll('-', '+').replaceAll('_', '/') +
        '=' * ((4 - s.length % 4) % 4),
  );
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  if (!_hex.hasMatch(s)) throw const FormatException('bad hex');
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List concat(Iterable<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.toBytes();
}

bool equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

ByteBuffer ab(Uint8List u8) => Uint8List.fromList(u8).buffer;

Uint8List u32(int n) => Uint8List.fromList([
  (n >> 24) & 255,
  (n >> 16) & 255,
  (n >> 8) & 255,
  n & 255,
]);

int readU32(List<int> b, int o) {
  int at(int i) => i >= 0 && i < b.length ? b[i] : 0;
  return ((at(o) << 24) | (at(o + 1) << 16) | (at(o + 2) << 8) | at(o + 3)) &
      0xffffffff;
}

String base32(List<int> bytes) {
  var bits = 0, acc = 0;
  final out = StringBuffer();
  for (final b in bytes) {
    acc = (acc << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(_crockford[(acc >> (bits - 5)) & 31]);
      bits -= 5;
    }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_crockford[(acc << (5 - bits)) & 31]);
  return out.toString();
}
