import 'dart:io';

const _pkg = 'node_modules/lucide-vue-next/dist/esm';

void main() {
  final names = _usedIcons();
  final index = File('$_pkg/lucide-vue-next.js').readAsStringSync();
  final out = StringBuffer(_header);
  for (final name in names) {
    final m = RegExp(
      'default as $name[,\\s][^;]*?from \'\\./icons/([a-z0-9-]+)\\.js\'',
    ).firstMatch(index);
    if (m == null) throw StateError('icon $name not found');
    final src = File('$_pkg/icons/${m[1]}.js').readAsStringSync();
    final ops = <num>[];
    for (final el in RegExp(r'\[\s*"(\w+)",\s*\{([^}]*)\}').allMatches(src)) {
      final a = {
        for (final kv in RegExp(r'([\w-]+):\s*"([^"]*)"').allMatches(el[2]!))
          kv[1]!: kv[2]!,
      };
      _element(el[1]!, a, ops);
    }
    final field = name[0].toLowerCase() + name.substring(1);
    out.writeln(
      '  static const LucideData $field = LucideData(\'$name\', [${ops.map(_fmt).join(', ')}]);',
    );
  }
  out.writeln('}');
  File('lib/ui/icons.dart').writeAsStringSync(out.toString());
  stdout.writeln('${names.length} icons');
}

List<String> _usedIcons() {
  final names = <String>{};
  final re = RegExp(r"import\s*\{([^}]*)\}\s*from\s*'lucide-vue-next'");
  for (final f in Directory('src').listSync(recursive: true)) {
    if (f is! File || !RegExp(r'\.(vue|js)$').hasMatch(f.path)) continue;
    for (final m in re.allMatches(f.readAsStringSync())) {
      names.addAll(
        m[1]!.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
  }
  return names.toList()..sort();
}

double _n(Map<String, String> a, String k) => double.parse(a[k] ?? '0');

void _element(String tag, Map<String, String> a, List<num> ops) {
  switch (tag) {
    case 'path':
      _path(a['d']!, ops);
    case 'circle':
      ops.addAll([6, _n(a, 'cx'), _n(a, 'cy'), _n(a, 'r'), _n(a, 'r')]);
    case 'ellipse':
      ops.addAll([6, _n(a, 'cx'), _n(a, 'cy'), _n(a, 'rx'), _n(a, 'ry')]);
    case 'rect':
      final rx = a['rx'] ?? a['ry'] ?? '0';
      final ry = a['ry'] ?? a['rx'] ?? '0';
      ops.addAll([
        7,
        _n(a, 'x'),
        _n(a, 'y'),
        _n(a, 'width'),
        _n(a, 'height'),
        double.parse(rx),
        double.parse(ry),
      ]);
    case 'line':
      ops.addAll([0, _n(a, 'x1'), _n(a, 'y1'), 1, _n(a, 'x2'), _n(a, 'y2')]);
    case 'polyline' || 'polygon':
      final p = RegExp(
        r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
      ).allMatches(a['points']!).map((m) => double.parse(m[0]!)).toList();
      for (var i = 0; i < p.length; i += 2) {
        ops.addAll([i == 0 ? 0 : 1, p[i], p[i + 1]]);
      }
      if (tag == 'polygon') ops.add(5);
    default:
      throw StateError('unsupported element $tag');
  }
}

void _path(String d, List<num> ops) {
  var i = 0;
  void skip() {
    while (i < d.length && ' ,\t\n\r'.contains(d[i])) {
      i++;
    }
  }

  final numRe = RegExp(r'[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?');
  double num() {
    skip();
    final m = numRe.matchAsPrefix(d, i);
    if (m == null) throw FormatException('number expected', d, i);
    i = m.end;
    return double.parse(m[0]!);
  }

  double flag() {
    skip();
    final c = d[i++];
    if (c != '0' && c != '1') throw FormatException('flag expected', d, i);
    return c == '1' ? 1 : 0;
  }

  bool more() {
    skip();
    return i < d.length && !RegExp(r'[A-Za-z]').hasMatch(d[i]);
  }

  var x = 0.0, y = 0.0, sx = 0.0, sy = 0.0;
  double? cx, cy, qx, qy;
  String cmd = '';
  while (true) {
    skip();
    if (i >= d.length) break;
    if (RegExp(r'[A-Za-z]').hasMatch(d[i])) {
      cmd = d[i++];
    }
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = ox + num();
        y = oy + num();
        sx = x;
        sy = y;
        ops.addAll([0, x, y]);
        cmd = rel ? 'l' : 'L';
        cx = qx = null;
        continue;
      case 'L':
        x = ox + num();
        y = oy + num();
        ops.addAll([1, x, y]);
        cx = qx = null;
      case 'H':
        x = ox + num();
        ops.addAll([1, x, y]);
        cx = qx = null;
      case 'V':
        y = oy + num();
        ops.addAll([1, x, y]);
        cx = qx = null;
      case 'C':
        final x1 = ox + num(), y1 = oy + num();
        final x2 = ox + num(), y2 = oy + num();
        x = ox + num();
        y = oy + num();
        ops.addAll([2, x1, y1, x2, y2, x, y]);
        cx = x2;
        cy = y2;
        qx = null;
      case 'S':
        final x1 = cx == null ? x : 2 * x - cx;
        final y1 = cy == null ? y : 2 * y - cy;
        final x2 = ox + num(), y2 = oy + num();
        x = ox + num();
        y = oy + num();
        ops.addAll([2, x1, y1, x2, y2, x, y]);
        cx = x2;
        cy = y2;
        qx = null;
      case 'Q':
        final x1 = ox + num(), y1 = oy + num();
        x = ox + num();
        y = oy + num();
        ops.addAll([3, x1, y1, x, y]);
        qx = x1;
        qy = y1;
        cx = null;
      case 'T':
        final x1 = qx == null ? x : 2 * x - qx;
        final y1 = qy == null ? y : 2 * y - qy;
        x = ox + num();
        y = oy + num();
        ops.addAll([3, x1, y1, x, y]);
        qx = x1;
        qy = y1;
        cx = null;
      case 'A':
        final rx = num(), ry = num(), rot = num();
        final large = flag(), sweep = flag();
        x = ox + num();
        y = oy + num();
        ops.addAll([4, rx, ry, rot, large, sweep, x, y]);
        cx = qx = null;
      case 'Z':
        x = sx;
        y = sy;
        ops.add(5);
        cx = qx = null;
      default:
        throw FormatException('unknown command $cmd', d, i);
    }
    if (!more()) cmd = '';
  }
}

String _fmt(num v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(4);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s;
}

const _header = '''
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

@immutable
class LucideData {
  const LucideData(this.name, this.ops);
  final String name;
  final List<double> ops;
}

class Lucide extends StatelessWidget {
  const Lucide(
    this.icon, {
    super.key,
    this.size = 24,
    this.strokeWidth = 2,
    this.color,
    this.semanticLabel,
  });

  final LucideData icon;
  final double size;
  final double strokeWidth;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c =
        color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);
    final paint = SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: LucidePainter(icon, strokeWidth, c)),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: paint)
        : Semantics(label: semanticLabel, image: true, child: paint);
  }
}

class LucidePainter extends CustomPainter {
  LucidePainter(this.icon, this.strokeWidth, this.color);
  final LucideData icon;
  final double strokeWidth;
  final Color color;

  static final Map<LucideData, Path> _cache = {};

  static Path pathOf(LucideData icon) => _cache[icon] ??= _build(icon.ops);

  static Path _build(List<double> o) {
    final p = Path();
    var i = 0;
    while (i < o.length) {
      switch (o[i++].toInt()) {
        case 0:
          p.moveTo(o[i], o[i + 1]);
          i += 2;
        case 1:
          p.lineTo(o[i], o[i + 1]);
          i += 2;
        case 2:
          p.cubicTo(o[i], o[i + 1], o[i + 2], o[i + 3], o[i + 4], o[i + 5]);
          i += 6;
        case 3:
          p.quadraticBezierTo(o[i], o[i + 1], o[i + 2], o[i + 3]);
          i += 4;
        case 4:
          p.arcToPoint(
            Offset(o[i + 5], o[i + 6]),
            radius: Radius.elliptical(o[i], o[i + 1]),
            rotation: o[i + 2],
            largeArc: o[i + 3] != 0,
            clockwise: o[i + 4] != 0,
          );
          i += 7;
        case 5:
          p.close();
        case 6:
          p.addOval(
            Rect.fromCenter(
              center: Offset(o[i], o[i + 1]),
              width: o[i + 2] * 2,
              height: o[i + 3] * 2,
            ),
          );
          i += 4;
        case 7:
          final rx = math.min(o[i + 4], o[i + 2] / 2);
          final ry = math.min(o[i + 5], o[i + 3] / 2);
          p.addRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(o[i], o[i + 1], o[i + 2], o[i + 3]),
              Radius.elliptical(rx, ry),
            ),
          );
          i += 6;
      }
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      pathOf(icon),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(LucidePainter old) =>
      old.icon != icon || old.strokeWidth != strokeWidth || old.color != color;
}

abstract final class LucideIcons {
''';
