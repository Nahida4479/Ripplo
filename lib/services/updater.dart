import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/state.dart';
import '../i18n.dart';
import '../mesh/bridge.dart';
import '../ui/ui_state.dart';
import '../util/github_cache.dart';
import '../util/js.dart' as js;

const releasesUrl = 'https://api.github.com/repos/Nahida4479/Ripplo/releases';
const _fallbackVersion = String.fromEnvironment(
  'RIPPLO_VERSION',
  defaultValue: '0.0.0',
);
const _day = 24 * 3600 * 1000;
const _promptGap = 6 * 3600 * 1000;
final _sha = RegExp(r'^[0-9a-f]{64}$', caseSensitive: false);

List<int> _num(String v) => v
    .replaceFirst(RegExp(r'^v'), '')
    .split('.')
    .map(
      (n) =>
          int.tryParse(RegExp(r'^\s*[+-]?\d+').stringMatch(n)?.trim() ?? '') ??
          0,
    )
    .toList();

bool newer(String a, String b) {
  final x = _num(a), y = _num(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p > q;
  }
  return false;
}

String? hashOf(Map rel, String name) {
  final assets = rel['assets'] is List ? rel['assets'] as List : const [];
  for (final a in assets) {
    if (a is Map && a['name'] == name) {
      final d = a['digest'];
      if (d is String && d.startsWith('sha256:')) return d.substring(7);
      break;
    }
  }
  for (final l in '${rel['body'] ?? ''}'.split('\n')) {
    final p = l.trim().split(RegExp(r'\s+'));
    if (p.length >= 2 && p[1] == name && _sha.hasMatch(p[0])) return p[0];
  }
  return null;
}

bool validInstall(String? url, String? sha) {
  final u = url == null ? null : Uri.tryParse(url);
  return u != null &&
      u.scheme == 'https' &&
      u.host.isNotEmpty &&
      sha != null &&
      _sha.hasMatch(sha);
}

class PrefsGhStorage implements GhStorage {
  PrefsGhStorage(this.sp);
  final SharedPreferences sp;
  @override
  String? getItem(String key) => sp.getString(key);
  @override
  void setItem(String key, String value) => js.fire(sp.setString(key, value));
}

Future<GhResponse> httpGhFetch(String url, Map<String, String> headers) async {
  final c = HttpClient();
  try {
    final req = await c.getUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    final res = await req.close();
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(','));
    final text = await res.transform(utf8.decoder).join();
    return GhResponse(
      res.statusCode,
      headers: h,
      json: () async => jsonDecode(text),
    );
  } finally {
    c.close();
  }
}

Future<String> packageVersion() async =>
    (await PackageInfo.fromPlatform()).version;

class Updater {
  Updater({
    required this.mesh,
    required this.state,
    required this.ui,
    required this.getJson,
    required this.native,
    this.currentVersion = packageVersion,
    this.online = _yes,
    this.openUrl,
    this.minCheck = const Duration(milliseconds: 800),
    int Function()? now,
  }) : _now = now ?? (() => js.now());

  static bool _yes() => true;

  final Mesh mesh;
  final RipploState state;
  final UiState ui;
  final GhGet getJson;
  final bool native;
  final Future<String> Function() currentVersion;
  final bool Function() online;
  final void Function(String url)? openUrl;
  final Duration minCheck;
  final int Function() _now;
  Future<String>? _current;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  VoidCallback? _settingsWatch;

  Future<String> version() =>
      _current ??= (native ? currentVersion() : Future.value(_fallbackVersion))
          .catchError((Object _) => _fallbackVersion)
          .then((v) => state.update.current = v);

  String _explain(Object e) {
    if (e is GhError) {
      if (e.code == 'rate') {
        final d = DateTime.fromMillisecondsSinceEpoch(e.until ?? 0);
        final hh = d.hour.toString().padLeft(2, '0');
        final mm = d.minute.toString().padLeft(2, '0');
        return t('err_rate_limit', {'time': '$hh:$mm'});
      }
      return e.message;
    }
    return '$e';
  }

  Future<void> checkUpdate([bool manual = false]) async {
    final u = state.update;
    final cur = await version();
    if (!online() || u.checking) return;
    u.checking = true;
    u.error = null;
    final t0 = _now();
    try {
      final rel =
          await (manual
                  ? getJson('$releasesUrl/latest', maxAge: 60000)
                  : getJson('$releasesUrl/latest'))
              as Map;
      final tag = '${rel['tag_name']}';
      u.latest = tag.replaceFirst(RegExp(r'^v'), '');
      u.url = rel['html_url'] as String?;
      u.available = newer(u.latest!, cur);
      final name = 'Ripplo-$tag.apk';
      final assets = rel['assets'] as List;
      final apk = assets
          .cast<Map>()
          .where((a) => a['name'] == name)
          .firstOrNull;
      u.apkUrl = apk?['browser_download_url'] as String?;
      u.sha256 = hashOf(rel, name);
      u.checkedAt = _now();
      if (u.available) promptUpdate();
    } catch (e) {
      u.error = _explain(e);
    } finally {
      final left = minCheck - Duration(milliseconds: _now() - t0);
      if (left > Duration.zero) await Future<void>.delayed(left);
      u.checking = false;
    }
  }

  void promptUpdate() {
    final u = state.update;
    if (ui.confirm != null || _now() - u.promptedAt < _promptGap) return;
    u.promptedAt = _now();
    final direct = native && validInstall(u.apkUrl, u.sha256);
    ui.confirm = ConfirmRequest(
      title: t('updateFound', {'version': u.latest}),
      text: t(direct ? 'updateAsk' : 'updateAskWeb'),
      ok: t(direct ? 'updateNow' : 'openRelease'),
      cancel: t('later'),
      onOk: () {
        if (direct) {
          return install();
        }
        final url = u.url;
        if (url != null && url.startsWith('https://')) openUrl?.call(url);
      },
    );
  }

  Future<void> install([bool prompt = true]) async {
    final u = state.update;
    if (u.installing) return;
    final url = u.apkUrl, sha = u.sha256;
    if (!validInstall(url, sha)) {
      u.error = 'invalid_update';
      return;
    }
    u.installing = true;
    u.error = null;
    u.progress = 0;
    final off = mesh.on(
      'updateProgress',
      (d) => u.progress = d['progress'] as num?,
    );
    try {
      await mesh.installUpdate(url!, sha!, prompt);
    } catch (e) {
      final m = e is MeshError ? e.message : '$e';
      u.error = m == 'install_permission' ? t('err_install_permission') : m;
    } finally {
      off();
      u.progress = null;
      u.installing = false;
    }
  }

  Future<void> checkIntegrity() async {
    final i = state.integrity;
    try {
      if (!native) {
        i.status = 'unsupported';
        i.checkedAt = _now();
        return;
      }
      final mine = await mesh.selfHash();
      if (mine == null || mine.isEmpty) {
        i.status = 'unsupported';
        return;
      }
      if (!online()) {
        i.status = 'offline';
        return;
      }
      final tag = 'v${await version()}';
      final rel = await getJson('$releasesUrl/tags/$tag', maxAge: _day) as Map;
      final hash = hashOf(rel, 'Ripplo-$tag.apk');
      final ok = hash != null && hash.toLowerCase() == mine.toLowerCase();
      i.status = ok ? 'ok' : 'mismatch';
      i.checkedAt = _now();
    } catch (_) {
      i.status = 'offline';
    }
  }

  void _run() {
    js.fire(checkUpdate());
    js.fire(checkIntegrity());
  }

  Future<void> start() async {
    if (native && await mesh.fromPlay()) {
      state.fromPlay = true;
      state.integrity.status = 'unsupported';
      js.fire(version());
      js.fire(mesh.setAutoUpdate(false));
      return;
    }
    _run();
    _timer = Timer.periodic(const Duration(hours: 6), (_) => _run());
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (_now() - state.update.checkedAt > 10 * 60000) _run();
      },
    );
    if (native) {
      bool? last;
      void watch() {
        final on = state.settings.autoUpdate;
        if (on == last) return;
        last = on;
        js.fire(mesh.setAutoUpdate(on));
      }

      _settingsWatch = watch;
      state.addListener(watch);
      watch();
    }
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    final w = _settingsWatch;
    if (w != null) state.removeListener(w);
  }
}
