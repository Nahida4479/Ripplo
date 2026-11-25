import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../mesh/native_mesh_bridge.dart';
import '../util/js_compat.dart' as js;

Map<String, Object?> backupMeta(RipploState state, String appVersion) {
  final p = state.profile;
  return {
    'app': appVersion,
    'created': js.now(),
    if (p != null) 'ripploId': p.ripploId,
  };
}

String groupCode(String s) {
  final digits = js.cut(s.replaceAll(RegExp(r'\D'), ''), 0, 30);
  return RegExp(r'.{1,5}').allMatches(digits).map((m) => m.group(0)!).join(' ');
}

Future<void> autoBackup(Mesh mesh, RipploState state, String appVersion) async {
  if (!mesh.isNative) return;
  try {
    final s = await mesh.backupStatus();
    if (js.truthy(s['enabled']) && js.truthy(s['folder'])) {
      await mesh.backupCreate('auto', backupMeta(state, appVersion));
    }
  } catch (_) {}
}

AppLifecycleListener startBackup(
  Mesh mesh,
  RipploState state,
  String appVersion,
) {
  js.fire(autoBackup(mesh, state, appVersion));
  return AppLifecycleListener(
    onResume: () => js.fire(autoBackup(mesh, state, appVersion)),
  );
}
