import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/views/gate_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

void main() {
  setUpAll(setUpGoldens);
  for (final name in const ['gate-needed', 'gate-partial', 'gate-optional']) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final s = scene(name);
        final perms = Map<String, String>.from(s.extras['perms'] as Map);
        await pumpScreen(
          tester,
          GateView(check: () async => perms),
          theme: theme,
          scene: s,
        );
        await tester.pump(const Duration(milliseconds: 100));
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
