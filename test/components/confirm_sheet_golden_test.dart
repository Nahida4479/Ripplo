import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/components/confirm_sheet.dart';
import 'package:ripplo/ui/views/contact_profile_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';
import '../views/contact_view_golden_test.dart' show loadMonoFont;
import '../views/people_view_golden_test.dart' show peopleScreen;

void main() {
  setUpAll(() async {
    await setUpGoldens();
    await loadMonoFont();
  });
  for (final name in const [
    'confirm-sure',
    'confirm-delete',
    'confirm-invite',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        final invite = name == 'confirm-invite';
        await pumpScreen(
          tester,
          Stack(
            fit: StackFit.expand,
            children: [
              invite
                  ? peopleScreen(s)
                  : ContactView(
                      id: s.id!,
                      state: s.state,
                      live: false,
                      safety: (id) async => fixtureSafety[id]!,
                    ),
              const ConfirmSheet(),
            ],
          ),
          theme: theme,
          scene: s,
        );
        if (!invite) {
          final pos = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          pos.jumpTo(pos.maxScrollExtent);
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 100));
        await expectGolden(tester, s.screen, s.variant, theme);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
