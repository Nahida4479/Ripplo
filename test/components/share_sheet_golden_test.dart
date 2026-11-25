import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/components/share_sheet.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';
import '../views/chats_view_golden_test.dart' show chatsScreen;

void main() {
  setUpAll(setUpGoldens);
  for (final theme in Brightness.values) {
    testWidgets('share-text ${theme.name}', (tester) async {
      final s = scene('share-text');
      await pumpScreen(
        tester,
        Stack(
          fit: StackFit.expand,
          children: [
            chatsScreen(s),
            ShareSheet(state: s.state),
          ],
        ),
        theme: theme,
        scene: s,
      );
      await expectGolden(tester, s.screen, s.variant, theme);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
