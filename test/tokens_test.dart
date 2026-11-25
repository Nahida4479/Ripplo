import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ripplo/services/prefs.dart';
import 'package:ripplo/services/theme.dart';
import 'package:ripplo/ui/tokens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('dark and light hex values match the spec', () {
    final d = RipploColors.resolve(light: false);
    expect(d.bg, hexColor('#0b0b0c'));
    expect(d.surface, hexColor('#161617'));
    expect(d.surface2, hexColor('#1f1f21'));
    expect(d.border, hexColor('#2a2a2d'));
    expect(d.text, hexColor('#f2f2f3'));
    expect(d.text2, hexColor('#a1a1a6'));
    expect(d.warn, hexColor('#f5b544'));
    expect(d.danger, hexColor('#ef5350'));
    expect(d.ok, hexColor('#3ecf8e'));
    expect(d.accent, hexColor('#4f9cf9'));
    final l = RipploColors.resolve(light: true);
    expect(l.bg, hexColor('#ffffff'));
    expect(l.surface, hexColor('#f4f4f6'));
    expect(l.surface2, hexColor('#ebebef'));
    expect(l.border, hexColor('#e2e2e7'));
    expect(l.text, hexColor('#111114'));
    expect(l.text2, hexColor('#6b6b73'));
    expect(l.warn, hexColor('#b7791f'));
    expect(l.danger, hexColor('#d32f2f'));
    expect(l.ok, hexColor('#1f9d63'));
  });

  test('derived colours', () {
    final c = RipploColors.resolve(
      light: false,
      accent: hexColor('#1e3a8a'),
      gradient: hexColor('#5b2ea6'),
    );
    expect(c.accentSoft.a, closeTo(.16, 1e-3));
    expect(c.tabBg.a, closeTo(.82, 1e-3));
    expect(c.glowStart.a, closeTo(.55, 1e-3));
    expect(c.glowEnd.toARGB32(), 0x005B2EA6);
    expect(RipploColors.resolve(light: false).glow.a, 0);
    expect(kScrim.toARGB32(), 0x8C000000);
  });

  test('on-accent rule with 0.0556', () {
    for (final a in kAccents) {
      expect(onAccentFor(hexColor(a)), kOnAccentDark, reason: a);
    }
    expect(onAccentFor(hexColor('#1e3a8a')), kOnAccentWhite);
    expect(onAccentFor(hexColor('#000000')), kOnAccentWhite);
    expect(onAccentFor(hexColor('#ffffff')), kOnAccentDark);
    expect(accentLuminance(hexColor('#4f9cf9')), closeTo(.32, .02));
    expect(accentLuminance(hexColor('#1e3a8a')), closeTo(.05, .02));
  });

  test('on-accent cut at luminance 0.1916', () {
    int grey(int v) => 0xFF000000 | (v << 16) | (v << 8) | v;
    int lastWhite = -1;
    for (var v = 0; v < 256; v++) {
      if (onAccentFor(Color(grey(v))) == kOnAccentWhite) lastWhite = v;
    }
    expect(accentLuminance(Color(grey(lastWhite))), lessThanOrEqualTo(.1916));
    expect(accentLuminance(Color(grey(lastWhite + 1))), greaterThan(.1916));
  });

  test('prefs load never throws and theme round trips', () async {
    SharedPreferences.setMockInitialValues({themeKey: '{not json'});
    final bad = await ThemeController.load(await Prefs.load());
    expect(bad.mode, 'system');
    expect(bad.accent, '#4f9cf9');
    SharedPreferences.setMockInitialValues({themeKey: '5'});
    expect((await Prefs.load()).theme, isEmpty);
    SharedPreferences.setMockInitialValues({});
    final c = await ThemeController.load();
    c.setMode('light');
    c.setAccent('#22C55E');
    await Future<void>.delayed(Duration.zero);
    SharedPreferences.setMockInitialValues({
      themeKey: '{"mode":"light","accent":"#22c55e","gradient":"#5b2ea6"}',
    });
    final r = await ThemeController.load(await Prefs.load());
    expect((r.mode, r.accent, r.gradient), ('light', '#22c55e', '#5b2ea6'));
  });
}
