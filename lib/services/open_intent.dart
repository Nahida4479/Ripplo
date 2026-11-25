import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/state.dart';
import '../mesh/bridge.dart';
import '../util/js.dart' as js;
import 'notifications.dart';

const _answerWindow = 20000;
final _chatId = RegExp(r'^[0-9A-HJKMNP-TV-Z]{16}$|^[A-Za-z0-9_-]{6,32}$');

class OpenIntent {
  OpenIntent({
    required this.mesh,
    required this.state,
    required this.acceptCall,
    required this.openChat,
    this.notifications,
    int Function()? now,
  }) : _now = now ?? (() => js.now());

  final Mesh mesh;
  final RipploState state;
  final Future<void> Function() acceptCall;
  final void Function(String chatId) openChat;
  final Notifications? notifications;
  final int Function() _now;

  ({String peer, String id, int until})? _want;
  bool _sawCall = false;
  bool _hadCall = false;
  List<Object?>? _last;
  Timer? _poll;
  Timer? _guard;
  Unsub? _off;
  AppLifecycleListener? _lifecycle;

  void go(Object? id) {
    final s = '$id';
    if (_chatId.hasMatch(s)) openChat(s);
  }

  void _stopTimers() {
    _poll?.cancel();
    _guard?.cancel();
    _poll = _guard = null;
  }

  void endLocked() {
    _stopTimers();
    _sawCall = false;
    if (!state.lockedCall) return;
    state.lockedCall = false;
    js.fire(mesh.endLockedCall());
  }

  Future<void> enterLocked() async {
    if (state.lockedCall || !await mesh.isLocked()) return;
    state.lockedCall = true;
    _sawCall = state.call != null;
    _guard = Timer(const Duration(milliseconds: _answerWindow + 5000), () {
      if (state.call == null) endLocked();
    });
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      bool locked;
      try {
        locked = await mesh.isLocked();
      } catch (_) {
        return;
      }
      if (!locked) {
        _stopTimers();
        state.lockedCall = false;
      }
    });
  }

  Future<void> take() async {
    final o = await mesh.takeOpen();
    if (o == null) return;
    final answer = o['answer'];
    final chat = o['chatId'];
    if (js.truthy(answer)) {
      _want = (peer: '$chat', id: '$answer', until: _now() + _answerWindow);
      await enterLocked();
    }
    go(chat);
  }

  void _onState() {
    final has = state.call != null;
    if (has != _hadCall) {
      _hadCall = has;
      if (state.lockedCall) {
        if (has) {
          _sawCall = true;
        } else if (_sawCall) {
          endLocked();
        }
      }
    }
    final c = state.call;
    final key = [c?.status, c?.peer, c?.dir, c?.id];
    final last = _last;
    if (last != null &&
        last[0] == key[0] &&
        last[1] == key[1] &&
        last[2] == key[2] &&
        last[3] == key[3]) {
      return;
    }
    _last = key;
    final w = _want;
    if (w != null &&
        c != null &&
        c.status == 'ringing' &&
        c.dir == 'in' &&
        c.peer == w.peer &&
        c.id == w.id &&
        _now() < w.until) {
      _want = null;
      js.fire(acceptCall());
    }
  }

  void start() {
    _hadCall = state.call != null;
    state.addListener(_onState);
    _onState();
    notifications?.onTap = go;
    js.fire(take());
    _off = mesh.on('open', (_) => js.fire(take()));
    _lifecycle = AppLifecycleListener(onResume: () => js.fire(take()));
  }

  void dispose() {
    state.removeListener(_onState);
    _stopTimers();
    _off?.call();
    _lifecycle?.dispose();
  }
}
