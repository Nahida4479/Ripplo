import 'package:flutter/foundation.dart';

import '../util/js_compat.dart';

final _lines = <String>[];
Future<Object?> Function(String text)? _sink;

void setDiagSink(Future<Object?> Function(String text)? f) => _sink = f;

void diagLog(String m) {
  final line =
      '${DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true).toIso8601String().substring(11, 23)} $m';
  _lines.add(line);
  final s = _sink;
  if (s != null) fire(s('js $line'));
  if (_lines.length > 400) _lines.removeAt(0);
  debugPrint('ripplo $m');
}

String diagText() => _lines.join('\n');

void diagClear() => _lines.clear();
