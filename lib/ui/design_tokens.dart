import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

Color hexColor(String hex) {
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final full = h.length == 3 ? h.split('').map((c) => c + c).join() : h;
  return Color(0xFF000000 | int.parse(full, radix: 16));
}

double accentLuminance(Color c) {
  final argb = c.toARGB32();
  double lin(int v) {
    final s = v / 255;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin((argb >> 16) & 0xff) +
      0.7152 * lin((argb >> 8) & 0xff) +
      0.0722 * lin(argb & 0xff);
}

const Color kOnAccentWhite = Color(0xFFFFFFFF);
const Color kOnAccentDark = Color(0xFF111111);

Color onAccentFor(Color accent) {
  final l = accentLuminance(accent);
  return 1.05 / (l + 0.05) >= (l + 0.05) / 0.0556
      ? kOnAccentWhite
      : kOnAccentDark;
}

String? debugFontFamily;

@immutable
class RipploColors extends ThemeExtension<RipploColors> {
  const RipploColors({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.text,
    required this.text2,
    required this.warn,
    required this.danger,
    required this.ok,
    required this.accent,
    required this.onAccent,
    required this.glow,
    required this.accentSoft,
    required this.tabBg,
    required this.light,
  });

  final Color bg,
      surface,
      surface2,
      border,
      text,
      text2,
      warn,
      danger,
      ok,
      accent,
      onAccent,
      glow,
      accentSoft,
      tabBg;
  final bool light;

  static const Color darkBg = Color(0xFF0B0B0C);
  static const Color darkSurface = Color(0xFF161617);
  static const Color darkSurface2 = Color(0xFF1F1F21);
  static const Color darkBorder = Color(0xFF2A2A2D);
  static const Color darkText = Color(0xFFF2F2F3);
  static const Color darkText2 = Color(0xFFA1A1A6);
  static const Color darkWarn = Color(0xFFF5B544);
  static const Color darkDanger = Color(0xFFEF5350);
  static const Color darkOk = Color(0xFF3ECF8E);

  static const Color lightBg = Color(0xFFFFFFFF);
  static const Color lightSurface = Color(0xFFF4F4F6);
  static const Color lightSurface2 = Color(0xFFEBEBEF);
  static const Color lightBorder = Color(0xFFE2E2E7);
  static const Color lightText = Color(0xFF111114);
  static const Color lightText2 = Color(0xFF6B6B73);
  static const Color lightWarn = Color(0xFFB7791F);
  static const Color lightDanger = Color(0xFFD32F2F);
  static const Color lightOk = Color(0xFF1F9D63);

  static const Color defaultAccent = Color(0xFF4F9CF9);

  static RipploColors resolve({
    required bool light,
    Color accent = defaultAccent,
    Color? gradient,
  }) {
    final surface = light ? lightSurface : darkSurface;
    return RipploColors(
      light: light,
      bg: light ? lightBg : darkBg,
      surface: surface,
      surface2: light ? lightSurface2 : darkSurface2,
      border: light ? lightBorder : darkBorder,
      text: light ? lightText : darkText,
      text2: light ? lightText2 : darkText2,
      warn: light ? lightWarn : darkWarn,
      danger: light ? lightDanger : darkDanger,
      ok: light ? lightOk : darkOk,
      accent: accent,
      onAccent: onAccentFor(accent),
      glow: gradient ?? const Color(0x00000000),
      accentSoft: accent.withValues(alpha: .16),
      tabBg: surface.withValues(alpha: .82),
    );
  }

  Color get glowStart => glow.withValues(alpha: glow.a * .55);
  Color get glowEnd => glow.withValues(alpha: 0);

  LinearGradient get pageGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [glowStart, glowEnd],
  );

  SystemUiOverlayStyle get overlayStyle => SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    systemNavigationBarColor: bg,
    statusBarIconBrightness: light ? Brightness.dark : Brightness.light,
    statusBarBrightness: light ? Brightness.light : Brightness.dark,
    systemNavigationBarIconBrightness: light
        ? Brightness.dark
        : Brightness.light,
  );

  @override
  RipploColors copyWith({
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? border,
    Color? text,
    Color? text2,
    Color? warn,
    Color? danger,
    Color? ok,
    Color? accent,
    Color? onAccent,
    Color? glow,
    Color? accentSoft,
    Color? tabBg,
    bool? light,
  }) => RipploColors(
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    surface2: surface2 ?? this.surface2,
    border: border ?? this.border,
    text: text ?? this.text,
    text2: text2 ?? this.text2,
    warn: warn ?? this.warn,
    danger: danger ?? this.danger,
    ok: ok ?? this.ok,
    accent: accent ?? this.accent,
    onAccent: onAccent ?? this.onAccent,
    glow: glow ?? this.glow,
    accentSoft: accentSoft ?? this.accentSoft,
    tabBg: tabBg ?? this.tabBg,
    light: light ?? this.light,
  );

  @override
  RipploColors lerp(ThemeExtension<RipploColors>? other, double t) {
    if (other is! RipploColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return RipploColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surface2: l(surface2, other.surface2),
      border: l(border, other.border),
      text: l(text, other.text),
      text2: l(text2, other.text2),
      warn: l(warn, other.warn),
      danger: l(danger, other.danger),
      ok: l(ok, other.ok),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      glow: l(glow, other.glow),
      accentSoft: l(accentSoft, other.accentSoft),
      tabBg: l(tabBg, other.tabBg),
      light: t < .5 ? light : other.light,
    );
  }
}

extension RipploContext on BuildContext {
  RipploColors get rc => Theme.of(this).extension<RipploColors>()!;
}

const double kRadiusPill = 999;
const double kRadiusSheet = 22;
const double kRadiusToast = 18;
const double kRadiusCard = 14;
const double kRadiusField = 12;
const double kRadiusListRow = 12;

const double kPagePadX = 16;
const double kPageTop = 8;
const double kPageBottomReserve = 110;
const double kTabBarBottom = 12;
const double kToastBottom = 90;
const double kSheetPad = 16;
const double kSheetMaxWidth = 560;
const double kSheetMaxHeightFraction = .92;
const double kToastMaxWidth = 420;
const double kToastMaxWidthFraction = .92;
const double kCenterTextMaxWidth = 340;
const double kGlowHeight = 340;
const double kTabBarBlur = 16;

const double kHdrMin = 52;
const double kIconBtn = 40;
const double kBtnMin = 44;
const double kBtnPadX = 18;
const double kBtnGap = 8;
const double kBtnSmMin = 32;
const double kBtnSmPadX = 12;
const double kCardMarginBottom = 16;
const double kRowMin = 52;
const double kRowPadY = 8;
const double kRowPadX = 14;
const double kRowGap = 12;
const double kPad = 14;
const double kChipPadX = 8;
const double kChipPadY = 2;
const double kChipGap = 4;
const double kSegPad = 3;
const double kSegBtnMin = 34;
const double kSwatchGap = 14;
const double kSwatchSize = 30;
const double kSwatchRingInner = 3;
const double kSwatchRingOuter = 5;
const double kSwitchW = 48;
const double kSwitchH = 28;
const double kSwitchKnob = 22;
const double kSwitchInset = 3;
const double kSwitchTravel = 20;
const double kFieldMin = 48;
const double kFieldPadX = 16;
const double kListRowMin = 68;
const double kListRowPadY = 8;
const double kListRowPadX = 4;
const double kListRowGap = 12;
const double kBadgeMin = 20;
const double kBadgePadX = 6;
const double kDotSize = 9;
const double kDotTop = 4;
const double kDotRight = 8;
const double kTabBarPad = 6;
const double kTabBarGap = 4;
const double kTabPadY = 10;
const double kTabPadX = 16;
const double kTabGap = 6;
const double kToastPadY = 12;
const double kToastPadX = 20;
const double kCenterPad = 24;
const double kCenterGap = 16;
const double kEmptyPadY = 32;
const double kEmptyPadX = 16;
const double kIconSize = 22;
const double kIconStroke = 1.75;

const double kBorderWidth = 1;
const double kFocusOutline = 2;
const double kFocusOutlineOffset = 2;
const double kDisabledOpacity = .5;

const Color kScrim = Color(0x8C000000);
const List<BoxShadow> kToastShadow = [
  BoxShadow(color: Color(0x59000000), offset: Offset(0, 6), blurRadius: 24),
];

List<BoxShadow> swatchRing(RipploColors c) => [
  BoxShadow(color: c.text, spreadRadius: kSwatchRingOuter),
  BoxShadow(color: c.surface, spreadRadius: kSwatchRingInner),
];

const List<Color> kRainbow = [
  Color(0xFFFF0000),
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFF0000FF),
  Color(0xFFFF00FF),
  Color(0xFFFF0000),
];

const Duration kSpinDuration = Duration(seconds: 1);
const Curve kSpinCurve = Curves.linear;
const Duration kSwitchDuration = Duration(milliseconds: 150);
const Curve kSwitchCurve = Curves.ease;

Duration motion(BuildContext context, Duration d) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;

String get kMonoFamily =>
    defaultTargetPlatform == TargetPlatform.iOS ? 'Menlo' : 'monospace';

class RipploText {
  static const TextLeadingDistribution _even = TextLeadingDistribution.even;

  static const TextStyle body = TextStyle(
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w400,
    leadingDistribution: _even,
  );
  static const TextStyle h1 = TextStyle(
    fontSize: 28,
    height: 1.4,
    fontWeight: FontWeight.w700,
    leadingDistribution: _even,
  );
  static const TextStyle sheetTitle = TextStyle(
    fontSize: 20,
    height: 1.4,
    fontWeight: FontWeight.w700,
    leadingDistribution: _even,
  );
  static const TextStyle sub = TextStyle(
    fontSize: 12,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle btn = TextStyle(
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w600,
    leadingDistribution: _even,
  );
  static const TextStyle btnSm = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w600,
    leadingDistribution: _even,
  );
  static const TextStyle section = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w600,
    letterSpacing: 13 * .04,
    leadingDistribution: _even,
  );
  static const TextStyle rowLabel = TextStyle(
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w500,
    leadingDistribution: _even,
  );
  static const TextStyle rowHint = TextStyle(
    fontSize: 13,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle rowVal = TextStyle(
    fontSize: 14,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle chip = TextStyle(
    fontSize: 12,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle seg = TextStyle(
    fontSize: 14,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle segOn = TextStyle(
    fontSize: 14,
    height: 1.4,
    fontWeight: FontWeight.w600,
    leadingDistribution: _even,
  );
  static const TextStyle listName = TextStyle(
    fontSize: 16,
    height: 1.4,
    fontWeight: FontWeight.w600,
    leadingDistribution: _even,
  );
  static const TextStyle listPrev = TextStyle(
    fontSize: 14,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle listMeta = TextStyle(
    fontSize: 12,
    height: 1.4,
    leadingDistribution: _even,
  );
  static const TextStyle badge = TextStyle(
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w600,
    leadingDistribution: _even,
  );
  static const TextStyle tab = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w500,
    leadingDistribution: _even,
  );
  static const TextStyle toast = TextStyle(
    fontSize: 15,
    height: 1.35,
    leadingDistribution: _even,
  );

  static TextStyle mono(TextStyle base) => base.copyWith(
    fontFamily: kMonoFamily,
    fontFamilyFallback: const ['ui-monospace', 'SF Mono', 'Menlo', 'monospace'],
  );
}
