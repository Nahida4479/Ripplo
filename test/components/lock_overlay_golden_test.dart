import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/components/lock_overlay.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

void main() {
  setUpAll(setUpGoldens);
  for (final theme in Brightness.values) {
    testWidgets('lock-locked ${theme.name}', (tester) async {
      final s = scene('lock-locked');
      await pumpScreen(
        tester,
        LockOverlay(onUnlock: () {}),
        theme: theme,
        scene: s,
      );
      await expectGolden(tester, s.screen, s.variant, theme);
    });
  }
}
