import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/components/add_contact_sheet.dart';
import 'package:ripplo/views/contact_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';
import '../views/chats_view_golden_test.dart' show chatsScreen;
import '../views/contact_view_golden_test.dart' show loadMonoFont;

void main() {
  setUpAll(() async {
    await setUpGoldens();
    await loadMonoFont();
  });
  for (final name in const [
    'addcontact-code',
    'addcontact-scan',
    'addcontact-paste-empty',
    'addcontact-paste-filled',
    'addcontact-verify',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        final verify = name == 'addcontact-verify';
        await pumpScreen(
          tester,
          Stack(
            fit: StackFit.expand,
            children: [
              verify
                  ? ContactView(
                      id: s.id!,
                      state: s.state,
                      live: false,
                      safety: (id) async => fixtureSafety[id]!,
                    )
                  : chatsScreen(s),
              AddContactSheet(
                state: s.state,
                inviteLink: () => fixtureMyLink,
                scanner: (onCode, onError) => const SizedBox.shrink(),
              ),
            ],
          ),
          theme: theme,
          scene: s,
        );
        if (verify) {
          final pos = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          pos.jumpTo(pos.maxScrollExtent);
          await tester.pump();
        }
        final sheet = find.byType(AddContactSheet);
        Future<void> tapText(String text) =>
            tester.tap(find.descendant(of: sheet, matching: find.text(text)));
        final tab = s.extras['tab'];
        if (tab == 'scan') await tapText('Scan');
        if (tab == 'paste') await tapText('Paste link');
        await tester.pump();
        final text = s.extras['pasteText'];
        if (text != null) {
          await tester.enterText(
            find.descendant(of: sheet, matching: find.byType(TextField)),
            text as String,
          );
        }
        final lag = name == 'addcontact-code' && theme == Brightness.light
            ? 700
            : 100;
        await tester.pump(Duration(milliseconds: lag));
        await expectGolden(tester, s.screen, s.variant, theme);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
