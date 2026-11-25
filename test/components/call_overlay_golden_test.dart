import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/components/call_overlay.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

void main() {
  setUpAll(setUpGoldens);
  for (final name in const ['call-incoming', 'call-active', 'call-outgoing']) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        await pumpScreen(
          tester,
          CallOverlay(state: s.state, onRing: (_) {}, onKeepAwake: (_) {}),
          theme: theme,
          scene: s,
        );
        await expectGolden(tester, s.screen, s.variant, theme);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
