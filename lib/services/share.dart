import 'package:flutter/widgets.dart';

import '../mesh/bridge.dart';
import '../ui/ui_state.dart';
import '../util/js.dart' as js;

Future<void> checkShare(Mesh mesh, UiState ui) async {
  final s = await mesh.takeShare();
  if (s != null) {
    ui.share = ShareRequest(
      kind: s['kind'] as String,
      text: s['text'] as String?,
      path: s['path'] as String?,
      mime: s['mime'] as String?,
    );
  }
}

void Function() startShare(Mesh mesh, UiState ui) {
  js.fire(checkShare(mesh, ui));
  final unsub = mesh.on('share', (_) => js.fire(checkShare(mesh, ui)));
  final lifecycle = AppLifecycleListener(onResume: () => js.fire(checkShare(mesh, ui)));
  return () {
    unsub();
    lifecycle.dispose();
  };
}
