import 'dart:async';

import 'package:flutter/services.dart';

import '../mesh/native_mesh_bridge.dart';

class Ringtone {
  Ringtone({required this.mesh});

  final Mesh mesh;
  Timer? _timer;
  bool _native = false;

  void start() {
    stop();
    if (mesh.isNative) {
      _native = true;
      mesh.startRing().catchError((Object _) => _web());
      return;
    }
    _web();
  }

  void _web() {
    _cycle();
    _timer = Timer.periodic(
      const Duration(milliseconds: 2500),
      (_) => _cycle(),
    );
  }

  void _cycle() {
    SystemSound.play(SystemSoundType.alert).catchError((Object _) {});
    HapticFeedback.vibrate().catchError((Object _) {});
  }

  void stop() {
    if (_native) {
      _native = false;
      mesh.stopRing().catchError((Object _) {});
    }
    _timer?.cancel();
    _timer = null;
  }
}
