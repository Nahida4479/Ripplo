import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/i18n.dart';
import 'package:ripplo/ui/widgets.dart';
import 'package:ripplo/views/chats_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

Widget chatsScreen(Scene s) => Stack(
  fit: StackFit.expand,
  children: [
    ChatsView(state: s.state),
    RTabBar(
      current: 'chats',
      onSelect: (_) {},
      items: [
        RTabItem(
          path: 'chats',
          icon: LucideIcons.messageCircle,
          label: t('chats'),
        ),
        RTabItem(path: 'people', icon: LucideIcons.users, label: t('people')),
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
    'chats-empty',
    'chats-list',
    'chats-list-accent',
    'chats-requests',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        await pumpScreen(tester, chatsScreen(s), theme: theme, scene: s);
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
