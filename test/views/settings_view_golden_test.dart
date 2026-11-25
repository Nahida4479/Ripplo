import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/i18n.dart';
import 'package:ripplo/mesh/bridge.dart' as bridge;
import 'package:ripplo/ui/theme.dart';
import 'package:ripplo/ui/widgets.dart';
import 'package:ripplo/ui/views/settings_view.dart';

import '../support/fixtures.dart';
import '../support/pump_screen.dart';

class FakeMesh implements bridge.Mesh {
  @override
  bool get isNative => false;

  @override
  Future<List<Map<String, Object?>>> getTransports() async => [
    {'name': 'broadcast', 'running': true},
  ];

  @override
  Future<({bool coded, bool extended})> getBleCaps() async =>
      (coded: false, extended: false);

  @override
  Future<String> getDiag() async => '';

  @override
  bridge.Unsub on(String event, void Function(Map<String, Object?>) cb) =>
      () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget settingsScreen(Scene s, Brightness theme, ScrollController controller) =>
    Stack(
      fit: StackFit.expand,
      children: [
        SettingsView(
          state: s.state,
          mesh: FakeMesh(),
          controller: controller,
          android: false,
          theme: ThemeController(
            mode: theme.name,
            accent: s.accent,
            gradient: s.gradient,
          ),
        ),
        RTabBar(
          current: 'settings',
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
              label: t('people'),
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

Future<void> loadMonoFont() async {
  final f = [
    File('/usr/share/fonts/TTF/DejaVuSansMono.ttf'),
    File('/usr/share/fonts/noto/NotoSansMono-Regular.ttf'),
  ].where((f) => f.existsSync()).firstOrNull;
  if (f == null) return;
  final loader = FontLoader('monospace')
    ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  await loader.load();
}

void main() {
  setUpAll(() async {
    await setUpGoldens();
    await loadMonoFont();
  });
  for (final name in const [
    'settings-top',
    'settings-top-accent',
    'settings-appearance',
    'settings-network',
    'settings-security',
    'settings-updates',
    'settings-about',
    'settings-contributors',
    'settings-dev',
  ]) {
    for (final theme in Brightness.values) {
      testWidgets('$name ${theme.name}', (tester) async {
        final s = scene(name);
        final controller = ScrollController();
        addTearDown(controller.dispose);
        await pumpScreen(
          tester,
          settingsScreen(s, theme, controller),
          theme: theme,
          scene: s,
        );
        await tester.pump(const Duration(milliseconds: 100));
        final section = s.extras['section'] as String?;
        if (section != null) {
          final heading = find
              .ancestor(
                of: find.text(section.toUpperCase()),
                matching: find.byType(Padding),
              )
              .first;
          final top = tester.getTopLeft(heading).dy;
          final want = (controller.offset + top - 60).roundToDouble();
          controller.jumpTo(
            want.clamp(0.0, controller.position.maxScrollExtent),
          );
          await tester.pump();
        }
        await expectGolden(tester, s.screen, s.variant, theme);
      });
    }
  }
}
