import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../translations.dart';
import '../mesh/native_mesh_bridge.dart';
import '../util/js_compat.dart' as js;

const _away = 30000;

class AppLock extends ChangeNotifier {
  AppLock({
    required this.mesh,
    required this.state,
    required this.saveSettings,
    int Function()? now,
  }) : _now = now ?? (() => js.now());

  final Mesh mesh;
  final RipploState state;
  final Future<void> Function(Map<String, Object?> patch) saveSettings;
  final int Function() _now;
  bool _locked = false;
  bool _busy = false;
  int _hiddenAt = 0;
  AppLifecycleListener? _lifecycle;

  bool get locked => _locked;
  bool get busy => _busy;
  bool get showLock => _locked && !state.lockedCall;
  bool get showContent => !state.lockedCall;

  void _set({bool? locked, bool? busy}) {
    _locked = locked ?? _locked;
    _busy = busy ?? _busy;
    notifyListeners();
  }

  Future<void> unlock() async {
    if (_busy) return;
    _set(busy: true);
    try {
      if (await mesh.authenticate(t('unlockReason'))) _set(locked: false);
    } catch (_) {
    } finally {
      _set(busy: false);
    }
  }

  Future<bool> setAppLock(bool on) async {
    if (!await mesh.authenticate(t('unlockReason'))) return false;
    await saveSettings({'appLock': on});
    await mesh.setSecure(on);
    return true;
  }

  void away() {
    if (!_locked && !_busy && _hiddenAt == 0) _hiddenAt = _now();
  }

  void back() {
    final long = _hiddenAt != 0 && _now() - _hiddenAt > _away;
    _hiddenAt = 0;
    if (long && state.settings.appLock) {
      _set(locked: true);
      js.fire(unlock());
    }
  }

  void start() {
    js.fire(mesh.setSecure(state.settings.appLock));
    if (state.settings.appLock) {
      _set(locked: true);
      js.fire(unlock());
    }
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s == AppLifecycleState.resumed) {
          back();
        } else if (s != AppLifecycleState.inactive) {
          away();
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}
