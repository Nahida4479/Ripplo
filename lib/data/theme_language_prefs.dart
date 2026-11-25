import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String themeKey = 'ripplo.theme';
const String langKey = 'ripplo.lang';

class Prefs {
  Prefs({this.theme = const {}, this.lang});

  final Map<String, Object?> theme;
  final String? lang;

  static Future<SharedPreferences?> _open() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static Future<Prefs> load() async {
    final sp = await _open();
    if (sp == null) return Prefs();
    Map<String, Object?> theme = const {};
    String? lang;
    try {
      final raw = sp.getString(themeKey);
      if (raw != null) {
        final v = jsonDecode(raw);
        if (v is Map) theme = Map<String, Object?>.from(v);
      }
    } catch (_) {}
    try {
      lang = sp.getString(langKey);
    } catch (_) {}
    return Prefs(theme: theme, lang: lang);
  }

  static Future<void> saveTheme(Map<String, Object?> theme) async {
    try {
      final sp = await _open();
      await sp?.setString(themeKey, jsonEncode(theme));
    } catch (_) {}
  }

  static Future<void> saveLang(String lang) async {
    try {
      final sp = await _open();
      await sp?.setString(langKey, lang);
    } catch (_) {}
  }
}
