import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/components/new_chat_sheet.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';
import 'chats_view_golden_test.dart' show chatsScreen;

void main() {
  setUpAll(setUpGoldens);
  for (final name in const [
    'newchat-empty',
    'newchat-contacts',
    'newchat-group',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        s.state.chats = s.state.chats.reversed.toList();
        await pumpScreen(
          tester,
          Stack(
            fit: StackFit.expand,
            children: [
              chatsScreen(s),
              NewChatSheet(state: s.state),
            ],
          ),
          theme: theme,
          scene: s,
        );
        if (name == 'newchat-group') {
          await tester.enterText(find.byType(TextField).last, 'Trip crew');
          final sheet = find.byType(NewChatSheet);
          await tester.tap(
            find.descendant(of: sheet, matching: find.text('Bob')),
          );
          await tester.tap(
            find.descendant(of: sheet, matching: find.text('Carol')),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
