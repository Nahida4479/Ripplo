import 'package:material_ui/material_ui.dart';

import 'design_tokens.dart';
import '../data/theme_language_prefs.dart';

const List<String> kAccents = [
  '#22c55e',
  '#14b8a6',
  '#4f9cf9',
  '#a78bfa',
  '#e467b0',
  '#ea6a5f',
  '#e67e22',
  '#9ca3af',
];
const List<String> kGradients = [
  '',
  '#5b2ea6',
  '#1e3a8a',
  '#0f5257',
  '#7a1f4f',
  '#6b3a0a',
  '#3d4552',
];
const List<String> kThemeModes = ['system', 'light', 'dark'];

final RegExp _hex6 = RegExp(r'^#[0-9a-fA-F]{6}$');

class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController({
    this.mode = 'system',
    this.accent = '#4f9cf9',
    this.gradient = '',
  });

  String mode;
  String accent;
  String gradient;

  static Future<ThemeController> load([Prefs? prefs]) async {
    final p = prefs ?? await Prefs.load();
    final m = p.theme['mode'];
    final a = p.theme['accent'];
    final g = p.theme['gradient'];
    return ThemeController(
      mode: m is String && kThemeModes.contains(m) ? m : 'system',
      accent: a is String && _hex6.hasMatch(a) ? a.toLowerCase() : '#4f9cf9',
      gradient: g is String && _hex6.hasMatch(g) ? g.toLowerCase() : '',
    );
  }

  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => notifyListeners();

  bool get isLight {
    if (mode == 'light') return true;
    if (mode == 'dark') return false;
    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.light;
  }

  RipploColors get colors => RipploColors.resolve(
    light: isLight,
    accent: hexColor(accent),
    gradient: gradient.isEmpty ? null : hexColor(gradient),
  );

  ThemeData get themeData => buildTheme(colors);

  void setMode(String v) => _set(() => mode = v);
  void setAccent(String hex) => _set(() => accent = hex.toLowerCase());
  void setGradient(String hex) => _set(() => gradient = hex.toLowerCase());

  void _set(void Function() f) {
    f();
    Prefs.saveTheme({'mode': mode, 'accent': accent, 'gradient': gradient});
    notifyListeners();
  }
}

ThemeData buildTheme(RipploColors c) {
  final base = RipploText.body.copyWith(color: c.text);
  return ThemeData(
    useMaterial3: true,
    brightness: c.light ? Brightness.light : Brightness.dark,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    splashFactory: NoSplash.splashFactory,
    highlightColor: const Color(0x00000000),
    hoverColor: const Color(0x00000000),
    colorScheme: ColorScheme(
      brightness: c.light ? Brightness.light : Brightness.dark,
      primary: c.accent,
      onPrimary: c.onAccent,
      secondary: c.accent,
      onSecondary: c.onAccent,
      error: c.danger,
      onError: const Color(0xFFFFFFFF),
      surface: c.surface,
      onSurface: c.text,
    ),
    textTheme: TextTheme(
      bodyLarge: base,
      bodyMedium: base,
      bodySmall: base,
      labelLarge: base,
      labelMedium: base,
      labelSmall: base,
      titleMedium: base,
      titleSmall: base,
    ),
    extensions: [c],
  );
}
