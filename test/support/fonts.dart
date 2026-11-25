import 'dart:io';

import 'package:flutter/services.dart';

String? _fontDir() {
  final env = Platform.environment['FLUTTER_ROOT'];
  final roots = <String>[
    'test/fonts',
    if (env != null) '$env/bin/cache/artifacts/material_fonts',
  ];
  var d = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    roots.add('${d.path}/artifacts/material_fonts');
    roots.add('${d.path}/bin/cache/artifacts/material_fonts');
    d = d.parent;
  }
  roots.add('/opt/flutter/bin/cache/artifacts/material_fonts');
  for (final r in roots) {
    if (File('$r/Roboto-Regular.ttf').existsSync()) return r;
  }
  return null;
}

bool _loaded = false;

Future<void> loadGoldenFonts() async {
  if (_loaded) return;
  final dir = _fontDir();
  if (dir == null) {
    throw StateError('Roboto not found in test/fonts or the Flutter SDK');
  }
  final loader = FontLoader('Roboto');
  for (final f in const ['Regular', 'Medium', 'Bold']) {
    final bytes = await File('$dir/Roboto-$f.ttf').readAsBytes();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
  _loaded = true;
}
