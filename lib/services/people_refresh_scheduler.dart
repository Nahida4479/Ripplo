import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/app_state.dart';
import '../util/js_compat.dart' as js;
import '../util/refresh_slot_schedule.dart';

class Scheduler {
  Scheduler({required this.state, required this.refreshPeople});

  final RipploState state;
  final Future<void> Function() refreshPeople;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  void start() {
    _timer = Timer.periodic(
      const Duration(milliseconds: slotMs),
      (_) => tick(),
    );
    _lifecycle = AppLifecycleListener(onResume: tick);
    tick();
  }

  void tick() {
    final p = state.profile;
    if (p == null || state.peopleRefreshing) return;
    if (isDue(p.tag, state.peopleRefreshedAt)) js.fire(refreshPeople());
  }

  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
  }
}
