import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/app.dart';
import 'package:ripplo/mesh/bridge.dart';
import 'package:ripplo/mesh/dev/dev_mesh.dart';
import 'package:ripplo/router.dart';
import 'package:ripplo/services/lock.dart';
import 'package:ripplo/ui/theme.dart';
import 'package:ripplo/ui/ui_state.dart';
import 'package:ripplo/ui/widgets.dart';
import 'package:ripplo/ui/views/chats_view.dart';
import 'package:ripplo/ui/views/onboarding_view.dart';
import 'package:ripplo/ui/views/people_view.dart';
import 'package:ripplo/ui/views/settings_view.dart';

import 'support/fixtures.dart';
import 'support/pump_screen.dart';

Future<RipploRouter> pumpApp(
  WidgetTester tester,
  Scene s, {
  bool granted = true,
}) async {
  final view = tester.view;
  view.devicePixelRatio = 2;
  view.physicalSize = Size(kScreenSize.width * 2, kScreenSize.height * 2);
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
    ui.reset();
  });
  debugFontFamily = 'Roboto';
  mesh = DevMesh.memory(DevHub());
  final router = RipploRouter();
  final theme = ThemeController(mode: 'dark');
  final lock = AppLock(mesh: mesh, state: s.state, saveSettings: (_) async {});
  await tester.pumpWidget(
    RipploApp(
      theme: theme,
      state: s.state,
      lock: lock,
      router: router,
      granted: granted,
      live: false,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    lock.dispose();
    theme.dispose();
  });
  return router;
}

Finder tabIcon(int i) => find
    .descendant(of: find.byType(RTabBar), matching: find.byType(Lucide))
    .at(i);

void main() {
  setUpAll(setUpGoldens);

  testWidgets('chats tab renders with the tab bar', (tester) async {
    final s = scene('chats-list');
    await pumpApp(tester, s);
    expect(find.byType(ChatsView), findsOneWidget);
    expect(find.text('Bob'), findsWidgets);
    expect(find.byType(RTabBar), findsOneWidget);
  });

  testWidgets('tab bar switches between tabs', (tester) async {
    final s = scene('chats-list');
    final router = await pumpApp(tester, s);
    await tester.tap(tabIcon(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(router.location, '/people');
    expect(find.byType(PeopleView), findsOneWidget);
    expect(find.byType(ChatsView), findsNothing);
    await tester.tap(tabIcon(2));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SettingsView), findsOneWidget);
    router.back();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PeopleView), findsOneWidget);
  });

  testWidgets('opening a chat hides the tab bar and back returns', (
    tester,
  ) async {
    final s = scene('chats-list');
    final router = await pumpApp(tester, s);
    router.chat(kBobId);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(RTabBar), findsNothing);
    router.back();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatsView), findsOneWidget);
    expect(find.byType(RTabBar), findsOneWidget);
  });

  testWidgets('a locked call hides the content', (tester) async {
    final s = scene('chats-list');
    await pumpApp(tester, s);
    s.state.lockedCall = true;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatsView), findsNothing);
    expect(find.byType(RTabBar), findsNothing);
    expect(find.text('Ripplo…'), findsOneWidget);
    s.state.lockedCall = false;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ChatsView), findsOneWidget);
  });

  testWidgets('a fresh profile shows onboarding', (tester) async {
    final s = scene('onboarding-empty');
    await pumpApp(tester, s);
    expect(find.byType(OnboardingView), findsOneWidget);
    expect(find.byType(RTabBar), findsNothing);
  });
}
