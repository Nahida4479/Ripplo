import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/views/onboarding_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

void main() {
  setUpAll(setUpGoldens);
  for (final name in const ['onboarding-empty', 'onboarding-filled']) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        await pumpScreen(
          tester,
          const OnboardingView(native: false),
          theme: theme,
          scene: s,
        );
        final text = s.extras['name'] as String;
        if (text.isNotEmpty) {
          await tester.enterText(find.byType(TextField), text);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await expectGolden(tester, s.screen, s.variant, theme);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
