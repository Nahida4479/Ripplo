import 'package:flutter/widgets.dart';

import '../core/messenger_core.dart';
import '../mesh/native_mesh_bridge.dart';
import '../util/js_compat.dart' as js;

class Notifications {
  Notifications({required this.mesh, bool Function()? visible})
    : _visible = visible ?? _foreground;

  final Mesh mesh;
  final bool Function() _visible;
  String? _openChat;
  Future<bool>? _granted;
  void Function(String chatId)? _onTap;

  static bool _foreground() {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null ||
        s == AppLifecycleState.resumed ||
        s == AppLifecycleState.inactive;
  }

  void setOpenChat(String? id) => _openChat = id;

  set onTap(void Function(String chatId)? cb) => _onTap = cb;

  Future<void> takeTap() async {
    final chatId = (await mesh.takeOpen())?['chatId'];
    final cb = _onTap;
    if (chatId is String && chatId.isNotEmpty && cb != null) cb(chatId);
  }

  Notifier get notifier => notify;

  void notify(Notice n) {
    if (_visible() && _openChat == n.chatId) return;
    js.fire(_send(n));
  }

  Future<void> _send(Notice n) async {
    try {
      if (mesh.isNative && !await (_granted ??= _ask())) return;
      await mesh.notify(n.title, n.body, n.chatId);
    } catch (_) {}
  }

  Future<bool> _ask() async {
    if ((await mesh.checkPermissions())['notifications'] == 'granted') {
      return true;
    }
    return (await mesh.requestPermissions())['notifications'] == 'granted';
  }
}
