import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

const List<int> _dataCodewordsL = [
  19,
  34,
  55,
  80,
  108,
  136,
  156,
  194,
  232,
  274,
  324,
  370,
  428,
  461,
  523,
  589,
  647,
  721,
  795,
  861,
  932,
  1006,
  1094,
  1174,
  1276,
  1370,
  1468,
  1531,
  1631,
  1735,
  1843,
  1955,
  2071,
  2191,
  2306,
  2434,
  2566,
  2702,
  2812,
  2956,
];

enum _Mode { numeric, alnum, byte }

class _Seg {
  _Seg(this.data, this.mode, this.length);
  String data;
  final _Mode mode;
  final int length;
}

int _ccBits(_Mode m, int v) => switch (m) {
  _Mode.numeric => v < 10 ? 10 : (v < 27 ? 12 : 14),
  _Mode.alnum => v < 10 ? 9 : (v < 27 ? 11 : 13),
  _Mode.byte => v < 10 ? 8 : 16,
};

int _bits(int len, _Mode m) => switch (m) {
  _Mode.numeric => 10 * (len ~/ 3) + (len % 3 != 0 ? (len % 3) * 3 + 1 : 0),
  _Mode.alnum => 11 * (len ~/ 2) + 6 * (len % 2),
  _Mode.byte => len * 8,
};

int _byteLen(String s) => utf8.encode(s).length;

int _segLen(_Seg s) => s.mode == _Mode.byte ? _byteLen(s.data) : s.data.length;

List<_Seg> _rawSegments(String s) {
  final out = <(int, _Seg)>[];
  void scan(RegExp re, _Mode m) {
    for (final x in re.allMatches(s)) {
      out.add((x.start, _Seg(x[0]!, m, x[0]!.length)));
    }
  }

  scan(RegExp(r'[0-9]+'), _Mode.numeric);
  scan(RegExp(r'[A-Z $%*+\-./:]+'), _Mode.alnum);
  scan(RegExp(r'[^A-Z0-9 $%*+\-./:]+'), _Mode.byte);
  final idx = List.generate(out.length, (i) => i)
    ..sort((a, b) {
      final c = out[a].$1.compareTo(out[b].$1);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) out[i].$2];
}

int _dataBits(int v) => _dataCodewordsL[v - 1] * 8;

int _reserved(List<_Seg> segs, int v) {
  var n = 0;
  for (final s in segs) {
    n += 4 + _ccBits(s.mode, v) + _bits(_segLen(s), s.mode);
  }
  return n;
}

int? _bestVersion(List<_Seg> segs) {
  if (segs.isEmpty) return 1;
  if (segs.length > 1) {
    for (var v = 1; v <= 40; v++) {
      if (_reserved(segs, v) <= _dataBits(v)) return v;
    }
    return null;
  }
  final s = segs.first;
  final len = _segLen(s);
  for (var v = 1; v <= 40; v++) {
    final usable = _dataBits(v) - (4 + _ccBits(s.mode, v));
    final cap = switch (s.mode) {
      _Mode.numeric => (usable / 10 * 3).floor(),
      _Mode.alnum => (usable / 11 * 2).floor(),
      _Mode.byte => (usable / 8).floor(),
    };
    if (len <= cap) return v;
  }
  return null;
}

List<_Seg> _optimal(String s, int version) {
  final segs = _rawSegments(s);
  final nodes = <List<_Seg>>[];
  for (final g in segs) {
    switch (g.mode) {
      case _Mode.numeric:
        nodes.add([
          g,
          _Seg(g.data, _Mode.alnum, g.length),
          _Seg(g.data, _Mode.byte, g.length),
        ]);
      case _Mode.alnum:
        nodes.add([g, _Seg(g.data, _Mode.byte, g.length)]);
      case _Mode.byte:
        nodes.add([_Seg(g.data, _Mode.byte, _byteLen(g.data))]);
    }
  }
  final graph = <String, Map<String, int>>{'start': {}};
  final table = <String, ({_Seg node, List<int> last})>{};
  var prev = ['start'];
  for (var i = 0; i < nodes.length; i++) {
    final cur = <String>[];
    for (var j = 0; j < nodes[i].length; j++) {
      final node = nodes[i][j];
      final key = '$i$j';
      cur.add(key);
      table[key] = (node: node, last: [0]);
      graph[key] = {};
      for (final p in prev) {
        final t = table[p];
        if (t != null && t.node.mode == node.mode) {
          graph[p]![key] =
              _bits(t.last[0] + node.length, node.mode) -
              _bits(t.last[0], node.mode);
          t.last[0] += node.length;
        } else {
          if (t != null) t.last[0] = node.length;
          graph[p]![key] =
              _bits(node.length, node.mode) + 4 + _ccBits(node.mode, version);
        }
      }
    }
    prev = cur;
  }
  for (final p in prev) {
    graph[p]!['end'] = 0;
  }
  final costs = <String, int>{'start': 0};
  final pred = <String, String>{};
  final open = <(String, int)>[('start', 0)];
  while (open.isNotEmpty) {
    final (u, cu) = open.removeAt(0);
    for (final e in (graph[u] ?? const <String, int>{}).entries) {
      final c = cu + e.value;
      final old = costs[e.key];
      if (old == null || old > c) {
        costs[e.key] = c;
        var at = open.length;
        while (at > 0 && open[at - 1].$2 > c) {
          at--;
        }
        open.insert(at, (e.key, c));
        pred[e.key] = u;
      }
    }
  }
  final path = <String>[];
  for (String? k = 'end'; k != null; k = pred[k]) {
    path.insert(0, k);
  }
  final merged = <_Seg>[];
  for (final k in path.sublist(1, path.length - 1)) {
    final n = table[k]!.node;
    if (merged.isNotEmpty && merged.last.mode == n.mode) {
      merged.last.data += n.data;
    } else {
      merged.add(_Seg(n.data, n.mode, n.length));
    }
  }
  return merged;
}

int _penalty(List<List<bool>> m) {
  final size = m.length;
  int g(int r, int c) => m[r][c] ? 1 : 0;
  var n1 = 0;
  for (var row = 0; row < size; row++) {
    var sc = 0, sr = 0;
    int? lc, lr;
    for (var col = 0; col < size; col++) {
      var v = g(row, col);
      if (v == lc) {
        sc++;
      } else {
        if (sc >= 5) n1 += 3 + (sc - 5);
        lc = v;
        sc = 1;
      }
      v = g(col, row);
      if (v == lr) {
        sr++;
      } else {
        if (sr >= 5) n1 += 3 + (sr - 5);
        lr = v;
        sr = 1;
      }
    }
    if (sc >= 5) n1 += 3 + (sc - 5);
    if (sr >= 5) n1 += 3 + (sr - 5);
  }
  var n2 = 0;
  for (var r = 0; r < size - 1; r++) {
    for (var c = 0; c < size - 1; c++) {
      final s = g(r, c) + g(r, c + 1) + g(r + 1, c) + g(r + 1, c + 1);
      if (s == 4 || s == 0) n2++;
    }
  }
  var n3 = 0;
  for (var row = 0; row < size; row++) {
    var bc = 0, br = 0;
    for (var col = 0; col < size; col++) {
      bc = ((bc << 1) & 0x7FF) | g(row, col);
      if (col >= 10 && (bc == 0x5D0 || bc == 0x05D)) n3++;
      br = ((br << 1) & 0x7FF) | g(col, row);
      if (col >= 10 && (br == 0x5D0 || br == 0x05D)) n3++;
    }
  }
  var dark = 0;
  for (final r in m) {
    for (final v in r) {
      if (v) dark++;
    }
  }
  final k = ((dark * 100 / (size * size)) / 5).ceil() - 10;
  return n1 + n2 * 3 + n3 * 40 + k.abs() * 10;
}

final Map<String, List<List<bool>>> _matrixCache = {};

List<List<bool>> qrMatrix(String text) => _matrixCache[text] ??= () {
  final est = _bestVersion(_rawSegments(text));
  final segs = _optimal(text, est ?? 40);
  final version = _bestVersion(segs);
  if (version == null) throw ArgumentError('QR payload too long');
  final payload = QrPayload();
  for (final s in segs) {
    switch (s.mode) {
      case _Mode.numeric:
        payload.addNumeric(s.data);
      case _Mode.alnum:
        payload.addAlphaNumeric(s.data);
      case _Mode.byte:
        payload.addTypedData(Uint8List.fromList(utf8.encode(s.data)));
    }
  }
  final code = QrCode(
    payload: payload,
    errorCorrectLevel: QrErrorCorrectLevel.low,
    minTypeNumber: version,
  );
  List<List<bool>>? best;
  var low = 1 << 62;
  for (var p = 0; p < 8; p++) {
    final img = QrImage.withMaskPattern(code, p);
    final m = [
      for (var r = 0; r < img.moduleCount; r++)
        [for (var c = 0; c < img.moduleCount; c++) img.isDark(r, c)],
    ];
    final pen = _penalty(m);
    if (pen < low) {
      low = pen;
      best = m;
    }
  }
  return best!;
}();

List<int> qrRuns(
  int modules,
  int devicePixels, {
  int margin = 2,
  double width = 560,
}) {
  final total = modules + margin * 2;
  final scale = width >= total ? width / total : 4.0;
  final w = (total * scale).floor();
  final sm = margin * scale;
  return [
    for (var d = 0; d < devicePixels; d++)
      () {
        final s = ((d + .5) * w / devicePixels).floor();
        return s >= sm && s < w - sm ? ((s - sm) / scale).floor() : -1;
      }(),
  ];
}

class QrView extends StatelessWidget {
  const QrView(
    this.data, {
    super.key,
    required this.width,
    this.padding = 0,
    this.radius = 0,
    this.semanticLabel,
  });

  final String data;
  final double width;
  final double padding;
  final double radius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final inner = width - padding * 2;
    return Semantics(
      label: semanticLabel,
      image: true,
      child: Container(
        width: width,
        height: width,
        padding: EdgeInsets.all(padding),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: CustomPaint(
          size: Size.square(inner),
          painter: _QrPainter(
            qrMatrix(data),
            MediaQuery.devicePixelRatioOf(context),
          ),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.m, this.dpr);
  final List<List<bool>> m;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final d = (size.width * dpr).round();
    final runs = qrRuns(m.length, d);
    final paint = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    canvas.save();
    canvas.scale(1 / dpr);
    final spans = <(int, int, int)>[];
    var start = 0;
    for (var i = 1; i <= d; i++) {
      if (i == d || runs[i] != runs[start]) {
        spans.add((start, i, runs[start]));
        start = i;
      }
    }
    for (final (y0, y1, r) in spans) {
      if (r < 0) continue;
      for (final (x0, x1, c) in spans) {
        if (c < 0 || !m[r][c]) continue;
        canvas.drawRect(
          Rect.fromLTRB(
            x0.toDouble(),
            y0.toDouble(),
            x1.toDouble(),
            y1.toDouble(),
          ),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.m != m || old.dpr != dpr;
}
