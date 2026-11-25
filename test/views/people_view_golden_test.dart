import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/i18n.dart';
import 'package:ripplo/ui/widgets.dart';
import 'package:ripplo/views/people_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

Widget peopleScreen(Scene s) => Stack(
  fit: StackFit.expand,
  children: [
    PeopleView(state: s.state, live: false),
    RTabBar(
      current: 'people',
      onSelect: (_) {},
      items: [
        RTabItem(
          path: 'chats',
          icon: LucideIcons.messageCircle,
          label: t('chats'),
        ),
        RTabItem(
          path: 'people',
          icon: LucideIcons.users,
          label: 'Find\npeople',
        ),
        RTabItem(
          path: 'settings',
          icon: LucideIcons.settings,
          label: t('settings'),
        ),
      ],
    ),
  ],
);

void main() {
  setUpAll(setUpGoldens);
  for (final name in const [
    'people-empty',
    'people-nearby',
    'people-request',
    'people-mesh',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        await pumpScreen(tester, peopleScreen(s), theme: theme, scene: s);
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
