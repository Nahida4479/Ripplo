import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/components/add_contact_sheet.dart';
import 'package:ripplo/ui/ui_request_state.dart';
import 'package:ripplo/ui/shared_widgets.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';
import '../views/chats_view_golden_test.dart' show chatsScreen;

void main() {
  setUpAll(setUpGoldens);
  for (final theme in Brightness.values) {
    testWidgets('toast-camera ${theme.name}', (tester) async {
      final s = scene('toast-camera');
      await pumpScreen(
        tester,
        Stack(
          fit: StackFit.expand,
          children: [
            chatsScreen(s),
            AddContactSheet(
              state: s.state,
              inviteLink: () => fixtureMyLink,
              scanner: (onCode, onError) => const SizedBox.shrink(),
            ),
            ListenableBuilder(
              listenable: ui,
              builder: (context, _) => RToast(text: ui.toastText),
            ),
          ],
        ),
        theme: theme,
        scene: s,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AddContactSheet),
          matching: find.text('Scan'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await expectGolden(tester, s.screen, s.variant, theme);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
