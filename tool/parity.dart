import 'dart:io';

import 'package:image/image.dart' as img;

const double kMaxPercent = 1.5;
const int kChannelDelta = 16;

class Diff {
  Diff(this.percent, this.overlay);
  final double percent;
  final img.Image overlay;
}

Diff diffImages(img.Image a, img.Image b) {
  final w = a.width > b.width ? a.width : b.width;
  final h = a.height > b.height ? a.height : b.height;
  final overlay = img.Image(width: w, height: h);
  var bad = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inA = x < a.width && y < a.height;
      final inB = x < b.width && y < b.height;
      var differs = inA != inB;
      if (!differs) {
        final p = a.getPixel(x, y);
        final q = b.getPixel(x, y);
        differs =
            (p.r - q.r).abs() > kChannelDelta ||
            (p.g - q.g).abs() > kChannelDelta ||
            (p.b - q.b).abs() > kChannelDelta ||
            (p.a - q.a).abs() > kChannelDelta;
      }
      if (differs) {
        bad++;
        overlay.setPixelRgb(x, y, 255, 0, 0);
      } else {
        final p = inA ? a.getPixel(x, y) : b.getPixel(x, y);
        overlay.setPixelRgb(
          x,
          y,
          (p.r * 0.3 + 178).round(),
          (p.g * 0.3 + 178).round(),
          (p.b * 0.3 + 178).round(),
        );
      }
    }
  }
  return Diff(100.0 * bad / (w * h), overlay);
}

int run(
  String goldens,
  String ref,
  String out, {
  List<String> only = const [],
}) {
  final gd = Directory(goldens);
  final rd = Directory(ref);
  final names = <String>{
    if (rd.existsSync())
      for (final f in rd.listSync().whereType<File>())
        if (f.path.endsWith('.png')) f.uri.pathSegments.last,
    if (gd.existsSync())
      for (final f in gd.listSync().whereType<File>())
        if (f.path.endsWith('.png')) f.uri.pathSegments.last,
  }.where((n) => only.isEmpty || only.any(n.startsWith)).toList()..sort();
  Directory(out).createSync(recursive: true);
  var fail = false;
  stdout.writeln('${'screen'.padRight(36)} mismatch%  status');
  for (final n in names) {
    final g = File('$goldens/$n');
    final r = File('$ref/$n');
    final label = n.substring(0, n.length - 4).padRight(36);
    if (!r.existsSync()) {
      stdout.writeln('$label     -      MISSING REFERENCE');
      fail = true;
      continue;
    }
    if (!g.existsSync()) {
      stdout.writeln('$label     -      MISSING GOLDEN');
      fail = true;
      continue;
    }
    final a = img.decodePng(g.readAsBytesSync());
    final b = img.decodePng(r.readAsBytesSync());
    if (a == null || b == null) {
      stdout.writeln('$label     -      UNREADABLE');
      fail = true;
      continue;
    }
    final d = diffImages(a, b);
    final ok = d.percent <= kMaxPercent;
    if (!ok) fail = true;
    File('$out/$n').writeAsBytesSync(img.encodePng(d.overlay));
    stdout.writeln(
      '$label ${d.percent.toStringAsFixed(2).padLeft(8)}  ${ok ? 'ok' : 'FAIL'}',
    );
  }
  return fail ? 1 : 0;
}

void main(List<String> args) {
  exit(
    run(
      args.isNotEmpty ? args[0] : 'test/goldens',
      args.length > 1 ? args[1] : 'test/goldens/ref',
      args.length > 2 ? args[2] : 'build/parity',
      only: args.length > 3 ? args[3].split(',') : const [],
    ),
  );
}
