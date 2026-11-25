import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ripplo/ui/views/contact_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

Future<void> loadMonoFont() async {
  final f = File('/usr/share/fonts/noto/NotoSansMono-Regular.ttf');
  if (!f.existsSync()) return;
  final loader = FontLoader('monospace')
    ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  await loader.load();
}

void main() {
  setUpAll(() async {
    await setUpGoldens();
    await loadMonoFont();
  });
  for (final name in const ['contact-verified', 'contact-unverified']) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        await pumpScreen(
          tester,
          ContactView(
            id: s.id!,
            state: s.state,
            live: false,
            safety: (id) async => fixtureSafety[id]!,
          ),
          theme: theme,
          scene: s,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
