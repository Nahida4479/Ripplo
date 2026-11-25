import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/ui/theme.dart';
import 'package:ripplo/ui/design_tokens.dart';
import 'package:ripplo/ui/ui_request_state.dart';
import 'package:ripplo/util/js_compat.dart' as js;

import 'fixtures.dart';
import 'fonts.dart';

const Size kScreenSize = Size(412, 915);
const double kSafeTop = 24;
const double kSafeBottom = 16;

String goldenName(String screen, String state, Brightness theme) =>
    '$screen-$state-${theme == Brightness.light ? 'light' : 'dark'}.png';

Future<void> setUpGoldens() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadGoldenFonts();
  goldenFileComparator = LocalFileComparator(
    Uri.file('${Directory.current.path}/test/goldens/_.dart'),
  );
}

Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  required Brightness theme,
  Scene? scene,
  String? accent,
  String? gradient,
  int? nowMs,
  Widget Function(Widget child)? wrap,
  bool settle = true,
}) async {
  final view = tester.view;
  view.devicePixelRatio = 2;
  view.physicalSize = Size(kScreenSize.width * 2, kScreenSize.height * 2);
  final pad = FakeViewPadding(top: kSafeTop * 2, bottom: kSafeBottom * 2);
  view.padding = pad;
  view.viewPadding = pad;
  tester.platformDispatcher.textScaleFactorTestValue = 1;
  tester.platformDispatcher.platformBrightnessTestValue = theme;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  debugFontFamily = 'Roboto';
  final prevNow = js.now;
  final clock = nowMs ?? scene?.nowMs;
  if (clock != null) js.now = () => clock;
  scene?.applyUi(ui);
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
    view.resetPadding();
    view.resetViewPadding();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    js.now = prevNow;
    ui.reset();
  });

  final colors = RipploColors.resolve(
    light: theme == Brightness.light,
    accent: hexColor(accent ?? scene?.accent ?? '#4f9cf9'),
    gradient: () {
      final g = gradient ?? scene?.gradient ?? '';
      return g.isEmpty ? null : hexColor(g);
    }(),
  );
  final base = buildTheme(colors);
  final data = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
  );
  Widget body = Material(
    color: colors.bg,
    child: DefaultTextStyle.merge(
      style: const TextStyle(fontFamily: 'Roboto'),
      child: screen,
    ),
  );
  if (wrap != null) body = wrap(body);
  await tester.pumpWidget(
    MaterialApp(debugShowCheckedModeBanner: false, theme: data, home: body),
  );
  if (settle) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> expectGolden(
  WidgetTester tester,
  String screen,
  String state,
  Brightness theme,
) => expectLater(
  find.byType(MaterialApp),
  matchesGoldenFile(goldenName(screen, state, theme)),
);
